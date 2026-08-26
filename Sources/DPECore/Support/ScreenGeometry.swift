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
    /// (The chorus clock leaned left and up on a 1512×982 display for exactly that
    /// reason: authored at 1440×900, it was centred on that screen and nothing else.)
    static func rect(from frame: [Double], on screen: NSScreen, anchor: String? = nil,
                     fallbackSize: NSSize? = nil) -> NSRect {
        let sf = screen.frame
        let x = frame.count > 0 ? frame[0] : 0
        let topY = frame.count > 1 ? frame[1] : 0
        var w = frame.count > 2 ? frame[2] : (fallbackSize?.width ?? 300)
        var h = frame.count > 3 ? frame[3] : (fallbackSize?.height ?? 200)
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
        let sf = screen.frame
        return NSRect(x: sf.midX - size.width / 2, y: sf.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}
