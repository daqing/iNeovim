import AppKit
import XCTest
@testable import iNeovim

@MainActor
final class MarkdownRendererTests: XCTestCase {
    private let theme = MarkdownRenderer.Theme(
        foreground: .black,
        background: .white,
        isDark: false,
        bodyFont: .systemFont(ofSize: 15),
        codeFont: .monospacedSystemFont(ofSize: 13, weight: .regular),
        linkColor: .blue
    )

    func testRendersBlocksToHTML() {
        let markdown = """
        # Title

        Some **bold** and [link](https://example.com).

        - one
        - two

        1. first

        ```swift
        let x = 1
        ```

        ---
        """
        let html = MarkdownRenderer.body(markdown, baseURL: nil)

        XCTAssertTrue(html.contains("<h1>Title</h1>"))
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertTrue(html.contains("<a href=\"https://example.com\">link</a>"))
        XCTAssertTrue(html.contains("<span class=\"marker\">•</span> one"))
        XCTAssertTrue(html.contains("<span class=\"marker\">1.</span> first"))
        XCTAssertTrue(html.contains("<pre><code"))
        XCTAssertTrue(html.contains("let x = 1"))
        XCTAssertTrue(html.contains("<hr>"))
    }

    func testCodeBlockKeepsDiagramWhitespaceAndDoesNotWrapInCSS() {
        let diagram = """
        +--------+     +--------+
        |  CLI   | --> | runner |
        +--------+     +--------+
        """
        let html = MarkdownRenderer.body("```\n\(diagram)\n```", baseURL: nil)
        XCTAssertTrue(html.contains("<pre><code>"))
        XCTAssertTrue(html.contains("+--------+     +--------+"))
        XCTAssertTrue(html.contains("|  CLI   | --&gt; | runner |"))

        let document = MarkdownRenderer.document(body: html, theme: theme)
        XCTAssertTrue(document.contains("white-space: pre"))
        XCTAssertTrue(document.contains("overflow-x: auto"))
    }

    func testEscapesCodeBlockMarkup() {
        let html = MarkdownRenderer.body("```\n<b>not a tag</b>\n```", baseURL: nil)
        XCTAssertTrue(html.contains("&lt;b&gt;not a tag&lt;/b&gt;"))
    }

    func testRelativeLinkResolvesAgainstTheBaseURL() {
        let base = URL(fileURLWithPath: "/tmp/docs", isDirectory: true)
        let html = MarkdownRenderer.body("[other](other.md)", baseURL: base)
        XCTAssertTrue(html.contains("<a href=\"file:///tmp/docs/other.md\">other</a>"))
    }

    func testRendersPipeTableWithHeaderAndBody() {
        let markdown = """
        | Name | Type |
        |------|------|
        | id   | int  |
        | name | text |
        """
        let html = MarkdownRenderer.body(markdown, baseURL: nil)

        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("<thead>"))
        XCTAssertTrue(html.contains("<th>Name</th>"))
        XCTAssertTrue(html.contains("<th>Type</th>"))
        XCTAssertTrue(html.contains("<tbody>"))
        XCTAssertTrue(html.contains("<tr><td>id</td><td>int</td></tr>"))
        XCTAssertTrue(html.contains("<tr><td>name</td><td>text</td></tr>"))

        let document = MarkdownRenderer.document(body: html, theme: theme)
        XCTAssertTrue(document.contains("border-collapse: collapse"))
        XCTAssertTrue(document.contains("overflow-x: auto"))
    }

    func testTableAlignmentColumnsAndInlineCells() {
        let markdown = """
        | Left | Center | Right |
        |:-----|:------:|------:|
        | a    | **b**  | `c`   |
        """
        let html = MarkdownRenderer.body(markdown, baseURL: nil)

        XCTAssertTrue(html.contains("<th style=\"text-align:left\">Left</th>"))
        XCTAssertTrue(html.contains("<th style=\"text-align:center\">Center</th>"))
        XCTAssertTrue(html.contains("<th style=\"text-align:right\">Right</th>"))
        XCTAssertTrue(html.contains("<td style=\"text-align:center\"><strong>b</strong></td>"))
        XCTAssertTrue(html.contains("<code>c</code>"))
    }

    func testTableEscapedPipeStaysInCell() {
        let markdown = """
        | A | B |
        |---|---|
        | a\\|b | c |
        """
        let html = MarkdownRenderer.body(markdown, baseURL: nil)

        XCTAssertTrue(html.contains("<td>a|b</td>"))
        XCTAssertTrue(html.contains("<td>c</td>"))
    }

    func testTableBetweenParagraphs() {
        let markdown = """
        Intro.

        | a | b |
        |---|---|
        | 1 | 2 |

        Outro.
        """
        let html = MarkdownRenderer.body(markdown, baseURL: nil)

        XCTAssertTrue(html.contains("<p>Intro.</p>"))
        XCTAssertTrue(html.contains("<td>1</td>"))
        XCTAssertTrue(html.contains("<p>Outro.</p>"))
    }

    func testFencedCodeIsNotParsedAsTable() {
        let markdown = """
        ```
        | a | b |
        |---|---|
        ```
        """
        let html = MarkdownRenderer.body(markdown, baseURL: nil)

        XCTAssertTrue(html.contains("<pre><code>"))
        XCTAssertTrue(html.contains("| a | b |"))
        XCTAssertFalse(html.contains("<table>"))
    }

    func testDelimiterMismatchAndSetextHeadingAreNotTables() {
        let mismatched = MarkdownRenderer.body("| a | b |\n|---|", baseURL: nil)
        XCTAssertTrue(mismatched.contains("| a | b |"))
        XCTAssertFalse(mismatched.contains("<table>"))

        let setext = MarkdownRenderer.body("Title\n---", baseURL: nil)
        XCTAssertTrue(setext.contains("<h2>Title</h2>"))
        XCTAssertFalse(setext.contains("<table>"))
    }

    func testDocumentUsesTheThemeColors() {
        let document = MarkdownRenderer.document(body: "<p>hi</p>", theme: theme)
        XCTAssertTrue(document.contains("#000000"))
        XCTAssertTrue(document.contains("#FFFFFF"))
    }

    func testBufferSnapshotRecognizesMarkdown() {
        XCTAssertTrue(
            NvimBufferSnapshot(name: "/tmp/a.md", filetype: "", lines: []).isMarkdown
        )
        XCTAssertTrue(
            NvimBufferSnapshot(name: "/tmp/a.txt", filetype: "markdown", lines: []).isMarkdown
        )
        XCTAssertTrue(
            NvimBufferSnapshot(name: "/tmp/a.mdx", filetype: "markdown.mdx", lines: []).isMarkdown
        )
        XCTAssertFalse(
            NvimBufferSnapshot(name: "/tmp/a.rb", filetype: "ruby", lines: []).isMarkdown
        )
        XCTAssertFalse(
            NvimBufferSnapshot(name: "", filetype: "text", lines: []).isMarkdown
        )
    }
}
