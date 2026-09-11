import AppKit

/// A monospaced text plane, transparent, sized to whatever window it is put in — which in
/// this show is usually the whole screen.
///
/// It is not `AsciiRenderer`. That one converts a picture or a block of text into ASCII
/// art and lays it out ONCE in an `NSTextView`, auto-fit to a card. This is a live plane
/// on a fixed character grid: it has a clock, it scrolls, it strobes, and it draws itself
/// rather than hosting a text system. Full-screen text through `NSTextView` re-lays every
/// glyph on every change, which is the whole frame budget at these sizes.
///
/// Four sources, and they split into two shapes:
///
/// - **Streams** (`.hex`, `.lines`) push one line at a time into a rolling buffer at `hz`
///   and scroll. A memory dump and a log are the same object with different line
///   generators.
/// - **Frames** (`.text`, `.windows`) rebuild the whole grid when something changes —
///   a strobe phase, a window opening — and otherwise sit still.
///
/// **Transparent by construction.** No layer background, `isOpaque` false, and the ground
/// is drawn only when a `background` is given (the window map's blue). Everything under it
/// shows through the gaps between glyphs, which is the point of putting it over the whole
/// screen rather than in a card.
final class AsciiLogView: NSView {

    enum Source {
        /// Lines of a memory dump: offset, hex bytes, printable gutter.
        case hex(seed: UInt64)
        /// Supplied lines, pushed one at a time — the lyric going out as a log.
        case lines([String])
        /// A fixed block, drawn once and left. Corrupted if `zalgo` is set.
        case text(String)
        /// The show's own windows, drawn as box art. Redrawn as they come and go.
        case windows
    }

    /// Interior fills, lightest first. One per window by depth in the stack, so a pile of
    /// overlapping boxes stays legible as separate objects instead of one field of tone.
    /// All ASCII, for the advance-width reason in `windowMap`.
    static let shades: [Character] = [".", ":", "-", "=", "+", "*", "#"]

    /// Where `.windows` gets its rectangles. Set once by `PerformanceEngine` — the plane
    /// is built by a free function that has no route to the manager, and threading one
    /// through every content view for one source would be worse than a seam here.
    /// Returns (frame in screen points, label), back to front.
    ///
    /// Takes the ASKING window so the provider can leave it out. The plane is itself an
    /// `openWindow` and therefore in the manager's list, full-screen and frontmost — left
    /// in, it draws a box over the whole grid and its `░` interior buries every window it
    /// was supposed to be showing. The map must not contain the map.
    static var windowProvider: ((NSWindow?) -> [(NSRect, String)])?

    private let source: Source
    private let fg: NSColor
    private let background: NSColor?
    private let hz: Double
    private let zalgo: Double
    private let seed: UInt64
    /// Strobe rate in Hz, 0 = off. On `.windows` this alternates the whole plane between
    /// drawn and clear, so the real screen shows through on the off phase.
    private let strobe: Double

    private var pt: CGFloat = 13
    private var cell = NSSize(width: 8, height: 15)
    private var cols = 80
    private var rows = 24

    private var buffer: [String] = []
    private var frameLines: [String] = []
    private var tick = 0
    private var strobeOn = true
    private var timer: Timer?
    private var rng: SplitMix64

    init(size: NSSize, source: Source, fg: NSColor, background: NSColor?,
         hz: Double, fontSize: CGFloat, zalgo: Double, strobe: Double, seed: UInt64) {
        self.source = source
        self.fg = fg
        self.background = background
        self.hz = max(0.1, hz)
        self.zalgo = zalgo
        self.strobe = max(0, strobe)
        self.seed = seed
        self.rng = SplitMix64(seed: seed)
        super.init(frame: NSRect(origin: .zero, size: size))
        self.pt = max(6, fontSize)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        regrid()
    }

    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { background != nil && strobe == 0 }

    // MARK: - Grid

    private func regrid() {
        cell = AsciiFont.cell(ofSize: pt)
        cols = max(8, Int(bounds.width / max(cell.width, 1)))
        rows = max(2, Int(bounds.height / max(cell.height, 1)))
        rebuildFrame()
        if ProcessInfo.processInfo.environment["DPE_ASCII_DEBUG"] == "1" {
            NSLog("[DPE] asciilog regrid: bounds \(bounds.size) cell \(cell) → \(cols)x\(rows) "
                + "frameLines \(frameLines.count) provider \(AsciiLogView.windowProvider == nil ? "nil" : "set")")
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        regrid()
    }

    // MARK: - Clock
    //
    // Self-timed, like every other continuously-running view in the show (`UIChaosView`,
    // `MandalaView`, `FileworksView`), and started from `viewDidMoveToWindow` so a view
    // that is built and thrown away never leaves a timer behind. `--bench-views` is what
    // says whether it costs the pump anything.

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // NO WINDOW SHADOW. `EffectWindow` turns it on for everything, which is right for
        // a card floating over the desktop and wrong here: on a TRANSPARENT window AppKit
        // derives the shadow from the alpha mask, so it is not one shadow behind a panel —
        // every single glyph casts its own. On a full screen of text that reads as a
        // botched drop shadow on the type. Turned off from the view because the plane is
        // the thing that knows it never wants one, wherever it is opened.
        window?.hasShadow = false
        if window == nil, Scheduler.profiling, draws > 0 {
            NSLog("[DPE] asciilog \(source): \(draws) draws, mean %.1f ms, worst %.1f ms on main",
                  drawMs / Double(draws), drawWorstMs)
        }
        // The clock runs only while the plane is ON SCREEN (`WindowVisibility`): the
        // window exists from load, prewarmed, and the map rebuilding a dozen times a
        // second in a window nobody could see was most of the main thread for the
        // whole show. It also means the strobe's phase starts on the cue, as authored.
        visibility.follow(window)
    }

    private lazy var visibility = WindowVisibility { [weak self] visible in
        self?.setRunning(visible)
    }

    private func setRunning(_ running: Bool) {
        timer?.invalidate()
        timer = nil
        guard running else { return }
        // The plane advances on the faster of its two clocks: the line rate and the
        // strobe. One timer either way — two would drift against each other and the
        // strobe phase would slide off the beat it was authored on.
        let rate = max(hz, strobe * 2, 1)
        let t = Timer(timeInterval: 1.0 / rate, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit { timer?.invalidate() }

    private func step() {
        tick += 1
        let rate = max(hz, strobe * 2, 1)
        if strobe > 0 {
            // Half-cycles: a 4 Hz strobe is on for an eighth of a second and off for one.
            let half = max(1, Int((rate / (strobe * 2)).rounded()))
            let phase = (tick / half) % 2 == 0
            if phase != strobeOn { strobeOn = phase; needsDisplay = true }
        }
        switch source {
        case .hex, .lines:
            let every = max(1, Int((rate / hz).rounded()))
            if tick % every == 0 { pushLine(); needsDisplay = true }
        case .windows:
            // Cheap enough to rebuild every tick and it has to be: windows open and close
            // under it a dozen times a second during the eruption.
            rebuildFrame()
            needsDisplay = true
        case .text:
            break                     // static; drawn once
        }
    }

    // MARK: - Sources

    private func pushLine() {
        let line: String
        switch source {
        case .hex:
            line = AsciiLogView.hexLine(offset: tick, rng: &rng, cols: cols)
        case .lines(let ls):
            guard !ls.isEmpty else { return }
            let raw = ls[(tick / max(1, Int((max(hz, strobe * 2, 1) / hz).rounded()))) % ls.count]
            line = AsciiLogView.logLine(raw, index: buffer.count)
        default:
            return
        }
        buffer.append(zalgo > 0 ? Zalgo.corrupt(line, intensity: zalgo, seed: seed &+ UInt64(tick)) : line)
        if buffer.count > rows { buffer.removeFirst(buffer.count - rows) }
    }

    /// `0007fe40  4f 6e 20 74 68 65 20 66  6c 6f 6f 72 20 6f 66 20  |On the floor of |`
    ///
    /// Not real memory — it is a show, and reading the process's own address space to
    /// put on screen would be both slower and a genuinely bad idea. The bytes are the
    /// seeded generator's, biased toward printable ASCII so the right-hand gutter reads
    /// as text rather than as dots, which is what makes a dump look like a dump.
    private static func hexLine(offset: Int, rng: inout SplitMix64, cols: Int) -> String {
        // 16 bytes is the canonical width; drop to 8 on a narrow grid rather than wrap.
        let n = cols >= 76 ? 16 : 8
        var bytes: [UInt8] = []
        for _ in 0..<n {
            // Two in three printable: an all-random dump is a wall of dots in the gutter.
            let r = rng.nextUnit()
            bytes.append(r < 0.66 ? UInt8(32 + Int(rng.nextUnit() * 94)) : UInt8(rng.next() & 0xFF))
        }
        let addr = String(format: "%08x", (offset &* 16) & 0xFFFFFFF)
        var hex = ""
        for (i, b) in bytes.enumerated() {
            hex += String(format: "%02x ", b)
            if i == n / 2 - 1 { hex += " " }          // the classic mid-row gap
        }
        let gutter = String(bytes.map { $0 >= 32 && $0 < 127 ? Character(UnicodeScalar($0)) : "." })
        return "\(addr)  \(hex) |\(gutter)|"
    }

    /// A lyric line as the machine would log it. Monotonic clock, a level, a subsystem —
    /// the shape of a real log, so the words arriving in it land as words the machine is
    /// emitting rather than as a caption.
    private static func logLine(_ text: String, index: Int) -> String {
        let t = Double(index) * 0.4669                 // one line per beat at 128.5 BPM
        let level = index % 7 == 3 ? "WARN " : index % 11 == 5 ? "ERROR" : "INFO "
        return String(format: "[%9.4f] %@ giveit2me[1337]: %@", t, level, text)
    }

    private func rebuildFrame() {
        switch source {
        case .text(let s):
            let body = zalgo > 0 ? Zalgo.corrupt(s, intensity: zalgo, seed: seed) : s
            frameLines = body.components(separatedBy: "\n")
        case .windows:
            frameLines = AsciiLogView.windowMap(cols: cols, rows: rows,
                                                screen: window?.screen ?? NSScreen.main,
                                                excluding: window)
            if ProcessInfo.processInfo.environment["DPE_ASCII_DEBUG"] == "1" {
                let n = AsciiLogView.windowProvider?(window).count ?? -1
                NSLog("[DPE] asciilog windows: provider gave \(n) rects → \(frameLines.count) lines"
                    + " (grid \(cols)x\(rows))")
            }
        case .hex, .lines:
            break
        }
    }

    /// The show's own windows, drawn as box art on the character grid.
    ///
    /// Synthesised from the rectangles the engine already owns — NOT a screen capture.
    /// Capturing would need Screen Recording, which macOS will not settle with an inline
    /// prompt, and `TimelineTests` fails any cut that needs it. The engine knows every
    /// window's frame and title because it opened them, so this is both free and exact.
    private static func windowMap(cols: Int, rows: Int, screen: NSScreen?,
                                  excluding asking: NSWindow?) -> [String] {
        guard let provider = windowProvider, let screen else { return [] }
        let bounds = screen.frame
        var grid = [[Character]](repeating: [Character](repeating: " ", count: cols), count: rows)

        func put(_ ch: Character, _ c: Int, _ r: Int) {
            guard r >= 0, r < rows, c >= 0, c < cols else { return }
            grid[r][c] = ch
        }

        // Front-most last, so a window drawn later overwrites the one behind it — the
        // same order the window server composites in, which is what makes the overlaps
        // read correctly instead of as a wireframe pile.
        var depth = 0
        for (frame, title) in provider(asking) {
            // Screen points → cells. Y flips: AppKit measures up from the bottom, the
            // grid counts down from the top.
            let c0 = Int(((frame.minX - bounds.minX) / bounds.width) * CGFloat(cols))
            let c1 = Int(((frame.maxX - bounds.minX) / bounds.width) * CGFloat(cols))
            let r0 = Int(((bounds.maxY - frame.maxY) / bounds.height) * CGFloat(rows))
            let r1 = Int(((bounds.maxY - frame.minY) / bounds.height) * CGFloat(rows))
            guard c1 > c0, r1 > r0 else { continue }

            // PURE ASCII — `+ - | . : = # *` — not the Unicode box-drawing set.
            //
            // Monaco has no box-drawing glyphs, so `┌ ─ │ ░` are drawn by whatever face
            // CoreText substitutes, and they come back 7.83pt wide against ASCII's 7.80
            // (measured; `AsciiFontTests` pins it). Three hundredths of a point sounds
            // like nothing and is three quarters of a character by column 193 — every box
            // edge on a row drifts out of true with the rows above it. ASCII is the same
            // face at the same advance the whole way across, and it is what the act asked
            // for.
            let fill = AsciiLogView.shades[depth % AsciiLogView.shades.count]
            for r in r0...r1 {
                for c in c0...c1 {
                    let edgeT = r == r0, edgeB = r == r1, edgeL = c == c0, edgeR = c == c1
                    if (edgeT || edgeB) && (edgeL || edgeR) { put("+", c, r) }
                    else if edgeT || edgeB { put("-", c, r) }
                    else if edgeL || edgeR { put("|", c, r) }
                    // Each window gets its own shade off its depth in the stack, so two
                    // overlapping boxes are still two things rather than one grey field.
                    else { put(fill, c, r) }
                }
            }
            depth += 1
            // The title bar rule, and the title in it if there is room for it.
            if r0 + 1 <= r1 - 1 {
                for c in (c0 + 1)...max(c0 + 1, c1 - 1) { put("=", c, r0 + 1) }
            }
            let room = max(0, c1 - c0 - 3)
            if room > 3 {
                let label = String(title.prefix(room))
                for (i, ch) in label.enumerated() { put(ch, c0 + 2 + i, r0) }
            }
        }
        return grid.map { String($0) }
    }

    // MARK: - Drawing

    // DPE_PROFILE=1: what each redraw of the plane costs the main thread.
    private var draws = 0
    private var drawMs = 0.0
    private var drawWorstMs = 0.0

    override func draw(_ dirtyRect: NSRect) {
        // The off phase of a strobe is genuinely nothing — not a dimmed plane, not a
        // cleared one. The window under it is transparent, so the real screen is what
        // shows, which is what "strobe between the windows and the ASCII" means.
        if strobe > 0 && !strobeOn { return }
        let t0 = CACurrentMediaTime()
        defer {
            if Scheduler.profiling {
                let ms = (CACurrentMediaTime() - t0) * 1000
                draws += 1; drawMs += ms; drawWorstMs = max(drawWorstMs, ms)
            }
        }

        if let background {
            background.setFill()
            dirtyRect.fill()
        }

        let font = AsciiFont.font(ofSize: pt)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg]
        let lines: [String]
        switch source {
        case .hex, .lines: lines = buffer
        case .text, .windows: lines = frameLines
        }

        // Top-down. `isFlipped` is left alone (the show's other views are unflipped) and
        // the row origin is computed instead, so this composes with anything else drawn
        // into the same window.
        for (r, line) in lines.enumerated() {
            let y = bounds.height - CGFloat(r + 1) * cell.height
            if y + cell.height < dirtyRect.minY || y > dirtyRect.maxY { continue }
            NSAttributedString(string: line, attributes: attrs)
                .draw(at: NSPoint(x: 0, y: y))
        }
    }
}
