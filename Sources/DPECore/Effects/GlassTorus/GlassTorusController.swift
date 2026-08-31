import AppKit
import MetalKit

/// A tumbling glass or mirror-metal torus in a borderless, fully transparent window,
/// refracting the viewer's desktop picture, driven by the show clock.
///
/// - MTKView is `isPaused` and drawn from `update(now:)` with `elapsed` written from
///   the timeline position: the tumble scrubs with the playhead, freezes when the
///   transport stops, and is identical take to take.
/// - The reflection is a picture, not a capture — see `ScreenEnvironment`.
/// - Metal is built lazily, so a show that never opens a torus does not pay for it.
///
/// **Reversibility.** One window, no cursor warp, no icon moves. `closeAll()` closes it,
/// which is what the panic hotkey reaches.
///
/// Like the other executors, every method here is called on the main thread by the
/// display pump — see `EventContext.execute`.
final class GlassTorusController {
    private struct Torus {
        let id: String
        let window: TorusWindow
        let view: TorusView
        let renderer: TorusRenderer
        let speed: Double
        /// Timeline position the event fired at, so `elapsed` starts from zero.
        let startTime: Double
        var endTime: Double?
    }

    private var torus: Torus?

    /// Built once and kept: pipeline compilation and the studio environment texture are
    /// expensive, and a show may open and close a torus several times.
    private var device: MTLDevice?
    private var scene: TorusScene?
    private var environment: ScreenEnvironment?
    private var environmentLoaded = false

    var bpm: Double = 120

    /// Supplies the desktop picture the metal reflects. Set by `PerformanceEngine`, so
    /// the torus can reach the wallpaper snapshot without holding the controller that
    /// owns it — and so a show with no `deskWallpaper` still gets the live wallpaper.
    var desktopPictureURL: ((NSScreen?) -> URL?)?

    // MARK: - Lifecycle

    func begin(_ p: GlassTorusParams, at now: Double, bpm: Double) {
        // One torus at a time; a second event replaces the first.
        if torus != nil { teardown() }

        guard let scene = ensureScene(), let environment else {
            NSLog("[DPE] glassTorus: no Metal device or pipeline — event ignored")
            return
        }

        let renderer = TorusRenderer(scene: scene, environment: environment)
        if let name = p.material,
           let preset = MaterialPreset.all.first(where: { $0.name == name }) {
            renderer.preset = preset
        }
        renderer.roughness = Float(min(1.0, max(0.0, p.roughness ?? 0.04)))
        renderer.planeDistance = Float(min(20.0, max(0.6, p.planeDistance ?? 2.0)))

        let frame = self.frame(for: p)
        let view = TorusView(frame: NSRect(origin: .zero, size: frame.size), device: scene.device)
        view.colorPixelFormat = TorusScene.colorFormat
        view.depthStencilPixelFormat = TorusScene.depthFormat
        view.sampleCount = TorusScene.sampleCount
        view.delegate = renderer
        // The show clock drives every frame; MTKView must not also run its own timer,
        // or the tumble would advance while the transport is stopped.
        view.isPaused = true
        view.enableSetNeedsDisplay = false

        let window = TorusWindow(contentRect: frame, styleMask: [.borderless],
                                 backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // Scenery: every click passes through to whatever is underneath, torus pixels
        // included. It cannot be clicked, so it cannot be dragged either.
        window.ignoresMouseEvents = true
        window.isMovable = false
        window.isMovableByWindowBackground = false
        switch p.level ?? "screenSaver" {
        case "normal":   window.level = .normal
        case "floating": window.level = .floating
        default:         window.level = .screenSaver
        }
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                     .stationary, .ignoresCycle]
        window.contentView = view
        // orderFront, never makeKey — the control window keeps focus (see TorusWindow).
        window.orderFront(nil)

        let duration = Beats.seconds(p.durationBeats, or: p.durationSeconds, bpm: bpm)
        torus = Torus(id: p.id, window: window, view: view, renderer: renderer,
                      speed: p.speed ?? 1.0, startTime: now,
                      endTime: duration.map { now + $0 })

        // Once per run: the picture does not change, and a second torus reuses the
        // texture the first one loaded. The load is async and non-blocking — the torus
        // renders against the studio environment until it lands, and keeps rendering
        // against it if there is no readable wallpaper file.
        if !environmentLoaded {
            environmentLoaded = true
            environment.start(desktopPicture: desktopPictureURL?(window.screen),
                              on: window.screen)
        }
    }

    /// Matches `closeWindow` by id, the same way an open-ended `sprite` is ended.
    func stop(id: String) {
        guard torus?.id == id else { return }
        teardown()
    }

    /// Idempotent. Closes the window; the loaded environment is kept, since a later
    /// torus in the same run reflects the same desktop picture.
    func closeAll() {
        teardown()
    }

    private func teardown() {
        guard let t = torus else { return }
        t.view.delegate = nil
        t.window.orderOut(nil)
        t.window.close()
        torus = nil
    }

    // MARK: - Tick

    func update(now: Double) {
        guard var t = torus else { return }

        if let end = t.endTime, now >= end {
            teardown()
            return
        }

        // Straight from the timeline — no accumulation, so a seek lands on exactly the
        // frame that position always produces.
        t.renderer.elapsed = max(0, (now - t.startTime) * t.speed)
        torus = t
        t.view.draw()
    }

    // MARK: - Setup

    /// Metal device + pipeline + environment, built on first use. Returns nil on a Mac
    /// with no Metal GPU or a pipeline that won't compile; the event is then skipped
    /// rather than taking the show down.
    private func ensureScene() -> TorusScene? {
        if let scene { return scene }
        guard let device = device ?? MTLCreateSystemDefaultDevice() else { return nil }
        self.device = device
        do {
            let scene = try TorusScene(device: device)
            self.scene = scene
            self.environment = try ScreenEnvironment(device: device)
            return scene
        } catch {
            NSLog("[DPE] glassTorus: \(error)")
            return nil
        }
    }

    /// Authored `frame` wins; otherwise the standalone app's sizing — 72% of the
    /// screen's shorter side, clamped to 560…1100 — centred.
    private func frame(for p: GlassTorusParams) -> NSRect {
        let screen = ScreenGeometry.screen(p.screen)
        let sf = screen.frame
        let side = p.size ?? max(560, min(1100, (min(sf.width, sf.height) * 0.72).rounded()))
        return ScreenGeometry.rectOrCentred(p.frame, size: NSSize(width: side, height: side),
                                            on: screen)
    }
}
