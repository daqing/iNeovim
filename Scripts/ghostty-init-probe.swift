// Standalone regression probe for the vendored libghostty: calls the exact
// initialization sequence the native terminal pane depends on, outside the
// GUI. This exists because the equivalent check cannot run inside the
// XCTest host (the host exits during libghostty init there); run it after
// rebuilding Vendor/GhosttyKit.xcframework.
//
// Build & run from the repo root:
//   F=Packages/GhosttySupport/Vendor/GhosttyKit.xcframework/macos-arm64_x86_64
//   swiftc Scripts/ghostty-init-probe.swift -I "$F/Headers" "$F/ghostty-internal.a" \
//     -lc++ -framework CoreFoundation -framework CoreText -framework Foundation \
//     -framework AppKit -framework Metal -framework CoreVideo -framework IOKit \
//     -framework CoreGraphics -framework CoreServices -framework IOSurface \
//     -framework QuartzCore -framework AudioUnit -framework AudioToolbox \
//     -framework CoreAudio -framework SystemConfiguration -framework Network \
//     -framework Security -framework Carbon \
//     -o /tmp/ghostty-init-probe && /tmp/ghostty-init-probe
//
// Expected output ends with "ALL OK" (ghostty_init rc=0, config loaded,
// app created); the app target additionally links -lc++ via Package.swift
// linkerSettings because the static library contains C++ (glslang).

import AppKit
import GhosttyKit

print("step 1: ghostty_init")
let rc = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
print("  rc=\(rc)")
guard rc == GHOSTTY_SUCCESS else { exit(1) }

print("step 2: ghostty_config_new")
guard let cfg = ghostty_config_new() else { print("  config_new FAILED"); exit(1) }
print("  ok")

print("step 3: load_default_files")
ghostty_config_load_default_files(cfg)
print("  ok")

print("step 4: finalize")
ghostty_config_finalize(cfg)
print("  ok")

print("step 5: runtime config + ghostty_app_new")
var runtime_cfg = ghostty_runtime_config_s(
    userdata: nil,
    supports_selection_clipboard: true,
    wakeup_cb: { _ in },
    action_cb: { _, _, _ in return false },
    read_clipboard_cb: { _, _, _, _, _, _ in return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED },
    confirm_read_clipboard_cb: { _, _, _, _ in },
    write_clipboard_cb: { _, _, _, _, _ in },
    close_surface_cb: { _, _ in }
)
let app = ghostty_app_new(&runtime_cfg, cfg)
print("  app=\(app != nil ? "created" : "nil")")
guard app != nil else { exit(1) }

print("ALL OK")
