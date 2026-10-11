import Foundation

/// One `vim.diagnostic` entry on the clicked line.
nonisolated struct LineDiagnostic: Equatable {
    enum Severity: Int {
        case error = 1
        case warning
        case info
        case hint
    }

    var severity: Severity
    var message: String
    var source: String
    var code: String
}

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

    /// Pick an ext_popupmenu completion: move the selection to `index` and
    /// insert it, closing the menu (row clicks in the native panel).
    func selectPopupmenuItem(_ index: Int) async throws {
        _ = try await session.call("nvim_select_popupmenu_item", params: [
            .int(Int64(index)), .bool(true), .bool(true), .nil,
        ])
    }

    /// The embedded nvim's working directory (the directory fzf's sources
    /// would walk when launched from the cmdline).
    func currentDirectory() async throws -> String {
        try await callFunction("getcwd", args: [])
    }

    /// Run a Lua chunk with `nvim_exec_lua`; `args` arrive as varargs.
    func execLua(_ code: String, args: [MsgPackValue] = []) async throws -> MsgPackValue {
        try await session.call("nvim_exec_lua", params: [.string(code), .array(args)])
    }

    /// Translate a grid position to the buffer line it displays (across
    /// splits), then collect the diagnostics on that line. The Lua runs in
    /// the embedded nvim because only it knows the window layout and each
    /// window's scroll position.
    func lineDiagnostics(row: Int, col: Int) async throws -> [LineDiagnostic] {
        let value = try await execLua(Self.lineDiagnosticsLua, args: [
            .int(Int64(row)), .int(Int64(col)),
        ])
        return Self.parseLineDiagnostics(value)
    }

    /// Map with the `lnum`/`items` shape produced by `lineDiagnosticsLua`.
    static func parseLineDiagnostics(_ value: MsgPackValue) -> [LineDiagnostic] {
        guard case let .map(map) = value,
              case let .array(items)? = map[.string("items")] else { return [] }
        return items.compactMap { item in
            guard case let .map(fields) = item else { return nil }
            return LineDiagnostic(
                severity: fields[.string("severity")]?.intValue.flatMap(LineDiagnostic.Severity.init(rawValue:)) ?? .info,
                message: fields[.string("message")]?.stringValue ?? "",
                source: fields[.string("source")]?.stringValue ?? "",
                code: fields[.string("code")]?.stringValue ?? ""
            )
        }
    }

    /// Find the window covering the clicked cell, map the screen row to a
    /// buffer line (`getwininfo` reports window rects in the same global
    /// grid coordinates `nvim_input_mouse` uses), and list that line's
    /// `vim.diagnostic` entries. Guarded by pcall so nvim versions without
    /// the module still return an empty list and the click falls through.
    private static let lineDiagnosticsLua = """
        local row, col = ...
        local target = nil
        for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          local info = vim.fn.getwininfo(w)[1]
          if info
            and row + 1 >= info.winrow and row + 1 < info.winrow + info.height
            and col + 1 >= info.wincol and col + 1 < info.wincol + info.width then
            target = { win = w, info = info }
            break
          end
        end
        if not target then return { items = {} } end
        local lnum = target.info.topline + (row + 1 - target.info.winrow)
        local items = {}
        local ok, diags = pcall(vim.diagnostic.get, vim.api.nvim_win_get_buf(target.win), { lnum = lnum - 1 })
        if ok then
          for _, d in ipairs(diags) do
            table.insert(items, {
              severity = d.severity or 3,
              message = d.message or '',
              source = d.source or '',
              code = d.code and tostring(d.code) or '',
            })
          end
        end
        return { lnum = lnum, items = items }
        """

    /// Install the diagnostics hook in the embedded nvim: autocmds broadcast
    /// every `vim.diagnostic` change — from any language server, for any
    /// buffer — back to this GUI as `NvimDiagnosticUpdate.rpcMethod`
    /// notifications, plus an initial sweep over buffers that already carry
    /// diagnostics. Idempotent per nvim instance.
    func installDiagnosticsHook() async throws -> Bool {
        let value = try await execLua(Self.diagnosticsHookLua, args: [])
        return value.boolValue ?? false
    }

    /// Move the cursor in the active window (problems-sheet jump target).
    /// `line` is 1-based, `column` the zero-based byte offset nvim reports.
    func moveCursor(line: Int, column: Int) async throws {
        _ = try await execLua(
            "local lnum, col = ...; vim.api.nvim_win_set_cursor(0, { lnum, col }); return true",
            args: [.int(Int64(line)), .int(Int64(column))]
        )
    }

    /// The diagnostics hook: re-collects the full per-buffer snapshot through
    /// `vim.diagnostic.get` inside the autocmd (instead of trusting the event
    /// payload) so the shape is canonical across nvim versions, and notifies
    /// the attached UI channel. `vim.diagnostic.set` fires `DiagnosticChanged`
    /// even when the new list is empty, which is how the GUI learns a buffer
    /// went clean.
    private static let diagnosticsHookLua = """
        if vim.g.ineovim_diagnostics_hooked then return true end
        vim.g.ineovim_diagnostics_hooked = true
        local group = vim.api.nvim_create_augroup('ineovim_diagnostics', { clear = true })
        local function payload(bufnr)
          local ok, diags = pcall(vim.diagnostic.get, bufnr)
          if not ok then diags = {} end
          local items = {}
          for _, d in ipairs(diags) do
            items[#items + 1] = {
              lnum = d.lnum, col = d.col,
              end_lnum = d.end_lnum, end_col = d.end_col,
              severity = d.severity,
              message = d.message or '',
              source = d.source,
              code = d.code and tostring(d.code) or nil,
            }
          end
          local uis = vim.api.nvim_list_uis()
          local chan = uis and uis[1] and uis[1].chan or 0
          local name = ''
          if vim.api.nvim_buf_is_valid(bufnr) then name = vim.api.nvim_buf_get_name(bufnr) end
          vim.rpcnotify(chan, 'ineovim:diagnostics', { buf = bufnr, name = name, diagnostics = items })
        end
        vim.api.nvim_create_autocmd('DiagnosticChanged', {
          group = group,
          callback = function(args) vim.schedule(function() payload(args.buf) end) end,
        })
        vim.api.nvim_create_autocmd({ 'BufUnload', 'BufWipeout' }, {
          group = group,
          callback = function(args) vim.schedule(function() payload(args.buf) end) end,
        })
        for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_is_loaded(bufnr) and #vim.diagnostic.get(bufnr) > 0 then
            payload(bufnr)
          end
        end
        return true
        """

    private func callFunction(_ name: String, args: [MsgPackValue]) async throws -> String {
        let value = try await session.call("nvim_call_function", params: [
            .string(name), .array(args),
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
