import SwiftUI

enum LineKind {
    case banner, section, key, plain, dim, ok, warn, alert, prompt, rule
}

struct TermLine: Identifiable {
    let id = UUID()
    var label: String?
    var text: String
    var kind: LineKind = .plain
    var pause: Int = 0          // extra reveal ticks before this line
}

func kv(_ label: String, _ value: String?, kind: LineKind = .plain) -> TermLine {
    if let v = value, !v.isEmpty {
        return TermLine(label: label, text: v, kind: kind)
    }
    return TermLine(label: label, text: "<unavailable>", kind: .dim)
}

func section(_ title: String) -> [TermLine] {
    [
        TermLine(text: "", kind: .plain, pause: 6),
        TermLine(text: "┌─ " + title.uppercased() + " " + String(repeating: "─", count: max(2, 58 - title.count)), kind: .section, pause: 4)
    ]
}

func note(_ s: String) -> TermLine { TermLine(text: s, kind: .dim) }
func warn(_ s: String) -> TermLine { TermLine(text: s, kind: .warn) }
func ok(_ s: String) -> TermLine { TermLine(text: s, kind: .ok) }

// MARK: - formatting helpers

func bytes(_ n: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowsNonnumericFormatting = false
    return f.string(fromByteCount: n)
}

func bytes(_ n: UInt64) -> String { bytes(Int64(clamping: n)) }

func pct(_ x: Double) -> String { String(format: "%.1f%%", x * 100) }

func bar(_ fraction: Double, width: Int = 24) -> String {
    let f = min(max(fraction, 0), 1)
    let filled = Int((Double(width) * f).rounded())
    return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
}

func duration(_ seconds: TimeInterval) -> String {
    let s = Int(seconds)
    let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if d > 0 { return "\(d)d \(h)h \(m)m" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m \(s % 60)s"
}

func stamp(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZ"
    return f.string(from: d)
}
