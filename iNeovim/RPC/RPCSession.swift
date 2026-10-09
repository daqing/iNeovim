import Foundation
import os

actor RPCSession {
    private var decoder = MsgPackDecoder()
    private var nextMsgid: UInt64 = 1
    private var pending: [UInt64: CheckedContinuation<MsgPackValue, Error>] = [:]
    private var notificationHandlers: [String: [@Sendable ([MsgPackValue]) -> Void]] = [:]
    private var isClosed = false
    private var readTask: Task<Void, Never>?

    /// The embedded process this session speaks to; one process per session.
    let process: NvimProcess
    /// The `redraw` notification bridge owned by this session.
    let redrawBus = RedrawEventStream()

    init(process: NvimProcess = NvimProcess()) {
        self.process = process
    }

    /// Oldest nvim API level this GUI is written against (Neovim 0.9).
    static let minimumApiLevel: UInt64 = 12

    private(set) var channel: UInt64?

    /// Exchange `nvim_get_api_info`, recording the channel id and checking the
    /// API level reported by nvim.
    func handshake() async throws {
        let response = try await call("nvim_get_api_info")
        guard case let .array(info) = response,
              info.count == 2,
              case let .uint(channel) = info[0] else {
            throw RPCError.invalidHandshake(response)
        }
        self.channel = channel

        if case let .map(metadata) = info[1],
           case let .map(version)? = metadata[.string("version")],
           case let .uint(apiLevel)? = version[.string("api_level")] {
            guard apiLevel >= Self.minimumApiLevel else {
                throw RPCError.unsupportedApiLevel(found: apiLevel, required: Self.minimumApiLevel)
            }
            Log.rpc.info("nvim channel \(channel, privacy: .public), API level \(apiLevel, privacy: .public)")
        }
    }

    func addNotificationHandler(for method: String, handler: @escaping @Sendable ([MsgPackValue]) -> Void) {
        notificationHandlers[method, default: []].append(handler)
    }

    func start() async throws {
        try await process.start()
        guard !isClosed, let output = await process.standardOutput else { throw NvimProcessError.notRunning }
        // Read on the pipe's queue and hand chunks to a single consumer through
        // an AsyncStream. Yielding to one continuation (instead of spawning a
        // Task per chunk) guarantees the decoder sees bytes in arrival order:
        // an out-of-order `feed` corrupts the stream and blanks the screen.
        readTask?.cancel()
        let (chunks, continuation) = AsyncStream<Data>.makeStream()
        output.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            continuation.yield(data)
        }
        readTask = Task { [weak self] in
            for await chunk in chunks {
                await self?.feed(chunk)
            }
            guard !Task.isCancelled else { return }
            await self?.close(RPCError.connectionClosed)
        }
    }

    /// Return the session to a pre-start state so a restarted nvim can be
    /// handshaken over the same client. Pending calls are failed by `close`
    /// before `reset` is called (see `AppModel.restart`).
    func reset() {
        readTask?.cancel()
        readTask = nil
        decoder = MsgPackDecoder()
        nextMsgid = 1
        pending.removeAll()
        notificationHandlers.removeAll()
        isClosed = false
        channel = nil
    }

    /// Send a request and resume with its result; a non-nil error value from nvim
    /// becomes an `RPCError.remote`.
    func call(_ method: String, params: [MsgPackValue] = []) async throws -> MsgPackValue {
        if isClosed { throw RPCError.connectionClosed }
        let msgid = nextMsgid
        nextMsgid += 1
        let message = MsgPackValue.array([.uint(0), .uint(msgid), .string(method), .array(params)])
        return try await withCheckedThrowingContinuation { continuation in
            pending[msgid] = continuation
            do {
                try process.writeToStandardInput(MsgPackEncoder.encode(message))
            } catch {
                pending.removeValue(forKey: msgid)
                continuation.resume(throwing: error)
            }
        }
    }

    private func send(_ value: MsgPackValue) throws {
        try process.writeToStandardInput(MsgPackEncoder.encode(value))
    }

    private func close(_ error: Error) {
        guard !isClosed else { return }
        isClosed = true
        Log.rpc.error("RPC connection closed: \(error.localizedDescription, privacy: .public)")
        let continuations = pending
        pending.removeAll()
        for continuation in continuations.values {
            continuation.resume(throwing: error)
        }
    }

    func feed(_ data: Data) {
        let signpost = Signpost.rpc.beginInterval("decode")
        defer { Signpost.rpc.endInterval("decode", signpost) }
        decoder.feed(data)
        do {
            while let value = try decoder.nextValue() {
                guard let message = RPCMessage(value) else {
                    Log.rpc.error("Discarding unparseable RPC message")
                    continue
                }
                handleMessage(message)
            }
        } catch {
            Log.rpc.error("RPC decode error: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleMessage(_ message: RPCMessage) {
        switch message {
        case .request(let msgid, let method, _):
            Log.rpc.warning("Unhandled RPC request \(method, privacy: .public); replying with error")
            do {
                try send(.array([.uint(1), .uint(msgid), .string("request not supported by GUI"), .nil]))
            } catch {
                Log.rpc.error("Failed to reply to RPC request: \(error.localizedDescription, privacy: .public)")
            }
        case .response(let msgid, let error, let result):
            guard let continuation = pending.removeValue(forKey: msgid) else {
                Log.rpc.error("Stray RPC response #\(msgid, privacy: .public)")
                return
            }
            if error == .nil {
                continuation.resume(returning: result)
            } else {
                continuation.resume(throwing: RPCError.remote(error))
            }
        case .notification(let method, let params):
            guard let handlers = notificationHandlers[method], !handlers.isEmpty else {
                Log.rpc.debug("No handlers for RPC notification \(method, privacy: .public)")
                return
            }
            for handler in handlers {
                handler(params)
            }
        }
    }
}
