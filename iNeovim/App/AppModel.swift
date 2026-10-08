import Combine
import Foundation
import os

/// App-wide coordination between the SwiftUI shell and the embedded Neovim
/// session: owns startup, forwards editor commands, and queues files opened
/// before the session is ready.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    /// True once the embedded Neovim is attached and its streams are running.
    @Published private(set) var isReady = false

    private let client = NvimClient()
    private let openHandler: @MainActor ([URL]) -> Void
    private var pendingFiles: [URL] = []

    /// Files opened before startup finished, exposed for tests.
    var pendingFileCount: Int { pendingFiles.count }

    init(openHandler: @escaping @MainActor ([URL]) -> Void = AppModel.openInNeovim) {
        self.openHandler = openHandler
    }

    /// Start the embedded Neovim, attach the UI, and begin consuming the
    /// redraw and input streams. Idempotent.
    func bootstrap() async {
        guard !isReady else { return }
        do {
            try await RPCSession.shared.start()
            try await RPCSession.shared.handshake()
            try await client.uiAttach(width: 80, height: 24, options: .map(MsgPackValueMap([
                .string("ext_linegrid"): .bool(true),
            ])))
            Log.render.info("UI attached 80x24 (ext_linegrid)")
            // One wheel event scrolls exactly one line so the visual lead
            // in ScrollAccumulator maps 1:1 to grid_scroll confirmations.
            try await client.command("set mousescroll=ver:1,hor:1")
            let stream = await client.makeRedrawEventStream()
            await Screen.shared.startConsuming(stream)
            await InputDispatcher.shared.startConsuming(with: client)
            isReady = true
            flushPendingFiles()
        } catch {
            Log.rpc.error("Failed to connect to embedded nvim: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Mark the session ready without starting Neovim; for tests and previews.
    func markReadyForTesting() {
        isReady = true
        flushPendingFiles()
    }

    /// Send a raw `nvim_command`; failures are logged, not thrown, so menu
    /// actions stay one-liners.
    func command(_ command: String) {
        Task {
            do {
                try await client.command(command)
            } catch {
                Log.app.error("nvim_command failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Send raw key notation to Neovim.
    func input(_ keys: String) {
        Task {
            do {
                try await client.input(keys)
            } catch {
                Log.input.error("nvim_input failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Open files in the running instance, queueing them until the session is
    /// ready (files dropped before nvim finishes handshaking must not be lost).
    func open(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if isReady {
            openHandler(urls)
        } else {
            pendingFiles.append(contentsOf: urls)
        }
    }

    private func flushPendingFiles() {
        guard !pendingFiles.isEmpty else { return }
        let urls = pendingFiles
        pendingFiles = []
        openHandler(urls)
    }

    /// Default opener: `:edit` each escaped path in Neovim.
    private static func openInNeovim(_ urls: [URL]) {
        let client = NvimClient()
        Task {
            for url in urls {
                do {
                    let escaped = try await client.fnameescape(url.path(percentEncoded: false))
                    try await client.command("edit \(escaped)")
                } catch {
                    Log.app.error(
                        "Failed to open \(url.path(percentEncoded: false), privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
    }
}
