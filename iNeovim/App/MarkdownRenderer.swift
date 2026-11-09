import AppKit
import Foundation

/// Renders a Markdown buffer to an HTML document for the preview window's
/// `WKWebView`. Foundation's CommonMark parse supplies the block and inline
/// presentation intents; the HTML/CSS gives code blocks `white-space: pre`
/// with horizontal scrolling, so ASCII and box-drawing diagrams keep their
/// layout instead of wrapping at the reading column.
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
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        guard let parsed = try? AttributedString(
            markdown: markdown,
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
        return groups.map { render($0, baseURL: baseURL) }.joined(separator: "\n")
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
