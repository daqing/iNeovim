# iNeovim

A Neovim GUI for macOS with a fully native Mac experience.

## Overview

iNeovim embeds Neovim and renders its UI as a first-class macOS application. The
goal is not merely to wrap Neovim in a window, but to deliver the best Neovim GUI
available — one that feels indistinguishable from a native Mac app.

The project is at an early stage. See **Roadmap / Status** below.

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
│  │ nvim --embed (child process)   │  │
│  └────────────────────────────────┘  │
└──────────────────────────────────────┘
```

## Status

Phases 1–8 of the task plan are implemented: the app embeds `nvim --embed`,
renders the linegrid UI with Core Text + `CALayer`, handles keyboard/IME/mouse
input, provides smooth scrolling and cursor animation, and ships a native app
shell (Neovim tabpages, settings window, File/Neovim menus, window title from
`set_title`, and Open With / drag-and-drop file opening). The test suite covers
the codec, redraw parsing, UI state, input, scrolling, settings, and an embedded
`:terminal` sanity check.

Phase 9 (polish and release) is still open: no app icon, license, or
notarization/release pipeline yet. See `docs/TASKS.md` for the full plan and
`docs/VERIFICATION.md` for manual checks.

## Requirements

- macOS 14.6 or later
- Xcode 26.3 or later
- Neovim 0.9 or later (the embedded binary is located automatically)

## Building

Open `iNeovim.xcodeproj` in Xcode and build/run the `iNeovim` scheme.
There is no command-line build script or CI at this time.

## License

TBD
