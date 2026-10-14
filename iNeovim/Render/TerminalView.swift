import AppKit
import CoreText
import os

/// The terminal surface: hosts the scrollable grid content layer, paints
/// the background behind it, and routes keyboard, mouse, and scroll input.
final class TerminalView: NSView {
    /// Breathing room around the grid on every side. The grid is sized from
    /// the inset area only, so the last line (statusline/cmdline) can never
    /// touch the window edges.
    static let contentInset: CGFloat = 6

    /// Extra vertical space between the statusline row and the cmdline row
    /// below it: the last grid row is drawn this far below its uniform slot,
    /// so the two rows never touch. The last grid row is nvim's message /
    /// cmdline area; with `laststatus` >= 2 the row above it is the
    /// statusline.
    static let cmdlineGap: CGFloat = 5

    /// Grid rows nvim never scrolls: the statusline row and the cmdline row
    /// below it. They are drawn by the frozen footer layer, which the scroll
    /// lead never translates — nvim does not scroll them either.
    static let frozenFooterRows = 2

    /// View size minus the content inset on both sides and the cmdline gap:
    /// the area the grid (rows plus gap) may occupy. Grid cell counts must
    /// always be derived from this, never from the raw bounds, or the grid
    /// fills the view edge to edge.
    static func gridAreaSize(_ size: CGSize) -> CGSize {
        let inset = contentInset * 2
        return CGSize(
            width: max(0, size.width - inset),
            height: max(0, size.height - inset - cmdlineGap)
        )
    }

    /// Y of a grid row's top edge in grid space (view space minus the
    /// content inset), with the cmdline row shifted down by `cmdlineGap`.
    static func gridRowY(_ row: Int, gridHeight: Int, cellHeight: CGFloat) -> CGFloat {
        let y = CGFloat(row) * cellHeight
        return row == gridHeight - 1 ? y + cmdlineGap : y
    }

    /// Inverse of `gridRowY` for hit-testing: grid-space y to a row index,
    /// clamped to the grid. The gap band itself belongs to the statusline
    /// row; the cmdline row starts at its shifted top edge.
    static func gridRow(atY y: CGFloat, gridHeight: Int, cellHeight: CGFloat) -> Int {
        let last = gridHeight - 1
        if last <= 0 { return max(0, last) }
        if y >= CGFloat(last) * cellHeight + cmdlineGap { return last }
        return min(max(Int(y / cellHeight), 0), last - 1)
    }

    /// Whether the nvim theme reads as dark: nvim reports its default
    /// background at attach and re-reports it on every `:colorscheme`
    /// change. nil (or nvim's -1 "unset" sentinel) means unknown, and the
    /// window chrome then follows the system appearance.
    static func hasDarkBackground(_ background: Int?) -> Bool? {
        guard let background, let color = NSColor(packedRGB: background)?.usingColorSpace(.sRGB) else {
            return nil
        }
        let luma = 0.299 * color.redComponent + 0.587 * color.greenComponent + 0.114 * color.blueComponent
        return luma < 0.5
    }

    /// nvim's built-in default colorscheme `Normal` pair per `background`
    /// mode (probed on nvim 0.12.5); the two modes are exact inverses. The
    /// statusline row is drawn in the opposite mode's pair so the bar
    /// contrasts with the editor background — themes pick statusline
    /// backgrounds nearly identical to it (monokai pro dark: #2E323C on
    /// #26292C).
    static let lightDefaultBackground = 0xE0E2EA
    static let lightDefaultForeground = 0x14161B
    static let darkDefaultBackground = 0x14161B
    static let darkDefaultForeground = 0xE0E2EA

    /// Translucency of the statusline bar: it composites over the editor
    /// background, softening the inverted default colors' contrast (a
    /// full-strength bar glares at night).
    static let statuslineBarOpacity: Float = 0.5

    /// Duration of the fade that softens a light↔dark theme flip seen in
    /// place (`:colorscheme`): the previous rendering fades out over the
    /// redrawn content instead of the whole grid popping to the new colors.
    static let themeCrossfadeDuration: TimeInterval = 0.25

    /// The statusline row's bar/text colors: the opposite theme mode's
    /// default pair; an unknown theme (nil) follows the window appearance.
    static func statuslineColors(themeIsDark: Bool?) -> (background: NSColor, foreground: NSColor) {
        let light = (
            background: NSColor(packedRGB: lightDefaultBackground) ?? .textBackgroundColor,
            foreground: NSColor(packedRGB: lightDefaultForeground) ?? .textColor
        )
        let dark = (
            background: NSColor(packedRGB: darkDefaultBackground) ?? .textBackgroundColor,
            foreground: NSColor(packedRGB: darkDefaultForeground) ?? .textColor
        )
        switch themeIsDark {
        case .some(true): return light
        case .some(false): return dark
        case .none:
            let isDark = { (appearance: NSAppearance) in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            }
            return (
                background: NSColor(name: nil) { isDark($0) ? light.background : dark.background },
                foreground: NSColor(name: nil) { isDark($0) ? light.foreground : dark.foreground }
            )
        }
    }

    let model: AppModel
    private(set) var metrics: FontMetrics
    private var snapshot: ScreenSnapshot?
    /// Overlay fading the previous theme's rendering out during a light↔dark
    /// flip seen in place (see `crossfadeThemeTransition`).
    private var themeCrossfadeView: NSView?
    /// The scrolling region: the grid rows above the frozen footer, drawn in
    /// a layer the scroll lead translates inside `scrollClipLayer`.
    private let contentLayer: GridContentLayer
    /// The grid rows nvim never scrolls — the statusline row and the
    /// cmdline/message row below it — in a layer of their own. Only the
    /// scrolling region takes the scroll lead, so the statusline text stays
    /// on its bar instead of sliding off it mid-gesture.
    private let footerLayer: GridContentLayer
    /// Clips the scrolling region to the rows above the frozen footer: the
    /// lead translates that layer, and without this clip a downward lead
    /// would draw the last text rows over the statusline bar.
    private let scrollClipLayer = CALayer()
    /// Backdrop painting the statusline row with the opposite theme mode's
    /// default background, stretched to the window edges. The footer layer
    /// keeps that row's cells transparent, so the backdrop shows across the
    /// whole row; the side bands are the part the grid itself can't reach.
    private let statuslineLayer = CALayer()
    /// Native ext_popupmenu completion panel, placed above the content layer
    /// at the anchor nvim reports.
    private let completionPanel = CompletionPanelView()
    /// Native ⌘P file finder; presented centered over the editor and hidden
    /// again after a pick or cancel.
    private let openQuicklyPanel = OpenQuicklyPanel()
    /// Native popover listing the diagnostics on a gutter sign's line.
    private let diagnosticPopover = DiagnosticPopover()
    private let scrollAnimator = ScrollAnimator()
    private let cursorAnimator = CursorAnimator()
    private let resizeController: ResizeController
    private var keyHandler = KeyInputHandler()
    private let mouseHandler: MouseHandler
    private let scrollController: ScrollController
    let imeHandler = IMEHandler()
    private var sessionReady = false
    /// Grid rect of the link currently underlined for ⌘-hover, nil otherwise.
    private var hoveredLinkRect: CellRect?
    /// Whether the pointing-hand cursor is currently set by a link hover, so
    /// the cursor is only reset when it was ours to change.
    private var linkCursorActive = false
    private var hoverTrackingArea: NSTrackingArea?
    /// The view size for which a corrective resize was already attempted; a
    /// rejected request must not be repeated forever.
    private var reconciledViewSize: CGSize?
    var inputSettings = InputSettings() {
        didSet {
            keyHandler.passCmdKeys = inputSettings.passCmdKeysThrough
            keyHandler.optionAsMeta = inputSettings.optionAsMeta
        }
    }
    /// Whether a typed `:terminal` opens the native pane; from settings.
    var nativeTerminalPaneEnabled = true

    /// Both grid layers: the scrolling region and the frozen footer. They are
    /// fed the same snapshot so the split stays invisible; only the scrolling
    /// region is translated by the scroll lead.
    private var gridLayers: [GridContentLayer] { [contentLayer, footerLayer] }

    /// Apply user settings: font metrics, input switches, and animation
    /// toggles. Changing the font reflows the grid at the new cell size.
    func apply(settings: AppSettings) {
        let font = settings.resolvedFont()
        if metrics.font != font {
            applyMetrics(FontMetrics(font: font))
        }
        inputSettings = settings.inputSettings
        nativeTerminalPaneEnabled = settings.nativeTerminalPane
        let animations = settings.animationSettings
        scrollController.settings = animations
        scrollAnimator.settings = animations
        cursorAnimator.settings = animations
    }

    /// Notified when the embedded session becomes ready. The very first resize
    /// can be issued before `ui_attach` completes, in which case nvim rejects
    /// it and the grid would stay at its initial size; re-send the current view
    /// size once the session is up.
    func sessionDidChangeReady(_ ready: Bool) {
        defer { sessionReady = ready }
        guard ready, !sessionReady else { return }
        requestResize(to: bounds.size)
    }

    /// Send the view size to Neovim; a new size also re-arms the corrective
    /// resize below.
    private func requestResize(to size: CGSize) {
        reconciledViewSize = nil
        let area = Self.gridAreaSize(size)
        let cellCount = ResizeController.cellCount(for: area, cellSize: metrics.cellSize)
        // Record the size so `ui_attach` can use it instead of 80x24.
        model.noteGridSize(cols: cellCount.cols, rows: cellCount.rows)
        Task { await resizeController.viewDidResize(to: area) }
    }

    /// Neovim rejects a resize that arrives before `ui_attach`, which would
    /// leave the grid at the fallback attach size and visibly smaller than the
    /// window if the window is never resized again. Once a snapshot is applied,
    /// compare its grid with the size the view needs and re-request when they
    /// differ (at most once per view size, so a rejected request cannot spin).
    private func reconcileGridSize(with snapshot: ScreenSnapshot) {
        guard sessionReady, let grid = snapshot.grid, !grid.isEmpty else { return }
        let expected = ResizeController.cellCount(
            for: Self.gridAreaSize(bounds.size),
            cellSize: metrics.cellSize
        )
        guard grid.width != expected.cols || grid.height != expected.rows else { return }
        guard reconciledViewSize != bounds.size else { return }
        reconciledViewSize = bounds.size
        Task { await resizeController.viewDidResize(to: Self.gridAreaSize(bounds.size)) }
    }

    private func applyMetrics(_ newMetrics: FontMetrics) {
        metrics = newMetrics
        for gridLayer in gridLayers {
            gridLayer.updateMetrics(newMetrics)
            if let snapshot {
                gridLayer.update(snapshot: snapshot)
            }
            gridLayer.setNeedsDisplay()
        }
        updateFooterGeometry()
        updateStatuslineLayer()
        updateCompletionPanel()
        let size = bounds.size
        Task { [weak self] in
            guard let self else { return }
            await self.resizeController.setCellSize(newMetrics.cellSize)
            await self.resizeController.viewDidResize(to: Self.gridAreaSize(size))
        }
        reconciledViewSize = nil
    }

    init(
        model: AppModel,
        metrics: FontMetrics = FontMetrics(
            font: .monospacedSystemFont(ofSize: FontMetrics.defaultSize, weight: .regular)
        )
    ) {
        self.model = model
        self.metrics = metrics
        self.contentLayer = GridContentLayer(metrics: metrics)
        self.footerLayer = GridContentLayer(metrics: metrics)
        self.mouseHandler = MouseHandler(dispatcher: model.inputDispatcher)
        self.scrollController = ScrollController(dispatcher: model.inputDispatcher)
        self.resizeController = ResizeController(cellSize: metrics.cellSize, client: model.client)
        super.init(frame: NSRect(
            origin: .zero,
            size: CGSize(
                width: metrics.cellSize.width * 80 + Self.contentInset * 2,
                height: metrics.cellSize.height * 24 + Self.contentInset * 2 + Self.cmdlineGap
            )
        ))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.masksToBounds = true
        // Anchor the scrolling region's top-left to the inset origin, inside
        // the clip layer that bounds it to the rows above the frozen footer.
        // Without the anchor the layer is centered on its origin and clipped
        // out of view; the footer layer is placed by `updateFooterGeometry`
        // from the grid height.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.rowSlice = .head(excludingTrailing: Self.frozenFooterRows)
        footerLayer.rowSlice = .tail(count: Self.frozenFooterRows)
        contentLayer.anchorPoint = .zero
        contentLayer.position = .zero
        footerLayer.anchorPoint = .zero
        scrollClipLayer.masksToBounds = true
        CATransaction.commit()
        statuslineLayer.opacity = Self.statuslineBarOpacity
        layer?.addSublayer(statuslineLayer)
        layer?.addSublayer(scrollClipLayer)
        scrollClipLayer.addSublayer(contentLayer)
        layer?.addSublayer(footerLayer)
        completionPanel.onSelect = { [weak self] index in
            guard let self else { return }
            Task { try? await self.model.client.selectPopupmenuItem(index) }
        }
        addSubview(completionPanel)
        completionPanel.isHidden = true
        addSubview(openQuicklyPanel)
        openQuicklyPanel.isHidden = true
        openQuicklyPanel.onOpen = { [weak self] path in
            self?.openQuickly(path: path)
        }
        openQuicklyPanel.onClose = { [weak self] in
            self?.dismissOpenQuickly()
        }
        registerForDraggedTypes([.fileURL])
        imeHandler.view = self
        mouseHandler.view = self
        scrollController.view = self
        scrollController.onOffsetChange = { [weak self] offset, animated in
            self?.scrollAnimator.setTarget(offset, animated: animated)
        }
        scrollAnimator.onUpdate = { [weak self] offset in
            guard let self else { return }
            self.contentLayer.transform = CATransform3DMakeTranslation(0, offset, 0)
        }
        cursorAnimator.onUpdate = { [weak self] in
            guard let self else { return }
            // The cursor glides across the footer boundary when `:` moves it
            // into the cmdline row, so both layers carry the offset; only the
            // layer drawing the cursor uses it.
            let offset = self.cursorAnimator.offset
            self.contentLayer.cursorGlideOffset = offset
            self.footerLayer.cursorGlideOffset = offset
        }
        imeHandler.onMarkedTextChange = { [weak self] in
            self?.invalidatePreeditRegion()
        }
        refreshBackgroundColor()
        refreshWindowAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        diagnosticPopover.close()
        if imeHandler.hasMarkedText {
            // Composition in progress: let the input context route the event
            // to setMarkedText/insertText/doCommand.
            interpretKeyEvents([event])
            return
        }
        if let key = keyHandler.nvimKey(for: event) {
            sendKeys(key)
        } else {
            // Printable text and dead keys go through the input context so
            // IME composition produces marked text (see IMEHandler).
            interpretKeyEvents([event])
        }
    }

    /// The view's key-equivalent hook runs before the main menu's during
    /// responder-chain dispatch, so when Command passthrough is enabled we
    /// must offer app shortcuts the event first.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.contains(.command) else { return false }
        guard inputSettings.passCmdKeysThrough else { return false }
        if let mainMenu = NSApp.mainMenu, mainMenu.performKeyEquivalent(with: event) {
            return true
        }
        guard let key = keyHandler.nvimKey(for: event) else { return false }
        sendKeys(key)
        return true
    }

    func sendKeys(_ keys: String) {
        trackCmdline(keys)
        // A typed `:terminal` opens the native Ghostty pane beside the
        // editor instead of a terminal buffer inside nvim; the Enter that
        // would execute it cancels the cmdline instead.
        if keys == "<CR>", nativeTerminalPaneEnabled,
           let shellCommand = Self.nativeTerminalRequest(from: cmdlineBuffer) {
            Log.input.notice("Intercepted typed :terminal, opening native pane")
            cmdlineBuffer = ""
            model.inputDispatcher.send(.keys("<Esc>"))
            model.requestTerminalPane(command: shellCommand)
            return
        }
        // A typed `:tabnew [file]` opens a native tab (its own window and
        // nvim session) instead of an in-grid tabpage; same shape as the
        // `:terminal` interception above.
        if keys == "<CR>", let file = Self.nativeTabRequest(from: cmdlineBuffer) {
            Log.input.notice("Intercepted typed :\(self.cmdlineBuffer, privacy: .public), opening a native tab")
            cmdlineBuffer = ""
            model.inputDispatcher.send(.keys("<Esc>"))
            model.requestNativeTab(file: file)
            return
        }
        // Hard gate: the tree-walking fzf commands must not run in / or
        // $HOME — walking either tree can freeze the machine.
        if keys == "<CR>", Self.isFzfWalkCommand(cmdlineBuffer) {
            gateFzfExecution(pendingKeys: keys)
            return
        }
        model.inputDispatcher.send(.keys(keys))
    }

    /// fzf.vim commands whose source walks the current directory tree.
    static let fzfWalkCommands = ["FZF", "Files", "Ag", "Rg", "RGrep", "LGrep"]

    /// Whether a typed cmdline names a tree-walking fzf command. The buffer
    /// holds the command text after the leading `:` (the mode-change flush
    /// has usually landed by the time the first character is typed).
    static func isFzfWalkCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard let name = trimmed.split(separator: " ").first else { return false }
        let bare = name.hasSuffix("!") ? name.dropLast() : name
        return fzfWalkCommands.contains(String(bare))
    }

    /// Directories whose trees are too large to walk with fzf.
    static func isDangerousFzfDirectory(_ path: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == "/" || path == home
    }

    /// Whether a `mode_change` name names the cmdline. nvim's UI protocol
    /// sends the full forms (`cmdline_normal` while typing, `cmdline_insert`
    /// / `cmdline_replace` submodes); `"c"` is only the short name `mode()`
    /// returns — the fzf gate and the `:terminal` interception both keyed on
    /// the short form and never fired. Accept both spellings.
    static func isCmdlineMode(_ modeName: String?) -> Bool {
        guard let modeName else { return false }
        return modeName == "c" || modeName.hasPrefix("cmdline_")
    }

    /// Whether a typed cmdline names a `:terminal` invocation that should
    /// open the native pane instead of an in-buffer terminal.
    static func isNativeTerminalCommand(_ command: String) -> Bool {
        nativeTerminalRequest(from: command) != nil
    }

    /// Parse the cmdline text (after the leading `:`) of a typed `:terminal`
    /// into the shell command the native pane should run ("" for the default
    /// shell); nil when the command is anything else. Matching mirrors nvim:
    /// built-in commands are case-sensitive (`:Term` stays a user command)
    /// and `term`…`terminal` are the accepted abbreviations. An optional
    /// `vert`…`vertical` modifier matches the pane's right-side placement;
    /// other modifiers (`:tab`, `:hor`) are left to nvim itself.
    static func nativeTerminalRequest(from command: String) -> String? {
        var words = command.trimmingCharacters(in: .whitespaces)
            .split(separator: " ", omittingEmptySubsequences: true)
        if let first = words.first, first.count >= 4, "vertical".hasPrefix(first) {
            words.removeFirst()
        }
        guard let name = words.first else { return nil }
        let bare = name.hasSuffix("!") ? name.dropLast() : name
        guard bare.count >= 4, "terminal".hasPrefix(bare) else { return nil }
        return words.dropFirst().joined(separator: " ")
    }

    /// Whether a typed cmdline names a tab-creating command that should open
    /// a native tab instead of an in-grid tabpage.
    static func isNativeTabCommand(_ command: String) -> Bool {
        nativeTabRequest(from: command) != nil
    }

    /// Parse the cmdline text of a tab-creating command into the file to open
    /// in the new native tab ("" for a bare `:tabnew`); nil when the command
    /// is anything else. Matching mirrors nvim: built-in commands are
    /// case-sensitive, `:tabe[dit]` accepts its four-letter abbreviation and
    /// `:tabnew` needs all six letters (`tabne…` is ambiguous with
    /// `:tabnext`). A trailing `|` bar or a `+cmd`/`++opt` modifier stays
    /// with nvim, as do ranges (`:$tabnew` never matches — the range makes
    /// the first word unparseable).
    static func nativeTabRequest(from command: String) -> String? {
        let words = command.trimmingCharacters(in: .whitespaces)
            .split(separator: " ", omittingEmptySubsequences: true)
        guard let name = words.first else { return nil }
        let bare = name.hasSuffix("!") ? name.dropLast() : name
        guard (bare.count >= 6 && "tabnew".hasPrefix(bare))
            || (bare.count >= 4 && "tabedit".hasPrefix(bare)) else { return nil }
        let file = words.dropFirst().joined(separator: " ")
        guard !file.contains("|"), !file.hasPrefix("+") else { return nil }
        return file
    }

    /// Cmdline text accumulated while nvim reports cmdline mode.
    private var cmdlineBuffer = ""

    private func trackCmdline(_ keys: String) {
        guard Self.isCmdlineMode(snapshot?.modeName) else {
            cmdlineBuffer = ""
            return
        }
        switch keys {
        case "<BS>":
            if !cmdlineBuffer.isEmpty { cmdlineBuffer.removeLast() }
        case "<C-u>":
            cmdlineBuffer = ""
        default:
            // Printable runs arrive as plain text; notation tokens (<Esc>,
            // arrows, …) are cmdline editing keys that do not add text.
            if !keys.hasPrefix("<") { cmdlineBuffer += keys }
        }
    }

    /// Hold the Enter that would launch fzf until the working directory is
    /// known to be safe; in / or $HOME ask first, since walking those trees
    /// can freeze the machine.
    private func gateFzfExecution(pendingKeys: String) {
        let command = cmdlineBuffer
        cmdlineBuffer = ""
        Task { @MainActor in
            let directory = (try? await model.client.currentDirectory()) ?? ""
            guard Self.isDangerousFzfDirectory(directory) else {
                model.inputDispatcher.send(.keys(pendingKeys))
                return
            }
            let where_ = directory == "/" ? "the root directory" : "your home directory"
            let alert = NSAlert()
            alert.messageText = "Run \(command) in \(where_)?"
            alert.informativeText = "That directory tree is enormous; walking it with fzf can freeze the machine."
            alert.addButton(withTitle: "Run Anyway")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                model.inputDispatcher.send(.keys(pendingKeys))
            } else {
                model.inputDispatcher.send(.keys("<Esc>"))
            }
        }
    }

    // MARK: - Open Quickly (⌘P)

    /// Toggle the native file finder; presented centered over the editor.
    func toggleOpenQuickly() {
        if openQuicklyPanel.isHidden {
            presentOpenQuickly()
        } else {
            dismissOpenQuickly()
        }
    }

    private func presentOpenQuickly() {
        positionOpenQuicklyPanel()
        openQuicklyPanel.isHidden = false
        window?.makeFirstResponder(openQuicklyPanel.preferredFocus)
        Task { @MainActor in
            let cwd = (try? await model.client.currentDirectory()) ?? ""
            guard !openQuicklyPanel.isHidden, !cwd.isEmpty else { return }
            let files = await QuicklyFileSource.collect(cwd: cwd)
            guard !openQuicklyPanel.isHidden else { return }
            openQuicklyPanel.present(files: files, workingDirectory: cwd)
        }
    }

    private func dismissOpenQuickly() {
        openQuicklyPanel.isHidden = true
        window?.makeFirstResponder(self)
    }

    private func openQuickly(path: String) {
        dismissOpenQuickly()
        Task { @MainActor in
            guard let escaped = try? await model.client.fnameescape(path) else { return }
            try? await model.client.command("edit \(escaped)")
        }
    }

    private func positionOpenQuicklyPanel() {
        let size = OpenQuicklyPanel.panelSize
        let x = (bounds.width - size.width) / 2
        let y = max((bounds.height - size.height) / 2, 0)
        openQuicklyPanel.setFrameOrigin(CGPoint(x: x, y: y))
    }

    // Standard Edit-menu actions reach the first responder through the
    // responder chain. Paste goes to Neovim as typed input; copy mirrors the
    // unnamed register to the system pasteboard.

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        Task { try? await model.client.paste(text) }
    }

    @objc func copy(_ sender: Any?) {
        Task {
            guard let text = try? await model.client.registerContents("\""), !text.isEmpty else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }

    override func selectAll(_ sender: Any?) {
        sendKeys("<Esc>ggVG")
    }

    /// View-space rect for a character range of the marked text, anchored at
    /// the cursor cell and wide as the covered cells, plus the content inset
    /// and the live scroll offset (the frozen footer is not translated, so a
    /// cursor in the cmdline row anchors at the statusline row instead). IME
    /// candidate windows anchor to this (see `firstRect(forCharacterRange:)`).
    func preeditRect(forCharacterRange range: NSRange) -> CGRect {
        guard let (layer, rect) = preeditLayerRect(forCharacterRange: range) else { return .zero }
        return rect.offsetBy(dx: Self.contentInset, dy: layerOriginY(layer))
    }

    /// The layer drawing the marked text plus the preedit rect within it; nil
    /// when there is nothing to anchor to.
    private func preeditLayerRect(forCharacterRange range: NSRange) -> (GridContentLayer, CGRect)? {
        guard imeHandler.hasMarkedText, let host = cursorHost() else { return nil }
        let anchor = host.rect
        let cellWidth = metrics.cellSize.width
        let start = Self.cellOffset(of: imeHandler.markedText, upToUTF16: range.location)
        let end = Self.cellOffset(of: imeHandler.markedText, upToUTF16: range.location + range.length)
        return (host.layer, CGRect(
            x: anchor.minX + CGFloat(start) * cellWidth,
            y: anchor.minY,
            width: CGFloat(max(end - start, 1)) * cellWidth,
            height: anchor.height
        ))
    }

    /// The layer drawing the cursor and the cursor's rect within it, so the
    /// preedit is drawn by whichever layer owns the cursor's row.
    private func cursorHost() -> (layer: GridContentLayer, rect: CGRect)? {
        guard let snapshot, let grid = snapshot.grid, !grid.isEmpty else { return nil }
        let layer = cursorLayer(for: snapshot.cursor, in: snapshot)
        guard let rect = layer.cursorAnchorRect() else { return nil }
        return (layer, rect)
    }

    /// The layer that draws a cursor: the frozen footer owns the rows nvim
    /// never scrolls, everything above lives in the scrolling region.
    private func cursorLayer(for cursor: CursorState, in snapshot: ScreenSnapshot) -> GridContentLayer {
        let footerStart = max(0, (snapshot.grid?.height ?? 0) - Self.frozenFooterRows)
        return cursor.row >= footerStart ? footerLayer : contentLayer
    }

    /// View-space y of a grid layer's local origin: the scrolling region sits
    /// under the live scroll lead, the frozen footer is never translated.
    private func layerOriginY(_ layer: GridContentLayer) -> CGFloat {
        let gridOrigin = layer === footerLayer ? footerLayer.sliceOriginY : scrollAnimator.presentationOffset
        return Self.contentInset + gridOrigin
    }

    /// Display width in cells for preedit text: wide characters take two,
    /// everything else one. Kept on the view (not CellRenderer) because
    /// preedit strings are plain text, not grid cells.
    static func cellCount(of text: String) -> Int {
        text.reduce(0) { $0 + (CellRenderer.isDoubleWidth(String($1)) ? 2 : 1) }
    }

    /// Cells covered by the text strictly before the utf16 offset.
    static func cellOffset(of text: String, upToUTF16 target: Int) -> Int {
        var consumed = 0
        var cells = 0
        for character in text {
            let length = String(character).utf16.count
            if consumed + length > target { break }
            consumed += length
            cells += CellRenderer.isDoubleWidth(String(character)) ? 2 : 1
        }
        return cells
    }

    /// Where the marked text was last drawn and in which layer, so clearing
    /// it repaints the layer that drew it — the preedit follows the cursor,
    /// which can move between the scrolling region and the cmdline row.
    private var lastPreedit: (layer: GridContentLayer, rect: CGRect)?

    /// Live grid dimensions for input translation (mouse cell coordinates).
    var gridDimensions: (width: Int, height: Int)? {
        snapshot?.grid.map { ($0.width, $0.height) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseHandler.mouseDown(event)
    }

    override func mouseDragged(with event: NSEvent) {
        mouseHandler.mouseDragged(event)
    }

    override func mouseUp(with event: NSEvent) {
        mouseHandler.mouseUp(event)
    }

    // MARK: - Link hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        refreshLinkHover(
            atViewPoint: convert(event.locationInWindow, from: nil),
            commandHeld: event.modifierFlags.contains(.command)
        )
    }

    override func mouseEntered(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        clearLinkHover()
    }

    /// Command pressed or released while the pointer is still: re-evaluate the
    /// hover from the current pointer instead of waiting for a mouse move.
    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        refreshLinkHoverFromPointer(commandHeld: event.modifierFlags.contains(.command))
    }

    override func scrollWheel(with event: NSEvent) {
        diagnosticPopover.close()
        scrollController.scrollWheel(with: event)
    }

    // MARK: - Link opening

    /// The http(s) URL rendered at a grid cell, used by ⌘-click. Read from the
    /// same snapshot the renderer draws, so it matches what is on screen.
    func linkTarget(atRow row: Int, col: Int) -> URL? {
        linkHit(atRow: row, col: col)?.url
    }

    /// The URL and the cells it covers at a grid cell, or nil when the cell is
    /// not part of an http(s) URL.
    func linkHit(atRow row: Int, col: Int) -> LinkHit? {
        guard let grid = snapshot?.grid, !grid.isEmpty,
              row >= 0, row < grid.height, col >= 0, col < grid.width else { return nil }
        return LinkDetector.hit(in: Array(grid.rowSlice(row)), column: col)
    }

    /// Underline the link under a view-space point and switch to the
    /// pointing-hand cursor while Command is held over one; clear both
    /// otherwise.
    private func refreshLinkHover(atViewPoint point: CGPoint, commandHeld: Bool) {
        var rect: CellRect?
        if commandHeld, bounds.contains(point), let cell = gridCell(atViewPoint: point),
           let hit = linkHit(atRow: cell.row, col: cell.col) {
            rect = CellRect(
                minRow: cell.row,
                minCol: hit.columns.lowerBound,
                maxRow: cell.row + 1,
                maxCol: hit.columns.upperBound
            )
        }
        guard rect != hoveredLinkRect else { return }
        hoveredLinkRect = rect
        for gridLayer in gridLayers { gridLayer.linkUnderline = rect }
        setLinkCursor(active: rect != nil)
    }

    /// Re-evaluate the hover from the live pointer, for a modifier change that
    /// arrives with no mouse event of its own.
    private func refreshLinkHoverFromPointer(commandHeld: Bool) {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        refreshLinkHover(atViewPoint: point, commandHeld: commandHeld)
    }

    private func clearLinkHover() {
        guard hoveredLinkRect != nil else { return }
        refreshLinkHover(atViewPoint: CGPoint(x: -1, y: -1), commandHeld: false)
    }

    private func setLinkCursor(active: Bool) {
        guard linkCursorActive != active else { return }
        linkCursorActive = active
        (active ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    /// Grid cell under a point in view coordinates, via the same
    /// inset-adjusted math as the mouse handler.
    private func gridCell(atViewPoint point: CGPoint) -> (row: Int, col: Int)? {
        guard let dimensions = gridDimensions else { return nil }
        let gridPoint = CGPoint(x: point.x - Self.contentInset, y: point.y - Self.contentInset)
        return MouseHandler.cellLocation(
            for: gridPoint,
            cellSize: metrics.cellSize,
            gridWidth: dimensions.width,
            gridHeight: dimensions.height
        )
    }

    // MARK: - Diagnostics popover

    /// A plain left click in the sign column (the gutter carrying the
    /// diagnostic signs): look up the clicked line's `vim.diagnostic`
    /// entries and show them in a native popover anchored at the clicked
    /// cell. A line without diagnostics falls back to a normal click,
    /// forwarded after the lookup.
    func presentDiagnostics(atRow row: Int, col: Int) {
        let anchor = signColumnRect(row: row, col: col)
        let themeIsDark = Self.hasDarkBackground(snapshot?.defaultBackground)
        Task { @MainActor in
            let items = (try? await model.client.lineDiagnostics(row: row, col: col)) ?? []
            guard !items.isEmpty else {
                model.inputDispatcher.send(.mouse(
                    button: "left", action: "press", modifier: "", grid: 1, row: row, col: col
                ))
                return
            }
            diagnosticPopover.present(
                items: items, relativeTo: anchor, of: self, themeIsDark: themeIsDark
            )
        }
    }

    /// View-space rect of the clicked gutter cell, two cells wide so the
    /// popover arrow centers on the sign slot.
    private func signColumnRect(row: Int, col: Int) -> CGRect {
        let cell = metrics.cellSize
        let gridHeight = gridDimensions?.height ?? 0
        return CGRect(
            x: Self.contentInset + CGFloat(col) * cell.width,
            y: Self.contentInset + Self.gridRowY(row, gridHeight: gridHeight, cellHeight: cell.height),
            width: cell.width * 2,
            height: cell.height
        )
    }

    // Dropping files on the editor opens them as buffers (same path as
    // "Open With"/Dock drops, which arrive through the app delegate).

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.droppedFileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        model.open(urls)
        return true
    }

    static func droppedFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
    }

    private func invalidatePreeditRegion() {
        let previous = lastPreedit
        lastPreedit = nil
        for gridLayer in gridLayers { gridLayer.preedit = nil }
        guard imeHandler.hasMarkedText,
              let (layer, rect) = preeditLayerRect(forCharacterRange: NSRange(
                  location: 0,
                  length: imeHandler.markedText.utf16.count
              )) else {
            if let previous { previous.layer.setNeedsDisplay(previous.rect) }
            return
        }
        layer.preedit = GridContentLayer.Preedit(
            text: imeHandler.markedText,
            selection: imeHandler.markedSelection
        )
        var dirty = rect
        if let previous {
            if previous.layer === layer {
                dirty = dirty.union(previous.rect)
            } else {
                previous.layer.setNeedsDisplay(previous.rect)
            }
        }
        layer.setNeedsDisplay(dirty)
        lastPreedit = (layer, rect)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
        if snapshot == nil {
            connectScreen()
        }
        // Place the grid layers before anything can draw: an empty clip layer
        // would hide the scrolling region entirely, and the snapshot may have
        // arrived while this view was not yet in a window.
        updateFooterGeometry()
        // Take focus so typing reaches the editor without requiring a click.
        // Re-assert on the next main-actor turn in case SwiftUI restores focus
        // to another control while the window is being laid out.
        if let window {
            // Tracking areas deliver mouseMoved independently, but enabling the
            // window-level flag too keeps hover working across AppKit versions.
            window.acceptsMouseMovedEvents = true
            // init resolved the adaptive fallback with no window context,
            // baking the system appearance into the layer's CGColor; paint
            // the seeded theme before the window can first display.
            refreshBackgroundColor(themeIsDark: model.themeIsDark)
            // `attach` hides a plain window until its theme is known (native
            // tab windows are revealed at once) so the first frame is never
            // the system appearance.
            model.attach(to: window)
            observeWindowKeyState(window)
            refreshWindowAppearance()
            _ = window.makeFirstResponder(self)
        }
        Task { @MainActor [weak self] in
            guard let self, let window = self.window else { return }
            _ = window.makeFirstResponder(self)
        }
    }

    private var isObservingKeyState = false

    /// Menu commands act on the key window's session; follow key-window
    /// changes so `AppModel.active` always tracks the window being driven.
    /// The selector-based observer returns no token on this SDK, so the
    /// registration is removed by observer in `deinit`.
    private func observeWindowKeyState(_ window: NSWindow) {
        guard !isObservingKeyState else { return }
        isObservingKeyState = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hostWindowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
    }

    @objc private func hostWindowDidBecomeKey(_ notification: Notification) {
        model.becameActive()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Fallback colors follow the system appearance; repaint so cells
        // drawn with nvim-packed colors keep showing through where set.
        refreshBackgroundColor()
        updateFooterGeometry()
        updateStatuslineLayer()
        for gridLayer in gridLayers { gridLayer.setNeedsDisplay() }
    }

    private func updateContentsScale() {
        layer?.contentsScale = backingScale
        for gridLayer in gridLayers {
            gridLayer.contentsScale = backingScale
            gridLayer.setNeedsDisplay()
        }
    }

    override func setFrameSize(_ newSize: CGSize) {
        super.setFrameSize(newSize)
        requestResize(to: newSize)
        updateFooterGeometry()
        updateStatuslineLayer()
        updateCompletionPanel()
        positionOpenQuicklyPanel()
    }

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    }

    /// Pull a fresh snapshot on every nvim flush, then invalidate only the
    /// cells the flush dirtied.
    private func connectScreen() {
        let screen = model.screen
        Task { [weak self] in
            guard let self else { return }
            await screen.setFlushHandler { [weak self] grid, cellRects in
                guard let self, grid == 1 else { return }
                Task { @MainActor in
                    let snapshot = await screen.snapshot()
                    let previous = self.snapshot
                    self.updateCursorGlide(previous: previous, next: snapshot)
                    self.crossfadeThemeTransition(from: previous, to: snapshot)
                    self.snapshot = snapshot
                    for gridLayer in self.gridLayers {
                        gridLayer.update(snapshot: snapshot)
                        gridLayer.invalidate(cellRects: cellRects)
                    }
                    self.updateFooterGeometry()
                    self.refreshBackgroundColor()
                    self.updateStatuslineLayer()
                    self.updateCompletionPanel()
                    self.refreshWindowAppearance()
                    self.reconcileGridSize(with: snapshot)
                    self.refreshLinkHoverFromPointer(
                        commandHeld: NSEvent.modifierFlags.contains(.command)
                    )
                }
            }
            await screen.setScrollHandler { [weak self] grid, rows, _ in
                guard let self, grid == 1, rows != 0 else { return }
                Task { @MainActor in
                    self.scrollController.confirmScroll(rows: rows)
                }
            }
            // nvim may have painted before this view was in a window; adopt the
            // current state now instead of waiting for the next flush.
            let snapshot = await screen.snapshot()
            guard snapshot.grid != nil else { return }
            self.snapshot = snapshot
            for gridLayer in self.gridLayers {
                gridLayer.update(snapshot: snapshot)
                gridLayer.setNeedsDisplay()
            }
            self.updateFooterGeometry()
            self.refreshBackgroundColor()
            self.updateStatuslineLayer()
            self.updateCompletionPanel()
            self.refreshWindowAppearance()
            self.refreshLinkHoverFromPointer(
                commandHeld: NSEvent.modifierFlags.contains(.command)
            )
        }
    }

    private func refreshBackgroundColor(themeIsDark: Bool? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = resolvedBackgroundColor(themeIsDark: themeIsDark)
        CATransaction.commit()
    }

    /// The layer background as a resolved CGColor. nvim's packed colors are
    /// appearance-independent; the seeded background (a native tab's host) is
    /// used until the first flush carries nvim's own, so the new tab paints
    /// identically to the tab it continues. The adaptive fallback is a dynamic
    /// AppKit color whose CGColor conversion bakes in whichever appearance is
    /// current at call time — init runs before the window (and its seeded
    /// theme) exists, which painted fresh windows in the system appearance
    /// for their first frames. Resolve under the given theme, else under the
    /// view's live effective appearance.
    private func resolvedBackgroundColor(themeIsDark: Bool?) -> CGColor {
        if let packed = snapshot?.defaultBackground ?? model.seededBackground,
           let color = NSColor(packedRGB: packed) {
            return color.cgColor
        }
        let appearance = themeIsDark.flatMap {
            NSAppearance(named: $0 ? .darkAqua : .aqua)
        } ?? effectiveAppearance
        var resolved: CGColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor.textBackgroundColor.cgColor
        }
        return resolved ?? NSColor.textBackgroundColor.cgColor
    }

    /// Place the two grid layers: the clip container spans the rows the
    /// scroll lead moves (everything above the statusline row) and the frozen
    /// footer sits at the statusline row's top edge, so its rows land exactly
    /// where the grid puts them.
    private func updateFooterGeometry() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let grid = snapshot?.grid, !grid.isEmpty else {
            scrollClipLayer.frame = .zero
            return
        }
        let cellHeight = metrics.cellSize.height
        let footerStart = max(0, grid.height - Self.frozenFooterRows)
        let footerTop = Self.gridRowY(
            footerStart, gridHeight: grid.height, cellHeight: cellHeight
        )
        scrollClipLayer.frame = CGRect(
            x: Self.contentInset,
            y: Self.contentInset,
            width: CGFloat(grid.width) * metrics.cellSize.width,
            height: footerTop
        )
        footerLayer.position = CGPoint(x: Self.contentInset, y: Self.contentInset + footerTop)
    }

    /// Paint the statusline row with the opposite theme mode's default
    /// background, stretched to the full window width: themes pick statusline
    /// backgrounds nearly identical to the editor background (monokai pro
    /// dark: #2E323C on #26292C), so the row itself can't be told apart. The
    /// row above the last grid row is the statusline — the same layout the
    /// cmdline gap assumes (last row = cmdline area, `laststatus` >= 2). The
    /// layer sits below the footer layer, whose statusline-row cells stay
    /// transparent so this fill shows through; the edges are snapped to the
    /// same pixels the grid layers snap their fills to.
    private func updateStatuslineLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let snapshot, let grid = snapshot.grid, !grid.isEmpty, grid.height >= 2 else {
            statuslineLayer.frame = .zero
            statuslineLayer.backgroundColor = nil
            return
        }
        let row = grid.height - 2
        let cellHeight = metrics.cellSize.height
        let scale = backingScale
        let top = Self.contentInset + Self.gridRowY(row, gridHeight: grid.height, cellHeight: cellHeight)
        let snappedTop = (top * scale).rounded() / scale
        let snappedBottom = ((top + cellHeight) * scale).rounded() / scale
        statuslineLayer.frame = CGRect(
            x: 0,
            y: snappedTop,
            width: bounds.width,
            height: max(0, snappedBottom - snappedTop)
        )
        statuslineLayer.backgroundColor = Self.statuslineColors(
            themeIsDark: Self.hasDarkBackground(snapshot.defaultBackground)
        ).background.cgColor
    }

    /// Place and update the native completion panel from the popup state in
    /// the snapshot. The anchor cell comes from nvim (it has already picked
    /// above/below the cursor); the panel flips up when it would overflow
    /// the bottom edge and clamps inside the view horizontally.
    private func updateCompletionPanel() {
        guard let popup = snapshot?.popup, let grid = snapshot?.grid, !grid.isEmpty else {
            if !completionPanel.isHidden { completionPanel.isHidden = true }
            return
        }
        let size = completionPanel.update(
            popup,
            metrics: metrics,
            maxWidth: bounds.width - Self.contentInset * 2
        )
        let cellWidth = metrics.cellSize.width
        let cellHeight = metrics.cellSize.height
        let anchorRowTop = Self.contentInset + CGFloat(popup.row) * cellHeight
        let x = Self.contentInset + CGFloat(popup.col) * cellWidth
        var y = Self.contentInset + Self.gridRowY(
            popup.row, gridHeight: grid.height, cellHeight: cellHeight
        )
        if y + size.height > bounds.height {
            y = anchorRowTop - size.height
        }
        y = min(max(y, 0), max(0, bounds.height - size.height))
        let clampedX = min(max(x, 0), max(0, bounds.width - size.width))
        completionPanel.setFrameOrigin(CGPoint(x: clampedX, y: y))
        completionPanel.isHidden = false
    }

    /// Push the nvim theme into the window chrome through SwiftUI: setting
    /// `NSWindow.appearance` directly is reset by the hosting WindowGroup,
    /// while `preferredColorScheme` drives the window appearance (titlebar,
    /// traffic lights, title text) and survives SwiftUI updates.
    private func refreshWindowAppearance() {
        model.setThemeIsDark(Self.hasDarkBackground(snapshot?.defaultBackground))
        model.setTerminalColors(AppModel.TerminalColors(
            foreground: snapshot?.defaultForeground,
            background: snapshot?.defaultBackground
        ))
    }

    /// Soften a theme-mode change the user can already see: when a flush
    /// reports a light↔dark mode different from the one on screen, the
    /// current rendering is snapshotted and faded out over the redrawn
    /// content. On a first paint the seen mode is the seeded theme (a new
    /// tab inherits its host's) or the window's effective appearance, so
    /// even the initial fill fades when it changes the look; an in-place
    /// `:colorscheme` flip crossfades through the previous snapshot.
    private func crossfadeThemeTransition(from previous: ScreenSnapshot?, to next: ScreenSnapshot) {
        guard let window, window.isVisible else { return }
        guard let to = Self.hasDarkBackground(next.defaultBackground) else { return }
        let seenMode: Bool?
        if let previous, let seen = Self.hasDarkBackground(previous.defaultBackground) {
            seenMode = seen
        } else if let seeded = model.themeIsDark {
            seenMode = seeded
        } else {
            seenMode = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
        guard let seenMode, seenMode != to, let contents = snapshotContents() else { return }
        // A flip while a fade is in flight swaps in a fresh overlay.
        themeCrossfadeView?.removeFromSuperview()
        let overlay = NSImageView(frame: bounds)
        overlay.image = NSImage(cgImage: contents, size: bounds.size)
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        themeCrossfadeView = overlay
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.themeCrossfadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            overlay.animator().alphaValue = 0
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.themeCrossfadeDuration))
            guard let self, self.themeCrossfadeView === overlay else { return }
            overlay.removeFromSuperview()
            self.themeCrossfadeView = nil
        }
    }

    /// Render the current layer tree (grid content, statusline bar, cursor)
    /// into a bitmap for the theme crossfade overlay.
    private func snapshotContents() -> CGImage? {
        guard let layer, bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = backingScale
        guard let context = CGContext(
            data: nil,
            width: max(1, Int(bounds.width * scale)),
            height: max(1, Int(bounds.height * scale)),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        return context.makeImage()
    }

    /// Slide the cursor to its new cell instead of jumping; runs before the
    /// content layer adopts the new snapshot so the previous cell rect is
    /// still available as the glide origin.
    private func updateCursorGlide(previous: ScreenSnapshot?, next: ScreenSnapshot) {
        guard let previous,
              previous.cursor.grid == 1, next.cursor.grid == 1,
              previous.cursor != next.cursor,
              let grid = next.grid,
              next.cursor.row >= 0, next.cursor.row < grid.height,
              next.cursor.col >= 0, next.cursor.col < grid.width,
              let oldRect = cursorLayer(for: previous.cursor, in: previous).cursorGridRect() else {
            return
        }
        let cellSize = metrics.cellSize
        // A cursor on a double-width char (empty continuation cell beside it)
        // glides as a two-cell rect so it matches what gets drawn.
        let wide = next.cursor.col + 1 < grid.width
            && grid[next.cursor.row, next.cursor.col + 1].text.isEmpty
        let newRect = CGRect(
            x: CGFloat(next.cursor.col) * cellSize.width,
            y: Self.gridRowY(
                next.cursor.row,
                gridHeight: grid.height,
                cellHeight: cellSize.height
            ),
            width: cellSize.width * (wide ? 2 : 1),
            height: cellSize.height
        )
        let distance = max(
            abs(next.cursor.row - previous.cursor.row),
            abs(next.cursor.col - previous.cursor.col)
        )
        cursorAnimator.glide(from: oldRect, to: newRect, distanceInCells: CGFloat(distance))
    }

}
