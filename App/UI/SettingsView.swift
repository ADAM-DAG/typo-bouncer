import AppKit
import BouncerCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var showExcludedApps = false
    @State private var showActionHelp = false

    var body: some View {
        @Bindable var settings = model.settings
        @Bindable var updater = model.updater
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Keyboard shortcut") {
                    Picker("Trigger", selection: $settings.correctionTrigger) {
                        ForEach(CorrectionTrigger.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.help("Tap and release the same key twice. If Fn also opens Dictation, change its shortcut in macOS Keyboard settings.")
                    if settings.correctionTrigger != .keyCombination {
                        if model.doubleTapUnavailable {
                            HStack {
                                Text("Keyboard access is needed for double-tap.").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Allow keyboard access…") { model.requestDoubleTapAccess() }
                            }
                        }
                    }
                    HStack {
                        Text(settings.correctionTrigger == .keyCombination ? "Shortcut" : "Backup shortcut")
                        Spacer()
                        Button {
                            model.beginRecording()
                        } label: {
                            Text(model.recordingShortcut ? String(localized: "Press your shortcut…") : ShortcutNames.label(settings.shortcut))
                                .font(.system(.body, design: .monospaced)).frame(minWidth: 90)
                        }
                        .accessibilityLabel("Change correction shortcut")
                        .accessibilityValue(model.recordingShortcut ? String(localized: "Recording") : ShortcutNames.label(settings.shortcut))
                        .help("Click, then press the key combination you want to use.")
                        if model.recordingShortcut {
                            Button("Cancel") { model.stopRecording() }
                        } else if settings.shortcut != .proofread {
                            Button("Reset") { model.setShortcut(.proofread) }.controlSize(.small)
                        }
                    }
                    if let message = model.shortcutMessage {
                        Text(message).foregroundStyle(.orange).font(.caption)
                    } else if model.shortcutConflict {
                        Text("Your shortcut is in use. Click it to choose another.").foregroundStyle(.orange).font(.caption)
                    } else if model.recordingShortcut {
                        Text("Include ⌘, ⌃ or ⌥. Escape cancels.")
                            .foregroundStyle(.secondary).font(.caption)
                    }
                }
                Section("Corrections") {
                    HStack(spacing: 6) {
                        Text("Action")
                        Button { showActionHelp.toggle() } label: {
                            Image(systemName: "info.circle")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("About correction actions")
                        .help("Learn about Proofread and Improve sentences.")
                        .popover(isPresented: $showActionHelp, arrowEdge: .trailing) {
                            actionHelp
                        }
                        Spacer()
                        Picker("Action", selection: $settings.action) {
                            Text("Proofread").tag(Command.proofread)
                            Text("Improve sentences").tag(Command.improveSentences)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Picker("Auto mode", selection: $settings.autoMode) {
                        ForEach(AutoMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .help(settings.autoMode.detail)
                    Toggle("Select text when nothing is selected", isOn: $settings.selectFocusedText)
                        .help("Select all text in the focused editable field when you use your shortcut with no selection.")
                    Toggle("Expand chat shorthand", isOn: $settings.expandShorthand)
                        .help("“idk” becomes “I don't know”.")
                }
                Section {
                    Toggle("Launch at login", isOn: Binding(
                        get: { model.launchAtLogin.isOn },
                        set: { model.launchAtLogin.setEnabled($0) }
                    ))
                    .help("Start Typo Bouncer quietly in the menu bar when you log in to your Mac.")
                    if model.launchAtLogin.needsApproval {
                        Text("Allow Typo Bouncer in Login Items to finish enabling launch at login.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let message = model.launchAtLogin.errorMessage {
                        Text(message).font(.caption).foregroundStyle(.orange)
                    }
                    if model.launchAtLogin.needsApproval || model.launchAtLogin.errorMessage != nil {
                        Button("Open Login Items…") { model.launchAtLogin.openSystemSettings() }
                    }
                }
                Section("Updates") {
                    if model.updater.isReleaseInstall {
                        Toggle("Check for updates automatically", isOn: $updater.automaticChecks)
                            .help("Check GitHub once a day. Updates install only when you choose Update and relaunch.")
                        HStack {
                            Text(model.updater.status).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if model.updater.phase == .checking || model.updater.phase == .downloading {
                                Button("Cancel") { model.updater.cancel() }
                            } else if model.updater.available != nil {
                                Button("Update and relaunch") {
                                    model.stopRecording()
                                    model.updater.install { !model.coordinator.working && !model.coordinator.applying }
                                }
                                .disabled(model.updater.busy || model.coordinator.working || model.coordinator.applying)
                            } else {
                                Button("Check now") { model.updater.check() }.disabled(model.updater.busy)
                            }
                        }
                    } else {
                        Text(model.updater.status).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Other apps") {
                    HStack {
                        Label(model.accessibility.isTrusted ? "Access allowed" : "Access needed",
                              systemImage: model.accessibility.isTrusted ? "checkmark.circle.fill" : "hand.raised")
                            .foregroundStyle(model.accessibility.isTrusted ? Color.secondary : .primary)
                        Spacer()
                        if !model.accessibility.isTrusted {
                            Button("Allow access…") { model.accessibility.request() }
                        }
                    }
                    DisclosureGroup("Excluded apps", isExpanded: $showExcludedApps) {
                        ForEach(settings.deniedApps, id: \.self) { identifier in
                            HStack {
                                Text(appName(identifier)).help(identifier)
                                Spacer()
                                Button {
                                    settings.deniedApps.removeAll { $0 == identifier }
                                } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                .accessibilityLabel("Remove \(appName(identifier)) from excluded apps")
                            }
                        }
                        Button("Add app…", action: chooseExcludedApp)
                    }
                }
            }.formStyle(.grouped)
            if model.modelStatus != .ready {
                Text(model.modelStatus.detail).font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.bottom, 16)
            }
        }.frame(width: 520, height: 550)
            .onChange(of: settings.correctionTrigger) { model.stopRecording(); model.configureShortcut() }
            .onAppear { model.launchAtLogin.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                model.configureShortcut(); model.launchAtLogin.refresh()
            }
            .onDisappear { model.stopRecording() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in model.stopRecording() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
                if (note.object as? NSWindow)?.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" { model.stopRecording() }
            }
    }

    private var actionHelp: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Proofread").fontWeight(.semibold)
                Text("Fixes spelling, grammar, punctuation and capitalization with minimal wording changes.")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Improve sentences").fontWeight(.semibold)
                Text("Also rewrites awkward wording, word order and run-on sentences for clearer flow, while keeping your meaning and tone.")
            }
            Divider()
            Text("Both use Apple’s on-device AI plus local checks. Your text stays on this Mac. AI can miss mistakes or misread names, so review important text.")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(18)
        .frame(width: 350)
    }

    private func appName(_ identifier: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)?
            .deletingPathExtension().lastPathComponent ?? identifier
    }

    private func chooseExcludedApp() {
        guard let window = NSApplication.shared.keyWindow else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(filePath: "/Applications")
        panel.prompt = String(localized: "Exclude app")
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url, let identifier = Bundle(url: url)?.bundleIdentifier,
                  !model.settings.deniedApps.contains(identifier) else { return }
            model.settings.deniedApps.append(identifier)
        }
    }
}
