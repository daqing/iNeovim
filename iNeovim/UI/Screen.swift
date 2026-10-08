import Foundation

/// Cursor position in grid coordinates.
struct CursorState: Equatable, Sendable {
    var grid: Int
    var row: Int
    var col: Int
}

/// An immutable copy of the applied UI state for one render pass.
struct ScreenSnapshot: Equatable, Sendable {
    var grid: Grid?
    var highlights: HighlightStore
    var defaultForeground: Int?
    var defaultBackground: Int?
    var defaultSpecial: Int?
    var cursor: CursorState
    var modes: [ModeInfo]
    var modeIndex: Int

    var cursorModeInfo: ModeInfo? {
        guard modes.indices.contains(modeIndex) else { return nil }
        return modes[modeIndex]
    }
}

/// A half-open rectangle in grid cell coordinates.
struct CellRect: Equatable, Sendable {
    var minRow: Int
    var minCol: Int
    var maxRow: Int   // exclusive
    var maxCol: Int   // exclusive

    static func cell(_ row: Int, _ col: Int) -> CellRect {
        CellRect(minRow: row, minCol: col, maxRow: row + 1, maxCol: col + 1)
    }

    func union(_ other: CellRect) -> CellRect {
        CellRect(
            minRow: min(minRow, other.minRow),
            minCol: min(minCol, other.minCol),
            maxRow: max(maxRow, other.maxRow),
            maxCol: max(maxCol, other.maxCol)
        )
    }
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
    private var dirtyRects: [Int: CellRect] = [:]

    /// Called on the screen's executor once per `flush` for every grid that
    /// received events since the previous flush, with the coalesced dirty
    /// region in cell coordinates.
    var flushHandler: (@Sendable (Int, CellRect) -> Void)?

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
            let length = runs.reduce(0) { $0 + $1.count }
            guard length > 0 else { break }
            markDirty(grid, CellRect(
                minRow: row,
                minCol: colStart,
                maxRow: row + 1,
                maxCol: colStart + length
            ))
        case let .gridScroll(grid, top, bot, left, right, rows, cols):
            grids[grid]?.scroll(top: top, bot: bot, left: left, right: right, rows: rows, cols: cols)
            markDirty(grid, CellRect(minRow: top, minCol: left, maxRow: bot, maxCol: right))
        case let .gridClear(grid):
            grids[grid]?.clear()
            markGridDirty(grid)
        case let .gridResize(grid, width, height):
            grids[grid, default: Grid(id: grid)].resize(width: width, height: height)
            markGridDirty(grid)
        case let .gridDestroy(grid):
            if grid != 1 {
                grids[grid] = nil
            }
        case let .cursorGoto(grid, row, col):
            markDirty(cursor.grid, .cell(max(cursor.row, 0), max(cursor.col, 0)))
            cursor = CursorState(grid: grid, row: row, col: col)
            markDirty(grid, .cell(max(row, 0), max(col, 0)))
        case let .hlAttrDefine(id, attr):
            highlights.define(attr, for: id)
            markAllGridsDirty()
        case let .defaultColorsSet(foreground, background, special):
            defaultForeground = foreground
            defaultBackground = background
            defaultSpecial = special
            markAllGridsDirty()
        case let .modeChange(name, index):
            modeName = name
            modeIndex = index
            markDirty(cursor.grid, .cell(max(cursor.row, 0), max(cursor.col, 0)))
        case let .modeInfoSet(infos):
            modes = infos
            markDirty(cursor.grid, .cell(max(cursor.row, 0), max(cursor.col, 0)))
        case .flush:
            for (grid, rect) in dirtyRects {
                flushHandler?(grid, rect)
            }
            dirtyRects = [:]
        case let .unknown(name):
            Log.render.debug("Ignoring unknown redraw event \(name, privacy: .public)")
        }
    }

    private func markDirty(_ grid: Int, _ rect: CellRect) {
        dirtyRects[grid] = dirtyRects[grid]?.union(rect) ?? rect
    }

    private func markGridDirty(_ grid: Int) {
        guard let grid = grids[grid], grid.width > 0, grid.height > 0 else { return }
        markDirty(grid.id, CellRect(minRow: 0, minCol: 0, maxRow: grid.height, maxCol: grid.width))
    }

    private func markAllGridsDirty() {
        for id in grids.keys {
            markGridDirty(id)
        }
    }

    /// An immutable view of the applied state for the next render pass.
    func snapshot() -> ScreenSnapshot {
        ScreenSnapshot(
            grid: grids[1],
            highlights: highlights,
            defaultForeground: defaultForeground,
            defaultBackground: defaultBackground,
            defaultSpecial: defaultSpecial,
            cursor: cursor,
            modes: modes,
            modeIndex: modeIndex
        )
    }

    /// Consume the redraw event stream, applying events in arrival order.
    func startConsuming(_ events: AsyncStream<RedrawEvent>) {
        consumeTask?.cancel()
        consumeTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.apply(event)
            }
        }
    }

    func stopConsuming() {
        consumeTask?.cancel()
        consumeTask = nil
    }
}
