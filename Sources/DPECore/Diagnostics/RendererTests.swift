import AppKit
import Metal

/// The GlassTorus render path.
///
/// Worth more than it looks: `TorusScene` compiles its Metal shaders **from a source
/// string at runtime**, so a clean build says nothing about whether they are valid. This
/// compiles them on the real GPU and renders a frame offscreen.
enum RendererTests {
    static func run(_ t: TestHarness) {
        t.suite("GlassTorus") { t in
            guard let device = MTLCreateSystemDefaultDevice() else {
                return t.expect(false, "no Metal device")
            }

            guard let scene = try? TorusScene(device: device) else {
                return t.expect(false, "the torus pipeline failed to compile on \(device.name)")
            }
            t.notNil(scene, "pipeline compiled on \(device.name)")

            // A frame, offscreen. Two properties matter and they pull against each
            // other: the torus must actually be drawn, AND the background must stay
            // transparent — a fully opaque frame means the window renders as a black
            // box over the show rather than floating in front of it.
            let out = NSTemporaryDirectory() + "dpe-torus-selftest.png"
            do {
                try Snapshot.write(to: out, size: 256, elapsed: 2.5, environmentPath: nil,
                                   roughness: 0.04, metal: "chrome", mirror: false,
                                   planeDistance: 2.0)
            } catch {
                return t.expect(false, "offscreen render threw: \(error)")
            }
            defer { try? FileManager.default.removeItem(atPath: out) }

            guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: out) as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                return t.expect(false, "could not read back the rendered PNG")
            }

            let w = img.width, h = img.height
            var px = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))

            var opaque = 0, clear = 0
            for i in stride(from: 3, to: px.count, by: 4) {
                if px[i] > 200 { opaque += 1 } else if px[i] < 8 { clear += 1 }
            }
            let total = w * h
            t.expect(opaque > total / 50, "the torus is drawn (\(opaque * 100 / total)% opaque)")
            t.expect(clear > total / 4,
                     "the background stays transparent (\(clear * 100 / total)% clear)")
        }
    }
}

/// Real vs drawn window chrome.
enum ChromeTests {
    static func run(_ t: TestHarness) {
        t.suite("Chrome") { t in
            let big = NSSize(width: 420, height: 260)
            let micro = NSSize(width: 46, height: 34)

            t.expect(usesNativeChrome("mac", size: big), "a full-size window gets real chrome")
            t.expect(usesNativeChrome("mac", size: micro),
                     "small panels carry real chrome too, down to the degeneracy floor")
            t.expect(!fitsNativeChrome(NSSize(width: 20, height: 12)),
                     "below the floor there would be no content area at all")
            t.expect(!usesNativeChrome("none", size: big), "chrome 'none' stays bare")
            // A window that authors no chrome still gets a title bar: everything except
            // the torus is meant to read as an app window. Only an explicit "none" opts
            // out. 241 windows in the shipped show rely on this.
            t.expect(usesNativeChrome(nil, size: big), "no chrome authored still gets a real bar")

            // A native window must actually be titled, and must still refuse key status —
            // real chrome is not worth breaking the never-interrupt-a-take invariant.
            let spec = ContentSpec(kind: "color", hex: "#020AF5", chrome: "mac", title: "Untitled")
            let win = EffectWindow(contentRect: NSRect(origin: .zero, size: big), content: spec)
            t.expect(win.isNativeChrome, "big window reports native chrome")
            t.expect(win.styleMask.contains(.titled), "native window is .titled")
            t.expect(win.styleMask.contains(.closable), "native window has a close button")
            t.equal(win.title, "Untitled", "the authored title reaches the real title bar")
            t.expect(!win.canBecomeKey, "a native window still never takes focus")
            t.notNil(win.standardWindowButton(.closeButton), "real traffic lights exist")

            // The authored frame is the OUTER frame: adding a title bar must not silently
            // grow the window past what the timeline asked for.
            t.near(win.frame.height, big.height, 1.0, "title bar fits inside the authored frame")
            t.near(win.frame.width, big.width, 1.0, "authored width preserved")

            // REGRESSION: re-opening an id used to re-render the authored spec verbatim,
            // which painted a DRAWN title bar inside a window that already had a real
            // one — a second, fake bar under the genuine article. The show cycles a pool
            // of ids constantly, so this hit nearly every window after its first open.
            let freshSubviews = win.contentView?.subviews.count ?? -1
            win.applyContent(spec, frame: NSRect(origin: .zero, size: big))
            t.equal(win.contentView?.subviews.count ?? -2, freshSubviews,
                    "re-opening an id does not add a second, drawn title bar")
            t.expect(win.isNativeChrome, "re-opening keeps the window native")

            // The content view is sized to the CONTENT rect, not the outer frame, or it
            // renders a title bar's worth too tall and the bottom is clipped.
            t.near(Double(win.contentView?.frame.height ?? 0),
                   Double(win.contentRect(forFrameRect: win.frame).height), 1.0,
                   "content view matches the content rect, not the frame")

            // The typeText letter goes through HostedEffectWindow — a separate path that
            // also used to draw its own "mac" bar.
            let editor = TextEditorView(size: big, title: "resignation.txt", fontSize: 13)
            let letter = HostedEffectWindow(contentRect: NSRect(origin: .zero, size: big),
                                            view: editor, title: "resignation.txt")
            t.expect(letter.isNativeChrome, "the letter window gets real chrome")
            t.equal(letter.title, "resignation.txt", "the letter's title reaches the real bar")
            letter.orderOut(nil); letter.close()

            // Pooled micro-windows — sprite pixels and cursor-trail breadcrumbs — carry
            // real chrome too. AppKit honours the exact outer frame at any size, so the
            // authored cell size is preserved and the 28pt bar comes out of the body;
            // a sprite's grid spacing is therefore unaffected.
            for cell in [NSSize(width: 79, height: 57), NSSize(width: 84, height: 58)] {
                let m = MicroWindow(size: cell, bodyColor: .blue, shadow: false)
                t.expect(m.isNativeChrome, "a \(Int(cell.width))pt sprite cell gets real chrome")
                t.near(Double(m.frame.width), Double(cell.width), 1.0, "cell width preserved")
                t.near(Double(m.frame.height), Double(cell.height), 1.0, "cell height preserved")
                t.expect(m.contentRect(forFrameRect: m.frame).height < cell.height,
                         "the title bar comes out of the body, not out of the grid")
                t.notNil(m.standardWindowButton(.closeButton), "micro window has real traffic lights")
                m.orderOut(nil); m.close()
            }

            // Three traffic lights need roughly 70pt; nothing the show authors is
            // narrower than that, so none of them are clipped.
            t.expect(nativeChromeMinSize.width <= 79 && nativeChromeMinSize.height <= 57,
                     "the smallest shipped sprite cell clears the chrome floor")

            let small = EffectWindow(contentRect: NSRect(origin: .zero, size: micro), content: spec)
            // 46x34 is above the degeneracy floor, so even this wears chrome now.
            t.expect(small.isNativeChrome, "even a 46x34 window carries a real title bar")

            for w in [win, small] { w.orderOut(nil); w.close() }

            // REGRESSION: the livecode view reserved a title-bar's height at the top for
            // a drawn bar. The test was `content.chrome == nil`, and "none" is not nil,
            // so the gap survived the drawn bar's removal — a black band across the top
            // of every hydra window.
            let live = ContentSpec(kind: "livecode", text: "osc(40).out()",
                                   chrome: "browser", title: "hydra", running: true)
            //
            // The sketch renders one of two ways: a real hydra WKWebView added as a
            // SUBVIEW when the library shipped, or the Core Animation impression added
            // as a SUBLAYER when it didn't. Either is fine; what must hold is that
            // whichever one is live fills the full height.
            let liveView = makeLiveCodeContentView(live, size: big)
            let canvasHeight = liveView.subviews.first(where: { $0.frame.height > big.height / 2 })?
                .frame.height
                ?? liveView.layer?.sublayers?.first?.frame.height
                ?? 0
            t.near(Double(canvasHeight), Double(big.height), 1.0,
                   "the hydra sketch fills the window; no reserved bar gap")

            // REGRESSION: micro-windows (sprite pixels, trail breadcrumbs) drew a
            // miniature title bar with traffic-light dots.
            let micro2 = makeMicroContentView(size: NSSize(width: 46, height: 34),
                                              bodyColor: .blue)
            t.equal(micro2.subviews.count, 0, "a sprite pixel draws no chrome at all")

            // REGRESSION: the typeText editor was built at the OUTER frame size and then
            // squeezed into the smaller content area, clipping the bottom of the letter.
            let frame = NSRect(origin: .zero, size: big)
            let contentSize = BaseEffectWindow.contentSize(forFrame: frame, native: true)
            t.expect(contentSize.height < big.height,
                     "a native content rect is shorter than its frame")
            let ed = TextEditorView(size: contentSize, title: "letter", fontSize: 13)
            let letterWin = HostedEffectWindow(contentRect: frame, view: ed, title: "letter")
            t.near(Double(ed.frame.height),
                   Double(letterWin.contentRect(forFrameRect: letterWin.frame).height), 1.0,
                   "the editor is built at the content size, so nothing is clipped")
            letterWin.orderOut(nil); letterWin.close()

            // Alert illustrations. Every variant must produce a NON-BLANK bitmap at the
            // size AppKit lays an alert icon out at: the system images are
            // resolution-independent and render as empty boxes unless flattened.
            for variant in [DialogIcon.caution, .info, .app, .critical] {
                guard let img = variant.image() else {
                    t.expect(false, "icon \(variant.rawValue) produced no image")
                    continue
                }
                t.near(Double(img.size.width), Double(DialogIcon.side), 0.5,
                       "icon \(variant.rawValue) is laid out at 64pt")
                // Non-blank: at least one pixel with meaningful alpha.
                var opaque = 0
                if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                        for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
                            if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { opaque += 1 }
                        }
                    }
                }
                t.expect(opaque > 0, "icon \(variant.rawValue) actually draws something")
            }
            t.expect(DialogIcon.none.image() == nil, "icon 'none' draws nothing")

            // An unrecognised authored value falls back rather than rendering blank.
            t.equal(DialogIcon(rawValue: "nonsense") ?? .caution, .caution,
                    "an unknown icon name falls back to caution")

            // The icon is dropped on a panel too small to carry it, so a dense show of
            // little dialogs doesn't become all icon and no words.
            let roomy = makeDialogContentView(title: "T", message: "m", buttons: ["OK"],
                                              icon: .caution, size: NSSize(width: 440, height: 180))
            let cramped = makeDialogContentView(title: "T", message: "m", buttons: ["OK"],
                                                icon: .caution, size: NSSize(width: 220, height: 110))
            t.expect(roomy.subviews.count > cramped.subviews.count,
                     "a full-size alert carries an icon; a tiny one drops it")

            // Dialog typography follows the system, not hardcoded points.
            t.near(Double(NSFont.systemFontSize), 13.0, 0.01, "system font size is the alert size")
            t.near(Double(NSFont.smallSystemFontSize), 11.0, 0.01, "small system font size")
        }
    }
}

/// Window ownership.
///
/// Every window the show holds strongly and later `close()`s must opt out of AppKit's
/// release-on-close. `isReleasedWhenClosed` defaults to TRUE for a programmatically
/// created NSWindow, so `close()` sends an extra release and leaves the owning
/// reference dangling. That does not crash at the close — it detonates later, inside
/// an unrelated Core Animation transaction, with a backtrace pointing at
/// `objc_autoreleasePoolPop` and nothing at all to do with the real culprit.
///
/// Two of these shipped broken (`TorusWindow`, the probe's report window). Their
/// upstream apps never closed their windows — they just quit — so the bug only became
/// reachable when the ports added teardown.
enum WindowOwnershipTests {
    static func run(_ t: TestHarness) {
        t.suite("WindowOwnership") { t in
            let rect = NSRect(x: 0, y: 0, width: 120, height: 90)

            let torus = TorusWindow(contentRect: rect, styleMask: [.borderless],
                                    backing: .buffered, defer: false)
            t.expect(!torus.isReleasedWhenClosed, "TorusWindow opts out of release-on-close")

            let photo = PhotoWindow(frame: rect, shadows: false, level: .normal)
            t.expect(!photo.isReleasedWhenClosed, "PhotoWindow opts out of release-on-close")

            let report = SystemProbeController.makeReportWindow(frame: rect)
            t.expect(!report.isReleasedWhenClosed, "the probe's window opts out of release-on-close")

            let effect = EffectWindow(contentRect: rect, content: ContentSpec(kind: "color", hex: "#000000"))
            t.expect(!effect.isReleasedWhenClosed, "EffectWindow opts out of release-on-close")

            // And closing one we hold must be survivable — the whole point.
            for w in [torus as NSWindow, photo, report, effect] {
                w.orderOut(nil)
                w.close()
            }
            t.expect(true, "closing a held window did not over-release")

            // A DISSOLVING window is still the manager's to sweep. `closeWindow` with
            // `fadeSeconds` runs the alpha down instead of cutting, and the show's hard
            // rule is that nothing survives a stop, a quit or the panic key — so a fade
            // in flight must not be the one thing left on the viewer's screen.
            let wm = WindowManager()
            let card = OpenWindowParams(id: "fade0",
                                        content: ContentSpec(kind: "color", hex: "#020AF5"),
                                        frame: [0, 0, 80, 60])
            wm.openWindow(card, at: 0)
            wm.close(id: "fade0", fadeSeconds: 4)          // still running below
            t.expect(wm.windows["fade0"] != nil, "a dissolving window is still held")
            wm.closeAll()
            t.equal(wm.windows.count, 0, "closeAll sweeps a dissolve in flight")

            // The mirror of it: an id re-opened mid-dissolve must not be ordered out
            // when the fade it interrupted finally lands.
            wm.openWindow(card, at: 0)
            wm.close(id: "fade0", fadeSeconds: 0.05)
            wm.openWindow(card, at: 1)
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
            t.expect(wm.windows["fade0"] != nil, "a window re-opened mid-dissolve survives its old fade")
            t.near(Double(wm.windows["fade0"]?.alphaValue ?? 0), 1.0, 0.001,
                   "…and is opaque again, not left part-way through the fade")
            wm.closeAll()
        }
    }
}

/// The system_probe report.
///
/// `Probe.start()` is deliberately never called here: it reads the Contacts "me" card
/// and asks Location Services for a fix, and a test suite that fires two TCC prompts is
/// a bad citizen. These are the section builders the report is made of, minus the two
/// that prompt.
enum SystemProbeTests {
    static func run(_ t: TestHarness) {
        t.suite("SystemProbe") { t in
            t.expect(machineSection().count > 0, "machine section gathered")
            t.expect(storageSection().count > 0, "storage section gathered")
            t.expect(performanceSection(Sampler().sample()).count > 0, "performance section gathered")

            // REGRESSION: devicesSection was the one section the tests didn't call, and
            // it trapped mid-show. networkLines() walked getifaddrs and read the MAC out
            // of a *copied* sockaddr_dl — a fixed 12-byte tuple standing in for a
            // variable-length struct — so any interface with a name longer than six
            // characters indexed past the end. `bridge0` is seven and exists on most
            // Macs, so simply calling this on a real machine is the reproduction.
            // displayLines() is @MainActor (it reads NSScreen); the harness runs on main.
            let displays = MainActor.assumeIsolated { displayLines() }
            let devices = devicesSection(displays: displays)
            t.expect(devices.count > 0, "devices section gathered without trapping")
            t.expect(networkLines().count > 0, "network lines gathered without trapping")

            // ...and the address is actually read, not silently truncated to garbage or
            // skipped. A wrong offset would still "not crash".
            let macs = networkLines().map(\.text).filter { $0.contains(":") && $0.count >= 17 }
            let wellFormed = macs.filter { line in
                line.split(separator: " ").contains { field in
                    let parts = field.split(separator: ":")
                    return parts.count == 6 && parts.allSatisfy {
                        $0.count == 2 && $0.allSatisfy(\.isHexDigit)
                    }
                }
            }
            t.expect(!wellFormed.isEmpty,
                     "at least one well-formed MAC was read (\(wellFormed.count) of \(macs.count) candidate lines)")

            // REGRESSION: sections were gathered on the global CONCURRENT queue and
            // appended as each one finished, so the report read in COMPLETION order,
            // not the order `start()` asks for — identity, which the disclosure opens
            // on, could land behind hardware. The real sections all take about the same
            // time, so the race only shows with an unequal pair: a slow builder asked
            // for FIRST must still be read first. No section builder is called here, so
            // nothing touches Contacts or Location Services.
            let probe = MainActor.assumeIsolated { Probe() }
            MainActor.assumeIsolated {
                probe.gather { Thread.sleep(forTimeInterval: 0.2); return [TermLine(text: "FIRST")] }
                probe.gather { [TermLine(text: "SECOND")] }
            }
            let deadline = Date().addingTimeInterval(5)
            var draining = true
            while draining && Date() < deadline {
                for _ in 0..<64 where draining {
                    draining = MainActor.assumeIsolated { probe.revealOne() }
                }
                if draining { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            }
            let texts = MainActor.assumeIsolated { probe.lines.map(\.text) }
            let first = texts.firstIndex(of: "FIRST")
            let second = texts.firstIndex(of: "SECOND")
            t.expect(!draining, "the gathered sections drained")
            t.expect(first != nil && second != nil, "both gathered sections were read")
            if let first, let second {
                t.expect(first < second,
                         "sections read in the order asked for, not the order they finished "
                         + "(first at \(first), second at \(second))")
            }

            // The automaton sizes its OWN grid to the view, which is the whole reason
            // it computes in the engine rather than shipping generated art: the field
            // has to reach every edge of whatever window the fill happens to give it.
            // The first version of these authored a grid and left a dead strip down the
            // right of any window whose aspect didn't match.
            for box in [NSSize(width: 326, height: 233), NSSize(width: 318, height: 194)] {
                let av = MainActor.assumeIsolated {
                    AutomatonView(size: box, rule: 30, seed: 0, fontSize: 9, hz: 12)
                }
                let (cols, rows) = av.gridForTesting
                let font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
                let cellW = ("M" as NSString).size(withAttributes: [.font: font]).width
                // Within one cell of filling: the grid is whole cells, so the remainder
                // is the only slack allowed.
                t.expect(box.width - CGFloat(cols) * cellW < cellW,
                         "automaton fills \(Int(box.width))pt across (\(cols) cols)")
                t.expect(box.height - CGFloat(rows) * 9 < 9,
                         "automaton fills \(Int(box.height))pt down (\(rows) rows)")
                // Buffer starts full, so a window opens mid-computation, and the still
                // renderer (no run loop, so no ticks) still catches a real field.
                t.equal(av.linesForTesting.count, rows, "automaton opens with a full field")
                t.expect(av.linesForTesting.allSatisfy { $0.count == cols },
                         "every automaton row is the full width")
            }
            // Rule 30 from a single live cell can only spread one cell per side per
            // generation. If the neighbourhood indexing were wrong the pattern would
            // still look plausible — but it would leak outside its own light cone.
            let cone = MainActor.assumeIsolated {
                AutomatonView(size: NSSize(width: 400, height: 200), rule: 30, seed: 0,
                              fontSize: 9, hz: 12)
            }
            let (ccols, _) = cone.gridForTesting
            let leaks = cone.linesForTesting.enumerated().filter { (row, line) in
                let live = line.enumerated().filter { $0.element == "\u{2588}" }.map(\.offset)
                return live.contains { abs($0 - ccols / 2) > row }
            }
            t.expect(leaks.isEmpty, "rule 30 stays inside its light cone")

            // The packed-UI windows are built from REAL AppKit controls, which is the
            // point and also the hazard: a live NSButton inside a scenery window would
            // take the click and press itself instead of the window being dragged. The
            // view refuses hits for exactly that reason.
            let chaos = MainActor.assumeIsolated {
                UIChaosView(size: NSSize(width: 360, height: 240), seed: 900, density: 1.15)
            }
            t.expect(chaos.subviews.count > 12,
                     "packed UI window is actually packed (\(chaos.subviews.count) elements)")
            t.expect(MainActor.assumeIsolated { chaos.hitTest(NSPoint(x: 20, y: 20)) } == nil,
                     "packed UI window swallows no clicks")
            // Seeded: the same window packs the same way every take, like everything else.
            let again = MainActor.assumeIsolated {
                UIChaosView(size: NSSize(width: 360, height: 240), seed: 900, density: 1.15)
            }
            t.equal(again.subviews.count, chaos.subviews.count, "packed UI window is seeded")
            t.expect(zip(chaos.subviews, again.subviews).allSatisfy { $0.frame == $1.frame },
                     "packed UI window lays out identically for the same seed")

            // The fireworks. The MOTION is checked by `--test-fileworks`, which runs it
            // for real -- a particle system's first frame is an empty sky, so a unit
            // test of it would assert nothing. What is worth pinning here is the part
            // that is not time-dependent: the cards exist, they are actually drawn, and
            // the view stays scenery.
            let fw = MainActor.assumeIsolated {
                FileworksView(size: NSSize(width: 600, height: 400), seed: 1046,
                              hz: 1.0, intensity: 1.0)
            }
            t.expect(fw.cardCountForTesting > 8,
                     "the fireworks build an icon set (\(fw.cardCountForTesting) cards)")
            t.expect(MainActor.assumeIsolated { fw.hitTest(NSPoint(x: 10, y: 10)) } == nil,
                     "the fireworks swallow no clicks")
            // A card is an icon AND a filename: an empty or blank image would fly around
            // convincingly and show nothing.
            // Built and measured inside one hop: NSImage is not Sendable, so carrying it
            // back across the isolation boundary is a warning today and an error under
            // Swift 6.
            let (cardW, inked) = MainActor.assumeIsolated { () -> (CGFloat, Int) in
                let card = FileworksView.card(type: .pdf, name: "Resume FINAL v3.pdf")
                // Through cgImage, not `representations.first`: a lockFocus-drawn NSImage
                // is backed by a snapshot rep, not an NSBitmapImageRep, so the cast fails
                // and the sampler reads an empty image that was never empty.
                var box = NSRect(origin: .zero, size: card.size)
                guard let cg = card.cgImage(forProposedRect: &box, context: nil, hints: nil)
                else { return (card.size.width, 0) }
                let rep = NSBitmapImageRep(cgImage: cg)
                var n = 0
                for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                    for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                        if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.2 { n += 1 }
                    }
                }
                return (card.size.width, n)
            }
            t.expect(cardW > 40, "a card has a size")
            do {
                t.expect(inked > 40, "a card actually draws something (\(inked) inked samples)")
            }

            // The cursor swarm. The CHASE is checked by `--test-cursors`, which warps the
            // real pointer across the window and looks at where they went; what is
            // pinned here is the geometry, which is the part that was wrong twice.
            let cs = MainActor.assumeIsolated {
                CursorSwarmView(size: NSSize(width: 800, height: 500), seed: 3136, count: 60)
            }
            t.equal(cs.countForTesting, 60, "the swarm is populated")
            let csizes = cs.sizesForTesting
            t.expect((csizes.max() ?? 0) / max(1, csizes.min() ?? 1) > 3,
                     "the pointers are a wide range of sizes "
                     + "(\(Int(csizes.min() ?? 0))-\(Int(csizes.max() ?? 0))pt)")
            t.expect(MainActor.assumeIsolated { cs.hitTest(NSPoint(x: 5, y: 5)) } == nil,
                     "the swarm swallows no clicks")
            // The arrow is drawn in its OWN orientation, so the rotation has to subtract
            // where the art points. Up and to the LEFT for this outline — a straightened
            // arrow would make this pi/2 and stop looking like a cursor.
            let art = CursorSwarmView.artAngle
            t.expect(art > 1.7 && art < 2.4,
                     "the pointer art faces up-left (\(String(format: "%.2f", art)) rad)")
            // It pivots about its point, not its middle: near the top-left of the box.
            let anchor = CursorSwarmView.tipAnchor
            t.expect(anchor.x < 0.35 && anchor.y > 0.85,
                     "the pointer pivots about its tip (\(anchor.x), \(anchor.y))")

            // The SHOAL (cue 28). Four things have to hold, and each of them is a way
            // the flock is known to fail: it has to arrive on a spiral, it has to stay
            // on the screen, it has to keep moving, and it must not pile up on one
            // point — cohesion without separation collapses a flock into a dot.
            let w = 800.0, h = 500.0
            let sch = MainActor.assumeIsolated {
                CursorSwarmView(size: NSSize(width: w, height: h), seed: 4438,
                                count: 54, mode: .school)
            }
            func radii(_ v: CursorSwarmView) -> [Double] {
                v.positionsForTesting.map { hypot($0.0 - w / 2, $0.1 - h / 2) }
            }
            let spawnR = radii(sch)
            // Laid out along the arm, so radius climbs with index: the last is far out,
            // the first is at the middle, and the walk out is monotonic.
            let climbs = zip(spawnR, spawnR.dropFirst()).allSatisfy { $0 <= $1 + 0.001 }
            t.expect(climbs, "the shoal is spawned along a spiral arm, centre outward")
            t.expect((spawnR.max() ?? 0) > 0.35 * h && (spawnR.min() ?? 99) < 1,
                     "the arm reaches from the centre to \(Int(spawnR.max() ?? 0))pt out")

            MainActor.assumeIsolated { sch.stepForTesting(600) }   // ten seconds of it
            let pos = sch.positionsForTesting
            let out = pos.filter { $0.0 < -40 || $0.0 > w + 40 || $0.1 < -40 || $0.1 > h + 40 }
            t.equal(out.count, 0, "ten seconds later the shoal is still on the screen")
            let cruise = sch.speedsForTesting
            t.expect((cruise.min() ?? 0) > 40, "every pointer is still swimming "
                     + "(slowest \(Int(cruise.min() ?? 0))pt/s)")
            t.expect((cruise.max() ?? 0) < 400, "and none of them has run away "
                     + "(fastest \(Int(cruise.max() ?? 0))pt/s)")
            var closest = Double.infinity
            for i in pos.indices {
                for j in pos.indices where j > i {
                    closest = min(closest, hypot(pos[i].0 - pos[j].0, pos[i].1 - pos[j].1))
                }
            }
            t.expect(closest > 3, "the shoal has not collapsed onto one point "
                     + "(closest pair \(Int(closest))pt)")

            // The mandala. Its TURNING is checked by `--test-mandala`; here it is the
            // arrangement and the one safety number.
            let mv = MainActor.assumeIsolated {
                MandalaView(size: NSSize(width: 900, height: 700), seed: 3863,
                            rings: 5, intensity: 1.0)
            }
            t.expect(mv.countForTesting > 40, "the mandala is populated (\(mv.countForTesting))")
            // Rings, not a scatter: a handful of distinct radii, each with many balls on it.
            let radii = Set(mv.radiiForTesting.map { Int($0.rounded()) })
            t.equal(radii.count, 5, "the mandala is rings, not a scatter")
            // Neighbouring rings turn opposite ways — that is what makes it a mandala
            // rather than a wheel.
            let speeds = mv.ringSpeedsForTesting
            t.expect(zip(speeds, speeds.dropFirst()).allSatisfy { $0 * $1 < 0 },
                     "the mandala's rings counter-rotate")
            // It is the SYSTEM's beach ball, sliced out of the cursor file, not a
            // drawing of one -- 15 frames, or 1 if the file has moved and it fell back.
            t.equal(mv.frameCountForTesting, MandalaView.frameTotal,
                    "the mandala uses the real cursor's 15 frames")
            t.expect(FileManager.default.fileExists(atPath: MandalaView.systemCursorPath),
                     "the system beach ball is where we think it is")
            // Photosensitivity: each ball steps at the cursor's own 30 fps, which is
            // what every Mac shows anyway -- but eighty stepping IN UNISON would be one
            // synchronised full-screen change at that rate, through the 15-20 Hz band.
            // Staggered phases are what prevent that.
            let sync = mv.phaseSyncForTesting
            t.expect(sync < 0.25,
                     "the beach balls do not step in unison "
                     + "(\(Int(sync * 100))% share a frame)")
            t.expect(MainActor.assumeIsolated { mv.hitTest(NSPoint(x: 5, y: 5)) } == nil,
                     "the mandala swallows no clicks")

            t.equal(bytes(Int64(1_500_000)), "1.5 MB", "byte formatting")
            t.equal(pct(0.4237), "42.4%", "percent formatting")
            t.equal(bar(0.5, width: 4), "██░░", "meter bar")
            t.equal(pad("ab", 5), "ab   ", "column padding")
        }
    }
}
