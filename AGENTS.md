# AGENTS.md — iNeovim

## Project overview

iNeovim is a native macOS desktop application written in Swift with SwiftUI. It embeds one
`nvim --embed` child process per window over msgpack-RPC and renders Neovim's linegrid +
multigrid protocol itself (Core Text + `CALayer`), with macOS-native input, smooth
scrolling, and an
app shell. Phases 1–8 of `docs/TASKS.md` are implemented: RPC, UI state, rendering, input,
scrolling, and the SwiftUI app shell (tabs, settings, menus, window title, file opening).
Phase 9 (polish and release) added crash recovery, performance baselines/signposts, an
app icon, the `com.mzevo` bundle identifier, the MIT license, and a documented
archive → notarize release flow (`docs/RELEASE.md`).

Key facts from `iNeovim.xcodeproj/project.pbxproj`:

- **Platform:** macOS only (`SUPPORTED_PLATFORMS = macosx`, `SUPPORTS_MACCATALYST = NO`).
  The iOS-orientation keys in the target settings are unused template leftovers.
- **Deployment target:** macOS 14 (`MACOSX_DEPLOYMENT_TARGET =
  "$(RECOMMENDED_MACOSX_DEPLOYMENT_TARGET)"`, which the macOS 27 SDK resolves to
  14.0; the `iNeovimTests` target still pins 14.6).
- **Created with:** Xcode 26.3 (`CreatedOnToolsVersion = 26.3`).
- **Swift:** `SWIFT_VERSION = 5.0`, approachable concurrency enabled
  (`SWIFT_APPROACHABLE_CONCURRENCY = YES`), default actor isolation is `MainActor`
  (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`).
- **Bundle:** display name `iNeovim`, category `public.app-category.developer-tools`,
  bundle ID `com.mzevo.<product>` (`com.mzevo.iNeovim`, tests `com.mzevo.iNeovimTests`;
  changed from the template placeholder in T9.4).
- **Capabilities:** App Sandbox **disabled** (`ENABLE_APP_SANDBOX = NO`) — the embedded
  `nvim` must execute a user-installed binary and read the user's config, plugins, and
  arbitrary project files, which the sandbox forbids. App Groups registered.
- **Versioning:** `MARKETING_VERSION = 1.0`, `CURRENT_PROJECT_VERSION = 1` — both live only
  in `project.pbxproj`. The Info.plist is generated (`GENERATE_INFOPLIST_FILE = YES`) and
  merged with the partial `Config/Info.plist`, which declares the document types the app
  can open (T8.6) and the `ineovim` URL scheme the command-line launcher uses.

## Repository layout

```
iNeovim/                  App sources (a PBXFileSystemSynchronizedRootGroup)
├── MyApp.swift           @main entry point: WindowGroup + Settings + menu commands
├── ContentView.swift     Window shell hosting the render view via NSViewRepresentable
├── AppDelegate.swift     NSApplicationDelegate: bootstrap, open-file requests, teardown
├── App/                  SwiftUI app shell (Phase 8)
│   ├── AppModel.swift        per-window session stack, command routing, file queues, title
│   ├── AppSettings.swift     persisted font/layout/input/animation settings
│   ├── SettingsView.swift    settings window
│   ├── SetupView.swift       first-run guidance when no nvim is installed
│   ├── EditorCommands.swift  File + Neovim menu commands
│   ├── DiagnosticsStore.swift  per-session aggregated LSP diagnostics
│   ├── ProblemsPanel.swift   docked non-modal issues sidebar
│   └── CommandLineTool.swift  installs the ineovim launcher into PATH
├── Logging.swift         os.Logger categories (rpc, render, input, app)
├── NvimDiscovery.swift   Locates the nvim binary and checks its version
├── NvimProcess.swift     Actor owning the nvim --embed child process
├── RPC/                  MessagePack codec and msgpack-RPC layer
│   ├── MsgPackValue.swift    msgpack value model
│   ├── MsgPackEncoder.swift  Value → bytes, canonical smallest markers
│   ├── MsgPackDecoder.swift  Incremental buffered decoder
│   ├── NvimHandle.swift      Buffer/Window/Tabpage ext-type handles
│   ├── RPCMessage.swift      msgpack-RPC frame parsing
│   ├── RPCError.swift        RPC error types
│   ├── RPCSession.swift      Actor: read loop, request matching, notifications
│   └── NvimClient.swift      Typed convenience API over RPCSession
├── UI/                   UI-protocol layer: redraw events and grid state (Phase 4)
│   ├── RedrawEvent.swift     typed `redraw` events + notification parser
│   ├── Highlight.swift       HlAttr highlight model, resolution, and store
│   ├── Grid.swift            cell storage with line/scroll/clear/resize ops
│   ├── ResizeController.swift  debounced view-resize → nvim_ui_try_resize
│   ├── Screen.swift            applied grid/highlight/mode/cursor state actor
│   └── RedrawEventStream.swift  single-consumer AsyncStream of redraw events
├── Render/               Core Text + CALayer rendering layer (Phase 5)
│   ├── FontMetrics.swift     NSFont → cell size/ascent/baseline metrics
│   ├── CellRenderer.swift    grid rows → styled runs for CTLine shaping
│   ├── GridContentLayer.swift  one grid's cells/cursor/preedit in a CALayer
│   │                           (one instance per displayed grid)
│   ├── TerminalView.swift    layer-backed NSView hosting the per-grid layers
│   ├── CompletionPanelView.swift  native ext_popupmenu completion list
│   ├── DiagnosticPopover.swift  native vim.diagnostic popover for gutter clicks
│   ├── LineContentPopover.swift  native full-line popover for truncated rows
│   ├── CursorBlinker.swift   cursor blink timing (wait/on/off)
│   └── NSColor+PackedRGB.swift  0xRRGGBB ↔ NSColor helpers
├── Input/                keyboard/mouse translation layer (Phase 6)
│   ├── KeyInputHandler.swift  keyDown → nvim key notation, special-key table
│   ├── InputSettings.swift    passCmdKeysThrough / optionAsMeta switches
│   ├── IMEHandler.swift       marked text state + NSTextInputClient
│   ├── MouseHandler.swift     press/drag/release → nvim_input_mouse
│   ├── LinkDetector.swift     http(s) URL hit-testing for ⌘-click
│   ├── InputEvent.swift       the unified input event enum
│   └── InputDispatcher.swift  single-consumer stream into NvimClient
├── Scroll/               smooth scrolling and animation (Phase 7)
│   ├── ScrollAccumulator.swift  pixel↔whole-line bookkeeping (pure, testable)
│   ├── ScrollController.swift   scrollWheel events → offsets + wheel requests
│   ├── ScrollAnimator.swift     display-link offset chase (settle/glide)
│   ├── CursorAnimator.swift     cursor glide between cells (~80 ms)
│   ├── ScrollAnimationSettings.swift  shared durations/thresholds knobs
│   ├── DisplayLinkDriver.swift  CVDisplayLink → Swift closure trampoline
│   └── ScrollIndicator.swift    transient overlay scrollbar while scrolling
├── TerminalPane/         native Ghostty terminal pane (see design decisions)
│   ├── EditorSplitView.swift    editor|divider|pane container, pane intents
│   ├── TerminalPaneView.swift   pane header + surface lifecycle
│   └── GhosttyTerminalController.swift  process-wide Ghostty.App, config, surfaces
└── Assets.xcassets/      AccentColor colorset + AppIcon.appiconset (T9.3)
Packages/GhosttySupport/  Local Swift package wrapping the self-built
                          GhosttyKit xcframework (Vendor/) and the adapted
                          libghostty Swift bindings (Sources/); see its
                          ADAPTATION.md for provenance and pruning notes
Scripts/                  One-off tooling (app-icon generator) and the release
                          pipeline (publish.sh); not part of the build
iNeovimTests/             XCTest target (synchronized group); codec round-trip,
                          redraw-parsing, settings/model, and embedded-nvim tests
Config/Info.plist         Partial Info.plist merged into the generated one
                          (document types, ineovim URL scheme); outside the
                          synchronized group
Config/ExportOptions.plist  developer-id export options (T9.6)
docs/                     TASKS, VERIFICATION, PERFORMANCE, RELEASE, screenshots/
iNeovim.xcodeproj/        iNeovim app + iNeovimTests unit test targets
```

Important: the `iNeovim` folder is registered as a **file-system-synchronized group**, so
any `.swift` file added to that directory is automatically part of the target — no
`project.pbxproj` edit is needed when adding or removing source files. Files outside that
folder are not compiled.

## Build and run

- There is no `Package.swift`, no Makefile, no CI configuration, and no build scripts
  other than the release pipeline in `Scripts/publish.sh`.
  Building is done in **Xcode** (open `iNeovim.xcodeproj`, target `iNeovim`, Debug/Release).
- **Do not run `xcodebuild` or `swift build` as part of routine changes** — the project
  owner verifies builds manually in Xcode. When delivering a change, make sure the Swift
  code is correct and list the changed points; do not claim the app "builds" unless you
  were explicitly asked to compile and did.
- Command-line build (only when explicitly requested):
  `xcodebuild -project iNeovim.xcodeproj -scheme iNeovim -configuration Debug build`

## Testing

Tests live in the synchronized `iNeovimTests/` group (target `iNeovimTests`, wired
against the app as its test host). Follow the existing XCTest style when adding
tests. Note that app sources compile with `MainActor` default isolation, so test
classes exercising them are annotated `@MainActor`.

SwiftUI `#Preview` (and `#Playground`) macros in `ContentView.swift` are the existing
mechanism for interactive visual verification. `EmbeddedTerminalTests` is an integration
check that starts `:terminal` in the embedded nvim and skips when nvim is unavailable;
`docs/VERIFICATION.md` lists the manual GUI checks.

## Code style guidelines

- Swift + SwiftUI, Xcode-default formatting (4-space indentation, as produced by the
  Xcode template).
- Views are structs conforming to `View`; app entry uses the `@main` `App` protocol.
- Because `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, code is main-actor isolated by
  default — mark explicitly when opting out, and prefer Swift concurrency
  (`async`/`await`, actors) over GCD for new code.
- Match the terse template style: no header comments, no doc comments unless the API
  genuinely needs explanation.
- Keep source files under the synchronized `iNeovim/` group; name types after their file
  (e.g. `MyApp.swift` → `MyApp`).

## Design decisions

- **Window chrome follows the nvim theme:** nvim's default background
  (reported at attach and re-reported on every `:colorscheme` change via
  `default_colors_set`) drives the window's `preferredColorScheme` — luma
  < 0.5 maps to dark, otherwise light, and an unset background follows the
  system. The titlebar, traffic lights, title text, and the adaptive
  fallback colors then match the editor instead of the OS mode. Do not set
  `NSWindow.appearance` directly: the hosting WindowGroup resets it on its
  next update pass. A fresh window is *born* in the system appearance and
  SwiftUI orders it front, fully opaque, before
  `TerminalView.viewDidMoveToWindow` / `AppModel.attach` can set
  `alphaValue` to 0 (measured with a ⌘N screen capture: at attach the new
  window was already `visible=true alpha=1.0 appr=Aqua` and stayed light
  ~160 ms until nvim reported). No post-creation hook can hide those frames;
  the only lever is to give the window the right scheme at `init`. So every
  model — not just a tab — is seeded with a scheme and packed background:
  the requesting tab's (`pendingThemeSeed` / `pendingBackgroundSeed`), else
  the active session's (`AppModel.active`), else the last value any session
  reported, persisted in UserDefaults (`lastThemeIsDark` /
  `lastDefaultBackground`). A pre-report `nil` from
  `refreshWindowAppearance` must not clear that seed — `setThemeIsDark`
  ignores it until a snapshot actually carries a scheme — or the window
  reverts to the system appearance and flashes again. The adaptive fallback
  background is a dynamic `NSColor` whose `cgColor` conversion bakes in the
  appearance current at call time; `TerminalView` resolves it under the
  seeded theme (`resolvedBackgroundColor(themeIsDark:)`), and
  `ContentView`'s window backdrop uses the same seed (`seededBackground`)
  until nvim reports, then prefers the reported `terminalColors.background`
  so transparent chrome (the terminal pane header, the splitters) follows a
  `:colorscheme` flip instead of holding the window's original theme and
  neither the AppKit surface nor the SwiftUI layer behind it shows a
  light frame. A native tab additionally joins the requesting window's
  group in `AppDelegate.registerEditorWindow`, waiting (`joinTabWhenThemed`)
  with the window invisible until its `effectiveAppearance` matches the seed
  so it appears already themed. Do not fade a *visible* standalone window
  over the group and join later: a standalone window has no tab bar, so the
  chrome changes mid-transition and the grid jumps vertically when the
  deferred join shifts the content down. A plain window (⌘N / first launch)
  installs at `alphaValue` 0 and `AppModel.revealWindow` fades it in
  (0.25 s) on the first report — bootstrap failures and a 1.5 s timeout
  backstop it; `revealWindow` also waits (bounded) for `effectiveAppearance`
  to take the reported scheme and pins `window.appearance` before the fade.
  The first launch after a fresh install has no persisted seed, so only that
  one window can still flash; every window after it is seeded. A
  `:colorscheme` flip on a shown window crossfades via
  `TerminalView.crossfadeThemeTransition`: the old rendering is snapshotted
  and faded out (0.25 s) over the redrawn content; on a first paint the
  seen mode falls back to the seeded theme and then to the window's
  effective appearance. The snapshot lives in an AppKit subview, so it needs
  the same `zPosition` lift as the completion panel (`syncGridBoxes` re-stacks
  it above every grid box); with the default 0 the window grids composite
  over it and only the base grid fades.
- **New-tab first paint:** `ui_attach` uses the view's real grid size
  (`AppModel.pendingGridSize`, reported from `TerminalView.requestResize`
  as the window lays out) instead of a placeholder 80x24. The placeholder
  would be drawn first and then resized a debounce interval later, so a new
  tab appeared to wipe in from the top; attaching at the target size paints
  the first frame full. `AppModel.attach` also sets
  `window.animationBehavior = .none` so AppKit contributes no order-in or
  tab-bar-entrance motion on top of the redraw. The 80x24 fallback only
  applies if bootstrap beats the first layout.
- **Content inset & cmdline gap:** the grid is inset
  `TerminalView.contentInset` (6 pt) above and below, the user's
  `leadingPadding` on the left and `trailingPadding` on the right (Settings ▸
  Layout; defaults 4 pt and 12 pt) — the trailing value is clamped to
  `TerminalView.minimumTrailingPadding`, which reserves the transient scroll
  thumb that hugs the window's right edge
  (`ScrollIndicator` width plus `rightInset`), a 2 pt gap to it, and the
  gutter shift buffer text carries (see "Gutter-to-text padding" below) — and
  the last grid row (nvim's cmdline/message area) is drawn
  `TerminalView.cmdlineGap` (5 pt) below the
  row above it, so the statusline and the cmdline never touch. Every grid
  cell-count computation (`ResizeController.cellCount` via
  `TerminalView.gridAreaSize`) derives from the inset- and gap-adjusted size,
  never the raw bounds — otherwise the floor-rounded grid fills the view edge
  to edge and the last line hugs — or, while resizes race, overflows — the
  window's bottom edge. All view-space→grid-space conversions (mouse
  `MouseHandler`, wheel pointer `ScrollController`, IME preedit rects) subtract
  the leading inset, and row↔y math everywhere goes through
  `TerminalView.gridRowY`/`gridRow(atY:)` so the gap stays consistent. Pointer
  hit-testing (`MouseHandler`, link hover, wheel targeting) goes through
  `TerminalView.gridHit(forViewPoint:)`, which resolves the topmost
  mouse-enabled grid under the point — the message grid, floats by z order,
  then window grids, then grid 1 — returns grid-local row/col plus the global
  cell the frame puts it at, and subtracts the live scroll lead for points in
  the lead grid (the only one that visually moves mid-gesture).
- **Gutter-to-text padding:** nvim's gutter (sign, fold, and number columns)
  is whole cells wide, so the extra 2 pt of air the buffer text needs between
  itself and the gutter cannot come from an option; the renderer draws a text
  region's glyphs `NvimTextLayout.textShift` (2 pt) right of their cell
  origins instead. The gutter, the statusline row, and the cmdline row are
  outside every region and stay on the grid, and a window with no gutter
  (`textoff` 0) reports no region — its text starts at the leading inset with
  nothing to clear. Cell backgrounds, the statusline bar, and all hit-testing
  stay on cell origins; only glyphs, the block cursor, the cursor glyph reuse,
  the IME preedit, and the ⌘-hover underline carry the shift, which is why the
  layers and the scroll clip are `textShift` wider (a shifted last column must
  not be clipped) and the trailing inset reserves the shift again. nvim
  reports each window's text area — its rows plus the columns past `textoff`,
  from `getwininfo` in global grid coordinates, floats excluded — as
  `ineovim:textlayout` notifications. `textoff` changes with options
  (`number`, `signcolumn`, …) but also when a language server or plugin places
  signs, which fire no autocmd (`signcolumn=auto` collapsing is the everyday
  case), so `NvimClient.installTextLayoutHook` re-checks the layout from a
  decoration provider's `on_start` — the only callback that sees every
  redraw — and pushes only when the collected layout changed. The provider
  may only schedule work (the docs call anything but `vim.rpcnotify`
  experimental), so the scan runs from `vim.schedule` plus a 100 ms
  `vim.defer_fn`, with a pending flag collapsing a scrolling frame burst.
  A run shifts as a whole by its first cell, because `GridContentLayer`'s
  pinned glyph groups are shaped and cached without an offset; a run spanning
  the gutter boundary only happens when both share one highlight, and then it
  keeps the gutter's alignment.
- **Soft wrap:** `NvimClient.installWrap` sets `wrap` in every window and
  as the global default before `ui_attach`, so the first full screen is
  already wrapped instead of reflowing after the paint. An embedded nvim
  does not finish startup until the UI attaches: bootstrap's RPC commands
  run before `init.lua` is sourced (measured: `vim.v.vim_did_enter == 0`
  and no scripts loaded when they execute), so a plain `set wrap` is
  undone by a user config's `set nowrap` moments later. While startup is
  still in flight the setting is therefore applied again from a one-shot
  `VimEnter` autocmd, the last startup event. (Any other option
  bootstrap must own needs the same treatment.) The app offers no
  horizontal scrolling (the wheel's horizontal deltas are ignored; vertical
  smooth-scrolling only), so a clipped tail would be unreachable. Wrapping is
  nvim's, not the renderer's: continuation rows arrive as ordinary `grid_line`s
  and nvim leaves the number column blank on them, so a buffer line keeps
  exactly one number. Any screen-row→buffer-line math must therefore use
  `screenpos` (see the gutter diagnostics popover below), because one
  line can cover several rows.
- **Truncated long lines:** lines whose display width exceeds 280 cells
  (`vim.fn.strwidth`) collapse to a ONE-ROW preview ending in
  `…`, and clicking the preview row opens the full line in
  `LineContentPopover`. The feature REQUIRES nvim 0.13+
  (`NvimClient.truncatedLinesLua` gates on `vim.version()` and returns
  false below): on 0.12 the feature's own extmark layout freezes upward
  scrolling — with `conceal_lines` runs plus the `virt_lines_above`
  preview mark, the topline LOOPS (measured on 0.12.5: 37→35→37 forever,
  wheel-up included, so every line above the run is unreachable;
  upstream neovim#42317, fixed only on master by #42480 for 0.13,
  and #42077's wider stuck/scrolls-down behavior is still open; 0.12.6
  predates both). Re-anchoring previews below the run's predecessor or
  dropping "n" from 'concealcursor' removes only the hard loop, not the
  row miscounts (measured). On gated nvim the hook stays off entirely:
  over-long lines keep their normal wrapped rows and scrolling works.
  Implemented nvim-side (`NvimClient.installTruncatedLines`,
  idempotent via `_G.ineovim_trunc`), not in the renderer: a `conceal_lines`
  extmark hides the whole line INCLUDING its wrap rows, and ONE `virt_lines`
  extmark per run carries the run's previews as a multi-row list (attached to
  the FIRST unconcealed line after the run with `virt_lines_above` — marks
  attached to a concealed line are swallowed with it, and separate
  same-anchor marks do NOT draw in creation order: the first lands topmost
  and the rest in reverse, scrambling runs of three or more). A run that
  reaches the buffer's LAST line has no following line to hang above, so its
  previews instead hang BELOW the last unconcealed line before the run —
  they land right after that line's (possibly wrapped) rows, exactly where
  the concealed run sat; a below-mark on the concealed last line itself is
  swallowed (measured on 0.12), and a run covering the WHOLE buffer (first
  AND last line over-long) stays unconcealed rather than blanking the
  buffer. Each preview
  takes exactly one grid row, because virt lines
  never wrap. Measured on nvim 0.12: `conceal_lines` collapses ONLY at
  `conceallevel` 2 (0 and 1 leave the line drawn), and the cursor's own line
  unfolds unless `concealcursor` includes the mode — both options are owned
  like `wrap` (`conceallevel` 2, `concealcursor` "nv" so reading keeps a
  line folded with the cursor on it while insert mode reveals it for
  editing; global + every window + rescan re-apply). The
  preview text is the longest char-prefix fitting `winwidth - textoff - 1`
  cells plus the ellipsis (char-wise walk; Lua string slices are byte-based).
  Rescans run on buffer/enter/text-change/resize autocmds with a full-buffer
  width scan — fine for code files, a future optimization if huge buffers
  feel sluggish in insert. Plain left clicks (outside the gutter) ask
  `NvimClient.lineFullContent(row:col:)` for the clicked row's line: the Lua
  walks the registered lines and locates each preview by run shape —
  mid-buffer runs use `screenpos(run_end + 1, 1).row - (run_end - lnum)`;
  last-line runs use the predecessor's LAST byte (`screenpos(run_start - 1,
  #pred).row + 1 + (lnum - run_start)`, so a wrapped predecessor counts
  from its bottom row) — and returns the full
  text (nil elsewhere). The click itself still reaches nvim first, so the
  cursor may land on a neighboring real line — the popover is the reading
  path, `j`/`k` still traverse the hidden lines. Concealing is
  buffer-global: every split showing the buffer truncates, previews sized
  for the rescanning window clip in narrower ones, and the scroll
  indicator's visible-lines metric drifts by the run's hidden rows.
- **Full-width statusline bar:** the statusline row (the one above the cmdline
  row) gets a backdrop layer (`TerminalView.statuslineLayer`, below the grid
  layers) filled with the OPPOSITE theme mode's default background — a
  dark editor draws the light default (#E0E2EA), a light editor the dark
  default (#14161B), probed from nvim 0.12.5's built-in colorscheme — from
  window edge to window edge, so the bar runs full width while the cells stay
  inset and stays visible against dark themes, whose own statusline background
  is nearly indistinguishable from the editor background (monokai pro dark:
  #2E323C on #26292C). The bar composites at 75% opacity
  (`TerminalView.statuslineBarOpacity`), blending toward the editor background
  — the user found the full-strength inversion glaring at night. The global
  grid's layer skips per-run background fills on that row and draws its text
  in the opposite mode's default foreground — the theme's statusline text
  matches its editor background and would vanish on the inverted bar. An
  unknown nvim background (nil) follows the window appearance.
  `updateStatuslineBar()` keeps its frame/color in sync from the flush,
  initial-snapshot, metrics-, resize-, and appearance-change paths; like the
  cmdline gap it assumes the last row is the cmdline area and the row above it
  the statusline (`laststatus` >= 2, `cmdheight` 1) — EXCEPT while a
  message block rails the screen: a visible message grid whose `msg_set_pos`
  rows reach the statusline row (cmdline errors + the hit-enter prompt)
  suppresses the bar and the row's inverted text
  (`ScreenSnapshot.messageGridCovers`, consulted by `updateStatuslineBar` and
  `GridContentLayer.effectiveStatuslineRow`, which also invalidates the row
  when the coverage flips without grid 1 receiving dirty rects); otherwise
  the inverted bar painted a stray full-width band behind
  `E…: Command failed`.
- **Message-grid re-parking:** after a hit-enter prompt is dismissed,
  nvim 0.12 sends ONE flush that moves the message grid onto the cmdline row
  (`msg_set_pos [grid, H-1, false, …]`) and clears only its row 0 with
  blanks; rows 1+ keep their stale cells and never get cleared (identical
  with `-u NONE` and real configs). The app therefore renders that parked
  grid like any other grid — blank row 0 draws nothing — and must not
  trust the move's dirty rects alone: `GridContentLayer.update` fully
  invalidates itself whenever its `GridFrame` changes (and `contentsGravity`
  is pinned to `.topLeft`), so a stale backing store can neither linger at
  the new position nor squash into shrunken bounds as a ghost message band.
  `draw(in:)` also caps its row loop to the same visible band as the bounds:
  without that cap, stale row 1 loses the cmdline gap in the beyond-screen y
  math and lands back inside the one-row bounds, repainting the old error as
  a red strip even though its backing store was invalidated.
- **Vertical separator cleanup:** nvim paints vsplit separators into the
  global grid but does not erase separators that disappear when a window
  closes, moves, or is resized (closing NERDTree otherwise leaves a vertical
  line). `Screen` records the separator cells required by the last flush's
  window layout; after position, size, visibility, or close events it
  reconciles once at the flush against the final layout, clears only stale
  cells to default blanks, and marks grid 1 dirty. A separator is required at
  `frame.col - 1` for every visible, non-float, non-message window grid with
  `frame.col > 0`, over that window grid's rows, so separators used by other
  splits survive the cleanup. A separator drag resizes the window one column
  per mouse event and nvim leaves a separator at every intermediate column;
  when redraw batches coalesce, the frames only show the edge before and after
  a burst, and a fast back-and-forth drag can sweep outside both endpoints.
  The cleanup therefore does not try to reconstruct the crossed columns from
  the frames: grid 1's tiled-window rows hold nothing but separators, so it
  clears every `│` there that the current layout does not require (the glyph
  is learned from a required separator cell because `'fillchars'` can change
  it). Without that sweep, dragging the sidebar divider left the whole pane
  striped with vertical bars. The divider is also no longer draggable:
  `MouseHandler` swallows a left press on the separator column immediately to
  the right of a window pinned to the screen's left edge
  (`ScreenSnapshot.isSidebarSeparator`), so nvim never starts the sidebar
  resize in the first place. Interior split dividers stay draggable.
  The same reconcile pass also clears the global grid under every visible
  tiled window's text rectangle: nvim draws each window's statusline into the
  global grid (not the window's own grid), and when a split closes the
  surviving window grows over the row that held its old statusline — which
  nvim never clears. The window grids leave default-background cells
  transparent, so the stale statusline showed through the buffer text
  (closing a quickfix split printed the old statusline across the middle of
  the file). Inside a window's rectangle the window's own grid is the only
  owner (gutter, text, and winbar all live there), so any non-blank global
  cell found there after a layout change is stale by construction.
- **ext_multigrid layering:** nvim attaches with `ext_linegrid`,
  `ext_popupmenu`, AND `ext_multigrid` (AppModel.bootstrap). Grid 1 stays the
  GLOBAL grid — the screen background, vsplit separators, the statusline row,
  and the message-area fill — while every window, float, and the
  message/cmdline area arrive as their OWN grid (`grid_resize` +
  `win_pos`/`win_float_pos`/`msg_set_pos`) laid out in grid-1 coordinates.
  `Screen` stores that layout per grid in `frames: [Int: GridFrame]` (position,
  hidden, isFloat/isMessage, mouseEnabled, zindex/compindex, `win_viewport`
  metrics) and ships it inside every `ScreenSnapshot` next to `grids:
  [Int: Grid]`. `TerminalView` keeps one `GridBox` (a clip layer plus a
  `GridContentLayer`) per displayed grid: `syncGridBoxes(with:)` reconciles
  the box set and z order (base < window grids < floats and the message grid
  by zindex/compindex) on every applied snapshot, and `updateBoxGeometry()`
  places each box at its frame's global position. The cmdline gap belongs to
  the GLOBAL last row: `GridContentLayer` computes row y from the frame's
  global offset, so a grid reaching the last row (grid 1 itself, the message
  grid) carries the gap in its own row math and window grids never do. A grid
  taller than the visible band (the message grid's capacity is a full screen)
  draws only the visible band. The smooth-scroll lead binds to ONE grid — the
  one the gesture grabbed (`ScrollController` resolves the hit per event and
  calls `TerminalView.setScrollLead`); only that box translates mid-gesture
  only that box translates mid-gesture and only its `grid_scroll`
  confirmations collapse the lead (other grids' scrolls are ignored, so
  `:windo`-style scrolling never smears). The cursor,
  the IME preedit, and the cursor glide live entirely on the cursor grid's
  layer — a cursor jumping between grids snaps instead of gliding.
  `ineovim:textlayout` regions stay in global coordinates; each layer maps its
  local cells through its frame before the gutter-shift lookup. nvim has no
  window→grid Lua API, so the diagnostics lookup and `reloadChangedFile` keep
  taking GLOBAL coordinates (`GridHit.globalRow/GlobalCol`) while
  `nvim_input_mouse` gets the grid-local ones.
- **RPC read path:** nvim's stdout is drained by a dedicated blocking-read
  thread (POSIX `read(2)` loop → `AsyncStream<Data>` → a single consumer task
  feeding `RPCSession.feed`), **not** by `FileHandle.readabilityHandler` (can
  drop wakeups for large bursts under GUI load) and **not** via
  `FileHandle.read(upToCount:)` (it accumulates until the full count or EOF —
  a 64 KB request against nvim's smaller bursts hangs the session at the
  handshake). With readabilityHandler, whole `redraw` notifications went
  missing: the screen kept stale rows after `:edit`, and every later nvim
  delta compounded the damage because nvim believed the UI had already seen
  the missing rows. A raw blocking read cannot miss bytes that were written
  to the pipe. Big redraw batches (>10 grid_line tuples) are logged at notice
  level in `RPCSession.handleMessage` so any recurrence is visible in the
  unified log
  (`log show --predicate 'subsystem == "com.mzevo.iNeovim"'`).
- **Redraw wire shapes:** `redraw` params arrive in two forms: pre-0.10 nvim
  sends one argument holding the whole batch (an array of event arrays);
  0.10+ sends each event array (`["grid_line", tuple, …]`) as its own
  argument — including a single-argument flush where one big event (e.g. the
  full-screen `grid_line` after `:edit`) is sent alone with a string head.
  `RedrawEvent.parseNotification` must distinguish them by whether
  `params[0].first` is itself an array; treating every single-argument
  notification as the pre-0.10 shape silently parses the whole-screen
  baseline to zero events and leaves stale rows.
- **Child-process environment:** nvim is spawned with an augmented PATH —
  the GUI PATH omits version managers (rbenv/asdf) and Homebrew, so tools
  nvim spawns (LSP servers, formatters) silently fell back to system
  binaries: a `ruby-lsp` resolved to the system Ruby 2.6 and died against a
  modern Gemfile. `NvimProcess.augmentedEnvironment()` prepends
  `~/.rbenv/shims`, `~/.asdf/shims`, `~/.local/bin`, `/opt/homebrew/bin`,
  and `/usr/local/bin` (inherited PATH kept at the end). The same GUI-PATH
  limitation is why `NvimDiscovery` probes absolute Homebrew paths instead
  of relying on PATH.
- **fzf tree-walk guard:** typed cmdline input is funneled through
  `TerminalView.sendKeys`, which accumulates the command text while nvim
  reports cmdline mode (`TerminalView.isCmdlineMode`: nvim's UI protocol
  sends `cmdline_normal`/`cmdline_insert`/`cmdline_replace`, never
  `mode()`'s short `"c"` — keying on the short form silently disabled
  both gates until it was caught in the Ghostty-pane work) and, on Enter,
  matches it against the tree-walking fzf.vim commands (`FZF`, `Files`,
  `Ag`, `Rg`, `RGrep`, `LGrep`). In `/` or `$HOME` the Enter is held while
  an `NSAlert` asks whether to run anyway (Cancel sends `<Esc>` instead) —
  walking either tree has frozen the machine (625k+ entries under `$HOME`).
  Commands triggered by mappings/plugins bypass the cmdline and are not
  gated.
- **Key repeat over press-and-hold:** printable keys reach nvim through the
  text input system (the `keyDown` → `interpretKeyEvents` path), where macOS
  "press and hold" (the accent popup) replaces system key repeat — letters
  without accent alternates (j, k, …) get no repeats at all. At launch the
  app persists `ApplePressAndHoldEnabled = false` in its own defaults domain
  (the standard terminal-emulator opt-out), skipping the write when the user
  has set the key explicitly in the app or global domain. Named keys (arrows,
  Esc, …) bypass the text input system and repeat regardless.
- **Native completion panel (ext_popupmenu):** the UI attaches with
  `ext_popupmenu: true`, so nvim stops drawing the popupmenu into the grid
  and sends `popupmenu_show/select/hide` instead. `Screen` keeps a
  `PopupState` (items, selected, anchor row/col) surfaced through
  `ScreenSnapshot.popup`; `TerminalView.updateCompletionPanel()` places
  `CompletionPanelView` (vibrancy-backed AppKit list, row cap 50, every row
  shown — the panel sizes to fit the list and never scrolls) at the anchor
  cell — flipping up when it would overflow the bottom edge — from the
  flush, initial-snapshot, metrics-, and resize
  paths. Keyboard navigation stays with nvim (`popupmenu_select` updates the
  panel); row clicks call `nvim_select_popupmenu_item`. The panel is the
  only completion UI while attached — there is no in-grid fallback. The panel
  is an AppKit subview, while every grid box is a raw sublayer carrying
  `zPosition` 0…n; composition sorts by `zPosition`, so
  `syncGridBoxes` lifts the panel above the highest box — without that, the
  buffer's window grid paints its text straight across the menu. Hover /
  signature-help floats render as float grids (`win_float_pos`) like any
  other floating window; they are grid content, not native panels, but they
  place, layer, and hit-test correctly through the ext_multigrid machinery.
- **⌘-click opens URLs:** `MouseHandler.mouseDown` intercepts a left click
  carrying Command before anything reaches nvim: it hit-tests the clicked grid
  cell against the rendered snapshot via `TerminalView.linkTarget` and
  `LinkDetector`, and hands an `http(s)` URL to `NSWorkspace.shared.open`.
  `LinkDetector` is pure (grid row cells + column → `URL?`): it joins the row's
  non-blank cells into a token, finds the first `http://`/`https://`, cuts the
  body at the first non-URL character (so adjacent CJK or prose needs no
  separating space), and trims wrapping punctuation while keeping balanced
  parentheses (`…/Foo_(bar)`). A click on the empty continuation cell of a
  double-width glyph resolves against the glyph cell before it. The gesture
  sets `isSwallowingGesture`, so nvim never sees the press — or an orphaned
  drag/release. A ⌘-click that is not on a URL still falls through to normal
  mouse handling.
- **⌘-hover underlines links:** while Command is held, an `NSTrackingArea` on
  `TerminalView` (`.mouseMoved` / `.mouseEnteredAndExited`, `activeInKeyWindow`,
  `inVisibleRect`, with `window.acceptsMouseMovedEvents`) re-detects the link
  under the pointer on every move; `flagsChanged` re-detects when Command is
  pressed or released without a move, and a flush re-detects so a scroll or
  redraw cannot leave the underline on the wrong row. `LinkHit.columns` (the
  cell range `LinkDetector` already computes for the click) is stored on both
  `GridContentLayer`s as `linkUnderline` and drawn as a line at the font's
  underline position in the cells' own foreground — so the underline lives in
  the scrolling layer and follows a scroll lead — and the pointer becomes
  `NSCursor.pointingHand`. Both are cleared on `mouseExited`, Command release,
  and when the pointer leaves a link.
- **Sign-column diagnostics popover:** a plain left click in the gutter
  (grid columns 0–1, where LSP signs such as gopls' "E" render) opens a
  native popover listing that line's `vim.diagnostic` entries — severity
  dot, selectable message, `source · code` — anchored at the clicked cell,
  with its appearance following the nvim theme. The click is intercepted in
  `MouseHandler` before `nvim_input_mouse`: `TerminalView` asks nvim via
  `nvim_exec_lua` (`NvimClient.lineDiagnostics`) to map the screen row to a
  buffer line — across splits, using `getwininfo` window rects in global
  grid coordinates, and `screenpos` because a wrapped line covers several
  rows — and to collect the diagnostics. An empty result (clean
  line, non-text row, or an nvim without `vim.diagnostic`, guarded by
  pcall) forwards the original press, so behavior outside the feature is
  unchanged. The rest of the intercepted gesture (drag/release) is always
  swallowed so nvim never sees orphan events. The popover sizes its message
  labels from the labels' own cells (`cellSize(forBounds:)`), not from
  `NSString.size(withAttributes:)`/`boundingRect`: the cell insets its text
  by 2 pt per side, so a message that only just fits measured one line wide
  and wrapped its last word onto a second line that the old bounding-rect
  height did not reserve — the popover showed "E302 expected 2 blank lines,
  found " with the count clipped. Width comes from the cell's single-line
  size (clamped 220…440 pt), height from the same cell at that width. The
  popover is a transient
  `NSPopover` (click-outside dismissal); typing or scrolling closes it too.
- **Problems panel (LSP diagnostics):** the app listens to every language
  server through one nvim-side hook, not per-language plumbing. At bootstrap
  `NvimClient.installDiagnosticsHook` execs Lua that registers
  `DiagnosticChanged` (plus `BufUnload`/`BufWipeout`) autocmds; each event
  re-collects the full per-buffer snapshot via `vim.diagnostic.get` and
  `vim.rpcnotify`s it to the attached UI channel as `ineovim:diagnostics`
  (`NvimDiagnosticUpdate.parse` decodes it; nvim's msgpack encoder drops
  nil-valued map keys, so parsing tolerates missing fields). nvim 0.12
  fires `DiagnosticChanged` even when `vim.diagnostic.set` gets an empty
  list — that is how the app learns a buffer went clean (probed against
  0.12.5 with the repo's own codec). `DiagnosticsStore` (one per session)
  aggregates the snapshots and feeds the native `ProblemsPanelController`,
  a non-modal issues sidebar docked at the window's left edge like Xcode's
  issue navigator (`EditorSplitView`: panel | editor | divider | terminal
  pane). The list live-updates while shown and lists every severity —
  errors and warnings at full strength, info/hint dimmed, with per-severity
  counts in the header. Each row is two lines: the message (newlines folded
  to spaces) wraps to the panel's width above a dimmed `file:line`, because
  the sidebar is narrow and a tail-truncated compiler message hides the part
  that matters ("… found 1" ending at "found "). Rows are hand-laid out by
  `ProblemsRowView` and the data source measures each height at the column
  width, so dragging the panel divider re-wraps every message instead of
  clipping it. Selecting a row jumps the editor
  (`:edit` when the path differs from the current buffer →
  `nvim_win_set_cursor`) and the panel keeps focus, so the arrow keys walk
  the list. The panel is created once per window and stays subscribed while
  hidden. It opens only on demand — ⌘P or the Neovim menu's "Toggle
  Problems" — and closes via the header ✕ or the same toggle; nothing pops
  it open automatically and no settings gate exists. The ⌘P chord is claimed
  by the same `AppDelegate` keyDown monitor as ⌘D and ⌘L/⌘R: SwiftUI registers
  the ⌘P menu equivalent but never fires it (a bare AppKit item with the
  same registration does match a real keypress), so the monitor does the
  work and the menu entry is display-only.
- **Command-line tool (Neovim ▸ Install Command Line Tool…):** writes an
  `ineovim` shell script into the first of `~/.local/bin`, `/opt/homebrew/bin`,
  `/usr/local/bin` that the user's login shell PATH actually contains —
  `CommandLineTool.loginShellPath` asks `$SHELL -l -c` because a GUI app
  inherits launchd's minimal PATH (zsh only reads `.zprofile` for a login
  shell, where Homebrew and user-bin entries usually live). A `~/.local/bin`
  on PATH is used even when it does not exist yet (it is created); when none
  of the candidates is on PATH the script still lands in `~/.local/bin` and
  the success alert shows the `export PATH=…` line to add. A directory the
  user cannot write (typically `/usr/local/bin`) asks first, then elevates
  through Standard Additions (`do shell script … with administrator
  privileges`), passing the script as base64 so no quoting layer sees its
  contents; a cancelled auth prompt (-128) is silent. The normal path does
  not use `open -a`: the launcher sends `ineovim://open?payload=…` (scheme
  declared in `Config/Info.plist`), which carries the shell's `$PWD` — a
  file open cannot say which directory the command ran in. The payload is
  base64url over NUL-terminated UTF-8 components (shell directory first,
  then each argument), so spaces, newlines, and non-ASCII names survive;
  `CommandLineTool.openRequest(from:)` resolves relative arguments against
  the shell's directory and then takes the window's directory from the
  arguments: the first path's parent (or the path itself when it is a
  directory), or the shell's directory when there are no arguments.
  `application(_:open:)` routes these to `AppDelegate`'s request queue,
  which hands out one at a time. A request that belongs to the launch — it
  arrives during startup, or within a second of
  `applicationDidFinishLaunching` in case delivery slips past it — is taken
  by the window SwiftUI already opens: the launch window can register
  *before* LaunchServices delivers the URL, so the request is applied to
  that window directly (`launchWindowModel`) rather than parked in the
  pending slot, which nothing would then consume and the first window would
  stay in `$HOME`. The pending slot is only used while that window has not
  registered yet. Afterwards the window for an invocation is the one SwiftUI
  shows for the URL event itself — measured ~40 ms *before*
  `application(_:open:)` reaches the delegate — so a request that arrives
  next to a window registered in the last half second
  (`newestWindowModel`/`newestWindowAt`) is applied to that window instead of
  asking for another one; an explicit `openWindow` beside it produced two
  windows per invocation, a default `$HOME` one next to the requested one.
  A request whose window has not registered yet waits in the pending slot,
  and only when none appears within half a second does
  `pumpCommandLineRequests` open a window itself. `registerEditorWindow` acts
  only on a window's first registration (a weak `NSHashTable` of windows
  already seen): a repeat `viewDidMoveToWindow` must not take the pending
  request, adopt the launch slot, or count as the newest window. The window
  is a standalone editor window (like ⌘N, so it seeds from the active
  session's theme). Its `AppModel.openFromCommandLine` seeds
  `NvimProcess.start(workingDirectory:)` when its session has not started —
  so init.lua already sees the directory — otherwise `:cd`s before opening
  the files. Startup re-reads the requested directory after every suspension
  point and once more right before `ui_attach` (nvim sources init.lua only
  when the UI attaches, so a later `:cd` would be too late for a config that
  reads `getcwd()` at startup), because a launch request can arrive while
  nvim is already booting. That also makes the request's directory win on a
  cold launch over the one the launch window resumed in (see "Last working
  directory"). It also marks the
  window (`focusAfterCommandLineOpen`) to activate the app and take keyboard
  focus as it is revealed (`fadeIn` uses `makeKeyAndOrderFront` instead of
  `orderFront`), so the command line can be typed into without clicking
  first. `open -a <the app that
  installed it>` (falling back to `open -b com.mzevo.iNeovim` when the app
  has moved) remains the fallback when the URL scheme is unavailable, e.g. a
  launcher left over from an older build. The launcher creates missing path
  arguments so `ineovim newfile.txt` behaves like nvim's new buffer, and
  supports `-h`/`--help`. An existing file not carrying the launcher's
  marker is only replaced after an explicit confirmation.
- **Native terminal pane (Ghostty):** a typed `:terminal` (and its `term`…
  `terminal` abbreviations, optional `vert[ical]` modifier, optional `!`,
  optional trailing command) never reaches nvim: `TerminalView.sendKeys`
  matches the accumulated cmdline (same `cmdlineBuffer` mechanism as the
  fzf gate), swallows the Enter, sends `<Esc>` to cancel the cmdline, and
  asks `AppModel.requestTerminalPane(command:)` to open the native pane
  instead. The pane is an in-window right-hand split (`EditorSplitView`:
  optional problems sidebar | editor | draggable divider | `TerminalPaneView`)
  whose width drives the normal resize pipeline — narrowing the editor simply
  reflows the nvim grid through `ResizeController`. The pane hosts a real libghostty
  surface: `Packages/GhosttySupport` (local Swift package) wraps a
  self-built `GhosttyKit.xcframework` (ghostty 1.3.2-main+246f702, Zig
  0.16.0, macOS-universal slice only — iOS slices pruned; provenance and
  pruning in its `ADAPTATION.md`) plus adapted Swift bindings. One
  `Ghostty.App` per process (`GhosttyTerminalController`) hosts every
  window's surface; per-surface `SurfaceConfiguration` sets the cwd from
  nvim's `getcwd()` and the command parsed off the cmdline. The generated
  app config (Application Support/iNeovim/ghostty.conf) mirrors the editor
  font and nvim's default colors and sets `shell-integration = none` —
  Ghostty's shell-integration scripts are GPLv3 and must not ship in this
  MIT app. It also unbinds `super+1`…`super+9`
  (`keybind = super+N=unbind`): Ghostty's default `super+N=goto_tab:N` (and
  `super+9=last_tab`) would otherwise swallow the editor's "Go to Tab"
  shortcuts while the pane has focus. It is written when the first pane opens
  and rewritten + reloaded
  (`GhosttyTerminalController.updateColors` → `Ghostty.App.reloadConfig`,
  driven by `AppModel.$terminalColors`) whenever a session reports a new
  default background, so an open pane follows a dark↔light colorscheme flip
  instead of keeping its original theme. ⌘-clicking a file path recognized in
  the pane opens it in the editor instead of the system's default app:
  `Ghostty.SurfaceView.openURLHandler` offers the raw `open_url` target before
  the system fallback, and `EditorSplitView` routes an existing regular file
  through `TerminalFileLink` — absolute paths, `file://` URLs, relative paths
  against the surface's OSC 7 pwd or the pane's initial directory, and an
  optional `:line[:column]` suffix — to `AppModel.open`, then focuses the
  editor; web URLs keep the browser. Menu "Toggle Terminal
  Pane" / ⌘D toggles regardless of focus; the keyDown monitor in `AppDelegate`
  claims ⌘D (and its ⌃` alternate) before dispatch because Ghostty's
  `SurfaceView.performKeyEquivalent` would otherwise consume ⌘D for its
  default `new_split:right` binding while the pane is focused, so the menu
  shortcut alone only ever opened the pane. The same monitor claims ⌘L, ⌘R,
  and ⌘P (the problems panel). ⌘L focuses the editor; ⌘R previews the current
  Markdown buffer in a reading window, and every other buffer keeps the
  chord's old meaning — focus the terminal pane, opening it first when it is
  hidden (the pane's `.focus` intent and the editor's `.focusEditor` intent).
  A focus change is often invisible — two panes both filled with text, or a
  second ⌘R — so
  `EditorSplitView` answers every successful `makeFirstResponder` for these
  intents (and for a pane that opens and takes focus) with a short
  `FocusToastView` card at the center of the window ("Focus: Editor" /
  "Focus: Terminal"), a `.popover`-material `NSVisualEffectView` rounded 10 pt
  that fades in over 0.12 s, holds ~0.9 s, and fades out over 0.25 s from a
  cancellable main-actor task; it hit-tests to nil so clicks fall through, is
  re-raised above its siblings on show, and is re-centered in
  `placeSubviews`. The
  toast only appears when the responder change actually succeeded, so it also
  reports a pane that refused focus by staying silent. The
  settings toggle
  "Open :terminal in native pane" only gates the cmdline interception
  (mappings/plugins/RPC `:terminal` bypass `sendKeys` and keep nvim's
  in-buffer terminal, exactly like the fzf gate's known edges). GhosttySupport
  is a **dynamic** package product (`Package.swift` keeps it dynamic so the app
  and the XCTest bundle share one copy of libghostty's global state), so the
  app target's "Embed Frameworks" copy phase must keep it: publishing the
  product into `Contents/Frameworks` is the only thing that makes
  `@rpath/GhosttySupport.framework/…` resolvable. Running from Xcode hides a
  missing embed phase (the run action injects `DYLD_FRAMEWORK_PATH`, pointing
  at `$(BUILT_PRODUCTS_DIR)/PackageFrameworks`), and the symptom of losing it
  is a dyld abort at launch — before `main` — on the exported app: "Library
  not loaded: @rpath/GhosttySupport.framework/Versions/A/GhosttySupport".
- **Markdown preview (⌘R):** the keyDown monitor's ⌘R asks
  `AppModel.handleCmdR`, which snapshots the current buffer through
  `NvimClient.currentBufferSnapshot` (name, filetype, and lines, so unsaved
  edits preview). A Markdown buffer (filetype `markdown*` or a Markdown
  extension) opens in a standalone `MarkdownPreviewWindowController` — a
  read-only `WKWebView` rendering HTML from `MarkdownRenderer`, one window
  per buffer name, re-rendered and brought forward when previewed again.
  The renderer parses with Foundation's `AttributedString(markdown:)` and
  maps its presentation intents to headings, lists, block quotes, code
  blocks, and thematic breaks, and its inline intents to
  bold/italic/code/strikethrough/links; the CSS follows the editor's nvim
  default colors, keeps the reading column at 720 pt, and renders code
  blocks `white-space: pre` with `overflow-x: auto` so ASCII and
  box-drawing diagrams keep their layout instead of wrapping at the reading
  column. File links open in this session's editor,
  web links in the browser. A non-Markdown buffer keeps ⌘R's old meaning
  (focus/open the terminal pane); the Neovim menu's "Preview Markdown" item
  carries the ⌘R hint and beeps on a non-Markdown buffer.
- **`ext_multigrid` policy:** the app attaches with `ext_linegrid`,
  `ext_popupmenu`, AND `ext_multigrid` — there is no single-grid path and no
  feature flag. Every grid is first-class: `Screen.grids`/`Screen.frames` key
  state by grid ID, `ScreenSnapshot` carries both, and `TerminalView` renders
  one `GridBox` per displayed grid with hit-testing (`gridHit`) and scrolling
  (`setScrollLead`) resolving per grid. New per-window features should read
  `frames` (position, z, mouseEnabled, viewport metrics) rather than assuming
  one screen-sized grid. KNOWN DEFERRAL: the scroll indicator still queries
  nvim per wheel event (`windowScrollMetrics` Lua, cursor's window — so it
  reflects the focused window when wheeling an unfocused split). `Screen`
  already stores `win_viewport` metrics per grid in `GridFrame.viewport`;
  switching the indicator to those (per hit grid, no RPC) is the intended
  follow-up.
- **Wide-glyph rendering:** nvim signals double-width cells by following the
  character with an empty-text continuation cell in `grid_line` ("the right
  cell of a double-width char will be represented as the empty string"); cell
  widths come from that protocol, not from a local wcwidth table (which
  disagrees with nvim on emoji). Glyphs are shaped as one CTLine per highlight
  run but drawn pinned to cell origins (`CellRenderer.shiftGroups` →
  per-correction `CTRunDraw` ranges), because Core Text's automatic font
  fallback (PingFang for CJK, Apple Color Emoji) advances by its own metrics
  and drifts text off the cell grid. `grid_line` entries with `repeat` 0 are
  chunk markers and must not overwrite cells.
- **Tabs are native macOS window tabs:** ⌘T — and a typed
  `:tabnew [file]` / `:tabe[dit] [file]`, intercepted in `TerminalView.sendKeys`
  with the same cmdline-buffer mechanism as the `:terminal` gate — opens a new
  editor window joined to the requesting window's tab group: one window, one
  embedded nvim session per tab (like ⌘N, except grouped). `AppDelegate` owns
  the plumbing: it implements `newWindowForTab:` (the tab bar's + button and
  the system New Tab action), holds the SwiftUI `openWindow` action captured
  by the first `ContentView` (`WindowGroup` carries `id: "editor"` for it),
  and `registerEditorWindow` — called from `AppModel.attach(to:)` as the new
  window's content installs — assigns the shared
  `tabbingIdentifier com.mzevo.iNeovim.editor`, consumes the pending tab
  placement (`addTabbedWindow` unless the system auto-tabbed the window under
  the user's tabbing preference — at registration time neither window has a
  group yet, so plain `tabGroup` inequality would skip the join), and routes a
  pending file through the model's pre-ready queue (paths resolved against
  nvim's cwd via `AppModel.resolveTabFile`). Reach the delegate through
  `AppDelegate.shared` (set in `init`), never `NSApp.delegate as? AppDelegate`:
  `@NSApplicationDelegateAdaptor` installs a `SwiftUI.AppDelegate` wrapper as
  the real `NSApp.delegate` that only forwards protocol methods and `@objc`
  selectors, so that cast silently fails and menu actions become no-ops. All editor windows must share one
  `tabbingIdentifier`; the default per-scene identifier could auto-group
  editors with Settings under the "Always" tabbing preference. ⌘1–9,
  ⌘⇧[ / ⌘⇧] walk `NSWindow.tabGroup` (`EditorCommands`); nvim's own tabpages
  stay reachable through `gt`/`gT` and un-intercepted `:tab*` commands
  (ranges, `+cmd`/`++opt` modifiers, and `|` bars pass through, as do
  `:tabclose`/`:tabnext` etc.).
- **Windows — one session per window (⌘N):** every window owns its own
  `AppModel` and its own embedded stack (`NvimProcess` → `RPCSession`, plus
  that session's `RedrawEventStream`/`Screen`/`InputDispatcher`); nothing
  session-scoped is a singleton. Menu commands and system file opens route
  through `AppModel.active` (the key window's session, tracked via
  `NSWindow.didBecomeKey`); files that arrive before any session is ready are
  staged app-level and flushed to the first ready session. New sessions start
  in `$HOME` (`NvimProcess` sets the child's cwd) — except the launch window,
  which resumes in the last working directory — and closing a window
  terminates its nvim in `AppModel.deinit`.
- **Last working directory:** the launch window resumes where the last session
  was. nvim reports its working directory once after
  `NvimClient.installWorkingDirectoryHook` installs and again on every
  `DirChanged` (`:cd`, `:tcd`, `:lcd`) as `ineovim:dirchanged`; `AppModel`
  keeps the latest and writes it to `lastWorkingDirectory` whenever that
  window is active (`becameActive`), plus once more from
  `applicationWillTerminate` — so closing from another window or a crash
  cannot save a stale directory. Only the launch window
  (`registerEditorWindow` marks it) seeds `NvimProcess.start` from it; ⌘N and
  native-tab windows keep starting in `$HOME`, and a directory that no longer
  exists restores nothing. A window an `ineovim` command opened never uses the
  saved value: the request's own directory takes precedence, and on a cold
  launch — where the launch window may already have spawned in the saved
  directory before the URL reaches it — the startup `:cd` is applied before
  `ui_attach`, so nvim finishes startup with the requested directory, not the
  saved one.
- **⌘W (File > Close):** `EditorCommands.closeKeyWindow` closes the key
  editor window — with native tabs that is the current tab, and a window in
  a tab group with other tabs never quits the app. It closes the window with
  `close()`, not `performClose(_:)`: `performClose` simulates a click on the
  close button, whose action `registerEditorWindow` replaces with
  `confirmCloseEditorWindow`, so it would run the quit confirmation on every
  ⌘W (and `confirmCloseEditorWindow`'s own close re-entered itself in an
  endless alert loop). When `AppModel.live` reports a single session left, it
  first confirms with an `NSAlert` and quits via `NSApp.terminate` (whose
  `applicationWillTerminate` begins shutdown for every live session) —
  SwiftUI would otherwise leave the app running with no window. A non-editor
  key window (e.g. Settings) closes directly.
- **Typed quit confirmation:** a typed `:q`/`:qu`/`:quit`/`:qa`/`:qall`
  (with optional `!`) is held at Enter — `TerminalView.sendKeys` matches it
  before sending anything — and only confirmed Enter reaches nvim; Cancel
  sends `<Esc>` and the cmdline goes away. The red close button
  (`confirmCloseEditorWindow`) routes through the same alert. Because the
  embedded session's clean exit closes only its own tab — and quits the app
  only when nothing else is left — the alert names that scope
  (`QuitConfirmation.scope(for:)` → `QuitConfirmation.scope(tabCount:
  editorWindowCount:)`): more than one native tab shows "Close Tab?" (only
  that tab's session ends), a standalone window while another session is live
  shows "Close Window?", and the last editor window keeps "Quit iNeovim?".
  `editorWindowCount` is `AppModel.live.count`, the same measure the ⌘W path
  uses to decide whether the app would have anything left to show.
- **Scroll sync (T7.3):** the embedded nvim runs with `mousescroll=ver:1,hor:1`
  so one wheel event scrolls exactly one line and the visual lead in
  `ScrollAccumulator` maps 1:1 to incoming `grid_scroll` confirmations.
  `nvim_input_mouse` takes the wheel as button `"wheel"` with the direction as
  the *action* (`"up"`/`"down"`); the terminfo-style `"wheelup"`/`"press"`
  pair is rejected with `invalid button or action`, which leaves nvim
  unscrolled while the visual lead runs ahead and then snaps back — the
  blank-space symptom — so `ScrollLineRequest.wheelButton` owns the mapping.
  Horizontal wheel input is not sent yet (`wheelleft`/`wheelright` require
  nvim 0.10; the minimum is 0.9) — horizontal deltas are ignored for now.
- **Scroll lead (T7.4, revised):** the content may lead Neovim's scroll by at
  most one line — exactly one wheel notch — and the lead is whole lines only:
  `ScrollAccumulator.offset` is the *requested but unconfirmed* part of the
  gesture (`sent - confirmed`), not the finger's pixel travel. A request
  therefore moves the content in the wheel's own frame instead of waiting for
  the round trip, which is what makes wheel scrolling feel like a native
  scroll instead of a sequence of steps; a trackpad's sub-line deltas stay in
  `credit` until they add up to a line. Following the pixels too
  (`credit - confirmed`) left a sub-line remainder that Neovim can never
  confirm — it scrolls whole rows only — so every trackpad gesture ended with
  the content sliding back by up to a line, visibly, after
  `confirmationGrace` (measured against the real app: 13 of 16 points at the
  end of one gesture). Trackpad phase edges carry no delta of their own, so
  `ScrollController.scrollWheel` reads `.began`/`.ended` before the zero-delta
  check: dropping a zero-delta `.ended` left the gesture open — and
  `acceptConfirmations` on, so a background redraw could move the offset —
  after the fingers had lifted. A single grid has no pixels
  beyond the visible screenful, so that lead is one line Neovim has not
  painted yet; the `grid_scroll` it answers with arrives a frame or two later,
  and the flush that carries it swaps the lead for the newly painted row in
  the same main-actor turn as the grid repaint
  (`ScrollController.applyConfirmedOffset`, called from
  `TerminalView.apply(snapshot:cellRects:)`). The ordering is the point: an
  offset applied before that repaint, or eased back over later frames, makes
  the already-painted content slide the wrong way for a frame. A burst of
  notches Neovim has not answered is clamped to the same one line, so a fast
  spin exposes at most that one line of unpainted space and the confirmations
  drain the rest; a lead Neovim never confirms — the buffer's edge — is held
  while the gesture lasts and given up after `confirmationGrace`, so it never
  stands. (The earlier policy suspended a whole-line lead outright, which is
  why wheel steps used to move only when Neovim answered.) Deltas are never
  dropped: throttling requests past the cap made the content fall behind the
  wheel *and* left up to a screen of blank. The lead translates only the
  grabbed grid's content layer, inside that grid's own clip layer — the other
  boxes (statusline row, message area, floats) never move mid-gesture, and no
  box's content can paint outside its clip.
- **Animation pacing (T7.6):** all easing is time-based (elapsed/duration,
  sampled from `CVDisplayLink` frame timestamps), so animation speed is
  identical at 60 Hz and 120 Hz ProMotion; ProMotion just samples the curve
  more often. Tuning lives in `ScrollAnimationSettings`. `ScrollAnimator`
  starts the display link only when the presentation actually has to move:
  every `grid_scroll` confirmation applies its offset directly with the
  repaint it accounts for, so there is nothing to chase, and starting a link
  just to chase 0→0 cost a thread create/start/stop (measured ~0.5 ms) plus a
  main-thread tick per wheel step — a hitch at exactly the moment the frame
  is committed. The link runs only for the unconfirmed lead's snap-back after
  the gesture ends.
- **Scroll repaint cost:** every wheel step still makes Neovim repaint the
  whole viewport (one `grid_scroll` plus the revealed row), and the flush that
  carries it repaints on the main thread, so every avoidable cost there shows
  up as lag behind the wheel. `GridContentLayer` therefore caches shaped runs
  (`lineCache`) keyed by run text, font variant, and foreground color — the
  foreground must be part of the key because Core Text bakes it into the
  `CTLine` rather than taking the context fill color — and drops the cache
  when highlights, the default colors, the font, or the window appearance
  change (the adaptive `.textColor` fallback resolves at shaping time). Runs whose background
  resolves to nvim's default skip their fill, because the view's layer already paints
  it — true only where that fill is actually underneath the cells: the base
  grid and the tiled window grids sit directly on the view's background
  layer, but a grid layered above another grid's CELLS must paint its own
  default background (`GridContentLayer.overlaysOtherGridContent` — floats
  and the message grid). A skipped fill there is a HOLE the covered text
  shows through: an fzf panel (a float over the buffer) lost its background
  and the buffer text rendered on top of the panel's rows.
  `CellRenderer.runs` accumulates a run in locals and appends it when it
  ends, instead of mutating `runs[last]` per cell (which copied the run's text
  and slot array per cell). `TerminalView` coalesces flush applies: flushes
  that arrive while one apply is queued only add their dirty cells, and the
  apply reads the newest snapshot, so a wheel burst costs one repaint rather
  than one per flush. `GridContentLayer.draw(in:)` repaints the display clip,
  never a record of the flushed cells: Core Animation clears every pixel of
  the dirty clip before the call, so a display pass that merges a flush with
  another invalidation — a cursor blink or glide, the link underline, the IME
  preedit — must repaint the whole clip. Painting only the flushed cells
  erased the rest, which showed up as blank characters along a search jump's
  cursor glide until nvim repainted those rows.
- **Scroll indicator:** wheel and trackpad deltas flash a transient overlay
  scrollbar (`ScrollIndicator`): a 6 pt rounded thumb at the window's right
  edge (`rightInset` 2 pt), leaving the text 2 pt clear of the thumb (the
  trailing inset reserves the shifted text's edge, see "Gutter-to-text
  padding"), spanning the global grid's content rows (its last two rows —
  statusline and cmdline — stay thumb-free), faded out
  0.7 s after the last delta — the system overlay scrollers' show-on-scroll,
  hide-when-idle behavior. The `redraw` stream's `win_viewport` metrics are
  already stored per grid (`GridFrame.viewport`), but the thumb still gets its
  geometry from `NvimClient.windowScrollMetrics`: Lua that finds the window
  under the pointer cell via `getwininfo` rects
  (falling back to the current window when the pointer is over the
  statusline/cmdline rows) and returns `topline`, the buffer's line count,
  and the number of visible buffer lines (`botline - topline + 1`, so a
  wrapped line counts once and a fully wrapped buffer still reports as
  scrollable) — so the thumb reflects the CURSOR's window when a wheel
  gesture targets an unfocused split. Switching the thumb to
  `GridFrame.viewport` of the hit grid (no RPC round trip, correct per-window
  metrics) is the planned follow-up (see "ext_multigrid policy"). One query
  per delta with at most one in flight
  (sub-millisecond round trips; against a blocked nvim the queries would
  otherwise pile up behind the input it is not processing). A buffer that
  fits the window shows no thumb; a failed query leaves the geometry as it
  was. The knob follows the nvim theme (white on dark, black on light, 34%
  alpha) and is informational only: it takes no mouse events, so it never
  intercepts a click on the text beneath it.

## Security considerations

- App Sandbox is **disabled** (`ENABLE_APP_SANDBOX = NO`). Neovim has to run a
  user-installed binary (Homebrew, `~/.local/bin`, …) and read the user's
  `~/.config/nvim`, plugins, and arbitrary project files; under the sandbox the
  child `nvim` could not even be located, which left the window blank. Distribution is
  developer-id + notarization (not the Mac App Store), so the sandbox is not required.
  The Release build keeps `ENABLE_HARDENED_RUNTIME = YES`.
- Code signing uses automatic signing with a personal development team
  (`DEVELOPMENT_TEAM = S39RD89QY9`) — do not hardcode other team IDs or credentials.
- Never commit secrets (API keys, provisioning credentials, `.env` files); none exist in
  the repo today.
- The bundle ID prefix is the real reverse-DNS identifier `com.mzevo` (T9.4); keep
  any future App Group identifiers under the same prefix.

## Deployment / release

No automated pipeline or CI exists. Release signing uses automatic signing with team
`S39RD89QY9`; Release enables the hardened runtime for notarization. The full
archive → export (`Config/ExportOptions.plist`) → notarize (`notarytool`) → staple flow
is documented in `docs/RELEASE.md`; `Scripts/publish.sh` runs it, and its `--upload`
flag publishes the ZIP and DMG to the GitHub release for tag `v<version>` (the script
never creates or pushes the tag itself). The app is MIT-licensed (`LICENSE`).
