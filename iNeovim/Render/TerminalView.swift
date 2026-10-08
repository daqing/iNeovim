import AppKit
import CoreText
import os

/// The terminal surface: hosts the scrollable grid content layer, paints
/// the background behind it, and routes keyboard, mouse, and scroll input.
final class TerminalView: NSView {
    private(set) var metrics: FontMetrics
    private var snapshot: ScreenSnapshot?
    private var blinker = CursorBlinker()
    private var cursorKey: (row: Int, col: Int, modeIndex: Int)?
    private let contentLayer: GridContentLayer
    private let scrollAnimator = ScrollAnimator()
    private let resizeController: ResizeController
    private var keyHandler = KeyInputHandler()
    private let mouseHandler = MouseHandler()
    private let scrollController = ScrollController()
    let imeHandler = IMEHandler()
    var inputSettings = InputSettings() {
        didSet {
            keyHandler.passCmdKeys = inputSettings.passCmdKeysThrough
            keyHandler.optionAsMeta = inputSettings.optionAsMeta
        }
    }

    init(
        metrics: FontMetrics = FontMetrics(
            font: .monospacedSystemFont(ofSize: FontMetrics.defaultSize, weight: .regular)
        )
    ) {
        self.metrics = metrics
        self.contentLayer = GridContentLayer(metrics: metrics)
        self.resizeController = ResizeController(cellSize: metrics.cellSize)
        super.init(frame: NSRect(
            origin: .zero,
            size: CGSize(
                width: metrics.cellSize.width * 80,
                height: metrics.cellSize.height * 24
            )
        ))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.masksToBounds = true
        layer?.addSublayer(contentLayer)
        imeHandler.view = self
        mouseHandler.view = self
        scrollController.view = self
        scrollController.onOffsetChange = { [weak self] offset, animated in
            self?.scrollAnimator.setTarget(offset, animated: animated)
        }
        scrollAnimator.onUpdate = { [weak self] offset in
            guard let self else { return }
            self.contentLayer.transform = CATransform3DMakeTranslation(0, offset, 0)
        }
        imeHandler.onMarkedTextChange = { [weak self] in
            self?.invalidatePreeditRegion()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if imeHandler.hasMarkedText {
            // Composition in progress: let the input context route the event
            // to setMarkedText/insertText/doCommand.
            interpretKeyEvents([event])
            return
        }
        if let key = keyHandler.nvimKey(for: event) {
            sendKeys(key)
        } else {
            // Printable text and dead keys go through the input context so
            // IME composition produces marked text (see IMEHandler).
            interpretKeyEvents([event])
        }
    }

    /// The view's key-equivalent hook runs before the main menu's during
    /// responder-chain dispatch, so when Command passthrough is enabled we
    /// must offer app shortcuts the event first.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.contains(.command) else { return false }
        guard inputSettings.passCmdKeysThrough else { return false }
        if let mainMenu = NSApp.mainMenu, mainMenu.performKeyEquivalent(with: event) {
            return true
        }
        guard let key = keyHandler.nvimKey(for: event) else { return false }
        sendKeys(key)
        return true
    }

    func sendKeys(_ keys: String) {
        InputDispatcher.shared.send(.keys(keys))
    }

    /// View-space rect for a character range of the marked text, anchored at
    /// the cursor cell and wide as the covered cells, plus the live scroll
    /// offset. IME candidate windows anchor to this (see
    /// `firstRect(forCharacterRange:)`).
    func preeditRect(forCharacterRange range: NSRange) -> CGRect {
        preeditLayerRect(forCharacterRange: range)
            .offsetBy(dx: 0, dy: scrollAnimator.presentationOffset)
    }

    private func preeditLayerRect(forCharacterRange range: NSRange) -> CGRect {
        guard imeHandler.hasMarkedText, let anchor = contentLayer.cursorAnchorRect() else { return .zero }
        let cellWidth = metrics.cellSize.width
        let start = Self.cellOffset(of: imeHandler.markedText, upToUTF16: range.location)
        let end = Self.cellOffset(of: imeHandler.markedText, upToUTF16: range.location + range.length)
        return CGRect(
            x: anchor.minX + CGFloat(start) * cellWidth,
            y: anchor.minY,
            width: CGFloat(max(end - start, 1)) * cellWidth,
            height: anchor.height
        )
    }

    /// Display width in cells for preedit text: wide characters take two,
    /// everything else one. Kept on the view (not CellRenderer) because
    /// preedit strings are plain text, not grid cells.
    static func cellCount(of text: String) -> Int {
        text.reduce(0) { $0 + (CellRenderer.isDoubleWidth(String($1)) ? 2 : 1) }
    }

    /// Cells covered by the text strictly before the utf16 offset.
    static func cellOffset(of text: String, upToUTF16 target: Int) -> Int {
        var consumed = 0
        var cells = 0
        for character in text {
            let length = String(character).utf16.count
            if consumed + length > target { break }
            consumed += length
            cells += CellRenderer.isDoubleWidth(String(character)) ? 2 : 1
        }
        return cells
    }

    private var lastPreeditRect: CGRect?

    /// Live grid dimensions for input translation (mouse cell coordinates).
    var gridDimensions: (width: Int, height: Int)? {
        snapshot?.grid.map { ($0.width, $0.height) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseHandler.mouseDown(event)
    }

    override func mouseDragged(with event: NSEvent) {
        mouseHandler.mouseDragged(event)
    }

    override func mouseUp(with event: NSEvent) {
        mouseHandler.mouseUp(event)
    }

    override func scrollWheel(with event: NSEvent) {
        scrollController.scrollWheel(with: event)
    }

    private func invalidatePreeditRegion() {
        let rect = preeditLayerRect(forCharacterRange: NSRange(
            location: 0,
            length: imeHandler.markedText.utf16.count
        ))
        var dirty = rect
        if let lastPreeditRect { dirty = dirty.union(lastPreeditRect) }
        lastPreeditRect = imeHandler.hasMarkedText ? rect : nil
        contentLayer.preedit = imeHandler.hasMarkedText
            ? GridContentLayer.Preedit(text: imeHandler.markedText, selection: imeHandler.markedSelection)
            : nil
        guard !dirty.isEmpty else { return }
        contentLayer.setNeedsDisplay(dirty)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
        if snapshot == nil {
            connectScreen()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Fallback colors follow the system appearance; repaint so cells
        // drawn with nvim-packed colors keep showing through where set.
        needsDisplay = true
        contentLayer.setNeedsDisplay()
    }

    private func updateContentsScale() {
        layer?.contentsScale = backingScale
        contentLayer.contentsScale = backingScale
        contentLayer.setNeedsDisplay()
    }

    override func setFrameSize(_ newSize: CGSize) {
        super.setFrameSize(newSize)
        Task { await resizeController.viewDidResize(to: newSize) }
    }

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    }

    /// Pull a fresh snapshot on every nvim flush, then invalidate only the
    /// cells the flush dirtied.
    private func connectScreen() {
        Task { [weak self] in
            guard let self else { return }
            await Screen.shared.setFlushHandler { [weak self] grid, cellRect in
                guard let self, grid == 1 else { return }
                Task { @MainActor in
                    let snapshot = await Screen.shared.snapshot()
                    self.updateBlink(previous: self.snapshot, next: snapshot)
                    self.snapshot = snapshot
                    self.contentLayer.update(snapshot: snapshot)
                    self.contentLayer.invalidate(cellRect: cellRect)
                }
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        NSBezierPath.fill(dirtyRect)
    }

    private func updateBlink(previous: ScreenSnapshot?, next: ScreenSnapshot) {
        guard let mode = next.cursorModeInfo,
              let blinkOn = mode.blinkOn, blinkOn > 0,
              let blinkOff = mode.blinkOff, blinkOff > 0 else {
            blinker.cancel()
            setCursorVisible(true)
            cursorKey = nil
            return
        }
        let key = (row: next.cursor.row, col: next.cursor.col, modeIndex: next.modeIndex)
        if let cursorKey, cursorKey == key, blinker.isActive { return }
        self.cursorKey = key
        blinker.restart(wait: mode.blinkWait ?? 0, on: blinkOn, off: blinkOff) { [weak self] visible in
            guard let self else { return }
            self.setCursorVisible(visible)
        }
    }

    private func setCursorVisible(_ visible: Bool) {
        contentLayer.cursorVisible = visible
    }

    /// Colors for when nvim leaves a default unset (-1): adaptive AppKit
    /// colors, so the surface follows dark/light mode.
    private var fallbackBackground: NSColor { .textBackgroundColor }

    private var backgroundColor: NSColor {
        if let packed = snapshot?.defaultBackground, let color = NSColor(packedRGB: packed) {
            return color
        }
        return fallbackBackground
    }
}
