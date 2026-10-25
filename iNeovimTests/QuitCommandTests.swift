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

    func testQuitConfirmationScope() {
        // A tab among others closes only itself, however many other editor
        // windows exist.
        XCTAssertEqual(QuitConfirmation.scope(tabCount: 2, editorWindowCount: 2), .tab)
        XCTAssertEqual(QuitConfirmation.scope(tabCount: 3, editorWindowCount: 5), .tab)
        // A standalone window among others closes only itself.
        XCTAssertEqual(QuitConfirmation.scope(tabCount: 1, editorWindowCount: 2), .window)
        // The last editor window quits the app; a window that is not in a tab
        // group reports no group at all.
        XCTAssertEqual(QuitConfirmation.scope(tabCount: 1, editorWindowCount: 1), .app)
        XCTAssertEqual(QuitConfirmation.scope(tabCount: 0, editorWindowCount: 1), .app)
    }
}
