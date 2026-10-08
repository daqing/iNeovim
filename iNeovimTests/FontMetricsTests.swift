import AppKit
import XCTest
@testable import iNeovim

@MainActor
final class FontMetricsTests: XCTestCase {
    func testCellSizeIsPositiveAndWholePoints() {
        let metrics = FontMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        XCTAssertGreaterThan(metrics.cellSize.width, 0)
        XCTAssertGreaterThan(metrics.cellSize.height, 0)
        XCTAssertEqual(metrics.cellSize.width, metrics.cellSize.width.rounded())
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
