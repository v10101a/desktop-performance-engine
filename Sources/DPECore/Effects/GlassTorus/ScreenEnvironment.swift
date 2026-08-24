import CoreMedia
import CoreVideo
import Metal
import ScreenCaptureKit
import os
import simd

/// Query with:
///   log show --last 5m --predicate 'subsystem == "com.computerart.glasstorus"'
let glassTorusLog = Logger(subsystem: "com.computerart.glasstorus", category: "environment")

/// Supplies the environment map the metal reflects.
///
/// Preferred source is a live ScreenCaptureKit stream of the display, so the
/// torus mirrors whatever is behind it.
///
/// **Changed in the port.** The standalone app excluded its whole *application*
/// from the capture to stop the reflection recursing. Inside the show that would
/// exclude the show — the photo wall, every effect window — and the torus would
/// refract nothing but the bare desktop behind it all. Here only the torus's own
/// window is excluded (`excludingWindowNumber`), which is the minimum needed to
/// break the feedback loop, so the glass picks up the performance happening
/// underneath it. Pass `excludeWholeApp` to get the standalone behaviour back.
///
/// Screen Recording is a TCC-gated permission we may simply not have, so
/// `texture` is always valid: it starts as a procedural studio environment and
/// is only replaced once frames actually arrive.
final class ScreenEnvironment: NSObject, SCStreamOutput, SCStreamDelegate {
    private let device: MTLDevice
    private let sampleQueue = DispatchQueue(label: "com.computerart.glasstorus.capture")

    private var textureCache: CVMetalTextureCache?
    private var stream: SCStream?

    private let bufferLock = NSLock()
    private var pendingBuffer: CVPixelBuffer?
    private var hasLoggedFirstFrame = false

    /// Equirectangular surround, always present — used for reflection rays that
    /// miss the desktop plane, and as the ambient term.
    private(set) var studioTexture: MTLTexture

    /// Live capture of `capturedDisplayID`, nil until the first frame lands.
    /// Both are read on the render thread only.
    private(set) var screenTexture: MTLTexture?
    private(set) var capturedDisplayID: CGDirectDisplayID = 0

    var isLive: Bool { screenTexture != nil }

    private let statusLock = NSLock()
    private var _status: String
    var status: String {
        statusLock.lock(); defer { statusLock.unlock() }
        return _status
    }
    private func setStatus(_ value: String) {
        statusLock.lock(); _status = value; statusLock.unlock()
        // .public or the interpolation is redacted to <private> in the log.
        glassTorusLog.notice("status: \(value, privacy: .public)")
    }

    init(device: MTLDevice) throws {
        self.device = device
        self.studioTexture = try StudioEnvironment.makeTexture(device: device)
        self._status = "studio environment (capture not started)"
        super.init()
    }

    // MARK: - Capture

    /// - Parameters:
    ///   - excludingWindowNumber: `NSWindow.windowNumber` of the torus window, kept out
    ///     of the capture so its own image cannot feed back into itself.
    ///   - excludeWholeApp: exclude every window this app owns instead, which is what
    ///     the standalone app did — the torus then reflects only what is behind the show.
    func start(excludingWindowNumber: Int? = nil, excludeWholeApp: Bool = false) {
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache) == kCVReturnSuccess else {
            setStatus("studio environment (no Metal texture cache)")
            return
        }

        // All of this runs off the main thread on purpose. Both the TCC request
        // and SCShareableContent block until the user answers the permission
        // prompt; on the main thread that would stall the window and the render
        // loop behind a dialog, so the torus would not appear until you replied.
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }

            // Preflight before touching SCShareableContent: that call blocks
            // until TCC resolves, so with an unanswered prompt it simply never
            // returns and the app sits silently on the fallback.
            if !CGPreflightScreenCaptureAccess() {
                self.setStatus("requesting Screen Recording permission")
                guard CGRequestScreenCaptureAccess() else {
                    self.setStatus("studio environment — grant Screen Recording in "
                        + "System Settings ▸ Privacy & Security, then relaunch")
                    return
                }
            }

            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true
                )
                guard let display = content.displays.first else {
                    setStatus("studio environment (no display to capture)")
                    return
                }

                // Breaking the feedback loop. Excluding the single torus window is
                // enough and leaves the rest of the show visible to the glass; falling
                // back to whole-app exclusion only if that window isn't in the list yet
                // (it is ordered in before start() is called, so this is belt-and-braces
                // — an un-excluded torus would recurse into its own reflection).
                let ownWindow = excludingWindowNumber.flatMap { number in
                    content.windows.first { $0.windowID == CGWindowID(number) }
                }
                let filter: SCContentFilter
                if !excludeWholeApp, let ownWindow {
                    filter = SCContentFilter(display: display, excludingWindows: [ownWindow])
                } else {
                    let ownApplications = content.applications.filter {
                        $0.bundleIdentifier == Bundle.main.bundleIdentifier
                    }
                    filter = SCContentFilter(
                        display: display,
                        excludingApplications: ownApplications,
                        exceptingWindows: []
                    )
                }

                let configuration = SCStreamConfiguration()
                let targetWidth = 720
                let scale = Double(targetWidth) / Double(display.width)
                configuration.width = targetWidth
                configuration.height = max(2, Int((Double(display.height) * scale).rounded()))
                configuration.pixelFormat = kCVPixelFormatType_32BGRA
                configuration.colorSpaceName = CGColorSpace.sRGB
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 20)
                configuration.queueDepth = 3
                configuration.showsCursor = false

                let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
                try await stream.startCapture()
                self.stream = stream
                self.capturedDisplayID = display.displayID
                let scope = (!excludeWholeApp && ownWindow != nil) ? "show visible" : "show excluded"
                setStatus("reflecting display \(display.displayID) at "
                    + "\(configuration.width)×\(configuration.height) (\(scope))")
            } catch {
                setStatus("studio environment — screen capture unavailable: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        stream?.stopCapture { _ in }
        stream = nil
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // The compositor also emits idle/blank frames; only `.complete` ones
        // carry new pixels.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           SCFrameStatus(rawValue: raw) != .complete {
            return
        }

        bufferLock.lock()
        pendingBuffer = buffer
        bufferLock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        setStatus("studio environment — capture stopped: \(error.localizedDescription)")
    }

    // MARK: - Per-frame upload

    /// Must be called before the render encoder is created: it opens its own
    /// blit encoder on the same command buffer, and Metal forbids nesting.
    func update(using commandBuffer: MTLCommandBuffer) {
        bufferLock.lock()
        let buffer = pendingBuffer
        pendingBuffer = nil
        bufferLock.unlock()

        guard let buffer, let cache = textureCache else { return }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)

        var cvTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, buffer, nil, .bgra8Unorm, width, height, 0, &cvTexture
        )
        guard result == kCVReturnSuccess,
              let cvTexture,
              let source = CVMetalTextureGetTexture(cvTexture)
        else { return }

        if screenTexture?.width != width || screenTexture?.height != height {
            screenTexture = Self.makeMipmappedTexture(device: device, width: width, height: height)
        }
        guard let destination = screenTexture,
              let blit = commandBuffer.makeBlitCommandEncoder()
        else { return }

        blit.copy(
            from: source, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: destination, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.generateMipmaps(for: destination)
        blit.endEncoding()

        // Keep the cache-backed texture alive until the GPU is done with it.
        commandBuffer.addCompletedHandler { _ in _ = cvTexture }

        if !hasLoggedFirstFrame {
            hasLoggedFirstFrame = true
            glassTorusLog.notice(
                "first captured frame uploaded: \(width, privacy: .public)×\(height, privacy: .public)"
            )
        }
        CVMetalTextureCacheFlush(cache, 0)
    }

    static func makeMipmappedTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: true
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }
}

/// Procedural equirectangular studio: two softboxes over a bright ceiling and a
/// dark floor. Stands in when screen capture is denied, and gives the metal
/// something with real contrast to reflect either way.
enum StudioEnvironment {
    static func makeTexture(device: MTLDevice) throws -> MTLTexture {
        let width = 512, height = 256
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        for y in 0..<height {
            let v = Float(y) / Float(height - 1)
            let up = cos(v * .pi)   // +1 at the top pole, -1 at the bottom

            for x in 0..<width {
                let u = Float(x) / Float(width - 1)

                var color = SIMD3<Float>(0.045, 0.050, 0.065)
                color += SIMD3<Float>(0.28, 0.34, 0.45) * max(up, 0)
                color += SIMD3<Float>(0.06, 0.05, 0.05) * max(-up, 0) * 0.4

                color += SIMD3<Float>(1.00, 0.96, 0.90) * softbox(u, v, 0.28, 0.20, 0.013, 0.007) * 1.7
                color += SIMD3<Float>(0.55, 0.70, 1.00) * softbox(u, v, 0.72, 0.34, 0.022, 0.020) * 0.8
                color += SIMD3<Float>(1.00, 0.72, 0.45) * softbox(u, v, 0.05, 0.44, 0.010, 0.030) * 0.5

                // Faint horizon so grazing reflections get a line to catch.
                let horizon = exp(-pow((v - 0.5) / 0.02, 2))
                color += SIMD3<Float>(0.12, 0.14, 0.18) * horizon

                let index = (y * width + x) * 4
                pixels[index + 0] = encode(color.z)   // B
                pixels[index + 1] = encode(color.y)   // G
                pixels[index + 2] = encode(color.x)   // R
                pixels[index + 3] = 255
            }
        }

        guard let texture = ScreenEnvironment.makeMipmappedTexture(
            device: device, width: width, height: height
        ) else { throw SceneError.setupFailed("could not allocate the studio environment") }

        try upload(pixels: pixels, width: width, height: height, to: texture, device: device)
        return texture
    }

    private static func softbox(
        _ u: Float, _ v: Float,
        _ centerU: Float, _ centerV: Float,
        _ spreadU: Float, _ spreadV: Float
    ) -> Float {
        let du = min(abs(u - centerU), 1 - abs(u - centerU))   // wrap in longitude
        let dv = v - centerV
        return exp(-(du * du / spreadU + dv * dv / spreadV))
    }

    /// The shader linearises with pow(c, 2.2), so store sRGB-ish bytes.
    private static func encode(_ value: Float) -> UInt8 {
        UInt8(max(0, min(1, pow(max(value, 0), 1 / 2.2))) * 255)
    }

    /// Uploads level 0 into a private texture via a staging buffer, then builds
    /// the mip chain the roughness lookup samples from.
    static func upload(
        pixels: [UInt8], width: Int, height: Int,
        to texture: MTLTexture, device: MTLDevice
    ) throws {
        guard
            let staging = device.makeBuffer(bytes: pixels, length: pixels.count, options: .storageModeShared),
            let queue = device.makeCommandQueue(),
            let commandBuffer = queue.makeCommandBuffer(),
            let blit = commandBuffer.makeBlitCommandEncoder()
        else { throw SceneError.setupFailed("could not upload the environment map") }

        blit.copy(
            from: staging, sourceOffset: 0,
            sourceBytesPerRow: width * 4, sourceBytesPerImage: width * height * 4,
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: texture, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }
}
