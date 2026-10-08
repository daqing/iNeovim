import XCTest
@testable import iNeovim

@MainActor
final class AppSettingsTests: XCTestCase {
    private let suiteName = "AppSettingsTests"

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func testDefaults() {
        let settings = AppSettings(defaults: makeDefaults())
        XCTAssertEqual(settings.fontFamily, "")
        XCTAssertEqual(settings.fontSize, Double(FontMetrics.defaultSize))
        XCTAssertFalse(settings.optionAsMeta)
        XCTAssertFalse(settings.passCmdKeysThrough)
        XCTAssertTrue(settings.scrollAnimationEnabled)
        XCTAssertTrue(settings.cursorAnimationEnabled)
    }

    func testInputSettingsMirror() {
        let settings = AppSettings(defaults: makeDefaults())
        settings.optionAsMeta = true
        settings.passCmdKeysThrough = true
        XCTAssertTrue(settings.inputSettings.optionAsMeta)
        XCTAssertTrue(settings.inputSettings.passCmdKeysThrough)
    }

    func testAnimationSettingsMirror() {
        let settings = AppSettings(defaults: makeDefaults())
        settings.scrollAnimationEnabled = false
        settings.cursorAnimationEnabled = false
        XCTAssertFalse(settings.animationSettings.scrollEnabled)
        XCTAssertFalse(settings.animationSettings.cursorEnabled)
    }

    func testPersistence() {
        let defaults = makeDefaults()
        let first = AppSettings(defaults: defaults)
        first.fontSize = 18
        first.optionAsMeta = true

        let second = AppSettings(defaults: defaults)
        XCTAssertEqual(second.fontSize, 18)
        XCTAssertTrue(second.optionAsMeta)
    }

    func testResolvedFontUsesRequestedSize() {
        let settings = AppSettings(defaults: makeDefaults())
        settings.fontSize = 17
        XCTAssertEqual(settings.resolvedFont().pointSize, 17, accuracy: 0.01)
    }

    func testResetRestoresDefaults() {
        let settings = AppSettings(defaults: makeDefaults())
        settings.fontFamily = "Menlo"
        settings.fontSize = 22
        settings.optionAsMeta = true
        settings.scrollAnimationEnabled = false

        settings.resetToDefaults()

        XCTAssertEqual(settings.fontFamily, "")
        XCTAssertEqual(settings.fontSize, Double(FontMetrics.defaultSize))
        XCTAssertFalse(settings.optionAsMeta)
        XCTAssertTrue(settings.scrollAnimationEnabled)
    }
}
