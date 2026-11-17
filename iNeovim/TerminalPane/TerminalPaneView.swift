import AppKit
import GhosttySupport

/// One native terminal pane: a Ghostty surface plus the close-cycle
/// plumbing. The pane column's tab bar hosts several of these — the +
/// right of the tabs opens another terminal tab, ⌘⇧D splits one below
/// another, and there are no per-pane close buttons. The surface
/// close cycle — the child exiting, a ⌘D close intent, or the window
/// closing — ends in `onClose`, which the column uses to remove the pane.
final class TerminalPaneView: NSView {
    /// Left inset of the surface's text content. Mirrored in the generated
    /// Ghostty config (`window-padding-x`) and in the column tab bar's
    /// glyph so all three start on the same column.
    static let contentInset: CGFloat = 8

    var onClose: (() -> Void)?

    let surfaceView: Ghostty.SurfaceView

    /// Directory the pane opened in; a split or new tab falls back to it
    /// when neither the foreground process nor OSC 7 reports a directory.
    let initialDirectory: String

    /// The directory a new tab or split should start in: the foreground
    /// process's cwd (which follows `cd` even though shell integration is
    /// off), else the shell's OSC 7 pwd, else the opening directory.
    var currentDirectory: String {
        if let pid = surfaceView.foregroundPID,
           let path = ProcessWorkingDirectory.path(of: pid) {
            return path
        }
        if let pwd = surfaceView.pwd, !pwd.isEmpty {
            // Some shells report OSC 7 as a file:// URL; the surface config
            // wants a plain path.
            if pwd.hasPrefix("file://"), let url = URL(string: pwd) {
                return url.path
            }
            return pwd
        }
        return initialDirectory
    }

    /// Set once a close has been requested; the next close callback (even
    /// with the child still alive) finishes the teardown instead of asking
    /// the surface to force-close again.
    private var closeRequested = false

    init(surfaceView: Ghostty.SurfaceView, initialDirectory: String = "") {
        self.surfaceView = surfaceView
        self.initialDirectory = initialDirectory
        super.init(frame: .zero)
        wantsLayer = true
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
        surfaceView.frame = bounds
        // The surface does not observe its own frame; feed it the point
        // size it occupies so the terminal grid matches the view.
        surfaceView.sizeDidChange(surfaceView.bounds.size)
    }

    /// Begin the close cycle from outside (the ⌘D close intent).
    func requestClose() {
        closeRequested = true
        GhosttyTerminalController.shared.requestClose(surfaceView)
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
