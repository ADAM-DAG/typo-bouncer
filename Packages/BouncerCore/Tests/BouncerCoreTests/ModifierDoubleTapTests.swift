import Testing
@testable import BouncerCore

private func update(_ detector: inout ModifierDoubleTapDetector, trigger: CorrectionTrigger, keyCode: UInt16,
                    flags: UInt64, timestamp: Double, context: Int32) -> Bool {
    detector.update(trigger: trigger, keyCode: keyCode, flags: flags, timestamp: timestamp, context: context)
}

private func tap(_ detector: inout ModifierDoubleTapDetector, trigger: CorrectionTrigger = .doubleControl,
                 key: UInt16 = 59, at time: Double, hold: Double = 0.06, context: Int32 = 1,
                 additionalFlags: UInt64 = 0) -> Bool {
    #expect(!update(&detector, trigger: trigger, keyCode: key, flags: trigger.modifierFlag | additionalFlags,
                            timestamp: time, context: context))
    return detector.update(trigger: trigger, keyCode: key, flags: additionalFlags,
                           timestamp: time + hold, context: context)
}

@Test func doubleTapsFireOnlyAfterTwoCompletePresses() {
    for (trigger, key) in [(CorrectionTrigger.doubleFunction, UInt16(63)), (.doubleControl, 59), (.doubleControl, 62)] {
        var detector = ModifierDoubleTapDetector()
        #expect(!tap(&detector, trigger: trigger, key: key, at: 1))
        #expect(tap(&detector, trigger: trigger, key: key, at: 1.2))
    }
}

@Test func modifierChordsAndWrongKeysNeverTrigger() {
    for extra: UInt64 in [1 << 17, 1 << 19, 1 << 20, 1 << 23] {
        var detector = ModifierDoubleTapDetector()
        #expect(!tap(&detector, at: 1, additionalFlags: extra))
        #expect(!tap(&detector, at: 1.2, additionalFlags: extra))
        #expect(!tap(&detector, at: 1.4))
    }
    for (trigger, key) in [(CorrectionTrigger.keyCombination, UInt16(59)), (.doubleFunction, 59), (.doubleControl, 63)] {
        var detector = ModifierDoubleTapDetector()
        #expect(!tap(&detector, trigger: trigger, key: key, at: 1))
        #expect(!tap(&detector, trigger: trigger, key: key, at: 1.2))
    }
}

@Test func interruptionAndContextChangeCancelFirstTap() {
    var detector = ModifierDoubleTapDetector()
    #expect(!tap(&detector, at: 1))
    detector.reset()
    #expect(!tap(&detector, at: 1.2))
    #expect(!tap(&detector, at: 1.4, context: 2))
    #expect(tap(&detector, at: 1.6, context: 2))
}

@Test func alternatingControlKeysCannotCombine() {
    var detector = ModifierDoubleTapDetector()
    #expect(!tap(&detector, key: 59, at: 1))
    #expect(!tap(&detector, key: 62, at: 1.2))
    #expect(!tap(&detector, key: 59, at: 1.4))
    #expect(tap(&detector, key: 59, at: 1.6))
}

@Test func longHoldsBouncesAndSlowGapsAreRejected() {
    for hold in [0.001, 0.4] {
        var detector = ModifierDoubleTapDetector()
        #expect(!tap(&detector, at: 1, hold: hold))
        #expect(!tap(&detector, at: 1.5))
    }
    var detector = ModifierDoubleTapDetector()
    #expect(!tap(&detector, at: 1))
    #expect(!tap(&detector, at: 1.5))
    #expect(tap(&detector, at: 1.7))
    detector.reset()
    #expect(!tap(&detector, at: 2))
    #expect(!tap(&detector, at: 2.2, hold: 0.4))
    #expect(!tap(&detector, at: 2.8))
}

@Test func rapidTripleAndQuadrupleTapsTriggerOnlyOnce() {
    var detector = ModifierDoubleTapDetector()
    #expect(!tap(&detector, at: 1))
    #expect(tap(&detector, at: 1.2))
    #expect(!tap(&detector, at: 1.4))
    #expect(!tap(&detector, at: 1.6))
    #expect(!tap(&detector, at: 2.1))
    #expect(tap(&detector, at: 2.3))
}

@Test func strayReleasesAndInvalidTimestampsDoNotTrigger() {
    for time in [0.5, 1.06, Double.nan, Double.infinity] {
        var detector = ModifierDoubleTapDetector()
        #expect(!tap(&detector, at: 1))
        #expect(!update(&detector, trigger: .doubleControl, keyCode: 59, flags: 1 << 18, timestamp: time, context: 1))
        #expect(!update(&detector, trigger: .doubleControl, keyCode: 59, flags: 0, timestamp: 1.3, context: 1))
        #expect(!tap(&detector, at: 1.5))
    }
    var detector = ModifierDoubleTapDetector()
    #expect(!update(&detector, trigger: .doubleControl, keyCode: 59, flags: 0, timestamp: 1, context: 1))
    #expect(!tap(&detector, at: 1.2))
    #expect(!update(&detector, trigger: .doubleControl, keyCode: 59, flags: 0, timestamp: 1.3, context: 1))
    #expect(!tap(&detector, at: 1.5))
}

@Test func duplicateDownChangesCancelAndCapsLockIsIgnored() {
    var detector = ModifierDoubleTapDetector()
    #expect(!update(&detector, trigger: .doubleControl, keyCode: 59, flags: 1 << 18, timestamp: 1, context: 1))
    #expect(!update(&detector, trigger: .doubleControl, keyCode: 59, flags: 1 << 18, timestamp: 1.02, context: 1))
    #expect(!update(&detector, trigger: .doubleControl, keyCode: 59, flags: 0, timestamp: 1.06, context: 1))
    #expect(!tap(&detector, at: 1.2, additionalFlags: 1 << 16))
    #expect(tap(&detector, at: 1.4, additionalFlags: 1 << 16))
}
