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

        // Does the map actually fly? Builds a real MapFlyView off-screen, samples the
        // camera at t0 and again a couple of seconds later, and reports whether the
        // pose moved. (Tiles are a separate question — that needs the network.)
        if CommandLine.arguments.contains("--test-map") {
            runMapSelfTest()
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
            if let url = Bundle.module.url(forResource: "timeline", withExtension: "json") {
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
        } else if let bundled = Bundle.module.url(forResource: "timeline", withExtension: "json") {
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
            gate = IntroGateController(
                onStart: { [weak self] in self?.controller?.startShow() },
                onExit: { NSApp.terminate(nil) })
            gate?.present()
        }

        // Self-test path: play the whole show with fire logging, then panic-restore
        // and quit. Verifies clock → scheduler → executors → restore end to end.
        if args.contains("--autoplay") {
            engine.enableFiringLog()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                NSLog("[DPE] --autoplay: starting show")
                self.engine.play()
                let cap = ProcessInfo.processInfo.environment["DPE_AUTOPLAY_SECS"].flatMap(Double.init)
                let quitAfter = cap ?? (self.engine.duration + 2.5)
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

    /// First sprite event in a timeline, for `--snapshot` sprite rendering.
    static func firstSprite(in path: String) -> SpriteParams? {
        guard let tl = try? TimelineLoader.load(from: URL(fileURLWithPath: path)) else { return nil }
        for ev in tl.events {
            if case .sprite(let p) = ev.action { return p }
        }
        return nil
    }

    /// Build a real map window off-screen and watch its camera for a couple of
    /// seconds. Proves the flight is running independently of the pump.
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
                                       frame: [400, 300, 200, 150], animate: AnimateSpec(kind: "none")))
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
