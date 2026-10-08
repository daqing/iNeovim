import XCTest
@testable import iNeovim

@MainActor
final class AppModelTests: XCTestCase {
    func testFilesOpenedBeforeReadyAreQueued() {
        var opened: [[URL]] = []
        let model = AppModel(openHandler: { opened.append($0) })
        let url = URL(fileURLWithPath: "/tmp/a.txt")

        model.open([url])
        XCTAssertEqual(model.pendingFileCount, 1)
        XCTAssertTrue(opened.isEmpty)

        model.markReadyForTesting()
        XCTAssertEqual(model.pendingFileCount, 0)
        XCTAssertEqual(opened, [[url]])
    }

    func testFilesOpenedAfterReadyGoStraightThrough() {
        var opened: [[URL]] = []
        let model = AppModel(openHandler: { opened.append($0) })
        model.markReadyForTesting()
        let url = URL(fileURLWithPath: "/tmp/b.txt")

        model.open([url])
        XCTAssertEqual(model.pendingFileCount, 0)
        XCTAssertEqual(opened, [[url]])
    }

    func testEmptyFileListIsIgnored() {
        var opened: [[URL]] = []
        let model = AppModel(openHandler: { opened.append($0) })

        model.open([])
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(model.pendingFileCount, 0)
    }

    func testTabCommandsRouteToNeovim() {
        var commands: [String] = []
        let model = AppModel(openHandler: { _ in }, commandHandler: { commands.append($0) })

        model.newTab()
        model.closeTab()
        model.nextTab()
        model.previousTab()
        model.goToTab(3)

        XCTAssertEqual(
            commands,
            ["tabnew", "tabclose", "tabnext", "tabprevious", "tabnext 3"]
        )
    }

    func testEditorCommandsRouteToNeovim() {
        var commands: [String] = []
        let model = AppModel(openHandler: { _ in }, commandHandler: { commands.append($0) })

        model.splitHorizontal()
        model.splitVertical()
        model.closeWindow()
        model.save()
        model.openTerminal()

        XCTAssertEqual(commands, ["split", "vsplit", "close", "write", "terminal"])
    }
}
