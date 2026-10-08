import AppKit
import XCTest
@testable import iNeovim

@MainActor
final class MouseHandlerTests: XCTestCase {
    private let cellSize = CGSize(width: 10, height: 20)

    func testCellLocationMapsPointToCell() {
        let location = MouseHandler.cellLocation(
            for: CGPoint(x: 25, y: 45),
            cellSize: cellSize,
            gridWidth: 80,
            gridHeight: 24
        )
        XCTAssertEqual(location.row, 2)
        XCTAssertEqual(location.col, 2)
    }

    func testCellLocationClampsToGrid() {
        let location = MouseHandler.cellLocation(
            for: CGPoint(x: 10_000, y: -50),
            cellSize: cellSize,
            gridWidth: 80,
            gridHeight: 24
        )
        XCTAssertEqual(location.row, 0)
        XCTAssertEqual(location.col, 79)
    }

    func testCellLocationWithoutGridIsNotClampedAbove() {
        let location = MouseHandler.cellLocation(
            for: CGPoint(x: 250, y: 90),
            cellSize: cellSize,
            gridWidth: nil,
            gridHeight: nil
        )
        XCTAssertEqual(location.row, 4)
        XCTAssertEqual(location.col, 25)
    }

    func testModifierStringOrder() {
        let flags: NSEvent.ModifierFlags = [.shift, .command]
        XCTAssertEqual(MouseHandler.modifierString(for: flags), "SM")
    }

    func testModifierStringEmpty() {
        XCTAssertEqual(MouseHandler.modifierString(for: []), "")
    }

    func testModifierStringIgnoresCapsLock() {
        let flags: NSEvent.ModifierFlags = [.shift, .capsLock]
        XCTAssertEqual(MouseHandler.modifierString(for: flags), "S")
    }

    func testModifierStringAll() {
        let flags: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        XCTAssertEqual(MouseHandler.modifierString(for: flags), "SCAM")
    }

    func testButtonNames() {
        XCTAssertEqual(MouseHandler.buttonName(for: mouseEvent(.leftMouseDown)), "left")
        XCTAssertEqual(MouseHandler.buttonName(for: mouseEvent(.rightMouseDown)), "right")
        XCTAssertEqual(MouseHandler.buttonName(for: mouseEvent(.otherMouseDown)), "middle")
        let keyEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        )!
        XCTAssertNil(MouseHandler.buttonName(for: keyEvent))
    }

    private func mouseEvent(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )!
    }
}
