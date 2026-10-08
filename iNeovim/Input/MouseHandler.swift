import AppKit

/// Translates mouse events into `nvim_input_mouse` calls on grid 1.
/// Dragging extends selections because nvim treats "drag" actions as
/// selection extension.
final class MouseHandler {
    weak var view: TerminalView?
    private var pressedButton: String?

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
        let dimensions = view.gridDimensions
        let location = Self.cellLocation(
            for: point,
            cellSize: view.metrics.cellSize,
            gridWidth: dimensions?.width,
            gridHeight: dimensions?.height
        )
        let modifier = Self.modifierString(for: event.modifierFlags)
        let (row, col) = location
        Task {
            do {
                try await NvimClient().inputMouse(
                    button: button,
                    action: action,
                    modifier: modifier,
                    grid: 1,
                    row: row,
                    col: col
                )
            } catch {
                Log.input.error("nvim_input_mouse failed: \(error.localizedDescription, privacy: .public)")
            }
        }
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
        var result = ""
        if flags.contains(.shift) { result += "S" }
        if flags.contains(.control) { result += "C" }
        if flags.contains(.option) { result += "A" }
        if flags.contains(.command) { result += "M" }
        return result
    }

    /// View point (y-down, flipped view) to grid cell, clamped to the grid.
    static func cellLocation(
        for point: CGPoint,
        cellSize: CGSize,
        gridWidth: Int?,
        gridHeight: Int?
    ) -> (row: Int, col: Int) {
        let col = min(max(Int(point.x / cellSize.width), 0), gridWidth.map { $0 - 1 } ?? .max)
        let row = min(max(Int(point.y / cellSize.height), 0), gridHeight.map { $0 - 1 } ?? .max)
        return (row, col)
    }
}
