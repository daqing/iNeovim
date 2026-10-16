import XCTest
@testable import iNeovim

@MainActor
final class QuitCommandTests: XCTestCase {
    func testQuitCommandsMatch() {
        // nvim abbreviations, the bang variant, and surrounding whitespace.
        for command in ["q", "qu", "qui", "quit", "q!", "quit!", "  quit"] {
            XCTAssertTrue(TerminalView.isQuitCommand(command), "\(command) should match")
        }
        // `:qa[ll]` and its abbreviations quit every window.
        for command in ["qa", "qal", "qall", "qa!", "qall!"] {
            XCTAssertTrue(TerminalView.isQuitCommand(command), "\(command) should match")
        }
    }

    func testNonQuitCommandsDoNotMatch() {
        for command in [
            "quita", "quitall", "wq", "x", "w", "qax", "write", "only",
            "Q", "QUIT", "", "  ",
        ] {
            XCTAssertFalse(TerminalView.isQuitCommand(command), "\(command) should not match")
        }
    }
}
