public enum CorrectionTrigger: String, CaseIterable, Sendable {
    case keyCombination, doubleFunction, doubleControl

    public var modifierFlag: UInt64 {
        switch self {
        case .keyCombination: 0
        case .doubleFunction: 1 << 23
        case .doubleControl: 1 << 18
        }
    }

    public func accepts(keyCode: UInt16) -> Bool {
        switch self {
        case .keyCombination: false
        case .doubleFunction: keyCode == 63
        case .doubleControl: keyCode == 59 || keyCode == 62
        }
    }
}

/// Two complete, isolated presses of the same physical modifier. Stores only
/// timing/key identity; normal key events interrupt it without reading their text.
public struct ModifierDoubleTapDetector: Sendable {
    private enum Phase: Sendable { case idle, firstDown(Double), firstUp(Double), secondDown(Double), cooldown(Double) }
    private var phase: Phase = .idle
    private var physicalKey: UInt16?
    private var context: Int32?
    private var lastTimestamp: Double?
    private let maximumGap = 0.35
    private let maximumHold = 0.30
    private let minimumHold = 0.015

    public init() { }

    public mutating func reset() {
        phase = .idle; physicalKey = nil; context = nil; lastTimestamp = nil
    }

    public mutating func update(trigger: CorrectionTrigger, keyCode: UInt16, flags: UInt64,
                                timestamp: Double, context: Int32) -> Bool {
        // Ignore Caps Lock and device-specific side bits, but reject modifier chords.
        let relevant: UInt64 = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20) | (1 << 23)
        let held = flags & relevant
        guard timestamp.isFinite, trigger.accepts(keyCode: keyCode),
              held == 0 || held == trigger.modifierFlag else { reset(); return false }
        if self.context != context || physicalKey != keyCode {
            reset(); self.context = context; physicalKey = keyCode
        }
        if let lastTimestamp, timestamp <= lastTimestamp { reset(); return false }
        lastTimestamp = timestamp
        let down = held == trigger.modifierFlag
        switch phase {
        case .idle:
            if down { phase = .firstDown(timestamp) }
        case .firstDown(let start):
            guard !down, (minimumHold...maximumHold).contains(timestamp - start) else { reset(); return false }
            phase = .firstUp(timestamp)
        case .firstUp(let released):
            guard down else { reset(); return false }
            phase = timestamp - released <= maximumGap ? .secondDown(timestamp) : .firstDown(timestamp)
        case .secondDown(let start):
            guard !down, (minimumHold...maximumHold).contains(timestamp - start) else { reset(); return false }
            phase = .cooldown(timestamp)
            return true
        case .cooldown(let released):
            if down && timestamp - released > maximumGap { phase = .firstDown(timestamp) }
            else if !down { phase = .cooldown(timestamp) }
        }
        return false
    }
}
