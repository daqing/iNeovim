# iNeovim

A Neovim GUI for macOS with a fully native Mac experience.

## Overview

iNeovim embeds Neovim and renders its UI as a first-class macOS application. The
goal is not merely to wrap Neovim in a window, but to deliver the best Neovim GUI
available — one that feels indistinguishable from a native Mac app.

![iNeovim editing a Swift file](docs/screenshots/editor.png)

All nine phases of the task plan are implemented; see **Status** below.

## Goals

iNeovim aims for a complete native Mac experience, including:

- **Native rendering** — crisp text rendering at the quality level of Apple's own apps
- **Smooth scrolling and fluid animations** — proper momentum scrolling and
  cursor/visual feedback, without tearing or jitter
- **System-grade font rendering** — correct kerning, ligatures, and Retina-quality
  antialiasing via Core Text
- **Native keyboard experience** — macOS key handling and native shortcuts
- **System integration** — input methods (IME), the Emoji & Symbols panel, and other
  macOS services working as they do in any native app
- **Native terminal pane** — `:terminal` opens a real [Ghostty](https://ghostty.org)
  terminal docked beside the editor instead of a terminal buffer inside Neovim

## Architecture

iNeovim embeds a Neovim instance and implements the GUI protocol:

- **Neovim embedding** — Neovim runs as a child process via `nvim --embed`;
  the GUI communicates with it over the msgpack-RPC API.
- **RPC layer** — a small, hand-rolled MessagePack codec (no third-party
  dependency; msgpack-RPC needs only a small type subset, plus ext types for
  buffer/window/tabpage handles). Concurrency is structured around actors and
  async/await:
  - `NvimProcess` owns the child-process lifecycle (launch, stdio pipes,
    termination).
  - `MsgPackCodec` is a stateless, incremental decoder — msgpack-RPC over stdio
    has no length prefix, so incoming bytes are buffered and parsed object by
    object.
  - `RPCSession` (actor) matches responses to requests by msgid via checked
    continuations (`func call(_:params:) async throws`), and dispatches
    notifications.
  - `NvimClient` exposes a typed API on top and turns `redraw` notifications
    into an `AsyncStream` of strongly-typed events (`gridLine`, `gridScroll`,
    `cursorGoto`, …), so the rendering layer never touches raw msgpack.
  - The RPC layer runs off the main actor so the read loop and redraw traffic
    never block the UI.
- **Hybrid AppKit + SwiftUI UI layer**:
  - **AppKit** renders the editor grid through a custom `NSView`, using
    **Core Text + CALayer** (no Metal). AppKit is chosen for rendering performance:
    the text grid repaints at high frequency (scrolling, cursor blink, animations),
    and an AppKit custom view gives direct control over the draw pipeline that
    SwiftUI does not provide.
  - **SwiftUI** provides the application shell — window chrome, tabs, settings, and
    other surrounding UI — bridging to the AppKit view via `NSViewRepresentable`.
- **Input handling** — `NSEvent` translation stays thin and complete:
  - *Keyboard*: `keyDown(with:)` translates to Neovim key notation
    (`nvim_input`), assembled from `charactersIgnoringModifiers` plus modifier
    state (so Ctrl chords don't arrive as control characters). Cmd is reserved
    for macOS conventions — `performKeyEquivalent` serves the app's own
    shortcuts first; remaining Cmd chords may optionally pass through as `<D->`.
    Option is configurable as Meta (`macosOptionAsMeta`) or left to produce
    system characters.
  - *IME*: the render view implements the full `NSTextInputClient` protocol.
    Marked (preedit) text is drawn by the GUI at the cursor with an underline
    and is only sent to Neovim on `insertText`; `firstRect(forCharacterRange:)`
    returns the cursor's exact screen position so IME candidate windows anchor
    to it.
  - *Mouse*: press/drag/release map to `nvim_input_mouse` (drag = visual
    selection).
  - Input is organized into `KeyInputHandler`, `IMEHandler`, `MouseHandler`,
    and `ScrollController` components feeding a unified `InputEvent` stream
    into `NvimClient`.
- **Scroll and animation strategy** — Neovim's grid is line-discrete, so
  pixel-smooth scrolling is composited GUI-side: logical scrolling goes through
  Neovim, visual interpolation through Core Animation.
  - Trackpad deltas and phases (`NSEventPhase` began/changed/ended/momentum)
    drive the scroll directly; momentum for traditional wheel mice is
    synthesized by the GUI.
  - Grid content lives in a `CALayer` whose pixel offset is animated by a
    `CADisplayLink`-driven animator — purely visual, never touching Neovim.
  - Accumulated pixel deltas are converted to whole lines and sent to Neovim;
    incoming `grid_scroll` events update the grid content. The offset is
    clamped (at most one screen ahead) so fast scrolling never runs past the
    content into blank space.
  - The cursor glides between positions with a short (~50–100 ms) interpolated
    animation instead of jumping.

```
┌──────────────────────────────────────┐
│  SwiftUI shell (windows, tabs, ...)  │
│  ┌────────────────────────────────┐  │
│  │ AppKit NSView (editor grid)    │  │
│  │ Core Text + CALayer rendering  │  │
│  └──────────────┬─────────────────┘  │
│                 │ msgpack-RPC        │
│  ┌──────────────▼─────────────────┐  │
│  │ nvim --embed, one per window  │  │
│  └────────────────────────────────┘  │
└──────────────────────────────────────┘
```

## Status

Phases 1–9 of the task plan are implemented. The app embeds `nvim --embed`,
renders the linegrid UI with Core Text + `CALayer`, handles keyboard/IME/mouse
input, provides smooth scrolling and cursor animation, and ships a native app
shell (Neovim tabpages, settings window, File/Neovim menus, window title from
`set_title`, Open With / drag-and-drop file opening, and crash recovery with
in-place restart). Each window (⌘N) runs its own embedded Neovim session,
starting in `$HOME`. Phase 9 adds the app icon, the `com.mzevo` bundle identifier,
the MIT license, performance baselines and Instruments signposts, and a
documented notarization/release flow.

The test suite covers the codec, redraw parsing, UI state, input, scrolling,
settings, crash recovery, render smoke tests, and an embedded `:terminal`
sanity check. See `docs/TASKS.md` for the plan, `docs/VERIFICATION.md` for manual
checks, `docs/PERFORMANCE.md` for profiling, and `docs/RELEASE.md` for shipping.

### Native terminal pane

Typing `:terminal` opens a native terminal pane docked to the right of the
editor — a real Ghostty terminal surface (libghostty), not a terminal buffer
inside Neovim. The pane starts in Neovim's working directory
(`:term <cmd>` runs a command instead of a shell), mirrors the editor's font
and colors, and follows `⌃\`` or **Neovim ▸ Toggle Terminal Pane**. The
interception can be disabled in Settings to fall back to Neovim's in-buffer
terminal. The embedded GhosttyKit binary and its adapted Swift bindings are
vendored under `Packages/GhosttySupport` (built from a pinned Ghostty source
snapshot; see its `ADAPTATION.md`).

## Requirements

- macOS 14.6 or later
- Neovim 0.9 or later (the embedded binary is located automatically; when it
  is missing, the app walks you through `brew install neovim` on launch)
- Xcode 26.3 or later (only to build from source)

## Install

There is no published binary yet; build from source:

1. Install Neovim 0.9 or later, for example `brew install neovim`.
2. Clone and open the project:

   ```sh
   git clone https://github.com/daqing/iNeovim.git
   cd iNeovim
   open iNeovim.xcodeproj
   ```

3. Select the `iNeovim` scheme and run (⌘R).

There is no command-line build script or CI at this time. Release builds are
archived, notarized, and stapled following `docs/RELEASE.md`.

## License

[MIT](LICENSE) © 2026 David Zhang
