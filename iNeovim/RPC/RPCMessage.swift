import Foundation

/// A msgpack-RPC frame: request `[0, msgid, method, params]`,
/// response `[1, msgid, error, result]`, or notification `[2, method, params]`.
nonisolated enum RPCMessage {
    case request(msgid: UInt64, method: String, params: [MsgPackValue])
    case response(msgid: UInt64, error: MsgPackValue, result: MsgPackValue)
    case notification(method: String, params: [MsgPackValue])

    init?(_ value: MsgPackValue) {
        guard case let .array(elements) = value, elements.count >= 3,
              case let .uint(type) = elements[0] else { return nil }
        switch type {
        case 0:
            guard elements.count == 4,
                  case let .uint(msgid) = elements[1],
                  case let .string(method) = elements[2],
                  case let .array(params) = elements[3] else { return nil }
            self = .request(msgid: msgid, method: method, params: params)
        case 1:
            guard elements.count == 4,
                  case let .uint(msgid) = elements[1] else { return nil }
            self = .response(msgid: msgid, error: elements[2], result: elements[3])
        case 2:
            guard case let .string(method) = elements[1],
                  case let .array(params) = elements[2] else { return nil }
            self = .notification(method: method, params: params)
        default:
            return nil
        }
    }
}
