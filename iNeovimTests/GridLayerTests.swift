import AppKit
import XCTest
@testable import iNeovim

/// Under ext_multigrid every displayed grid draws in its own
/// `GridContentLayer`, placed at its frame's global position. The cmdline
/// gap belongs to the global grid's last row, so a grid reaching that row
/// (the global grid itself, the message grid) carries the gap in its own
/// row math while window grids never do.
@MainActor
final class GridLayerTests: XCTestCase {
    private let metrics = FontMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))

    func testGlobalGridLastRowCarriesTheCmdlineGap() {
        let snapshot = snapshot(globalHeight: 6)
        let layer = GridContentLayer(metrics: metrics, gridId: 1)
        layer.update(snapshot: snapshot)
        let cellHeight = metrics.cellSize.height
        // Five uniform rows plus the gap-shifted last row.
        XCTAssertEqual(
            layer.bounds.height,
            6 * cellHeight + TerminalView.cmdlineGap,
            accuracy: 0.001
        )
        XCTAssertEqual(layer.originY, 0, accuracy: 0.001)
    }

    func testWindowGridRowsStayUniform() {
        // A window grid at the top of the screen: its last row is the global
        // statusline row minus one, so no row inside the window is shifted.
        var snapshot = snapshot(globalHeight: 12)
        snapshot.frames[2] = GridFrame(row: 0, col: 0)
        let layer = GridContentLayer(metrics: metrics, gridId: 2)
        layer.update(snapshot: snapshot)
        let cellHeight = metrics.cellSize.height
        XCTAssertEqual(layer.bounds.height, 10 * cellHeight, accuracy: 0.001)
        XCTAssertEqual(layer.originY, 0, accuracy: 0.001)
    }

    func testMessageGridCarriesTheGapOnTheGlobalLastRow() {
        // The message grid holds the cmdline row: its frame starts three
        // rows above the global grid's bottom, so its own last row is the
        // global last row and takes the gap.
        var snapshot = snapshot(globalHeight: 12)
        snapshot.frames[3] = GridFrame(row: 9, col: 0, isMessage: true)
        let layer = GridContentLayer(metrics: metrics, gridId: 3)
        layer.update(snapshot: snapshot)
        let cellHeight = metrics.cellSize.height
        // Rows 0..2 map to global rows 9..11 uniformly; row 2 is the global
        // last row (11) and is gap-shifted, capping the layer at the window
        // bottom.
        XCTAssertEqual(
            layer.bounds.height,
            3 * cellHeight + TerminalView.cmdlineGap,
            accuracy: 0.001
        )
        XCTAssertEqual(layer.originY, 9 * cellHeight, accuracy: 0.001)
    }

    func testMessageGridCoveringTheStatuslineRowReportsCoverage() {
        // A multi-row message block (error text plus the hit-enter prompt)
        // rails the screen: the row above the last row carries a message,
        // not the statusline.
        var snapshot = snapshot(globalHeight: 12)
        snapshot.frames[3] = GridFrame(row: 9, col: 0, isMessage: true)
        XCTAssertTrue(snapshot.messageGridCovers(row: 10))
        XCTAssertFalse(snapshot.messageGridCovers(row: 8))
    }

    func testSingleRowMessageLeavesTheStatuslineRowAlone() {
        // A one-line message lives on the cmdline row only; the statusline
        // stays visible underneath.
        var snapshot = snapshot(globalHeight: 12)
        snapshot.frames[3] = GridFrame(row: 11, col: 0, isMessage: true)
        XCTAssertFalse(snapshot.messageGridCovers(row: 10))
        XCTAssertTrue(snapshot.messageGridCovers(row: 11))
    }

    func testHiddenMessageGridCoversNothing() {
        var snapshot = snapshot(globalHeight: 12)
        snapshot.frames[3] = GridFrame(row: 9, col: 0, hidden: true, isMessage: true)
        XCTAssertFalse(snapshot.messageGridCovers(row: 10))
    }

    func testDismissedMessageGridDoesNotDrawStaleRows() {
        var snapshot = snapshot(globalHeight: 12)
        snapshot.frames[3] = GridFrame(row: 11, col: 0, isMessage: true)
        snapshot.highlights.define(
            HlAttr(foreground: 0x14161B, background: 0xC53B4A),
            for: 905
        )
        var messageGrid = snapshot.grids[3]!
        messageGrid.applyLine(
            row: 0,
            colStart: 0,
            runs: [GridCellRun(text: " ", attrId: 0, count: 8)]
        )
        messageGrid.applyLine(
            row: 1,
            colStart: 0,
            runs: [GridCellRun(text: "E", attrId: 905, count: 8)]
        )
        snapshot.grids[3] = messageGrid

        let layer = GridContentLayer(metrics: metrics, gridId: 3)
        layer.update(snapshot: snapshot)
        XCTAssertEqual(layer.bounds.height, metrics.cellSize.height, accuracy: 0.001)

        let width = Int(layer.bounds.width.rounded())
        let height = Int(layer.bounds.height.rounded())
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            layer.draw(in: context)
            return true
        }
        XCTAssertTrue(drew)
        XCTAssertTrue(
            pixels.allSatisfy { $0 == 0 },
            "The re-parked message grid must not draw its stale second row into the cmdline row"
        )
    }

    func testCursorIsDrawnOnlyByItsOwnGridLayer() throws {
        var snapshot = snapshot(globalHeight: 12, cursorGrid: 2, cursorRow: 3)
        snapshot.frames[2] = GridFrame(row: 0, col: 0)

        let base = GridContentLayer(metrics: metrics, gridId: 1)
        base.update(snapshot: snapshot)
        XCTAssertNil(base.cursorAnchorRect())

        let window = GridContentLayer(metrics: metrics, gridId: 2)
        window.update(snapshot: snapshot)
        let anchor = try XCTUnwrap(window.cursorAnchorRect())
        XCTAssertEqual(anchor.minY, 3 * metrics.cellSize.height, accuracy: 0.001)

        // The glide's from/to geometry reads cursor rects straight out of
        // older snapshots of the same grid.
        let previous = snapshot
        XCTAssertEqual(
            try XCTUnwrap(window.cursorRestRect(in: previous)).minY,
            anchor.minY,
            accuracy: 0.001
        )
    }

    /// A global grid of blank cells; every other grid is a blank window
    /// grid 10 rows tall at 8 columns.
    private func snapshot(
        globalHeight: Int,
        cursorGrid: Int = 1,
        cursorRow: Int = 0
    ) -> ScreenSnapshot {
        let width = 8
        var grids: [Int: Grid] = [:]
        var grid = Grid(id: 1, width: width, height: globalHeight)
        for row in 0..<globalHeight {
            grid.applyLine(
                row: row,
                colStart: 0,
                runs: [GridCellRun(text: " ", attrId: 0, count: width)]
            )
        }
        grids[1] = grid
        for id in [2, 3] {
            var window = Grid(id: id, width: width, height: 10)
            for row in 0..<10 {
                window.applyLine(
                    row: row,
                    colStart: 0,
                    runs: [GridCellRun(text: " ", attrId: 0, count: width)]
                )
            }
            grids[id] = window
        }
        return ScreenSnapshot(
            grid: grid,
            grids: grids,
            frames: [:],
            highlights: HighlightStore(),
            defaultForeground: 0xC8D3E0,
            defaultBackground: 0x0F1419,
            defaultSpecial: nil,
            cursor: CursorState(grid: cursorGrid, row: cursorRow, col: 2),
            modes: [ModeInfo(name: "normal", cursorShape: .block)],
            modeIndex: 0
        )
    }
}
