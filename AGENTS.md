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
│   └── EditorCommands.swift  File + Neovim menu commands
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
└── Assets.xcassets/      AccentColor colorset + AppIcon.appiconset (T9.3)
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
