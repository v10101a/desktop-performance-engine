//  Imported from ~/segcam (2026-09-03), unchanged except for this header.
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
//  TWO DIVERGENCES, both marked below and both the same shape — a hard-coded look becomes
//  a property whose default is upstream's value, so this file still behaves exactly as
//  segcam does unless a cue says otherwise:
//
//    * the window LEVEL. Upstream pins every panel one level under the shielding window,
//      because in segcam the swarm is the screen. Here it is one act among several and a
//      cue has to be able to say what goes over it.
//    * the green BORDER. Upstream rings every panel to mark it as a detection. In the
//      piece the panels are the furniture rather than an annotation of it, and a green
//      keyline on sixty windows reads as a debug overlay laid over the show.

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
    /// DPE divergence: upstream hard-codes this at the shielding level (see the header).
    static let defaultLevel = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) - 1)
    /// DPE divergence: upstream always draws this keyline. Nil takes it off.
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
        setBorder(SegmentPanel.defaultBorder)
        borderLayer.backgroundColor = NSColor.clear.cgColor
        content.layer?.addSublayer(imageLayer)
        content.layer?.addSublayer(borderLayer)
    }

    /// DPE divergence: the keyline, or none at all.
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
    /// Instances already given a window. Segments can be republished across frames (Vision
    /// runs at half rate and its results are reused), and a repeat is the same instance, not
    /// a new one.
    private var spawned: Set<SegmentID> = []

    var mirrored = true
    /// How many windows the collage holds before the oldest is recycled.
    var maxBlobs = 100
    /// DPE divergence: what the pile sits at. Upstream is always `SegmentPanel.defaultLevel`.
    var level = SegmentPanel.defaultLevel
    /// DPE divergence: the keyline round each panel, or nil for none. Upstream is green.
    var border: NSColor? = SegmentPanel.defaultBorder

    private let minWidth: CGFloat = 120     // a titled window can't be narrower than its bar
    private let minHeight: CGFloat = 28

    var panelCount: Int { panels.count }

    func update(segments: [Segment], crops: [SegmentID: CGImage], screenFrame: CGRect) {
        for segment in segments where !spawned.contains(segment.id) {
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

            let panel = panels.count >= maxBlobs ? panels.removeFirst() : SegmentPanel()
            panel.level = level                 // DPE divergence — see the header
            panel.setBorder(border)             // DPE divergence — see the header
            panel.adopt(title: segment.label, image: crops[segment.id],
                        contentRect: rect, mirrored: mirrored)
            panels.append(panel)
        }
    }

    func clear() {
        for panel in panels {
            panel.orderOut(nil)
            panel.close()
        }
        panels.removeAll()
        spawned.removeAll()
    }
}
