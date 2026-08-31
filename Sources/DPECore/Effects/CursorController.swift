import AppKit
import CoreGraphics

/// Choreographs the real system cursor along authored paths, driven off the audio
/// clock so motion is take-repeatable.
///
/// Two move modes:
///  - `"warp"` (default): `CGWarpMouseCursorPosition` — instant, needs NO permission.
///  - `"post"`: synthetic `.mouseMoved` HID events — other apps see hover states,
///    but this requires **Accessibility** permission or it silently no-ops.
///
/// Coordinates are global display points, top-left origin — the same space as window
/// frames and CoreGraphics, so authored points map straight through.
final class CursorController {
    /// Fired the first time a path actually starts controlling the cursor, so the
    /// RestoreManager knows to warp it home on restore.
    var onControlStarted: (() -> Void)?

    /// When true, log sampled positions (used by the `--autoplay` self-test).
    var logSamples = false

    private struct ActivePath {
        let points: [CGPoint]
        let start: Double
        let duration: Double
        let easing: (Double) -> Double
        let catmullRom: Bool
        let mode: String
    }

    private var active: ActivePath?
    private var sampleCounter = 0

    func begin(_ p: CursorPathParams, at now: Double, bpm: Double) {
        // Authored points map through the same canvas scale as window frames.
        let (sx, sy) = ScreenGeometry.scale(for: ScreenGeometry.screen(nil))
        let pts = p.points.compactMap {
            $0.count >= 2 ? CGPoint(x: $0[0] * sx, y: $0[1] * sy) : nil
        }
        guard !pts.isEmpty else { return }
        let duration = p.durationSeconds ?? ((p.durationBeats ?? 1) * 60.0 / bpm)
        let catmull = (p.path ?? "linear") == "catmullRom" && pts.count >= 3
        active = ActivePath(points: pts,
                            start: now,
                            duration: max(0.01, duration),
                            easing: easingCurve(p.easing),
                            catmullRom: catmull,
                            mode: p.mode ?? "warp")
        sampleCounter = 0
        onControlStarted?()
    }

    /// Called every pump tick with the current timeline position.
    func update(now: Double) {
        guard let a = active else { return }
        let u = min(1.0, (now - a.start) / a.duration)
        let eased = a.easing(u)
        let pos = CursorController.sample(a.points, eased, catmullRom: a.catmullRom)
        move(to: pos, mode: a.mode)

        if logSamples {
            sampleCounter += 1
            if sampleCounter % 8 == 0 || u >= 1.0 {
                let readback = CGEvent(source: nil)?.location ?? .zero
                NSLog(String(format: "[DPE] cursor u=%.2f target=(%.0f,%.0f) actual=(%.0f,%.0f)",
                             u, pos.x, pos.y, readback.x, readback.y))
            }
        }

        if u >= 1.0 { active = nil }
    }

    /// Drop any in-flight path (called on stop/panic before restore warps home).
    func cancel() { active = nil }

    // MARK: - Movement

    private func move(to p: CGPoint, mode: String) {
        if mode == "post" {
            if let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                   mouseCursorPosition: p, mouseButton: .left) {
                event.post(tap: .cghidEventTap)
            }
        } else {
            CGWarpMouseCursorPosition(p)
        }
    }

    // MARK: - Path sampling

    private static func sample(_ pts: [CGPoint], _ u: Double, catmullRom: Bool) -> CGPoint {
        if pts.count == 1 { return pts[0] }
        let n = pts.count
        let scaled = min(max(u, 0), 1) * Double(n - 1)
        let i = min(Int(scaled), n - 2)
        let localT = scaled - Double(i)
        if catmullRom {
            let p0 = pts[max(i - 1, 0)]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = pts[min(i + 2, n - 1)]
            return catmull(p0, p1, p2, p3, localT)
        }
        return lerp(pts[i], pts[i + 1], localT)
    }

    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    private static func catmull(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint,
                                _ t: Double) -> CGPoint {
        let t2 = t * t, t3 = t2 * t
        func comp(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
            0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
        }
        return CGPoint(x: comp(p0.x, p1.x, p2.x, p3.x), y: comp(p0.y, p1.y, p2.y, p3.y))
    }

}
