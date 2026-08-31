import AppKit

/// A window packed to bursting with macOS interface.
///
/// Real AppKit controls and the system's own icons, not drawings of them — the same
/// standard the terminal and the alerts hold themselves to. A window of these is what
/// the eruption is *about*: the machine's own vocabulary, too much of it, on top of
/// itself.
///
/// **Deliberately overlapping.** Elements are placed at random over the whole area with
/// no collision test, so they pile up and occlude each other. A tidy grid of controls
/// reads as a preferences pane; a heap of them reads as a machine coming apart.
///
/// Seeded, so a given window packs the same way every take.
final class UIChaosView: NSView {
    /// The system's own icons. Names, not files: these are whatever the running macOS
    /// draws for them, so they match every other icon on the viewer's screen.
    private static let iconNames: [NSImage.Name] = [
        NSImage.computerName, NSImage.folderName, NSImage.trashFullName,
        NSImage.cautionName, NSImage.applicationIconName, NSImage.userName,
        NSImage.networkName, NSImage.infoName, NSImage.advancedName,
        NSImage.bonjourName, NSImage.colorPanelName, NSImage.fontPanelName,
        NSImage.everyoneName, NSImage.multipleDocumentsName, NSImage.userGroupName,
    ]

    private static let labels = [
        "Untitled", "Macintosh HD", "Applications", "Downloads", "Are you sure?",
        "Continue", "Don't Save", "Allow", "Deny", "Preferences", "Show All",
        "Move to Trash", "Empty Trash…", "Restart", "Shut Down", "give it 2 me",
    ]

    /// Everything is drawn from one seeded stream. It lives in a box rather than being
    /// passed `inout` alongside the closures that read it: nested functions capturing a
    /// local `var` while that same var is also passed `&`-wise is overlapping exclusive
    /// access, and Swift traps on it at runtime ("fatal access conflict").
    private final class Stream {
        var rng: SplitMix64
        init(seed: Int) { rng = SplitMix64(seed: UInt64(bitPattern: Int64(seed == 0 ? 1 : seed))) }
        func int(_ n: Int) -> Int { n <= 0 ? 0 : Int(rng.next() % UInt64(n)) }
        func f(_ lo: Double, _ hi: Double) -> CGFloat {
            CGFloat(lo + (hi - lo) * Double(rng.next() % 10_000) / 10_000.0)
        }
    }

    init(size: NSSize, seed: Int, density: Double) {
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let s = Stream(seed: seed)
        // Scaled to area, so a big window is not sparser than a small one.
        let area = Double(size.width * size.height)
        let count = max(10, min(70, Int(area / 2600.0 * max(0.2, density))))

        for _ in 0..<count {
            guard let v = makeElement(s) else { continue }
            // Placed over the whole area INCLUDING the margins, so elements run off the
            // edges and the packing reads as continuing past the window.
            v.setFrameOrigin(NSPoint(x: s.f(-24, Double(size.width) - 12),
                                     y: s.f(-16, Double(size.height) - 12)))
            addSubview(v)
        }
    }

    private func makeElement(_ s: Stream) -> NSView? {
        switch s.int(10) {
        case 0, 1, 2:
            // Icons, at the sizes the Finder actually uses.
            let iv = NSImageView(frame: .zero)
            iv.image = NSImage(named: UIChaosView.iconNames[s.int(UIChaosView.iconNames.count)])
            let side = s.f(24, 72)
            iv.frame.size = NSSize(width: side, height: side)
            iv.imageScaling = .scaleProportionallyUpOrDown
            return iv
        case 3, 4:
            let b = NSButton(title: UIChaosView.labels[s.int(UIChaosView.labels.count)],
                             target: nil, action: nil)
            b.bezelStyle = .rounded
            b.sizeToFit()
            return b
        case 5:
            let c = NSButton(checkboxWithTitle: UIChaosView.labels[s.int(UIChaosView.labels.count)],
                             target: nil, action: nil)
            c.state = s.int(2) == 0 ? .on : .off
            c.sizeToFit()
            return c
        case 6:
            let sl = NSSlider(frame: NSRect(x: 0, y: 0, width: s.f(80, 180), height: 20))
            sl.doubleValue = Double(s.f(0, 100))
            return sl
        case 7:
            let p = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: s.f(70, 170), height: 16))
            p.style = .bar
            p.isIndeterminate = false
            p.doubleValue = Double(s.f(5, 95))
            return p
        case 8:
            let seg = NSSegmentedControl(labels: ["All", "Some", "None"],
                                         trackingMode: .selectOne, target: nil, action: nil)
            seg.selectedSegment = s.int(3)
            seg.sizeToFit()
            return seg
        default:
            let t = NSTextField(labelWithString: UIChaosView.labels[s.int(UIChaosView.labels.count)])
            t.font = .systemFont(ofSize: s.f(10, 15))
            t.sizeToFit()
            return t
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// The window owns the mouse. These are REAL controls — a live NSButton would take
    /// the click and press itself, and the viewer would be clicking a checkbox instead
    /// of dragging the window. Scenery, like every other effect view.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
