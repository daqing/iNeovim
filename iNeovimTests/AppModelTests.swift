import Combine
import XCTest
@testable import iNeovim

@MainActor
final class AppModelTests: XCTestCase {
    func testFilesOpenedBeforeReadyAreQueued() {
        var opened: [[URL]] = []
        let model = AppModel(openHandler: { urls, _ in opened.append(urls) })
        let url = URL(fileURLWithPath: "/tmp/a.txt")

        model.open([url])
        XCTAssertEqual(model.pendingFileCount, 1)
        XCTAssertTrue(opened.isEmpty)

        model.markReadyForTesting()
        XCTAssertEqual(model.pendingFileCount, 0)
        XCTAssertEqual(opened, [[url]])
    }

    func testCommandLineOpenQueuesFilesUntilReady() {
        var opened: [[URL]] = []
        let model = AppModel(openHandler: { urls, _ in opened.append(urls) })
        let file = URL(fileURLWithPath: "/work/repo/main.go")

        model.openFromCommandLine(directory: URL(fileURLWithPath: "/work/repo"), files: [file])
        XCTAssertEqual(model.pendingFileCount, 1)
        XCTAssertTrue(opened.isEmpty)

        model.markReadyForTesting()
        XCTAssertEqual(opened, [[file]])
    }

    func testFilesOpenedAfterReadyGoStraightThrough() {
        var opened: [[URL]] = []
        let model = AppModel(openHandler: { urls, _ in opened.append(urls) })
        model.markReadyForTesting()
        let url = URL(fileURLWithPath: "/tmp/b.txt")

        model.open([url])
        XCTAssertEqual(model.pendingFileCount, 0)
        XCTAssertEqual(opened, [[url]])
    }

    func testEmptyFileListIsIgnored() {
        var opened: [[URL]] = []
        let model = AppModel(openHandler: { urls, _ in opened.append(urls) })

        model.open([])
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(model.pendingFileCount, 0)
    }

    func testSystemOpensRouteToTheActiveReadySession() {
        var opened: [[URL]] = []
        let model = AppModel(openHandler: { urls, _ in opened.append(urls) }, commandHandler: { _, _ in })
        model.markReadyForTesting()
        AppModel.active = model
        defer { AppModel.active = nil }
        let url = URL(fileURLWithPath: "/tmp/c.txt")

        AppModel.openFromSystem([url])

        XCTAssertEqual(model.pendingFileCount, 0)
        XCTAssertEqual(opened, [[url]])
    }

    func testResolveTabFileAgainstNvimWorkingDirectory() {
        XCTAssertEqual(
            AppModel.resolveTabFile("src/main.go", workingDirectory: "/work/repo"),
            URL(fileURLWithPath: "/work/repo/src/main.go")
        )
        // Absolute paths and ~ pass through unchanged.
        XCTAssertEqual(
            AppModel.resolveTabFile("/etc/hosts", workingDirectory: "/work/repo"),
            URL(fileURLWithPath: "/etc/hosts")
        )
        XCTAssertEqual(
            AppModel.resolveTabFile("~/notes.md", workingDirectory: "/work/repo"),
            URL(fileURLWithPath: NSString(string: "~/notes.md").expandingTildeInPath)
        )
        // A bare :tabnew opens no file; an empty working directory falls back
        // to the process cwd.
        XCTAssertNil(AppModel.resolveTabFile("", workingDirectory: "/work/repo"))
        XCTAssertNil(AppModel.resolveTabFile("   ", workingDirectory: ""))
        XCTAssertEqual(
            AppModel.resolveTabFile("a.txt", workingDirectory: ""),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("a.txt").standardized
        )
    }

    func testUnexpectedTerminationSurfacesCrash() {
        let model = AppModel(openHandler: { _, _ in }, commandHandler: { _, _ in })
        model.markReadyForTesting()

        model.handleTermination(status: 1)

        XCTAssertEqual(model.crash?.status, 1)
        XCTAssertFalse(model.isReady)
    }

    func testCleanNvimExitClosesWindowWithoutCrashDialog() {
        var cleanExits = 0
        let model = AppModel(
            openHandler: { _, _ in },
            commandHandler: { _, _ in },
            cleanExitHandler: { cleanExits += 1 }
        )
        model.markReadyForTesting()

        model.handleTermination(status: 0)

        XCTAssertNil(model.crash)
        XCTAssertFalse(model.isReady)
        XCTAssertEqual(cleanExits, 1)
    }

    func testShutdownSuppressesCrashDialog() {
        let model = AppModel(openHandler: { _, _ in }, commandHandler: { _, _ in })
        model.markReadyForTesting()

        model.beginShutdown()
        model.handleTermination(status: 0)

        XCTAssertNil(model.crash)
        XCTAssertTrue(model.isReady)
    }

    func testDismissCrashClearsIt() {
        let model = AppModel(openHandler: { _, _ in }, commandHandler: { _, _ in })
        model.handleTermination(status: 137)
        XCTAssertNotNil(model.crash)

        model.dismissCrash()
        XCTAssertNil(model.crash)
    }

    func testRestartIsIgnoredAfterShutdown() {
        let model = AppModel(openHandler: { _, _ in }, commandHandler: { _, _ in })
        model.beginShutdown()

        model.restart()

        XCTAssertNil(model.crash)
    }

    func testMissingNvimEntersSetupFlow() {
        let model = AppModel(openHandler: { _, _ in }, commandHandler: { _, _ in })

        model.handleBootstrapFailure(NvimDiscoveryError.notFound)

        XCTAssertEqual(model.setup, NvimSetupGuide(homebrewInstalled: NvimDiscovery.locateHomebrew() != nil))
        XCTAssertNil(model.bootstrapError)
    }

    func testOtherBootstrapFailuresSurfaceAsError() {
        let model = AppModel(openHandler: { _, _ in }, commandHandler: { _, _ in })

        model.handleBootstrapFailure(NvimDiscoveryError.missingOverride("/nonexistent/nvim"))

        XCTAssertNil(model.setup)
        XCTAssertNotNil(model.bootstrapError)
    }

    func testActiveSessionTracksWindowFocus() {
        let first = AppModel(openHandler: { _, _ in }, commandHandler: { _, _ in })
        let second = AppModel(openHandler: { _, _ in }, commandHandler: { _, _ in })
        AppModel.active = nil
        defer { AppModel.active = nil }

        first.becameActive()
        XCTAssertTrue(AppModel.active === first)

        second.becameActive()
        XCTAssertTrue(AppModel.active === second)
    }

    func testEditorCommandsRouteToNeovim() {
        var commands: [String] = []
        let model = AppModel(openHandler: { _, _ in }, commandHandler: { command, _ in commands.append(command) })

        model.splitHorizontal()
        model.splitVertical()
        model.closeWindow()
        model.save()

        XCTAssertEqual(commands, ["split", "vsplit", "close", "write"])
    }

    func testTerminalPaneFocusAndCloseIntents() {
        let model = AppModel(openHandler: { _, _ in }, commandHandler: { _, _ in })
        model.setTerminalPaneVisible(true)

        model.requestTerminalPane(command: "ls")
        XCTAssertEqual(model.terminalPaneIntent, .focus)

        model.toggleTerminalPaneFocus()
        XCTAssertEqual(model.terminalPaneIntent, .toggleFocus)

        model.toggleTerminalPane()
        XCTAssertEqual(model.terminalPaneIntent, .close)
    }

    func testTerminalPaneOpenPublishesIntent() async {
        let model = AppModel(openHandler: { _, _ in }, commandHandler: { _, _ in })
        let opened = expectation(description: "open intent published")
        var sink: Set<AnyCancellable> = []
        model.$terminalPaneIntent.sink { intent in
            if case .open(let request) = intent {
                XCTAssertEqual(request.shellCommand, "git status")
                opened.fulfill()
            }
        }.store(in: &sink)

        model.requestTerminalPane(command: "git status")
        await fulfillment(of: [opened], timeout: 2)
    }
}
