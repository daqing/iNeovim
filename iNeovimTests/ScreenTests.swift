import XCTest
@testable import iNeovim

private final class TitleBox: @unchecked Sendable {
    var value: String?
}

/// Handlers run as @Sendable closures, so plain captured vars would trip the
/// data-race warnings; a shared box is the lightweight escape hatch.
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

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
        // Positive rows scroll content up: row 0 takes row 1's (blank) content.
        XCTAssertEqual(grid?[0, 0], GridCell())
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

    func testSetTitleUpdatesTitleAndNotifiesHandler() async {
        let screen = Screen()
        let box = TitleBox()
        await screen.setTitleHandler { box.value = $0 }

        await screen.apply(.setTitle("file.txt - NVIM"))

        let title = await screen.title
        XCTAssertEqual(title, "file.txt - NVIM")
        XCTAssertEqual(box.value, "file.txt - NVIM")
    }

    func testCursorGotoUpdatesCursor() async {
        let screen = Screen()
        await screen.apply(.cursorGoto(grid: 1, row: 3, col: 7))
        let cursor = await screen.cursor
        XCTAssertEqual(cursor, CursorState(grid: 1, row: 3, col: 7))
    }

    func testCursorGotoDirtiesContinuationCellOfWideChar() async {
        // A cursor on a double-width char spans two cells; moving or reshaping
        // it must repaint both, or the leftover half smears.
        let screen = Screen()
        await screen.apply(.gridResize(grid: 1, width: 4, height: 1))
        await screen.apply(.gridLine(grid: 1, row: 0, colStart: 0, runs: [
            GridCellRun(text: "你", attrId: 0, count: 1),
            GridCellRun(text: "", attrId: 0, count: 1),
        ]))
        await screen.apply(.flush)

        let flushed = Box<(grid: Int, rects: [CellRect])?>(nil)
        await screen.setFlushHandler({ grid, rects in flushed.value = (grid, rects) })
        await screen.apply(.cursorGoto(grid: 1, row: 0, col: 0))
        await screen.apply(.flush)

        XCTAssertEqual(flushed.value?.rects, [CellRect(minRow: 0, minCol: 0, maxRow: 1, maxCol: 2)])
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

    func testFlushReportsCoalescedDirtyRegion() async {
        let screen = Screen()
        let flushed = Box<(grid: Int, rects: [CellRect])?>(nil)
        await screen.setFlushHandler({ grid, rects in flushed.value = (grid, rects) })

        await screen.apply(.gridResize(grid: 1, width: 4, height: 3))
        await screen.apply(.gridLine(grid: 1, row: 1, colStart: 1, runs: [
            GridCellRun(text: "x", attrId: 0, count: 2),
        ]))
        await screen.apply(.flush)

        // The resize dirtied the whole grid, so the line's dirt is subsumed.
        XCTAssertEqual(flushed.value?.grid, 1)
        XCTAssertEqual(flushed.value?.rects, [CellRect(minRow: 0, minCol: 0, maxRow: 3, maxCol: 4)])
    }

    func testFlushWithoutNewEventsDoesNotNotify() async {
        let screen = Screen()
        let flushCount = Box(0)
        await screen.setFlushHandler({ _, _ in flushCount.value += 1 })

        await screen.apply(.gridResize(grid: 1, width: 2, height: 2))
        await screen.apply(.flush)
        await screen.apply(.flush)

        XCTAssertEqual(flushCount.value, 1)
    }

    func testDirtyRectsStaySeparateAcrossDistantEvents() async {
        let screen = Screen()
        let flushed = Box<(grid: Int, rects: [CellRect])?>(nil)
        await screen.setFlushHandler({ grid, rects in flushed.value = (grid, rects) })

        await screen.apply(.gridResize(grid: 1, width: 4, height: 4))
        await screen.apply(.flush)
        await screen.apply(.gridLine(grid: 1, row: 0, colStart: 0, runs: [
            GridCellRun(text: "a", attrId: 0, count: 1),
        ]))
        await screen.apply(.gridLine(grid: 1, row: 2, colStart: 1, runs: [
            GridCellRun(text: "b", attrId: 0, count: 2),
        ]))
        await screen.apply(.flush)

        // Two non-touching edits must not be merged into one bounding box that
        // would span the whole screen.
        XCTAssertEqual(flushed.value?.rects, [
            CellRect(minRow: 0, minCol: 0, maxRow: 1, maxCol: 1),
            CellRect(minRow: 2, minCol: 1, maxRow: 3, maxCol: 3),
        ])
    }

    func testCursorGotoDirtiesOldAndNewCells() async {
        let screen = Screen()
        let flushed = Box<(grid: Int, rects: [CellRect])?>(nil)
        await screen.setFlushHandler({ grid, rects in flushed.value = (grid, rects) })

        await screen.apply(.gridResize(grid: 1, width: 8, height: 8))
        await screen.apply(.flush)
        await screen.apply(.cursorGoto(grid: 1, row: 2, col: 3))
        await screen.apply(.flush)

        XCTAssertEqual(flushed.value?.rects, [
            CellRect(minRow: 0, minCol: 0, maxRow: 1, maxCol: 1),
            CellRect(minRow: 2, minCol: 3, maxRow: 3, maxCol: 4),
        ])
    }

    func testFlushReportsNetScrollDelta() async {
        let screen = Screen()
        let reported = Box<(grid: Int, rows: Int, cols: Int)?>(nil)
        await screen.setScrollHandler({ grid, rows, cols in reported.value = (grid, rows, cols) })

        await screen.apply(.gridResize(grid: 1, width: 4, height: 4))
        await screen.apply(.gridScroll(grid: 1, top: 0, bot: 4, left: 0, right: 4, rows: 2, cols: 0))
        await screen.apply(.gridScroll(grid: 1, top: 0, bot: 4, left: 0, right: 4, rows: 1, cols: 0))
        await screen.apply(.flush)

        XCTAssertEqual(reported.value?.grid, 1)
        XCTAssertEqual(reported.value?.rows, 3)
        XCTAssertEqual(reported.value?.cols, 0)
    }

    func testFlushWithoutScrollReportsNothing() async {
        let screen = Screen()
        let scrollCount = Box(0)
        await screen.setScrollHandler({ _, _, _ in scrollCount.value += 1 })

        await screen.apply(.gridResize(grid: 1, width: 2, height: 2))
        await screen.apply(.gridLine(grid: 1, row: 0, colStart: 0, runs: [
            GridCellRun(text: "x", attrId: 0, count: 1),
        ]))
        await screen.apply(.flush)

        XCTAssertEqual(scrollCount.value, 0)
    }

    func testScrollDeltaResetsAfterFlush() async {
        let screen = Screen()
        let reports = Box<[(rows: Int, cols: Int)]>([])
        await screen.setScrollHandler({ _, rows, cols in reports.value.append((rows, cols)) })

        await screen.apply(.gridResize(grid: 1, width: 2, height: 2))
        await screen.apply(.gridScroll(grid: 1, top: 0, bot: 2, left: 0, right: 2, rows: 1, cols: 0))
        await screen.apply(.flush)
        await screen.apply(.flush)
        await screen.apply(.gridScroll(grid: 1, top: 0, bot: 2, left: 0, right: 2, rows: -1, cols: 0))
        await screen.apply(.flush)

        XCTAssertEqual(reports.value.map(\.rows), [1, -1])
        XCTAssertEqual(reports.value.map(\.cols), [0, 0])
    }

    func testPopupmenuStateTransitionsThroughSnapshot() async {
        let screen = Screen()
        let items = [
            PopupItem(word: "alpha"),
            PopupItem(word: "beta", kind: "Function", menu: "[LSP]"),
        ]
        await screen.apply(.popupmenuShow(items: items, selected: 0, row: 3, col: 6, grid: 1))
        await screen.apply(.popupmenuSelect(1))

        var snapshot = await screen.snapshot()
        XCTAssertEqual(
            snapshot.popup,
            PopupState(items: items, selected: 1, row: 3, col: 6)
        )

        await screen.apply(.popupmenuHide)
        snapshot = await screen.snapshot()
        XCTAssertNil(snapshot.popup)
    }

    func testPopupmenuAcceptsAnyGrid() async {
        let screen = Screen()
        await screen.apply(.popupmenuShow(items: [PopupItem(word: "x")], selected: 0, row: 0, col: 0, grid: 2))
        let snapshot = await screen.snapshot()
        // The completion panel anchors inside the popup's own grid, so a
        // float window's grid is a valid anchor target.
        XCTAssertEqual(snapshot.popup?.grid, 2)
    }

    func testPopupmenuSelectWithoutShowIsIgnored() async {
        let screen = Screen()
        await screen.apply(.popupmenuSelect(2))
        let snapshot = await screen.snapshot()
        XCTAssertNil(snapshot.popup)
    }

    // MARK: - ext_multigrid layout

    func testWinPosLaysOutWindowGrid() async {
        let screen = Screen()
        await screen.apply(.winPos(grid: 2, row: 0, col: 46, width: 44, height: 26))
        await screen.apply(.winHide(grid: 2))

        let snapshot = await screen.snapshot()
        XCTAssertEqual(snapshot.frames[2]?.hidden, true)
        XCTAssertEqual(snapshot.grids[2]?.width, 44)
    }

    func testWinFloatPosComputesNorthWestPlacement() async {
        let screen = Screen()
        await screen.apply(.winFloatPos(
            grid: 5, anchorGrid: 1, anchorRow: 5.0, anchorCol: 10.0,
            corner: "NW", mouseEnabled: true, zindex: 50, compindex: 1,
            screenRow: 5, screenCol: 10
        ))

        let snapshot = await screen.snapshot()
        let frame = snapshot.frames[5]
        XCTAssertEqual(frame?.row, 5)
        XCTAssertEqual(frame?.col, 10)
        XCTAssertEqual(frame?.isFloat, true)
        XCTAssertEqual(frame?.zindex, 50)
    }

    func testWinFloatPosFallsBackToAnchorMathWithoutScreenCoords() async {
        let screen = Screen()
        await screen.apply(.winFloatPos(
            grid: 5, anchorGrid: 1, anchorRow: 3.0, anchorCol: 4.0,
            corner: "SE", mouseEnabled: false, zindex: 50, compindex: 1,
            screenRow: nil, screenCol: nil
        ))

        let snapshot = await screen.snapshot()
        let frame = snapshot.frames[5]
        // A SE-anchored float's top-left corner sits anchorRow/anchorCol
        // cells up and left of the anchor point.
        XCTAssertEqual(frame?.row, -3)
        XCTAssertEqual(frame?.col, -4)
        XCTAssertEqual(frame?.mouseEnabled, false)
    }

    func testWindowLayoutChangeClearsStaleVerticalSeparators() async {
        let screen = Screen()
        await screen.apply(.gridResize(grid: 1, width: 80, height: 24))
        await screen.apply(.winPos(grid: 2, row: 0, col: 0, width: 80, height: 22))
        await screen.apply(.winPos(grid: 2, row: 0, col: 32, width: 48, height: 22))
        await screen.apply(.winPos(grid: 4, row: 0, col: 0, width: 31, height: 22))
        for row in [0, 21] {
            await screen.apply(.gridLine(grid: 1, row: row, colStart: 31, runs: [
                GridCellRun(text: "│", attrId: 927, count: 1),
            ]))
        }
        await screen.apply(.flush)

        let flushed = Box<[Int: [CellRect]]>([:])
        await screen.setFlushHandler { grid, rects in flushed.value[grid] = rects }
        await screen.apply(.winClose(grid: 4))
        await screen.apply(.gridDestroy(grid: 4))
        await screen.apply(.winPos(grid: 2, row: 0, col: 0, width: 80, height: 22))
        await screen.apply(.flush)

        let snapshot = await screen.snapshot()
        XCTAssertEqual(snapshot.grid?[0, 31], GridCell())
        XCTAssertEqual(snapshot.grid?[21, 31], GridCell())
        XCTAssertEqual(flushed.value[1], [
            CellRect(minRow: 0, minCol: 31, maxRow: 22, maxCol: 32),
        ])
    }

    func testFastSeparatorDragClearsEveryIntermediateColumn() async {
        // Dragging the NERDTree/editor divider resizes the window one column
        // per mouse event. Nvim paints a separator at every intermediate
        // boundary and never erases the ones it leaves behind. A fast drag
        // coalesces many of those layout changes into one flush, so the app
        // sees only the final edge position; it must still clear every stale
        // separator, including columns the edge crossed when it reversed
        // direction, or the sidebar ends up striped with vertical bars.
        let screen = Screen()
        await screen.apply(.gridResize(grid: 1, width: 80, height: 24))
        await screen.apply(.gridResize(grid: 4, width: 31, height: 22))
        await screen.apply(.gridResize(grid: 2, width: 48, height: 22))
        await screen.apply(.winPos(grid: 4, row: 0, col: 0, width: 31, height: 22))
        await screen.apply(.winPos(grid: 2, row: 0, col: 32, width: 48, height: 22))
        for row in [0, 21] {
            await screen.apply(.gridLine(grid: 1, row: row, colStart: 31, runs: [
                GridCellRun(text: "│", attrId: 927, count: 1),
            ]))
        }
        await screen.apply(.flush)

        // The edge sweeps left to column 2 and then right to 55 between two
        // flushes; nvim left a separator at every column it crossed.
        for col in 2...55 {
            for row in [0, 21] {
                await screen.apply(.gridLine(grid: 1, row: row, colStart: col, runs: [
                    GridCellRun(text: "│", attrId: 927, count: 1),
                ]))
            }
        }
        await screen.apply(.winPos(grid: 4, row: 0, col: 0, width: 55, height: 22))
        await screen.apply(.winPos(grid: 2, row: 0, col: 56, width: 24, height: 22))
        await screen.apply(.flush)

        let snapshot = await screen.snapshot()
        for col in 2...54 {
            XCTAssertEqual(
                snapshot.grid?[0, col], GridCell(),
                "column \(col) kept a stale separator"
            )
            XCTAssertEqual(
                snapshot.grid?[21, col], GridCell(),
                "column \(col) kept a stale separator"
            )
        }
        // The separator at the final boundary is still required and stays.
        XCTAssertEqual(snapshot.grid?[0, 55], GridCell(text: "│", attrId: 927))
        XCTAssertEqual(snapshot.grid?[21, 55], GridCell(text: "│", attrId: 927))
    }

    func testWindowLayoutChangePreservesSeparatorsStillInUse() async {
        let screen = Screen()
        await screen.apply(.gridResize(grid: 1, width: 80, height: 24))
        await screen.apply(.winPos(grid: 4, row: 0, col: 0, width: 31, height: 22))
        await screen.apply(.winPos(grid: 2, row: 0, col: 32, width: 32, height: 22))
        await screen.apply(.winPos(grid: 5, row: 0, col: 64, width: 16, height: 22))
        for col in [31, 63] {
            await screen.apply(.gridLine(grid: 1, row: 0, colStart: col, runs: [
                GridCellRun(text: "│", attrId: 927, count: 1),
            ]))
        }
        await screen.apply(.flush)

        await screen.apply(.winClose(grid: 4))
        await screen.apply(.gridDestroy(grid: 4))
        await screen.apply(.winPos(grid: 2, row: 0, col: 0, width: 64, height: 22))
        await screen.apply(.flush)

        let snapshot = await screen.snapshot()
        XCTAssertEqual(snapshot.grid?[0, 31], GridCell())
        XCTAssertEqual(snapshot.grid?[0, 63], GridCell(text: "│", attrId: 927))
    }

    func testMsgSetPosTracksTheMessageGridAndHidesItOnZero() async {
        let screen = Screen()
        await screen.apply(.msgSetPos(grid: 3, row: 27, scrolled: false, zindex: 200, compindex: 0))

        var snapshot = await screen.snapshot()
        XCTAssertEqual(snapshot.frames[3]?.isMessage, true)
        XCTAssertEqual(snapshot.frames[3]?.row, 27)

        await screen.apply(.msgSetPos(grid: 0, row: 0, scrolled: false, zindex: 200, compindex: 0))
        snapshot = await screen.snapshot()
        XCTAssertEqual(snapshot.frames[3]?.hidden, true)
    }

    func testWinViewportRecordsBufferMetrics() async {
        let screen = Screen()
        await screen.apply(.winPos(grid: 2, row: 0, col: 0, width: 40, height: 26))
        await screen.apply(.winViewport(
            grid: 2, topline: 9, botline: 34, curline: 11, curcol: 3,
            lineCount: 42, scrollDelta: 0
        ))

        let snapshot = await screen.snapshot()
        let viewport = snapshot.frames[2]?.viewport
        XCTAssertEqual(viewport?.topline, 9)
        XCTAssertEqual(viewport?.botline, 34)
        XCTAssertEqual(viewport?.lineCount, 42)
    }

    func testGridDestroyDropsTheFrame() async {
        let screen = Screen()
        await screen.apply(.winPos(grid: 6, row: 0, col: 0, width: 10, height: 10))
        await screen.apply(.gridDestroy(grid: 6))

        let snapshot = await screen.snapshot()
        XCTAssertNil(snapshot.frames[6])
        XCTAssertNil(snapshot.grids[6])
    }
}
