import AppKit

/// Translates `scrollWheel` events into pixel offsets plus whole-line wheel
/// requests for Neovim, then folds the `grid_scroll` events Neovim answers
/// with back into the offset (see `ScrollAccumulator`).
///
/// Trackpad gestures report `NSEventPhase` directly. Traditional wheel events
/// carry no phase, so an idle timer synthesizes the "ended" transition. The
/// content follows both 1:1 while the gesture lasts; the animator only eases
/// the unconfirmed lead back to rest afterwards.
final class ScrollController {
    weak var view: TerminalView?
    var settings = ScrollAnimationSettings.default
    private let dispatcher: InputDispatcher
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

    init(dispatcher: InputDispatcher) {
        self.dispatcher = dispatcher
    }

    func scrollWheel(with event: NSEvent) {
        guard let view else { return }
        let lineHeight = view.metrics.cellSize.height
        let rawDelta = event.scrollingDeltaY
        guard rawDelta != 0, rawDelta.isFinite else { return }
        updateLeadCap()
        let viewPoint = view.convert(event.locationInWindow, from: nil)
        // Grid space starts contentInset into the view (see MouseHandler).
        lastPointerLocation = CGPoint(
            x: viewPoint.x - TerminalView.contentInset,
            y: viewPoint.y - TerminalView.contentInset
        )
        lastModifierFlags = event.modifierFlags

        if event.hasPreciseScrollingDeltas {
            // The gesture must be open before the first delta it carries: a
            // `began` (or momentum `began`) phase that reports no movement
            // returns above without opening it, and a gesture opened late
            // ignores the confirmations answering it, so the lead would grow
            // against a stationary grid.
            if !gestureActive || event.phase == .began || event.momentumPhase == .began {
                beginGesture()
            }
            apply(delta: rawDelta, lineHeight: lineHeight)
            // A phase ended without momentum can be followed by a momentum
            // began, so close the gesture on a short delay that a momentum
            // start cancels. (`.none` would resolve to Optional.none and
            // compare against nil; an unset phase is the empty set.)
            if event.momentumPhase == .ended
                || (event.phase == .ended && event.momentumPhase.isEmpty) {
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
    ///
    /// Only the accumulator moves here. The offset that goes with the
    /// confirmation is applied by `applyConfirmedOffset`, after the flush
    /// carrying it has repainted the grid: the grid moved by exactly the
    /// confirmed amount and the lead shrank by the same amount, so swapping
    /// both in one frame leaves the content exactly where the gesture had it.
    /// Applying the offset here (a task earlier) or easing it back over later
    /// frames would show the content sliding against the gesture for a frame
    /// or more.
    func confirmScroll(rows: Int) {
        guard acceptConfirmations, let view else { return }
        accumulator.confirmScroll(rows: rows, lineHeight: view.metrics.cellSize.height)
    }

    /// Apply a confirmation's offset change, if any, immediately after the
    /// flush that carried it has repainted the grid. Called by the view at the
    /// end of its flush apply so the new grid and the offset that belongs to
    /// it are presented in the same frame instead of a frame apart.
    func applyConfirmedOffset() {
        guard acceptConfirmations else { return }
        onOffsetChange?(accumulator.offset, false)
    }

    /// Allow at most one cell of visual lead. Neovim only sends the visible
    /// screenful, so a whole-line lead already exposes undrawn space; the cap
    /// keeps the content from getting more than one wheel step ahead of it.
    private func updateLeadCap() {
        guard let view else { return }
        accumulator.maxLead = max(1, view.metrics.cellSize.height)
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
            let wheel = request.wheelButton
            dispatcher.send(.mouse(
                button: wheel.button,
                action: wheel.action,
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
            try? await Task.sleep(for: self?.settings.confirmationGrace ?? .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.acceptConfirmations = false
            self.accumulator.collapse()
            self.onOffsetChange?(self.accumulator.offset, true)
        }
    }
}
