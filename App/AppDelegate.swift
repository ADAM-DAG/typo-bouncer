import AppKit
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private(set) var settingsWindow: NSWindow?
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              let identifier = Bundle.main.bundleIdentifier else { return }
        let current = NSRunningApplication.current
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { !$0.isTerminated && $0.processIdentifier != current.processIdentifier }
        let own = AppInstance(pid: current.processIdentifier, launched: current.launchDate ?? .distantFuture)
        let peers = apps.map { AppInstance(pid: $0.processIdentifier, launched: $0.launchDate ?? .distantFuture) }
        guard let peer = SingleInstancePolicy.existingInstance(current: own, peers: peers),
              let existing = apps.first(where: { $0.processIdentifier == peer.pid }) else { return }
        existing.activate(options: [])
        NSApplication.shared.terminate(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 550),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = String(localized: "Typo Bouncer Settings")
            window.identifier = NSUserInterfaceItemIdentifier("com_apple_SwiftUI_Settings_window")
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Finish clipboard restoration and update preparation before exiting.
        (model.coordinator.applying || !model.updater.mayTerminate) ? .terminateCancel : .terminateNow
    }
}
