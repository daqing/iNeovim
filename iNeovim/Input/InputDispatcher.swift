import Foundation
import os

/// Carries `InputEvent`s from the view-side handlers to a single consumer
/// that forwards them to nvim via `NvimClient`.
actor InputDispatcher {
    static let shared = InputDispatcher()

    // Immutable so `send` can yield from any thread without hopping actors.
    private let stream: AsyncStream<InputEvent>
    private let continuation: AsyncStream<InputEvent>.Continuation
    private var isHandedOut = false
    private var consumeTask: Task<Void, Never>?

    init() {
        let (stream, continuation) = AsyncStream<InputEvent>.makeStream()
        self.stream = stream
        self.continuation = continuation
    }

    /// Queue an event from any handler; cheap and non-blocking.
    nonisolated func send(_ event: InputEvent) {
        continuation.yield(event)
    }

    /// Hand out the event stream; only the first caller receives the live
    /// stream, later requests get a finished one.
    func makeStream() -> AsyncStream<InputEvent> {
        guard !isHandedOut else {
            Log.input.error("Input event stream requested more than once; dropping extra consumer")
            return AsyncStream { $0.finish() }
        }
        isHandedOut = true
        return stream
    }

    /// Allow a restarted session to consume the stream again. The stream
    /// itself is kept (its continuation is nonisolated for `send`).
    func reset() {
        isHandedOut = false
        consumeTask?.cancel()
        consumeTask = nil
    }

    /// Start the single consumer translating events into RPC calls. Later
    /// calls are dropped with a log message.
    func startConsuming(with client: NvimClient = NvimClient()) {
        guard consumeTask == nil else {
            Log.input.error("Input event stream consumed more than once; dropping extra consumer")
            return
        }
        let stream = makeStream()
        consumeTask = Task {
            for await event in stream {
                switch event {
                case let .keys(keys):
                    do {
                        try await client.input(keys)
                    } catch {
                        Log.input.error("nvim_input failed: \(error.localizedDescription, privacy: .public)")
                    }
                case let .mouse(button, action, modifier, grid, row, col):
                    do {
                        try await client.inputMouse(
                            button: button,
                            action: action,
                            modifier: modifier,
                            grid: grid,
                            row: row,
                            col: col
                        )
                    } catch {
                        Log.input.error("nvim_input_mouse failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
    }
}
