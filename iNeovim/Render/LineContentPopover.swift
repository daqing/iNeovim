import AppKit

/// Native popover showing the FULL text of a buffer line whose display was
/// truncated to a one-row preview (see `NvimClient.installTruncatedLines`),
/// shown when the user clicks the preview row. Built on NSPopover so
/// dismissal (click outside), theming, and the arrow come for free; the text
/// is selectable so it can be copied, wraps at the popover width, and very
/// long lines scroll instead of growing past the screen.
final class LineContentPopover {
    private static let maxTextWidth: CGFloat = 560
    private static let maxTextHeight: CGFloat = 360
    private static let padding: CGFloat = 12
    /// Absurdly long lines stop here; the popover is a reading aid, not a
    /// second editor.
    private static let maxCharacters = 20_000

    private let popover = NSPopover()

    var isShown: Bool { popover.isShown }

    init() {
        popover.behavior = .transient
    }

    func close() {
        guard popover.isShown else { return }
        popover.close()
    }

    /// Show the line's full text anchored at the clicked cell. `themeIsDark`
    /// picks the popover appearance to match the nvim theme driving the
    /// window chrome, like the diagnostics popover.
    func present(
        content: String,
        relativeTo rect: CGRect,
        of view: NSView,
        themeIsDark: Bool?
    ) {
        close()
        if let themeIsDark {
            popover.appearance = NSAppearance(named: themeIsDark ? .darkAqua : .aqua)
        } else {
            popover.appearance = nil
        }

        let display: String
        if content.count > Self.maxCharacters {
            display = String(content.prefix(Self.maxCharacters)) + "\n…"
        } else {
            display = content
        }

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: Self.padding, height: Self.padding)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.drawsBackground = false
        textView.string = display

        let textWidth = Self.maxTextWidth - Self.padding * 2
        textView.textContainer?.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        textView.frame.size = NSSize(width: Self.maxTextWidth, height: Self.maxTextHeight)
        var contentHeight: CGFloat = 0
        if let container = textView.textContainer, let layoutManager = textView.layoutManager {
            layoutManager.ensureLayout(for: container)
            contentHeight = layoutManager.usedRect(for: container).height
        }

        let scrollView = NSScrollView(frame: NSRect(
            x: 0, y: 0,
            width: Self.maxTextWidth,
            height: min(Self.maxTextHeight, ceil(contentHeight) + Self.padding * 2)
        ))
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let viewController = NSViewController()
        viewController.view = scrollView
        popover.contentViewController = viewController
        popover.contentSize = scrollView.frame.size
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }
}
