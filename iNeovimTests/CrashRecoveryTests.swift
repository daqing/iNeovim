import XCTest
@testable import iNeovim

/// T9.1: the app must surface an unexpected nvim exit and be able to restart
/// the embedded process in place. Boots its own private session so the app's
/// windows are unaffected, and skips when nvim is unavailable.
@MainActor
final class CrashRecoveryTests: XCTestCase {
    func testRestartAfterCrashRestoresSession() async throws {
        let model = AppModel()
        await model.bootstrap()
        try XCTSkipUnless(
            model.isReady,
            "Embedded nvim session did not start: \(model.bootstrapError ?? "unknown")"
        )

        let client = model.client
        try await client.command("let g:ineovim_probe = 1")

        await model.session.process.terminate()
        let crashed = await waitFor(timeout: 10) { model.crash != nil }
        XCTAssertTrue(
            crashed,
            "nvim exit not surfaced; ready=\(model.isReady) crash=\(String(describing: model.crash))"
        )

        model.restart()
        let recovered = await waitFor(timeout: 15) { model.isReady }
        XCTAssertTrue(recovered, "session did not recover after restart")
        model.dismissCrash()

        // A fresh process must not carry the old global.
        let probe = try await client.evaluate("exists('g:ineovim_probe')")
        XCTAssertEqual(probe, "0")
    }

    private func waitFor(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }
}
