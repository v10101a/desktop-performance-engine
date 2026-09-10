import Foundation
import IOSurface

/// Reads a Syphon feed from a separate process, the way Resolume would, and says what
/// arrives: frame size, rate, a few pixel values. `./probe.sh [name-fragment] [frames]`.
let arguments = CommandLine.arguments
let wanted = (arguments.count > 1 ? arguments[1] : "Insta360").lowercased()
let wantedFrames = arguments.count > 2 ? (Int(arguments[2]) ?? 30) : 30
let deadline = Date().addingTimeInterval(12)

func describe(_ server: [String: Any]) -> String {
    let app = server[SyphonServerDescriptionAppNameKey] as? String ?? "?"
    let name = server[SyphonServerDescriptionNameKey] as? String ?? ""
    return name.isEmpty ? app : "\(app) — \(name)"
}

func servers() -> [[String: Any]] {
    (SyphonServerDirectory.shared().servers as? [[String: Any]]) ?? []
}

var client: SyphonClientBase?
let lock = NSLock()
var frames = 0
var firstFrame: Date?
var lastFrame: Date?

func connect() -> Bool {
    guard let match = servers().first(where: { describe($0).lowercased().contains(wanted) }) else { return false }
    print("connecting to \(describe(match))")
    client = SyphonClientBase(serverDescription: match, options: nil) { anyClient in
        guard let c = anyClient as? SyphonClientBase else { return }
        // `newSurface` is a +1 CF return: the very IOSurface the server rendered into.
        let surface = c.newSurface().takeRetainedValue()
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let w = IOSurfaceGetWidth(surface), h = IOSurfaceGetHeight(surface)
        let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        let base = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        func pixel(_ x: Int, _ y: Int) -> String {
            let p = base + y * bytesPerRow + x * 4        // BGRA
            return String(format: "#%02X%02X%02X", p[2], p[1], p[0])
        }
        lock.lock()
        frames += 1
        let n = frames
        let now = Date()
        if firstFrame == nil { firstFrame = now }
        lastFrame = now
        lock.unlock()
        if n == 1 || n % 10 == 0 {
            print("frame \(n): \(w)x\(h)  (\(w / 8),\(h / 8)) \(pixel(w / 8, h / 8))  centre \(pixel(w / 2, h / 2))  (\(w * 7 / 8),\(h * 7 / 8)) \(pixel(w * 7 / 8, h * 7 / 8))")
        }
    }
    return client != nil
}

var connected = false
while Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    if !connected {
        connected = connect()
        if !connected { continue }
        if client?.isValid != true {
            print("client did not connect")
            exit(1)
        }
    }
    lock.lock()
    let n = frames
    lock.unlock()
    if n >= wantedFrames { break }
}

if !connected {
    let seen = servers().map(describe)
    print("no Syphon server matching \"\(wanted)\" (servers seen: \(seen.isEmpty ? "none" : seen.joined(separator: ", ")))")
    exit(1)
}
lock.lock()
let total = frames
let span = (firstFrame != nil && lastFrame != nil) ? lastFrame!.timeIntervalSince(firstFrame!) : 0
lock.unlock()
if total > 1, span > 0 {
    print(String(format: "received %d frames in %.2f s (%.1f fps)", total, span, Double(total - 1) / span))
} else {
    print("received \(total) frames")
}
client?.stop()
exit(total > 0 ? 0 : 1)
