import Foundation

/// Interpolates the cursor's position over a short glide instead of jumping
/// between cells, driven by the display link.
final class CursorAnimator {
    private lazy var driver = DisplayLinkDriver { [weak self] timestamp in
        self?.tick(timestamp: timestamp)
    }

    /// The offset added to the logical cursor cell rect while gliding.
    private(set) var offset: CGSize = .zero

    var settings = ScrollAnimationSettings.default

    var onUpdate: (() -> Void)?

    private var glide: (from: CGSize, start: TimeInterval?)?

    /// The logical cursor cell changed: glide from its previous rect to the
    /// new one so the cursor appears to slide between cells.
    func glide(from oldRect: CGRect, to newRect: CGRect, distanceInCells: CGFloat) {
        let initial = CGSize(
            width: oldRect.minX - newRect.minX,
            height: oldRect.minY - newRect.minY
        )
        guard distanceInCells <= settings.cursorGlideMaxCells, initial != .zero else {
            snap()
            return
        }
        glide = (from: initial, start: nil)
        driver.start()
    }

    /// Stop gliding and draw the cursor at its logical cell.
    func snap() {
        glide = nil
        driver.stop()
        setOffset(.zero)
    }

    /// Linear interpolation from `from` to `.zero` at eased `progress`.
    static func interpolatedOffset(from: CGSize, progress: CGFloat) -> CGSize {
        CGSize(
            width: from.width * (1 - progress),
            height: from.height * (1 - progress)
        )
    }

    static func easeOutCubic(_ progress: CGFloat) -> CGFloat {
        1 - pow(1 - progress, 3)
    }

    private func tick(timestamp: TimeInterval) {
        guard var animation = glide else {
            driver.stop()
            return
        }
        if animation.start == nil { animation.start = timestamp }
        guard let start = animation.start else { return }
        let progress = min(1, max(0, (timestamp - start) / settings.cursorGlideDuration))
        setOffset(Self.interpolatedOffset(
            from: animation.from,
            progress: Self.easeOutCubic(progress)
        ))
        if progress >= 1 {
            glide = nil
            driver.stop()
        } else {
            glide = animation
        }
    }

    private func setOffset(_ value: CGSize) {
        guard offset != value else { return }
        offset = value
        onUpdate?()
    }
}
