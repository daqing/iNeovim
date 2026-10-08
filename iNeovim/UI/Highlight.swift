import Foundation

/// A parsed `hl_attr_define` entry. Colors are packed 0xRRGGBB; nil means nvim
/// did not set that color for the attribute.
struct HlAttr: Equatable, Sendable {
    var foreground: Int?
    var background: Int?
    var special: Int?
    var bold = false
    var italic = false
    var underline = false
    var undercurl = false
    var strikethrough = false
    var reverse = false
    var standout = false

    init(
        foreground: Int? = nil,
        background: Int? = nil,
        special: Int? = nil,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        undercurl: Bool = false,
        strikethrough: Bool = false,
        reverse: Bool = false,
        standout: Bool = false
    ) {
        self.foreground = foreground
        self.background = background
        self.special = special
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.undercurl = undercurl
        self.strikethrough = strikethrough
        self.reverse = reverse
        self.standout = standout
    }

    init(rawMap map: MsgPackValueMap) {
        self.init(
            foreground: map[.string("foreground")]?.intValue,
            background: map[.string("background")]?.intValue,
            special: map[.string("special")]?.intValue,
            bold: map[.string("bold")]?.boolValue ?? false,
            italic: map[.string("italic")]?.boolValue ?? false,
            underline: map[.string("underline")]?.boolValue ?? false,
            undercurl: map[.string("undercurl")]?.boolValue ?? false,
            strikethrough: map[.string("strikethrough")]?.boolValue ?? false,
            reverse: map[.string("reverse")]?.boolValue ?? false,
            standout: map[.string("standout")]?.boolValue ?? false
        )
    }
}
