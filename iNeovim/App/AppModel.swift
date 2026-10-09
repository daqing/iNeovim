import AppKit
import Combine
import Foundation
import os

/// An unexpected exit of the embedded Neovim process, surfaced to the UI so
/// the user can restart it.
struct NvimCrash: Identifiable, Equatable, Sendable {
    let id = UUID()
    let status: Int32
}

/// First-run setup guidance: nvim is missing, so the app explains how to
/// install it — via Homebrew when present, or Homebrew itself via brew.sh.
struct NvimSetupGuide: Equatable {
    let homebrewInstalled: Bool
}

/// Weak box for tracking live per-window sessions without keeping them alive.
@MainActor
private final class WeakModelBox {
    weak var value: AppModel?
    init(value: AppModel) { self.value = value }
}

/// Coordination for one window and its embedded Neovim session: owns the
/// process/RPC/screen/input stack, forwards editor commands, and queues files
/// opened before the session is ready. Each window owns its own model; menu
/// commands and system file opens route through `AppModel.active`.
@MainActor
final class AppModel: ObservableObject {
    /// The key window's session; menu commands act on it.
    static weak var active: AppModel?

    private static var liveBoxes: [WeakModelBox] = []

    /// Sessions whose windows are still open.
    static var live: [AppModel] {
        liveBoxes = liveBoxes.filter { $0.value != nil }
        return liveBoxes.compactMap(\.value)
    }

    /// Files opened through the system (Dock, "Open With", the Open panel)
    /// before any session could take them; flushed to a session once ready.
    private static var stagedFiles: [URL] = []

    /// True once the embedded Neovim is attached and its streams are running.
    @Published private(set) var isReady = false

    /// Window title reported by Neovim through `set_title`.
    @Published private(set) var windowTitle: String?

    /// Last unexpected nvim exit, or nil while the session is healthy.
    @Published private(set) var crash: NvimCrash?

    /// Reason the last bootstrap attempt failed, or nil after success.
    @Published private(set) var bootstrapError: String?

    /// Setup guidance shown while nvim is missing, or nil.
    @Published private(set) var setup: NvimSetupGuide?

    let session: RPCSession
    let screen: Screen
    let inputDispatcher: InputDispatcher
    let client: NvimClient
    /// Window hosting this session; set when the terminal view is installed.
    weak var hostWindow: NSWindow?

    private let openHandler: @MainActor ([URL], NvimClient) -> Void
    private let commandHandler: @MainActor (String, NvimClient) -> Void
    private let cleanExitHandler: (@MainActor () -> Void)?
    private var pendingFiles: [URL] = []
    private var terminationTask: Task<Void, Never>?
    private var isShuttingDown = false
    private var isBootstrapping = false

    /// Files opened before startup finished, exposed for tests.
    var pendingFileCount: Int { pendingFiles.count }

    init(
        session: RPCSession = RPCSession(),
        screen: Screen = Screen(),
        inputDispatcher: InputDispatcher = InputDispatcher(),
        openHandler: @escaping @MainActor ([URL], NvimClient) -> Void = AppModel.openInNeovim,
        commandHandler: @escaping @MainActor (String, NvimClient) -> Void = AppModel.commandInNeovim,
        cleanExitHandler: (@MainActor () -> Void)? = nil
    ) {
        self.session = session
        self.screen = screen
        self.inputDispatcher = inputDispatcher
        self.client = NvimClient(session: session)
        self.openHandler = openHandler
        self.commandHandler = commandHandler
        self.cleanExitHandler = cleanExitHandler
        Self.liveBoxes.append(WeakModelBox(value: self))
    }

    deinit {
        // Closing a window must not leak its embedded nvim; terminating an
        // unstarted process is a no-op.
        let process = session.process
        Task { await process.terminate() }
    }

    /// Called when the hosting window becomes (or is installed in) the key
    /// window so menu commands and system file opens reach the session the
    /// user is driving.
    func becameActive() {
        AppModel.active = self
    }

    /// Remember the window hosting this session (used by the clean-exit
    /// close) and make this the active session.
    func attach(to window: NSWindow) {
        hostWindow = window
        becameActive()
    }

    /// Start the embedded Neovim, attach the UI, and begin consuming the
    /// redraw and input streams. Idempotent.
    func bootstrap() async {
        guard !isReady, !isBootstrapping else { return }
        isBootstrapping = true
        defer { isBootstrapping = false }
        do {
            bootstrapError = nil
            setup = nil
            try await session.start()
            try await session.handshake()
            // Subscribe before attaching: nvim sends its first full screen as
            // the redraw batch that immediately follows ui_attach, and that
            // batch is lost if no handler is registered yet.
            let stream = await client.makeRedrawEventStream()
            await screen.startConsuming(stream)
            await screen.setTitleHandler { [weak self] title in
                Task { @MainActor in self?.windowTitle = title }
            }
            try await client.uiAttach(width: 80, height: 24, options: .map(MsgPackValueMap([
                .string("ext_linegrid"): .bool(true),
            ])))
            Log.render.info("UI attached 80x24 (ext_linegrid)")
            // One wheel event scrolls exactly one line so the visual lead
            // in ScrollAccumulator maps 1:1 to grid_scroll confirmations.
            try await client.command("set mousescroll=ver:1,hor:1")
            await inputDispatcher.startConsuming(with: client)
            startObservingTermination()
            isReady = true
            flushPendingFiles()
            AppModel.flushStagedFiles()
        } catch {
            handleBootstrapFailure(error)
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
        let process = session.process
        terminationTask = Task { [weak self] in
            for await status in process.termination {
                guard let self else { return }
                self.handleTermination(status: status)
            }
        }
    }

    /// Called when the embedded nvim exits. Intentional shutdown is ignored;
    /// a clean exit (status 0, e.g. `:q` on the last tab) closes the window
    /// instead of surfacing a crash; anything else offers a restart.
    func handleTermination(status: Int32) {
        guard !isShuttingDown else { return }
        isReady = false
        guard status != 0 else {
            Log.app.info("Embedded nvim exited cleanly; closing the window")
            if let cleanExitHandler {
                cleanExitHandler()
            } else {
                closeOwnWindowQuittingIfLast()
            }
            return
        }
        crash = NvimCrash(status: status)
        Log.app.error("Embedded nvim exited unexpectedly (status \(status, privacy: .public))")
    }

    /// Close the window this session ran in. One session per window means the
    /// app has nothing left to show without an editor window, so quit when
    /// none remains.
    private func closeOwnWindowQuittingIfLast() {
        let window = hostWindow ?? NSApp.keyWindow
        window?.close()
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            NSApp.terminate(nil)
        }
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
        await screen.stopConsuming()
        await screen.resetState()
        await session.redrawBus.reset()
        await inputDispatcher.reset()
        await session.reset()
        await bootstrap()
    }

    /// Stop the session for app termination or window teardown.
    func shutdownSession() async {
        await screen.stopConsuming()
        await session.process.terminate()
    }

    /// Route a failed bootstrap: a missing nvim enters the setup flow;
    /// anything else surfaces as a generic error.
    func handleBootstrapFailure(_ error: Error) {
        guard case NvimDiscoveryError.notFound = error else {
            bootstrapError = error.localizedDescription
            Log.rpc.error("Failed to connect to embedded nvim: \(error.localizedDescription, privacy: .public)")
            return
        }
        let homebrew = NvimDiscovery.locateHomebrew() != nil
        setup = NvimSetupGuide(homebrewInstalled: homebrew)
        Log.app.info("nvim not found; entering setup flow (Homebrew installed: \(homebrew, privacy: .public))")
    }

    /// Send a raw `nvim_command`; failures are logged, not thrown, so menu
    /// actions stay one-liners.
    func command(_ command: String) {
        commandHandler(command, client)
    }

    // MARK: - Tabs

    // T8.2 decision: tabs are Neovim tabpages, not native window tabs. Each
    // window's embedded nvim already draws the tabline and owns the
    // buffer/window/tab model. Editor commands below route to `:tab*`, and
    // `gt`/`gT` keep working through normal key input.

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

    /// Open files in this window's session, queueing them until the session
    /// is ready (files dropped before nvim finishes handshaking must not be
    /// lost).
    func open(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if isReady {
            openHandler(urls, client)
        } else {
            pendingFiles.append(contentsOf: urls)
        }
    }

    /// Open files from outside any window (Dock, "Open With", the Open
    /// panel): give them to the active ready session, else any ready one,
    /// else stage them until a session comes up.
    static func openFromSystem(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        stagedFiles.append(contentsOf: urls)
        flushStagedFiles()
    }

    static func flushStagedFiles() {
        guard !stagedFiles.isEmpty else { return }
        let ready = live.filter(\.isReady)
        let target = (active?.isReady == true ? active : ready.first) ?? active ?? live.first
        guard let target else { return }
        let urls = stagedFiles
        stagedFiles = []
        target.open(urls)
    }

    private func flushPendingFiles() {
        guard !pendingFiles.isEmpty else { return }
        let urls = pendingFiles
        pendingFiles = []
        openHandler(urls, client)
    }

    /// Default command sink: fire the command at this session.
    private static func commandInNeovim(_ command: String, client: NvimClient) {
        Task {
            do {
                try await client.command(command)
            } catch {
                Log.app.error("nvim_command failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Default opener: `:edit` each escaped path in this session.
    private static func openInNeovim(_ urls: [URL], client: NvimClient) {
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
