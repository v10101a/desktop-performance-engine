import AppKit
import Carbon.HIToolbox

/// The panic hotkey (⌘Esc): stop the show and put the desktop back, from anywhere,
/// at any point in the piece.
///
/// The Carbon plumbing moved to `HotKeyCenter` when the console key (⌃⌥⌘D) was added —
/// Carbon delivers every hotkey press to every installed handler, so a second handler
/// here would have made the console key panic. This is now a thin claim on one chord.
final class PanicController {
    private var token: HotKeyCenter.Token?

    var onPanic: (() -> Void)?

    func install() {
        guard token == nil else { return }
        token = HotKeyCenter.shared.register(
            key: HotKeys.panic.key,
            modifiers: HotKeys.panic.modifiers,
            signature: OSType(0x50414E43)          // 'PANC'
        ) { [weak self] in self?.onPanic?() }
    }

    func uninstall() {
        if let token { HotKeyCenter.shared.unregister(token) }
        token = nil
    }
}
