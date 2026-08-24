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

    /// Document BPM, so beat-based durations resolve to seconds.
    var bpm: Double = 120

    init(windows: WindowManager, cursor: CursorController,
         icons: DesktopIconController, wallpaper: WallpaperController,
         photos: PhotoWallController, torus: GlassTorusController,
         probe: SystemProbeController, swarm: FileSwarmController) {
        self.windows = windows
        self.cursor = cursor
        self.icons = icons
        self.wallpaper = wallpaper
        self.photos = photos
        self.torus = torus
        self.probe = probe
        self.swarm = swarm
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
            windows.close(id: p.id)
            photos.stop(id: p.id)
            torus.stop(id: p.id)
            wallpaper.stopDesk(id: p.id)
            probe.stop(id: p.id)
            swarm.stop(id: p.id)
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
        }
    }
}
