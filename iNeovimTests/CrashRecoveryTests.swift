import XCTest
@testable import iNeovim

/// T9.1: the app must surface an unexpected nvim exit and be able to restart
/// the embedded process in place. Runs against the real app session, so it
/// skips when nvim is unavailable.
@MainActor
final class CrashRecoveryTests: XCTestCase {
    func testRestartAfterCrashRestoresSession() async throws {
        let ready = await waitForReady()
        try XCTSkipUnless(
            ready,
            "Embedded nvim session did not start: \(AppModel.shared.bootstrapError ?? "unknown")"
        )

        let client = NvimClient()
        try await client.command("let g:ineovim_probe = 1")

        await NvimProcess.shared.terminate()
        let crashed = await waitFor(timeout: 10) { AppModel.shared.crash != nil }
        XCTAssertTrue(
            crashed,
            "nvim exit not surfaced; ready=\(AppModel.shared.isReady) crash=\(String(describing: AppModel.shared.crash))"
        )

        AppModel.shared.restart()
        let recovered = await waitFor(timeout: 15) { AppModel.shared.isReady }
        XCTAssertTrue(recovered, "session did not recover after restart")
        AppModel.shared.dismissCrash()

        // A fresh process must not carry the old global.
        let probe = try await client.evaluate("exists('g:ineovim_probe')")
        XCTAssertEqual(probe, "0")
    }

    private func waitForReady(timeout: TimeInterval = 15) async -> Bool {
        await waitFor(timeout: timeout) { AppModel.shared.isReady }
    }

    private func waitFor(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }
}
