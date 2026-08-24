import MetalKit

/// The transparent window the torus floats in.
///
/// Ported from the standalone app's `TorusWindow`, with the focus behaviour inverted:
/// there the window *wanted* key status, because its keyboard shortcuts were the only
/// way to drive it. Here the show owns the keyboard — a torus that took focus would
/// pull it off the control window mid-performance and swallow the transport keys.
final class TorusWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask,
                  backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask,
                   backing: backing, defer: flag)
        // The controller holds this window strongly and calls close() on teardown.
        // isReleasedWhenClosed defaults to TRUE for a programmatically created window,
        // so close() would send an extra release and leave the controller's reference
        // dangling — which does not crash there, but later, inside an unrelated
        // Core Animation transaction. The standalone app never closed its window (it
        // just quit), so this only became reachable once the port added teardown.
        isReleasedWhenClosed = false
    }
}

/// MTKView with the transparency plumbing. Three things have to line up or the window
/// renders as a black box: `layer.isOpaque = false` (re-applied when the view joins a
/// window, because MTKView rebuilds its `CAMetalLayer` then), a zero-alpha clear colour,
/// and a fragment shader that writes premultiplied alpha.
///
/// The standalone app's key handling (material cycling, roughness, plane distance,
/// pause, quit) is gone: those are authored per event now, and `Esc` belongs to the
/// panic hotkey.
final class TorusView: MTKView {
    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        configureTransparency()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        configureTransparency()
    }

    private func configureTransparency() {
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    }

    override var isOpaque: Bool { false }

    override var acceptsFirstResponder: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // MTKView rebuilds its CAMetalLayer when it joins a window.
        layer?.isOpaque = false
    }
}
