import XCTest
@testable import iNeovim

@MainActor
final class TerminalPaneCommandTests: XCTestCase {
    func testTerminalInvocationsMatch() {
        // Full name, nvim abbreviations, whitespace, and the bang variant.
        for command in ["terminal", "term", "termina", "  terminal", "terminal!"] {
            XCTAssertTrue(TerminalView.isNativeTerminalCommand(command), "\(command) should match")
        }
        // The vertical modifier names the pane's right-side placement.
        for command in ["vert term", "vertical terminal", "vert term zsh -l"] {
            XCTAssertTrue(TerminalView.isNativeTerminalCommand(command), "\(command) should match")
        }
    }

    func testNonTerminalCommandsDoNotMatch() {
        for command in [
            "te", "terma", "terminalfoo", "Term", "TERMINAL", "files", "",
            "tab term", "hor term", "vertical split", "vertical",
        ] {
            XCTAssertFalse(TerminalView.isNativeTerminalCommand(command), "\(command) should not match")
        }
    }

    func testArgumentsBecomeTheShellCommand() {
        XCTAssertEqual(TerminalView.nativeTerminalRequest(from: "term"), "")
        XCTAssertEqual(TerminalView.nativeTerminalRequest(from: "terminal"), "")
        XCTAssertEqual(TerminalView.nativeTerminalRequest(from: "term git status"), "git status")
        XCTAssertEqual(TerminalView.nativeTerminalRequest(from: "vert term zsh -l"), "zsh -l")
        XCTAssertEqual(TerminalView.nativeTerminalRequest(from: "  term!  ls -la "), "ls -la")
    }

    func testNonTerminalCommandsHaveNoRequest() {
        XCTAssertNil(TerminalView.nativeTerminalRequest(from: "te"))
        XCTAssertNil(TerminalView.nativeTerminalRequest(from: "Term"))
        XCTAssertNil(TerminalView.nativeTerminalRequest(from: "tab term"))
        XCTAssertNil(TerminalView.nativeTerminalRequest(from: ""))
    }

    func testCmdlineModeNames() {
        // The UI protocol sends the full forms; "c" is mode()'s short name.
        for name in ["c", "cmdline_normal", "cmdline_insert", "cmdline_replace"] {
            XCTAssertTrue(TerminalView.isCmdlineMode(name), "\(name) should be cmdline")
        }
        for name in [nil, "normal", "insert", "replace", "visual", "operator", "cmdline"] {
            XCTAssertFalse(TerminalView.isCmdlineMode(name), "\(name.map { "'\($0)'" } ?? "nil") should not be cmdline")
        }
    }
}
