public struct HotkeyShortcut: Codable, Equatable, Sendable {
    public let keyCode: UInt32
    public let modifiers: UInt32
    public init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }
    /// Carbon modifier bits: Command, Shift, Option and Control. Plain typing keys
    /// and modifier-only events must never become a global correction trigger.
    public var isValid: Bool {
        let allowed: UInt32 = 256 | 512 | 2048 | 4096
        let required: UInt32 = 256 | 2048 | 4096
        let modifiersOnly: Set<UInt32> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        return keyCode <= 126 && !modifiersOnly.contains(keyCode)
            && modifiers & required != 0 && modifiers & ~allowed == 0
    }
    public static let proofread = HotkeyShortcut(keyCode: 5, modifiers: 256 | 4096)
}
