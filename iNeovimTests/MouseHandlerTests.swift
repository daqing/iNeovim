import AppKit
import XCTest
@testable import iNeovim

@MainActor
final class MouseHandlerTests: XCTestCase {
    private let cellSize = CGSize(width: 10, height: 20)

    func testGridRowYShiftsCmdlineRow() {
        XCTAssertEqual(TerminalView.gridRowY(22, gridHeight: 24, cellHeight: 20), 440)
        XCTAssertEqual(TerminalView.gridRowY(23, gridHeight: 24, cellHeight: 20), 465)
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

    private func makeMouseHandler(dispatcher: InputDispatcher) -> (MouseHandler, TerminalView) {
        let view = TerminalView(model: AppModel(inputDispatcher: dispatcher))
        let handler = MouseHandler(dispatcher: dispatcher)
        handler.view = view
        return (handler, view)
    }

    private func collectEvents(from stream: AsyncStream<InputEvent>) async -> [InputEvent] {
        let collector = Task.detached {
            var events: [InputEvent] = []
            for await event in stream {
                events.append(event)
            }
            return events
        }
        try? await Task.sleep(for: .milliseconds(20))
        collector.cancel()
        return await collector.value
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        location: CGPoint = .zero,
        modifiers: NSEvent.ModifierFlags = [],
        clickCount: Int = 1
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 0
        )!
    }
}
