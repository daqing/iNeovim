import AppKit
import CoreText
import os

/// The scrollable grid surface: owns drawing of the cells, the cursor, and
/// the IME preedit, so the animator can translate the whole content while
/// the view behind it keeps painting the background.
final class GridContentLayer: CALayer {
    struct Preedit: Equatable {
        var text: String
        var selection: NSRange
    }

    private(set) var snapshot: ScreenSnapshot?
    private(set) var metrics: FontMetrics
    private var fonts: FontVariants
    var preedit: Preedit?
    var cursorVisible = true {
        didSet { invalidateCursor() }
    }
    /// Translation applied to the drawn cursor while it glides between cells.
    var cursorGlideOffset: CGSize = .zero {
        didSet { invalidateCursor() }
    }
    /// Layer-space rect the cursor was last drawn at, so a glide can invalidate
    /// the position it is leaving in addition to the one it is moving to.
    private var lastDrawnCursorRect: CGRect?
    /// Cell regions pending redraw for the next `draw(in:)`, so a flush that
    /// touched two far-apart cells doesn't make us shape every row between.
    private var pendingCellRects: [CellRect] = []

    init(metrics: FontMetrics) {
        self.metrics = metrics
        self.fonts = FontVariants(metrics.font)
        super.init()
        // The host view is flipped, so the layer inherits a top-left origin;
        // leaving this false keeps the grid's y-down drawing math correct.
        isGeometryFlipped = false
        needsDisplayOnBoundsChange = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The grid is drawn imperatively and updates its contents/properties every
    /// flush; Core Animation must not implicitly animate any of them, or typed
    /// characters cross-fade in and the scroll transform lags. `NSNull` is the
    /// sentinel that disables the implicit action for every key.
    override func action(forKey event: String) -> CAAction? {
        NSNull()
    }

    /// Core Animation copies a layer with this initializer when it animates or
    /// presents it; without it the layer traps.
    override init(layer: Any) {
        let source = layer as? GridContentLayer
        let metrics = source?.metrics
            ?? FontMetrics(font: .monospacedSystemFont(ofSize: FontMetrics.defaultSize, weight: .regular))
        self.metrics = metrics
        self.fonts = FontVariants(metrics.font)
        super.init(layer: layer)
        if let source {
            snapshot = source.snapshot
            preedit = source.preedit
            cursorVisible = source.cursorVisible
            cursorGlideOffset = source.cursorGlideOffset
        }
    }

    /// Apply a fresh snapshot and resize to the grid's content size (the
    /// bounds change invalidates the whole layer).
    func update(snapshot: ScreenSnapshot) {
        self.snapshot = snapshot
        let size: CGSize
        if let grid = snapshot.grid, !grid.isEmpty {
            size = CGSize(
                width: CGFloat(grid.width) * metrics.cellSize.width,
                height: CGFloat(grid.height) * metrics.cellSize.height
            )
        } else {
            size = .zero
        }
        if bounds.size != size {
            // Resizing the backing grid is a content change, not an animation;
            // without this Core Animation would implicitly animate `bounds`.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            bounds = CGRect(origin: .zero, size: size)
            CATransaction.commit()
        }
    }

    /// Swap in metrics from a newly selected font. The caller re-applies the
    /// snapshot afterwards so bounds match the new cell size.
    func updateMetrics(_ newMetrics: FontMetrics) {
        metrics = newMetrics
        fonts = FontVariants(newMetrics.font)
        setNeedsDisplay()
    }

    /// Mark one or more cell-coordinate regions dirty.
    func invalidate(cellRects: [CellRect]) {
        guard !cellRects.isEmpty else { return }
        pendingCellRects.append(contentsOf: cellRects)
        for rect in cellRects {
            setNeedsDisplay(snappedToPixels(pixelRect(for: rect)))
        }
    }

    func invalidateCursor() {
        guard let rect = cursorCellRect() else { return }
        let offsetRect = rect.offsetBy(dx: cursorGlideOffset.width, dy: cursorGlideOffset.height)
        // Include the rect the cursor was last drawn at: while gliding, the
        // offset shrinks each frame, so the union of the cell and the current
        // offset would shrink too and leave the earlier, farther-out block
        // pixels unpainted (smearing the block across cells).
        var dirty = rect.union(offsetRect)
        if let lastDrawnCursorRect { dirty = dirty.union(lastDrawnCursorRect) }
        setNeedsDisplay(snappedToPixels(dirty))
    }

    /// Layer-space rect of the cursor cell (including any glide offset);
    /// the preedit anchors to it.
    func cursorAnchorRect() -> CGRect? {
        cursorCellRect().map {
            $0.offsetBy(dx: cursorGlideOffset.width, dy: cursorGlideOffset.height)
        }
    }

    override func draw(in context: CGContext) {
        let signpost = Signpost.render.beginInterval("gridDraw")
        defer { Signpost.render.endInterval("gridDraw", signpost) }
        guard let snapshot, let grid = snapshot.grid, !grid.isEmpty else { return }
        let cellHeight = metrics.cellSize.height
        let clip = context.boundingBoxOfClipPath.intersection(bounds)
        guard !clip.isEmpty else { return }

        // The regions to repaint: the flushed cells if this cycle came from a
        // flush, otherwise the clip (a cursor blink or preedit change). Using
        // the individual regions — not their bounding box — keeps a flush that
        // touched two far-apart cells from shaping every row in between.
        var dirtyRects = pendingCellRects.compactMap { rect -> CGRect? in
            let pixelRect = snappedToPixels(pixelRect(for: rect)).intersection(bounds)
            return pixelRect.isEmpty ? nil : pixelRect
        }
        pendingCellRects.removeAll(keepingCapacity: true)
        if dirtyRects.isEmpty { dirtyRects = [clip] }

        let minY = dirtyRects.map(\.minY).min() ?? 0
        let maxY = dirtyRects.map(\.maxY).max() ?? 0
        let firstRow = max(0, Int(floor(minY / cellHeight)))
        let lastRow = min(grid.height - 1, Int(floor(maxY / cellHeight)))
        guard firstRow <= lastRow else { return }
        let dirtyBounds = CGRect(x: clip.minX, y: minY, width: clip.width, height: maxY - minY)

        // Resolve each highlight id once per frame instead of once per run.
        var colorCache: [Int: ResolvedColors] = [:]
        for row in firstRow...lastRow {
            let runs = CellRenderer.runs(forRow: grid.rowSlice(row))

            // Background pass, in layer coordinates (y down). Runs without an
            // explicit background stay transparent, letting the view's
            // default-background fill show through.
            for run in runs {
                let runRect = rect(for: run, row: row)
                guard dirtyRects.contains(where: { $0.intersects(runRect) }) else { continue }
                guard let background = color(for: run.attrId, cache: &colorCache).background else { continue }
                context.setFillColor(background.cgColor)
                context.fill(snappedToPixels(runRect))
            }

            // Text pass, in Core Text coordinates (y up).
            context.saveGState()
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            for run in runs where !run.text.isEmpty {
                guard dirtyRects.contains(where: { $0.intersects(rect(for: run, row: row)) }) else { continue }
                drawText(
                    run: run,
                    row: row,
                    colors: color(for: run.attrId, cache: &colorCache),
                    context: context
                )
            }
            context.restoreGState()
        }

        drawCursor(dirtyBounds, context: context)
        drawPreedit(dirtyBounds, context: context)
    }

    private func pixelRect(for cellRect: CellRect) -> CGRect {
        let cellWidth = metrics.cellSize.width
        let cellHeight = metrics.cellSize.height
        return CGRect(
            x: CGFloat(cellRect.minCol) * cellWidth,
            y: CGFloat(cellRect.minRow) * cellHeight,
            width: CGFloat(cellRect.maxCol - cellRect.minCol) * cellWidth,
            height: CGFloat(cellRect.maxRow - cellRect.minRow) * cellHeight
        )
    }

    private func rect(for run: StyledRun, row: Int) -> CGRect {
        CGRect(
            x: CGFloat(run.startCol) * metrics.cellSize.width,
            y: CGFloat(row) * metrics.cellSize.height,
            width: CGFloat(run.endCol - run.startCol) * metrics.cellSize.width,
            height: metrics.cellSize.height
        )
    }

    /// Round a rect to backing-pixel boundaries so filled cell rects and
    /// cursor bars land on whole pixels instead of straddling two.
    private func snappedToPixels(_ rect: CGRect) -> CGRect {
        let scale = contentsScale
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

    private struct ResolvedColors {
        var foreground: NSColor
        var background: NSColor?
        var special: NSColor
    }

    private func color(for attrId: Int, cache: inout [Int: ResolvedColors]) -> ResolvedColors {
        if let cached = cache[attrId] { return cached }
        let resolved = resolvedColors(for: attrId)
        cache[attrId] = resolved
        return resolved
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
        context: CGContext,
        translation: CGSize = .zero
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

        let baseline = CGFloat(row) * metrics.cellSize.height + metrics.baseline + translation.height
        let textY = bounds.height - baseline
        let originX = CGFloat(run.startCol) * metrics.cellSize.width + translation.width
        drawPinned(line: line, slots: run.slots, originX: originX, textY: textY, context: context)

        let thickness = max(1, CTFontGetUnderlineThickness(ctFont))
        let startX = CGFloat(run.startCol) * metrics.cellSize.width + translation.width
        let endX = CGFloat(run.endCol) * metrics.cellSize.width + translation.width
        let underlineY = textY + CTFontGetUnderlinePosition(ctFont)

        if attr.underline || attr.undercurl {
            let path = CGMutablePath()
            if attr.undercurl {
                addUndercurl(to: path, from: startX, to: endX, y: underlineY, thickness: thickness)
            } else {
                path.move(to: CGPoint(x: startX, y: underlineY))
                path.addLine(to: CGPoint(x: endX, y: underlineY))
            }
            context.setStrokeColor(colors.special.cgColor)
            context.setLineWidth(thickness)
            context.addPath(path)
            context.strokePath()
        }

        if attr.strikethrough {
            let strikeY = textY + CTFontGetXHeight(ctFont) / 2
            context.setStrokeColor(colors.special.cgColor)
            context.setLineWidth(thickness)
            context.strokeLineSegments(between: [
                CGPoint(x: startX, y: strikeY),
                CGPoint(x: endX, y: strikeY),
            ])
        }
    }

    /// Draws a shaped line with every cell's glyph cluster pinned to its
    /// grid origin. Fallback fonts (CJK, emoji) advance by their own metrics
    /// instead of whole cells, so a naive CTLineDraw drifts text off the
    /// grid; each equal-correction glyph group is drawn as one shifted
    /// CTRunDraw range instead (see `CellRenderer.shiftGroups`). Slot columns
    /// are relative to `originX`, the run's first cell.
    private func drawPinned(
        line: CTLine,
        slots: [StyledRunSlot],
        originX: CGFloat,
        textY: CGFloat,
        context: CGContext
    ) {
        let groups = CellRenderer.shiftGroups(
            for: line,
            slots: slots,
            cellWidth: metrics.cellSize.width
        )
        for group in groups {
            context.textPosition = CGPoint(x: originX + group.dx, y: textY)
            CTRunDraw(group.run, context, group.range)
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

    private func cursorCellRect() -> CGRect? {
        guard let snapshot, let grid = snapshot.grid,
              snapshot.cursor.grid == 1,
              snapshot.cursor.row >= 0, snapshot.cursor.row < grid.height,
              snapshot.cursor.col >= 0, snapshot.cursor.col < grid.width else {
            return nil
        }
        return CGRect(
            x: CGFloat(snapshot.cursor.col) * metrics.cellSize.width,
            y: CGFloat(snapshot.cursor.row) * metrics.cellSize.height,
            width: metrics.cellSize.width * CGFloat(cursorCellCols(grid)),
            height: metrics.cellSize.height
        )
    }

    /// Columns the cursor covers: two when it sits on a double-width char,
    /// which nvim marks with an empty-text continuation cell.
    private func cursorCellCols(_ grid: Grid) -> Int {
        let row = snapshot?.cursor.row ?? 0
        let col = snapshot?.cursor.col ?? 0
        guard col + 1 < grid.width else { return 1 }
        return grid[row, col + 1].text.isEmpty ? 2 : 1
    }

    private func drawCursor(_ dirtyRect: CGRect, context: CGContext) {
        guard cursorVisible, let snapshot,
              let cellRect = cursorCellRect()?
                  .offsetBy(dx: cursorGlideOffset.width, dy: cursorGlideOffset.height)
        else { return }
        lastDrawnCursorRect = cellRect
        let mode = snapshot.cursorModeInfo
        let colors = resolvedColors(for: cursorCellAttrId(snapshot))

        switch mode?.cursorShape ?? .block {
        case .block:
            context.setFillColor(colors.foreground.cgColor)
            context.fill(snappedToPixels(cellRect.intersection(dirtyRect)))
            // Redraw the glyph under the block, swapped to the background color.
            guard let grid = snapshot.grid else { return }
            let cell = grid[snapshot.cursor.row, snapshot.cursor.col]
            guard !cell.text.isEmpty else { return }
            let cols = cursorCellCols(grid)
            let run = StyledRun(
                text: cell.text,
                attrId: cell.attrId,
                startCol: snapshot.cursor.col,
                endCol: snapshot.cursor.col + cols,
                slots: [StyledRunSlot(utf16: 0, col: 0, cols: cols)]
            )
            let swapped = ResolvedColors(
                foreground: colors.background ?? fallbackBackground,
                background: nil,
                special: colors.special
            )
            context.saveGState()
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            drawText(
                run: run,
                row: snapshot.cursor.row,
                colors: swapped,
                context: context,
                translation: cursorGlideOffset
            )
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
            context.setFillColor(colors.foreground.cgColor)
            context.fill(snappedToPixels(bar.intersection(dirtyRect)))
        case .vertical:
            let percentage = CGFloat(mode?.cellPercentage ?? 25)
            let width = max(1, (cellRect.width * percentage / 100).rounded())
            let bar = CGRect(
                x: cellRect.minX,
                y: cellRect.minY,
                width: width,
                height: cellRect.height
            )
            context.setFillColor(colors.foreground.cgColor)
            context.fill(snappedToPixels(bar.intersection(dirtyRect)))
        }
    }

    private func cursorCellAttrId(_ snapshot: ScreenSnapshot) -> Int {
        guard let grid = snapshot.grid,
              snapshot.cursor.row < grid.height, snapshot.cursor.col < grid.width else {
            return 0
        }
        return grid[snapshot.cursor.row, snapshot.cursor.col].attrId
    }

    // MARK: - Preedit (marked text)

    /// Draws the IME composition at the cursor: the underlying cells are
    /// cleared, the preedit string is drawn with an accent underline, and a
    /// bar marks the selection position inside it.
    private func drawPreedit(_ dirtyRect: CGRect, context: CGContext) {
        guard let preedit, let snapshot, let anchor = cursorCellRect() else { return }
        let rect = preeditRect(for: preedit, range: NSRange(
            location: 0,
            length: preedit.text.utf16.count
        )).intersection(bounds)
        guard !rect.isEmpty, rect.intersects(dirtyRect) else { return }

        // Follow the nvim colorscheme (or the adaptive defaults) instead of
        // always clearing with the system background color.
        let colors = resolvedColors(for: 0)
        context.setFillColor((colors.background ?? fallbackBackground).cgColor)
        context.fill(snappedToPixels(rect))

        // The selection bar uses layer coordinates, so it must be filled
        // before the Core Text coordinate flip below.
        let selectionCells = TerminalView.cellOffset(of: preedit.text, upToUTF16: preedit.selection.location)
        let bar = snappedToPixels(CGRect(
            x: anchor.minX + CGFloat(selectionCells) * metrics.cellSize.width,
            y: anchor.minY,
            width: 2,
            height: anchor.height
        ))
        context.setFillColor(colors.foreground.cgColor)
        context.fill(bar)

        context.saveGState()
        context.clip(to: CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height))
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)

        let font = fonts.regular
        let attributed = NSAttributedString(string: preedit.text, attributes: [
            .font: font,
            .foregroundColor: colors.foreground,
        ])
        let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)

        // Pin each character to its cells so committed-width previews (CJK
        // spans two cells) stay aligned with the bar and underline.
        var slots: [StyledRunSlot] = []
        var offset = 0
        var col = 0
        for character in preedit.text {
            let cols = CellRenderer.isDoubleWidth(String(character)) ? 2 : 1
            slots.append(StyledRunSlot(utf16: offset, col: col, cols: cols))
            offset += String(character).utf16.count
            col += cols
        }
        let textY = bounds.height - (anchor.minY + metrics.baseline)
        drawPinned(line: line, slots: slots, originX: anchor.minX, textY: textY, context: context)

        let underlineY = textY + CTFontGetUnderlinePosition(font as CTFont)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(max(1, CTFontGetUnderlineThickness(font as CTFont)))
        context.strokeLineSegments(between: [
            CGPoint(x: rect.minX, y: underlineY),
            CGPoint(x: rect.maxX, y: underlineY),
        ])

        context.restoreGState()
    }

    private func preeditRect(for preedit: Preedit, range: NSRange) -> CGRect {
        guard let anchor = cursorCellRect() else { return .zero }
        let cellWidth = metrics.cellSize.width
        let start = TerminalView.cellOffset(of: preedit.text, upToUTF16: range.location)
        let end = TerminalView.cellOffset(of: preedit.text, upToUTF16: range.location + range.length)
        return CGRect(
            x: anchor.minX + CGFloat(start) * cellWidth,
            y: anchor.minY,
            width: CGFloat(max(end - start, 1)) * cellWidth,
            height: anchor.height
        )
    }

    /// Colors for when nvim leaves a default unset (-1): adaptive AppKit
    /// colors, so the surface follows dark/light mode.
    private var fallbackForeground: NSColor { .textColor }
    private var fallbackBackground: NSColor { .textBackgroundColor }
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
