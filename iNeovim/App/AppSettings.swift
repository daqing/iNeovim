import AppKit
import Combine
import CoreGraphics

/// User-facing settings, persisted in `UserDefaults` and published so both
/// the settings window and the render view stay in sync.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// Font family name; empty means the system monospaced font.
    @Published var fontFamily: String {
        didSet { defaults.set(fontFamily, forKey: Keys.fontFamily) }
    }
    @Published var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: Keys.fontSize) }
    }
    @Published var optionAsMeta: Bool {
        didSet { defaults.set(optionAsMeta, forKey: Keys.optionAsMeta) }
    }
    @Published var passCmdKeysThrough: Bool {
        didSet { defaults.set(passCmdKeysThrough, forKey: Keys.passCmdKeysThrough) }
    }
    @Published var scrollAnimationEnabled: Bool {
        didSet { defaults.set(scrollAnimationEnabled, forKey: Keys.scrollAnimationEnabled) }
    }
    @Published var cursorAnimationEnabled: Bool {
        didSet { defaults.set(cursorAnimationEnabled, forKey: Keys.cursorAnimationEnabled) }
    }
    /// Redirect a typed `:terminal` to the native Ghostty side pane instead
    /// of an in-buffer terminal.
    @Published var nativeTerminalPane: Bool {
        didSet { defaults.set(nativeTerminalPane, forKey: Keys.nativeTerminalPane) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let fontFamily = "settings.fontFamily"
        static let fontSize = "settings.fontSize"
        static let optionAsMeta = "settings.optionAsMeta"
        static let passCmdKeysThrough = "settings.passCmdKeysThrough"
        static let scrollAnimationEnabled = "settings.scrollAnimationEnabled"
        static let cursorAnimationEnabled = "settings.cursorAnimationEnabled"
        static let nativeTerminalPane = "settings.nativeTerminalPane"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.fontFamily: "",
            Keys.fontSize: Double(FontMetrics.defaultSize),
            Keys.optionAsMeta: false,
            Keys.passCmdKeysThrough: false,
            Keys.scrollAnimationEnabled: true,
            Keys.cursorAnimationEnabled: true,
            Keys.nativeTerminalPane: true,
        ])
        fontFamily = defaults.string(forKey: Keys.fontFamily) ?? ""
        fontSize = defaults.double(forKey: Keys.fontSize)
        optionAsMeta = defaults.bool(forKey: Keys.optionAsMeta)
        passCmdKeysThrough = defaults.bool(forKey: Keys.passCmdKeysThrough)
        scrollAnimationEnabled = defaults.bool(forKey: Keys.scrollAnimationEnabled)
        cursorAnimationEnabled = defaults.bool(forKey: Keys.cursorAnimationEnabled)
        nativeTerminalPane = defaults.bool(forKey: Keys.nativeTerminalPane)
    }

    var inputSettings: InputSettings {
        InputSettings(
            passCmdKeysThrough: passCmdKeysThrough,
            optionAsMeta: optionAsMeta
        )
    }

    var animationSettings: ScrollAnimationSettings {
        var settings = ScrollAnimationSettings.default
        settings.scrollEnabled = scrollAnimationEnabled
        settings.cursorEnabled = cursorAnimationEnabled
        return settings
    }

    /// The selected font at the selected size, falling back to the system
    /// monospaced font when the family cannot be resolved.
    func resolvedFont() -> NSFont {
        let size = CGFloat(fontSize)
        if !fontFamily.isEmpty,
           let font = NSFontManager.shared.font(withFamily: fontFamily, traits: [], weight: 5, size: size) {
            return font
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Families with a fixed-pitch regular face, for the font picker.
    static func monospacedFamilies() -> [String] {
        NSFontManager.shared.availableFontFamilies.filter { family in
            let members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
            return members.contains { member in
                guard member.count > 1, let name = member[1] as? String,
                      let font = NSFont(name: name, size: 12) else { return false }
                return font.isFixedPitch
            }
        }.sorted()
    }

    func resetToDefaults() {
        fontFamily = ""
        fontSize = Double(FontMetrics.defaultSize)
        optionAsMeta = false
        passCmdKeysThrough = false
        scrollAnimationEnabled = true
        cursorAnimationEnabled = true
        nativeTerminalPane = true
    }
}
