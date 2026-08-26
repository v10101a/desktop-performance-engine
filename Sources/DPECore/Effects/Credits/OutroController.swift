import AppKit
import QuartzCore

/// How the piece actually ends.
///
/// The credits finish typing, and then the machine appears to give up: a force-quit
/// alert, a half-second of the screen tearing itself apart, a boot bar, and the app is
/// gone. Both alert buttons do the same thing — the choice is scenery, the machine has
/// already decided.
///
/// **Everything here runs on wall-clock timers, not the show clock.** The end card is
/// authored on the last beat, so by the time any of this happens the engine has hit its
/// end-of-piece branch, called `pause()` and stopped the pump — a transport-driven
/// sequence would never advance. See `CreditsController.startTyping` for the same
/// reasoning applied to the typing itself.
///
/// **Reversibility.** Windows only, plus the final `NSApp.terminate`, which routes
/// through `applicationWillTerminate` → `engine.stopAndRestore()`. The desktop is put
/// back before the process goes; quitting is not a way to skip the restore.
final class OutroController {
    /// Called when the boot bar has filled. The app quits from here.
    var onFinished: (() -> Void)?

    private var windows: [NSWindow] = []
    private var timers: [Timer] = []
    /// Pre-rendered glitch frames, built while the alert is on screen so the half-second
    /// itself never waits on a screen capture.
    private var glitchFrames: [CGImage] = []
    private var started = false

    var glitchSeconds: Double = 0.5
    var bootSeconds: Double = 5.0
    var appName: String = "GiveIt2Me_DJ_Dave_malware"

    // MARK: - Prewarm

    /// Grab the screen and render the glitch frames ahead of time.
    ///
    /// Kicked off when the credits finish typing — the capture is async and permission
    /// gated, and half a second is not enough to do it in. If the capture fails (no
    /// Screen Recording grant, no display) the frames are synthesised instead, so the
    /// sequence looks the same and never stalls.
    func prewarmGlitch(screen: NSScreen) {
        let displayID = WallpaperImage.displayID(of: screen)
        let size = screen.frame.size
        // Only the display ID crosses into the task — NSScreen isn't Sendable — and the
        // hop back is `DispatchQueue.main.async` with a weak `self`, matching
        // `WallpaperController.applyRecursive`. (Both carry the same Swift 6 "capture of
        // non-Sendable self" warning; this is the house pattern, not a new exception.)
        // The glitch pass runs in the task, off the main thread: six frames at 1600px is
        // far too much to do on the main thread while the alert is up.
        Task.detached(priority: .userInitiated) { [weak self] in
            var source: CGImage?
            if let id = displayID { source = try? await WallpaperImage.captureDisplay(id) }
            let rendered = OutroController.renderGlitchFrames(from: source, size: size)
            DispatchQueue.main.async {
                guard let me = self else { return }
                me.glitchFrames = rendered
            }
        }
    }

    /// The dump frames.
    ///
    /// Not the `GlitchImage` engine the wallpaper uses — that one is analogue in
    /// character (sine warps, chroma bleed, scanlines), which reads as a broken CRT.
    /// This wants the opposite: a memory dump. Chunky whole pixels, one bit per channel,
    /// and corruption that moves in aligned blocks rather than smooth waves.
    ///
    /// Three passes, in order:
    ///
    /// 1. **Pixelate.** The capture is drawn into a grid `dumpColumns` wide with
    ///    interpolation off, so every cell is one flat colour.
    /// 2. **Hard contrast.** Each channel is thresholded to 0 or 255 — an eight-colour
    ///    palette, no gradients anywhere.
    /// 3. **Corrupt.** Whole rows slip sideways by a whole number of cells, runs are
    ///    overwritten with a repeating 4-cell pattern lifted from elsewhere in the
    ///    buffer, and other runs are flattened to black or white. Everything lands on
    ///    the cell grid, which is what makes it read as memory rather than as noise.
    private static func renderGlitchFrames(from source: CGImage?, size: NSSize) -> [CGImage] {
        let cols = dumpColumns
        let rows = max(2, Int((Double(cols) * size.height / max(size.width, 1)).rounded()))
        guard let small = downsample(source, cols: cols, rows: rows) else { return [] }
        return (0..<dumpFrameCount).compactMap { i in
            var buf = small
            var rng = SplitMix64(seed: 0x5EED &+ UInt64(i) &* 7919)
            threshold(&buf)
            corrupt(&buf, cols: cols, rows: rows, rng: &rng,
                    // The dump is worst on the first frame and calms from there.
                    intensity: 1.0 - Double(i) / Double(dumpFrameCount) * 0.6)
            return makeImage(buf, cols: cols, rows: rows)
        }
    }

    /// Frames for the still renderer, from an arbitrary source image rather than a live
    /// screen capture — the dump is the one outro surface with no other way to preview it.
    static func previewFrames(from source: CGImage?, size: NSSize) -> [CGImage] {
        renderGlitchFrames(from: source, size: size)
    }

    /// Grid width in cells. 128 across a 16:10 screen is ~15 px per cell at 1920 — big
    /// enough to read as deliberate pixelation rather than a low-res image.
    private static let dumpColumns = 128
    private static let dumpFrameCount = 8

    /// Screen (or stand-in) into a `cols × rows` RGBA8 buffer, nearest-neighbour.
    private static func downsample(_ source: CGImage?, cols: Int, rows: Int) -> [UInt8]? {
        let cg = source ?? synthesisedSource()
        var buf = [UInt8](repeating: 0, count: cols * rows * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = buf.withUnsafeMutableBytes({ raw in
            CGContext(data: raw.baseAddress, width: cols, height: rows, bitsPerComponent: 8,
                      bytesPerRow: cols * 4, space: space, bitmapInfo: info)
        }) else { return nil }
        ctx.interpolationQuality = .none        // flat cells, not a blurred thumbnail
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cols, height: rows))
        guard let data = ctx.data else { return nil }
        let p = data.bindMemory(to: UInt8.self, capacity: cols * rows * 4)
        return Array(UnsafeBufferPointer(start: p, count: cols * rows * 4))
    }

    /// One bit per channel. Everything mid-grey snaps to a corner of the colour cube.
    private static func threshold(_ buf: inout [UInt8]) {
        for i in stride(from: 0, to: buf.count, by: 4) {
            buf[i]     = buf[i]     < 128 ? 0 : 255
            buf[i + 1] = buf[i + 1] < 128 ? 0 : 255
            buf[i + 2] = buf[i + 2] < 128 ? 0 : 255
            buf[i + 3] = 255
        }
    }

    private static func corrupt(_ buf: inout [UInt8], cols: Int, rows: Int,
                                rng: inout SplitMix64, intensity: Double) {
        let stride4 = cols * 4
        func cell(_ x: Int, _ y: Int) -> Int { y * stride4 + x * 4 }

        // Rows slip sideways by whole cells — the classic torn-scanline of a bad read,
        // but quantised to the grid.
        for y in 0..<rows where rng.chance(0.35 * intensity) {
            let shift = rng.int(1...max(1, cols / 3))
            let row = Array(buf[cell(0, y)..<cell(0, y) + stride4])
            for x in 0..<cols {
                let src = ((x + shift) % cols) * 4
                for c in 0..<4 { buf[cell(x, y) + c] = row[src + c] }
            }
        }

        // Runs overwritten with a 4-cell pattern read from somewhere else in the buffer:
        // the same bytes repeating is what a dump of structured memory looks like.
        let runs = Int(Double(rows) * 0.5 * intensity)
        for _ in 0..<max(0, runs) {
            let y = rng.int(0...(rows - 1))
            let x0 = rng.int(0...(cols - 1))
            let len = rng.int(4...max(4, cols / 2))
            let sy = rng.int(0...(rows - 1)), sx = rng.int(0...(cols - 4))
            var pattern = [UInt8]()
            for k in 0..<4 { pattern.append(contentsOf: buf[cell(sx + k, sy)..<cell(sx + k, sy) + 4]) }
            for k in 0..<len {
                let x = x0 + k
                guard x < cols else { break }
                let src = (k % 4) * 4
                for c in 0..<4 { buf[cell(x, y) + c] = pattern[src + c] }
            }
        }

        // Dead runs: all bits low or all bits high.
        let dead = Int(Double(rows) * 0.3 * intensity)
        for _ in 0..<max(0, dead) {
            let y = rng.int(0...(rows - 1))
            let x0 = rng.int(0...(cols - 1))
            let len = rng.int(2...max(2, cols / 4))
            let v: UInt8 = rng.chance(0.5) ? 0 : 255
            for k in 0..<len {
                let x = x0 + k
                guard x < cols else { break }
                buf[cell(x, y)] = v; buf[cell(x, y) + 1] = v; buf[cell(x, y) + 2] = v
            }
        }
    }

    private static func makeImage(_ buf: [UInt8], cols: Int, rows: Int) -> CGImage? {
        var data = buf
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        return data.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(data: raw.baseAddress, width: cols, height: rows,
                                      bitsPerComponent: 8, bytesPerRow: cols * 4,
                                      space: space, bitmapInfo: info) else { return nil }
            return ctx.makeImage()
        }
    }

    /// Stand-in when the screen can't be captured: hard blue-and-white bands, the same
    /// two colours the end card's tile is built from.
    private static func synthesisedSource() -> CGImage {
        let w = 128, h = 80
        var buf = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            let on = (y / 3) % 2 == 0
            for x in 0..<w {
                let i = (y * w + x) * 4
                buf[i] = on ? 0 : 255
                buf[i + 1] = on ? 40 : 255
                buf[i + 2] = 255
                buf[i + 3] = 255
            }
        }
        return makeImage(buf, cols: w, rows: h)!
    }

    // MARK: - Sequence

    /// Step 1: the machine says it has stopped responding.
    func begin(on screen: NSScreen) {
        guard !started else { return }
        started = true
        let sf = screen.frame
        // 560 wide: the real macOS phrasing plus this app's long name truncates at 460.
        let size = NSSize(width: 560, height: 172)
        let alert = FakeDialogWindow(
            contentRect: NSRect(x: sf.midX - size.width / 2, y: sf.midY - size.height / 2,
                                width: size.width, height: size.height),
            title: "“\(appName)” is not responding.",
            message: "The application is not responding. Do you want to force quit?",
            buttons: ["Wait", "Force Quit"], icon: .caution)
        // Both buttons, same ending. Whichever the viewer picks, the machine goes.
        for b in alert.contentView?.subviews.compactMap({ $0 as? NSButton }) ?? [] {
            b.target = self
            b.action = #selector(chosen)
        }
        alert.present(animate: "springIn")
        windows.append(alert)
        prewarmGlitch(screen: screen)
    }

    @objc private func chosen() {
        // Once. A double-click on the alert must not start two sequences.
        guard let alert = windows.first else { return }
        alert.orderOut(nil)
        windows.removeAll()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { finish(); return }
        runGlitch(on: screen)
    }

    /// Step 2: half a second of the screen coming apart.
    private func runGlitch(on screen: NSScreen) {
        let sf = screen.frame
        let win = BaseEffectWindow(contentRect: sf)
        win.ignoresMouseEvents = true
        win.hasShadow = false
        // A layer, not an NSImageView: `magnificationFilter = .nearest` is what keeps the
        // cells hard-edged when a 128-wide buffer is blown up to a 5K display. Any
        // smoothing here and the whole point of the pixelation is lost.
        let host = NSView(frame: NSRect(origin: .zero, size: sf.size))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.black.cgColor
        host.layer?.magnificationFilter = .nearest
        host.layer?.contentsGravity = .resize
        host.layer?.contents = glitchFrames.first
        win.contentView = host
        win.present(animate: "none")
        windows.append(win)

        // Flip frames across the half second; if the capture never landed there are no
        // frames and this is simply a black flash of the same length.
        let frames = glitchFrames
        if !frames.isEmpty {
            let step = glitchSeconds / Double(frames.count)
            for (i, frame) in frames.enumerated() {
                after(step * Double(i)) { host.layer?.contents = frame }
            }
        }
        after(glitchSeconds) { [weak self] in
            win.orderOut(nil)
            self?.windows.removeAll { $0 === win }
            self?.runBoot(on: screen)
        }
    }

    /// Step 3: the boot bar — the same `BootView` the fake reboot uses, driven here by a
    /// timer rather than the (stopped) pump.
    private func runBoot(on screen: NSScreen) {
        let sf = screen.frame
        let win = BaseEffectWindow(contentRect: sf)
        win.ignoresMouseEvents = true
        win.hasShadow = false
        win.isOpaque = true
        win.backgroundColor = .black
        let view = BootView(size: sf.size, glyph: "\u{F8FF}", color: .white)
        view.showsBar = true
        win.contentView = view
        win.present(animate: "none")
        windows.append(win)

        let start = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let p = min(1.0, (CACurrentMediaTime() - start) / self.bootSeconds)
            view.progress = p
            if p >= 1.0 {
                timer.invalidate()
                // A beat on the full bar before the screen goes, or the quit reads as a
                // crash rather than the machine finishing.
                self.after(0.6) { self.finish() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timers.append(t)
    }

    /// Step 4: gone.
    private func finish() {
        onFinished?()
    }

    // MARK: - Plumbing

    /// `Timer` rather than `asyncAfter` so `closeAll` can cancel a sequence in flight —
    /// Stop and the panic hotkey have to be able to take the show down mid-outro.
    private func after(_ delay: Double, _ body: @escaping () -> Void) {
        let t = Timer(timeInterval: max(0.001, delay), repeats: false) { _ in body() }
        RunLoop.main.add(t, forMode: .common)
        timers.append(t)
    }

    func closeAll() {
        for t in timers { t.invalidate() }
        timers.removeAll()
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        glitchFrames.removeAll()
        started = false
    }
}
