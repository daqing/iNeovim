import Foundation

/// A URL found in a rendered grid row: the URL itself plus the half-open
/// cell-column range it covers, so the renderer can underline exactly the
/// link and the mouse handler can open it.
nonisolated struct LinkHit: Equatable, Sendable {
    var url: URL
    var columns: Range<Int>
}

/// Locates an http(s) URL inside a rendered grid row so ⌘-hover can underline
/// it and ⌘-click can hand it to the default browser. Pure and grid-agnostic
/// for testability: the caller supplies the row's cells and the clicked column.
nonisolated enum LinkDetector {
    /// Punctuation that may sit just outside a URL in prose and is dropped
    /// from the tail; paired brackets are handled separately.
    private static let trailingPunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?", "\"", "'", "`", "*", "|", ">",
    ]
    private static let bracketPairs: [Character: Character] = [")": "(", "]": "[", "}": "{"]

    /// Characters that may appear inside a URL per RFC 3986 (unreserved,
    /// reserved, and the percent escape). The URL body is cut at the first
    /// character outside this set, which stops it from swallowing adjacent
    /// prose or CJK text with no separating space.
    private static let urlCharacters = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~:/?#[]@!$&'()*+,;=%"
    )

    /// The URL under `column` with the cells it covers, if the token covering
    /// that cell contains one. A click on a continuation cell (the empty right
    /// half of a double-width glyph) resolves against the glyph cell before it.
    static func hit(in cells: [GridCell], column: Int) -> LinkHit? {
        guard let token = token(in: cells, column: column),
              let range = candidateRange(in: token.text),
              let url = validatedURL(String(token.text[range])) else { return nil }
        let startCol = gridColumn(of: range.lowerBound, in: token)
        let endCol = gridColumn(of: range.upperBound, in: token)
        guard startCol < endCol else { return nil }
        return LinkHit(url: url, columns: startCol..<endCol)
    }

    /// The URL under `column`, without the column mapping.
    static func url(in cells: [GridCell], column: Int) -> URL? {
        hit(in: cells, column: column)?.url
    }

    /// Find the http(s) URL inside a raw token and reject anything malformed.
    static func url(from token: String) -> URL? {
        guard let range = candidateRange(in: token) else { return nil }
        return validatedURL(String(token[range]))
    }

    private static func validatedURL(_ candidate: String) -> URL? {
        guard let url = URL(string: candidate),
              let host = url.host,
              !host.isEmpty else { return nil }
        return url
    }

    /// The character range of the URL inside the token: from the scheme to the
    /// end of the URL body, with wrapping punctuation trimmed off.
    private static func candidateRange(in token: String) -> Range<String.Index>? {
        guard let start = schemeStart(in: token) else { return nil }
        let tail = token[start...]
        let cut = tail.firstIndex(where: { !urlCharacters.contains($0) }) ?? token.endIndex
        let trimmed = trimTrailing(String(tail[..<cut]))
        guard !trimmed.isEmpty else { return nil }
        return start..<token.index(start, offsetBy: trimmed.count)
    }

    /// Index of the first `http://` or `https://` in the token, if any.
    private static func schemeStart(in token: String) -> String.Index? {
        let starts = ["http://", "https://"].compactMap {
            token.range(of: $0, options: .caseInsensitive)?.lowerBound
        }
        return starts.min()
    }

    /// One token: the joined text, the starting cell, and the cells themselves
    /// so a character offset can be mapped back to a grid column.
    private struct Token {
        var text: String
        var startCell: Int
        var cells: [GridCell]
    }

    /// The maximal run of non-blank cells around `column`, joined into one
    /// string. `nil` when the column holds no glyph at all.
    private static func token(in cells: [GridCell], column: Int) -> Token? {
        guard !cells.isEmpty else { return nil }
        var index = min(max(column, 0), cells.count - 1)
        // A continuation cell has no glyph of its own; fall back to the cell
        // carrying the double-width character.
        while index > 0, cells[index].text.isEmpty { index -= 1 }
        guard !cells[index].text.isEmpty else { return nil }

        var start = index
        while start > 0, isTokenCell(cells[start - 1]) { start -= 1 }
        var end = index
        while end + 1 < cells.count, isTokenCell(cells[end + 1]) { end += 1 }
        let slice = Array(cells[start...end])
        return Token(text: slice.map(\.text).joined(), startCell: start, cells: slice)
    }

    /// Grid column of a character offset into the token. Empty cells are
    /// double-width continuations: they occupy a column but hold no character,
    /// so the offset skips over them.
    private static func gridColumn(of offset: String.Index, in token: Token) -> Int {
        var remaining = token.text.distance(from: token.text.startIndex, to: offset)
        var index = 0
        while index < token.cells.count {
            let count = token.cells[index].text.count
            if count == 0 {
                index += 1
                continue
            }
            if remaining < count { return token.startCell + index }
            remaining -= count
            if remaining == 0 {
                var next = index + 1
                while next < token.cells.count, token.cells[next].text.isEmpty { next += 1 }
                return token.startCell + next
            }
            index += 1
        }
        return token.startCell + token.cells.count
    }

    /// A cell belongs to the token when it holds a glyph that is not
    /// whitespace; the empty string is a double-width continuation and is
    /// always included.
    private static func isTokenCell(_ cell: GridCell) -> Bool {
        guard !cell.text.isEmpty else { return true }
        return !cell.text.contains { $0.isWhitespace }
    }

    /// Drop trailing prose punctuation. A paired bracket is kept when its
    /// opener is present, so `…/Foo_(bar)` survives while a wrapping `)`
    /// from `(https://example.com)` does not.
    private static func trimTrailing(_ token: String) -> String {
        var candidate = token
        var didTrim = true
        while didTrim, let last = candidate.last {
            didTrim = false
            if trailingPunctuation.contains(last) {
                candidate.removeLast()
                didTrim = true
            } else if let opener = bracketPairs[last],
                      count(of: opener, in: candidate) < count(of: last, in: candidate) {
                candidate.removeLast()
                didTrim = true
            }
        }
        return candidate
    }

    private static func count(of character: Character, in text: String) -> Int {
        text.reduce(0) { $0 + ($1 == character ? 1 : 0) }
    }
}
