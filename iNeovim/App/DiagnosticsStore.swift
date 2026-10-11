import Foundation

/// Aggregated `vim.diagnostic` state for one embedded session, keyed by
/// buffer. Each `ineovim:diagnostics` notification replaces the snapshot for
/// its buffer, so clearing and re-publishing stay in sync with nvim. The
/// problems sheet reads `problems` and reloads through `onChange`.
@MainActor
final class DiagnosticsStore {
    struct Problem: Equatable {
        var diagnostic: NvimDiagnostic
        var path: String
    }

    private struct BufferDiagnostics: Equatable {
        var path: String
        var diagnostics: [NvimDiagnostic]
    }

    private var buffers: [Int: BufferDiagnostics] = [:]

    /// Invoked on the main actor after every change; the problems sheet
    /// subscribes while it is open.
    var onChange: (() -> Void)?

    func apply(_ update: NvimDiagnosticUpdate) {
        buffers[update.bufferId] = BufferDiagnostics(path: update.path, diagnostics: update.diagnostics)
        onChange?()
    }

    func clear() {
        guard !buffers.isEmpty else { return }
        buffers.removeAll()
        onChange?()
    }

    /// Every error and warning across buffers, errors first, then by path and
    /// position. Info and hint entries are kept in `buffers` but not listed.
    var problems: [Problem] {
        var list: [Problem] = []
        for buffer in buffers.values {
            for diagnostic in buffer.diagnostics
            where diagnostic.severity == .error || diagnostic.severity == .warning {
                list.append(Problem(diagnostic: diagnostic, path: buffer.path))
            }
        }
        return list.sorted { lhs, rhs in
            let lhsRank = lhs.diagnostic.severity == .error ? 0 : 1
            let rhsRank = rhs.diagnostic.severity == .error ? 0 : 1
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            if lhs.path != rhs.path { return lhs.path < rhs.path }
            if lhs.diagnostic.line != rhs.diagnostic.line {
                return lhs.diagnostic.line < rhs.diagnostic.line
            }
            if lhs.diagnostic.column != rhs.diagnostic.column {
                return lhs.diagnostic.column < rhs.diagnostic.column
            }
            return lhs.diagnostic.message < rhs.diagnostic.message
        }
    }

    var problemCount: Int {
        buffers.values.reduce(0) { count, buffer in
            count + buffer.diagnostics.filter {
                $0.severity == .error || $0.severity == .warning
            }.count
        }
    }
}
