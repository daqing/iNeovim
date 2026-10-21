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

    func testSubLineLeadFollowsTheGesture() {
        var accumulator = makeAccumulator()
        _ = accumulator.addDelta(4, lineHeight: line)
        XCTAssertEqual(accumulator.offset, 4)
        _ = accumulator.addDelta(3, lineHeight: line)
        XCTAssertEqual(accumulator.offset, 7)
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
        _ = accumulator.addDelta(3, lineHeight: line)
        XCTAssertEqual(accumulator.offset, 3)
    }

    func testConfirmationShrinksAnOutstandingLead() {
        var accumulator = makeAccumulator()
        _ = accumulator.addDelta(4, lineHeight: line)
        XCTAssertEqual(accumulator.offset, 4)
        _ = accumulator.addDelta(4, lineHeight: line)
        XCTAssertEqual(accumulator.offset, 8)
        // Neovim scrolled a whole line: the lead is spent, leaving the
        // sub-line part of the gesture outstanding.
        accumulator.confirmScroll(rows: -1, lineHeight: line)
        XCTAssertEqual(accumulator.offset, 0)
    }

    func testOffsetNeverCrossesZeroAgainstTheGesture() {
        // A confirmation that outruns the gesture (Neovim scrolling on its
        // own, or a late one) must not drag the content the other way.
        var accumulator = makeAccumulator()
        _ = accumulator.addDelta(4, lineHeight: line)
        accumulator.confirmScroll(rows: -1, lineHeight: line)
        XCTAssertEqual(accumulator.offset, 0)

        var downward = makeAccumulator()
        _ = downward.addDelta(-4, lineHeight: line)
        downward.confirmScroll(rows: 1, lineHeight: line)
        XCTAssertEqual(downward.offset, 0)
    }

    func testBeginGesturePreservesTheSubLineOffset() {
        var accumulator = makeAccumulator()
        _ = accumulator.addDelta(13, lineHeight: line)
        accumulator.confirmScroll(rows: -1, lineHeight: line)
        XCTAssertEqual(accumulator.offset, 3)

        accumulator.beginGesture()
        XCTAssertEqual(accumulator.offset, 3)
        // The unrequested sub-line remainder survives the gesture change.
        XCTAssertEqual(accumulator.addDelta(4, lineHeight: line), [])
        XCTAssertEqual(accumulator.addDelta(4, lineHeight: line), [.up])
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
        XCTAssertEqual(accumulator.offset, 1)
    }

    func testCollapseDropsTheLeadWithoutBackwardsJump() {
        var accumulator = makeAccumulator()
        _ = accumulator.addDelta(4, lineHeight: line)
        accumulator.collapse()
        XCTAssertTrue(accumulator.isSettled)
        // A confirmation still in flight leaves the content at rest.
        accumulator.confirmScroll(rows: -1, lineHeight: line)
        XCTAssertEqual(accumulator.offset, 0)
    }
}
