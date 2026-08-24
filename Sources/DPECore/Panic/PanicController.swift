import AppKit
import Carbon.HIToolbox

/// Registers a global panic hotkey (⌃⌥⌘Esc) via Carbon. RegisterEventHotKey works
/// even when the app is in the background and — unlike NSEvent global monitors —
/// does not require Accessibility permission.
final class PanicController {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    var onPanic: (() -> Void)?

    func install() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: OSType(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { (_, _, userData) -> OSStatus in
            if let userData = userData {
                let me = Unmanaged<PanicController>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { me.onPanic?() }
            }
            return noErr
        }, 1, &spec, selfPtr, &eventHandler)

        let hotKeyID = EventHotKeyID(signature: OSType(0x50414E43), id: 1) // 'PANC'
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        RegisterEventHotKey(UInt32(kVK_Escape), modifiers, hotKeyID,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func uninstall() {
        if let hotKeyRef = hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler = eventHandler { RemoveEventHandler(eventHandler) }
        hotKeyRef = nil
        eventHandler = nil
    }
}
