import AppKit

/// The intro gate. These pin the two things that decide whether the piece can start at
/// all — the buttons doing something, and the track not starting until they do.
enum GateTests {
    static func run(_ t: TestHarness) {
        t.suite("gate") { t in
            let alert = IntroGate.script.first { $0.style == .macAlert }
            t.notNil(alert, "the gate has a macOS-chrome alert card")
            guard let alert else { return }

            var started = 0, exited = 0
            var view: NSView? = GateAlertView(alert, size: IntroGate.alertSize,
                                              onStart: { started += 1 },
                                              onExit: { exited += 1 })
            // Force a pass of the autorelease pool: the bug this guards against is an
            // action object surviving construction and dying immediately afterwards.
            autoreleasepool { _ = NSString(string: "cycle") }

            let buttons = (view?.subviews.first?.subviews.compactMap { $0 as? NSButton }) ?? []
            t.equal(buttons.count, 2, "the alert has two buttons")

            // `NSControl.target` is WEAK. If nothing strongly holds the action object it
            // is nil by now and the button is dead scenery — clicking "yes" would do
            // nothing at all, which is exactly the failure this catches.
            for b in buttons {
                t.notNil(b.target, "button \"\(b.title)\" still has a live target")
                t.notNil(b.action, "button \"\(b.title)\" still has an action")
            }

            // And the actions are wired to the right side.
            for b in buttons {
                if let target = b.target as? GateButtonAction { target.fire() }
            }
            t.equal(started, 1, "exactly one button starts the show")
            t.equal(exited, 1, "exactly one button leaves")

            view = nil

            // The face is keyed to transparency so it can sit on the show's blue rather
            // than the near-pure blue inside the JPEG. That keying must never reach the
            // file: `setColor` writes through to the backing store, and an `NSImage`
            // loaded from a path can be backed by the mapped file — it edited a
            // committed asset on disk once already.
            let facePath = resolveResourcePath(IntroGate.faceAsset)
            t.expect(FileManager.default.fileExists(atPath: facePath),
                     "the restart card's face asset resolves — looked at \(facePath)")
            let before = (try? Data(contentsOf: URL(fileURLWithPath: facePath))) ?? Data()
            if let raw = NSImage(contentsOfFile: facePath) {
                let masked = RestartCardView.maskingField(raw)
                let after = (try? Data(contentsOf: URL(fileURLWithPath: facePath))) ?? Data()
                t.expect(!before.isEmpty && before == after,
                         "keying the face leaves the asset file untouched")
                t.expect(Set(raw.representations.map { ObjectIdentifier($0) })
                            .isDisjoint(with: Set(masked.representations.map { ObjectIdentifier($0) })),
                         "the keyed face owns its own representation")

                // The field really is gone, and the face really is still there.
                var r = NSRect(origin: .zero, size: masked.size)
                if let cg = masked.cgImage(forProposedRect: &r, context: nil, hints: nil) {
                    let rep = NSBitmapImageRep(cgImage: cg)
                    t.near(Double(rep.colorAt(x: 0, y: 0)?.alphaComponent ?? 1), 0, 0.01,
                           "the corner of the face is transparent")
                    var opaque = 0
                    for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
                        for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                            if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { opaque += 1 }
                        }
                    }
                    t.expect(opaque > 40, "the face itself survives the keying — \(opaque) opaque samples")
                }
            }
        }
    }
}
