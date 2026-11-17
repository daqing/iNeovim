import AppKit
import GhosttySupport

/// The whole right-hand terminal column: a tab bar (terminal glyph, one
/// numbered item per tab, and the + that opens a new tab) above the ACTIVE
/// tab's `TerminalPaneStackView`. Tabs show one terminal group at a time;
/// a new tab inherits the active terminal's directory; ⌘⇧D splits within
/// the active tab. Surface creation and the editor-facing intents stay
/// with `EditorSplitView`, which hosts one column while the pane is open.
final class TerminalPaneColumnView: NSView {
    static let tabBarHeight: CGFloat = 26

    /// The + button asked for a new terminal tab; `EditorSplitView` creates
    /// the surface (it owns the model colors and the ⌘-click link handler).
    var onNewTab: (() -> Void)?

    /// The last tab is gone; `EditorSplitView` tears the column down.
    var onEmptied: (() -> Void)?

    private let tabBar = TerminalTabBarView()
    /// One stack per tab; only the active one is visible.
    private var stacks: [TerminalPaneStackView] = []
    private var activeIndex = 0

    init() {
        super.init(frame: .zero)
        tabBar.onSelect = { [weak self] index in
            self?.selectTab(at: index)
        }
        tabBar.onAdd = { [weak self] in
            self?.onNewTab?()
        }
        addSubview(tabBar)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var activeStack: TerminalPaneStackView? {
        stacks.indices.contains(activeIndex) ? stacks[activeIndex] : nil
    }

    /// The pane whose surface view is `surface`, across every tab.
    func pane(for surface: Ghostty.SurfaceView?) -> TerminalPaneView? {
        guard let surface else { return nil }
        for stack in stacks {
            if let pane = stack.pane(for: surface) { return pane }
        }
        return nil
    }

    /// Open a new tab holding `pane`, inserted after the active one and
    /// activated. `EditorSplitView` focuses the pane afterwards.
    func addTab(pane: TerminalPaneView) {
        let stack = TerminalPaneStackView()
        stack.setInitialPane(pane)
        addSubview(stack)
        let index = min(activeIndex + 1, stacks.count)
        stacks.insert(stack, at: index)
        switchToTab(at: index)
    }

    func switchToTab(at index: Int) {
        guard stacks.indices.contains(index) else { return }
        activeIndex = index
        for (i, stack) in stacks.enumerated() {
            stack.isHidden = i != index
        }
        tabBar.reload(count: stacks.count, selected: index)
        needsLayout = true
    }

    /// Tab click: switch and focus the tab's remembered pane.
    private func selectTab(at index: Int) {
        switchToTab(at: index)
        focusPane(activeStack?.lastFocusedPane ?? activeStack?.panes.first)
    }

    /// Make `pane`'s surface the first responder and remember it in its own
    /// tab's stack. Returns whether the focus change happened.
    @discardableResult
    func focusPane(_ pane: TerminalPaneView?) -> Bool {
        guard let pane, let stack = stackContaining(pane), let window else { return false }
        if window.makeFirstResponder(pane.surfaceView) {
            stack.noteFocus(pane)
            return true
        }
        return false
    }

    func stackContaining(_ pane: TerminalPaneView) -> TerminalPaneStackView? {
        stacks.first { $0.panes.contains(where: { $0 === pane }) }
    }

    /// Begin the close cycle for every pane in every tab (⌘D hides the
    /// whole column).
    func requestCloseAll() {
        for stack in stacks {
            stack.requestCloseAll()
        }
    }

    /// Immediate teardown when the hosting window goes away; silent — no
    /// `onEmptied` — because the column's owner is going away with it.
    func destroyAll() {
        for stack in stacks {
            stack.destroyAll()
        }
        stacks = []
        activeIndex = 0
        tabBar.reload(count: 0, selected: 0)
        needsLayout = true
    }

    /// One pane's surface finished its close cycle (an exited shell or a
    /// ⌘D close request). A tab whose last pane is gone is removed; an
    /// emptied ACTIVE tab hands focus to a neighbor tab, and the last tab
    /// reports the column emptied.
    func paneDidClose(_ pane: TerminalPaneView) {
        guard let stack = stackContaining(pane),
              let tabIndex = stacks.firstIndex(where: { $0 === stack }) else { return }
        let wasActive = tabIndex == activeIndex
        let wasFocused = stack.pane(for: window?.firstResponder as? Ghostty.SurfaceView) === pane
        let nextNeighbor = stack.neighbor(of: pane)
        if !stack.removePane(pane) {
            if wasActive, wasFocused {
                focusPane(nextNeighbor)
            }
            return
        }
        stacks.remove(at: tabIndex)
        stack.removeFromSuperview()
        guard !stacks.isEmpty else {
            onEmptied?()
            return
        }
        if wasActive {
            activeIndex = min(tabIndex, stacks.count - 1)
        } else if tabIndex < activeIndex {
            // A tab left of the active one shifted the numbering.
            activeIndex -= 1
        }
        for (i, surviving) in stacks.enumerated() {
            surviving.isHidden = i != activeIndex
        }
        tabBar.reload(count: stacks.count, selected: activeIndex)
        if wasActive, wasFocused {
            focusPane(stacks[activeIndex].lastFocusedPane ?? stacks[activeIndex].panes.first)
        }
    }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    override func layout() {
        super.layout()
        relayout()
    }

    private func relayout() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        tabBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.tabBarHeight)
        // Every stack tracks the body geometry (hidden ones included), so
        // surfaces reflow while off-screen and a switch shows fresh sizes.
        let body = NSRect(
            x: 0,
            y: Self.tabBarHeight,
            width: bounds.width,
            height: max(0, bounds.height - Self.tabBarHeight)
        )
        for stack in stacks {
            stack.frame = body
        }
    }
}
