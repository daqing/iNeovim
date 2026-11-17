import AppKit

/// Tab bar row at the top of the terminal column: the terminal glyph, one
/// compact numbered item per tab, and the + button right after the last
/// item (it replaced the old close button) that asks the column for a new
/// terminal tab.
final class TerminalTabBarView: NSView {
    var onSelect: ((Int) -> Void)?
    var onAdd: (() -> Void)?

    private let iconView = NSImageView()
    private let addButton = TabItemButton()
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
            let item = TabItemButton()
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
        // Items flow left to right after the glyph and the + follows the
        // last one, so it stays reachable next to the tabs. When the row
        // would run past the right edge, squeeze the items uniformly.
        let start = iconView.frame.maxX + 8
        let addWidth: CGFloat = 24
        let trailingInset: CGFloat = 4
        let available = max(0, bounds.width - trailingInset - addWidth - Self.itemGap - start)
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
        let addX = min(items.isEmpty ? start : x, bounds.width - trailingInset - addWidth)
        addButton.frame = NSRect(
            x: max(0, addX),
            y: (bounds.height - Self.itemHeight) / 2,
            width: addWidth,
            height: Self.itemHeight
        )
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

/// A tab item or the + button; the cursor becomes a pointing hand over both.
private final class TabItemButton: NSButton {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
