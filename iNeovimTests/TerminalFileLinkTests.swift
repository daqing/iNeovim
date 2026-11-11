import XCTest
@testable import iNeovim

final class TerminalFileLinkTests: XCTestCase {
    /// The repository root: this file lives in iNeovimTests/, one level down.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var agentsFile: URL {
        repoRoot.appendingPathComponent("AGENTS.md")
    }

    func testAbsolutePath() throws {
        let link = try XCTUnwrap(TerminalFileLink.parse(agentsFile.path, workingDirectory: nil))
        XCTAssertEqual(link.url.standardizedFileURL, agentsFile.standardizedFileURL)
        XCTAssertNil(link.line)
        XCTAssertNil(link.column)
    }

    func testRelativePathResolvesAgainstTheWorkingDirectory() throws {
        let link = try XCTUnwrap(TerminalFileLink.parse("AGENTS.md", workingDirectory: repoRoot))
        XCTAssertEqual(link.url.standardizedFileURL, agentsFile.standardizedFileURL)
    }

    func testQuotedRelativePath() throws {
        let link = try XCTUnwrap(TerminalFileLink.parse("\"AGENTS.md\"", workingDirectory: repoRoot))
        XCTAssertEqual(link.url.standardizedFileURL, agentsFile.standardizedFileURL)
    }

    func testLineAndColumnSuffix() throws {
        let link = try XCTUnwrap(
            TerminalFileLink.parse("AGENTS.md:12:3", workingDirectory: repoRoot)
        )
        XCTAssertEqual(link.url.standardizedFileURL, agentsFile.standardizedFileURL)
        XCTAssertEqual(link.line, 12)
        XCTAssertEqual(link.column, 3)
    }

    func testLineOnlySuffixOnABareFilename() throws {
        // `AGENTS.md:12` must not be mistaken for a URL with the scheme
        // "AGENTS.md".
        let link = try XCTUnwrap(
            TerminalFileLink.parse("AGENTS.md:12", workingDirectory: repoRoot)
        )
        XCTAssertEqual(link.url.standardizedFileURL, agentsFile.standardizedFileURL)
        XCTAssertEqual(link.line, 12)
        XCTAssertNil(link.column)
    }

    func testFileURL() throws {
        let link = try XCTUnwrap(
            TerminalFileLink.parse(agentsFile.absoluteString, workingDirectory: nil)
        )
        XCTAssertEqual(link.url.standardizedFileURL, agentsFile.standardizedFileURL)
    }

    func testWebURLIsNotAFileLink() {
        XCTAssertNil(TerminalFileLink.parse(
            "https://example.com/file.rb", workingDirectory: repoRoot
        ))
    }

    func testMissingPathIsNotAFileLink() {
        XCTAssertNil(TerminalFileLink.parse("missing-file.rb", workingDirectory: repoRoot))
        XCTAssertNil(TerminalFileLink.parse("missing-file.rb:12", workingDirectory: repoRoot))
    }

    func testDirectoryIsNotAFileLink() {
        XCTAssertNil(TerminalFileLink.parse(repoRoot.path, workingDirectory: nil))
    }

    func testRelativePathWithoutAWorkingDirectoryIsRejected() {
        XCTAssertNil(TerminalFileLink.parse("AGENTS.md", workingDirectory: nil))
    }
}
