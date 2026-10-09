import Foundation
import os

enum NvimProcessError: LocalizedError {
    case notRunning

    var errorDescription: String? {
        switch self {
        case .notRunning:
            "The embedded nvim process is not running"
        }
    }
}

actor NvimProcess {
    private let terminationStream: (stream: AsyncStream<Int32>, continuation: AsyncStream<Int32>.Continuation)

    nonisolated var termination: AsyncStream<Int32> { terminationStream.stream }

    private var process: Process?
    private var isStarting = false
    private var stdoutPipe: Pipe?
    nonisolated(unsafe) private var stdinWriter: FileHandle?

    init() {
        terminationStream = AsyncStream.makeStream(of: Int32.self)
    }

    var standardOutput: FileHandle? { stdoutPipe?.fileHandleForReading }

    func start() async throws {
        guard !isStarting, process == nil else { return }
        isStarting = true
        defer { isStarting = false }

        let binary = try await NvimDiscovery().resolve()
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = binary
        process.arguments = ["--embed"]
        // A GUI launch inherits "/" as the working directory; starting in the
        // user's home must happen here (not via RPC) so init.lua already sees
        // the expected `getcwd()` during startup.
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { [weak self] process in
            Task { await self?.handleTermination(process) }
        }
        try process.run()
        self.process = process
        self.stdinWriter = stdin.fileHandleForWriting
        self.stdoutPipe = stdout
        forwardStandardError(stderr.fileHandleForReading)
        Log.rpc.info("Embedded nvim started (pid \(process.processIdentifier, privacy: .public))")
    }

    nonisolated func writeToStandardInput(_ data: Data) throws {
        guard let stdinWriter else { throw NvimProcessError.notRunning }
        try stdinWriter.write(contentsOf: data)
    }

    func terminate() {
        guard let process, process.isRunning else { return }
        Log.rpc.info("Terminating embedded nvim (pid \(process.processIdentifier, privacy: .public))")
        process.terminate()
    }

    private func handleTermination(_ process: Process) {
        Log.rpc.info("Embedded nvim exited (status \(process.terminationStatus, privacy: .public))")
        // The stream stays open: the app can restart nvim after a crash and
        // observers keep listening across restarts.
        terminationStream.continuation.yield(process.terminationStatus)
        if self.process === process {
            self.process = nil
        }
    }

    private func forwardStandardError(_ handle: FileHandle) {
        handle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .newlines), !text.isEmpty else { return }
            Log.rpc.error("nvim stderr: \(text, privacy: .public)")
        }
    }
}
