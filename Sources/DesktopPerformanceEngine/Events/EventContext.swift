import AppKit

/// Bundles the effect executors and dispatches a resolved `EventAction` to the
/// right one. Phase 3 (desktop icons) plugs in here next.
final class EventContext {
    let windows: WindowManager
    let cursor: CursorController
    let icons: DesktopIconController
    let wallpaper: WallpaperController

    /// Document BPM, so beat-based durations resolve to seconds.
    var bpm: Double = 120

    init(windows: WindowManager, cursor: CursorController,
         icons: DesktopIconController, wallpaper: WallpaperController) {
        self.windows = windows
        self.cursor = cursor
        self.icons = icons
        self.wallpaper = wallpaper
    }

    /// Always invoked on the main thread (the pump hops to main before ticking).
    /// `now` is the current timeline position, so timed effects can anchor to it.
    func execute(_ action: EventAction, now: Double) {
        switch action {
        case .openWindow(let p):
            windows.openWindow(p)
        case .fakeDialog(let p):
            windows.openDialog(p)
        case .closeWindow(let p):
            windows.close(id: p.id)
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
        }
    }
}
