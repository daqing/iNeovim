import AppKit
import GhosttyKit
import System

// Vendored from ghostty 1.3.2-main+246f702 (macos/Sources/Ghostty/Surface
// View/SurfaceView.swift) for embedding in iNeovim: the per-surface
// configuration passed to Ghostty.SurfaceView, plus the small Array helper
// it relies on.

extension Array where Element == String {
    /// Executes a closure with an array of C string pointers.
    func withCStrings<T>(_ body: ([UnsafePointer<Int8>?]) throws -> T) rethrows -> T {
        // Handle empty array
        if isEmpty {
            return try body([])
        }

        // Recursive helper to process strings
        func helper(index: Int, accumulated: [UnsafePointer<Int8>?], body: ([UnsafePointer<Int8>?]) throws -> T) rethrows -> T {
            if index == count {
                return try body(accumulated)
            }

            return try self[index].withCString { cStr in
                var newAccumulated = accumulated
                newAccumulated.append(cStr)
                return try helper(index: index + 1, accumulated: newAccumulated, body: body)
            }
        }

        return try helper(index: 0, accumulated: [], body: body)
    }
}

/// Run a body with an optional string as a C string: nil passes nil
/// through (the "unset" case), non-nil borrows the pointer for the call.
private func withOptionalCString<T>(_ str: String?, _ body: (UnsafePointer<CChar>?) throws -> T) rethrows -> T {
    guard let str else { return try body(nil) }
    return try str.withCString { try body($0) }
}

extension Ghostty {
    /// The configuration for a surface. For any configuration not set, defaults will be chosen from
    /// libghostty, usually from the Ghostty configuration.
    public struct SurfaceConfiguration {
        /// Explicit font size to use in points
        public var fontSize: Float32?

        /// Explicit working directory. This is normalized on assignment to
        /// remove any redundant and trailing path separators.
        public var workingDirectory: String? {
            get { normalizedWorkingDirectory }
            set { normalizedWorkingDirectory = newValue.map { FilePath($0).string } }
        }
        private var normalizedWorkingDirectory: String?

        /// Explicit command to set
        public var command: String?

        /// Environment variables to set for the terminal
        public var environmentVariables: [String: String] = [:]

        /// Extra input to send as stdin
        public var initialInput: String?

        /// Wait after the command
        public var waitAfterCommand: Bool = false

        /// Context for surface creation
        public var context: ghostty_surface_context_e = GHOSTTY_SURFACE_CONTEXT_WINDOW

        public init() {}

        /// Provides a C-compatible ghostty configuration within a closure. The configuration
        /// and all its string pointers are only valid within the closure.
        func withCValue<T>(view: SurfaceView, _ body: (inout ghostty_surface_config_s) throws -> T) rethrows -> T {
            var config = ghostty_surface_config_new()
            config.userdata = Unmanaged.passUnretained(view).toOpaque()
            config.platform_tag = GHOSTTY_PLATFORM_MACOS
            config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
                nsview: Unmanaged.passUnretained(view).toOpaque()
            ))
            config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)

            // Zero is our default value that means to inherit the font size.
            config.font_size = fontSize ?? 0

            // Set wait after command
            config.wait_after_command = waitAfterCommand

            // Set context
            config.context = context

            // Use withCString to ensure strings remain valid for the duration of the closure
            return try withOptionalCString(workingDirectory) { cWorkingDir in
                config.working_directory = cWorkingDir

                return try withOptionalCString(command) { cCommand in
                    config.command = cCommand

                    return try withOptionalCString(initialInput) { cInput in
                        config.initial_input = cInput

                        // Convert dictionary to arrays for easier processing
                        let keys = Array(environmentVariables.keys)
                        let values = Array(environmentVariables.values)

                        // Create C strings for all keys and values
                        return try keys.withCStrings { keyCStrings in
                            return try values.withCStrings { valueCStrings in
                                // Create array of ghostty_env_var_s
                                var envVars = [ghostty_env_var_s]()
                                envVars.reserveCapacity(environmentVariables.count)
                                for i in 0..<environmentVariables.count {
                                    envVars.append(ghostty_env_var_s(
                                        key: keyCStrings[i],
                                        value: valueCStrings[i]
                                    ))
                                }

                                return try envVars.withUnsafeMutableBufferPointer { buffer in
                                    config.env_vars = buffer.baseAddress
                                    config.env_var_count = environmentVariables.count
                                    return try body(&config)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
