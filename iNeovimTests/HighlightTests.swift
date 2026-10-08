import XCTest
@testable import iNeovim

@MainActor
final class HighlightTests: XCTestCase {
    func testResolvedColorsFallBackToDefaults() {
        let attr = HlAttr(foreground: 0x11_22_33)
        let colors = attr.resolvedColors(defaultForeground: 0xaa, defaultBackground: 0xbb, defaultSpecial: 0xcc)
        XCTAssertEqual(colors.foreground, 0x11_22_33)
        XCTAssertEqual(colors.background, 0xbb)
        XCTAssertEqual(colors.special, 0xcc)
    }

    func testResolvedColorsApplyReverse() {
        let attr = HlAttr(foreground: 0x11, background: 0x22, reverse: true)
        let colors = attr.resolvedColors(defaultForeground: 0xaa, defaultBackground: 0xbb, defaultSpecial: nil)
        XCTAssertEqual(colors.foreground, 0x22)
        XCTAssertEqual(colors.background, 0x11)
    }

    func testReverseWithoutExplicitColorsSwapsDefaults() {
        let attr = HlAttr(reverse: true)
        let colors = attr.resolvedColors(defaultForeground: 0xaa, defaultBackground: 0xbb, defaultSpecial: nil)
        XCTAssertEqual(colors.foreground, 0xbb)
        XCTAssertEqual(colors.background, 0xaa)
    }

    func testStoreDefinesAndResolves() {
        var store = HighlightStore()
        XCTAssertNil(store[3])
        XCTAssertNil(store.resolvedColors(for: 3, defaultForeground: nil, defaultBackground: nil, defaultSpecial: nil))

        store.define(HlAttr(foreground: 0xff, bold: true), for: 3)
        XCTAssertEqual(store[3], HlAttr(foreground: 0xff, bold: true))

        let colors = store.resolvedColors(for: 3, defaultForeground: 0xaa, defaultBackground: 0xbb, defaultSpecial: nil)
        XCTAssertEqual(colors?.foreground, 0xff)
        XCTAssertEqual(colors?.background, 0xbb)
    }
}
