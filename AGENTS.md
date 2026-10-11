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
  next update pass.
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
  row) gets a backdrop layer (`TerminalView.statuslineLayer`, below the
  content layer) that fills the row's leftmost run's resolved background from
  window edge to window edge, so the bar runs full width while the cells stay
  inset. `updateStatuslineLayer()` keeps its frame/color in sync from the
  flush, initial-snapshot, metrics-, resize-, and appearance-change paths;
  like the cmdline gap it assumes the last row is the cmdline area and the
  row above it the statusline (`laststatus` >= 2, `cmdheight` 1).
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
  app config (Application Support/iNeovim/ghostty.conf, frozen when the
  first pane opens) mirrors the editor font and nvim's default colors and
  sets `shell-integration = none` — Ghostty's shell-integration scripts
  are GPLv3 and must not ship in this MIT app. Menu "Toggle Terminal
  Pane" / ⌃` toggles regardless of focus; the settings toggle
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
- **Tabs (T8.2):** tabs are **Neovim tabpages**, not native macOS window tabs.
  Each window's embedded nvim already draws the tabline and owns the
  buffer/window/tab model, so a tab is a tabpage inside that window's session.
  Editor commands route to `:tab*` (`EditorCommands` → `AppModel.active`), and
  `gt`/`gT` keep working through normal key input.
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
  Horizontal wheel input is not sent yet (`wheelleft`/`wheelright` require
  nvim 0.10; the minimum is 0.9) — horizontal deltas are ignored for now.
- **Scroll lead cap (T7.4):** the visual lead is clamped at one screen (or the
  grid content height when smaller). Deltas beyond the cap are dropped rather
  than deferred, which also throttles wheel requests to a stalled Neovim.
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
