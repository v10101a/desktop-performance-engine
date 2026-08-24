import AppKit
import ImageIO

/// Borderless window holding one photo, stretched to exactly fill the frame.
///
/// Ported from the standalone photowall app with three changes the show requires:
///
/// - **Never becomes key.** The standalone app made its first window key so that its
///   own esc handler kept working under a buried menu bar. Here that would pull focus
///   off the control window mid-show; the panic hotkey is a global Carbon handler that
///   fires whatever is frontmost, so nothing needs focus.
/// - **Transparent to the mouse.** Clicking a photo used to close it. During a
///   performance a stray click must not start dismantling the wall, and `cursorPath`
///   effects drive the real cursor across the screen while the wall is up.
/// - **Configurable level.** The standalone app always sat above the menu bar and Dock.
///   Here the default is the normal level, so the wall interleaves with the show's
///   other effect windows instead of burying them.
final class PhotoWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The rectangle this window was placed at. Coverage bookkeeping uses this rather
    /// than `frame`, so the grid can never drift from what was marked if AppKit ever
    /// adjusts a frame under us.
    let placedRect: CGRect
    private let imageView = NSImageView()

    init(frame: CGRect, shadows: Bool, level: PhotoWallConfig.Level) {
        placedRect = frame
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        // We hold windows in an array and close them on eviction; without this, AppKit
        // releases on close and the stored reference dangles.
        isReleasedWhenClosed = false
        isOpaque = true
        backgroundColor = .black
        hasShadow = shadows
        switch level {
        case .normal:   self.level = .normal
        case .floating: self.level = .floating
        case .front:    self.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        }
        collectionBehavior = [.fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = false
        // The wall is scenery, not a control surface — let every click through to
        // whatever is underneath.
        ignoresMouseEvents = true

        imageView.frame = CGRect(origin: .zero, size: frame.size)
        imageView.autoresizingMask = [.width, .height]
        imageView.imageFrameStyle = .none
        // The whole point: ignore the photo's aspect ratio and stretch it to the frame.
        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = false
        contentView = imageView
    }

    func show(_ image: NSImage) { imageView.image = image }
}

enum ImageLoader {
    /// Decodes a downsampled image sized for the window it will fill — full-res
    /// decodes of a few hundred photos would be gigabytes for no visible gain.
    static func thumbnail(_ url: URL, maxPixel: CGFloat) -> NSImage? {
        let srcOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, srcOpts as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // honour EXIF orientation
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, maxPixel)
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
