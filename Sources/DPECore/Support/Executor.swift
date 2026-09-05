import Foundation

/// What every effect executor owes the engine. `PerformanceEngine.executors` is the
/// single list every obligation (tick, seek, stop/panic teardown) iterates — a missed
/// entry would mean the panic hotkey doesn't clean that effect up. `bpm` is
/// deliberately not part of the protocol; tempo is set once at load.
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
extension RebootController: Executor {}
extension OracleController: Executor {}
extension PhotoBoothController: Executor {}
extension CreditsController: Executor {}
extension FileSwarmController: Executor {}
extension OtherAppsController: Executor {}
extension BrickBreakerController: Executor {}
extension SegSwarmController: Executor {}

/// `WallpaperController` owns the plain `wallpaper` event as well as `deskWallpaper`,
/// so its tick and teardown are named for the latter.
extension WallpaperController: Executor {
    func update(now: Double) { updateDesk(now: now) }
    func closeAll() { closeDesk() }
}

extension CursorController: Executor {
    func closeAll() { cancel() }
}

extension WindowManager: Executor {}
