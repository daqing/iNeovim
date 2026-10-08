import AppKit
import CoreText
import os

/// The terminal surface: a layer-backed view that renders the applied grid
/// state from `Screen` with Core Text.
final class TerminalView: NSView {
    private(set) var metrics: FontMetrics
    private var fonts: FontVariants
    private var snapshot: ScreenSnapshot?
    private var cursorVisible = true
    private var blinker = CursorBlinker()
    private var cursorKey: (row: Int, col: Int, modeIndex: Int)?
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
        self.fonts = FontVariants(metrics.font)
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
        imeHandler.view = self
        mouseHandler.view = self
        scrollController.view = self
        // Interim offset sink (T7.1): shift the whole surface; T7.2 moves the
        // grid into its own layer and drives this with a display link.
        scrollController.onOffsetChange = { [weak self] offset in
            self?.layer?.transform = CATransform3DMakeTranslation(0, offset, 0)
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
    /// the cursor cell and wide as the covered cells. IME candidate windows
    /// anchor to this (see `firstRect(forCharacterRange:)`).
    func preeditRect(forCharacterRange range: NSRange) -> CGRect {
        guard imeHandler.hasMarkedText, let snapshot, let anchor = cursorCellRect(snapshot) else { return .zero }
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
        let rect = preeditRect(forCharacterRange: NSRange(
            location: 0,
            length: imeHandler.markedText.utf16.count
        ))
        var dirty = rect
        if let lastPreeditRect { dirty = dirty.union(lastPreeditRect) }
        lastPreeditRect = imeHandler.hasMarkedText ? rect : nil
        guard !dirty.isEmpty else { return }
        setNeedsDisplay(dirty)
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
    }

    private func updateContentsScale() {
        layer?.contentsScale = backingScale
    }

    override func setFrameSize(_ newSize: CGSize) {
        super.setFrameSize(newSize)
        Task { await resizeController.viewDidResize(to: newSize) }
    }

    /// Round a rect to backing-pixel boundaries so filled cell rects and
    /// cursor bars land on whole pixels instead of straddling two.
    private func snappedToPixels(_ rect: CGRect) -> CGRect {
        let scale = backingScale
        guard scale > 0 else { return rect }
        let minX = (rect.minX * scale).rounded()
        let maxX = (rect.maxX * scale).rounded()
        let minY = (rect.minY * scale).rounded()
        let maxY = (rect.maxY * scale).rounded()
        return CGRect(
            x: minX / scale,
            y: minY / scale,
            width: (maxX - minX) / scale,
            height: (maxY - minY) / scale
        )
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
                    self.invalidate(cellRect: cellRect)
                }
            }
        }
    }

    private func invalidate(cellRect: CellRect) {
        let cellWidth = metrics.cellSize.width
        let cellHeight = metrics.cellSize.height
        setNeedsDisplay(snappedToPixels(CGRect(
            x: CGFloat(cellRect.minCol) * cellWidth,
            y: CGFloat(cellRect.minRow) * cellHeight,
            width: CGFloat(cellRect.maxCol - cellRect.minCol) * cellWidth,
            height: CGFloat(cellRect.maxRow - cellRect.minRow) * cellHeight
        )))
    }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        NSBezierPath.fill(dirtyRect)

        guard let snapshot, let grid = snapshot.grid, !grid.isEmpty else { return }
        let cellHeight = metrics.cellSize.height
        let context = NSGraphicsContext.current!.cgContext

        let firstRow = max(0, Int(floor(dirtyRect.minY / cellHeight)))
        let lastRow = min(grid.height - 1, Int(floor(dirtyRect.maxY / cellHeight)))

        for row in firstRow...lastRow {
            var cells = [GridCell]()
            cells.reserveCapacity(grid.width)
            for col in 0..<grid.width {
                cells.append(grid[row, col])
            }
            let runs = CellRenderer.runs(forRow: cells)

            // Background pass, in view coordinates (y down).
            for run in runs {
                let runRect = runRect(run, row: row)
                guard runRect.intersects(dirtyRect) else { continue }
                let colors = resolvedColors(for: run.attrId)
                (colors.background ?? backgroundColor).setFill()
                NSBezierPath.fill(snappedToPixels(runRect))
            }

            // Text pass, in Core Text coordinates (y up).
            context.saveGState()
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            for run in runs where !run.text.isEmpty {
                guard runRect(run, row: row).intersects(dirtyRect) else { continue }
                drawText(run: run, row: row, colors: resolvedColors(for: run.attrId), context: context)
            }
            context.restoreGState()
        }

        drawCursor(dirtyRect, context: context)
        drawPreedit(dirtyRect, context: context)
    }

    private func runRect(_ run: StyledRun, row: Int) -> CGRect {
        CGRect(
            x: CGFloat(run.startCol) * metrics.cellSize.width,
            y: CGFloat(row) * metrics.cellSize.height,
            width: CGFloat(run.endCol - run.startCol) * metrics.cellSize.width,
            height: metrics.cellSize.height
        )
    }

    private struct ResolvedColors {
        var foreground: NSColor
        var background: NSColor?
        var special: NSColor
    }

    private func resolvedColors(for attrId: Int) -> ResolvedColors {
        let attr = snapshot?.highlights[attrId] ?? HlAttr()
        let resolved = attr.resolvedColors(
            defaultForeground: snapshot?.defaultForeground,
            defaultBackground: snapshot?.defaultBackground,
            defaultSpecial: snapshot?.defaultSpecial
        )
        let foreground = resolved.foreground.flatMap(NSColor.init(packedRGB:)) ?? fallbackForeground
        return ResolvedColors(
            foreground: foreground,
            background: resolved.background.flatMap(NSColor.init(packedRGB:)),
            special: resolved.special.flatMap(NSColor.init(packedRGB:)) ?? foreground
        )
    }

    private func drawText(
        run: StyledRun,
        row: Int,
        colors: ResolvedColors,
        context: CGContext
    ) {
        let attr = snapshot?.highlights[run.attrId] ?? HlAttr()
        let font = fonts.font(for: attr)
        let ctFont = font as CTFont

        let attributed = NSAttributedString(string: run.text, attributes: [
            .font: font,
            .foregroundColor: colors.foreground,
            // Standard ligatures on: contiguous same-style text is shaped as
            // one CTLine above, so fonts like Fira Code ligate across cells.
            .ligature: 1,
        ])
        let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)

        let baseline = CGFloat(row) * metrics.cellSize.height + metrics.baseline
        let textY = bounds.height - baseline
        context.textPosition = CGPoint(x: CGFloat(run.startCol) * metrics.cellSize.width, y: textY)
        CTLineDraw(line, context)

        let thickness = max(1, CTFontGetUnderlineThickness(ctFont))
        let startX = CGFloat(run.startCol) * metrics.cellSize.width
        let endX = CGFloat(run.endCol) * metrics.cellSize.width
        let underlineY = textY + CTFontGetUnderlinePosition(ctFont)

        if attr.underline || attr.undercurl {
            let path = CGMutablePath()
            if attr.undercurl {
                addUndercurl(to: path, from: startX, to: endX, y: underlineY, thickness: thickness)
            } else {
                path.move(to: CGPoint(x: startX, y: underlineY))
                path.addLine(to: CGPoint(x: endX, y: underlineY))
            }
            colors.special.setStroke()
            context.setLineWidth(thickness)
            context.addPath(path)
            context.strokePath()
        }

        if attr.strikethrough {
            let strikeY = textY + CTFontGetXHeight(ctFont) / 2
            colors.special.setStroke()
            context.setLineWidth(thickness)
            context.strokeLineSegments(between: [
                CGPoint(x: startX, y: strikeY),
                CGPoint(x: endX, y: strikeY),
            ])
        }
    }

    private func addUndercurl(
        to path: CGMutablePath,
        from startX: CGFloat,
        to endX: CGFloat,
        y: CGFloat,
        thickness: CGFloat
    ) {
        let amplitude = max(1, thickness)
        let period = max(4, thickness * 4)
        let step = max(1, period / 8)
        var x = startX
        path.move(to: CGPoint(x: x, y: y))
        while x < endX {
            x = min(x + step, endX)
            let phase = 2 * CGFloat.pi * x / period
            path.addLine(to: CGPoint(x: x, y: y + amplitude * cos(phase)))
        }
    }

    // MARK: - Cursor

    private func cursorCellRect(_ snapshot: ScreenSnapshot) -> CGRect? {
        guard snapshot.cursor.grid == 1, let grid = snapshot.grid,
              snapshot.cursor.row >= 0, snapshot.cursor.row < grid.height,
              snapshot.cursor.col >= 0, snapshot.cursor.col < grid.width else {
            return nil
        }
        return CGRect(
            x: CGFloat(snapshot.cursor.col) * metrics.cellSize.width,
            y: CGFloat(snapshot.cursor.row) * metrics.cellSize.height,
            width: metrics.cellSize.width,
            height: metrics.cellSize.height
        )
    }

    private func drawCursor(_ dirtyRect: NSRect, context: CGContext) {
        guard cursorVisible, let snapshot, let cellRect = cursorCellRect(snapshot) else { return }
        let mode = snapshot.cursorModeInfo
        let colors = resolvedColors(for: cursorCellAttrId(snapshot))

        switch mode?.cursorShape ?? .block {
        case .block:
            colors.foreground.setFill()
            NSBezierPath.fill(snappedToPixels(cellRect.intersection(dirtyRect)))
            // Redraw the glyph under the block, swapped to the background color.
            guard let grid = snapshot.grid else { return }
            let cell = grid[snapshot.cursor.row, snapshot.cursor.col]
            guard !cell.text.isEmpty else { return }
            let width = CellRenderer.isDoubleWidth(cell.text) ? 2 : 1
            let run = StyledRun(
                text: cell.text,
                attrId: cell.attrId,
                startCol: snapshot.cursor.col,
                endCol: snapshot.cursor.col + width
            )
            let swapped = ResolvedColors(
                foreground: colors.background ?? backgroundColor,
                background: nil,
                special: colors.special
            )
            context.saveGState()
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            drawText(run: run, row: snapshot.cursor.row, colors: swapped, context: context)
            context.restoreGState()
        case .horizontal:
            let percentage = CGFloat(mode?.cellPercentage ?? 20)
            let height = max(2, (cellRect.height * percentage / 100).rounded())
            let bar = CGRect(
                x: cellRect.minX,
                y: cellRect.maxY - height,
                width: cellRect.width,
                height: height
            )
            colors.foreground.setFill()
            NSBezierPath.fill(snappedToPixels(bar.intersection(dirtyRect)))
        case .vertical:
            let percentage = CGFloat(mode?.cellPercentage ?? 25)
            let width = max(1, (cellRect.width * percentage / 100).rounded())
            let bar = CGRect(
                x: cellRect.minX,
                y: cellRect.minY,
                width: width,
                height: cellRect.height
            )
            colors.foreground.setFill()
            NSBezierPath.fill(snappedToPixels(bar.intersection(dirtyRect)))
        }
    }

    private func cursorCellAttrId(_ snapshot: ScreenSnapshot) -> Int {
        guard let grid = snapshot.grid,
              snapshot.cursor.row < grid.height, snapshot.cursor.col < grid.width else {
            return 0
        }
        return grid[snapshot.cursor.row, snapshot.cursor.col].attrId
    }

    private func updateBlink(previous: ScreenSnapshot?, next: ScreenSnapshot) {
        guard let mode = next.cursorModeInfo,
              let blinkOn = mode.blinkOn, blinkOn > 0,
              let blinkOff = mode.blinkOff, blinkOff > 0 else {
            blinker.cancel()
            cursorVisible = true
            cursorKey = nil
            return
        }
        let key = (row: next.cursor.row, col: next.cursor.col, modeIndex: next.modeIndex)
        if let cursorKey, cursorKey == key, blinker.isActive { return }
        self.cursorKey = key
        blinker.restart(wait: mode.blinkWait ?? 0, on: blinkOn, off: blinkOff) { [weak self] visible in
            guard let self else { return }
            self.cursorVisible = visible
            self.invalidateCursorCell()
        }
    }

    private func invalidateCursorCell() {
        guard let snapshot, let cellRect = cursorCellRect(snapshot) else { return }
        setNeedsDisplay(cellRect)
    }

    // MARK: - Preedit (marked text)

    /// Draws the IME composition at the cursor: the underlying cells are
    /// cleared, the preedit string is drawn with an accent underline, and a
    /// bar marks the selection position inside it.
    private func drawPreedit(_ dirtyRect: NSRect, context: CGContext) {
        guard imeHandler.hasMarkedText, let snapshot, let anchor = cursorCellRect(snapshot) else { return }
        let rect = preeditRect(forCharacterRange: NSRange(
            location: 0,
            length: imeHandler.markedText.utf16.count
        )).intersection(bounds)
        guard !rect.isEmpty else { return }

        backgroundColor.setFill()
        NSBezierPath.fill(snappedToPixels(rect))

        // The selection bar uses view coordinates, so it must be filled
        // before the Core Text coordinate flip below.
        let selectionCells = Self.cellOffset(of: imeHandler.markedText, upToUTF16: imeHandler.markedSelection.location)
        let bar = snappedToPixels(CGRect(
            x: anchor.minX + CGFloat(selectionCells) * metrics.cellSize.width,
            y: anchor.minY,
            width: 2,
            height: anchor.height
        ))
        fallbackForeground.setFill()
        context.fill(bar)

        context.saveGState()
        context.clip(to: CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height))
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)

        let font = fonts.regular
        let attributed = NSAttributedString(string: imeHandler.markedText, attributes: [
            .font: font,
            .foregroundColor: fallbackForeground,
        ])
        let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
        let textY = bounds.height - (anchor.minY + metrics.baseline)
        context.textPosition = CGPoint(x: anchor.minX, y: textY)
        CTLineDraw(line, context)

        let underlineY = textY + CTFontGetUnderlinePosition(font as CTFont)
        NSColor.controlAccentColor.setStroke()
        context.setLineWidth(max(1, CTFontGetUnderlineThickness(font as CTFont)))
        context.strokeLineSegments(between: [
            CGPoint(x: rect.minX, y: underlineY),
            CGPoint(x: rect.maxX, y: underlineY),
        ])

        context.restoreGState()
    }

    /// Colors for when nvim leaves a default unset (-1): adaptive AppKit
    /// colors, so the surface follows dark/light mode.
    private var fallbackForeground: NSColor { .textColor }
    private var fallbackBackground: NSColor { .textBackgroundColor }

    private var backgroundColor: NSColor {
        if let packed = snapshot?.defaultBackground, let color = NSColor(packedRGB: packed) {
            return color
        }
        return fallbackBackground
    }
}

/// The four font variants needed to satisfy `HlAttr` bold/italic
/// combinations, resolved once per metrics change.
private struct FontVariants {
    let regular: NSFont
    let bold: NSFont
    let italic: NSFont
    let boldItalic: NSFont

    init(_ font: NSFont) {
        let manager = NSFontManager.shared
        regular = font
        bold = manager.convert(font, toHaveTrait: .boldFontMask) ?? font
        italic = manager.convert(font, toHaveTrait: .italicFontMask) ?? font
        boldItalic = manager.convert(font, toHaveTrait: [.boldFontMask, .italicFontMask]) ?? bold
    }

    func font(for attr: HlAttr) -> NSFont {
        switch (attr.bold, attr.italic) {
        case (true, true): return boldItalic
        case (true, false): return bold
        case (false, true): return italic
        default: return regular
        }
    }
}
