import XCTest
@testable import iNeovim

@MainActor
final class PreeditGeometryTests: XCTestCase {
    func testCellCountTreatsAsciiAsSingleWidth() {
        XCTAssertEqual(TerminalView.cellCount(of: "kana"), 4)
    }

    func testCellCountTreatsCjkAsDoubleWidth() {
        XCTAssertEqual(TerminalView.cellCount(of: "かな"), 4)
    }

    func testCellCountMixesWidths() {
        XCTAssertEqual(TerminalView.cellCount(of: "aか"), 3)
    }

    // CJK Ext B characters are double-width and use a surrogate pair, so one
    // character spans two UTF-16 units and two cells.
    private let wide = "\u{20000}\u{20001}"

    func testCellOffsetCountsWholeCharacters() {
        XCTAssertEqual(TerminalView.cellOffset(of: wide, upToUTF16: 2), 2)
        XCTAssertEqual(TerminalView.cellOffset(of: "ab" + wide, upToUTF16: 2), 2)
        XCTAssertEqual(TerminalView.cellOffset(of: "ab" + wide, upToUTF16: 4), 4)
    }

    func testCellOffsetSplitsSurrogatePairs() {
        // A utf16 offset landing inside a surrogate pair covers nothing of it.
        XCTAssertEqual(TerminalView.cellOffset(of: wide, upToUTF16: 1), 0)
        XCTAssertEqual(TerminalView.cellOffset(of: "ab" + wide, upToUTF16: 3), 2)
    }
}
