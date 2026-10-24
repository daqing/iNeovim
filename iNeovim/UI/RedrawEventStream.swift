import Foundation
import os

/// Bridges `redraw` notifications to a typed event stream for the render
/// layer. Runs off the main actor (fed from the RPC session's notification
/// dispatch) and supports a single consumer by contract.
actor RedrawEventStream {
    private var stream: AsyncStream<RedrawEvent>
    private var continuation: AsyncStream<RedrawEvent>.Continuation
    private var isSubscribed = false
    private var isHandedOut = false

    init() {
        let (stream, continuation) = AsyncStream<RedrawEvent>.makeStream()
        self.stream = stream
        self.continuation = continuation
    }

    /// Register the `redraw` notification handler on the session; idempotent.
    func subscribe(to session: RPCSession) async {
        guard !isSubscribed else { return }
        isSubscribed = true
        // The continuation is Sendable and its `yield` is thread-safe. Yielding
        // synchronously on the session's dispatch keeps redraw batches in
        // arrival order; spawning a Task per batch could reorder them.
        let sink = continuation
        await session.addNotificationHandler(for: "redraw") { params in
            for event in RedrawEvent.parseNotification(params) {
                sink.yield(event)
            }
        }
    }

    /// Hand out the event stream; only the first caller receives the live
    /// stream, later requests get a finished one.
    func makeStream() -> AsyncStream<RedrawEvent> {
        guard !isHandedOut else {
            Log.render.error("Redraw event stream requested more than once; dropping extra consumer")
            return AsyncStream { $0.finish() }
        }
        isHandedOut = true
        return stream
    }

    /// Drop the previous stream, subscription, and consumer hand-out so a
    /// restarted nvim can re-subscribe and the render layer can re-consume.
    func reset() {
        let (stream, continuation) = AsyncStream<RedrawEvent>.makeStream()
        self.stream = stream
        self.continuation = continuation
        isSubscribed = false
        isHandedOut = false
    }
}
