import AppKit
import SwiftUI

/// Native menu commands for Neovim-relevant actions. Neovim owns the
/// buffer/window/tab model, so each command routes to the embedded instance
/// rather than duplicating state in the shell.
struct EditorCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open\u{2026}") { Self.showOpenPanel() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Close") { Self.closeKeyWindow() }
                .keyboardShortcut("w", modifiers: .command)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") { AppModel.active?.save() }
                .keyboardShortcut("s", modifiers: .command)
        }

        CommandMenu("Neovim") {
            Button("New Tab") { AppModel.active?.newTab() }
                .keyboardShortcut("t", modifiers: .command)
            Button("Close Tab") { AppModel.active?.closeTab() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            Divider()
            Button("Next Tab") { AppModel.active?.nextTab() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { AppModel.active?.previousTab() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Menu("Go to Tab") {
                ForEach(1...9, id: \.self) { index in
                    Button("Tab \(index)") { AppModel.active?.goToTab(index) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
                }
            }
            Divider()
            Button("Split Horizontally") { AppModel.active?.splitHorizontal() }
            Button("Split Vertically") { AppModel.active?.splitVertical() }
            Button("Close Window") { AppModel.active?.closeWindow() }
            Divider()
            Button("Open Terminal") { AppModel.active?.openTerminal() }
        }
    }

    private static func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        AppModel.openFromSystem(panel.urls)
    }

    /// ⌘W closes the key editor window. With only one editor window left it
    /// asks for confirmation instead — SwiftUI would otherwise leave the app
    /// running with no window after the last close. Non-editor key windows
    /// (e.g. Settings) close directly.
    private static func closeKeyWindow() {
        let live = AppModel.live
        let keyWindow = NSApp.keyWindow
        guard let model = live.first(where: { $0.hostWindow === keyWindow })
            ?? (keyWindow == nil ? AppModel.active : nil),
            let window = model.hostWindow else {
            keyWindow?.performClose(nil)
            return
        }
        guard live.count > 1 else {
            let alert = NSAlert()
            alert.messageText = "Quit iNeovim?"
            alert.informativeText = "This is the last editor window; closing it quits iNeovim."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            NSApp.terminate(nil)
            return
        }
        window.performClose(nil)
    }
}
