import AppKit

/// Translates `scrollWheel` events into pixel offsets (and, from T7.3,
/// whole-line wheel requests for Neovim).
///
/// Trackpad gestures report `NSEventPhase` directly. Traditional wheel events
/// carry no phase, so an idle timer synthesizes the "ended" transition and
/// the gesture is closed once ticks stop arriving — the momentum-like glide
/// is the animator's decay (T7.2).
final class ScrollController {
    weak var view: TerminalView?
    private var accumulator = ScrollAccumulator()
    private var wheelEndTask: Task<Void, Never>?
    private var gestureActive = false

    /// Visual scroll offset sink, in points (y down).
    var onOffsetChange: ((CGFloat) -> Void)?

    func scrollWheel(with event: NSEvent) {
        let lineHeight = view?.metrics.cellSize.height ?? 1
        let rawDelta = event.scrollingDeltaY
        guard rawDelta != 0, rawDelta.isFinite else { return }

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

    private func beginGesture() {
        wheelEndTask?.cancel()
        gestureActive = true
        accumulator.beginGesture()
    }

    private func apply(delta: CGFloat, lineHeight: CGFloat) {
        _ = accumulator.addDelta(delta, lineHeight: lineHeight)
        onOffsetChange?(accumulator.offset)
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
        accumulator.collapse()
        onOffsetChange?(accumulator.offset)
    }
}
