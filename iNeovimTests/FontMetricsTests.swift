import AppKit
import XCTest
@testable import iNeovim

@MainActor
final class FontMetricsTests: XCTestCase {
    func testCellWidthMatchesFontAdvance() {
        // Text runs are shaped with the font's natural advances, so the cell
        // width must equal the advance exactly or glyphs drift away from the
        // cursor/background cells.
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let metrics = FontMetrics(font: font)
        let advance = font.advancement(forGlyph: font.glyph(withName: "M")).width
        XCTAssertGreaterThan(metrics.cellSize.width, 0)
        XCTAssertEqual(metrics.cellSize.width, advance, accuracy: 0.001)
    }

    func testCellHeightIsWholePoints() {
        let metrics = FontMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        XCTAssertGreaterThan(metrics.cellSize.height, 0)
        XCTAssertEqual(metrics.cellSize.height, metrics.cellSize.height.rounded())
    }

    func testBaselineSitsInsideTheCell() {
        let metrics = FontMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        XCTAssertGreaterThan(metrics.baseline, 0)
        XCTAssertLessThanOrEqual(metrics.baseline, metrics.cellSize.height)
        XCTAssertGreaterThanOrEqual(metrics.baseline, metrics.ascent)
    }

    func testCellHeightCoversAscentDescentLeading() {
        let metrics = FontMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        XCTAssertGreaterThanOrEqual(
            metrics.cellSize.height,
            metrics.ascent + metrics.descent + metrics.leading
        )
    }

    func testLargerFontProducesLargerCells() {
        let small = FontMetrics(font: .monospacedSystemFont(ofSize: 11, weight: .regular))
        let large = FontMetrics(font: .monospacedSystemFont(ofSize: 22, weight: .regular))
        XCTAssertLessThan(small.cellSize.height, large.cellSize.height)
    }
}
