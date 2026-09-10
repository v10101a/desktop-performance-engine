import AppKit

// Organisational split out of WindowManager.swift: extensions can't hold stored
// properties, so the state these operate on still lives in the core type.

extension WindowManager {
    /// Open a window that writes itself out.
    ///
    /// Three surfaces, chosen by `chrome`. The default is the document: a white page in
    /// real macOS chrome, typed character by character. `"terminal"` is Terminal.app's
    /// own window — built through `applyContent` like every other terminal in the piece
    /// and typed into by fishing its label back out, so the welcome card and the end
    /// card's credits are literally the same surface rather than two approximations
    /// of it. `"bubble"` is Clippy's balloon, for the one moment the machine speaks to
    /// the viewer in the first person and asks them for something.
    func beginTyping(_ p: TypeTextParams, at now: Double, bpm: Double) {
        let scr = screen(p.screen)
        let frame = rect(from: p.frame, on: scr)
        close(id: p.id)
        let win: BaseEffectWindow
        let sink: TypedTextSink
        if p.chrome == "bubble" {
            // No chrome at all: the balloon IS the window, so the frame is its content
            // rect and the corners outside the outline stay transparent.
            let tail = SpeechBubbleView.Tail(rawValue: p.tail ?? "left") ?? .left
            let view = SpeechBubbleView(size: frame.size, tail: tail,
                                        fontSize: CGFloat(p.fontSize ?? 13))
            win = HostedEffectWindow(contentRect: frame, view: view, title: nil)
            sink = view
        } else if p.chrome == "terminal" {
            let term = EffectWindow(contentRect: frame,
                                    content: ContentSpec(kind: "code", hex: p.hex, text: "",
                                                         fg: p.fg,
                                                         chrome: "terminal", title: p.title))
            guard let label = firstTextField(in: term.contentView) else { return }
            label.font = .monospacedSystemFont(ofSize: CGFloat(p.fontSize ?? 11), weight: .regular)
            win = term
            sink = TerminalTextSink(label: label)
        } else {
            // Build the editor at the CONTENT size, not the outer frame: it lays its text
            // layer out once in init, so handing it the frame size makes it a title bar too
            // tall and the bottom of the letter is clipped.
            let title = p.title ?? "Untitled"
            let native = usesNativeChrome("mac", size: frame.size)
            let view = TextEditorView(size: BaseEffectWindow.contentSize(forFrame: frame, native: native),
                                      title: title, fontSize: CGFloat(p.fontSize ?? 13))
            win = HostedEffectWindow(contentRect: frame, view: view, title: title)
            sink = view
        }
        // Draggable, but with no close zone armed: the copy can be shoved around while
        // it writes itself, and can't be dismissed by accident.
        if p.interactive == true { win.makeInteractive(size: frame.size) }
        windows[p.id] = win
        win.present(animate: "fadeIn")
        // By the line, a "stop" is the end of a line and the rate is lines per beat; by
        // the character every character is a stop. Same scheme the credits use, so both
        // read as the same machine printing.
        let chars = Array(p.text)
        let byLine = p.linesPerBeat != nil
        var stops: [Int] = []
        if byLine {
            var n = 0
            for (i, line) in p.text.components(separatedBy: "\n").enumerated() {
                n += line.count + (i > 0 ? 1 : 0)      // the newline before every line but the first
                stops.append(n)
            }
        } else {
            stops = chars.isEmpty ? [] : Array(1...chars.count)
        }
        let rate = byLine ? (p.linesPerBeat ?? 1) : (p.charsPerBeat ?? 16)
        let trim = p.durationSeconds ?? p.durationBeats.map { $0 * 60.0 / bpm }
        typers[p.id] = Typer(sink: sink, text: chars, stops: stops, byLine: byLine, start: now,
                             unitsPerSecond: max(0.05, rate * bpm / 60.0),
                             endTime: trim.map { now + $0 }, shown: -1, caretOn: true)
        sink.showTyped("", caret: true)
    }

    /// Advance every open typewriter: stops by elapsed time, caret blinking at 2 Hz,
    /// redraw only when one of them changes. By the line the caret waits at the start
    /// of the NEXT line, the way a prompt does after a command has printed; by the
    /// character it trails the last letter. Unlike the credits the caret keeps blinking
    /// once the copy is done — a `typeText` window is closed by the cut, not by the
    /// viewer, so there is nothing for a finished state to hand over to.
    func updateTypers(now: Double) {
        for (id, var t) in typers {
            guard windows[id] != nil else { typers[id] = nil; continue }
            if let end = t.endTime, now >= end { typers[id] = nil; continue }
            let elapsed = now - t.start
            let units = max(0, Int(elapsed * t.unitsPerSecond))
            let want = (units == 0 || t.stops.isEmpty) ? 0 : t.stops[min(units, t.stops.count) - 1]
            let caret = Int(elapsed * 2) % 2 == 0
            guard want != t.shown || caret != t.caretOn else { continue }
            t.shown = want
            t.caretOn = caret
            typers[id] = t
            t.sink.showTyped(String(t.text[0..<want]) + (caret && t.byLine && want > 0 ? "\n" : ""),
                             caret: caret)
        }
    }

    /// Called every pump tick to advance active moves and jiggles.
}
