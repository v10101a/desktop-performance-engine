import AppKit

/// Screen lookup and the timeline's frame convention: documented once here and
/// implemented once.
enum ScreenGeometry {
    /// The canvas the running timeline's numbers were authored in — set at load from
    /// `meta.authoredSize`, nil for documents that never declare one. When set, every
    /// frame, cursor point and authored size is mapped from that canvas onto the real
    /// screen, so a different-sized display gets the same composition, centred and
    /// scaled, instead of the authored pixels huddled in its top-left corner.
    static var authoredCanvas: CGSize?

    /// Per-axis scale from the authored canvas onto `screen` ((1, 1) without one).
    static func scale(for screen: NSScreen) -> (sx: Double, sy: Double) {
        guard let c = authoredCanvas, c.width > 0, c.height > 0 else { return (1, 1) }
        return (screen.frame.width / c.width, screen.frame.height / c.height)
    }

    /// Screen by timeline index, falling back to the main screen for a missing or
    /// out-of-range index rather than trapping on a bad document.
    static func screen(_ index: Int?) -> NSScreen {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return NSScreen.main! }
        let i = index ?? 0
        return (i >= 0 && i < screens.count) ? screens[i] : (NSScreen.main ?? screens[0])
    }

    /// Interpret `[x, y, w, h]` as **top-left origin** relative to `screen`, converting
    /// to AppKit's bottom-left global coordinates.
    ///
    /// **Negative x/y anchor to the far edge**, which keeps authored frames
    /// resolution-independent: `x < 0` measures from the right, `y < 0` from the bottom,
    /// so `[36, -36, 176, 64]` is the lower-left corner on any display.
    ///
    /// **A width or height ≤ 0 stretches to the far edge**, minus that much: `[0, 0, 0, 0]`
    /// is the whole screen on any display, `[40, 40, -40, -40]` is the screen with a
    /// 40pt margin. The lyric cards and the end card use this; nothing else authors a
    /// zero-size window, so it can't collide with an existing frame.
    ///
    /// **`anchor: "center"`** reads `[dx, dy, w, h]` instead: the window's *centre* sits
    /// `dx` right of and `dy` below the screen's centre. A ring of windows authored this
    /// way is centred on any display, which top-left coordinates cannot be — they are
    /// measured from a corner, so the same numbers drift off-centre as the screen grows.
    static func rect(from frame: [Double], on screen: NSScreen, anchor: String? = nil,
                     fallbackSize: NSSize? = nil) -> NSRect {
        let sf = screen.frame
        // Authored-canvas mapping: frame numbers scale onto the real screen; a
        // fallbackSize is a runtime size and passes through unscaled.
        let (sx, sy) = scale(for: screen)
        let x = (frame.count > 0 ? frame[0] : 0) * sx
        let topY = (frame.count > 1 ? frame[1] : 0) * sy
        var w = frame.count > 2 ? frame[2] * sx : (fallbackSize?.width ?? 300)
        var h = frame.count > 3 ? frame[3] * sy : (fallbackSize?.height ?? 200)
        if anchor == "center" {
            w = max(1, w); h = max(1, h)
            return NSRect(x: sf.midX + x - w / 2, y: sf.midY - topY - h / 2, width: w, height: h)
        }
        if w <= 0 { w = max(1, sf.width - max(0, x) + w) }
        if h <= 0 { h = max(1, sf.height - max(0, topY) + h) }
        let originX = x >= 0 ? sf.minX + x : sf.maxX + x - w
        let originY = topY >= 0 ? sf.maxY - topY - h    // from top
                                : sf.minY - topY         // from bottom (topY negative)
        return NSRect(x: originX, y: originY, width: w, height: h)
    }

    /// Authored `frame` if it is complete, otherwise `size` centred on the screen.
    /// The shape both the torus and the probe window need.
    static func rectOrCentred(_ frame: [Double]?, size: NSSize, on screen: NSScreen) -> NSRect {
        if let frame, frame.count >= 4 { return rect(from: frame, on: screen) }
        // `size` is authored (the torus's `size` param, the controllers' defaults), so
        // it scales with the canvas — uniformly, so an authored square stays square.
        let (sx, sy) = scale(for: screen)
        let s = min(sx, sy)
        let sf = screen.frame
        return NSRect(x: sf.midX - size.width * s / 2, y: sf.midY - size.height * s / 2,
                      width: size.width * s, height: size.height * s)
    }
}
