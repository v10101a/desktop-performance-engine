import AppKit

/// Screen lookup and the timeline's frame convention, in one place.
///
/// Both were duplicated across `WindowManager`, `GlassTorusController` and
/// `SystemProbeController` — three copies of the same y-flip, each of which had to be
/// right independently. The convention is documented once here and implemented once.
enum ScreenGeometry {
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
    static func rect(from frame: [Double], on screen: NSScreen,
                     fallbackSize: NSSize? = nil) -> NSRect {
        let sf = screen.frame
        let x = frame.count > 0 ? frame[0] : 0
        let topY = frame.count > 1 ? frame[1] : 0
        let w = frame.count > 2 ? frame[2] : (fallbackSize?.width ?? 300)
        let h = frame.count > 3 ? frame[3] : (fallbackSize?.height ?? 200)
        let originX = x >= 0 ? sf.minX + x : sf.maxX + x - w
        let originY = topY >= 0 ? sf.maxY - topY - h    // from top
                                : sf.minY - topY         // from bottom (topY negative)
        return NSRect(x: originX, y: originY, width: w, height: h)
    }

    /// Authored `frame` if it is complete, otherwise `size` centred on the screen.
    /// The shape both the torus and the probe window need.
    static func rectOrCentred(_ frame: [Double]?, size: NSSize, on screen: NSScreen) -> NSRect {
        if let frame, frame.count >= 4 { return rect(from: frame, on: screen) }
        let sf = screen.frame
        return NSRect(x: sf.midX - size.width / 2, y: sf.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}
