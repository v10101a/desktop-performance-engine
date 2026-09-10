import AppKit
import Carbon.HIToolbox
import Foundation

/// What has to be true of a copy handed to someone else.
///
/// Three separate promises, and each one of them is invisible when it breaks — which is
/// why they are pinned here rather than checked by looking at the app:
///
/// - The console does not show itself. A window called "Desktop Performance Engine" with
///   a Play button is the one thing on screen that explains the piece.
/// - The photo wall always has photographs. Refusing Files and Folders used to leave the
///   index empty and cue 22 opened nothing at all.
/// - The .app carries every file the show names. Run from the repo, a bundle missing
///   half its assets looks perfect, because `resolveResourcePath` finds them in the
///   checkout.
enum ProductionTests {
    static func run(_ t: TestHarness) {
        t.suite("production") { t in
            consoleVisibility(t)
            hotKeys(t)
            photoSource(t)
            bundledAssets(t)
        }
    }

    // MARK: - The console stays shut

    private static func consoleVisibility(_ t: TestHarness) {
        t.expect(!AppDelegate.consoleVisibleAtLaunch([]),
                 "a plain launch shows no transport window")
        t.expect(!AppDelegate.consoleVisibleAtLaunch(["dpe", "--autoplay"]),
                 "--autoplay drives itself and shows no transport window")
        t.expect(!AppDelegate.consoleVisibleAtLaunch(["dpe", "show.json"]),
                 "a timeline argument does not open the console either")
        t.expect(AppDelegate.consoleVisibleAtLaunch(["dpe", "--console"]),
                 "--console asks for it")
        // Without this one, skipping the gate leaves a running app with no window and
        // no way to press Play — the dev loop with nothing to drive.
        t.expect(AppDelegate.consoleVisibleAtLaunch(["dpe", "--no-gate"]),
                 "--no-gate is the dev loop, so it keeps the console")
    }

    // MARK: - Two chords, two actions

    private static func hotKeys(_ t: TestHarness) {
        t.expect(HotKeys.panic.key != HotKeys.console.key,
                 "panic and console are different keys")
        t.equal(HotKeys.console.modifiers, UInt32(controlKey | optionKey | cmdKey),
                "the console chord is ⌃⌥⌘")
        t.equal(HotKeys.console.key, kVK_ANSI_D, "…D")
        // Two keys, not four: the viewer at the machine has to be able to hit it in a
        // panic (2026-09-11). ⌥⌘Esc is Force Quit, so neither ⌥ nor ⌃ may creep back in.
        t.equal(HotKeys.panic.modifiers, UInt32(cmdKey), "the panic chord is ⌘ alone")
        t.equal(HotKeys.panic.key, kVK_Escape, "…Esc")

        // The regression this exists for. Carbon delivers every hotkey press to every
        // handler installed on the event target, so two controllers each installing
        // their own handler — which is how the panic key was written before the console
        // key existed — would each fire for BOTH chords, and ⌃⌥⌘D would stop the show.
        // `HotKeyCenter` dispatches on the hotkey id instead; this proves it.
        var fired: [String] = []
        let center = HotKeyCenter.shared
        let before = center.registrationCount
        let a = center.register(key: kVK_ANSI_1, modifiers: UInt32(controlKey | optionKey | cmdKey),
                                signature: OSType(0x54535431)) { fired.append("a") }
        let b = center.register(key: kVK_ANSI_2, modifiers: UInt32(controlKey | optionKey | cmdKey),
                                signature: OSType(0x54535432)) { fired.append("b") }
        if let a, let b {
            t.equal(center.registrationCount, before + 2, "both test chords registered")
            center.fire(id: b.id)
            t.equal(fired, ["b"], "a press runs only the action for that chord")
            center.fire(id: a.id)
            t.equal(fired, ["b", "a"], "…and the other one runs only its own")
            center.unregister(a)
            center.unregister(b)
            t.equal(center.registrationCount, before, "unregistering gives the chords back")
        } else {
            // Registration can legitimately fail if something else owns the chord.
            t.expect(true, "test chords unavailable on this machine — dispatch not exercised")
        }
    }

    // MARK: - The wall always has photographs

    private static func photoSource(_ t: TestHarness) {
        let cfg = PhotoWallConfig(PhotoWallParams(id: "t"))

        // What the fallback is FOR: a source that found nothing has to be topped up, and
        // the bundle is where it stops.
        t.equal(PhotoSource.bundled([]).floor, 0, "the bundled pool has nothing to fall back to")
        t.equal(PhotoSource.user([]).floor, PhotoSource.minUserPhotos,
                "a thin scan of the viewer's folders is topped up from the bundle")
        // A viewer who put six photographs in the folder gets a wall of those six, not
        // six of theirs and fifteen broken laptops.
        t.equal(PhotoSource.curated(URL(fileURLWithPath: "/tmp/x")).floor, 1,
                "a curated folder is replaced only if it is empty, never topped up")

        // "Load ALL of the photos from that folder" — the default floors exist to reject
        // icons and scrub thumbnails in a walk of a whole home folder, and a folder the
        // viewer filled by hand is not that walk.
        let curated = PhotoSource.curated(URL(fileURLWithPath: "/tmp/x")).filters(cfg)
        t.expect(curated.minPixels < cfg.minPixels, "a curated folder relaxes the pixel floor")
        t.expect(curated.minBytes < cfg.minBytes, "…and the byte floor")
        t.expect(!curated.includeCloud,
                 "…but never iCloud-evicted files: the first read blocks for ~20s")
        let user = PhotoSource.user(cfg.roots).filters(cfg)
        t.equal(user.minPixels, cfg.minPixels, "a scan of the viewer's folders keeps the floors")

        // The curated folder is matched case-insensitively. Nobody is told the name has
        // to be lowercase, and a `GiveIt2Me` that silently did nothing would be the worst
        // kind of bug — one where the viewer did everything right.
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dpe-photosource-\(UUID().uuidString)")
        let desktop = home.appendingPathComponent("Desktop")
        try? fm.createDirectory(at: desktop, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        t.expect(PhotoSource.curatedFolder(in: home) == nil,
                 "no giveit2me folder, no curated source")
        let odd = desktop.appendingPathComponent("GiveIt2Me")
        try? fm.createDirectory(at: odd, withIntermediateDirectories: true)
        t.equal(PhotoSource.curatedFolder(in: home)?.lastPathComponent, "GiveIt2Me",
                "a differently-cased giveit2me folder is still found")
        // A FILE by that name is not a folder of photographs.
        try? fm.removeItem(at: odd)
        fm.createFile(atPath: desktop.appendingPathComponent("giveit2me").path, contents: Data())
        t.expect(PhotoSource.curatedFolder(in: home) == nil,
                 "a file called giveit2me is not mistaken for the folder")

        // An unreadable Desktop is the refusal case, and it must not resolve to a
        // curated source built out of a failed read.
        let noDesktop = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dpe-nohome-\(UUID().uuidString)")
        t.expect(PhotoSource.curatedFolder(in: noDesktop) == nil,
                 "an unreadable Desktop yields no curated folder")
    }

    // MARK: - The .app carries the show

    private static func bundledAssets(_ t: TestHarness) {
        guard let url = Bundle.module.url(forResource: "timeline", withExtension: "json"),
              let tl = try? TimelineLoader.load(from: url) else {
            t.expect(false, "bundled timeline.json failed to load")
            return
        }

        // The enumerator is only useful if it actually finds things. These are the counts
        // the shipped cut has; the point is that a kind quietly dropping out of
        // `TimelineAssets.paths` shows up as a number falling, not as a black window on
        // somebody else's machine.
        let paths = TimelineAssets.paths(in: tl)
        t.expect(paths.count > 25, "the show names \(paths.count) files")
        t.expect(paths.contains(tl.meta.audioFile ?? ""), "the backing track is one of them")
        t.expect(paths.contains { $0.hasPrefix("assets/lyrics_desktops/") },
                 "…the lyric wallpapers")
        t.expect(paths.contains { $0.hasPrefix("assets/broken_screens/") },
                 "…the broken screens")
        t.expect(paths.contains { $0.hasPrefix("assets/shaders/") }, "…the shaders")
        t.expect(paths.contains { $0.hasSuffix(".mov") }, "…the segmenter's clip")
        t.expect(paths.contains { $0.contains("credits_tile") }, "…the end card's tile")
        t.expect(paths.contains { $0.contains("torus_dimension") }, "…the torus environment")
        t.expect(Set(paths).count == paths.count, "no path is listed twice")

        // Every one of them exists somewhere this checkout can see. (Whether the .app
        // carries them is `--check`'s question — it can only be asked of a real bundle,
        // and these tests run from the repo, where everything resolves.)
        for name in paths where !FileManager.default.fileExists(atPath: resolveResourcePath(name)) {
            t.expect(false, "the show names \(name), which is not in this checkout")
        }

        // The fallback pool. Not named by any event — the wall resolves it at run time —
        // so nothing else in the suite would notice it going missing.
        let pool = PhotoSource.bundledRoots()
        t.expect(!pool.isEmpty, "the fallback pool resolves to at least one folder")
        var photos: [String] = []
        for root in pool {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            photos += files.filter { $0.lowercased().hasSuffix(".jpg") }
        }
        t.expect(photos.count >= 6,
                 "the fallback pool has \(photos.count) photograph(s) — a refused machine still gets a wall")

        // The one exclusion that is not about the cut: a screenshot of a real person's
        // Instagram DM must not ride along in a build that gets handed around.
        t.expect(!photos.contains { $0.lowercased().hasPrefix("img_0624") },
                 "the DM screenshot is not in the fallback pool")
    }
}
