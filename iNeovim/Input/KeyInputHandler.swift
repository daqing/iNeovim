import AppKit

/// Translates `keyDown` events into Neovim key notation. Returns nil for
/// events that carry printable text with no significant modifiers — those go
/// through the input context (IME) so composing input keeps working.
struct KeyInputHandler {
    /// When false (default), Option chords fall back to the system character
    /// (Option-a → "å") delivered as text. When true, Option becomes `<M-…>`.
    var optionAsMeta = false
    /// When false (default), Command chords are left to the app (menus);
    /// keyDown events that still carry Command are ignored. When true, they
    /// are passed through as `<D-…>`.
    var passCmdKeys = false

    func nvimKey(for event: NSEvent) -> String? {
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function])

        // Named keys are looked up by keyCode first (layout-independent), then
        // by the characters AppKit reports (covers non-ANSI keyboards where a
        // key's code differs but the function character is stable).
        if let named = Self.namedKeys[event.keyCode] {
            return notation(named, modifiers: modifiers)
        }
        if let named = Self.namedCharacters[event.characters ?? ""] {
            return notation(named, modifiers: modifiers)
        }

        let hasCommand = modifiers.contains(.command)
        let hasControl = modifiers.contains(.control)
        let hasOption = modifiers.contains(.option)

        // Command belongs to the app unless explicitly passed through.
        if hasCommand && !passCmdKeys { return nil }
        // Without meta mode, Option produces the system character (å, é, …)
        // which is delivered as text through the IME path.
        if hasOption && !optionAsMeta && !hasControl && !hasCommand { return nil }
        // Anything else without Control/Command/meta-Option is plain text.
        guard hasCommand || hasControl || (hasOption && optionAsMeta) else { return nil }

        let charactersIgnoringModifiers = event.charactersIgnoringModifiers ?? ""
        guard charactersIgnoringModifiers.count == 1,
              let base = charactersIgnoringModifiers.first,
              let scalar = base.unicodeScalars.first,
              scalar.value >= 0x20, scalar.value < 0x7F else {
            return nil
        }
        return notation(String(base).lowercased(), modifiers: modifiers)
    }

    private func notation(_ key: String, modifiers: NSEvent.ModifierFlags) -> String {
        var prefix = ""
        if modifiers.contains(.control) { prefix += "C-" }
        if modifiers.contains(.shift) { prefix += "S-" }
        if modifiers.contains(.option) { prefix += "M-" }
        if modifiers.contains(.command) { prefix += "D-" }
        return prefix.isEmpty ? key : "<\(prefix)\(key)>"
    }

    /// Hardware key codes that map to a named Neovim key. Only keys that do
    /// not produce ordinary printable text are listed; printable keypad
    /// digits and Space go through the text path like regular characters.
    private static let namedKeys: [UInt16: String] = [
        48: "Tab",
        53: "Esc",
        36: "CR",
        76: "CR",       // keypad Enter
        78: "kMinus",   // keypad -
        69: "kPlus",    // keypad +
        67: "kMultiply",
        75: "kDivide",
        65: "kPoint",
        123: "Left",
        124: "Right",
        125: "Down",
        126: "Up",
        114: "Help",
        115: "Home",
        119: "End",
        116: "PageUp",
        121: "PageDown",
        117: "Del",
        122: "F1", 120: "F2", 99: "F3", 118: "F4",
        96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// Special characters (function-key glyphs, control characters) that
    /// name a key regardless of hardware keyCode.
    private static let namedCharacters: [String: String] = [
        "\r": "CR",
        "\u{1b}": "Esc",
        "\u{7f}": "BS",
        "\u{8}": "BS",
        "\t": "Tab",
        "\u{f700}": "Up",
        "\u{f701}": "Down",
        "\u{f702}": "Left",
        "\u{f703}": "Right",
        "\u{f704}": "F1", "\u{f705}": "F2", "\u{f706}": "F3", "\u{f707}": "F4",
        "\u{f708}": "F5", "\u{f709}": "F6", "\u{f70a}": "F7", "\u{f70b}": "F8",
        "\u{f70c}": "F9", "\u{f70d}": "F10", "\u{f70e}": "F11", "\u{f70f}": "F12",
        "\u{f727}": "Insert",
        "\u{f728}": "Del",
        "\u{f729}": "Home",
        "\u{f72b}": "End",
        "\u{f72c}": "PageUp",
        "\u{f72d}": "PageDown",
    ]
}
