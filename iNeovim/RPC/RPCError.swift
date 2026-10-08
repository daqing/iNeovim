import Foundation

enum RPCError: LocalizedError {
    case remote(MsgPackValue)
    case connectionClosed

    var errorDescription: String? {
        switch self {
        case .remote(let error):
            "nvim returned an error: \(error)"
        case .connectionClosed:
            "The connection to nvim is closed"
        }
    }
}
