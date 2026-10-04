import BouncerCore
import Carbon

@MainActor
final class GlobalHotkey {
    private static var nextID: UInt32 = 1
    private let id: UInt32
    private var hotkey: EventHotKeyRef?
    private var shortcut: HotkeyShortcut?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        id = Self.nextID
        Self.nextID &+= 1
        self.action = action
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var received = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &received)
            guard status == noErr else { return status }
            return MainActor.assumeIsolated {
                let owner = Unmanaged<GlobalHotkey>.fromOpaque(context).takeUnretainedValue()
                guard received.signature == 0x54425052 && received.id == owner.id else { return OSStatus(eventNotHandledErr) }
                owner.action()
                return noErr
            }
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    @discardableResult
    func register(_ shortcut: HotkeyShortcut) -> Bool {
        guard shortcut.isValid, handler != nil else { return false }
        if self.shortcut == shortcut, hotkey != nil { return true }
        let identity = EventHotKeyID(signature: 0x54425052, id: id)
        var candidate: EventHotKeyRef?
        guard RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, identity,
            GetApplicationEventTarget(), 0, &candidate) == noErr else { return false }
        unregister()
        hotkey = candidate; self.shortcut = shortcut
        return true
    }

    func unregister() {
        if let hotkey { UnregisterEventHotKey(hotkey) }
        hotkey = nil; shortcut = nil
    }

    isolated deinit {
        if let hotkey { UnregisterEventHotKey(hotkey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
