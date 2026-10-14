# AGENTS.md — iNeovim

## Project overview

iNeovim is a native macOS desktop application written in Swift with SwiftUI. It embeds one
`nvim --embed` child process per window over msgpack-RPC and renders Neovim's linegrid
protocol itself (Core Text + `CALayer`), with macOS-native input, smooth scrolling, and an
app shell. Phases 1–8 of `docs/TASKS.md` are implemented: RPC, UI state, rendering, input,
scrolling, and the SwiftUI app shell (tabs, settings, menus, window title, file opening).
Phase 9 (polish and release) added crash recovery, performance baselines/signposts, an
app icon, the `com.mzevo` bundle identifier, the MIT license, and a documented
archive → notarize release flow (`docs/RELEASE.md`).

Key facts from `iNeovim.xcodeproj/project.pbxproj`:

- **Platform:** macOS only (`SUPPORTED_PLATFORMS = macosx`, `SUPPORTS_MACCATALYST = NO`).
  The iOS-orientation keys in the target settings are unused template leftovers.
- **Deployment target:** macOS 14.6 (`MACOSX_DEPLOYMENT_TARGET = 14.6`).
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
  can open (T8.6).

## Repository layout

```
iNeovim/                  App sources (a PBXFileSystemSynchronizedRootGroup)
├── MyApp.swift           @main entry point: WindowGroup + Settings + menu commands
├── ContentView.swift     Window shell hosting the render view via NSViewRepresentable
├── AppDelegate.swift     NSApplicationDelegate: bootstrap, open-file requests, teardown
├── App/                  SwiftUI app shell (Phase 8)
│   ├── AppModel.swift        per-window session stack, command routing, file queues, title
│   ├── AppSettings.swift     persisted font/input/animation settings
│   ├── SettingsView.swift    settings window
│   ├── SetupView.swift       first-run guidance when no nvim is installed
│   ├── EditorCommands.swift  File + Neovim menu commands
│   ├── OpenQuicklyPanel.swift  native ⌘P file finder panel
│   ├── QuicklyFileSource.swift  first-level directory listing for the panel
│   ├── DiagnosticsStore.swift  per-session aggregated LSP diagnostics
│   ├── ProblemsPanel.swift   docked non-modal issues sidebar
│   └── FuzzyMatcher.swift    fzf --filter front end with in-process fallback
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
│   ├── GridContentLayer.swift  cells/cursor/preedit in a scrollable CALayer
│   │                           (one row slice per layer: the scrolling
│   │                           region and the frozen footer)
│   ├── TerminalView.swift    layer-backed NSView hosting the content layer
│   ├── CompletionPanelView.swift  native ext_popupmenu completion list
│   ├── DiagnosticPopover.swift  native vim.diagnostic popover for gutter clicks
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
│   └── DisplayLinkDriver.swift  CVDisplayLink → Swift closure trampoline
├── TerminalPane/         native Ghostty terminal pane (see design decisions)
│   ├── EditorSplitView.swift    editor|divider|pane container, pane intents
│   ├── TerminalPaneView.swift   pane header + surface lifecycle
│   └── GhosttyTerminalController.swift  process-wide Ghostty.App, config, surfaces
└── Assets.xcassets/      AccentColor colorset + AppIcon.appiconset (T9.3)
Packages/GhosttySupport/  Local Swift package wrapping the self-built
                          GhosttyKit xcframework (Vendor/) and the adapted
                          libghostty Swift bindings (Sources/); see its
                          ADAPTATION.md for provenance and pruning notes
Scripts/                  One-off tooling (app-icon generator); not part of the build
iNeovimTests/             XCTest target (synchronized group); codec round-trip,
                          redraw-parsing, settings/model, and embedded-nvim tests
Config/Info.plist         Partial Info.plist merged into the generated one
                          (document types); outside the synchronized group
Config/ExportOptions.plist  developer-id export options (T9.6)
docs/                     TASKS, VERIFICATION, PERFORMANCE, RELEASE, screenshots/
iNeovim.xcodeproj/        iNeovim app + iNeovimTests unit test targets
```

Important: the `iNeovim` folder is registered as a **file-system-synchronized group**, so
any `.swift` file added to that directory is automatically part of the target — no
`project.pbxproj` edit is needed when adding or removing source files. Files outside that
folder are not compiled.

## Build and run

- There is no `Package.swift`, no Makefile, no CI configuration, and no build scripts.
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
  effective appearance.
- **New-tab first paint:** `ui_attach` uses the view's real grid size
  (`AppModel.pendingGridSize`, reported from `TerminalView.requestResize`
  as the window lays out) instead of a placeholder 80x24. The placeholder
  would be drawn first and then resized a debounce interval later, so a new
  tab appeared to wipe in from the top; attaching at the target size paints
  the first frame full. `AppModel.attach` also sets
  `window.animationBehavior = .none` so AppKit contributes no order-in or
  tab-bar-entrance motion on top of the redraw. The 80x24 fallback only
  applies if bootstrap beats the first layout.
- **Content inset & cmdline gap:** the grid is inset `TerminalView.contentInset`
  (6 pt) from the view on all sides, and the last grid row (nvim's
  cmdline/message area) is drawn `TerminalView.cmdlineGap` (4 pt) below the
  row above it, so the statusline and the cmdline never touch. Every grid
  cell-count computation (`ResizeController.cellCount` via
  `TerminalView.gridAreaSize`) derives from the inset- and gap-adjusted size,
  never the raw bounds — otherwise the floor-rounded grid fills the view edge
  to edge and the last line hugs — or, while resizes race, overflows — the
  window's bottom edge. All view-space→grid-space conversions (mouse
  `MouseHandler`, wheel pointer `ScrollController`, IME preedit rects)
  subtract the inset, and row↔y math everywhere goes through
  `TerminalView.gridRowY`/`gridRow(atY:)` so the gap stays consistent.
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
  — the user found the full-strength inversion glaring at night. The footer
  layer skips per-run background fills on that row and draws its text in the
  opposite mode's default foreground — the theme's statusline text matches its
  editor background and would vanish on the inverted bar. An unknown nvim
  background (nil) follows the window appearance. `updateStatuslineLayer()`
  keeps its frame/color in sync from the flush, initial-snapshot, metrics-,
  resize-, and appearance-change paths; like the cmdline gap it assumes the
  last row is the cmdline area and the row above it the statusline
  (`laststatus` >= 2, `cmdheight` 1).
- **Frozen footer (statusline + cmdline rows):** nvim never scrolls the last
  two rows, so the app must not either. The grid is therefore drawn as two
  `GridContentLayer`s — the scrolling region (`.head(excludingTrailing:
  TerminalView.frozenFooterRows)`) and the frozen footer (`.tail(count:)`),
  which share one snapshot and split `CellRect` invalidations by row — and
  only the scrolling region takes the scroll lead's transform. The scrolling
  region lives inside `scrollClipLayer` (`masksToBounds`), because a lead that
  moves it *down* would otherwise paint the last text rows over the statusline
  bar; the clip band ends exactly where the footer begins. Doing this in one
  layer (the original design) dragged the statusline text off its bar mid-drag
  while the sibling bar stayed put, which read as a style error. Because both
  layers keep grid coordinates internally (`GridRowSlice` + `sliceOriginY`),
  the cursor, the IME preedit, and the cursor glide were re-routed by row
  (`TerminalView.cursorLayer`) but their geometry math is unchanged; the
  footer is positioned by `updateFooterGeometry()`, which every snapshot,
  metrics, resize, and appearance path calls next to `updateStatuslineLayer()`.
  At most a sub-cell band of blank background opens between the last text row
  and the footer while the lead lasts — the same sub-line blank the top edge
  shows, and the price of leading Neovim at all (T7.4).
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
- **Open Quickly (⌘P):** a native file finder, deliberately outside nvim —
  `EditorCommands` routes ⌘P to the key window's TerminalView, which
  presents `OpenQuicklyPanel` (vibrancy panel: `NSSearchField` +
  `NSTableView` + path preview, centered over the editor, focus moves into
  the panel and back to the terminal on close). The list shows the FIRST
  LEVEL of the current directory only (`QuicklyFileSource`: `fd
  --max-depth 1` respecting .gitignore → `find -maxdepth 1`, non-hidden);
  Enter on a directory re-collects that directory's children (drill-down,
  with a `..` row to go back up) — never a recursive walk, so huge trees
  cannot stall it. Ranking goes through `FuzzyMatcher`, which shells out to
  `fzf --filter` when the binary exists (homebrew paths are probed — the
  GUI PATH does not include them) and otherwise falls back to an
  in-process subsequence scorer; selected rows use the OS accent color.
  Picking a file sends `:edit <fnameescape(path)>` over RPC. This panel is
  also the safe replacement for tree-walking fzf usage in huge
  directories: it never spawns a TUI and caps its sources.
- **Child-process environment:** nvim is spawned with an augmented PATH —
  the GUI PATH omits version managers (rbenv/asdf) and Homebrew, so tools
  nvim spawns (LSP servers, formatters) silently fell back to system
  binaries: a `ruby-lsp` resolved to the system Ruby 2.6 and died against a
  modern Gemfile. `NvimProcess.augmentedEnvironment()` prepends
  `~/.rbenv/shims`, `~/.asdf/shims`, `~/.local/bin`, `/opt/homebrew/bin`,
  and `/usr/local/bin` (inherited PATH kept at the end). The same GUI-PATH
  limitation is why `NvimDiscovery`, `FuzzyMatcher`, and
  `QuicklyFileSource` probe absolute Homebrew paths instead of relying on
  PATH.
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
  gated; the native Open Quickly panel is the safe replacement.
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
  `CompletionPanelView` (vibrancy-backed AppKit list, row cap 50, ~10 rows
  visible) at the anchor cell — flipping up when it would overflow the
  bottom edge — from the flush, initial-snapshot, metrics-, and resize
  paths. Keyboard navigation stays with nvim (`popupmenu_select` updates the
  panel); row clicks call `nvim_select_popupmenu_item`. The panel is the
  only completion UI while attached — there is no in-grid fallback. Hover /
  signature-help floats still render as grid content; making those native
  requires `ext_multigrid` and is a separate, much larger iteration.
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
  grid coordinates — and to collect the diagnostics. An empty result (clean
  line, non-text row, or an nvim without `vim.diagnostic`, guarded by
  pcall) forwards the original press, so behavior outside the feature is
  unchanged. The rest of the intercepted gesture (drag/release) is always
  swallowed so nvim never sees orphan events. The popover is a transient
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
  counts in the header; selecting a row jumps the editor
  (`:edit` when the path differs from the current buffer →
  `nvim_win_set_cursor`) and the panel keeps focus, so the arrow keys walk
  the list. The panel is created once per window and stays subscribed while
  hidden. It opens only on demand — ⌘I or the Neovim menu's "Toggle
  Problems" — and closes via the header ✕ or the same toggle; nothing pops
  it open automatically and no settings gate exists.
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
  MIT app. It is written when the first pane opens and rewritten + reloaded
  (`GhosttyTerminalController.updateColors` → `Ghostty.App.reloadConfig`,
  driven by `AppModel.$terminalColors`) whenever a session reports a new
  default background, so an open pane follows a dark↔light colorscheme flip
  instead of keeping its original theme. Menu "Toggle Terminal
  Pane" / ⌃` toggles regardless of focus, and so does ⌥T — a local keyDown
  monitor in `AppDelegate` (SwiftUI menu items can carry only one shortcut)
  claims the exact ⌥T chord before dispatch; when "Option as Meta" is on the
  chord goes to nvim as `<M-t>` and the pane stays on ⌃` alone; the settings
  toggle
  "Open :terminal in native pane" only gates the cmdline interception
  (mappings/plugins/RPC `:terminal` bypass `sendKeys` and keep nvim's
  in-buffer terminal, exactly like the fzf gate's known edges).
- **`ext_multigrid` policy (T1.3):** v1 attaches to nvim with a single grid
  (`ext_multigrid` off). All redraw and grid handling must still carry grid
  IDs from day one — event cases take a `grid` identifier and grid state is
  keyed by ID — so enabling multigrid later is a switch flip, not a rewrite.
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
  in `$HOME` (`NvimProcess` sets the child's cwd), and closing a window
  terminates its nvim in `AppModel.deinit`.
- **⌘W (File > Close):** `EditorCommands.closeKeyWindow` closes the key
  editor window via `performClose`. When `AppModel.live` reports a single
  session left, it first confirms with an `NSAlert` and quits via
  `NSApp.terminate` (whose `applicationWillTerminate` begins shutdown for
  every live session) — SwiftUI would otherwise leave the app running with
  no window. A non-editor key window (e.g. Settings) closes directly.
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
- **Scroll lead limit (T7.4):** the content may lead Neovim's scroll by at
  most one cell — the sub-line part of the gesture, which is what makes a drag
  look smooth (`ScrollAccumulator.offset`). A single grid has no pixels beyond
  the visible screenful, so a whole line of lead is space Neovim has not
  painted: blank space above/below the text that stands as long as the lead
  does. A gesture that wants one therefore has the lead suspended — a
  whole-line wheel step immediately, and any gesture at the buffer's edge,
  where nothing is ever confirmed — and the content then moves with Neovim's
  confirmations alone until a confirmation proves the backlog is gone.
  Deltas are never dropped: the old cap throttled requests past it, which made
  the content fall behind the wheel *and* left up to a screen of blank. The
  lead translates the scrolling grid layer only — never the frozen footer, and
  never past the clip band above it (see "Frozen footer" above).
- **Animation pacing (T7.6):** all easing is time-based (elapsed/duration,
  sampled from `CVDisplayLink` frame timestamps), so animation speed is
  identical at 60 Hz and 120 Hz ProMotion; ProMotion just samples the curve
  more often. Tuning lives in `ScrollAnimationSettings`.

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
is documented in `docs/RELEASE.md`. The app is MIT-licensed (`LICENSE`).
