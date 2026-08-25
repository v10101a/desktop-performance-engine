import SwiftUI
import AppKit

/// Terminal.app's "Basic" profile, matching `TerminalStyle` on the AppKit side so the
/// report and the `code` windows are the same surface.
///
/// This replaced a CRT phosphor palette (green on near-black, with scanlines and a
/// glow). ANSI-ish accents are kept for the few line kinds that need to stand apart,
/// at the weights a real terminal would print them.
enum Phosphor {
    static let base    = Color.black
    static let dim     = Color(white: 0.42)
    static let section = Color(red: 0.00, green: 0.31, blue: 0.75)   // ANSI blue
    static let alert   = Color(red: 0.70, green: 0.00, blue: 0.00)   // ANSI red
    static let warn    = Color(red: 0.60, green: 0.36, blue: 0.00)   // ANSI yellow, darkened
    static let ok      = Color(red: 0.00, green: 0.45, blue: 0.10)   // ANSI green
    static let ground  = Color.white
    /// Highlighter yellow, for the lines a `focus` re-read points at.
    static let marker  = Color(red: 1.00, green: 0.90, blue: 0.20).opacity(0.85)
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
                titleBar
                stream
                statusBar
            }
        }
        .frame(minWidth: 780, minHeight: 520)
        .onReceive(cursorTimer) { _ in cursorOn.toggle() }
    }

    // MARK: title

    private var titleBar: some View {
        HStack(spacing: 8) {
            Spacer().frame(width: 68)          // room for the traffic lights
            Text("system_probe")
                .font(termFont(11, bold: true))
                .foregroundStyle(Phosphor.base)
            Text("— local disclosure terminal")
                .font(termFont(11))
                .foregroundStyle(Phosphor.dim)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(probe.plainText, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
            } label: {
                Text(copied ? "[ copied ]" : "[ copy report ]")
                    .font(termFont(11))
                    .foregroundStyle(copied ? Phosphor.ok : Phosphor.dim)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 14)
        }
        .frame(height: 30)
        .background(Color.black.opacity(0.45))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Phosphor.dim.opacity(0.4)), alignment: .bottom)
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
                    .font(termFont(line.kind == .banner ? 12 : 12, bold: line.kind == .banner || line.kind == .section))
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
        case .banner:  return Phosphor.base
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
