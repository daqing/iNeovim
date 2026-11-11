import AppKit
import QuartzCore

/// Small centered HUD for short confirmations: keyboard focus switches (⌘L /
/// ⌘R report where focus went even when nothing else visibly moves) and
/// mouse-selection copies. Clicks fall through to the views underneath.
@MainActor
final class FocusToastView: NSView {
    private static let font = NSFont.systemFont(ofSize: 12, weight: .medium)
    private static let iconGap: CGFloat = 2
    private static let unboundedRect = NSRect(
        x: 0,
        y: 0,
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
    )

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var hideTask: Task<Void, Never>?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.opacity = 0
        icon.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: Self.font.pointSize, weight: .medium))
        icon.contentTintColor = .secondaryLabelColor
        addSubview(icon)
        label.font = Self.font
        label.textColor = .secondaryLabelColor
        addSubview(label)
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
        let iconSize = icon.image?.size ?? .zero
        let size = CGSize(
            width: ceil(iconSize.width) + Self.iconGap + textSize.width,
            height: max(ceil(iconSize.height), textSize.height)
        )
        setFrameSize(size)
        icon.frame = CGRect(
            x: 0,
            y: (size.height - iconSize.height) / 2,
            width: iconSize.width,
            height: iconSize.height
        )
        label.frame = CGRect(
            x: ceil(iconSize.width) + Self.iconGap,
            y: (size.height - textSize.height) / 2,
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
