import CoreVideo

/// Trampoline so Core Video's display link can drive a Swift closure with
/// frame timestamps. `CVDisplayLink` (rather than `CADisplayLink`, whose
/// target/selector initializer is unavailable on macOS) fires at the actual
/// display refresh rate, up to 120 Hz on ProMotion panels.
final class DisplayLinkDriver {
    private let handler: (TimeInterval) -> Void
    private var link: CVDisplayLink?
    private var retainedContext: UnsafeMutableRawPointer?

    init(handler: @escaping (TimeInterval) -> Void) {
        self.handler = handler
    }

    var isRunning: Bool { link != nil }

    func start() {
        guard link == nil else { return }
        var raw: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&raw) == kCVReturnSuccess, let raw else { return }
        let context = Unmanaged.passRetained(self).toOpaque()
        guard CVDisplayLinkSetOutputCallback(raw, outputCallback, context) == kCVReturnSuccess else {
            Unmanaged<DisplayLinkDriver>.fromOpaque(context).release()
            return
        }
        link = raw
        retainedContext = context
        CVDisplayLinkStart(raw)
    }

    func stop() {
        guard let link else { return }
        CVDisplayLinkStop(link)
        self.link = nil
        if let retainedContext {
            Unmanaged<DisplayLinkDriver>.fromOpaque(retainedContext).release()
            self.retainedContext = nil
        }
    }

    deinit {
        stop()
    }

    fileprivate func handleTick(timestamp: TimeInterval) {
        handler(timestamp)
    }
}

private func outputCallback(
    _: CVDisplayLink,
    now: UnsafePointer<CVTimeStamp>,
    _: UnsafePointer<CVTimeStamp>,
    _: CVOptionFlags,
    _: UnsafeMutablePointer<CVOptionFlags>?,
    context: UnsafeMutableRawPointer?
) -> CVReturn {
    guard let context else { return kCVReturnError }
    let driver = Unmanaged<DisplayLinkDriver>.fromOpaque(context).takeUnretainedValue()
    let timestamp = TimeInterval(now.pointee.videoTime) / TimeInterval(now.pointee.videoTimeScale)
    driver.handleTick(timestamp: timestamp)
    return kCVReturnSuccess
}
