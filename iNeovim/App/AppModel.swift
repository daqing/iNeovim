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

    /// Theme mode and packed default background to seed the next window a
    /// native-tab request creates (the requesting window's): consumed by the
    /// following `init`, so the new tab paints its host's exact look from its
    /// first frame instead of flashing the system appearance until nvim
    /// reports. Both self-clearing.
    static var pendingThemeSeed: Bool?
    static var pendingBackgroundSeed: Int?

    /// Last scheme/background any session reported, persisted so a brand-new
    /// window (launch / ⌘N) is created with the right look before its nvim
    /// starts. Without it the window is born in the system appearance and
    /// flashes light on a dark theme until the first report.
    private static let persistedThemeKey = "lastThemeIsDark"
    private static let persistedBackgroundKey = "lastDefaultBackground"

    static var persistedThemeIsDark: Bool? {
        UserDefaults.standard.object(forKey: persistedThemeKey) as? Bool
    }

    static var persistedBackground: Int? {
        UserDefaults.standard.object(forKey: persistedBackgroundKey) as? Int
    }

    /// Notification carrying nvim's working directory (see
    /// `NvimClient.installWorkingDirectoryHook`).
    private static let workingDirectoryNotification = "ineovim:dirchanged"

    /// The active session's working directory, persisted so a launch by
    /// clicking the app starts where the user left off. A window opened by an
    /// `ineovim` command never uses it: that window's directory comes from the
    /// command, which would otherwise be shadowed by this value on a cold
    /// launch (the launch window boots before the request reaches it).
    private static let persistedWorkingDirectoryKey = "lastWorkingDirectory"

    /// The persisted directory, or nil when there is none or it no longer
    /// exists (nvim then starts in `$HOME`).
    static var persistedWorkingDirectory: URL? {
        guard let path = UserDefaults.standard.string(forKey: persistedWorkingDirectoryKey) else {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func persistWorkingDirectory(_ directory: URL?) {
        guard let path = directory?.path(percentEncoded: false) else { return }
        if UserDefaults.standard.string(forKey: persistedWorkingDirectoryKey) != path {
            UserDefaults.standard.set(path, forKey: persistedWorkingDirectoryKey)
        }
    }

    /// The seeded packed default background, used to paint this window until
    /// nvim reports its own (the first flush replaces it in the snapshot).
    private(set) var seededBackground: Int?

    /// True once a snapshot actually carried a scheme. Until then a `nil` from
    /// `refreshWindowAppearance` (no snapshot yet) must not clear the seed.
    private var hasReportedTheme = false

    func setThemeIsDark(_ isDark: Bool?) {
        if let isDark {
            hasReportedTheme = true
            if UserDefaults.standard.object(forKey: Self.persistedThemeKey) as? Bool != isDark {
                UserDefaults.standard.set(isDark, forKey: Self.persistedThemeKey)
            }
        } else if !hasReportedTheme && themeIsDark != nil {
            // Pre-report `nil` from the empty snapshot: keep the seeded scheme
            // so the window is not reverted to the system appearance.
            return
        }
        if themeIsDark != isDark {
            themeIsDark = isDark
        }
        // The first report is the reveal trigger: the window fades in with
        // its real theme and its content already drawn. Native tab windows
        // are already revealed, so this is a no-op for them.
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
        if let background = colors.background,
           UserDefaults.standard.object(forKey: Self.persistedBackgroundKey) as? Int != background {
            UserDefaults.standard.set(background, forKey: Self.persistedBackgroundKey)
        }
        if terminalColors != colors {
            terminalColors = colors
        }
    }

    /// Buffer text areas of the current tabpage's windows, as nvim reports
    /// them (see `NvimClient.installTextLayoutHook`). The renderer draws their
    /// glyphs a few points right of the grid so buffer text clears the gutter.
    @Published private(set) var textRegions: [NvimTextRegion] = []

    func setTextRegions(_ regions: [NvimTextRegion]) {
        if textRegions != regions {
            textRegions = regions
        }
    }

    /// Take the working directory nvim reported, saving it when this is the
    /// active window so the next launch resumes there.
    func setWorkingDirectory(_ path: String) {
        guard !path.isEmpty else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        if currentWorkingDirectory != directory {
            currentWorkingDirectory = directory
        }
        if AppModel.active === self {
            Self.persistWorkingDirectory(directory)
        }
    }

    let session: RPCSession
    let screen: Screen
    let inputDispatcher: InputDispatcher
    let client: NvimClient
    /// Window hosting this session; set when the terminal view is installed.
    weak var hostWindow: NSWindow?

    /// The grid size the hosting view needs, reported as it lays out. nvim is
    /// attached at this size instead of the 80x24 placeholder, which would
    /// otherwise be drawn and then resized a debounce interval later — on a
    /// new tab that reads as the content wiping in from the top.
    private(set) var pendingGridSize: (cols: Int, rows: Int)?

    func noteGridSize(cols: Int, rows: Int) {
        pendingGridSize = (max(1, cols), max(1, rows))
    }

    /// Diagnostics pushed by the embedded nvim's language servers (see
    /// `NvimClient.installDiagnosticsHook`); the problems panel renders it.
    let diagnosticsStore = DiagnosticsStore()

    private let openHandler: @MainActor ([URL], NvimClient) -> Void
    private let commandHandler: @MainActor (String, NvimClient) -> Void
    private let cleanExitHandler: (@MainActor () -> Void)?
    private var pendingFiles: [URL] = []
    /// Directory an `ineovim` command opened this window in. It seeds the
    /// nvim child process (so init.lua sees it) and doubles as the
    /// post-attach `:cd` when the request arrives after startup began.
    private var workingDirectory: URL?
    /// The session's live working directory, reported by nvim on startup and
    /// on every `DirChanged`. Persisted while this window is active (and again
    /// as the app terminates) so the next launch can start there.
    private(set) var currentWorkingDirectory: URL?
    /// True for the window SwiftUI opened at launch, marked by
    /// `AppDelegate.registerEditorWindow`. It is the only window that starts
    /// in the saved working directory; `$HOME` stays the default otherwise.
    var isLaunchWindow = false
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
        if let seed = Self.pendingThemeSeed {
            Self.pendingThemeSeed = nil
            themeIsDark = seed
        } else {
            // A fresh window has no host to inherit from; fall back to the
            // active session, then the last persisted scheme, so SwiftUI
            // builds the window already themed.
            themeIsDark = AppModel.active?.themeIsDark ?? Self.persistedThemeIsDark
        }
        seededBackground = Self.pendingBackgroundSeed
            ?? AppModel.active?.terminalColors.background
            ?? Self.persistedBackground
        Self.pendingBackgroundSeed = nil
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
    /// user is driving. The window's directory is saved on the way: the active
    /// window's is the one the next launch resumes in.
    func becameActive() {
        AppModel.active = self
        AppModel.persistWorkingDirectory(currentWorkingDirectory)
    }

    /// Remember the window hosting this session (used by the clean-exit
    /// close), make this the active session, and register the window for
    /// native tabbing.
    func attach(to window: NSWindow) {
        hostWindow = window
        becameActive()
        // AppKit's inferred window animations (the order-in drop and the
        // tab-bar entrance that shifts the grid down) only add motion on top
        // of a redraw the view already handles itself; suppress them so a new
        // tab lands instantly.
        window.animationBehavior = .none
        if !hasRevealedWindow {
            // Hide until the theme is known (or the reveal timeout) so the
            // first frame is never the system appearance before
            // `preferredColorScheme` lands. Native tab windows are released
            // at once by `registerEditorWindow`. Setting alpha here (rather
            // than in the view) keeps a re-added view from re-hiding a
            // window that has already been revealed.
            window.alphaValue = 0
            scheduleWindowRevealFallback()
        }
        AppDelegate.shared?.registerEditorWindow(window, model: self)
    }

    // MARK: - Window reveal

    /// A plain editor window (⌘N / first launch) is created invisible and
    /// fades in once its theme is known: a fresh standalone window displays
    /// for 1–2 frames before `preferredColorScheme` reaches it and would
    /// otherwise flash the system appearance. Native tab windows do not use
    /// this path (see `revealWindowImmediately`).
    static let windowRevealDuration: TimeInterval = 0.25

    /// How long a window may stay hidden waiting for its first theme report
    /// before it is revealed regardless (bootstrap failures reveal sooner).
    static let windowRevealTimeout: Duration = .seconds(1.5)

    private var hasRevealedWindow = false
    private var windowRevealTask: Task<Void, Never>?
    /// An `ineovim` command opened this window to be typed in at once: take
    /// keyboard focus as it is revealed, instead of leaving it in whatever
    /// window was key when the command was run.
    private var focusesOnReveal = false

    /// Bring the app forward now and make the window key once it is visible.
    /// Focusing before the fade would leave the keyboard on a transparent
    /// window for the first frames.
    func focusAfterCommandLineOpen() {
        focusesOnReveal = true
        guard let window = hostWindow else { return }
        NSApp.activate()
        if hasRevealedWindow {
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Release a window that must not use the standalone fade: a native tab
    /// joining its host's group. The seeded theme is already painted, so the
    /// window is ordered front at once and AppKit's own tab-add transition is
    /// the whole animation. A standalone fade would instead expose a window
    /// without the group's tab bar, then jump the grid vertically when the
    /// deferred join shifted the content down under it.
    func revealWindowImmediately() {
        guard !hasRevealedWindow else { return }
        hasRevealedWindow = true
        windowRevealTask?.cancel()
        windowRevealTask = nil
        guard let window = hostWindow else { return }
        // Pin the seeded scheme on the window as well: the hosting WindowGroup
        // resets `window.appearance` on its next update pass, but by then the
        // seeded `preferredColorScheme` is what it resets to, so the dark look
        // holds through the first frames instead of flashing the system mode.
        if let dark = themeIsDark {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        }
        window.alphaValue = 1
    }

    /// Fade the hosting window in; idempotent. Runs on the first known
    /// theme, on a bootstrap failure (the setup/error UI must be visible),
    /// or on the timeout scheduled in `attach`.
    private func revealWindow() {
        guard !hasRevealedWindow else { return }
        hasRevealedWindow = true
        windowRevealTask?.cancel()
        windowRevealTask = nil
        guard let window = hostWindow else { return }
        let desired: NSAppearance.Name? = themeIsDark.map { $0 ? .darkAqua : .aqua }
        windowRevealTask = Task { @MainActor [weak self] in
            if let desired {
                // The hosting WindowGroup installs `preferredColorScheme` a
                // frame or two after `themeIsDark` changes; fading before then
                // showed a light titlebar that darkened mid-flight. Wait
                // (bounded) for the window to actually take the scheme, then
                // pin it so the chrome is themed before the first visible
                // frame.
                for _ in 0..<12 {
                    let current = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
                    if current == desired { break }
                    try? await Task.sleep(for: .milliseconds(8))
                }
                window.appearance = NSAppearance(named: desired)
            }
            guard let self, self.hostWindow === window else { return }
            self.fadeIn(window)
        }
    }

    /// Order the window front and fade it in. Kept synchronous so
    /// `NSAnimationContext.runAnimationGroup` resolves to its non-async
    /// overload rather than the Swift-concurrency one.
    private func fadeIn(_ window: NSWindow) {
        if focusesOnReveal {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
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
            // The launch window resumes in the directory the last session
            // was in; a window an `ineovim` command opened starts in the
            // directory the command ran in, which takes precedence.
            let resumed = isLaunchWindow ? Self.persistedWorkingDirectory : nil
            try await session.start(workingDirectory: workingDirectory ?? resumed)
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
            // The gutter layout (how many columns each window's `textoff`
            // gutter occupies) arrives as `ineovim:textlayout` notifications.
            await session.addNotificationHandler(for: NvimTextLayout.rpcMethod) { [weak self] params in
                guard let regions = NvimTextLayout.parse(params) else { return }
                guard let self else { return }
                Task { @MainActor in self.setTextRegions(regions) }
            }
            // The working directory follows `:cd` in the session; the latest
            // one is remembered for the next launch.
            await session.addNotificationHandler(for: Self.workingDirectoryNotification) { [weak self] params in
                guard let path = params.first?.stringValue else { return }
                guard let self else { return }
                Task { @MainActor in self.setWorkingDirectory(path) }
            }
            // Long lines soft-wrap at the window's right edge. A single
            // linegrid exposes no horizontal scrolling, so without wrap the
            // rest of the line is unreachable; applied before attaching so
            // the first full screen is already wrapped instead of reflowing.
            try await client.installWrap()
            // A directory an `ineovim` command asked for must be in effect
            // before `ui_attach`: nvim finishes startup — and sources
            // init.lua — only once the UI attaches, so a `:cd` after that
            // would leave a config that reads `getcwd()` at startup in the
            // wrong directory. The request can land at any point in the
            // sequence, so it is re-read after every later suspension.
            let appliedDirectory = await applyRequestedDirectory()
            let attach = pendingGridSize ?? (cols: 80, rows: 24)
            try await client.uiAttach(width: attach.cols, height: attach.rows, options: .map(MsgPackValueMap([
                .string("ext_linegrid"): .bool(true),
                .string("ext_popupmenu"): .bool(true),
                // Per-window grids: splits, floats, and the message/cmdline
                // area each arrive as their own grid positioned on the
                // screen, so the renderer layers windows instead of
                // compositing one global grid.
                .string("ext_multigrid"): .bool(true),
            ])))
            Log.render.info("UI attached \(attach.cols)x\(attach.rows) (ext_linegrid, ext_popupmenu, ext_multigrid)")
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
            do {
                if try await client.installTextLayoutHook() != true {
                    Log.render.warning("Text layout hook did not install; text keeps its cell origin")
                }
            } catch {
                Log.render.error("Failed to install text layout hook: \(error.localizedDescription, privacy: .public)")
            }
            do {
                if try await client.installTruncatedLines() != true {
                    // false is the expected outcome on nvim 0.12, whose
                    // conceal_lines + virt_lines scroll bugs freeze upward
                    // scrolling next to preview rows (see the version gate
                    // in `NvimClient.truncatedLinesLua`).
                    Log.app.info("Truncated lines off: needs nvim 0.13+; over-long lines stay fully wrapped")
                }
            } catch {
                Log.app.error("Failed to install truncated-line hook: \(error.localizedDescription, privacy: .public)")
            }
            do {
                if try await client.installWorkingDirectoryHook() != true {
                    Log.app.warning("Working directory hook did not install; the next launch starts in $HOME")
                }
            } catch {
                Log.app.error("Failed to install working directory hook: \(error.localizedDescription, privacy: .public)")
            }
            await inputDispatcher.startConsuming(with: client) { [weak self] in
                self?.announceSelectionCopy()
            }
            startObservingTermination()
            // A request can also land while the attach and the hooks run; it
            // must be applied before the queued files open.
            await applyRequestedDirectory(after: appliedDirectory)
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

    /// Incremented after a mouse selection lands on the pasteboard; the
    /// split container flashes a short "已复制" HUD 200 ms later. A counter
    /// rather than a flag so repeated copies each re-announce.
    @Published private(set) var selectionCopyCount = 0

    private func announceSelectionCopy() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self else { return }
            selectionCopyCount += 1
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
        case focusEditor
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

    /// Menu / ⌘D action (⌃` alternate): hide a shown pane, otherwise open one.
    func toggleTerminalPane() {
        if isTerminalPaneVisible {
            terminalPaneIntent = .close
        } else {
            requestTerminalPane(command: "")
        }
    }

    /// Menu / ⌘R action: focus the terminal pane, opening it when it is
    /// hidden.
    func focusTerminalPane() {
        requestTerminalPane(command: "")
    }

    // MARK: - Markdown preview

    /// Open preview windows owned by this editor window, keyed by the
    /// previewed buffer's name (one window per file). Re-previewing a file
    /// re-renders its existing window.
    private var markdownPreviews: [String: MarkdownPreviewWindowController] = [:]

    /// ⌘R: preview the current Markdown buffer in a separate reading window.
    /// For every other buffer the chord keeps its old meaning — focus the
    /// terminal pane (opening it when hidden).
    func handleCmdR() {
        Task { @MainActor in
            if let snapshot = try? await client.currentBufferSnapshot(), snapshot.isMarkdown {
                presentMarkdownPreview(snapshot)
            } else {
                focusTerminalPane()
            }
        }
    }

    /// Menu action for "Preview Markdown": open the reading window for the
    /// current buffer, or beep when the buffer is not Markdown.
    func previewMarkdown() {
        Task { @MainActor in
            guard let snapshot = try? await client.currentBufferSnapshot(),
                  snapshot.isMarkdown else {
                NSSound.beep()
                return
            }
            presentMarkdownPreview(snapshot)
        }
    }

    private func presentMarkdownPreview(_ snapshot: NvimBufferSnapshot) {
        let theme = markdownTheme()
        let key = snapshot.name.isEmpty ? "<untitled>" : snapshot.name
        if let preview = markdownPreviews[key] {
            preview.update(markdown: snapshot.text, baseURL: snapshot.baseURL, theme: theme)
            preview.present()
            return
        }
        let preview = MarkdownPreviewWindowController(
            title: snapshot.previewTitle,
            fileURL: snapshot.fileURL,
            markdown: snapshot.text,
            baseURL: snapshot.baseURL,
            theme: theme,
            onOpenLink: { [weak self] url in self?.openPreviewLink(url) },
            onClose: { [weak self] in self?.markdownPreviews[key] = nil }
        )
        markdownPreviews[key] = preview
        preview.present()
    }

    private func markdownTheme() -> MarkdownRenderer.Theme {
        let background = terminalColors.background.flatMap(NSColor.init(packedRGB:))
            ?? .textBackgroundColor
        let isDark = TerminalView.hasDarkBackground(terminalColors.background)
            ?? (NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        let foreground = terminalColors.foreground.flatMap(NSColor.init(packedRGB:))
            ?? (isDark ? .white : .black)
        let linkColor: NSColor = isDark
            ? NSColor(srgbRed: 0.45, green: 0.72, blue: 1.0, alpha: 1)
            : NSColor(srgbRed: 0.0, green: 0.38, blue: 0.75, alpha: 1)
        return MarkdownRenderer.Theme(
            foreground: foreground,
            background: background,
            isDark: isDark,
            bodyFont: .systemFont(ofSize: 15),
            codeFont: AppSettings.shared.resolvedFont(),
            linkColor: linkColor
        )
    }

    /// Preview links: local files open in this session's editor (the next
    /// reading step stays in the app); web links use the default browser.
    private func openPreviewLink(_ url: URL) {
        if url.isFileURL {
            open([url])
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Menu / ⌘L action: return keyboard focus to the editor.
    func focusEditor() {
        terminalPaneIntent = .focusEditor
    }

    // MARK: - Diagnostics panel

    /// Whether the docked problems panel is shown in this window; the split
    /// container mirrors the flag into the layout.
    @Published private(set) var isProblemsPanelVisible = false

    /// Deliver one per-buffer diagnostics snapshot from the embedded nvim.
    /// The panel refreshes through the store's `onChange`; it opens only on
    /// demand (⌘P / Neovim menu / header ✕), never automatically.
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

    /// Open the files of an `ineovim` command in the directory it ran in.
    /// The window was created for this request, so its process normally has
    /// not started yet — setting the directory here starts nvim in it. A
    /// session that is already running (the launch window on a cold start)
    /// is moved with `:cd` before its files open, since its process may
    /// already have booted in another directory.
    func openFromCommandLine(directory: URL, files: [URL]) {
        workingDirectory = directory
        focusAfterCommandLineOpen()
        guard isReady else {
            open(files)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            await self.changeWorkingDirectory(to: directory)
            self.open(files)
        }
    }

    /// Move the embedded nvim to `directory`. The process starts there
    /// whenever the request is known early enough; this covers the rest and
    /// keeps init.lua-owned state (autochdir, session files) consistent.
    private func changeWorkingDirectory(to directory: URL) async {
        do {
            let escaped = try await client.fnameescape(directory.path(percentEncoded: false))
            try await client.command("cd \(escaped)")
        } catch {
            Log.app.error(
                "Failed to change directory to \(directory.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Apply the directory a command-line request asked for, and return it.
    /// The request can arrive (and the `:cd` itself can suspend) at any point
    /// of `bootstrap`, so the current request is re-read after every
    /// suspension and the last one wins.
    @discardableResult
    private func applyRequestedDirectory(after applied: URL? = nil) async -> URL? {
        var applied = applied
        while let directory = workingDirectory, directory != applied {
            applied = directory
            await changeWorkingDirectory(to: directory)
        }
        return applied
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
