import Foundation

/// One diagnostic entry pushed by the embedded nvim's diagnostics hook
/// (`vim.diagnostic` items, whatever language server produced them).
nonisolated struct NvimDiagnostic: Equatable, Sendable {
    enum Severity: Int, Equatable, Sendable {
        case error = 1
        case warning
        case info
        case hint
    }

    var severity: Severity
    var message: String
    var source: String
    var code: String
    /// Zero-based buffer line/column of the range start; `endLine`/`endColumn`
    /// default to the start when the server omits them.
    var line: Int
    var column: Int
    var endLine: Int
    var endColumn: Int
}

/// Payload of one `ineovim:diagnostics` notification: the full diagnostic
/// snapshot for a single buffer (empty list means the buffer is now clean).
nonisolated struct NvimDiagnosticUpdate: Equatable, Sendable {
    static let rpcMethod = "ineovim:diagnostics"

    var bufferId: Int
    var path: String
    var diagnostics: [NvimDiagnostic]

    /// Parse the notification params (`[payload]`, a one-element array whose
    /// item is the map the Lua hook rpcnotify'd). Missing keys are tolerated:
    /// nvim's msgpack encoder drops nil-valued map entries.
    static func parse(_ params: [MsgPackValue]) -> NvimDiagnosticUpdate? {
        guard let payload = params.first,
              case let .map(map) = payload,
              let bufferId = map[.string("buf")]?.intValue else { return nil }
        var diagnostics: [NvimDiagnostic] = []
        if case let .array(items)? = map[.string("diagnostics")] {
            diagnostics = items.compactMap(parseDiagnostic)
        }
        return NvimDiagnosticUpdate(
            bufferId: bufferId,
            path: map[.string("name")]?.stringValue ?? "",
            diagnostics: diagnostics
        )
    }

    private static func parseDiagnostic(_ value: MsgPackValue) -> NvimDiagnostic? {
        guard case let .map(fields) = value else { return nil }
        let line = fields[.string("lnum")]?.intValue ?? 0
        let column = fields[.string("col")]?.intValue ?? 0
        return NvimDiagnostic(
            severity: fields[.string("severity")]?.intValue.flatMap(NvimDiagnostic.Severity.init(rawValue:)) ?? .info,
            message: fields[.string("message")]?.stringValue ?? "",
            source: fields[.string("source")]?.stringValue ?? "",
            code: fields[.string("code")]?.stringValue ?? "",
            line: line,
            column: column,
            endLine: fields[.string("end_lnum")]?.intValue ?? line,
            endColumn: fields[.string("end_col")]?.intValue ?? column
        )
    }
}
