import Foundation
import os

actor RPCSession {
    static let shared = RPCSession()

    private let process = NvimProcess.shared
    private var decoder = MsgPackDecoder()
    private var nextMsgid: UInt64 = 1
    private var pending: [UInt64: CheckedContinuation<MsgPackValue, Error>] = [:]

    func start() async throws {
        try await process.start()
        guard let output = await process.standardOutput else { throw NvimProcessError.notRunning }
        output.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            Task { await self?.feed(data) }
        }
    }

    /// Send a request and resume with its result; a non-nil error value from nvim
    /// becomes an `RPCError.remote`.
    func call(_ method: String, params: [MsgPackValue] = []) async throws -> MsgPackValue {
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
            Log.rpc.debug("RPC notification \(method, privacy: .public) (\(params.count, privacy: .public) params)")
        }
    }
}
