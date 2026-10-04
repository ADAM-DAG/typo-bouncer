public enum AutoMode: String, CaseIterable, Sendable {
    case off, clean, full

    public func usesCompactFeedback(for command: Command) -> Bool {
        self == .full || (self == .clean && command == .proofread)
    }
}
