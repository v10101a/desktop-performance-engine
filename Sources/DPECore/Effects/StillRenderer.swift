import AppKit
import AVFoundation

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
                                             bodyColor: NSColor(hex: colors[i % colors.count]) ?? .magenta)
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
            let size: NSSize
            switch spec.style {
            case .popup:    size = IntroGate.popupSize
            case .macAlert: size = IntroGate.alertSize
            default:        size = card
            }
            let view = makeIntroCardView(spec, size: size)
            // The restart card animates off a timer, and a still has no run loop to turn
            // it. Render the moment that matters: the bar caught at 60%, ground blue.
            (view as? RestartCardView)?.renderStatic(t: RestartCardView.stillMoment, turned: true)
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
        // A still is `cacheDisplay` into a bitmap, which draws layers and skips web
        // views entirely — a real hydra canvas would come out an empty rectangle. The
        // impression draws, so snapshots use it whatever the show is running.
        HydraWeb.enabled = false
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
        editor.showTyped("""
                      Dear Dean Atwill and Marcela

                      I'm writing to formally confirm the change I've discussed with \
                      Marcela: this spring will be my last semester at NYU Shangh
                      """, caret: true)

        [a, b, editor].forEach { canvas.addSubview($0) }
        try writePNG(canvas: canvas, to: url)
    }

    /// The end card, laid out the way the live one is. `--snapshot-credits=out.png`.
    ///
    /// The `credits` event is read from the bundled show so the still and the show can't
    /// drift apart; the booth photo is a stand-in; the copy is fully typed. The real
    /// windows are built in a screen-sized frame parked off-screen at (-6000, -6000) and
    /// composited back to front, so what this shows is the actual layout code's output —
    /// title bars, tilt, tile and all — minus the window-server shadows.
    static func renderCredits(to url: URL) throws {
        let size = NSScreen.main?.frame.size ?? NSSize(width: 1512, height: 982)
        let sf = NSRect(x: -6000, y: -6000, width: size.width, height: size.height)

        var params = CreditsParams(id: "snapshot", lines: ["GiveIt2Me", "by DJ_Dave", "", "Bye"])
        var bpm = 128.0
        if let tlURL = AppDelegate.bundledTimelineURL(), let tl = try? TimelineLoader.load(from: tlURL) {
            bpm = tl.meta.bpm
            for ev in tl.events {
                if case .credits(let p) = ev.action { params = p; break }
            }
        }
        params.outro = false          // the outro quits the process

        let stand = NSImage(size: NSSize(width: 400, height: 300))
        stand.lockFocus()
        NSGradient(starting: NSColor(hex: "#FF2D95")!, ending: NSColor(hex: "#0078D7")!)?
            .draw(in: NSRect(x: 0, y: 0, width: 400, height: 300), angle: 35)
        NSColor(white: 1, alpha: 0.85).setFill()
        NSBezierPath(ovalIn: NSRect(x: 150, y: 90, width: 100, height: 130)).fill()
        stand.unlockFocus()
        let hadPhoto = PhotoBoothStore.shared.image
        PhotoBoothStore.shared.keep(stand)
        defer { if let hadPhoto { PhotoBoothStore.shared.keep(hadPhoto) } else { PhotoBoothStore.shared.discard() } }

        let c = CreditsController()
        c.begin(params, at: 0, bpm: bpm, screenFrame: sf)
        c.finishTypingForSnapshot()
        defer { c.closeAll() }
        // Let the windows lay out and draw once where they are.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let canvas = NSView(frame: NSRect(origin: .zero, size: size))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor.black.cgColor
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        for (win, frame) in c.windowsForSnapshot {
            // Three of the four present with `fadeIn`, which starts at alpha 0 and
            // animates up; land the fade first so the model values are the final ones.
            win.alphaValue = 1
            win.displayIfNeeded()
            // Rendered from the LAYER tree, not `cacheDisplay`: the tiled ground is a
            // layer with a pattern colour and no `draw(_:)`, which `cacheDisplay` skips;
            // `render(in:)` composites every layer, title bar included.
            guard let frameView = win.contentView?.superview, let layer = frameView.layer,
                  let cg = CGContext(data: nil,
                                     width: Int(frameView.bounds.width * scale),
                                     height: Int(frameView.bounds.height * scale),
                                     bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else {
                NSLog("[DPE] snapshot-credits: could not render \(win.title) \(win.frame)")
                continue
            }
            cg.scaleBy(x: scale, y: scale)
            layer.render(in: cg)
            guard let image = cg.makeImage() else { continue }
            // At the LAYOUT's frame, not the window's: off-screen, AppKit drags a titled
            // window back to the nearest screen edge, so its own `frame` is not the one
            // the card would have on a real screen.
            let iv = NSImageView(frame: NSRect(x: frame.minX - sf.minX, y: frame.minY - sf.minY,
                                               width: frameView.bounds.width, height: frameView.bounds.height))
            iv.imageScaling = .scaleAxesIndependently
            iv.image = NSImage(cgImage: image, size: frameView.bounds.size)
            canvas.addSubview(iv)
        }
        try writePNG(canvas: canvas, to: url)
    }

    /// Preview the restructured show's new surfaces, none of which needs a camera, a
    /// location fix or a running clock to draw: a lyric card at screen aspect, one of
    /// the clock windows, the boot screen mid-bar, Photo Booth on "2" with no camera,
    /// the oracle asking and answering, and the end card's photo frame, vitals terminal and
    /// credits terminal. `--snapshot-acts=out.png`.
    static func renderActs(to url: URL) throws {
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: 1900, height: 2070))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor(hex: "#1A1A20")?.cgColor

        func put(_ v: NSView, _ x: CGFloat, _ y: CGFloat) {
            v.frame.origin = NSPoint(x: x, y: y)
            canvas.addSubview(v)
        }

        // Row 1: lyric cards — the fullscreen frame at 16:10, and one clock window.
        let card = makeEffectContentView(
            ContentSpec(kind: "lyric", hex: "#0078D7", text: "i can’t get enough", fg: "#F2F4FE"),
            size: NSSize(width: 640, height: 400))
        put(card, 20, 760)
        let card2 = makeEffectContentView(
            ContentSpec(kind: "lyric", hex: "#F2F4FE", text: "so give it to me", fg: "#0078D7"),
            size: NSSize(width: 230, height: 108))
        put(card2, 1150, 640)
        let boot = BootView(size: NSSize(width: 640, height: 400), glyph: "\u{F8FF}", color: .white)
        boot.showsBar = true
        boot.progress = 0.62
        put(boot, 740, 760)

        // Row 2: Photo Booth (no camera), the oracle asking, the oracle answering.
        let booth = BoothView(size: NSSize(width: 520, height: 400), session: AVCaptureSession(), mirror: true)
        booth.setCameraAvailable(false)
        booth.show(number: 2)
        put(booth, 20, 340)
        let (ask, _) = OracleController.makeAskView(
            size: NSSize(width: 460, height: 186), title: "hey, i'm the magic torus",
            body: "ask me a question", placeholder: "will you give it 2 me?", icon: .app,
            target: nil, action: nil)
        put(ask, 580, 520)
        let answer = OracleController.makeAnswerView(
            size: NSSize(width: 460, height: 186), question: "will you give it 2 me?",
            answer: OracleController.answer(to: "will you give it 2 me?", from: [], fallback: 0),
            icon: .app)
        put(answer, 580, 340 - 30)

        // Row 3: the end card's pieces, with a stand-in photo.
        let stand = NSImage(size: NSSize(width: 400, height: 300))
        stand.lockFocus()
        NSGradient(starting: NSColor(hex: "#FF2D95")!, ending: NSColor(hex: "#0078D7")!)?
            .draw(in: NSRect(x: 0, y: 0, width: 400, height: 300), angle: 35)
        NSColor(white: 1, alpha: 0.85).setFill()
        NSBezierPath(ovalIn: NSRect(x: 150, y: 90, width: 100, height: 130)).fill()
        stand.unlockFocus()
        let photo = CreditsController.makePhotoCard(
            size: NSSize(width: 412, height: 415), photo: stand,
            photoRect: NSRect(x: 16, y: 100, width: 380, height: 285),
            caption: CreditsController.defaultCaption(), filter: "instant", showsSave: true)
        put(photo, 20, 24)
        let info = makeEffectContentView(
            ContentSpec(kind: "code", text: CreditsController.machineSummary(), chrome: "terminal",
                        title: "system_probe — summary"),
            size: NSSize(width: 470, height: 230))
        put(info, 460, 90)
        // Row 4 (top): the credits terminal, caught mid-type — the surface that replaced
        // the credits dialog. Cut off partway through the copy, the way the viewer first
        // sees it, caret and all.
        let creditsCopy = [
            "GiveIt2Me", "by DJ_Dave", "produced by ninajirachi", "2026", "",
            "Malware and mu\u{2588}",
        ].joined(separator: "\n")
        let roll = makeEffectContentView(
            ContentSpec(kind: "code", text: creditsCopy, chrome: "terminal", title: "credits"),
            size: NSSize(width: 660, height: 250))
        put(roll, 20, 1190)

        // The outro's two surfaces: the alert that ends the piece, and the boot bar it
        // finishes on. (The glitch between them is rendered from a live screen capture,
        // so it has no still to preview.)
        let quit = makeDialogContentView(
            title: "\u{201C}GiveIt2Me_DJ_Dave_malware\u{201D} is not responding.",
            message: "The application is not responding. Do you want to force quit?",
            buttons: ["Wait", "Force Quit"], icon: .caution,
            size: NSSize(width: 560, height: 172))
        put(quit, 720, 1190)
        let outroBoot = BootView(size: NSSize(width: 380, height: 238), glyph: "\u{F8FF}", color: .white)
        outroBoot.showsBar = true
        outroBoot.progress = 0.88
        put(outroBoot, 1320, 1190)

        // The end card's backdrop: the tile at its authored padding, laid out the way the
        // live card lays it out, so the spacing is checkable without running the show.
        let tileBack = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 580))
        tileBack.wantsLayer = true
        tileBack.layer?.backgroundColor = NSColor.white.cgColor
        CreditsController.addDriftingTile("assets/credits_tile.png", to: tileBack,
                                          secondsPerTile: 4, padding: 1.0, scale: 0.05)
        put(tileBack, 1110, 1470)

        // Row 5 (top): two frames of the memory dump, run over the end card's own tile so
        // the pixelation and the 1-bit palette are visible. Nearest-neighbour on the way
        // up, exactly as the live sequence draws it.
        // Decoded from the file's bytes rather than through `NSImage`, which can hand back
        // a shared, file-backed representation.
        let tileData = (try? Data(contentsOf: URL(fileURLWithPath:
            resolveResourcePath("assets/credits_tile.png")))) ?? Data()
        let tileCG = NSBitmapImageRep(data: tileData)?.cgImage
        let dump = OutroController.previewFrames(from: tileCG, size: NSSize(width: 520, height: 325))
        for (i, frame) in dump.prefix(2).enumerated() {
            let v = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 325))
            v.wantsLayer = true
            v.layer?.magnificationFilter = .nearest
            v.layer?.contentsGravity = .resize
            v.layer?.contents = frame
            put(v, 20 + CGFloat(i) * 545, 1470)
        }


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
            let m = makeMicroContentView(size: NSSize(width: 30, height: 22), bodyColor: body)
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
    /// Montage of real, titled effect windows — the actual macOS chrome, captured from
    /// each window's frame view rather than a drawing of one. `--snapshot-chrome=out.png`.
    ///
    /// The frame view (`contentView.superview`) is the view AppKit draws the title bar
    /// and traffic lights into, so caching its display gives a genuine screenshot with
    /// no Screen Recording permission involved. Each window is parked far offscreen and
    /// ordered to the back, so nothing appears on the display.
    static func renderChrome(to url: URL) throws {
        let specs: [(ContentSpec, String)] = [
            (ContentSpec(kind: "color", hex: "#020AF5", chrome: "mac", title: "Untitled"), "mac"),
            (ContentSpec(kind: "text", text: "you looked", chrome: "browser",
                         title: "look://found"), "browser"),
            (ContentSpec(kind: "code",
                         text: "const want = \"what I want\";\nwhile (need(love)) {\n  giveItToMe();\n}",
                         chrome: "terminal"), "terminal"),
        ]
        let size = NSSize(width: 420, height: 260)
        let pad: CGFloat = 24
        var shots: [NSImage] = []

        // NOTE: the traffic lights draw in the INACTIVE style here, and in the show —
        // AppKit colours them only for a key/main window, and these windows deliberately
        // never become key. Not a defect of this snapshot (verified: makeKey() changes nothing).

        for (spec, _) in specs {
            let win = EffectWindow(contentRect: NSRect(origin: .zero, size: size), content: spec)
            win.level = .normal
            win.setFrameOrigin(NSPoint(x: -6000, y: -6000))
            win.orderBack(nil)
            win.displayIfNeeded()
            guard let frameView = win.contentView?.superview,
                  let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)
            else { win.close(); continue }
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            let image = NSImage(size: frameView.bounds.size)
            image.addRepresentation(rep)
            shots.append(image)
            win.orderOut(nil)
            win.close()
        }
        // The typeText letter goes through HostedEffectWindow, a different path — include
        // it so a regression there shows up here too.
        do {
            let native = usesNativeChrome("mac", size: size)
            let editor = TextEditorView(
                size: BaseEffectWindow.contentSize(forFrame: NSRect(origin: .zero, size: size),
                                                   native: native),
                title: "resignation.txt — Edited", fontSize: 13)
            editor.showTyped("Dear Dean Atwill and Marcela\n\nI'm writing to formally confirm", caret: true)
            let win = HostedEffectWindow(contentRect: NSRect(origin: .zero, size: size),
                                         view: editor, title: "resignation.txt — Edited")
            win.level = .normal
            win.setFrameOrigin(NSPoint(x: -6000, y: -6000))
            win.orderBack(nil)
            win.displayIfNeeded()
            if let frameView = win.contentView?.superview,
               let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                frameView.cacheDisplay(in: frameView.bounds, to: rep)
                let image = NSImage(size: frameView.bounds.size)
                image.addRepresentation(rep)
                shots.append(image)
            }
            win.orderOut(nil)
            win.close()
        }
        // The welcome card (cue 3): the same typewriter writing into Terminal's own
        // window instead, by the line, with the credits' block cursor. Copy, size and
        // face come from the SHIPPED timeline rather than from a sample here — the
        // whole question this shot answers is whether the authored frame holds the
        // authored copy without wrapping, which a stand-in cannot tell you.
        if let url = Bundle.module.url(forResource: "timeline", withExtension: "json"),
           let tl = try? TimelineLoader.load(from: url),
           let p = tl.events.compactMap({ ev -> TypeTextParams? in
               guard case .typeText(let p) = ev.action, p.chrome == "terminal" else { return nil }
               return p
           }).first, p.frame.count == 4 {
            let welcomeSize = NSSize(width: p.frame[2], height: p.frame[3])
            let win = EffectWindow(contentRect: NSRect(origin: .zero, size: welcomeSize),
                                   content: ContentSpec(kind: "code", text: "", chrome: "terminal"))
            if let label = firstTextField(in: win.contentView) {
                label.font = .monospacedSystemFont(ofSize: CGFloat(p.fontSize ?? 11), weight: .regular)
                TerminalTextSink(label: label).showTyped(p.text, caret: true)
            }
            win.level = .normal
            win.setFrameOrigin(NSPoint(x: -6000, y: -6000))
            win.orderBack(nil)
            win.displayIfNeeded()
            if let frameView = win.contentView?.superview,
               let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                frameView.cacheDisplay(in: frameView.bounds, to: rep)
                let image = NSImage(size: frameView.bounds.size)
                image.addRepresentation(rep)
                shots.append(image)
            }
            win.orderOut(nil)
            win.close()
        }

        // Alerts: every illustration variant, at the real dialog size the show uses.
        // Sample copy matches what the show actually ships: the alert text is the song
        // (docs/LYRICS.md), fed to both generators from tools/lyrics.py.
        for (icon, title, body) in [
            (DialogIcon.critical, "what I want",
             "I told you that i need your love so give it to me"),
            (DialogIcon.caution, "running up",
             "my currents i can\u{2019}t get enough of this feeling baby"),
            (DialogIcon.info, "all i got", "i\u{2019}m giving that so give it up"),
        ] {
            let dialogSize = NSSize(width: 460, height: 190)
            let win = FakeDialogWindow(contentRect: NSRect(origin: .zero, size: dialogSize),
                                       title: title, message: body,
                                       buttons: ["not now", "ok"], icon: icon)
            win.level = .normal
            win.setFrameOrigin(NSPoint(x: -6000, y: -6000))
            win.orderBack(nil)
            win.displayIfNeeded()
            if let frameView = win.contentView?.superview,
               let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                frameView.cacheDisplay(in: frameView.bounds, to: rep)
                let image = NSImage(size: frameView.bounds.size)
                image.addRepresentation(rep)
                shots.append(image)
            }
            win.orderOut(nil)
            win.close()
        }

        // Pooled micro-windows at the sizes the show actually uses: horse sprite cells
        // and cursor-trail breadcrumbs. These are real windows, so this is the only way
        // to see whether a 28pt title bar leaves a usable body at these sizes.
        let microSizes: [(NSSize, String)] = [
            (NSSize(width: 79, height: 57), "horse sprite cell"),
            (NSSize(width: 84, height: 58), "cursor-trail breadcrumb"),
            (NSSize(width: 120, height: 80), "small chaos window"),
        ]
        var microShots: [NSImage] = []
        for (msize, _) in microSizes {
            let win = MicroWindow(size: msize, bodyColor: NSColor(hex: "#020AF5") ?? .blue,
                                  shadow: false)
            win.level = .normal
            win.setFrameOrigin(NSPoint(x: -6000, y: -6000))
            win.orderBack(nil)
            win.displayIfNeeded()
            if let frameView = win.contentView?.superview,
               let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
                frameView.cacheDisplay(in: frameView.bounds, to: rep)
                let image = NSImage(size: frameView.bounds.size)
                image.addRepresentation(rep)
                microShots.append(image)
            }
            win.orderOut(nil)
            win.close()
        }
        // Lay them in one row so their relative sizes are obvious.
        if !microShots.isEmpty {
            let rowW = microShots.reduce(0) { $0 + $1.size.width + 18 } + 18
            let rowH = (microShots.map(\.size.height).max() ?? 60) + 24
            let row = NSView(frame: NSRect(x: 0, y: 0, width: rowW, height: rowH))
            row.wantsLayer = true
            row.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
            var x: CGFloat = 18
            for shot in microShots {
                let iv = NSImageView(frame: NSRect(x: x, y: (rowH - shot.size.height) / 2,
                                                   width: shot.size.width, height: shot.size.height))
                iv.image = shot
                iv.imageScaling = .scaleNone
                row.addSubview(iv)
                x += shot.size.width + 18
            }
            if let rep = row.bitmapImageRepForCachingDisplay(in: row.bounds) {
                row.cacheDisplay(in: row.bounds, to: rep)
                let image = NSImage(size: row.bounds.size)
                image.addRepresentation(rep)
                shots.append(image)
            }
        }

        guard !shots.isEmpty else { throw NSError(domain: "StillRenderer", code: 2) }

        // Shots differ in size (windows vs alerts), so stack by each one's own height.
        let widest = shots.map(\.size.width).max() ?? 400
        let totalH = shots.reduce(0) { $0 + $1.size.height + pad } + pad
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: widest + pad * 2, height: totalH))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor.systemTeal.withAlphaComponent(0.25).cgColor
        var y = canvas.frame.height - pad
        for shot in shots {
            y -= shot.size.height
            let iv = NSImageView(frame: NSRect(x: pad, y: y,
                                               width: shot.size.width, height: shot.size.height))
            iv.image = shot
            iv.imageScaling = .scaleNone
            canvas.addSubview(iv)
            y -= pad
        }
        try writePNG(canvas: canvas, to: url)
    }

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
