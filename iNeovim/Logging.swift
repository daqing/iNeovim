import Foundation
import os

enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "devplaceholder.iNeovim"

    nonisolated static let rpc = Logger(subsystem: subsystem, category: "rpc")
    nonisolated static let render = Logger(subsystem: subsystem, category: "render")
    nonisolated static let input = Logger(subsystem: subsystem, category: "input")
    nonisolated static let app = Logger(subsystem: subsystem, category: "app")
}

/// Signposts for the three T9.2 hot paths. In Instruments, add the `os_signpost`
/// instrument and filter by these categories: `render` (grid draw), `rpc`
/// (msgpack decode), and `scroll` (display-link offset chase).
nonisolated enum Signpost {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "devplaceholder.iNeovim"

    static let render = OSSignposter(subsystem: subsystem, category: "render")
    static let rpc = OSSignposter(subsystem: subsystem, category: "rpc")
    static let scroll = OSSignposter(subsystem: subsystem, category: "scroll")
}
