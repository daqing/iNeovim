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
        XCTAssertTrue(script.contains("BUNDLE_ID='com.mzevo.iNeovim'"))
        XCTAssertTrue(script.contains("/usr/bin/open \"ineovim://open?payload=$payload\""))
        XCTAssertTrue(script.contains("exec /usr/bin/open -a \"$APP_PATH\" \"$@\""))
    }

    func testLauncherScriptSendsWorkingDirectoryAndArguments() {
        let script = CommandLineTool.launcherScript(appPath: "/Applications/iNeovim.app")
        XCTAssertTrue(script.contains("printf '%s\\0' \"${PWD:-$(pwd -P)}\""))
        XCTAssertTrue(script.contains("printf '%s\\0' \"$arg\""))
        XCTAssertTrue(script.contains("/usr/bin/tr '+/' '-_'"))
        XCTAssertTrue(script.contains("/usr/bin/tr -d '='"))
    }

    func testLauncherScriptQuotesTheAppPath() {
        let script = CommandLineTool.launcherScript(appPath: "/Applications/Neo's Editor.app")
        XCTAssertTrue(script.contains("APP_PATH='/Applications/Neo'\\''s Editor.app'"))
    }

    func testParsesCommandLineRequest() {
        let url = requestURL(["/work/repo", "src/main.go", "/etc/hosts", "note with space.md"])
        let request = CommandLineTool.openRequest(from: url)
        XCTAssertEqual(request?.workingDirectory.path, "/work/repo")
        XCTAssertEqual(request?.files, [
            URL(fileURLWithPath: "/work/repo/src/main.go"),
            URL(fileURLWithPath: "/etc/hosts"),
            URL(fileURLWithPath: "/work/repo/note with space.md"),
        ])
    }

    func testParsesRequestWithOnlyADirectory() {
        let request = CommandLineTool.openRequest(from: requestURL(["/work/repo"]))
        XCTAssertEqual(request?.workingDirectory.path, "/work/repo")
        XCTAssertEqual(request?.files, [])
    }

    func testFileArgumentDecidesTheWorkingDirectory() {
        let request = CommandLineTool.openRequest(
            from: requestURL(["/work/repo", "/elsewhere/project/main.go", "local.md"])
        )
        XCTAssertEqual(request?.workingDirectory.path, "/elsewhere/project")
        XCTAssertEqual(request?.files, [
            URL(fileURLWithPath: "/elsewhere/project/main.go"),
            URL(fileURLWithPath: "/work/repo/local.md"),
        ])
    }

    func testDirectoryArgumentBecomesTheWorkingDirectory() {
        let directory = FileManager.default.temporaryDirectory
        let request = CommandLineTool.openRequest(from: requestURL(["/work/repo", directory.path]))
        XCTAssertEqual(request?.workingDirectory.standardizedFileURL, directory.standardizedFileURL)
    }

    func testDecodesNonASCIIFileNames() {
        let url = requestURL(["/work/项目", "笔记.md"])
        let request = CommandLineTool.openRequest(from: url)
        XCTAssertEqual(request?.workingDirectory.path, "/work/项目")
        XCTAssertEqual(request?.files, [URL(fileURLWithPath: "/work/项目/笔记.md")])
    }

    func testIgnoresUnrelatedURLs() {
        XCTAssertNil(CommandLineTool.openRequest(from: URL(string: "https://example.com/open?payload=abc")!))
        XCTAssertNil(CommandLineTool.openRequest(from: URL(string: "ineovim://other?payload=abc")!))
        XCTAssertNil(CommandLineTool.openRequest(from: URL(string: "ineovim://open")!))
        XCTAssertNil(CommandLineTool.openRequest(from: URL(string: "ineovim://open?payload=!!!")!))
    }

    /// Mirrors the launcher's encoding: base64url over NUL-terminated UTF-8.
    private func requestURL(_ components: [String]) -> URL {
        var data = Data()
        for component in components {
            data.append(contentsOf: component.utf8)
            data.append(0)
        }
        let payload = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return URL(string: "ineovim://open?payload=\(payload)")!
    }
}
