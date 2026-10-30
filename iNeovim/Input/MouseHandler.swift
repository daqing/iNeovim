import AppKit

/// Translates mouse events into `nvim_input_mouse` calls carrying the grid
/// the pointer is actually over (multigrid hit-testing) and cell coordinates
/// local to that grid. Dragging extends selections because nvim treats
/// "drag" actions as selection extension.
final class MouseHandler {
    /// The gutter cells (sign column) where a plain left click opens the
    /// diagnostics popover instead of moving nvim's cursor.
    static let signColumnMaxCol = 1

    weak var view: TerminalView?
    private let dispatcher: InputDispatcher
    private var pressedButton: String?
    private var pressedHit: TerminalView.GridHit?
    private var pressedClick = false
    private var didDrag = false
    /// The current gesture was routed to the diagnostics popover; its drag
    /// and release must not reach nvim as orphans.
    private var isSwallowingGesture = false

    init(dispatcher: InputDispatcher) {
        self.dispatcher = dispatcher
    }

    func mouseDown(_ event: NSEvent) {
        guard let button = Self.buttonName(for: event) else { return }
        view?.window?.makeFirstResponder(view)
        pressedButton = button
        pressedHit = hitLocation(for: event)
        pressedClick = button == "left" && event.clickCount == 1
            && Self.modifierString(for: event.modifierFlags).isEmpty
        didDrag = false
        // ⌘-click on an http(s) URL opens it in the default browser instead of
        // reaching nvim; the rest of the gesture is swallowed so nvim never
        // sees an orphan drag/release.
        if button == "left",
           event.modifierFlags.contains(.command),
           let hit = pressedHit,
           let url = view?.linkTarget(at: hit) {
            isSwallowingGesture = true
            _ = NSWorkspace.shared.open(url)
            return
        }
        if button == "left",
           Self.modifierString(for: event.modifierFlags).isEmpty,
           let hit = pressedHit,
           hit.col <= Self.signColumnMaxCol {
            isSwallowingGesture = true
            view?.presentDiagnostics(at: hit)
            return
        }
        handle(event, button: button, action: "press")
    }

    func mouseDragged(_ event: NSEvent) {
        guard let pressedButton else { return }
        didDrag = true
        guard !isSwallowingGesture else { return }
        handle(event, button: pressedButton, action: "drag")
    }

    func mouseUp(_ event: NSEvent) {
        guard let pressedButton else { return }
        self.pressedButton = nil
        let hit = pressedHit
        let wasSwallowing = isSwallowingGesture
        let plainClick = pressedClick && !didDrag && !wasSwallowing
        pressedHit = nil
        pressedClick = false
        didDrag = false
        if wasSwallowing {
            isSwallowingGesture = false
        } else {
            handle(event, button: pressedButton, action: "release")
        }
        if plainClick, let hit {
            dispatcher.send(.reloadChangedFile(row: hit.globalRow, col: hit.globalCol))
            // A plain click on a truncated line's preview row (not the
            // gutter, which belongs to the diagnostics popover) opens the
            // full line in a popover. The click itself has already reached
            // nvim; the popover never blocks it.
            if hit.col > Self.signColumnMaxCol {
                Task { @MainActor in
                    await self.view?.presentLineContentIfTruncated(at: hit)
                }
            }
        }
    }

    private func handle(_ event: NSEvent, button: String, action: String) {
        guard let hit = hitLocation(for: event) else { return }
        let modifier = Self.modifierString(for: event.modifierFlags)
        dispatcher.send(.mouse(
            button: button,
            action: action,
            modifier: modifier,
            grid: hit.grid,
            row: hit.row,
            col: hit.col
        ))
    }

    /// The grid and cell under the event's location, or nil before the
    /// session has laid out a grid.
    private func hitLocation(for event: NSEvent) -> TerminalView.GridHit? {
        guard let view else { return nil }
        let point = view.convert(event.locationInWindow, from: nil)
        return view.gridHit(forViewPoint: point)
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
}
