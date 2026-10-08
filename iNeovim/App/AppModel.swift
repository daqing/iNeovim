import Combine
import Foundation
import os

/// An unexpected exit of the embedded Neovim process, surfaced to the UI so
/// the user can restart it.
struct NvimCrash: Identifiable, Equatable, Sendable {
    let id = UUID()
    let status: Int32
}

/// App-wide coordination between the SwiftUI shell and the embedded Neovim
/// session: owns startup, forwards editor commands, and queues files opened
/// before the session is ready.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    /// True once the embedded Neovim is attached and its streams are running.
    @Published private(set) var isReady = false

    /// Window title reported by Neovim through `set_title`.
    @Published private(set) var windowTitle: String?

    /// Last unexpected nvim exit, or nil while the session is healthy.
    @Published private(set) var crash: NvimCrash?

    /// Reason the last bootstrap attempt failed, or nil after success.
    @Published private(set) var bootstrapError: String?

    private let client = NvimClient()
    private let openHandler: @MainActor ([URL]) -> Void
    private let commandHandler: @MainActor (String) -> Void
    private var pendingFiles: [URL] = []
    private var terminationTask: Task<Void, Never>?
    private var isShuttingDown = false

    /// Files opened before startup finished, exposed for tests.
    var pendingFileCount: Int { pendingFiles.count }

    init(
        openHandler: @escaping @MainActor ([URL]) -> Void = AppModel.openInNeovim,
        commandHandler: @escaping @MainActor (String) -> Void = AppModel.commandInNeovim
    ) {
        self.openHandler = openHandler
        self.commandHandler = commandHandler
    }

    /// Start the embedded Neovim, attach the UI, and begin consuming the
    /// redraw and input streams. Idempotent.
    func bootstrap() async {
        guard !isReady else { return }
        do {
            bootstrapError = nil
            try await RPCSession.shared.start()
            try await RPCSession.shared.handshake()
            try await client.uiAttach(width: 80, height: 24, options: .map(MsgPackValueMap([
                .string("ext_linegrid"): .bool(true),
            ])))
            Log.render.info("UI attached 80x24 (ext_linegrid)")
            // One wheel event scrolls exactly one line so the visual lead
            // in ScrollAccumulator maps 1:1 to grid_scroll confirmations.
            try await client.command("set mousescroll=ver:1,hor:1")
            await Screen.shared.setTitleHandler { title in
                Task { @MainActor in AppModel.shared.windowTitle = title }
            }
            let stream = await client.makeRedrawEventStream()
            await Screen.shared.startConsuming(stream)
            await InputDispatcher.shared.startConsuming(with: client)
            startObservingTermination()
            isReady = true
            flushPendingFiles()
        } catch {
            bootstrapError = error.localizedDescription
            Log.rpc.error("Failed to connect to embedded nvim: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Mark the session ready without starting Neovim; for tests and previews.
    func markReadyForTesting() {
        isReady = true
        flushPendingFiles()
    }

    // MARK: - Crash recovery (T9.1)

    private func startObservingTermination() {
        terminationTask?.cancel()
        terminationTask = Task { [weak self] in
            for await status in NvimProcess.shared.termination {
                guard let self else { return }
                self.handleTermination(status: status)
            }
        }
    }

    /// Called when the embedded nvim exits. Intentional shutdown is ignored;
    /// otherwise the exit is surfaced so the UI can offer a restart.
    func handleTermination(status: Int32) {
        guard !isShuttingDown else { return }
        isReady = false
        crash = NvimCrash(status: status)
        Log.app.error("Embedded nvim exited unexpectedly (status \(status, privacy: .public))")
    }

    /// Mark an intentional shutdown so the exit notification is not surfaced.
    func beginShutdown() {
        isShuttingDown = true
        terminationTask?.cancel()
        terminationTask = nil
    }

    func dismissCrash() {
        crash = nil
    }

    /// Restart the embedded nvim in place: tear down the streams and session,
    /// then bootstrap again. Editor state is not preserved (the process died).
    func restart() {
        guard !isShuttingDown else { return }
        crash = nil
        isReady = false
        Task { await reloadSession() }
    }

    private func reloadSession() async {
        await Screen.shared.stopConsuming()
        await Screen.shared.resetState()
        await RedrawEventStream.shared.reset()
        await InputDispatcher.shared.reset()
        await RPCSession.shared.reset()
        await bootstrap()
    }

    /// Send a raw `nvim_command`; failures are logged, not thrown, so menu
    /// actions stay one-liners.
    func command(_ command: String) {
        commandHandler(command)
    }

    // MARK: - Tabs

    // T8.2 decision: tabs are Neovim tabpages, not native window tabs. One
    // embedded nvim and one line-grid surface already render the tabline and
    // own the buffer/window/tab model, so native tabs would need either a
    // second nvim session or a second view onto a single-consumer redraw
    // stream. Editor commands below route to `:tab*`, and `gt`/`gT` keep
    // working through normal key input.

    func newTab() {
        command("tabnew")
    }

    func closeTab() {
        command("tabclose")
    }

    func nextTab() {
        command("tabnext")
    }

    func previousTab() {
        command("tabprevious")
    }

    func goToTab(_ index: Int) {
        command("tabnext \(index)")
    }

    // MARK: - Windows and files

    func splitHorizontal() {
        command("split")
    }

    func splitVertical() {
        command("vsplit")
    }

    func closeWindow() {
        command("close")
    }

    func save() {
        command("write")
    }

    /// Open an embedded `:terminal`, which exercises the sandbox/entitlement
    /// path tracked by T8.7.
    func openTerminal() {
        command("terminal")
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

    /// Default command sink: fire the command at the RPC session.
    private static func commandInNeovim(_ command: String) {
        let client = NvimClient()
        Task {
            do {
                try await client.command(command)
            } catch {
                Log.app.error("nvim_command failed: \(error.localizedDescription, privacy: .public)")
            }
        }
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
