import Foundation

/// One Open Quickly candidate: a file path, or a directory (Enter narrows
/// the panel into it rather than opening anything).
struct QuicklyEntry: Equatable, Sendable {
    var path: String
    var isDirectory: Bool
}

/// Candidate collection for the Open Quickly panel: the immediate children
/// of one directory (the working directory, or the directory the panel has
/// drilled into). One level per read — never a recursive walk.
enum QuicklyFileSource {
    /// First-level, non-hidden children of `directory`: files plus
    /// directories (Enter on a directory re-collects it).
    static func collect(cwd directory: String) async -> [QuicklyEntry] {
        // fd respects .gitignore (keeps node_modules out of repos); find is
        // the always-available fallback. Both list one level.
        if let files = await run(fdBinary(), ["--max-depth", "1", "--type", "f", "--absolute-path", ".", directory]), !files.isEmpty {
            let dirs = await run(fdBinary(), ["--max-depth", "1", "--type", "d", "--absolute-path", ".", directory]) ?? []
            return files.map { QuicklyEntry(path: $0, isDirectory: false) }
                + dirs.map { QuicklyEntry(path: $0, isDirectory: true) }
        }
        let files = await run("/usr/bin/find", [directory, "-maxdepth", "1", "-type", "f", "-not", "-path", "*/.*"]) ?? []
        let dirs = await run("/usr/bin/find", [directory, "-maxdepth", "1", "-type", "d", "-not", "-path", "*/.*"]) ?? []
        return files.map { QuicklyEntry(path: $0, isDirectory: false) }
            + dirs.filter { $0 != directory }
                .map { QuicklyEntry(path: $0, isDirectory: true) }
    }

    /// fd lives outside the GUI PATH; probe the usual Homebrew locations.
    private static func fdBinary() -> String {
        let candidates = [
            "/opt/homebrew/bin/fd",
            "/usr/local/bin/fd",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/fd").path,
        ]
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0)
        } ?? "/usr/bin/fd"
    }

    /// Run a line-oriented listing, capped at `entryCap` lines; nil when the
    /// tool is missing or fails so the caller can fall back.
    private static func run(_ path: String, _ arguments: [String]) async -> [String]? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                process.standardError = Pipe()
                let out = Pipe()
                process.standardOutput = out
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                var lines: [String] = []
                let entryCap = 20_000
                let handle = out.fileHandleForReading
                var data = Data()
                while lines.count < entryCap {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    data.append(chunk)
                    while let newline = data.firstIndex(of: 0x0A) {
                        let lineData = data[..<newline]
                        data.removeSubrange(...newline)
                        if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                            lines.append(line)
                            if lines.count >= entryCap {
                                process.terminate()
                                continuation.resume(returning: lines)
                                return
                            }
                        }
                    }
                }
                process.waitUntilExit()
                // A non-zero exit means the tool could not list (git outside
                // a repository, a broken fd invocation): hand the fallback
                // chain to the next source instead of an empty result.
                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                if let tail = String(data: data, encoding: .utf8), !tail.isEmpty {
                    lines.append(tail)
                }
                continuation.resume(returning: lines)
            }
        }
    }
}
