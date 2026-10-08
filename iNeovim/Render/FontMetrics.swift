import AppKit
import CoreText

/// Metrics for a fixed terminal cell grid derived from a monospace font:
/// the cell size plus vertical placement values used to position Core Text
/// baselines.
struct FontMetrics: Equatable {
    static let defaultSize: CGFloat = 13

    var font: NSFont
    let cellSize: CGSize
    let ascent: CGFloat
    let descent: CGFloat
    let leading: CGFloat
    /// Distance from the top of a cell to the text baseline.
    let baseline: CGFloat

    init(font: NSFont) {
        self.font = font
        let ctFont = font as CTFont
        let ascent = CTFontGetAscent(ctFont)
        let descent = CTFontGetDescent(ctFont)
        let leading = CTFontGetLeading(ctFont)
        self.ascent = ascent
        self.descent = descent
        self.leading = leading
        let cellHeight = ceil(ascent + descent + leading)
        self.cellSize = CGSize(
            width: FontMetrics.widestAdvance(of: ctFont),
            height: cellHeight
        )
        self.baseline = ascent + floor((cellHeight - ascent - descent) / 2)
    }

    /// The widest horizontal advance across printable ASCII. Monospace fonts
    /// give every ASCII glyph the same advance, but taking the maximum keeps
    /// the grid intact for fonts whose symbols or italic variants run wide.
    private static func widestAdvance(of font: CTFont) -> CGFloat {
        let scalars = [UniChar]((UInt16(32)...UInt16(126)))
        var glyphs = [CGGlyph](repeating: 0, count: scalars.count)
        let mapped = scalars.withUnsafeBufferPointer { characters in
            glyphs.withUnsafeMutableBufferPointer { destination in
                CTFontGetGlyphsForCharacters(
                    font, characters.baseAddress!, destination.baseAddress!, scalars.count
                )
            }
        }
        guard mapped else { return ceil(CTFontGetSize(font)) }
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        advances.withUnsafeMutableBufferPointer { buffer in
            CTFontGetAdvancesForGlyphs(
                font, .horizontal, glyphs, buffer.baseAddress!, glyphs.count
            )
        }
        let widest = advances.reduce(0) { max($0, $1.width) }
        return ceil(widest)
    }
}
