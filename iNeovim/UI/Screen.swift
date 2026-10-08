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

    /// Called on the screen's executor after each `flush` batch has been
    /// applied; the render layer refreshes its snapshot from this.
    var flushHandler: (@Sendable () -> Void)?

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
            flushHandler?()
        case let .unknown(name):
            Log.render.debug("Ignoring unknown redraw event \(name, privacy: .public)")
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
