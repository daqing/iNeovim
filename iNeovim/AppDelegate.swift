import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("Application did finish launching")
        Task {
            do {
                try await RPCSession.shared.start()
                try await RPCSession.shared.handshake()
            } catch {
                Log.rpc.error("Failed to connect to embedded nvim: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.app.info("Application will terminate")
        Task { await NvimProcess.shared.terminate() }
    }
}
