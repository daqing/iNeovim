# iNeovim — Task Plan

A step-by-step development plan derived from the architecture in `README.md`.
Tasks are numbered `T<phase>.<step>` and ordered so that each phase builds on the
previous one. Each task is sized to be completable in one sitting. Verify changes
in Xcode after each task (no command-line builds).

- Chinese version: `TASKS.zh-CN.md`
- Conventions: follow `AGENTS.md` (no `main`-branch commits, no Metal, no
  third-party dependencies without discussion).

## Phase 1 — Foundations

- **T1.1** Add structured logging with `os.Logger` (categories: `rpc`, `render`,
  `input`, `app`). All later phases depend on this for debugging.
- **T1.2** Neovim discovery: locate the `nvim` binary (config override → `PATH` →
  common locations such as `/opt/homebrew/bin`, `/usr/local/bin`) and read its
  version (`nvim --version`) to enforce the minimum API level.
- **T1.3** Decide and document the `ext_multigrid` policy: single-grid for v1,
  but keep grid IDs in all redraw handling so multigrid can be enabled later.
- **T1.4** App lifecycle: launch/terminate the embedded `nvim` together with the
  app (clean teardown on quit, kill on crash).
- **T1.5** Project hygiene: add `.gitignore` for `xcuserdata/` and other
  user-specific Xcode state.
- **T1.6** Sandbox entitlement review: resolved by **removing the App Sandbox**
  (`ENABLE_APP_SANDBOX = NO`). Under the sandbox the child `nvim` could not be
  located at all (the window stayed blank) and could not read `~/.config/nvim` or
  project files; `user-selected-files` did not cover a real editor workflow. The
  Release build keeps the hardened runtime.

## Phase 2 — MessagePack codec

Hand-rolled, no third-party dependency. Pure, stateless, and testable.

- **T2.1** Define the `Value` enum: nil, bool, int, uint, float, string, binary,
  array, map, ext.
- **T2.2** Encoder: `Value` → bytes for all msgpack types.
- **T2.3** Incremental decoder: maintain a byte buffer, parse one object at a
  time, and signal "need more bytes" when a partial object arrives (stdio has no
  length prefix).
- **T2.4** Map ext types 0/1/2 to strongly-typed `Buffer` / `Window` / `Tabpage`
  handles.
- **T2.5** Round-trip tests for the codec (requires adding an XCTest target in
  Xcode — the project has none yet).

## Phase 3 — RPC layer

- **T3.1** `NvimProcess`: spawn `nvim --embed` with stdin/stdout/stderr pipes;
  forward stderr to the `rpc` log.
- **T3.2** Read loop: a background `Task` that reads stdout continuously and
  feeds the incremental decoder.
- **T3.3** `RPCSession` actor: msgid allocation, request/response matching via
  checked continuations, `func call(_:params:) async throws -> Value`.
- **T3.4** Notification dispatch: route msgpack-RPC notifications to registered
  handlers.
- **T3.5** Failure propagation: on process exit or pipe EOF, fail all pending
  continuations and notify the UI layer.
- **T3.6** Handshake: call `nvim_get_api_info` on startup, store the channel id,
  and verify API compatibility.
- **T3.7** `NvimClient`: typed convenience API over `RPCSession`
  (`nvim_ui_attach`, `nvim_input`, `nvim_input_mouse`, `nvim_command`,
  `nvim_call_atomic`, `nvim_ui_try_resize`, …).

## Phase 4 — UI protocol and grid model

- **T4.1** Parse `redraw` notifications into a strongly-typed event enum:
  `gridLine`, `gridScroll`, `gridClear`, `gridResize`, `cursorGoto`,
  `hlAttrDefine`, `defaultColorsSet`, `modeChange`, `flush`, etc.
- **T4.2** Highlight model: `HlAttr` storage keyed by attr id, resolving
  foreground/background/special and text attributes.
- **T4.3** Grid model: cell storage with `grid_line`, `grid_scroll`,
  `grid_clear`, `grid_resize` application.
- **T4.4** Resize plumbing: view resize → cell-count recompute →
  `nvim_ui_try_resize` (debounced during live resize).
- **T4.5** Mode and cursor state tracking (`mode_change`, `cursor_goto`,
  `mode_info_set` for cursor shapes).
- **T4.6** Expose the event stream to the render layer as an `AsyncStream`
  (single consumer, off the main actor).

## Phase 5 — Rendering (Core Text + CALayer)

- **T5.1** Font pipeline: configurable `NSFont`, cell width/height metrics,
  ascent/descent for baseline placement.
- **T5.2** Render view skeleton: layer-backed custom `NSView`, background filled
  from default colors.
- **T5.3** Cell renderer: build `CTLine`s per styled run; apply bold, italic,
  underline, undercurl, strikethrough, fg/bg/sp from `HlAttr`.
- **T5.4** Ligatures: shape contiguous runs through Core Text so ligatures
  (Fira Code etc.) render correctly.
- **T5.5** Wide characters: double-width and combining characters occupy cells
  correctly (wcwidth-style handling, matching Neovim's cell model).
- **T5.6** Cursor rendering per mode (block/horizontal/vertical, percentage
  widths from `mode_info_set`) with blink support.
- **T5.7** Dirty-region coalescing: batch `grid_line` updates per `flush` and
  invalidate minimal rects only.
- **T5.8** Retina handling: `contentsScale`, pixel-snapped cell rects.
- **T5.9** Appearance: dark/light mode and `guibg`-driven background handling.

## Phase 6 — Input

- **T6.1** `KeyInputHandler`: `keyDown(with:)` → Neovim key notation using
  `charactersIgnoringModifiers` + modifier state; full special-key table
  (`<BS>`, `<CR>`, `<Esc>`, arrows, function keys, …).
- **T6.2** Cmd handling: `performKeyEquivalent` serves app shortcuts first;
  remaining Cmd chords optionally pass through as `<D->` (configurable).
- **T6.3** `macosOptionAsMeta` setting: Option as `<M->` vs. system characters.
- **T6.4** `IMEHandler`: full `NSTextInputClient` implementation
  (`insertText`, `setMarkedText`, `hasMarkedText`, `unmarkText`,
  `selectedRange`, `attributedSubstringForProposedRange`, …).
- **T6.5** Marked text UX: draw preedit text at the cursor with underline;
  implement `firstRect(forCharacterRange:)` so IME candidate windows anchor to
  the cursor (verify view → window → screen coordinate conversion).
- **T6.6** `MouseHandler`: press/drag/release → `nvim_input_mouse`
  (drag = visual selection); modifier + click combinations.
- **T6.7** Unified input flow: all handlers emit a single `InputEvent` stream
  into `NvimClient`.
- **T6.8** Layout edge cases: dead keys and non-US keyboard layouts.

## Phase 7 — Scroll and animation

- **T7.1** `ScrollController`: trackpad deltas and `NSEventPhase`
  (began/changed/ended/momentum); synthesize momentum for traditional wheels.
- **T7.2** Pixel-offset layer: grid content in a `CALayer` with a
  `CADisplayLink`-driven animator for the visual offset.
- **T7.3** Logical sync: accumulate pixel deltas → whole lines → send scrolls to
  Neovim; apply incoming `grid_scroll` events to the grid.
- **T7.4** Offset clamping: cap visual lead at one screen so fast scrolling
  never reveals blank space.
- **T7.5** Cursor glide: interpolate cursor position over ~50–100 ms instead of
  jumping.
- **T7.6** Animation tuning: curves, and 120 Hz ProMotion behavior.

## Phase 8 — App shell (SwiftUI)

- **T8.1** Replace the template `ContentView`: window shell hosting the render
  view via `NSViewRepresentable`.
- **T8.2** Tabs: decide Neovim tabpages vs. native window tabs; implement the
  chosen model.
- **T8.3** Settings UI: font family/size, `macosOptionAsMeta`, scroll/cursor
  animation toggles.
- **T8.4** Native menu bar: standard app menus plus Neovim-relevant commands.
- **T8.5** Window title from the `set_title` redraw event.
- **T8.6** File opening: "Open With" / drop-on-icon → open in a running instance.
- **T8.7** nvim-embedded terminal sanity check (requires T1.6 entitlements).

## Phase 9 — Polish and release

- **T9.1** Error surfacing: nvim crash/exit dialog with restart option.
- **T9.2** Performance pass with Instruments: render hot path, RPC throughput,
  scroll frame pacing.
- **T9.3** App icon in `Assets.xcassets`.
- **T9.4** Replace the `devplaceholder` bundle ID prefix with a real
  reverse-DNS identifier.
- **T9.5** Choose a license and add the `LICENSE` file; update both READMEs.
- **T9.6** Distribution: signing, notarization, and release flow from Xcode
  archives.
- **T9.7** Final documentation: screenshots, install instructions, and status
  updates in `README.md` / `README.zh-CN.md`.
