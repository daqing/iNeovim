import Foundation
import os

/// Bridges `redraw` notifications to a typed event stream for the render
/// layer. Runs off the main actor (fed from the RPC session's notification
/// dispatch) and supports a single consumer by contract.
actor RedrawEventStream {
    static let shared = RedrawEventStream()

    private let stream: AsyncStream<RedrawEvent>
    private let continuation: AsyncStream<RedrawEvent>.Continuation
    private var isSubscribed = false
    private var isHandedOut = false

    private init() {
        let (stream, continuation) = AsyncStream<RedrawEvent>.makeStream()
        self.stream = stream
        self.continuation = continuation
    }

    /// Register the `redraw` notification handler on the session; idempotent.
    func subscribe(to session: RPCSession = .shared) async {
        guard !isSubscribed else { return }
        isSubscribed = true
        await session.addNotificationHandler(for: "redraw") { [weak self] params in
            let events = RedrawEvent.parseNotification(params)
            Task { await self?.publish(events) }
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

    private func publish(_ events: [RedrawEvent]) {
        for event in events {
            continuation.yield(event)
        }
    }
}
