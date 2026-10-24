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

    /// The diagnostics hook installed at bootstrap forwards every
    /// `vim.diagnostic` change (any language server, any buffer) to the app
    /// as `ineovim:diagnostics` notifications; both a set and its clear must
    /// land in the session's store.
    func testDiagnosticsHookPushesSetAndClear() async throws {
        guard let model = await readyModel() else {
            throw XCTSkip("Embedded nvim session did not start (nvim missing or handshake failed)")
        }

        func probeProblems() -> [DiagnosticsStore.Problem] {
            model.diagnosticsStore.problems.filter { $0.diagnostic.source == "ineovim-tests" }
        }

        _ = try await model.client.execLua(Self.setProbeDiagnosticsLua, args: [])
        let appeared = await waitUntil(timeout: 5) { !probeProblems().isEmpty }
        XCTAssertTrue(appeared, "diagnostics set in nvim never reached the app store")
        let problems = probeProblems()
        XCTAssertEqual(problems.map(\.diagnostic.severity), [.error, .warning])
        XCTAssertEqual(problems.map(\.diagnostic.line), [3, 5])

        _ = try await model.client.execLua(Self.clearProbeDiagnosticsLua, args: [])
        let cleared = await waitUntil(timeout: 5) { probeProblems().isEmpty }
        XCTAssertTrue(cleared, "clearing diagnostics in nvim never reached the app store")
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private static let setProbeDiagnosticsLua = """
        local ns = vim.api.nvim_create_namespace('ineovim_tests')
        vim.diagnostic.set(ns, 0, {
          { lnum = 3, col = 0, severity = 1, message = 'probe error', source = 'ineovim-tests' },
          { lnum = 5, col = 0, severity = 2, message = 'probe warning', source = 'ineovim-tests' },
        }, {})
        return true
        """

    private static let clearProbeDiagnosticsLua = """
        local ns = vim.api.nvim_get_namespaces()['ineovim_tests']
        vim.diagnostic.set(ns, 0, {}, {})
        return true
        """

    private func readyModel(timeout: TimeInterval = 15) async -> AppModel? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let model = AppModel.live.first(where: \.isReady) { return model }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return AppModel.live.first(where: \.isReady)
    }
}
