import AppKit

/// The native completion panel for `ext_popupmenu`: a vibrancy-backed list
/// anchored at the cursor. Neovim keeps driving selection through
/// `popupmenu_select`; clicking a row reports back through `onSelect`.
/// `update(_:)` sizes the panel (see `contentSize`); the host view positions
/// it and flips it up when space below the anchor runs out.
final class CompletionPanelView: NSView {
    /// Rows actually created, so a huge candidate list cannot spawn hundreds
    /// of label trees on every keystroke.
    fileprivate static let rowCap = 50
    fileprivate static let visibleRows = 10
    fileprivate static let horizontalPadding: CGFloat = 10
    fileprivate static let columnGap: CGFloat = 10
    fileprivate static let edgeInset: CGFloat = 4

    /// Fired with the item index when a row is clicked.
    var onSelect: ((Int) -> Void)?

    /// Rounded, border-drawing container; the outer view keeps the shadow,
    /// since a layer cannot both clip to corners and cast a shadow.
    private let clipView = NSView()
    private let effect = NSVisualEffectView()
    private let scrollView = NSScrollView()
    private let content = NSView()
    private var rowViews: [RowView] = []
    private var rowHeight: CGFloat = 22
    private(set) var contentSize: CGSize = .zero

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.3
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: 2)

        clipView.wantsLayer = true
        clipView.layer?.cornerRadius = 8
        clipView.layer?.masksToBounds = true
        clipView.layer?.borderWidth = 1
        clipView.layer?.borderColor = NSColor.separatorColor.usingColorSpace(.sRGB)?.cgColor
        clipView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clipView)

        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.translatesAutoresizingMaskIntoConstraints = false
        clipView.addSubview(effect)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(
            top: Self.edgeInset, left: 0, bottom: Self.edgeInset, right: 0
        )
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = content
        clipView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            clipView.leadingAnchor.constraint(equalTo: leadingAnchor),
            clipView.trailingAnchor.constraint(equalTo: trailingAnchor),
            clipView.topAnchor.constraint(equalTo: topAnchor),
            clipView.bottomAnchor.constraint(equalTo: bottomAnchor),
            effect.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            effect.topAnchor.constraint(equalTo: clipView.topAnchor),
            effect.bottomAnchor.constraint(equalTo: clipView.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: clipView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: clipView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Rebuild the rows for the popup state and size the panel; the host
    /// places the returned size at the anchor (flipping up if needed).
    @discardableResult
    func update(_ popup: PopupState, metrics: FontMetrics, maxWidth: CGFloat) -> CGSize {
        rowHeight = metrics.cellSize.height + 2
        rebuildRows(for: popup.items, metrics: metrics)
        layoutRows()
        setSelected(popup.selected)

        let width = min(
            max(rowViews.map(\.preferredWidth).max() ?? 0, 160),
            max(maxWidth, 160)
        )
        let visible = min(rowViews.count, Self.visibleRows)
        contentSize = CGSize(
            width: width,
            height: Self.edgeInset * 2 + CGFloat(visible) * rowHeight
        )
        setFrameSize(contentSize)
        scrollView.frame = bounds
        layoutRows()
        return contentSize
    }

    private func rebuildRows(for items: [PopupItem], metrics: FontMetrics) {
        let capped = Array(items.prefix(Self.rowCap))
        if rowViews.count == capped.count,
           zip(rowViews, capped).allSatisfy({ $0.item == $1 }) {
            return
        }
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = capped.enumerated().map { index, item in
            let row = RowView(item: item, font: metrics.font)
            row.onSelect = { [weak self] in self?.onSelect?(index) }
            content.addSubview(row)
            return row
        }
    }

    private func setSelected(_ selected: Int) {
        for (index, row) in rowViews.enumerated() {
            row.isSelected = index == selected
        }
        if rowViews.indices.contains(selected) {
            scrollView.scrollToVisible(rowViews[selected].frame)
        }
    }

    private func layoutRows() {
        for (index, row) in rowViews.enumerated() {
            row.frame = CGRect(x: 0, y: CGFloat(index) * rowHeight, width: bounds.width, height: rowHeight)
        }
        content.setFrameSize(CGSize(
            width: max(bounds.width, scrollView.contentSize.width),
            height: CGFloat(rowViews.count) * rowHeight
        ))
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        layoutRows()
    }
}

/// One completion row: the word in the editor's monospaced font, the source
/// text, and the kind on the trailing edge; the selected row fills with the
/// accent color like a native menu item.
private final class RowView: NSView {
    let item: PopupItem
    var onSelect: (() -> Void)?
    var isSelected = false {
        didSet { updateColors() }
    }

    let preferredWidth: CGFloat
    private let wordLabel = NSTextField(labelWithString: "")
    private let menuLabel = NSTextField(labelWithString: "")
    private let kindLabel = NSTextField(labelWithString: "")

    init(item: PopupItem, font: NSFont) {
        self.item = item
        let secondary = NSFont.systemFont(ofSize: min(font.pointSize - 1.5, 11))
        wordLabel.font = font
        wordLabel.stringValue = item.word
        menuLabel.font = secondary
        menuLabel.stringValue = item.menu
        kindLabel.font = secondary
        kindLabel.stringValue = item.kind
        // Truncate long entries so one candidate cannot blow up the panel.
        for label in [wordLabel, menuLabel, kindLabel] {
            label.cell?.truncatesLastVisibleLine = true
            label.cell?.wraps = false
            label.maximumNumberOfLines = 1
        }
        let wordWidth = (item.word as NSString).size(withAttributes: [.font: font]).width
        let menuWidth = (item.menu as NSString).size(withAttributes: [.font: secondary]).width
        let kindWidth = (item.kind as NSString).size(withAttributes: [.font: secondary]).width
        var width = CompletionPanelView.horizontalPadding + wordWidth
        if !item.menu.isEmpty { width += CompletionPanelView.columnGap + menuWidth }
        if !item.kind.isEmpty { width += CompletionPanelView.columnGap + kindWidth }
        preferredWidth = width + CompletionPanelView.horizontalPadding
        super.init(frame: .zero)
        for label in [wordLabel, menuLabel, kindLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        var constraints = [
            wordLabel.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: CompletionPanelView.horizontalPadding),
            wordLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            kindLabel.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -CompletionPanelView.horizontalPadding),
            kindLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        if !item.menu.isEmpty {
            constraints.append(menuLabel.leadingAnchor.constraint(
                equalTo: wordLabel.trailingAnchor, constant: CompletionPanelView.columnGap))
            constraints.append(menuLabel.centerYAnchor.constraint(equalTo: centerYAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        updateColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func updateColors() {
        if isSelected {
            wordLabel.textColor = .white
            menuLabel.textColor = .white.withAlphaComponent(0.8)
            kindLabel.textColor = .white.withAlphaComponent(0.8)
        } else {
            wordLabel.textColor = .labelColor
            menuLabel.textColor = .secondaryLabelColor
            kindLabel.textColor = .secondaryLabelColor
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            // The OS accent color: it must contrast with the dark vibrancy
            // material, which selectedContentBackgroundColor does not in
            // dark windows.
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 4, yRadius: 4).fill()
        }
    }

    override func mouseUp(with event: NSEvent) {
        onSelect?()
    }
}
