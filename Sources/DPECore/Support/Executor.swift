import Foundation

/// What every effect executor owes the engine.
///
/// This exists because the three obligations below used to be three hand-maintained
/// lists in `PerformanceEngine` — one in the tick, one in `seek`, one in
/// `stopAndRestore`. Adding an executor meant remembering all three, and nothing caught
/// a miss: forget the seek list and a seek leaves the effect running over the new
/// position; forget the teardown list and **the panic hotkey doesn't clean it up**,
/// which for `fileSwarm` means files left on the Desktop.
///
/// With one array those failure modes stop being possible — `executors` is the single
/// list, and every obligation iterates it.
/// Note what is deliberately *not* here: `bpm`. Two executors take tempo per call
/// rather than storing it, and adding a property they'd never read would be the same
/// unused state this refactor is removing. Tempo is also set once at load in one place,
/// where a miss is immediately visible as a wrong-tempo show rather than silent.
protocol Executor: AnyObject {
    /// Advance to the timeline position `now`. Called on the main thread from the
    /// display pump, throttled to ~72 Hz.
    func update(now: Double)

    /// Stop everything and put back whatever was changed. **Must be idempotent** — the
    /// panic hotkey, the UI, seek, and app termination all land here, sometimes twice.
    func closeAll()
}

extension PhotoWallController: Executor {}
extension GlassTorusController: Executor {}
extension SystemProbeController: Executor {}
extension FileSwarmController: Executor {}

/// `WallpaperController` predates the protocol and owns the plain `wallpaper` event as
/// well as `deskWallpaper`, so its tick and teardown are named for the latter.
extension WallpaperController: Executor {
    func update(now: Double) { updateDesk(now: now) }
    func closeAll() { closeDesk() }
}

/// `CursorController` and `WindowManager` already match the shape; conforming them
/// means the engine's loops cover every executor rather than most of them.
extension CursorController: Executor {
    func closeAll() { cancel() }
}

extension WindowManager: Executor {}
