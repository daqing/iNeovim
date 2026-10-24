import AppKit
import Foundation
import os

/// Installs an `ineovim` launcher into a directory the user's shell already
/// searches. The launcher hands its arguments — and the shell's working
/// directory, which a plain file open cannot carry — to the app as one
/// `ineovim://` URL, so every command opens its own window in the directory
/// the user typed it in.
enum CommandLineTool {
    static let commandName = "ineovim"
    static let bundleIdentifier = "com.mzevo.iNeovim"
    static let urlScheme = "ineovim"

    private static let scriptMarker = "# iNeovim command-line launcher"

    struct Destination: Equatable {
        let directory: URL
        /// Whether the directory is on the login shell's PATH; nil when the
        /// shell could not be queried.
        let isOnPath: Bool?

        var commandURL: URL { directory.appendingPathComponent(CommandLineTool.commandName) }
    }

    /// One `ineovim` invocation: the shell's directory plus its file
    /// arguments, resolved to absolute paths.
    struct OpenRequest: Equatable {
        let workingDirectory: URL
        let files: [URL]
    }

    /// Decode `ineovim://open?payload=…`. The payload is base64url over
    /// NUL-terminated UTF-8 components: the shell's directory first, then
    /// each argument, so spaces, newlines, and non-ASCII names survive the
    /// trip. Relative arguments resolve against the shell's directory.
    /// The window's directory follows the arguments: the first one's
    /// directory (or the argument itself when it is a directory), falling
    /// back to the shell's directory when there is no argument.
    static func openRequest(from url: URL) -> OpenRequest? {
        guard url.scheme?.lowercased() == urlScheme, url.host == "open",
              let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems,
              let payload = queryItems.first(where: { $0.name == "payload" })?.value,
              let components = decodePayload(payload),
              let directory = components.first else {
            return nil
        }
        let shellDirectory = resolvePath(directory, relativeTo: nil)
        let files = components.dropFirst().map { resolvePath($0, relativeTo: shellDirectory) }
        return OpenRequest(
            workingDirectory: workingDirectory(for: files, fallback: shellDirectory),
            files: files
        )
    }

    /// A path argument decides the directory — running `ineovim
    /// /elsewhere/file.go` from `$HOME` opens the window in `/elsewhere`,
    /// not in `$HOME`. A directory argument is its own target.
    private static func workingDirectory(for files: [URL], fallback: URL) -> URL {
        guard let first = files.first else { return fallback }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: first.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return first
        }
        return first.deletingLastPathComponent()
    }

    private static func decodePayload(_ payload: String) -> [String]? {
        var base64 = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: base64),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        var components = text
            .split(separator: "\0", omittingEmptySubsequences: false)
            .map(String.init)
        if components.last?.isEmpty == true {
            components.removeLast()
        }
        return components.isEmpty ? nil : components
    }

    private static func resolvePath(_ path: String, relativeTo directory: URL?) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        let base = directory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return base.appendingPathComponent(expanded).standardizedFileURL
    }

    /// Picks `~/.local/bin`, then Apple Silicon Homebrew, then the shared
    /// `/usr/local/bin`. A directory the login shell actually searches wins
    /// over one that merely exists, so the installed command is runnable.
    static func resolveDestination(
        homeDirectory: URL,
        shellPath: [String]?,
        fileExists: (String) -> Bool
    ) -> Destination {
        let localBin = homeDirectory.appendingPathComponent(".local/bin", isDirectory: true)
        let candidates = [
            localBin,
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
        ]

        if let shellPath {
            if shellPath.contains(localBin.path) {
                return Destination(directory: localBin, isOnPath: true)
            }
            let shared = candidates.dropFirst()
            let onPath = shared.first { shellPath.contains($0.path) && fileExists($0.path) }
                ?? shared.first { shellPath.contains($0.path) }
            if let onPath {
                return Destination(directory: onPath, isOnPath: true)
            }
        }

        if let existing = candidates.first(where: { fileExists($0.path) }) {
            return Destination(directory: existing, isOnPath: shellPath.map { $0.contains(existing.path) })
        }
        return Destination(directory: localBin, isOnPath: shellPath?.contains(localBin.path) ?? false)
    }

    static func install() {
        Task {
            let fileManager = FileManager.default
            let destination = resolveDestination(
                homeDirectory: fileManager.homeDirectoryForCurrentUser,
                shellPath: await loginShellPath(),
                fileExists: { fileManager.fileExists(atPath: $0) }
            )
            guard confirmReplacement(at: destination.commandURL) else { return }
            let needsAdmin = needsAdministrator(for: destination.directory)
            guard !needsAdmin || confirmAdministratorInstall(destination) else { return }

            let script = launcherScript(appPath: Bundle.main.bundlePath)
            do {
                if needsAdmin {
                    try installWithAdministratorPrivileges(script, at: destination.commandURL)
                } else {
                    try install(script, at: destination.commandURL)
                }
                Log.app.info("Installed \(commandName, privacy: .public) at \(destination.commandURL.path, privacy: .public)")
                reportSuccess(destination)
            } catch InstallError.cancelled {
                Log.app.notice("Command-line tool installation cancelled")
            } catch {
                Log.app.error("Command-line tool installation failed: \(error.localizedDescription, privacy: .public)")
                reportFailure(error)
            }
        }
    }

    private static func confirmReplacement(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path), !isInstalledLauncher(at: url) else {
            return true
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Replace the existing \(commandName) command?"
        alert.informativeText = "\(url.path) already exists and was not installed by iNeovim. Replacing it may break other software."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func confirmAdministratorInstall(_ destination: Destination) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Install \(commandName) to \(destination.directory.path)?"
        alert.informativeText = "This folder needs administrator privileges. macOS will ask for your password."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func reportSuccess(_ destination: Destination) {
        let alert = NSAlert()
        alert.messageText = "Command Line Tool Installed"
        var details = "The \(commandName) command is available at \(destination.commandURL.path). Run \(commandName) --help for usage."
        if destination.isOnPath == false {
            details += "\n\n\(destination.directory.path) is not in your shell's PATH. Add it to your shell profile, for example:\n\nexport PATH=\"\(destination.directory.path):$PATH\""
        }
        alert.informativeText = details
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func reportFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could Not Install \(commandName)"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func isInstalledLauncher(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        return String(decoding: data.prefix(1024), as: UTF8.self).contains(scriptMarker)
    }

    private static func needsAdministrator(for directory: URL) -> Bool {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            return !isDirectory.boolValue || !fileManager.isWritableFile(atPath: directory.path)
        }
        let parent = directory.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory),
              parentIsDirectory.boolValue else {
            return true
        }
        return !fileManager.isWritableFile(atPath: parent.path)
    }

    private static func install(_ script: String, at url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fileManager.createFile(atPath: url.path, contents: Data(script.utf8)) else {
            throw InstallError.writeFailed(url.path)
        }
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Elevates through Standard Additions: the script travels as base64 so
    /// no quoting layer has to see its contents, and the destination is
    /// shell-quoted for the single `do shell script` command.
    private static func installWithAdministratorPrivileges(_ script: String, at url: URL) throws {
        let encoded = Data(script.utf8).base64EncodedString()
        let directory = shellQuote(url.deletingLastPathComponent().path)
        let target = shellQuote(url.path)
        let command = [
            "/bin/mkdir -p \(directory)",
            "/bin/echo \(shellQuote(encoded)) | /usr/bin/base64 -D > \(target)",
            "/bin/chmod 755 \(target)",
        ].joined(separator: " && ")
        let source = "do shell script \"\(appleScriptEscaped(command))\" with administrator privileges"
        guard let appleScript = NSAppleScript(source: source) else {
            throw InstallError.writeFailed(url.path)
        }
        var errorInfo: NSDictionary?
        appleScript.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return }
        if (errorInfo[NSAppleScript.errorNumber] as? Int) == -128 {
            throw InstallError.cancelled
        }
        let message = errorInfo[NSAppleScript.errorMessage] as? String
            ?? "Could not write \(url.path)."
        throw InstallError.appleScript(message)
    }

    static func launcherScript(appPath: String) -> String {
        """
        #!/bin/sh
        \(scriptMarker) (installed by iNeovim).
        APP_PATH=\(shellQuote(appPath))
        BUNDLE_ID='\(bundleIdentifier)'

        case "${1-}" in
            -h|--help)
                printf 'usage: \(commandName) [path ...]\\n\\nOpen paths in a new iNeovim window. The window starts in the directory\\nof the first path, or in the current directory when no path is given.\\nMissing paths are created.\\n'
                exit 0
                ;;
        esac

        for arg in "$@"; do
            case "$arg" in
                -*) continue ;;
            esac
            if [ ! -e "$arg" ]; then
                if ! ( : >"$arg" ); then
                    printf '\(commandName): cannot create %s\\n' "$arg" >&2
                    exit 1
                fi
            fi
        done

        # A plain file open cannot say which directory the command ran in, so
        # the directory and the arguments travel as one URL: base64url over
        # NUL-terminated components (the directory first).
        payload=$(
            {
                printf '%s\\0' "${PWD:-$(pwd -P)}"
                for arg in "$@"; do
                    printf '%s\\0' "$arg"
                done
            } | /usr/bin/base64 | /usr/bin/tr -d '\\n' | /usr/bin/tr '+/' '-_' | /usr/bin/tr -d '='
        )

        if /usr/bin/open "\(urlScheme)://open?payload=$payload" 2>/dev/null; then
            exit 0
        fi

        if [ -d "$APP_PATH" ]; then
            exec /usr/bin/open -a "$APP_PATH" "$@"
        fi
        exec /usr/bin/open -b "$BUNDLE_ID" "$@"
        """
    }

    /// GUI apps inherit launchd's minimal PATH, so ask the login shell for
    /// the PATH a terminal would see (zsh only reads `.zprofile` there, where
    /// Homebrew and user bin directories usually live).
    private static func loginShellPath() async -> [String]? {
        guard let shell = ProcessInfo.processInfo.environment["SHELL"], shell.hasPrefix("/") else {
            return nil
        }
        let shellName = (shell as NSString).lastPathComponent
        let command = shellName == "fish"
            ? "printf '__INEVIM_PATH_BEGIN__%s__INEVIM_PATH_END__' (string join : $PATH)"
            : "printf '__INEVIM_PATH_BEGIN__%s__INEVIM_PATH_END__' \"$PATH\""
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: shell)
                process.arguments = ["-l", "-c", command]
                process.standardInput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                let output = Pipe()
                process.standardOutput = output
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0,
                      let text = String(data: data, encoding: .utf8),
                      let start = text.range(of: "__INEVIM_PATH_BEGIN__"),
                      let end = text.range(of: "__INEVIM_PATH_END__", range: start.upperBound..<text.endIndex) else {
                    continuation.resume(returning: nil)
                    return
                }
                let value = String(text[start.upperBound..<end.lowerBound])
                continuation.resume(returning: value.split(separator: ":").map(String.init))
            }
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private enum InstallError: LocalizedError {
        case cancelled
        case writeFailed(String)
        case appleScript(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                "Installation was cancelled."
            case .writeFailed(let path):
                "Could not write \(path)."
            case .appleScript(let message):
                message
            }
        }
    }
}
