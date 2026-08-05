import AppKit

/// Renders the show's window content into a single PNG, off-screen, using the same
/// content builders the live windows use. Lets us verify visual rendering without
/// needing Screen Recording permission. Not part of the performance — a dev tool.
enum StillRenderer {
    static func render(to url: URL) throws {
        let canvasSize = NSSize(width: 1120, height: 620)
        let canvas = NSView(frame: NSRect(origin: .zero, size: canvasSize))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor(hex: "#101014")?.cgColor

        // color window
        let color = makeEffectContentView(ContentSpec(kind: "color", hex: "#FF2D95", text: nil, path: nil),
                                          size: NSSize(width: 360, height: 260))
        color.frame = NSRect(x: 40, y: 320, width: 360, height: 260)

        // text window
        let text = makeEffectContentView(ContentSpec(kind: "text", hex: nil, text: "HELLO", path: nil),
                                         size: NSSize(width: 440, height: 200))
        text.frame = NSRect(x: 440, y: 360, width: 440, height: 200)

        // teal color window
        let teal = makeEffectContentView(ContentSpec(kind: "color", hex: "#25F4EE", text: nil, path: nil),
                                         size: NSSize(width: 200, height: 200))
        teal.frame = NSRect(x: 900, y: 360, width: 200, height: 200)

        // fake dialog
        let dialog = makeDialogContentView(title: "CRITICAL VIBES",
                                           message: "Your desktop is 12% too calm. Increase chaos?",
                                           buttons: ["MORE", "EVEN MORE"],
                                           size: NSSize(width: 440, height: 180))
        dialog.frame = NSRect(x: 60, y: 40, width: 440, height: 180)

        let dialog2 = makeDialogContentView(title: "UH OH",
                                            message: "A wild window appeared.",
                                            buttons: ["neat"],
                                            size: NSSize(width: 380, height: 150))
        dialog2.frame = NSRect(x: 560, y: 40, width: 380, height: 150)

        [color, text, teal, dialog, dialog2].forEach { canvas.addSubview($0) }

        // Host in an off-screen window so the layer tree composites, then cache it.
        let host = NSWindow(contentRect: NSRect(origin: NSPoint(x: -5000, y: -5000), size: canvasSize),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        host.contentView = canvas
        host.orderBack(nil)
        canvas.display()

        guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
            throw NSError(domain: "StillRenderer", code: 1)
        }
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        host.orderOut(nil)

        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "StillRenderer", code: 2)
        }
        try data.write(to: url)
    }
}
