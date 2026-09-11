import AppKit
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
                    ["brickBreaker", "closeWindow", "credits", "cursorPath", "cursorTrail",
                     "deskWallpaper", "fakeDialog", "fileSwarm", "glassTorus", "hideOtherApps",
                     "jiggle", "moveWindow", "openWindow", "oracle", "photoBooth", "photoWall",
                     "rearrangeIcons", "reboot", "screenFlash", "segSwarm", "sprite",
                     "systemProbe", "typeText", "wallpaper"],
                    "registered event types")

            // The stage-clearing event takes no required params at all.
            if let ev = decode(#"{"beat":0,"type":"hideOtherApps","params":{}}"#),
               case .hideOtherApps(let p) = ev.action {
                t.equal(p.id ?? "", "", "hideOtherApps id defaults to nil")
                t.equal(p.except ?? [], [], "hideOtherApps except defaults to nil")
            } else { t.expect(false, "bare hideOtherApps failed to decode") }
            if let ev = decode(#"{"beat":0,"type":"hideOtherApps","params":{"id":"apps","except":["com.apple.finder"]}}"#),
               case .hideOtherApps(let p) = ev.action {
                t.equal(p.id ?? "", "apps", "hideOtherApps id")
                t.equal(p.except ?? [], ["com.apple.finder"], "hideOtherApps except")
            } else { t.expect(false, "hideOtherApps failed to decode") }

            // --- the restructured show's new acts ---

            // A scheduled slide run: one landing time per image, `hz` irrelevant.
            if let ev = decode(#"{"beat":0,"type":"deskWallpaper","params":{"id":"w","mode":"slides","images":["a.jpg","b.jpg"],"at":[0.0,0.47],"durationSeconds":5}}"#),
               case .deskWallpaper(let p) = ev.action {
                t.equal(p.at ?? [], [0.0, 0.47], "deskWallpaper at schedule decodes")
            } else { t.expect(false, "scheduled deskWallpaper failed to decode") }

            // The welcome card: a Terminal window typing itself out by the line, the
            // credits' surface and the credits' cadence.
            if let ev = decode(#"{"beat":18,"type":"typeText","params":{"id":"w","frame":[0,0,400,300],"text":"a\nbb","chrome":"terminal","linesPerBeat":1,"fontSize":20}}"#),
               case .typeText(let p) = ev.action {
                t.equal(p.chrome ?? "", "terminal", "typeText chrome decodes")
                t.equal(p.linesPerBeat ?? -1, 1, "typeText linesPerBeat decodes")
            } else { t.expect(false, "terminal typeText failed to decode") }

            // A torn card in the fill (cue 15).
            if let ev = decode(#"{"beat":166,"type":"openWindow","params":{"id":"g","frame":[0,0,300,200],"content":{"kind":"glitch","path":"assets/pixelface.jpg","intensity":0.45,"seed":4100,"chrome":"mixed"}}}"#),
               case .openWindow(let p) = ev.action {
                t.equal(p.content.kind, "glitch", "glitch content kind decodes")
                t.equal(p.content.intensity ?? -1, 0.45, "glitch intensity decodes")
                t.equal(p.content.seed ?? -1, 4100, "glitch seed decodes")
            } else { t.expect(false, "glitch content failed to decode") }

            // The GLSL graphic (cue 17).
            if let ev = decode(#"{"beat":192,"type":"openWindow","params":{"id":"g","frame":[0,0,700,460],"content":{"kind":"shader","path":"assets/shaders/graphic.frag","drop":0.0}}}"#),
               case .openWindow(let p) = ev.action {
                t.equal(p.content.kind, "shader", "shader content kind decodes")
                t.equal(p.content.drop ?? -1, 0.0, "shader drop uniform decodes")
            } else { t.expect(false, "shader content failed to decode") }

            // A running automaton in the fill (cue 15).
            if let ev = decode(#"{"beat":166,"type":"openWindow","params":{"id":"a","frame":[0,0,300,200],"content":{"kind":"automaton","rule":110,"seed":110,"hz":10,"fontSize":9}}}"#),
               case .openWindow(let p) = ev.action {
                t.equal(p.content.rule ?? -1, 110, "automaton rule decodes")
                t.equal(p.content.hz ?? -1, 10, "automaton hz decodes")
            } else { t.expect(false, "automaton content failed to decode") }



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
                // The show as shipped must not write to the disk, and must not change
                // the machine's real desktop picture. Act 1 still paints the desktop DJ
                // Dave blue — it just does it on the desktop LAYER, a window that cannot
                // outlive the process, so the gate that covers the real wallpaper stays
                // shut. The pairing is the actual guard: the gate may only be open if
                // some event genuinely needs it, so a stray `true` with nothing behind it
                // still fails, and a cue that quietly switches to `surface: "wallpaper"`
                // without opening the gate fails too.
                t.equal(tl.meta.allowWallpaper == true, tl.usesWallpaper,
                        "wallpaper gate is open exactly when the show changes the real wallpaper")
                t.expect(!tl.usesWallpaper, "shipped show never touches the real wallpaper")
                let paintsDesktop = tl.events.contains {
                    if case .deskWallpaper = $0.action { return true }; return false
                }
                t.expect(paintsDesktop, "shipped show paints the desktop in Act 1")
                t.expect(tl.meta.allowDesktopFiles != true, "shipped show ships file gate off")

                // THE COPY HAS TO FIT THE WINDOW IT IS AUTHORED INTO. Both of these are
                // written to be rewritten — the torus's monologue and the end card's
                // credits are the piece's two blocks of prose — and neither surface
                // scrolls or wraps to a bigger window: copy past the bottom of a
                // `typeText` page types off the end of it, and a credit line wider than
                // the terminal breaks in the middle of a name. Measured against the
                // frames the show actually authors.
                for ev in tl.events {
                    guard case .typeText(let p) = ev.action, p.chrome != "terminal",
                          p.frame.count == 4 else { continue }
                    let frame = NSSize(width: p.frame[2], height: p.frame[3])
                    let fontSize = CGFloat(p.fontSize ?? 13)
                    let needs: CGFloat, has: CGFloat
                    if p.chrome == "bubble" {
                        // The balloon is borderless, so the authored frame IS the
                        // content — no title bar comes off it — and the spike takes a
                        // bite out of the side the copy can use.
                        let tail = SpeechBubbleView.Tail(rawValue: p.tail ?? "left") ?? .left
                        needs = SpeechBubbleView.textHeight(p.text, in: frame, tail: tail,
                                                            fontSize: fontSize)
                        has = SpeechBubbleView.textBox(in: frame, tail: tail).height
                    } else {
                        let page = BaseEffectWindow.contentSize(
                            forFrame: NSRect(origin: .zero, size: frame), native: true)
                        needs = TextEditorView.textHeight(p.text, in: page, fontSize: fontSize)
                        has = TextEditorView.textBox(in: page).height
                    }
                    t.expect(needs <= has,
                             "\"\(p.id)\" fits its page — needs \(Int(needs))pt of \(Int(has))")
                }
                for ev in tl.events {
                    guard case .credits(let p) = ev.action, let lines = p.lines else { continue }
                    // The narrowest screen the piece is meant to play on. `rollFont`
                    // shrinks the face until the longest line fits; bottoming out at the
                    // floor means it no longer does, at any size worth reading.
                    let small = NSRect(x: 0, y: 0, width: 1440, height: 900)
                    let font = CreditsController.rollFont(for: lines, size: p.fontSize ?? 11, in: small)
                    t.expect(font.pointSize > 11,
                             "the credits fit the terminal on a 1440-wide screen — "
                             + "fitted to \(font.pointSize)pt")
                    let size = CreditsController.rollSize(for: lines, font: font, in: small)
                    t.expect(CreditsController.naturalRollWidth(for: lines, font: font) <= size.width,
                             "…without the longest line wrapping")
                    // WHERE THE CARD MAY LAND. Two edges, and only one of them is taste.
                    //
                    // The late edge is a hard engine constraint: `PerformanceEngine.step`
                    // tests `now >= duration` BEFORE ticking the scheduler, and `credits`
                    // has no intrinsic duration, so a card AT the end of the file makes
                    // `timeline.duration` equal its own fire time and the end-of-piece
                    // branch trips on the tick before it ever fires — the card simply
                    // never comes up. Do not close that margin up.
                    //
                    // The early edge is cue 30, the stop at 160.55 s where everything
                    // closes. The card belongs in the silence after it, not over the
                    // eruption.
                    //
                    // Between those the position is a judgement call and it has moved
                    // twice: onto the stop, then to 169.42 s (after the last of the
                    // music), and now to 164.29 s, pulled 5 s forward so the ending
                    // arrives sooner. At that position the credits again begin over the
                    // final ~5.6 s of the track, which the 2026-09-07 move had
                    // deliberately stopped. That is a choice, so it is pinned loosely
                    // here and argued in generate_show.py's cue 31 header.
                    let track = 169.85, stop = 160.55
                    t.expect(ev.fireTime > stop && ev.fireTime < track - 0.2,
                             "the end card lands in the silence after the stop and before "
                             + "the file ends (\(ev.fireTime)s, stop \(stop)s, track \(track)s)")
                    // AND NO SECOND RESTART. The outro's Apple-logo boot bar is geometry-
                    // matched to the gate's stalled restart card, and the piece opens on
                    // that — a second one to close reads as the same beat played twice.
                    t.equal(p.bootSeconds, 0, "the ending skips the boot bar")
                }
                // Every answer the torus can give fits the card the show opens for it.
                let answerBox = NSSize(width: 460 - (20 + DialogIcon.side + 16) - 20, height: 186 - 100)
                for answer in OracleController.defaultAnswers {
                    let font = OracleController.answerFont(for: answer, in: answerBox)
                    let h = answer.boundingRect(
                        with: NSSize(width: answerBox.width, height: .greatestFiniteMagnitude),
                        options: [.usesLineFragmentOrigin], attributes: [.font: font]).height
                    t.expect(h <= answerBox.height,
                             "the torus's \"\(answer)\" fits its card at \(font.pointSize)pt")
                }

                // The lyric wallpapers are named by path in the timeline and swapped in
                // during the show. A misnamed one is silent — the desktop just keeps
                // whatever was there — so every path is resolved up front here.
                var slideCount = 0, missing: [String] = [], timedRuns = 0
                for ev in tl.events {
                    guard case .deskWallpaper(let p) = ev.action, let images = p.images else { continue }
                    slideCount += images.count
                    for name in images where !FileManager.default.fileExists(
                        atPath: resolveResourcePath(name)) {
                        missing.append(name)
                    }
                    // A scheduled run (the lyric on the desktop, cue 12) carries one
                    // landing time per image, ascending, inside the run — a word landing
                    // after the run ends would never show.
                    guard let at = p.at else { continue }
                    timedRuns += 1
                    t.equal(at.count, images.count, "one landing time per desktop word")
                    t.expect(zip(at, at.dropFirst()).allSatisfy { $0 < $1 },
                             "desktop words land in ascending order")
                    t.expect(at.first ?? -1 >= 0, "the first desktop word lands after the run starts")
                    if let dur = p.durationSeconds {
                        t.expect((at.last ?? .infinity) < dur,
                                 "the last desktop word lands before the run ends")
                    }
                    // The words are a chorus, not a strobe: nothing lands faster than a
                    // sixteenth at 128.5 BPM (~117 ms), which is where the flashing was.
                    let gaps = zip(at, at.dropFirst()).map { $1 - $0 }
                    t.expect((gaps.min() ?? 1) > 0.11,
                             "desktop words are paced to the lyric, not flashed (min gap \(gaps.min() ?? 0)s)")
                }
                t.expect(timedRuns >= 1, "the lyric wallpaper run (cue 12) carries an `at` schedule")

                // Every window that writes itself out has to FINISH before the cut takes
                // it away — a welcome card cut off mid-sentence reads as a bug, not as a
                // beat. Checked against the `closeWindow` aimed at its own id.
                for ev in tl.events {
                    guard case .typeText(let p) = ev.action else { continue }
                    let lines = p.text.components(separatedBy: "\n").count
                    let units = p.linesPerBeat.map { (Double(lines), $0) }
                             ?? (Double(p.text.count), p.charsPerBeat ?? 16)
                    let typedBeats = units.0 / max(0.001, units.1)
                    let closedAt = tl.events.first {
                        if case .closeWindow(let c) = $0.action { return c.id == p.id && $0.fireTime > ev.fireTime }
                        return false
                    }?.fireTime
                    guard let closedAt else { continue }
                    let roomBeats = (closedAt - ev.fireTime) * tl.meta.bpm / 60.0
                    t.expect(typedBeats <= roomBeats,
                             "typeText \(p.id) finishes (\(typedBeats) beats) before its close (\(roomBeats) beats)")
                }

                // The torn cards in the fill name their source by path, and a misnamed
                // one is silent — the window just stays empty for the whole act. The
                // tear is also a pure function of (image, intensity, seed), so an
                // out-of-range intensity or a missing seed would be a different picture
                // every take in a show that is otherwise identical take to take.
                var tornCards = 0
                for ev in tl.events {
                    guard case .openWindow(let p) = ev.action, p.content.kind == "glitch" else { continue }
                    tornCards += 1
                    let path = p.content.path ?? ""
                    t.expect(FileManager.default.fileExists(atPath: resolveResourcePath(path)),
                             "torn card \(p.id) resolves \(path)")
                    let intensity = p.content.intensity ?? -1
                    t.expect(intensity > 0 && intensity <= 1,
                             "torn card \(p.id) intensity \(intensity) is in 0…1")
                    t.expect(p.content.seed != nil, "torn card \(p.id) is seeded")
                }
                // Cue 15 is pulled (`FILL_ACT = False` in the generator), and it was
                // the only act that opened torn cards — so `tornCards` is 0 in the
                // current cut. The checks above are what stands guard when it returns.

                // The automata cards in the fill run in the engine — the timeline
                // carries only the rule, so the numbers it carries have to be ones a
                // rule can actually be. An out-of-range rule truncates silently to a
                // different automaton, and hz 0 would freeze the window solid.
                var automata = 0
                for ev in tl.events {
                    guard case .openWindow(let p) = ev.action,
                          p.content.kind == "automaton" else { continue }
                    automata += 1
                    let rule = p.content.rule ?? -1
                    t.expect(rule >= 0 && rule <= 255, "\(p.id) rule \(rule) is an 8-bit rule")
                    t.expect((p.content.hz ?? 0) > 0, "\(p.id) scrolls")
                }
                // Same as the torn cards: the automata came with the pulled fill, so
                // the count is 0 until `FILL_ACT` goes back on.

                // NOTHING THE SHOW PLAYS ASKS FOR SCREEN RECORDING. The outro no longer
                // captures the display and the glass torus reflects the wallpaper file
                // rather than a live stream, which leaves `deskWallpaper` mode
                // "recursive" as the last path in the engine that reaches
                // ScreenCaptureKit. Authoring one would put a permission dialog in front
                // of a viewer mid-performance — macOS cannot even settle that one with a
                // prompt, it sends them to System Settings and wants a relaunch.
                for ev in tl.events {
                    guard case .deskWallpaper(let p) = ev.action else { continue }
                    t.expect(p.mode != "recursive",
                             "no recursive wallpaper — it is the last thing here that "
                             + "would ask for Screen Recording")
                }

                // The game (cue 5). It ends when the cue closes it — a `brickBreaker`
                // with no close is a table of windows left on the desktop, which is the
                // one thing the piece is not allowed to do.
                for ev in tl.events {
                    guard case .brickBreaker(let p) = ev.action else { continue }
                    let closed = tl.events.contains {
                        if case .closeWindow(let c) = $0.action { return c.id == p.id }
                        return false
                    }
                    t.expect(closed, "the brick breaker \(p.id) is closed by the timeline")
                    t.expect((p.rows ?? 4) * (p.cols ?? 8) >= 8,
                             "…and racks a wall worth hitting (\((p.rows ?? 4) * (p.cols ?? 8)) bricks)")
                }

                // The swarm owns real windows above everything and nothing but its own
                // close takes them away, so a `segSwarm` the timeline never closes is a
                // desktop full of panels for the rest of the run.
                for ev in tl.events {
                    guard case .segSwarm(let p) = ev.action else { continue }
                    let closed = tl.events.contains {
                        if case .closeWindow(let c) = $0.action { return c.id == p.id }
                        return false
                    }
                    t.expect(closed, "the segmenter swarm \(p.id) is closed by the timeline")
                    // A clip is named by an authored path, and a missing one is a black
                    // screen where an act should be.
                    if let path = p.path {
                        t.expect(FileManager.default.fileExists(atPath: resolveResourcePath(path)),
                                 "…and its clip resolves (\(path))")
                    }
                }

                // DooM. One window, one id, and NOT one of the eruption's recycled
                // `w0…w13`: re-opening an id rebuilds the content view, which restarts
                // the game — a DooM that reboots every few beats never leaves its title
                // screen. So what is pinned here is that nothing else ever opens on this
                // id, which is the failure that would be invisible in the timeline.
                var doomIds: [String] = []
                for ev in tl.events {
                    guard case .openWindow(let p) = ev.action, p.content.kind == "doom" else { continue }
                    doomIds.append(p.id)
                    t.expect(p.frame.count == 4 && p.frame[2] > 0 && p.frame[2] <= 560,
                             "the DooM window is a window on the desktop, not the screen "
                             + "(\(Int(p.frame[2]))pt wide)")
                }
                // Pulled in the timeline (2026-09-03) — `DOOMVID_ACT = False` in the
                // generator, so the count is 0. The per-window checks above are what
                // stands guard when the video slot takes it back.
                t.expect(doomIds.count <= 1, "DooM runs in at most one window")
                if let id = doomIds.first {
                    let opens = tl.events.filter {
                        if case .openWindow(let p) = $0.action { return p.id == id }
                        return false
                    }
                    t.equal(opens.count, 1, "…and opens \(id) once, so the game is never restarted")
                    let closes = tl.events.filter {
                        if case .closeWindow(let p) = $0.action { return p.id == id }
                        return false
                    }
                    t.expect(closes.count >= 1, "…and closes it — nothing outlives the stop")
                }

                // The shader windows name a .frag by path and it has to be there — a
                // missing one is a black window, same as a broken one. And it has to be
                // pure ASCII: GLSL ES 1.00 restricts the character set and ANGLE
                // enforces it at the lexer, so a single em dash in a COMMENT fails the
                // compile with an empty info log and no other symptom. One did.
                var shaders = 0
                for ev in tl.events {
                    guard case .openWindow(let p) = ev.action,
                          p.content.kind == "shader" else { continue }
                    shaders += 1
                    let path = resolveResourcePath(p.content.path ?? "")
                    guard let src = try? String(contentsOfFile: path, encoding: .utf8) else {
                        t.expect(false, "shader \(p.id) resolves \(p.content.path ?? "")")
                        continue
                    }
                    t.expect(src.allSatisfy(\.isASCII),
                             "shader \(p.id) is pure ASCII (comments included)")
                    t.expect(src.contains("void main"), "shader \(p.id) has a main()")
                }

                // The desktop-animation windows (cue 17): each names an .mp4 by path,
                // which has to be there — a missing clip is a black box — and the "video"
                // kind has to build the looping view. The harness runs on main, so the
                // view build is safe to assume-isolated; only the first is built, to keep
                // the test to one AVPlayer.
                var videos = 0
                var builtVideo = false
                for ev in tl.events {
                    guard case .openWindow(let p) = ev.action,
                          p.content.kind == "video" else { continue }
                    videos += 1
                    let clip = resolveResourcePath(p.content.path ?? "")
                    let there = FileManager.default.fileExists(atPath: clip)
                    t.expect(there, "video \(p.id) resolves \(p.content.path ?? "")")
                    if there && !builtVideo {
                        builtVideo = true
                        let view = MainActor.assumeIsolated {
                            makeEffectContentView(p.content, size: NSSize(width: 320, height: 200))
                        }
                        let vv = view.subviews.compactMap { $0 as? VideoContentView }.first
                        t.expect(vv?.hasClipForTesting == true,
                                 "openWindow · video builds the looping view on its clip")
                    }
                }
                t.expect(videos >= 4,
                         "the breakdown opens its desktop animations (\(videos) video windows)")

                // Cue 4's fifth probe panel scans HARDWARE now, not contacts (which the
                // show isn't entitled for). The generator names the section and the Swift
                // `Probe.gatherFocused` renders it; a rename in one place only would read
                // out "unknown section".
                var probeFocuses = Set<String>()
                for ev in tl.events {
                    if case .systemProbe(let p) = ev.action { p.focus?.forEach { probeFocuses.insert($0) } }
                }
                t.expect(probeFocuses.contains("hardware"), "the probe scans hardware")
                t.expect(!probeFocuses.contains("contacts"), "…and no longer scans contacts")
                let hw = hardwareDeepSection(displays: [])
                t.expect(hw.count >= 8, "the hardware section reads out a deep block (\(hw.count) lines)")

                // Dialog buttons close their window now: openDialog/makeDialogContentView
                // wire each NSButton to a target/action, where they used to be inert.
                let dialog = makeDialogContentView(title: "t", message: "m", buttons: ["OK", "Cancel"],
                                                   size: NSSize(width: 320, height: 160), onButton: { _ in })
                let dialogButtons = dialog.subviews.compactMap { $0 as? NSButton }
                t.expect(dialogButtons.count == 2, "the dialog draws its buttons")
                t.expect(dialogButtons.allSatisfy { $0.target != nil && $0.action != nil },
                         "…and each button is wired to an action")

                // Cue 7's desktop is a BAKED wallpaper (assets/pixelface_desktop.jpg,
                // written by the generator), not the raw artwork stretched over the
                // screen. It used to be composed at run time from `pixelface.jpg` plus a
                // `fit: center` on the event, which is one more thing to go wrong at show
                // time than a picture is. Measured from the file: the face has to be
                // small ON it, or we have shipped a full-screen face again.
                for ev in tl.events {
                    guard case .deskWallpaper(let p) = ev.action,
                          let first = p.images?.first, first.contains("pixelface") else { continue }
                    guard let img = NSImage(contentsOfFile: resolveResourcePath(first)),
                          let bmp = img.representations.first as? NSBitmapImageRep else {
                        t.expect(false, "the face wallpaper resolves (\(first))"); continue
                    }
                    t.expect(bmp.pixelsWide > 1200 && bmp.pixelsHigh > 800,
                             "the face wallpaper is desktop-sized "
                             + "(\(bmp.pixelsWide)x\(bmp.pixelsHigh))")
                    // The ground is the artwork's own field colour, so "not the ground"
                    // finds only the face's light features -- and a STRETCHED face would
                    // spread those over the whole picture. Placed, they sit in a small
                    // box in the middle.
                    // Distance from the GROUND, not brightness: HSB brightness is the
                    // max channel, and this ground is #001FFD -- a blue of 253 -- so
                    // every pixel of it reads as "bright" and the whole picture matched.
                    guard let ground = bmp.colorAt(x: 2, y: 2)?.usingColorSpace(.deviceRGB)
                    else { t.expect(false, "the wallpaper has a ground"); continue }
                    var minY = bmp.pixelsHigh, maxY = 0, found = false
                    for y in stride(from: 0, to: bmp.pixelsHigh, by: 4) {
                        for x in stride(from: 0, to: bmp.pixelsWide, by: 4) {
                            guard let c = bmp.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                                  abs(c.redComponent - ground.redComponent) > 0.08
                                    || abs(c.greenComponent - ground.greenComponent) > 0.08
                                    || abs(c.blueComponent - ground.blueComponent) > 0.08
                            else { continue }
                            minY = min(minY, y); maxY = max(maxY, y); found = true
                        }
                    }
                    t.expect(found, "the face is on the wallpaper at all")
                    let boxH = Double(maxY - minY) / Double(bmp.pixelsHigh)
                    t.expect(found && boxH > 0.02 && boxH < 0.30,
                             "the face is placed small, not stretched (its features span "
                             + "\(Int(boxH * 100))% of the wallpaper's height)")
                }

                // The fireworks (cue 10) are a TRANSPARENT FULL-SCREEN overlay: the
                // spiral of lyrics is still winding out underneath and has to show
                // through. `[0,0,0,0]` is the fullscreen sentinel; any chrome would
                // paint a ground and hide what it is supposed to be thrown over.
                var fireworks = 0
                for ev in tl.events {
                    guard case .openWindow(let p) = ev.action,
                          p.content.kind == "fileworks" else { continue }
                    fireworks += 1
                    t.equal(p.frame, [0, 0, 0, 0], "the fireworks fill the screen")
                    t.equal(p.content.chrome ?? "", "none", "the fireworks wear no chrome")
                    t.expect(p.content.seed != nil, "the fireworks are seeded")
                }
                // Pulled in the timeline (2026-09-03) — `WORKS_ACT = False`. They moved
                // from cue 10 to cue 25 and then out of the cut altogether, so the count
                // is 0; never more than one, because a live full-screen particle layer
                // over the word swaps is what dragged chorus 1B.
                t.expect(fireworks <= 1, "the fireworks are up at most once")

                // Both cursor swarms — the one that chases the pointer (cue 24) and the
                // shoal that ignores it (cue 28) — are transparent full-screen overlays,
                // same as the fireworks: they work across the whole screen, and any
                // chrome would paint a ground over what they move through. An unknown
                // `mode` string would silently fall back to chasing, which on cue 28
                // would be 54 pointers converging on the viewer's mouse instead of a
                // shoal, so the spelling is checked rather than assumed.
                var modes: [String] = []
                var patterns: Set<String> = []
                // When each swarm is on screen, so the level rule below can be about what
                // it actually has to outrank rather than about which cue it is.
                // Paired with the id, because a swarm that CUTS re-opens its own id every
                // beat and those are not windows burying it — they are it.
                let opensAt = tl.events.compactMap { ev -> (Double, String)? in
                    if case .openWindow(let o) = ev.action { return (ev.fireTime, o.id) }
                    return nil
                }
                for ev in tl.events {
                    guard case .openWindow(let p) = ev.action,
                          p.content.kind == "cursors" else { continue }
                    modes.append(p.content.mode ?? "chase")
                    if let pat = p.content.pattern { patterns.insert(pat) }
                    // A school has to outrank whatever it swims through, and the show's
                    // z-order is just the order things opened in. So the rule is about
                    // COMPANY, not about which cue it is: cue 21's shoal rides an eruption
                    // that raises a window every fifth of a beat and is buried without
                    // `floating`; cue 12's swarm has the lyric desktop to itself.
                    //
                    // This used to assert `floating` on every school, which held only
                    // while cue 21's shoal was the only one in the piece.
                    //
                    // The threshold is 20 rather than 1 because "company" is not all the
                    // same thing. An ERUPTION is hundreds of windows over tens of seconds
                    // and buries anything below it. A SEAM is a burst of five to eight
                    // (`sm…`) covering an act changeover for about a third of a second,
                    // and the lyric swarm passes under two of them by design — the seam is
                    // meant to cover the join, including this.
                    let close = tl.events.compactMap { e -> Double? in
                        if case .closeWindow(let c) = e.action, c.id == p.id,
                           e.fireTime > ev.fireTime { return e.fireTime }
                        return nil
                    }.min() ?? tl.duration
                    let company = opensAt.filter {
                        $0.1 != p.id && $0.0 > ev.fireTime + 0.05 && $0.0 < close
                    }.count
                    if p.content.mode == "school", company > 20 {
                        t.equal(p.level ?? "normal", "floating",
                                "a shoal under an eruption (\(company) windows) floats")
                    }
                    t.equal(p.frame, [0, 0, 0, 0], "the cursor swarm fills the screen")
                    t.equal(p.content.chrome ?? "", "none", "the cursor swarm wears no chrome")
                    t.expect(p.content.seed != nil, "the cursor swarm is seeded")
                    t.expect(["chase", "school"].contains(p.content.mode ?? "chase"),
                             "cursor swarm mode \(p.content.mode ?? "chase") is a real one")
                }
                // EXACTLY ONE chase. That is the mode that reads `NSEvent.mouseLocation`
                // and hunts the viewer's own pointer; every other swarm in the piece is a
                // school, which never touches it. A second chase would be a cue quietly
                // grabbing the one thing on screen the viewer still owns.
                t.equal(modes.filter { $0 == "chase" }.count, 1,
                        "exactly one pointer-chasing swarm in the show (cue 24)")
                t.expect(modes.filter { $0 == "school" }.count > 1,
                        "\(modes.filter { $0 == "school" }.count) schools — cue 21's shoal and cue 12's cuts")
                // The cuts are only cuts if they cut to something else. All five patterns
                // spawn differently AND flock differently; a run that collapsed to one
                // would play as a single scene being reseeded.
                t.expect(patterns.count >= 4,
                         "the lyric-desktop swarm cuts between \(patterns.count) patterns \(patterns.sorted())")

                // The mandala (cue 26): the third transparent full-screen overlay, and
                // the same rule applies -- chrome would paint a ground over the piece.
                var mandalas = 0
                for ev in tl.events {
                    guard case .openWindow(let p) = ev.action,
                          p.content.kind == "mandala" else { continue }
                    mandalas += 1
                    t.equal(p.frame, [0, 0, 0, 0], "the mandala fills the screen")
                    t.equal(p.content.chrome ?? "", "none", "the mandala wears no chrome")
                    t.expect((p.content.cols ?? 0) >= 2, "the mandala has rings")
                }
                // Pulled in the timeline (2026-09-03) — `MANDALA_ACT = False`.
                t.expect(mandalas <= 1, "the mandala is up at most once")

                // A quarter of the eruption's flat cards come up packed with macOS UI
                // instead. The rate is what is authored, so this checks the proportion
                // rather than a count -- and that every one is seeded, since an unseeded
                // pile would differ take to take in a show that is otherwise identical.
                var flatCards = 0, packedCards = 0
                for ev in tl.events {
                    guard case .openWindow(let p) = ev.action,
                          p.id.hasPrefix("w"), Int(p.id.dropFirst()) != nil else { continue }
                    if p.content.kind == "color" { flatCards += 1 }
                    if p.content.kind == "uichaos" {
                        packedCards += 1
                        t.expect(p.content.seed != nil, "packed window \(p.id) is seeded")
                    }
                }
                let slots = flatCards + packedCards
                let share = slots > 0 ? Double(packedCards) / Double(slots) : 0
                t.expect(share > 0.15 && share < 0.40,
                         "about a quarter of the eruption's flat cards are packed with UI "
                         + "(\(packedCards) of \(slots))")

                t.expect(shaders >= 1, "the show carries the GLSL graphic (cue 17)")
                // Its host page has to ship too, or every shader window is black.
                t.expect(bundledResource("shader", "html") != nil,
                         "the GLSL host page is in this build")

                // `beginMove` DROPS a move aimed at an id that isn't open yet — silently,
                // with a log line nobody reads mid-show. Every move in the show must
                // therefore land strictly after its window's open.
                var firstOpen: [String: Double] = [:]
                for ev in tl.events {
                    guard case .openWindow(let p) = ev.action else { continue }
                    if firstOpen[p.id] == nil { firstOpen[p.id] = ev.fireTime }
                }
                let orphanMoves = tl.events.compactMap { ev -> String? in
                    guard case .moveWindow(let p) = ev.action,
                          (firstOpen[p.id] ?? .infinity) >= ev.fireTime else { return nil }
                    return p.id
                }
                t.expect(orphanMoves.isEmpty,
                         "every moveWindow fires after its window opens "
                         + "(\(Set(orphanMoves).sorted().joined(separator: ", ")))")

                // The traveller's trail (cue 8) is a DELAY LINE: identical copies of the
                // leader, each one frame further behind and 1% of the screen further
                // left. Every invariant here is one that has already bitten once —
                // opens tied on the same beat leave the stack to the loader's sort,
                // which is not guaranteed stable, and an inverted stack shows the OLDEST
                // copy in front with the leader buried behind it.
                let chain = ["traveller"] + (1...20).map { "tr\($0)" }
                let chainOpens = chain.compactMap { id in firstOpen[id].map { (id, $0) } }
                t.equal(chainOpens.count, chain.count, "every link of the trail opens")
                let openTimes = Set(chainOpens.map(\.1))
                t.equal(openTimes.count, chainOpens.count,
                        "no two links of the trail open on the same instant")
                // Deepest first, leader last: presentation order IS z-order.
                if let leader = firstOpen["traveller"] {
                    t.expect(chainOpens.filter { $0.0 != "traveller" }.allSatisfy { $0.1 < leader },
                             "the leader opens in front of every copy behind it")
                }
                // Link k lags the leader by k frames and sits k% of the screen left of
                // it — checked on the first leg, which every link walks.
                let legMoves = chain.compactMap { id -> (String, Double, Double)? in
                    guard let ev = tl.events.first(where: {
                        if case .moveWindow(let p) = $0.action { return p.id == id }
                        return false
                    }), case .moveWindow(let p) = ev.action, !p.frame.isEmpty else { return nil }
                    return (id, ev.fireTime, p.frame[0])
                }
                t.equal(legMoves.count, chain.count, "every link walks the first leg")
                let lags = zip(legMoves, legMoves.dropFirst()).map { $1.1 - $0.1 }
                t.expect(lags.allSatisfy { $0 > 0.001 },
                         "each link lags the one in front of it by a real interval")
                t.expect(zip(legMoves, legMoves.dropFirst()).allSatisfy { $1.2 < $0.2 },
                         "each link sits to the left of the one in front of it")

                // A terminal's label WRAPS, and a wrapped line reads as a bug in a
                // window pretending to be Terminal. The generator sizes the frame from
                // an estimate of SF Mono's advance; this is the same measurement taken
                // against the real font, so an estimate that drifts fails here rather
                // than on screen.
                for ev in tl.events {
                    guard case .typeText(let p) = ev.action, p.chrome == "terminal",
                          p.frame.count == 4 else { continue }
                    let font = NSFont.monospacedSystemFont(ofSize: CGFloat(p.fontSize ?? 11),
                                                           weight: .regular)
                    let widest = p.text.components(separatedBy: "\n")
                        .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
                        .max() ?? 0
                    let room = CGFloat(p.frame[2]) - TerminalStyle.inset * 2
                    t.expect(widest <= room,
                             "typeText \(p.id) copy fits its terminal without wrapping "
                             + "(\(Int(widest.rounded()))pt of \(Int(room))pt)")
                }
                // The desktop's blue is authored as an exact rgb triple. It is written
                // to a PNG and handed to the window server, and a colour-space
                // round-trip on the way shifted it by ten in the blue channel — so the
                // file itself is checked, pixel for pixel.
                if let solid = tl.events.compactMap({ ev -> DeskWallpaperParams? in
                    guard case .deskWallpaper(let p) = ev.action, p.mode == "solid" else { return nil }
                    return p
                }).first, let hex = solid.hex {
                    t.equal(hex.uppercased(), "#020AF5", "the desktop is authored as the signature blue")
                    // Raw bytes out of the file, not `colorAt` — reading a pixel back
                    // through AppKit re-interprets it against a profile and reports a
                    // colour that is not what is stored.
                    if let url = try? WallpaperImage.solid(hex: hex),
                       let data = try? Data(contentsOf: url),
                       let rep = NSBitmapImageRep(data: data),
                       let px = rep.bitmapData {
                        let spp = rep.samplesPerPixel
                        let i = 4 * rep.bytesPerRow / rep.bytesPerRow + 4 * spp
                        t.equal(Int(px[i]), 2, "wallpaper red is 2")
                        t.equal(Int(px[i + 1]), 10, "wallpaper green is 10")
                        t.equal(Int(px[i + 2]), 245, "wallpaper blue is 245")
                    }
                }

                t.expect(slideCount > 0, "the show has a wallpaper slide run")
                t.equal(missing.count, 0,
                        "every lyric wallpaper resolves — missing: \(missing.joined(separator: ", "))")
                // The track must not start before the viewer answers the intro gate.
                // The transport window is on screen behind the gate, so its Play button
                // and the space bar both reach `play()` while the gate is still up —
                // this is what stops them. Never armed here, so nothing actually plays.
                let engine = PerformanceEngine()
                try? engine.loadTimeline(at: url)
                t.expect(engine.isArmed, "a fresh engine is armed — only the gate disarms it")
                engine.disarm()
                engine.play()
                t.expect(!engine.isPlaying, "a disarmed engine refuses to play")
                engine.arm()
                t.expect(engine.isArmed, "arming releases the transport")
            } else {
                t.expect(false, "bundled timeline.json failed to load")
            }
        }
    }
}
