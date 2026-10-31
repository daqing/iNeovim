import AppKit
import CoreText
import os

/// The grid surface: owns drawing of one nvim grid's cells, the cursor, and
/// the IME preedit, so the animator can translate a scrolling window grid
/// while the view behind it keeps painting the background. One instance per
/// displayed grid: the global grid (separators, statusline, message-area
/// fill), every split window's grid, and each float or the message grid.
final class GridContentLayer: CALayer {
    struct Preedit: Equatable {
        var text: String
        var selection: NSRange
    }

    private(set) var snapshot: ScreenSnapshot?
    /// The nvim grid this layer draws (1 = the global grid).
    let gridId: Int
    /// The grid's layout from the latest snapshot: global row/col the layer
    /// is placed at, and what kind of grid it is. Row math needs it to keep
    /// the global grid's cmdline gap consistent across grids.
    private(set) var gridFrame = GridFrame(row: 0, col: 0)
    private(set) var metrics: FontMetrics
    private var fonts: FontVariants
    var preedit: Preedit?
    var cursorVisible = true {
        didSet { invalidateCursor() }
    }
    /// Grid rect of the ⌘-hovered link, underlined on top of the cells. nil
    /// when no link is hovered.
    var linkUnderline: CellRect? {
        didSet {
            guard linkUnderline != oldValue else { return }
            var dirty = CGRect.null
            for rect in [oldValue, linkUnderline].compactMap({ $0 }).compactMap({ clamped(toGrid: $0) }) {
                dirty = dirty.union(snappedToPixels(pixelRect(for: rect)))
            }
            guard !dirty.isNull else { return }
            setNeedsDisplay(dirty.intersection(bounds))
        }
    }
    /// Translation applied to the drawn cursor while it glides between cells.
    var cursorGlideOffset: CGSize = .zero {
        didSet { invalidateCursor() }
    }
    /// Buffer text areas of the current tabpage (from nvim's
    /// `ineovim:textlayout` notification). Cells in these ranges are drawn
    /// `NvimTextLayout.textShift` right of their cell origin, so buffer text
    /// clears the window's gutter; the gutter, the statusline row, and the
    /// cmdline row are outside every region and stay on the grid.
    var textRegions: [NvimTextRegion] = [] {
        didSet {
            guard textRegions != oldValue else { return }
            setNeedsDisplay()
        }
    }
    /// Layer-space rect the cursor was last drawn at, so a glide can invalidate
    /// the position it is leaving in addition to the one it is moving to.
    private var lastDrawnCursorRect: CGRect?

    /// Shaped lines and their cell-pinning groups, keyed by everything that
    /// affects shaping. A scroll repaints the whole viewport, but the rows it
    /// repaints are the rows that were already on screen (shifted by a line),
    /// so without this every wheel step re-shaped every visible run with Core
    /// Text — the dominant cost of a scroll frame.
    private var lineCache: [LineKey: CachedLine] = [:]
    private static let lineCacheLimit = 2048

    private struct LineKey: Hashable {
        var text: String
        var variant: FontVariants.Variant
        var foregroundKey: Int
    }

    private struct CachedLine {
        var line: CTLine
        var groups: [CellRenderer.GlyphShiftGroup]
    }

    /// Cache key for an adaptive AppKit foreground; nvim's packed colors are
    /// non-negative, so the sentinels cannot collide with them.
    static let adaptiveForegroundKey = -1
    static func statuslineForegroundKey(themeIsDark: Bool?) -> Int {
        switch themeIsDark {
        case .some(true): return -2
        case .some(false): return -3
        case .none: return -4
        }
    }

    init(metrics: FontMetrics, gridId: Int = 1) {
        self.metrics = metrics
        self.gridId = gridId
        self.fonts = FontVariants(metrics.font)
        super.init()
        // The host view is flipped, so the layer inherits a top-left origin;
        // leaving this false keeps the grid's y-down drawing math correct.
        isGeometryFlipped = false
        needsDisplayOnBoundsChange = true
        // A stale backing store (a frame that moved before the repaint, e.g.
        // the message grid re-parked on the cmdline row) must never stretch
        // into the new bounds: draw it at its own size, top-left anchored,
        // so at worst one unchanged row band shows instead of a squashed
        // blend of the whole old grid.
        contentsGravity = .topLeft
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
        self.gridId = source?.gridId ?? 1
        self.gridFrame = source?.gridFrame ?? GridFrame(row: 0, col: 0)
        self.fonts = FontVariants(metrics.font)
        super.init(layer: layer)
        if let source {
            snapshot = source.snapshot
            preedit = source.preedit
            cursorVisible = source.cursorVisible
            cursorGlideOffset = source.cursorGlideOffset
            linkUnderline = source.linkUnderline
            textRegions = source.textRegions
        }
    }

    /// Apply a fresh snapshot and resize to the grid's content size (the
    /// bounds change invalidates the whole layer). `gridFrame` carries the
    /// grid's global placement from the same snapshot.
    func update(snapshot: ScreenSnapshot) {
        let previousStatuslineRow = effectiveStatuslineRow()
        if let previous = self.snapshot,
           previous.highlights != snapshot.highlights
            || previous.defaultForeground != snapshot.defaultForeground
            || previous.defaultBackground != snapshot.defaultBackground
            || previous.defaultSpecial != snapshot.defaultSpecial {
            lineCache.removeAll(keepingCapacity: true)
        }
        self.snapshot = snapshot
        let previousFrame = gridFrame
        if let newFrame = snapshot.frames[gridId] {
            gridFrame = newFrame
        }
        // A moved frame (the message grid re-parked by `msg_set_pos`, a split
        // repositioned by `win_pos`) invalidates every cached position: row
        // y math, the cmdline gap, the visible band. Repaint the whole layer
        // from the new frame instead of trusting dirty rects that describe
        // the move's destination row only — otherwise the old bitmap's
        // content lingers at the new position (a ghost message row on the
        // cmdline row). Full invalidation is cheap: the visible band of a
        // moved grid is a handful of rows.
        if gridFrame != previousFrame {
            setNeedsDisplay()
        }
        // The statusline special-casing can flip without grid 1 receiving
        // dirty rects for the row (a flush may only carry `msg_set_pos`), so
        // repaint both rows whenever it changes.
        let statuslineRow = effectiveStatuslineRow()
        if statuslineRow != previousStatuslineRow, let target = snapshot.grids[gridId] {
            var dirty = CGRect.null
            for row in [previousStatuslineRow, statuslineRow].compactMap({ $0 })
            where row < target.height {
                dirty = dirty.union(pixelRect(for: CellRect(
                    minRow: row, minCol: 0, maxRow: row + 1, maxCol: target.width
                )))
            }
            if !dirty.isNull {
                let clipped = dirty.intersection(bounds)
                if !clipped.isNull {
                    setNeedsDisplay(snappedToPixels(clipped))
                }
            }
        }
        let grid = snapshot.grids[gridId]
        let size: CGSize
        if let grid, !grid.isEmpty {
            // A grid whose rows extend past the global grid (the message
            // grid's capacity is a full screen) only draws the visible band.
            let visibleRows = min(grid.height, max(1, globalGridHeight - gridFrame.row))
            let top = rowY(0)
            let bottom = rowY(visibleRows - 1) + metrics.cellSize.height
            size = CGSize(
                // The extra band beyond the last cell keeps a shifted last
                // column (glyph, cursor) inside the layer and its clip.
                width: CGFloat(grid.width) * metrics.cellSize.width + NvimTextLayout.textShift,
                height: bottom - top
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
        lineCache.removeAll(keepingCapacity: true)
        setNeedsDisplay()
    }

    /// Drop cached shaping. The adaptive fallback colors (`NSColor.textColor`)
    /// resolve against the appearance current when the line was shaped, so a
    /// system light/dark switch must re-shape even though no highlight changed.
    func invalidateShaping() {
        lineCache.removeAll(keepingCapacity: true)
    }

    /// Mark one or more cell-coordinate regions dirty. A flush covers the
    /// whole grid, so each rect is clamped to this grid and one outside it is
    /// dropped.
    func invalidate(cellRects: [CellRect]) {
        let mine = cellRects.compactMap(clamped(toGrid:))
        guard !mine.isEmpty else { return }
        for rect in mine {
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
    /// the preedit anchors to it. Nil when this grid does not hold the
    /// snapshot's cursor, which is how the other layers skip drawing it.
    func cursorAnchorRect() -> CGRect? {
        cursorCellRect().map {
            $0.offsetBy(dx: cursorGlideOffset.width, dy: cursorGlideOffset.height)
        }
    }

    /// Layer-space rect of a snapshot's cursor cell without the glide
    /// offset — the from/to geometry the cursor glide animates between;
    /// nil when that snapshot's cursor is not on this grid.
    func cursorRestRect(in snap: ScreenSnapshot?) -> CGRect? {
        cursorCellRect(snap)
    }

    override func draw(in context: CGContext) {
        let signpost = Signpost.render.beginInterval("gridDraw")
        defer { Signpost.render.endInterval("gridDraw", signpost) }
        guard let snapshot, let grid, !grid.isEmpty else { return }
        let cellHeight = metrics.cellSize.height
        let clip = context.boundingBoxOfClipPath.intersection(bounds)
        guard !clip.isEmpty else { return }

        // The clip is the contract: Core Animation clears every pixel inside
        // it before this call, so whatever is not repainted here is erased.
        // Invalidations come from several paths — a flush's cells, the
        // cursor's blink and glide, the link underline, the IME preedit — and
        // a display pass can carry more than one of them, so the clip, not a
        // record of the flushed cells, decides what is repainted. (Painting
        // only the flushed rects left the rest of a merged clip blank: after
        // a search jump, the cursor invalidation's band ran from the cell the
        // cursor was last drawn at to the new one, and every character in
        // between stayed missing until nvim repainted those rows.) The clip's
        // band narrows the rows and the shaped-line cache absorbs the
        // repeats.
        let minY = clip.minY
        let maxY = clip.maxY
        // Rows of this grid that overlap the dirty band. Testing the rows
        // instead of dividing y by the cell height keeps rows clear of the
        // cmdline gap — the global grid's last row sits that gap lower than
        // its slot.
        let rows = (0..<grid.height).filter { rowY($0) < maxY && rowY($0) + cellHeight > minY }
        guard !rows.isEmpty else { return }

        // Resolve each highlight id once per frame instead of once per run.
        var colorCache: [Int: ResolvedColors] = [:]
        // The global grid's statusline row sits on the view's opposite-mode
        // bar: its cells stay transparent so the bar shows through, and its
        // text draws in the opposite mode's default foreground — the theme's
        // per-run colors match the editor background, not the bar. Window
        // grids have no statusline row; it lives on the global grid. A
        // visible message grid covering the row (error messages, the
        // hit-enter prompt) turns it back into an ordinary message row.
        let statuslineRow = effectiveStatuslineRow() ?? -1
        let statuslineTheme = TerminalView.hasDarkBackground(snapshot.defaultBackground)
        let statuslineText = TerminalView.statuslineColors(themeIsDark: statuslineTheme).foreground
        let statuslineKey = Self.statuslineForegroundKey(themeIsDark: statuslineTheme)
        for row in rows {
            let runs = CellRenderer.runs(forRow: grid.rowSlice(row))

            // Background pass, in layer coordinates (y down). Runs without an
            // explicit background stay transparent, letting the view's
            // default-background fill show through.
            for run in runs {
                let runRect = rect(for: run, row: row)
                guard runRect.intersects(clip) else { continue }
                guard row != statuslineRow,
                      let background = color(for: run.attrId, cache: &colorCache).fillBackground else { continue }
                context.setFillColor(background.cgColor)
                context.fill(snappedToPixels(runRect))
            }

            // Text pass, in Core Text coordinates (y up).
            context.saveGState()
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            for run in runs where !run.text.isEmpty {
                guard rect(for: run, row: row).intersects(clip) else { continue }
                drawText(
                    run: run,
                    row: row,
                    colors: row == statuslineRow
                        ? ResolvedColors(
                            foreground: statuslineText,
                            background: nil,
                            fillBackground: nil,
                            special: statuslineText,
                            foregroundKey: statuslineKey
                        )
                        : color(for: run.attrId, cache: &colorCache),
                    context: context
                )
            }
            context.restoreGState()
        }

        drawCursor(clip, context: context)
        drawPreedit(clip, context: context)
        drawLinkUnderline(context: context)
    }

    /// Y of one of this grid's rows in layer space: the row's global y (which
    /// carries the cmdline gap on the global grid's last row) minus the
    /// layer's own origin, so a grid whose rows reach the global last row
    /// (the message grid, the global grid itself) keeps the gap continuous
    /// through its rows.
    private func rowY(_ row: Int) -> CGFloat {
        globalRowY(gridFrame.row + row) - originY
    }

    /// Global-grid y of a global row's top edge (cmdline gap on the last row).
    private func globalRowY(_ globalRow: Int) -> CGFloat {
        TerminalView.gridRowY(
            globalRow,
            gridHeight: globalGridHeight,
            cellHeight: metrics.cellSize.height
        )
    }

    /// Layer-space y of the grid's first row — the offset the terminal
    /// positions the layer at, so its rows land where the global grid puts
    /// them.
    var originY: CGFloat { globalRowY(gridFrame.row) }

    private var globalGridHeight: Int { snapshot?.grid?.height ?? 0 }

    private var grid: Grid? { snapshot?.grids[gridId] }

    /// The global grid's statusline row — the one drawn on the view's
    /// inverted bar — or nil when this grid has none (window/float/message
    /// grids) or a visible message grid covers it: while messages occupy the
    /// bottom rows, that row carries a message, not the statusline.
    private func effectiveStatuslineRow() -> Int? {
        guard gridId == 1, let grid, grid.height >= 2 else { return nil }
        let row = grid.height - 2
        return snapshot?.messageGridCovers(row: row) == true ? nil : row
    }

    /// Clamp a cell rect to this grid's rows and columns; nil when the rect
    /// lies entirely outside the grid.
    private func clamped(toGrid rect: CellRect) -> CellRect? {
        guard let grid = snapshot?.grids[gridId] else { return nil }
        let minRow = max(rect.minRow, 0)
        let maxRow = min(rect.maxRow, grid.height)
        let minCol = max(rect.minCol, 0)
        let maxCol = min(rect.maxCol, grid.width)
        guard minRow < maxRow, minCol < maxCol else { return nil }
        return CellRect(minRow: minRow, minCol: minCol, maxRow: maxRow, maxCol: maxCol)
    }

    /// A cell rect in layer space, a little wider than the cells: the glyphs
    /// and the cursor of a text region are drawn up to `textShift` right of
    /// their cell, and the cursor's block starts that far past its left edge,
    /// so the dirty band has to cover them.
    private func pixelRect(for cellRect: CellRect) -> CGRect {
        let cellWidth = metrics.cellSize.width
        let cellHeight = metrics.cellSize.height
        let shift = NvimTextLayout.textShift
        let y = rowY(cellRect.minRow)
        let bottom = rowY(cellRect.maxRow - 1) + cellHeight
        return CGRect(
            x: CGFloat(cellRect.minCol) * cellWidth - shift,
            y: y,
            width: CGFloat(cellRect.maxCol - cellRect.minCol) * cellWidth + shift * 2,
            height: bottom - y
        )
    }

    /// The horizontal shift for a cell's glyphs: the text inset inside a
    /// window's text area, zero for the gutter, the statusline, and the
    /// cmdline. A run shifts as a whole (by its first cell), because its
    /// pinned glyph groups are shaped and cached without an offset; a run
    /// spanning the gutter boundary can only happen when the gutter and the
    /// text share one highlight, and then it keeps the gutter's alignment.
    /// Text regions arrive in global grid coordinates, so a local cell is
    /// mapped through its grid's frame before the lookup.
    private func textShift(row: Int, column: Int) -> CGFloat {
        let globalRow = gridFrame.row + row
        let globalCol = gridFrame.col + column
        for region in textRegions
        where region.rows.contains(globalRow) && region.columns.contains(globalCol) {
            return NvimTextLayout.textShift
        }
        return 0
    }

    private func rect(for run: StyledRun, row: Int) -> CGRect {
        CGRect(
            x: CGFloat(run.startCol) * metrics.cellSize.width,
            y: rowY(row),
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
        /// The full resolved background, including nvim's default; used where
        /// the color itself matters (the cursor's swapped glyph, preedit).
        var background: NSColor?
        /// The background this run must paint itself; nil when it resolves to
        /// the default, which the view's layer already paints underneath.
        var fillBackground: NSColor?
        var special: NSColor
        /// Shaping-cache discriminator for the foreground: the packed nvim
        /// color, or a sentinel for an adaptive AppKit color.
        var foregroundKey: Int
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
        let background = resolved.background.flatMap(NSColor.init(packedRGB:))
        // The view's own layer already paints the default background, so
        // filling it per run only repaints the whole viewport on every
        // scroll frame for no visible change.
        let fillBackground = resolved.background == snapshot?.defaultBackground ? nil : background
        return ResolvedColors(
            foreground: foreground,
            background: background,
            fillBackground: fillBackground,
            special: resolved.special.flatMap(NSColor.init(packedRGB:)) ?? foreground,
            foregroundKey: resolved.foreground ?? Self.adaptiveForegroundKey
        )
    }

    private func drawText(
        run: StyledRun,
        row: Int,
        colors: ResolvedColors,
        context: CGContext,
        translation: CGSize = .zero,
        cacheable: Bool = true
    ) {
        let attr = snapshot?.highlights[run.attrId] ?? HlAttr()
        let variant = FontVariants.variant(for: attr)
        let font = fonts.font(variant)
        let ctFont = font as CTFont
        let shaped = shapedLine(
            for: run,
            font: font,
            variant: variant,
            foreground: colors.foreground,
            foregroundKey: colors.foregroundKey,
            cacheable: cacheable
        )

        let baseline = rowY(row) + metrics.baseline + translation.height
        let textY = bounds.height - baseline
        let shift = translation.width + textShift(row: row, column: run.startCol)
        let originX = CGFloat(run.startCol) * metrics.cellSize.width + shift
        drawPinned(groups: shaped.groups, originX: originX, textY: textY, context: context)

        let thickness = max(1, CTFontGetUnderlineThickness(ctFont))
        let startX = CGFloat(run.startCol) * metrics.cellSize.width + shift
        let endX = CGFloat(run.endCol) * metrics.cellSize.width + shift
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
    /// Shape a run, or reuse the cached result when nothing that affects
    /// shaping changed. Scrolling repaints every visible row each step, and
    /// the rows (shifted by a line or two) are mostly the ones already shaped
    /// in the previous frame, so this turns most of a scroll frame's Core Text
    /// work into dictionary lookups.
    private func shapedLine(
        for run: StyledRun,
        font: NSFont,
        variant: FontVariants.Variant,
        foreground: NSColor,
        foregroundKey: Int,
        cacheable: Bool
    ) -> CachedLine {
        let key = LineKey(text: run.text, variant: variant, foregroundKey: foregroundKey)
        if cacheable, let cached = lineCache[key] {
            return cached
        }
        let attributed = NSAttributedString(string: run.text, attributes: [
            .font: font,
            .foregroundColor: foreground,
            // Standard ligatures on: contiguous same-style text is shaped as
            // one CTLine above, so fonts like Fira Code ligate across cells.
            .ligature: 1,
        ])
        let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
        let cached = CachedLine(
            line: line,
            groups: CellRenderer.shiftGroups(
                for: line,
                slots: run.slots,
                cellWidth: metrics.cellSize.width
            )
        )
        if cacheable {
            if lineCache.count >= Self.lineCacheLimit {
                lineCache.removeAll(keepingCapacity: true)
            }
            lineCache[key] = cached
        }
        return cached
    }

    private func drawPinned(
        groups: [CellRenderer.GlyphShiftGroup],
        originX: CGFloat,
        textY: CGFloat,
        context: CGContext
    ) {
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

    /// Layer-space rect of a snapshot's cursor cell without the glide
    /// offset (the applied snapshot by default); nil when that snapshot's
    /// cursor is not on this grid.
    private func cursorCellRect(_ snap: ScreenSnapshot? = nil) -> CGRect? {
        guard let snapshot = snap ?? self.snapshot, let grid, !grid.isEmpty,
              snapshot.cursor.grid == gridId,
              snapshot.cursor.row >= 0, snapshot.cursor.row < grid.height,
              snapshot.cursor.col >= 0, snapshot.cursor.col < grid.width else {
            return nil
        }
        return CGRect(
            x: CGFloat(snapshot.cursor.col) * metrics.cellSize.width
                + textShift(row: snapshot.cursor.row, column: snapshot.cursor.col),
            y: rowY(snapshot.cursor.row),
            width: metrics.cellSize.width * CGFloat(cursorCellCols(grid, snapshot)),
            height: metrics.cellSize.height
        )
    }

    /// Columns the cursor covers: two when it sits on a double-width char,
    /// which nvim marks with an empty-text continuation cell.
    private func cursorCellCols(_ grid: Grid, _ snap: ScreenSnapshot? = nil) -> Int {
        let snapshot = snap ?? self.snapshot
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
            guard let grid else { return }
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
                fillBackground: nil,
                special: colors.special,
                foregroundKey: colors.foregroundKey
            )
            context.saveGState()
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            drawText(
                run: run,
                row: snapshot.cursor.row,
                colors: swapped,
                context: context,
                translation: cursorGlideOffset,
                cacheable: false
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
        guard let grid, snapshot.cursor.row < grid.height, snapshot.cursor.col < grid.width else {
            return 0
        }
        return grid[snapshot.cursor.row, snapshot.cursor.col].attrId
    }

    // MARK: - Link underline

    /// Underline the hovered ⌘-link in the cells' own foreground color, in
    /// layer coordinates (y down) at the font's underline position.
    private func drawLinkUnderline(context: CGContext) {
        guard let rect = linkUnderline, let grid, !grid.isEmpty,
              let sliced = clamped(toGrid: rect) else { return }
        let font = metrics.font
        let ctFont = font as CTFont
        // Match the text pass: the global grid's statusline row draws on the
        // inverted bar and uses the opposite mode's foreground, not the
        // cell's own.
        let statuslineRow = effectiveStatuslineRow() ?? -1
        let color: NSColor
        if sliced.minRow == statuslineRow {
            color = TerminalView.statuslineColors(
                themeIsDark: TerminalView.hasDarkBackground(snapshot?.defaultBackground)
            ).foreground
        } else {
            color = resolvedColors(for: grid[sliced.minRow, sliced.minCol].attrId).foreground
        }
        let y = rowY(sliced.minRow) + metrics.baseline - CTFontGetUnderlinePosition(ctFont)
        let shift = textShift(row: sliced.minRow, column: sliced.minCol)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(max(1, CTFontGetUnderlineThickness(ctFont)))
        context.move(to: CGPoint(x: CGFloat(sliced.minCol) * metrics.cellSize.width + shift, y: y))
        context.addLine(to: CGPoint(x: CGFloat(sliced.maxCol) * metrics.cellSize.width + shift, y: y))
        context.strokePath()
    }

    // MARK: - Preedit (marked text)

    /// Draws the IME composition at the cursor: the underlying cells are
    /// cleared, the preedit string is drawn with an accent underline, and a
    /// bar marks the selection position inside it.
    private func drawPreedit(_ dirtyRect: CGRect, context: CGContext) {
        guard let preedit, snapshot != nil, let anchor = cursorCellRect() else { return }
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
        drawPinned(
            groups: CellRenderer.shiftGroups(
                for: line,
                slots: slots,
                cellWidth: metrics.cellSize.width
            ),
            originX: anchor.minX,
            textY: textY,
            context: context
        )

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
        bold = manager.convert(font, toHaveTrait: .boldFontMask)
        italic = manager.convert(font, toHaveTrait: .italicFontMask)
        boldItalic = manager.convert(font, toHaveTrait: [.boldFontMask, .italicFontMask])
    }

    enum Variant: Hashable {
        case regular, bold, italic, boldItalic
    }

    static func variant(for attr: HlAttr) -> Variant {
        switch (attr.bold, attr.italic) {
        case (true, true): return .boldItalic
        case (true, false): return .bold
        case (false, true): return .italic
        default: return .regular
        }
    }

    func font(for attr: HlAttr) -> NSFont {
        font(Self.variant(for: attr))
    }

    func font(_ variant: Variant) -> NSFont {
        switch variant {
        case .regular: return regular
        case .bold: return bold
        case .italic: return italic
        case .boldItalic: return boldItalic
        }
    }
}
