import AppKit
import SwiftUI

@main @MainActor
struct TypoBouncerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Typo Bouncer", systemImage: "text.badge.checkmark") {
            let model = delegate.model
            if model.coordinator.working {
                Text("Correcting…")
                Button("Cancel correction") { model.coordinator.cancel() }
            } else if model.coordinator.applying {
                Text("Applying…")
            } else {
                Text(model.modelStatus.title)
                Button("Correct text") { model.trigger() }
            }
            if model.coordinator.correctionStatus?.needsDetails == true {
                Button("Review correction…") { model.requestCorrectionReview() }
            }
            Divider()
            Button("Settings…") { delegate.showSettings() }.keyboardShortcut(",")
            Button("Quit Typo Bouncer") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q").disabled(model.coordinator.applying)
        }.menuBarExtraStyle(.menu)
    }
}
