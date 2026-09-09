import AppKit

/// The intro gate. These pin the two things that decide whether the piece can start at
/// all — the buttons doing something, and the track not starting until they do.
enum GateTests {
    static func run(_ t: TestHarness) {
        t.suite("gate") { t in
            // THE ORDER OF THE SCRIPT. The question is asked first and the machine
            // restarts on the answer — consent, then the consequence — and the LAST card
            // is what finishes the gate, so the track comes up out of the restart rather
            // than on the click of a button.
            t.equal(IntroGate.script.first?.style, .macAlert,
                    "the question is the first thing the viewer sees")
            t.equal(IntroGate.script.last?.style, .restart,
                    "…and the restart is the last card, so the track starts out of it")
            t.expect(IntroGate.script.first?.dwell == nil,
                     "the question waits for an answer rather than timing out")
            // The last card carries the gate: with no dwell and no buttons it would sit
            // there forever and the piece would never start.
            t.notNil(IntroGate.script.last?.dwell,
                     "the card that ends the gate advances on its own")

            // WHERE THE PERMISSION PROMPTS GO. On the answer, and nowhere else: the
            // viewer says yes, macOS asks over the card they just answered, and the
            // restart does not begin until every prompt has been accepted or denied.
            // These are the three states of `proceed`, which is the only thing in the
            // gate that decides what happens next.
            let last = IntroGate.script.count - 1
            t.equal(IntroGateController.step(at: 0, consented: false, hasConsentHandler: true),
                    .consentThenNext, "YES raises the prompts before anything else moves")
            t.equal(IntroGateController.step(at: 0, consented: true, hasConsentHandler: true),
                    .next, "…once, not again on the way past")
            t.equal(IntroGateController.step(at: last, consented: true, hasConsentHandler: true),
                    .finish, "the last card is what starts the show")
            // A gate with nothing to ask for must not stall waiting to ask it.
            t.equal(IntroGateController.step(at: 0, consented: false, hasConsentHandler: false),
                    .next, "no prompts to raise means straight on")

            // …and it has to be POSSIBLE to answer them. The gate is a takeover at
            // `.screenSaver`, which is above the level macOS puts its own permission
            // dialogs at, so while the prompts are up it drops out of the way. A prompt
            // raised behind an opaque window nobody can move is the same as no prompt:
            // the viewer watches the question card sit there and nothing happens.
            t.expect(IntroGate.consentLevel.rawValue < IntroGate.level.rawValue,
                     "the gate drops below its own level while the prompts are up")
            t.expect(IntroGate.consentLevel.rawValue <= NSWindow.Level.normal.rawValue,
                     "…to at or below a normal window, which system alerts sit above")

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
            // The gate is the only thing in the piece that makes a noise of its own, and
            // it makes two: one when the alert LANDS and a different one when it is
            // answered. Both are named .wav files under a blanket `assets/*.wav` ignore
            // rule with individual exceptions, and both need their own line in bundle.sh
            // (the audio loop there takes only compressed formats) — so "the file is
            // there" is exactly the thing that silently stops being true.
            for asset in [IntroGate.appearSound, IntroGate.dismissSound] {
                let path = resolveResourcePath(asset)
                t.expect(FileManager.default.fileExists(atPath: path),
                         "gate sound \(asset) resolves — looked at \(path)")
            }

            // ONE BLINK, ONCE. The face used to blink eight times on an uneven pattern
            // that repeated every 23 s; a single blink is worse to be looked at by. The
            // table is sampled over two minutes rather than the card's ~4.6 s life so
            // this also catches the wrap coming back — the old version would show its
            // second cycle here even though the shipped card never lives that long.
            var blinks = 0, wasShut = false
            for step in 0...(120 * 120) {
                let shut = RestartCardView.eyesAreShut(at: Double(step) / 120.0)
                if shut && !wasShut { blinks += 1 }
                wasShut = shut
            }
            t.equal(blinks, 1, "the face blinks exactly once, and never again")

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
