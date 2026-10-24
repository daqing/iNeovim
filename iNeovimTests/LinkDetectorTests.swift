import XCTest
@testable import iNeovim

@MainActor
final class LinkDetectorTests: XCTestCase {
    func testDetectsURLUnderClickedColumn() {
        let cells = cells("see https://example.com/docs now")
        let col = 10 // inside "example"
        XCTAssertEqual(
            LinkDetector.url(in: cells, column: col)?.absoluteString,
            "https://example.com/docs"
        )
    }

    func testClicksAnywhereInTokenResolveTheSameURL() {
        let cells = cells("https://example.com")
        let expected = "https://example.com"
        for col in 0..<cells.count {
            XCTAssertEqual(LinkDetector.url(in: cells, column: col)?.absoluteString, expected)
        }
    }

    func testRejectsNonURLTokens() {
        XCTAssertNil(LinkDetector.url(in: cells("just some words"), column: 6))
        XCTAssertNil(LinkDetector.url(in: cells("ftp://example.com"), column: 5))
        XCTAssertNil(LinkDetector.url(in: cells("example.com"), column: 2))
        XCTAssertNil(LinkDetector.url(in: cells(""), column: 0))
    }

    func testStopsAtWhitespace() {
        let cells = cells("a https://example.com b")
        XCTAssertEqual(
            LinkDetector.url(in: cells, column: 5)?.absoluteString,
            "https://example.com"
        )
    }

    func testTrimsSurroundingPunctuation() {
        XCTAssertEqual(
            LinkDetector.url(from: "(https://example.com).")?.absoluteString,
            "https://example.com"
        )
        XCTAssertEqual(
            LinkDetector.url(from: "<https://example.com>")?.absoluteString,
            "https://example.com"
        )
        XCTAssertEqual(
            LinkDetector.url(from: "\"https://example.com?q=1\"")?.absoluteString,
            "https://example.com?q=1"
        )
    }

    func testKeepsBalancedParenthesesInsideURL() {
        let url = "https://en.wikipedia.org/wiki/Foo_(bar)"
        XCTAssertEqual(LinkDetector.url(from: url)?.absoluteString, url)
    }

    func testClickOnDoubleWidthContinuationResolvesGlyph() {
        // A CJK glyph occupies [0] with an empty-text continuation at [1],
        // then the URL starts at [2].
        var cells = [GridCell(text: "編"), GridCell(text: "")]
        cells.append(contentsOf: self.cells("https://example.com"))
        XCTAssertEqual(
            LinkDetector.url(in: cells, column: 1)?.absoluteString,
            "https://example.com"
        )
        XCTAssertEqual(
            LinkDetector.url(in: cells, column: 6)?.absoluteString,
            "https://example.com"
        )
    }

    func testAcceptsUppercaseScheme() {
        XCTAssertEqual(
            LinkDetector.url(from: "HTTPS://Example.COM/Path")?.absoluteString.lowercased(),
            "https://example.com/path"
        )
    }

    func testHitReportsURLColumns() {
        let cells = cells("see https://example.com/docs now")
        let hit = LinkDetector.hit(in: cells, column: 10)
        XCTAssertEqual(hit?.url.absoluteString, "https://example.com/docs")
        XCTAssertEqual(hit?.columns, 4..<28)
    }

    func testHitColumnsExcludeWrappingPunctuation() {
        let cells = cells("(https://example.com).")
        let hit = LinkDetector.hit(in: cells, column: 3)
        XCTAssertEqual(hit?.url.absoluteString, "https://example.com")
        XCTAssertEqual(hit?.columns, 1..<20)
    }

    func testHitColumnsSkipDoubleWidthContinuations() {
        var cells = [GridCell(text: "參"), GridCell(text: "")]
        cells.append(GridCell(text: "見"))
        cells.append(GridCell(text: ""))
        cells.append(contentsOf: self.cells("https://example.com"))
        let hit = LinkDetector.hit(in: cells, column: 1)
        XCTAssertEqual(hit?.url.absoluteString, "https://example.com")
        XCTAssertEqual(hit?.columns, 4..<23)
    }

    private func cells(_ text: String) -> [GridCell] {
        text.map { GridCell(text: String($0)) }
    }
}
