import AppKit
import SwiftUI
import XCTest
@testable import TypoBouncer

@MainActor final class PermissionTests: XCTestCase {
    func testReopeningUsesOneSettingsWindowWithoutCreatingAnEditor() {
        let delegate = AppDelegate()
        XCTAssertNil(delegate.settingsWindow)
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        let window = delegate.settingsWindow
        defer { window?.close() }
        XCTAssertNotNil(window)
        XCTAssertEqual(window?.identifier?.rawValue, "com_apple_SwiftUI_Settings_window")
        XCTAssertTrue(window?.contentView is NSHostingView<SettingsView>)
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true))
        XCTAssertTrue(delegate.settingsWindow === window)
    }
    func testRecheckReadsCurrentPermissionAndNotifiesOnlyOnChanges() {
        var allowed = false
        var checks = 0
        let gate = AccessibilityGate { checks += 1; return allowed }
        var changes = 0
        gate.onChange = { changes += 1 }
        XCTAssertFalse(gate.isTrusted)
        allowed = true
        XCTAssertTrue(gate.refresh())
        XCTAssertTrue(gate.isTrusted)
        XCTAssertEqual(changes, 1)
        XCTAssertTrue(gate.refresh())
        XCTAssertEqual(changes, 1)
        allowed = false
        XCTAssertFalse(gate.refresh())
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(checks, 4)
    }
    func testPermissionPanelMeasuresWrappedTextInsteadOfTruncatingIt() {
        let host = NSHostingView(rootView: PermissionSetupView(gate: AccessibilityGate { false }, close: {}))
        host.frame = NSRect(x: 0, y: 0, width: 580, height: 1)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.width, 580, accuracy: 1)
        XCTAssertGreaterThan(host.fittingSize.height, 250)
    }
    func testSecondCopyReusesOlderInstanceAndFirstRemainsAlive() {
        let older = AppInstance(pid: 10, launched: Date(timeIntervalSince1970: 1))
        let newer = AppInstance(pid: 11, launched: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(SingleInstancePolicy.existingInstance(current: newer, peers: [older])?.pid, 10)
        XCTAssertNil(SingleInstancePolicy.existingInstance(current: older, peers: [newer]))
        XCTAssertNil(SingleInstancePolicy.existingInstance(current: older, peers: []))
    }
    func testSimultaneousCopiesChooseSameInstance() {
        let time = Date(timeIntervalSince1970: 1)
        let first = AppInstance(pid: 10, launched: time)
        let second = AppInstance(pid: 11, launched: time)
        XCTAssertEqual(SingleInstancePolicy.existingInstance(current: second, peers: [first])?.pid, 10)
        XCTAssertNil(SingleInstancePolicy.existingInstance(current: first, peers: [second]))
    }
}
