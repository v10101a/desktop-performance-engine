//  Imported from ~/segcam (2026-09-10), unchanged except for this header.
//
//  segcam's second display: every detection becomes its own titled macOS window holding
//  the frame it was cut from, positioned where it sat in the picture, so the desktop
//  piles up with everything the source has seen. Panels are recycled rather than closed
//  and recreated — at thirty frames a second of brand-new instances, churning real
//  windows that fast costs far more than re-dressing one that already exists.
//
//  Driven here by `SegSwarmController` instead of segcam's app. Fixes belong upstream
//  first; if this file and ~/segcam's copy drift, the one there is the original.
//
//  This copy used to carry two divergences — the window LEVEL and the green BORDER as
//  properties whose defaults were upstream's hard-coded look, so a cue could say what goes
//  over the pile and take the keyline off sixty windows that read as a debug overlay.
//  Both are upstream's own properties now (`SegmentSwarm.level`, `SegmentSwarm.border`,
//  with `SegmentPanel.defaultLevel` and `.defaultBorder` as the defaults), so the file is
//  the original again and `SegSwarmController` sets them the same way it always did.
//
//  ONE DIVERGENCE AGAIN (2026-09-12), to go upstream when ~/segcam is next to hand: a pool
//  of SPARE panels. `prewarm(count:)` builds panels ahead of time, hidden; `update` takes
//  one before creating one; `clear` hides the pile and keeps it as spares instead of
//  closing it; `SegmentPanel.blank()` drops a spare's picture. Everything else is as
//  imported. The first second of a pile used to be sixty real windows being created on
//  the main thread as the motion appeared, and on a cue that is a visible stall. With it:
//  `clearGradually` (the cue's close takes the pile down a few panels per run-loop pass —
//  sixty `orderOut`s in one call measured as a 200 ms stall) and `clearOver(seconds:)`
//  (the same, paced over a given time, oldest first); `rampSeconds` (the cap grows in
//  over that long — measured not to help the pickup, kept as a dial); and `adopted`, a
//  counter the controller reads for its stats. Tried and dropped, each measured: parking
//  the spares ordered in at zero alpha, borderless panels, no shadow, pre-displaying the
//  title bars — none of them is what a new window costs. Idle windows elsewhere in the
//  app were (240 of them doubled it), and that is fixed in `WindowManager.close`.

import AppKit
import QuartzCore

/// One detected segment, living as its own titled macOS window and showing the single frame
/// it was cut from. Panels are recycled rather than closed and recreated — at 30 frames a
/// second of brand-new instances, churning real windows that fast is far more expensive than
/// re-dressing one that already exists.
final class SegmentPanel: NSPanel {
    private let imageLayer = CALayer()
    private let borderLayer = CALayer()
    private static let green = NSColor(calibratedRed: 0.25, green: 1, blue: 0.4, alpha: 1)

    /// One under the shielding window: above the Dock and the menu bar, because here the
    /// swarm is the screen. A host that layers it among other things sets `SegmentSwarm.level`.
    static let defaultLevel = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) - 1)
    /// The keyline that marks a panel as a detection. Nil takes it off.
    static let defaultBorder: NSColor? = SegmentPanel.green

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 160, height: 120),
                   styleMask: [.titled, .closable, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        // Above the Dock and the menu bar: the canvas is the *whole* screen, not the part
        // system UI leaves over. Still non-activating and click-through, so nothing traps
        // the user behind them.
        isFloatingPanel = true
        level = SegmentPanel.defaultLevel
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 120))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        content.layer?.masksToBounds = true
        contentView = content

        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .linear
        borderLayer.borderWidth = 2
        borderLayer.borderColor = SegmentPanel.green.cgColor
        borderLayer.backgroundColor = NSColor.clear.cgColor
        content.layer?.addSublayer(imageLayer)
        content.layer?.addSublayer(borderLayer)
        setBorder(SegmentPanel.defaultBorder)
    }

    /// Drop the picture: a panel going back into the spare pool holds no frame.
    func blank() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = nil
        CATransaction.commit()
    }


    /// The keyline, or none at all.
    func setBorder(_ color: NSColor?) {
        borderLayer.borderWidth = color == nil ? 0 : 2
        borderLayer.borderColor = color?.cgColor
    }

    /// Become a different blob: new title, new snapshot, new place on screen. `rect` is where
    /// the *video* belongs, so the title bar sits above it and the crop lands exactly where
    /// the segment was in the frame.
    func adopt(title: String, image: CGImage?, contentRect rect: CGRect, mirrored: Bool) {
        self.title = title
        setFrame(frameRect(forContentRect: rect), display: false)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = CGRect(origin: .zero, size: contentView?.bounds.size ?? rect.size)
        imageLayer.frame = bounds
        borderLayer.frame = bounds
        imageLayer.transform = mirrored ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity
        imageLayer.contents = image
        CATransaction.commit()

        orderFrontRegardless()      // the newest blob lands on top of the pile
    }
}

/// Mode 2: the desktop is the camera frame. Every detection, on every frame, becomes its own
/// window holding that frame — so the desktop piles up with everything the camera has seen,
/// oldest recycled away once the pile is full.
final class SegmentSwarm {
    private var panels: [SegmentPanel] = []     // oldest first
    /// Panels built ahead of time and hidden, taken before a new one is created. The
    /// first second of a pile used to be sixty `SegmentPanel()` calls on the main
    /// thread as the motion appeared — real windows, each a round trip to the window
    /// server — and it showed. `prewarm` fills this before the clock runs and `clear`
    /// refills it, so a pile is only ever re-dressing windows that already exist.
    private var spares: [SegmentPanel] = []
    /// Instances already given a window. Segments can be republished across frames (Vision
    /// runs at half rate and its results are reused), and a repeat is the same instance, not
    /// a new one.
    private var spawned: Set<SegmentID> = []

    var mirrored = true
    /// How many windows the collage holds before the oldest is recycled. Lowering it takes
    /// effect at once — the extra windows go now rather than waiting for new segments to
    /// push them out, which on a paused clip would never happen.
    var maxBlobs = 100 {
        didSet {
            if maxBlobs < 1 { maxBlobs = 1 }
            while panels.count > maxBlobs {
                let panel = panels.removeFirst()
                panel.orderOut(nil)
                panel.close()
            }
        }
    }
    /// The pile fills over this many seconds: the cap it may grow to rises from
    /// `rampFloor` to `maxBlobs` across them. 0 is the full cap at once.
    var rampSeconds = 0.0
    private let rampFloor = 6
    private var rampStart: CFTimeInterval?
    /// What the pile sits at. `SegmentPanel.defaultLevel` is above everything.
    var level = SegmentPanel.defaultLevel
    /// The keyline round each panel, or nil for none. Applied as panels are adopted, so a
    /// change shows on the next window rather than repainting the pile.
    var border: NSColor? = SegmentPanel.defaultBorder

    private let minWidth: CGFloat = 120     // a titled window can't be narrower than its bar
    private let minHeight: CGFloat = 28

    var panelCount: Int { panels.count }
    var spareCount: Int { spares.count }
    /// Panels re-dressed since the counter was last zeroed — the churn, which is the cost.
    var adopted = 0
    private var generation = 0

    /// Build panels now, hidden, until `count` exist between the pile and the spares.
    ///
    /// Hidden means ordered OUT. Keeping the spares ordered in at zero alpha was tried
    /// (2026-09-12), so that a spare's first appearance would be a re-order rather than
    /// the server creating the window: it made the act slower — a parked window still
    /// takes part in every re-order of the pile — and the first second no better.
    func prewarm(count: Int) {
        while spares.count + panels.count < count { spares.append(SegmentPanel()) }
    }

    func update(segments: [Segment], crops: [SegmentID: CGImage], screenFrame: CGRect) {
        // The cap this frame: the whole pile, or — on a ramp — the part of it reached.
        // A segment that finds the pile at its cap while the cap is still growing is
        // simply not spawned; nothing is tracked, so the motion mints a new one next
        // frame and the pile catches up as the cap rises.
        var cap = maxBlobs
        if rampSeconds > 0 {
            let now = CACurrentMediaTime()
            let start = rampStart ?? now
            rampStart = start
            let u = min(1.0, (now - start) / rampSeconds)
            cap = min(maxBlobs, max(rampFloor, Int(Double(maxBlobs) * u)))
        }
        for segment in segments where !spawned.contains(segment.id) {
            if panels.count >= cap && cap < maxBlobs { continue }
            spawned.insert(segment.id)
            if spawned.count > 8192 { spawned = [segment.id] }

            var rect = FrameMap.spread(segment.rect, across: screenFrame, mirrored: mirrored)
            if rect.width < minWidth {
                rect.origin.x -= (minWidth - rect.width) / 2
                rect.size.width = minWidth
            }
            if rect.height < minHeight {
                rect.origin.y -= (minHeight - rect.height) / 2
                rect.size.height = minHeight
            }

            let panel = panels.count >= cap ? panels.removeFirst()
                      : (spares.popLast() ?? SegmentPanel())
            panel.level = level
            panel.setBorder(border)
            panel.adopt(title: segment.label, image: crops[segment.id],
                        contentRect: rect, mirrored: mirrored)
            panels.append(panel)
            adopted += 1
        }
    }

    /// Take the pile down `perPass` panels per run-loop pass, oldest first, instead of
    /// all of them in one call: sixty `orderOut`s back to back measured as a 200 ms stall
    /// on the main thread, and a cue's close is not a panic. A `clear()` (or a new pile)
    /// in the meantime ends the run; the generation guards a stale pass.
    func clearGradually(perPass: Int = 4) {
        spawned.removeAll()
        generation += 1
        let mine = generation
        func pass() {
            guard mine == generation, !panels.isEmpty else { return }
            retire(panels.prefix(perPass).count)
            DispatchQueue.main.async(execute: pass)
        }
        pass()
    }

    /// Take the pile down over `seconds`, oldest panel first, at the display's pace: the
    /// act LEAVING rather than being switched off — and never more than a few panels on
    /// any one frame. Ends early, harmlessly, if a `clear()` or a new pile comes first.
    func clearOver(seconds: Double) {
        guard seconds > 0, !panels.isEmpty else { clearGradually(); return }
        spawned.removeAll()
        generation += 1
        let mine = generation
        rampStart = nil
        let total = panels.count
        let t0 = CACurrentMediaTime()
        var gone = 0
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self, mine == self.generation, !self.panels.isEmpty else { t.invalidate(); return }
            let due = min(total, Int(Double(total) * (CACurrentMediaTime() - t0) / seconds))
            if due > gone {
                self.retire(due - gone)
                gone = due
            }
            if self.panels.isEmpty { t.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func retire(_ n: Int) {
        let batch = panels.prefix(n)
        for panel in batch {
            panel.orderOut(nil)
            panel.blank()
        }
        spares += batch
        panels.removeFirst(batch.count)
    }

    /// Take the pile off the screen. The panels are hidden and kept as spares rather
    /// than closed, so the next pile — a second run, a seek back over the cue — starts
    /// with its windows already built; nothing about them is visible in between.
    func clear() {
        generation += 1
        rampStart = nil
        for panel in panels {
            panel.orderOut(nil)
            panel.blank()
        }
        spares += panels
        panels.removeAll()
        spawned.removeAll()
    }
}
