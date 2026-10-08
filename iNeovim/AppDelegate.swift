import AppKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("Application did finish launching")
        Task {
            do {
                try await RPCSession.shared.start()
                try await RPCSession.shared.handshake()
                let client = NvimClient()
                try await client.uiAttach(width: 80, height: 24, options: .map(MsgPackValueMap([
                    .string("ext_linegrid"): .bool(true),
                ])))
                Log.render.info("UI attached 80x24 (ext_linegrid)")
                let stream = await client.makeRedrawEventStream()
                await Screen.shared.startConsuming(stream)
                await InputDispatcher.shared.startConsuming(with: client)
            } catch {
                Log.rpc.error("Failed to connect to embedded nvim: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.app.info("Application will terminate")
        Task {
            await Screen.shared.stopConsuming()
            await NvimProcess.shared.terminate()
        }
    }
}
