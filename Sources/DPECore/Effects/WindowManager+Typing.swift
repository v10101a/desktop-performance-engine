import AppKit

// Split out of WindowManager.swift, which had grown to 753 lines covering seven
// unrelated subsystems. Extensions can't hold stored properties, so the state these
// operate on still lives in the core type — this is an organisational split, not a
// decoupling. Genuinely extracting these into their own executors is the right end
// state, but it should wait until the animation paths have test coverage; there is
// none today, and they are the hardest thing here to verify by eye.

extension WindowManager {
    func beginTyping(_ p: TypeTextParams, at now: Double, bpm: Double) {
        let scr = screen(p.screen)
        let frame = rect(from: p.frame, on: scr)
        close(id: p.id)
        // Build the editor at the CONTENT size, not the outer frame: it lays its text
        // layer out once in init, so handing it the frame size makes it a title bar too
        // tall and the bottom of the letter is clipped.
        let title = p.title ?? "Untitled"
        let native = usesNativeChrome("mac", size: frame.size)
        let view = TextEditorView(size: BaseEffectWindow.contentSize(forFrame: frame, native: native),
                                  title: title, fontSize: CGFloat(p.fontSize ?? 13))
        let win = HostedEffectWindow(contentRect: frame, view: view, title: title)
        // Draggable, but with no close zone armed: the letter can be shoved around
        // while it writes itself, and can't be dismissed by accident.
        if p.interactive == true { win.makeInteractive(size: frame.size) }
        windows[p.id] = win
        win.present(animate: "fadeIn")
        let cps = max(0.5, (p.charsPerBeat ?? 16) * bpm / 60.0)
        let trim = p.durationSeconds ?? p.durationBeats.map { $0 * 60.0 / bpm }
        typers[p.id] = Typer(view: view, text: Array(p.text), start: now,
                             charsPerSecond: cps, endTime: trim.map { now + $0 },
                             shown: -1, caretOn: true)
        view.render("", caret: true)
    }

    func updateTypers(now: Double) {
        for (id, var t) in typers {
            guard windows[id] != nil else { typers[id] = nil; continue }
            if let end = t.endTime, now >= end { typers[id] = nil; continue }
            let want = min(t.text.count, max(0, Int((now - t.start) * t.charsPerSecond)))
            let caret = Int((now - t.start) * 2) % 2 == 0
            guard want != t.shown || caret != t.caretOn else { continue }
            t.shown = want
            t.caretOn = caret
            typers[id] = t
            t.view.render(String(t.text[0..<want]), caret: caret)
        }
    }

    /// Called every pump tick to advance active moves and jiggles.
}
