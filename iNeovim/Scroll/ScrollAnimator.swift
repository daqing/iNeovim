import Foundation
import os

/// Drives the content layer's scroll offset. While a gesture is active the
/// offset is applied directly (1:1 with the wheel or trackpad), and each
/// `grid_scroll` confirmation is applied in the same turn as the repaint it
/// accounts for; the exponential chase only eases the unconfirmed lead back
/// to rest after the gesture. Time-based easing keeps the settle identical at
/// 60 Hz and 120 Hz ProMotion refresh rates.
final class ScrollAnimator {
    private lazy var driver = DisplayLinkDriver { [weak self] timestamp in
        self?.tick(timestamp: timestamp)
    }
    private var presentation: CGFloat = 0
    private var target: CGFloat = 0
    private var lastTimestamp: TimeInterval?

    var settings = ScrollAnimationSettings.default

    /// The offset currently applied to the content layer.
    private(set) var presentationOffset: CGFloat = 0

    var onUpdate: ((CGFloat) -> Void)?

    /// - Parameter animated: direct application when false (gesture active),
    ///   display-link chase when true.
    func setTarget(_ value: CGFloat, animated: Bool) {
        target = value
        // Nothing to chase: confirmations and wheel steps apply their offset
        // directly, so most targets equal the presentation, and starting a
        // display link for that costs a thread create/start plus a
        // main-thread tick — real jitter on a fast wheel. The link is only
        // started when the presentation actually has to move.
        if animated, settings.scrollEnabled, value != presentation {
            lastTimestamp = nil
            driver.start()
        } else {
            driver.stop()
            presentation = value
            emit()
        }
    }

    func stop() {
        driver.stop()
    }

    private func tick(timestamp: TimeInterval) {
        let signpost = Signpost.scroll.beginInterval("chase")
        defer { Signpost.scroll.endInterval("chase", signpost) }
        let dt = lastTimestamp.map { max(0, timestamp - $0) } ?? (1.0 / 60.0)
        lastTimestamp = timestamp
        let step = 1 - exp(-dt / settings.scrollTimeConstant)
        presentation += (target - presentation) * step
        if abs(target - presentation) < 0.25 {
            presentation = target
            driver.stop()
        }
        emit()
    }

    private func emit() {
        if presentationOffset != presentation {
            presentationOffset = presentation
            onUpdate?(presentation)
        }
    }
}
