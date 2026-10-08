import XCTest
@testable import iNeovim

/// Integration checks against the live embedded-nvim session. The test host
/// is the real app, so a passing run exercises the same launch path as the
/// shipped build.
@MainActor
final class EmbeddedTerminalTests: XCTestCase {
    /// T8.7: the embedded `nvim` can open a `:terminal` (PTY + shell).
    func testEmbeddedTerminalStarts() async throws {
        let ready = await waitForSession()
        try XCTSkipUnless(ready, "Embedded nvim session did not start (nvim missing or handshake failed)")

        let client = NvimClient()
        try await client.command("terminal")
        // Give the terminal buffer a moment to be created.
        try await Task.sleep(for: .milliseconds(400))

        let name = try await client.evaluate("bufname('%')")
        XCTAssertTrue(
            name.contains("term"),
            "expected the current buffer to be a terminal, got \(name)"
        )
    }

    func testEmbeddedSessionStartsInHomeDirectory() async throws {
        let ready = await waitForSession()
        try XCTSkipUnless(ready, "Embedded nvim session did not start (nvim missing or handshake failed)")

        let cwd = try await NvimClient().evaluate("getcwd()")
        var home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        if home.hasSuffix("/") { home.removeLast() }
        XCTAssertEqual(
            cwd,
            home,
            "the embedded nvim should start with $HOME as its working directory"
        )
    }

    private func waitForSession(timeout: TimeInterval = 15) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !AppModel.shared.isReady, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return AppModel.shared.isReady
    }
}
