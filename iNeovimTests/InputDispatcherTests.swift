import XCTest
@testable import iNeovim

@MainActor
final class InputDispatcherTests: XCTestCase {
    func testEventsRoundTripThroughTheSingleHandoutStream() async {
        let dispatcher = InputDispatcher()
        let stream = await dispatcher.makeStream()

        dispatcher.send(.keys("i"))
        dispatcher.send(.mouse(button: "left", action: "press", modifier: "", grid: 1, row: 2, col: 3))

        var received: [InputEvent] = []
        for await event in stream {
            received.append(event)
            if received.count == 2 { break }
        }
        XCTAssertEqual(received, [
            .keys("i"),
            .mouse(button: "left", action: "press", modifier: "", grid: 1, row: 2, col: 3),
        ])
    }

    func testSecondHandoutGetsAFinishedStream() async {
        let dispatcher = InputDispatcher()
        _ = await dispatcher.makeStream()
        let second = await dispatcher.makeStream()
        var iterator = second.makeAsyncIterator()
        let element = await iterator.next()
        XCTAssertNil(element)
    }
}
