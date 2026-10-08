import Foundation

/// A Neovim object reference; nvim encodes these as msgpack ext with a
/// big-endian integer id payload.
protocol NvimHandle: Hashable, Sendable {
    var rawValue: Int { get }
    init(rawValue: Int)
    static var extType: Int8 { get }
}

struct Buffer: NvimHandle {
    static let extType: Int8 = 0
    let rawValue: Int
}

struct Window: NvimHandle {
    static let extType: Int8 = 1
    let rawValue: Int
}

struct Tabpage: NvimHandle {
    static let extType: Int8 = 2
    let rawValue: Int
}

extension MsgPackValue {
    init<H: NvimHandle>(_ handle: H) {
        var bytes = Data(count: 8)
        var value = UInt64(handle.rawValue)
        for i in stride(from: 7, through: 0, by: -1) {
            bytes[i] = UInt8(value & 0xff)
            value >>= 8
        }
        self = .ext(type: H.extType, data: bytes)
    }

    func handle<H: NvimHandle>(as type: H.Type = H.self) -> H? {
        guard case let .ext(kind, data) = self, kind == H.extType, !data.isEmpty, data.count <= 8 else {
            return nil
        }
        let raw = data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return H(rawValue: Int(raw))
    }
}
