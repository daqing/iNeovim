import AppKit
import QuartzCore

/// Small centered HUD shown after a keyboard focus switch, so ⌘L / ⌘R
/// report where focus went even when nothing else visibly moves. Clicks fall
/// through to the views underneath.
@MainActor
final class FocusToastView: NSView {
    private static let horizontalPadding: CGFloat = 16
    private static let verticalPadding: CGFloat = 8
    private static let cornerRadius: CGFloat = 10
    private static let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    private static let unboundedRect = NSRect(
        x: 0,
        y: 0,
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
    )

    private let effect = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "")
    private var hideTask: Task<Void, Never>?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.opacity = 0
        effect.material = .popover
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.masksToBounds = true
        effect.layer?.cornerRadius = Self.cornerRadius
        addSubview(effect)
        label.font = Self.font
        label.textColor = .labelColor
        effect.addSubview(label)
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// Resize to the label, fade in, hold briefly, and fade back out. A new
    /// message restarts the cycle from the current opacity.
    func show(_ text: String) {
        label.stringValue = text
        let measured = label.cell?.cellSize(forBounds: Self.unboundedRect) ?? .zero
        let textSize = CGSize(width: ceil(measured.width), height: ceil(measured.height))
        let size = CGSize(
            width: textSize.width + Self.horizontalPadding * 2,
            height: textSize.height + Self.verticalPadding * 2
        )
        setFrameSize(size)
        effect.frame = bounds
        label.frame = CGRect(
            x: Self.horizontalPadding,
            y: Self.verticalPadding,
            width: textSize.width,
            height: textSize.height
        )
        isHidden = false
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.fade(to: 1, duration: 0.12)
            try? await Task.sleep(for: .seconds(0.9))
            guard !Task.isCancelled else { return }
            self.fade(to: 0, duration: 0.25)
            try? await Task.sleep(for: .seconds(0.25))
            guard !Task.isCancelled else { return }
            self.isHidden = true
        }
    }

    private func fade(to opacity: Float, duration: CFTimeInterval) {
        guard let layer else { return }
        let from = layer.presentation()?.opacity ?? layer.opacity
        layer.removeAnimation(forKey: "opacity")
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = opacity
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.opacity = opacity
        layer.add(animation, forKey: "opacity")
    }
}
