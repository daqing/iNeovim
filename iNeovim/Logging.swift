import Foundation
import os

enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "devplaceholder.iNeovim"

    nonisolated static let rpc = Logger(subsystem: subsystem, category: "rpc")
    nonisolated static let render = Logger(subsystem: subsystem, category: "render")
    nonisolated static let input = Logger(subsystem: subsystem, category: "input")
    nonisolated static let app = Logger(subsystem: subsystem, category: "app")
}
