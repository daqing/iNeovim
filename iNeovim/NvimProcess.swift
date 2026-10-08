import Foundation
import os

actor NvimProcess {
    static let shared = NvimProcess()

    private var process: Process?
    private var isStarting = false

    func start() async throws {
        guard !isStarting, process == nil else { return }
        isStarting = true
        defer { isStarting = false }

        let binary = try await NvimDiscovery().resolve()
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--embed"]
        process.standardInput = Pipe()
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        process.terminationHandler = { [weak self] process in
            Task { await self?.handleTermination(process) }
        }
        try process.run()
        self.process = process
        Log.rpc.info("Embedded nvim started (pid \(process.processIdentifier, privacy: .public))")
    }

    func terminate() {
        guard let process, process.isRunning else { return }
        Log.rpc.info("Terminating embedded nvim (pid \(process.processIdentifier, privacy: .public))")
        process.terminate()
    }

    private func handleTermination(_ process: Process) {
        Log.rpc.info("Embedded nvim exited (status \(process.terminationStatus, privacy: .public))")
        if self.process === process {
            self.process = nil
        }
    }
}
