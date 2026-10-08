import Foundation
import os

actor RPCSession {
    static let shared = RPCSession()

    private let process = NvimProcess.shared
    private var decoder = MsgPackDecoder()
    private var nextMsgid: UInt64 = 1
    private var pending: [UInt64: CheckedContinuation<MsgPackValue, Error>] = [:]
    private var notificationHandlers: [String: [@Sendable ([MsgPackValue]) -> Void]] = [:]
    private var isClosed = false

    func addNotificationHandler(for method: String, handler: @escaping @Sendable ([MsgPackValue]) -> Void) {
        notificationHandlers[method, default: []].append(handler)
    }

    func start() async throws {
        try await process.start()
        guard !isClosed, let output = await process.standardOutput else { throw NvimProcessError.notRunning }
        output.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                Task { await self?.close(RPCError.connectionClosed) }
                return
            }
            Task { await self?.feed(data) }
        }
        Task { [weak self] in
            for await _ in await NvimProcess.shared.termination {
                await self?.close(RPCError.connectionClosed)
            }
        }
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
