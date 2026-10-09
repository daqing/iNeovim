# Verification

Manual and automated checks for behavior that cannot be proven by unit tests
alone. Runnable tests live in `iNeovimTests/`; run them from Xcode (⌘U) or:

```
xcodebuild test -project iNeovim.xcodeproj -scheme iNeovim -destination 'platform=macOS'
```

## Embedded terminal sanity check (T8.7)

The embedded `nvim` is a normal child process of an **unsandboxed** app, so
`:terminal` can create a PTY and spawn a shell like any other terminal. The
App Sandbox was dropped in T1.6 (the child could not locate the user's `nvim`
or read `~/.config/nvim` under it); `ENABLE_HARDENED_RUNTIME` stays on for
Release.

Automated check: `EmbeddedTerminalTests.testEmbeddedTerminalStarts` waits for
the app's embedded session to handshake, runs `:terminal`, and asserts that the
current buffer name contains `term`. It skips when no `nvim` is installed. The
test host is the real app, so a pass exercises the same launch path as the
shipped build.

Manual check in the GUI:

1. Launch the app and wait for the grid to appear.
2. Choose **Neovim ▸ Open Terminal** (or run `:terminal` from normal mode).
3. A terminal buffer opens in the grid; type `echo $0` and press Return.

Expected: the shell runs, prints its path, and accepts input. Failure modes to
watch for in Console (`log stream --predicate 'subsystem == "…"'`): PTY open or
`exec` failures, or nvim reporting "Failed to start terminal".

## CJK rendering and IME input

Neovim marks double-width characters by following them with an empty-text
continuation cell in `grid_line`; cell widths come from that protocol, and
glyphs are drawn pinned to cell origins (`CellRenderer.shiftGroups`), because
fallback fonts (PingFang for CJK, Apple Color Emoji) advance by their own
metrics and would otherwise drift off the grid. Automated checks:
`CellRendererTests` (slot mapping and pin groups, including a real fallback
shaping case) and the CJK/emoji lines in `RenderSmokeTests`.

Manual check in the GUI:

1. Open a file containing mixed CJK/ASCII/emoji lines (e.g.
   `中文abc测试emoji 👋 x`) in insert or normal mode.
2. Scroll and edit across those lines.

Expected: CJK glyphs each occupy exactly two cells and stay aligned with the
ASCII grid, backgrounds/underlines match the text, and the block cursor covers
both cells of a CJK glyph. With a Chinese IME: composing shows the preedit at
the cursor (wide chars spanning two cells, selection bar at the caret), the
candidate window anchors below it, and committed text inserts and renders
aligned.

## App shell checks

- **Tabs (T8.2):** **Neovim ▸ New Tab** opens a tabpage and the tabline shows
  it; ⌘T creates a tab without leaving the keyboard; **Next/Previous Tab** and
  `gt`/`gT` move between tabpages; ⌘1…⌘9 jump straight to the Nth tab.
- **Settings (T8.3):** ⌘, opens Settings. Changing font/size reflows the grid;
  Option-as-Meta and Command passthrough change key behavior immediately.
- **Window title (T8.5):** opening a file updates the window title from
  neovim's `set_title`.
- **File opening (T8.6):** dragging a text file onto the editor opens it as a
  buffer, as does Finder's **Open With ▸ iNeovim** and dropping it on the Dock
  icon.
- **Setup guide (no nvim):** on a machine where Neovim is not installed,
  launch shows install guidance instead of the editor — `brew install neovim`
  with a copy button when Homebrew exists, otherwise a brew.sh link — and
  **Recheck** starts the session once Neovim is installed.
- **Nvim exit handling:** `:q`/`:qa` on the last tab closes the window
  silently (and quits the app when no editor window remains) with no dialog;
  an abnormal exit (e.g. `kill` the nvim process) still shows the
  **Neovim exited** alert with **Restart**.
- **Multiple windows (⌘N):** ⌘N opens a new window running its own embedded
  Neovim in `$HOME` (`:pwd`); typing, scrolling, and tab shortcuts act on the
  focused window only; menu commands and ⌘O opens route to the key window;
  closing one window leaves the others' sessions running.
