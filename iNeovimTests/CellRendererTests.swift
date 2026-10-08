import XCTest
@testable import iNeovim

@MainActor
final class CellRendererTests: XCTestCase {
    func testEmptyRowHasNoRuns() {
        XCTAssertEqual(CellRenderer.runs(forRow: []), [])
    }

    func testSameAttrCellsMergeIntoOneRun() {
        let row = [GridCell(text: "a", attrId: 3), GridCell(text: "b", attrId: 3)]
        XCTAssertEqual(
            CellRenderer.runs(forRow: row),
            [StyledRun(text: "ab", attrId: 3, startCol: 0, endCol: 2)]
        )
    }

    func testAttrChangeSplitsRuns() {
        let row = [
            GridCell(text: "a", attrId: 1),
            GridCell(text: "b", attrId: 2),
            GridCell(text: "c", attrId: 2),
        ]
        XCTAssertEqual(
            CellRenderer.runs(forRow: row),
            [
                StyledRun(text: "a", attrId: 1, startCol: 0, endCol: 1),
                StyledRun(text: "bc", attrId: 2, startCol: 1, endCol: 3),
            ]
        )
    }

    func testBlankCellsMergeWithinSameAttr() {
        let row = [GridCell(text: "a", attrId: 5), GridCell(text: " ", attrId: 5)]
        XCTAssertEqual(
            CellRenderer.runs(forRow: row),
            [StyledRun(text: "a ", attrId: 5, startCol: 0, endCol: 2)]
        )
    }

    func testAttrChangeSplitsOffBlankCells() {
        // A default-highlight blank (attr 0) is a different background and
        // must not be absorbed into a styled run.
        let row = [GridCell(text: "a", attrId: 5), GridCell()]
        XCTAssertEqual(
            CellRenderer.runs(forRow: row),
            [
                StyledRun(text: "a", attrId: 5, startCol: 0, endCol: 1),
                StyledRun(text: " ", attrId: 0, startCol: 1, endCol: 2),
            ]
        )
    }

    func testLigatureSequencesStayInOneShapedRun() {
        // "==>" shaped as one CTLine lets Core Text form the Fira Code
        // ligature; splitting the run would break it.
        let row = ["=", "=", ">"].map { GridCell(text: $0, attrId: 0) }
        XCTAssertEqual(
            CellRenderer.runs(forRow: row),
            [StyledRun(text: "==>", attrId: 0, startCol: 0, endCol: 3)]
        )
    }

    func testStyleChangeBreaksLigatureRuns() {
        let row = [
            GridCell(text: "=", attrId: 1),
            GridCell(text: "=", attrId: 2),
        ]
        XCTAssertEqual(
            CellRenderer.runs(forRow: row),
            [
                StyledRun(text: "=", attrId: 1, startCol: 0, endCol: 1),
                StyledRun(text: "=", attrId: 2, startCol: 1, endCol: 2),
            ]
        )
    }

    func testWideCharAbsorbsContinuationDespiteAttrChange() {
        let row = [GridCell(text: "你", attrId: 1), GridCell(text: "", attrId: 2)]
        XCTAssertEqual(
            CellRenderer.runs(forRow: row),
            [StyledRun(text: "你", attrId: 1, startCol: 0, endCol: 2)]
        )
    }

    func testAdjacentWideCharsAbsorbBothContinuationCells() {
        let row = [
            GridCell(text: "你", attrId: 1),
            GridCell(text: "你", attrId: 1),
            GridCell(text: "", attrId: 1),
            GridCell(text: "", attrId: 1),
        ]
        XCTAssertEqual(
            CellRenderer.runs(forRow: row),
            [StyledRun(text: "你你", attrId: 1, startCol: 0, endCol: 4)]
        )
    }

    func testCombiningSequencePassesThroughUnchanged() {
        let row = [GridCell(text: "e\u{301}", attrId: 3), GridCell(text: "x", attrId: 3)]
        XCTAssertEqual(
            CellRenderer.runs(forRow: row),
            [StyledRun(text: "e\u{301}x", attrId: 3, startCol: 0, endCol: 2)]
        )
    }
}
