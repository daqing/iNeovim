import XCTest
@testable import iNeovim

/// T9.2 performance baselines for the hot paths identified in the review:
/// redraw run grouping, msgpack-RPC codec throughput, and grid scrolling.
/// Run with test repetitions enabled (Product ▸ Test, or the test plan) to
/// track regressions; Instruments covers the GPU/Core Text side that XCTest
/// cannot (see docs/PERFORMANCE.md).
@MainActor
final class PerformanceTests: XCTestCase {
    func testRunGroupingFullScreen() {
        let grid = Self.makeGrid(rows: 60, cols: 200)
        measure {
            for row in 0..<grid.height {
                _ = CellRenderer.runs(forRow: grid.rowSlice(row))
            }
        }
    }

    func testMsgPackEncodeThroughput() {
        let value = Self.representativeBatch
        measure {
            _ = MsgPackEncoder.encode(value)
        }
    }

    func testMsgPackDecodeThroughput() {
        let encoded = MsgPackEncoder.encode(Self.representativeBatch)
        measure {
            var decoder = MsgPackDecoder()
            decoder.feed(encoded)
            _ = try? decoder.nextValue()
        }
    }

    func testGridScrollThroughput() {
        var grid = Self.makeGrid(rows: 60, cols: 200)
        measure {
            grid.scroll(top: 0, bot: 60, left: 0, right: 200, rows: 1, cols: 0)
        }
    }

    private static func makeGrid(rows: Int, cols: Int) -> Grid {
        var grid = Grid(id: 1, width: cols, height: rows)
        let runs = [
            GridCellRun(text: "a", attrId: 0, count: cols / 2),
            GridCellRun(text: "b", attrId: 1, count: cols - cols / 2),
        ]
        for row in 0..<rows {
            grid.applyLine(row: row, colStart: 0, runs: runs)
        }
        return grid
    }

    /// A `redraw`-shaped payload: a batch of grid_line events plus a flush.
    private static var representativeBatch: MsgPackValue {
        var events: [MsgPackValue] = []
        for row in 0..<24 {
            events.append(.array([
                .string("grid_line"), .uint(1), .uint(UInt64(row)), .uint(0),
                .array([
                    .array([.string("the quick brown fox "), .uint(1), .uint(20)]),
                ]),
            ]))
        }
        events.append(.array([.string("cursor_goto"), .uint(1), .uint(10), .uint(4)]))
        events.append(.array([.string("flush")]))
        return .array([.string("redraw"), .array(events)])
    }
}
