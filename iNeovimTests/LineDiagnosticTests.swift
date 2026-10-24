import XCTest
@testable import iNeovim

@MainActor
final class LineDiagnosticTests: XCTestCase {
    func testParseItemsFromLuaResult() {
        let value = MsgPackValue.map(MsgPackValueMap([
            .string("lnum"): .int(12),
            .string("items"): .array([
                .map(MsgPackValueMap([
                    .string("severity"): .int(1),
                    .string("message"): .string("undefined: fmt"),
                    .string("source"): .string("gopls"),
                    .string("code"): .string("undefined"),
                ])),
                .map(MsgPackValueMap([
                    .string("severity"): .uint(2),
                    .string("message"): .string("unused variable x"),
                ])),
            ]),
        ]))

        let items = NvimClient.parseLineDiagnostics(value)

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].severity, .error)
        XCTAssertEqual(items[0].message, "undefined: fmt")
        XCTAssertEqual(items[0].source, "gopls")
        XCTAssertEqual(items[0].code, "undefined")
        XCTAssertEqual(items[1].severity, .warning)
        XCTAssertEqual(items[1].source, "")
    }

    func testParseToleratesMissingAndMalformedEntries() {
        XCTAssertEqual(NvimClient.parseLineDiagnostics(.nil), [])

        let missingItems = MsgPackValue.map(MsgPackValueMap([.string("lnum"): .int(3)]))
        XCTAssertEqual(NvimClient.parseLineDiagnostics(missingItems), [])

        let withJunk = MsgPackValue.map(MsgPackValueMap([
            .string("items"): .array([
                .string("not a map"),
                .map(MsgPackValueMap([:])),
            ]),
        ]))
        let items = NvimClient.parseLineDiagnostics(withJunk)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].severity, .info)
    }
}
