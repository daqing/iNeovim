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
the app's embedded session to handshake, runs `:terminal` over RPC, and
asserts that the current buffer name contains `term`. It skips when no `nvim`
is installed. The test host is the real app, so a pass exercises the same
launch path as the shipped build. Note that this drives `nvim_command`
directly — the typed-`:terminal` interception below never sees it, so the
in-buffer terminal remains reachable through RPC, mappings, and plugins.

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

- **Tabs (native window tabs):** ⌘T opens a new editor window as a native
  macOS tab of the current window's tab group (own embedded nvim; the tab bar
  appears with two or more tabs); the tab bar's **+** button does the same;
  typed `:tabnew [file]` / `:tabe[dit] [file]` also open a native tab and
  resolve the file against nvim's cwd; **Next/Previous Tab** and ⌘1…⌘9 switch
  native tabs; **Close Tab** (⌘⇧W) closes the current tab; nvim tabpages stay
  reachable through `gt`/`gT` and `:tabnext`-style commands.
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
- **Diagnostics popover:** in a Go (or any LSP) project with a diagnostic on
  screen, click the error sign in the gutter ("E" left of the line number): a
  native popover appears anchored there listing severity, message, and
  `source · code`; click outside, type, or scroll to dismiss. Clicking a
  gutter cell on a clean line behaves exactly like before (the click reaches
  nvim, e.g. it toggles a fold when a fold column is present).
- **Open a URL (⌘-click):** with a URL visible in the grid, hold ⌘ and move the
  pointer onto it: the link is underlined and the pointer becomes a hand; move
  off it (or release ⌘) and both revert. ⌘-click opens it in the default
  browser; the click (and its drag/release) never reaches nvim. The URL is read
  from the same snapshot the renderer draws, so it matches what is on screen;
  the hit test tolerates the punctuation that typically wraps a URL in prose
  (`(https://…)`, a trailing `.`) and clicks on the continuation cell of an
  adjacent double-width glyph.

## Smooth scrolling and the frozen footer

Neovim never scrolls the statusline and cmdline rows, so the app draws them in
a layer the scroll lead does not translate: the grid is split into a scrolling
region and a frozen footer (`GridContentLayer.rowSlice`), and the scrolling
region is clipped to its own rows. Drawing the whole grid in one translated
layer let the statusline text slide off its bar mid-gesture.

Manual check in the GUI:

1. Open a long file and scroll with a precision trackpad gesture that moves
   the grid by less than one line (a slow two-finger drag).
2. Watch the statusline row while the text above it is still moving.

Expected: the statusline text and its full-width bar stay planted; at most a
sub-cell band of blank background opens between the last text row and the
statusline, and it closes as soon as the gesture settles. Scrolling the other
way shows the mirror behavior (blank at the top edge, footer still planted).
Automated check: `FrozenFooterTests` pins the row slices, the layers' tiling,
and which layer draws a cursor in the cmdline row.

## Native terminal pane (Ghostty)

A typed `:terminal` opens a native Ghostty terminal pane docked to the right
of the editor instead of an in-buffer terminal. Manual checks:

1. Type `:terminal` and press Return: the cmdline cancels (no nvim terminal
   buffer), the pane slides in on the right, focus moves into it, and the
   pane's shell starts in nvim's working directory (`:pwd` matches `pwd` in
   the pane). The nvim grid reflows to the narrower editor area.
2. Type `:term git status`: the pane runs that command instead of a shell.
3. ⌘D (or ⌃`) or **Neovim ▸ Toggle Terminal Pane** toggles the
   pane; both work while the pane has focus too. Dragging the divider resizes
   the pane (280 pt…60% of the window) and the editor follows live.
4. ⌘⇧T (**Neovim ▸ Switch Focus Between Editor and Terminal**) moves focus
   between the editor and the pane in both directions, opening the pane when
   hidden. Typing lands in whichever side now has focus.
5. `:terminal` while the pane is open just focuses it. Typing `exit` in the
   pane (or the ⓧ button) closes the pane and returns focus to the editor.
6. Settings ▸ Terminal ▸ "Open :terminal in native pane" off: `:terminal`
   falls back to nvim's in-buffer terminal; ⌘D/⌃`/the menu still open the pane.
7. The pane's font and colors follow the editor (font/size from settings,
   background/foreground from nvim's colorscheme at open time).
8. Multiple windows (⌘N) each own a pane; closing a window cleans up its
   surface; IME composition works inside the pane.

Automated checks: `TerminalPaneCommandTests` pins the cmdline matcher
(abbreviations, `vert[ical]`, bang, arguments, non-matches).
