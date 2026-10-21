import AppKit
import SwiftUI

/// Native menu commands for editor actions. Splits, buffers, and the cmdline
/// route to the embedded nvim, which owns that model; tabs are native macOS
/// window tabs (one window and nvim session per tab).
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
            Button("New Tab") { Self.requestNewTab() }
                .keyboardShortcut("t", modifiers: .command)
            Button("Close Tab") { Self.closeKeyWindow() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            Divider()
            Button("Next Tab") { Self.cycleNativeTab(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { Self.cycleNativeTab(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Menu("Go to Tab") {
                ForEach(1...9, id: \.self) { index in
                    Button("Tab \(index)") { Self.selectNativeTab(index) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index)")), modifiers: .command)
                }
            }
            Divider()
            Button("Split Horizontally") { AppModel.active?.splitHorizontal() }
            Button("Split Vertically") { AppModel.active?.splitVertical() }
            Button("Close Window") { AppModel.active?.closeWindow() }
            Divider()
            Button("Toggle Terminal Pane") { AppModel.active?.toggleTerminalPane() }
                .keyboardShortcut("d", modifiers: .command)
            Button("Focus Editor") { AppModel.active?.focusEditor() }
                .keyboardShortcut("l", modifiers: .command)
            Button("Focus Terminal Pane") { AppModel.active?.focusTerminalPane() }
                .keyboardShortcut("r", modifiers: .command)
            Divider()
            Button("Toggle Problems") { AppModel.active?.toggleProblemsPanel() }
                .keyboardShortcut("p", modifiers: .command)
            Divider()
            Button("Install Command Line Tool\u{2026}") { CommandLineTool.install() }
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

    // MARK: Native tabs

    /// ⌘T / New Tab: a new editor window joined to the key window's tab
    /// group, routed through the app delegate so the tab bar's + button
    /// (system `newWindowForTab:`) shares one path.
    private static func requestNewTab() {
        AppDelegate.shared?.requestNewTab(from: NSApp.keyWindow)
    }

    private static func cycleNativeTab(_ offset: Int) {
        guard let group = NSApp.keyWindow?.tabGroup, let selected = group.selectedWindow,
              let index = group.windows.firstIndex(of: selected) else { return }
        let next = index + offset
        guard group.windows.indices.contains(next) else { return }
        group.windows[next].makeKey()
    }

    /// ⌘1…⌘9 select the first…ninth tab; `NSWindowTabGroup.windows` is
    /// 0-indexed in visual (leading to trailing) order, so subtract one.
    private static func selectNativeTab(_ index: Int) {
        guard let group = NSApp.keyWindow?.tabGroup, index >= 1, index <= group.windows.count else { return }
        group.windows[index - 1].makeKey()
    }

    /// ⌘W closes the key editor window — the current native tab. With only
    /// one editor window left it asks for confirmation instead — SwiftUI
    /// would otherwise leave the app running with no window after the last
    /// close. Non-editor key windows (e.g. Settings) close directly.
    private static func closeKeyWindow() {
        let live = AppModel.live
        let keyWindow = NSApp.keyWindow
        guard let model = live.first(where: { $0.hostWindow === keyWindow })
            ?? (keyWindow == nil ? AppModel.active : nil),
            let window = model.hostWindow else {
            keyWindow?.performClose(nil)
            return
        }
        // `performClose(_:)` simulates a click on the close button, whose
        // action runs the quit confirmation — it would ask on every ⌘W and
        // re-enter itself. Tab windows therefore close directly; a window
        // in a tab group never quits the app, only the current tab goes.
        let hasOtherWindows = live.count > 1 || (window.tabGroup?.windows.count ?? 0) > 1
        guard hasOtherWindows else {
            let alert = NSAlert()
            alert.messageText = "Quit iNeovim?"
            alert.informativeText = "This is the last editor window; closing it quits iNeovim."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            NSApp.terminate(nil)
            return
        }
        window.close()
    }
}
