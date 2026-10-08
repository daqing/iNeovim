import Foundation

enum MsgPackValue: Hashable, Sendable {
    case `nil`
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case float(Double)
    case string(String)
    case binary(Data)
    case array([MsgPackValue])
    case map([MsgPackValue: MsgPackValue])
    case ext(type: Int8, data: Data)
}
