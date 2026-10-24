import AppKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The adaptor instance. `NSApp.delegate` cannot be cast to this class —
    /// SwiftUI installs its own `SwiftUI.AppDelegate` wrapper that only
    /// forwards `NSApplicationDelegate` protocol methods and `@objc` selectors,
    /// so every `NSApp.delegate as? AppDelegate` silently fails. Route direct
    /// calls through here instead.
    static private(set) weak var shared: AppDelegate?

    /// All editor windows share one tabbing identifier so native tabs
    /// (⌘T, the tab bar's + button) can group them, and so editor windows
    /// never auto-group with SwiftUI scenes like Settings.
    static let editorTabbingIdentifier: NSWindow.TabbingIdentifier = "com.mzevo.iNeovim.editor"

    /// Opens one more editor window; captured from SwiftUI's `openWindow`
    /// action by the first window, since tabs are created from AppKit.
    private var openEditorWindow: (() -> Void)?

    /// Tab placement waiting for the next editor window to register.
    private weak var pendingTabHost: NSWindow?
    private var pendingTabFile: URL?

    /// `ineovim` invocations waiting for a window. Requests are handed out
    /// one at a time: a window consumes its request as its content installs,
    /// and only then does the next request ask for a window, so two commands
    /// never race over the single pending slot.
    private var pendingCommandLineRequest: CommandLineTool.OpenRequest?
    private var queuedCommandLineRequests: [CommandLineTool.OpenRequest] = []

    /// True until launch finishes. A request delivered during launch is
    /// taken by the window SwiftUI already opens, rather than leaving an
    /// empty default window next to it.
    private var isLaunching = true

    /// The editor window SwiftUI opened at launch. A request that caused the
    /// launch can arrive *after* that window registered (LaunchServices
    /// delivers the URL during startup, not before the window exists), so the
    /// request is applied to this window directly — waiting for a pending
    /// window would leave it in `$HOME` forever.
    private weak var launchWindowModel: AppModel?
    private var launchWindowTookRequest = false
    private var didFinishLaunchingAt: Date?

    /// How long after launch a request can still be the one that caused the
    /// launch. The URL event is normally delivered before launch finishes;
    /// the window only stays adoptable for a short margin in case delivery
    /// slips just past `applicationDidFinishLaunching`.
    private static let launchRequestWindow: TimeInterval = 1

    /// Windows whose content has already registered. `viewDidMoveToWindow`
    /// can run again for a window that is already set up, and only the first
    /// registration may take a request meant for a new window. Weak, so a
    /// closed window's identity cannot be mistaken for a new window's.
    private let registeredWindows = NSHashTable<NSWindow>.weakObjects()

    /// The editor window that registered most recently. SwiftUI opens a
    /// window of its own for an external URL — measured about 40 ms before
    /// `application(_:open:)` reaches the delegate — so a request that
    /// arrives next to a freshly registered window belongs to that window.
    private weak var newestWindowModel: AppModel?
    private var newestWindowAt: Date?

    /// Opens a window for a request only when none showed up on its own.
    private var commandLineWindowTask: Task<Void, Never>?
    private static let recentWindowInterval: TimeInterval = 0.5
    private static let commandLineWindowDelay: Duration = .milliseconds(500)

    private var keyDownMonitor: Any?

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        isLaunching = true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Printable keys reach nvim through the text input system (the
        // TerminalView interpretKeyEvents path), where macOS "press and hold"
        // — the accent popup — replaces key repeat: letters without accent
        // alternates (j, k) never repeat at all. Terminal semantics need
        // repeats, so persist the standard terminal-emulator opt-out once;
        // an explicit setting in the app or global domain is left untouched.
        if UserDefaults.standard.object(forKey: "ApplePressAndHoldEnabled") == nil {
            UserDefaults.standard.set(false, forKey: "ApplePressAndHoldEnabled")
        }
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .function])
            guard let key = event.charactersIgnoringModifiers?.lowercased() else { return event }
            switch (modifiers, key) {
            case (.command, "d"):
                return MainActor.assumeIsolated(Self.claimTerminalPaneChord) ? nil : event
            case (.control, "`"):
                return MainActor.assumeIsolated(Self.claimTerminalPaneChord) ? nil : event
            case (.command, "p"):
                return MainActor.assumeIsolated(Self.claimProblemsPanelChord) ? nil : event
            case (.command, "l"):
                return MainActor.assumeIsolated(Self.claimEditorFocusChord) ? nil : event
            case (.command, "r"):
                return MainActor.assumeIsolated(Self.claimTerminalPaneFocusChord) ? nil : event
            default:
                return event
            }
        }
        Log.app.info("Application did finish launching")
        isLaunching = false
        didFinishLaunchingAt = Date()
        pumpCommandLineRequests()
    }

    /// ⌘D (and its ⌃` alternate) toggles the terminal pane from any focused
    /// view. A local monitor sees the keydown before the responder chain and
    /// before Ghostty's `SurfaceView.performKeyEquivalent`, which otherwise
    /// claims ⌘D for its default `new_split:right` binding while the pane is
    /// focused — the menu shortcut alone then only ever opened the pane.
    /// Returns whether the chord was claimed; a modal session leaves it alone.
    private static func claimTerminalPaneChord() -> Bool {
        guard NSApp.modalWindow == nil else { return false }
        AppModel.active?.toggleTerminalPane()
        return true
    }

    /// ⌘P toggles the problems panel like its menu item, which is
    /// display-only: SwiftUI registers the ⌘P equivalent but never fires it
    /// (bare AppKit items do — verified against a real HID keypress), so the
    /// chord is claimed here like the other chords. A modal session leaves it
    /// alone.
    private static func claimProblemsPanelChord() -> Bool {
        guard NSApp.modalWindow == nil else { return false }
        AppModel.active?.toggleProblemsPanel()
        return true
    }

    /// ⌘L returns keyboard focus to the editor from the terminal pane or the
    /// problems panel. Claimed by the local monitor like the other chords.
    private static func claimEditorFocusChord() -> Bool {
        guard NSApp.modalWindow == nil else { return false }
        AppModel.active?.focusEditor()
        return true
    }

    /// ⌘R focuses the terminal pane, opening it when it is hidden. A local
    /// monitor sees the keydown before the responder chain and before
    /// Ghostty's `SurfaceView.performKeyEquivalent`, so the chord works while
    /// the pane already owns the keyboard.
    private static func claimTerminalPaneFocusChord() -> Bool {
        guard NSApp.modalWindow == nil else { return false }
        AppModel.active?.focusTerminalPane()
        return true
    }

    /// "Open With", Dock-icon drops, and `open -a` all arrive here; the model
    /// routes them to the active session or stages them until one is ready.
    /// `ineovim://` requests (the command-line launcher) are not file opens:
    /// each one gets its own window in the directory the command ran in.
    func application(_ application: NSApplication, open urls: [URL]) {
        let requests = urls.compactMap(CommandLineTool.openRequest(from:))
        let files = urls.filter { $0.isFileURL }
        if !files.isEmpty {
            Log.app.info("Open request for \(files.count, privacy: .public) file(s)")
            AppModel.openFromSystem(files)
        }
        if !requests.isEmpty {
            Log.app.info("Command-line open request for \(requests.count, privacy: .public) window(s)")
            queuedCommandLineRequests.append(contentsOf: requests)
            pumpCommandLineRequests()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.app.info("Application will terminate")
        for model in AppModel.live {
            model.beginShutdown()
            Task { await model.shutdownSession() }
        }
    }

    // MARK: - Native tabs

    /// Hand SwiftUI's `openWindow` action over to AppKit; called by the first
    /// editor window's content, which exists before any tab can be requested.
    func registerWindowOpener(_ opener: @escaping () -> Void) {
        guard openEditorWindow == nil else { return }
        openEditorWindow = opener
        pumpCommandLineRequests()
    }

    /// Hand the next `ineovim` request to a window. The window SwiftUI opens
    /// at launch takes a launch-time request as soon as it has registered;
    /// afterwards a request goes to the window SwiftUI itself opened for the
    /// URL event that carried it, and only opens a window of its own when
    /// none shows up.
    private func pumpCommandLineRequests() {
        while pendingCommandLineRequest == nil, !queuedCommandLineRequests.isEmpty {
            let request = queuedCommandLineRequests.removeFirst()

            if !launchWindowTookRequest, isAdoptingLaunchRequest {
                guard let launchWindowModel else {
                    // The launch window is still installing; it takes the
                    // request when it registers. Opening a window here would
                    // race it.
                    pendingCommandLineRequest = request
                    return
                }
                launchWindowTookRequest = true
                newestWindowAt = nil
                Log.app.info("Launch window takes the command-line request")
                launchWindowModel.openFromCommandLine(directory: request.workingDirectory, files: request.files)
                continue
            }

            // SwiftUI opens a window of its own for the external URL —
            // measured ~40 ms before `application(_:open:)` reaches this
            // delegate — so a window that registered just now is the one
            // meant for this request. Asking for another window here produced
            // two windows per `ineovim` invocation (the user saw an extra
            // default one next to the request).
            if let newestWindowModel, let newestWindowAt,
               Date().timeIntervalSince(newestWindowAt) < Self.recentWindowInterval {
                self.newestWindowAt = nil
                Log.app.info("SwiftUI's window takes the command-line request")
                newestWindowModel.openFromCommandLine(directory: request.workingDirectory, files: request.files)
                continue
            }

            pendingCommandLineRequest = request
            scheduleCommandLineWindow()
        }
    }

    /// Open a window for a parked request unless one appears on its own
    /// first. SwiftUI's window registers within a frame or two of the URL
    /// event; the delay only covers a delivery that skips it (e.g. a request
    /// from a launcher whose event the system routes differently).
    private func scheduleCommandLineWindow() {
        commandLineWindowTask?.cancel()
        guard pendingCommandLineRequest != nil, openEditorWindow != nil else { return }
        commandLineWindowTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.commandLineWindowDelay)
            guard !Task.isCancelled, let self, self.pendingCommandLineRequest != nil else { return }
            Log.app.notice("No window appeared for the command-line request; opening one")
            self.openEditorWindow?()
        }
    }

    private var isAdoptingLaunchRequest: Bool {
        if isLaunching { return true }
        guard let didFinishLaunchingAt else { return false }
        return Date().timeIntervalSince(didFinishLaunchingAt) < Self.launchRequestWindow
    }

    /// The tab bar's + button and the system New Tab action both land here.
    @objc func newWindowForTab(_ sender: Any?) {
        requestNewTab(from: NSApp.keyWindow)
    }

    /// The red close button's action for editor windows: confirm first, then
    /// close — quitting the whole app when this was the last editor window,
    /// matching a clean `:q` exit and ⌘W on the last window.
    @objc func confirmCloseEditorWindow(_ sender: Any?) {
        let window = (sender as? NSButton)?.window
            ?? (sender as? NSWindow)
            ?? NSApp.keyWindow
        guard let window else { return }
        guard QuitConfirmation.present() else { return }
        let hasOtherWindows = AppModel.live.count > 1
            || (window.tabGroup?.windows.count ?? 0) > 1
        if !hasOtherWindows {
            NSApp.terminate(nil)
        } else {
            // `performClose(_:)` simulates a click on the close button, which
            // re-enters this action and shows the confirmation again; close
            // the tab window directly instead.
            window.close()
        }
    }

    /// Open a new editor window joined as a tab to `host`'s tab group, with
    /// `file` opened in it once its session is ready. A host that is not an
    /// editor window (e.g. Settings) yields a standalone window.
    func requestNewTab(from host: NSWindow?, file: URL? = nil) {
        guard let openEditorWindow else {
            Log.app.notice("New tab requested before any editor window existed; ignored")
            return
        }
        pendingTabHost = host?.tabbingIdentifier == Self.editorTabbingIdentifier ? host : nil
        pendingTabFile = file
        // The new session reports its colorscheme only after the first flush;
        // seed the next model with the host's mode and background so the tab
        // appears in the host's exact look and the real report does not snap.
        if let pendingTabHost,
           let hostModel = AppModel.live.first(where: { $0.hostWindow === pendingTabHost }) {
            AppModel.pendingThemeSeed = hostModel.themeIsDark
            AppModel.pendingBackgroundSeed = hostModel.terminalColors.background
        } else {
            AppModel.pendingThemeSeed = nil
            AppModel.pendingBackgroundSeed = nil
        }
        openEditorWindow()
    }

    /// Called from `AppModel.attach(to:)` as a new editor window's content is
    /// installed: enable tabbing, consume any pending tab placement, and hand
    /// over a pending file. Safe to call for plain ⌘N windows (no pending tab).
    /// A tab joins its host's group here — the seeded window already paints
    /// the host's theme, so AppKit's own tab-add transition is the whole
    /// animation. Deferring the join in a *visible* standalone window would
    /// expose chrome (no tab bar) and content geometry that disagree with the
    /// group's; the join is only deferred across the invisible appearance
    /// gap, never while the window can be seen.
    func registerEditorWindow(_ window: NSWindow, model: AppModel) {
        // `viewDidMoveToWindow` can run again for a window that is already
        // set up; only the first registration may take a request, adopt the
        // launch slot, or count as the newest window.
        let isNewWindow = !registeredWindows.contains(window)
        if isNewWindow {
            registeredWindows.add(window)
            newestWindowModel = model
            newestWindowAt = Date()
            // The launch window adopts a launch-time request (see
            // `pumpCommandLineRequests`); later windows never do.
            if launchWindowModel == nil, !launchWindowTookRequest {
                launchWindowModel = model
            }
        }
        // The red close button goes through the same confirmation a typed
        // `:q` shows before tearing the window (and its embedded nvim) down.
        // `performClose(_:)` runs this action too (it simulates a click on
        // the button), so the close commands use `close()` for tab windows
        // to avoid re-entering the confirmation.
        if let closeButton = window.standardWindowButton(.closeButton) {
            closeButton.target = self
            closeButton.action = #selector(confirmCloseEditorWindow(_:))
        }
        let host = pendingTabHost
        let file = pendingTabFile
        pendingTabHost = nil
        pendingTabFile = nil
        if let host, host !== window {
            // Give the window a unique identifier while it waits (invisible)
            // for its seeded appearance: a unique identifier disables the
            // system's automatic tabbing, so it cannot slip into the host's
            // group as the selected (transparent) tab mid-wait. The explicit
            // join below installs the shared editor identifier.
            window.tabbingIdentifier = "com.mzevo.iNeovim.pending.\(UUID().uuidString)"
            // Match the host's frame while the window is still invisible so
            // the group cannot adopt the new window's cascaded position.
            window.setFrame(host.frame, display: false)
            joinTabWhenThemed(window, host: host, model: model)
        } else {
            window.tabbingIdentifier = Self.editorTabbingIdentifier
        }
        if let file {
            model.open([file])
        }
        if isNewWindow, let request = pendingCommandLineRequest {
            pendingCommandLineRequest = nil
            commandLineWindowTask?.cancel()
            newestWindowAt = nil
            if launchWindowModel === model {
                launchWindowTookRequest = true
            }
            model.openFromCommandLine(directory: request.workingDirectory, files: request.files)
            // Ask for the next window outside this window's layout pass.
            Task { @MainActor in self.pumpCommandLineRequests() }
        }
    }

    /// Join `window` into `host`'s group and reveal it once the seeded
    /// `preferredColorScheme` has actually reached the window. The hosting
    /// WindowGroup installs that scheme a couple of frames after the window
    /// is created; revealing earlier showed those system-appearance frames as
    /// a white flash on a dark tab. The window stays invisible here, so the
    /// host tab remains on screen until the new tab appears already themed.
    private func joinTabWhenThemed(_ window: NSWindow, host: NSWindow, model: AppModel) {
        let desired: NSAppearance.Name? = model.themeIsDark.map { $0 ? .darkAqua : .aqua }
        Task { @MainActor in
            if let desired {
                // Bounded wait: if the scheme never lands, reveal anyway rather
                // than leaving the window hidden.
                for _ in 0..<12 {
                    let current = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
                    if current == desired { break }
                    try? await Task.sleep(for: .milliseconds(8))
                }
            }
            window.tabbingIdentifier = Self.editorTabbingIdentifier
            model.revealWindowImmediately()
            // The system may already have tabbed the window itself (tabbing
            // preference "Always"); join only when it is still standalone.
            if window.tabGroup == nil || window.tabGroup !== host.tabGroup {
                host.addTabbedWindow(window, ordered: .above)
            }
            window.makeKeyAndOrderFront(nil)
        }
    }
}
