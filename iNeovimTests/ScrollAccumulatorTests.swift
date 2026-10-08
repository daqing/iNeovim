import XCTest
@testable import iNeovim

final class ScrollAccumulatorTests: XCTestCase {
    private let line: CGFloat = 10

    func testOffsetFollowsAccumulatedDelta() {
        var accumulator = ScrollAccumulator()
        _ = accumulator.addDelta(4, lineHeight: line)
        XCTAssertEqual(accumulator.offset, 4)
        _ = accumulator.addDelta(3, lineHeight: line)
        XCTAssertEqual(accumulator.offset, 7)
    }

    func testWholeLinesBecomeScrollRequests() {
        var accumulator = ScrollAccumulator()
        XCTAssertEqual(accumulator.addDelta(25, lineHeight: line), [.up, .up])
        XCTAssertEqual(accumulator.offset, 25)
        XCTAssertEqual(accumulator.addDelta(4, lineHeight: line), [])
        XCTAssertEqual(accumulator.addDelta(1, lineHeight: line), [.up])
        XCTAssertEqual(accumulator.offset, 30)
    }

    func testNegativeDeltaRequestsDown() {
        var accumulator = ScrollAccumulator()
        XCTAssertEqual(accumulator.addDelta(-12, lineHeight: line), [.down])
        XCTAssertEqual(accumulator.offset, -12)
    }

    func testReversalRequestsOppositeDirection() {
        var accumulator = ScrollAccumulator()
        _ = accumulator.addDelta(30, lineHeight: line)
        XCTAssertEqual(accumulator.addDelta(-15, lineHeight: line), [.down, .down])
        // Two of the three sent lines were undone: 15 up remain outstanding.
        XCTAssertEqual(accumulator.offset, 15)
    }

    func testConfirmationShrinksVisualLead() {
        var accumulator = ScrollAccumulator()
        _ = accumulator.addDelta(30, lineHeight: line)
        // Neovim scrolled the window up by two lines in response to wheelup.
        accumulator.confirmScroll(rows: -2, lineHeight: line)
        XCTAssertEqual(accumulator.offset, 10)
        accumulator.confirmScroll(rows: -1, lineHeight: line)
        XCTAssertTrue(accumulator.isSettled)
    }

    func testDownConfirmationShrinksNegativeLead() {
        var accumulator = ScrollAccumulator()
        _ = accumulator.addDelta(-30, lineHeight: line)
        accumulator.confirmScroll(rows: 3, lineHeight: line)
        XCTAssertEqual(accumulator.offset, 0)
    }

    func testBeginGesturePreservesVisualOffset() {
        var accumulator = ScrollAccumulator()
        _ = accumulator.addDelta(13, lineHeight: line)
        accumulator.confirmScroll(rows: -1, lineHeight: line)
        XCTAssertEqual(accumulator.offset, 3)

        accumulator.beginGesture()
        XCTAssertEqual(accumulator.offset, 3)
        // Sent lines reset relative to the new gesture.
        XCTAssertEqual(accumulator.addDelta(7, lineHeight: line), [.up])
        XCTAssertEqual(accumulator.offset, 10)
    }

    func testCollapseDropsUnconfirmedLead() {
        var accumulator = ScrollAccumulator()
        _ = accumulator.addDelta(25, lineHeight: line)
        accumulator.collapse()
        XCTAssertTrue(accumulator.isSettled)
    }

    func testLeadIsCapped() {
        var accumulator = ScrollAccumulator(maxLead: 40)
        _ = accumulator.addDelta(100, lineHeight: line)
        XCTAssertEqual(accumulator.offset, 40)
        // The cap throttles requests: only the four lead lines are sent.
        XCTAssertEqual(accumulator.addDelta(10, lineHeight: line), [])
        XCTAssertEqual(accumulator.offset, 40)
    }

    func testNegativeLeadIsCapped() {
        var accumulator = ScrollAccumulator(maxLead: 40)
        _ = accumulator.addDelta(-100, lineHeight: line)
        XCTAssertEqual(accumulator.offset, -40)
    }
}
