import AppKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("Application did finish launching")
        Task { await AppModel.shared.bootstrap() }
    }

    /// "Open With", Dock-icon drops, and `open -a` all arrive here; the model
    /// queues them until Neovim finished handshaking.
    func application(_ application: NSApplication, open urls: [URL]) {
        Log.app.info("Open request for \(urls.count, privacy: .public) file(s)")
        AppModel.shared.open(urls)
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.app.info("Application will terminate")
        AppModel.shared.beginShutdown()
        Task {
            await Screen.shared.stopConsuming()
            await NvimProcess.shared.terminate()
        }
    }
}
