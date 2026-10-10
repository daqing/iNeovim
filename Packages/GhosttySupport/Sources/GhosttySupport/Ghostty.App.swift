import AppKit
import Combine
import GhosttyKit

// A minimal embedding-oriented version of Ghostty.App from ghostty
// 1.3.2-main+246f702 (macos/Sources/Ghostty/Ghostty.App.swift). The upstream
// class carries the Ghostty.app window/tab/split model; this one keeps only
// what an embedded surface needs: the runtime callbacks (wakeup/tick,
// clipboard, close-surface) and the surface-scoped action dispatch (title,
// pwd, cell size, mouse, bell, config/color changes). Window-management
// actions (new window/tab/split, fullscreen, quit, ...) are answered with
// "not performed" so libghostty knows this host does not provide them.

extension Ghostty {
    public class App: ObservableObject {
        enum Readiness: String {
            case loading, error, ready
        }

        /// The readiness value of the state.
        @Published var readiness: Readiness = .loading

        /// The global app configuration.
        @Published private(set) var config: Config

        /// Preferred config file path (nil loads Ghostty's own defaults).
        private var configPath: String?

        /// The ghostty app instance. One per process hosts every surface.
        @Published public var app: ghostty_app_t? {
            didSet {
                guard let old = oldValue else { return }
                ghostty_app_free(old)
            }
        }

        /// True once `ghostty_init` ran. It must precede every other
        /// libghostty call — including `ghostty_config_new` — and happens
        /// in upstream's main() before NSApplicationMain; an embedding has
        /// to do it on first App creation instead.
        private static var initialized = false

        public init(configPath: String? = nil) {
            self.configPath = configPath
            self.app = nil
            if !App.initialized,
               ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS {
                App.initialized = true
            }
            guard App.initialized else {
                Ghostty.logger.critical("ghostty_init failed")
                self.config = Config(config: nil)
                readiness = .error
                return
            }
            self.config = Config(at: configPath)
            if self.config.config == nil {
                readiness = .error
                return
            }

            var runtime_cfg = ghostty_runtime_config_s(
                userdata: Unmanaged.passUnretained(self).toOpaque(),
                supports_selection_clipboard: true,
                wakeup_cb: { userdata in App.wakeup(userdata) },
                action_cb: { app, target, action in App.action(app!, target: target, action: action) },
                read_clipboard_cb: { userdata, loc, state, mimes, mimesLen, list in
                    App.readClipboard(
                        userdata,
                        location: loc,
                        state: state,
                        mimes: mimes,
                        mimesLen: mimesLen,
                        list: list)
                },
                confirm_read_clipboard_cb: { userdata, confirm, state, request in
                    App.confirmReadClipboard(
                        userdata,
                        confirm: confirm,
                        state: state,
                        request: request)
                },
                write_clipboard_cb: { userdata, loc, content, len, confirm in
                    App.writeClipboard(userdata, location: loc, content: content, len: len, confirm: confirm)
                },
                close_surface_cb: { userdata, processAlive in
                    App.closeSurface(userdata, processAlive: processAlive)
                }
            )

            guard let app = ghostty_app_new(&runtime_cfg, config.config) else {
                Ghostty.logger.critical("ghostty_app_new failed")
                readiness = .error
                return
            }
            self.app = app

            ghostty_app_set_focus(app, NSApp.isActive)

            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(keyboardSelectionDidChange(notification:)),
                name: NSTextInputContext.keyboardSelectionDidChangeNotification,
                object: nil)
            center.addObserver(
                self,
                selector: #selector(applicationDidBecomeActive(notification:)),
                name: NSApplication.didBecomeActiveNotification,
                object: nil)
            center.addObserver(
                self,
                selector: #selector(applicationDidResignActive(notification:)),
                name: NSApplication.didResignActiveNotification,
                object: nil)

            self.readiness = .ready
        }

        deinit {
            // This will force the didSet callbacks to run which free.
            self.app = nil
            NotificationCenter.default.removeObserver(self)
        }

        // MARK: App Operations

        func appTick() {
            guard let app = self.app else { return }
            ghostty_app_tick(app)
        }

        /// Reload the configuration from the configured path.
        func reloadConfig() {
            guard let app = self.app else { return }
            let newConfig = Config(at: configPath)
            guard newConfig.loaded else {
                Ghostty.logger.warning("failed to reload configuration")
                return
            }
            ghostty_app_update_config(app, newConfig.config!)
            self.config = newConfig
        }

        /// Request that the given surface is closed. This will trigger the full normal surface close event
        /// cycle which will call our close surface callback.
        public func requestClose(surface: ghostty_surface_t) {
            ghostty_surface_request_close(surface)
        }

        // MARK: Notifications

        // Called when the selected keyboard changes. We have to notify Ghostty so that
        // it can reload the keyboard mapping for input.
        @objc private func keyboardSelectionDidChange(notification: NSNotification) {
            guard let app = self.app else { return }
            ghostty_app_keyboard_changed(app)
        }

        @objc private func applicationDidBecomeActive(notification: NSNotification) {
            guard let app = self.app else { return }
            ghostty_app_set_focus(app, true)
        }

        @objc private func applicationDidResignActive(notification: NSNotification) {
            guard let app = self.app else { return }
            ghostty_app_set_focus(app, false)
        }

        // MARK: Ghostty Callbacks

        static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
            let surfaceView = self.surfaceUserdata(from: userdata)
            NotificationCenter.default.post(name: Ghostty.Notification.ghosttyCloseSurface, object: surfaceView, userInfo: [
                "process_alive": processAlive,
            ])
        }

        static func readClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            location: ghostty_clipboard_e,
            state: UnsafeMutableRawPointer?,
            mimes: UnsafePointer<UnsafePointer<CChar>?>?,
            mimesLen: Int,
            list: Bool
        ) -> ghostty_clipboard_read_result_e {
            let surfaceView = self.surfaceUserdata(from: userdata)
            guard let surface = surfaceView.surface else {
                return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
            }

            // Get our pasteboard
            guard let pasteboard = NSPasteboard.ghostty(location) else {
                return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
            }

            // Gather the representation for each requested MIME type that
            // the pasteboard can serve. We only ever read the requested
            // representations so unrelated (potentially large) clipboard
            // contents are never loaded.
            var contents: [Ghostty.ClipboardContent] = []
            var seen = Set<String>()
            if let mimes {
                for i in 0..<mimesLen {
                    guard let ptr = mimes[i] else { continue }
                    let mime = String(cString: ptr)
                    guard !seen.contains(mime) else { continue }
                    seen.insert(mime)
                    guard let data = pasteboard.ghosttyData(forMime: mime) else { continue }
                    contents.append(.init(mime: mime, data: data))
                }
            }

            // The listing of available types, only gathered when requested.
            let available: [String] = list ? pasteboard.ghosttyAvailableMimes() : []

            // With nothing to serve and no listing requested there is
            // nothing to complete the read with.
            if contents.isEmpty && !list {
                return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
            }

            completeClipboardRequest(
                surface,
                contents: contents,
                available: available,
                state: state)
            return GHOSTTY_CLIPBOARD_READ_STARTED
        }

        static func confirmReadClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
            state: UnsafeMutableRawPointer?,
            request: ghostty_clipboard_request_e
        ) {
            let surfaceView = self.surfaceUserdata(from: userdata)
            guard let surface = surfaceView.surface else { return }
            guard let confirm,
                  let kind = Ghostty.ClipboardRequest.from(request: request) else {
                ghostty_surface_deny_clipboard_request(surface, state)
                return
            }
            let c = confirm.pointee

            // Copy the borrowed C representations: the confirmation is
            // asynchronous and completes with exactly what the user
            // approved, so the clipboard is never re-read.
            var reps: [Ghostty.ClipboardContent] = []
            if let contents = c.contents {
                for i in 0..<c.contents_len {
                    let content = contents[i]
                    let data: Data = if content.len > 0 {
                        Data(bytes: content.data, count: content.len)
                    } else {
                        Data()
                    }
                    reps.append(.init(mime: String(cString: content.mime), data: data))
                }
            }
            var avail: [String] = []
            if let available = c.available {
                for i in 0..<c.available_len {
                    guard let ptr = available[i] else { continue }
                    avail.append(String(cString: ptr))
                }
            }

            // The dialog can only display text: show the text
            // representation when there is one and summarize the rest.
            let display = reps.first(where: { $0.mime == "text/plain" })
                .flatMap { String(data: $0.data, encoding: .utf8) }
                ?? reps.map { "\($0.mime) (\($0.data.count) bytes)" }.joined(separator: "\n")

            // Decode an image representation so the dialog can preview
            // exactly what would be disclosed rather than a byte count.
            let previewImage: NSImage? = reps.lazy
                .filter { $0.mime.hasPrefix("image/") }
                .compactMap { NSImage(data: $0.data) }
                .first

            // libghostty reaches this callback only when the request attempted
            // by readClipboard requires confirmation. Reads allowed by policy
            // complete immediately and never become pending Swift state.
            let request = Ghostty.ClipboardConfirmationRequest(
                surface: surfaceView,
                contents: display,
                kind: kind,
                canRemember: c.can_remember,
                previewImage: previewImage
            ) { surfaceView, confirmed, remember in
                guard let surface = surfaceView.surface else { return }
                if confirmed {
                    completeClipboardRequest(
                        surface,
                        contents: reps,
                        available: avail,
                        state: state,
                        confirmed: true,
                        remember: remember)
                } else {
                    ghostty_surface_deny_clipboard_request(surface, state)
                }
            }
            surfaceView.pendingClipboardConfirmation = request
        }

        private static func completeClipboardRequest(
            _ surface: ghostty_surface_t,
            contents: [Ghostty.ClipboardContent],
            available: [String],
            state: UnsafeMutableRawPointer?,
            confirmed: Bool = false,
            remember: Bool = false
        ) {
            // Copy everything into C memory for the duration of the call.
            var cStrings: [UnsafeMutablePointer<CChar>] = []
            var cDatas: [UnsafeMutableRawPointer] = []
            defer {
                cStrings.forEach { free($0) }
                cDatas.forEach { $0.deallocate() }
            }

            var cContents: [ghostty_clipboard_content_s] = []
            for entry in contents {
                guard let mime = strdup(entry.mime) else { continue }
                cStrings.append(mime)
                let buf = UnsafeMutableRawPointer.allocate(
                    byteCount: max(entry.data.count, 1),
                    alignment: 1)
                cDatas.append(buf)
                entry.data.withUnsafeBytes { src in
                    if let base = src.baseAddress {
                        buf.copyMemory(from: base, byteCount: src.count)
                    }
                }
                cContents.append(ghostty_clipboard_content_s(
                    mime: mime,
                    data: buf.assumingMemoryBound(to: CChar.self),
                    len: entry.data.count))
            }

            var cAvailable: [UnsafePointer<CChar>?] = []
            for mime in available {
                guard let str = strdup(mime) else { continue }
                cStrings.append(str)
                cAvailable.append(UnsafePointer(str))
            }

            cContents.withUnsafeBufferPointer { contentsBuf in
                cAvailable.withUnsafeBufferPointer { availableBuf in
                    var complete = ghostty_clipboard_complete_s(
                        contents: contentsBuf.baseAddress,
                        contents_len: contentsBuf.count,
                        available: availableBuf.baseAddress,
                        available_len: availableBuf.count,
                        confirmed: confirmed,
                        remember: remember)
                    ghostty_surface_complete_clipboard_request(surface, &complete, state)
                }
            }
        }

        static func writeClipboard(
            _ userdata: UnsafeMutableRawPointer?,
            location: ghostty_clipboard_e,
            content: UnsafePointer<ghostty_clipboard_content_s>?,
            len: Int,
            confirm: Bool
        ) {
            let surfaceView = self.surfaceUserdata(from: userdata)
            guard let pasteboard = NSPasteboard.ghostty(location) else { return }
            guard let content = content, len > 0 else { return }

            // Convert the C array to Swift array
            let contentArray = (0..<len).compactMap { i in
                Ghostty.ClipboardContent.from(content: content[i])
            }
            guard !contentArray.isEmpty else { return }

            // Assert there is only one text/plain entry. For security reasons we need
            // to guarantee this for now since our confirmation dialog only shows one.
            assert(contentArray.filter({ $0.mime == "text/plain" }).count <= 1,
                   "clipboard contents should have at most one text/plain entry")

            if !confirm {
                // Apply writes allowed by policy immediately. Only writes that
                // require confirmation continue to the pending request below.
                let types = contentArray.compactMap { item in
                    NSPasteboard.PasteboardType(mimeType: item.mime)
                }
                pasteboard.declareTypes(types, owner: nil)

                // Set data for each type
                for item in contentArray {
                    guard let type = NSPasteboard.PasteboardType(mimeType: item.mime) else { continue }
                    pasteboard.setData(item.data, forType: type)
                }
                return
            }

            // For confirmation, use the text/plain content if it exists
            guard let textPlainContent = contentArray.first(where: { $0.mime == "text/plain" }),
                  let textPlainString = textPlainContent.string else {
                return
            }

            let request = Ghostty.ClipboardConfirmationRequest(
                surface: surfaceView,
                contents: textPlainString,
                kind: .osc_52_write
            ) { _, confirmed, _ in
                guard confirmed else { return }
                pasteboard.declareTypes([.string], owner: nil)
                pasteboard.setString(textPlainString, forType: .string)
            }
            surfaceView.pendingClipboardConfirmation = request
        }

        static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
            let state = Unmanaged<App>.fromOpaque(userdata!).takeUnretainedValue()

            // Wakeup can be called from any thread so we schedule the app tick
            // from the main thread.
            DispatchQueue.main.async { state.appTick() }
        }

        /// Returns the surface view from the userdata.
        static private func surfaceUserdata(from userdata: UnsafeMutableRawPointer?) -> SurfaceView {
            return Unmanaged<SurfaceView>.fromOpaque(userdata!).takeUnretainedValue()
        }

        static private func surfaceView(from surface: ghostty_surface_t) -> SurfaceView? {
            guard let surface_ud = ghostty_surface_userdata(surface) else { return nil }
            return Unmanaged<SurfaceView>.fromOpaque(surface_ud).takeUnretainedValue()
        }

        // MARK: Actions

        static func action(_ app: ghostty_app_t, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
            // Make sure it is a target we understand so all our action handlers can assert
            switch target.tag {
            case GHOSTTY_TARGET_APP, GHOSTTY_TARGET_SURFACE:
                break

            default:
                Ghostty.logger.warning("unknown action target=\(target.tag.rawValue)")
                return false
            }

            switch action.tag {
            case GHOSTTY_ACTION_SET_TITLE:
                guard let surface = target.target.surface,
                      let surfaceView = self.surfaceView(from: surface),
                      let title = String(cString: action.action.set_title.title!, encoding: .utf8)
                else { return false }
                surfaceView.setTitle(title)
                return true

            case GHOSTTY_ACTION_PWD:
                guard let surface = target.target.surface,
                      let surfaceView = self.surfaceView(from: surface),
                      let pwd = String(cString: action.action.pwd.pwd!, encoding: .utf8)
                else { return false }
                surfaceView.pwd = pwd
                return true

            case GHOSTTY_ACTION_CELL_SIZE:
                guard let surface = target.target.surface,
                      let surfaceView = self.surfaceView(from: surface)
                else { return false }
                let v = action.action.cell_size
                let backingSize = NSSize(width: Double(v.width), height: Double(v.height))
                DispatchQueue.main.async { [weak surfaceView] in
                    guard let surfaceView else { return }
                    surfaceView.cellSize = surfaceView.convertFromBacking(backingSize)
                }
                return true

            case GHOSTTY_ACTION_RENDERER_HEALTH:
                guard let surface = target.target.surface,
                      let surfaceView = self.surfaceView(from: surface)
                else { return false }
                NotificationCenter.default.post(
                    name: Ghostty.Notification.didUpdateRendererHealth,
                    object: surfaceView,
                    userInfo: ["health": action.action.renderer_health]
                )
                return true

            case GHOSTTY_ACTION_MOUSE_SHAPE:
                guard let surface = target.target.surface,
                      let surfaceView = self.surfaceView(from: surface)
                else { return false }
                surfaceView.setCursorShape(action.action.mouse_shape)
                return true

            case GHOSTTY_ACTION_MOUSE_VISIBILITY:
                guard let surface = target.target.surface,
                      let surfaceView = self.surfaceView(from: surface)
                else { return false }
                switch action.action.mouse_visibility {
                case GHOSTTY_MOUSE_VISIBLE:
                    surfaceView.setCursorVisibility(true)
                case GHOSTTY_MOUSE_HIDDEN:
                    surfaceView.setCursorVisibility(false)
                default:
                    break
                }
                return true

            case GHOSTTY_ACTION_MOUSE_OVER_LINK:
                guard let surface = target.target.surface,
                      let surfaceView = self.surfaceView(from: surface)
                else { return false }
                let v = action.action.mouse_over_link
                guard v.len > 0 else {
                    surfaceView.hoverUrl = nil
                    return true
                }
                let buffer = Data(bytes: v.url!, count: v.len)
                surfaceView.hoverUrl = String(data: buffer, encoding: .utf8)
                return true

            case GHOSTTY_ACTION_RING_BELL:
                guard let surface = target.target.surface,
                      let surfaceView = self.surfaceView(from: surface)
                else { return false }
                NotificationCenter.default.post(
                    name: .ghosttyBellDidRing,
                    object: surfaceView
                )
                return true

            case GHOSTTY_ACTION_KEY_TABLE:
                guard let surface = target.target.surface,
                      let surfaceView = self.surfaceView(from: surface),
                      let keyTable = Ghostty.Action.KeyTable(c: action.action.key_table)
                else { return false }
                NotificationCenter.default.post(
                    name: Ghostty.Notification.didChangeKeyTable,
                    object: surfaceView,
                    userInfo: [Ghostty.Notification.KeyTableKey: keyTable]
                )
                return true

            case GHOSTTY_ACTION_CONFIG_CHANGE:
                let config = Config(clone: action.action.config_change.config)
                switch target.tag {
                case GHOSTTY_TARGET_APP:
                    NotificationCenter.default.post(
                        name: .ghosttyConfigDidChange,
                        object: nil,
                        userInfo: [
                            Foundation.Notification.Name.GhosttyConfigChangeKey: config,
                        ]
                    )
                    guard let app_ud = ghostty_app_userdata(app) else { return true }
                    let ghostty = Unmanaged<App>.fromOpaque(app_ud).takeUnretainedValue()
                    ghostty.config = config
                case GHOSTTY_TARGET_SURFACE:
                    guard let surface = target.target.surface,
                          let surfaceView = self.surfaceView(from: surface)
                    else { return false }
                    NotificationCenter.default.post(
                        name: .ghosttyConfigDidChange,
                        object: surfaceView,
                        userInfo: [
                            Foundation.Notification.Name.GhosttyConfigChangeKey: config,
                        ]
                    )
                default:
                    break
                }
                return true

            case GHOSTTY_ACTION_COLOR_CHANGE:
                guard let surface = target.target.surface,
                      let surfaceView = self.surfaceView(from: surface)
                else { return false }
                NotificationCenter.default.post(
                    name: .ghosttyColorDidChange,
                    object: surfaceView,
                    userInfo: [
                        Foundation.Notification.Name.GhosttyColorChangeKey: Action.ColorChange(c: action.action.color_change)
                    ]
                )
                return true

            case GHOSTTY_ACTION_OPEN_URL:
                let v = action.action.open_url
                let url: URL
                if let candidate = String(cString: v.url!, encoding: .utf8).flatMap(URL.init(string:)),
                   candidate.scheme != nil {
                    url = candidate
                } else {
                    let path = String(cString: v.url!, encoding: .utf8) ?? ""
                    url = URL(fileURLWithPath: NSString(string: path).standardizingPath)
                }
                NSWorkspace.shared.open(url)
                return true

            default:
                // Window-management and app-shell actions (new window/tab,
                // splits, fullscreen, quit, notifications, ...) are not
                // provided by this embedding.
                Ghostty.logger.debug("unhandled action action=\(action.tag.rawValue)")
                return false
            }
        }
    }
}
