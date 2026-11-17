import AppKit
import GhosttySupport

/// Vertical stack of terminal panes filling the right-hand terminal column:
/// ⌘⇧D on a focused pane inserts a new pane below it (a horizontal split),
/// each pane's ✕ (or a closed shell) removes it, and the horizontal
/// dividers between panes redistribute their heights. The stack owns pane
/// geometry only — surface creation, focus intents, and the column's frame
/// stay with `EditorSplitView`, which hosts one stack while the pane is open.
final class TerminalPaneStackView: NSView {
    static let dividerThickness: CGFloat = 5
    /// Smallest height a side keeps when a divider is dragged.
    static let minPaneHeight: CGFloat = 80

    private(set) var panes: [TerminalPaneView] = []
    /// The pane last marked through `noteFocus`; the fallback target for
    /// focus and split intents that arrive while the editor holds the
    /// keyboard.
    private(set) weak var lastFocusedPane: TerminalPaneView?
    /// `dividers[i]` sits between `panes[i]` and `panes[i + 1]`.
    private var dividers: [PaneDividerView] = []
    /// Relative height of each pane; layout normalizes the weights to the
    /// available height, so they survive window resizes.
    private var weights: [CGFloat] = []

    var isEmpty: Bool { panes.isEmpty }

    /// The pane whose surface view is `surface`, if it is in this stack.
    func pane(for surface: Ghostty.SurfaceView?) -> TerminalPaneView? {
        guard let surface else { return nil }
        return panes.first { $0.surfaceView === surface }
    }

    func noteFocus(_ pane: TerminalPaneView) {
        lastFocusedPane = pane
    }

    /// Fill the empty stack with the first pane.
    func setInitialPane(_ pane: TerminalPaneView) {
        precondition(panes.isEmpty)
        panes = [pane]
        weights = [1]
        addSubview(pane)
        noteFocus(pane)
        needsLayout = true
    }

    /// Insert `pane` directly below `anchor`, giving it half of the anchor's
    /// height so the anchor keeps the top half of its old frame.
    func insertPane(_ pane: TerminalPaneView, below anchor: TerminalPaneView) {
        guard let anchorIndex = panes.firstIndex(where: { $0 === anchor }) else { return }
        let index = anchorIndex + 1
        panes.insert(pane, at: index)
        let half = weights[anchorIndex] / 2
        weights[anchorIndex] = half
        weights.insert(half, at: index)

        // The divider's neighbors change as panes come and go, so the drag
        // resolves its own index at drag time instead of capturing one.
        let divider = PaneDividerView(horizontal: true)
        divider.onDrag = { [weak self, weak divider] _, deltaY in
            guard let self, let divider,
                  let dividerIndex = self.dividers.firstIndex(where: { $0 === divider }) else { return }
            self.adjustSplit(dividerIndex: dividerIndex, deltaY: deltaY)
        }
        dividers.insert(divider, at: anchorIndex)
        addSubview(divider)
        addSubview(pane)
        noteFocus(pane)
        needsLayout = true
    }

    /// Remove a closed pane, returning its height to the pane above (or, for
    /// the topmost, to the new topmost). Returns whether the stack emptied.
    @discardableResult
    func removePane(_ pane: TerminalPaneView) -> Bool {
        guard let index = panes.firstIndex(where: { $0 === pane }) else { return isEmpty }
        panes.remove(at: index)
        let weight = weights.remove(at: index)
        if index > 0 {
            weights[index - 1] += weight
        } else if !weights.isEmpty {
            weights[0] += weight
        }
        if index > 0 {
            let divider = dividers.remove(at: index - 1)
            divider.removeFromSuperview()
        } else if !dividers.isEmpty {
            let divider = dividers.removeFirst()
            divider.removeFromSuperview()
        }
        if lastFocusedPane === pane {
            lastFocusedPane = panes.first
        }
        pane.removeFromSuperview()
        needsLayout = true
        return panes.isEmpty
    }

    /// The pane that should take `pane`'s keyboard focus when it closes —
    /// the one below, else the one above. Call before removing it.
    func neighbor(of pane: TerminalPaneView) -> TerminalPaneView? {
        guard let index = panes.firstIndex(where: { $0 === pane }) else { return nil }
        if index + 1 < panes.count { return panes[index + 1] }
        return index > 0 ? panes[index - 1] : nil
    }

    /// Begin the close cycle for every pane (⌘D hides the whole column).
    func requestCloseAll() {
        for pane in panes {
            pane.requestClose()
        }
    }

    /// Immediate teardown when the hosting window goes away.
    func destroyAll() {
        for pane in panes {
            pane.destroy()
        }
        for divider in dividers {
            divider.removeFromSuperview()
        }
        panes = []
        dividers = []
        weights = []
        lastFocusedPane = nil
        needsLayout = true
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

    /// Panes top to bottom, weights normalized to the space left after the
    /// dividers; cumulative positions are floored so panes meet without
    /// seams or overlap.
    private func relayout() {
        guard bounds.width > 0, bounds.height > 0, !panes.isEmpty else { return }
        let content = max(0, bounds.height - CGFloat(dividers.count) * Self.dividerThickness)
        let total = weights.reduce(0, +)
        guard total > 0 else { return }
        var y: CGFloat = 0
        var consumed: CGFloat = 0
        for index in panes.indices {
            consumed += weights[index]
            let isLast = index == panes.count - 1
            let bottom = isLast ? content : floor((consumed / total) * content)
            panes[index].frame = NSRect(x: 0, y: y, width: bounds.width, height: max(0, bottom - y))
            y = bottom
            if !isLast {
                dividers[index].frame = NSRect(x: 0, y: y, width: bounds.width, height: Self.dividerThickness)
                y += Self.dividerThickness
            }
        }
    }

    /// Dragging divider `index` moves the boundary between panes `index` and
    /// `index + 1`: a downward drag (negative `deltaY`, AppKit coordinates)
    /// grows the upper pane. Each side keeps `minPaneHeight`.
    private func adjustSplit(dividerIndex: Int, deltaY: CGFloat) {
        guard dividerIndex + 1 < weights.count, weights.count == panes.count else { return }
        let content = max(0, bounds.height - CGFloat(dividers.count) * Self.dividerThickness)
        guard content > 0 else { return }
        let total = weights.reduce(0, +)
        let available = weights[dividerIndex] + weights[dividerIndex + 1]
        let minimum = Self.minPaneHeight / content * total
        guard available >= minimum * 2 else { return }
        let upper = min(max(weights[dividerIndex] - deltaY / content * total, minimum), available - minimum)
        weights[dividerIndex] = upper
        weights[dividerIndex + 1] = available - upper
        needsLayout = true
    }
}
