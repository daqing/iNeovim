import AppKit

/// Tab bar row at the top of the terminal column: the terminal glyph, one
/// compact numbered item per tab, and the + button in the pane's top-right
/// corner (it replaced the old close button) that asks the column for a
/// new terminal tab.
final class TerminalTabBarView: NSView {
    var onSelect: ((Int) -> Void)?
    var onAdd: (() -> Void)?

    private let iconView = NSImageView()
    private let addButton = NSButton()
    private var items: [NSButton] = []
    private var selectedIndex = 0
    private static let itemHeight: CGFloat = 20
    private static let itemGap: CGFloat = 4

    init() {
        super.init(frame: .zero)
        iconView.image = NSImage(
            systemSymbolName: "terminal",
            accessibilityDescription: "Terminal"
        )?.withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        iconView.contentTintColor = .secondaryLabelColor
        addSubview(iconView)

        addButton.isBordered = false
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New terminal tab")
        addButton.contentTintColor = .secondaryLabelColor
        addButton.target = self
        addButton.action = #selector(addClicked)
        addSubview(addButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Rebuild the items for `count` tabs; indices shift as tabs come and
    /// go, so the row is rebuilt instead of patched.
    func reload(count: Int, selected: Int) {
        selectedIndex = selected
        for item in items {
            item.removeFromSuperview()
        }
        items = (0..<count).map { index in
            let item = NSButton()
            item.isBordered = false
            item.tag = index
            item.target = self
            item.action = #selector(itemClicked(_:))
            item.wantsLayer = true
            addSubview(item)
            return item
        }
        styleItems()
        needsLayout = true
    }

    @objc private func itemClicked(_ sender: NSButton) {
        onSelect?(sender.tag)
    }

    @objc private func addClicked() {
        onAdd?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let iconSize = iconView.fittingSize
        iconView.frame = NSRect(
            x: TerminalPaneView.contentInset,
            y: (bounds.height - iconSize.height) / 2,
            width: iconSize.width,
            height: iconSize.height
        )
        addButton.frame = NSRect(x: bounds.width - 28, y: 3, width: 24, height: 20)
        // Items flow left to right after the glyph; when they would run
        // into the + button, squeeze them uniformly into the space left.
        let start = iconView.frame.maxX + 8
        let available = max(0, addButton.frame.minX - 8 - start)
        let gaps = Self.itemGap * CGFloat(max(items.count - 1, 0))
        let width = min(28, max(18, (available - gaps) / CGFloat(max(items.count, 1))))
        var x = start
        for item in items {
            item.frame = NSRect(
                x: x,
                y: (bounds.height - Self.itemHeight) / 2,
                width: width,
                height: Self.itemHeight
            )
            x += width + Self.itemGap
        }
    }

    private func styleItems() {
        for (index, item) in items.enumerated() {
            let isSelected = index == selectedIndex
            item.attributedTitle = NSAttributedString(
                string: "\(index + 1)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: isSelected ? .semibold : .regular),
                    .foregroundColor: isSelected ? NSColor.labelColor : NSColor.secondaryLabelColor
                ]
            )
            // `labelColor` resolves per appearance, so a captured `cgColor`
            // would keep a stale shade after the editor flips theme;
            // re-styling on appearance changes re-resolves it.
            item.layer?.backgroundColor = isSelected
                ? NSColor.labelColor.withAlphaComponent(0.08).cgColor
                : nil
            item.layer?.cornerRadius = 5
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        styleItems()
    }
}
