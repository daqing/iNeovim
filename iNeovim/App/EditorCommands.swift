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
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") { AppModel.shared.save() }
                .keyboardShortcut("s", modifiers: .command)
        }

        CommandMenu("Neovim") {
            Button("New Tab") { AppModel.shared.newTab() }
                .keyboardShortcut("t", modifiers: .command)
            Button("Close Tab") { AppModel.shared.closeTab() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            Divider()
            Button("Next Tab") { AppModel.shared.nextTab() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { AppModel.shared.previousTab() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Menu("Go to Tab") {
                ForEach(1...9, id: \.self) { index in
                    Button("Tab \(index)") { AppModel.shared.goToTab(index) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
                }
            }
            Divider()
            Button("Split Horizontally") { AppModel.shared.splitHorizontal() }
            Button("Split Vertically") { AppModel.shared.splitVertical() }
            Button("Close Window") { AppModel.shared.closeWindow() }
            Divider()
            Button("Open Terminal") { AppModel.shared.openTerminal() }
        }
    }

    private static func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        AppModel.shared.open(panel.urls)
    }
}
