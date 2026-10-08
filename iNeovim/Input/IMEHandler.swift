import AppKit
import os

/// Holds IME (marked text) state and implements `NSTextInputClient` on
/// behalf of TerminalView. Committed text goes to Neovim as literal input;
/// composing text stays in `markedText` until the input context unmarks it.
final class IMEHandler: NSObject {
    weak var view: TerminalView?

    private(set) var markedText = ""
    private(set) var markedSelection = NSRange(location: 0, length: 0)
    var hasMarkedText: Bool { !markedText.isEmpty }

    /// The view hooks this to redraw the preedit region.
    var onMarkedTextChange: (() -> Void)?

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = Self.extract(string)
        if hasMarkedText { unmarkText() }
        guard !text.isEmpty, let view else { return }
        view.sendKeys(Self.literalKeys(for: text))
    }

    func setMarkedText(_ string: Any, selectedRange selRange: NSRange, replacementRange: NSRange) {
        markedText = Self.extract(string)
        let count = markedText.utf16.count
        let location = min(max(selRange.location, 0), count)
        markedSelection = NSRange(location: location, length: min(max(selRange.length, 0), count - location))
        onMarkedTextChange?()
    }

    func unmarkText() {
        guard hasMarkedText else { return }
        markedText = ""
        markedSelection = NSRange(location: 0, length: 0)
        onMarkedTextChange?()
    }

    func selectedRange() -> NSRange {
        hasMarkedText ? markedSelection : NSRange(location: NSNotFound, length: 0)
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = NSRange(location: 0, length: markedText.utf16.count)
        guard let view, let window = view.window else { return .zero }
        let rect = view.preeditRect(forCharacterRange: range)
        return window.convertToScreen(view.convert(rect, to: nil))
    }

    func doCommand(by selector: Selector?) {
        guard let selector else { return }
        guard let keys = Self.selectorKeys[selector] else {
            // Unknown selectors (layout-specific keys, editing commands we do
            // not model) are dropped; visible at debug level when diagnosing.
            Log.input.debug("Ignoring unhandled input command \(selector)")
            return
        }
        view?.sendKeys(keys)
    }

    /// Literal committed text for `nvim_input`: a raw "<" would start key
    /// notation, so it is spelled out; line breaks become Enter.
    static func literalKeys(for text: String) -> String {
        text
            .replacingOccurrences(of: "<", with: "<lt>")
            .replacingOccurrences(of: "\r", with: "<CR>")
            .replacingOccurrences(of: "\n", with: "<CR>")
    }

    private static func extract(_ string: Any) -> String {
        if let attributed = string as? NSAttributedString { return attributed.string }
        if let plain = string as? String { return plain }
        return ""
    }

    /// `doCommand(by:)` selectors the input context can send instead of
    /// `insertText` — during composition this is how navigation reaches us.
    static let selectorKeys: [Selector: String] = [
        Selector("insertNewline:"): "<CR>",
        Selector("insertTab:"): "<Tab>",
        Selector("insertBacktab:"): "<S-Tab>",
        Selector("deleteBackward:"): "<BS>",
        Selector("deleteForward:"): "<Del>",
        Selector("cancelOperation:"): "<Esc>",
        Selector("moveUp:"): "<Up>",
        Selector("moveDown:"): "<Down>",
        Selector("moveLeft:"): "<Left>",
        Selector("moveRight:"): "<Right>",
        Selector("moveToBeginningOfLine:"): "<Home>",
        Selector("moveToEndOfLine:"): "<End>",
        Selector("moveToBeginningOfDocument:"): "<C-Home>",
        Selector("moveToEndOfDocument:"): "<C-End>",
        Selector("movePageUp:"): "<PageUp>",
        Selector("movePageDown:"): "<PageDown>",
    ]
}

extension TerminalView: NSTextInputClient {
    func insertText(_ insertString: Any, replacementRange: NSRange) {
        imeHandler.insertText(insertString, replacementRange: replacementRange)
    }

    func setMarkedText(_ string: Any, selectedRange selRange: NSRange, replacementRange: NSRange) {
        imeHandler.setMarkedText(string, selectedRange: selRange, replacementRange: replacementRange)
    }

    func unmarkText() {
        imeHandler.unmarkText()
    }

    func selectedRange() -> NSRange {
        imeHandler.selectedRange()
    }

    func hasMarkedText() -> Bool {
        imeHandler.hasMarkedText
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        imeHandler.attributedSubstring(forProposedRange: range, actualRange: actualRange)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        imeHandler.firstRect(forCharacterRange: range, actualRange: actualRange)
    }

    func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }

    func doCommand(by selector: Selector?) {
        imeHandler.doCommand(by: selector)
    }
}
