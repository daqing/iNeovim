import Foundation

/// Query matching for the Open Quickly panel. Prefers the real `fzf`
/// (`fzf --filter`, the headless batch mode with no TUI) so results keep
/// fzf's ranking; falls back to an in-process subsequence scorer when the
/// binary is unavailable.
enum FuzzyMatcher {
    static let resultCap = 200

    /// Filtered and ranked candidates for `query`; empty for an empty
    /// query's tail beyond the cap. Uses fzf when possible.
    static func filter(_ query: String, candidates: [String]) async -> [String] {
        guard !query.isEmpty else { return Array(candidates.prefix(resultCap)) }
        if let fzf = fzfBinary(), let ranked = await runFZF(fzf, query: query, candidates: candidates) {
            return ranked
        }
        return fallbackFilter(query, candidates: candidates)
    }

    /// fzf lives outside the GUI PATH; probe the usual Homebrew locations.
    static func fzfBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/fzf",
            "/usr/local/bin/fzf",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/fzf").path,
        ]
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    /// `fzf --filter`: feed candidates on stdin, read ranked matches back.
    /// Writing happens on its own thread — the candidate list can exceed
    /// the pipe buffer, so reading must start before writing finishes.
    /// Returns nil when the tool fails, so the caller can fall back.
    private static func runFZF(_ binary: String, query: String, candidates: [String]) async -> [String]? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binary)
                process.arguments = ["--filter", query]
                let inPipe = Pipe()
                let outPipe = Pipe()
                process.standardInput = inPipe
                process.standardOutput = outPipe
                process.standardError = Pipe()
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }

                let input = Data((candidates.joined(separator: "\n") + "\n").utf8)
                Thread.detachNewThread {
                    try? inPipe.fileHandleForWriting.write(contentsOf: input)
                    inPipe.fileHandleForWriting.closeFile()
                }

                var lines: [String] = []
                var data = Data()
                let handle = outPipe.fileHandleForReading
                while lines.count < resultCap {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    data.append(chunk)
                    while let newline = data.firstIndex(of: 0x0A) {
                        let lineData = data[..<newline]
                        data.removeSubrange(...newline)
                        if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                            lines.append(line)
                            if lines.count >= resultCap {
                                process.terminate()
                                continuation.resume(returning: lines)
                                return
                            }
                        }
                    }
                }
                process.waitUntilExit()
                continuation.resume(returning: lines)
            }
        }
    }

    /// In-process subsequence match: every query character must appear in
    /// order; runs of consecutive matches and matches at path-segment
    /// starts score higher. Case-insensitive on the path tail.
    static func fallbackFilter(_ query: String, candidates: [String]) -> [String] {
        let needle = query.lowercased()
        var scored: [(String, Int)] = []
        for candidate in candidates {
            if let score = score(needle, in: candidate.lowercased()) {
                scored.append((candidate, score))
            }
        }
        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(resultCap)
            .map(\.0)
    }

    private static func score(_ needle: String, in haystack: String) -> Int? {
        var score = 0
        var streak = 0
        var index = haystack.startIndex
        for character in needle {
            guard index < haystack.endIndex else { return nil }
            var matched = false
            while index < haystack.endIndex {
                if haystack[index] == character {
                    streak += 1
                    score += streak
                    if index == haystack.startIndex || haystack[haystack.index(before: index)] == "/" {
                        score += 5
                    }
                    index = haystack.index(after: index)
                    matched = true
                    break
                }
                streak = 0
                index = haystack.index(after: index)
            }
            if !matched { return nil }
        }
        // Shorter paths beat longer ones at equal scores.
        return score * 1000 - haystack.count
    }
}
