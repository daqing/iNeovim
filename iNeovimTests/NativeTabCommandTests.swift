import XCTest
@testable import iNeovim

@MainActor
final class NativeTabCommandTests: XCTestCase {
    func testTabCreationCommandsMatch() {
        // Full name, the :tabe[dit] abbreviation, whitespace, and the bang
        // variant.
        for command in ["tabnew", "tabe", "tabedit", "  tabnew", "tabnew!"] {
            XCTAssertTrue(TerminalView.isNativeTabCommand(command), "\(command) should match")
        }
    }

    func testNonTabCommandsDoNotMatch() {
        for command in [
            // `tabne…` is ambiguous with :tabnext, so nvim keeps it.
            "tabne", "tab", "tabn", "tabnext", "tabprevious", "tabclose",
            "tab term", "tabfind x", "tabdrop x", "Tabnew", "TABNEW", "",
        ] {
            XCTAssertFalse(TerminalView.isNativeTabCommand(command), "\(command) should not match")
        }
    }

    func testFileArgumentCarriesOver() {
        XCTAssertEqual(TerminalView.nativeTabRequest(from: "tabnew"), "")
        XCTAssertEqual(TerminalView.nativeTabRequest(from: "tabe"), "")
        XCTAssertEqual(TerminalView.nativeTabRequest(from: "tabedit src/main.go"), "src/main.go")
        XCTAssertEqual(TerminalView.nativeTabRequest(from: "  tabnew  ~/notes.md "), "~/notes.md")
    }

    func testModifiersAndBarsStayWithNvim() {
        // `+cmd`, `++opt`, and `|` bars need nvim's own execution.
        for command in ["tabnew +readme", "tabnew ++ff=unix file", "tabe a.txt | b.txt"] {
            XCTAssertNil(TerminalView.nativeTabRequest(from: command), "\(command) should not match")
        }
    }
}
