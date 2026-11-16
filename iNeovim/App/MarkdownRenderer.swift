import AppKit
import Foundation

/// Renders a Markdown buffer to an HTML document for the preview window's
/// `WKWebView`. Foundation's CommonMark parse supplies the block and inline
/// presentation intents; the HTML/CSS gives code blocks `white-space: pre`
/// with horizontal scrolling, so ASCII and box-drawing diagrams keep their
/// layout instead of wrapping at the reading column. GFM pipe tables are
/// outside that CommonMark parse: they are lifted out before parsing,
/// rendered to `<table>` HTML directly, and spliced back in through
/// paragraph markers.
@MainActor
enum MarkdownRenderer {
    struct Theme {
        var foreground: NSColor
        var background: NSColor
        var isDark: Bool
        var bodyFont: NSFont
        var codeFont: NSFont
        var linkColor: NSColor
    }

    /// The HTML body for the parsed Markdown, without the document wrapper.
    static func body(_ markdown: String, baseURL: URL?) -> String {
        let extraction = extractPipeTables(markdown, baseURL: baseURL)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        guard let parsed = try? AttributedString(
            markdown: extraction.source,
            options: options,
            baseURL: baseURL
        ) else {
            return "<pre>\(escapeHTML(markdown))</pre>"
        }

        var groups: [Group] = []
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            guard !text.isEmpty else { continue }
            let block = Block(run.presentationIntent)
            let inline = InlineRun(
                text: text,
                inline: run.inlinePresentationIntent,
                link: run.link
            )
            if let index = groups.indices.last, groups[index].block.key == block.key {
                groups[index].runs.append(inline)
            } else {
                groups.append(Group(block: block, runs: [inline]))
            }
        }
        var html = groups.map { render($0, baseURL: baseURL) }.joined(separator: "\n")
        for table in extraction.tables {
            let placeholder = "<p>\(table.marker)</p>"
            if html.contains(placeholder) {
                html = html.replacingOccurrences(of: placeholder, with: table.html)
            } else {
                html = html.replacingOccurrences(of: table.marker, with: table.html)
            }
        }
        return html
    }

    /// Wrap the body in a theme-aware document with the preview stylesheet.
    static func document(body: String, theme: Theme) -> String {
        let foreground = cssColor(theme.foreground)
        let background = cssColor(theme.background)
        let link = cssColor(theme.linkColor)
        let codeBackground = cssColor(theme.foreground, alpha: 0.08)
        let border = cssColor(theme.foreground, alpha: 0.18)
        let quoteText = cssColor(theme.foreground, alpha: 0.75)
        let marker = cssColor(theme.foreground, alpha: 0.6)
        let codeFamily = editorCodeFamily(theme.codeFont)
        let bodySize = Int(theme.bodyFont.pointSize.rounded())

        let css = """
        :root { color-scheme: \(theme.isDark ? "dark" : "light"); }
        html {
          background: \(background);
          -webkit-text-size-adjust: none;
        }
        body {
          box-sizing: border-box;
          margin: 0 auto;
          max-width: 720px;
          padding: 28px 24px 48px;
          background: \(background);
          color: \(foreground);
          font: 400 \(bodySize)px/1.55 -apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif;
          overflow-wrap: break-word;
        }
        h1, h2, h3, h4, h5, h6 {
          margin: 1.4em 0 0.5em;
          font-weight: 650;
          line-height: 1.25;
        }
        h1 { margin-top: 0.2em; font-size: 1.75em; }
        h2 { font-size: 1.45em; }
        h3 { font-size: 1.2em; }
        h4, h5, h6 { font-size: 1em; }
        p { margin: 0 0 0.9em; }
        a { color: \(link); text-decoration: none; }
        a:hover { text-decoration: underline; }
        code, pre {
          font-family: \(codeFamily), Menlo, Monaco, "SFMono-Regular", monospace;
        }
        code {
          font-size: 0.86em;
          background: \(codeBackground);
          border-radius: 4px;
          padding: 0.12em 0.35em;
        }
        pre {
          margin: 0.4em 0 1em;
          padding: 10px 12px;
          border-radius: 6px;
          background: \(codeBackground);
          overflow-x: auto;
          white-space: pre;
          line-height: 1.2;
        }
        pre code {
          padding: 0;
          border-radius: 0;
          background: none;
          font-size: 13px;
        }
        blockquote {
          margin: 0 0 0.9em;
          padding-left: 14px;
          border-left: 3px solid \(border);
          color: \(quoteText);
        }
        table {
          display: block;
          width: max-content;
          max-width: 100%;
          margin: 0 0 1em;
          border-collapse: collapse;
          overflow-x: auto;
        }
        th, td {
          border: 1px solid \(border);
          padding: 0.3em 0.75em;
          text-align: left;
          vertical-align: top;
        }
        thead th {
          font-weight: 650;
          background: \(codeBackground);
        }
        hr { border: 0; border-top: 1px solid \(border); margin: 1.5em 0; }
        .li {
          padding-left: 1.6em;
          text-indent: -1.6em;
          margin: 0.15em 0;
        }
        .li .marker { color: \(marker); }
        """
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>\(css)</style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    // MARK: - Blocks

    private static func render(_ group: Group, baseURL: URL?) -> String {
        let inline = inlineHTML(group.runs, baseURL: baseURL)
        switch group.block.kind {
        case .heading(let level):
            let tag = "h\(min(max(level, 1), 6))"
            return quoteWrapper("<\(tag)>\(inline)</\(tag)>", block: group.block)

        case .paragraph:
            return quoteWrapper("<p>\(inline)</p>", block: group.block)

        case .listItem:
            let indent = CGFloat(max(0, group.block.listDepth - 1)) * 1.5
            let marker = group.block.ordered == true
                ? "\(group.block.ordinal ?? 1)."
                : "•"
            let item = "<div class=\"li\" style=\"margin-left:\(number(indent))em\">"
                + "<span class=\"marker\">\(marker)</span> \(inline)</div>"
            return quoteWrapper(item, block: group.block)

        case .codeBlock(let language):
            let className = language.map { " class=\"language-\(escapeAttribute($0))\"" } ?? ""
            let text = group.runs.map(\.text).joined()
            return quoteWrapper(
                "<pre><code\(className)>\(escapeHTML(text))</code></pre>",
                block: group.block
            )

        case .thematicBreak:
            return "<hr>"
        }
    }

    private static func quoteWrapper(_ content: String, block: Block) -> String {
        guard block.quoteDepth > 0 else { return content }
        let margin = CGFloat(max(0, block.quoteDepth - 1)) * 1.5
        return "<blockquote style=\"margin-left:\(number(margin))em\">\(content)</blockquote>"
    }

    // MARK: - Inline

    private static func inlineHTML(_ runs: [InlineRun], baseURL: URL?) -> String {
        var html = ""
        for run in runs {
            var text = escapeHTML(run.text)
            if let link = run.link {
                let resolved = resolvedLink(link, baseURL: baseURL)
                text = "<a href=\"\(escapeAttribute(resolved.absoluteString))\">\(text)</a>"
            }
            if let inline = run.inline {
                if inline.contains(.code) {
                    text = "<code>\(text)</code>"
                }
                if inline.contains(.stronglyEmphasized) {
                    text = "<strong>\(text)</strong>"
                }
                if inline.contains(.emphasized) {
                    text = "<em>\(text)</em>"
                }
                if inline.contains(.strikethrough) {
                    text = "<del>\(text)</del>"
                }
            }
            html += text
        }
        return html
    }

    private static func resolvedLink(_ link: URL, baseURL: URL?) -> URL {
        if link.scheme == nil, let baseURL {
            return URL(string: link.relativeString, relativeTo: baseURL)?.absoluteURL
                ?? link.absoluteURL
        }
        return link.absoluteURL
    }

    // MARK: - Parsing support

    private struct InlineRun {
        var text: String
        var inline: InlinePresentationIntent?
        var link: URL?
    }

    private struct Group {
        var block: Block
        var runs: [InlineRun]
    }

    /// The block-level structure of one run, independent of its inline
    /// styling. Identities are unique per parsed block, so runs with the same
    /// key belong to the same paragraph or list item.
    private struct Block {
        enum Kind {
            case paragraph
            case heading(Int)
            case listItem
            case codeBlock(String?)
            case thematicBreak
        }

        var key: String
        var kind: Kind
        var listDepth = 0
        var ordinal: Int?
        var ordered: Bool?
        var quoteDepth = 0

        init(_ intent: PresentationIntent?) {
            var keyParts: [String] = []
            var headingLevel: Int?
            var codeLanguage: String?
            var isCode = false
            var isThematic = false
            var item: Int?
            var orderedList: Bool?

            let components = intent?.components ?? []
            for (index, component) in components.enumerated() {
                keyParts.append(String(component.identity))
                switch component.kind {
                case .header(let level):
                    headingLevel = level
                case .codeBlock(let language):
                    isCode = true
                    codeLanguage = language
                case .thematicBreak:
                    isThematic = true
                case .blockQuote:
                    quoteDepth += 1
                case .listItem(let number):
                    item = number
                    listDepth += 1
                    for later in components[(index + 1)...] {
                        if case .orderedList = later.kind {
                            orderedList = true
                            break
                        }
                        if case .unorderedList = later.kind {
                            orderedList = false
                            break
                        }
                    }
                case .paragraph:
                    break
                default:
                    break
                }
            }

            key = keyParts.joined(separator: "/")
            ordinal = item
            ordered = orderedList
            if let headingLevel {
                kind = .heading(headingLevel)
            } else if isCode {
                kind = .codeBlock(codeLanguage)
            } else if isThematic {
                kind = .thematicBreak
            } else if item != nil {
                kind = .listItem
            } else {
                kind = .paragraph
            }
        }
    }

    // MARK: - Pipe tables

    /// One lifted-out GFM pipe table and the paragraph marker standing in
    /// for it during the Foundation parse.
    private struct PipeTable {
        var marker: String
        var html: String
    }

    private enum CellAlignment: String {
        case left, center, right
    }

    /// Foundation's CommonMark parser has no GFM pipe tables: table lines
    /// would render as a paragraph of pipes and dashes. Each table is lifted
    /// out of the source before the parse, rendered to HTML directly, and
    /// spliced back in through an unambiguous paragraph marker, so the rest
    /// of the document keeps its Foundation-parsed structure. Fenced code is
    /// skipped, a table starts only on a header row directly followed by a
    /// matching delimiter row, and it stops at the first line that cannot be
    /// a row. Tables inside block quotes or list items stay plain text.
    private static func extractPipeTables(_ markdown: String, baseURL: URL?) -> (source: String, tables: [PipeTable]) {
        var lines = markdown.components(separatedBy: "\n")
        for index in lines.indices where lines[index].hasSuffix("\r") {
            lines[index].removeLast()
        }

        var tables: [PipeTable] = []
        var prepared: [String] = []
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        var fence: (marker: Character, length: Int)?
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if let open = fence {
                if isFenceClose(line, open) {
                    fence = nil
                }
                prepared.append(line)
                index += 1
                continue
            }
            if let open = opensFence(line) {
                fence = open
                prepared.append(line)
                index += 1
                continue
            }
            if let table = pipeTable(at: index, in: lines, baseURL: baseURL) {
                let marker = "INEOVIMTABLE\(nonce)\(tables.count)"
                prepared.append("")
                prepared.append(marker)
                prepared.append("")
                tables.append(PipeTable(marker: marker, html: table.html))
                index += table.lineCount
                continue
            }
            prepared.append(line)
            index += 1
        }
        return (prepared.joined(separator: "\n"), tables)
    }

    private static func pipeTable(
        at index: Int,
        in lines: [String],
        baseURL: URL?
    ) -> (html: String, lineCount: Int)? {
        guard isTableRow(lines[index]), index + 1 < lines.count else { return nil }
        let header = splitRow(lines[index])
        guard let alignments = delimiterAlignments(lines[index + 1], columnCount: header.count) else {
            return nil
        }
        var rows: [[String]] = []
        var end = index + 2
        while end < lines.count, let cells = bodyRowCells(lines[end]) {
            rows.append(cells)
            end += 1
        }
        return (
            renderTable(header: header, alignments: alignments, rows: rows, baseURL: baseURL),
            end - index
        )
    }

    /// A line that may hold a table cell row: not blank, not indented code,
    /// not a blockquote marker, not the opening line of another block, and
    /// carrying at least one pipe.
    private static func isTableRow(_ line: String) -> Bool {
        let (indent, rest) = leadingSpaces(line)
        guard indent <= 3 else { return false }
        let trimmed = String(rest).trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.contains("|") else { return false }
        if trimmed.hasPrefix(">") { return false }
        if opensFence(line) != nil { return false }
        if startsOtherBlock(trimmed) { return false }
        return true
    }

    private static func bodyRowCells(_ line: String) -> [String]? {
        guard isTableRow(line) else { return nil }
        return splitRow(line)
    }

    /// A line opening another block-level structure (ATX heading, bullet or
    /// ordered list item); a table neither starts on nor continues past one.
    private static func startsOtherBlock(_ line: String) -> Bool {
        var rest = Substring(line)
        if rest.first == "#" {
            let hashes = rest.prefix { $0 == "#" }
            if hashes.count <= 6 {
                let after = rest.dropFirst(hashes.count)
                if after.first == nil || after.first == " " || after.first == "\t" {
                    return true
                }
            }
        }
        if rest.first == "-" || rest.first == "+" || rest.first == "*" {
            let after = rest.dropFirst()
            if after.first == " " || after.first == "\t" {
                return true
            }
        }
        var digits = 0
        while digits < 9, let first = rest.first, first.isNumber {
            digits += 1
            rest = rest.dropFirst()
        }
        if digits > 0, rest.first == "." || rest.first == ")" {
            let after = rest.dropFirst()
            if after.first == " " || after.first == "\t" {
                return true
            }
        }
        return false
    }

    private static func leadingSpaces(_ line: String) -> (count: Int, rest: Substring) {
        var count = 0
        var rest = Substring(line)
        while rest.first == " " {
            count += 1
            rest = rest.dropFirst()
        }
        return (count, rest)
    }

    private static func opensFence(_ line: String) -> (marker: Character, length: Int)? {
        let (indent, rest) = leadingSpaces(line)
        guard indent <= 3, let first = rest.first, first == "`" || first == "~" else { return nil }
        let run = rest.prefix { $0 == first }
        guard run.count >= 3 else { return nil }
        return (marker: first, length: run.count)
    }

    private static func isFenceClose(_ line: String, _ open: (marker: Character, length: Int)) -> Bool {
        let (indent, rest) = leadingSpaces(line)
        guard indent <= 3 else { return false }
        let run = rest.prefix { $0 == open.marker }
        guard run.count >= open.length else { return false }
        return String(rest.dropFirst(run.count)).trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// One row's cells: the optional edge pipes come off (an escaped `\|`
    /// stays in its cell), the row splits on unescaped pipes, and each cell
    /// is trimmed with its escaped pipes restored.
    private static func splitRow(_ line: String) -> [String] {
        var row = Substring(line.trimmingCharacters(in: .whitespaces))
        if row.hasPrefix("|") {
            row = row.dropFirst()
        }
        if row.hasSuffix("|") && !endsWithEscapedPipe(row) {
            row = row.dropLast()
        }
        var cells: [String] = []
        var cell = ""
        var escapes = 0
        for ch in row {
            if ch == "|" && escapes % 2 == 0 {
                cells.append(cell)
                cell = ""
                escapes = 0
                continue
            }
            if ch == "\\" {
                escapes += 1
            } else {
                escapes = 0
            }
            cell.append(ch)
        }
        cells.append(cell)
        return cells.map {
            $0.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\\|", with: "|")
        }
    }

    /// True when the row's trailing pipe is an escaped `\|`, so it belongs to
    /// the last cell instead of ending the row.
    private static func endsWithEscapedPipe(_ row: Substring) -> Bool {
        var backslashes = 0
        var index = row.index(before: row.endIndex)
        while index > row.startIndex {
            index = row.index(before: index)
            if row[index] == "\\" {
                backslashes += 1
            } else {
                break
            }
        }
        return backslashes % 2 == 1
    }

    /// The delimiter row's alignments, or nil when the line is not a valid
    /// delimiter row for a `columnCount`-column table.
    private static func delimiterAlignments(_ line: String, columnCount: Int) -> [CellAlignment?]? {
        let (indent, rest) = leadingSpaces(line)
        guard indent <= 3 else { return nil }
        let trimmed = String(rest).trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }
        let cells = splitRow(line)
        guard cells.count == columnCount else { return nil }
        var alignments: [CellAlignment?] = []
        for cell in cells {
            guard isDelimiterCell(cell) else { return nil }
            let left = cell.hasPrefix(":")
            let right = cell.hasSuffix(":")
            if left && right {
                alignments.append(.center)
            } else if right {
                alignments.append(.right)
            } else if left {
                alignments.append(.left)
            } else {
                alignments.append(nil)
            }
        }
        return alignments
    }

    private static func isDelimiterCell(_ cell: String) -> Bool {
        var content = Substring(cell)
        if content.first == ":" {
            content = content.dropFirst()
        }
        if content.last == ":" {
            content = content.dropLast()
        }
        return !content.isEmpty && content.allSatisfy { $0 == "-" }
    }

    private static func renderTable(
        header: [String],
        alignments: [CellAlignment?],
        rows: [[String]],
        baseURL: URL?
    ) -> String {
        let head = header.enumerated().map { index, cell in
            cellHTML(cell, tag: "th", alignment: alignments[index], baseURL: baseURL)
        }.joined()
        let bodyRows = rows.map { row in
            "<tr>"
                + row.enumerated().map { index, cell in
                    let alignment = index < alignments.count ? alignments[index] : nil
                    return cellHTML(cell, tag: "td", alignment: alignment, baseURL: baseURL)
                }.joined()
                + "</tr>"
        }.joined(separator: "\n")
        let tbody = bodyRows.isEmpty ? "<tbody></tbody>" : "<tbody>\n\(bodyRows)\n</tbody>"
        return "<table>\n<thead>\n<tr>\(head)</tr>\n</thead>\n\(tbody)\n</table>"
    }

    private static func cellHTML(
        _ cell: String,
        tag: String,
        alignment: CellAlignment?,
        baseURL: URL?
    ) -> String {
        let style = alignment.map { " style=\"text-align:\($0.rawValue)\"" } ?? ""
        return "<\(tag)\(style)>\(inlineFragmentHTML(cell, baseURL: baseURL))</\(tag)>"
    }

    /// Inline markup for one cell's text: the same inline rendering the rest
    /// of the document gets, without block intents.
    private static func inlineFragmentHTML(_ source: String, baseURL: URL?) -> String {
        guard !source.isEmpty else { return "" }
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        guard let parsed = try? AttributedString(
            markdown: source,
            options: options,
            baseURL: baseURL
        ) else {
            return escapeHTML(source)
        }
        var runs: [InlineRun] = []
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            guard !text.isEmpty else { continue }
            runs.append(InlineRun(text: text, inline: run.inlinePresentationIntent, link: run.link))
        }
        return inlineHTML(runs, baseURL: baseURL)
    }

    // MARK: - Helpers

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttribute(_ text: String) -> String {
        escapeHTML(text).replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func number(_ value: CGFloat) -> String {
        String(format: "%.2f", value)
    }

    private static func cssColor(_ color: NSColor) -> String {
        let converted = color.usingColorSpace(.sRGB) ?? color
        let red = Int((converted.redComponent * 255).rounded())
        let green = Int((converted.greenComponent * 255).rounded())
        let blue = Int((converted.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    private static func cssColor(_ color: NSColor, alpha: CGFloat) -> String {
        let converted = color.usingColorSpace(.sRGB) ?? color
        let red = Int((converted.redComponent * 255).rounded())
        let green = Int((converted.greenComponent * 255).rounded())
        let blue = Int((converted.blueComponent * 255).rounded())
        return "rgba(\(red), \(green), \(blue), \(number(alpha)))"
    }

    private static func editorCodeFamily(_ font: NSFont) -> String {
        if let family = font.familyName, !family.hasPrefix(".") {
            return "\"\(escapeAttribute(family))\""
        }
        return "ui-monospace"
    }
}
