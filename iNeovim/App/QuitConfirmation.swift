import AppKit

/// The confirmation shown before an editor window and its embedded Neovim are
/// torn down: a typed `:q` and a click on the window's red close button both
/// route through here so they warn identically. The alert names what
/// confirming will actually do — close this tab, close this window, or quit
/// the app when it is the last editor window.
enum QuitConfirmation {
    enum Scope: Equatable {
        /// One tab among several: only this tab's session ends.
        case tab
        /// A standalone editor window among others: only it closes.
        case window
        /// The last editor window: closing it quits the app.
        case app
    }

    /// The scope for `window` as it stands now. The editor-window count is
    /// the number of live sessions, the same measure the close paths use to
    /// decide whether the app has anything left to show.
    @MainActor
    static func scope(for window: NSWindow?) -> Scope {
        scope(
            tabCount: window?.tabGroup?.windows.count ?? 0,
            editorWindowCount: AppModel.live.count
        )
    }

    /// The decision behind `scope(for:)`, kept pure so it can be tested
    /// without real windows.
    static func scope(tabCount: Int, editorWindowCount: Int) -> Scope {
        if tabCount > 1 { return .tab }
        return editorWindowCount > 1 ? .window : .app
    }

    /// Present the alert for `scope`; true when the user chose to go ahead.
    @MainActor
    static func present(_ scope: Scope) -> Bool {
        let alert = NSAlert()
        switch scope {
        case .tab:
            alert.messageText = "Close Tab?"
            alert.informativeText = "The embedded Neovim in this tab will exit and the tab will close."
            alert.addButton(withTitle: "Close Tab")
        case .window:
            alert.messageText = "Close Window?"
            alert.informativeText = "The embedded Neovim in this window will exit and the window will close."
            alert.addButton(withTitle: "Close Window")
        case .app:
            alert.messageText = "Quit iNeovim?"
            alert.informativeText = "The embedded Neovim will exit and this window will close."
            alert.addButton(withTitle: "Quit")
        }
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
