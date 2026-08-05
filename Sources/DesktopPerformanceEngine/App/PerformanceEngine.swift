import AppKit

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
        // Build sprite/trail window pools now, while nothing is playing — the
        // window server digests dozens of new windows long before the clock runs.
        windows.prewarm(for: tl.events)
    }

    var loadedInfo: String {
        guard let tl = timeline else { return "No timeline loaded" }
        return "\(tl.events.count) events · \(String(format: "%.1f", tl.duration))s · \(Int(tl.meta.bpm)) BPM"
    }

    var usingClickTrack: Bool { clock.usingSynthesizedClick }

    var duration: Double { timeline?.duration ?? 0 }

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
        lastFxUpdate = -1.0

        let audioURL = resolveAudioURL(tl.meta.audioFile)
        do {
            try clock.prepare(audioURL: audioURL,
                              fallbackBPM: tl.meta.bpm,
                              fallbackDuration: tl.duration + 4)
        } catch {
            NSLog("[DPE] audio prepare failed: \(error)")
        }

        // Align what the eye sees with what the ear hears.
        offsetCorrection = (tl.meta.timelineLatency ?? 0) - clock.outputLatency

        clock.play()
        isPlaying = true
        pump.start { [weak self] in self?.step() }
    }

    private func step() {
        guard isPlaying, let raw = clock.currentTime() else { return }
        let now = raw + offsetCorrection
        // Fire events every tick (prompt), but throttle the per-frame effect updates
        // (window setFrame / cursor warp) to ~72 Hz so a 120 Hz ProMotion display
        // doesn't double the window-server traffic for no visible benefit.
        scheduler.tick(now: now, ctx: context)
        if now - lastFxUpdate >= 1.0 / 72.0 {
            cursor.update(now: now)
            windows.update(now: now)
            lastFxUpdate = now
        }
        onTick?(now)
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

    private func resolveAudioURL(_ name: String?) -> URL? {
        guard let name = name else { return nil }
        let url: URL
        if name.hasPrefix("/") {
            url = URL(fileURLWithPath: name)
        } else if let dir = timelineDir {
            url = dir.appendingPathComponent(name)
        } else {
            url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(name)
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
