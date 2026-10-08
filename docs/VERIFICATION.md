# Verification

Manual and automated checks for behavior that cannot be proven by unit tests
alone. Runnable tests live in `iNeovimTests/`; run them from Xcode (⌘U) or:

```
xcodebuild test -project iNeovim.xcodeproj -scheme iNeovim -destination 'platform=macOS'
```

## Embedded terminal sanity check (T8.7)

The embedded `nvim` runs as a child of the sandboxed app, so `:terminal` has to
create a PTY and spawn a shell from inside the App Sandbox. T1.6 widened
`ENABLE_USER_SELECTED_FILES` to `readwrite`; no extra PTY entitlement is needed
because the child inherits the parent's sandbox.

Automated check: `EmbeddedTerminalTests.testEmbeddedTerminalStarts` waits for
the app's embedded session to handshake, runs `:terminal`, and asserts that the
current buffer name contains `term`. It skips when no `nvim` is installed. The
test host is the sandboxed app, so a pass exercises the real entitlement path.

Manual check in the GUI:

1. Launch the app and wait for the grid to appear.
2. Choose **Neovim ▸ Open Terminal** (or run `:terminal` from normal mode).
3. A terminal buffer opens in the grid; type `echo $0` and press Return.

Expected: the shell runs, prints its path, and accepts input. Failure modes to
watch for in Console (`log stream --predicate 'subsystem == "…"'`): sandbox
denials around `posix_openpt`/`exec`, or nvim reporting "Failed to start
terminal".

## App shell checks

- **Tabs (T8.2):** **Neovim ▸ New Tab** opens a tabpage and the tabline shows
  it; **Next/Previous Tab** and `gt`/`gT` move between tabpages.
- **Settings (T8.3):** ⌘, opens Settings. Changing font/size reflows the grid;
  Option-as-Meta and Command passthrough change key behavior immediately.
- **Window title (T8.5):** opening a file updates the window title from
  neovim's `set_title`.
- **File opening (T8.6):** dragging a text file onto the editor opens it as a
  buffer, as does Finder's **Open With ▸ iNeovim** and dropping it on the Dock
  icon.
