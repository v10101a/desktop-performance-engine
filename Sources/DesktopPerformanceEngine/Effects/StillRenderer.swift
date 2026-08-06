import AppKit

/// Renders the show's window content into a single PNG, off-screen, using the same
/// content builders the live windows use. Lets us verify visual rendering without
/// needing Screen Recording permission. Not part of the performance — a dev tool.
enum StillRenderer {
    /// Render phases of a timeline's first sprite as a vertical montage — the same
    /// cell geometry + micro content views the live pool uses, so what you see is
    /// what the show spawns. Used by `--snapshot=out.png path/to/timeline.json`.
    static func renderSprite(_ p: SpriteParams, to url: URL) throws {
        let cellW = p.cell ?? 30
        let cellH = cellW * (p.cellAspect ?? 0.72)
        let gap = p.gap ?? 4
        let offsets = WindowManager.spriteFrameOffsets(p.frames, strideX: cellW + gap,
                                                       strideY: cellH + gap)
        let phases = [0, offsets.count / 3, (2 * offsets.count) / 3]
        let spriteW = (p.frames.first?.map(\.count).max() ?? 1)
        let spriteH = p.frames.first?.count ?? 1
        let paneW = Double(spriteW) * (cellW + gap) + 40
        let paneH = Double(spriteH) * (cellH + gap) + 40
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: paneW,
                                          height: paneH * Double(phases.count)))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor(hex: "#101014")?.cgColor
        let colors = p.colors ?? WindowManager.defaultPoolColors
        for (pi, fi) in phases.enumerated() {
            let baseY = canvas.frame.height - paneH * Double(pi + 1) + 20
            for (i, cell) in offsets[fi].enumerated() {
                let v = makeMicroContentView(size: NSSize(width: cellW, height: cellH),
                                             bodyColor: NSColor(hex: colors[i % colors.count]) ?? .magenta,
                                             chrome: resolvedChromeKind(p.chrome ?? "mixed", index: i),
                                             title: nil)
                // Flip authored +y-down offsets into the view's bottom-left space.
                v.frame = NSRect(x: 20 + cell.x,
                                 y: baseY + paneH - 40 - cell.y - cellH,
                                 width: cellW, height: cellH)
                canvas.addSubview(v)
            }
        }
        try writePNG(canvas: canvas, to: url)
    }

    static func render(to url: URL) throws {
        let canvasSize = NSSize(width: 1120, height: 620)
        let canvas = NSView(frame: NSRect(origin: .zero, size: canvasSize))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor(hex: "#101014")?.cgColor

        // color window with fake browser chrome
        let color = makeEffectContentView(ContentSpec(kind: "color", hex: "#020AF5", text: nil, path: nil,
                                                      chrome: "browser", title: "horse://gallop"),
                                          size: NSSize(width: 360, height: 260))
        color.frame = NSRect(x: 40, y: 320, width: 360, height: 260)

        // text window
        let text = makeEffectContentView(ContentSpec(kind: "text", hex: nil, text: "HELLO", path: nil,
                                                     chrome: nil, title: nil),
                                         size: NSSize(width: 440, height: 200))
        text.frame = NSRect(x: 440, y: 360, width: 440, height: 200)

        // teal color window with terminal chrome
        let teal = makeEffectContentView(ContentSpec(kind: "color", hex: "#68BDF8", text: nil, path: nil,
                                                     chrome: "terminal", title: "haunt.sh"),
                                         size: NSSize(width: 200, height: 200))
        teal.frame = NSRect(x: 900, y: 360, width: 200, height: 200)

        // a row of micro-windows at sprite-pixel size, mixed chrome
        var micros: [NSView] = []
        for i in 0..<5 {
            let body = NSColor(hex: WindowManager.defaultPoolColors[i % WindowManager.defaultPoolColors.count]) ?? .magenta
            let m = makeMicroContentView(size: NSSize(width: 30, height: 22),
                                         bodyColor: body,
                                         chrome: resolvedChromeKind("mixed", index: i),
                                         title: nil)
            m.frame = NSRect(x: 560 + CGFloat(i) * 38, y: 260, width: 30, height: 22)
            micros.append(m)
        }

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

        ([color, text, teal, dialog, dialog2] + micros).forEach { canvas.addSubview($0) }
        try writePNG(canvas: canvas, to: url)
    }

    /// Host in an off-screen window so the layer tree composites, then cache to PNG.
    private static func writePNG(canvas: NSView, to url: URL) throws {
        let host = NSWindow(contentRect: NSRect(origin: NSPoint(x: -5000, y: -5000),
                                                size: canvas.frame.size),
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
