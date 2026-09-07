import AppKit
import ImageIO
import MapKit
import WebKit

/// Decoded-thumbnail cache. Decoding a large Retina screenshot/HEIC on the main
/// thread blocks the pump for 100+ ms; we decode downsampled thumbnails on a
/// background queue (ImageIO is thread-safe) and cache them. NSCache evicts under
/// memory pressure.
private let dpeImageCache = NSCache<NSString, NSImage>()
private let dpeImageQueue = DispatchQueue(label: "com.computerart.dpe.img",
                                          qos: .userInitiated, attributes: .concurrent)

/// Fill an image view from disk without ever blocking the main thread. Cache hits
/// are set immediately; misses decode a thumbnail off-thread, then set on main.
private func loadImageAsync(_ path: String, into imageView: NSImageView) {
    if let cached = dpeImageCache.object(forKey: path as NSString) {
        imageView.image = cached
        return
    }
    dpeImageQueue.async { [weak imageView] in
        guard let image = decodeThumbnail(path, maxPixel: 800) else { return }
        dpeImageCache.setObject(image, forKey: path as NSString)
        DispatchQueue.main.async { imageView?.image = image }
    }
}

/// Tear an image once, off the main thread, and hand the result to a view.
/// Cached by path AND settings — the tear is a pure function of (image, intensity,
/// seed) — and rendered at 512 on the long edge: these are window-sized, not wallpaper.
private func loadGlitchImageAsync(_ path: String, intensity: Double, seed: UInt64,
                                  into imageView: NSImageView) {
    let key = "\(path)|glitch|\(intensity)|\(seed)" as NSString
    if let cached = dpeImageCache.object(forKey: key) {
        imageView.image = cached
        return
    }
    dpeImageQueue.async { [weak imageView] in
        // Resolved for the same reason as `decodeThumbnail` — a torn card whose source
        // cannot be found is another black frame.
        guard let source = try? WallpaperImage.load(at: URL(fileURLWithPath: resolveResourcePath(path))),
              let bitmap = try? Bitmap.render(source, maxEdge: 512),
              let torn = try? glitch(bitmap, settings: GlitchSettings(intensity: intensity,
                                                                      seed: seed)),
              let cg = try? torn.makeImage()
        else {
            NSLog("[DPE] glitch content: could not tear \(path)")
            return
        }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        dpeImageCache.setObject(image, forKey: key)
        DispatchQueue.main.async { imageView?.image = image }
    }
}

/// Decode a downsampled thumbnail directly (never fully decodes the source bitmap).
/// `path` is an AUTHORED path ("assets/pixelface.jpg"), so it is resolved here rather
/// than handed to the filesystem as written. Without that it is relative to the process's
/// working directory: fine under `swift run` from the repo, and nothing at all in a
/// double-clicked .app, where the cwd is `/`. An `image` window that cannot find its file
/// keeps the `#111116` ground it was given and comes up as a black frame — which is
/// exactly what the eight faces round the torus were doing.
private func decodeThumbnail(_ path: String, maxPixel: Int) -> NSImage? {
    let resolved = resolveResourcePath(path)
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: resolved) as CFURL, nil) else { return nil }
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        kCGImageSourceCreateThumbnailWithTransform: true
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

/// Terminal.app's default "Basic" profile, as a Mac ships it.
///
/// Shared by the `code` content kind and the system_probe report so the two are
/// literally the same surface rather than two approximations of it.
enum TerminalStyle {
    /// SF Mono 11 — Terminal's default. `monospacedSystemFont` IS SF Mono.
    static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let boldFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
    static let background = NSColor.white
    static let text = NSColor.black
    /// Terminal insets its text by roughly this much from the window edge.
    static let inset: CGFloat = 6

    /// A Terminal window's title: working directory, shell, and the grid size.
    static func title(cols: Int = 80, rows: Int = 24) -> String {
        let user = NSUserName()
        return "\(user) — -zsh — \(cols)×\(rows)"
    }
}

// MARK: - Chrome

/// Smallest window that gets REAL macOS chrome. The title bar is a fixed ~28pt and
/// AppKit enforces no minimum frame, so below this the content area would be nothing
/// at all. Smaller windows render bare; the glass torus is the deliberate exception.
let nativeChromeMinSize = NSSize(width: 44, height: 34)

/// Whether an authored window of this size and chrome should be a real titled window.
func usesNativeChrome(_ chrome: String?, size: NSSize) -> Bool {
    guard chrome != "none" else { return false }
    return fitsNativeChrome(size)
}

/// Whether a window of this size can carry a real title bar without its content area
/// collapsing. Used by the pooled micro-windows, which author no chrome of their own.
func fitsNativeChrome(_ size: NSSize) -> Bool {
    size.width >= nativeChromeMinSize.width && size.height >= nativeChromeMinSize.height
}

/// Content view for a pooled micro-window (sprite pixel / trail breadcrumb).
func makeMicroContentView(size: NSSize, bodyColor: NSColor) -> NSView {
    let view = NSView(frame: NSRect(origin: .zero, size: size))
    view.wantsLayer = true
    view.layer?.backgroundColor = bodyColor.cgColor
    view.layer?.cornerRadius = min(5, size.height * 0.18)
    view.layer?.masksToBounds = true
    view.layer?.borderWidth = 1
    view.layer?.borderColor = NSColor(white: 0, alpha: 0.25).cgColor
    return view
}

// MARK: - Live-coding REPL

/// Tempo of the running show, so generative content can lock its animation periods
/// to the beat. Set by `WindowManager.bpm` when a timeline loads.
var dpeShowBPM: Double = 120

/// A hydra sketch. The patch's own output fills the window — `Hydra` reads the chain
/// and builds the layer stack it describes — with the source over the top in the
/// editor's type: no gutter, a dark box behind each line, numbers in pink. That is
/// what hydra.ojack.xyz looks like while someone is playing it.
///
/// `content.running == false` draws the source over a dead black canvas, the state the
/// page is in before you hit run. Re-opening the same window id with `running: true`
/// swaps in the live version — the show's way of "executing" the code on a click.
func makeLiveCodeContentView(_ content: ContentSpec, size: NSSize) -> NSView {
    let beat = 60.0 / max(40, dpeShowBPM)
    let accent = NSColor(hex: content.hex ?? "#68BDF8") ?? .cyan
    let source = content.text ?? ""
    let running = content.running ?? true

    let root = NSView(frame: NSRect(origin: .zero, size: size))
    root.wantsLayer = true
    root.layer?.backgroundColor = NSColor.black.cgColor
    root.layer?.masksToBounds = true
    root.layer?.cornerRadius = 6

    let body = NSRect(origin: .zero, size: size)
    if running {
        // Real hydra when the library shipped, the Core Animation impression when it
        // didn't; the code, prompt and toolbar are drawn the same way either way.
        if let canvas = HydraWeb.take() {
            canvas.frame = body
            canvas.autoresizingMask = [.width, .height]
            root.addSubview(canvas)
            canvas.run(source)
        } else {
            let visual = Hydra.makeVisual(source: source, size: body.size,
                                          tint: accent, beat: beat)
            // A `moveWindow` resize doesn't rebuild the content, so the sketch has to
            // stretch with the window. (The composition re-centers properly the next
            // time the window is re-opened at its final size.)
            visual.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            root.layer?.addSublayer(visual)
        }
    }

    // --- the source, hydra-style: no line numbers, a dark box behind every line ---
    func codeText(_ pt: CGFloat) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: pt, weight: .regular)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = pt * 0.30
        let box = NSColor(white: 0, alpha: 0.55)
        let code = NSMutableAttributedString()
        for line in source.components(separatedBy: "\n") {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: NSColor(white: 0.96, alpha: 1),
                .paragraphStyle: para, .backgroundColor: box]
            let piece = NSMutableAttributedString(string: line + "\n", attributes: attrs)
            // Numbers pink, the way hydra's editor highlights them.
            if let re = try? NSRegularExpression(pattern: "-?\\d+(\\.\\d+)?") {
                let ns = line as NSString
                for m in re.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                    piece.addAttribute(.foregroundColor, value: NSColor(hex: "#F58AE1") ?? .magenta,
                                       range: m.range)
                }
            }
            code.append(piece)
        }
        return code
    }

    // Shrink to fit: the type gives way; the source stays whole.
    var fontSize = min(max(size.height * 0.045, 6.5), 13)
    var pad = max(6, fontSize * 0.8)
    let label = NSTextField(labelWithAttributedString: codeText(fontSize))
    label.maximumNumberOfLines = 0
    func measure() -> NSSize {
        label.sizeThatFits(NSSize(width: size.width - pad * 2, height: .greatestFiniteMagnitude))
    }
    var fit = measure()
    let room = size.height - pad * 1.2
    while fit.height > room, fontSize > 4.5 {
        fontSize -= 0.5
        pad = max(4, fontSize * 0.8)
        label.attributedStringValue = codeText(fontSize)
        fit = measure()
    }
    let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    label.frame = NSRect(x: pad, y: size.height - fit.height - pad * 0.6,
                         width: size.width - pad * 2, height: fit.height)
    label.autoresizingMask = [.minYMargin, .maxXMargin]   // stays pinned top-left
    root.addSubview(label)

    // The REPL prompt in the bottom-left corner.
    if size.height > 120 {
        let prompt = NSTextField(labelWithAttributedString: NSAttributedString(
            string: running ? ">>" : ">> _", attributes: [
                .font: font, .foregroundColor: NSColor(white: 0.62, alpha: 0.9)]))
        prompt.frame = NSRect(x: pad, y: pad * 0.5, width: 80, height: fontSize * 1.6)
        prompt.autoresizingMask = [.maxYMargin, .maxXMargin]   // stays bottom-left
        root.addSubview(prompt)
    }

    // Hydra's little toolbar, top-right.
    if size.width > 260 {
        let names = ["play.fill", "trash", "puzzlepiece", "shuffle", "die.face.5",
                     "square.and.arrow.up", "questionmark.circle"]
        let g = min(max(size.height * 0.045, 9), 15)
        var x = size.width - pad - g
        for name in names.reversed() {
            guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { continue }
            let iv = NSImageView(frame: NSRect(x: x, y: size.height - pad * 0.6 - g,
                                               width: g, height: g))
            iv.image = img
            iv.contentTintColor = NSColor(white: 1, alpha: 0.85)
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.autoresizingMask = [.minXMargin, .minYMargin]   // stays top-right
            root.addSubview(iv)
            x -= g * 1.7
            if x < size.width * 0.5 { break }
        }
    }

    return root
}

// MARK: - Apple Maps flythrough

/// 0…1 eased in and out — the curve the map's FALL is drawn on.
private func easeInOut(_ u: Double) -> Double {
    u < 0.5 ? 2 * u * u : 1 - pow(-2 * u + 2, 2) / 2
}

/// 0…1 eased in over the first `ramp` of the leg and then CONSTANT — the curve the
/// map's orbit is drawn on. An orbit that eased out would be sitting still by the time
/// the cut came, which is the opposite of the point: the camera has to still be going
/// round the location when the window is taken off the screen. Normalised so the leg
/// still travels exactly `orbitDegrees`.
private func easeInThenSteady(_ u: Double, ramp k: Double = 1.0 / 6.0) -> Double {
    guard u > 0 else { return 0 }
    let raw = u < k ? u * u / (2 * k) : u - k / 2
    return raw / (1 - k / 2)
}


/// A real MKMapView flying its camera between two poses — Apple's own 3-D flyover
/// tiles, inside one of our windows.
///
/// The camera is stepped by a self-owned 30 Hz timer rather than the show's pump: a
/// map redraw is heavy and unpredictable (it waits on tiles), and the pump's budget
/// belongs to the windows that have to hit the beat. It costs a network connection —
/// with no route to Apple's tile servers the window just sits there grey.
final class MapFlyView: NSView {
    private let map = MKMapView()
    private var timer: Timer?

    init(size: NSSize, spec: MapSpec) {
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        map.frame = bounds
        map.autoresizingMask = [.width, .height]
        switch spec.style {
        case "satellite": map.mapType = .satellite
        case "hybrid":    map.mapType = .hybridFlyover
        case "standard":  map.mapType = .standard
        default:          map.mapType = .satelliteFlyover
        }
        // No affordances — it is a shot in a film, not a map the viewer drives.
        map.isZoomEnabled = false
        map.isScrollEnabled = false
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.showsCompass = false
        map.showsZoomControls = false
        addSubview(map)

        // `here`: the viewer's own location, if Location Services gave us one. The
        // authored coordinates are the fallback — the show flies somewhere either way.
        var lat = spec.lat, lon = spec.lon
        var toLat = spec.toLat ?? spec.lat, toLon = spec.toLon ?? spec.lon
        if spec.here == true, let fix = LocationStore.shared.coordinate {
            lat = fix.latitude; lon = fix.longitude
            toLat = fix.latitude; toLon = fix.longitude
        }
        let from = MKMapCamera(lookingAtCenter: CLLocationCoordinate2D(latitude: lat,
                                                                      longitude: lon),
                               fromDistance: spec.altitude ?? 900,
                               pitch: CGFloat(spec.pitch ?? 60),
                               heading: spec.heading ?? 0)
        map.camera = from

        // Two legs of one shot. The FALL — centre, altitude and pitch — lands in
        // `zoomSeconds`; the rest of `seconds` is the ORBIT, `orbitDegrees` of heading
        // turned around the point it landed on. `zoomSeconds` defaults to the whole
        // shot and `orbitDegrees` to none, so a spec written before these existed flies
        // exactly as it did: one eased move filling the duration.
        let duration = max(0.5, spec.seconds ?? 14)
        let fall = min(duration, max(0.1, spec.zoomSeconds ?? duration))
        let orbit = spec.orbitDegrees ?? 0
        let fromAlt = spec.altitude ?? 900
        let fromPitch = CGFloat(spec.pitch ?? 60)
        let fromHeading = spec.heading ?? 0
        let toAlt = spec.toAltitude ?? fromAlt
        let toPitch = CGFloat(spec.toPitch ?? fromPitch)
        let toHeading = spec.toHeading ?? (fromHeading + 90)
        let started = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            let now = Date().timeIntervalSince(started)
            let e = easeInOut(min(1.0, now / fall))
            // The orbit picks the turn up out of the standstill the fall settles into
            // — no kink at the handover — and then holds that rate for the rest of the
            // shot: it is still circling when the cut takes it.
            let spin = duration > fall
                ? easeInThenSteady(min(1.0, max(0, now - fall) / (duration - fall)))
                : 0
            let heading = fromHeading + (toHeading - fromHeading) * e + orbit * spin
            let cam = MKMapCamera(
                lookingAtCenter: CLLocationCoordinate2D(latitude: lat + (toLat - lat) * e,
                                                        longitude: lon + (toLon - lon) * e),
                fromDistance: fromAlt + (toAlt - fromAlt) * e,
                pitch: fromPitch + (toPitch - fromPitch) * CGFloat(e),
                heading: heading.truncatingRemainder(dividingBy: 360))
            self.map.camera = cam
            if now >= duration { t.invalidate() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit { timer?.invalidate() }
}

// MARK: - Content builders (shared by live windows and the still renderer)

/// Build the content view for a pure-visual window: solid color, big text, or image.
/// An optional `chrome` draws a fake title bar and insets the body under it.
func makeEffectContentView(_ content: ContentSpec, size: NSSize) -> NSView {
    // Self-contained: draws its own REPL header and never takes fake chrome.
    if content.kind == "livecode" { return makeLiveCodeContentView(content, size: size) }
    if content.kind == "web", let urlString = content.url, let url = URL(string: urlString) {
        // A real browser view. Needs the network; with no route it just sits blank.
        let config = WKWebViewConfiguration()
        let web = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
        web.autoresizingMask = [.width, .height]
        web.setValue(false, forKey: "drawsBackground")
        web.load(URLRequest(url: url))
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.black.cgColor
        host.layer?.masksToBounds = true
        host.layer?.cornerRadius = 6
        host.addSubview(web)
        return host
    }
    if content.kind == "map", let spec = content.map {
        return MapFlyView(size: size, spec: spec)
    }

    let view = NSView(frame: NSRect(origin: .zero, size: size))
    view.wantsLayer = true
    view.layer?.masksToBounds = true

    // No drawn bar to inset under: a window either wears a REAL title bar (in which
    // case `size` is already the content rect) or none at all.
    let body = NSRect(origin: .zero, size: size)

    switch content.kind {
    case "text":
        view.layer?.backgroundColor = (NSColor(hex: content.hex ?? "#091724") ?? .black).cgColor
        view.layer?.cornerRadius = 6
        let label = NSTextField(labelWithString: content.text ?? "")
        label.font = .systemFont(ofSize: CGFloat(content.fontSize ?? 42), weight: .heavy)
        label.textColor = NSColor(hex: content.fg ?? "#FFFFFF") ?? .white
        label.alignment = .center
        label.maximumNumberOfLines = 0
        label.frame = body
        label.autoresizingMask = [.width, .height]
        view.addSubview(label)
    case "lyric":
        // A lyric-video frame: the ground is a flat colour and the line is set as big
        // as the window allows, wrapped, centred both ways. Fullscreen it is the whole
        // screen going blue with the words on it; at 300pt it is a caption in a clock.
        view.layer?.backgroundColor = (NSColor(hex: content.hex ?? "#0078D7") ?? .systemBlue).cgColor
        view.layer?.cornerRadius = size.width > 600 ? 0 : 6
        let label = NSTextField(labelWithString: content.text ?? "")
        label.textColor = NSColor(hex: content.fg ?? "#FFFFFF") ?? .white
        label.alignment = .center
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        let pad = max(8, min(size.width, size.height) * 0.07)
        let room = NSSize(width: size.width - pad * 2, height: size.height - pad * 2)
        // Shrink to fit: start at a fifth of the height and step down until the
        // wrapped block fits both ways. A word wider than the window wraps mid-word,
        // which reads as broken, so that counts as not fitting too.
        var pt = max(12, size.height * 0.22)
        var fit = NSSize.zero
        while pt > 8 {
            let font = LyricFont.font(ofSize: pt)
            label.font = font
            fit = label.sizeThatFits(NSSize(width: room.width, height: .greatestFiniteMagnitude))
            let widest = (content.text ?? "").split(separator: " ")
                .map { (String($0) as NSString).size(withAttributes: [.font: font]).width }
                .max() ?? 0
            if fit.height <= room.height && widest <= room.width { break }
            pt -= max(1, pt * 0.06)
        }
        label.frame = NSRect(x: pad, y: (size.height - fit.height) / 2,
                             width: room.width, height: fit.height)
        label.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        view.addSubview(label)
    case "code":
        // Terminal.app, "Basic" — the profile a Mac ships with: white background,
        // black text, SF Mono 11. Not a green-on-black hacker terminal; the point is
        // that it is indistinguishable from the real thing sitting next to it.
        //
        // Manual frame (no autolayout) — created at volume during the show.
        // …unless the event asks for another surface. `hex` is the ground and `fg` the
        // type, the same two fields the `text` and `lyric` kinds use, so a terminal can
        // be recoloured per window without every terminal in the piece changing with it.
        let termGround = content.hex.flatMap { NSColor(hex: $0) } ?? TerminalStyle.background
        let termInk = content.fg.flatMap { NSColor(hex: $0) } ?? TerminalStyle.text
        view.layer?.backgroundColor = termGround.cgColor
        view.layer?.cornerRadius = 0            // Terminal has square content corners
        let label = NSTextField(wrappingLabelWithString: content.text ?? "")
        label.font = TerminalStyle.font
        label.textColor = termInk
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.alignment = .left
        label.frame = NSRect(x: TerminalStyle.inset, y: TerminalStyle.inset,
                             width: body.width - TerminalStyle.inset * 2,
                             height: body.height - TerminalStyle.inset * 2)
        label.autoresizingMask = [.width, .height]
        view.addSubview(label)
    case "image":
        view.layer?.backgroundColor = (NSColor(hex: "#111116") ?? .darkGray).cgColor
        let iv = NSImageView(frame: body)
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.autoresizingMask = [.width, .height]
        view.addSubview(iv)
        if let path = content.path { loadImageAsync(path, into: iv) }
    case "mandala":
        // Transparent, like the swarm and the fireworks. `intensity` is the population
        // per ring; `cols` doubles as the ring count (a small integer either way).
        let mv = MandalaView(size: body.size, seed: content.seed ?? 5,
                             rings: content.cols ?? 5, intensity: content.intensity ?? 1.0)
        mv.autoresizingMask = [.width, .height]
        view.addSubview(mv)
    case "segcam":
        // The imported segmenter (~/segcam), headless: camera or clip in, boxes out.
        let sc = SegCamView(size: body.size, content: content)
        sc.autoresizingMask = [.width, .height]
        view.addSubview(sc)
    case "particles":
        // Transparent, like the fireworks and the swarm: no ground, so the field is over
        // whatever the show has on screen. `mode` is the behaviour, `sprite` the body.
        let pf = ParticleFieldView(size: body.size, seed: content.seed ?? 11,
                                   count: Int((content.intensity ?? 1.0) * 64),
                                   mode: ParticleFieldView.Mode(content.mode),
                                   sprite: ParticleFieldView.Sprite(content.sprite))
        pf.autoresizingMask = [.width, .height]
        view.addSubview(pf)
    case "doom":
        // It runs DooM. The engine is fetched, not committed (tools/fetch_doom.sh); the
        // page says so in the window if it is missing.
        let dv = DoomView(frame: NSRect(origin: .zero, size: body.size))
        dv.autoresizingMask = [.width, .height]
        view.addSubview(dv)
    case "cursors":
        // Transparent, like the fireworks: no background, so the swarm is over whatever
        // the show has on screen. `intensity` is the population, `mode` the behaviour.
        let cs = CursorSwarmView(size: body.size, seed: content.seed ?? 3,
                                 count: Int((content.intensity ?? 1.0) * 90),
                                 mode: CursorSwarmView.Mode(content.mode),
                                 rampSeconds: content.spawnSeconds ?? 0)
        cs.autoresizingMask = [.width, .height]
        view.addSubview(cs)
    case "fileworks":
        // A transparent overlay: no background is set, so whatever the show already has
        // on screen shows through and the icons appear to be thrown over it.
        let fw = FileworksView(size: body.size, seed: content.seed ?? 7,
                               hz: content.hz ?? 1.6, intensity: content.intensity ?? 1.0)
        fw.autoresizingMask = [.width, .height]
        view.addSubview(fw)
    case "uichaos":
        // Real controls and the system's own icons, heaped up. `intensity` is how
        // densely (default 1.0); `seed` fixes the pile.
        let uv = UIChaosView(size: body.size, seed: content.seed ?? 1,
                             density: content.intensity ?? 1.0)
        uv.autoresizingMask = [.width, .height]
        view.addSubview(uv)
    case "shader":
        // A GLSL fragment shader, live. `path` is the .frag; the scalar uniforms the
        // artist's shaders take (`drop`, `u_vol`, `midi`) are authored per event.
        view.layer?.backgroundColor = NSColor.black.cgColor
        let sv = ShaderCanvasView(frame: body)
        sv.autoresizingMask = [.width, .height]
        view.addSubview(sv)
        if let spin = content.spin { sv.startSpinning(degreesPerSecond: spin) }
        if let path = content.path {
            sv.load(shaderAt: path)
            for (name, value) in [("drop", content.drop), ("u_vol", content.vol),
                                  ("midi", content.midi)] {
                if let value { sv.setUniform(name, value) }
            }
        }
    case "automaton":
        let av = AutomatonView(size: body.size,
                               rule: content.rule ?? 30,
                               seed: content.seed ?? 0,
                               fontSize: CGFloat(content.fontSize ?? 9),
                               hz: content.hz ?? 12)
        av.autoresizingMask = [.width, .height]
        view.addSubview(av)
    case "glitch":
        // Torn once when the window opens, deliberately NOT animated: cue 15 ramps to
        // ~26 windows, and a per-frame re-tear in each is the window-server load the
        // wallpaper glitch had to be dialled back from (2.5 Hz → 1.5).
        view.layer?.backgroundColor = (NSColor(hex: "#0B0E16") ?? .black).cgColor
        view.layer?.cornerRadius = 6
        let gv = NSImageView(frame: body)
        // Axes-independent, so the tear runs edge to edge: a letterboxed glitch reads
        // as a picture of a glitch rather than as the window itself being broken.
        gv.imageScaling = .scaleAxesIndependently
        gv.autoresizingMask = [.width, .height]
        view.addSubview(gv)
        if let path = content.path {
            loadGlitchImageAsync(resolveResourcePath(path),
                                 intensity: content.intensity ?? 0.6,
                                 seed: UInt64(max(0, content.seed ?? 0)),
                                 into: gv)
        }
    case "ascii":
        view.layer?.backgroundColor = (NSColor(hex: "#060A14") ?? .black).cgColor
        view.layer?.cornerRadius = 6
        let inset = NSRect(x: 6, y: 6, width: max(body.width - 12, 8), height: max(body.height - 12, 8))
        let tv = makeAsciiTextView(frame: inset)
        view.addSubview(tv)
        let fg = NSColor(hex: content.hex ?? "#8CF2A6") ?? .green   // matrix-green default
        let ramp = content.ramp ?? dpeAsciiRamp
        if let path = content.path {
            loadAsciiImageAsync(path: resolveResourcePath(path), cols: content.cols ?? 80,
                                invert: content.invert ?? false, colorized: content.colorized ?? false,
                                ramp: ramp, fg: fg, into: tv)
        } else {
            renderAscii(asciiArtFromText(content.text ?? ""), into: tv, fg: fg)
        }
    case "asciilog":
        // The live text plane. NOT the `ascii` kind above: that converts a picture or a
        // block of text to art and lays it out once in a card; this has a clock, scrolls,
        // strobes, and is normally the whole screen with nothing behind it.
        //
        // No ground on the view. The plane paints its own only when `bg` is given, so the
        // default really is transparent — everything under it shows through the gaps
        // between the glyphs.
        let src: AsciiLogView.Source
        switch content.source ?? "hex" {
        case "lines":   src = .lines(content.lines ?? [])
        case "text":    src = .text(content.text ?? "")
        case "windows": src = .windows
        default:        src = .hex(seed: UInt64(abs(content.seed ?? 1)))
        }
        let plane = AsciiLogView(
            size: body.size, source: src,
            // The show's sky blue, not the `ascii` kind's matrix-green: these planes run
            // over the eruption and on the window map's own DJ-blue ground, and green on
            // that is a different piece of work than the one this is in.
            fg: NSColor(hex: content.hex ?? "#68BDF8") ?? .systemBlue,
            background: content.bg.flatMap { NSColor(hex: $0) },
            hz: content.hz ?? 12,
            fontSize: CGFloat(content.fontSize ?? 13),
            zalgo: content.zalgo ?? 0,
            strobe: content.strobe ?? 0,
            seed: UInt64(abs(content.seed ?? 1)))
        plane.autoresizingMask = [.width, .height]
        view.addSubview(plane)
    default: // "color"
        view.layer?.backgroundColor = (NSColor(hex: content.hex ?? "#020AF5") ?? .systemBlue).cgColor
        view.layer?.cornerRadius = 6
    }

    return view
}

/// Build the content view for a deliberately comedic fake dialog — never styled to
/// imitate a real macOS security, password, or Gatekeeper prompt.
/// The illustration a macOS alert carries at its left.
///
/// These are the system's own images, not drawings of them: `NSCaution` is the yellow
/// warning triangle every Mac app uses, and `NSApplicationIcon` is whatever icon the
/// running app is bundled with. `critical` composites the two the way AppKit does for
/// `NSAlert.Style.critical` — the app icon with the caution triangle badged over its
/// bottom-right corner.
enum DialogIcon: String {
    case caution, info, app, critical, none

    /// 64pt is the size AppKit lays an alert icon out at.
    static let side: CGFloat = 64

    /// Always returns a FLATTENED bitmap at `side` points: the system images' reps do
    /// not draw into an offscreen `cacheDisplay` context (verified — empty boxes in
    /// `--snapshot-chrome`), so every variant is rasterised here.
    func image() -> NSImage? {
        guard self != .none else { return nil }
        let side = DialogIcon.side
        let box = NSRect(x: 0, y: 0, width: side, height: side)

        let flattened = NSImage(size: NSSize(width: side, height: side))
        flattened.lockFocus()
        switch self {
        case .none:
            break
        case .caution:
            NSImage(named: NSImage.cautionName)?.draw(in: box)
        case .info:
            NSImage(named: NSImage.infoName)?.draw(in: box)
        case .app:
            NSImage(named: NSImage.applicationIconName)?.draw(in: box)
        case .critical:
            NSImage(named: NSImage.applicationIconName)?.draw(in: box)
            // Badge at half scale on the bottom-right, as a critical alert does.
            NSImage(named: NSImage.cautionName)?
                .draw(in: NSRect(x: side * 0.5, y: 0, width: side * 0.5, height: side * 0.5))
        }
        flattened.unlockFocus()
        return flattened
    }
}

func makeDialogContentView(title: String, message: String, buttons: [String],
                           icon: DialogIcon = .caution, size: NSSize) -> NSView {
    // Solid, manual-frame panel — no NSVisualEffectView blur or autolayout, both of
    // which are far too expensive when dozens of dialogs spawn during a show.
    let root = NSView(frame: NSRect(origin: .zero, size: size))
    root.wantsLayer = true
    // Semantic colours, not fixed greys: these track the viewer's light/dark setting
    // and accent colour, which is most of what makes a panel read as system-drawn.
    root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    root.layer?.cornerRadius = 12
    root.layer?.borderWidth = 1
    root.layer?.borderColor = NSColor.separatorColor.cgColor

    // macOS alert typography and layout; the icon is dropped on a panel too small to
    // carry it, so a dense show of little dialogs doesn't turn into all icon, no words.
    let side = DialogIcon.side
    var textX: CGFloat = 20
    if size.width >= 300, size.height >= 130, let image = icon.image() {
        let iv = NSImageView(frame: NSRect(x: 20, y: size.height - side - 22,
                                           width: side, height: side))
        iv.image = image
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.autoresizingMask = [.minYMargin]
        root.addSubview(iv)
        textX = 20 + side + 16
    }
    let textW = size.width - textX - 20

    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
    titleLabel.textColor = .labelColor
    titleLabel.frame = NSRect(x: textX, y: size.height - 40, width: textW, height: 22)
    titleLabel.autoresizingMask = [.width, .minYMargin]

    let body = NSTextField(wrappingLabelWithString: message)
    body.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    body.textColor = .secondaryLabelColor
    body.frame = NSRect(x: textX, y: 48, width: textW, height: size.height - 96)
    body.autoresizingMask = [.width, .height]

    root.addSubview(titleLabel)
    root.addSubview(body)

    var bx = size.width - 20
    for (i, label) in buttons.reversed().enumerated() {
        let b = NSButton(title: label, target: nil, action: nil)
        b.bezelStyle = .rounded
        b.controlSize = .regular
        b.font = .systemFont(ofSize: NSFont.systemFontSize)
        // Rightmost button is the default one, so it draws in the accent colour the
        // way a real alert's does.
        if i == 0 { b.keyEquivalent = "\r" }
        b.sizeToFit()
        let w = max(b.frame.width, 76)
        b.frame = NSRect(x: bx - w, y: 12, width: w, height: b.frame.height)
        b.autoresizingMask = [.minXMargin, .maxYMargin]
        root.addSubview(b)
        bx -= (w + 8)
    }
    return root
}

// MARK: - Windows

/// Borderless, non-activating floating panel that appears on every Space and above
/// normal windows, without stealing focus (so spawning it never interrupts a take).
class BaseEffectWindow: NSPanel, NSWindowDelegate {
    /// True when this window wears a real macOS title bar rather than a drawn one.
    private(set) var isNativeChrome = false

    /// The style mask a native effect window uses. One definition, because the content
    /// size has to be derived from the same mask the window is built with.
    static let nativeStyleMask: NSWindow.StyleMask =
        [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel]

    /// Content size for an authored OUTER frame.
    ///
    /// A hosted view whose internal layout is fixed at init (the typeText editor lays
    /// its text layer out once) must be built at this size, not at the frame size —
    /// otherwise it is a title bar too tall and its bottom is clipped.
    static func contentSize(forFrame frame: NSRect, native: Bool) -> NSSize {
        native ? NSWindow.contentRect(forFrameRect: frame, styleMask: nativeStyleMask).size
               : frame.size
    }

    /// - Parameter native: use a real titled window. The authored rect is then treated
    ///   as the OUTER frame and converted to a content rect, so an authored
    ///   `[x, y, w, h]` still describes the space the whole window occupies rather than
    ///   silently growing by the height of the title bar.
    init(contentRect: NSRect, native: Bool = false) {
        let mask: NSWindow.StyleMask = native
            ? BaseEffectWindow.nativeStyleMask
            : [.borderless, .nonactivatingPanel]
        let rect = native
            ? NSWindow.contentRect(forFrameRect: contentRect, styleMask: mask)
            : contentRect
        super.init(contentRect: rect, styleMask: mask, backing: .buffered, defer: false)
        isNativeChrome = native
        isFloatingPanel = true
        hidesOnDeactivate = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hasShadow = true
        isReleasedWhenClosed = false
        if native {
            // A real window is opaque and uses the system's own background, so it
            // picks up light/dark appearance like every other app on the machine.
            isOpaque = true
            backgroundColor = .windowBackgroundColor
            // Panels default to a narrow utility title bar; this is the standard one.
            isMovableByWindowBackground = false
            delegate = self
        } else {
            isOpaque = false
            backgroundColor = .clear
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Refuse the close and let the controller decide — `respawn` needs the window to
    /// come back rather than staying shut.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let onUserClose else { return false }
        onUserClose()
        return false
    }

    /// Fired when the viewer clicks this window's real traffic-light close button.
    var onUserClose: (() -> Void)?

    /// Hand the window to the viewer: draggable anywhere by its body, closable by its
    /// traffic lights. It still never becomes key, so grabbing one can't pull focus
    /// away mid-show.
    func makeInteractive(size: NSSize) {
        ignoresMouseEvents = false
        // A native window already drags by its title bar and closes by its real button;
        // a bare one can only be shoved around by its body.
        guard !isNativeChrome else { return }
        isMovableByWindowBackground = true
    }

    func present(animate kind: String) {
        orderFrontRegardless()
        switch kind {
        case "none":
            alphaValue = 1
        case "springIn":
            alphaValue = 1
            if let layer = contentView?.layer {
                let spring = CASpringAnimation(keyPath: "transform.scale")
                spring.fromValue = 0.6
                spring.toValue = 1.0
                spring.damping = 12
                spring.initialVelocity = 6
                spring.duration = spring.settlingDuration
                layer.add(spring, forKey: "springIn")
            }
        default: // "fadeIn"
            alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                animator().alphaValue = 1
            }
        }
    }
}

/// A pure-visual window. Click-through so a choreographed cursor passes over it untouched.
final class EffectWindow: BaseEffectWindow {
    init(contentRect: NSRect, content: ContentSpec, interactive: Bool = false) {
        super.init(contentRect: contentRect,
                   native: usesNativeChrome(content.chrome, size: contentRect.size))
        ignoresMouseEvents = true
        applyContent(content, frame: contentRect)
        if interactive { makeInteractive(size: contentRect.size) }
    }

    /// Install (or swap in) this window's content. The only place content is rendered:
    /// a native-chrome window must not also paint a drawn bar, and the content view is
    /// sized to the CONTENT rect, not the outer frame — the reuse path included.
    func applyContent(_ content: ContentSpec, frame: NSRect) {
        setFrame(frame, display: false)
        var spec = content
        if isNativeChrome {
            spec.chrome = "none"
            title = LocationStore.fill(content.title ?? EffectWindow.defaultTitle(for: content))
        }
        contentView = makeEffectContentView(spec, size: contentRect(forFrameRect: frame).size)
    }

    /// Real windows always have a title. Falls back to something plausible for the
    /// content kind rather than leaving the bar blank, which reads as broken.
    static func defaultTitle(for content: ContentSpec) -> String {
        switch content.kind {
        case "code":     return TerminalStyle.title()
        case "livecode": return "hydra"
        case "map":      return "Maps"
        case "web":      return content.url ?? "Safari"
        case "image":    return "Preview"
        case "ascii":    return "art.txt"
        case "asciilog": return "console"
        case "glitch":   return "recovered.jpg"
        case "automaton": return "automaton"
        case "shader":   return "shader.frag"
        case "uichaos":  return "Finder"
        case "fileworks": return "Desktop"
        case "cursors":  return "pointer"
        case "mandala":  return "wait"
        default:         return "Untitled"
        }
    }
}

/// A tiny pooled window used as a "pixel" by sprites and cursor trails.
/// Click-through; shadow is optional because dozens of these move every frame and
/// the window-server shadow recompute is the expensive part of moving them.
final class MicroWindow: BaseEffectWindow {
    init(size: NSSize, bodyColor: NSColor, shadow: Bool) {
        // The authored cell size is the OUTER frame, so a sprite's grid spacing is
        // unchanged by the title bar — the coloured body just gets shorter by 28pt.
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   native: fitsNativeChrome(size))
        ignoresMouseEvents = true
        hasShadow = shadow
        setFrame(NSRect(origin: frame.origin, size: size), display: false)
        // Content rect, not the outer frame — otherwise the body is a title bar too
        // tall and the bottom is clipped.
        contentView = makeMicroContentView(size: contentRect(forFrameRect: frame).size,
                                           bodyColor: bodyColor)
    }
}

/// An elementary cellular automaton, printing itself out in Terminal's own colours.
/// The grid comes from the VIEW, not the timeline, so the field reaches every edge.
/// It scrolls one generation per tick at `hz`; the buffer starts full so a window opens
/// mid-computation and the still renderer (no run loop) still catches a real field.
/// Deterministic: row n is a pure function of `rule` and `seed`.
final class AutomatonView: NSView {
    private let textLayer = CATextLayer()
    private let font: NSFont
    private let rule: UInt8
    private let ink = NSColor.black
    /// Live cells are a full block and dead ones a light dither, so the off cells still
    /// read as a grid: the point is a pixel field, not a scatter of marks.
    private static let live = "\u{2588}", dead = "\u{2591}"

    private var cells: [UInt8] = []
    private var lines: [String] = []
    private var cols = 0, rows = 0
    private var timer: Timer?

    init(size: NSSize, rule: Int, seed: Int, fontSize: CGFloat, hz: Double) {
        self.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        self.rule = UInt8(truncatingIfNeeded: rule)
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = TerminalStyle.background.cgColor
        layer?.masksToBounds = true

        // No padding: the field is the window. A monospace advance is measured rather
        // than assumed at 0.6 em — the ratio differs between faces and a wrong guess
        // shows up as a missing or clipped last column.
        let cellW = max(1, ("M" as NSString).size(withAttributes: [.font: font]).width)
        cols = max(8, Int(size.width / cellW))
        rows = max(4, Int(size.height / fontSize))

        textLayer.frame = CGRect(origin: .zero, size: size)
        textLayer.isWrapped = false
        textLayer.alignmentMode = .left
        textLayer.truncationMode = .none
        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(textLayer)

        // Row 0: seed 0 is the classic single live cell; otherwise a seeded random row.
        cells = [UInt8](repeating: 0, count: cols)
        if seed == 0 {
            cells[cols / 2] = 1
        } else {
            var rng = SplitMix64(seed: UInt64(bitPattern: Int64(seed)))
            for x in 0..<cols { cells[x] = UInt8(rng.next() & 1) }
        }
        for _ in 0..<rows { step() }
        render()

        let interval = 1.0 / max(0.5, min(30, hz))
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.step()
            self?.render()
        }
        // .common so it keeps running while a menu is open or a window is dragged.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit { timer?.invalidate() }

    /// Stop when the view leaves the screen — a timer ticking against a detached view
    /// is a leak the show would accumulate once per automaton per run.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { timer?.invalidate(); timer = nil }
    }

    /// One generation. Wolfram's numbering: bit n of the rule is the next state of the
    /// neighbourhood whose (left, centre, right) reads as the binary number n.
    private func step() {
        lines.append(String(cells.map { $0 == 1 ? Character(AutomatonView.live)
                                                : Character(AutomatonView.dead) }))
        if lines.count > rows { lines.removeFirst(lines.count - rows) }
        var next = [UInt8](repeating: 0, count: cols)
        for x in 0..<cols {
            let l = x > 0 ? cells[x - 1] : 0
            let r = x < cols - 1 ? cells[x + 1] : 0
            next[x] = (rule >> (l << 2 | cells[x] << 1 | r)) & 1
        }
        cells = next
    }

    /// Test seam: the grid the view chose for itself, and what it has computed so far.
    var gridForTesting: (cols: Int, rows: Int) { (cols, rows) }
    var linesForTesting: [String] { lines }

    private func render() {
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = font.pointSize
        para.maximumLineHeight = font.pointSize
        para.lineSpacing = 0
        let s = NSAttributedString(string: lines.joined(separator: "\n"), attributes: [
            .font: font, .foregroundColor: ink, .paragraphStyle: para])
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // no implicit fade on every generation
        textLayer.string = s
        CATransaction.commit()
    }
}

/// A surface a typewriter writes into.
///
/// Two of them, and the difference is the whole point: the `typeText` document below,
/// and a real Terminal window — the same surface the end card's credits type into, so a
/// terminal that writes itself out anywhere in the piece reads as the same machine.
protocol TypedTextSink: AnyObject {
    /// `visible` already carries the newline the caret sits after when the copy types
    /// by the line; the sink only decides what the caret looks like.
    func showTyped(_ visible: String, caret: Bool)
}

/// Terminal's own label, written into by the typewriter. `█` is a Terminal block
/// cursor, not a document's thin bar — the caret the credits have always used.
final class TerminalTextSink: TypedTextSink {
    private let label: NSTextField
    init(label: NSTextField) { self.label = label }
    func showTyped(_ visible: String, caret: Bool) {
        label.stringValue = visible + (caret ? "\u{2588}" : "")
    }
}

/// The label `applyContent` made for a `code` window, fished back out rather than
/// rebuilt, so typed text keeps exactly the chrome every other terminal in the piece
/// wears.
func firstTextField(in view: NSView?) -> NSTextField? {
    guard let view else { return nil }
    if let tf = view as? NSTextField { return tf }
    for sub in view.subviews {
        if let tf = firstTextField(in: sub) { return tf }
    }
    return nil
}

/// A plain document mid-composition: white page, dark text, blinking caret.
/// The text lives in a CATextLayer rather than an NSTextField: the typewriter rewrites
/// it ~30 times a second, and an NSTextField would re-run cell layout on the main
/// thread every keystroke.
final class TextEditorView: NSView, TypedTextSink {
    private let textLayer = CATextLayer()
    private let font: NSFont
    private let ink = NSColor(white: 0.09, alpha: 1)

    init(size: NSSize, title: String?, fontSize: CGFloat) {
        self.font = .systemFont(ofSize: fontSize, weight: .regular)
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        textLayer.frame = TextEditorView.textBox(in: size)
        textLayer.isWrapped = true
        textLayer.alignmentMode = .left
        textLayer.truncationMode = .none
        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(textLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// The page inside the document — the frame the copy actually has to fit in, and the
    /// one thing a cue can get wrong: `typeText` authors an outer window frame, and copy
    /// longer than this box types straight off the bottom of its own window with no
    /// scroll and no warning. Shared so a test can measure the box the show authors.
    static func textBox(in size: NSSize) -> CGRect {
        let pad = min(max(size.width * 0.055, 14), 40)
        return CGRect(x: pad, y: pad, width: size.width - pad * 2, height: size.height - pad * 1.4)
    }

    /// How tall `text` sets in that box at `fontSize`, with the same line spacing
    /// `showTyped` uses. Bigger than the box means the copy does not fit.
    static func textHeight(_ text: String, in size: NSSize, fontSize: CGFloat) -> CGFloat {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = fontSize * 0.30
        let box = textBox(in: size)
        return text.boundingRect(
            with: NSSize(width: box.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .regular),
                         .paragraphStyle: para]).height
    }

    /// CATextLayer anchors its string at the TOP of its frame, which is what a
    /// document does — the text grows downward as it is typed.
    func showTyped(_ visible: String, caret: Bool) {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = font.pointSize * 0.30
        let s = NSMutableAttributedString(string: visible, attributes: [
            .font: font, .foregroundColor: ink, .paragraphStyle: para])
        if caret {
            s.append(NSAttributedString(string: "▌", attributes: [
                .font: font, .foregroundColor: ink, .paragraphStyle: para]))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)     // no implicit fade on every keystroke
        textLayer.string = s
        CATransaction.commit()
    }
}

/// An effect window built around a content view the caller already has a handle on
/// (the typewriter needs to keep talking to its view after the window is up).
final class HostedEffectWindow: BaseEffectWindow {
    /// `title` opts the window into REAL macOS chrome when it is big enough — the
    /// `typeText` letter is a full-size document window and should look like one.
    init(contentRect: NSRect, view: NSView, title: String? = nil) {
        let native = title != nil && usesNativeChrome("mac", size: contentRect.size)
        super.init(contentRect: contentRect, native: native)
        ignoresMouseEvents = true
        if native {
            self.title = title ?? "Untitled"
            setFrame(contentRect, display: false)
            view.frame = NSRect(origin: .zero, size: self.contentRect(forFrameRect: contentRect).size)
        }
        contentView = view
    }
}

/// A deliberately comedic fake dialog window.
final class FakeDialogWindow: BaseEffectWindow {
    init(contentRect: NSRect, title: String, message: String, buttons: [String],
         icon: DialogIcon = .caution) {
        // Borderless on purpose: a real macOS alert has no title bar either.
        super.init(contentRect: contentRect)
        ignoresMouseEvents = false
        contentView = makeDialogContentView(title: title, message: message,
                                            buttons: buttons, icon: icon,
                                            size: contentRect.size)
    }
}

/// A fullscreen click-through color wash that fades out. One instance per screen is
/// REUSED across every flash — creating a fullscreen window per flash is far too
/// expensive during a dense strobe.
final class FlashWindow: BaseEffectWindow {
    private let colorLayerView = NSView()

    private var offToken = 0
    private var shown = false

    init(frame: NSRect) {
        super.init(contentRect: frame)
        ignoresMouseEvents = true
        hasShadow = false
        colorLayerView.frame = NSRect(origin: .zero, size: frame.size)
        colorLayerView.wantsLayer = true
        colorLayerView.layer?.opacity = 0            // idle: invisible
        colorLayerView.autoresizingMask = [.width, .height]
        contentView = colorLayerView
        alphaValue = 1
    }

    /// Hard on/off via LAYER OPACITY on a persistently ordered-in window — no window
    /// show/hide (recomposites every revealed window per flash) and no fade (re-blends
    /// the whole screen each frame). Idle at opacity 0; a flash is a GPU opacity toggle.
    func flash(color: NSColor, duration: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        colorLayerView.layer?.backgroundColor = color.cgColor
        colorLayerView.layer?.opacity = 1
        CATransaction.commit()
        if !shown { orderFrontRegardless(); shown = true }
        offToken &+= 1
        let token = offToken
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.02, duration)) { [weak self] in
            guard let self = self, self.offToken == token else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.colorLayerView.layer?.opacity = 0
            CATransaction.commit()
        }
    }
}


// MARK: - The lyric face

/// Every lyric card is set in Hack Bold — the face in `assets/fonts/hack`, registered
/// with the font manager the first time a card is built, so the file never has to be
/// installed on the viewer's machine. If the file is missing (a stripped bundle) the
/// cards fall back to the system's heavy face rather than to nothing.
enum LyricFont {
    static let family = "Hack-Bold"
    private static let registered: Bool = {
        let path = resolveResourcePath("assets/fonts/hack/Hack-Bold.ttf")
        guard FileManager.default.fileExists(atPath: path) else {
            NSLog("[DPE] lyric font: assets/fonts/hack/Hack-Bold.ttf not found — using the system face")
            return false
        }
        var error: Unmanaged<CFError>?
        let ok = CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: path) as CFURL, .process, &error)
        // "Already registered" is a failure by the API's lights and a success by ours.
        return ok || NSFont(name: family, size: 12) != nil
    }()

    static func font(ofSize pt: CGFloat) -> NSFont {
        if registered, let f = NSFont(name: family, size: pt) { return f }
        return .systemFont(ofSize: pt, weight: .heavy)
    }
}
