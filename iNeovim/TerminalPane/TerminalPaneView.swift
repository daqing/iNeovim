import AppKit
import GhosttySupport

/// One native terminal pane: a slim header (title + close button) above a
/// Ghostty surface. The surface close cycle — the child exiting, or a close
/// request from the button, ⌃`, or the window closing — ends in `onClose`,
/// which the split container uses to remove the pane.
final class TerminalPaneView: NSView {
    static let headerHeight: CGFloat = 26

    var onClose: (() -> Void)?

    let surfaceView: Ghostty.SurfaceView
    private let closeButton = NSButton()
    private let titleLabel = NSTextField(labelWithString: "terminal")

    /// Set once a close has been requested; the next close callback (even
    /// with the child still alive) finishes the teardown instead of asking
    /// the surface to force-close again.
    private var closeRequested = false

    init(surfaceView: Ghostty.SurfaceView) {
        self.surfaceView = surfaceView
        super.init(frame: .zero)
        wantsLayer = true

        titleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        titleLabel.textColor = .secondaryLabelColor
        addSubview(titleLabel)

        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close terminal")
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeButtonClicked)
        addSubview(closeButton)

        addSubview(surfaceView)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(surfaceCloseRequested(_:)),
            name: Ghostty.Notification.ghosttyCloseSurface,
            object: surfaceView
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        relayout()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    private func relayout() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        closeButton.frame = NSRect(x: bounds.width - 28, y: 3, width: 24, height: 20)
        let titleSize = titleLabel.fittingSize
        titleLabel.frame = NSRect(x: 10, y: 5, width: titleSize.width, height: titleSize.height)
        surfaceView.frame = NSRect(
            x: 0,
            y: Self.headerHeight,
            width: bounds.width,
            height: bounds.height - Self.headerHeight
        )
        // The surface does not observe its own frame; feed it the point
        // size it occupies so the terminal grid matches the view.
        surfaceView.sizeDidChange(surfaceView.bounds.size)
    }

    /// Begin the close cycle from outside (⌃`, the menu, a close intent).
    func requestClose() {
        closeRequested = true
        GhosttyTerminalController.shared.requestClose(surfaceView)
    }

    @objc private func closeButtonClicked() {
        requestClose()
    }

    /// libghostty reports a pending surface close here. With the child
    /// still alive this is the "confirm quit" hook; the pane always closes,
    /// so request once more to force, and finish on the next callback.
    @objc private func surfaceCloseRequested(_ note: Notification) {
        let alive = note.userInfo?["process_alive"] as? Bool ?? false
        if alive, !closeRequested {
            closeRequested = true
            GhosttyTerminalController.shared.requestClose(surfaceView)
            return
        }
        onClose?()
    }

    /// Immediate teardown when the hosting window goes away; the surface
    /// is freed once the view graph releases it.
    func destroy() {
        NotificationCenter.default.removeObserver(self)
        surfaceView.removeFromSuperview()
        removeFromSuperview()
    }
}
