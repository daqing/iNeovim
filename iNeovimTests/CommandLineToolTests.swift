import XCTest
@testable import iNeovim

@MainActor
final class CommandLineToolTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/test")

    func testPrefersUserLocalBinWhenItIsOnPath() {
        let destination = CommandLineTool.resolveDestination(
            homeDirectory: home,
            shellPath: ["/usr/bin", "/Users/test/.local/bin", "/opt/homebrew/bin"],
            fileExists: { $0 == "/Users/test/.local/bin" || $0 == "/opt/homebrew/bin" }
        )
        XCTAssertEqual(destination.directory.path, "/Users/test/.local/bin")
        XCTAssertEqual(destination.isOnPath, true)
    }

    func testCreatesLocalBinWhenItIsOnPathButMissing() {
        let destination = CommandLineTool.resolveDestination(
            homeDirectory: home,
            shellPath: ["/Users/test/.local/bin", "/usr/local/bin"],
            fileExists: { $0 == "/usr/local/bin" }
        )
        XCTAssertEqual(destination.directory.path, "/Users/test/.local/bin")
        XCTAssertEqual(destination.isOnPath, true)
    }

    func testSkipsLocalBinWhenItIsNotOnPath() {
        let destination = CommandLineTool.resolveDestination(
            homeDirectory: home,
            shellPath: ["/usr/bin", "/opt/homebrew/bin"],
            fileExists: { $0 == "/Users/test/.local/bin" || $0 == "/opt/homebrew/bin" }
        )
        XCTAssertEqual(destination.directory.path, "/opt/homebrew/bin")
        XCTAssertEqual(destination.isOnPath, true)
    }

    func testFallsBackToLocalBinAndReportsMissingPath() {
        let destination = CommandLineTool.resolveDestination(
            homeDirectory: home,
            shellPath: ["/usr/bin", "/bin"],
            fileExists: { _ in false }
        )
        XCTAssertEqual(destination.directory.path, "/Users/test/.local/bin")
        XCTAssertEqual(destination.isOnPath, false)
    }

    func testLauncherScriptOpensThroughTheApp() {
        let script = CommandLineTool.launcherScript(appPath: "/Applications/iNeovim.app")
        XCTAssertTrue(script.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(script.contains("APP_PATH='/Applications/iNeovim.app'"))
        XCTAssertTrue(script.contains("exec /usr/bin/open -a \"$APP_PATH\" \"$@\""))
        XCTAssertTrue(script.contains("BUNDLE_ID='com.mzevo.iNeovim'"))
    }

    func testLauncherScriptQuotesTheAppPath() {
        let script = CommandLineTool.launcherScript(appPath: "/Applications/Neo's Editor.app")
        XCTAssertTrue(script.contains("APP_PATH='/Applications/Neo'\\''s Editor.app'"))
    }
}
