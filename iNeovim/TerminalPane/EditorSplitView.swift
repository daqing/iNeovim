import AppKit
import Combine

/// Window content container: the nvim editor fills the view, flanked left by
/// the optional problems panel (docked issues sidebar, driven by
/// `isProblemsPanelVisible`) and right by the native terminal pane once it
/// opens. The pane follows the intents published by `AppModel`; actual pane
/// visibility is reported back through `setTerminalPaneVisible`. Narrowing
/// the editor reflows the nvim grid through the normal resize pipeline.
final class EditorSplitView: NSView {
    static let defaultPaneWidth: CGFloat = 420
    static let minPaneWidth: CGFloat = 280
    static let defaultPanelWidth: CGFloat = 280
    static let minPanelWidth: CGFloat = 200
    static let minEditorWidth: CGFloat = 160
    static let dividerThickness: CGFloat = 5

    let terminalView: TerminalView

    private let model: AppModel
    private let divider = PaneDividerView()
    private let problemsDivider = PaneDividerView()
    private var pane: TerminalPaneView?
    private var problemsPanel: ProblemsPanelController?
    private var paneWidth: CGFloat = EditorSplitView.defaultPaneWidth
    private var panelWidth: CGFloat = EditorSplitView.defaultPanelWidth
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
        problemsDivider.isHidden = true
        problemsDivider.onDrag = { [weak self] deltaX in
            guard let self else { return }
            setPanelWidth(panelWidth + deltaX, animated: false)
        }
        addSubview(problemsDivider)
        model.$terminalPaneIntent
            .receive(on: DispatchQueue.main)
            .sink { [weak self] intent in
                guard let intent else { return }
                self?.apply(intent)
            }
            .store(in: &cancellables)
        model.$isProblemsPanelVisible
            .receive(on: DispatchQueue.main)
            .sink { [weak self] visible in
                self?.setProblemsPanelVisible(visible, animated: true)
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

    // MARK: Problems panel

    private func setProblemsPanelVisible(_ visible: Bool, animated: Bool) {
        if visible {
            let panel = problemsPanel ?? makeProblemsPanel()
            if panel.view.superview == nil {
                addSubview(panel.view)
            }
            problemsDivider.isHidden = false
            placeSubviews(animated: animated)
        } else {
            guard let panel = problemsPanel, panel.view.superview != nil else { return }
            panel.view.removeFromSuperview()
            problemsDivider.isHidden = true
            placeSubviews(animated: animated)
        }
    }

    /// The panel is cheap and must keep its subscription while hidden, so it
    /// is created once and kept for the window's lifetime.
    private func makeProblemsPanel() -> ProblemsPanelController {
        let panel = ProblemsPanelController(store: model.diagnosticsStore) { [weak self] problem in
            self?.model.jumpToProblem(problem)
        }
        problemsPanel = panel
        return panel
    }

    private func setPanelWidth(_ width: CGFloat, animated: Bool) {
        panelWidth = Self.clampedPanelWidth(width, containerWidth: bounds.width, otherSpans: paneSpans())
        placeSubviews(animated: animated)
    }

    private func paneSpans() -> CGFloat {
        pane != nil ? Self.dividerThickness + paneWidth : 0
    }

    static func clampedPanelWidth(_ width: CGFloat, containerWidth: CGFloat, otherSpans: CGFloat) -> CGFloat {
        let maxPanel = max(minPanelWidth, containerWidth - otherSpans - minEditorWidth)
        return min(max(width, minPanelWidth), maxPanel)
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
        let panelVisible = problemsPanel?.view.superview != nil
        let paneWidth = pane != nil ? self.paneWidth : 0
        let paneSpan = paneWidth > 0 ? Self.dividerThickness + paneWidth : 0
        let panelWidth = panelVisible
            ? min(self.panelWidth, max(0, bounds.width - paneSpan - Self.minEditorWidth))
            : 0
        let panelSpan = panelVisible ? panelWidth + Self.dividerThickness : 0
        let editorWidth = max(0, bounds.width - panelSpan - paneSpan)
        let frames = (
            panel: NSRect(x: 0, y: 0, width: panelWidth, height: bounds.height),
            problemsDivider: NSRect(x: panelWidth, y: 0, width: Self.dividerThickness, height: bounds.height),
            editor: NSRect(x: panelSpan, y: 0, width: editorWidth, height: bounds.height),
            divider: NSRect(x: panelSpan + editorWidth, y: 0, width: Self.dividerThickness, height: bounds.height),
            pane: NSRect(x: panelSpan + editorWidth + Self.dividerThickness, y: 0, width: paneWidth, height: bounds.height)
        )
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                problemsPanel?.view.animator().frame = frames.panel
                problemsDivider.animator().frame = frames.problemsDivider
                terminalView.animator().frame = frames.editor
                divider.animator().frame = frames.divider
                pane?.animator().frame = frames.pane
            }
        } else {
            problemsPanel?.view.frame = frames.panel
            problemsDivider.frame = frames.problemsDivider
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
