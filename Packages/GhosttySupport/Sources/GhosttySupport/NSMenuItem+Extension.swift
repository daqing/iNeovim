import AppKit

extension NSMenuItem {
    /// Set a SF Symbol image if the symbol is available on this OS version.
    func setImageIfDesired(systemSymbolName symbol: String) {
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            self.image = image
        }
    }
}
