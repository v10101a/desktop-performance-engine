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
                    ["closeWindow", "cursorPath", "cursorTrail", "deskWallpaper",
                     "fakeDialog", "fileSwarm", "glassTorus", "jiggle", "moveWindow",
                     "openWindow", "photoWall", "rearrangeIcons", "screenFlash",
                     "sprite", "systemProbe", "typeText", "wallpaper"],
                    "registered event types")

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
                t.expect(tl.events.count > 1000, "bundled show has \(tl.events.count) events")
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
