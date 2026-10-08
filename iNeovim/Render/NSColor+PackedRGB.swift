import AppKit

extension NSColor {
    /// 0xRRGGBB (the packed format nvim sends) as a calibrated color.
    convenience init?(packedRGB value: Int) {
        guard (0...0xFFFFFF).contains(value) else { return nil }
        self.init(
            calibratedRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
