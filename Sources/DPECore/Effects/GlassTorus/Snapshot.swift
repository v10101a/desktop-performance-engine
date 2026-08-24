import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

enum SnapshotError: Error, CustomStringConvertible {
    case setupFailed(String)
    case encodeFailed

    var description: String {
        switch self {
        case .setupFailed(let m): return m
        case .encodeFailed: return "could not encode PNG"
        }
    }
}

/// Renders a single frame offscreen and writes it as a PNG with a real alpha
/// channel. Useful for eyeballing the shading without launching a window, and it
/// is the honest way to confirm the background is transparent.
///
/// Ported unchanged from the standalone app. It is the only way to verify the torus
/// actually renders inside the show without granting Screen Recording or taking over
/// the display — `--test-glasstorus` drives it.
enum Snapshot {
    /// `environmentPath` substitutes a still image for the live screen capture,
    /// which is how the reflection maths can be checked without Screen Recording
    /// permission. Nil uses the procedural studio environment.
    static func write(
        to path: String,
        size: Int,
        elapsed: Double,
        environmentPath: String?,
        roughness: Float,
        metal: String?,
        mirror: Bool,
        planeDistance: Float
    ) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw SnapshotError.setupFailed("no Metal device available")
        }
        let scene = try TorusScene(device: device)
        guard let queue = device.makeCommandQueue() else {
            throw SnapshotError.setupFailed("could not create a command queue")
        }

        let studio = try StudioEnvironment.makeTexture(device: device)
        let screen = try environmentPath.map { try loadEnvironment(path: $0, device: device) } ?? studio
        let preset = MaterialPreset.all.first { $0.name == metal } ?? MaterialPreset.all[0]

        let multisample = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: TorusScene.colorFormat, width: size, height: size, mipmapped: false)
        multisample.textureType = .type2DMultisample
        multisample.sampleCount = TorusScene.sampleCount
        multisample.usage = .renderTarget
        multisample.storageMode = .private

        let depth = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: TorusScene.depthFormat, width: size, height: size, mipmapped: false)
        depth.textureType = .type2DMultisample
        depth.sampleCount = TorusScene.sampleCount
        depth.usage = .renderTarget
        depth.storageMode = .private

        let resolve = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: TorusScene.colorFormat, width: size, height: size, mipmapped: false)
        resolve.usage = [.renderTarget, .shaderRead]
        resolve.storageMode = .shared

        guard
            let multisampleTexture = device.makeTexture(descriptor: multisample),
            let depthTexture = device.makeTexture(descriptor: depth),
            let resolveTexture = device.makeTexture(descriptor: resolve)
        else {
            throw SnapshotError.setupFailed("could not allocate render targets")
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = multisampleTexture
        pass.colorAttachments[0].resolveTexture = resolveTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1.0

        guard
            let buffer = queue.makeCommandBuffer(),
            let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
        else {
            throw SnapshotError.setupFailed("could not begin encoding")
        }
        var settings = RenderSettings(surround: studio, screen: screen)
        settings.elapsed = elapsed
        settings.twistPhase = Float(elapsed * 0.55)
        settings.roughness = roughness
        settings.material = preset
        if mirror {
            // Stands in for the live geometry: pretend the display is the size of
            // the supplied image and the window is a centred square a third as
            // wide, which is roughly how the real thing sits on screen.
            let displayWidth = Float(screen.width)
            let displayHeight = Float(screen.height)
            let side = displayWidth / 3
            settings.mirrorEnabled = true
            settings.displaySize = SIMD2<Float>(displayWidth, displayHeight)
            settings.windowRect = SIMD4<Float>(
                (displayWidth - side) / 2, (displayHeight - side) / 2, side, side
            )
            settings.planeDistance = planeDistance
        }
        scene.encode(into: encoder, settings: settings)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()

        try writePNG(from: resolveTexture, size: size, to: path)
    }

    /// Loads any ImageIO-readable file as an equirectangular environment map.
    private static func loadEnvironment(path: String, device: MTLDevice) throws -> MTLTexture {
        let url = URL(fileURLWithPath: path)
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw SnapshotError.setupFailed("could not read environment image at \(path)") }

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
        ) else { throw SnapshotError.setupFailed("could not decode environment image") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let texture = ScreenEnvironment.makeMipmappedTexture(
            device: device, width: width, height: height
        ) else { throw SnapshotError.setupFailed("could not allocate the environment texture") }

        try StudioEnvironment.upload(
            pixels: pixels, width: width, height: height, to: texture, device: device
        )
        return texture
    }

    private static func writePNG(from texture: MTLTexture, size: Int, to path: String) throws {
        let bytesPerRow = size * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * size)
        pixels.withUnsafeMutableBytes { raw in
            texture.getBytes(
                raw.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, size, size),
                mipmapLevel: 0
            )
        }

        // .bgra8Unorm → premultipliedFirst + little-endian byte order.
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )
        guard
            let provider = CGDataProvider(data: Data(pixels) as CFData),
            let image = CGImage(
                width: size, height: size,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo,
                provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent
            )
        else { throw SnapshotError.encodeFailed }

        let url = URL(fileURLWithPath: path)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { throw SnapshotError.encodeFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw SnapshotError.encodeFailed
        }
    }
}
