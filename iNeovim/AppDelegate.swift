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

    private var keyDownMonitor: Any?

    override init() {
        super.init()
        Self.shared = self
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
            guard modifiers == .option,
                  let key = event.charactersIgnoringModifiers?.lowercased() else { return event }
            switch key {
            case "t":
                return MainActor.assumeIsolated(Self.claimTerminalPaneChord) ? nil : event
            case "p":
                return MainActor.assumeIsolated(Self.claimProblemsPanelChord) ? nil : event
            case "1":
                return MainActor.assumeIsolated(Self.claimEditorFocusChord) ? nil : event
            case "2":
                return MainActor.assumeIsolated(Self.claimTerminalPaneFocusChord) ? nil : event
            default:
                return event
            }
        }
        Log.app.info("Application did finish launching")
    }

    /// ⌥T toggles the terminal pane like the menu's ⌃`, from any focused view
    /// (a local monitor sees the keydown before the responder chain). Returns
    /// whether the chord was claimed; a modal session owning the app, or
    /// "Option as Meta" dedicating Option to nvim (`<M-t>`), leaves it alone.
    private static func claimTerminalPaneChord() -> Bool {
        guard NSApp.modalWindow == nil, !AppSettings.shared.optionAsMeta else { return false }
        AppModel.active?.toggleTerminalPane()
        return true
    }

    /// ⌥P toggles the problems panel like its menu item, which is display-only:
    /// SwiftUI registers the ⌥P equivalent but never fires it (bare AppKit
    /// items do — verified against a real HID keypress), so the chord is
    /// claimed here like ⌥T. Same guards: a modal session, or "Option as
    /// Meta" dedicating Option to nvim (`<M-p>`), leaves it alone.
    private static func claimProblemsPanelChord() -> Bool {
        guard NSApp.modalWindow == nil, !AppSettings.shared.optionAsMeta else { return false }
        AppModel.active?.toggleProblemsPanel()
        return true
    }

    /// ⌥1 puts keyboard focus in the editor. Same guards as the other
    /// Option-only chords.
    private static func claimEditorFocusChord() -> Bool {
        guard NSApp.modalWindow == nil, !AppSettings.shared.optionAsMeta else { return false }
        AppModel.active?.focusEditor()
        return true
    }

    /// ⌥2 puts keyboard focus in the terminal pane, opening it when it is
    /// hidden. Same guards as the other Option-only chords.
    private static func claimTerminalPaneFocusChord() -> Bool {
        guard NSApp.modalWindow == nil, !AppSettings.shared.optionAsMeta else { return false }
        AppModel.active?.focusTerminalPane()
        return true
    }

    /// "Open With", Dock-icon drops, and `open -a` all arrive here; the model
    /// routes them to the active session or stages them until one is ready.
    func application(_ application: NSApplication, open urls: [URL]) {
        Log.app.info("Open request for \(urls.count, privacy: .public) file(s)")
        AppModel.openFromSystem(urls)
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
        if AppModel.live.count <= 1 {
            NSApp.terminate(nil)
        } else {
            window.performClose(nil)
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
        // The red close button goes through the same confirmation a typed
        // `:q` shows before tearing the window (and its embedded nvim) down.
        // `performClose(_:)` (⌘W) does not use the button's action, so only
        // the traffic-light click is intercepted here.
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
