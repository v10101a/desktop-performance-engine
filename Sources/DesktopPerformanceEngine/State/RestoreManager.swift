import AppKit

/// Snapshot of the pre-show desktop state. Phase 1 tracks the cursor location;
/// Phase 3 will add desktop icon positions and the wallpaper URL.
struct StateSnapshot {
    let cursorLocation: CGPoint   // CoreGraphics global space (top-left origin)

    static func capture() -> StateSnapshot {
        StateSnapshot(cursorLocation: cgCursorLocation())
    }

    /// NSEvent.mouseLocation is bottom-left; convert to CG's top-left origin.
    static func cgCursorLocation() -> CGPoint {
        let p = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: primaryHeight - p.y)
    }
}

/// Idempotent restore. Safe to call from the panic hotkey, the UI, and app
/// termination, and safe to call twice.
final class RestoreManager {
    private let windows: WindowManager
    private var snapshot: StateSnapshot?

    /// Set true once an effect actually moves the real cursor (Phase 2). Until then
    /// we never warp it on restore, so panic can't nudge a cursor we never touched.
    var cursorWasControlled = false

    init(windows: WindowManager) {
        self.windows = windows
    }

    func snapshotNow() {
        snapshot = StateSnapshot.capture()
    }

    func restore() {
        windows.closeAll()
        if cursorWasControlled, let snap = snapshot {
            CGWarpMouseCursorPosition(snap.cursorLocation)
        }
    }
}
