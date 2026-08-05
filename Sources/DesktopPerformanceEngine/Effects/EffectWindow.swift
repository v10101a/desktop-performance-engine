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

// MARK: - Content builders (shared by live windows and the still renderer)

/// Build the content view for a pure-visual window: solid color, big text, or image.
func makeEffectContentView(_ content: ContentSpec, size: NSSize) -> NSView {
    let view = NSView(frame: NSRect(origin: .zero, size: size))
    view.wantsLayer = true

    switch content.kind {
    case "text":
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.cornerRadius = 6
        let label = NSTextField(labelWithString: content.text ?? "")
        label.font = .systemFont(ofSize: 42, weight: .heavy)
        label.textColor = .white
        label.alignment = .center
        label.maximumNumberOfLines = 0
        label.frame = view.bounds
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
        label.frame = NSRect(x: 14, y: 12, width: size.width - 28, height: size.height - 24)
        label.autoresizingMask = [.width, .height]
        view.addSubview(label)
    case "image":
        view.layer?.backgroundColor = (NSColor(hex: "#111116") ?? .darkGray).cgColor
        let iv = NSImageView(frame: view.bounds)
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.autoresizingMask = [.width, .height]
        view.addSubview(iv)
        if let path = content.path { loadImageAsync(path, into: iv) }
    default: // "color"
        view.layer?.backgroundColor = (NSColor(hex: content.hex ?? "#FF00AA") ?? .magenta).cgColor
        view.layer?.cornerRadius = 6
    }
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
