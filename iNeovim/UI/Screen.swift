import Foundation
import os

/// Cursor position in grid coordinates.
struct CursorState: Equatable, Sendable {
    var grid: Int
    var row: Int
    var col: Int
}

/// The ext_popupmenu completion menu state: items, the selected index
/// (-1 = none), and the grid cell the panel anchors at.
struct PopupState: Equatable, Sendable {
    var items: [PopupItem]
    var selected: Int
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
    var modeName: String?
    var popup: PopupState?

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
    private(set) var grids: [Int: Grid] = [:]
    private(set) var highlights = HighlightStore()
    private(set) var defaultForeground: Int?
    private(set) var defaultBackground: Int?
    private(set) var defaultSpecial: Int?
    private(set) var cursor = CursorState(grid: 1, row: 0, col: 0)
    private(set) var modes: [ModeInfo] = []
    private(set) var modeName: String?
    private(set) var modeIndex = 0
    private(set) var title: String?
    private(set) var popup: PopupState?
    private var consumeTask: Task<Void, Never>?
    private var dirtyRects: [Int: [CellRect]] = [:]

    /// Called on the screen's executor once per `flush` for every grid that
    /// received events since the previous flush, with the dirty regions in
    /// cell coordinates. A list (not one bounding box) so that two edits at
    /// opposite corners don't force the renderer to repaint everything between.
    private var flushHandler: (@Sendable (Int, [CellRect]) -> Void)?

    /// Called on the screen's executor once per `flush` for every grid that
    /// scrolled since the previous flush, with the net scroll amounts
    /// (same sign convention as `grid_scroll`).
    private var scrollHandler: (@Sendable (Int, Int, Int) -> Void)?
    private var scrollDeltas: [Int: (rows: Int, cols: Int)] = [:]
    private var titleHandler: (@Sendable (String) -> Void)?

    /// The primary (grid 1) content; nil before the first `grid_resize`.
    var primaryGrid: Grid? { grids[1] }

    /// Cursor presentation for the active mode, once `mode_info_set` arrived.
    var cursorModeInfo: ModeInfo? {
        guard modes.indices.contains(modeIndex) else { return nil }
        return modes[modeIndex]
    }

    func setFlushHandler(_ handler: (@Sendable (Int, [CellRect]) -> Void)?) {
        flushHandler = handler
    }

    func setScrollHandler(_ handler: (@Sendable (Int, Int, Int) -> Void)?) {
        scrollHandler = handler
    }

    /// Called when Neovim reports a new window title via `set_title`.
    func setTitleHandler(_ handler: (@Sendable (String) -> Void)?) {
        titleHandler = handler
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
            if rows != 0 || cols != 0 {
                var delta = scrollDeltas[grid] ?? (rows: 0, cols: 0)
                delta.rows += rows
                delta.cols += cols
                scrollDeltas[grid] = delta
            }
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
            markCursorDirty(cursor.grid, cursor.row, cursor.col)
            cursor = CursorState(grid: grid, row: row, col: col)
            markCursorDirty(grid, row, col)
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
            markCursorDirty(cursor.grid, cursor.row, cursor.col)
        case let .modeInfoSet(infos):
            modes = infos
            markCursorDirty(cursor.grid, cursor.row, cursor.col)
        case let .setTitle(title):
            self.title = title
            titleHandler?(title)
        case let .popupmenuShow(items, selected, row, col, grid):
            guard grid == 1 else { break }
            popup = PopupState(items: items, selected: selected, row: row, col: col)
        case let .popupmenuSelect(selected):
            popup?.selected = selected
        case .popupmenuHide:
            popup = nil
        case .flush:
            for (grid, rects) in dirtyRects {
                flushHandler?(grid, rects)
            }
            dirtyRects = [:]
            for (grid, delta) in scrollDeltas {
                scrollHandler?(grid, delta.rows, delta.cols)
            }
            scrollDeltas = [:]
        case let .unknown(name):
            Log.render.debug("Ignoring unknown redraw event \(name, privacy: .public)")
        }
    }

    /// The cursor cell plus the continuation cell when it sits on a
    /// double-width char (an empty-text cell in the grid), so a two-cell
    /// block cursor fully repaints when it moves away or changes shape.
    private func markCursorDirty(_ grid: Int, _ row: Int, _ col: Int) {
        guard let g = grids[grid], row >= 0, row < g.height, col >= 0, col < g.width else {
            markDirty(grid, .cell(max(row, 0), max(col, 0)))
            return
        }
        var rect = CellRect.cell(row, col)
        if col + 1 < g.width, g[row, col + 1].text.isEmpty {
            rect = rect.union(.cell(row, col + 1))
        }
        markDirty(grid, rect)
    }

    /// Add a dirty region, merging it into any existing region it touches or
    /// overlaps so the list stays small while distinct regions stay separate.
    private func markDirty(_ grid: Int, _ rect: CellRect) {
        var list = dirtyRects[grid] ?? []
        var merged = rect
        var didMerge = true
        while didMerge {
            didMerge = false
            var rest: [CellRect] = []
            rest.reserveCapacity(list.count)
            for existing in list {
                if Self.touches(merged, existing) {
                    merged = merged.union(existing)
                    didMerge = true
                } else {
                    rest.append(existing)
                }
            }
            list = rest
        }
        list.append(merged)
        dirtyRects[grid] = list
    }

    /// Two cell rects merge when they overlap or share an edge.
    private static func touches(_ a: CellRect, _ b: CellRect) -> Bool {
        a.minRow <= b.maxRow && b.minRow <= a.maxRow
            && a.minCol <= b.maxCol && b.minCol <= a.maxCol
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
            modeIndex: modeIndex,
            modeName: modeName,
            popup: popup
        )
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

    /// Clear applied state so a restarted nvim starts from a blank screen.
    func resetState() {
        consumeTask?.cancel()
        consumeTask = nil
        grids = [:]
        highlights = HighlightStore()
        defaultForeground = nil
        defaultBackground = nil
        defaultSpecial = nil
        cursor = CursorState(grid: 1, row: 0, col: 0)
        modes = []
        modeName = nil
        modeIndex = 0
        title = nil
        popup = nil
        dirtyRects = [:]
        scrollDeltas = [:]
    }
}
