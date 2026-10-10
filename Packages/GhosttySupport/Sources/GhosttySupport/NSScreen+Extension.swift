import Cocoa

// Trimmed from ghostty's NSScreen+Extension.swift: only the display ID
// accessor is used by the embedded surface view.

extension NSScreen {
    /// The unique CoreGraphics display ID for this screen.
    var displayID: UInt32? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    }
}
