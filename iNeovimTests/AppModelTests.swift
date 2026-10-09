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

    func testUnexpectedTerminationSurfacesCrash() {
        let model = AppModel(openHandler: { _ in }, commandHandler: { _ in })
        model.markReadyForTesting()

        model.handleTermination(status: 1)

        XCTAssertEqual(model.crash?.status, 1)
        XCTAssertFalse(model.isReady)
    }

    func testCleanNvimExitClosesWindowWithoutCrashDialog() {
        var cleanExits = 0
        let model = AppModel(
            openHandler: { _ in },
            commandHandler: { _ in },
            cleanExitHandler: { cleanExits += 1 }
        )
        model.markReadyForTesting()

        model.handleTermination(status: 0)

        XCTAssertNil(model.crash)
        XCTAssertFalse(model.isReady)
        XCTAssertEqual(cleanExits, 1)
    }

    func testShutdownSuppressesCrashDialog() {
        let model = AppModel(openHandler: { _ in }, commandHandler: { _ in })
        model.markReadyForTesting()

        model.beginShutdown()
        model.handleTermination(status: 0)

        XCTAssertNil(model.crash)
        XCTAssertTrue(model.isReady)
    }

    func testDismissCrashClearsIt() {
        let model = AppModel(openHandler: { _ in }, commandHandler: { _ in })
        model.handleTermination(status: 137)
        XCTAssertNotNil(model.crash)

        model.dismissCrash()
        XCTAssertNil(model.crash)
    }

    func testRestartIsIgnoredAfterShutdown() {
        let model = AppModel(openHandler: { _ in }, commandHandler: { _ in })
        model.beginShutdown()

        model.restart()

        XCTAssertNil(model.crash)
    }

    func testMissingNvimEntersSetupFlow() {
        let model = AppModel(openHandler: { _ in }, commandHandler: { _ in })

        model.handleBootstrapFailure(NvimDiscoveryError.notFound)

        XCTAssertEqual(model.setup, NvimSetupGuide(homebrewInstalled: NvimDiscovery.locateHomebrew() != nil))
        XCTAssertNil(model.bootstrapError)
    }

    func testOtherBootstrapFailuresSurfaceAsError() {
        let model = AppModel(openHandler: { _ in }, commandHandler: { _ in })

        model.handleBootstrapFailure(NvimDiscoveryError.missingOverride("/nonexistent/nvim"))

        XCTAssertNil(model.setup)
        XCTAssertNotNil(model.bootstrapError)
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
