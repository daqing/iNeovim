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
        Log.app.info("Application did finish launching")
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
        // seed the next model with the host's mode so the tab appears in the
        // host's theme and the real report crossfades instead of snapping.
        AppModel.pendingThemeSeed = pendingTabHost != nil
            ? AppModel.live.first { $0.hostWindow === pendingTabHost }?.themeIsDark
            : nil
        openEditorWindow()
    }

    /// Called from `AppModel.attach(to:)` as a new editor window's content is
    /// installed: enable tabbing, consume any pending tab placement, and hand
    /// over a pending file. Safe to call for plain ⌘N windows (no pending tab).
    /// The tab-group join itself is deferred to the reveal
    /// (`AppModel.revealWindow`): joining here would order this requesting
    /// tab off the screen while the new session is still starting.
    func registerEditorWindow(_ window: NSWindow, model: AppModel) {
        window.tabbingIdentifier = Self.editorTabbingIdentifier
        let host = pendingTabHost
        let file = pendingTabFile
        pendingTabHost = nil
        pendingTabFile = nil
        model.deferTabJoin(to: host !== window ? host : nil)
        if let file {
            model.open([file])
        }
    }
}
