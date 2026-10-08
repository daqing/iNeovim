import Foundation

/// Boxed map storage: with MainActor as the module's default actor isolation, a
/// dictionary associated value directly on the recursive enum triggers a compiler
/// circular reference; the box lets conformance synthesis resolve normally.
struct MsgPackValueMap {
    var entries: [MsgPackValue: MsgPackValue]

    init(_ entries: [MsgPackValue: MsgPackValue] = [:]) {
        self.entries = entries
    }

    subscript(key: MsgPackValue) -> MsgPackValue? {
        entries[key]
    }
}

enum MsgPackValue {
    case `nil`
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case float(Double)
    case string(String)
    case binary(Data)
    case array([MsgPackValue])
    case map(MsgPackValueMap)
    case ext(type: Int8, data: Data)
}

// Conformances are declared nonisolated: these value types are passed between
// actors (RPC layer), and MainActor-isolated conformances cannot satisfy the
// nonisolated generic contexts they are used from.
nonisolated extension MsgPackValueMap: Hashable {}
nonisolated extension MsgPackValue: Hashable {}
