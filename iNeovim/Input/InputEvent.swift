/// A single input event funnel: everything the user does with keyboard and
/// mouse becomes one of these, so delivery to nvim has exactly one path.
enum InputEvent: Equatable, Sendable {
    /// Neovim key notation, already escaped for `nvim_input`.
    case keys(String)
    /// A mouse action, ready for `nvim_input_mouse`.
    case mouse(button: String, action: String, modifier: String, grid: Int, row: Int, col: Int)
}
