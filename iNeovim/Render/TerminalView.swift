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

    let model: AppModel
    private(set) var metrics: FontMetrics
    private var snapshot: ScreenSnapshot?
    private let contentLayer: GridContentLayer
    /// Backdrop stretching the statusline row's background to the window
    /// edges; the content layer draws over it, so only the side bands the
    /// content inset leaves open actually show.
    private let statuslineLayer = CALayer()
    /// Native ext_popupmenu completion panel, placed above the content layer
    /// at the anchor nvim reports.
    private let completionPanel = CompletionPanelView()
    /// Native ⌘P file finder; presented centered over the editor and hidden
    /// again after a pick or cancel.
    private let openQuicklyPanel = OpenQuicklyPanel()
    private let scrollAnimator = ScrollAnimator()
    private let cursorAnimator = CursorAnimator()
    private let resizeController: ResizeController
    private var keyHandler = KeyInputHandler()
    private let mouseHandler: MouseHandler
    private let scrollController: ScrollController
    let imeHandler = IMEHandler()
    private var sessionReady = false
    /// The view size for which a corrective resize was already attempted; a
    /// rejected request must not be repeated forever.
    private var reconciledViewSize: CGSize?
    var inputSettings = InputSettings() {
        didSet {
            keyHandler.passCmdKeys = inputSettings.passCmdKeysThrough
            keyHandler.optionAsMeta = inputSettings.optionAsMeta
        }
    }

    /// Apply user settings: font metrics, input switches, and animation
    /// toggles. Changing the font reflows the grid at the new cell size.
    func apply(settings: AppSettings) {
        let font = settings.resolvedFont()
        if metrics.font != font {
            applyMetrics(FontMetrics(font: font))
        }
        inputSettings = settings.inputSettings
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
        Task { await resizeController.viewDidResize(to: Self.gridAreaSize(size)) }
    }

    /// Neovim rejects a resize that arrives before `ui_attach`, which would
    /// leave the grid at its initial 80x24 and visibly smaller than the window
    /// if the window is never resized again. Once a snapshot is applied, compare
    /// its grid with the size the view needs and re-request when they differ
    /// (at most once per view size, so a rejected request cannot spin).
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
        contentLayer.updateMetrics(newMetrics)
        if let snapshot {
            contentLayer.update(snapshot: snapshot)
        }
        contentLayer.setNeedsDisplay()
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
        // Anchor the content layer's top-left to the inset origin. Its own
        // bounds grow to the full grid (for scrolling); without this the layer
        // is centered on the origin and clipped out of view.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.anchorPoint = .zero
        contentLayer.position = CGPoint(x: Self.contentInset, y: Self.contentInset)
        CATransaction.commit()
        layer?.addSublayer(statuslineLayer)
        layer?.addSublayer(contentLayer)
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
            self.contentLayer.cursorGlideOffset = self.cursorAnimator.offset
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

    /// Cmdline text accumulated while nvim reports cmdline mode.
    private var cmdlineBuffer = ""

    private func trackCmdline(_ keys: String) {
        guard snapshot?.modeName == "c" else {
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
    /// and the live scroll offset. IME candidate windows anchor to this (see
    /// `firstRect(forCharacterRange:)`).
    func preeditRect(forCharacterRange range: NSRange) -> CGRect {
        preeditLayerRect(forCharacterRange: range)
            .offsetBy(
                dx: Self.contentInset,
                dy: Self.contentInset + scrollAnimator.presentationOffset
            )
    }

    private func preeditLayerRect(forCharacterRange range: NSRange) -> CGRect {
        guard imeHandler.hasMarkedText, let anchor = contentLayer.cursorAnchorRect() else { return .zero }
        let cellWidth = metrics.cellSize.width
        let start = Self.cellOffset(of: imeHandler.markedText, upToUTF16: range.location)
        let end = Self.cellOffset(of: imeHandler.markedText, upToUTF16: range.location + range.length)
        return CGRect(
            x: anchor.minX + CGFloat(start) * cellWidth,
            y: anchor.minY,
            width: CGFloat(max(end - start, 1)) * cellWidth,
            height: anchor.height
        )
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

    private var lastPreeditRect: CGRect?

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

    override func scrollWheel(with event: NSEvent) {
        scrollController.scrollWheel(with: event)
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
        let rect = preeditLayerRect(forCharacterRange: NSRange(
            location: 0,
            length: imeHandler.markedText.utf16.count
        ))
        var dirty = rect
        if let lastPreeditRect { dirty = dirty.union(lastPreeditRect) }
        lastPreeditRect = imeHandler.hasMarkedText ? rect : nil
        contentLayer.preedit = imeHandler.hasMarkedText
            ? GridContentLayer.Preedit(text: imeHandler.markedText, selection: imeHandler.markedSelection)
            : nil
        guard !dirty.isEmpty else { return }
        contentLayer.setNeedsDisplay(dirty)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
        if snapshot == nil {
            connectScreen()
        }        // Take focus so typing reaches the editor without requiring a click.
        // Re-assert on the next main-actor turn in case SwiftUI restores focus
        // to another control while the window is being laid out.
        if let window {
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
        updateStatuslineLayer()
        contentLayer.setNeedsDisplay()
    }

    private func updateContentsScale() {
        layer?.contentsScale = backingScale
        contentLayer.contentsScale = backingScale
        contentLayer.setNeedsDisplay()
    }

    override func setFrameSize(_ newSize: CGSize) {
        super.setFrameSize(newSize)
        requestResize(to: newSize)
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
                    self.snapshot = snapshot
                    self.contentLayer.update(snapshot: snapshot)
                    self.contentLayer.invalidate(cellRects: cellRects)
                    self.refreshBackgroundColor()
                    self.updateStatuslineLayer()
                    self.updateCompletionPanel()
                    self.refreshWindowAppearance()
                    self.reconcileGridSize(with: snapshot)
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
            self.contentLayer.update(snapshot: snapshot)
            self.contentLayer.setNeedsDisplay()
            self.refreshBackgroundColor()
            self.updateStatuslineLayer()
            self.updateCompletionPanel()
            self.refreshWindowAppearance()
        }
    }

    private func refreshBackgroundColor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = backgroundColor.cgColor
        CATransaction.commit()
    }

    /// Stretch the statusline row's background to the full window width.
    /// The row above the last grid row is the statusline — the same layout
    /// the cmdline gap assumes (last row = cmdline area, `laststatus` >= 2).
    /// The layer sits below the content layer, so the row's own in-grid fill
    /// (same color) covers the overlap; the edges are snapped to the same
    /// pixels that fill snaps to inside the content layer.
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
        statuslineLayer.backgroundColor = statuslineBackgroundColor(row: row).cgColor
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

    /// The statusline row's background: its leftmost run's resolved color,
    /// falling back to the view's background when the row leaves it unset.
    private func statuslineBackgroundColor(row: Int) -> NSColor {        guard let snapshot, let grid = snapshot.grid,
              let run = CellRenderer.runs(forRow: grid.rowSlice(row)).first else {
            return backgroundColor
        }
        let attr = snapshot.highlights[run.attrId] ?? HlAttr()
        let resolved = attr.resolvedColors(
            defaultForeground: snapshot.defaultForeground,
            defaultBackground: snapshot.defaultBackground,
            defaultSpecial: snapshot.defaultSpecial
        )
        return resolved.background.flatMap(NSColor.init(packedRGB:)) ?? backgroundColor
    }

    /// Push the nvim theme into the window chrome through SwiftUI: setting
    /// `NSWindow.appearance` directly is reset by the hosting WindowGroup,
    /// while `preferredColorScheme` drives the window appearance (titlebar,
    /// traffic lights, title text) and survives SwiftUI updates.
    private func refreshWindowAppearance() {
        model.setThemeIsDark(Self.hasDarkBackground(snapshot?.defaultBackground))
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
              let oldRect = contentLayer.cursorAnchorRect() else {
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

    /// Colors for when nvim leaves a default unset (-1): adaptive AppKit
    /// colors, so the surface follows dark/light mode.
    private var fallbackBackground: NSColor { .textBackgroundColor }

    private var backgroundColor: NSColor {
        if let packed = snapshot?.defaultBackground, let color = NSColor(packedRGB: packed) {
            return color
        }
        return fallbackBackground
    }
}
