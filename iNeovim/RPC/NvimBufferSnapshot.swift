import Foundation

/// The current nvim buffer's name, filetype, and contents, captured for the
/// Markdown preview. The body comes from the buffer rather than the file on
/// disk, so unsaved edits are previewed; the name supplies the base URL for
/// relative links.
nonisolated struct NvimBufferSnapshot: Equatable, Sendable {
    var name: String
    var filetype: String
    var lines: [String]

    var text: String { lines.joined(separator: "\n") }

    var fileURL: URL? {
        guard !name.isEmpty else { return nil }
        return URL(fileURLWithPath: name)
    }

    var baseURL: URL? {
        fileURL?.deletingLastPathComponent()
    }

    var previewTitle: String {
        guard let fileURL, !fileURL.lastPathComponent.isEmpty else {
            return "Markdown Preview"
        }
        return "\(fileURL.lastPathComponent) — Preview"
    }

    var isMarkdown: Bool {
        let type = filetype.lowercased()
        if type == "markdown" || type.hasPrefix("markdown.") { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return ["md", "markdown", "mdown", "mkd", "mdx"].contains(ext)
    }
}
