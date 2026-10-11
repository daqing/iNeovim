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

    /// Whether the nvim colorscheme background is dark (nil before nvim
    /// reports default colors). Drives the window chrome color scheme.
    @Published private(set) var themeIsDark: Bool?

    func setThemeIsDark(_ isDark: Bool?) {
        if themeIsDark != isDark {
            themeIsDark = isDark
        }
        // The first report is the new window's reveal trigger (see revealWindow).
        if isDark != nil {
            revealWindow()
        }
    }

    /// nvim's default fg/bg (0xRRGGBB), mirrored so the native terminal
    /// pane can match the editor's colorscheme.
    struct TerminalColors: Equatable {
        var foreground: Int?
        var background: Int?

        init(foreground: Int? = nil, background: Int? = nil) {
            self.foreground = foreground
            self.background = background
        }
    }

    @Published private(set) var terminalColors = TerminalColors()

    func setTerminalColors(_ colors: TerminalColors) {
        if terminalColors != colors {
            terminalColors = colors
        }
    }

    let session: RPCSession
    let screen: Screen
    let inputDispatcher: InputDispatcher
    let client: NvimClient
    /// Window hosting this session; set when the terminal view is installed.
    weak var hostWindow: NSWindow?

    /// Diagnostics pushed by the embedded nvim's language servers (see
    /// `NvimClient.installDiagnosticsHook`); the problems panel renders it.
    let diagnosticsStore = DiagnosticsStore()

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
    /// close), make this the active session, and register the window for
    /// native tabbing.
    func attach(to window: NSWindow) {
        hostWindow = window
        becameActive()
        if !hasRevealedWindow {
            // Hold the window invisible until its theme is known so it can
            // fade in with the right look instead of showing the system
            // appearance and snapping when nvim reports (see revealWindow).
            window.alphaValue = 0
            scheduleWindowRevealFallback()
        }
        AppDelegate.shared?.registerEditorWindow(window, model: self)
    }

    // MARK: - Window reveal

    /// A new editor window starts invisible (`attach` sets alpha 0) and
    /// fades in once its theme is known, so a dark-themed nvim in a
    /// light-system window never flashes the empty light state and then
    /// snaps dark. With native tabs the previous tab shows through until
    /// the fade, so the new tab reads as a soft crossfade over it.
    static let windowRevealDuration: TimeInterval = 0.3

    /// How long a window may stay hidden waiting for its first theme report
    /// before it is faded in regardless (bootstrap failures reveal sooner).
    static let windowRevealTimeout: Duration = .seconds(1.5)

    private var hasRevealedWindow = false
    private var windowRevealTask: Task<Void, Never>?

    /// Fade the hosting window in; idempotent. Runs on the first known
    /// theme, on a bootstrap failure (the setup/error UI must be visible),
    /// or on the timeout started in `attach`.
    private func revealWindow() {
        guard !hasRevealedWindow else { return }
        hasRevealedWindow = true
        windowRevealTask?.cancel()
        windowRevealTask = nil
        guard let window = hostWindow else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.windowRevealDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    private func scheduleWindowRevealFallback() {
        windowRevealTask?.cancel()
        windowRevealTask = Task { [weak self] in
            try? await Task.sleep(for: Self.windowRevealTimeout)
            guard !Task.isCancelled else { return }
            self?.revealWindow()
        }
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
                guard let self else { return }
                Task { @MainActor in self.windowTitle = title }
            }
            // Diagnostics from every language server arrive as
            // `ineovim:diagnostics` notifications; subscribe before attaching,
            // like the redraw stream, so early publishes are not dropped.
            await session.addNotificationHandler(for: NvimDiagnosticUpdate.rpcMethod) { [weak self] params in
                guard let update = NvimDiagnosticUpdate.parse(params) else { return }
                guard let self else { return }
                Task { @MainActor in self.handleDiagnosticUpdate(update) }
            }
            try await client.uiAttach(width: 80, height: 24, options: .map(MsgPackValueMap([
                .string("ext_linegrid"): .bool(true),
                .string("ext_popupmenu"): .bool(true),
            ])))
            Log.render.info("UI attached 80x24 (ext_linegrid, ext_popupmenu)")
            // One wheel event scrolls exactly one line so the visual lead
            // in ScrollAccumulator maps 1:1 to grid_scroll confirmations.
            try await client.command("set mousescroll=ver:1,hor:1")
            do {
                if try await client.installDiagnosticsHook() != true {
                    Log.app.warning("Diagnostics hook did not install; the problems sheet stays empty")
                }
            } catch {
                Log.app.error("Failed to install diagnostics hook: \(error.localizedDescription, privacy: .public)")
            }
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
        diagnosticsStore.clear()
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
        // The setup/error UI replaces the theme as the reveal trigger.
        revealWindow()
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

    // MARK: - Native tabs

    // Tabs are native macOS window tabs (Terminal/Ghostty style): each tab is
    // its own window with its own embedded nvim session, joined through
    // NSWindow's tab group. nvim's own tabpages stay reachable through
    // `gt`/`gT` and un-intercepted `:tab*` commands for configs that use them.

    /// ⌘T / a typed `:tabnew [file]`: open a new editor window as a tab of
    /// this window's tab group, opening `file` (typed cmdline text, resolved
    /// against nvim's cwd) in it once the new session is ready.
    func requestNativeTab(file: String) {
        Task { @MainActor in
            let directory = (try? await client.currentDirectory()) ?? ""
            AppDelegate.shared?.requestNewTab(
                from: hostWindow,
                file: Self.resolveTabFile(file, workingDirectory: directory)
            )
        }
    }

    /// Resolve a typed `:tabnew` file name against nvim's working directory;
    /// nil for a bare `:tabnew` (the new session starts in $HOME).
    static func resolveTabFile(_ file: String, workingDirectory: String) -> URL? {
        let name = file.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let path = NSString(string: name).expandingTildeInPath
        guard !path.hasPrefix("/") else { return URL(fileURLWithPath: path) }
        let base = workingDirectory.isEmpty
            ? FileManager.default.currentDirectoryPath
            : workingDirectory
        return URL(fileURLWithPath: base).appendingPathComponent(path).standardized
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

    // MARK: - Native terminal pane

    /// Startup parameters for one native terminal pane surface.
    struct TerminalPaneRequest: Equatable {
        let workingDirectory: String
        let shellCommand: String
    }

    /// What the terminal pane should do next; consumed by the split
    /// container, which owns the actual Ghostty surface.
    enum TerminalPaneIntent: Equatable {
        case open(TerminalPaneRequest)
        case focus
        case close
    }

    /// Whether this window's native terminal pane is shown; kept in sync by
    /// the split container as it opens and closes the surface.
    @Published private(set) var isTerminalPaneVisible = false

    @Published private(set) var terminalPaneIntent: TerminalPaneIntent?

    func setTerminalPaneVisible(_ visible: Bool) {
        isTerminalPaneVisible = visible
    }

    /// Open the native terminal pane in the session's working directory
    /// (running `shellCommand` instead of the default shell when nonempty),
    /// or focus it when it is already shown.
    func requestTerminalPane(command: String) {
        guard !isTerminalPaneVisible else {
            terminalPaneIntent = .focus
            return
        }
        Task { @MainActor in
            let directory = (try? await client.currentDirectory()) ?? ""
            terminalPaneIntent = .open(TerminalPaneRequest(
                workingDirectory: directory,
                shellCommand: command
            ))
        }
    }

    /// Menu / ⌃` action: hide a shown pane, otherwise open one.
    func toggleTerminalPane() {
        if isTerminalPaneVisible {
            terminalPaneIntent = .close
        } else {
            requestTerminalPane(command: "")
        }
    }

    // MARK: - Diagnostics panel

    /// Whether the docked problems panel is shown in this window; the split
    /// container mirrors the flag into the layout.
    @Published private(set) var isProblemsPanelVisible = false

    /// Deliver one per-buffer diagnostics snapshot from the embedded nvim.
    /// The panel refreshes through the store's `onChange`; it opens only on
    /// demand (⌘I / Neovim menu / header ✕), never automatically.
    func handleDiagnosticUpdate(_ update: NvimDiagnosticUpdate) {
        diagnosticsStore.apply(update)
    }

    /// Menu action: show the docked problems panel, or hide it.
    func toggleProblemsPanel() {
        isProblemsPanelVisible.toggle()
    }

    /// Header close button (and any future explicit show/hide) in the panel.
    func setProblemsPanelVisible(_ visible: Bool) {
        isProblemsPanelVisible = visible
    }

    /// Jump the editor to a problem row from the panel: `:edit` the file when
    /// it is not the current buffer, then move the cursor. The panel keeps
    /// focus, so the arrow keys keep walking the list.
    func jumpToProblem(_ problem: DiagnosticsStore.Problem) {
        Task { @MainActor in
            do {
                if !problem.path.isEmpty {
                    let current = try await client.evaluate("expand('%:p')")
                    if current != problem.path {
                        let escaped = try await client.fnameescape(problem.path)
                        try await client.command("edit \(escaped)")
                    }
                }
                try await client.moveCursor(
                    line: problem.diagnostic.line + 1,
                    column: problem.diagnostic.column
                )
            } catch {
                Log.app.error(
                    "Failed to jump to \(problem.path, privacy: .public):\(problem.diagnostic.line + 1, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
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
