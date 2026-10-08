import Foundation

/// Drives cursor blink timing: `blinkwait` milliseconds of solid cursor,
/// then alternating `blinkon`/`blinkoff` milliseconds until restarted or
/// cancelled. All timing constants come from `mode_info_set`.
final class CursorBlinker {
    private var blinkTask: Task<Void, Never>?

    var isActive: Bool { blinkTask != nil }

    func restart(
        wait: Int,
        on: Int,
        off: Int,
        toggle: @escaping @MainActor (Bool) -> Void
    ) {
        cancel()
        blinkTask = Task { @MainActor in
            toggle(true)
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait) * NSEC_PER_MSEC)
            }
            var visible = true
            while !Task.isCancelled {
                visible.toggle()
                toggle(visible)
                let duration = visible ? on : off
                try? await Task.sleep(nanoseconds: UInt64(duration) * NSEC_PER_MSEC)
            }
        }
    }

    func cancel() {
        blinkTask?.cancel()
        blinkTask = nil
    }
}
