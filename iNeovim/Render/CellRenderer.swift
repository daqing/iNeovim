import Foundation

/// A run of adjacent cells sharing one highlight id, ready to be shaped as a
/// single CTLine: the background fill spans `startCol..<endCol`, and `text` is
/// the concatenated cell text.
struct StyledRun: Equatable, Sendable {
    var text: String
    var attrId: Int
    var startCol: Int
    var endCol: Int
}

enum CellRenderer {
    /// Group one grid row into maximal runs of equal highlight id. Blank and
    /// continuation cells stay in their run (their background must still be
    /// filled); cells whose text is empty simply contribute nothing to the
    /// shaped string.
    ///
    /// Continuation cells (the empty second half of a double-width char)
    /// are absorbed into the preceding run even if nvim assigned them a
    /// different id, so backgrounds and decorations stay continuous across
    /// wide glyphs.
    static func runs(forRow row: [GridCell]) -> [StyledRun] {
        var runs: [StyledRun] = []
        var continuationCellsRemaining = 0
        for (index, cell) in row.enumerated() {
            if continuationCellsRemaining > 0, !runs.isEmpty {
                continuationCellsRemaining -= 1
                runs[runs.count - 1].endCol = index + 1
                continue
            }
            if let last = runs.last, last.attrId == cell.attrId {
                runs[runs.count - 1].endCol = index + 1
                runs[runs.count - 1].text += cell.text
            } else {
                runs.append(StyledRun(text: cell.text, attrId: cell.attrId, startCol: index, endCol: index + 1))
            }
            continuationCellsRemaining = isDoubleWidth(cell.text) ? 1 : 0
        }
        return runs
    }

    /// wcwidth-style wide/fullwidth check on the leading scalar. Neovim
    /// decides actual cell occupancy; the renderer only uses this to keep a
    /// wide glyph's continuation cell attached to its run.
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
             0x20000...0x2FFFD, // CJK Ext B..
             0x30000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}
