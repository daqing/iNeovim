import AppKit
import XCTest
@testable import iNeovim

@MainActor
final class TerminalViewThemeTests: XCTestCase {
    func testDarkBackgroundReadsAsDark() {
        XCTAssertEqual(TerminalView.hasDarkBackground(0x1E222A), true)
    }

    func testLightBackgroundReadsAsLight() {
        XCTAssertEqual(TerminalView.hasDarkBackground(0xFFFFFF), false)
    }

    func testUnsetBackgroundIsUnknown() {
        XCTAssertNil(TerminalView.hasDarkBackground(nil))
        // nvim's -1 sentinel for "not set" is not a color.
        XCTAssertNil(TerminalView.hasDarkBackground(-1))
    }
}
