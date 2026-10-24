import XCTest
@testable import iNeovim

@MainActor
final class ScrollMetricsTests: XCTestCase {
    func testBufferThatFitsIsNotScrollable() {
        let metrics = ScrollMetrics(topline: 1, lineCount: 20, visibleLines: 20)
        XCTAssertFalse(metrics.isScrollable)
    }

    func testThumbProportionIsTheVisibleShareOfTheBuffer() {
        let metrics = ScrollMetrics(topline: 1, lineCount: 100, visibleLines: 25)
        XCTAssertTrue(metrics.isScrollable)
        XCTAssertEqual(metrics.proportion, 0.25)
        XCTAssertEqual(metrics.position, 0)
    }

    func testPositionReachesTheBottomAtTheLastScreenful() {
        // With 25 lines visible in a 100-line buffer the last topline is 76.
        let metrics = ScrollMetrics(topline: 76, lineCount: 100, visibleLines: 25)
        XCTAssertEqual(metrics.position, 1)
    }

    func testPositionClampsOutsideTheScrollableRange() {
        XCTAssertEqual(ScrollMetrics(topline: 0, lineCount: 100, visibleLines: 25).position, 0)
        XCTAssertEqual(ScrollMetrics(topline: 500, lineCount: 100, visibleLines: 25).position, 1)
    }

    func testSingleLineBufferDoesNotDivideByZero() {
        let metrics = ScrollMetrics(topline: 1, lineCount: 1, visibleLines: 1)
        XCTAssertEqual(metrics.proportion, 1)
        XCTAssertEqual(metrics.position, 0)
    }

    func testParseMetricsFromLuaResult() {
        let value = MsgPackValue.map(MsgPackValueMap([
            .string("topline"): .int(12),
            .string("linecount"): .int(400),
            .string("height"): .int(40),
        ]))
        XCTAssertEqual(
            NvimClient.parseScrollMetrics(value),
            ScrollMetrics(topline: 12, lineCount: 400, visibleLines: 40)
        )
    }

    func testParseToleratesMissingFields() {
        XCTAssertNil(NvimClient.parseScrollMetrics(.nil))
        let zeroHeight = MsgPackValue.map(MsgPackValueMap([
            .string("topline"): .int(1),
            .string("linecount"): .int(10),
            .string("height"): .int(0),
        ]))
        XCTAssertNil(NvimClient.parseScrollMetrics(zeroHeight))
    }
}
