import Foundation
import IOSurface

/// The Syphon server. It hands out the IOSurface the renderer draws into and announces
/// each finished frame.
///
/// The Syphon builds that ship inside TouchDesigner and OBS are Syphon 5 without a
/// `SyphonMetalServer`, but `SyphonServerBase` plus its subclassing category is all a
/// server needs: ask it for a surface, wrap the surface in a Metal texture, render, call
/// `publish`. That is what the framework's own Metal server does internally.
final class SyphonOutput {
    let name: String
    private let server: SyphonServerBase
    private var surface: IOSurfaceRef?

    init(name: String) {
        self.name = name
        server = SyphonServerBase(name: name, options: nil)
    }

    var hasClients: Bool { server.hasClients }

    /// What clients see in their server lists — the app name comes from the bundle.
    var description: [String: Any] {
        (server.serverDescription as? [String: Any]) ?? [:]
    }

    /// The surface for frames of this size. Syphon keeps one surface and replaces it when
    /// the size changes, telling clients either way; `copySurfaceForWidth:` is a +1 CF
    /// return so the ownership lands here.
    func surface(width: Int, height: Int) -> IOSurfaceRef? {
        guard let s = server.copySurface(forWidth: width, height: height, options: nil)?.takeRetainedValue() else {
            return nil
        }
        surface = s
        return s
    }

    /// Call once the surface holds a finished frame.
    func publish() { server.publish() }

    func stop() {
        server.stop()
        surface = nil
    }
}
