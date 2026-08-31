import Foundation

/// Beats → seconds, the one way.
///
/// Every event type that carries `durationBeats`/`durationSeconds` resolves them the
/// same way: beats win, seconds are the fallback, and `bpm` is floored at 1 so a
/// malformed document can't divide by zero.
enum Beats {
    static func seconds(_ beats: Double?, or seconds: Double?, bpm: Double) -> Double? {
        if let beats { return beats * 60.0 / max(1, bpm) }
        return seconds
    }
}

/// Fractional-rate pacing for effects that do a discrete thing at a per-beat rate —
/// place a photo, reveal a line, step a pattern.
///
/// Three behaviours, in one place:
///
/// 1. **The remainder carries.** Rates are fractional and the work is integral, so the
///    leftover credit persists across ticks. Without it a rate below one-per-tick would
///    round to nothing and the effect would never run.
/// 2. **Bursts are capped, and the excess is discarded rather than owed.** After a long
///    stall a two-second gap would otherwise try to do 40+ units at once; and if the
///    capped remainder were *carried*, the effect would spend the following ticks paying
///    off a debt from one hitch.
/// 3. **A seek is not elapsed time.** The playhead can jump backwards or far forwards,
///    which makes the elapsed-beat count meaningless. Those ticks charge nothing and
///    simply re-anchor.
struct Cadence {
    /// Units of work per beat.
    var ratePerBeat: Double
    /// Most units one tick may run. Picked per effect from what its downstream can
    /// actually absorb — the window server, Finder, a text layer.
    let burstCap: Int

    private var credit: Double = 0
    private var lastNow: Double

    /// Anything longer than this between ticks is a seek or a stall, not a frame.
    private static let maxTickInterval = 0.5

    init(ratePerBeat: Double, burstCap: Int, start: Double) {
        self.ratePerBeat = max(0.0001, ratePerBeat)
        self.burstCap = max(1, burstCap)
        self.lastNow = start
    }

    /// Units of work owed this tick. Returns 0 on a seek, a stall, or a tick too short
    /// to have earned one whole unit.
    mutating func step(now: Double, bpm: Double) -> Int {
        let dt = now - lastNow
        lastNow = now
        guard dt > 0, dt < Cadence.maxTickInterval else { return 0 }

        credit += dt * (bpm / 60.0) * ratePerBeat
        let n = min(Int(credit), burstCap)
        if n > 0 { credit -= Double(n) }
        // Discard when the *cap* bit, not when the leftover happens to be large:
        // keying off `n == burstCap` drops the unpayable debt while leaving the
        // ordinary sub-tick remainder to carry. (Testing `credit > burstCap` instead
        // leaves the refused work owed, and the effect runs flat out paying off one hitch.)
        if n == burstCap { credit = 0 }
        return n
    }

    /// Drop any owed work without advancing time — used when an effect changes phase
    /// (the photo wall dropping from its fill rate to its churn rate) and the credit
    /// earned at the old rate shouldn't spend at the new one.
    mutating func resetCredit() { credit = 0 }
}
