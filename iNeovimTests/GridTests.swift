import XCTest
@testable import iNeovim

@MainActor
final class GridTests: XCTestCase {
    func testInitialGridIsBlank() {
        let grid = Grid(id: 1, width: 3, height: 2)
        XCTAssertEqual(grid.width, 3)
        XCTAssertEqual(grid.height, 2)
        XCTAssertEqual(grid[0, 0], GridCell())
        XCTAssertEqual(grid[1, 2], GridCell())
    }

    func testApplyLineExpandsRunsAndClips() {
        var grid = Grid(id: 1, width: 4, height: 2)
        grid.applyLine(row: 0, colStart: 1, runs: [
            GridCellRun(text: "a", attrId: 7, count: 2),
            GridCellRun(text: "b", attrId: 8, count: 5),
        ])
        XCTAssertEqual(grid[0, 0], GridCell())
        XCTAssertEqual(grid[0, 1], GridCell(text: "a", attrId: 7))
        XCTAssertEqual(grid[0, 2], GridCell(text: "a", attrId: 7))
        XCTAssertEqual(grid[0, 3], GridCell(text: "b", attrId: 8))
        // Untouched row stays blank.
        XCTAssertEqual(grid[1, 3], GridCell())
    }

    func testApplyLineOutOfBoundsIsIgnored() {
        var grid = Grid(id: 1, width: 2, height: 2)
        grid.applyLine(row: 5, colStart: 0, runs: [GridCellRun(text: "x", attrId: 1, count: 1)])
        grid.applyLine(row: 0, colStart: 3, runs: [GridCellRun(text: "x", attrId: 1, count: 1)])
        XCTAssertEqual(grid[0, 0], GridCell())
    }

    func testApplyLineSkipsZeroCountCells() {
        // nvim emits repeat-0 entries as chunk markers when splitting one row
        // across grid_line events; they cover no cells.
        var grid = Grid(id: 1, width: 4, height: 1)
        grid.applyLine(row: 0, colStart: 0, runs: [
            GridCellRun(text: "a", attrId: 1, count: 1),
            GridCellRun(text: " ", attrId: 0, count: 0),
            GridCellRun(text: "b", attrId: 2, count: 1),
        ])
        XCTAssertEqual(grid[0, 0].text, "a")
        XCTAssertEqual(grid[0, 1].text, "b")
        XCTAssertEqual(grid[0, 2], GridCell())
    }

    func testApplyLineStoresWideCharContinuationFromProtocol() {
        // A wide char is followed by an explicit empty-text cell; the renderer
        // reads that back as the double-width marker.
        var grid = Grid(id: 1, width: 4, height: 1)
        grid.applyLine(row: 0, colStart: 0, runs: [
            GridCellRun(text: "你", attrId: 1, count: 1),
            GridCellRun(text: "", attrId: 1, count: 1),
            GridCellRun(text: "x", attrId: 1, count: 1),
        ])
        XCTAssertEqual(grid[0, 0].text, "你")
        XCTAssertEqual(grid[0, 1].text, "")
        XCTAssertEqual(grid[0, 2].text, "x")
    }

    func testResizePreservesTopLeftAndClearsNewCells() {
        var grid = Grid(id: 1, width: 2, height: 2)
        grid.applyLine(row: 0, colStart: 0, runs: [GridCellRun(text: "x", attrId: 1, count: 2)])
        grid.applyLine(row: 1, colStart: 0, runs: [GridCellRun(text: "y", attrId: 1, count: 2)])

        grid.resize(width: 4, height: 3)
        XCTAssertEqual(grid.width, 4)
        XCTAssertEqual(grid.height, 3)
        XCTAssertEqual(grid[0, 0], GridCell(text: "x", attrId: 1))
        XCTAssertEqual(grid[1, 1], GridCell(text: "y", attrId: 1))
        XCTAssertEqual(grid[2, 0], GridCell())
        XCTAssertEqual(grid[0, 3], GridCell())

        grid.resize(width: 1, height: 1)
        XCTAssertEqual(grid[0, 0], GridCell(text: "x", attrId: 1))
        XCTAssertEqual(grid.width, 1)
        XCTAssertEqual(grid.height, 1)
    }

    func testClearResetsAllCells() {
        var grid = Grid(id: 1, width: 2, height: 2)
        grid.applyLine(row: 0, colStart: 0, runs: [GridCellRun(text: "x", attrId: 3, count: 2)])
        grid.clear()
        XCTAssertEqual(grid[0, 0], GridCell())
        XCTAssertEqual(grid[0, 1], GridCell())
    }

    func testScrollUpMovesContentAndClearsBottom() {
        var grid = gridWithColumnContent(["A", "B", "C", "D", "E"])
        grid.scroll(top: 0, bot: 5, left: 0, right: 1, rows: 2, cols: 0)
        XCTAssertEqual(grid[0, 0].text, "C")
        XCTAssertEqual(grid[1, 0].text, "D")
        XCTAssertEqual(grid[2, 0].text, "E")
        XCTAssertEqual(grid[3, 0], GridCell())
        XCTAssertEqual(grid[4, 0], GridCell())
    }

    func testScrollDownMovesContentAndClearsTop() {
        var grid = gridWithColumnContent(["A", "B", "C", "D", "E"])
        grid.scroll(top: 0, bot: 5, left: 0, right: 1, rows: -2, cols: 0)
        XCTAssertEqual(grid[0, 0], GridCell())
        XCTAssertEqual(grid[1, 0], GridCell())
        XCTAssertEqual(grid[2, 0].text, "A")
        XCTAssertEqual(grid[3, 0].text, "B")
        XCTAssertEqual(grid[4, 0].text, "C")
    }

    func testScrollsOnlyWithinRegion() {
        var grid = gridWithColumnContent(["A", "B", "C", "D", "E"])
        grid.scroll(top: 1, bot: 4, left: 0, right: 1, rows: 1, cols: 0)
        XCTAssertEqual(grid[0, 0].text, "A")
        XCTAssertEqual(grid[1, 0].text, "C")
        XCTAssertEqual(grid[2, 0].text, "D")
        XCTAssertEqual(grid[3, 0], GridCell())
        XCTAssertEqual(grid[4, 0].text, "E")
    }

    func testScrollLeftMovesContentHorizontally() {
        var grid = Grid(id: 1, width: 5, height: 1)
        grid.applyLine(row: 0, colStart: 0, runs: ["A", "B", "C", "D", "E"].map {
            GridCellRun(text: $0, attrId: 0, count: 1)
        })
        grid.scroll(top: 0, bot: 1, left: 0, right: 5, rows: 0, cols: 2)
        XCTAssertEqual(grid[0, 0].text, "C")
        XCTAssertEqual(grid[0, 1].text, "D")
        XCTAssertEqual(grid[0, 2].text, "E")
        XCTAssertEqual(grid[0, 3], GridCell())
        XCTAssertEqual(grid[0, 4], GridCell())
    }

    func testDiagonalScrollReadsPreScrollContent() {
        var grid = Grid(id: 1, width: 3, height: 3)
        for row in 0..<3 {
            grid.applyLine(row: row, colStart: 0, runs: [GridCellRun(text: "\(row)", attrId: 0, count: 3)])
        }
        grid.scroll(top: 0, bot: 3, left: 0, right: 3, rows: 1, cols: 1)
        XCTAssertEqual(grid[0, 0].text, "1")
        XCTAssertEqual(grid[1, 1].text, "2")
        XCTAssertEqual(grid[2, 2], GridCell())
        XCTAssertEqual(grid[0, 2], GridCell())
    }

    func testZeroScrollIsANoOp() {
        var grid = gridWithColumnContent(["A", "B"])
        grid.scroll(top: 0, bot: 2, left: 0, right: 1, rows: 0, cols: 0)
        XCTAssertEqual(grid[0, 0].text, "A")
        XCTAssertEqual(grid[1, 0].text, "B")
    }

    private func gridWithColumnContent(_ texts: [String]) -> Grid {
        var grid = Grid(id: 1, width: 1, height: texts.count)
        for (row, text) in texts.enumerated() {
            grid.applyLine(row: row, colStart: 0, runs: [GridCellRun(text: text, attrId: 0, count: 1)])
        }
        return grid
    }
}
