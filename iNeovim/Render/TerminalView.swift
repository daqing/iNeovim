import AppKit

/// The terminal surface: a layer-backed view that renders the applied grid
/// state from `Screen` with Core Text.
final class TerminalView: NSView {
    private(set) var metrics: FontMetrics
    private var snapshot: ScreenSnapshot?
    private let resizeController: ResizeController

    init(
        metrics: FontMetrics = FontMetrics(
            font: .monospacedSystemFont(ofSize: FontMetrics.defaultSize, weight: .regular)
        )
    ) {
        self.metrics = metrics
        self.resizeController = ResizeController(cellSize: metrics.cellSize)
        super.init(frame: NSRect(
            origin: .zero,
            size: CGSize(
                width: metrics.cellSize.width * 80,
                height: metrics.cellSize.height * 24
            )
        ))
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if snapshot == nil {
            connectScreen()
        }
    }

    override func setFrameSize(_ newSize: CGSize) {
        super.setFrameSize(newSize)
        resizeController.viewDidResize(to: newSize)
    }

    /// Pull a fresh snapshot on every nvim flush; events between flushes are
    /// coalesced by needsDisplay.
    private func connectScreen() {
        Task {
            await Screen.shared.flushHandler = { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.snapshot = await Screen.shared.snapshot()
                    self.needsDisplay = true
                }
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        NSBezierPath.fill(dirtyRect)
    }

    private var backgroundColor: NSColor {
        if let packed = snapshot?.defaultBackground, let color = NSColor(packedRGB: packed) {
            return color
        }
        return .textBackgroundColor
    }
}
