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

    /// Render every intro-gate card as a vertical montage, using the same card builder
    /// the live gate uses. Buttons draw but are inert. `--snapshot-gate=out.png`.
    static func renderGate(to url: URL) throws {
        let card = NSSize(width: 1200, height: 750)
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: card.width,
                                          height: card.height * CGFloat(IntroGate.script.count)))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor.black.cgColor
        for (i, spec) in IntroGate.script.enumerated() {
            let tileY = canvas.frame.height - card.height * CGFloat(i + 1)
            // Popups render at their real on-screen size, centered in the tile, so
            // the montage shows how big they actually are.
            let size = spec.style == .popup ? IntroGate.popupSize : card
            let view = makeIntroCardView(spec, size: size)
            view.frame.origin = NSPoint(x: (card.width - size.width) / 2,
                                        y: tileY + (card.height - size.height) / 2)
            canvas.addSubview(view)
        }
        try writePNG(canvas: canvas, to: url)
    }

    /// Preview the Phase 6 scenes: two livecode REPL windows and the letter editor
    /// mid-sentence. `--snapshot-scenes=out.png`.
    ///
    /// Caveat: the REPL's motion is Core Animation, and a layer renders its MODEL
    /// value off-screen — so the piano roll and the numerals all show at once here,
    /// where live they blink through in sequence.
    static func renderScenes(to url: URL) throws {
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor(hex: "#101014")?.cgColor

        let small = ContentSpec(kind: "livecode", hex: "#68BDF8",
                                text: "osc(40, 0.1, 0.8)\n  .kaleid(5)\n  .out()",
                                chrome: "browser", title: "hydra.ojack.xyz")
        let a = makeEffectContentView(small, size: NSSize(width: 300, height: 190))
        a.frame = NSRect(x: 30, y: 680, width: 300, height: 190)

        let big = ContentSpec(kind: "livecode", hex: "#68BDF8",
                              text: "voronoi(14, 0.3)\n  .diff(osc(30, 0.2))\n  .kaleid(7)\n  .rotate(0.2, 0.1)\n  .out()",
                              chrome: "browser", title: "hydra — sketch 02")
        let b = makeEffectContentView(big, size: NSSize(width: 620, height: 380))
        b.frame = NSRect(x: 380, y: 490, width: 620, height: 380)

        let editor = TextEditorView(size: NSSize(width: 700, height: 440),
                                    title: "resignation.txt — Edited", fontSize: 14)
        editor.frame = NSRect(x: 40, y: 20, width: 700, height: 440)
        editor.render("""
                      Dear Dean Atwill and Marcela

                      I'm writing to formally confirm the change I've discussed with \
                      Marcela: this spring will be my last semester at NYU Shangh
                      """, caret: true)

        [a, b, editor].forEach { canvas.addSubview($0) }
        try writePNG(canvas: canvas, to: url)
    }

    static func render(to url: URL) throws {
        let canvasSize = NSSize(width: 1120, height: 620)
        let canvas = NSView(frame: NSRect(origin: .zero, size: canvasSize))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor(hex: "#101014")?.cgColor

        // color window with fake browser chrome
        let color = makeEffectContentView(ContentSpec(kind: "color", hex: "#020AF5", chrome: "browser", title: "horse://gallop"),
                                          size: NSSize(width: 360, height: 260))
        color.frame = NSRect(x: 40, y: 320, width: 360, height: 260)

        // text window
        let text = makeEffectContentView(ContentSpec(kind: "text", text: "HELLO"),
                                         size: NSSize(width: 440, height: 200))
        text.frame = NSRect(x: 440, y: 360, width: 440, height: 200)

        // teal color window with terminal chrome
        let teal = makeEffectContentView(ContentSpec(kind: "color", hex: "#68BDF8", chrome: "terminal", title: "haunt.sh"),
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

    /// ASCII-renderer demo: literal art + image→ASCII (colorized and monochrome), for
    /// `--snapshot=out.png` with `DPE_ASCII_DEMO=1`. Renders synchronously so the PNG
    /// captures the converted art (the live path is async).
    static func renderAsciiDemo(to url: URL) throws {
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: 1180, height: 520))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor(hex: "#101014")?.cgColor

        func panel(_ frame: NSRect) -> NSTextView {
            let p = NSView(frame: frame)
            p.wantsLayer = true
            p.layer?.backgroundColor = NSColor(hex: "#060A14")?.cgColor
            p.layer?.cornerRadius = 6
            let tv = makeAsciiTextView(frame: NSRect(x: 8, y: 8, width: frame.width - 16, height: frame.height - 16))
            p.addSubview(tv)
            canvas.addSubview(p)
            canvas.window?.layoutIfNeeded()
            tv.layoutManager?.ensureLayout(for: tv.textContainer!)
            return tv
        }

        let cat = " /\\_/\\\n( o.o )\n > ^ <\n ASCII"
        renderAscii(asciiArtFromText(cat), into: panel(NSRect(x: 20, y: 20, width: 320, height: 480)),
                    fg: NSColor(hex: "#8CF2A6") ?? .green)

        let horse = resolveResourcePath("assets/muybridge_horse.gif")
        if let a = asciiArtFromImage(path: horse, cols: 92, invert: false, colorized: true, ramp: dpeAsciiRamp) {
            renderAscii(a, into: panel(NSRect(x: 360, y: 20, width: 400, height: 480)), fg: .white)
        }
        if let a = asciiArtFromImage(path: horse, cols: 92, invert: true, colorized: false, ramp: dpeAsciiRamp) {
            renderAscii(a, into: panel(NSRect(x: 780, y: 20, width: 400, height: 480)),
                        fg: NSColor(hex: "#68BDF8") ?? .cyan)
        }
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
