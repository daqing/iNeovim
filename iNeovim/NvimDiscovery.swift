import Foundation
import os

struct NvimVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    static func < (lhs: NvimVersion, rhs: NvimVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }
}

enum NvimDiscoveryError: LocalizedError {
    case missingOverride(String)
    case notFound
    case versionCheckFailed(URL, status: Int32)
    case unparsableVersionOutput(URL)
    case unsupportedVersion(found: NvimVersion, required: NvimVersion)

    var errorDescription: String? {
        switch self {
        case .missingOverride(let path):
            "Configured nvim binary does not exist or is not executable: \(path)"
        case .notFound:
            "Could not find the nvim binary. Install Neovim or set the nvimBinaryPath preference."
        case .versionCheckFailed(let url, let status):
            "'\(url.path) --version' exited with status \(status)"
        case .unparsableVersionOutput(let url):
            "Could not parse version from '\(url.path) --version' output"
        case .unsupportedVersion(let found, let required):
            "Neovim \(found) is too old; version \(required) or later is required"
        }
    }
}

struct NvimDiscovery {
    /// Minimum nvim release the GUI supports.
    static let minimumVersion = NvimVersion(major: 0, minor: 9, patch: 0)

    static let binaryPreferenceKey = "nvimBinaryPath"

    private static let commonSearchDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        NSHomeDirectory() + "/.local/bin",
    ]

    func resolve() async throws -> URL {
        let binary = try locate()
        let version = try await installedVersion(of: binary)
        guard version >= Self.minimumVersion else {
            throw NvimDiscoveryError.unsupportedVersion(found: version, required: Self.minimumVersion)
        }
        Log.rpc.info("Found nvim \(version.description, privacy: .public) at \(binary.path, privacy: .public)")
        return binary
    }

    private func locate() throws -> URL {
        if let override = UserDefaults.standard.string(forKey: Self.binaryPreferenceKey), !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw NvimDiscoveryError.missingOverride(override)
            }
            return url
        }

        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        for directory in pathDirectories + Self.commonSearchDirectories {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("nvim")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw NvimDiscoveryError.notFound
    }

    private func installedVersion(of binary: URL) async throws -> NvimVersion {
        let output = try await runVersionCheck(binary)
        return try parseVersion(output, source: binary)
    }

    private func runVersionCheck(_ binary: URL) async throws -> String {
        try await Task.detached {
            let process = Process()
            let stdout = Pipe()
            process.executableURL = binary
            process.arguments = ["--version"]
            process.standardOutput = stdout
            process.standardError = Pipe()
            try process.run()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NvimDiscoveryError.versionCheckFailed(binary, status: process.terminationStatus)
            }
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    private func parseVersion(_ output: String, source: URL) throws -> NvimVersion {
        guard let match = output.range(of: #"NVIM v(\d+)\.(\d+)\.(\d+)"#, options: .regularExpression) else {
            throw NvimDiscoveryError.unparsableVersionOutput(source)
        }
        let numbers = output[match].dropFirst(6).split(separator: ".").compactMap { Int($0) }
        guard numbers.count == 3 else {
            throw NvimDiscoveryError.unparsableVersionOutput(source)
        }
        return NvimVersion(major: numbers[0], minor: numbers[1], patch: numbers[2])
    }
}
