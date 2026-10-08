import Foundation
import os

actor RPCSession {
    static let shared = RPCSession()

    private let process = NvimProcess.shared
    private var decoder = MsgPackDecoder()

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
            Log.rpc.debug("RPC request #\(msgid, privacy: .public): \(method, privacy: .public)")
        case .response(let msgid, _, _):
            Log.rpc.debug("RPC response #\(msgid, privacy: .public)")
        case .notification(let method, let params):
            Log.rpc.debug("RPC notification \(method, privacy: .public) (\(params.count, privacy: .public) params)")
        }
    }
}
