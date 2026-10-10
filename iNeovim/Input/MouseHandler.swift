import AppKit

/// Translates mouse events into `nvim_input_mouse` calls on grid 1.
/// Dragging extends selections because nvim treats "drag" actions as
/// selection extension.
final class MouseHandler {
    weak var view: TerminalView?
    private let dispatcher: InputDispatcher
    private var pressedButton: String?

    init(dispatcher: InputDispatcher) {
        self.dispatcher = dispatcher
    }

    func mouseDown(_ event: NSEvent) {
        guard let button = Self.buttonName(for: event) else { return }
        view?.window?.makeFirstResponder(view)
        pressedButton = button
        handle(event, button: button, action: "press")
    }

    func mouseDragged(_ event: NSEvent) {
        guard let pressedButton else { return }
        handle(event, button: pressedButton, action: "drag")
    }

    func mouseUp(_ event: NSEvent) {
        guard let pressedButton else { return }
        self.pressedButton = nil
        handle(event, button: pressedButton, action: "release")
    }

    private func handle(_ event: NSEvent, button: String, action: String) {
        guard let view else { return }
        let point = view.convert(event.locationInWindow, from: nil)
        // The grid starts contentInset into the view; convert to grid space
        // before dividing into cells.
        let gridPoint = CGPoint(
            x: point.x - TerminalView.contentInset,
            y: point.y - TerminalView.contentInset
        )
        let dimensions = view.gridDimensions
        let (row, col) = Self.cellLocation(
            for: gridPoint,
            cellSize: view.metrics.cellSize,
            gridWidth: dimensions?.width,
            gridHeight: dimensions?.height
        )
        let modifier = Self.modifierString(for: event.modifierFlags)
        dispatcher.send(.mouse(
            button: button,
            action: action,
            modifier: modifier,
            grid: 1,
            row: row,
            col: col
        ))
    }

    static func buttonName(for event: NSEvent) -> String? {
        switch event.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp: return "left"
        case .rightMouseDown, .rightMouseDragged, .rightMouseUp: return "right"
        case .otherMouseDown, .otherMouseDragged, .otherMouseUp: return "middle"
        default: return nil
        }
    }

    /// nvim mouse modifier string: shift S, control C, option A, command M.
    static func modifierString(for flags: NSEvent.ModifierFlags) -> String {
        let flags = flags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function])
        var result = ""
        if flags.contains(.shift) { result += "S" }
        if flags.contains(.control) { result += "C" }
        if flags.contains(.option) { result += "A" }
        if flags.contains(.command) { result += "M" }
        return result
    }

    /// View point (y-down, flipped view) to grid cell, clamped to the grid.
    /// Row mapping goes through `TerminalView.gridRow` so the gap above the
    /// cmdline row is accounted for.
    static func cellLocation(
        for point: CGPoint,
        cellSize: CGSize,
        gridWidth: Int?,
        gridHeight: Int?
    ) -> (row: Int, col: Int) {
        let col = min(max(Int(point.x / cellSize.width), 0), gridWidth.map { $0 - 1 } ?? .max)
        let row: Int
        if let gridHeight {
            row = TerminalView.gridRow(
                atY: point.y,
                gridHeight: gridHeight,
                cellHeight: cellSize.height
            )
        } else {
            row = max(Int(point.y / cellSize.height), 0)
        }
        return (row, col)
    }
}
