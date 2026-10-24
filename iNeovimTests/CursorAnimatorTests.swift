import XCTest
@testable import iNeovim

final class CursorAnimatorTests: XCTestCase {
    func testInterpolatedOffsetStartsAtFrom() {
        XCTAssertEqual(
            CursorAnimator.interpolatedOffset(from: CGSize(width: 7, height: -10), progress: 0),
            CGSize(width: 7, height: -10)
        )
    }

    func testInterpolatedOffsetEndsAtZero() {
        XCTAssertEqual(
            CursorAnimator.interpolatedOffset(from: CGSize(width: 7, height: -10), progress: 1),
            .zero
        )
    }

    func testInterpolatedOffsetIsLinear() {
        XCTAssertEqual(
            CursorAnimator.interpolatedOffset(from: CGSize(width: 10, height: 0), progress: 0.25),
            CGSize(width: 7.5, height: 0)
        )
    }

    func testEaseOutCubicEndpoints() {
        XCTAssertEqual(CursorAnimator.easeOutCubic(0), 0)
        XCTAssertEqual(CursorAnimator.easeOutCubic(1), 1)
    }

    func testEaseOutCubicIsBackLoaded() {
        // Past the midpoint, more of the curve remains than has elapsed.
        XCTAssertEqual(CursorAnimator.easeOutCubic(0.5), 0.875, accuracy: 0.001)
    }
}
