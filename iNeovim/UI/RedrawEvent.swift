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

/// A Neovim UI redraw event (linegrid protocol, `ext_multigrid` off).
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
