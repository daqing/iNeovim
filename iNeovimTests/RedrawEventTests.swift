import XCTest
@testable import iNeovim

@MainActor
final class RedrawEventTests: XCTestCase {
    func testParseBatch() {
        XCTAssertEqual(
            parse([
                .array([.string("grid_resize"), .uint(1), .uint(80), .uint(24)]),
                .array([.string("flush")]),
            ]),
            [
                .gridResize(grid: 1, width: 80, height: 24),
                .flush,
            ]
        )
    }

    func testParseSkipsMalformedEvents() {
        XCTAssertEqual(parse([.int(7), .array([]), .string("nope")]), [])
        // grid_clear missing its grid argument
        XCTAssertEqual(parse([.array([.string("grid_clear")])]), [])
        XCTAssertEqual(RedrawEvent.parseNotification([]), [])
    }

    func testParseToleratesFlatEventList() {
        XCTAssertEqual(
            RedrawEvent.parseNotification([.array([.string("flush")])]),
            []
        )
        XCTAssertEqual(
            RedrawEvent.parseNotification([
                .array([.string("grid_clear"), .uint(1)]),
                .array([.string("flush")]),
            ]),
            [.gridClear(grid: 1), .flush]
        )
    }

    func testGridLineParsesRunsWithRepeatAndHlContinuation() {
        let cells: MsgPackValue = .array([
            .array([.string("h"), .uint(2)]),
            .array([.string("i"), .uint(3), .uint(2)]),
            .array([.string("!")]),
            .array([.string("?"), .uint(9), .uint(0)]),
        ])
        XCTAssertEqual(
            parse([.array([.string("grid_line"), .uint(1), .uint(4), .uint(3), cells])]),
            [
                .gridLine(grid: 1, row: 4, colStart: 3, runs: [
                    GridCellRun(text: "h", attrId: 2, count: 1),
                    GridCellRun(text: "i", attrId: 3, count: 2),
                    GridCellRun(text: "!", attrId: 3, count: 1),
                    GridCellRun(text: "?", attrId: 9, count: 1),
                ]),
            ]
        )
    }

    func testGridScrollParsesNegativeRows() {
        XCTAssertEqual(
            parse([.array([
                .string("grid_scroll"),
                .uint(1), .uint(0), .uint(24), .uint(0), .uint(80), .int(-1), .uint(0),
            ])]),
            [.gridScroll(grid: 1, top: 0, bot: 24, left: 0, right: 80, rows: -1, cols: 0)]
        )
    }

    func testCursorGotoAcceptsLinegridAndLegacyForms() {
        XCTAssertEqual(
            parse([.array([.string("grid_cursor_goto"), .uint(1), .uint(5), .uint(9)])]),
            [.cursorGoto(grid: 1, row: 5, col: 9)]
        )
        XCTAssertEqual(
            parse([.array([.string("cursor_goto"), .uint(5), .uint(9)])]),
            [.cursorGoto(grid: 1, row: 5, col: 9)]
        )
    }

    func testHlAttrDefineParsesColorsAndFlags() {
        let rgbMap: MsgPackValue = .map(MsgPackValueMap([
            .string("foreground"): .uint(0xff_00_00),
            .string("background"): .uint(0x00_10_20),
            .string("special"): .uint(0x00_00_ff),
            .string("bold"): .bool(true),
            .string("italic"): .bool(true),
            .string("undercurl"): .bool(true),
            .string("strikethrough"): .bool(true),
            .string("reverse"): .bool(true),
        ]))
        XCTAssertEqual(
            parse([.array([.string("hl_attr_define"), .uint(7), rgbMap, .map(MsgPackValueMap()), .array([])])]),
            [
                .hlAttrDefine(id: 7, attr: HlAttr(
                    foreground: 0xff_00_00,
                    background: 0x00_10_20,
                    special: 0x00_00_ff,
                    bold: true,
                    italic: true,
                    undercurl: true,
                    strikethrough: true,
                    reverse: true
                )),
            ]
        )
    }

    func testDefaultColorsSetTreatsNegativeAsUnset() {
        XCTAssertEqual(
            parse([.array([
                .string("default_colors_set"),
                .int(-1), .uint(0xab_cd_ef), .uint(0x12_34_56), .uint(1), .uint(2),
            ])]),
            [.defaultColorsSet(foreground: nil, background: 0xab_cd_ef, special: 0x12_34_56)]
        )
    }

    func testModeChange() {
        XCTAssertEqual(
            parse([.array([.string("mode_change"), .string("insert"), .uint(1)])]),
            [.modeChange(name: "insert", index: 1)]
        )
    }

    func testModeInfoSet() {
        let modes: MsgPackValue = .array([
            .map(MsgPackValueMap([
                .string("name"): .string("normal"),
                .string("cursor_shape"): .string("block"),
                .string("cell_percentage"): .uint(100),
                .string("blinkwait"): .uint(700),
                .string("blinkon"): .uint(400),
                .string("blinkoff"): .uint(250),
            ])),
            .map(MsgPackValueMap([
                .string("name"): .string("insert"),
                .string("cursor_shape"): .string("vertical"),
                .string("cell_percentage"): .uint(25),
            ])),
            .map(MsgPackValueMap([.string("cursor_shape"): .string("diagonal")])),
        ])
        XCTAssertEqual(
            parse([.array([.string("mode_info_set"), .bool(true), modes])]),
            [
                .modeInfoSet([
                    ModeInfo(
                        name: "normal",
                        cursorShape: .block,
                        cellPercentage: 100,
                        blinkWait: 700,
                        blinkOn: 400,
                        blinkOff: 250
                    ),
                    ModeInfo(
                        name: "insert",
                        cursorShape: .vertical,
                        cellPercentage: 25,
                        blinkWait: nil,
                        blinkOn: nil,
                        blinkOff: nil
                    ),
                    ModeInfo(
                        name: nil,
                        cursorShape: nil,
                        cellPercentage: nil,
                        blinkWait: nil,
                        blinkOn: nil,
                        blinkOff: nil
                    ),
                ]),
            ]
        )
    }

    func testUnknownEventKeepsName() {
        XCTAssertEqual(
            parse([.array([.string("win_pos"), .uint(1), .uint(0), .uint(0), .uint(80), .uint(24)])]),
            [.unknown(name: "win_pos")]
        )
    }

    private func parse(_ events: [MsgPackValue]) -> [RedrawEvent] {
        RedrawEvent.parseNotification([.array(events)])
    }
}
