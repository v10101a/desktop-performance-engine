import SwiftUI
import AppKit

/// Terminal.app's "Basic" profile, matching `TerminalStyle` on the AppKit side so the
/// report and the `code` windows are the same surface.
///
/// This replaced a CRT phosphor palette (green on near-black, with scanlines and a
/// glow). ANSI-ish accents are kept for the few line kinds that need to stand apart,
/// at the weights a real terminal would print them.
enum Phosphor {
    static var base    = Color.black
    static var dim     = Color(white: 0.42)
    static var section = Color(red: 0.00, green: 0.31, blue: 0.75)   // ANSI blue
    static var alert   = Color(red: 0.70, green: 0.00, blue: 0.00)   // ANSI red
    static var warn    = Color(red: 0.60, green: 0.36, blue: 0.00)   // ANSI yellow, darkened
    static var ok      = Color(red: 0.00, green: 0.45, blue: 0.10)   // ANSI green
    static var ground  = Color.white
    /// Highlighter yellow, for the lines a `focus` re-read points at.
    static var marker  = Color(red: 1.00, green: 0.90, blue: 0.20).opacity(0.85)

    /// Print the report on another surface: `ground` behind, `text` on it.
    ///
    /// **Static, so every probe window in a show shares one look.** That is what the
    /// piece wants — cue 4 puts five of them on the screen at once and they are one
    /// machine talking — and it is the reason this is a set of variables rather than an
    /// environment value threaded through the view. Two probe windows in two different
    /// colours at the same time would need that; nothing asks for it.
    ///
    /// The accents are re-derived rather than kept: ANSI's dark blue section headers and
    /// dark red alerts are close to invisible on a saturated blue ground. On a themed
    /// surface they become light tints that hold their meaning — the section still reads
    /// as the piece's own light blue, the alert still reads as an alert.
    static func use(background: NSColor, text: NSColor) {
        ground  = Color(nsColor: background)
        base    = Color(nsColor: text)
        dim     = Color(nsColor: text).opacity(0.55)
        section = Color(red: 0.41, green: 0.74, blue: 0.97)          // #68BDF8
        alert   = Color(red: 1.00, green: 0.58, blue: 0.64)
        warn    = Color(red: 1.00, green: 0.83, blue: 0.30)
        ok      = Color(red: 0.61, green: 0.91, blue: 0.69)
        marker  = Color(nsColor: text).opacity(0.30)
    }

    /// Back to Terminal's Basic profile. The still renderer and the tests draw the
    /// report too, and they must not inherit a colour a show happened to set.
    static func useTerminalBasic() {
        base = .black
        dim = Color(white: 0.42)
        section = Color(red: 0.00, green: 0.31, blue: 0.75)
        alert = Color(red: 0.70, green: 0.00, blue: 0.00)
        warn = Color(red: 0.60, green: 0.36, blue: 0.00)
        ok = Color(red: 0.00, green: 0.45, blue: 0.10)
        ground = .white
        marker = Color(red: 1.00, green: 0.90, blue: 0.20).opacity(0.85)
    }
}

/// Terminal renders everything at one size in one face; the `size` argument is kept
/// so the existing call sites still read, but it is ignored in favour of the real
/// thing — SF Mono 11, exactly what `TerminalStyle.font` uses.
func termFont(_ size: CGFloat, bold: Bool = false) -> Font {
    Font(bold ? TerminalStyle.boldFont : TerminalStyle.font)
}

struct TerminalView: View {
    @EnvironmentObject var probe: Probe
    @State private var cursorOn = true
    @State private var copied = false

    private let cursorTimer = Timer.publish(every: 0.55, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Phosphor.ground.ignoresSafeArea()

            VStack(spacing: 0) {
                stream
                statusBar
            }
        }
        .frame(minWidth: 780, minHeight: 520)
        .onReceive(cursorTimer) { _ in cursorOn.toggle() }
    }

    // MARK: stream

    private var stream: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2.5) {
                    ForEach(probe.lines) { line in
                        row(line).id(line.id)
                    }
                    Color.clear.frame(height: 6).id("bottom")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .textSelection(.enabled)
            // The trailing-closure onChange is macOS 14+; DPE deploys to 13, so this
            // uses the older single-value form.
            .onChange(of: probe.lines.count) { _ in
                withAnimation(.linear(duration: 0.12)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func row(_ line: TermLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let label = line.label {
                Text(label)
                    .font(termFont(12))
                    .foregroundStyle(Phosphor.dim)
                    .frame(width: 150, alignment: .leading)
                Text(line.text)
                    .font(termFont(12, bold: line.kind == .alert))
                    .foregroundStyle(color(line.kind))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(line.text)
                    .font(termFont(12, bold: line.kind == .section))
                    .foregroundStyle(color(line.kind))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The `focus` re-read: a marker behind the line, the way you'd highlight the
        // one paragraph in a printout that says where somebody lives.
        .padding(.horizontal, line.highlight ? 6 : 0)
        .padding(.vertical, line.highlight ? 1 : 0)
        .background(line.highlight ? Phosphor.marker : Color.clear)
        .transition(.opacity)
    }

    private func color(_ kind: LineKind) -> Color {
        switch kind {
        case .section: return Phosphor.section
        case .dim:     return Phosphor.dim
        case .ok:      return Phosphor.ok
        case .warn:    return Phosphor.warn
        case .alert:   return Phosphor.alert
        case .prompt:  return Phosphor.base
        default:       return Phosphor.base.opacity(0.92)
        }
    }

    // MARK: status bar

    private var statusBar: some View {
        let s = probe.live
        return VStack(spacing: 0) {
            Rectangle().frame(height: 1).foregroundStyle(Phosphor.dim.opacity(0.4))
            HStack(spacing: 18) {
                gauge("CPU", s.cpuBusy, detail: pct(s.cpuBusy))
                gauge("MEM", s.memFraction, detail: "\(bytes(s.memUsed))")
                if let bf = s.batteryFraction {
                    gauge("PWR", bf, detail: "\(Int(bf * 100))%")
                }
                metric("LOAD", String(format: "%.2f", s.load.0))
                metric("PROC", "\(s.processes)")
                metric("THERM", s.thermal.lowercased().hasPrefix("nominal") ? "ok" : "hot")
                Spacer()
                Text(probe.streaming ? "scanning\(cursorOn ? " ▍" : "  ")" : "idle\(cursorOn ? " ▍" : "  ")")
                    .font(termFont(11))
                    .foregroundStyle(probe.streaming ? Phosphor.alert : Phosphor.base)
            }
            .padding(.horizontal, 20)
            .frame(height: 34)
        }
        .background(Color.black.opacity(0.55))
    }

    private func gauge(_ name: String, _ value: Double, detail: String) -> some View {
        HStack(spacing: 6) {
            Text(name).font(termFont(10)).foregroundStyle(Phosphor.dim)
            Text(bar(value, width: 10))
                .font(termFont(10))
                .foregroundStyle(value > 0.85 ? Phosphor.warn : Phosphor.base)
            Text(detail).font(termFont(10)).foregroundStyle(Phosphor.base.opacity(0.85))
        }
    }

    private func metric(_ name: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(name).font(termFont(10)).foregroundStyle(Phosphor.dim)
            Text(value).font(termFont(10)).foregroundStyle(Phosphor.base.opacity(0.85))
        }
    }

}
