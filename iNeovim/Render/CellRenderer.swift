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
    static func runs(forRow row: [GridCell]) -> [StyledRun] {
        var runs: [StyledRun] = []
        for (index, cell) in row.enumerated() {
            if let last = runs.last, last.attrId == cell.attrId {
                runs[runs.count - 1].endCol = index + 1
                runs[runs.count - 1].text += cell.text
            } else {
                runs.append(StyledRun(text: cell.text, attrId: cell.attrId, startCol: index, endCol: index + 1))
            }
        }
        return runs
    }
}
