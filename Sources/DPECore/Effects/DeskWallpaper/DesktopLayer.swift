import AppKit
import QuartzCore

/// A full-screen window pinned to the **desktop level**: above the picture the window
/// server draws as the wallpaper, below the Finder's desktop icons, below everything the
/// show opens. What it displays reads as the wallpaper, and changing it costs a layer
/// assignment rather than a ~300 ms WallpaperAgent round-trip.
///
/// Why it exists: `NSWorkspace.setDesktopImageURL` blocks for ~270–330 ms per call per
/// screen and the cost barely moves with image size, so it is a hard **~3 Hz wall** on
/// how fast the desktop can change (see `WallpaperController.updateDesk`). Every
/// rate-driven `deskWallpaper` mode — `strobe`, `slides`, `glitch`, `recursive` — is
/// limited by that and nothing else. Drawing the same frames here is limited by the
/// display instead.
///
/// It is also strictly *more* reversible than the real swap. This window dies with the
/// process, so a crash, a panic or a `kill -9` cannot leave the desktop changed: there
/// is no snapshot to restore, no `Index.plist` to put back, no `WallpaperAgent` to
/// bounce, and no per-Space blind spot — `canJoinAllSpaces` means the one window is on
/// every desktop already.
///
/// What it is not: the actual wallpaper. System Settings still shows the viewer's own
/// picture, and a screenshot of the desktop taken by anything that excludes windows sees
/// through it. For a show neither matters; for "the malware really changed your
/// wallpaper, go look", only `WallpaperController.set` does that.
final class DesktopLayer {
    /// Where the window sits in the global z-order.
    ///
    /// `.desktopWindow` is the level the wallpaper itself is drawn at; a window there
    /// lands above the picture and below the Finder's icon window. `.iconOverlay` puts
    /// it above the icons too, for a mode that is meant to bury the desktop whole.
    /// Both are resolved from `CGWindowLevelForKey`, never hardcoded — the numbers have
    /// moved between releases.
    enum Depth {
        /// Above the wallpaper, under the desktop icons. The default: the viewer's icons
        /// stay on top of it, exactly as they sit on a real wallpaper.
        case belowIcons
        /// Above the desktop icons, still under every app window.
        case aboveIcons

        var level: NSWindow.Level {
            switch self {
            case .belowIcons: return NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            case .aboveIcons: return NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            }
        }
    }

    private var windows: [(screen: NSScreen, window: NSWindow)] = []

    var isOpen: Bool { !windows.isEmpty }

    /// The window this layer put on `screen`, for the ordering probe and for tests.
    func window(for screen: NSScreen) -> NSWindow? {
        windows.first { $0.screen == screen }?.window
    }

    // MARK: - Lifecycle

    /// One window per screen, each covering that screen's whole frame — menu bar and
    /// Dock included, because the wallpaper runs under both.
    ///
    /// Idempotent: opening an already-open layer re-syncs the frames to the current
    /// screen arrangement rather than stacking a second set of windows.
    func open(on screens: [NSScreen] = NSScreen.screens, depth: Depth = .belowIcons) {
        if isOpen {
            resync(to: screens, depth: depth)
            return
        }
        windows = screens.map { screen in
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.level = depth.level
            // On every Space, and NOT carried between them by Mission Control — the one
            // window covers all the desktops that `setDesktopImageURL` could never reach.
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle,
                                         .fullScreenNone]
            // The desktop underneath must stay clickable: icons, drag-select, the
            // Finder's own context menu.
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.isOpaque = true
            window.backgroundColor = .black
            window.isReleasedWhenClosed = false
            // A borderless window is not in the window cycle, but say so anyway — nothing
            // here should ever take focus off the show.
            window.isExcludedFromWindowsMenu = true
            window.contentView = DesktopLayer.makeContentView(for: screen)
            // `orderFrontRegardless` without activating: at desktop level "front" still
            // means behind every app, and ordering front is what makes it visible at all.
            window.orderFrontRegardless()
            return (screen, window)
        }
        NSLog("[DPE] desktop layer open: \(windows.count) screen(s) at level \(depth.level.rawValue)")
    }

    /// Take the layer down. Instant and total — there is nothing to put back.
    func close() {
        guard isOpen else { return }
        for (_, window) in windows { window.orderOut(nil) }
        windows.removeAll()
        NSLog("[DPE] desktop layer closed")
    }

    /// Follow a display arrangement change (resolution, a screen plugged or pulled).
    /// Screens that are still present keep their window and their contents; the set is
    /// otherwise rebuilt.
    func resync(to screens: [NSScreen] = NSScreen.screens, depth: Depth = .belowIcons) {
        guard isOpen else { return }
        for (screen, window) in windows where !screens.contains(screen) {
            window.orderOut(nil)
        }
        windows = screens.map { screen in
            if let existing = windows.first(where: { $0.screen == screen })?.window {
                existing.setFrame(screen.frame, display: false)
                existing.level = depth.level
                existing.contentView?.layer?.contentsScale = screen.backingScaleFactor
                return (screen, existing)
            }
            let fresh = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                                 backing: .buffered, defer: false)
            fresh.level = depth.level
            fresh.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle,
                                        .fullScreenNone]
            fresh.ignoresMouseEvents = true
            fresh.hasShadow = false
            fresh.isOpaque = true
            fresh.backgroundColor = .black
            fresh.isReleasedWhenClosed = false
            fresh.isExcludedFromWindowsMenu = true
            fresh.contentView = DesktopLayer.makeContentView(for: screen)
            fresh.orderFrontRegardless()
            return (screen, fresh)
        }
    }

    // MARK: - Drawing

    /// Put `image` on every screen the layer covers.
    ///
    /// Cheap enough to call from the pump: it hands a CGImage to a CALayer and returns.
    /// No file is written, nothing is encoded, and the window server is not consulted
    /// until the next vsync.
    func show(_ image: CGImage) {
        for (_, window) in windows { DesktopLayer.set(image, on: window) }
    }

    /// Put `image` on one screen — `recursive` needs this, since each display reflects
    /// its own capture.
    func show(_ image: CGImage, on screen: NSScreen) {
        guard let window = window(for: screen) else { return }
        DesktopLayer.set(image, on: window)
    }

    /// Paint a flat colour. `strobe` and `solid` never need a bitmap at all — a layer
    /// background colour is a couple of floats, so the whole
    /// render → encode → write → read → decode round trip those modes pay for a solid
    /// frame disappears.
    func show(color: CGColor) {
        for (_, window) in windows {
            guard let layer = window.contentView?.layer else { continue }
            DesktopLayer.withoutAnimation {
                layer.contents = nil
                layer.backgroundColor = color
            }
        }
    }

    private static func set(_ image: CGImage, on window: NSWindow) {
        guard let layer = window.contentView?.layer else { return }
        withoutAnimation { layer.contents = image }
    }

    /// Every contents change goes through here.
    ///
    /// Load bearing: a `CALayer.contents` assignment on a layer-backed view is an
    /// *implicitly animated* property, so without this each frame cross-fades into the
    /// next over the default 0.25 s. At 3 Hz that reads as a soft dissolve; at 30 Hz the
    /// strobe never reaches either end of its swing and the whole effect turns to grey
    /// mush. Disabling actions is what makes a fast desktop actually look fast.
    private static func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    private static func makeContentView(for screen: NSScreen) -> NSView {
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        guard let layer = view.layer else { return view }
        // The same fill semantics as `WallpaperImage.fillOptions` — wallpapers are
        // stretched to cover, and the strobe frames are 64×64 on purpose.
        layer.contentsGravity = .resizeAspectFill
        layer.contentsScale = screen.backingScaleFactor
        layer.backgroundColor = NSColor.black.cgColor
        layer.magnificationFilter = .linear
        layer.minificationFilter = .trilinear
        // Nothing is drawn outside the screen's own rect, and saying so lets the
        // compositor skip a clip test per frame.
        layer.masksToBounds = true
        return view
    }
}
