import AppKit
import BouncerCore
import Carbon

@MainActor
enum ShortcutNames {
    static func label(_ shortcut: HotkeyShortcut) -> String {
        var prefix = ""
        if shortcut.modifiers & UInt32(controlKey) != 0 { prefix += "⌃" }
        if shortcut.modifiers & UInt32(optionKey) != 0 { prefix += "⌥" }
        if shortcut.modifiers & UInt32(shiftKey) != 0 { prefix += "⇧" }
        if shortcut.modifiers & UInt32(cmdKey) != 0 { prefix += "⌘" }
        let known: [UInt32: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        if let key = known[shortcut.keyCode] { return prefix + key }
        let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return prefix + "Key \(shortcut.keyCode)" }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        let layout = unsafeBitCast(CFDataGetBytePtr(data), to: UnsafePointer<UCKeyboardLayout>.self)
        var deadKey: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(layout, UInt16(shortcut.keyCode), UInt16(kUCKeyActionDisplay), 0,
                                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKey,
                                    characters.count, &length, &characters)
        guard status == noErr, length > 0 else { return prefix + "Key \(shortcut.keyCode)" }
        return prefix + String(utf16CodeUnits: characters, count: length).uppercased()
    }

    static func shortcut(from event: NSEvent) -> HotkeyShortcut? {
        guard event.type == .keyDown, !event.isARepeat else { return nil }
        let flags = event.modifierFlags
        guard flags.contains(.control) || flags.contains(.option) || flags.contains(.command) else { return nil }
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        let shortcut = HotkeyShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        return shortcut.isValid ? shortcut : nil
    }
}
