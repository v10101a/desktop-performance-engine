import AppKit

/// Tells a content view when its window is actually on screen — ordered in and not
/// wholly covered — so a timer-driven surface can idle until then.
///
/// `WindowManager.prewarm` builds every `openWindow` in the timeline at load, content
/// view included, and a view that starts its clock in `viewDidMoveToWindow` starts it
/// THEN: minutes before its cue, in a window nobody can see. Measured (2026-09-12, a
/// stack sample of the main thread through chorus 2A): the ASCII window map, scheduled
/// for the last three seconds of the piece, had been rebuilding twelve times a second
/// since load, and each rebuild asked the window server for the app's window order
/// thousands of times — 61% of the main thread, and the pump at 5 Hz under the
/// segmenter. Occlusion is the one signal that covers `orderFront`, `orderOut` and
/// being buried alike; `VideoContentView` watches it the same way.
final class WindowVisibility {
    private var observer: NSObjectProtocol?
    private(set) var visible = false
    private let onChange: (Bool) -> Void

    init(onChange: @escaping (Bool) -> Void) { self.onChange = onChange }

    /// Call from `viewDidMoveToWindow`. Reports the current state at once if it differs
    /// from the last, and again whenever it changes; no window is "not visible".
    func follow(_ window: NSWindow?) {
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        guard let window else { set(false); return }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            self?.set(window?.occlusionState.contains(.visible) ?? false)
        }
        set(window.occlusionState.contains(.visible))
    }

    private func set(_ now: Bool) {
        guard now != visible else { return }
        visible = now
        onChange(now)
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}
