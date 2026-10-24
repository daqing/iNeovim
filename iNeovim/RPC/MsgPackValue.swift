import Foundation

/// Boxed map storage: with MainActor as the module's default actor isolation, a
/// dictionary associated value directly on the recursive enum triggers a compiler
/// circular reference; the box lets conformance synthesis resolve normally.
nonisolated struct MsgPackValueMap: Hashable {
    var entries: [MsgPackValue: MsgPackValue]

    init(_ entries: [MsgPackValue: MsgPackValue] = [:]) {
        self.entries = entries
    }

    subscript(key: MsgPackValue) -> MsgPackValue? {
        entries[key]
    }
}

nonisolated enum MsgPackValue: Hashable {
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

// The value types cross actor boundaries freely (RPC read thread, session
// actor, main actor), which is why they — and the codec below — are nonisolated
// instead of picking up the module's MainActor default.

nonisolated extension MsgPackValue {
    /// Numeric payload regardless of whether nvim encoded it as msgpack int or uint.
    var intValue: Int? {
        switch self {
        case .int(let value):
            Int(value)
        case .uint(let value):
            Int(value)
        default:
            nil
        }
    }

    var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }
}
