import AppKit
import XCTest
@testable import iNeovim

@MainActor
final class KeyInputHandlerTests: XCTestCase {
    private let handler = KeyInputHandler()

    func testPlainCharacterReturnsNilForTextPath() {
        let event = keyEvent("a", ignoringModifiers: "a", keyCode: 0)
        XCTAssertNil(handler.nvimKey(for: event))
    }

    func testShiftedCharacterReturnsNilForTextPath() {
        let event = keyEvent("A", ignoringModifiers: "A", keyCode: 0, modifiers: [.shift])
        XCTAssertNil(handler.nvimKey(for: event))
    }

    func testControlLetterProducesNotation() {
        let event = keyEvent("\u{1}", ignoringModifiers: "a", keyCode: 0, modifiers: [.control])
        XCTAssertEqual(handler.nvimKey(for: event), "<C-a>")
    }

    func testControlShiftLetterProducesNotation() {
        let event = keyEvent("\u{1}", ignoringModifiers: "A", keyCode: 0, modifiers: [.control, .shift])
        XCTAssertEqual(handler.nvimKey(for: event), "<C-S-a>")
    }

    func testEscapeProducesNotation() {
        let event = keyEvent("\u{1b}", ignoringModifiers: "\u{1b}", keyCode: 53)
        XCTAssertEqual(handler.nvimKey(for: event), "<Esc>")
    }

    func testReturnProducesNotation() {
        let event = keyEvent("\r", ignoringModifiers: "\r", keyCode: 36)
        XCTAssertEqual(handler.nvimKey(for: event), "<CR>")
    }

    func testTabProducesNotation() {
        let event = keyEvent("\t", ignoringModifiers: "\t", keyCode: 48)
        XCTAssertEqual(handler.nvimKey(for: event), "<Tab>")
    }

    func testBackspaceProducesNotation() {
        let event = keyEvent("\u{7f}", ignoringModifiers: "\u{7f}", keyCode: 51)
        XCTAssertEqual(handler.nvimKey(for: event), "<BS>")
    }

    func testArrowsProduceNotation() {
        XCTAssertEqual(handler.nvimKey(for: keyEvent("\u{f702}", ignoringModifiers: "\u{f702}", keyCode: 123)), "<Left>")
        XCTAssertEqual(handler.nvimKey(for: keyEvent("\u{f703}", ignoringModifiers: "\u{f703}", keyCode: 124)), "<Right>")
        XCTAssertEqual(handler.nvimKey(for: keyEvent("\u{f701}", ignoringModifiers: "\u{f701}", keyCode: 125)), "<Down>")
        XCTAssertEqual(handler.nvimKey(for: keyEvent("\u{f700}", ignoringModifiers: "\u{f700}", keyCode: 126)), "<Up>")
    }

    func testArrowWithModifiersProducesNotation() {
        let event = keyEvent("\u{f702}", ignoringModifiers: "\u{f702}", keyCode: 123, modifiers: [.control, .shift])
        XCTAssertEqual(handler.nvimKey(for: event), "<C-S-Left>")
    }

    func testFunctionKeysProduceNotation() {
        XCTAssertEqual(handler.nvimKey(for: keyEvent("", ignoringModifiers: "", keyCode: 122)), "<F1>")
        XCTAssertEqual(handler.nvimKey(for: keyEvent("", ignoringModifiers: "", keyCode: 96)), "<F5>")
        XCTAssertEqual(handler.nvimKey(for: keyEvent("", ignoringModifiers: "", keyCode: 111)), "<F12>")
    }

    func testNavigationKeysProduceNotation() {
        XCTAssertEqual(handler.nvimKey(for: keyEvent("\u{f729}", ignoringModifiers: "\u{f729}", keyCode: 115)), "<Home>")
        XCTAssertEqual(handler.nvimKey(for: keyEvent("\u{f72b}", ignoringModifiers: "\u{f72b}", keyCode: 119)), "<End>")
        XCTAssertEqual(handler.nvimKey(for: keyEvent("\u{f72c}", ignoringModifiers: "\u{f72c}", keyCode: 116)), "<PageUp>")
        XCTAssertEqual(handler.nvimKey(for: keyEvent("\u{f72d}", ignoringModifiers: "\u{f72d}", keyCode: 121)), "<PageDown>")
        XCTAssertEqual(handler.nvimKey(for: keyEvent("\u{f728}", ignoringModifiers: "\u{f728}", keyCode: 117)), "<Del>")
    }

    func testShiftTabProducesNotation() {
        let event = keyEvent("\u{19}", ignoringModifiers: "\t", keyCode: 48, modifiers: [.shift])
        XCTAssertEqual(handler.nvimKey(for: event), "<S-Tab>")
    }

    func testKeypadOperatorsProduceNotation() {
        XCTAssertEqual(handler.nvimKey(for: keyEvent("+", ignoringModifiers: "+", keyCode: 69)), "<kPlus>")
        XCTAssertEqual(handler.nvimKey(for: keyEvent("-", ignoringModifiers: "-", keyCode: 78)), "<kMinus>")
        XCTAssertEqual(handler.nvimKey(for: keyEvent("*", ignoringModifiers: "*", keyCode: 67)), "<kMultiply>")
        XCTAssertEqual(handler.nvimKey(for: keyEvent("/", ignoringModifiers: "/", keyCode: 75)), "<kDivide>")
    }

    func testKeypadEnterProducesCR() {
        let event = keyEvent("\r", ignoringModifiers: "\r", keyCode: 76)
        XCTAssertEqual(handler.nvimKey(for: event), "<CR>")
    }

    func testCommandKeyIsIgnoredByDefault() {
        let event = keyEvent("k", ignoringModifiers: "k", keyCode: 40, modifiers: [.command])
        XCTAssertNil(handler.nvimKey(for: event))
    }

    func testCapsLockIsNotAModifier() {
        let event = keyEvent("\u{1}", ignoringModifiers: "a", keyCode: 0, modifiers: [.control, .capsLock])
        XCTAssertEqual(handler.nvimKey(for: event), "<C-a>")
    }

    func testNonAsciiModifierBaseIsIgnored() {
        // A control combination that resolves to a non-ASCII base has no
        // notation; the IME path handles it.
        let event = keyEvent("å", ignoringModifiers: "å", keyCode: 0, modifiers: [.control])
        XCTAssertNil(handler.nvimKey(for: event))
    }

    private func keyEvent(
        _ characters: String,
        ignoringModifiers: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: ignoringModifiers,
            keyCode: keyCode,
            isARepeat: false
        )!
    }
}
