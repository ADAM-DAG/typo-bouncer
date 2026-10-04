import AppKit
import BouncerCore
import Observation

@MainActor @Observable
final class ProofreadingCoordinator {
    private(set) var command: Command = .proofread
    private(set) var appliedCorrection: ValidatedCorrection?
    private(set) var reviewRequested = false
    private var applyBlocked = false
    @ObservationIgnored private var autoMode: AutoMode = .off
    @ObservationIgnored private var expandShorthand = false
    private var wantsAuto: Bool { autoMode != .off }
    @ObservationIgnored private let autoCheck: @MainActor (ValidatedCorrection, Command) -> Bool
    @ObservationIgnored private let insert: @MainActor (String, CapturedSelection) async throws -> Void
    private(set) var working = false
    private(set) var result: ValidatedCorrection?
    private(set) var message: String?
    private(set) var sourceAppName: String?
    private(set) var applying = false
    @ObservationIgnored private let timeout: Double?
    @ObservationIgnored private let service: any ProofreadingService
    @ObservationIgnored let capture: any SelectionCapturing
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var requestID: UUID?
    @ObservationIgnored private var target: CapturedSelection?
    private var missingSelection = false
    @ObservationIgnored private var emptySelectionAnchor: SelectionAnchor?
    @ObservationIgnored private var statusGeneration = UUID()
    @ObservationIgnored var changed: (() -> Void)?

    init(service: any ProofreadingService = OnDeviceModel(), timeout: Double? = nil,
         capture: any SelectionCapturing = SelectionCapture(),
         autoCheck: @escaping @MainActor (ValidatedCorrection, Command) -> Bool = NativeSpellingEvidence.allowsAuto,
         insert: (@MainActor (String, CapturedSelection) async throws -> Void)? = nil) {
        self.service = service; self.timeout = timeout; self.capture = capture; self.autoCheck = autoCheck
        self.insert = insert ?? { correction, target in try await TextInserter(capture: capture).apply(correction, to: target) }
    }
    var statusTarget: CapturedSelection? { target }
    var statusAnchor: SelectionAnchor? { target?.anchor ?? emptySelectionAnchor }
    /// Read only the captured element while its feedback is visible. Sending,
    /// clearing or editing that draft ends its pending correction and model work.
    func validateStatusTarget() async -> Bool {
        guard let target, !applying else { return true }
        let generation = statusGeneration
        let replacement = appliedCorrection?.corrected
        let current = await capture.containsDraft(target, replacement: replacement)
        // An AX read may finish after a new request or our own paste has started.
        guard !Task.isCancelled, generation == statusGeneration, !applying,
              replacement == appliedCorrection?.corrected else { return true }
        if !current { cancel() }
        return current
    }
    private(set) var statusSourcePID: pid_t?
    var canApply: Bool { !working && !applying && !applyBlocked && result != nil && result?.isUnchanged == false && target?.canReplace == true }
    var copyOnly: Bool { target?.canReplace != true }
    var externalFormattingMessage: String? {
        guard result != nil, target?.canReplace == true else { return nil }
        if target?.formatting.usesRichText == true {
            return String(localized: "Formatting is kept when your app supports rich-text paste.")
        }
        if target?.canAutoReplace == false {
            return String(localized: "Apply uses plain text. Formatting inside the selection may be lost.")
        }
        return nil
    }
    var usesAutoStatus: Bool { autoMode.usesCompactFeedback(for: command) }
    var correctionStatus: CorrectionStatus? {
        if working { return .correcting }
        if applying { return .applying }
        if appliedCorrection != nil { return .applied }
        if applyBlocked { return .failed }
        if let result { return result.isUnchanged ? .unchanged : .review }
        return message == nil ? nil : missingSelection ? .noText : .failed
    }
    func requestReview() { reviewRequested = true; changed?() }
    func collapseReview() {
        guard !applying else { return }
        reviewRequested = false
        changed?()
    }
    func prewarm() { Task { await service.prewarm() } }

    func proofreadSelection(pid: pid_t, limit: Int, command: Command = .proofread, mode: AutoMode = .off, expandShorthand: Bool = false, appName: String? = nil, selectFocusedText: Bool = false) {
        guard !working, !applying else { return }
        prepareRequest(command: command, mode: mode, expandShorthand: expandShorthand)
        target = nil; result = nil; message = nil; sourceAppName = appName; statusSourcePID = pid
        let id = startDeadline(characters: limit)
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                let selected = try await capture.capture(pid: pid, selectFocusedText: selectFocusedText, limit: limit)
                guard requestID == id else { return }
                target = selected
                changed?()
                let correction = try await service.correct(selected.text, limit: limit, command: command, expandShorthand: expandShorthand)
                finish(id: id, correction: correction)
            } catch {
                guard requestID == id, !Task.isCancelled else { return }
                let noText = target == nil && ((error as? AppFailure) == .noSelection || (error as? SelectionError) == .empty)
                if noText {
                    let anchor = await capture.focusedFieldAnchor(pid: pid)
                    guard requestID == id, !Task.isCancelled else { return }
                    emptySelectionAnchor = anchor
                }
                fail(id: id, error: error, noText: noText)
            }
        }
    }

    private func prepareRequest(command: Command, mode: AutoMode, expandShorthand: Bool) {
        statusGeneration = UUID()
        missingSelection = false; emptySelectionAnchor = nil
        reviewRequested = false; statusSourcePID = nil
        self.command = command; autoMode = mode; self.expandShorthand = expandShorthand; applyBlocked = false
        appliedCorrection = nil
    }

    private func startDeadline(characters: Int) -> UUID {
        let id = UUID(); requestID = id; working = true
        watchdog?.cancel()
        let seconds = timeout ?? min(command == .improveSentences ? 40.0 : 25.0,
                                     (command == .improveSentences ? 16.0 : 8.0) + Double(characters) * 0.01)
        watchdog = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(seconds))
                guard let self, requestID == id else { return }
                worker?.cancel(); fail(id: id, error: AppFailure.timedOut)
            } catch { }
        }
        changed?()
        return id
    }

    private func finish(id: UUID, correction: ValidatedCorrection) {
        guard requestID == id else { return }
        requestID = nil; watchdog?.cancel(); working = false; result = correction
        if !reviewRequested, canApply, target?.canAutoReplace == true, allowsAutomaticApply(correction) {
            apply(automatically: true)
        } else {
            if !correction.isUnchanged {
                offerReview(explicit: true)
                if wantsAuto {
                    if target?.canReplace != true {
                        // The review already explains its Copy-only action.
                        message = nil
                    } else if target?.canAutoReplace != true {
                        message = String(localized: "This field’s formatting needs review before applying.")
                    } else { message = String(localized: "This change needs a review before applying.") }
                }
            }
            changed?()
        }
    }
    private func allowsAutomaticApply(_ correction: ValidatedCorrection) -> Bool {
        switch autoMode {
        case .off: return false
        case .full: return true
        case .clean:
            guard command == .proofread else { return false }
            // An enabled, deterministic expansion is explicitly authorized. Evaluate
            // any remaining edits using the same conservative Clean evidence.
            let baseline = expandShorthand ? ChatShorthand.expand(correction.original) : correction.original
            if baseline == correction.corrected { return true }
            guard let remaining = try? OutputValidator.validate(original: baseline, corrected: correction.corrected, command: command) else { return false }
            return autoCheck(remaining, command)
        }
    }

    private func fail(id: UUID, error: Error, noText: Bool = false) {
        guard requestID == id else { return }
        requestID = nil; watchdog?.cancel(); working = false
        if !(error is CancellationError) {
            missingSelection = noText
            if !noText { offerReview() }
            message = AppFailure.message(for: error)
        }
        changed?()
    }

    /// Corrections requiring approval open review, including in Auto mode.
    /// Other Auto errors keep compact details unless review was explicitly requested.
    private func offerReview(explicit: Bool = false) {
        if explicit || !usesAutoStatus { reviewRequested = true }
    }

    func cancel() {
        guard !applying else { return }
        statusGeneration = UUID()
        requestID = nil; worker?.cancel(); watchdog?.cancel()
        working = false; result = nil; message = nil; target = nil
        missingSelection = false; emptySelectionAnchor = nil
        reviewRequested = false
        appliedCorrection = nil
        changed?()
    }

    func blockReviewedApply(_ error: Error) {
        guard !applying, result != nil else { return }
        applyBlocked = true; reviewRequested = true
        message = AppFailure.message(for: error)
        changed?()
    }

    func apply(automatically: Bool = false) {
        guard canApply, let result else { return }
        guard let target else { return }
        applying = true; changed?()
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                try await insert(result.corrected, target)
                self.result = nil
                appliedCorrection = result
                message = automatically ? String(localized: "Applied automatically. Use ⌘Z in your app to undo.") : String(localized: "Applied. Use ⌘Z in your app to undo.")
            } catch { applyBlocked = true; offerReview(explicit: !automatically); message = AppFailure.message(for: error) }
            applying = false; changed?()
        }
    }

    func copyCorrection() {
        guard let result, !working, !applying else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.corrected, forType: .string)
        message = String(localized: "Correction copied."); changed?()
    }
    func externalMessage(_ text: String, command: Command = .proofread, mode: AutoMode = .off, expandShorthand: Bool = false) {
        prepareRequest(command: command, mode: mode, expandShorthand: expandShorthand)
        result = nil; sourceAppName = nil
        target = nil; message = text; offerReview(); changed?()
    }
}
