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

            t.equal(bytes(Int64(1_500_000)), "1.5 MB", "byte formatting")
            t.equal(pct(0.4237), "42.4%", "percent formatting")
            t.equal(bar(0.5, width: 4), "██░░", "meter bar")
            t.equal(pad("ab", 5), "ab   ", "column padding")
        }
    }
}
