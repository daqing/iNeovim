import AppKit

/// Native popover listing the `vim.diagnostic` entries on one line, shown
/// when the user clicks a diagnostic sign in the gutter. Built on NSPopover
/// so dismissal (click outside), theming, and the arrow come for free; the
/// messages are selectable so they can be copied.
final class DiagnosticPopover {
    private static let maxTextWidth: CGFloat = 440
    private static let minTextWidth: CGFloat = 220
    private static let sidePadding: CGFloat = 12
    private static let verticalPadding: CGFloat = 10
    private static let itemSpacing: CGFloat = 8
    private static let dotSize: CGFloat = 8
    private static let dotGap: CGFloat = 8
    private static let metaGap: CGFloat = 2
    private static let unboundedRect = NSRect(
        x: 0, y: 0,
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
    )

    private let popover = NSPopover()

    var isShown: Bool { popover.isShown }

    init() {
        popover.behavior = .transient
    }

    func close() {
        guard popover.isShown else { return }
        popover.close()
    }

    /// Build the content view for the diagnostics and show the popover
    /// anchored at the clicked sign cell. `themeIsDark` picks the popover
    /// appearance to match the nvim theme driving the window chrome.
    func present(
        items: [LineDiagnostic],
        relativeTo rect: CGRect,
        of view: NSView,
        themeIsDark: Bool?
    ) {
        guard !items.isEmpty else { return }
        close()
        if let themeIsDark {
            popover.appearance = NSAppearance(named: themeIsDark ? .darkAqua : .aqua)
        } else {
            popover.appearance = nil
        }
        let content = PopoverContentView()
        let size = Self.layout(items: items, in: content)
        content.frame = CGRect(origin: .zero, size: size)
        // NSViewController has no view-taking initializer on macOS.
        let viewController = NSViewController()
        viewController.view = content
        popover.contentViewController = viewController
        popover.contentSize = size
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }

    /// Frame every subview manually (same style as the completion panel) and
    /// return the fitted content size; a flipped container makes the top-down
    /// item math direct.
    private static func layout(items: [LineDiagnostic], in content: NSView) -> CGSize {
        let font = NSFont.systemFont(ofSize: 13)
        let metaFont = NSFont.systemFont(ofSize: 11)
        // NSFont has no lineHeight; the classic metric sum is its equivalent.
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let metaLineHeight = ceil(metaFont.ascender - metaFont.descender + metaFont.leading)
        // Fit the widest message, clamped: short errors get a small popover,
        // long compiler output wraps at the cap instead of running off-screen.
        // Measure with the label cell, not `NSString`: the cell insets its
        // text by 2 pt per side and its single-line width is that much wider
        // than `NSString.size(withAttributes:)`. At the narrower width a
        // message that only just fits wrapped its last word onto a second
        // line that the old height calculation did not reserve, so the
        // popover showed "E302 expected 2 blank lines, found " clipped
        // before the count.
        let labels = items.map { item -> NSTextField in
            let label = NSTextField(wrappingLabelWithString: item.message)
            label.font = font
            return label
        }
        let naturalWidth = labels
            .map { $0.cell?.cellSize(forBounds: Self.unboundedRect).width ?? minTextWidth }
            .max() ?? minTextWidth
        let textWidth = min(max(ceil(naturalWidth), minTextWidth), maxTextWidth)

        let rows: [(item: LineDiagnostic, label: NSTextField, messageHeight: CGFloat, meta: String)] =
            items.indices.map { index in
            let item = items[index]
            let label = labels[index]
            let measured = label.cell?.cellSize(forBounds: NSRect(
                x: 0, y: 0,
                width: textWidth,
                height: Self.unboundedRect.height
            )).height ?? lineHeight
            let meta = [item.source, item.code].filter { !$0.isEmpty }.joined(separator: " · ")
            return (item, label, ceil(max(measured, lineHeight)) + 2, meta)
        }

        let textX = sidePadding + dotSize + dotGap
        let width = textX + textWidth + sidePadding

        var y = verticalPadding
        for row in rows {
            let dot = NSView(frame: CGRect(
                x: sidePadding,
                y: y + (lineHeight - dotSize) / 2,
                width: dotSize,
                height: dotSize
            ))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = severityColor(row.item.severity).cgColor
            dot.layer?.cornerRadius = dotSize / 2
            content.addSubview(dot)

            let message = row.label
            message.textColor = .labelColor
            message.isSelectable = true
            message.setFrameOrigin(CGPoint(x: textX, y: y))
            message.setFrameSize(CGSize(width: textWidth, height: row.messageHeight))
            content.addSubview(message)

            y += row.messageHeight
            if !row.meta.isEmpty {
                let meta = NSTextField(labelWithString: row.meta)
                meta.font = metaFont
                meta.textColor = .secondaryLabelColor
                meta.cell?.truncatesLastVisibleLine = true
                meta.cell?.wraps = false
                meta.setFrameOrigin(CGPoint(x: textX, y: y + metaGap))
                meta.setFrameSize(CGSize(width: textWidth, height: metaLineHeight))
                content.addSubview(meta)
                y += metaGap + metaLineHeight
            }
            y += itemSpacing
        }

        let height = y - itemSpacing + verticalPadding
        return CGSize(width: width, height: height)
    }

    private static func severityColor(_ severity: LineDiagnostic.Severity) -> NSColor {
        switch severity {
        case .error: .systemRed
        case .warning: .systemYellow
        case .info: .systemBlue
        case .hint: .systemGray
        }
    }
}

/// Flipped container so diagnostics stack top-down in AppKit coordinates.
private final class PopoverContentView: NSView {
    override var isFlipped: Bool { true }
}
