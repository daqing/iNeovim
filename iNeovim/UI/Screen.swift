import Foundation

/// Cursor position in grid coordinates.
struct CursorState: Equatable, Sendable {
    var grid: Int
    var row: Int
    var col: Int
}

/// Applied UI state — grids, highlights, default colors, mode and cursor —
/// updated from the redraw event stream. The render layer reads snapshots
/// from here instead of touching raw msgpack or events.
actor Screen {
    static let shared = Screen()

    private(set) var grids: [Int: Grid] = [:]
    private(set) var highlights = HighlightStore()
    private(set) var defaultForeground: Int?
    private(set) var defaultBackground: Int?
    private(set) var defaultSpecial: Int?
    private(set) var cursor = CursorState(grid: 1, row: 0, col: 0)
    private(set) var modes: [ModeInfo] = []
    private(set) var modeName: String?
    private(set) var modeIndex = 0
    private var consumeTask: Task<Void, Never>?

    /// The primary (grid 1) content; nil before the first `grid_resize`.
    var primaryGrid: Grid? { grids[1] }

    /// Cursor presentation for the active mode, once `mode_info_set` arrived.
    var cursorModeInfo: ModeInfo? {
        guard modes.indices.contains(modeIndex) else { return nil }
        return modes[modeIndex]
    }

    func apply(_ event: RedrawEvent) {
        switch event {
        case let .gridLine(grid, row, colStart, runs):
            grids[grid, default: Grid(id: grid)].applyLine(row: row, colStart: colStart, runs: runs)
        case let .gridScroll(grid, top, bot, left, right, rows, cols):
            grids[grid]?.scroll(top: top, bot: bot, left: left, right: right, rows: rows, cols: cols)
        case let .gridClear(grid):
            grids[grid]?.clear()
        case let .gridResize(grid, width, height):
            grids[grid, default: Grid(id: grid)].resize(width: width, height: height)
        case let .gridDestroy(grid):
            if grid != 1 {
                grids[grid] = nil
            }
        case let .cursorGoto(grid, row, col):
            cursor = CursorState(grid: grid, row: row, col: col)
        case let .hlAttrDefine(id, attr):
            highlights.define(attr, for: id)
        case let .defaultColorsSet(foreground, background, special):
            defaultForeground = foreground
            defaultBackground = background
            defaultSpecial = special
        case let .modeChange(name, index):
            modeName = name
            modeIndex = index
        case let .modeInfoSet(infos):
            modes = infos
        case .flush:
            break
        case let .unknown(name):
            Log.render.debug("Ignoring unknown redraw event \(name, privacy: .public)")
        }
    }

    /// Consume the redraw event stream, applying events in arrival order.
    func startConsuming(_ events: AsyncStream<RedrawEvent>) {
        consumeTask?.cancel()
        consumeTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.apply(event)
            }
        }
    }

    func stopConsuming() {
        consumeTask?.cancel()
        consumeTask = nil
    }
}
