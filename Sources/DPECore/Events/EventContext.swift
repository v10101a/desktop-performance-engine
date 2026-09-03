import AppKit

/// Bundles the effect executors and dispatches a resolved `EventAction` to the
/// right one.
final class EventContext {
    let windows: WindowManager
    let cursor: CursorController
    let icons: DesktopIconController
    let wallpaper: WallpaperController
    let photos: PhotoWallController
    let torus: GlassTorusController
    let probe: SystemProbeController
    let swarm: FileSwarmController
    let reboot: RebootController
    let oracle: OracleController
    let booth: PhotoBoothController
    let credits: CreditsController
    let otherApps: OtherAppsController
    let bricks: BrickBreakerController

    /// Document BPM, so beat-based durations resolve to seconds.
    var bpm: Double = 120

    init(windows: WindowManager, cursor: CursorController,
         icons: DesktopIconController, wallpaper: WallpaperController,
         photos: PhotoWallController, torus: GlassTorusController,
         probe: SystemProbeController, swarm: FileSwarmController,
         reboot: RebootController, oracle: OracleController,
         booth: PhotoBoothController, credits: CreditsController,
         otherApps: OtherAppsController, bricks: BrickBreakerController) {
        self.windows = windows
        self.cursor = cursor
        self.icons = icons
        self.wallpaper = wallpaper
        self.photos = photos
        self.torus = torus
        self.probe = probe
        self.swarm = swarm
        self.reboot = reboot
        self.oracle = oracle
        self.booth = booth
        self.credits = credits
        self.otherApps = otherApps
        self.bricks = bricks
    }

    /// Always invoked on the main thread (the pump hops to main before ticking).
    /// `now` is the current timeline position, so timed effects can anchor to it.
    func execute(_ action: EventAction, now: Double) {
        switch action {
        case .openWindow(let p):
            windows.openWindow(p, at: now)
        case .fakeDialog(let p):
            windows.openDialog(p)
        case .closeWindow(let p):
            windows.close(id: p.id, fadeSeconds: p.fadeSeconds ?? 0)
            bricks.stop(id: p.id)
            photos.stop(id: p.id)
            torus.stop(id: p.id)
            wallpaper.stopDesk(id: p.id)
            probe.stop(id: p.id)
            swarm.stop(id: p.id)
            reboot.stop(id: p.id)
            oracle.stop(id: p.id)
            booth.stop(id: p.id)
            credits.stop(id: p.id)
            otherApps.stop(id: p.id)
        case .moveWindow(let p):
            windows.beginMove(p, at: now, bpm: bpm)
        case .screenFlash(let p):
            windows.screenFlash(p)
        case .cursorPath(let p):
            cursor.begin(p, at: now, bpm: bpm)
        case .rearrangeIcons(let p):
            icons.rearrange(p)
        case .jiggle(let p):
            windows.beginJiggle(p, at: now, bpm: bpm)
        case .wallpaper(let p):
            wallpaper.set(p)
        case .sprite(let p):
            windows.beginSprite(p, at: now, bpm: bpm)
        case .cursorTrail(let p):
            windows.beginTrail(p, at: now, bpm: bpm)
        case .typeText(let p):
            windows.beginTyping(p, at: now, bpm: bpm)
        case .photoWall(let p):
            photos.begin(p, at: now, bpm: bpm)
        case .glassTorus(let p):
            torus.begin(p, at: now, bpm: bpm)
        case .deskWallpaper(let p):
            wallpaper.beginDesk(p, at: now, bpm: bpm)
        case .systemProbe(let p):
            probe.begin(p, at: now, bpm: bpm)
        case .fileSwarm(let p):
            swarm.begin(p, at: now, bpm: bpm)
        case .reboot(let p):
            reboot.begin(p, at: now, bpm: bpm)
        case .oracle(let p):
            oracle.begin(p, at: now, bpm: bpm)
        case .photoBooth(let p):
            booth.begin(p, at: now, bpm: bpm)
        case .credits(let p):
            credits.begin(p, at: now, bpm: bpm)
        case .brickBreaker(let p):
            bricks.start(p)
        case .hideOtherApps(let p):
            otherApps.begin(p)
        }
    }
}
