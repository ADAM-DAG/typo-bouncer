import SwiftUI

struct PermissionSetupView: View {
    let gate: AccessibilityGate
    var close: () -> Void
    @State private var checked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Use Typo Bouncer in other apps", systemImage: "hand.raised.fill").font(.headline)
            Text("Allow Device Control and Data Access so Typo Bouncer can correct selected text when you use your shortcut. Password fields and excluded apps are left alone.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                Text("Already enabled?").font(.subheadline.bold())
                Text("If the switch is on but access is still blocked, remove TypoBouncer from the permission list and add this copy again. A development update can leave an older permission behind.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(Bundle.main.bundleURL.path).font(.caption.monospaced())
                    .foregroundStyle(.secondary).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
            }.padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            if checked && !gate.isTrusted {
                Text("macOS still reports access as blocked for this copy. Re-add it, then quit and reopen Typo Bouncer.")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Close", action: close)
                Button("Check again") { checked = true; if gate.refresh() { close() } }
                Spacer()
                Button("Open permission settings") { gate.request() }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 580)
    }
}
