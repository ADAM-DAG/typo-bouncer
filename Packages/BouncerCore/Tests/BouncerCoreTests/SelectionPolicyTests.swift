import Testing
@testable import BouncerCore

@Test func emptySelectionsAreRefused() {
    for text in ["", " \t\r\n", "\u{00a0}"] {
        #expect(throws: SelectionError.empty) { try SelectionPolicy().validate(text) }
    }
}

@Test func limitIsInclusive() throws {
    let policy = SelectionPolicy()
    try policy.validate(String(repeating: "a", count: 1_500))
    #expect(throws: SelectionError.tooLong(count: 1_501, limit: 1_500)) {
        try policy.validate(String(repeating: "a", count: 1_501))
    }
}

@Test func unicodeCharactersAreNotCountedAsUTF16Units() throws {
    let policy = SelectionPolicy(maximumCharacters: 250)
    for grapheme in ["👩🏽‍💻", "e\u{0301}", "🇳🇱"] {
        let text = String(repeating: grapheme, count: 250)
        #expect(text.count == 250)
        try policy.validate(text)
    }
}

@Test func corruptOrExtremeLimitsAreClamped() {
    #expect(SelectionPolicy(maximumCharacters: Int.min).maximumCharacters == 250)
    #expect(SelectionPolicy(maximumCharacters: Int.max).maximumCharacters == 5_000)
    #expect(SelectionPolicy().maximumCharacters == 1_500)
}


@Test func globalShortcutsRequireARealKeyAndIntentionalModifiers() {
    #expect(HotkeyShortcut.proofread.isValid)
    #expect(HotkeyShortcut(keyCode: 40, modifiers: 4096 | 2048).isValid)
    for shortcut in [HotkeyShortcut(keyCode: 36, modifiers: 0),
                     HotkeyShortcut(keyCode: 40, modifiers: 512),
                     HotkeyShortcut(keyCode: 55, modifiers: 256),
                     HotkeyShortcut(keyCode: UInt32.max, modifiers: 256),
                     HotkeyShortcut(keyCode: 40, modifiers: UInt32.max)] {
        #expect(!shortcut.isValid)
    }
}
