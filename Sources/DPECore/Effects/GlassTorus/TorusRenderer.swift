import MetalKit

/// Drives `TorusScene` from an MTKView's draw loop.
///
/// **Changed in the port.** The standalone renderer accumulated `elapsed` from
/// `CACurrentMediaTime()` deltas and had a `paused` flag. Here `elapsed` is *written by
/// the show clock* before each draw, so the tumble scrubs with the playhead, freezes
/// when the transport pauses, and renders the same frame for the same timeline
/// position on every take. Nothing else about the frame differs.
final class TorusRenderer: NSObject, MTKViewDelegate {
    private let scene: TorusScene
    private let environment: ScreenEnvironment
    private let commandQueue: MTLCommandQueue

    /// Animation position, in seconds. Set from the timeline, not a wall clock.
    var elapsed: Double = 0
    /// Fixed: the camera no longer dollies, so the torus keeps a constant size.
    let cameraDistance: Float = 3.35
    var roughness: Float = 0.04
    var planeDistance: Float = 2.0
    var preset: MaterialPreset = MaterialPreset.all[0]
    private var hasWarnedAboutDisplay = false

    init(scene: TorusScene, environment: ScreenEnvironment) {
        self.scene = scene
        self.environment = environment
        self.commandQueue = scene.device.makeCommandQueue()!
        super.init()
    }

    /// Locates the window on the display the desktop picture belongs to, so the
    /// shader can turn a reflection ray into a point on that desktop.
    ///
    /// Everything is kept in points and normalised by the display's own size, so
    /// the picture's pixel resolution and the screen's backing scale never enter
    /// the maths. NSScreen's origin is bottom-left and textures are top-left, so
    /// the y coordinate is flipped here.
    private func applyMirrorGeometry(to settings: inout RenderSettings, view: MTKView) {
        guard
            environment.desktopTexture != nil,
            let window = view.window,
            let screen = window.screen,
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return }

        // The picture belongs to one display; on another one the mapping would be
        // wrong, so fall back to the surround rather than mirror the wrong thing.
        guard CGDirectDisplayID(number.uint32Value) == environment.desktopDisplayID else {
            if !hasWarnedAboutDisplay {
                hasWarnedAboutDisplay = true
                glassTorusLog.notice("window is on a display the desktop picture is not for; mirror disabled")
            }
            return
        }

        let contentRect = window.convertToScreen(view.convert(view.bounds, to: nil))
        let displayFrame = screen.frame

        settings.windowRect = SIMD4<Float>(
            Float(contentRect.minX - displayFrame.minX),
            Float(displayFrame.maxY - contentRect.maxY),
            Float(contentRect.width),
            Float(contentRect.height)
        )
        settings.displaySize = SIMD2<Float>(Float(displayFrame.width), Float(displayFrame.height))
        settings.mirrorEnabled = true
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let buffer = commandQueue.makeCommandBuffer() else { return }

        guard
            let descriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable,
            let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor)
        else {
            buffer.commit()
            return
        }

        let size = view.drawableSize
        var settings = RenderSettings(
            surround: environment.studioTexture,
            screen: environment.desktopTexture ?? environment.studioTexture
        )
        settings.aspect = size.height > 0 ? Float(size.width / size.height) : 1
        settings.elapsed = elapsed
        settings.cameraDistance = cameraDistance
        settings.roughness = roughness
        settings.material = preset
        settings.planeDistance = planeDistance
        // Rolls the ridges around the ring, independently of the tumble.
        settings.twistPhase = Float(elapsed * 0.55)
        applyMirrorGeometry(to: &settings, view: view)

        scene.encode(into: encoder, settings: settings)

        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}
