# GhosttySupport vendoring notes

`Vendor/GhosttyKit.xcframework` and the Swift sources in
`Sources/GhosttySupport/` come from Ghostty:

- **Source snapshot:** `ghostty-source.tar.gz` of the `tip` nightly release,
  **1.3.2-main+246f702** (the GitHub "tip" release asset published around
  2026-10-09). This is a commit-pinned snapshot of `ghostty-org/ghostty`
  `main`, not a stable tag: v1.3.1 pins Zig 0.15.2, which cannot link
  against the Xcode 26 SDK on this machine (libSystem symbols unresolved),
  while this snapshot pins Zig 0.16.0, which can.
- **Built with:** `zig build -Doptimize=ReleaseFast` (portable Zig 0.16.0
  from ziglang.org). On macOS this defaults to `app_runtime = .none`
  (libghostty) and emits `macos/GhosttyKit.xcframework`; this snapshot's
  build produces a single macOS-universal slice (`macos-arm64_x86_64`,
  static `ghostty-internal.a`) — no iOS slices to prune.
- **Post-build:** `strip -S` removed debug sections from the static archive
  (260 MB → 49 MB). The archive stays a valid fat static library and links
  normally; only symbolication of the Ghostty code inside a crash report is
  lost. Rebuild from the pinned source for an unstripped copy.
- **Build prerequisites on Xcode 26:** the Metal toolchain is a separate
  download (`xcodebuild -downloadComponent MetalToolchain`) — Ghostty
  compiles its Metal shaders as part of the library.
- **License:** Ghostty is MIT (`LICENSE` here). Its shell-integration
  scripts are GPLv3, so the generated Ghostty app config sets
  `shell-integration = none` — those scripts are never injected and never
  redistributed with iNeovim.

## Swift binding adaptations

The Swift files under `Sources/GhosttySupport/` are copied from
`macos/Sources/Ghostty/` (plus a few `macos/Sources/Helpers/` extensions)
of the same snapshot and adapted for embedding. Upstream these form the
Ghostty.app framework; they reference the app's window/tab/split model,
which this embedding does not have. Adaptations, per file:

- `Ghostty.App.swift` — **rewritten** as a minimal embedding host: same
  runtime callbacks (wakeup→tick, clipboard read/confirm/write,
  close-surface — the tip's clipboard callback signatures, not 1.3.1's)
  but the action dispatcher only answers surface-scoped actions (title,
  pwd, cell size, mouse shape/visibility/links, bell, key tables,
  config/color change, open URL). Window-management actions (new
  window/tab/split, fullscreen, quit, notifications, inspector, quick
  terminal) return "not performed".
- `SurfaceView_AppKit.swift` — kept nearly verbatim (NSTextInputClient,
  key translation, mouse handling, drag & drop, context menus). Pruned:
  search overlay state, key-sequence indicator, progress reports, user
  notifications, secure-input tracking, Codable state restoration, and
  `AppDelegate`/`BaseTerminalController` references
  (`AppDelegate.logger` → `Ghostty.logger`, `UserDefaults.ghostty` →
  `UserDefaults.standard`).
- `OSSurfaceView.swift` — pruned to the published state a plain embedding
  needs (pwd, cellSize, health, error, hover URL, key tables, size info,
  readonly) plus the two search-navigation helpers.
- `SurfaceConfiguration.swift` — extracted verbatim from the SwiftUI
  `SurfaceView.swift`, plus the `withCStrings` Array helper; the optional
  string C-pointer nesting uses a small `withOptionalCString` helper.
- `GhosttyPackage.swift` — pruned `toSplitTreeFocusDirection` (app type).
- `Ghostty.Config.swift` — dropped `keyboardShortcut(for:)` (macOS 15
  SwiftUI type; package targets macOS 14) and the `windowFullscreen*` /
  `quickTerminal*` accessors (Ghostty.app windowing types).
- `Ghostty.Input.swift` — dropped `keyboardShortcut(for:)` (same reason).
- `Ghostty.Error.swift` / `Ghostty.Surface.swift` — added missing
  `Foundation` imports; `Ghostty.Shell.swift` — the regex literal was
  rewritten as an equivalent `Set<Character>` (SPM compile).
- `NSScreen+Extension.swift` — trimmed to the `displayID` accessor.
- `NSMenuItem+Extension.swift` — minimal local replacement for the app's
  icon-preferring helper.
- Copied verbatim: `Ghostty.Action.swift`, `Ghostty.ClipboardConfirmation
  Request.swift`, `Ghostty.Command.swift`, `Ghostty.ConfigTypes.swift`,
  `Ghostty.Inspector.swift`, `GhosttyPackageMeta.swift`,
  `NSEvent+Extension.swift`, `NSPasteboard+Extension.swift`,
  `KeyboardLayout.swift`, `Cursor.swift`, `AppInfo.swift` (just
  `isRunningInXcode()`), `OSColor+Extension.swift`,
  `String+Extension.swift` (+ import), `NSAppearance+Extension.swift`.

The package target compiles in Swift 5 language mode to match the upstream
sources' concurrency assumptions.

## Linking notes

- **`ghostty_init` must run before any other libghostty call** — including
  `ghostty_config_new`, which otherwise dies with EXC_BAD_ACCESS (null
  deref of the uninitialized global state). Upstream does this in
  `macos/Sources/App/main.swift` before `NSApplicationMain`; the embedding
  does it once, guarded, at the top of `Ghostty.App.init`.
- The `GhosttySupport` product is declared **`.dynamic`** on purpose: a
  static product gives every linked image its own copy of libghostty's
  global state (e.g. the app's debug dylib and an injected test bundle),
  and copies that were never `ghostty_init`-ed are landmines. One dynamic
  framework in `Contents/Frameworks` = one initialized copy per process.
- The package target carries `linkerSettings: [.linkedLibrary("c++")]`:
  the vendored static library contains C++ (glslang), so every consumer
  link needs libc++.
- **The XCTest host cannot run libghostty tests**: a test importing
  GhosttySupport makes the host exit(1) the moment the test runs (only in
  the xctest environment — the same calls work from a standalone binary).
  Use `Scripts/ghostty-init-probe.swift` to regression-check the
  init sequence after rebuilding the vendored framework.

libghostty is explicitly "not stable for general purpose use" — when
upgrading this vendored snapshot, re-diff `macos/Sources/Ghostty/` against
these copies and re-read `include/ghostty.h` for callback signature changes
(the 1.3.1 → tip clipboard callbacks changed shape, for example).
