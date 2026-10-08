import AppKit
import CoreText

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

    init(metrics: FontMetrics) {
        self.metrics = metrics
        self.fonts = FontVariants(metrics.font)
        super.init()
        isGeometryFlipped = true
        needsDisplayOnBoundsChange = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
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
            bounds = CGRect(origin: .zero, size: size)
        }
    }

    /// Mark a cell-coordinate region dirty.
    func invalidate(cellRect: CellRect) {
        setNeedsDisplay(snappedToPixels(pixelRect(for: cellRect)))
    }

    func invalidateCursor() {
        guard let rect = cursorCellRect() else { return }
        let offsetRect = rect.offsetBy(dx: cursorGlideOffset.width, dy: cursorGlideOffset.height)
        setNeedsDisplay(snappedToPixels(rect.union(offsetRect)))
    }

    /// Layer-space rect of the cursor cell (including any glide offset);
    /// the preedit anchors to it.
    func cursorAnchorRect() -> CGRect? {
        cursorCellRect().map {
            $0.offsetBy(dx: cursorGlideOffset.width, dy: cursorGlideOffset.height)
        }
    }

    override func draw(in context: CGContext) {
        guard let snapshot, let grid = snapshot.grid, !grid.isEmpty else { return }
        let cellHeight = metrics.cellSize.height
        let dirtyRect = context.boundingBoxOfClipPath.intersection(bounds)
        guard !dirtyRect.isEmpty else { return }

        let firstRow = max(0, Int(floor(dirtyRect.minY / cellHeight)))
        let lastRow = min(grid.height - 1, Int(floor(dirtyRect.maxY / cellHeight)))
        guard firstRow <= lastRow else { return }

        for row in firstRow...lastRow {
            var cells = [GridCell]()
            cells.reserveCapacity(grid.width)
            for col in 0..<grid.width {
                cells.append(grid[row, col])
            }
            let runs = CellRenderer.runs(forRow: cells)

            // Background pass, in layer coordinates (y down). Runs without an
            // explicit background stay transparent, letting the view's
            // default-background fill show through.
            for run in runs {
                let runRect = rect(for: run, row: row)
                guard runRect.intersects(dirtyRect) else { continue }
                guard let background = resolvedColors(for: run.attrId).background else { continue }
                context.setFillColor(background.cgColor)
                context.fill(snappedToPixels(runRect))
            }

            // Text pass, in Core Text coordinates (y up).
            context.saveGState()
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            for run in runs where !run.text.isEmpty {
                guard rect(for: run, row: row).intersects(dirtyRect) else { continue }
                drawText(run: run, row: row, colors: resolvedColors(for: run.attrId), context: context)
            }
            context.restoreGState()
        }

        drawCursor(dirtyRect, context: context)
        drawPreedit(dirtyRect, context: context)
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
        context.textPosition = CGPoint(
            x: CGFloat(run.startCol) * metrics.cellSize.width + translation.width,
            y: textY
        )
        CTLineDraw(line, context)

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
            width: metrics.cellSize.width,
            height: metrics.cellSize.height
        )
    }

    private func drawCursor(_ dirtyRect: CGRect, context: CGContext) {
        guard cursorVisible, let snapshot,
              let cellRect = cursorCellRect()?
                  .offsetBy(dx: cursorGlideOffset.width, dy: cursorGlideOffset.height)
        else { return }
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
            let width = CellRenderer.isDoubleWidth(cell.text) ? 2 : 1
            let run = StyledRun(
                text: cell.text,
                attrId: cell.attrId,
                startCol: snapshot.cursor.col,
                endCol: snapshot.cursor.col + width
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

        context.setFillColor(fallbackBackground.cgColor)
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
        context.setFillColor(fallbackForeground.cgColor)
        context.fill(bar)

        context.saveGState()
        context.clip(to: CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height))
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)

        let font = fonts.regular
        let attributed = NSAttributedString(string: preedit.text, attributes: [
            .font: font,
            .foregroundColor: fallbackForeground,
        ])
        let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
        let textY = bounds.height - (anchor.minY + metrics.baseline)
        context.textPosition = CGPoint(x: anchor.minX, y: textY)
        CTLineDraw(line, context)

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
