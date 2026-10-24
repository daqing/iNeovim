import AppKit
import XCTest
@testable import iNeovim

@MainActor
final class TerminalViewDragTests: XCTestCase {
    func testDroppedFileURLsReadsFileURLs() {
        let pasteboard = NSPasteboard(name: .init("TerminalViewDragTests"))
        pasteboard.clearContents()
        let url = URL(fileURLWithPath: "/tmp/drag.txt")
        pasteboard.writeObjects([url as NSURL])

        XCTAssertEqual(TerminalView.droppedFileURLs(from: pasteboard), [url])
    }

    func testDroppedFileURLsIgnoresPlainText() {
        let pasteboard = NSPasteboard(name: .init("TerminalViewDragTestsText"))
        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)

        XCTAssertTrue(TerminalView.droppedFileURLs(from: pasteboard).isEmpty)
    }
}
