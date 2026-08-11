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

/// Decode a downsampled thumbnail directly (never fully decodes the source bitmap).
private func decodeThumbnail(_ path: String, maxPixel: Int) -> NSImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        kCGImageSourceCreateThumbnailWithTransform: true
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}

// MARK: - Fake chrome

/// Chrome kinds cycled by "mixed" so a pool of micro-windows gets visual variety.
private let fakeChromeKinds = ["browser", "terminal", "mac"]

/// Resolve an authored chrome value for the `index`-th window of a pool.
func resolvedChromeKind(_ kind: String?, index: Int) -> String? {
    guard let kind = kind, kind != "none" else { return nil }
    if kind == "mixed" { return fakeChromeKinds[index % fakeChromeKinds.count] }
    return kind
}

func fakeChromeBarHeight(for size: NSSize) -> CGFloat {
    min(max(size.height * 0.26, 7), 22)
}

/// Deliberately stylized mini window chrome — traffic-light dots, a URL pill —
/// drawn as plain layer views so it stays cheap and scales down to sprite-pixel
/// size. Same ethos as the fake dialogs: playful, never a pixel-accurate imitation
/// of real browser/system UI.
func addFakeChrome(to view: NSView, size: NSSize, kind: String, title: String?) {
    let barH = fakeChromeBarHeight(for: size)
    let bar = NSView(frame: NSRect(x: 0, y: size.height - barH, width: size.width, height: barH))
    bar.autoresizingMask = [.width, .minYMargin]
    bar.wantsLayer = true

    let barColor: NSColor
    switch kind {
    case "terminal": barColor = NSColor(hex: "#26262C") ?? .black
    case "mac":      barColor = NSColor(hex: "#E8E8EC") ?? .lightGray
    default:         barColor = NSColor(hex: "#D8D8E0") ?? .lightGray   // browser
    }
    bar.layer?.backgroundColor = barColor.cgColor

    let d = min(max(barH * 0.42, 3), 7)
    let dotColors = ["#FF5F57", "#FEBC2E", "#28C840"]
    var dx = max(3, barH * 0.35)
    for hex in dotColors {
        let dot = NSView(frame: NSRect(x: dx, y: (barH - d) / 2, width: d, height: d))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = (NSColor(hex: hex) ?? .gray).cgColor
        dot.layer?.cornerRadius = d / 2
        bar.addSubview(dot)
        dx += d + max(2, d * 0.5)
    }

    // Room permitting: a URL pill (browser) or a tiny title. Skipped at micro sizes.
    if barH >= 12, size.width >= 110 {
        if kind == "browser" {
            let pill = NSView(frame: NSRect(x: dx + 4, y: barH * 0.15,
                                            width: size.width - dx - 12, height: barH * 0.7))
            pill.wantsLayer = true
            pill.layer?.backgroundColor = NSColor(white: 1, alpha: 0.9).cgColor
            pill.layer?.cornerRadius = barH * 0.35
            pill.autoresizingMask = [.width]
            if size.width >= 150 {
                let label = NSTextField(labelWithString: title ?? "about:blank")
                label.font = .monospacedSystemFont(ofSize: max(7, barH * 0.5), weight: .regular)
                label.textColor = NSColor(white: 0.35, alpha: 1)
                label.lineBreakMode = .byTruncatingTail
                label.frame = pill.bounds.insetBy(dx: 6, dy: 0)
                label.autoresizingMask = [.width, .height]
                pill.addSubview(label)
            }
            bar.addSubview(pill)
        } else if let title = title {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: max(7, barH * 0.5), weight: .medium)
            label.textColor = kind == "terminal" ? NSColor(hex: "#8CF2A6")! : NSColor(white: 0.3, alpha: 1)
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.frame = NSRect(x: dx + 2, y: 0, width: size.width - 2 * (dx + 2), height: barH)
            label.autoresizingMask = [.width]
            bar.addSubview(label)
        }
    }
    view.addSubview(bar)
}

/// Content view for a pooled micro-window (sprite pixel / trail breadcrumb).
func makeMicroContentView(size: NSSize, bodyColor: NSColor, chrome: String?, title: String?) -> NSView {
    let view = NSView(frame: NSRect(origin: .zero, size: size))
    view.wantsLayer = true
    view.layer?.backgroundColor = bodyColor.cgColor
    view.layer?.cornerRadius = min(5, size.height * 0.18)
    view.layer?.masksToBounds = true
    view.layer?.borderWidth = 1
    view.layer?.borderColor = NSColor(white: 0, alpha: 0.25).cgColor
    if let kind = chrome { addFakeChrome(to: view, size: size, kind: kind, title: title) }
    return view
}

// MARK: - Live-coding REPL

/// Tempo of the running show, so generative content can lock its animation periods
/// to the beat. Set by `WindowManager.bpm` when a timeline loads.
var dpeShowBPM: Double = 120

private let liveCodeInk    = NSColor(hex: "#9BE0FF") ?? .cyan
private let liveCodeGutter = NSColor(hex: "#3E6E88") ?? .gray

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

    let barH = content.chrome == nil ? 0 : fakeChromeBarHeight(for: size)
    if running {
        let visual = Hydra.makeVisual(source: source,
                                      size: NSSize(width: size.width, height: size.height - barH),
                                      tint: accent, beat: beat)
        // A `moveWindow` resize doesn't rebuild the content, so the sketch has to
        // stretch with the window. (The composition re-centers properly the next time
        // the window is re-opened at its final size.)
        visual.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        root.layer?.addSublayer(visual)
    }

    // --- the source, hydra-style: no line numbers, a dark box behind every line ---
    let fontSize = min(max(size.height * 0.045, 6.5), 13)
    let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    let para = NSMutableParagraphStyle()
    para.lineSpacing = fontSize * 0.30
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
    let label = NSTextField(labelWithAttributedString: code)
    label.maximumNumberOfLines = 0
    let pad = max(6, fontSize * 0.8)
    let fit = label.sizeThatFits(NSSize(width: size.width - pad * 2, height: .greatestFiniteMagnitude))
    label.frame = NSRect(x: pad, y: size.height - barH - fit.height - pad * 0.6,
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
            let iv = NSImageView(frame: NSRect(x: x, y: size.height - barH - pad * 0.6 - g,
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

    if let kind = resolvedChromeKind(content.chrome, index: 0) {
        addFakeChrome(to: root, size: size, kind: kind, title: content.title)
    }
    return root
}

// MARK: - Apple Maps flythrough

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

        let from = MKMapCamera(lookingAtCenter: CLLocationCoordinate2D(latitude: spec.lat,
                                                                      longitude: spec.lon),
                               fromDistance: spec.altitude ?? 900,
                               pitch: CGFloat(spec.pitch ?? 60),
                               heading: spec.heading ?? 0)
        map.camera = from

        let duration = max(0.5, spec.seconds ?? 14)
        let toLat = spec.toLat ?? spec.lat
        let toLon = spec.toLon ?? spec.lon
        let toAlt = spec.toAltitude ?? (spec.altitude ?? 900)
        let toPitch = CGFloat(spec.toPitch ?? (spec.pitch ?? 60))
        let toHeading = spec.toHeading ?? ((spec.heading ?? 0) + 90)
        let started = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            let u = min(1.0, Date().timeIntervalSince(started) / duration)
            let e = u < 0.5 ? 2 * u * u : 1 - pow(-2 * u + 2, 2) / 2      // easeInOut
            let cam = MKMapCamera(
                lookingAtCenter: CLLocationCoordinate2D(latitude: spec.lat + (toLat - spec.lat) * e,
                                                        longitude: spec.lon + (toLon - spec.lon) * e),
                fromDistance: (spec.altitude ?? 900) + (toAlt - (spec.altitude ?? 900)) * e,
                pitch: CGFloat(spec.pitch ?? 60) + (toPitch - CGFloat(spec.pitch ?? 60)) * CGFloat(e),
                heading: (spec.heading ?? 0) + (toHeading - (spec.heading ?? 0)) * e)
            self.map.camera = cam
            if u >= 1 { t.invalidate() }
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
        if let kind = resolvedChromeKind(content.chrome, index: 0) {
            let barH = fakeChromeBarHeight(for: size)
            web.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height - barH)
            addFakeChrome(to: host, size: size, kind: kind, title: content.title)
        }
        return host
    }
    if content.kind == "map", let spec = content.map {
        let view = MapFlyView(size: size, spec: spec)
        if let kind = resolvedChromeKind(content.chrome, index: 0) {
            addFakeChrome(to: view, size: size, kind: kind, title: content.title)
        }
        return view
    }

    let view = NSView(frame: NSRect(origin: .zero, size: size))
    view.wantsLayer = true
    view.layer?.masksToBounds = true

    let chromeKind = resolvedChromeKind(content.chrome, index: 0)
    let barH = chromeKind != nil ? fakeChromeBarHeight(for: size) : 0
    let body = NSRect(x: 0, y: 0, width: size.width, height: size.height - barH)

    switch content.kind {
    case "text":
        view.layer?.backgroundColor = (NSColor(hex: "#091724") ?? .black).cgColor
        view.layer?.cornerRadius = 6
        let label = NSTextField(labelWithString: content.text ?? "")
        label.font = .systemFont(ofSize: 42, weight: .heavy)
        label.textColor = .white
        label.alignment = .center
        label.maximumNumberOfLines = 0
        label.frame = body
        label.autoresizingMask = [.width, .height]
        view.addSubview(label)
    case "code":
        // Manual frame (no autolayout) — created at volume during the show.
        view.layer?.backgroundColor = (NSColor(hex: "#0B0E16") ?? .black).cgColor
        view.layer?.cornerRadius = 6
        let label = NSTextField(wrappingLabelWithString: content.text ?? "")
        label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        label.textColor = NSColor(hex: "#8CF2A6") ?? .green
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.alignment = .left
        label.frame = NSRect(x: 14, y: 12, width: body.width - 28, height: body.height - 24)
        label.autoresizingMask = [.width, .height]
        view.addSubview(label)
    case "image":
        view.layer?.backgroundColor = (NSColor(hex: "#111116") ?? .darkGray).cgColor
        let iv = NSImageView(frame: body)
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.autoresizingMask = [.width, .height]
        view.addSubview(iv)
        if let path = content.path { loadImageAsync(path, into: iv) }
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
    default: // "color"
        view.layer?.backgroundColor = (NSColor(hex: content.hex ?? "#020AF5") ?? .systemBlue).cgColor
        view.layer?.cornerRadius = 6
    }

    if let kind = chromeKind { addFakeChrome(to: view, size: size, kind: kind, title: content.title) }
    return view
}

/// Build the content view for a deliberately comedic fake dialog — never styled to
/// imitate a real macOS security, password, or Gatekeeper prompt.
func makeDialogContentView(title: String, message: String, buttons: [String], size: NSSize) -> NSView {
    // Solid, manual-frame panel — no NSVisualEffectView blur or autolayout, both of
    // which are far too expensive when dozens of dialogs spawn during a show.
    let root = NSView(frame: NSRect(origin: .zero, size: size))
    root.wantsLayer = true
    root.layer?.backgroundColor = (NSColor(hex: "#2A2A32") ?? .darkGray).cgColor
    root.layer?.cornerRadius = 12
    root.layer?.borderWidth = 1
    root.layer?.borderColor = NSColor(white: 1, alpha: 0.15).cgColor

    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
    titleLabel.textColor = .white
    titleLabel.frame = NSRect(x: 20, y: size.height - 40, width: size.width - 40, height: 22)
    titleLabel.autoresizingMask = [.width, .minYMargin]

    let body = NSTextField(wrappingLabelWithString: message)
    body.font = .systemFont(ofSize: 12)
    body.textColor = NSColor(white: 0.85, alpha: 1)
    body.frame = NSRect(x: 20, y: 48, width: size.width - 40, height: size.height - 96)
    body.autoresizingMask = [.width, .height]

    root.addSubview(titleLabel)
    root.addSubview(body)

    var bx = size.width - 20
    for label in buttons.reversed() {
        let b = NSButton(title: label, target: nil, action: nil)
        b.bezelStyle = .rounded
        b.sizeToFit()
        let w = max(b.frame.width, 60)
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
class BaseEffectWindow: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        hidesOnDeactivate = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Fired when the viewer clicks this window's (fake) traffic lights.
    var onUserClose: (() -> Void)?
    private var closeZone: NSRect = .zero

    /// Hand the window to the viewer: draggable anywhere by its body, closable by its
    /// traffic lights. It still never becomes key, so grabbing one can't pull focus
    /// away mid-show.
    func makeInteractive(size: NSSize) {
        ignoresMouseEvents = false
        isMovableByWindowBackground = true
        let barH = fakeChromeBarHeight(for: size)
        let d = min(max(barH * 0.42, 3), 7)
        closeZone = NSRect(x: 0, y: size.height - barH,
                           width: max(3, barH * 0.35) + d * 4.8, height: barH)
    }

    override func mouseDown(with event: NSEvent) {
        if onUserClose != nil, closeZone.contains(event.locationInWindow) {
            onUserClose?()
            return
        }
        super.mouseDown(with: event)   // let isMovableByWindowBackground drag it
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
        super.init(contentRect: contentRect)
        ignoresMouseEvents = true
        contentView = makeEffectContentView(content, size: contentRect.size)
        if interactive { makeInteractive(size: contentRect.size) }
    }
}

/// A tiny pooled window used as a "pixel" by sprites and cursor trails.
/// Click-through; shadow is optional because dozens of these move every frame and
/// the window-server shadow recompute is the expensive part of moving them.
final class MicroWindow: BaseEffectWindow {
    init(size: NSSize, bodyColor: NSColor, chrome: String?, title: String?, shadow: Bool) {
        super.init(contentRect: NSRect(origin: .zero, size: size))
        ignoresMouseEvents = true
        hasShadow = shadow
        contentView = makeMicroContentView(size: size, bodyColor: bodyColor,
                                           chrome: chrome, title: title)
    }
}

/// A plain document mid-composition: white page, dark text, blinking caret. The
/// deliberate opposite of everything else on screen — nothing neon, nothing flashing,
/// just someone writing.
///
/// The text lives in a CATextLayer rather than an NSTextField: the typewriter rewrites
/// it ~30 times a second and the layer lays out on the render server, where an
/// NSTextField would re-run cell layout on the main thread every keystroke.
final class TextEditorView: NSView {
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

        let barH = fakeChromeBarHeight(for: size)
        let pad = min(max(size.width * 0.055, 14), 40)
        textLayer.frame = CGRect(x: pad, y: pad,
                                 width: size.width - pad * 2,
                                 height: size.height - barH - pad * 1.4)
        textLayer.isWrapped = true
        textLayer.alignmentMode = .left
        textLayer.truncationMode = .none
        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(textLayer)
        addFakeChrome(to: self, size: size, kind: "mac", title: title ?? "Untitled")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// CATextLayer anchors its string at the TOP of its frame, which is what a
    /// document does — the text grows downward as it is typed.
    func render(_ visible: String, caret: Bool) {
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
    init(contentRect: NSRect, view: NSView) {
        super.init(contentRect: contentRect)
        ignoresMouseEvents = true
        contentView = view
    }
}

/// A deliberately comedic fake dialog window.
final class FakeDialogWindow: BaseEffectWindow {
    init(contentRect: NSRect, title: String, message: String, buttons: [String]) {
        super.init(contentRect: contentRect)
        ignoresMouseEvents = false
        contentView = makeDialogContentView(title: title, message: message,
                                            buttons: buttons, size: contentRect.size)
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
    /// show/hide (which forces the server to recomposite the ~25 revealed windows
    /// every flash) and no fade (which re-blends the whole screen each frame). Idle at
    /// opacity 0; a flash is a GPU opacity toggle. This was the single biggest win for
    /// keeping the pump fed during a dense strobe.
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
