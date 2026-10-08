import Foundation

/// A run of identical cells from a `grid_line` event: cell text, highlight id,
/// and the number of consecutive cells it occupies.
struct GridCellRun: Equatable, Sendable {
    var text: String
    var attrId: Int
    var count: Int
}

/// Per-mode cursor presentation from a `mode_info_set` event.
struct ModeInfo: Equatable, Sendable {
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
enum RedrawEvent: Equatable, Sendable {
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
    case flush
    case unknown(name: String)
}

extension RedrawEvent {
    /// Parse the params of a `redraw` notification; nvim batches the individual
    /// events as `[[name, args...], ...]` in a single param. Malformed entries
    /// are skipped rather than failing the whole batch.
    static func parseNotification(_ params: [MsgPackValue]) -> [RedrawEvent] {
        let rawEvents: [MsgPackValue]
        if params.count == 1, case let .array(events) = params[0] {
            rawEvents = events
        } else {
            rawEvents = params
        }
        return rawEvents.compactMap(parseEvent(_:))
    }

    private static func parseEvent(_ raw: MsgPackValue) -> RedrawEvent? {
        guard case let .array(elements) = raw, !elements.isEmpty,
              case let .string(eventName) = elements[0] else {
            return nil
        }
        let args = Array(elements.dropFirst())
        switch eventName {
        case "grid_line":
            return parseGridLine(args)
        case "grid_scroll":
            return parseGridScroll(args)
        case "grid_clear":
            guard args.count == 1, let grid = args[0].intValue else { return nil }
            return .gridClear(grid: grid)
        case "grid_resize":
            guard args.count == 3,
                  let grid = args[0].intValue,
                  let width = args[1].intValue,
                  let height = args[2].intValue else { return nil }
            return .gridResize(grid: grid, width: width, height: height)
        case "grid_destroy":
            guard args.count == 1, let grid = args[0].intValue else { return nil }
            return .gridDestroy(grid: grid)
        case "grid_cursor_goto":
            guard args.count == 3,
                  let grid = args[0].intValue,
                  let row = args[1].intValue,
                  let col = args[2].intValue else { return nil }
            return .cursorGoto(grid: grid, row: row, col: col)
        case "cursor_goto":
            guard args.count == 2,
                  let row = args[0].intValue,
                  let col = args[1].intValue else { return nil }
            return .cursorGoto(grid: 1, row: row, col: col)
        case "hl_attr_define":
            guard args.count >= 2,
                  let id = args[0].intValue,
                  case let .map(map) = args[1] else { return nil }
            return .hlAttrDefine(id: id, attr: HlAttr(rawMap: map))
        case "default_colors_set":
            guard args.count >= 3 else { return nil }
            return .defaultColorsSet(
                foreground: colorValue(args[0]),
                background: colorValue(args[1]),
                special: colorValue(args[2])
            )
        case "mode_change":
            guard args.count == 2,
                  case let .string(modeName) = args[0],
                  let index = args[1].intValue else { return nil }
            return .modeChange(name: modeName, index: index)
        case "mode_info_set":
            guard args.count >= 2, case let .array(rawModes) = args[1] else { return nil }
            return .modeInfoSet(rawModes.compactMap(ModeInfo.init(rawValue:)))
        case "flush":
            return .flush
        default:
            return .unknown(name: eventName)
        }
    }

    private static func parseGridLine(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count == 4,
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
            let attrId = cell.count > 1 ? (cell[1].intValue ?? lastAttrId) : lastAttrId
            let count = cell.count > 2 ? (cell[2].intValue ?? 1) : 1
            lastAttrId = attrId
            runs.append(GridCellRun(text: text, attrId: attrId, count: max(count, 1)))
        }
        return .gridLine(grid: grid, row: row, colStart: colStart, runs: runs)
    }

    private static func parseGridScroll(_ args: [MsgPackValue]) -> RedrawEvent? {
        guard args.count == 7,
              let grid = args[0].intValue,
              let top = args[1].intValue,
              let bot = args[2].intValue,
              let left = args[3].intValue,
              let right = args[4].intValue,
              let rows = args[5].intValue,
              let cols = args[6].intValue else {
            return nil
        }
        return .gridScroll(grid: grid, top: top, bot: bot, left: left, right: right, rows: rows, cols: cols)
    }

    /// A color of -1 from nvim means "not set".
    private static func colorValue(_ raw: MsgPackValue) -> Int? {
        guard let value = raw.intValue, value >= 0 else { return nil }
        return value
    }
}

extension ModeInfo {
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
