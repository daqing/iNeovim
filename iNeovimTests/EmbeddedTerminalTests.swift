import XCTest
@testable import iNeovim

/// Integration checks against a live embedded-nvim session. The test host is
/// the real app, so a passing run exercises the same launch path as the
/// shipped build.
@MainActor
final class EmbeddedTerminalTests: XCTestCase {
    /// T8.7: the embedded `nvim` can open a `:terminal` (PTY + shell).
    func testEmbeddedTerminalStarts() async throws {
        guard let model = await readyModel() else {
            throw XCTSkip("Embedded nvim session did not start (nvim missing or handshake failed)")
        }

        let client = model.client
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
        guard let model = await readyModel() else {
            throw XCTSkip("Embedded nvim session did not start (nvim missing or handshake failed)")
        }

        let cwd = try await model.client.evaluate("getcwd()")
        var home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        if home.hasSuffix("/") { home.removeLast() }
        XCTAssertEqual(
            cwd,
            home,
            "the embedded nvim should start with $HOME as its working directory"
        )
    }

    private func readyModel(timeout: TimeInterval = 15) async -> AppModel? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let model = AppModel.live.first(where: \.isReady) { return model }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return AppModel.live.first(where: \.isReady)
    }
}
