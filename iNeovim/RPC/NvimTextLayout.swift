import CoreGraphics

/// A window's text area in global grid coordinates, as `getwininfo` reports
/// it: the `textoff` gutter columns (fold, sign, and number columns) sit left
/// of `columns`. The renderer draws a region's cells a few points right of
/// the grid, so buffer text clears the gutter — nvim's gutter widths are
/// whole cells only, so that padding cannot come from an option.
nonisolated struct NvimTextRegion: Equatable, Sendable {
    var rows: Range<Int>
    var columns: Range<Int>
}

/// Payload of one `ineovim:textlayout` notification: the text areas of the
/// current tabpage's windows. A window without a gutter is omitted (its text
/// already starts at the window's left edge, with nothing to clear), and
/// floating windows are left out — they are placed by the cursor, not by the
/// tabpage layout.
nonisolated enum NvimTextLayout {
    static let rpcMethod = "ineovim:textlayout"

    /// How far a text region's glyphs are drawn right of their cell origin.
    static let textShift: CGFloat = 2

    /// Parse the notification params (`[windows]`): an array of window text
    /// areas. Missing or unusable entries are dropped; an empty array is
    /// valid and means no window has a gutter.
    static func parse(_ params: [MsgPackValue]) -> [NvimTextRegion]? {
        guard let payload = params.first, case let .array(windows) = payload else { return nil }
        return windows.compactMap { window -> NvimTextRegion? in
            guard case let .map(fields) = window,
                  let row = fields[.string("row")]?.intValue,
                  let col = fields[.string("col")]?.intValue,
                  let height = fields[.string("height")]?.intValue,
                  let width = fields[.string("width")]?.intValue,
                  height > 0, width > 0 else { return nil }
            return NvimTextRegion(rows: row..<(row + height), columns: col..<(col + width))
        }
    }
}
