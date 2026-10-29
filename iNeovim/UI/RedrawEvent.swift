import Foundation

/// A run of identical cells from a `grid_line` event: cell text, highlight id,
/// and the number of consecutive cells it occupies.
nonisolated struct GridCellRun: Equatable, Sendable {
    var text: String
    var attrId: Int
    var count: Int
}

/// One completion entry from a `popupmenu_show` event (ext_popupmenu). The
/// kind is a string in current nvim ("Function", "Variable", …) but older
/// revisions sent the protocol's legacy integer codes, so both parse.
nonisolated struct PopupItem: Equatable, Sendable {
    var word: String
    var kind: String
    var menu: String
    var info: String

    init(word: String = "", kind: String = "", menu: String = "", info: String = "") {
        self.word = word
        self.kind = kind
        self.menu = menu
        self.info = info
    }

    init?(rawValue raw: MsgPackValue) {
        guard case let .array(fields) = raw, case .string(let word)? = fields.first else {
            return nil
        }
        self.init(
            word: word,
            kind: Self.kindString(fields.count > 1 ? fields[1] : .nil),
            menu: fields.count > 2 ? fields[2].stringValue ?? "" : "",
            info: fields.count > 3 ? fields[3].stringValue ?? "" : ""
        )
    }

    private static func kindString(_ raw: MsgPackValue) -> String {
        if let text = raw.stringValue { return text }
        if let code = raw.intValue { return String(code) }
        return ""
    }
}

/// Per-mode cursor presentation from a `mode_info_set` event.
nonisolated struct ModeInfo: Equatable, Sendable {
    enum CursorShape: String, Equatable, Sendable {
        case block
        case horizontal
        case vertical
    }

    var name: String?
    var cursorShape: CursorShape?
    var cellPercentage: Int?
    var blinkWait: Int?
    var blinkOn: Int?
    var blinkOff: Int?
}

/// Where a floating window anchors: the anchor grid plus a fractional
/// row/col within it and the corner of the float the anchor points at
/// (`nvim_open_win` semantics). Kept as a struct — tuples do not conform to
/// `Equatable`, which the snapshot comparisons need.
nonisolated struct FloatAnchor: Equatable, Sendable {
    var grid: Int
    var row: Double
    var col: Double
    var corner: String
}

/// The multigrid layout of one window: its position in the global grid and
/// whether it is currently displayed. Floating windows and the message grid
/// carry z-ordering and the nvim-computed absolute position.
nonisolated struct GridFrame: Equatable, Sendable {
    var row: Int
    var col: Int
    var hidden: Bool = false
    var isFloat: Bool = false
    var isMessage: Bool = false
    var mouseEnabled: Bool = true
    var zindex: Int = 0
    var compindex: Int = 0

    /// Fallback positioning for floats whose event carries no absolute
    /// position: anchor within `anchorGrid` per `nvim_open_win` semantics.
    var anchor: FloatAnchor?

    /// `win_viewport`: the buffer-text range the window displays (nil until
    /// the grid's first event). Drives the scroll indicator without a Lua
    /// round-trip.
    var viewport: GridViewport?
}

/// The buffer-text range a window displays, from `win_viewport`. All
/// positions are zero-based; `botline` may exceed the line count when filler
/// lines (`~`) are shown.
nonisolated struct GridViewport: Equatable, Sendable {
    var topline: Int
    var botline: Int
    var curline: Int
    var curcol: Int
    var lineCount: Int
    var scrollDelta: Int
}

/// A Neovim UI redraw event (linegrid protocol, `ext_multigrid` on).
nonisolated enum RedrawEvent: Equatable, Sendable {
    case gridLine(grid: Int, row: Int, colStart: Int, runs: [GridCellRun])
    case gridScroll(grid: Int, top: Int, bot: Int, left: Int, right: Int, rows: Int, cols: Int)
    case gridClear(grid: Int)
    case gridResize(grid: Int, width: Int, height: Int)
    case gridDestroy(grid: Int)
    case cursorGoto(grid: Int, row: Int, col: Int)
    case hlAttrDefine(id: Int, attr: HlAttr)
    case defaultColorsSet(foreground: Int?, background: Int?, special: Int?)
    case modeChange(name: String, index: Int)
    case modeInfoSet([ModeInfo])
    case setTitle(String)
    case popupmenuShow(items: [PopupItem], selected: Int, row: Int, col: Int, grid: Int)
    case popupmenuSelect(Int)
    case popupmenuHide
    /// `win_pos`: a (possibly previously hidden) window grid at a global
    /// position. Nvim sizes the grid itself before this via `grid_resize`.
    case winPos(grid: Int, row: Int, col: Int, width: Int, height: Int)
    /// `win_float_pos`: a floating window. Positioning prefers the trailing
    /// absolute `screenRow`/`screenCol`; the anchor fields are the fallback.
    case winFloatPos(
        grid: Int, anchorGrid: Int, anchorRow: Double, anchorCol: Double,
        corner: String, mouseEnabled: Bool, zindex: Int, compindex: Int,
        screenRow: Double?, screenCol: Double?
    )
    /// `win_external_pos`: a window displayed outside this surface. The app
    /// has no desktop-window representation, so the grid is hidden.
    case winExternalPos(grid: Int)
    case winHide(grid: Int)
    case winClose(grid: Int)
    /// `msg_set_pos`: show the message grid at a global row (grid 0 hides it).
    case msgSetPos(grid: Int, row: Int, scrolled: Bool, zindex: Int, compindex: Int)
    /// `win_viewport`: the buffer-text range the window displays and how far
    /// it scrolled since the previous event (smooth-scroll confirmations).
    case winViewport(
        grid: Int, topline: Int, botline: Int, curline: Int, curcol: Int,
        lineCount: Int, scrollDelta: Int
    )
    /// `win_viewport_margins`: rows/columns of the grid that are not part of
    /// the viewport (winbar, float borders). Parsed and currently unused.
    case winViewportMargins(grid: Int, top: Int, bottom: Int, left: Int, right: Int)
    /// `grid_mouse_enabled`: `setmouse()` flipping a grid's mouse support.
    case gridMouseEnabled(grid: Int, enabled: Bool)
    case flush
    case unknown(name: String)
}

nonisolated extension RedrawEvent {
    /// Parse the params of a `redraw` notification. Nvim sends a single
    /// argument: a batch of events, each `[name, tuple, tuple, ...]`, where
    /// every parameter tuple is one logical instance of the event. Repeatable
    /// events (`grid_line`, `hl_attr_define`) therefore fan out into several
    /// typed events. Malformed entries are skipped rather than failing the
    /// whole batch.
    ///
    /// Wire shapes: pre-0.10 nvim sends one argument holding the whole batch
    /// (an array of event arrays); 0.10+ sends each event array as its own
    /// argument — including a single-argument flush where one big event
    /// (e.g. a full-screen `grid_line`) is sent alone with a string head.
    static func parseNotification(_ params: [MsgPackValue]) -> [RedrawEvent] {
        let rawEvents: [MsgPackValue]
        if params.count == 1, case let .array(events) = params[0], case .array? = events.first {
            rawEvents = events
        } else {
            rawEvents = params
        }
        return rawEvents.flatMap(parseEvent(_:))
    }

    private static func parseEvent(_ raw: MsgPackValue) -> [RedrawEvent] {
        guard case let .array(elements) = raw, !elements.isEmpty,
              case let .string(eventName) = elements[0] else {
            return []
        }
        let tuples = elements.dropFirst()
        switch eventName {
        case "grid_line":
            return tuples.compactMap { tuple in
                guard case let .array(args) = tuple else { return nil }
                return parseGridLine(args)
            }
        case "hl_attr_define":
            return tuples.compactMap { tuple in
                guard case let .array(args) = tuple, args.count >= 2,
                      let id = args[0].intValue,
                      case let .map(map) = args[1] else { return nil }
                return .hlAttrDefine(id: id, attr: HlAttr(rawMap: map))
            }
        case "grid_scroll":
            guard let args = firstTuple(tuples), args.count == 7,
                  let grid = args[0].intValue,
                  let top = args[1].intValue,
                  let bot = args[2].intValue,
                  let left = args[3].intValue,
                  let right = args[4].intValue,
                  let rows = args[5].intValue,
                  let cols = args[6].intValue else { return [] }
            return [.gridScroll(grid: grid, top: top, bot: bot, left: left, right: right, rows: rows, cols: cols)]
        case "grid_clear":
            guard let args = firstTuple(tuples), let grid = args.first?.intValue else { return [] }
            return [.gridClear(grid: grid)]
        case "grid_resize":
            guard let args = firstTuple(tuples), args.count == 3,
                  let grid = args[0].intValue,
                  let width = args[1].intValue,
                  let height = args[2].intValue else { return [] }
            return [.gridResize(grid: grid, width: width, height: height)]
        case "grid_destroy":
            guard let args = firstTuple(tuples), let grid = args.first?.intValue else { return [] }
            return [.gridDestroy(grid: grid)]
        case "grid_cursor_goto":
            guard let args = firstTuple(tuples), args.count == 3,
                  let grid = args[0].intValue,
                  let row = args[1].intValue,
                  let col = args[2].intValue else { return [] }
            return [.cursorGoto(grid: grid, row: row, col: col)]
        case "cursor_goto":
            guard let args = firstTuple(tuples), args.count == 2,
                  let row = args[0].intValue,
                  let col = args[1].intValue else { return [] }
            return [.cursorGoto(grid: 1, row: row, col: col)]
        case "default_colors_set":
            guard let args = firstTuple(tuples), args.count >= 3 else { return [] }
            return [.defaultColorsSet(
                foreground: colorValue(args[0]),
                background: colorValue(args[1]),
                special: colorValue(args[2])
            )]
        case "mode_change":
            guard let args = firstTuple(tuples), args.count == 2,
                  case let .string(name) = args[0],
                  let index = args[1].intValue else { return [] }
            return [.modeChange(name: name, index: index)]
        case "mode_info_set":
            guard let args = firstTuple(tuples), args.count >= 2,
                  case let .array(rawModes) = args[1] else { return [] }
            return [.modeInfoSet(rawModes.compactMap(ModeInfo.init(rawValue:)))]
        case "set_title":
            guard let args = firstTuple(tuples), case let .string(title)? = args.first else { return [] }
            return [.setTitle(title)]
        case "popupmenu_show":
            guard let args = firstTuple(tuples), args.count >= 4,
                  case let .array(rawItems) = args[0],
                  let selected = args[1].intValue,
                  let row = args[2].intValue,
                  let col = args[3].intValue else { return [] }
            return [.popupmenuShow(
                items: rawItems.compactMap(PopupItem.init(rawValue:)),
                selected: selected,
                row: row,
                col: col,
                grid: args.count > 4 ? args[4].intValue ?? 1 : 1
            )]
        case "popupmenu_select":
            guard let args = firstTuple(tuples), let selected = args.first?.intValue else { return [] }
            return [.popupmenuSelect(selected)]
        case "popupmenu_hide":
            return [.popupmenuHide]
        case "win_pos":
            guard let args = firstTuple(tuples), args.count >= 6,
                  let grid = args[0].intValue,
                  let row = args[2].intValue,
                  let col = args[3].intValue,
                  let width = args[4].intValue,
                  let height = args[5].intValue else { return [] }
            return [.winPos(grid: grid, row: row, col: col, width: width, height: height)]
        case "win_float_pos":
            guard let args = firstTuple(tuples), args.count >= 9,
                  let grid = args[0].intValue,
                  case let .string(corner) = args[2],
                  let anchorGrid = args[3].intValue,
                  let zindex = args[7].intValue else { return [] }
            // The trailing absolute position is optional (older nvim).
            let screenRow = args.count > 9 ? args[9].doubleValue : nil
            let screenCol = args.count > 10 ? args[10].doubleValue : nil
            return [.winFloatPos(
                grid: grid,
                anchorGrid: anchorGrid,
                anchorRow: args[4].doubleValue ?? 0,
                anchorCol: args[5].doubleValue ?? 0,
                corner: corner,
                mouseEnabled: args[6].boolValue ?? true,
                zindex: zindex,
                compindex: args.count > 8 ? args[8].intValue ?? 0 : 0,
                screenRow: screenRow,
                screenCol: screenCol
            )]
        case "win_external_pos":
            guard let args = firstTuple(tuples), let grid = args.first?.intValue else { return [] }
            return [.winExternalPos(grid: grid)]
        case "win_hide":
            guard let args = firstTuple(tuples), let grid = args.first?.intValue else { return [] }
            return [.winHide(grid: grid)]
        case "win_close":
            guard let args = firstTuple(tuples), let grid = args.first?.intValue else { return [] }
            return [.winClose(grid: grid)]
        case "msg_set_pos":
            guard let args = firstTuple(tuples), args.count >= 4,
                  let grid = args[0].intValue,
                  let row = args[1].intValue,
                  let scrolled = args[2].boolValue else { return [] }
            return [.msgSetPos(
                grid: grid,
                row: row,
                scrolled: scrolled,
                zindex: args.count > 4 ? args[4].intValue ?? 0 : 0,
                compindex: args.count > 5 ? args[5].intValue ?? 0 : 0
            )]
        case "win_viewport":
            guard let args = firstTuple(tuples), args.count >= 8,
                  let grid = args[0].intValue,
                  let topline = args[2].intValue,
                  let botline = args[3].intValue,
                  let curline = args[4].intValue,
                  let curcol = args[5].intValue,
                  let lineCount = args[6].intValue,
                  let scrollDelta = args[7].intValue else { return [] }
            return [.winViewport(
                grid: grid, topline: topline, botline: botline, curline: curline,
                curcol: curcol, lineCount: lineCount, scrollDelta: scrollDelta
            )]
        case "win_viewport_margins":
            guard let args = firstTuple(tuples), args.count >= 6,
                  let grid = args[0].intValue,
                  let top = args[2].intValue,
                  let bottom = args[3].intValue,
                  let left = args[4].intValue,
                  let right = args[5].intValue else { return [] }
            return [.winViewportMargins(grid: grid, top: top, bottom: bottom, left: left, right: right)]
        case "grid_mouse_enabled":
            guard let args = firstTuple(tuples), args.count >= 2,
                  let grid = args[0].intValue,
                  let enabled = args[1].boolValue else { return [] }
            return [.gridMouseEnabled(grid: grid, enabled: enabled)]
        case "flush":
            return [.flush]
        default:
            return [.unknown(name: eventName)]
        }
    }

    /// The single parameter tuple of a non-repeatable event.
    private static func firstTuple(_ tuples: ArraySlice<MsgPackValue>) -> [MsgPackValue]? {
        guard let first = tuples.first, case let .array(args) = first else { return nil }
        return args
    }

    private static func parseGridLine(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count >= 4,
              let grid = args[0].intValue,
              let row = args[1].intValue,
              let colStart = args[2].intValue,
              case let .array(rawCells) = args[3] else {
            return nil
        }
        var runs: [GridCellRun] = []
        var lastAttrId = 0
        for rawCell in rawCells {
            guard case let .array(cell) = rawCell, !cell.isEmpty,
                  case let .string(text) = cell[0] else {
                return nil
            }
            // Omitted hl_id reuses the previous cell's; omitted repeat means 1.
            // A repeat of 0 marks "the previous chunk was not a clearing
            // chunk" when nvim splits one row across grid_line events — it
            // covers no cells and must not overwrite anything.
            let attrId = cell.count > 1 ? (cell[1].intValue ?? lastAttrId) : lastAttrId
            let count = cell.count > 2 ? (cell[2].intValue ?? 1) : 1
            lastAttrId = attrId
            runs.append(GridCellRun(text: text, attrId: attrId, count: max(count, 0)))
        }
        return .gridLine(grid: grid, row: row, colStart: colStart, runs: runs)
    }

    /// A color of -1 from nvim means "not set".
    private static func colorValue(_ raw: MsgPackValue) -> Int? {
        guard let value = raw.intValue, value >= 0 else { return nil }
        return value
    }
}

nonisolated extension ModeInfo {
    init?(rawValue: MsgPackValue) {
        guard case let .map(map) = rawValue else { return nil }
        self.init(
            name: map[.string("name")]?.stringValue,
            cursorShape: map[.string("cursor_shape")]?.stringValue.flatMap(CursorShape.init(rawValue:)),
            cellPercentage: map[.string("cell_percentage")]?.intValue,
            blinkWait: map[.string("blinkwait")]?.intValue,
            blinkOn: map[.string("blinkon")]?.intValue,
            blinkOff: map[.string("blinkoff")]?.intValue
        )
    }
}
