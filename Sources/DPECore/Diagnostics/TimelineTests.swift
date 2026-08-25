import Foundation

/// The document format. Every event is authored as JSON by a generator, so a decoder
/// that silently rejects a type is a show that dies at the moment it fires.
enum TimelineTests {
    private static func decode(_ json: String) -> TimelineEvent? {
        try? JSONDecoder().decode(TimelineEvent.self, from: Data(json.utf8))
    }

    static func run(_ t: TestHarness) {
        t.suite("Timeline") { t in

            // The EventAction enum, the decoder table and `typeName` are three lists
            // that must agree. This is what makes drift between them fail here rather
            // than at showtime.
            t.equal(TimelineEvent.catalogIsConsistent(), [],
                    "every type string must decode to the case reporting that name")

            t.equal(TimelineEvent.registeredTypeNames,
                    ["closeWindow", "credits", "cursorPath", "cursorTrail", "deskWallpaper",
                     "fakeDialog", "fileSwarm", "glassTorus", "jiggle", "moveWindow",
                     "openWindow", "oracle", "photoBooth", "photoWall", "rearrangeIcons",
                     "reboot", "screenFlash", "sprite", "systemProbe", "typeText",
                     "wallpaper"],
                    "registered event types")

            // --- the restructured show's new acts ---

            if let ev = decode(#"{"beat":4,"type":"reboot","params":{"id":"boot","durationBeats":12,"delayBeats":2}}"#),
               case .reboot(let p) = ev.action {
                t.equal(p.durationBeats ?? -1, 12, "reboot durationBeats")
                t.equal(p.delayBeats ?? -1, 2, "reboot delayBeats")
            } else { t.expect(false, "reboot failed to decode") }

            if let ev = decode(#"{"beat":4,"type":"oracle","params":{"id":"o","answers":["yes","no"],"answerBeats":6}}"#),
               case .oracle(let p) = ev.action {
                t.equal(p.answers ?? [], ["yes", "no"], "oracle answers")
                t.equal(p.answerBeats ?? -1, 6, "oracle answerBeats")
                t.equal(OracleController.answer(to: "will you", from: p.answers ?? [], fallback: 0),
                        OracleController.answer(to: "will you", from: p.answers ?? [], fallback: 1),
                        "the same question always gets the same answer")
            } else { t.expect(false, "oracle failed to decode") }

            if let ev = decode(#"{"beat":4,"type":"photoBooth","params":{"id":"b","durationBeats":16,"count":3,"stepBeats":4}}"#),
               case .photoBooth(let p) = ev.action {
                t.equal(p.count ?? -1, 3, "photoBooth count")
                let plan = PhotoBoothController.Plan(p, bpm: 120)
                t.equal(plan.numberAt.count, 3, "photoBooth shows three numbers")
                t.equal(plan.numberAt.first ?? -1, 2.0, "3 shows at 4 beats before the shutter (120 BPM)")
                t.equal(plan.shutterAt, 8.0, "shutter at 16 beats (120 BPM)")
            } else { t.expect(false, "photoBooth failed to decode") }

            if let ev = decode(#"{"beat":4,"type":"credits","params":{"id":"c","lines":["a","b"],"hold":true}}"#),
               case .credits(let p) = ev.action {
                t.equal(p.lines ?? [], ["a", "b"], "credits lines")
                t.equal(p.hold, true, "credits hold")
            } else { t.expect(false, "credits failed to decode") }

            if let ev = decode(#"{"beat":4,"type":"systemProbe","params":{"id":"p","focus":["geolocation","network"]}}"#),
               case .systemProbe(let p) = ev.action {
                t.equal(p.focus ?? [], ["geolocation", "network"], "systemProbe focus")
            } else { t.expect(false, "systemProbe focus failed to decode") }

            if let ev = decode(##"{"beat":0,"type":"openWindow","params":{"id":"l","frame":[0,0,10,10],"content":{"kind":"lyric","text":"what I want","hex":"#0078D7","fg":"#FFFFFF"}}}"##),
               case .openWindow(let p) = ev.action {
                t.equal(p.content.kind, "lyric", "lyric content kind")
                t.equal(p.content.fg ?? "", "#FFFFFF", "lyric fg")
            } else { t.expect(false, "lyric window failed to decode") }

            if let ev = decode(#"{"beat":0,"type":"openWindow","params":{"id":"m","frame":[0,0,10,10],"content":{"kind":"map","map":{"lat":1,"lon":2,"here":true}}}}"#),
               case .openWindow(let p) = ev.action {
                t.equal(p.content.map?.here, true, "map here")
            } else { t.expect(false, "map here failed to decode") }

            t.expect(decode(#"{"beat":0,"type":"nope","params":{}}"#) == nil,
                     "an unknown type must be rejected")

            // --- the five ported sub-apps ---

            if let ev = decode(#"{"beat":2,"type":"photoWall","params":{"id":"w","fillPerBeat":20}}"#),
               case .photoWall(let p) = ev.action {
                t.equal(p.id, "w", "photoWall id")
                t.equal(p.fillPerBeat ?? -1, 20, "photoWall fillPerBeat")
                t.equal(ev.action.typeName, "photoWall", "photoWall typeName")
            } else { t.expect(false, "photoWall failed to decode") }

            if let ev = decode(#"{"beat":0,"type":"photoWall","params":{"id":"w"}}"#),
               case .photoWall(let p) = ev.action {
                let cfg = PhotoWallConfig(p)
                t.equal(cfg.churnPerBeat, 2.7, "photoWall default churnPerBeat")
                t.equal(cfg.liveWindows, 45, "photoWall default population")
                t.equal(cfg.cell, 12, "photoWall default lattice")
                t.equal(cfg.level, .normal,
                        "must not default to the standalone app's shielding level")
            } else { t.expect(false, "photoWall defaults failed to decode") }

            // minFrac/maxFrac are swapped if authored backwards; Planner assumes min<=max.
            if let ev = decode(#"{"beat":0,"type":"photoWall","params":{"id":"w","minFrac":0.8,"maxFrac":0.2}}"#),
               case .photoWall(let p) = ev.action {
                let cfg = PhotoWallConfig(p)
                t.expect(cfg.minFrac <= cfg.maxFrac, "inverted fractions are normalised")
            } else { t.expect(false, "photoWall fraction case failed to decode") }

            if let ev = decode(#"{"beat":4,"type":"glassTorus","params":{"id":"t","material":"chrome","speed":2}}"#),
               case .glassTorus(let p) = ev.action {
                t.equal(p.material ?? "", "chrome", "glassTorus material")
                t.equal(p.speed ?? -1, 2, "glassTorus speed")
            } else { t.expect(false, "glassTorus failed to decode") }

            for name in ["glass", "crystal", "chrome", "gold", "copper", "titanium"] {
                t.notNil(MaterialPreset.all.first { $0.name == name }, "torus preset \(name)")
            }

            if let ev = decode(#"{"beat":4,"type":"deskWallpaper","params":{"id":"w","mode":"glitch","hz":6}}"#),
               case .deskWallpaper(let p) = ev.action {
                t.equal(p.mode ?? "", "glitch", "deskWallpaper mode")
                t.equal(p.hz ?? -1, 6, "deskWallpaper hz")
            } else { t.expect(false, "deskWallpaper failed to decode") }

            if let ev = decode(#"{"beat":4,"type":"systemProbe","params":{"id":"p","linesPerBeat":30}}"#),
               case .systemProbe(let p) = ev.action {
                t.equal(p.linesPerBeat ?? -1, 30, "systemProbe linesPerBeat")
            } else { t.expect(false, "systemProbe failed to decode") }

            if let ev = decode(#"{"beat":4,"type":"fileSwarm","params":{"id":"s","pattern":"life","ticksPerBeat":3}}"#),
               case .fileSwarm(let p) = ev.action {
                t.equal(p.pattern ?? "", "life", "fileSwarm pattern")
            } else { t.expect(false, "fileSwarm failed to decode") }

            // --- meta gates ---

            // A document that says nothing must not end up writing files or swapping
            // the wallpaper.
            if let doc = try? JSONDecoder().decode(
                TimelineDocument.self, from: Data(#"{"meta":{"bpm":120},"events":[]}"#.utf8)) {
                t.expect(doc.meta.allowWallpaper != true, "allowWallpaper defaults off")
                t.expect(doc.meta.allowDesktopFiles != true, "allowDesktopFiles defaults off")
            } else { t.expect(false, "bare meta failed to decode") }

            if let doc = try? JSONDecoder().decode(
                TimelineDocument.self,
                from: Data(#"{"meta":{"bpm":120,"allowWallpaper":true,"allowDesktopFiles":true},"events":[]}"#.utf8)) {
                t.equal(doc.meta.allowWallpaper, true, "allowWallpaper reads when set")
                t.equal(doc.meta.allowDesktopFiles, true, "allowDesktopFiles reads when set")
            } else { t.expect(false, "gated meta failed to decode") }

            // --- the shipped show ---

            if let url = Bundle.module.url(forResource: "timeline", withExtension: "json"),
               let tl = try? TimelineLoader.load(from: url) {
                t.expect(tl.events.count > 500, "bundled show has \(tl.events.count) events")
                t.expect(tl.duration > 100, "bundled show duration \(tl.duration)s")
                // The scheduler walks a single advancing cursor, so order is load-bearing.
                let sorted = zip(tl.events, tl.events.dropFirst()).allSatisfy { $0.fireTime <= $1.fireTime }
                t.expect(sorted, "bundled show events are sorted by fire time")
                // The show as shipped must not touch the disk or the wallpaper.
                t.expect(tl.meta.allowWallpaper != true, "shipped show ships wallpaper gate off")
                t.expect(tl.meta.allowDesktopFiles != true, "shipped show ships file gate off")
            } else {
                t.expect(false, "bundled timeline.json failed to load")
            }
        }
    }
}
