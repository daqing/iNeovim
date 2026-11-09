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

## Gutter padding

nvim's gutter columns (sign, fold, number) are whole cells wide, so the 2 pt
gap between buffer text and the gutter is drawn by the renderer: the glyphs,
the block cursor, the IME preedit, and the ⌘-hover underline of a window's
text area sit 2 pt right of their cells, while the gutter itself stays on the
grid. nvim pushes each window's text area (rows plus the columns past
`textoff`) as `ineovim:textlayout`; `NvimClient.installTextLayoutHook` keeps
it current.

Manual check in the GUI:

1. Open a file with `number` on: the text starts 2 pt clear of the number
   column. A vertical split keeps the gap in both windows.
2. Make a sign column appear (`:set signcolumn=yes`, an LSP diagnostic, or a
   gitsigns change) and collapse again (`:set signcolumn=auto`): the text
   keeps its 2 pt gap and no row is left 2 pt off.
3. Turn `number` off with no sign column: the text starts at the normal left
   inset, with no extra indent.

## Sidebar divider and split separators

The NERDTree sidebar keeps a fixed width. A left press on the divider at its
right edge is swallowed before it reaches nvim, so the divider cannot be
dragged and nvim cannot start a window resize.

Manual check in the GUI:

1. Open NERDTree and drag the divider at the sidebar's right edge: it does
   not move, the sidebar keeps its width, and no stale vertical bars appear.
2. Drag the divider between two ordinary editor splits: it still resizes.
3. Click NERDTree entries: the highlight stays inside the sidebar (no
   full-width horizontal band).

## Soft wrap

The app enables nvim's own `wrap` before `ui_attach`, because a single
linegrid has no horizontal scrolling: a line wider than the window would
otherwise be unreachable past the right edge. An embedded nvim defers
startup until the UI attaches, so bootstrap's command runs before `init.lua`;
`installWrap` therefore re-applies `wrap` from a one-shot `VimEnter` autocmd
so the user config's `set nowrap` cannot win.

Manual check in the GUI:

1. Open a file with a line longer than the editor width (with the user's
   config, `:set nowrap` is overridden by the app).
2. Confirm the line continues on the following screen rows, that only the
   first row carries the line number (the number column is blank on the
   continuation rows), and that the next buffer line keeps its own number.
3. With an LSP diagnostic on such a line, click the gutter on any of its
   screen rows: every row maps to the same buffer line and shows the same
   popover.
4. Scroll with the wheel: Neovim scrolls whole buffer lines (one long
   wrapped line can move several rows at once), and the transient scroll
   thumb still appears because it measures buffer lines.

## Truncated long lines

Requires nvim 0.13+. On 0.12 the hook stays off (the unified log shows
"Truncated lines off: needs nvim 0.13+") because nvim 0.12's conceal_lines +
virt_lines scroll implementation LOOPS upward scrolling next to preview rows
(measured on 0.12.5 with the layout below: topline bounces 37→35→37 forever;
upstream neovim#42317/#42077, fixed only on master for 0.13). On a gated
nvim, verify over-long lines simply keep their normal wrapped rows and that
wheel-up scrolls through them normally.

A buffer line whose display width exceeds 280 cells collapses to a one-row
preview ending in `…` (`installTruncatedLines` — `conceal_lines` extmark plus
a one-row `virt_lines` preview, `conceallevel` owned at 2); clicking the
preview row opens the full line in `LineContentPopover`. A run that reaches
the buffer's last line hangs its previews BELOW the last unconcealed line
before the run (there is no following line to hang above; a below-mark on
the concealed last line itself is swallowed), and a run covering the whole
buffer stays unconcealed. Manual checks (on nvim 0.13+):

1. Open a file with a 400+ character line between normal lines: the long
   line shows as a single row ending in `…` — not its 7 wrapped rows — while
   the normal lines around it still soft-wrap as before.
2. Plain-click the preview row: a popover shows the full line text, wraps it
   at the popover width, is selectable (copyable), and scrolls for very long
   lines; clicking anywhere else (or typing, scrolling) dismisses it.
3. A long RUN (several adjacent over-long lines, e.g. three or more):
   one preview row per line, in buffer order — an eight-line run draws
   its previews top-to-bottom in the same order as the lines (same-anchor
   virt marks would scramble them; the run shares one extmark instead).
4. With the cursor resting on a truncated line (normal mode), the line
   stays folded; entering insert mode on it reveals the full line for
   editing, and leaving insert folds it again.
5. Delete characters until the line drops under 280 cells: it expands back
   to full wrapped display without a restart (`TextChanged` rescan).
6. Open a file whose LAST line is over-long (e.g. a huge close-out bullet
   at the end of a TASKS doc): it folds to a one-row preview like any other
   line, sitting directly under the previews of the run it joins; clicking
   it opens the full last line.
7. Resize the window wider: the preview grows to the new width and keeps its
   `…` visible at the right edge (`WinResized` rescan).
8. The scroll thumb's proportions drift by the hidden rows on such files
   (the Lua metric counts buffer lines) — known, informational only.

## Last working directory

The launch window resumes in the directory the last session was in, saved as
the app quits. A window an `ineovim` command opens uses the directory the
command ran in instead, never the saved one.

Manual check in the GUI:

1. Launch the app, `:cd` into a project, and quit (⌘Q). Launch it again by
   clicking the app icon: the window's `:pwd` is that project, not `$HOME`.
2. With the app not running, run `ineovim` from a different directory: its
   window's `:pwd` is that directory — not the one saved in step 1 — and the
   file named on the command line is the current buffer.
3. Quit, rename (or move) the saved directory, and launch by clicking the
   app: the window starts in `$HOME` instead of failing.

## App shell checks

- **Tabs (native window tabs):** ⌘T opens a new editor window as a native
  macOS tab of the current window's tab group (own embedded nvim; the tab bar
  appears with two or more tabs); the tab bar's **+** button does the same;
  typed `:tabnew [file]` / `:tabe[dit] [file]` also open a native tab and
  resolve the file against nvim's cwd; **Next/Previous Tab** and ⌘1…⌘9 switch
  native tabs; **Close Tab** (⌘⇧W) closes the current tab; nvim tabpages stay
  reachable through `gt`/`gT` and `:tabnext`-style commands.
- **Typed quit (`:q`):** with two or more native tabs, type `:q` and press
  Return in any tab: the alert asks **Close Tab?** — not "Quit iNeovim?" — and
  confirming closes only that tab while the other tabs' sessions keep
  running; Cancel leaves the tab alone and dismisses the cmdline. A
  standalone window beside another editor window asks **Close Window?**, and
  only the last editor window asks **Quit iNeovim?**; the red close button
  uses the same wording as the typed command would.
- **Settings (T8.3):** ⌘, opens Settings. Changing font/size reflows the grid;
  Option-as-Meta and Command passthrough change key behavior immediately.
  Layout ▸ Left/Right padding moves the grid live and reflows the column
  count; the right slider cannot go below the scroll indicator's strip, so
  the wheel's thumb never covers text.
- **Window title (T8.5):** opening a file updates the window title from
  neovim's `set_title`.
- **File opening (T8.6):** dragging a text file onto the editor opens it as a
  buffer, as does Finder's **Open With ▸ iNeovim** and dropping it on the Dock
  icon.
- **Setup guide (no nvim):** on a machine where Neovim is not installed,
  launch shows install guidance instead of the editor — `brew install neovim`
  with a copy button when Homebrew exists, otherwise a brew.sh link — and
  **Recheck** starts the session once Neovim is installed.
- **Nvim exit handling:** a clean exit — after confirming the typed quit, or
  from a path the gate never sees (`:wq`, `:x`, a mapping, a plugin) — closes
  the window silently (and quits the app when no editor window remains) with
  no second dialog; an abnormal exit (e.g. `kill` the nvim process) still
  shows the **Neovim exited** alert with **Restart**.
- **Multiple windows (⌘N):** ⌘N opens a new window running its own embedded
  Neovim in `$HOME` (`:pwd`); typing, scrolling, and tab shortcuts act on the
  focused window only; menu commands and ⌘O opens route to the key window;
  closing one window leaves the others' sessions running.
- **Diagnostics popover:** in a Go (or any LSP) project with a diagnostic on
  screen, click the error sign in the gutter ("E" left of the line number): a
  native popover appears anchored there listing severity, message, and
  `source · code`; click outside, type, or scroll to dismiss. Clicking a
  gutter cell on a clean line behaves exactly like before (the click reaches
  nvim, e.g. it toggles a fold when a fold column is present). The message is
  shown in full: a one-line message (e.g. pycodestyle's `E302 expected 2
  blank lines, found 1`) fits entirely instead of losing its last word, and a
  long message wraps inside the popover at its 440 pt cap.
- **Problems panel (⌘P):** in a project with LSP diagnostics, press ⌘P (or
  use **Neovim ▸ Toggle Problems**): the issues sidebar docks at the window's
  left edge, listing every error/warning/info/hint with counts in the header.
  A long message wraps to the panel width and is shown in full above its
  dimmed `file:line` — no ellipsis — and dragging the divider between the
  panel and the editor re-wraps every message at the new width. Selecting a
  row (click or arrow keys) jumps the editor while the panel keeps focus; an
  empty list reads "No problems"; the header ✕ closes the panel.
- **Open a URL (⌘-click):** with a URL visible in the grid, hold ⌘ and move the
  pointer onto it: the link is underlined and the pointer becomes a hand; move
  off it (or release ⌘) and both revert. ⌘-click opens it in the default
  browser; the click (and its drag/release) never reaches nvim. The URL is read
  from the same snapshot the renderer draws, so it matches what is on screen;
  the hit test tolerates the punctuation that typically wraps a URL in prose
  (`(https://…)`, a trailing `.`) and clicks on the continuation cell of an
  adjacent double-width glyph.

## Markdown preview (⌘R)

A Markdown buffer opens a separate read-only reading window; other buffers
keep ⌘R for the terminal pane.

Manual checks in the GUI:

1. Open a `.md` file and press ⌘R: a separate window renders headings,
   bold/italic, lists, code blocks, quotes, and links using the editor's
   colors; the editor stays put and the preview takes focus.
2. Open a page with a fenced ASCII or box-drawing architecture diagram (the
   README architecture block is one): the code block keeps its monospaced
   alignment and does **not** wrap; a line wider than the 720 pt reading
   column scrolls horizontally inside the code block.
3. Edit the buffer without saving and press ⌘R again: the same preview window
   comes forward with the new contents.
4. Press ⌘R in a non-Markdown buffer: the terminal pane is focused (or opens);
   the menu's "Preview Markdown" beeps instead.
5. Click an http link: the browser opens. A relative link to another file
   opens in the editor.
6. Resize the preview: the reading column stays capped around 720 pt and the
   text reflows; ⌘W closes it.

Automated checks: `MarkdownRendererTests` covers headings, list markers,
inline bold, links, relative-link resolution, HTML escaping, code-block
whitespace preservation / no-wrap CSS, and Markdown buffer detection.

## Smooth scrolling across grids

With ext_multigrid every window, float, and the message area is its own grid
drawn in its own clip layer; the scroll lead translates ONLY the grid the
gesture grabbed, so the statusline row (global grid), other splits, and floats
cannot move mid-gesture by construction. The grabbed grid's clip layer keeps
its content inside its rows, which replaces the old frozen-footer split
(`GridContentLayer.rowSlice` is retired).

Manual check in the GUI:

1. Open a long file and scroll with a precision trackpad gesture (a two-finger
   drag that scrolls the grid).
2. Watch the statusline row while the text above it is still moving.
3. Lift the fingers and keep watching until the momentum dies out.

Expected: the statusline text and its full-width bar stay planted; at most a
one-line band of blank background opens between the last text row and the
statusline, and it closes as soon as Neovim confirms the line. The content must
not slide back after the gesture ends — the lead is whole lines only, so there
is no sub-line remainder to give up (a snap-back here means the lead is being
drawn from `credit` instead of `sent`). Scrolling the other way shows the
mirror behavior (blank at the top edge, statusline still planted). With two
side-by-side splits, wheeling one must not move the other, and the cursor
stays put.
Automated check: `GridLayerTests` pins the per-grid box layering, z order, and
cursor ownership; `ScrollAccumulatorTests`
pins the whole-line lead and its confirmation.

Wheel check (traditional mouse wheel, no trackpad):

1. Scroll through a long file at a steady pace, then spin the wheel fast.
2. Watch the leading edge of the text and then scroll at the top or bottom of
   the buffer.

Expected: each notch moves the content in the wheel's own frame (no step
waiting for the round trip), with at most one line of background at the
leading edge until Neovim's `grid_scroll` paints the revealed row a frame or
two later; the text never jumps back. At the buffer's edge the one-line lead
is held only while the wheel is moving and eases back once it stops, instead
of staying blank. Automated check: `ScrollAccumulatorTests` pins the one-line
lead, the burst clamp, and the confirmation.

Scroll indicator:

1. Scroll a long file with the wheel and with a trackpad: a rounded thumb
   appears at the right edge from the first delta and follows the viewport
   (top of the buffer → thumb at the top, `G`/bottom → at the bottom, a short
   buffer → a long thumb), spanning the text rows only, not the statusline
   and cmdline rows. The thumb sits in the window's right margin beside the
   text — 2 pt clear of the last character of a row — so it never covers it.
2. Stop scrolling: the thumb fades out about 0.7 s after the last delta, and
   moving the wheel again brings it back at once.
3. Open a file shorter than the window and scroll: no thumb appears.
4. Switch the colorscheme between dark and light: the knob inverts with the
   theme.

Automated check: `ScrollMetricsTests` pins the thumb proportion and the
clamped position.

## Overlay grid backgrounds (floats and the message grid)

A grid layered above another grid's cells must paint its OWN default
background: the view's background layer sits under the base grid and the
tiled window grids, but under a float or the message grid sits another
grid's text, so a skipped default-background fill is a hole it shows
through. Manual checks:

1. Open fzf (`<leader>t` or `:Files/LGrep`…): the panel is a solid block in
   the theme's background color with its own text on top — no buffer text
   bleeding through its rows.
2. Trigger an LSP hover/signature float (or `:lua vim.lsp.util.
   open_floating_preview({'hover'}, 'markdown')`): same, an opaque panel.
3. Provoke a multi-row message block (`:messages` after a few entries, or a
   cmdline error: `:call NoSuch()`) that reaches past the cmdline row: the
   block covers the buffer rows underneath it instead of blending with them,
   and the inverted statusline bar stays off the rows it covers.
4. The base grid and the window grids still leave default-background cells to
   the view's own fill, which is what keeps a scroll frame from repainting the
   whole viewport (scrolling with a truncated/highlighted file must stay as
   smooth as before).

Automated check: `GridLayerTests` renders a float layer, a window layer, and
a re-parked message layer into bitmaps and asserts the float/message pixels
are opaque and uniform while the window's stay transparent.

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
4. ⌘L (**Neovim ▸ Focus Editor**) puts keyboard focus back in the editor,
   and ⌘R (**Neovim ▸ Focus Terminal Pane**) moves it to the pane, opening
   the pane when hidden. Typing lands in whichever side now has focus, and
   both chords work while the pane has focus. Each successful switch shows a
   small rounded card at the center of the window — "Focus: Editor" or
   "Focus: Terminal" — that fades in, holds about a second, and fades out; it
   also appears when ⌘R opens a hidden pane. Clicking on the card's spot
   while it is visible still reaches the editor/pane underneath (it ignores
   the mouse), and resizing the window keeps it centered both ways.
5. `:terminal` while the pane is open just focuses it. Typing `exit` in the
   pane (or the ⓧ button) closes the pane and returns focus to the editor.
6. Settings ▸ Terminal ▸ "Open :terminal in native pane" off: `:terminal`
   falls back to nvim's in-buffer terminal; ⌘D/⌃`/the menu still open the pane.
7. The pane's font and colors follow the editor (font/size from settings,
   background/foreground from nvim's colorscheme at open time).
8. Multiple windows (⌘N) each own a pane; closing a window cleans up its
   surface; IME composition works inside the pane.
9. ⌘-click a local file path printed in the pane (absolute or project-relative):
   the file opens in the editor and the editor takes focus; the terminal pane
   stays open. A `path:line:column` suffix still resolves the file. ⌘-click an
   http(s) link: the default browser opens instead.

Automated checks: `TerminalPaneCommandTests` pins the cmdline matcher
(abbreviations, `vert[ical]`, bang, arguments, non-matches) and
`TerminalFileLinkTests` covers path resolution, line suffixes, file URLs, and
web/nonexistent/directory rejection.

## Command-line tool

**Neovim ▸ Install Command Line Tool…** installs an `ineovim` launcher into
`~/.local/bin`, `/opt/homebrew/bin`, or `/usr/local/bin` — the first in the
login shell's PATH. Manual checks:

1. Run the menu item: the success alert names the installed path (normally
   `~/.local/bin/ineovim`), and the file exists and is executable.
2. In a new terminal, `ineovim --help` prints usage. `cd` into a project and
   run `ineovim README.md`: a new window opens in front with keyboard focus,
   nvim's directory is the file's directory (`:pwd`), and the file is the
   current buffer; typing works without clicking the window first.
3. Run `ineovim /path/to/another/project/main.go` from an unrelated
   directory: the window starts in that file's directory, not in the shell's
   cwd. Run `ineovim` with no arguments: the window starts in the shell's
   current directory.
4. Run `ineovim src/main.go` from the same project: a second, independent
   window opens (the first is untouched); relative arguments resolve against
   the shell's directory, and a directory or file name containing spaces or
   non-ASCII characters works without quoting surprises.
5. `ineovim newfile.txt` creates the empty file in the shell's directory and
   opens it as a new buffer.
6. Quit the app, then run `ineovim README.md`: the launch uses the single
   window SwiftUI opens — no extra empty window — in the file's directory.
   Quit again and run `ineovim .` from a project: that same first window's
   `:pwd` is the project directory, never `$HOME` (the launch window can
   register before the URL is delivered, so a request parked for "the next
   window" would never reach it).
7. With the app already running (any number of windows open), run
   `ineovim .` once: exactly **one** new window appears — the one SwiftUI
   opens for the URL event, showing that directory — with no extra empty
   `$HOME` window beside it. Running it a second time opens exactly one more
   window of its own; existing windows are untouched.
8. On a machine where the chosen directory is root-owned (typically
   `/usr/local/bin`), the confirmation alert appears first, then the macOS
   administrator prompt; cancelling the prompt changes nothing.
9. Running the menu item again silently replaces the launcher; a foreign
   (non-iNeovim) file at that path asks Replace/Cancel first.

Automated checks: `CommandLineToolTests` pins destination selection (PATH
membership, `~/.local/bin` creation, fallback), the launcher script's
encoding/quoting, and the URL payload decoder (shell directory, first-path
directory, relative paths, directory arguments, spaces, non-ASCII names,
unrelated URLs).
