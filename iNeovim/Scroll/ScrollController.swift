import AppKit

/// Translates `scrollWheel` events into pixel offsets for the animator plus
/// whole-line wheel requests for Neovim, then folds the `grid_scroll` events
/// Neovim answers with back into the offset (see `ScrollAccumulator`).
///
/// Trackpad gestures report `NSEventPhase` directly. Traditional wheel events
/// carry no phase, so an idle timer synthesizes the "ended" transition and
/// the momentum-like glide is the animator's decay.
final class ScrollController {
    /// How long after a gesture ends its unconfirmed lead may still be
    /// claimed by in-flight `grid_scroll` events before snapping back.
    static let confirmationGrace: Duration = .milliseconds(250)

    weak var view: TerminalView?
    private var accumulator = ScrollAccumulator()
    private var wheelEndTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var gestureActive = false
    /// Whether incoming `grid_scroll` events are scroll catch-up; background
    /// redraws (Ctrl-D, insert-mode scrolls) must not move the offset.
    private var acceptConfirmations = false
    private var lastPointerLocation: CGPoint = .zero
    private var lastModifierFlags: NSEvent.ModifierFlags = []

    /// Visual scroll offset sink, in points (y down); the second argument
    /// asks for an animated chase (gesture ended) vs. direct application.
    var onOffsetChange: ((CGFloat, Bool) -> Void)?

    func scrollWheel(with event: NSEvent) {
        guard let view else { return }
        let lineHeight = view.metrics.cellSize.height
        let rawDelta = event.scrollingDeltaY
        guard rawDelta != 0, rawDelta.isFinite else { return }
        lastPointerLocation = view.convert(event.locationInWindow, from: nil)
        lastModifierFlags = event.modifierFlags

        if event.hasPreciseScrollingDeltas {
            if event.phase == .began || (event.momentumPhase == .began && !gestureActive) {
                beginGesture()
            }
            apply(delta: rawDelta, lineHeight: lineHeight)
            // A phase ended without momentum can be followed by a momentum
            // began, so close the gesture on a short delay that a momentum
            // start cancels.
            if event.momentumPhase == .ended
                || (event.phase == .ended && event.momentumPhase == .none) {
                scheduleWheelEnd()
            } else {
                wheelEndTask?.cancel()
            }
        } else {
            // Wheel ticks arrive as discrete events with phase .none; batch
            // them into one gesture and end it shortly after the last tick.
            if !gestureActive { beginGesture() }
            apply(delta: rawDelta * lineHeight, lineHeight: lineHeight)
            scheduleWheelEnd()
        }
    }

    /// A `grid_scroll` Neovim applied to grid 1 while our scroll was in
    /// flight; shrinks the visual lead so the content does not jump.
    func confirmScroll(rows: Int) {
        guard acceptConfirmations, let view else { return }
        accumulator.confirmScroll(rows: rows, lineHeight: view.metrics.cellSize.height)
        onOffsetChange?(accumulator.offset, true)
    }

    private func beginGesture() {
        wheelEndTask?.cancel()
        settleTask?.cancel()
        gestureActive = true
        acceptConfirmations = true
        accumulator.beginGesture()
    }

    private func apply(delta: CGFloat, lineHeight: CGFloat) {
        let requests = accumulator.addDelta(delta, lineHeight: lineHeight)
        send(requests)
        onOffsetChange?(accumulator.offset, false)
    }

    private func send(_ requests: [ScrollLineRequest]) {
        guard let view, !requests.isEmpty else { return }
        // The pointer cell targets the window Neovim scrolls.
        let dimensions = view.gridDimensions
        let (row, col) = MouseHandler.cellLocation(
            for: lastPointerLocation,
            cellSize: view.metrics.cellSize,
            gridWidth: dimensions?.width,
            gridHeight: dimensions?.height
        )
        let modifier = MouseHandler.modifierString(for: lastModifierFlags)
        for request in requests {
            let button: String
            switch request {
            case .up: button = "wheelup"
            case .down: button = "wheeldown"
            }
            InputDispatcher.shared.send(.mouse(
                button: button,
                action: "press",
                modifier: modifier,
                grid: 1,
                row: row,
                col: col
            ))
        }
    }

    private func scheduleWheelEnd() {
        wheelEndTask?.cancel()
        wheelEndTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, !Task.isCancelled else { return }
            self.endGesture()
        }
    }

    private func endGesture() {
        gestureActive = false
        onOffsetChange?(accumulator.offset, true)
        guard accumulator.offset != 0 else {
            acceptConfirmations = false
            return
        }
        // Give in-flight wheel round-trips a grace window to claim the lead;
        // whatever is left afterwards snaps back.
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.confirmationGrace)
            guard let self, !Task.isCancelled else { return }
            self.acceptConfirmations = false
            self.accumulator.collapse()
            self.onOffsetChange?(self.accumulator.offset, true)
        }
    }
}
