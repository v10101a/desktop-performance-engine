import AppKit

/// A panel that CAN take the keyboard. Everything else the show opens refuses key
/// status so a stray click can't pull focus mid-take; the oracle needs a text field, so
/// it is the one exception — and it hands focus back the moment it has answered.
final class OraclePanel: NSPanel {
    var wantsKey = true
    override var canBecomeKey: Bool { wantsKey }
    override var canBecomeMain: Bool { false }
}

/// The magic torus. An alert asks the viewer to type a question and answers it when
/// they press OK (or Return) — or answers on its own after `answerBeats`, so a viewer
/// who won't play can't stall the show. The same question always gets the same answer:
/// a hash of the text picks from the list, so it feels like the torus *knows*.
///
/// **Reversibility.** One window; the only thing it touches is key-window status, which
/// it returns on answer and on teardown.
final class OracleController {
    private struct Oracle {
        let id: String
        let window: OraclePanel
        let field: NSTextField
        let answers: [String]
        let icon: DialogIcon
        let autoAt: Double?
        var answered = false
    }

    private var oracle: Oracle?
    private var askedCount = 0
    var bpm: Double = 120

    /// The torus only speaks in absolutes — and half of them are a "yes" with a catch.
    /// Rewriting this list is the whole of rewriting what the torus says; the answer
    /// card sizes itself to whatever is in it (see `makeAnswerView`).
    static let defaultAnswers = [
        "NO",
        "YES",
        "MAYBE",
        "YES FOR NOW",
        "YES, BUT NOT LIKE YOU THINK",
        "YOU MUST ASK THE VERSION OF YOU FROM YESTERDAY",
        "NO, THOUGH IT WILL FEEL LIKE YES",
        "NO, AND YOU WILL KNOW WHY"
    ]

    /// The answer for a question. Deterministic — FNV-1a over the lowercased text — so
    /// asking twice gets the same reply (`String.hashValue` is per-process random and
    /// would not). An empty question falls back to `fallback` into the list.
    static func answer(to question: String, from answers: [String], fallback: Int) -> String {
        let list = answers.isEmpty ? defaultAnswers : answers
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return list[abs(fallback) % list.count] }
        var h: UInt64 = 14_695_981_039_346_656_037
        for b in q.utf8 {
            h ^= UInt64(b)
            h = h &* 1_099_511_628_211
        }
        return list[Int(h % UInt64(list.count))]
    }

    // MARK: - Lifecycle

    func begin(_ p: OracleParams, at now: Double, bpm: Double) {
        teardown()
        let screen = ScreenGeometry.screen(p.screen)
        let size = NSSize(width: 460, height: 186)
        let frame = ScreenGeometry.rectOrCentred(p.frame, size: size, on: screen)

        let panel = OraclePanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = true

        let icon = DialogIcon(rawValue: p.icon ?? "app") ?? .app
        let (root, field) = OracleController.makeAskView(
            size: frame.size, title: p.title ?? "hey, i'm the magic torus",
            body: p.body ?? "ask me a question", placeholder: p.placeholder ?? "type it here",
            icon: icon, target: self, action: #selector(okPressed))
        panel.contentView = root
        // Key without activating the app — the way Spotlight takes typing.
        panel.wantsKey = true
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)

        let auto = Beats.seconds(p.answerBeats, or: p.answerSeconds, bpm: bpm) ?? 8 * 60 / bpm
        oracle = Oracle(id: p.id, window: panel, field: field,
                        answers: p.answers ?? OracleController.defaultAnswers,
                        icon: icon, autoAt: now + auto)
    }

    @objc private func okPressed() { answerNow() }

    private func answerNow() {
        guard var o = oracle, !o.answered else { return }
        o.answered = true
        askedCount += 1
        let question = o.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = OracleController.answer(to: question, from: o.answers, fallback: askedCount)

        o.window.contentView = OracleController.makeAnswerView(size: o.window.frame.size,
                                                               question: question, answer: answer,
                                                               icon: o.icon)
        oracle = o

        // The answer needs no keyboard: give it back.
        o.window.wantsKey = false
        handBackKey(from: o.window)
    }

    private func handBackKey(from window: NSWindow) {
        guard window.isKeyWindow else { return }
        if let other = NSApp.windows.first(where: { $0 !== window && $0.isVisible && $0.canBecomeKey
                                                     && !($0 is OraclePanel) }) {
            other.makeKey()
        }
    }

    func stop(id: String) {
        guard oracle?.id == id else { return }
        teardown()
    }

    func closeAll() { teardown() }

    private func teardown() {
        guard let o = oracle else { return }
        o.window.wantsKey = false
        handBackKey(from: o.window)
        o.window.orderOut(nil)
        o.window.close()
        oracle = nil
    }

    // MARK: - Tick

    func update(now: Double) {
        guard let o = oracle, !o.answered, let at = o.autoAt, now >= at else { return }
        answerNow()
    }

    // MARK: - Views (shared with the still renderer)

    private static func textX(for size: NSSize, icon: DialogIcon) -> CGFloat {
        (size.width >= 300 && size.height >= 130 && icon != .none) ? 20 + DialogIcon.side + 16 : 20
    }

    /// The question card: an alert with a text field and an OK button.
    static func makeAskView(size: NSSize, title: String, body: String, placeholder: String,
                            icon: DialogIcon, target: AnyObject?, action: Selector?) -> (NSView, NSTextField) {
        let root = makeDialogContentView(title: title, message: body, buttons: [], icon: icon, size: size)
        let x = textX(for: size, icon: icon)

        // Right under the prompt, the way an alert with a field lays out.
        let field = NSTextField(frame: NSRect(x: x, y: size.height - 100, width: size.width - x - 20, height: 26))
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.bezelStyle = .roundedBezel
        field.isEditable = true
        field.target = target
        field.action = action
        root.addSubview(field)

        let ok = NSButton(title: "OK", target: target, action: action)
        ok.bezelStyle = .rounded
        ok.keyEquivalent = "\r"
        ok.sizeToFit()
        let w = max(ok.frame.width, 76)
        ok.frame = NSRect(x: size.width - 20 - w, y: 12, width: w, height: ok.frame.height)
        root.addSubview(ok)
        return (root, field)
    }

    /// The answer's face: display size, SHRUNK TO FIT rather than clipped. The answers
    /// are copy and meant to be rewritten — the long ones ("YOU MUST ASK THE VERSION OF
    /// YOU FROM YESTERDAY") run to three lines, at which point the last of them falls
    /// out of the card and the torus appears to trail off mid-sentence.
    static func answerFont(for answer: String, in box: NSSize) -> NSFont {
        var pt: CGFloat = 30
        func font(_ pt: CGFloat) -> NSFont { .systemFont(ofSize: pt, weight: .heavy) }
        while pt > 13, answer.boundingRect(
                with: NSSize(width: box.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin],
                attributes: [.font: font(pt)]).height > box.height {
            pt -= 1
        }
        return font(pt)
    }

    /// The answer card: the question quoted in the title, the answer big and pink.
    static func makeAnswerView(size: NSSize, question: String, answer: String, icon: DialogIcon) -> NSView {
        let title = question.isEmpty ? "you didn't ask. the torus says:" : "“\(question)” — the torus says:"
        let root = makeDialogContentView(title: title, message: "", buttons: ["ok"], icon: icon, size: size)
        let x = textX(for: size, icon: icon)
        let big = NSTextField(wrappingLabelWithString: answer)
        big.textColor = NSColor(hex: "#FF2D95") ?? .systemPink
        let box = NSRect(x: x, y: 50, width: size.width - x - 20, height: size.height - 100)
        big.font = answerFont(for: answer, in: box.size)
        big.frame = box
        root.addSubview(big)
        return root
    }
}
