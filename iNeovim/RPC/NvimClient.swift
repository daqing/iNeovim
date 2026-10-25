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

/// Viewport metrics for the window under the pointer, used to place the
/// transient scroll indicator's thumb.
nonisolated struct ScrollMetrics: Equatable {
    /// First buffer line on screen, 1-based (`getwininfo().topline`).
    var topline: Int
    var lineCount: Int
    /// Buffer lines the window shows; a wrapped line counts once.
    var visibleLines: Int

    var isScrollable: Bool { lineCount > visibleLines }

    /// Visible share of the buffer, clamped to 0…1.
    var proportion: CGFloat {
        guard lineCount > 0 else { return 0 }
        return min(max(CGFloat(visibleLines) / CGFloat(lineCount), 0), 1)
    }

    /// Where the visible part sits over the scrollable range, 0 (top of the
    /// buffer) … 1 (bottom).
    var position: CGFloat {
        let span = max(1, lineCount - visibleLines)
        return min(max(CGFloat(topline - 1) / CGFloat(span), 0), 1)
    }
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

    /// Soft-wrap long lines, in every window and as the default for windows
    /// created later. `bootstrap` can reach nvim while `init.lua` is still
    /// being sourced (a fresh `nvim --embed` answers RPC before `VimEnter`),
    /// so a user config's `set nowrap` runs *after* a plain `set wrap` and
    /// wins; while startup is still in flight, apply again on `VimEnter`.
    func installWrap() async throws {
        _ = try await execLua(Self.installWrapLua, args: [])
    }

    private static let installWrapLua = """
        local function apply()
          vim.o.wrap = true
          for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
            for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
              vim.wo[win].wrap = true
            end
          end
        end
        apply()
        if vim.v.vim_did_enter == 0 then
          vim.api.nvim_create_autocmd('VimEnter', { once = true, callback = apply })
        end
        return true
        """

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
    /// `vim.diagnostic` entries. A wrapped line covers several screen rows,
    /// so the line is found from `screenpos` rather than by adding the row
    /// offset to `topline`; a row past the text (the `~` filler) belongs to
    /// no line. Guarded by pcall so nvim versions without the module still
    /// return an empty list and the click falls through.
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
        local screen_row = row + 1
        local last = target.info.botline
          or vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(target.win))
        local lnum = nil
        local start_row = 0
        for line = target.info.topline, last do
          local start = vim.fn.screenpos(target.win, line, 1)
          if start.row == 0 or start.row > screen_row then break end
          lnum = line
          start_row = start.row
        end
        if lnum then
          local length = vim.fn.col({ lnum, '$' }) - 1
          local end_row = start_row
          if length > 0 then
            local ending = vim.fn.screenpos(target.win, lnum, length)
            if ending.row ~= 0 then
              end_row = ending.row
            else
              -- The line is taller than the window, so its tail is
              -- off-screen; the clicked row is still inside it.
              end_row = math.huge
            end
          end
          if screen_row > end_row then lnum = nil end
        end
        if not lnum then return { items = {} } end
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

    /// The viewport metrics of the window covering a grid cell, for the
    /// scroll indicator: which buffer line is at the top, how long the buffer
    /// is, and how many buffer lines the window shows. A single linegrid
    /// carries no buffer position of its own (`win_viewport` needs
    /// `ext_multigrid`), so this asks nvim; nil when there is no window.
    func windowScrollMetrics(row: Int, col: Int) async throws -> ScrollMetrics? {
        let value = try await execLua(Self.scrollMetricsLua, args: [
            .int(Int64(row)), .int(Int64(col)),
        ])
        return Self.parseScrollMetrics(value)
    }

    static func parseScrollMetrics(_ value: MsgPackValue) -> ScrollMetrics? {
        guard case let .map(fields) = value,
              let topline = fields[.string("topline")]?.intValue,
              let lineCount = fields[.string("linecount")]?.intValue,
              let visible = fields[.string("visible")]?.intValue,
              visible > 0 else { return nil }
        return ScrollMetrics(topline: topline, lineCount: lineCount, visibleLines: visible)
    }

    /// Find the window covering the pointer's cell (`getwininfo` reports
    /// window rects in the same global grid coordinates `nvim_input_mouse`
    /// uses); a pointer over the statusline or cmdline row falls back to the
    /// current window, which is the one Neovim scrolls there anyway.
    private static let scrollMetricsLua = """
        local row, col = ...
        local function metrics(w)
          local info = vim.fn.getwininfo(w)[1]
          if not info then return nil end
          return {
            topline = info.topline,
            linecount = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(w)),
            -- Buffer lines, not screen rows: a wrapped line can cover
            -- several rows, and the thumb measures the buffer.
            visible = info.botline - info.topline + 1,
          }
        end
        for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          local info = vim.fn.getwininfo(w)[1]
          if info
            and row + 1 >= info.winrow and row + 1 < info.winrow + info.height
            and col + 1 >= info.wincol and col + 1 < info.wincol + info.width then
            return metrics(w)
          end
        end
        local win = vim.api.nvim_get_current_win()
        if not vim.api.nvim_win_is_valid(win) then return nil end
        return metrics(win)
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

    /// Watch the text areas of the current tabpage's windows and report them
    /// as `NvimTextLayout.rpcMethod` notifications, so the renderer can draw
    /// buffer text clear of the gutter. A window's `textoff` changes with
    /// options (`number`, `signcolumn`, …) and with signs a language server
    /// or plugin places, which fire no autocmd, so the hook re-checks on each
    /// redraw — the decoration provider's first callback — and notifies only
    /// when the layout actually changed. Idempotent per nvim instance.
    func installTextLayoutHook() async throws -> Bool {
        let value = try await execLua(Self.textLayoutHookLua, args: [])
        return value.boolValue ?? false
    }

    /// The decoration provider only schedules work: the docs allow `vim.rpcnotify`
    /// in a redraw callback but call anything else experimental, so the scan
    /// runs from a scheduled function. Redraws can arrive every frame while
    /// scrolling, so a pending scan collapses them and runs at most every
    /// 100 ms; the layout is compared with the last one pushed and an
    /// unchanged one sends nothing.
    private static let textLayoutHookLua = """
        if vim.g.ineovim_textlayout_hooked then return true end
        vim.g.ineovim_textlayout_hooked = true
        local ns = vim.api.nvim_create_namespace('ineovim_textlayout')
        local last = nil
        local pending = false
        local function collect()
          local wins = {}
          for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            if vim.api.nvim_win_is_valid(win)
              and vim.api.nvim_win_get_config(win).relative == '' then
              local info = vim.fn.getwininfo(win)[1]
              if info and info.textoff > 0 and info.width > info.textoff then
                wins[#wins + 1] = {
                  row = info.winrow - 1,
                  col = info.wincol - 1 + info.textoff,
                  height = info.height,
                  width = info.width - info.textoff,
                }
              end
            end
          end
          return wins
        end
        local function push()
          local wins = collect()
          local parts = {}
          for _, w in ipairs(wins) do
            parts[#parts + 1] = w.row .. ',' .. w.col .. ',' .. w.height .. ',' .. w.width
          end
          local key = table.concat(parts, ';')
          if key == last then return end
          local uis = vim.api.nvim_list_uis()
          local chan = uis and uis[1] and uis[1].chan or 0
          if chan == 0 then return end
          last = key
          vim.rpcnotify(chan, 'ineovim:textlayout', wins)
        end
        local function schedule_push()
          if pending then return end
          pending = true
          vim.schedule(function()
            vim.defer_fn(function()
              pending = false
              push()
            end, 100)
          end)
        end
        vim.api.nvim_set_decoration_provider(ns, { on_start = schedule_push })
        vim.schedule(push)
        return true
        """

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
