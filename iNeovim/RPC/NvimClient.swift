import Foundation

struct NvimClient {
    let session: RPCSession

    init(session: RPCSession = .shared) {
        self.session = session
    }

    func getApiInfo() async throws -> MsgPackValue {
        try await session.call("nvim_get_api_info")
    }

    func uiAttach(width: Int, height: Int, options: MsgPackValue = .map(MsgPackValueMap())) async throws {
        _ = try await session.call("nvim_ui_attach", params: [
            .int(Int64(width)), .int(Int64(height)), options,
        ])
    }

    func input(_ keys: String) async throws {
        _ = try await session.call("nvim_input", params: [.string(keys)])
    }

    func inputMouse(button: String, action: String, modifier: String, grid: Int, row: Int, col: Int) async throws {
        _ = try await session.call("nvim_input_mouse", params: [
            .string(button), .string(action), .string(modifier),
            .int(Int64(grid)), .int(Int64(row)), .int(Int64(col)),
        ])
    }

    func command(_ command: String) async throws {
        _ = try await session.call("nvim_command", params: [.string(command)])
    }

    func callAtomic(_ calls: [MsgPackValue]) async throws -> MsgPackValue {
        try await session.call("nvim_call_atomic", params: [.array(calls)])
    }

    func uiTryResize(width: Int, height: Int) async throws {
        _ = try await session.call("nvim_ui_try_resize", params: [
            .int(Int64(width)), .int(Int64(height)),
        ])
    }

    /// Stream `redraw` notifications as typed events; subscribes to the
    /// session on first use. Single consumer: the live stream is handed out
    /// only once.
    func makeRedrawEventStream() async -> AsyncStream<RedrawEvent> {
        let bus = RedrawEventStream.shared
        await bus.subscribe(to: session)
        return await bus.makeStream()
    }
}
