import Foundation

struct NvimClient {
    let session: RPCSession

    init(session: RPCSession) {
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

    /// Paste clipboard text as if typed, in one chunk (`phase = -1`).
    func paste(_ text: String) async throws {
        _ = try await session.call("nvim_paste", params: [
            .string(text), .bool(true), .int(-1),
        ])
    }

    /// Evaluate a VimL expression and return a string form of its value;
    /// scalars (used for `exists()`, counts, and flags) are stringified.
    func evaluate(_ expression: String) async throws -> String {
        let value = try await session.call("nvim_eval", params: [.string(expression)])
        switch value {
        case let .string(text):
            return text
        case let .int(number):
            return String(number)
        case let .uint(number):
            return String(number)
        case let .bool(flag):
            return flag ? "1" : "0"
        default:
            return ""
        }
    }

    /// Read a register's contents as text (used for the system clipboard).
    func registerContents(_ name: String) async throws -> String {
        let value = try await session.call("nvim_call_function", params: [
            .string("getreg"), .array([.string(name), .bool(true), .bool(true)]),
        ])
        return value.stringValue ?? ""
    }

    /// Escape a path for use in an Ex command (`:edit <path>`).
    func fnameescape(_ path: String) async throws -> String {
        let value = try await session.call("nvim_call_function", params: [
            .string("fnameescape"), .array([.string(path)]),
        ])
        return value.stringValue ?? path
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
        let bus = session.redrawBus
        await bus.subscribe(to: session)
        return await bus.makeStream()
    }
}
