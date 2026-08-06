import AppKit
import AVFoundation

/// Glue that wires the audio clock, display pump, scheduler, effect executors,
/// state snapshot/restore, and the global panic hotkey together.
final class PerformanceEngine {
    private let clock = AudioClock()
    private let pump = DisplayPump()
    private let scheduler = Scheduler()
    private let windows = WindowManager()
    private let cursor = CursorController()
    private let icons = DesktopIconController()
    private let wallpaper = WallpaperController()
    private let context: EventContext
    private let restore: RestoreManager
    private let panic = PanicController()

    private var timeline: LoadedTimeline?
    private var timelineDir: URL?
    private var offsetCorrection: Double = 0
    private var iconsArmed = false
    private var wallpaperArmed = false
    private var lastFxUpdate = -1.0
    private var audioDuration: Double = 0
    /// Where the next play() starts, and where the scrubber sits. Tracks the playhead
    /// while playing, so Stop leaves it in place (resume) and dragging it seeks.
    private(set) var startPosition: Double = 0

    private(set) var isPlaying = false

    /// Reports the effective timeline position each pump tick (for the UI).
    var onTick: ((Double) -> Void)?
    /// Fires when the show stops and the desktop has been restored.
    var onFinished: (() -> Void)?

    init() {
        context = EventContext(windows: windows, cursor: cursor, icons: icons, wallpaper: wallpaper)
        restore = RestoreManager(windows: windows)
        cursor.onControlStarted = { [weak self] in
            self?.restore.cursorWasControlled = true
        }
        panic.onPanic = { [weak self] in
            self?.stopAndRestore()
        }
        panic.install()
    }

    // MARK: - Loading

    func loadTimeline(at url: URL) throws {
        let tl = try TimelineLoader.load(from: url)
        timeline = tl
        timelineDir = url.deletingLastPathComponent()
        scheduler.load(tl.events)
        windows.bpm = tl.meta.bpm
        context.bpm = tl.meta.bpm
        wallpaper.baseDir = timelineDir
        wallpaper.enabled = tl.meta.allowWallpaper ?? false
        audioDuration = PerformanceEngine.probeAudioDuration(resolveAudioURL(tl.meta.audioFile))
        startPosition = 0
        // Build sprite/trail window pools now, while nothing is playing — the
        // window server digests dozens of new windows long before the clock runs.
        windows.prewarm(for: tl.events)
    }

    var loadedInfo: String {
        guard let tl = timeline else { return "No timeline loaded" }
        return "\(tl.events.count) events · \(String(format: "%.1f", tl.duration))s · \(Int(tl.meta.bpm)) BPM"
    }

    var usingClickTrack: Bool { clock.usingSynthesizedClick }

    /// Whole-piece length: the longer of the event timeline and the backing track.
    var duration: Double { max(timeline?.duration ?? 0, audioDuration) }

    var bpm: Double { timeline?.meta.bpm ?? 120 }

    /// Enable in-memory drift measurement (used by the `--autoplay` self-test).
    func enableFiringLog() {
        scheduler.logFiring = true
    }

    // MARK: - Transport

    func play() {
        guard let tl = timeline, !isPlaying else { return }

        restore.snapshotNow()
        // Rebuild any pools a previous run consumed (no-op on first play; a panic
        // wipe clears them). Still before the clock starts, so no mid-show stall.
        windows.prewarm(for: tl.events)
        // Only touch (and prompt for) desktop icons if the show actually uses them.
        iconsArmed = tl.usesIcons
        if iconsArmed { icons.snapshot() }
        wallpaperArmed = tl.usesWallpaper && wallpaper.enabled
        if wallpaperArmed { wallpaper.snapshot() }
        scheduler.reset()
        scheduler.seek(to: startPosition)
        lastFxUpdate = -1.0

        let audioURL = resolveAudioURL(tl.meta.audioFile)
        do {
            try clock.prepare(audioURL: audioURL,
                              fallbackBPM: tl.meta.bpm,
                              fallbackDuration: max(tl.duration, audioDuration) + 4)
        } catch {
            NSLog("[DPE] audio prepare failed: \(error)")
        }

        NSLog(String(format: "[DPE] audio source: %@ · %.1fs",
                     clock.usingSynthesizedClick ? "synth click track" : (tl.meta.audioFile ?? "?"),
                     audioDuration))

        // Align what the eye sees with what the ear hears.
        offsetCorrection = (tl.meta.timelineLatency ?? 0) - clock.outputLatency

        clock.play(from: startPosition)
        isPlaying = true
        pump.start { [weak self] in self?.step() }
    }

    private func step() {
        guard isPlaying, let raw = clock.currentTime() else { return }
        let now = raw + offsetCorrection

        // End of the piece: stop, restore, rewind the playhead to the top.
        if now >= duration {
            startPosition = 0
            stopAndRestore()
            onTick?(0)
            return
        }

        // Fire events every tick (prompt), but throttle the per-frame effect updates
        // (window setFrame / cursor warp) to ~72 Hz so a 120 Hz ProMotion display
        // doesn't double the window-server traffic for no visible benefit.
        scheduler.tick(now: now, ctx: context)
        if now - lastFxUpdate >= 1.0 / 72.0 {
            cursor.update(now: now)
            windows.update(now: now)
            lastFxUpdate = now
        }
        startPosition = now       // playhead tracks; Stop leaves it here to resume
        onTick?(now)
    }

    /// Move the playhead. While playing, seeks audio + visuals live (clean slate at
    /// the new position); while stopped, just sets where the next play() begins.
    func seek(to target: Double) {
        guard let tl = timeline else { return }
        let t = max(0, min(target, duration))
        startPosition = t
        if isPlaying {
            cursor.cancel()
            windows.closeAll()
            windows.prewarm(for: tl.events)
            scheduler.seek(to: t)
            clock.seek(to: t, playing: true)
            lastFxUpdate = -1.0
        }
        onTick?(t)
    }

    /// Idempotent: safe to call from the panic hotkey, the UI, and app termination.
    func stopAndRestore() {
        let wasPlaying = isPlaying
        isPlaying = false
        pump.stop()
        clock.stop()
        cursor.cancel()
        restore.restore()
        if iconsArmed { icons.restore() }
        if wallpaperArmed { wallpaper.restore() }
        if scheduler.logFiring { NSLog("[DPE] \(scheduler.driftSummary)") }
        NSLog("[DPE] stopAndRestore — windows remaining: \(windows.count)")
        if wasPlaying { onFinished?() }
    }

    // MARK: - Helpers

    /// Locate the backing track. Handles an absolute path, or a repo-relative path
    /// like "assets/track.wav" resolved against the timeline dir, the working dir, and
    /// parents of the app/executable — so it works from `swift run` (cwd = repo) and
    /// from the packaged .app (which lives under the repo tree at build/…).
    private func resolveAudioURL(_ name: String?) -> URL? {
        guard let name = name, !name.isEmpty else { return nil }
        let fm = FileManager.default
        if name.hasPrefix("/") {
            return fm.fileExists(atPath: name) ? URL(fileURLWithPath: name) : nil
        }
        var bases: [URL] = []
        if let dir = timelineDir { bases.append(dir) }
        bases.append(URL(fileURLWithPath: fm.currentDirectoryPath))
        if let res = Bundle.main.resourceURL { bases.append(res) }  // embedded copy in the .app
        var walk = Bundle.main.bundleURL
        for _ in 0..<7 { bases.append(walk); walk = walk.deletingLastPathComponent() }

        let basename = (name as NSString).lastPathComponent
        for base in bases {
            for cand in [base.appendingPathComponent(name),                                   // <base>/assets/track.mp3
                         base.appendingPathComponent("assets").appendingPathComponent(basename), // <base>/assets/track.mp3
                         base.appendingPathComponent(basename)] {                              // <base>/track.mp3 (bundled flat)
                if fm.fileExists(atPath: cand.path) { return cand }
            }
        }
        return nil
    }

    private static func probeAudioDuration(_ url: URL?) -> Double {
        guard let url = url, let f = try? AVAudioFile(forReading: url) else { return 0 }
        let sr = f.processingFormat.sampleRate
        return sr > 0 ? Double(f.length) / sr : 0
    }
}
