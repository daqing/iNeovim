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

    /// The cmdline gates (`:terminal` interception, fzf) key on the mode
    /// name carried by our snapshots. This pins what nvim's UI protocol
    /// actually reports when the user enters cmdline mode: the full form
    /// (`cmdline_normal`), not `mode()`'s short `"c"`.
    func testCmdlineModeIsReportedAsCmdlineNormal() async throws {
        guard let model = await readyModel() else {
            throw XCTSkip("Embedded nvim session did not start (nvim missing or handshake failed)")
        }

        // Baseline BEFORE pressing ':' — the redraw may land before the
        // input call returns, so the baseline must not race it.
        let baseline = await model.screen.snapshot().modeName
        try await model.client.input(":")
        var reported: String?
        var last: String?
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let snapshot = await model.screen.snapshot()
            last = snapshot.modeName
            if let modeName = snapshot.modeName, modeName != baseline {
                reported = modeName
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        try await model.client.input("<Esc>")

        XCTAssertTrue(
            TerminalView.isCmdlineMode(reported),
            "baseline \(baseline.map { "'\($0)'" } ?? "nil"), nvim reported mode \(reported.map { "'\($0)'" } ?? last.map { "'\($0)'" } ?? "nil") after ':'; the cmdline gates must accept it"
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
