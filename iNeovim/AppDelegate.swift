import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("Application did finish launching")
        Task {
            do {
                try await NvimProcess.shared.start()
            } catch {
                Log.rpc.error("Failed to start embedded nvim: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.app.info("Application will terminate")
        Task { await NvimProcess.shared.terminate() }
    }
}
