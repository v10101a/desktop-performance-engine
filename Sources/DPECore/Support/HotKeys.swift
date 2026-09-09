import AppKit
import Carbon.HIToolbox

/// Global hotkeys, registered through Carbon.
///
/// `RegisterEventHotKey` fires even when the app is in the background and — unlike an
/// NSEvent global monitor — needs no Accessibility permission. That matters twice here:
/// the panic key has to work while the show owns the screen, and the console key has to
/// work when nothing of ours is key, which during the show is always (every effect
/// window deliberately refuses key focus).
///
/// **One handler for the whole process, dispatching on the hotkey id.** Carbon hands
/// every hotkey press to every handler installed on the target, so two controllers each
/// installing their own handler would each fire for *both* keys — ⌃⌥⌘D would panic. The
/// registry is here so that cannot be written by accident.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    /// A registration, kept so it can be handed back to `unregister`.
    struct Token { let id: UInt32 }

    private var eventHandler: EventHandlerRef?
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1

    private init() {}

    /// Register `key` (a `kVK_` virtual keycode) with `modifiers`. Returns nil if macOS
    /// refused the registration — which it does when another app already owns the chord.
    @discardableResult
    func register(key: Int, modifiers: UInt32, signature: OSType,
                  action: @escaping () -> Void) -> Token? {
        installHandler()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(key), modifiers,
                                         EventHotKeyID(signature: signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("[DPE] hotkey: registration refused (status \(status)) — chord already taken?")
            return nil
        }
        refs[id] = ref
        actions[id] = action
        return Token(id: id)
    }

    func unregister(_ token: Token) {
        if let ref = refs.removeValue(forKey: token.id) { UnregisterEventHotKey(ref) }
        actions.removeValue(forKey: token.id)
    }

    /// Runs the action for one press. Internal rather than private so the dispatch can
    /// be tested without a real key event.
    func fire(id: UInt32) { actions[id]?() }

    /// How many chords are live. Only the tests read this.
    var registrationCount: Int { refs.count }

    private func installHandler() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: OSType(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { (_, event, userData) -> OSStatus in
            guard let userData, let event else { return noErr }
            var hotKeyID = EventHotKeyID()
            let ok = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                       EventParamType(typeEventHotKeyID), nil,
                                       MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard ok == noErr else { return noErr }
            let me = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            let id = hotKeyID.id
            DispatchQueue.main.async { me.fire(id: id) }
            return noErr
        }, 1, &spec, selfPtr, &eventHandler)
    }
}

/// The chords the piece claims. Both are deliberately three-modifier combinations: a
/// two-modifier chord collides with things people actually use, and macOS owns most of
/// the ⌘⌥ space already.
enum HotKeys {
    /// ⌃⌥⌘Esc — stop everything and put the desktop back. Documented to the viewer.
    static let panic = (key: kVK_Escape, modifiers: UInt32(controlKey | optionKey | cmdKey))

    /// ⌃⌥⌘D — reveal or hide the transport window. NOT documented to the viewer: the
    /// console is an instrument for whoever is running the piece, and a visible control
    /// panel is the one thing that would tell the room this is a piece of software
    /// rather than the machine coming apart.
    static let console = (key: kVK_ANSI_D, modifiers: UInt32(controlKey | optionKey | cmdKey))
}
