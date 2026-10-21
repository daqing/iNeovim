import AppKit

/// The transient overlay scrollbar shown while the wheel or trackpad scrolls
/// the grid: a rounded thumb at the view's right edge, over the scrolling
/// region but never the frozen footer, faded out shortly after the last delta
/// — the same show-on-scroll / hide-when-idle behavior as the system overlay
/// scrollers. Informational only; it never takes mouse events.
final class ScrollIndicator {
    /// Thumb width and its inset from the view's right edge.
    static let width: CGFloat = 6
    static let rightInset: CGFloat = 3
    /// A long buffer's thumb never gets shorter than this, so it still reads
    /// as a drag handle instead of a dot.
    static let minimumThumbHeight: CGFloat = 24
    /// Idle time before the thumb fades out, and the fade itself.
    static let hideDelay: TimeInterval = 0.7
    static let fadeDuration: TimeInterval = 0.3
    static let knobAlpha: CGFloat = 0.34

    let layer = CALayer()
    /// Viewport metrics for the window under the pointer, as of the last
    /// answered query.
    private var metrics: ScrollMetrics?
    /// The scrolling region in view space: from the content inset down to the
    /// statusline row's top edge, across the whole view (the thumb hugs the
    /// window edge, outside the inset grid).
    private var track: CGRect = .zero
    private var isDark = true
    private var scale: CGFloat = 2
    private var lastActivity: Date?
    private var hideTask: Task<Void, Never>?

    init() {
        layer.cornerRadius = Self.width / 2
        layer.opacity = 0
        layer.actions = [
            "opacity": NSNull(), "frame": NSNull(), "position": NSNull(),
            "bounds": NSNull(), "backgroundColor": NSNull(),
        ]
    }

    /// Keep the track, the knob color, and the pixel grid in step with the
    /// view's geometry and theme. Visibility only changes when there is
    /// nothing to show — an empty grid or a buffer that fits the window.
    func layout(track: CGRect, isDark: Bool, scale: CGFloat) {
        guard track != self.track || isDark != self.isDark || scale != self.scale else { return }
        self.track = track
        self.isDark = isDark
        self.scale = scale
        guard isScrollable else {
            hideTask?.cancel()
            setOpacity(0, animated: false)
            return
        }
        placeThumb()
    }

    /// A wheel or trackpad delta moved the content: show the thumb from what
    /// is already known and restart the idle timer. When no metrics have been
    /// reported yet, `setMetrics` shows it a round trip later.
    func flash() {
        lastActivity = .now
        scheduleHide()
        guard isScrollable else { return }
        placeThumb()
        setOpacity(1, animated: false)
    }

    /// Fresh viewport metrics from nvim. They can arrive after the idle timer
    /// expired (a slow round trip); then only the geometry is remembered for
    /// the next gesture and the thumb stays hidden.
    func setMetrics(_ newMetrics: ScrollMetrics?) {
        guard newMetrics != metrics else { return }
        let wasScrollable = isScrollable
        metrics = newMetrics
        guard isScrollable else {
            if wasScrollable {
                setOpacity(0, animated: true)
                hideTask?.cancel()
            }
            return
        }
        placeThumb()
        guard let lastActivity,
              Date.now.timeIntervalSince(lastActivity) < Self.hideDelay else { return }
        setOpacity(1, animated: false)
    }

    private var isScrollable: Bool {
        metrics?.isScrollable == true && !track.isEmpty
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.hideDelay))
            guard !Task.isCancelled else { return }
            self?.setOpacity(0, animated: true)
        }
    }

    private func setOpacity(_ value: Float, animated: Bool) {
        let current = layer.presentation()?.opacity ?? layer.opacity
        layer.opacity = value
        guard animated, current != value else {
            layer.removeAnimation(forKey: "opacity")
            return
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = current
        fade.toValue = value
        fade.duration = Self.fadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(fade, forKey: "opacity")
    }

    private func placeThumb() {
        guard let metrics, isScrollable else { return }
        let height = min(track.height, max(Self.minimumThumbHeight, track.height * metrics.proportion))
        let y = track.minY + metrics.position * (track.height - height)
        let x = track.maxX - Self.rightInset - Self.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = CGRect(
            x: (x * scale).rounded() / scale,
            y: (y * scale).rounded() / scale,
            width: Self.width,
            height: height
        )
        layer.backgroundColor = (isDark ? NSColor.white : NSColor.black)
            .withAlphaComponent(Self.knobAlpha).cgColor
        CATransaction.commit()
    }
}
