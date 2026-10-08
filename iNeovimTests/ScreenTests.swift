import XCTest
@testable import iNeovim

@MainActor
final class ScreenTests: XCTestCase {
    func testGridEventsBuildPrimaryGrid() async {
        let screen = Screen()
        await screen.apply(.gridResize(grid: 1, width: 4, height: 2))
        await screen.apply(.gridLine(grid: 1, row: 0, colStart: 0, runs: [
            GridCellRun(text: "h", attrId: 1, count: 1),
            GridCellRun(text: "i", attrId: 1, count: 1),
        ]))
        await screen.apply(.gridScroll(grid: 1, top: 0, bot: 2, left: 0, right: 4, rows: 1, cols: 0))

        let grid = await screen.primaryGrid
        XCTAssertEqual(grid?.width, 4)
        XCTAssertEqual(grid?.height, 2)
        XCTAssertEqual(grid?[0, 0], GridCell(text: "h", attrId: 1))
        XCTAssertEqual(grid?[1, 0], GridCell())
    }

    func testGridDestroyKeepsPrimaryGrid() async {
        let screen = Screen()
        await screen.apply(.gridResize(grid: 1, width: 1, height: 1))
        await screen.apply(.gridResize(grid: 7, width: 1, height: 1))
        await screen.apply(.gridDestroy(grid: 7))
        await screen.apply(.gridDestroy(grid: 1))

        let grids = await screen.grids
        XCTAssertEqual(Set(grids.keys), [1])
    }

    func testCursorGotoUpdatesCursor() async {
        let screen = Screen()
        await screen.apply(.cursorGoto(grid: 1, row: 3, col: 7))
        let cursor = await screen.cursor
        XCTAssertEqual(cursor, CursorState(grid: 1, row: 3, col: 7))
    }

    func testModeInfoAndChangeTrackCursorShape() async {
        let screen = Screen()
        await screen.apply(.modeInfoSet([
            ModeInfo(
                name: "normal",
                cursorShape: .block,
                cellPercentage: 100,
                blinkWait: nil,
                blinkOn: nil,
                blinkOff: nil
            ),
            ModeInfo(
                name: "insert",
                cursorShape: .vertical,
                cellPercentage: 25,
                blinkWait: nil,
                blinkOn: nil,
                blinkOff: nil
            ),
        ]))
        await screen.apply(.modeChange(name: "insert", index: 1))

        let modeName = await screen.modeName
        XCTAssertEqual(modeName, "insert")
        let cursorModeInfo = await screen.cursorModeInfo
        XCTAssertEqual(cursorModeInfo?.cursorShape, .vertical)
        XCTAssertEqual(cursorModeInfo?.cellPercentage, 25)
    }

    func testCursorModeInfoIsNilForOutOfRangeIndex() async {
        let screen = Screen()
        await screen.apply(.modeChange(name: "weird", index: 9))
        let cursorModeInfo = await screen.cursorModeInfo
        XCTAssertNil(cursorModeInfo)
    }

    func testDefaultColorsAndHighlightResolution() async {
        let screen = Screen()
        await screen.apply(.defaultColorsSet(foreground: 0xaa, background: 0xbb, special: 0xcc))
        await screen.apply(.hlAttrDefine(id: 5, attr: HlAttr(foreground: 0x11, reverse: true)))

        let highlights = await screen.highlights
        let colors = highlights.resolvedColors(for: 5, defaultForeground: 0xaa, defaultBackground: 0xbb, defaultSpecial: 0xcc)
        XCTAssertEqual(colors?.foreground, 0xbb)
        XCTAssertEqual(colors?.background, 0x11)
        XCTAssertEqual(colors?.special, 0xcc)
    }

    func testFlushAndUnknownEventsAreIgnored() async {
        let screen = Screen()
        await screen.apply(.flush)
        await screen.apply(.unknown(name: "win_pos"))
        let grid = await screen.primaryGrid
        XCTAssertNil(grid)
    }
}
