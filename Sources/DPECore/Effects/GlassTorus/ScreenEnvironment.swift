import AppKit
import CoreGraphics
import ImageIO
import Metal
import os
import simd

/// Query with:
///   log show --last 5m --predicate 'subsystem == "com.computerart.glasstorus"'
let glassTorusLog = Logger(subsystem: "com.computerart.glasstorus", category: "environment")

/// Supplies the environment map the metal reflects.
///
/// **Changed: the desktop plane is a picture, not a capture.** This used to run a live
/// ScreenCaptureKit stream of the display, so the glass refracted whatever was behind it
/// — the photo wall, every effect window, the show itself. That cost Screen Recording,
/// which is the one permission here that cannot be settled by a prompt: macOS sends the
/// viewer to System Settings and wants a relaunch, so a "no" (or an unanswered dialog)
/// left the torus reflecting a procedural studio for the rest of the run.
///
/// The plane is now the viewer's own desktop picture, read from the file
/// `WallpaperController` snapshots before the show swaps the wallpaper to blue. The torus
/// still shows *this* machine's desktop, which is the point of it; it just no longer
/// moves, and no longer catches the show layered on top.
///
/// Either way there is always something to reflect: the surround is the procedural studio
/// from the start, and the desktop picture only ever replaces the plane.
final class ScreenEnvironment {
    private let device: MTLDevice

    /// Equirectangular surround, always present — used for reflection rays that
    /// miss the desktop plane, and as the ambient term.
    private(set) var studioTexture: MTLTexture

    /// The desktop picture. Nil until the decode lands, and after it if the file could
    /// not be read. Written and read on the main thread only — the show renders from
    /// `GlassTorusController.update(now:)`, which the display pump drives on main — so
    /// the decode hops back there to publish and no lock is needed.
    private(set) var desktopTexture: MTLTexture?

    /// The display the picture was read for. The mirror maths maps window coordinates
    /// into this display's space, so on any other screen it must not be used.
    private(set) var desktopDisplayID: CGDirectDisplayID = 0

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
        self._status = "studio environment (no desktop picture loaded)"
    }

    // MARK: - Desktop picture

    /// Load `url` as the plane the metal reflects.
    ///
    /// Off the main thread, for the same reason the capture it replaces was async: this
    /// is called from `begin()`, which the display pump runs between frames, and a
    /// synchronous decode there stalls the show. Measured on this machine: a 5 MB HEIC
    /// wallpaper cost 48 ms, which on top of the ~80 ms Metal pipeline compile in
    /// `ensureScene` pushed the worst event drift of the run from 8 ms to 131 ms — a
    /// third of a beat, landing on the frame the torus appears.
    ///
    /// The torus renders against the studio surround for the handful of frames until the
    /// picture lands, which is exactly what it used to do while the capture warmed up.
    ///
    /// The decode is capped at `maxEnvironmentPixel` on the long edge. The stream this
    /// replaces ran at 720 px wide, so decoding a 6K wallpaper in full would buy detail
    /// no reflection can show.
    func start(desktopPicture url: URL?, on screen: NSScreen?) {
        guard let url else {
            setStatus("studio environment (no desktop picture to read)")
            return
        }
        let device = self.device
        let displayID = screen.flatMap(WallpaperImage.displayID(of:)) ?? 0
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let texture = try Self.loadEnvironment(
                    url: url, device: device, maxPixel: Self.maxEnvironmentPixel)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.desktopTexture = texture
                    self.desktopDisplayID = displayID
                    self.setStatus("reflecting the desktop picture \(url.lastPathComponent)")
                }
            } catch {
                DispatchQueue.main.async {
                    self?.setStatus("studio environment — could not read the desktop "
                        + "picture: \(error)")
                }
            }
        }
    }

    static let maxEnvironmentPixel = 1024

    /// Loads any ImageIO-readable file as an equirectangular environment map.
    ///
    /// `maxPixel` caps the long edge; ImageIO subsamples while decoding rather than
    /// afterwards, so a huge wallpaper costs about what a small one does. Pass nil for
    /// the full-size decode `Snapshot` wants.
    static func loadEnvironment(url: URL, device: MTLDevice, maxPixel: Int?) throws -> MTLTexture {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw SceneError.setupFailed("could not read environment image at \(url.path)")
        }
        let decoded: CGImage?
        if let maxPixel {
            decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel
            ] as CFDictionary)
        } else {
            decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let image = decoded else {
            throw SceneError.setupFailed("could not decode environment image at \(url.path)")
        }

        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        // premultipliedFirst + little-endian lays the bytes out as BGRA, which is
        // what .bgra8Unorm expects.
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo
        ) else { throw SceneError.setupFailed("could not decode environment image") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let texture = makeMipmappedTexture(device: device, width: width, height: height) else {
            throw SceneError.setupFailed("could not allocate the environment texture")
        }
        try StudioEnvironment.upload(
            pixels: pixels, width: width, height: height, to: texture, device: device)
        return texture
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
