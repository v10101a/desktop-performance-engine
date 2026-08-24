import CoreVideo
import Foundation

/// Vsync-driven pump. Each tick hops to the main thread and invokes the handler,
/// where the scheduler reads the audio clock and fires due events.
///
/// CRITICAL: the tick is COALESCED — at most one callback is ever in flight. The
/// CVDisplayLink fires at display rate on its own thread; if we posted a
/// `DispatchQueue.main.async` every tick, they would queue unboundedly whenever main
/// is busy, and each would run progressively later against an ever-advancing clock
/// (a ~180 ms drift plateau). Skipping ticks while one is pending keeps the handler
/// always working against a current clock, so drift stays near one frame.
///
/// Uses CVDisplayLink (available on macOS 13+). On 14+ CADisplayLink is the modern
/// replacement; a later refactor can swap it in behind this same interface.
final class DisplayPump {
    private var link: CVDisplayLink?
    private var handler: (() -> Void)?
    private let lock = NSLock()
    private var pending = false

    func start(_ handler: @escaping () -> Void) {
        stop()
        self.handler = handler

        var created: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&created)
        guard let link = created else { return }
        self.link = link

        let context = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, { (_, _, _, _, _, userInfo) -> CVReturn in
            guard let userInfo = userInfo else { return kCVReturnSuccess }
            let pump = Unmanaged<DisplayPump>.fromOpaque(userInfo).takeUnretainedValue()

            // Coalesce: drop this tick if a handler run is still queued/executing.
            pump.lock.lock()
            if pump.pending { pump.lock.unlock(); return kCVReturnSuccess }
            pump.pending = true
            pump.lock.unlock()

            DispatchQueue.main.async {
                pump.handler?()
                pump.lock.lock()
                pump.pending = false
                pump.lock.unlock()
            }
            return kCVReturnSuccess
        }, context)

        CVDisplayLinkStart(link)
    }

    func stop() {
        if let link = link {
            CVDisplayLinkStop(link)
        }
        link = nil
        handler = nil
        lock.lock()
        pending = false
        lock.unlock()
    }
}
