import Foundation
import os

enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "devplaceholder.iNeovim"

    static let rpc = Logger(subsystem: subsystem, category: "rpc")
    static let render = Logger(subsystem: subsystem, category: "render")
    static let input = Logger(subsystem: subsystem, category: "input")
    static let app = Logger(subsystem: subsystem, category: "app")
}
