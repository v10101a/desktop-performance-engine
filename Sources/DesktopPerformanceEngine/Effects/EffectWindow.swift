import AppKit
import ImageIO

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

// MARK: - Content builders (shared by live windows and the still renderer)

/// Build the content view for a pure-visual window: solid color, big text, or image.
/// An optional `chrome` draws a fake title bar and insets the body under it.
func makeEffectContentView(_ content: ContentSpec, size: NSSize) -> NSView {
    let view = NSView(frame: NSRect(origin: .zero, size: size))
    view.wantsLayer = true
    view.layer?.masksToBounds = true

    let chromeKind = resolvedChromeKind(content.chrome, index: 0)
    let barH = chromeKind != nil ? fakeChromeBarHeight(for: size) : 0
    let body = NSRect(x: 0, y: 0, width: size.width, height: size.height - barH)

    switch content.kind {
    case "text":
        view.layer?.backgroundColor = NSColor.black.cgColor
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
    default: // "color"
        view.layer?.backgroundColor = (NSColor(hex: content.hex ?? "#FF00AA") ?? .magenta).cgColor
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
    init(contentRect: NSRect, content: ContentSpec) {
        super.init(contentRect: contentRect)
        ignoresMouseEvents = true
        contentView = makeEffectContentView(content, size: contentRect.size)
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
