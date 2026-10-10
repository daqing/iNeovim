import AppKit
import Combine

/// Window content container: the nvim editor fills the view until the
/// native terminal pane opens, then the editor narrows, a divider appears,
/// and the pane takes the right side. The pane follows the intents
/// published by `AppModel`; actual visibility is reported back through
/// `setTerminalPaneVisible`. Narrowing the editor reflows the nvim grid
/// through the normal resize pipeline.
final class EditorSplitView: NSView {
    static let defaultPaneWidth: CGFloat = 420
    static let minPaneWidth: CGFloat = 280
    static let dividerThickness: CGFloat = 5

    let terminalView: TerminalView

    private let model: AppModel
    private let divider = PaneDividerView()
    private var pane: TerminalPaneView?
    private var paneWidth: CGFloat = EditorSplitView.defaultPaneWidth
    private var cancellables: Set<AnyCancellable> = []
    private var willCloseObserver: NSObjectProtocol?

    init(model: AppModel, metrics: FontMetrics) {
        self.model = model
        self.terminalView = TerminalView(model: model, metrics: metrics)
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(terminalView)
        divider.isHidden = true
        divider.onDrag = { [weak self] deltaX in
            guard let self else { return }
            setPaneWidth(paneWidth - deltaX, animated: false)
        }
        addSubview(divider)
        model.$terminalPaneIntent
            .receive(on: DispatchQueue.main)
            .sink { [weak self] intent in
                guard let intent else { return }
                self?.apply(intent)
            }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let willCloseObserver {
            NotificationCenter.default.removeObserver(willCloseObserver)
        }
    }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, willCloseObserver == nil else { return }
        willCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.closePane(removeImmediately: true)
            }
        }
    }

    // MARK: Settings passthrough

    func apply(settings: AppSettings) {
        terminalView.apply(settings: settings)
    }

    func sessionDidChangeReady(_ ready: Bool) {
        terminalView.sessionDidChangeReady(ready)
    }

    // MARK: Pane state

    private func apply(_ intent: AppModel.TerminalPaneIntent) {
        switch intent {
        case .open(let request):
            openPane(request)
        case .focus:
            if let pane {
                window?.makeFirstResponder(pane.surfaceView)
            }
        case .close:
            closePane(removeImmediately: false)
        }
    }

    private func openPane(_ request: AppModel.TerminalPaneRequest) {
        if let pane {
            window?.makeFirstResponder(pane.surfaceView)
            return
        }
        guard let surface = GhosttyTerminalController.shared.makeSurface(
            workingDirectory: request.workingDirectory,
            command: request.shellCommand,
            font: AppSettings.shared.resolvedFont(),
            colors: model.terminalColors
        ) else { return }
        let paneView = TerminalPaneView(surfaceView: surface)
        paneView.onClose = { [weak self] in self?.paneDidClose() }
        pane = paneView
        addSubview(paneView)
        divider.isHidden = false
        model.setTerminalPaneVisible(true)
        setPaneWidth(
            Self.clampedPaneWidth(paneWidth, containerWidth: bounds.width),
            animated: bounds.width > 0
        )
        window?.makeFirstResponder(surface)
    }

    /// Graceful close asks the surface to exit first; the close callback
    /// routes back through `paneDidClose`. `removeImmediately` tears the
    /// pane down synchronously (window teardown).
    private func closePane(removeImmediately: Bool) {
        guard let pane else { return }
        if removeImmediately {
            pane.destroy()
            self.pane = nil
            model.setTerminalPaneVisible(false)
            divider.isHidden = true
            placeSubviews()
            window?.makeFirstResponder(terminalView)
        } else {
            pane.requestClose()
        }
    }

    /// The surface finished its close cycle (child exit or forced close):
    /// remove the pane and hand focus back to the editor.
    private func paneDidClose() {
        guard let pane else { return }
        pane.removeFromSuperview()
        self.pane = nil
        model.setTerminalPaneVisible(false)
        divider.isHidden = true
        placeSubviews(animated: true)
        window?.makeFirstResponder(terminalView)
    }

    private func setPaneWidth(_ width: CGFloat, animated: Bool) {
        paneWidth = Self.clampedPaneWidth(width, containerWidth: bounds.width)
        placeSubviews(animated: animated)
    }

    static func clampedPaneWidth(_ width: CGFloat, containerWidth: CGFloat) -> CGFloat {
        guard containerWidth > 0 else { return defaultPaneWidth }
        let maxWidth = max(minPaneWidth, containerWidth * 0.6)
        return min(max(width, minPaneWidth), maxWidth)
    }

    override func layout() {
        super.layout()
        placeSubviews()
    }

    private func placeSubviews(animated: Bool = false) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let paneWidth = pane != nil ? paneWidth : 0
        let dividerX = bounds.width - paneWidth - Self.dividerThickness
        let frames = (
            editor: NSRect(x: 0, y: 0, width: dividerX, height: bounds.height),
            divider: NSRect(x: dividerX, y: 0, width: Self.dividerThickness, height: bounds.height),
            pane: NSRect(
                x: dividerX + Self.dividerThickness,
                y: 0,
                width: paneWidth,
                height: bounds.height
            )
        )
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                terminalView.animator().frame = frames.editor
                divider.animator().frame = frames.divider
                pane?.animator().frame = frames.pane
            }
        } else {
            terminalView.frame = frames.editor
            divider.frame = frames.divider
            pane?.frame = frames.pane
        }
    }
}

/// Draggable separator between the editor and the terminal pane.
final class PaneDividerView: NSView {
    var onDrag: ((CGFloat) -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.deltaX)
    }
}
