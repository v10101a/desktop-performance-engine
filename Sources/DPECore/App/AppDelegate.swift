import AppKit
import MapKit

public final class AppDelegate: NSObject, NSApplicationDelegate {
    public override init() { super.init() }

    let engine = PerformanceEngine()
    var controller: MainWindowController?
    var gate: IntroGateController?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Dev tools: render the intro gate's cards, or the Phase 6 scenes, to a PNG.
        for (flag, render) in [("--snapshot-gate=", StillRenderer.renderGate),
                               ("--snapshot-scenes=", StillRenderer.renderScenes),
                               ("--snapshot-acts=", StillRenderer.renderActs),
                               ("--snapshot-credits=", StillRenderer.renderCredits),
                               ("--snapshot-chrome=", StillRenderer.renderChrome)] {
            guard let arg = CommandLine.arguments.first(where: { $0.hasPrefix(flag) }) else { continue }
            let path = String(arg.dropFirst(flag.count))
            do {
                try render(URL(fileURLWithPath: path))
                NSLog("[DPE] snapshot written: \(path)")
            } catch {
                NSLog("[DPE] snapshot error: \(error)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
            return
        }

        // Dev tool: render a still of the window content to PNG and quit. With a
        // timeline argument that contains a sprite, renders that sprite's frames.
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--snapshot=") }) {
            let path = String(arg.dropFirst("--snapshot=".count))
            do {
                if ProcessInfo.processInfo.environment["DPE_ASCII_DEMO"] == "1" {
                    try StillRenderer.renderAsciiDemo(to: URL(fileURLWithPath: path))
                } else if let tlPath = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") }),
                   let sprite = AppDelegate.firstSprite(in: tlPath) {
                    try StillRenderer.renderSprite(sprite, to: URL(fileURLWithPath: path))
                } else {
                    try StillRenderer.render(to: URL(fileURLWithPath: path))
                }
                NSLog("[DPE] snapshot written: \(path)")
            } catch {
                NSLog("[DPE] snapshot error: \(error)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
            return
        }

        // Is this copy self-contained? Loads the bundled show, resolves the backing
        // track, reports what it found and quits — no windows, nothing touched. Run it
        // from a copy of the .app somewhere else to prove the bundle travels.
        if CommandLine.arguments.contains("--check") {
            let bundled = AppDelegate.bundledTimelineURL()
            NSLog("[DPE] check: bundle      \(Bundle.main.bundleURL.path)")
            NSLog("[DPE] check: timeline    \(bundled?.path ?? "NOT FOUND")")
            if let url = bundled {
                do {
                    try engine.loadTimeline(at: url)
                    NSLog("[DPE] check: loaded      \(engine.loadedInfo)")
                    let audio = engine.resolvedAudioPath
                    NSLog("[DPE] check: audio       \(audio ?? "NOT FOUND — would fall back to a synth click track")")
                    NSLog("[DPE] check: SELF-CONTAINED = \(audio != nil)")
                } catch {
                    NSLog("[DPE] check: load error  \(error)")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
            return
        }

        // What does the mini-hydra actually read out of a patch? Prints the op chain
        // it built — name, nesting depth, args, and which args are time functions — so
        // an op the parser cannot see shows up here instead of silently not happening.
        if CommandLine.arguments.contains("--parse-hydra") {
            let path = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") } ?? ""
            let src = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            for op in Hydra.parse(src) {
                var parts: [String] = []
                for i in 0..<4 where op.arg(i, .nan).isFinite {
                    parts.append(String(format: op.isDynamic(i) ? "%.3g*time" : "%.3g", op.arg(i, 0)))
                }
                NSLog("[DPE] hydra-parse: depth=\(op.depth) \(op.name)(\(parts.joined(separator: ", ")))")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
            return
        }

        // Does Pause actually hold the frame? Plays the given timeline, pauses partway,
        // and reports whether the clock stopped while the windows stayed up — the whole
        // point being that pausing is NOT a stop. Holds the pause long enough to grab a
        // screenshot from outside, then resumes and checks the clock picked up again.
        if CommandLine.arguments.contains("--test-pause") {
            controller = MainWindowController(engine: engine)   // keep-alive window
            controller?.showWindow(nil)
            let path = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") }
            let url = path.map { URL(fileURLWithPath: $0) } ?? AppDelegate.bundledTimelineURL()
            if let url = url { try? engine.loadTimeline(at: url) }
            var last = 0.0
            engine.onTick = { last = $0 }
            engine.setInspecting(true)
            engine.play()
            let log = { (m: String) in NSLog("[DPE] pause-test: \(m)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                log(String(format: "playing  pos=%.2f windows=%d", last, self.engine.liveWindowCount))
                self.engine.readHydraTicks { log("live sketches before pause: \($0)") }
                self.engine.pause()
                let atPause = last
                let winAtPause = self.engine.liveWindowCount
                log(String(format: "paused   pos=%.2f windows=%d", atPause, winAtPause))
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                    log(String(format: "held 5s  pos=%.2f windows=%d (expect same pos, same windows)",
                               last, self.engine.liveWindowCount))
                    log("HELD-FRAME = \(last == atPause && self.engine.liveWindowCount == winAtPause)")
                    for line in self.engine.inspectSummary { log("  \(line)") }
                    // A live canvas renders in its own process off its own rAF loop, so
                    // freezing CALayers proves nothing about it. Read the frame counter
                    // out of the page: identical across a 5s hold means truly stopped.
                    self.engine.readHydraTicks { log("live sketches after 5s hold: \($0)") }
                    self.engine.resume()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        log(String(format: "resumed  pos=%.2f (expect > %.2f)", last, atPause))
                        log("RESUMED = \(last > atPause)")
                        for line in self.engine.inspectSummary { log("  \(line)") }
                        self.engine.readHydraTicks { log("live sketches after resume: \($0)") }
                        self.engine.stopAndRestore()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
                    }
                }
            }
            return
        }

        // Does the map actually fly? Builds a real MapFlyView off-screen, samples the
        // camera at t0 and again a couple of seconds later, and reports whether the
        // pose moved. (Tiles are a separate question — that needs the network.)
        if CommandLine.arguments.contains("--test-map") {
            runMapSelfTest()
            return
        }

        // Is the hydra in the hydra windows actually hydra? Runs the show's own opening
        // sketch on a live canvas and screenshots it. `--test-hydra=out.png` keeps the
        // frame; DPE_HYDRA=fake runs the same test against the impression for contrast.
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--test-hydra") }) {
            runHydraSelfTest()
            return
        }

        // Same idea as --test-hydra, for the GLSL windows: put the real shader on a
        // real GL canvas and look at what comes out. A fragment shader that fails to
        // compile renders black, which is indistinguishable from one that renders black,
        // so "it built" proves nothing here. `--test-shader=out.png` keeps the frame.
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--test-shader") }) {
            runShaderSelfTest()
            return
        }

        // The fireworks: a transparent overlay whose whole content is motion, so a
        // still of frame one is an empty window and proves nothing. This runs it for
        // real, long enough for shells to rise and burst, then counts what is in the
        // air. `--test-fileworks=out.png` keeps the frame.
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--test-fileworks") }) {
            runFileworksSelfTest()
            return
        }

        // The cursor swarm: it chases the real pointer, so a still proves nothing
        // unless the pointer has been somewhere. This drives the mouse across the
        // window itself and then looks at where the swarm went and which way the
        // arrows are pointing. `--test-cursors=out.png` keeps the frame.
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--test-cursors") }) {
            runCursorSwarmSelfTest()
            return
        }

        // The mandala: rings that counter-rotate, so a still of one frame cannot show
        // whether anything turns. This samples the positions, waits, and samples again.
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--test-mandala") }) {
            runMandalaSelfTest()
            return
        }

        // What each of the continuously-running views costs the MAIN THREAD, which is
        // the thing that matters: `DisplayPump` is vsync-driven and coalesced, so it
        // silently drops ticks whenever main is busy, and a view that hogs it does not
        // look slow itself -- it makes the whole show slow.
        if CommandLine.arguments.contains("--bench-views") {
            runViewBenchmark()
            return
        }

        // Does it actually run DooM? A window that opens on a black canvas and one that
        // opens on the title screen are the same window from Swift, so this asks the
        // page how much of its canvas is lit after it has had a few seconds to boot.
        if CommandLine.arguments.contains("--test-doom") {
            runDoomSelfTest()
            return
        }

        if CommandLine.arguments.contains("--test-sprites") {
            runSpriteSelfTest()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
            return
        }

        if CommandLine.arguments.contains("--test-icons") {
            runIconSelfTest()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
            return
        }

        // Offscreen torus frame, alpha intact — same shape as --snapshot-gate/-scenes.
        // --torus-material / --torus-time / --torus-size tune it.
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--snapshot-torus=") }) {
            let path = String(arg.dropFirst("--snapshot-torus=".count))
            func opt(_ flag: String) -> String? {
                CommandLine.arguments.first { $0.hasPrefix(flag) }.map { String($0.dropFirst(flag.count)) }
            }
            do {
                try Snapshot.write(
                    to: path,
                    size: opt("--torus-size=").flatMap(Int.init) ?? 900,
                    elapsed: opt("--torus-time=").flatMap(Double.init) ?? 2.5,
                    environmentPath: opt("--torus-env="),
                    roughness: opt("--torus-roughness=").flatMap(Float.init) ?? 0.04,
                    metal: opt("--torus-material=") ?? "glass",
                    mirror: CommandLine.arguments.contains("--torus-mirror"),
                    planeDistance: opt("--torus-plane=").flatMap(Float.init) ?? 2.0
                )
                NSLog("[DPE] snapshot written: \(path)")
            } catch {
                NSLog("[DPE] snapshot error: \(error)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
            return
        }

        // Loads a timeline through the real loader and reports what it contains.
        // The --test-* modes decode inline JSON; this is what checks the actual
        // generated show file after tools/generate_show.py runs.
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--validate=") }) {
            let path = String(arg.dropFirst("--validate=".count))
            do {
                let tl = try TimelineLoader.load(from: URL(fileURLWithPath: path))
                var counts: [String: Int] = [:]
                for ev in tl.events { counts[ev.action.typeName, default: 0] += 1 }
                let summary = counts.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                NSLog("[DPE] validate: \(tl.events.count) events, \(String(format: "%.1f", tl.duration))s, "
                    + "\(Int(tl.meta.bpm)) BPM")
                NSLog("[DPE] validate: \(summary)")
                NSLog("[DPE] validate: allowWallpaper=\(tl.meta.allowWallpaper ?? false) "
                    + "allowDesktopFiles=\(tl.meta.allowDesktopFiles ?? false) "
                    + "markers=\(tl.meta.markers?.count ?? 0)")
            } catch {
                NSLog("[DPE] validate FAILED: \(error)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
            return
        }

        if CommandLine.arguments.contains("--test-phase4") {
            runPhase4SelfTest()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
            return
        }

        if CommandLine.arguments.contains("--test-seek") {
            controller = MainWindowController(engine: engine)   // keep-alive window
            controller?.showWindow(nil)
            if let url = AppDelegate.bundledTimelineURL() {
                try? engine.loadTimeline(at: url)
            }
            var last = 0.0
            engine.onTick = { last = $0 }
            engine.play()
            let log = { (m: String) in NSLog("[DPE] seek-test: \(m)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                log(String(format: "playing pos=%.1f", last)); self.engine.seek(to: 90)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    log(String(format: "after seek→90 pos=%.1f (expect ~90)", last)); self.engine.seek(to: 5)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                        log(String(format: "after seek→5 pos=%.1f (expect ~5)", last))
                        self.engine.stopAndRestore()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
                    }
                }
            }
            return
        }

        controller = MainWindowController(engine: engine)
        controller?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Timeline source: explicit CLI path, else the bundled sample.
        var url: URL?
        let args = CommandLine.arguments
        if let path = args.dropFirst().first(where: { !$0.hasPrefix("--") }) {
            url = URL(fileURLWithPath: path)
        } else if let bundled = AppDelegate.bundledTimelineURL() {
            url = bundled
        }

        NSLog("[DPE] timeline url: \(url?.path ?? "nil")")
        if let url = url {
            do {
                try engine.loadTimeline(at: url)
                controller?.refresh()
                controller?.setStatus("Loaded \(url.lastPathComponent)")
                NSLog("[DPE] loaded: \(engine.loadedInfo)")
            } catch {
                controller?.setStatus("Load error: \(error)")
                NSLog("[DPE] load error: \(error)")
            }
        }

        // Act 0: the viewer opts in (or leaves) before anything happens. Skipped for
        // the unattended paths — --autoplay drives itself, --no-gate is the dev loop.
        if !args.contains("--autoplay") && !args.contains("--no-gate") {
            // Nothing may start the track while the gate is up. The transport window is
            // already on screen behind it, so without this its Play button (and the
            // space bar) could start the show under the gate.
            engine.disarm()
            gate = IntroGateController(
                onStart: { [weak self] in
                    guard let self else { return }
                    // Every prompt the show will need, answered before the first beat.
                    NSLog("[DPE] gate: yes — running preflight")
                    Permissions.preflight(for: self.engine.events) { [weak self] in
                        guard let self else { return }
                        NSLog("[DPE] gate: preflight done — arming and starting")
                        self.engine.arm()
                        self.controller?.startShow()
                        NSLog("[DPE] gate: startShow returned, isPlaying=\(self.engine.isPlaying)")
                    }
                },
                onExit: { NSApp.terminate(nil) })
            gate?.present()
        }

        // Self-test path: play the whole show with fire logging, then panic-restore
        // and quit. Verifies clock → scheduler → executors → restore end to end.
        if args.contains("--autoplay") {
            engine.enableFiringLog()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                // DPE_AUTOPLAY_FROM=<seconds> starts partway in — the way to rehearse one
                // act without sitting through the ones before it.
                let env = ProcessInfo.processInfo.environment
                let from = env["DPE_AUTOPLAY_FROM"].flatMap(Double.init) ?? 0
                if from > 0 { self.engine.seek(to: from) }
                NSLog("[DPE] --autoplay: starting show at \(from)s")
                self.engine.play()
                let cap = env["DPE_AUTOPLAY_SECS"].flatMap(Double.init)
                let quitAfter = cap ?? (self.engine.duration - from + 2.5)
                DispatchQueue.main.asyncAfter(deadline: .now() + quitAfter) {
                    NSLog("[DPE] --autoplay: panic + restore")
                    self.engine.stopAndRestore()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }

    /// Locate the bundled show WITHOUT touching `Bundle.module` unless we have to.
    ///
    /// SwiftPM's generated `Bundle.module` looks in exactly two places: the top level
    /// of the .app, and an ABSOLUTE path into the `.build` directory of the machine
    /// that compiled it — and it calls `fatalError` when neither exists. So a packaged
    /// app that only carries its resources in `Contents/Resources` (the normal place)
    /// runs fine on the build machine and crashes on launch anywhere else. We look in
    /// the sane locations first and keep `Bundle.module` as the last resort, which is
    /// the case that matters for `swift run` during development.
    static func bundledTimelineURL() -> URL? {
        let fm = FileManager.default
        if let res = Bundle.main.resourceURL {
            // Flat copy first (what bundle.sh writes), then inside whichever SwiftPM
            // resource bundle is present — that name follows the package AND the target
            // declaring the resources, so it must not be hardcoded across renames.
            // DPECore's bundle is tried before any other: a stale executable-target
            // bundle in .build once played the previous show under `swift run` while
            // the new timeline sat unread in DPECore's.
            let flat = res.appendingPathComponent("timeline.json")
            if fm.fileExists(atPath: flat.path) { return flat }
            for b in resourceBundles(in: res, fm: fm) {
                let url = b.appendingPathComponent("timeline.json")
                if fm.fileExists(atPath: url.path) { return url }
            }
        }
        return Bundle.module.url(forResource: "timeline", withExtension: "json")
    }

    /// First sprite event in a timeline, for `--snapshot` sprite rendering.
    static func firstSprite(in path: String) -> SpriteParams? {
        guard let tl = try? TimelineLoader.load(from: URL(fileURLWithPath: path)) else { return nil }
        for ev in tl.events {
            if case .sprite(let p) = ev.action { return p }
        }
        return nil
    }

    /// Does the desktop actually go up in the air? Runs the real view on a real window
    /// for a few seconds and reports how many sparks are in flight.
    private func runFileworksSelfTest() {
        var spec: ContentSpec?
        if let url = AppDelegate.bundledTimelineURL(),
           let timeline = try? TimelineLoader.load(from: url) {
            for ev in timeline.events {
                if case .openWindow(let p) = ev.action, p.content.kind == "fileworks" {
                    spec = p.content; break
                }
            }
        }
        guard let spec else {
            NSLog("[DPE] fileworks: no fileworks window in the timeline; nothing to test")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
            return
        }
        let size = NSSize(width: 1100, height: 700)
        let host = NSWindow(contentRect: NSRect(x: 60, y: 60, width: size.width, height: size.height),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        // The view is transparent by design; the test gives it a dark ground so the
        // icons are legible in the capture. In the show that ground is the piece itself.
        host.backgroundColor = NSColor(white: 0.06, alpha: 1)
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        let fw = FileworksView(size: size, seed: spec.seed ?? 7,
                               hz: spec.hz ?? 1.6, intensity: spec.intensity ?? 1.0)
        root.addSubview(fw)
        host.contentView = root
        host.orderFrontRegardless()
        NSLog("[DPE] fileworks: \(fw.cardCountForTesting) distinct icon cards")

        // Five seconds: the launch rate is ~1.6/s and a shell takes about a second to
        // reach its fuse, so this is several full bursts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            let live = fw.liveSparksForTesting
            let spread = fw.spreadForTesting
            NSLog("[DPE] fileworks: \(live) sparks in the air, spread \(spread.w)x\(spread.h)pt "
                + "of \(Int(size.width))x\(Int(size.height)), "
                + "\(fw.stepsForTesting) steps, \(fw.burstsForTesting) bursts")
            NSLog("[DPE] fileworks: LIVE = \(live > 0)  (expect true)")
            if let shot = CGWindowListCreateImage(.null, .optionIncludingWindow,
                                                  CGWindowID(host.windowNumber),
                                                  [.boundsIgnoreFraming, .bestResolution]),
               let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--test-fileworks=") }) {
                let path = String(arg.dropFirst("--test-fileworks=".count))
                let rep = NSBitmapImageRep(cgImage: shot)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                    NSLog("[DPE] fileworks: wrote \(path)")
                }
            }
            NSApp.terminate(nil)
        }
    }

    /// Stand each heavy view up on its own and measure what the main thread has left.
    /// The probe is a 60 Hz timer counting its own firings: every tick it misses is a
    /// tick the display pump would also have missed.
    private func runViewBenchmark() {
        let size = NSSize(width: 1440, height: 900)
        func make(_ name: String) -> NSView? {
            switch name {
            case "fileworks": return FileworksView(size: size, seed: 1046, hz: 1.0, intensity: 1.0)
            case "cursors":   return CursorSwarmView(size: size, seed: 3136, count: 90)
            // Cue 28's shoal, at the population the show runs it at. Worth its own round:
            // the flocking is O(n²) per step and it lands in the busiest bar of the piece.
            case "school":    return CursorSwarmView(size: size, seed: 4438, count: 54,
                                                     mode: .school)
            case "mandala":   return MandalaView(size: size, seed: 3863, rings: 5, intensity: 1.0)
            case "automaton": return AutomatonView(size: NSSize(width: 330, height: 240),
                                                   rule: 30, seed: 0, fontSize: 9, hz: 14)
            case "uichaos":   return UIChaosView(size: NSSize(width: 360, height: 240),
                                                 seed: 900, density: 1.15)
            default:          return nil
            }
        }
        let names = ["baseline", "fileworks", "cursors", "school", "mandala", "automaton",
                     "uichaos", "all"]
        var index = 0
        // ONE window for the whole run, its content swapped each round. Closing a window
        // between rounds ends the app: it is the only one open, and AppKit terminates on
        // the last one. Swapping the content view also releases the previous round's
        // views, which is what stops their timers (`viewDidMoveToWindow`).
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.backgroundColor = .black
        w.orderFrontRegardless()

        func run(_ next: @escaping () -> Void) {
            guard index < names.count else { next(); return }
            let name = names[index]
            index += 1
            let root = NSView(frame: NSRect(origin: .zero, size: size))
            root.wantsLayer = true
            var built = 0
            if name == "all" {
                for n in ["fileworks", "cursors", "mandala"] {
                    if let v = make(n) { root.addSubview(v); built += 1 }
                }
            } else if let v = make(name) {
                root.addSubview(v); built = 1
            }
            w.contentView = root

            var ticks = 0
            let t0 = CACurrentMediaTime()
            let probe = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in ticks += 1 }
            RunLoop.main.add(probe, forMode: .common)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                probe.invalidate()
                let secs = CACurrentMediaTime() - t0
                NSLog("%@", String(format: "[DPE] bench %-10s %5.1f probe-Hz of 60  (%d view(s))",
                                   (name as NSString).utf8String!, Double(ticks) / secs, built))
                run(next)
            }
        }
        run { NSApp.terminate(nil) }
    }

    private func runMandalaSelfTest() {
        var spec: ContentSpec?
        if let url = AppDelegate.bundledTimelineURL(),
           let timeline = try? TimelineLoader.load(from: url) {
            for ev in timeline.events {
                if case .openWindow(let p) = ev.action, p.content.kind == "mandala" {
                    spec = p.content; break
                }
            }
        }
        guard let spec else {
            NSLog("[DPE] mandala: no mandala in the timeline; nothing to test")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
            return
        }
        let size = NSSize(width: 900, height: 700)
        let host = NSWindow(contentRect: NSRect(x: 60, y: 60, width: size.width, height: size.height),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.backgroundColor = NSColor(white: 0.06, alpha: 1)
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        let mv = MandalaView(size: size, seed: spec.seed ?? 5,
                             rings: spec.cols ?? 5, intensity: spec.intensity ?? 1.0)
        root.addSubview(mv)
        host.contentView = root
        host.orderFrontRegardless()
        let speeds = mv.ringSpeedsForTesting
        let alternating = zip(speeds, speeds.dropFirst()).allSatisfy { $0 * $1 < 0 }
        NSLog("[DPE] mandala: \(mv.countForTesting) beach balls, \(speeds.count) rings, "
            + "counter-rotating = \(alternating)")
        let before = mv.positionsForTesting

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            let after = mv.positionsForTesting
            let moved = zip(before, after).filter { hypot($0.x - $1.x, $0.y - $1.y) > 4 }.count
            NSLog("[DPE] mandala: \(moved)/\(after.count) balls moved")
            NSLog("[DPE] mandala: LIVE = \(moved > after.count / 2 && alternating)  (expect true)")
            if let shot = CGWindowListCreateImage(.null, .optionIncludingWindow,
                                                  CGWindowID(host.windowNumber),
                                                  [.boundsIgnoreFraming, .bestResolution]),
               let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--test-mandala=") }) {
                let path = String(arg.dropFirst("--test-mandala=".count))
                if let png = NSBitmapImageRep(cgImage: shot).representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                    NSLog("[DPE] mandala: wrote \(path)")
                }
            }
            NSApp.terminate(nil)
        }
    }

    private func runDoomSelfTest() {
        let size = NSSize(width: 640, height: 400)
        // ON screen, unlike the map's self-test: WebKit throttles requestAnimationFrame
        // to nothing in a window nobody can see, and the game loop IS a rAF loop — run
        // off-screen it reports a black canvas whether the engine works or not.
        let host = NSWindow(contentRect: NSRect(x: 80, y: 80, width: size.width, height: size.height),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        let doom = DoomView(frame: NSRect(origin: .zero, size: size))
        host.contentView = doom
        host.orderFrontRegardless()
        NSLog("[DPE] doom: engine installed = \(DoomView.isInstalled) "
              + "(tools/fetch_doom.sh if not)")
        // Long enough to fetch 6.5 MB off disk, instantiate it, run main() and get some
        // frames up — the title screen alone is a couple of seconds in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
            doom.report { line in
                NSLog("[DPE] doom: %@", line)
                NSLog("[DPE] doom: a lit count near zero means it booted onto a black screen")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
            }
        }
    }

    private func runCursorSwarmSelfTest() {
        var spec: ContentSpec?
        if let url = AppDelegate.bundledTimelineURL(),
           let timeline = try? TimelineLoader.load(from: url) {
            for ev in timeline.events {
                if case .openWindow(let p) = ev.action, p.content.kind == "cursors" {
                    spec = p.content; break
                }
            }
        }
        guard let spec else {
            NSLog("[DPE] cursors: no cursor swarm in the timeline; nothing to test")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
            return
        }
        let size = NSSize(width: 1100, height: 700)
        let host = NSWindow(contentRect: NSRect(x: 60, y: 60, width: size.width, height: size.height),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.backgroundColor = NSColor(white: 0.06, alpha: 1)
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        let cs = CursorSwarmView(size: size, seed: spec.seed ?? 3,
                                 count: Int((spec.intensity ?? 1.0) * 90),
                                 mode: CursorSwarmView.Mode(spec.mode))
        root.addSubview(cs)
        host.contentView = root
        host.orderFrontRegardless()
        let sizes = cs.sizesForTesting
        NSLog("%@", String(format: "[DPE] cursors: %d pointers, %.0f-%.0fpt, mode %@",
                           cs.countForTesting, sizes.min() ?? 0, sizes.max() ?? 0,
                           spec.mode ?? "chase"))

        // Walk the pointer across the window, then let the swarm run at it.
        let where1 = CGPoint(x: host.frame.minX + 120, y: host.frame.minY + 120)
        let where2 = CGPoint(x: host.frame.maxX - 140, y: host.frame.maxY - 160)
        func warp(_ p: CGPoint) {
            // Screen coordinates for CGWarpMouseCursorPosition are top-left origin.
            let h = NSScreen.screens.first?.frame.height ?? 0
            CGWarpMouseCursorPosition(CGPoint(x: p.x, y: h - p.y))
        }
        warp(where1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { warp(where2) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) {
            let headings = cs.headingsForTesting
            // If they are chasing, most of them are pointing the same way at once.
            let mean = atan2(headings.map(sin).reduce(0, +) / Double(headings.count),
                             headings.map(cos).reduce(0, +) / Double(headings.count))
            let agreeing = headings.filter { abs(atan2(sin($0 - mean), cos($0 - mean))) < 1.0 }.count
            NSLog("[DPE] cursors: spread \(cs.spreadForTesting)pt, "
                + "\(agreeing)/\(headings.count) pointing within 1 rad of the pack")
            NSLog("[DPE] cursors: LIVE = \(agreeing > headings.count / 2)  (expect true)")
            if let shot = CGWindowListCreateImage(.null, .optionIncludingWindow,
                                                  CGWindowID(host.windowNumber),
                                                  [.boundsIgnoreFraming, .bestResolution]),
               let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--test-cursors=") }) {
                let path = String(arg.dropFirst("--test-cursors=".count))
                if let png = NSBitmapImageRep(cgImage: shot).representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                    NSLog("[DPE] cursors: wrote \(path)")
                }
            }
            NSApp.terminate(nil)
        }
    }

    private func runShaderSelfTest() {
        var specs: [ContentSpec] = []
        if let url = AppDelegate.bundledTimelineURL(),
           let timeline = try? TimelineLoader.load(from: url) {
            for ev in timeline.events {
                if case .openWindow(let p) = ev.action, p.content.kind == "shader",
                   !specs.contains(where: { $0.path == p.content.path }) {
                    specs.append(p.content)
                }
            }
        }
        guard let spec = specs.first else {
            NSLog("[DPE] shader: no shader windows in the timeline; nothing to test")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
            return
        }
        NSLog("[DPE] shader: \(specs.count) shader window(s); testing \(spec.path ?? "?")")

        let size = NSSize(width: 640, height: 420)
        let host = NSWindow(contentRect: NSRect(x: 80, y: 80, width: size.width, height: size.height),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.backgroundColor = .black
        host.contentView = makeEffectContentView(spec, size: size)
        host.orderFrontRegardless()

        // Three seconds: the page, the GL context, the shader compile and a few hundred
        // frames — a raymarcher whose first frames are legitimately dark has moved on.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            guard let shot = CGWindowListCreateImage(.null, .optionIncludingWindow,
                                                     CGWindowID(host.windowNumber),
                                                     [.boundsIgnoreFraming, .bestResolution]) else {
                NSLog("[DPE] shader: capture failed (Screen Recording?); LIVE = unknown")
                NSApp.terminate(nil); return
            }
            let rep = NSBitmapImageRep(cgImage: shot)
            var lit = 0, total = 0
            var hues = Set<Int>()
            for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
                for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                    guard let c = rep.colorAt(x: x, y: y) else { continue }
                    total += 1
                    if c.brightnessComponent > 0.08 {
                        lit += 1
                        hues.insert(Int(c.hueComponent * 24))
                    }
                }
            }
            let percent = total > 0 ? 100.0 * Double(lit) / Double(total) : 0
            NSLog("%@", String(format: "[DPE] shader: %.1f%% of the canvas is lit, %d distinct hues",
                               percent, hues.count))
            NSLog("[DPE] shader: LIVE = \(percent > 2)  (expect true)")
            if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--test-shader=") }) {
                let path = String(arg.dropFirst("--test-shader=".count))
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                    NSLog("[DPE] shader: wrote \(path)")
                }
            }
            NSApp.terminate(nil)
        }
    }

    private func runHydraSelfTest() {
        guard HydraWeb.isAvailable else {
            NSLog("[DPE] hydra: NOT AVAILABLE — hydra-synth.js / hydra.html are not in this build")
            NSLog("[DPE] hydra: LIVE = false")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
            return
        }

        // The real sketches out of the real show, so this tests what actually ships.
        var specs: [ContentSpec] = []
        if let url = AppDelegate.bundledTimelineURL(),
           let timeline = try? TimelineLoader.load(from: url) {
            for ev in timeline.events {
                if case .openWindow(let p) = ev.action, p.content.kind == "livecode",
                   let text = p.content.text, p.content.running ?? true,
                   !specs.contains(where: { $0.text == text }) {
                    specs.append(p.content)
                }
            }
        }
        guard !specs.isEmpty else {
            NSLog("[DPE] hydra: no livecode windows in the timeline; nothing to test")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
            return
        }
        // `--sketch=N` puts the Nth sketch in the captured window, which is how you ask
        // "did MY patch render?" rather than "did the first one render?".
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--sketch=") }),
           let n = Int(arg.dropFirst("--sketch=".count)), n > 0, n < specs.count {
            specs = Array(specs[n...] + specs[..<n])
        }
        NSLog("[DPE] hydra: patch —\n\(specs[0].text ?? "")")

        // The bar before the drop has nine sketches running AT ONCE, and that — not one
        // canvas in isolation — is the load that decides whether this is affordable.
        // So the test stands up the show's real peak: nine windows, nine live sketches,
        // all drawing, and then reports the bill.
        let peak = 9
        let size = NSSize(width: 420, height: 280)
        // WebKit keeps a cache of idle content processes, and other apps have their own,
        // so an absolute count says nothing about what WE cost. Measure the delta.
        let before = AppDelegate.webContentUsage()
        HydraWeb.prewarm(count: peak)

        // The whole content view, not a bare canvas: the sketch has to end up UNDER
        // the source, the prompt, the toolbar and the chrome, and building it the way
        // the show builds it is the only way to catch a canvas that covers the code.
        var hosts: [NSWindow] = []
        for i in 0..<peak {
            let column = i % 3, row = i / 3
            let origin = NSPoint(x: 60 + CGFloat(column) * (size.width + 12),
                                 y: 80 + CGFloat(row) * (size.height + 12))
            let host = NSWindow(contentRect: NSRect(origin: origin, size: size),
                                styleMask: [.borderless], backing: .buffered, defer: false)
            host.backgroundColor = .black
            host.contentView = makeEffectContentView(specs[i % specs.count], size: size)
            host.orderFrontRegardless()
            hosts.append(host)
        }
        NSLog("[DPE] hydra: \(hosts.count) sketches live at once")
        guard let host = hosts.first else {
            NSLog("[DPE] hydra: no canvas; LIVE = false")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
            return
        }

        // Two and a half seconds: enough for the page, the GL context and a few hundred
        // frames, so a sketch whose first frame is legitimately black has moved on.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            guard let shot = CGWindowListCreateImage(.null, .optionIncludingWindow,
                                                     CGWindowID(host.windowNumber),
                                                     [.boundsIgnoreFraming, .bestResolution]) else {
                NSLog("[DPE] hydra: capture failed; LIVE = unknown")
                NSApp.terminate(nil); return
            }
            let rep = NSBitmapImageRep(cgImage: shot)
            var lit = 0, total = 0
            var hues = Set<Int>()
            for y in stride(from: 0, to: shot.height, by: 5) {
                for x in stride(from: 0, to: shot.width, by: 5) {
                    total += 1
                    guard let px = rep.colorAt(x: x, y: y) else { continue }
                    if px.brightnessComponent > 0.06 {
                        lit += 1
                        hues.insert(Int(px.hueComponent * 12))
                    }
                }
            }
            let percent = total > 0 ? 100.0 * Double(lit) / Double(total) : 0
            // "%@", not the string itself: NSLog re-reads its first argument as a
            // format, so a percent sign that survived String(format:) is eaten twice.
            NSLog("%@", String(format: "[DPE] hydra: %.1f%% of the canvas is lit, %d distinct hues",
                               percent, hues.count))
            NSLog("[DPE] hydra: LIVE = \(percent > 2)  (expect true)")
            AppDelegate.reportWebContentCost(canvases: hosts.count, before: before)
            if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--test-hydra=") }) {
                let path = String(arg.dropFirst("--test-hydra=".count))
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                    NSLog("[DPE] hydra: wrote \(path)")
                }
            }
            NSApp.terminate(nil)
        }
    }

    /// Every WebContent process on the machine, with its memory and CPU. Meaningless
    /// on its own — WebKit keeps a cache of idle content processes and every other app
    /// has its own — so only ever read as a delta against a baseline.
    static func webContentUsage() -> (count: Int, kb: Double, cpu: Double) {
        let task = Process()
        task.launchPath = "/bin/ps"
        task.arguments = ["-axo", "rss=,pcpu=,comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        guard (try? task.run()) != nil else { return (0, 0, 0) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let lines = (String(data: data, encoding: .utf8) ?? "")
            .components(separatedBy: "\n")
            .filter { $0.contains("com.apple.WebKit.WebContent") }
        var kb = 0.0, cpu = 0.0
        for line in lines {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            if fields.count >= 2 {
                kb += Double(fields[0]) ?? 0
                cpu += Double(fields[1]) ?? 0
            }
        }
        return (lines.count, kb, cpu)
    }

    static func reportWebContentCost(canvases: Int, before: (count: Int, kb: Double, cpu: Double)) {
        let now = webContentUsage()
        let lines = (count: now.count - before.count, kb: now.kb - before.kb)
        let totalKB = lines.kb, totalCPU = now.cpu - before.cpu
        // CPU across every WebContent process, with all nine sketches drawing. This is
        // the number that decides the feature: a Mac has 100% per core, so this is read
        // against the core count, and against how much the pump still needs.
        NSLog("%@", String(format: "[DPE] hydra: %d live sketches -> +%d process(es), +%.0f MB, +%.0f%% CPU (machine had %d before)",
                           canvases, lines.count, totalKB / 1024.0, totalCPU, before.count))
    }

    private func runMapSelfTest() {
        let spec = MapSpec(lat: 31.2397, lon: 121.4998, toLat: 31.2410, toLon: 121.5100,
                           altitude: 1600, toAltitude: 420, pitch: 72, toPitch: nil,
                           heading: 250, toHeading: 40, seconds: 6, style: "flyover")
        let size = NSSize(width: 640, height: 420)
        let view = MapFlyView(size: size, spec: spec)
        let host = NSWindow(contentRect: NSRect(origin: NSPoint(x: -5000, y: -5000), size: size),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.contentView = view
        host.orderBack(nil)

        guard let map = view.subviews.compactMap({ $0 as? MKMapView }).first else {
            NSLog("[DPE] map: MKMapView MISSING — the content view never built")
            NSApp.terminate(nil); return
        }
        let a = map.camera
        NSLog(String(format: "[DPE] map t=0.0  heading=%.1f altitude=%.0f pitch=%.1f center=(%.4f, %.4f)",
                     a.heading, a.centerCoordinateDistance, a.pitch,
                     a.centerCoordinate.latitude, a.centerCoordinate.longitude))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            let b = map.camera
            NSLog(String(format: "[DPE] map t=2.5  heading=%.1f altitude=%.0f pitch=%.1f center=(%.4f, %.4f)",
                         b.heading, b.centerCoordinateDistance, b.pitch,
                         b.centerCoordinate.latitude, b.centerCoordinate.longitude))
            let moved = abs(a.heading - b.heading) > 1
                || abs(a.centerCoordinateDistance - b.centerCoordinateDistance) > 10
            NSLog("[DPE] map FLYING = \(moved)  (expect true)")
            NSLog("[DPE] map tiles need the network; this test only proves the camera moves")
            NSApp.terminate(nil)
        }
    }

    /// Headless checks for the sprite/trail math: frame parsing, pool assignment
    /// (deterministic + stable), and stamp pen-up gating.
    private func runSpriteSelfTest() {
        let frames = [["X.X", ".X.", "..."], [".X.", "X.X", "..X"]]
        let offsets = WindowManager.spriteFrameOffsets(frames, strideX: 10, strideY: 10)
        NSLog("[DPE] sprite parse: lit=\(offsets.map(\.count)) (expect [3, 4])")

        // Assignment: every target gets a window; a window already near a target
        // keeps it (stability), and repeated runs are identical (determinism).
        let prev: [CGPoint?] = [CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 0), nil, nil]
        let targets = [CGPoint(x: 22, y: 2), CGPoint(x: 1, y: 1), CGPoint(x: 50, y: 50)]
        let a = WindowManager.assignCells(targets: targets, previous: prev)
        let b = WindowManager.assignCells(targets: targets, previous: prev)
        let deterministic = zip(a, b).allSatisfy { $0 == $1 }
        let assignedCount = a.compactMap { $0 }.count
        let stable = a[0] == CGPoint(x: 1, y: 1) && a[1] == CGPoint(x: 22, y: 2)
        NSLog("[DPE] sprite assign: deterministic=\(deterministic) assigned=\(assignedCount) (expect 3) stableNearest=\(stable)")

        // Stamp gating: normal travel stamps, a warp-sized jump is pen-up (-1).
        let s1 = WindowManager.stampCount(dist: 30, spacing: 28)
        let s2 = WindowManager.stampCount(dist: 90, spacing: 28)
        let s3 = WindowManager.stampCount(dist: 400, spacing: 28)
        NSLog("[DPE] stamp gating: near=\(s1) (expect 1) fast=\(s2) (expect 3) jump=\(s3) (expect -1)")
    }

    /// Headless checks for the icon layout math + parser, then a real snapshot probe
    /// (which reports whether Automation → Finder is granted).
    private func runIconSelfTest() {
        let raw = "Screenshot.png\t120\t80\nNotes.txt\t300\t260\nProject\t540\t80\n"
        let parsed = DesktopIconController.parse(raw)
        NSLog("[DPE] parse: \(parsed.count) icons (expect 3): \(parsed.map { "\($0.name)@\(Int($0.pos.x)),\(Int($0.pos.y))" })")

        let names = ["A", "B", "C", "D", "E"]
        let bounds = CGSize(width: 1440, height: 900)
        let a = DesktopIconController.layout("scatter", names: names, seed: 42, bounds: bounds)
        let b = DesktopIconController.layout("scatter", names: names, seed: 42, bounds: bounds)
        let deterministic = zip(a, b).allSatisfy { $0.1 == $1.1 }
        let inBounds = a.allSatisfy { $0.1.x >= 0 && $0.1.x <= bounds.width && $0.1.y >= 0 && $0.1.y <= bounds.height }
        NSLog("[DPE] scatter deterministic=\(deterministic) inBounds=\(inBounds): \(a.map { "\($0.0):\(Int($0.1.x)),\(Int($0.1.y))" })")
        let circle = DesktopIconController.layout("circle", names: names, seed: 1, bounds: bounds)
        NSLog("[DPE] circle: \(circle.map { "\($0.0):\(Int($0.1.x)),\(Int($0.1.y))" })")

        // Real probe — needs Automation → Finder. Times the snapshot, then does a
        // single-icon move → readback → restore roundtrip to prove reversibility.
        let icons = DesktopIconController()
        let t0 = Date()
        guard icons.snapshot() else {
            NSLog("[DPE] LIVE snapshot unavailable (Automation not granted / no desktop icons). error=\(icons.lastError ?? "none")")
            return
        }
        NSLog(String(format: "[DPE] LIVE snapshot OK — %d icons in %.2fs", icons.snapshotIcons.count, Date().timeIntervalSince(t0)))

        guard let first = icons.snapshotIcons.first else { return }
        let bnds = DesktopIconController.desktopBounds()
        let orig = first.pos
        let testPos = CGPoint(x: min(max(orig.x + 260, 90), bnds.width - 90),
                              y: min(max(orig.y + 180, 90), bnds.height - 90))
        NSLog("[DPE] roundtrip icon: \"\(first.name)\" orig=(\(Int(orig.x)),\(Int(orig.y))) → test=(\(Int(testPos.x)),\(Int(testPos.y)))")
        icons.setPosition(name: first.name, to: testPos)
        let moved = icons.getPosition(name: first.name) ?? .zero
        icons.setPosition(name: first.name, to: orig)
        let back = icons.getPosition(name: first.name) ?? .zero
        let movedOK = abs(moved.x - testPos.x) <= 2 && abs(moved.y - testPos.y) <= 2
        let restoredOK = abs(back.x - orig.x) <= 2 && abs(back.y - orig.y) <= 2
        NSLog("[DPE] roundtrip: moved=(\(Int(moved.x)),\(Int(moved.y))) movedOK=\(movedOK)  restored=(\(Int(back.x)),\(Int(back.y))) restoredOK=\(restoredOK)")
    }

    /// Phase 4 checks: wallpaper snapshot→swap→restore roundtrip, and a jiggle that
    /// oscillates then settles exactly back to its base origin.
    private func runPhase4SelfTest() {
        // Wallpaper: verify it is DISABLED by default and does NOT touch the desktop.
        // (Swap is opt-in via meta.allowWallpaper because it can't be reliably restored
        // on modern macOS — see WallpaperController.)
        let wp = WallpaperController() // enabled == false by default
        let before = NSWorkspace.shared.desktopImageURL(for: NSScreen.main!)
        wp.set(WallpaperParams(path: nil, color: "#3311AA", screen: nil)) // should be skipped
        let after = NSWorkspace.shared.desktopImageURL(for: NSScreen.main!)
        NSLog("[DPE] wallpaper disabled-by-default: desktopUnchanged=\(before == after) (expect true)")

        // Jiggle roundtrip
        let wm = WindowManager()
        wm.openWindow(OpenWindowParams(id: "j", screen: 0,
                                       content: ContentSpec(kind: "color", hex: "#00FF88", text: nil, path: nil,
                                                            chrome: nil, title: nil, map: nil),
                                       frame: [400, 300, 200, 150], animate: AnimateSpec(kind: "none")),
                     at: 0)
        guard let base = wm.frameOrigin(id: "j") else { NSLog("[DPE] jiggle: no window"); return }
        wm.beginJiggle(JiggleParams(id: "j", durationBeats: nil, durationSeconds: 1.0, amplitude: 20, frequency: 8),
                       at: 0, bpm: 120)
        var maxOffset = 0.0
        for t in stride(from: 0.0, through: 1.05, by: 0.05) {
            wm.update(now: t)
            if let o = wm.frameOrigin(id: "j") {
                maxOffset = max(maxOffset, hypot(o.x - base.x, o.y - base.y))
            }
        }
        let settled = wm.frameOrigin(id: "j")
        let settledOK = settled.map { abs($0.x - base.x) < 0.001 && abs($0.y - base.y) < 0.001 } ?? false
        NSLog(String(format: "[DPE] jiggle: base=(%.0f,%.0f) maxOffset=%.1fpx (expect ~20) settledBackOK=%@",
                     base.x, base.y, maxOffset, settledOK ? "true" : "false"))
        wm.closeAll()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        // Reversibility gate: never leave the desktop altered.
        engine.stopAndRestore()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
