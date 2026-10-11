import AppKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Printable keys reach nvim through the text input system (the
        // TerminalView interpretKeyEvents path), where macOS "press and hold"
        // — the accent popup — replaces key repeat: letters without accent
        // alternates (j, k) never repeat at all. Terminal semantics need
        // repeats, so persist the standard terminal-emulator opt-out once;
        // an explicit setting in the app or global domain is left untouched.
        if UserDefaults.standard.object(forKey: "ApplePressAndHoldEnabled") == nil {
            UserDefaults.standard.set(false, forKey: "ApplePressAndHoldEnabled")
        }
        Log.app.info("Application did finish launching")
    }

    /// "Open With", Dock-icon drops, and `open -a` all arrive here; the model
    /// routes them to the active session or stages them until one is ready.
    func application(_ application: NSApplication, open urls: [URL]) {
        Log.app.info("Open request for \(urls.count, privacy: .public) file(s)")
        AppModel.openFromSystem(urls)
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.app.info("Application will terminate")
        for model in AppModel.live {
            model.beginShutdown()
            Task { await model.shutdownSession() }
        }
    }
}
