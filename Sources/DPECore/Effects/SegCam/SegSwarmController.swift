import AppKit
import CoreVideo

/// The imported segmenter, playing the desktop instead of a window.
///
/// `segcam` as a content kind puts the picture and its boxes inside one window. This is
/// segcam's *other* display: no picture at all, and every segment it finds becomes its
/// own titled window holding the frame it was cut from, pinned where it was detected.
/// Nothing is tracked between frames, so a thing that simply sits there mints a new
/// instance — and a new window — on every frame, and the screen fills.
///
/// Ends on `closeWindow` with the same `id`, like every other act that owns windows.
final class SegSwarmController {
    private var id: String?
    private var source: SegCamSource?
    private let engine = SegmentEngine()
    private let swarm = SegmentSwarm()
    private var screenFrame: CGRect = .zero
    /// A file source built and readied at load, waiting for the cue that names its path.
    private var prepared: (path: String, source: SegCamFile)?

    // MARK: - Prewarm

    /// What `begin` would otherwise build on the beat, built now: the pile's panels
    /// (hidden) and the clip's player, loaded and ready to play. `PerformanceEngine`
    /// calls this from `loadTimeline` and again before each play and after a seek, like
    /// the window pools; it is cheap when there is nothing left to do. Without it the
    /// first second of the act was the decoder spinning up and sixty real windows
    /// being created on the main thread — a stall, on the vocal pickup of all places.
    func prewarm(for events: [ResolvedEvent]) {
        for ev in events {
            if case .segSwarm(let p) = ev.action { prewarm(p) }
        }
    }

    func prewarm(_ p: SegSwarmParams) {
        swarm.prewarm(count: max(1, p.maxWindows ?? 60))
        guard p.window == nil, let path = p.path, prepared?.path != path else { return }
        let file = SegCamFile(url: URL(fileURLWithPath: resolveResourcePath(path)), hz: p.hz ?? 30)
        file.prepare()
        if file.isPrepared { prepared = (path, file) }
    }

    // MARK: - Lifecycle

    /// `sourceView` is the window `p.window` names, resolved by the caller — the
    /// controller has no business reaching into the window manager itself.
    func begin(_ p: SegSwarmParams, sourceView: NSView? = nil) {
        closeAll()
        id = p.id
        let screen = ScreenGeometry.screen(p.screen)
        screenFrame = screen.frame
        swarm.mirrored = p.mirror ?? (p.path == nil)
        swarm.maxBlobs = max(1, p.maxWindows ?? 60)
        swarm.level = p.level.map(WindowManager.level) ?? SegmentPanel.defaultLevel
        swarm.border = p.border.map { $0 == "none" ? nil : NSColor(hex: $0) }
            ?? SegmentPanel.defaultBorder

        var settings = SegmentSettings()
        switch p.mode {
        case "threshold":
            engine.mode = .threshold
            settings.thresholdLevel = Int((1 - min(1, Swift.max(0, p.intensity ?? 0.33))) * 255)
            settings.invertThreshold = p.invert ?? false
        case "face":
            engine.mode = .face
        default:
            // Motion is the default here and `face` is the default in the view, on
            // purpose: a window shows you a face being found, and a screen filling up
            // wants something that finds a lot.
            engine.mode = .motion
            settings.motionSensitivityFraction = p.intensity ?? 0.6
        }
        engine.settings = settings
        // The crops ARE the act — each window shows the piece of frame it was cut from.
        engine.wantsImage = true

        engine.onResult = { [weak self] result in
            guard let self else { return }
            self.swarm.update(segments: result.segments, crops: result.crops,
                              screenFrame: self.screenFrame)
        }

        if p.window != nil, let sourceView {
            source = SegCamWindowSource(view: sourceView, hz: p.windowHz ?? 15)
        } else if let named = p.window {
            NSLog("[DPE] segswarm: no window \(named) to segment")
            source = nil
        } else if let path = p.path {
            // The prepared player if the cue names its clip; otherwise the cold path,
            // which still works and still says so in the log when the file is missing.
            if let ready = prepared, ready.path == path {
                source = ready.source
                prepared = nil
            } else {
                source = SegCamFile(url: URL(fileURLWithPath: resolveResourcePath(path)),
                                    hz: p.hz ?? 30)
            }
        } else {
            source = SegCamCamera()
        }
        source?.onStatus = { message in
            if let message { NSLog("[DPE] segswarm: %@", message) }
        }
        source?.onFrame = { [weak self] buffer in self?.engine.ingest(buffer) }
        source?.start()
    }

    func stop(id which: String) {
        guard which == id else { return }
        closeAll()
    }

    /// Idempotent: stop, seek, quit and the panic key all land here, and every one of
    /// those windows belongs to us.
    func closeAll() {
        source?.stop()
        source = nil
        engine.onResult = nil
        swarm.clear()
        id = nil
    }

    /// The frames arrive from the source's own clock, as they do everywhere else here.
    func update(now: Double) {}

    // MARK: - Test seams

    var isRunning: Bool { source != nil }
    var windowCountForTesting: Int { swarm.panelCount }
    var sparePanelCountForTesting: Int { swarm.spareCount }
    var isPreparedForTesting: Bool { prepared != nil }
}
