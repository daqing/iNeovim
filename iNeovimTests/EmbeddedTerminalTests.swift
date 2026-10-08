import XCTest
@testable import iNeovim

/// T8.7 sanity check: the embedded `nvim` must be able to open a `:terminal`
/// even though the app (and the nvim child) run under the App Sandbox. The
/// test host is the sandboxed app, so a passing run exercises the same
/// entitlement path as the shipped build.
@MainActor
final class EmbeddedTerminalTests: XCTestCase {
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

    private func waitForSession(timeout: TimeInterval = 15) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !AppModel.shared.isReady, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return AppModel.shared.isReady
    }
}
