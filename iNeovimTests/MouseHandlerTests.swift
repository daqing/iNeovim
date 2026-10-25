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

    func testCellLocationAccountsForCmdlineGap() {
        // The last row starts at 23 * 20 + 4 = 464; the 4pt gap band above it
        // still belongs to the statusline row.
        let belowGap = MouseHandler.cellLocation(
            for: CGPoint(x: 0, y: 465),
            cellSize: cellSize,
            gridWidth: 80,
            gridHeight: 24
        )
        XCTAssertEqual(belowGap.row, 23)

        let inGap = MouseHandler.cellLocation(
            for: CGPoint(x: 0, y: 462),
            cellSize: cellSize,
            gridWidth: 80,
            gridHeight: 24
        )
        XCTAssertEqual(inGap.row, 22)
    }

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

    func testSingleClickQueuesChangedFileReloadAfterMouseRelease() async {
        let dispatcher = InputDispatcher()
        let (handler, view) = makeMouseHandler(dispatcher: dispatcher)
        let stream = await dispatcher.makeStream()
        let point = textPoint(view: view, row: 2, col: 5)

        handler.mouseDown(mouseEvent(.leftMouseDown, location: point))
        handler.mouseUp(mouseEvent(.leftMouseUp, location: point))

        let events = await collectEvents(from: stream)
        XCTAssertEqual(events, [
            .mouse(button: "left", action: "press", modifier: "", grid: 1, row: 2, col: 5),
            .mouse(button: "left", action: "release", modifier: "", grid: 1, row: 2, col: 5),
            .reloadChangedFile(row: 2, col: 5),
        ])
    }

    func testDragDoesNotQueueChangedFileReload() async {
        let dispatcher = InputDispatcher()
        let (handler, view) = makeMouseHandler(dispatcher: dispatcher)
        let stream = await dispatcher.makeStream()
        let start = textPoint(view: view, row: 2, col: 5)
        let end = textPoint(view: view, row: 2, col: 6)

        handler.mouseDown(mouseEvent(.leftMouseDown, location: start))
        handler.mouseDragged(mouseEvent(.leftMouseDragged, location: end))
        handler.mouseUp(mouseEvent(.leftMouseUp, location: end))

        let events = await collectEvents(from: stream)
        XCTAssertEqual(events, [
            .mouse(button: "left", action: "press", modifier: "", grid: 1, row: 2, col: 5),
            .mouse(button: "left", action: "drag", modifier: "", grid: 1, row: 2, col: 6),
            .mouse(button: "left", action: "release", modifier: "", grid: 1, row: 2, col: 6),
        ])
    }

    func testDoubleClickDoesNotQueueChangedFileReload() async {
        let dispatcher = InputDispatcher()
        let (handler, view) = makeMouseHandler(dispatcher: dispatcher)
        let stream = await dispatcher.makeStream()
        let point = textPoint(view: view, row: 2, col: 5)

        handler.mouseDown(mouseEvent(.leftMouseDown, location: point, clickCount: 2))
        handler.mouseUp(mouseEvent(.leftMouseUp, location: point, clickCount: 2))

        let events = await collectEvents(from: stream)
        XCTAssertEqual(events, [
            .mouse(button: "left", action: "press", modifier: "", grid: 1, row: 2, col: 5),
            .mouse(button: "left", action: "release", modifier: "", grid: 1, row: 2, col: 5),
        ])
    }

    private func makeMouseHandler(dispatcher: InputDispatcher) -> (MouseHandler, TerminalView) {
        let view = TerminalView(model: AppModel(inputDispatcher: dispatcher))
        let handler = MouseHandler(dispatcher: dispatcher)
        handler.view = view
        return (handler, view)
    }

    private func textPoint(view: TerminalView, row: Int, col: Int) -> CGPoint {
        CGPoint(
            x: view.leadingContentInset + (CGFloat(col) + 0.5) * view.metrics.cellSize.width,
            y: TerminalView.contentInset + (CGFloat(row) + 0.5) * view.metrics.cellSize.height
        )
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
