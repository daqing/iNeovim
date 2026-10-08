/// User-facing input behavior switches. Wired into a settings UI in Phase 8;
/// until then views hold a mutable instance and defaults apply.
struct InputSettings {
    /// When true, Command chords without a menu owner are passed to Neovim
    /// as `<D-…>` instead of being dropped.
    var passCmdKeysThrough = false
    /// When false (default), Option chords produce the system character
    /// (Option-a → "å"). When true, Option becomes the `<M-…>` modifier.
    var optionAsMeta = false
}
