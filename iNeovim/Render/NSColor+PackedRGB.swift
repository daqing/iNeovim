import AppKit

extension NSColor {
    /// 0xRRGGBB (the packed format nvim sends) as an sRGB color. sRGB, not
    /// the legacy calibrated space: calibrated components drift through the
    /// device conversion (a reported #262B2C rendered as #292C34), shifting
    /// every color nvim sends.
    nonisolated convenience init?(packedRGB value: Int) {
        guard (0...0xFFFFFF).contains(value) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
