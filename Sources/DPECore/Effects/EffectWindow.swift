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

/// Smallest window that gets REAL macOS chrome.
///
/// A native title bar is a fixed ~28pt tall and its traffic lights have a fixed size,
/// so below roughly this it stops being a title bar and becomes the whole window. The
/// drawn chrome below scales to any size — which is the only reason it still exists:
/// sprite pixels and cursor-trail breadcrumbs are 7-30pt and cannot carry a real one.
///
/// AppKit honours whatever outer frame it is given — it enforces no minimum — and the
/// title bar is a fixed 28pt, so the content is simply what is left: a 79x57 window
/// gets a 29pt body, a 46x34 one gets 6pt. The floor here is therefore only about
/// degeneracy, not taste: below it the content area would be nothing at all.
///
/// Everything above it wears real chrome, down to sprite pixels and cursor-trail
/// breadcrumbs. The glass torus is the one deliberate exception — it is a shape
/// floating in a transparent window, not an app window.
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

/// NOTE: the drawn "fake chrome" that used to live here — a scaled title bar with
/// traffic-light dots and a URL pill — is gone entirely. Windows large enough for a
/// real macOS title bar get one (see `usesNativeChrome`); everything smaller, down to
/// sprite pixels and cursor-trail breadcrumbs, now renders bare rather than wearing a
/// miniature imitation.

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

    if running {
        let visual = Hydra.makeVisual(source: source, size: size, tint: accent, beat: beat)
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
        // Terminal.app, "Basic" — the profile a Mac ships with: white background,
        // black text, SF Mono 11. Not a green-on-black hacker terminal; the point is
        // that it is indistinguishable from the real thing sitting next to it.
        //
        // Manual frame (no autolayout) — created at volume during the show.
        view.layer?.backgroundColor = TerminalStyle.background.cgColor
        view.layer?.cornerRadius = 0            // Terminal has square content corners
        let label = NSTextField(wrappingLabelWithString: content.text ?? "")
        label.font = TerminalStyle.font
        label.textColor = TerminalStyle.text
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

    /// Always returns a FLATTENED bitmap at `side` points.
    ///
    /// The system images are resolution-independent and backed by reps that do not draw
    /// when an `NSImageView` holding them is rendered into an offscreen
    /// `cacheDisplay` context — they came out as empty boxes in `--snapshot-chrome`
    /// while the composited `critical` icon, which is already a bitmap, rendered fine.
    /// Rasterising here makes every variant behave the same, on screen and in snapshots,
    /// and pins the size AppKit lays an alert icon out at.
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

    // macOS alert typography: the message is bold at the standard system size, the
    // informative text is regular at the small system size. Those two constants are
    // what AppKit itself uses, so they follow the system rather than guessing 15/12.
    // The illustration sits at the left with the text column beside it — the layout a
    // real alert uses at this aspect. Dropped on a panel too small to carry it, so a
    // dense show of little dialogs doesn't turn into all icon and no words.
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

    /// The real traffic-light close button routes to the same hook the drawn one used,
    /// so `respawn` still works — the window comes back rather than staying shut. We
    /// refuse the close and let the controller decide what happens.
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
        // A native window already drags by its real title bar and closes with its real
        // close button, so it needs neither the body-drag nor the hit-tested close zone.
        guard !isNativeChrome else { return }
        // A sub-title-bar-sized window has no chrome at all now, so there is nothing to
        // hit-test a close on — it can be shoved around, and `respawn` reaches it only
        // through a real close button, which means only on windows big enough to have one.
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

    /// Install (or swap in) this window's content.
    ///
    /// **This is the only place content is rendered**, because two things have to happen
    /// together and one of them is easy to forget on the reuse path:
    ///
    /// 1. A window wearing a real title bar must not also paint a drawn one — it would
    ///    sit inside the frame, under the genuine article, as a second fake bar.
    /// 2. The content view is sized to the CONTENT rect, not the outer frame, or it
    ///    renders a title bar's worth too tall and the bottom is clipped.
    ///
    /// `WindowManager` re-opens the same id constantly (the show cycles a pool of them),
    /// and that path used to re-render the authored spec verbatim — which did exactly
    /// the wrong thing on both counts for every window after its first open.
    func applyContent(_ content: ContentSpec, frame: NSRect) {
        setFrame(frame, display: false)
        var spec = content
        if isNativeChrome {
            spec.chrome = "none"
            title = content.title ?? EffectWindow.defaultTitle(for: content)
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

        let pad = min(max(size.width * 0.055, 14), 40)
        textLayer.frame = CGRect(x: pad, y: pad,
                                 width: size.width - pad * 2,
                                 height: size.height - pad * 1.4)
        textLayer.isWrapped = true
        textLayer.alignmentMode = .left
        textLayer.truncationMode = .none
        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(textLayer)
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
