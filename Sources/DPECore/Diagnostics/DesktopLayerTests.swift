import AppKit

/// The desktop layer and the `surface` switch in front of it.
///
/// The thing worth pinning is not that a window can be opened — it is *where* it opens.
/// A layer that lands above the desktop icons buries the viewer's desktop; one that lands
/// below the wallpaper is invisible. Both are silent failures on someone else's Mac, and
/// the level constants have moved between macOS releases, so the ordering is asserted
/// against the window server's own list rather than assumed.
enum DesktopLayerTests {
    static func run(_ t: TestHarness) {
        t.suite("DesktopLayer") { t in
            guard let screen = NSScreen.main else {
                return t.expect(false, "no screen to test against")
            }

            // --- the surface switch ---

            t.equal(WallpaperController.Surface(nil), .layer, "surface defaults to the layer")
            t.equal(WallpaperController.Surface("layer"), .layer, #""layer" reads"#)
            t.equal(WallpaperController.Surface("wallpaper"), .wallpaper, #""wallpaper" reads"#)
            // Anything unrecognised falls to the safe surface, never to the one that
            // changes the machine.
            t.equal(WallpaperController.Surface("nonsense"), .layer,
                    "an unknown surface falls back to the layer, not the real wallpaper")

            // --- placement ---

            let layer = DesktopLayer()
            layer.open(on: [screen])
            defer { layer.close() }
            guard let window = layer.window(for: screen) else {
                return t.expect(false, "the layer opened no window")
            }

            t.equal(window.frame, screen.frame, "the layer covers the whole screen")
            t.expect(window.ignoresMouseEvents, "the desktop underneath stays clickable")
            t.expect(window.collectionBehavior.contains(.canJoinAllSpaces),
                     "the layer is on every Space — the blind spot the real swap has")
            t.expect(!window.canBecomeKey, "the layer never takes focus")

            let desktop = Int(CGWindowLevelForKey(.desktopWindow))
            let icons = Int(CGWindowLevelForKey(.desktopIconWindow))
            t.equal(window.level.rawValue, desktop, "the layer sits at the desktop level")
            t.expect(window.level.rawValue < icons,
                     "the layer is under the desktop icons (\(window.level.rawValue) < \(icons))")
            t.expect(window.level.rawValue < Int(CGWindowLevelForKey(.normalWindow)),
                     "the layer is under every app window, including the show's own")

            // `aboveIcons` has to actually clear the icons, or the mode is a no-op.
            let buried = DesktopLayer()
            buried.open(on: [screen], depth: .aboveIcons)
            if let w = buried.window(for: screen) {
                t.expect(w.level.rawValue > icons, "aboveIcons clears the desktop icons")
                t.expect(w.level.rawValue < Int(CGWindowLevelForKey(.normalWindow)),
                         "aboveIcons still sits under every app window")
            } else { t.expect(false, "the aboveIcons layer opened no window") }
            buried.close()

            // --- against the window server's real z-order ---

            // A window is not in the server's list the instant it is ordered in — the
            // placement happens on a runloop turn. Give it a few, or this asserts against
            // a list that simply has not heard about us yet.
            func onScreen() -> [[String: Any]] {
                CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                    as? [[String: Any]] ?? []
            }
            var listed = onScreen()
            let deadline = Date().addingTimeInterval(1.0)
            while Date() < deadline,
                  !listed.contains(where: {
                      ($0[kCGWindowNumber as String] as? Int) == window.windowNumber
                  }) {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                listed = onScreen()
            }

            // The list comes back front-to-back, so a smaller index is nearer the front.
            // Our window must be BEHIND Finder's icon window and IN FRONT OF whatever is
            // drawing the wallpaper.
            do {
                let all = listed
                let ids = all.compactMap { $0[kCGWindowNumber as String] as? Int }
                let mine = ids.firstIndex(of: window.windowNumber)
                t.expect(mine != nil, "the layer is on screen at all")
                let iconWindow = all.firstIndex {
                    ($0[kCGWindowLayer as String] as? Int) == icons
                        && ($0[kCGWindowOwnerName as String] as? String) == "Finder"
                }
                // Not every Mac has desktop icons showing; when none is on screen there
                // is nothing to be behind, and the level assertions above already cover
                // the contract.
                if let mine, let iconWindow {
                    t.expect(iconWindow < mine, "the window server puts the icons in front of the layer")
                }
            }

            // --- idempotence ---

            layer.open(on: [screen])
            t.equal(layer.window(for: screen)?.windowNumber, window.windowNumber,
                    "re-opening resyncs rather than stacking a second window")
            layer.close()
            t.expect(!layer.isOpen, "close leaves nothing open")
            layer.close()
            t.expect(!layer.isOpen, "closing twice is harmless — panic can follow expiry")
        }

        t.suite("deskWallpaper surface routing") { t in
            // The gate covers the real wallpaper and nothing else. A layer run must go
            // ahead with the gate shut — that is the whole reversibility argument — and a
            // `surface: "wallpaper"` run must not.
            let controller = WallpaperController()
            controller.enabled = false

            var p = DeskWallpaperParams(id: "layer-run")
            p.mode = "solid"
            p.hex = "#020AF5"
            controller.beginDesk(p, at: 0, bpm: 128.5)
            t.expect(controller.deskIsRunning, "a layer run starts with the gate shut")
            controller.closeDesk()

            var real = DeskWallpaperParams(id: "real-run")
            real.mode = "solid"
            real.surface = "wallpaper"
            controller.beginDesk(real, at: 0, bpm: 128.5)
            t.expect(!controller.deskIsRunning, "a real-wallpaper run is refused with the gate shut")

            // The photosensitivity cap is on the layer, where nothing else enforces it.
            var fast = DeskWallpaperParams(id: "fast")
            fast.mode = "strobe"
            fast.hz = 60
            controller.beginDesk(fast, at: 0, bpm: 128.5)
            t.equal(controller.deskHz, WallpaperController.layerMaxHz,
                    "hz is clamped to the layer's photosensitivity cap")
            controller.closeDesk()
        }

        t.suite("deskWallpaper scheduled slides on the layer") { t in
            // The claim this pins: on the layer, EVERY word of the lyric cue lands. On
            // the real wallpaper the ~3 Hz wall means a 186 ms gap is a word the window
            // server cannot fit, and the run drops it on purpose. There is no wall here,
            // so a dropped word would be a bug — a decode that did not finish in time,
            // which is exactly what `SlideStore`'s lookahead exists to prevent.
            guard let url = Bundle.module.url(forResource: "timeline", withExtension: "json"),
                  let tl = try? TimelineLoader.load(from: url) else {
                return t.expect(false, "could not load the shipped show")
            }
            let scheduled: DeskWallpaperParams? = tl.events.compactMap {
                if case .deskWallpaper(let p) = $0.action, p.at?.isEmpty == false { return p }
                return nil
            }.first
            guard let words = scheduled, let times = words.at else {
                return t.expect(false, "the shipped show has no scheduled slide run")
            }
            // One time per card, and enough of them to be the lyric rather than a stub.
            // Deliberately not a pinned count: the cards are regrouped whenever the
            // artwork is (49 single words became 31 phrase cards), and this test is about
            // whether they all LAND, not how many there are.
            t.equal(times.count, words.images?.count ?? -1,
                    "every scheduled time has a card (\(times.count))")
            t.expect(times.count > 20, "the lyric cue schedules \(times.count) cards")

            let controller = WallpaperController()
            controller.enabled = false          // layer runs need no gate — that is the point
            controller.baseDir = url.deletingLastPathComponent()
            controller.beginDesk(words, at: 0, bpm: tl.meta.bpm)
            guard controller.deskIsRunning else {
                return t.expect(false, "the scheduled run did not start")
            }

            // Walk the schedule. Each word gets its own slot to land in; a slide still
            // decoding makes `updateDesk` drop the tick and retry, so the loop pumps the
            // runloop rather than assuming the decode is instant. The wall-clock budget
            // per word is far more than the ~12 ms a full-screen card actually costs.
            for (i, at) in times.enumerated() {
                let deadline = Date().addingTimeInterval(2.0)
                while controller.deskFramesShown <= i, Date() < deadline {
                    controller.updateDesk(now: at + 0.001)
                    if controller.deskFramesShown > i { break }
                    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                }
                if controller.deskFramesShown <= i { break }
            }
            t.equal(controller.deskFramesShown, times.count,
                    "every scheduled word landed on the desktop layer")
            controller.closeDesk()
            t.expect(!controller.deskIsRunning, "the run tears down")
        }
    }
}
