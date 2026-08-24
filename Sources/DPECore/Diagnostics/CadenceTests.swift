import Foundation

/// The pacing every clock-driven effect shares. Previously three copy-pasted
/// accumulators, verified by reading NSLog.
enum CadenceTests {
    static func run(_ t: TestHarness) {
        t.suite("Cadence") { t in

            // 72 ticks of 1/72 s at 120 BPM and 20/beat is 40 units.
            //
            // It lands on 39, not 40: 1/72 has no exact binary representation, so the
            // accumulation ends a hair under and the last unit falls on the next tick.
            // The tolerance is the honest assertion; the next check is the one that
            // matters — that this is a fixed offset, not a drift that compounds.
            var c = Cadence(ratePerBeat: 20, burstCap: 12, start: 0)
            var total = 0
            for i in 1...72 { total += c.step(now: Double(i) / 72.0, bpm: 120) }
            t.near(total, 40, 1, "20/beat at 120bpm over 1s")

            c = Cadence(ratePerBeat: 20, burstCap: 12, start: 0)
            total = 0
            for i in 1...720 { total += c.step(now: Double(i) / 72.0, bpm: 120) }
            t.near(total, 400, 1,
                   "error must stay bounded over 10s (a per-second loss would land near 390)")

            // A rate slower than one per tick must still fire; rounding each tick
            // independently would floor it to zero forever.
            c = Cadence(ratePerBeat: 0.5, burstCap: 12, start: 0)
            total = 0
            for i in 1...144 { total += c.step(now: Double(i) / 72.0, bpm: 120) }
            t.near(total, 2, 1, "sub-tick rate still fires")

            // The cap and the seek guard cover different sized gaps, and the boundary
            // matters: anything from 0.5s up is a seek and charges nothing at all, so
            // the cap only ever bites on a gap *under* half a second. At 20/beat and
            // 120bpm a 0.49s hitch earns ~19.6 units, which the cap trims to 12.
            c = Cadence(ratePerBeat: 20, burstCap: 12, start: 0)
            t.equal(c.step(now: 0.49, bpm: 120), 12, "a sub-seek hitch is capped at 12")

            // The capped excess is discarded, not owed — otherwise one hitch makes the
            // effect run at the cap for several ticks paying off a debt.
            t.equal(c.step(now: 0.49 + 1.0 / 72.0, bpm: 120), 0,
                    "the tick after a capped burst owes only what it earned")

            c = Cadence(ratePerBeat: 20, burstCap: 12, start: 10)
            t.equal(c.step(now: 2.0, bpm: 120), 0, "seeking backwards charges nothing")

            c = Cadence(ratePerBeat: 20, burstCap: 12, start: 0)
            t.equal(c.step(now: 30.0, bpm: 120), 0, "a 30s jump is a seek, not a frame")

            // ...and it re-anchors rather than staying stuck.
            total = 0
            for i in 1...72 { total += c.step(now: 30.0 + Double(i) / 72.0, bpm: 120) }
            t.near(total, 40, 1, "resumes normally after a seek")

            func work(bpm: Double) -> Int {
                var c = Cadence(ratePerBeat: 20, burstCap: 100, start: 0)
                var n = 0
                for i in 1...72 { n += c.step(now: Double(i) / 72.0, bpm: bpm) }
                return n
            }
            t.near(work(bpm: 240), 2 * work(bpm: 120), 1, "tempo scales the rate")

            // The photo wall changes rate when the screen fills; credit earned at the
            // fill rate must not spend at the churn rate.
            c = Cadence(ratePerBeat: 20, burstCap: 100, start: 0)
            _ = c.step(now: 0.4, bpm: 120)
            c.resetCredit()
            c.ratePerBeat = 2.7
            t.equal(c.step(now: 0.4 + 1.0 / 72.0, bpm: 120), 0, "resetCredit drops owed work")
        }

        t.suite("Volume") { t in
            // Level must clamp: the slider can't send out of range, but a timeline or a
            // future caller could.
            let clock = AudioClock()
            clock.volume = 0.5
            t.near(Double(clock.volume), 0.5, 1e-6, "volume round-trips")
            clock.volume = 4
            t.near(Double(clock.volume), 1.0, 1e-6, "volume clamps above 1")
            clock.volume = -3
            t.near(Double(clock.volume), 0.0, 1e-6, "volume clamps below 0")

            // The real regression risk: prepare() tears the engine down and rebuilds the
            // graph on every play, so a level set before the first show has to survive
            // into the next one.
            clock.volume = 0.42
            try? clock.prepare(audioURL: nil, fallbackBPM: 120, fallbackDuration: 2)
            t.near(Double(clock.volume), 0.42, 1e-6, "volume survives prepare()")

            // Gain must not touch the clock: the show reads the player node's sample
            // time, so muting is a legitimate way to rehearse the visuals. Stopped, the
            // clock reports nothing whatever the level is.
            clock.volume = 0
            t.expect(clock.currentTime() == nil, "a stopped clock reports no time at 0 volume")
            clock.volume = 1
            t.expect(clock.currentTime() == nil, "a stopped clock reports no time at full volume")
            clock.stop()
        }

        t.suite("Beats") { t in
            t.near(Beats.seconds(4, or: 99, bpm: 120) ?? -1, 2.0, 1e-9, "beats win over seconds")
            t.near(Beats.seconds(nil, or: 99, bpm: 120) ?? -1, 99, 1e-9, "seconds are the fallback")
            t.expect(Beats.seconds(nil, or: nil, bpm: 120) == nil, "neither given is nil")
            // A malformed document must not divide by zero.
            t.near(Beats.seconds(1, or: nil, bpm: 0) ?? -1, 60.0, 1e-9, "bpm 0 is floored to 1")
        }
    }
}
