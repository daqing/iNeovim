import AppKit

/// The confirmation shown before an editor window and its embedded Neovim are
/// torn down: a typed `:q` and a click on the window's red close button both
/// route through here so they warn identically.
enum QuitConfirmation {
    /// Present the alert; true when the user chose to quit.
    @MainActor
    static func present() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Quit iNeovim?"
        alert.informativeText = "The embedded Neovim will exit and this window will close."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
