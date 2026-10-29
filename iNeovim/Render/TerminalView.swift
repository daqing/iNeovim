import AppKit
import Combine
import CoreText
import os

/// The terminal surface: hosts the scrollable grid content layer, paints
/// the background behind it, and routes keyboard, mouse, and scroll input.
final class TerminalView: NSView {
    /// Breathing room above and below the grid. The grid is sized from the
    /// inset area only, so the last line (statusline/cmdline) can never
    /// touch the window edges.
    static let contentInset: CGFloat = 6

    /// The narrowest right padding that keeps the text clear of the scroll
    /// indicator: the strip the thumb occupies along the window edge plus a
    /// 2 pt gap to the text, both measured from where the text actually ends
    /// — buffer text is drawn `NvimTextLayout.textShift` right of its cells,
    /// so that shift is reserved again here.
    static let minimumTrailingPadding: CGFloat =
        ScrollIndicator.rightInset + ScrollIndicator.width + NvimTextLayout.textShift + 2

    /// Padding used by a view before `apply(settings:)` supplies the user's
    /// values; also the reset default.
    static let defaultLeadingPadding: CGFloat = 4
    static let defaultTrailingPadding: CGFloat = 12

    /// Breathing room from the window's left edge to the grid. The gutter is
    /// chrome, not text: the gap between it and the buffer text comes from
    /// `NvimTextLayout.textShift`.
    private(set) var leadingPadding: CGFloat = TerminalView.defaultLeadingPadding

    /// Breathing room from the grid to the window's right edge, clamped to
    /// `minimumTrailingPadding` so the scroll thumb never sits on the text.
    private(set) var trailingPadding: CGFloat = TerminalView.defaultTrailingPadding

    var leadingContentInset: CGFloat { leadingPadding }
    var trailingContentInset: CGFloat { max(trailingPadding, Self.minimumTrailingPadding) }

    /// Extra vertical space between the statusline row and the cmdline row
    /// below it: the last grid row is drawn this far below its uniform slot,
    /// so the two rows never touch. The last global grid row is nvim's
    /// message / cmdline area; with `laststatus` >= 2 the row above it is
    /// the statusline.
    static let cmdlineGap: CGFloat = 5

    /// View size minus the horizontal and vertical insets and the cmdline
    /// gap: the area the grid (rows plus gap) may occupy. Grid cell counts
    /// must always be derived from this, never from the raw bounds, or the
    /// grid fills the view edge to edge.
    func gridAreaSize(_ size: CGSize) -> CGSize {
        return CGSize(
            width: max(0, size.width - leadingContentInset - trailingContentInset),
            height: max(0, size.height - Self.contentInset * 2 - Self.cmdlineGap)
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
    /// Dirty cells from flushes that arrived while a snapshot apply was
    /// already queued. A wheel burst produces a flush per step; applying each
    /// one on its own re-rendered the same latest snapshot and piled work up
    /// behind the event that caused it, so the content fell further behind.
    private var pendingFlushRects: [CellRect] = []
    private var flushApplyScheduled = false
    /// Overlay fading the previous theme's rendering out during a light↔dark
    /// flip seen in place (see `crossfadeThemeTransition`).
    private var themeCrossfadeView: NSView?

    /// One displayed grid: the content layer plus the clip bounding it. The
    /// scroll lead translates only the lead box's content layer, inside its
    /// own clip, so a gesture never smears rows over neighboring grids or
    /// the statusline bar.
    final class GridBox {
        let gridId: Int
        let contentLayer: GridContentLayer
        let clipLayer = CALayer()

        init(gridId: Int, metrics: FontMetrics) {
            self.gridId = gridId
            self.contentLayer = GridContentLayer(metrics: metrics, gridId: gridId)
            clipLayer.masksToBounds = true
            clipLayer.addSublayer(contentLayer)
            contentLayer.anchorPoint = .zero
            contentLayer.position = .zero
        }
    }

    /// The global grid's box: always present. It paints the screen
    /// background, vsplit separators, the statusline rows, and the
    /// message-area fill; window text lives in the boxes above it.
    private let baseBox: GridBox
    /// Boxes per displayed grid (windows, floats, the message grid); grid 1
    /// resolves to `baseBox`.
    private var boxes: [Int: GridBox] = [:]
    /// Box ids in draw order (bottom to top): the global grid, the tiled
    /// window grids, then floats and the message grid by nvim's z order.
    private var boxOrder: [Int] = [1]
    /// The grid a scroll gesture grabbed: the only box the lead translates
    /// and the only one whose nvim scroll confirmations count.
    private(set) var scrollLeadGrid = 1
    /// Live presentation offset of the scroll lead, so IME anchoring follows
    /// the visually-shifted lead content mid-gesture.
    private var scrollPresentationOffset: CGFloat = 0
    /// Backdrop painting the statusline row with the opposite theme mode's
    /// default background, stretched to the window edges. The global grid
    /// keeps that row's cells transparent, so the backdrop shows across the
    /// whole row; the side bands are the part the grid itself can't reach.
    private let statuslineLayer = CALayer()
    /// Native ext_popupmenu completion panel, placed above the content layer
    /// at the anchor nvim reports.
    private let completionPanel = CompletionPanelView()
    /// Native popover listing the diagnostics on a gutter sign's line.
    private let diagnosticPopover = DiagnosticPopover()
    private let scrollAnimator = ScrollAnimator()
    private let cursorAnimator = CursorAnimator()
    /// The transient overlay scrollbar shown while the wheel or trackpad
    /// scrolls and hidden shortly after it stops (see `ScrollIndicator`).
    private let scrollIndicator = ScrollIndicator()
    /// At most one metrics query is in flight: a wheel spin against a blocked
    /// nvim (a running `:!`, a prompt) would otherwise pile queries up behind
    /// the input it is not processing, and they would all run on unblock.
    private var scrollMetricsQueryInFlight = false
    private let resizeController: ResizeController
    private var keyHandler = KeyInputHandler()
    private let mouseHandler: MouseHandler
    private let scrollController: ScrollController
    let imeHandler = IMEHandler()
    private var sessionReady = false
    /// Grid rect of the link currently underlined for ⌘-hover, nil otherwise.
    private var hoveredLinkRect: CellRect?
    /// The grid the hovered link lives on, so the underline moves between
    /// the per-grid layers instead of being set on all of them.
    private var hoveredLinkGrid = 1
    /// Whether the pointing-hand cursor is currently set by a link hover, so
    /// the cursor is only reset when it was ours to change.
    private var linkCursorActive = false
    private var hoverTrackingArea: NSTrackingArea?
    private var cancellables: Set<AnyCancellable> = []
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

    /// The content layers of every displayed grid, in draw order (bottom to
    /// top).
    private var gridLayers: [GridContentLayer] {
        boxOrder.compactMap { boxes[$0]?.contentLayer }
    }
    /// Apply a fresh snapshot to every box, reconciling the box set with the
    /// snapshot's frames first: new grids get boxes, gone grids lose them,
    /// and the z order follows nvim's (base < windows < floats by zindex).
    private func syncGridBoxes(with snapshot: ScreenSnapshot) {
        for (gridId, box) in boxes where snapshot.frames[gridId] == nil && gridId != 1 {
            box.contentLayer.removeFromSuperlayer()
            box.clipLayer.removeFromSuperlayer()
            boxes[gridId] = nil
        }
        for gridId in snapshot.frames.keys where boxes[gridId] == nil && gridId != 1 {
            let box = GridBox(gridId: gridId, metrics: metrics)
            // Boxes come and go with snapshots, long after the view entered
            // a window: a layer added to the hierarchy directly never gets
            // AppKit's scale, so every new box needs the display's scale or
            // its text draws at 1x and blurs on a Retina screen.
            box.contentLayer.contentsScale = backingScale
            boxes[gridId] = box
            layer?.addSublayer(box.clipLayer)
        }
        var order: [Int] = [1]
        var floats: [(Int, GridFrame)] = []
        for (gridId, frame) in snapshot.frames where gridId != 1 && !frame.hidden {
            if frame.isFloat || frame.isMessage {
                floats.append((gridId, frame))
            } else {
                order.append(gridId)
            }
        }
        floats.sort { lhs, rhs in
            let (lhsGrid, lhsFrame) = lhs
            let (rhsGrid, rhsFrame) = rhs
            return (lhsFrame.zindex, lhsFrame.compindex, lhsGrid)
                < (rhsFrame.zindex, rhsFrame.compindex, rhsGrid)
        }
        order.append(contentsOf: floats.map { $0.0 })
        boxOrder = order
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var zIndex = 0
        for gridId in order {
            boxes[gridId]?.clipLayer.zPosition = CGFloat(zIndex)
            zIndex += 1
        }
        CATransaction.commit()
    }

    /// Place every displayed box at the global position its frame puts it:
    /// x from the frame column, y from the frame row's global y (which
    /// carries the cmdline gap when the frame reaches the last row), sized
    /// to the grid's cells. A hidden frame hides its box instead of
    /// removing it — nvim flips the same grid in and out.
    private func updateBoxGeometry() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let snapshot else { return }
        for gridId in boxOrder {
            guard let box = boxes[gridId] else { continue }
            let frame = snapshot.frames[gridId] ?? GridFrame(row: 0, col: 0)
            let grid = snapshot.grids[gridId]
            let cellWidth = metrics.cellSize.width
            box.clipLayer.isHidden = frame.hidden || grid == nil || grid?.isEmpty != false
            guard let grid, !grid.isEmpty else { continue }
            box.clipLayer.frame = CGRect(
                x: leadingContentInset + CGFloat(frame.col) * cellWidth,
                y: Self.contentInset + box.contentLayer.originY,
                width: CGFloat(grid.width) * cellWidth + NvimTextLayout.textShift,
                height: box.contentLayer.bounds.height
            )
        }
        // The thumb spans the rows the content scrolls through — never the
        // statusline/cmdline rows — but hugs the window edge like a system
        // scroller.
        if let grid = snapshot.grid, !grid.isEmpty {
            let scrollableHeight = grid.height >= 2
                ? Self.gridRowY(
                    grid.height - 2,
                    gridHeight: grid.height,
                    cellHeight: metrics.cellSize.height
                )
                : bounds.height - Self.contentInset
            scrollIndicator.layout(
                track: CGRect(x: 0, y: Self.contentInset, width: bounds.width, height: scrollableHeight),
                isDark: scrollIndicatorIsDark,
                scale: backingScale
            )
        } else {
            scrollIndicator.layout(
                track: .zero, isDark: scrollIndicatorIsDark, scale: backingScale
            )
        }
    }

    /// Apply user settings: font metrics, horizontal padding, input switches,
    /// and animation toggles. Changing the font reflows the grid at the new
    /// cell size; changing a padding moves the grid and re-requests its size.
    func apply(settings: AppSettings) {
        let font = settings.resolvedFont()
        if metrics.font != font {
            applyMetrics(FontMetrics(font: font))
        }
        applyPadding(
            leading: CGFloat(settings.leadingPadding),
            trailing: CGFloat(settings.trailingPadding)
        )
        inputSettings = settings.inputSettings
        nativeTerminalPaneEnabled = settings.nativeTerminalPane
        let animations = settings.animationSettings
        scrollController.settings = animations
        scrollAnimator.settings = animations
        cursorAnimator.settings = animations
    }

    /// Move the grid for a padding change. The layers are repositioned here
    /// rather than in `layout()` (this view has no layout override), and the
    /// smaller area re-requests the grid size so nvim reflows its columns.
    private func applyPadding(leading: CGFloat, trailing: CGFloat) {
        let clampedTrailing = max(trailing, Self.minimumTrailingPadding)
        guard leading != leadingPadding || clampedTrailing != trailingPadding else { return }
        leadingPadding = leading
        trailingPadding = clampedTrailing
        updateBoxGeometry()
        updateStatuslineBar()
        updateCompletionPanel()
        requestResize(to: bounds.size)
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
        let area = gridAreaSize(size)
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
            for: gridAreaSize(bounds.size),
            cellSize: metrics.cellSize
        )
        guard grid.width != expected.cols || grid.height != expected.rows else { return }
        guard reconciledViewSize != bounds.size else { return }
        reconciledViewSize = bounds.size
        Task { await resizeController.viewDidResize(to: gridAreaSize(bounds.size)) }
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
        updateBoxGeometry()
        updateStatuslineBar()
        updateCompletionPanel()
        let size = bounds.size
        Task { [weak self] in
            guard let self else { return }
            await self.resizeController.setCellSize(newMetrics.cellSize)
            await self.resizeController.viewDidResize(to: gridAreaSize(size))
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
        self.baseBox = GridBox(gridId: 1, metrics: metrics)
        self.boxes = [1: self.baseBox]
        self.mouseHandler = MouseHandler(dispatcher: model.inputDispatcher)
        self.scrollController = ScrollController(dispatcher: model.inputDispatcher)
        self.resizeController = ResizeController(cellSize: metrics.cellSize, client: model.client)
        super.init(frame: NSRect(
            origin: .zero,
            size: CGSize(
                width: metrics.cellSize.width * 80 + Self.defaultLeadingPadding + Self.defaultTrailingPadding,
                height: metrics.cellSize.height * 24 + Self.contentInset * 2 + Self.cmdlineGap
            )
        ))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.masksToBounds = true
        // The bar paints first (below every grid box), the global grid above
        // it (its statusline-row cells stay transparent so the bar shows
        // through), then the window/float/message boxes and the indicator —
        // added and z-ordered as the snapshots report grids.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        statuslineLayer.opacity = Self.statuslineBarOpacity
        layer?.addSublayer(statuslineLayer)
        layer?.addSublayer(baseBox.clipLayer)
        layer?.addSublayer(scrollIndicator.layer)
        CATransaction.commit()
        completionPanel.onSelect = { [weak self] index in
            guard let self else { return }
            Task { try? await self.model.client.selectPopupmenuItem(index) }
        }
        addSubview(completionPanel)
        completionPanel.isHidden = true
        registerForDraggedTypes([.fileURL])
        imeHandler.view = self
        mouseHandler.view = self
        scrollController.view = self
        scrollController.onOffsetChange = { [weak self] offset, animated in
            self?.scrollAnimator.setTarget(offset, animated: animated)
        }
        scrollController.onScrollActivity = { [weak self] row, col in
            self?.scrollActivity(row: row, col: col)
        }
        scrollAnimator.onUpdate = { [weak self] offset in
            guard let self else { return }
            self.scrollPresentationOffset = offset
            self.syncLeadTransform()
        }
        cursorAnimator.onUpdate = { [weak self] in
            guard let self else { return }
            // Only the layer drawing the cursor uses the offset; the rest
            // find no cursor of their own and skip.
            let offset = self.cursorAnimator.offset
            for gridLayer in self.gridLayers { gridLayer.cursorGlideOffset = offset }
        }
        imeHandler.onMarkedTextChange = { [weak self] in
            self?.invalidatePreeditRegion()
        }
        // nvim reports where each window's text begins (after its gutter);
        // every grid layer needs it to draw text clear of the gutter, and it
        // can change without a flush — a sign column that appears or
        // collapses.
        model.$textRegions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] regions in
                guard let self else { return }
                for gridLayer in gridLayers { gridLayer.textRegions = regions }
            }
            .store(in: &cancellables)
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
        // A typed `:q` (or another quit command) ends the embedded nvim —
        // and with it the window, or the whole app when it is the last one —
        // so confirm first; cancel sends `<Esc>` and dismisses the cmdline.
        if keys == "<CR>", Self.isQuitCommand(cmdlineBuffer) {
            confirmQuit(pendingKeys: keys)
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

    /// Whether a typed cmdline names a command that quits the embedded nvim:
    /// `:q[uit]` and `:qa[ll]`, each with an optional `!`. Matching mirrors
    /// nvim's abbreviations (`:q`, `:qu`, `:qui`, `:quit`; `:qa`, `:qal`,
    /// `:qall`) and is case-sensitive like nvim's built-in commands. Write-and-
    /// quit forms (`:wq`, `:x`) are left to nvim.
    static func isQuitCommand(_ command: String) -> Bool {
        let words = command.trimmingCharacters(in: .whitespaces)
            .split(separator: " ", omittingEmptySubsequences: true)
        guard let name = words.first else { return false }
        let bare = name.hasSuffix("!") ? name.dropLast() : name
        guard !bare.isEmpty else { return false }
        return "quit".hasPrefix(bare) || (bare.count >= 2 && "qall".hasPrefix(bare))
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

    /// Hold a typed quit command behind a confirmation: `:q` exits the
    /// embedded nvim, which closes this tab, this window, or the whole app
    /// when it is the last editor window — so a stray quit must be confirmed,
    /// in the words of what it will actually do. Cancel sends `<Esc>` instead,
    /// leaving the session running.
    private func confirmQuit(pendingKeys: String) {
        cmdlineBuffer = ""
        let window = self.window ?? model.hostWindow
        Task { @MainActor in
            if QuitConfirmation.present(QuitConfirmation.scope(for: window)) {
                model.inputDispatcher.send(.keys(pendingKeys))
            } else {
                model.inputDispatcher.send(.keys("<Esc>"))
            }
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
    /// the cursor cell of whichever grid holds it, plus that grid's global
    /// offset, the content inset, and the live scroll lead (the lead grid's
    /// content visually shifts mid-gesture). IME candidate windows anchor to
    /// this (see `firstRect(forCharacterRange:)`).
    func preeditRect(forCharacterRange range: NSRange) -> CGRect {
        guard let (box, rect) = preeditLayerRect(forCharacterRange: range) else { return .zero }
        let frame = snapshot?.frames[box.gridId] ?? GridFrame(row: 0, col: 0)
        return rect.offsetBy(
            dx: leadingContentInset + CGFloat(frame.col) * metrics.cellSize.width,
            dy: layerOriginY(box)
        )
    }

    /// The layer drawing the marked text plus the preedit rect within it; nil
    /// when there is nothing to anchor to.
    private func preeditLayerRect(forCharacterRange range: NSRange) -> (GridBox, CGRect)? {
        guard imeHandler.hasMarkedText, let host = cursorHost() else { return nil }
        let anchor = host.rect
        let cellWidth = metrics.cellSize.width
        let start = Self.cellOffset(of: imeHandler.markedText, upToUTF16: range.location)
        let end = Self.cellOffset(of: imeHandler.markedText, upToUTF16: range.location + range.length)
        return (host.box, CGRect(
            x: anchor.minX + CGFloat(start) * cellWidth,
            y: anchor.minY,
            width: CGFloat(max(end - start, 1)) * cellWidth,
            height: anchor.height
        ))
    }

    /// The box drawing the cursor and the cursor's rect within it, so the
    /// preedit is drawn by the grid the cursor sits on.
    private func cursorHost() -> (box: GridBox, rect: CGRect)? {
        guard let snapshot, let box = boxes[snapshot.cursor.grid],
              let rect = box.contentLayer.cursorAnchorRect() else { return nil }
        return (box, rect)
    }

    /// View-space y of a grid box's local origin: the scroll lead's live
    /// offset only shifts the lead grid's content.
    private func layerOriginY(_ box: GridBox) -> CGFloat {
        Self.contentInset + box.contentLayer.originY
            + (box.gridId == scrollLeadGrid ? scrollPresentationOffset : 0)
    }

    /// Translate the scroll lead's live offset onto the lead grid's content
    /// layer; other grids never move mid-gesture.
    private func syncLeadTransform() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (gridId, box) in boxes {
            let offset = gridId == scrollLeadGrid ? scrollPresentationOffset : 0
            box.contentLayer.transform = CATransform3DMakeTranslation(0, offset, 0)
        }
        CATransaction.commit()
    }

    /// Bind the scroll lead to the grid a gesture grabbed: only that box
    /// visually translates, and only its nvim scroll confirmations count.
    /// Called by the scroll controller at gesture start.
    func setScrollLead(_ grid: Int) {
        guard scrollLeadGrid != grid else { return }
        scrollLeadGrid = grid
        syncLeadTransform()
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
    /// which can move between grids.
    private var lastPreedit: (layer: GridContentLayer, rect: CGRect)?

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

    // MARK: - Scroll indicator

    /// A wheel or trackpad delta moved the content: show the scrollbar from
    /// what is already known and ask nvim for the viewport under the pointer.
    /// The query is issued per delta unless one is still in flight — a round
    /// trip is sub-millisecond, and its answer is what keeps the thumb in
    /// step with the scrolling.
    private func scrollActivity(row: Int, col: Int) {
        scrollIndicator.flash()
        guard !scrollMetricsQueryInFlight else { return }
        scrollMetricsQueryInFlight = true
        Task { [weak self] in
            guard let self else { return }
            let metrics = try? await self.model.client.windowScrollMetrics(row: row, col: col)
            self.scrollMetricsQueryInFlight = false
            self.scrollIndicator.setMetrics(metrics)
        }
    }

    /// The theme the scrollbar knob follows; an unknown nvim background falls
    /// back to the window appearance, like the statusline bar.
    private var scrollIndicatorIsDark: Bool {
        if let theme = Self.hasDarkBackground(snapshot?.defaultBackground) { return theme }
        return effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    // MARK: - Link opening

    /// The http(s) URL rendered at a resolved grid hit, used by ⌘-click. Read
    /// from the same snapshot the renderer draws, so it matches the screen.
    func linkTarget(at hit: GridHit) -> URL? {
        linkHit(at: hit)?.url
    }

    /// The URL and the cells it covers at a resolved grid hit, or nil when
    /// the cell is not part of an http(s) URL.
    func linkHit(at hit: GridHit) -> LinkHit? {
        guard let grid = snapshot?.grids[hit.grid], !grid.isEmpty,
              hit.row >= 0, hit.row < grid.height, hit.col >= 0, hit.col < grid.width else {
            return nil
        }
        return LinkDetector.hit(in: Array(grid.rowSlice(hit.row)), column: hit.col)
    }

    /// Underline the link under a view-space point and switch to the
    /// pointing-hand cursor while Command is held over one; clear both
    /// otherwise. The underline lives on the hit grid's own layer.
    private func refreshLinkHover(atViewPoint point: CGPoint, commandHeld: Bool) {
        var hit: GridHit?
        var rect: CellRect?
        if commandHeld, bounds.contains(point) {
            hit = gridHit(forViewPoint: point)
            if let hit, let link = linkHit(at: hit) {
                rect = CellRect(
                    minRow: hit.row,
                    minCol: link.columns.lowerBound,
                    maxRow: hit.row + 1,
                    maxCol: link.columns.upperBound
                )
            }
        }
        // The same cell rect on a different grid is still a different link.
        let newGrid = hit?.grid ?? hoveredLinkGrid
        guard rect != hoveredLinkRect || newGrid != hoveredLinkGrid else { return }
        if let previous = boxes[hoveredLinkGrid]?.contentLayer {
            previous.linkUnderline = nil
        }
        hoveredLinkRect = rect
        hoveredLinkGrid = newGrid
        if let rect, let layer = boxes[hoveredLinkGrid]?.contentLayer {
            layer.linkUnderline = rect
        }
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

    /// A resolved input target: the grid under a view point and the cell
    /// within it, plus the global cell the grid's frame puts it at (Lua
    /// helpers like the diagnostics query still speak global coordinates).
    struct GridHit {
        var grid: Int
        var row: Int
        var col: Int
        var globalRow: Int
        var globalCol: Int
    }

    /// View point → the grid and cell under it. Overlays are tested topmost
    /// first (the message grid, floats by z order — each only where nvim
    /// enabled the mouse), then the tiled window grids, then the global
    /// grid; a point over no laid-out cell falls back to the global grid
    /// clamped, so mouse events still land somewhere sane.
    func gridHit(forViewPoint point: CGPoint) -> GridHit? {
        guard let snapshot, let global = snapshot.grid, !global.isEmpty else { return nil }
        let cellSize = metrics.cellSize
        for gridId in boxOrder.reversed() {
            guard let box = boxes[gridId], !box.clipLayer.isHidden else { continue }
            let frame = snapshot.frames[gridId] ?? GridFrame(row: 0, col: 0)
            guard frame.mouseEnabled, let grid = snapshot.grids[gridId], !grid.isEmpty else {
                continue
            }
            var localY = point.y - Self.contentInset - box.contentLayer.originY
            if gridId == scrollLeadGrid {
                localY -= scrollPresentationOffset
            }
            let localX = point.x - leadingContentInset - CGFloat(frame.col) * cellSize.width
            let row = Int((localY / cellSize.height).rounded(.down))
            let col = Int((localX / cellSize.width).rounded(.down))
            guard row >= 0, col >= 0, row < grid.height, col < grid.width else { continue }
            return GridHit(
                grid: gridId,
                row: row,
                col: col,
                globalRow: frame.row + row,
                globalCol: frame.col + col
            )
        }
        let row = Self.gridRow(
            atY: point.y - Self.contentInset,
            gridHeight: global.height,
            cellHeight: cellSize.height
        )
        let col = min(max(Int((point.x - leadingContentInset) / cellSize.width), 0), global.width - 1)
        return GridHit(grid: 1, row: row, col: col, globalRow: row, globalCol: col)
    }

    // MARK: - Diagnostics popover

    /// A plain left click in the sign column (the gutter carrying the
    /// diagnostic signs): look up the clicked line's `vim.diagnostic` entries
    /// and show them in a native popover anchored at the clicked cell. A
    /// line without diagnostics falls back to a normal click, forwarded in
    /// the hit grid's own coordinates.
    func presentDiagnostics(at hit: GridHit) {
        let anchor = signColumnRect(globalRow: hit.globalRow, globalCol: hit.globalCol)
        let themeIsDark = Self.hasDarkBackground(snapshot?.defaultBackground)
        let grid = hit.grid
        let row = hit.row
        let col = hit.col
        Task { @MainActor in
            // The Lua lookup has no per-window grid API, so it still takes
            // the global cell.
            let items = (try? await model.client.lineDiagnostics(
                row: hit.globalRow, col: hit.globalCol
            )) ?? []
            guard !items.isEmpty else {
                model.inputDispatcher.send(.mouse(
                    button: "left", action: "press", modifier: "", grid: grid, row: row, col: col
                ))
                return
            }
            diagnosticPopover.present(
                items: items, relativeTo: anchor, of: self, themeIsDark: themeIsDark
            )
        }
    }

    /// View-space rect of the clicked gutter cell, two cells wide so the
    /// popover arrow centers on the sign slot. Anchored at the global cell,
    /// where the gutter actually sits.
    private func signColumnRect(globalRow: Int, globalCol: Int) -> CGRect {
        let cell = metrics.cellSize
        return CGRect(
            x: leadingContentInset + CGFloat(globalCol) * cell.width,
            y: Self.contentInset + globalRowY(globalRow),
            width: cell.width * 2,
            height: cell.height
        )
    }

    /// Global-grid y of a global row's top edge (cmdline gap on the last row).
    private func globalRowY(_ row: Int) -> CGFloat {
        Self.gridRowY(
            row,
            gridHeight: snapshot?.grid?.height ?? 0,
            cellHeight: metrics.cellSize.height
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
              let (box, rect) = preeditLayerRect(forCharacterRange: NSRange(
                  location: 0,
                  length: imeHandler.markedText.utf16.count
              )) else {
            if let previous { previous.layer.setNeedsDisplay(previous.rect) }
            return
        }
        box.contentLayer.preedit = GridContentLayer.Preedit(
            text: imeHandler.markedText,
            selection: imeHandler.markedSelection
        )
        var dirty = rect
        if let previous {
            if previous.layer === box.contentLayer {
                dirty = dirty.union(previous.rect)
            } else {
                previous.layer.setNeedsDisplay(previous.rect)
            }
        }
        box.contentLayer.setNeedsDisplay(dirty)
        lastPreedit = (box.contentLayer, rect)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
        if snapshot == nil {
            connectScreen()
        }
        // Place the grid boxes before anything can draw: the snapshot may
        // have arrived while this view was not yet in a window.
        updateBoxGeometry()
        updateStatuslineBar()
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
        updateBoxGeometry()
        updateStatuslineBar()
        for gridLayer in gridLayers {
            gridLayer.invalidateShaping()
            gridLayer.setNeedsDisplay()
        }
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
        updateBoxGeometry()
        updateStatuslineBar()
        updateCompletionPanel()
    }

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    }

    /// Fold a flush's dirty cells into the next apply. While one apply is
    /// queued, later flushes only accumulate their cells: the queued apply
    /// reads the newest snapshot, so the intermediate states it would have
    /// rendered are exactly the ones the next flush overwrites anyway.
    private func scheduleFlushApply(cellRects: [CellRect]) {
        pendingFlushRects.append(contentsOf: cellRects)
        guard !flushApplyScheduled else { return }
        flushApplyScheduled = true
        Task { [weak self] in
            await self?.applyPendingFlush()
        }
    }

    private func applyPendingFlush() async {
        while true {
            // Read the snapshot after the suspension, then drain the cells: any
            // flush that arrived while this task was starting is reflected in
            // the snapshot read next time round, never lost.
            let snapshot = await model.screen.snapshot()
            let cellRects = pendingFlushRects
            pendingFlushRects.removeAll(keepingCapacity: true)
            apply(snapshot: snapshot, cellRects: cellRects)
            // A flush handled while the snapshot was in flight may not be in
            // that snapshot; its cells are in `pendingFlushRects`, so paint
            // again from a fresh one. No suspension between this test and
            // clearing the flag, so a later flush cannot slip in unseen.
            guard !pendingFlushRects.isEmpty else {
                flushApplyScheduled = false
                return
            }
        }
    }

    private func apply(snapshot: ScreenSnapshot, cellRects: [CellRect]) {
        let previous = self.snapshot
        updateCursorGlide(previous: previous, next: snapshot)
        crossfadeThemeTransition(from: previous, to: snapshot)
        self.snapshot = snapshot
        syncGridBoxes(with: snapshot)
        for gridLayer in gridLayers {
            gridLayer.update(snapshot: snapshot)
            gridLayer.invalidate(cellRects: cellRects)
        }
        // A wheel confirmation's visual offset belongs to this repaint: swap
        // the one-line lead for the rows Neovim just painted in the same
        // frame, before the transform is ever committed on its own.
        scrollController.applyConfirmedOffset()
        updateBoxGeometry()
        refreshBackgroundColor()
        updateStatuslineBar()
        updateCompletionPanel()
        refreshWindowAppearance()
        reconcileGridSize(with: snapshot)
        refreshLinkHoverFromPointer(
            commandHeld: NSEvent.modifierFlags.contains(.command)
        )
    }

    /// Pull a fresh snapshot on every nvim flush (any grid's), then
    /// invalidate only the cells the flush dirtied. A flush's rects belong
    /// to its grid; each layer clamps them to itself.
    private func connectScreen() {
        let screen = model.screen
        Task { [weak self] in
            guard let self else { return }
            await screen.setFlushHandler { [weak self] grid, cellRects in
                guard let self else { return }
                Task { @MainActor in
                    self.scheduleFlushApply(cellRects: cellRects)
                }
            }
            await screen.setScrollHandler { [weak self] grid, rows, _ in
                guard let self, rows != 0 else { return }
                Task { @MainActor in
                    // Only the gesture's lead grid drives the smooth-scroll
                    // lead; other windows scrolling (e.g. `:windo`) confirm
                    // instantly instead.
                    guard grid == self.scrollLeadGrid else { return }
                    self.scrollController.confirmScroll(rows: rows)
                }
            }
            // nvim may have painted before this view was in a window; adopt the
            // current state now instead of waiting for the next flush.
            let snapshot = await screen.snapshot()
            guard snapshot.grid != nil else { return }
            self.snapshot = snapshot
            self.syncGridBoxes(with: snapshot)
            for gridLayer in self.gridLayers {
                gridLayer.update(snapshot: snapshot)
                gridLayer.setNeedsDisplay()
            }
            self.updateBoxGeometry()
            self.refreshBackgroundColor()
            self.updateStatuslineBar()
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

    /// Paint the statusline row with the opposite theme mode's default
    /// background, stretched to the full window width: themes pick statusline
    /// backgrounds nearly identical to the editor background (monokai pro
    /// dark: #2E323C on #26292C), so the row itself can't be told apart. The
    /// row above the global grid's last row is the statusline — the same
    /// layout the cmdline gap assumes (last row = cmdline area, `laststatus`
    /// >= 2). The bar sits below every grid box, and the global grid's
    /// statusline-row cells stay transparent so this fill shows through; the
    /// edges are snapped to the same pixels the grid layers snap their fills
    /// to.
    private func updateStatuslineBar() {
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
    /// the snapshot. The anchor cell is local to the popup's own grid (grid 1
    /// for an in-window menu, the anchor window's grid otherwise); nvim has
    /// already picked above/below the cursor, and the panel flips up when it
    /// would overflow the bottom edge and clamps inside the view horizontally.
    private func updateCompletionPanel() {
        guard let popup = snapshot?.popup, let grid = snapshot?.grid, !grid.isEmpty else {
            if !completionPanel.isHidden { completionPanel.isHidden = true }
            return
        }
        let size = completionPanel.update(
            popup,
            metrics: metrics,
            maxWidth: bounds.width - leadingContentInset - trailingContentInset
        )
        let cellWidth = metrics.cellSize.width
        let cellHeight = metrics.cellSize.height
        let anchorFrame = snapshot?.frames[popup.grid] ?? GridFrame(row: 0, col: 0)
        let anchorRow = anchorFrame.row + popup.row
        let anchorCol = anchorFrame.col + popup.col
        let anchorRowTop = Self.contentInset + Self.gridRowY(
            anchorRow, gridHeight: grid.height, cellHeight: cellHeight
        )
        let x = leadingContentInset + CGFloat(anchorCol) * cellWidth
        var y = anchorRowTop
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
    /// content layers adopt the new snapshot so the previous cell rect is
    /// still available as the glide origin. The glide stays inside the
    /// cursor's own grid — a cursor jumping between grids snaps.
    private func updateCursorGlide(previous: ScreenSnapshot?, next: ScreenSnapshot) {
        guard let previous,
              previous.cursor.grid == next.cursor.grid,
              previous.cursor != next.cursor,
              let box = boxes[next.cursor.grid],
              let oldRect = box.contentLayer.cursorRestRect(in: previous),
              let newRect = box.contentLayer.cursorRestRect(in: next) else {
            return
        }
        let distance = max(
            abs(next.cursor.row - previous.cursor.row),
            abs(next.cursor.col - previous.cursor.col)
        )
        cursorAnimator.glide(from: oldRect, to: newRect, distanceInCells: CGFloat(distance))
    }

}
