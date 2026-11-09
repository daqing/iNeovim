import Foundation

/// A file path recognized in the terminal pane (Ghostty's `open_url` action),
/// optionally followed by a `:line[:column]` suffix from compiler or test
/// output. Parsing resolves the path against the terminal's working directory
/// and only accepts existing regular files; web URLs and anything else return
/// nil so the system handler keeps its behavior.
nonisolated struct TerminalFileLink: Equatable, Sendable {
    var url: URL
    var line: Int?
    var column: Int?

    static func parse(_ raw: String, workingDirectory: URL?) -> TerminalFileLink? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = trimMatchingPair(text)
        guard !text.isEmpty else { return nil }

        // A file URL carries the path in its body; every other `scheme://`
        // target (http, mail, app schemes) stays with the system handler.
        if text.lowercased().hasPrefix("file:") {
            guard let candidate = URL(string: text) else { return nil }
            return make(path: candidate.path(percentEncoded: false), workingDirectory: workingDirectory)
        }
        if text.contains("://") { return nil }
        return make(path: text, workingDirectory: workingDirectory)
    }

    private static func make(path: String, workingDirectory: URL?) -> TerminalFileLink? {
        let peeled = peelLineSuffix(from: path, workingDirectory: workingDirectory)
        guard let url = resolve(peeled.path, workingDirectory: workingDirectory) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }
        return TerminalFileLink(url: url, line: peeled.line, column: peeled.column)
    }

    /// A `:line[:column]` suffix is only peeled when the path without it names
    /// an existing file, so a filename that itself contains `:12` survives.
    private static func peelLineSuffix(
        from path: String,
        workingDirectory: URL?
    ) -> (path: String, line: Int?, column: Int?) {
        guard let range = path.range(
            of: #":(\d+)(?::(\d+))?$"#,
            options: .regularExpression
        ) else {
            return (path, nil, nil)
        }
        let numbers = path[range].dropFirst().split(separator: ":").compactMap { Int($0) }
        guard let line = numbers.first else { return (path, nil, nil) }
        let base = String(path[..<range.lowerBound])
        guard exists(base, workingDirectory: workingDirectory) else {
            return (path, nil, nil)
        }
        return (base, line, numbers.count > 1 ? numbers[1] : nil)
    }

    private static func exists(_ path: String, workingDirectory: URL?) -> Bool {
        guard let url = resolve(path, workingDirectory: workingDirectory) else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    private static func resolve(_ path: String, workingDirectory: URL?) -> URL? {
        let expanded = NSString(string: path).expandingTildeInPath
        guard !expanded.isEmpty else { return nil }
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        guard let workingDirectory else { return nil }
        return URL(fileURLWithPath: expanded, relativeTo: workingDirectory).standardizedFileURL
    }

    /// Terminal prose often wraps a path in quotes or brackets; a trailing
    /// punctuation character is not part of the filename.
    private static func trimMatchingPair(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, let last = text.last else { return text }
        let pairs: [Character: Character] = [
            "\"": "\"", "'": "'", "`": "`", "(": ")", "[": "]", "<": ">",
        ]
        guard pairs[first] == last else { return text }
        return String(text.dropFirst().dropLast())
    }
}
