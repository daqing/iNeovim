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
    private var pressedLocation: CGPoint?
    /// The current gesture was routed to the diagnostics popover; its drag
    /// and release must not reach nvim as orphans.
    private var isSwallowingGesture = false
    /// A plain left click awaiting preview-row resolution: the press is
    /// held back until the query answers, because a forwarded click can
    /// scroll nvim and invalidate the very row the query inspects. Sub-
    /// millisecond locally; drags arriving meanwhile are replayed after a
    /// nil answer.
    private var gatedPress: (hit: TerminalView.GridHit, button: String, modifier: String)?
    private var gatedTask: Task<Void, Never>?
    private var latestGatedDrag: (grid: Int, row: Int, col: Int)?
    /// Pointer travel below this is click jitter, not a drag: AppKit
    /// delivers `leftMouseDragged` for sub-pixel wobble on some mice, which
    /// used to cancel plain clicks (and their popovers) at random.
    static let dragThreshold: CGFloat = 3

    init(dispatcher: InputDispatcher) {
        self.dispatcher = dispatcher
    }

    func mouseDown(_ event: NSEvent) {
        guard let button = Self.buttonName(for: event) else { return }
        view?.window?.makeFirstResponder(view)
        pressedButton = button
        pressedHit = hitLocation(for: event)
        pressedLocation = view?.convert(event.locationInWindow, from: nil)
        pressedClick = button == "left" && event.clickCount == 1
            && Self.modifierString(for: event.modifierFlags).isEmpty
        didDrag = false
        latestGatedDrag = nil
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
        // Plain left click on the text body: resolve the truncated-line
        // preview BEFORE the press reaches nvim (a forwarded click can
        // scroll and invalidate the clicked row). The press forwards the
        // moment the answer is nil; a preview row swallows the gesture and
        // opens the popover instead.
        if button == "left",
           pressedClick,
           let hit = pressedHit,
           hit.col > Self.signColumnMaxCol {
            gatedPress = (
                hit: hit,
                button: button,
                modifier: Self.modifierString(for: event.modifierFlags)
            )
            let view = view
            gatedTask = Task { @MainActor in
                let content = await view?.truncatedLineContent(at: hit)
                self.pressResolved(content: content)
            }
            return
        }
        handle(event, button: button, action: "press")
    }

    /// Called when the preview-row query for a gated press answers. nil
    /// forwards the held press (and any drag already recorded); text
    /// swallows the gesture and shows the popover.
    private func pressResolved(content: String?) {
        guard let gate = gatedPress else { return }
        gatedPress = nil
        gatedTask = nil
        if let content {
            isSwallowingGesture = true
            view?.presentLineContent(content, at: gate.hit)
            return
        }
        dispatcher.send(.mouse(
            button: gate.button,
            action: "press",
            modifier: gate.modifier,
            grid: gate.hit.grid,
            row: gate.hit.row,
            col: gate.hit.col
        ))
        if didDrag, let drag = latestGatedDrag {
            latestGatedDrag = nil
            dispatcher.send(.mouse(
                button: gate.button,
                action: "drag",
                modifier: "",
                grid: drag.grid,
                row: drag.row,
                col: drag.col
            ))
        }
    }

    func mouseDragged(_ event: NSEvent) {
        guard let pressedButton else { return }
        if let pressedLocation {
            let location = view?.convert(event.locationInWindow, from: nil) ?? pressedLocation
            if hypot(location.x - pressedLocation.x, location.y - pressedLocation.y) >= Self.dragThreshold {
                didDrag = true
            }
        } else {
            didDrag = true
        }
        if gatedPress != nil {
            if didDrag, let hit = hitLocation(for: event) {
                latestGatedDrag = (hit.grid, hit.row, hit.col)
            }
            return
        }
        guard didDrag, !isSwallowingGesture else { return }
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
        pressedLocation = nil
        // A release outrunning the (sub-millisecond) preview query falls
        // back to a normal click: forward the held press so nvim sees a
        // complete gesture, and let the popover go.
        if let gate = gatedPress {
            gatedTask?.cancel()
            gatedTask = nil
            gatedPress = nil
            latestGatedDrag = nil
            dispatcher.send(.mouse(
                button: gate.button,
                action: "press",
                modifier: gate.modifier,
                grid: gate.hit.grid,
                row: gate.hit.row,
                col: gate.hit.col
            ))
        }
        if wasSwallowing {
            isSwallowingGesture = false
        } else {
            handle(event, button: pressedButton, action: "release")
        }
        if plainClick, let hit {
            dispatcher.send(.reloadChangedFile(row: hit.globalRow, col: hit.globalCol))
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
