import CoreText
import Foundation

/// One contributing cell of a styled run: where its text begins in
/// `StyledRun.text` (UTF-16 units), the column it starts at counted from the
/// run's `startCol`, and how many cells it spans — 2 when nvim marked it
/// double-width by following it with an empty-text continuation cell.
struct StyledRunSlot: Equatable, Sendable {
    var utf16: Int
    var col: Int
    var cols: Int
}

/// A run of adjacent cells sharing one highlight id, ready to be shaped as a
/// single CTLine: the background fill spans `startCol..<endCol`, `text` is
/// the concatenated cell text, and `slots` maps each contributing cell back
/// to its grid position so drawing can pin glyphs to cell origins.
struct StyledRun: Equatable, Sendable {
    var text: String
    var attrId: Int
    var startCol: Int
    var endCol: Int
    var slots: [StyledRunSlot]
}

enum CellRenderer {
    /// Group one grid row into maximal runs of equal highlight id. Blank and
    /// continuation cells stay in their run (their background must still be
    /// filled); cells whose text is empty simply contribute nothing to the
    /// shaped string.
    ///
    /// An empty-text cell is nvim's protocol marker for the right half of a
    /// double-width character ("the right cell of a double-width char will be
    /// represented as the empty string"), regardless of what our own
    /// width table would say. It is absorbed into the preceding cell even
    /// when nvim assigned it a different highlight id, so backgrounds and
    /// decorations stay continuous across wide glyphs and the glyph earns a
    /// two-cell slot.
    ///
    /// Generic over the row storage so the renderer can pass a zero-copy
    /// `Grid.rowSlice(_:)` instead of copying the row each frame.
    static func runs<C: Collection>(forRow row: C) -> [StyledRun] where C.Element == GridCell {
        var runs: [StyledRun] = []
        var previousHadText = false
        var runTextUTF16 = 0
        var runStartCol = 0
        for (index, cell) in row.enumerated() {
            if cell.text.isEmpty, previousHadText, !runs.isEmpty {
                runs[runs.count - 1].endCol = index + 1
                runs[runs.count - 1].slots[runs[runs.count - 1].slots.count - 1].cols = 2
                previousHadText = false
                continue
            }
            if let last = runs.last, last.attrId == cell.attrId {
                runs[runs.count - 1].endCol = index + 1
                runs[runs.count - 1].text += cell.text
                runs[runs.count - 1].slots.append(StyledRunSlot(
                    utf16: runTextUTF16,
                    col: index - runStartCol,
                    cols: 1
                ))
                runTextUTF16 += cell.text.utf16.count
            } else {
                runs.append(StyledRun(
                    text: cell.text,
                    attrId: cell.attrId,
                    startCol: index,
                    endCol: index + 1,
                    slots: [StyledRunSlot(utf16: 0, col: 0, cols: 1)]
                ))
                runTextUTF16 = cell.text.utf16.count
                runStartCol = index
            }
            previousHadText = !cell.text.isEmpty
        }
        return runs
    }

    /// A stretch of glyphs from one CTRun drawn at a shared horizontal
    /// correction: `dx` is added to the pen origin before drawing `range`.
    struct GlyphShiftGroup {
        var run: CTRun
        var range: CFRange
        var dx: CGFloat
    }

    /// Splits a shaped line's glyphs into groups by the horizontal correction
    /// needed to pin each cell's cluster to `slot.col × cellWidth` relative
    /// to the pen origin the caller draws at. Fallback fonts (CJK, emoji)
    /// advance by their own metrics — narrower than the two cells nvim
    /// reserved — so uncorrected drawing drifts progressively off the grid.
    /// Clusters narrower than their slot are centered; wider ones (a ligature
    /// spanning several cells, an over-wide fallback glyph) keep the slot
    /// origin and spill right, exactly as the cell-by-cell shaping would
    /// place them. Right-to-left runs keep their natural positions.
    static func shiftGroups(
        for line: CTLine,
        slots: [StyledRunSlot],
        cellWidth: CGFloat
    ) -> [GlyphShiftGroup] {
        guard !slots.isEmpty else { return [] }
        var groups: [GlyphShiftGroup] = []
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            if CTRunGetStatus(run).contains(.rightToLeft) {
                groups.append(GlyphShiftGroup(run: run, range: CFRange(location: 0, length: count), dx: 0))
                continue
            }
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            var advances = [CGSize](repeating: .zero, count: count)
            CTRunGetAdvances(run, CFRange(location: 0, length: count), &advances)

            var corrections = [CGFloat](repeating: 0, count: count)
            var slotIndex = 0
            var glyph = 0
            while glyph < count {
                while slotIndex + 1 < slots.count, indices[glyph] >= slots[slotIndex + 1].utf16 {
                    slotIndex += 1
                }
                let slot = slots[slotIndex]
                let slotEnd = slotIndex + 1 < slots.count ? slots[slotIndex + 1].utf16 : Int.max
                var clusterWidth: CGFloat = 0
                let clusterStart = glyph
                while glyph < count, indices[glyph] >= slot.utf16, indices[glyph] < slotEnd {
                    clusterWidth += advances[glyph].width
                    glyph += 1
                }
                let slotWidth = CGFloat(slot.cols) * cellWidth
                let pen = CGFloat(slot.col) * cellWidth + max(0, (slotWidth - clusterWidth) / 2)
                let correction = pen - positions[clusterStart].x
                for index in clusterStart..<glyph {
                    corrections[index] = correction
                }
            }

            var start = 0
            for index in 1...count {
                if index == count || abs(corrections[index] - corrections[start]) >= 0.005 {
                    groups.append(GlyphShiftGroup(
                        run: run,
                        range: CFRange(location: start, length: index - start),
                        dx: corrections[start]
                    ))
                    start = index
                }
            }
        }
        return groups
    }

    /// wcwidth-style wide/fullwidth check on the leading scalar, used to
    /// estimate display widths of preedit (IME) strings, which are plain
    /// text outside the grid. Grid cells get their widths from nvim's
    /// continuation-cell protocol instead, which always matches nvim.
    static func isDoubleWidth(_ text: String) -> Bool {
        guard let scalar = text.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x1100...0x115F, // Hangul Jamo
             0x2E80...0x303E, // CJK Radicals, Kangxi, symbols
             0x3041...0x33FF, // Hiragana..CJK compatibility
             0x3400...0x4DBF, // CJK Ext A
             0x4E00...0x9FFF, // CJK Unified
             0xA000...0xA4CF, // Yi
             0xAC00...0xD7A3, // Hangul Syllables
             0xF900...0xFAFF, // CJK Compatibility Ideographs
             0xFE30...0xFE4F, // CJK compatibility forms
             0xFF00...0xFF60, // Fullwidth forms
             0xFFE0...0xFFE6, // Fullwidth signs
             0x1F300...0x1F64F, // Emoji: pictographs, emoticons
             0x1F680...0x1F6FF, // Emoji: transport and map
             0x1F900...0x1F9FF, // Emoji: supplemental symbols
             0x1FA70...0x1FAFF, // Emoji: extended pictographs
             0x20000...0x2FFFD, // CJK Ext B..
             0x30000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}
