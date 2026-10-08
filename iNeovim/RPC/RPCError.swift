import Foundation

enum RPCError: LocalizedError {
    case remote(MsgPackValue)
    case connectionClosed
    case invalidHandshake(MsgPackValue)
    case unsupportedApiLevel(found: UInt64, required: UInt64)

    var errorDescription: String? {
        switch self {
        case .remote(let error):
            "nvim returned an error: \(error)"
        case .connectionClosed:
            "The connection to nvim is closed"
        case .invalidHandshake(let response):
            "Unexpected nvim_get_api_info response: \(response)"
        case .unsupportedApiLevel(let found, let required):
            "nvim API level \(found) is below the required level \(required)"
        }
    }
}
