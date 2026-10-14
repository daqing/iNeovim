import AppKit
import XCTest
@testable import iNeovim

/// The grid is split into a scrolling region and a frozen footer (the
/// statusline row and the cmdline row below it). nvim never scrolls those
/// rows, and only the scrolling region takes the scroll lead, so the
/// statusline text cannot slide off its bar mid-gesture.
@MainActor
final class FrozenFooterTests: XCTestCase {
    private let metrics = FontMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))

    func testRowSliceRanges() {
        XCTAssertEqual(GridRowSlice.all.range(gridHeight: 10), 0..<10)
        XCTAssertEqual(GridRowSlice.head(excludingTrailing: 2).range(gridHeight: 10), 0..<8)
        XCTAssertEqual(GridRowSlice.tail(count: 2).range(gridHeight: 10), 8..<10)

        // A grid too short to hold both regions never hands a row to two
        // layers: the scrolling region just becomes empty.
        XCTAssertEqual(GridRowSlice.head(excludingTrailing: 2).range(gridHeight: 1), 0..<0)
        XCTAssertEqual(GridRowSlice.tail(count: 2).range(gridHeight: 1), 0..<1)
        XCTAssertEqual(GridRowSlice.head(excludingTrailing: 2).range(gridHeight: 0), 0..<0)
        XCTAssertEqual(GridRowSlice.tail(count: 2).range(gridHeight: 0), 0..<0)
    }

    func testSlicesTileTheGrid() {
        let snapshot = snapshot(height: 6)
        let cellHeight = metrics.cellSize.height

        let head = GridContentLayer(metrics: metrics)
        head.rowSlice = .head(excludingTrailing: 2)
        head.update(snapshot: snapshot)
        XCTAssertEqual(head.sliceOriginY, 0, accuracy: 0.001)
        XCTAssertEqual(head.bounds.height, 4 * cellHeight, accuracy: 0.001)

        let footer = GridContentLayer(metrics: metrics)
        footer.rowSlice = .tail(count: 2)
        footer.update(snapshot: snapshot)
        XCTAssertEqual(footer.sliceOriginY, 4 * cellHeight, accuracy: 0.001)
        // The footer's bounds carry the cmdline gap between its two rows.
        XCTAssertEqual(
            footer.bounds.height,
            2 * cellHeight + TerminalView.cmdlineGap,
            accuracy: 0.001
        )

        // Together the two layers cover the whole grid: the scrolling region
        // ends where the footer begins, and the footer ends on the last row's
        // bottom edge.
        XCTAssertEqual(head.bounds.height, footer.sliceOriginY, accuracy: 0.001)
        XCTAssertEqual(
            footer.sliceOriginY + footer.bounds.height,
            TerminalView.gridRowY(5, gridHeight: 6, cellHeight: cellHeight) + cellHeight,
            accuracy: 0.001
        )
    }

    func testCursorInTheCmdlineRowIsDrawnByTheFooter() throws {
        let snapshot = snapshot(height: 6, cursorRow: 5)
        let head = GridContentLayer(metrics: metrics)
        head.rowSlice = .head(excludingTrailing: 2)
        head.update(snapshot: snapshot)
        XCTAssertNil(head.cursorAnchorRect())

        let footer = GridContentLayer(metrics: metrics)
        footer.rowSlice = .tail(count: 2)
        footer.update(snapshot: snapshot)
        // The cmdline row sits the cmdline gap below the statusline row, so
        // the cursor lands there in the footer's own coordinates.
        let anchor = try XCTUnwrap(footer.cursorAnchorRect())
        XCTAssertEqual(
            anchor.minY,
            metrics.cellSize.height + TerminalView.cmdlineGap,
            accuracy: 0.001
        )
    }

    func testCursorInTheTextAreaIsDrawnByTheScrollingRegion() throws {
        let snapshot = snapshot(height: 6, cursorRow: 2)
        let footer = GridContentLayer(metrics: metrics)
        footer.rowSlice = .tail(count: 2)
        footer.update(snapshot: snapshot)
        XCTAssertNil(footer.cursorAnchorRect())

        let head = GridContentLayer(metrics: metrics)
        head.rowSlice = .head(excludingTrailing: 2)
        head.update(snapshot: snapshot)
        let anchor = try XCTUnwrap(head.cursorAnchorRect())
        XCTAssertEqual(anchor.minY, 2 * metrics.cellSize.height, accuracy: 0.001)
        // Grid coordinates put the same cell back on the grid row, which is
        // what the cursor glide interpolates in.
        let gridAnchor = try XCTUnwrap(head.cursorGridRect())
        XCTAssertEqual(gridAnchor.minY, anchor.minY, accuracy: 0.001)
    }

    /// A plain grid of blank cells, tall enough to hold both regions.
    private func snapshot(height: Int, cursorRow: Int = 0) -> ScreenSnapshot {
        let width = 8
        var grid = Grid(id: 1, width: width, height: height)
        for row in 0..<height {
            grid.applyLine(
                row: row,
                colStart: 0,
                runs: [GridCellRun(text: " ", attrId: 0, count: width)]
            )
        }
        return ScreenSnapshot(
            grid: grid,
            highlights: HighlightStore(),
            defaultForeground: 0xC8D3E0,
            defaultBackground: 0x0F1419,
            defaultSpecial: nil,
            cursor: CursorState(grid: 1, row: cursorRow, col: 2),
            modes: [ModeInfo(name: "normal", cursorShape: .block)],
            modeIndex: 0
        )
    }
}
