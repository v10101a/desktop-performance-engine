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
    private let photos = PhotoWallController()
    private let torus = GlassTorusController()
    private let probe = SystemProbeController()
    private let swarm = FileSwarmController()
    private let reboot = RebootController()
    private let oracle = OracleController()
    private let booth = PhotoBoothController()
    private let credits = CreditsController()
    private let context: EventContext
    private let restore: RestoreManager
    private let panic = PanicController()

    /// Every executor, once. The tick, `seek` and `stopAndRestore` all iterate this
    /// rather than naming each one — see the `Executor` protocol for why.
    private var executors: [Executor] {
        [windows, cursor, photos, torus, probe, wallpaper, swarm, reboot, oracle, booth, credits]
    }

    /// True once the track has ended under a held end card: the show is paused there,
    /// not stopped, until the viewer dismisses it.
    private(set) var holdingAtEnd = false

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
    /// Held mid-show: the timeline stops advancing but nothing is torn down.
    /// Only ever true while `isPlaying`.
    private(set) var isPaused = false

    /// Master output level, 0…1. Takes effect immediately, playing or not, and persists
    /// across stop/play because the clock re-applies it whenever it re-prepares.
    var volume: Float {
        get { clock.volume }
        set { clock.volume = newValue }
    }

    /// Reports the effective timeline position each pump tick (for the UI).
    var onTick: ((Double) -> Void)?
    /// Fires when the show stops and the desktop has been restored.
    var onFinished: (() -> Void)?
    /// Fires when the end card's outro has run to the end of its boot bar. The app quits
    /// from here; nothing else in the show ends the process on its own.
    var onOutroFinished: (() -> Void)?

    init() {
        context = EventContext(windows: windows, cursor: cursor, icons: icons,
                               wallpaper: wallpaper, photos: photos, torus: torus,
                               probe: probe, swarm: swarm, reboot: reboot, oracle: oracle,
                               booth: booth, credits: credits)
        restore = RestoreManager(windows: windows)
        credits.onDismiss = { [weak self] in
            self?.stopAndRestore()
        }
        // The end card's outro finishes by quitting. `applicationWillTerminate` calls
        // `stopAndRestore`, so the desktop is put back before the process goes —
        // quitting is not a way to skip the reversibility gate.
        credits.onQuit = { [weak self] in
            self?.onOutroFinished?()
        }
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
        photos.bpm = tl.meta.bpm
        torus.bpm = tl.meta.bpm
        probe.bpm = tl.meta.bpm
        swarm.bpm = tl.meta.bpm
        reboot.bpm = tl.meta.bpm
        oracle.bpm = tl.meta.bpm
        booth.bpm = tl.meta.bpm
        credits.bpm = tl.meta.bpm
        // Writes real files, so it is opt-in per timeline like the wallpaper swap.
        swarm.enabled = tl.meta.allowDesktopFiles ?? false
        wallpaper.baseDir = timelineDir
        wallpaper.enabled = tl.meta.allowWallpaper ?? false
        audioDuration = PerformanceEngine.probeAudioDuration(resolveAudioURL(tl.meta.audioFile))
        startPosition = 0
        // Build sprite/trail window pools now, while nothing is playing — the
        // window server digests dozens of new windows long before the clock runs.
        windows.prewarm(for: tl.events)
        // Walk the disk for photos now — a photoWall event fires on a beat and a cold
        // scan takes seconds, so the index has to be warm before the clock runs.
        photos.prewarm(for: tl.events)
        // Configure the camera session now; device discovery is far too slow for a tick.
        booth.prewarm(for: tl.events)
        credits.prewarm(for: tl.events)
    }

    /// The resolved events, for whoever needs to know what the show is going to ask
    /// for before it starts (`Permissions.preflight`).
    var events: [ResolvedEvent] { timeline?.events ?? [] }

    var loadedInfo: String {
        guard let tl = timeline else { return "No timeline loaded" }
        return "\(tl.events.count) events · \(String(format: "%.1f", tl.duration))s · \(Int(tl.meta.bpm)) BPM"
    }

    var usingClickTrack: Bool { clock.usingSynthesizedClick }

    /// How much the show currently has on screen — the readout for a paused frame.
    var liveWindowCount: Int { windows.count }

    /// Badge every live window with its timeline id and open time. An authoring
    /// overlay for telling a stack of near-identical windows apart; not in the piece.
    func setInspecting(_ on: Bool) { windows.setInspecting(on) }
    var isInspecting: Bool { windows.inspecting }
    /// Read-back of the inspect overlay + freeze state, for `--test-pause`.
    var inspectSummary: [String] { windows.inspectSummary }
    /// Live-sketch frame counts, for `--test-pause`.
    func readHydraTicks(_ done: @escaping ([String]) -> Void) { windows.readHydraTicks(done) }

    /// Where the backing track actually resolved to, or nil if nothing was found.
    /// Used by `--check` to prove a packaged .app is self-contained.
    var resolvedAudioPath: String? {
        resolveAudioURL(timeline?.meta.audioFile)?.path
    }

    /// Whole-piece length: the longer of the event timeline and the backing track.
    var duration: Double { max(timeline?.duration ?? 0, audioDuration) }

    var bpm: Double { timeline?.meta.bpm ?? 120 }

    /// Structural markers from track analysis (for the scrubber). Empty if none.
    var markers: [Marker] { timeline?.meta.markers ?? [] }

    /// The marker at or before `t` (the section the playhead is currently in), if any.
    func currentMarker(at t: Double) -> Marker? {
        markers.last { $0.t <= t + 0.05 }
    }

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
        photos.prewarm(for: tl.events)
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
        isPaused = false
        pump.start { [weak self] in self?.step() }
    }

    /// Hold the show exactly where it is. The playhead stops, the audio holds, and
    /// every window the show has opened STAYS ON SCREEN — the desktop is not restored
    /// and nothing is torn down, so a frame can be looked at and judged. This is the
    /// opposite of `stopAndRestore()`, which is still the way out.
    func pause() {
        guard isPlaying, !isPaused else { return }
        isPaused = true
        pump.stop()
        clock.pause()
        windows.setAnimationsPaused(true)
        onTick?(startPosition)
    }

    func resume() {
        guard isPlaying, isPaused else { return }
        isPaused = false
        windows.setAnimationsPaused(false)
        clock.resume()
        lastFxUpdate = -1.0       // don't skip the first frame's effect update
        pump.start { [weak self] in self?.step() }
    }

    private func step() {
        guard isPlaying, let raw = clock.currentTime() else { return }
        let now = raw + offsetCorrection

        // End of the piece: stop, restore, rewind the playhead to the top — unless the
        // end card asked to hold, in which case the show pauses on it and stays there
        // until the card is dismissed (its button, Stop, or panic).
        if now >= duration {
            if credits.isHolding {
                if !holdingAtEnd { NSLog("[DPE] end of track — holding on the end card") }
                holdingAtEnd = true
                pause()
                return
            }
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
            for executor in executors { executor.update(now: now) }
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
            for executor in executors { executor.closeAll() }
            windows.prewarm(for: tl.events)
            scheduler.seek(to: t)
            clock.seek(to: t, playing: !isPaused)   // scrubbing while paused stays paused
            lastFxUpdate = -1.0
        }
        onTick?(t)
    }

    /// Idempotent: safe to call from the panic hotkey, the UI, and app termination.
    func stopAndRestore() {
        let wasPlaying = isPlaying
        isPlaying = false
        isPaused = false
        pump.stop()
        clock.stop()
        for executor in executors { executor.closeAll() }
        // The booth's photo is for the credits and nothing after them.
        PhotoBoothStore.shared.discard()
        if holdingAtEnd {
            holdingAtEnd = false
            startPosition = 0
            onTick?(0)
        }
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
