import XCTest
@testable import iNeovim

private struct ResizeCall: Equatable {
    var cols: Int
    var rows: Int
}

private actor ResizeCallBox {
    private(set) var calls: [ResizeCall] = []

    func append(_ call: ResizeCall) {
        calls.append(call)
    }
}

@MainActor
final class ResizeControllerTests: XCTestCase {
    func testCellCountFloorsToWholeCells() {
        let count = ResizeController.cellCount(
            for: CGSize(width: 815, height: 615),
            cellSize: CGSize(width: 10, height: 20)
        )
        XCTAssertEqual(count.cols, 81)
        XCTAssertEqual(count.rows, 30)
    }

    func testCellCountClampsToAtLeastOneCell() {
        let count = ResizeController.cellCount(
            for: CGSize(width: 5, height: 0),
            cellSize: CGSize(width: 10, height: 20)
        )
        XCTAssertEqual(count.cols, 1)
        XCTAssertEqual(count.rows, 1)
    }

    func testViewResizeSendsDebouncedCellCount() async throws {
        let box = ResizeCallBox()
        let controller = ResizeController(cellSize: CGSize(width: 10, height: 20), debounceDelay: .milliseconds(20)) { cols, rows in
            await box.append(ResizeCall(cols: cols, rows: rows))
        }

        await controller.viewDidResize(to: CGSize(width: 800, height: 600))
        try await Task.sleep(for: .milliseconds(100))

        let calls = await box.calls
        XCTAssertEqual(calls, [ResizeCall(cols: 80, rows: 30)])
    }

    func testRapidResizesCoalesceToLastSize() async throws {
        let box = ResizeCallBox()
        let controller = ResizeController(cellSize: CGSize(width: 10, height: 20), debounceDelay: .milliseconds(30)) { cols, rows in
            await box.append(ResizeCall(cols: cols, rows: rows))
        }

        await controller.viewDidResize(to: CGSize(width: 800, height: 600))
        await controller.viewDidResize(to: CGSize(width: 500, height: 400))
        await controller.viewDidResize(to: CGSize(width: 1000, height: 700))
        try await Task.sleep(for: .milliseconds(150))

        let calls = await box.calls
        XCTAssertEqual(calls, [ResizeCall(cols: 100, rows: 35)])
    }

    func testCellSizeIsMutable() async throws {
        let box = ResizeCallBox()
        let controller = ResizeController(cellSize: CGSize(width: 10, height: 20), debounceDelay: .milliseconds(20)) { cols, rows in
            await box.append(ResizeCall(cols: cols, rows: rows))
        }
        await controller.setCellSize(CGSize(width: 5, height: 10))

        await controller.viewDidResize(to: CGSize(width: 100, height: 100))
        try await Task.sleep(for: .milliseconds(100))

        let calls = await box.calls
        XCTAssertEqual(calls, [ResizeCall(cols: 20, rows: 10)])
    }
}
