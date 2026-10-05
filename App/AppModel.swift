import AppKit
import BouncerCore
import FoundationModels
import Observation

@MainActor @Observable
final class AppModel {
    let settings = AppSettings()
    let launchAtLogin = LaunchAtLogin()
    let updater = AppUpdater()
    let coordinator = ProofreadingCoordinator()
    let accessibility = AccessibilityGate()
    private let languageModel = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
    private(set) var shortcutConflict = false
    private(set) var recordingShortcut = false
    private(set) var doubleTapUnavailable = false
    private(set) var shortcutMessage: String?
    @ObservationIgnored private var recorder: Any?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var permissionPresenter: PermissionPresenter?
    @ObservationIgnored private var statusPresenter: CorrectionStatusPresenter?
    @ObservationIgnored private var reviewAction: Task<Void, Never>?
    @ObservationIgnored private var hotkey: GlobalHotkey?
    @ObservationIgnored private var doubleTap: ModifierDoubleTap?

    var modelStatus: ModelStatus { ModelStatus(availability: languageModel.availability) }

    func start() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        guard !started else { return }; started = true
        permissionPresenter = PermissionPresenter(model: self)
        statusPresenter = CorrectionStatusPresenter { [weak self] in self?.requestCorrectionReview() }
        hotkey = GlobalHotkey { [weak self] in self?.trigger() }
        doubleTap = ModifierDoubleTap { [weak self] in self?.trigger() }
        doubleTap?.unavailable = { [weak self] in self?.doubleTapUnavailable = true }
        coordinator.changed = { [weak self] in self?.refreshPreview() }
        accessibility.onChange = { [weak self] in
            guard let self else { return }
            self.configureShortcut()
            if self.accessibility.isTrusted { self.permissionPresenter?.hide() }
        }
        // Normal typing must not pass through app-owned NSEvent keyboard monitors.
        // Double-taps use an opt-in, passive Core Graphics listener.
        accessibility.start(); configureShortcut()
        coordinator.prewarm()
        updater.start()
    }

    func configureShortcut() {
        guard started, !recordingShortcut else { return }
        shortcutConflict = !(hotkey?.register(settings.shortcut) ?? false)
        if settings.correctionTrigger == .keyCombination {
            doubleTap?.stop(); doubleTapUnavailable = false
        } else {
            doubleTapUnavailable = !(doubleTap?.start(settings.correctionTrigger) ?? false)
        }
    }

    func requestDoubleTapAccess() {
        // Called only by the user's Allow keyboard access button, never on launch.
        _ = CGRequestListenEventAccess()
        configureShortcut()
    }

    func trigger() {
        let command = settings.action
        guard !coordinator.working, !coordinator.applying, reviewAction == nil,
              updater.phase != .relaunching else { return }
        statusPresenter?.hide()
        guard !NSApplication.shared.isActive else { return }
        guard accessibility.refresh() else { permissionPresenter?.show(); return }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        guard !settings.deniedApps.contains(app.bundleIdentifier ?? "") else {
            coordinator.externalMessage(AppFailure.deniedApp.message, command: command, mode: settings.autoMode, expandShorthand: settings.expandShorthand); return
        }
        coordinator.proofreadSelection(pid: app.processIdentifier, limit: SelectionPolicy.defaultLimit, command: command, mode: settings.autoMode, expandShorthand: settings.expandShorthand, appName: app.localizedName, selectFocusedText: settings.selectFocusedText)
    }

    private func refreshPreview() {
        guard let status = coordinator.correctionStatus else {
            statusPresenter?.hide(); return
        }
        let target = coordinator.statusTarget
        // Wait for capture before positioning feedback; avoid a corner-to-field jump.
        if status.busy && target == nil && coordinator.statusSourcePID != nil { statusPresenter?.hide(); return }
        let capture = coordinator.capture
        let follow: (@Sendable () async -> SelectionAnchor?)?
        if let target { follow = { await capture.presentationAnchor(for: target) } }
        else { follow = nil }
        let isCurrent: @MainActor () async -> Bool = { [weak coordinator] in
            await coordinator?.validateStatusTarget() ?? false
        }
        if coordinator.reviewRequested && !coordinator.working && !coordinator.applying {
            statusPresenter?.showReview(coordinator: coordinator, anchor: coordinator.statusAnchor,
                sourcePID: coordinator.statusSourcePID, follow: follow, isCurrent: isCurrent,
                apply: { [weak self] in self?.applyReviewedCorrection() },
                collapse: { [weak self] in self?.collapseCorrectionReview() })
        } else {
            statusPresenter?.show(status, anchor: coordinator.statusAnchor, sourcePID: coordinator.statusSourcePID, follow: follow, isCurrent: isCurrent)
        }
    }

    private func applyReviewedCorrection() {
        guard coordinator.canApply, reviewAction == nil, let statusPresenter,
              updater.phase != .relaunching else { return }
        reviewAction = Task { [weak self] in
            guard let self else { return }
            defer { reviewAction = nil }
            do {
                try await statusPresenter.restoreSourceFocus()
                guard coordinator.canApply, updater.phase != .relaunching else { return }
                coordinator.collapseReview()
                coordinator.apply()
            } catch { coordinator.blockReviewedApply(error) }
        }
    }

    private func collapseCorrectionReview() {
        guard !coordinator.applying, reviewAction == nil, let statusPresenter else { return }
        reviewAction = Task { [weak self] in
            guard let self else { return }
            defer { reviewAction = nil }
            // Cancellation still closes review when the original app has disappeared.
            try? await statusPresenter.restoreSourceFocus()
            coordinator.collapseReview()
        }
    }

    func requestCorrectionReview() {
        // Explicit reopening is allowed after feedback was hidden on a focus change.
        statusPresenter?.resumeReview()
        coordinator.requestReview()
    }

    func beginRecording() {
        guard !recordingShortcut else { return }
        recordingShortcut = true; shortcutMessage = nil; hotkey?.unregister(); doubleTap?.stop()
        recorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.recordingShortcut else { return false }
                // Only the explicit Settings recorder may consume keyboard events.
                guard NSApplication.shared.keyWindow?.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" else {
                    self.stopRecording(); return false
                }
                if event.keyCode == 53 { self.stopRecording(); return true }
                guard !event.isARepeat else { return true }
                guard let shortcut = ShortcutNames.shortcut(from: event) else {
                    self.shortcutMessage = String(localized: "Include ⌘, ⌃ or ⌥ with your key.")
                    return true
                }
                if self.setShortcut(shortcut) { self.stopRecording() }
                return true
            }
            return consumed ? nil : event
        }
    }

    @discardableResult
    func setShortcut(_ shortcut: HotkeyShortcut) -> Bool {
        guard shortcut.isValid else { return false }
        // Save only a successfully registered shortcut. A conflict keeps the previous
        // preference, and cancelling restores its registration after recording.
        guard !started || hotkey?.register(shortcut) == true else {
            shortcutMessage = String(localized: "That shortcut is in use. Try another combination.")
            return false
        }
        settings.shortcut = shortcut; shortcutConflict = false; shortcutMessage = nil
        return true
    }

    func stopRecording() {
        guard recordingShortcut else { return }
        if let recorder { NSEvent.removeMonitor(recorder) }; recorder = nil
        recordingShortcut = false; shortcutMessage = nil; configureShortcut()
    }
    isolated deinit { if let recorder { NSEvent.removeMonitor(recorder) } }

}
