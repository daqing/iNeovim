import AppKit
import CoreText
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
            [StyledRun(text: "ab", attrId: 3, startCol: 0, endCol: 2, slots: [
                StyledRunSlot(utf16: 0, col: 0, cols: 1),
                StyledRunSlot(utf16: 1, col: 1, cols: 1),
            ])]
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
                StyledRun(text: "a", attrId: 1, startCol: 0, endCol: 1, slots: [
                    StyledRunSlot(utf16: 0, col: 0, cols: 1),
                ]),
                StyledRun(text: "bc", attrId: 2, startCol: 1, endCol: 3, slots: [
                    StyledRunSlot(utf16: 0, col: 0, cols: 1),
                    StyledRunSlot(utf16: 1, col: 1, cols: 1),
                ]),
            ]
        )
    }

    func testBlankCellsMergeWithinSameAttr() {
        let row = [GridCell(text: "a", attrId: 5), GridCell(text: " ", attrId: 5)]
        XCTAssertEqual(
            CellRenderer.runs(forRow: row),
            [StyledRun(text: "a ", attrId: 5, startCol: 0, endCol: 2, slots: [
                StyledRunSlot(utf16: 0, col: 0, cols: 1),
                StyledRunSlot(utf16: 1, col: 1, cols: 1),
            ])]
        )
    }

    func testAttrChangeSplitsOffBlankCells() {
        // A default-highlight blank (attr 0) is a different background and
        // must not be absorbed into a styled run.
        let row = [GridCell(text: "a", attrId: 5), GridCell()]
        XCTAssertEqual(
            CellRenderer.runs(forRow: row),
            [
                StyledRun(text: "a", attrId: 5, startCol: 0, endCol: 1, slots: [
                    StyledRunSlot(utf16: 0, col: 0, cols: 1),
                ]),
                StyledRun(text: " ", attrId: 0, startCol: 1, endCol: 2, slots: [
                    StyledRunSlot(utf16: 0, col: 0, cols: 1),
                ]),
            ]
        )
    }

    func testLigatureSequencesStayInOneShapedRun() {
        // "==>" shaped as one CTLine lets Core Text form the Fira Code
        // ligature; splitting the run would break it.
        let row = ["=", "=", ">"].map { GridCell(text: $0, attrId: 0) }
        XCTAssertEqual(
            CellRenderer.runs(forRow: row),
            [StyledRun(text: "==>", attrId: 0, startCol: 0, endCol: 3, slots: [
                StyledRunSlot(utf16: 0, col: 0, cols: 1),
                StyledRunSlot(utf16: 1, col: 1, cols: 1),
                StyledRunSlot(utf16: 2, col: 2, cols: 1),
            ])]
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
                StyledRun(text: "=", attrId: 1, startCol: 0, endCol: 1, slots: [
                    StyledRunSlot(utf16: 0, col: 0, cols: 1),
                ]),
                StyledRun(text: "=", attrId: 2, startCol: 1, endCol: 2, slots: [
                    StyledRunSlot(utf16: 0, col: 0, cols: 1),
                ]),
            ]
        )
    }

    func testWideCharAbsorbsContinuationDespiteAttrChange() {
        let row = [GridCell(text: "你", attrId: 1), GridCell(text: "", attrId: 2)]
        XCTAssertEqual(
            CellRenderer.runs(forRow: row),
            [StyledRun(text: "你", attrId: 1, startCol: 0, endCol: 2, slots: [
                StyledRunSlot(utf16: 0, col: 0, cols: 2),
            ])]
        )
    }

    func testAdjacentWideCharsAbsorbBothContinuationCells() {
        // Each 你 is followed by its empty continuation cell, so the second
        // one starts at column 2.
        let row = [
            GridCell(text: "你", attrId: 1),
            GridCell(text: "", attrId: 1),
            GridCell(text: "你", attrId: 1),
            GridCell(text: "", attrId: 1),
        ]
        XCTAssertEqual(
            CellRenderer.runs(forRow: row),
            [StyledRun(text: "你你", attrId: 1, startCol: 0, endCol: 4, slots: [
                StyledRunSlot(utf16: 0, col: 0, cols: 2),
                StyledRunSlot(utf16: 1, col: 2, cols: 2),
            ])]
        )
    }

    func testContinuationWidthComesFromProtocolNotWidthTable() {
        // An empty-text cell is nvim's continuation marker whatever the
        // character is — even one our own width table calls narrow.
        let row = [
            GridCell(text: "x", attrId: 1),
            GridCell(text: "", attrId: 1),
            GridCell(text: "y", attrId: 1),
        ]
        XCTAssertEqual(
            CellRenderer.runs(forRow: row),
            [StyledRun(text: "xy", attrId: 1, startCol: 0, endCol: 3, slots: [
                StyledRunSlot(utf16: 0, col: 0, cols: 2),
                StyledRunSlot(utf16: 1, col: 2, cols: 1),
            ])]
        )
    }

    func testCombiningSequencePassesThroughUnchanged() {
        let row = [GridCell(text: "e\u{301}", attrId: 3), GridCell(text: "x", attrId: 3)]
        XCTAssertEqual(
            CellRenderer.runs(forRow: row),
            [StyledRun(text: "e\u{301}x", attrId: 3, startCol: 0, endCol: 2, slots: [
                StyledRunSlot(utf16: 0, col: 0, cols: 1),
                StyledRunSlot(utf16: 2, col: 1, cols: 1),
            ])]
        )
    }

    // MARK: - Glyph pinning

    func testShiftGroupsLeaveAlignedAsciiAsOneGroup() {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let cellWidth = FontMetrics(font: font).cellSize.width
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: "abcd", attributes: [.font: font])
        )
        let slots = (0..<4).map { StyledRunSlot(utf16: $0, col: $0, cols: 1) }

        let groups = CellRenderer.shiftGroups(for: line, slots: slots, cellWidth: cellWidth)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].dx, 0)
        XCTAssertEqual(groups[0].range.location, 0)
        XCTAssertEqual(groups[0].range.length, 4)
    }

    func testShiftGroupsPinFallbackCjkToCellOrigins() {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let cellWidth = FontMetrics(font: font).cellSize.width
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: "ab中文cd", attributes: [.font: font])
        )
        // nvim's layout: 中 and 文 each take two cells.
        let slots = [
            StyledRunSlot(utf16: 0, col: 0, cols: 1),
            StyledRunSlot(utf16: 1, col: 1, cols: 1),
            StyledRunSlot(utf16: 2, col: 2, cols: 2),
            StyledRunSlot(utf16: 3, col: 4, cols: 2),
            StyledRunSlot(utf16: 4, col: 6, cols: 1),
            StyledRunSlot(utf16: 5, col: 7, cols: 1),
        ]

        let groups = CellRenderer.shiftGroups(for: line, slots: slots, cellWidth: cellWidth)

        // The CJK fallback advances narrower than two cells, so the run must
        // split: leading ASCII stays put, the glyphs after the shortfall get
        // shifted back onto their slots, and every glyph is still drawn
        // exactly once.
        XCTAssertGreaterThan(groups.count, 1)
        XCTAssertEqual(groups.first?.dx, 0)
        XCTAssertGreaterThan(groups.map(\.dx).max() ?? 0, 0.5)
        let totalGlyphs = (CTLineGetGlyphRuns(line) as! [CTRun]).reduce(0) { $0 + CTRunGetGlyphCount($1) }
        XCTAssertEqual(groups.reduce(0) { $0 + $1.range.length }, totalGlyphs)
    }
}
