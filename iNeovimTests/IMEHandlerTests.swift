import AppKit
import XCTest
@testable import iNeovim

@MainActor
final class IMEHandlerTests: XCTestCase {
    func testSetMarkedTextStoresTextAndSelection() {
        let ime = IMEHandler()
        ime.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(ime.hasMarkedText)
        XCTAssertEqual(ime.markedText, "かな")
        XCTAssertEqual(ime.selectedRange(), NSRange(location: 2, length: 0))
    }

    func testSetMarkedTextClampsSelection() {
        let ime = IMEHandler()
        ime.setMarkedText("ab", selectedRange: NSRange(location: 5, length: 9), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(ime.selectedRange(), NSRange(location: 2, length: 0))
    }

    func testUnmarkTextClearsMarkedState() {
        let ime = IMEHandler()
        ime.setMarkedText("かな", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        ime.unmarkText()
        XCTAssertFalse(ime.hasMarkedText)
        XCTAssertEqual(ime.selectedRange(), NSRange(location: NSNotFound, length: 0))
    }

    func testInsertTextUnmarksFirst() {
        let ime = IMEHandler()
        ime.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        ime.insertText("仮名", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(ime.hasMarkedText)
    }

    func testMarkedTextChangeNotifiesObserver() {
        let ime = IMEHandler()
        var notifications = 0
        ime.onMarkedTextChange = { notifications += 1 }
        ime.setMarkedText("a", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        ime.unmarkText()
        XCTAssertEqual(notifications, 2)
    }

    func testAttributedSubstringIsUnsupported() {
        let ime = IMEHandler()
        XCTAssertNil(ime.attributedSubstring(forProposedRange: NSRange(location: 0, length: 1), actualRange: nil))
    }

    func testLiteralKeysEscapesNotationAndLineBreaks() {
        XCTAssertEqual(IMEHandler.literalKeys(for: "a<b"), "a<lt>b")
        XCTAssertEqual(IMEHandler.literalKeys(for: "one\ntwo"), "one<CR>two")
        XCTAssertEqual(IMEHandler.literalKeys(for: "one\rtwo"), "one<CR>two")
    }

    func testDoCommandMapsKnownSelectors() {
        XCTAssertEqual(IMEHandler.selectorKeys[Selector("insertNewline:")], "<CR>")
        XCTAssertEqual(IMEHandler.selectorKeys[Selector("moveUp:")], "<Up>")
        XCTAssertEqual(IMEHandler.selectorKeys[Selector("cancelOperation:")], "<Esc>")
        XCTAssertEqual(IMEHandler.selectorKeys[Selector("insertBacktab:")], "<S-Tab>")
        XCTAssertEqual(IMEHandler.selectorKeys[Selector("moveToBeginningOfLine:")], "<Home>")
        XCTAssertEqual(IMEHandler.selectorKeys[Selector("movePageDown:")], "<PageDown>")
    }
}
