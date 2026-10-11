import XCTest
@testable import iNeovim

@MainActor
final class NvimDiagnosticsTests: XCTestCase {
    private func diagnosticMap(_ fields: [MsgPackValue: MsgPackValue]) -> MsgPackValue {
        .map(MsgPackValueMap(fields))
    }

    func testParseUpdatePayload() {
        let params: [MsgPackValue] = [
            diagnosticMap([
                .string("buf"): .uint(3),
                .string("name"): .string("/tmp/proj/main.go"),
                .string("diagnostics"): .array([
                    diagnosticMap([
                        .string("lnum"): .uint(4),
                        .string("col"): .uint(0),
                        .string("end_lnum"): .uint(4),
                        .string("end_col"): .uint(9),
                        .string("severity"): .uint(1),
                        .string("message"): .string("undefined: fmt"),
                        .string("source"): .string("gopls"),
                        .string("code"): .string("E1009"),
                    ]),
                    diagnosticMap([
                        .string("lnum"): .uint(12),
                        .string("col"): .uint(2),
                        .string("end_lnum"): .uint(12),
                        .string("end_col"): .uint(7),
                        .string("severity"): .uint(2),
                        .string("message"): .string("unused variable x"),
                        .string("source"): .string("gopls"),
                    ]),
                ]),
            ]),
        ]

        let update = NvimDiagnosticUpdate.parse(params)

        XCTAssertNotNil(update)
        XCTAssertEqual(update?.bufferId, 3)
        XCTAssertEqual(update?.path, "/tmp/proj/main.go")
        XCTAssertEqual(update?.diagnostics.count, 2)
        XCTAssertEqual(update?.diagnostics[0].severity, .error)
        XCTAssertEqual(update?.diagnostics[0].line, 4)
        XCTAssertEqual(update?.diagnostics[0].endColumn, 9)
        XCTAssertEqual(update?.diagnostics[0].code, "E1009")
        XCTAssertEqual(update?.diagnostics[1].severity, .warning)
    }

    func testParseToleratesMissingAndMalformedPayload() {
        XCTAssertNil(NvimDiagnosticUpdate.parse([]))
        XCTAssertNil(NvimDiagnosticUpdate.parse([.string("junk")]))
        XCTAssertNil(NvimDiagnosticUpdate.parse([.map(MsgPackValueMap([.string("name"): .string("x")]))]))

        // nvim's encoder drops nil-valued keys: a clean buffer arrives with
        // just `buf`, and entries can miss optional fields.
        let minimal = NvimDiagnosticUpdate.parse([
            diagnosticMap([
                .string("buf"): .int(7),
                .string("name"): .string(""),
                .string("diagnostics"): .array([
                    diagnosticMap([.string("message"): .string("boom")]),
                    .string("not a map"),
                ]),
            ]),
        ])
        XCTAssertEqual(minimal?.bufferId, 7)
        XCTAssertEqual(minimal?.path, "")
        XCTAssertEqual(minimal?.diagnostics.count, 1)
        XCTAssertEqual(minimal?.diagnostics[0].severity, .info)
        XCTAssertEqual(minimal?.diagnostics[0].line, 0)
    }

    func testStoreAggregatesBuffersAndSortsProblems() {
        let store = DiagnosticsStore()
        var changes = 0
        store.onChange = { changes += 1 }

        store.apply(NvimDiagnosticUpdate(
            bufferId: 1,
            path: "/b/second.go",
            diagnostics: [
                NvimDiagnostic(
                    severity: .warning, message: "w2", source: "s", code: "",
                    line: 0, column: 0, endLine: 0, endColumn: 0
                ),
                NvimDiagnostic(
                    severity: .error, message: "e2", source: "s", code: "",
                    line: 5, column: 1, endLine: 5, endColumn: 3
                ),
            ]
        ))
        store.apply(NvimDiagnosticUpdate(
            bufferId: 2,
            path: "/a/first.go",
            diagnostics: [
                NvimDiagnostic(
                    severity: .error, message: "e1", source: "s", code: "",
                    line: 9, column: 0, endLine: 9, endColumn: 1
                ),
                NvimDiagnostic(
                    severity: .hint, message: "h", source: "s", code: "",
                    line: 2, column: 0, endLine: 2, endColumn: 1
                ),
            ]
        ))

        XCTAssertEqual(changes, 2)
        XCTAssertEqual(store.problemCount, 3)
        let problems = store.problems
        XCTAssertEqual(problems.map(\.diagnostic.message), ["e1", "e2", "w2"])
        XCTAssertEqual(problems[0].path, "/a/first.go")
        // Hints are kept in the buffer snapshot but never listed.
        XCTAssertFalse(problems.contains { $0.diagnostic.severity == .hint })
    }

    func testStoreClearsBufferOnEmptyUpdateAndOnClear() {
        let store = DiagnosticsStore()
        store.apply(NvimDiagnosticUpdate(
            bufferId: 1,
            path: "/x.go",
            diagnostics: [
                NvimDiagnostic(
                    severity: .error, message: "e", source: "s", code: "",
                    line: 1, column: 0, endLine: 1, endColumn: 1
                ),
            ]
        ))
        var changes = 0
        store.onChange = { changes += 1 }

        store.apply(NvimDiagnosticUpdate(bufferId: 1, path: "/x.go", diagnostics: []))
        XCTAssertEqual(store.problemCount, 0)
        XCTAssertEqual(changes, 1)

        store.clear()
        XCTAssertEqual(changes, 1, "clear on an already-empty store must not fire onChange")
    }
}
