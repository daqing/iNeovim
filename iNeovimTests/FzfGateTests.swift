import XCTest
@testable import iNeovim

@MainActor
final class FzfGateTests: XCTestCase {
    func testTreeWalkingCommandsMatch() {
        for command in ["FZF", "Files", "Rg", "Ag", "RGrep", "LGrep"] {
            XCTAssertTrue(TerminalView.isFzfWalkCommand(command), "\(command) should match")
        }
        // Arguments, leading whitespace, and the bang variant all match.
        XCTAssertTrue(TerminalView.isFzfWalkCommand("Files ~/src"))
        XCTAssertTrue(TerminalView.isFzfWalkCommand("  FZF!"))
    }

    func testNonWalkingCommandsDoNotMatch() {
        for command in ["Buffers", "History", "edit file.txt", "files", "", "w", "FZF#run"] {
            XCTAssertFalse(TerminalView.isFzfWalkCommand(command), "\(command) should not match")
        }
    }

    func testRootAndHomeAreDangerous() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertTrue(TerminalView.isDangerousFzfDirectory("/"))
        XCTAssertTrue(TerminalView.isDangerousFzfDirectory(home))
        XCTAssertFalse(TerminalView.isDangerousFzfDirectory("/Users/daqing/mzevo"))
        XCTAssertFalse(TerminalView.isDangerousFzfDirectory(""))
    }
}
