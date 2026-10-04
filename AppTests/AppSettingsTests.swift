import AppKit
import BouncerCore
import Carbon
import XCTest
import ServiceManagement
@testable import TypoBouncer

@MainActor
final class AppSettingsTests: XCTestCase {
    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "TypoBouncerTests.\(UUID().uuidString)")!
    }

    func testFreshInstallStartsManualWithDefaultShortcut() {
        let settings = AppSettings(defaults: isolatedDefaults())
        XCTAssertEqual(settings.autoMode, .off)
        XCTAssertFalse(settings.selectFocusedText)
        XCTAssertFalse(settings.expandShorthand)
        XCTAssertEqual(settings.action, .proofread)
        XCTAssertEqual(settings.shortcut, .proofread)
        XCTAssertEqual(settings.correctionTrigger, .keyCombination)
    }

    func testCorrectionPreferencesAndCustomShortcutPersist() {
        let defaults = isolatedDefaults()
        let settings = AppSettings(defaults: defaults)
        let custom = HotkeyShortcut(keyCode: 8, modifiers: UInt32(controlKey | optionKey))
        settings.autoMode = .full; settings.expandShorthand = true; settings.selectFocusedText = true
        settings.action = .improveSentences; settings.shortcut = custom
        settings.correctionTrigger = .doubleControl
        settings.deniedApps = ["test.excluded.editor"]
        let loaded = AppSettings(defaults: defaults)
        XCTAssertEqual(loaded.autoMode, .full)
        XCTAssertTrue(loaded.expandShorthand)
        XCTAssertTrue(loaded.selectFocusedText)
        XCTAssertEqual(loaded.action, .improveSentences)
        XCTAssertEqual(loaded.shortcut, custom)
        XCTAssertEqual(loaded.correctionTrigger, .doubleControl)
        XCTAssertEqual(loaded.deniedApps, ["test.excluded.editor"])
    }

    func testFocusedFieldPreferenceCanBeDisabledWithoutChangingOtherOptions() {
        let defaults = isolatedDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.autoMode = .full; settings.correctionTrigger = .doubleControl
        settings.selectFocusedText = true
        XCTAssertTrue(AppSettings(defaults: defaults).selectFocusedText)
        settings.selectFocusedText = false
        let loaded = AppSettings(defaults: defaults)
        XCTAssertFalse(loaded.selectFocusedText)
        XCTAssertEqual(loaded.autoMode, .full)
        XCTAssertEqual(loaded.correctionTrigger, .doubleControl)
    }

    func testOldAutoMigratesOnceWithoutEnablingFullOrShorthand() {
        for legacy in [false, true] {
            let defaults = isolatedDefaults()
            defaults.set(legacy, forKey: "autoApply")
            let settings = AppSettings(defaults: defaults)
            XCTAssertEqual(settings.autoMode, legacy ? .clean : .off)
            XCTAssertFalse(settings.expandShorthand)
            XCTAssertNil(defaults.object(forKey: "autoApply"))
            settings.autoMode = .off
            XCTAssertEqual(AppSettings(defaults: defaults).autoMode, .off)
        }
    }

    func testObsoletePreferencesAreRemovedAndInvalidChoicesFallBack() throws {
        let defaults = isolatedDefaults()
        let obsolete = ["quickSide", "quickTrigger", "tapGap", "maximumSelectionCharacters"]
        for key in obsolete { defaults.set("unused", forKey: key) }
        defaults.set("format", forKey: "action")
        defaults.set("unexpected", forKey: "autoMode")
        defaults.set("unexpected", forKey: "correctionTrigger")
        defaults.set(try JSONEncoder().encode(HotkeyShortcut(keyCode: UInt32.max, modifiers: 0)), forKey: "shortcut")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.action, .proofread)
        XCTAssertEqual(settings.autoMode, .off)
        XCTAssertEqual(settings.shortcut, .proofread)
        XCTAssertEqual(settings.correctionTrigger, .keyCombination)
        for key in obsolete { XCTAssertNil(defaults.object(forKey: key)) }
    }

    func testEachTriggerPersistsWithoutReplacingBackupShortcut() {
        let defaults = isolatedDefaults()
        let settings = AppSettings(defaults: defaults)
        let backup = HotkeyShortcut(keyCode: 40, modifiers: UInt32(controlKey | optionKey))
        settings.shortcut = backup
        for trigger in CorrectionTrigger.allCases {
            settings.correctionTrigger = trigger
            let loaded = AppSettings(defaults: defaults)
            XCTAssertEqual(loaded.correctionTrigger, trigger)
            XCTAssertEqual(loaded.shortcut, backup)
        }
    }

    func testOldModifierPreferenceDoesNotOptIntoKeyboardListening() {
        let defaults = isolatedDefaults()
        defaults.set("control", forKey: "quickTrigger")
        XCTAssertEqual(AppSettings(defaults: defaults).correctionTrigger, .keyCombination)
    }

    func testCorruptShortcutDataDoesNotBreakSettings() {
        let defaults = isolatedDefaults()
        defaults.set(Data([0, 1, 2]), forKey: "shortcut")
        XCTAssertEqual(AppSettings(defaults: defaults).shortcut, .proofread)
    }
}

@MainActor final class ShortcutTests: XCTestCase {
    private func event(key: UInt16, modifiers: NSEvent.ModifierFlags, repeated: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil, characters: "k",
            charactersIgnoringModifiers: "k", isARepeat: repeated, keyCode: key)!
    }

    func testRecorderAcceptsCustomCombinationsAndRejectsTypingAndRepeats() {
        let input = event(key: 40, modifiers: [.control, .option, .shift])
        XCTAssertEqual(ShortcutNames.shortcut(from: input), HotkeyShortcut(keyCode: 40, modifiers: UInt32(controlKey | optionKey | shiftKey)))
        XCTAssertNil(ShortcutNames.shortcut(from: event(key: 40, modifiers: [])))
        XCTAssertNil(ShortcutNames.shortcut(from: event(key: 40, modifiers: [.shift])))
        XCTAssertNil(ShortcutNames.shortcut(from: event(key: 40, modifiers: [.command], repeated: true)))
        XCTAssertNil(ShortcutNames.shortcut(from: event(key: 36, modifiers: [])))
    }

    func testShortcutLabelsKeepAllChosenModifiers() {
        XCTAssertEqual(ShortcutNames.label(HotkeyShortcut(keyCode: 49, modifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey))), "⌃⌥⇧⌘Space")
    }

    func testConflictingReplacementKeepsPreviousHotkeyRegistered() throws {
        // No keys are sent. Use uncommon modified function keys to test Carbon ownership.
        let modifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        let occupied = HotkeyShortcut(keyCode: 79, modifiers: modifiers)
        let previous = HotkeyShortcut(keyCode: 80, modifiers: modifiers)
        let owner = GlobalHotkey(action: {})
        let editing = GlobalHotkey(action: {})
        let probe = GlobalHotkey(action: {})
        defer { owner.unregister(); editing.unregister(); probe.unregister() }
        guard owner.register(occupied), editing.register(previous) else {
            throw XCTSkip("Synthetic shortcut combinations are already reserved")
        }
        XCTAssertFalse(editing.register(occupied))
        XCTAssertFalse(probe.register(previous), "The old shortcut must survive a failed change")
        XCTAssertTrue(editing.register(previous), "Registering the current shortcut should be a no-op")
        owner.unregister()
        XCTAssertTrue(editing.register(occupied), "A free combination should replace the previous one")
        XCTAssertTrue(probe.register(previous), "A successful change must release the previous shortcut")
        XCTAssertFalse(owner.register(occupied))
    }
}


@MainActor final class ModifierEventTests: XCTestCase {
    // Synthetic event values are fed directly to the adapter, never posted to macOS.
    private func event(_ type: CGEventType = .flagsChanged, at time: Double, down: Bool = false,
                       trigger: CorrectionTrigger = .doubleControl) -> CGEvent {
        let event = CGEvent(source: nil)!
        event.type = type
        event.timestamp = UInt64(time * 1_000_000_000)
        event.setIntegerValueField(.keyboardEventKeycode, value: trigger == .doubleFunction ? 63 : 59)
        event.flags = CGEventFlags(rawValue: down ? trigger.modifierFlag : 0)
        return event
    }

    private func observe(_ event: CGEvent, trigger: CorrectionTrigger = .doubleControl,
                         detector: inout ModifierDoubleTapDetector) -> Bool {
        ModifierDoubleTap.observe(event.type, event: event, trigger: trigger, context: 42, detector: &detector)
    }

    func testNativeModifierEventsTriggerOnReleaseWithoutChangingEventData() {
        for trigger in [CorrectionTrigger.doubleControl, .doubleFunction] {
            var detector = ModifierDoubleTapDetector()
            for (time, down, expected) in [(1.0, true, false), (1.06, false, false), (1.2, true, false), (1.26, false, true)] {
                let event = event(at: time, down: down, trigger: trigger)
                let before = event.data as Data?
                XCTAssertEqual(observe(event, trigger: trigger, detector: &detector), expected)
                XCTAssertEqual(event.data as Data?, before)
            }
        }
    }

    func testTypingClicksDraggingAndScrollingInterruptDoubleTap() {
        for interruption in [CGEventType.keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                             .scrollWheel, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged] {
            var detector = ModifierDoubleTapDetector()
            XCTAssertFalse(observe(event(at: 1, down: true), detector: &detector))
            XCTAssertFalse(observe(event(at: 1.06), detector: &detector))
            XCTAssertFalse(observe(event(interruption, at: 1.1), detector: &detector))
            XCTAssertFalse(observe(event(at: 1.2, down: true), detector: &detector))
            XCTAssertFalse(observe(event(at: 1.26), detector: &detector))
            XCTAssertFalse(observe(event(at: 1.4, down: true), detector: &detector))
            XCTAssertTrue(observe(event(at: 1.46), detector: &detector))
        }
    }

    func testKeyCombinationModeDoesNotStartAListener() {
        let listener = ModifierDoubleTap(action: { XCTFail("Disabled double-taps must not fire") })
        XCTAssertFalse(listener.start(.keyCombination))
        XCTAssertFalse(listener.isRunning)
        listener.stop()
        XCTAssertFalse(listener.isRunning)
    }
}

@MainActor final class LaunchAtLoginTests: XCTestCase {
    func testInitialStatusAndRefreshNeverRegisterAutomatically() {
        var status = SMAppService.Status.notRegistered
        let login = LaunchAtLogin(readStatus: { status },
            register: { XCTFail("Only an explicit toggle may register") },
            unregister: { XCTFail("Only an explicit toggle may unregister") })
        XCTAssertFalse(login.isOn)
        status = .enabled
        login.refresh()
        XCTAssertTrue(login.isOn)
        status = .notRegistered
        login.refresh()
        XCTAssertFalse(login.isOn)
    }

    func testExplicitToggleHandlesApprovalAndDisablingPendingRegistration() {
        var status = SMAppService.Status.notRegistered
        var registrations = 0
        var removals = 0
        let login = LaunchAtLogin(readStatus: { status },
            register: { registrations += 1; status = .requiresApproval },
            unregister: { removals += 1; status = .notRegistered })
        login.setEnabled(true)
        XCTAssertTrue(login.isOn)
        XCTAssertTrue(login.needsApproval)
        login.setEnabled(true)
        XCTAssertEqual(registrations, 1)
        login.setEnabled(false)
        XCTAssertFalse(login.isOn)
        XCTAssertEqual(removals, 1)
    }

    func testFailedChangesKeepSystemStateAndCanBeRetried() {
        enum Failure: Error { case denied }
        var status = SMAppService.Status.notRegistered
        var fail = true
        let login = LaunchAtLogin(readStatus: { status },
            register: { if fail { throw Failure.denied }; status = .enabled },
            unregister: { throw Failure.denied })
        login.setEnabled(true)
        XCTAssertFalse(login.isOn)
        XCTAssertNotNil(login.errorMessage)
        fail = false
        login.setEnabled(true)
        XCTAssertTrue(login.isOn)
        XCTAssertNil(login.errorMessage)
        login.setEnabled(false)
        XCTAssertTrue(login.isOn)
        XCTAssertNotNil(login.errorMessage)
        status = .notFound
        login.refresh()
        XCTAssertFalse(login.isOn)
    }
}
