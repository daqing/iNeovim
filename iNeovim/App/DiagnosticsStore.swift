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

    /// Every diagnostic across buffers, most severe first (error, warning,
    /// info, hint), then by path and position. Info and hint rows render
    /// dimmed in the panel.
    var problems: [Problem] {
        var list: [Problem] = []
        for buffer in buffers.values {
            for diagnostic in buffer.diagnostics {
                list.append(Problem(diagnostic: diagnostic, path: buffer.path))
            }
        }
        return list.sorted { lhs, rhs in
            if lhs.diagnostic.severity.rawValue != rhs.diagnostic.severity.rawValue {
                return lhs.diagnostic.severity.rawValue < rhs.diagnostic.severity.rawValue
            }
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
}
