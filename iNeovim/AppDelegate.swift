import AppKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("Application did finish launching")
        Task { await AppModel.shared.bootstrap() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.app.info("Application will terminate")
        Task {
            await Screen.shared.stopConsuming()
            await NvimProcess.shared.terminate()
        }
    }
}
