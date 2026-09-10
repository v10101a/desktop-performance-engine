import AppKit
import MetalKit

/// The window's picture: the output frame letterboxed, with the mouse and trackpad wired
/// to the viewport. Drag pans, pinch zooms about the pointer, two-finger scroll pans,
/// ⌥-scroll zooms (for a mouse), a two-finger double-tap toggles 1× and 3×.
final class StitchView: MTKView {
    var renderer: StitchRenderer!
    /// Called after every pointer-driven change, for the status line.
    var onInteraction: (() -> Void)?

    private var lastDrag: NSPoint?

    override var isFlipped: Bool { true }          // y down, like the output frame
    override var acceptsFirstResponder: Bool { true }

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        colorPixelFormat = .bgra8Unorm
        preferredFramesPerSecond = 60
        isPaused = false
        enableSetNeedsDisplay = false
        clearColor = MTLClearColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1)
    }

    required init(coder: NSCoder) { fatalError("not used") }

    // MARK: - Geometry

    /// The output frame letterboxed into the view, in view points.
    var fittedRect: NSRect {
        let out = SIMD2<Double>(Double(renderer.outputSize.x), Double(renderer.outputSize.y))
        let fit = StitchRenderer.fit(output: out, into: [bounds.width, bounds.height])
        return NSRect(x: fit.origin.x, y: fit.origin.y, width: fit.size.x, height: fit.size.y)
    }

    /// The output pixel under a view point.
    func outputPixel(at p: NSPoint) -> SIMD2<Double> {
        let r = fittedRect
        return [(p.x - r.minX) / r.width * Double(renderer.outputSize.x),
                (p.y - r.minY) / r.height * Double(renderer.outputSize.y)]
    }

    /// A movement in view points as output pixels.
    func outputDelta(_ d: NSPoint) -> SIMD2<Double> {
        let r = fittedRect
        return [d.x / r.width * Double(renderer.outputSize.x),
                d.y / r.height * Double(renderer.outputSize.y)]
    }

    var centerPixel: SIMD2<Double> {
        [Double(renderer.outputSize.x) / 2, Double(renderer.outputSize.y) / 2]
    }

    // MARK: - Pointer

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        lastDrag = convert(event.locationInWindow, from: nil)
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let last = lastDrag else {
            lastDrag = p
            return
        }
        renderer.viewport.pan(byOutputPixels: outputDelta(NSPoint(x: p.x - last.x, y: p.y - last.y)))
        lastDrag = p
        onInteraction?()
    }

    override func mouseUp(with event: NSEvent) {
        lastDrag = nil
        NSCursor.pop()
    }

    override func magnify(with event: NSEvent) {
        let anchor = outputPixel(at: convert(event.locationInWindow, from: nil))
        renderer.viewport.zoom(by: 1 + event.magnification, anchor: anchor)
        onInteraction?()
    }

    override func smartMagnify(with event: NSEvent) {
        let anchor = outputPixel(at: convert(event.locationInWindow, from: nil))
        let z = renderer.viewport.zoom
        renderer.viewport.zoom(by: z < 1.5 ? 3 / z : 1 / z, anchor: anchor)
        onInteraction?()
    }

    override func scrollWheel(with event: NSEvent) {
        // Mice report whole lines; trackpads report points.
        let scale = event.hasPreciseScrollingDeltas ? 1.0 : 10.0
        let dx = event.scrollingDeltaX * scale, dy = event.scrollingDeltaY * scale
        if event.modifierFlags.contains(.option) {
            let anchor = outputPixel(at: convert(event.locationInWindow, from: nil))
            renderer.viewport.zoom(by: exp(dy * 0.01), anchor: anchor)
        } else {
            renderer.viewport.pan(byOutputPixels: outputDelta(NSPoint(x: dx, y: dy)))
        }
        onInteraction?()
    }
}
