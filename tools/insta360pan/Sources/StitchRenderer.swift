import AppKit
import CoreVideo
import IOSurface
import Metal
import MetalKit

/// Everything that puts pixels somewhere: takes the newest camera frame (or synthesises
/// one), renders the viewport through the lens model into the output frame — the IOSurface
/// Syphon publishes — and letterboxes that frame into the window. What the window shows
/// is exactly what Resolume gets.
final class StitchRenderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let stitchPipeline: MTLRenderPipelineState
    private let synthPipeline: MTLRenderPipelineState
    private let blitPipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private let placeholder: MTLTexture
    private let syphon: SyphonOutput?

    // Written on the source's thread, read on the main thread.
    private let lock = NSLock()
    private var pending: CVPixelBuffer?
    private var frameCount = 0

    // Main thread only.
    private var currentBuffer: CVPixelBuffer?
    private var current: CVMetalTexture?
    private var currentTexture: MTLTexture?
    private(set) var frameSize = SIMD2<Int>(0, 0)
    private(set) var outputTexture: MTLTexture?
    private(set) var outputSize = SIMD2<Int>(1920, 1080)
    private var dirty = true

    /// The synthetic camera: when on, frames are rendered rather than received. It is built
    /// on `syntheticTruth`, deliberately not the live calibration, so moving a control shows
    /// what that control does to a stitch that was right.
    var synthetic = false {
        didSet {
            guard synthetic != oldValue else { return }
            if synthetic {
                frameSize = StitchRenderer.syntheticFrameSize
                updateBand()
            }
            dirty = true
        }
    }
    static let syntheticTruth = Calibration()
    /// The scene sits at the default stitch distance, so the default calibration stitches
    /// it exactly; moving the distance then shows what parallax does to a seam.
    static let syntheticSceneDistance = Calibration().stitchDistanceMetres
    static let syntheticFrameSize = SIMD2<Int>(1920, 1080)
    private var synthTexture: MTLTexture?
    private let started = Date()

    var viewport = Viewport() {
        didSet { if viewport != oldValue { dirty = true } }
    }
    var calibration = Calibration() {
        didSet {
            if calibration != oldValue {
                updateBand()
                dirty = true
            }
        }
    }
    /// Show the frame as it arrives, with the lens model drawn over it.
    var rawView = false {
        didSet { dirty = true }
    }
    var showOverlay = true {
        didSet { dirty = true }
    }

    init(device: MTLDevice, syphon: SyphonOutput?) throws {
        self.device = device
        self.syphon = syphon
        guard let queue = device.makeCommandQueue() else {
            throw NSError(domain: "insta360pan", code: 1, userInfo: [NSLocalizedDescriptionKey: "no Metal command queue"])
        }
        self.queue = queue

        let library = try device.makeLibrary(source: shaderSource, options: nil)
        func pipeline(_ vertex: String, _ fragment: String) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try device.makeRenderPipelineState(descriptor: d)
        }
        stitchPipeline = try pipeline("fullscreen_vertex", "stitch_fragment")
        synthPipeline = try pipeline("fullscreen_vertex", "synth_fragment")
        blitPipeline = try pipeline("blit_vertex", "blit_fragment")

        // Until the first frame lands the camera is this: one dark grey pixel.
        let pd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        pd.usage = .shaderRead
        guard let placeholder = device.makeTexture(descriptor: pd) else {
            throw NSError(domain: "insta360pan", code: 2, userInfo: [NSLocalizedDescriptionKey: "no placeholder texture"])
        }
        var grey: [UInt8] = [40, 40, 40, 255]
        placeholder.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &grey, bytesPerRow: 4)
        self.placeholder = placeholder

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        updateBand()
        setOutputSize(outputSize)
    }

    // MARK: - Input

    /// New frame from the source. Any thread; only the newest one is ever drawn.
    func submit(_ buffer: CVPixelBuffer) {
        lock.lock()
        pending = buffer
        frameCount += 1
        lock.unlock()
    }

    /// Frames since the last call — the status line's fps.
    func takeFrameCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let n = frameCount
        frameCount = 0
        return n
    }

    var hasFrame: Bool { synthetic || currentTexture != nil }

    private func ingestPending() {
        lock.lock()
        let fresh = pending
        pending = nil
        lock.unlock()
        guard let fresh, let cache = textureCache else { return }

        let w = CVPixelBufferGetWidth(fresh), h = CVPixelBufferGetHeight(fresh)
        if frameSize != [w, h] {
            frameSize = [w, h]
            updateBand()
        }
        var cv: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, fresh, nil, .bgra8Unorm, w, h, 0, &cv)
        guard status == kCVReturnSuccess, let cv, let texture = CVMetalTextureGetTexture(cv) else { return }
        currentBuffer = fresh
        current = cv
        currentTexture = texture
        dirty = true
        CVMetalTextureCacheFlush(cache, 0)
    }

    /// The viewport needs to know how far up and down the band reaches; that comes from the
    /// calibration and only changes when it does.
    private func updateBand() {
        viewport.bandHalfPitch = calibration.bandHalfPitchDegrees
        viewport.normalise()
    }

    private var frameSizeDouble: SIMD2<Double> {
        frameSize.x > 0 ? SIMD2<Double>(Double(frameSize.x), Double(frameSize.y)) : Calibration.referenceFrame
    }

    // MARK: - Output

    /// (Re)creates the output frame at `size`. When Syphon is up the texture is a view onto
    /// the server's IOSurface, so rendering into it *is* publishing; otherwise it is a plain
    /// texture and the window is the only viewer.
    func setOutputSize(_ size: SIMD2<Int>) {
        outputSize = size
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size.x, height: size.y, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = device.hasUnifiedMemory ? .shared : .managed
        if let surface = syphon?.surface(width: size.x, height: size.y) {
            outputTexture = device.makeTexture(descriptor: d, iosurface: surface, plane: 0)
        }
        if outputTexture == nil || outputTexture!.width != size.x || outputTexture!.height != size.y {
            outputTexture = device.makeTexture(descriptor: d)
        }
        viewport.outputSize = [Double(size.x), Double(size.y)]
        viewport.normalise()
        dirty = true
    }

    func markDirty() { dirty = true }

    /// The uniform block for the stitch pass. The output frame is always rendered bottom
    /// row first, which is how Syphon surfaces are read; the window blit turns it back.
    private var stitchUniforms: StitchUniforms {
        var flags = StitchUniforms.flipVertical
        if rawView {
            flags |= StitchUniforms.rawView
            if showOverlay { flags |= StitchUniforms.overlay }
        }
        return calibration.uniforms(viewport: viewport, frameSize: frameSizeDouble, flags: flags)
    }

    private func encodeStitch(_ cmd: MTLCommandBuffer, into target: MTLTexture, camera: MTLTexture) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(stitchPipeline)
        enc.setFragmentTexture(camera, index: 0)
        var u = stitchUniforms
        enc.setFragmentBytes(&u, length: MemoryLayout<StitchUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// The synthetic camera's frame for this instant.
    private func encodeSynthetic(_ cmd: MTLCommandBuffer) -> MTLTexture? {
        if synthTexture == nil {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: StitchRenderer.syntheticFrameSize.x,
                height: StitchRenderer.syntheticFrameSize.y, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            synthTexture = device.makeTexture(descriptor: d)
        }
        guard let target = synthTexture else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        enc.setRenderPipelineState(synthPipeline)
        let size = SIMD2<Double>(Double(target.width), Double(target.height))
        var u = StitchRenderer.syntheticTruth.uniforms(
            viewport: viewport, frameSize: size, flags: 0,
            time: Date().timeIntervalSince(started), sceneDistance: StitchRenderer.syntheticSceneDistance)
        enc.setFragmentBytes(&u, length: MemoryLayout<StitchUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        return target
    }

    /// The camera texture for this frame, encoding the synthetic one first if that is
    /// where frames come from.
    private func cameraTexture(_ cmd: MTLCommandBuffer) -> MTLTexture {
        if synthetic {
            lock.lock()
            frameCount += 1
            lock.unlock()
            dirty = true
            return encodeSynthetic(cmd) ?? placeholder
        }
        return currentTexture ?? placeholder
    }

    /// Where a frame of `output` proportions sits when letterboxed into `container`, both
    /// in the same units. Used for the window and for turning pointer positions back into
    /// output pixels.
    static func fit(output: SIMD2<Double>, into container: SIMD2<Double>) -> (origin: SIMD2<Double>, size: SIMD2<Double>) {
        guard output.x > 0, output.y > 0, container.x > 0, container.y > 0 else { return ([0, 0], container) }
        let scale = min(container.x / output.x, container.y / output.y)
        let size = output * scale
        return ((container - size) / 2, size)
    }

    /// Draws one frame if anything changed since the last one: a new camera frame, a pan, a
    /// zoom, a setting. Otherwise nothing is drawn and nothing is published, so a still
    /// picture costs Resolume nothing. The synthetic camera always changes.
    func draw(in view: MTKView) {
        if !synthetic { ingestPending() }
        guard dirty || synthetic, let output = outputTexture else { return }
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer() else { return }
        let camera = cameraTexture(cmd)
        dirty = false

        encodeStitch(cmd, into: output, camera: camera)

        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1)
        if let enc = cmd.makeRenderCommandEncoder(descriptor: pass) {
            let container = SIMD2<Double>(view.drawableSize.width, view.drawableSize.height)
            let fitted = StitchRenderer.fit(output: [Double(output.width), Double(output.height)], into: container)
            let half = fitted.size / container      // fitted is centred, so this is the clip-space half extent
            var rect = SIMD4<Float>(Float(-half.x), Float(-half.y), Float(half.x), Float(half.y))
            var flipped: UInt32 = 1
            enc.setRenderPipelineState(blitPipeline)
            enc.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            enc.setVertexBytes(&flipped, length: MemoryLayout<UInt32>.stride, index: 1)
            enc.setFragmentTexture(output, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
        }
        cmd.present(drawable)

        // The camera texture must outlive the GPU's read of it, and Syphon clients are told
        // about the frame only once it is actually on the surface.
        let hold = (current, currentBuffer)
        let syphon = self.syphon
        cmd.addCompletedHandler { _ in
            withExtendedLifetime(hold) {}
            syphon?.publish()
        }
        cmd.commit()
    }

    /// Renders the output frame right now and reads it back the right way up — `--snapshot`.
    func snapshot() -> CGImage? {
        if !synthetic { ingestPending() }
        guard let output = outputTexture, let cmd = queue.makeCommandBuffer() else { return nil }
        let camera = cameraTexture(cmd)
        encodeStitch(cmd, into: output, camera: camera)
        if output.storageMode == .managed, let blit = cmd.makeBlitCommandEncoder() {
            blit.synchronize(resource: output)
            blit.endEncoding()
        }
        cmd.commit()
        cmd.waitUntilCompleted()
        syphon?.publish()

        let w = output.width, h = output.height, bytesPerRow = w * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * h)
        output.getBytes(&bytes, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        // The surface is bottom row first; a PNG is top row first.
        var upright = [UInt8](repeating: 0, count: bytesPerRow * h)
        for row in 0..<h {
            let src = (h - 1 - row) * bytesPerRow
            upright.replaceSubrange(row * bytesPerRow..<(row + 1) * bytesPerRow, with: bytes[src..<src + bytesPerRow])
        }
        guard let provider = CGDataProvider(data: Data(upright) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
