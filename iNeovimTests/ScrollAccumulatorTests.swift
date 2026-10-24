import XCTest
@testable import iNeovim

final class ScrollAccumulatorTests: XCTestCase {
    private let line: CGFloat = 10

    /// The controller caps the lead at one cell height; every test that cares
    /// about the visual offset uses that cap.
    private func makeAccumulator() -> ScrollAccumulator {
        ScrollAccumulator(maxLead: line)
    }

    func testWheelStepsUseNvimWheelButtonAndDirection() {
        // `nvim_input_mouse` takes the wheel as button "wheel" plus the
        // direction as the action; the terminfo-style "wheelup"/"press" pair
        // is rejected, so the grid never scrolls.
        XCTAssertEqual(ScrollLineRequest.up.wheelButton.button, "wheel")
        XCTAssertEqual(ScrollLineRequest.up.wheelButton.action, "up")
        XCTAssertEqual(ScrollLineRequest.down.wheelButton.button, "wheel")
        XCTAssertEqual(ScrollLineRequest.down.wheelButton.action, "down")
    }

    // MARK: - Whole-line requests

    func testWholeLinesBecomeScrollRequests() {
        var accumulator = makeAccumulator()
        XCTAssertEqual(accumulator.addDelta(25, lineHeight: line), [.up, .up])
        XCTAssertEqual(accumulator.addDelta(4, lineHeight: line), [])
        XCTAssertEqual(accumulator.addDelta(1, lineHeight: line), [.up])
        XCTAssertEqual(accumulator.sent, 30)
    }

    func testNegativeDeltaRequestsDown() {
        var accumulator = makeAccumulator()
        XCTAssertEqual(accumulator.addDelta(-12, lineHeight: line), [.down])
        XCTAssertEqual(accumulator.sent, -10)
    }

    func testReversalRequestsOppositeDirection() {
        var accumulator = makeAccumulator()
        _ = accumulator.addDelta(30, lineHeight: line)
        // Reversing 1.5 lines cancels the one whole requested line the reverse
        // crossed; the remaining half line stays outstanding. Rounding down
        // (rather than up) keeps small reversals from overshooting.
        XCTAssertEqual(accumulator.addDelta(-15, lineHeight: line), [.down])
        XCTAssertEqual(accumulator.sent, 20)
    }

    func testRequestsAreNeverThrottled() {
        // A fast spin must reach Neovim in full: dropping deltas past the lead
        // cap made the content fall behind the wheel.
        var accumulator = makeAccumulator()
        XCTAssertEqual(accumulator.addDelta(100, lineHeight: line).count, 10)
        XCTAssertEqual(accumulator.addDelta(10, lineHeight: line), [.up])
        XCTAssertEqual(accumulator.addDelta(-40, lineHeight: line).count, 4)
    }

    // MARK: - Visual lead

    func testSubLineTravelWaitsForAWholeLine() {
        // A trackpad's pixel deltas only move the content once they add up to
        // a line: the lead is whole lines, so none of it is left over to give
        // back when the gesture ends.
        var accumulator = makeAccumulator()
        XCTAssertEqual(accumulator.addDelta(4, lineHeight: line), [])
        XCTAssertEqual(accumulator.offset, 0)
        XCTAssertEqual(accumulator.addDelta(3, lineHeight: line), [])
        XCTAssertEqual(accumulator.offset, 0)
        XCTAssertEqual(accumulator.addDelta(3, lineHeight: line), [.up])
        XCTAssertEqual(accumulator.offset, 10)
    }

    func testWholeLineLeadFollowsTheWheel() {
        // One wheel step is a whole line: the content moves with the wheel at
        // once, and the confirmation replaces that line with the painted row.
        var accumulator = makeAccumulator()
        XCTAssertEqual(accumulator.addDelta(10, lineHeight: line), [.up])
        XCTAssertEqual(accumulator.offset, 10)
        accumulator.confirmScroll(rows: -1, lineHeight: line)
        XCTAssertTrue(accumulator.isSettled)
    }

    func testWholeLineLeadFollowsTheWheelDownwards() {
        var accumulator = makeAccumulator()
        XCTAssertEqual(accumulator.addDelta(-10, lineHeight: line), [.down])
        XCTAssertEqual(accumulator.offset, -10)
        accumulator.confirmScroll(rows: 1, lineHeight: line)
        XCTAssertEqual(accumulator.offset, 0)
    }

    func testBurstClampsTheLeadToOneLine() {
        // Steps that arrive before Neovim answers may only put the content
        // one line ahead; the confirmations drain the rest a frame at a time.
        var accumulator = makeAccumulator()
        XCTAssertEqual(accumulator.addDelta(10, lineHeight: line), [.up])
        XCTAssertEqual(accumulator.addDelta(10, lineHeight: line), [.up])
        XCTAssertEqual(accumulator.addDelta(10, lineHeight: line), [.up])
        XCTAssertEqual(accumulator.offset, 10)
        accumulator.confirmScroll(rows: -1, lineHeight: line)
        XCTAssertEqual(accumulator.offset, 10)
        accumulator.confirmScroll(rows: -1, lineHeight: line)
        XCTAssertEqual(accumulator.offset, 10)
        accumulator.confirmScroll(rows: -1, lineHeight: line)
        XCTAssertEqual(accumulator.offset, 0)
    }

    func testConfirmationResumesTheLead() {
        var accumulator = makeAccumulator()
        _ = accumulator.addDelta(10, lineHeight: line)
        XCTAssertEqual(accumulator.offset, 10)
        // Neovim scrolled the window up by one line in response to wheelup.
        accumulator.confirmScroll(rows: -1, lineHeight: line)
        XCTAssertTrue(accumulator.isSettled)
        XCTAssertEqual(accumulator.addDelta(3, lineHeight: line), [])
        XCTAssertEqual(accumulator.offset, 0)
        XCTAssertEqual(accumulator.addDelta(7, lineHeight: line), [.up])
        XCTAssertEqual(accumulator.offset, 10)
    }

    func testConfirmationSettlesTheRequestedLine() {
        var accumulator = makeAccumulator()
        XCTAssertEqual(accumulator.addDelta(13, lineHeight: line), [.up])
        XCTAssertEqual(accumulator.offset, 10)
        accumulator.confirmScroll(rows: -1, lineHeight: line)
        // Three points of travel are still outstanding, but they are not a
        // line, so the content sits on the grid instead of three points off.
        XCTAssertEqual(accumulator.offset, 0)
        XCTAssertEqual(accumulator.addDelta(7, lineHeight: line), [.up])
        XCTAssertEqual(accumulator.offset, 10)
    }

    func testOffsetNeverCrossesZeroAgainstTheGesture() {
        // A confirmation that outruns the gesture (Neovim scrolling on its
        // own, or a late one) must not drag the content the other way.
        var accumulator = makeAccumulator()
        _ = accumulator.addDelta(10, lineHeight: line)
        accumulator.confirmScroll(rows: -1, lineHeight: line)
        XCTAssertEqual(accumulator.offset, 0)
        accumulator.confirmScroll(rows: -1, lineHeight: line)
        XCTAssertEqual(accumulator.offset, 0)

        var downward = makeAccumulator()
        _ = downward.addDelta(-10, lineHeight: line)
        downward.confirmScroll(rows: 1, lineHeight: line)
        downward.confirmScroll(rows: 1, lineHeight: line)
        XCTAssertEqual(downward.offset, 0)
    }

    func testBeginGesturePreservesTheWholeLineLead() {
        var accumulator = makeAccumulator()
        _ = accumulator.addDelta(13, lineHeight: line)
        XCTAssertEqual(accumulator.offset, 10)

        accumulator.beginGesture()
        XCTAssertEqual(accumulator.offset, 10)
        // The unrequested sub-line remainder survives the gesture change:
        // three points were never requested, so seven more cross a line.
        XCTAssertEqual(accumulator.addDelta(4, lineHeight: line), [])
        XCTAssertEqual(accumulator.addDelta(6, lineHeight: line), [.up])
        accumulator.confirmScroll(rows: -1, lineHeight: line)
        XCTAssertEqual(accumulator.offset, 10)
    }

    func testBeginGestureDoesNotReRequestAnInFlightLine() {
        // A whole-line lead is still in flight when the next gesture starts
        // (a wheel's idle timer ends the gesture before a slow confirmation
        // arrives); the preserved line must not be requested a second time.
        var accumulator = makeAccumulator()
        XCTAssertEqual(accumulator.addDelta(10, lineHeight: line), [.up])
        XCTAssertEqual(accumulator.offset, 10)

        accumulator.beginGesture()
        XCTAssertEqual(accumulator.offset, 10)
        XCTAssertEqual(accumulator.addDelta(1, lineHeight: line), [])
        accumulator.confirmScroll(rows: -1, lineHeight: line)
        XCTAssertEqual(accumulator.offset, 0)
    }

    func testCollapseDropsTheLeadWithoutBackwardsJump() {
        var accumulator = makeAccumulator()
        _ = accumulator.addDelta(10, lineHeight: line)
        XCTAssertEqual(accumulator.offset, 10)
        accumulator.collapse()
        XCTAssertTrue(accumulator.isSettled)
        // A confirmation still in flight leaves the content at rest.
        accumulator.confirmScroll(rows: -1, lineHeight: line)
        XCTAssertEqual(accumulator.offset, 0)
    }
}
