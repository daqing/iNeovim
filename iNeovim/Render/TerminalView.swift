import AppKit
import CoreText

/// The terminal surface: a layer-backed view that renders the applied grid
/// state from `Screen` with Core Text.
final class TerminalView: NSView {
    private(set) var metrics: FontMetrics
    private var fonts: FontVariants
    private var snapshot: ScreenSnapshot?
    private let resizeController: ResizeController

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

        guard let snapshot, let grid = snapshot.grid, !grid.isEmpty else { return }
        let cellWidth = metrics.cellSize.width
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
                NSBezierPath.fill(runRect)
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
        let foreground = resolved.foreground.flatMap(NSColor.init(packedRGB:)) ?? .textColor
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

    private var backgroundColor: NSColor {
        if let packed = snapshot?.defaultBackground, let color = NSColor(packedRGB: packed) {
            return color
        }
        return .textBackgroundColor
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
        bold = manager.convert(font, toHaveSymbolicTraits: .bold) ?? font
        italic = manager.convert(font, toHaveSymbolicTraits: .italic) ?? font
        boldItalic = manager.convert(font, toHaveSymbolicTraits: [.bold, .italic]) ?? bold
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
