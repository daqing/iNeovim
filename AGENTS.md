# AGENTS.md — iNeovim

## Project overview

iNeovim is a native macOS desktop application written in Swift with SwiftUI. Despite the
name, there is currently no Neovim integration, terminal emulation, or editor functionality
implemented — the codebase is the stock Xcode 26.3 app template (a single
"Hello, world!" view) with one commit ("Initial Commit"). It is a starting skeleton, so
treat everything as early-stage and expect the architecture to be defined by upcoming work.

Key facts from `iNeovim.xcodeproj/project.pbxproj`:

- **Platform:** macOS only (`SUPPORTED_PLATFORMS = macosx`, `SUPPORTS_MACCATALYST = NO`).
  The iOS-orientation keys in the target settings are unused template leftovers.
- **Deployment target:** macOS 14.6 (`MACOSX_DEPLOYMENT_TARGET = 14.6`).
- **Created with:** Xcode 26.3 (`CreatedOnToolsVersion = 26.3`).
- **Swift:** `SWIFT_VERSION = 5.0`, approachable concurrency enabled
  (`SWIFT_APPROACHABLE_CONCURRENCY = YES`), default actor isolation is `MainActor`
  (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`).
- **Bundle:** display name `iNeovim`, category `public.app-category.developer-tools`,
  bundle ID `devplaceholder.<unique>.<product>` (placeholder prefix — replace before release).
- **Capabilities:** App Sandbox enabled, user-selected files readonly, App Groups registered.
- **Versioning:** `MARKETING_VERSION = 1.0`, `CURRENT_PROJECT_VERSION = 1` — both live only
  in `project.pbxproj` (there is no standalone `Info.plist`; it is generated via
  `GENERATE_INFOPLIST_FILE = YES`).

## Repository layout

```
iNeovim/                  App sources (a PBXFileSystemSynchronizedRootGroup)
├── MyApp.swift           @main entry point: WindowGroup hosting ContentView
├── ContentView.swift     Root view ("Hello, world!" + #Preview and #Playground macros)
└── Assets.xcassets/      AccentColor colorset only (no app icon yet)
iNeovim.xcodeproj/        Single-target Xcode project (no workspace-level schemes shared)
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

There is currently **no test target, no test files, and no test infrastructure**. Do not
invent a test scaffolding unprompted; if tests are requested later, add an XCTest target
through the Xcode project and follow its conventions.

SwiftUI `#Preview` (and `#Playground`) macros in `ContentView.swift` are the existing
mechanism for interactive visual verification.

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

- **`ext_multigrid` policy (T1.3):** v1 attaches to nvim with a single grid
  (`ext_multigrid` off). All redraw and grid handling must still carry grid
  IDs from day one — event cases take a `grid` identifier and grid state is
  keyed by ID — so enabling multigrid later is a switch flip, not a rewrite.

## Security considerations

- App Sandbox is **enabled** with `user-selected-files` access set to **read/write**
  (`ENABLE_USER_SELECTED_FILES = readwrite`, widened in T1.6) so edited buffers can be
  saved. The child `nvim` inherits the sandbox — it can only reach files the app itself
  may access (user-selected files, the app container) — keep this in mind for features
  like the embedded terminal or plugin file access.
- Code signing uses automatic signing with a personal development team
  (`DEVELOPMENT_TEAM = S39RD89QY9`) — do not hardcode other team IDs or credentials.
- Never commit secrets (API keys, provisioning credentials, `.env` files); none exist in
  the repo today.
- The bundle ID prefix `devplaceholder` must be replaced with a real reverse-DNS
  identifier before any distribution.

## Deployment / release

No deployment pipeline exists. There is no Fastlane, no CI, no notarization setup, and no
shared scheme. Releases, when needed, are produced from Xcode's archive flow.
