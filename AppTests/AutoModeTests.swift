import AppKit
import ApplicationServices
import BouncerCore
import QuartzCore
import SwiftUI
import XCTest
@testable import TypoBouncer

private actor AutoProofreader: ProofreadingService {
    let unchanged: Bool
    init(unchanged: Bool = false) { self.unchanged = unchanged }
    func prewarm() { }
    func correct(_ text: String, limit: Int, command: Command) async throws -> ValidatedCorrection {
        try? await Task.sleep(for: .milliseconds(100))
        return try OutputValidator.validate(original: text, corrected: unchanged ? text : text.replacingOccurrences(of: "teh", with: "the"), command: command)
    }
}
private actor AutoCapture: SelectionCapturing {
    let autoSafe: Bool
    let text: String
    init(autoSafe: Bool, text: String = "This is teh first draft.") { self.autoSafe = autoSafe; self.text = text }
    func capture(pid: pid_t) -> CapturedSelection {
        return CapturedSelection(element: AXUIElementCreateApplication(pid), canReplace: true, pid: pid,
            text: text, range: CFRange(location: 0, length: text.utf16.count), fullValue: text, digest: Data(), canAutoReplace: autoSafe)
    }
    func verify(_ target: CapturedSelection) { }
    func confirms(_ target: CapturedSelection, replacement: String) -> Bool { true }
}

private actor DraftLifecycleCapture: SelectionCapturing {
    private var value = "This is teh first draft."
    private var validationDelay: Duration = .zero
    private(set) var checks = 0
    func setValue(_ value: String) { self.value = value }
    func delayValidation(_ delay: Duration) { validationDelay = delay }
    func capture(pid: pid_t) -> CapturedSelection {
        CapturedSelection(element: AXUIElementCreateApplication(pid), canReplace: true, pid: pid,
            text: value, range: CFRange(location: 0, length: value.utf16.count),
            fullValue: value, digest: Data(), canAutoReplace: true)
    }
    func containsDraft(_ target: CapturedSelection, replacement: String?) async -> Bool {
        checks += 1
        let matches = value == (replacement ?? target.text)
        try? await Task.sleep(for: validationDelay)
        return matches
    }
    func verify(_ target: CapturedSelection) { }
    func confirms(_ target: CapturedSelection, replacement: String) -> Bool { true }
}

private actor CasualProofreader: ProofreadingService {
    func prewarm() { }
    func correct(_ text: String, limit: Int, command: Command) async throws -> ValidatedCorrection {
        try OutputValidator.validate(original: text,
            corrected: "Hi, I'm Adam. I wanted to test if this works. Can you help me?")
    }
}

private actor IslandCopyCapture: SelectionCapturing {
    func capture(pid: pid_t) -> CapturedSelection {
        CapturedSelection(element: AXUIElementCreateApplication(pid), canReplace: false, pid: pid,
            text: "This is teh first draft.")
    }
    func verify(_ target: CapturedSelection) throws { throw AppFailure.noSelection }
    func confirms(_ target: CapturedSelection, replacement: String) -> Bool { false }
}

private actor AutoFailureCapture: SelectionCapturing {
    let anchor: SelectionAnchor?
    let emptyField: Bool
    init(anchor: SelectionAnchor? = nil, emptyField: Bool = false) { self.anchor = anchor; self.emptyField = emptyField }
    func capture(pid: pid_t) throws -> CapturedSelection {
        if emptyField { throw SelectionError.empty }
        throw AppFailure.noSelection
    }
    func focusedFieldAnchor(pid: pid_t) async -> SelectionAnchor? { anchor }
    func verify(_ target: CapturedSelection) throws { throw AppFailure.noSelection }
    func confirms(_ target: CapturedSelection, replacement: String) -> Bool { false }
}

private actor DelayedEmptyFeedbackCapture: SelectionCapturing {
    private var first = true
    private var continuation: CheckedContinuation<SelectionAnchor?, Never>?
    var readingAnchor: Bool { continuation != nil }
    func capture(pid: pid_t) throws -> CapturedSelection {
        if first { first = false; throw AppFailure.noSelection }
        let text = "This is teh first draft."
        return CapturedSelection(element: AXUIElementCreateApplication(pid), canReplace: true, pid: pid,
            text: text, range: CFRange(location: 0, length: text.utf16.count), fullValue: text, digest: Data())
    }
    func focusedFieldAnchor(pid: pid_t) async -> SelectionAnchor? {
        await withCheckedContinuation { continuation = $0 }
    }
    func finishAnchor() {
        continuation?.resume(returning: SelectionAnchor(field: CGRect(x: 100, y: 200, width: 500, height: 80)))
        continuation = nil
    }
    func verify(_ target: CapturedSelection) { }
    func confirms(_ target: CapturedSelection, replacement: String) -> Bool { true }
}

private actor AutoFailureProofreader: ProofreadingService {
    func prewarm() { }
    func correct(_ text: String, limit: Int, command: Command) throws -> ValidatedCorrection {
        throw AppFailure.timedOut
    }
}

private actor WordingProofreader: ProofreadingService {
    func prewarm() { }
    func correct(_ text: String, limit: Int, command: Command) async throws -> ValidatedCorrection {
        try await Task.sleep(for: .milliseconds(50))
        return try OutputValidator.validate(original: text,
            corrected: "I was tired because I worked late.", command: command)
    }
}

@MainActor final class AutoModeTests: XCTestCase {
    func testFullAutoAppliesWordingAndSentenceImprovementsWhileOtherModesReview() async throws {
        for command in [Command.proofread, .improveSentences] {
            for mode in AutoMode.allCases {
                var pastes: [String] = []
                let coordinator = ProofreadingCoordinator(service: WordingProofreader(),
                    capture: AutoCapture(autoSafe: true, text: "I was tired. Because I worked late."),
                    autoCheck: { _, _ in false }, insert: { correction, _ in pastes.append(correction) })
                coordinator.proofreadSelection(pid: 123, limit: 1500, command: command, mode: mode)
                try await Task.sleep(for: .milliseconds(150))
                XCTAssertEqual(pastes, mode == .full ? ["I was tired because I worked late."] : [])
                XCTAssertEqual(coordinator.reviewRequested, mode != .full)
                XCTAssertEqual(coordinator.correctionStatus, mode == .full ? .applied : .review)
            }
        }
    }

    func testFullAutoExternalApplyKeepsFormattingGateAndCompactStatusForBothActions() async throws {
        for command in [Command.proofread, .improveSentences] {
            for autoSafe in [false, true] {
                var pastes = 0
                let coordinator = ProofreadingCoordinator(service: WordingProofreader(),
                    capture: AutoCapture(autoSafe: autoSafe, text: "I was tired. Because I worked late."),
                    autoCheck: { _, _ in false }, insert: { _, _ in pastes += 1 })
                coordinator.proofreadSelection(pid: 123, limit: 1500, command: command, mode: .full)
                XCTAssertTrue(coordinator.usesAutoStatus)
                try await Task.sleep(for: .milliseconds(150))
                XCTAssertEqual(pastes, autoSafe ? 1 : 0)
                XCTAssertEqual(coordinator.reviewRequested, !autoSafe)
                XCTAssertEqual(coordinator.correctionStatus, autoSafe ? .applied : .review)
            }
        }
    }

    func testFullAutoHonorsCopyOnlyFocusFailureAndExplicitReview() async throws {
        let copyOnly = ProofreadingCoordinator(service: AutoProofreader(), capture: IslandCopyCapture())
        copyOnly.proofreadSelection(pid: 123, limit: 1500, mode: .full)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(copyOnly.copyOnly)
        XCTAssertTrue(copyOnly.reviewRequested)
        XCTAssertNil(copyOnly.appliedCorrection)
        let blocked = ProofreadingCoordinator(service: AutoProofreader(), capture: AutoCapture(autoSafe: true),
            insert: { _, _ in throw AppFailure.noSelection })
        blocked.proofreadSelection(pid: 123, limit: 1500, mode: .full)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(blocked.correctionStatus, .failed)
        XCTAssertNil(blocked.appliedCorrection)
        var pastes = 0
        let review = ProofreadingCoordinator(service: AutoProofreader(), capture: AutoCapture(autoSafe: true),
            insert: { _, _ in pastes += 1 })
        review.proofreadSelection(pid: 123, limit: 1500, mode: .full)
        review.requestReview()
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(pastes, 0)
        XCTAssertNotNil(review.result)
        XCTAssertTrue(review.reviewRequested)
    }





    func testShorthandPreferenceFlowsThroughSelectedText() async throws {
        for enabled in [false, true] {
            var pastes: [String] = []
            let coordinator = ProofreadingCoordinator(service: AutoProofreader(),
                capture: AutoCapture(autoSafe: true, text: "idk what teh plan is."),
                autoCheck: { _, _ in true }, insert: { text, _ in pastes.append(text) })
            coordinator.proofreadSelection(pid: 123, limit: 1500, mode: .clean, expandShorthand: enabled)
            try await Task.sleep(for: .milliseconds(180))
            XCTAssertEqual(pastes, [enabled ? "I don't know what the plan is." : "idk what the plan is."])
            XCTAssertEqual(coordinator.appliedCorrection?.original, "idk what teh plan is.")
        }
    }

    func testSentDraftDismissesCompactFeedbackAndDiscardsPendingCorrection() async throws {
        let capture = DraftLifecycleCapture()
        let coordinator = ProofreadingCoordinator(service: AutoProofreader(), capture: capture, autoCheck: { _, _ in false })
        let presenter = CorrectionStatusPresenter(frontmost: { 123 }, details: {})
        defer { presenter.hide() }
        coordinator.proofreadSelection(pid: 123, limit: 1500, mode: .clean)
        try await Task.sleep(for: .milliseconds(180))
        coordinator.collapseReview()
        presenter.show(.review, sourcePID: 123, isCurrent: { await coordinator.validateStatusTarget() })
        XCTAssertTrue(presenter.panel.isVisible)
        await capture.setValue("")
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertFalse(presenter.panel.isVisible)
        XCTAssertNil(coordinator.result)
        XCTAssertNil(coordinator.statusTarget)
        XCTAssertNil(coordinator.correctionStatus)
        XCTAssertFalse(coordinator.canApply)
        // A later UI refresh must not revive the old floating indicator.
        presenter.show(.review, sourcePID: 123)
        XCTAssertFalse(presenter.panel.isVisible)
    }

    func testSentDraftDismissesReviewWhileWaitingForFocusAndAfterExpansion() async throws {
        for receivesFocus in [false, true] {
            let capture = DraftLifecycleCapture()
            let coordinator = ProofreadingCoordinator(service: AutoProofreader(), capture: capture)
            var active: pid_t? = 123
            var applies = 0
            let presenter = CorrectionStatusPresenter(frontmost: { active }, ownPID: 321,
                activateReview: { if receivesFocus { active = 321 } }, reviewIsKey: { _ in receivesFocus }, details: {})
            defer { presenter.hide() }
            coordinator.proofreadSelection(pid: 123, limit: 1500)
            try await Task.sleep(for: .milliseconds(180))
            presenter.showReview(coordinator: coordinator, sourcePID: 123,
                isCurrent: { await coordinator.validateStatusTarget() }, apply: { applies += 1 }, collapse: {})
            try await Task.sleep(for: .milliseconds(180))
            XCTAssertTrue(presenter.panel.isVisible)
            XCTAssertEqual(presenter.isReviewWaitingForFocus, !receivesFocus)
            await capture.setValue("")
            try await Task.sleep(for: .milliseconds(180))
            XCTAssertFalse(presenter.panel.isVisible)
            XCTAssertFalse(presenter.isReviewExpanded)
            XCTAssertFalse(presenter.isReviewWaitingForFocus)
            XCTAssertFalse(presenter.panel.canBecomeKey)
            XCTAssertNil(presenter.panel.reviewKeyAction)
            XCTAssertNil(coordinator.result)
            XCTAssertEqual(applies, 0)
        }
    }

    func testClearedDraftCancelsModelWorkAndIgnoresLateResult() async throws {
        let capture = DraftLifecycleCapture()
        var insertions = 0
        let coordinator = ProofreadingCoordinator(service: AutoProofreader(), capture: capture,
            autoCheck: { _, _ in true }, insert: { _, _ in insertions += 1 })
        coordinator.proofreadSelection(pid: 123, limit: 1500, mode: .clean)
        while coordinator.statusTarget == nil { await Task.yield() }
        XCTAssertTrue(coordinator.working)
        await capture.setValue("")
        let valid = await coordinator.validateStatusTarget()
        XCTAssertFalse(valid)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertFalse(coordinator.working)
        XCTAssertNil(coordinator.result)
        XCTAssertNil(coordinator.correctionStatus)
        XCTAssertEqual(insertions, 0)
    }

    func testOwnPasteKeepsCompletionFeedbackButSendingItEndsFeedback() async throws {
        let capture = DraftLifecycleCapture()
        let coordinator = ProofreadingCoordinator(service: AutoProofreader(), capture: capture,
            autoCheck: { _, _ in true }, insert: { replacement, _ in
                // Some editors expose an empty value briefly during replacement.
                await capture.setValue("")
                try await Task.sleep(for: .milliseconds(200))
                await capture.setValue(replacement)
            })
        coordinator.proofreadSelection(pid: 123, limit: 1500, mode: .clean)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(coordinator.applying)
        let duringPaste = await coordinator.validateStatusTarget()
        XCTAssertTrue(duringPaste)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(coordinator.correctionStatus, .applied)
        let completed = await coordinator.validateStatusTarget()
        XCTAssertTrue(completed)
        XCTAssertEqual(coordinator.correctionStatus, .applied)
        await capture.setValue("")
        let sent = await coordinator.validateStatusTarget()
        XCTAssertFalse(sent)
        XCTAssertNil(coordinator.correctionStatus)
    }

    func testOldDraftValidationCannotCancelANewerRequest() async throws {
        let capture = DraftLifecycleCapture()
        let coordinator = ProofreadingCoordinator(service: AutoProofreader(), capture: capture)
        coordinator.proofreadSelection(pid: 123, limit: 1500)
        try await Task.sleep(for: .milliseconds(180))
        await capture.setValue("")
        await capture.delayValidation(.milliseconds(200))
        let oldCheck = Task { await coordinator.validateStatusTarget() }
        while await capture.checks == 0 { await Task.yield() }
        coordinator.cancel()
        await capture.setValue("This is teh newer draft.")
        coordinator.proofreadSelection(pid: 123, limit: 1500)
        _ = await oldCheck.value
        XCTAssertEqual(coordinator.result?.original, "This is teh newer draft.")
        XCTAssertTrue(coordinator.canApply)
    }

    func testReportedMessageAutomaticallyAppliesWithoutPresentingReview() async throws {
        let original = "hi im adam i wanted to test if this works can you helpme"
        var insertions: [String] = []
        var presentations: [Bool] = []
        let coordinator = ProofreadingCoordinator(service: CasualProofreader(),
            capture: AutoCapture(autoSafe: true, text: original),
            insert: { correction, _ in insertions.append(correction) })
        coordinator.changed = { [weak coordinator] in presentations.append(coordinator?.reviewRequested ?? false) }
        coordinator.proofreadSelection(pid: 123, limit: 1500, mode: .clean)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(insertions, ["Hi, I'm Adam. I wanted to test if this works. Can you help me?"])
        XCTAssertFalse(presentations.contains(true))
        XCTAssertEqual(coordinator.correctionStatus, .applied)
        XCTAssertTrue(coordinator.usesAutoStatus)
        XCTAssertFalse(coordinator.reviewRequested)

    }

    func testNativeEvidenceAllowsRealTypoButNotValidWordSubstitution() throws {
        let typo = try OutputValidator.validate(original: "This is teh first draft.", corrected: "This is the first draft.")
        XCTAssertTrue(NativeSpellingEvidence.allowsAuto(typo, command: .proofread))
        let realWord = try OutputValidator.validate(original: "I hope you have a food day.", corrected: "I hope you have a good day.")
        XCTAssertFalse(NativeSpellingEvidence.allowsAuto(realWord, command: .proofread))
    }
    func testSpinnerPreservesFocusAndAvoidsSelectionAtScreenEdges() {
        let presenter = CorrectionStatusPresenter(details: {})
        for panel in [presenter.panel] {
            XCTAssertFalse(panel.canBecomeKey)
            XCTAssertFalse(panel.canBecomeMain)
            XCTAssertFalse(panel.styleMask.contains(.nonactivatingPanel))
        }
        XCTAssertTrue(presenter.panel.ignoresMouseEvents)
        let visible = NSRect(x: -1728, y: 180, width: 1728, height: 1000)
        for anchor in [NSRect(x: -1300, y: 500, width: 300, height: 24),
                       NSRect(x: -400, y: 190, width: 380, height: 24),
                       NSRect(x: -1720, y: 1100, width: 1700, height: 50)] {
            let frame = CorrectionStatusPresenter.frame(anchor: anchor, visibleFrame: visible)
            XCTAssertEqual(frame.size, StatusPillView.canvasSize)
            XCTAssertTrue(visible.contains(frame))
            XCTAssertFalse(frame.intersects(anchor))
        }
        let fallback = CorrectionStatusPresenter.frame(anchor: nil, visibleFrame: visible)
        XCTAssertTrue(visible.contains(fallback))
        XCTAssertLessThan(fallback.maxY, visible.midY)
    }

    func testPillIsCentredAboveInputAndIgnoresSelectionMovement() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let field = NSRect(x: 100, y: 120, width: 900, height: 300)
        let first = CorrectionStatusPresenter.frame(anchor: NSRect(x: 130, y: 150, width: 60, height: 20), field: field, visibleFrame: screen)
        let moved = CorrectionStatusPresenter.frame(anchor: NSRect(x: 630, y: 380, width: 110, height: 20), field: field, previous: first, visibleFrame: screen)
        let collapsed = CorrectionStatusPresenter.frame(anchor: nil, field: field, previous: moved, visibleFrame: screen)
        XCTAssertEqual(first.midX, field.midX)
        XCTAssertGreaterThan(first.minY, field.maxY)
        XCTAssertFalse(first.intersects(field))
        XCTAssertEqual(first, moved)
        XCTAssertEqual(first, collapsed)
    }

    func testEmptyFeedbackKeepsFieldPlacementAndOnlyRemembersTheSameApp() throws {
        let primary = try XCTUnwrap(NSScreen.screens.first)
        let field = NSRect(x: primary.visibleFrame.midX - 250, y: primary.visibleFrame.midY - 100, width: 500, height: 70)
        func anchor(_ rect: NSRect) -> SelectionAnchor {
            SelectionAnchor(field: CGRect(x: rect.minX, y: primary.frame.maxY - rect.maxY, width: rect.width, height: rect.height))
        }
        var pid: pid_t = 123, activations = 0
        let presenter = CorrectionStatusPresenter(frontmost: { pid }, activateReview: { activations += 1 }, details: {})
        defer { presenter.hide() }
        presenter.show(.correcting, anchor: anchor(field), sourcePID: pid)
        let normal = presenter.panel.frame
        presenter.hide()
        presenter.show(.noText, sourcePID: pid)
        XCTAssertEqual(presenter.panel.frame, normal)
        XCTAssertFalse(presenter.isReviewExpanded)
        XCTAssertFalse(presenter.panel.canBecomeKey)
        let view = try XCTUnwrap(presenter.panel.contentView as? StatusPillView)
        let firstShake = view.layer?.animation(forKey: "emptySelectionShake")?.beginTime
        presenter.show(.noText, sourcePID: pid)
        XCTAssertEqual(view.layer?.animation(forKey: "emptySelectionShake")?.beginTime, firstShake)
        presenter.hide()
        let moved = field.offsetBy(dx: 70, dy: 100)
        presenter.show(.noText, anchor: anchor(moved), sourcePID: pid)
        XCTAssertEqual(presenter.panel.frame.midX, moved.midX, accuracy: 0.5)
        XCTAssertNotEqual(presenter.panel.frame, normal)
        presenter.hide(); pid = 456
        presenter.show(.noText, sourcePID: pid)
        let visible = try XCTUnwrap(NSScreen.main).visibleFrame
        XCTAssertEqual(presenter.panel.frame.midX, visible.midX, accuracy: 0.5)
        XCTAssertEqual(presenter.panel.frame.midY, visible.midY, accuracy: 0.5)
        XCTAssertEqual(activations, 0)
    }

    func testEmptyFeedbackShakeMovesTheWholePillAndSettlesWithoutChangingLayout() throws {
        let view = StatusPillView(details: {})
        view.update(.noText, reduceMotion: false); view.setVisible(true)
        let frame = view.frame, capsule = view.capsule.frame
        view.shake()
        let shake = try XCTUnwrap(view.layer?.animation(forKey: "emptySelectionShake") as? CAKeyframeAnimation)
        XCTAssertEqual(shake.keyPath, "transform.translation.x")
        XCTAssertTrue(shake.isAdditive)
        XCTAssertEqual(shake.duration, 0.46)
        let values = try XCTUnwrap(shake.values as? [Double])
        XCTAssertEqual(values.first!, 0, accuracy: 0.001)
        XCTAssertEqual(values.last!, 0, accuracy: 0.001)
        XCTAssertLessThan(abs(values[1]), 0.1)
        XCTAssertLessThan(abs(values[values.count - 2]), 0.1)
        let peaks = (0..<3).map { cycle in values[(cycle * 30)...((cycle + 1) * 30)].map(abs).max()! }
        XCTAssertGreaterThan(peaks[0], 3)
        XCTAssertLessThan(peaks[0], 5)
        XCTAssertGreaterThan(peaks[0], peaks[1]); XCTAssertGreaterThan(peaks[1], peaks[2])
        XCTAssertNil(view.capsule.animation(forKey: "emptySelectionShake"))
        XCTAssertNil(view.arc.animation(forKey: "emptySelectionShake"))
        XCTAssertEqual(view.frame, frame); XCTAssertEqual(view.capsule.frame, capsule)
        view.update(.noText, reduceMotion: true); view.shake()
        XCTAssertNil(view.layer?.animation(forKey: "emptySelectionShake"))
        view.reset()
        view.update(.noText, reduceMotion: false); view.setVisible(true); view.shake()
        view.update(.correcting, reduceMotion: false)
        XCTAssertNil(view.layer?.animation(forKey: "emptySelectionShake"))
        view.reset()
    }

    func testEmptySelectionHasCompactFeedbackInEveryModeWithoutGeneratingOrApplying() async throws {
        let anchor = SelectionAnchor(field: CGRect(x: 100, y: 200, width: 500, height: 80))
        for mode in [AutoMode.off, .clean, .full] {
            for emptyField in [false, true] {
                let coordinator = ProofreadingCoordinator(service: AutoFailureProofreader(),
                    capture: AutoFailureCapture(anchor: anchor, emptyField: emptyField), insert: { _, _ in XCTFail("No text may be pasted") })
                coordinator.proofreadSelection(pid: 123, limit: 1500, mode: mode)
                try await Task.sleep(for: .milliseconds(40))
                XCTAssertEqual(coordinator.correctionStatus, .noText)
                XCTAssertEqual(coordinator.statusAnchor, anchor)
                XCTAssertNil(coordinator.statusTarget); XCTAssertNil(coordinator.result)
                XCTAssertFalse(coordinator.working); XCTAssertFalse(coordinator.canApply)
                XCTAssertFalse(coordinator.reviewRequested)
                coordinator.requestReview()
                XCTAssertTrue(coordinator.reviewRequested)
                coordinator.cancel()
                XCTAssertNil(coordinator.statusAnchor); XCTAssertNil(coordinator.correctionStatus)
            }
        }
    }

    func testAnOldEmptyFieldGeometryReadCannotReplaceANewerRequest() async throws {
        let capture = DelayedEmptyFeedbackCapture()
        let coordinator = ProofreadingCoordinator(service: AutoProofreader(), capture: capture)
        coordinator.proofreadSelection(pid: 123, limit: 1500)
        try await Task.sleep(for: .milliseconds(40))
        let reading = await capture.readingAnchor
        XCTAssertTrue(reading)
        coordinator.cancel()
        coordinator.proofreadSelection(pid: 456, limit: 1500)
        await capture.finishAnchor()
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(coordinator.statusTarget?.pid, 456)
        XCTAssertEqual(coordinator.correctionStatus, .review)
        XCTAssertEqual(coordinator.statusAnchor, SelectionAnchor())
        XCTAssertNil(coordinator.message)
        coordinator.cancel()
    }

    func testHighSearchBarOpensBelowAndDoesNotFlipAtThreshold() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let field = NSRect(x: 150, y: 810, width: 1000, height: 30)
        let below = CorrectionStatusPresenter.frame(anchor: field, field: field, visibleFrame: screen)
        XCTAssertLessThan(below.maxY, field.minY)
        XCTAssertEqual(below.midX, field.midX)
        XCTAssertTrue(screen.contains(below))
        let moved = field.offsetBy(dx: 0, dy: -20)
        let stable = CorrectionStatusPresenter.frame(anchor: moved, field: moved, previous: below, visibleFrame: screen)
        XCTAssertLessThan(stable.maxY, moved.minY)
        let lower = field.offsetBy(dx: 0, dy: -100)
        let above = CorrectionStatusPresenter.frame(anchor: lower, field: lower, previous: stable, visibleFrame: screen)
        XCTAssertGreaterThan(above.minY, lower.maxY)
    }

    func testPillPlacementFitsNarrowFieldsAndNegativeDisplayOrigins() {
        let screen = NSRect(x: -1728, y: 180, width: 1728, height: 1000)
        for field in [NSRect(x: -1725, y: 450, width: 100, height: 34),
                      NSRect(x: -180, y: 1100, width: 150, height: 32),
                      NSRect(x: -1300, y: 195, width: 600, height: 100)] {
            let frame = CorrectionStatusPresenter.frame(anchor: field, field: field, visibleFrame: screen)
            XCTAssertTrue(screen.contains(frame))
            XCTAssertFalse(frame.intersects(field))
        }
    }

    func testCollapsedSelectionKeepsItsPositionAsFieldMoves() {
        let old = SelectionAnchor(selection: CGRect(x: 120, y: 260, width: 200, height: 20),
                                  field: CGRect(x: 100, y: 200, width: 600, height: 400))
        let next = SelectionAnchor(field: CGRect(x: 140, y: 220, width: 600, height: 400))
        let stable = CorrectionStatusPresenter.stabilized(next, previous: old)
        XCTAssertEqual(stable.selection, CGRect(x: 160, y: 280, width: 200, height: 20))
    }

    func testProgressRingNeverRotatesAndRespectsCompletionAndReduceMotion() {
        let view = StatusPillView(details: {})
        view.update(.correcting, reduceMotion: false)
        XCTAssertNil(view.arc.superlayer?.animation(forKey: "rotation"))
        XCTAssertNotNil(view.arc.animation(forKey: "progress"))
        XCTAssertGreaterThanOrEqual(view.arc.lineWidth, 3)
        XCTAssertGreaterThan(view.arc.lineWidth, view.track.lineWidth)
        view.update(.applying, reduceMotion: true)
        XCTAssertNil(view.arc.animation(forKey: "progress"))
        XCTAssertNil(view.arc.superlayer?.animation(forKey: "rotation"))
        view.update(.applied, reduceMotion: false)
        XCTAssertNil(view.arc.superlayer?.animation(forKey: "rotation"))
        XCTAssertNotNil(view.arc.animation(forKey: "completion"))
        XCTAssertEqual(view.arc.strokeEnd, 1)
        view.reset()
        XCTAssertNil(view.arc.animationKeys())
        XCTAssertNil(view.arc.superlayer?.animationKeys())
    }

    func testProgressRingFillsFromTheTopAndClosesBeforeTurningGreen() async throws {
        let view = StatusPillView(details: {})
        let window = NSPanel(contentRect: NSRect(x: -10000, y: -10000, width: 240, height: 58),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.contentView = view
        defer { view.reset(); window.orderOut(nil) }
        window.orderFrontRegardless()
        view.update(.correcting, reduceMotion: false); view.setVisible(true)
        var start: CGPoint?
        var clockwise = false
        view.arc.path?.applyWithBlock { element in
            if element.pointee.type == .moveToPoint { start = element.pointee.points[0] }
            if element.pointee.type == .addCurveToPoint, !clockwise {
                clockwise = element.pointee.points[0].x > 13
            }
        }
        XCTAssertEqual(try XCTUnwrap(start).x, 13, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(start).y, 24, accuracy: 0.001)
        XCTAssertTrue(clockwise)
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(80))
        let initial = try XCTUnwrap(view.arc.presentation()).strokeEnd
        let orange = try XCTUnwrap(NSColor(cgColor: try XCTUnwrap(view.arc.presentation()?.strokeColor))?.usingColorSpace(.sRGB))
        XCTAssertEqual(orange.redComponent, 1, accuracy: 0.001)
        XCTAssertEqual(orange.greenComponent, 159.0 / 255, accuracy: 0.001)
        XCTAssertEqual(orange.blueComponent, 11.0 / 255, accuracy: 0.001)
        try await Task.sleep(for: .milliseconds(200))
        let filling = try XCTUnwrap(view.arc.presentation()).strokeEnd
        XCTAssertGreaterThan(filling, initial)
        XCTAssertLessThan(filling, 1)
        view.update(.applying, reduceMotion: false)
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(40))
        let handoff = try XCTUnwrap(view.arc.presentation()).strokeEnd
        XCTAssertLessThan(handoff - filling, 0.08) // Applying must not accelerate or jump toward the end.
        try await Task.sleep(for: .milliseconds(260))
        let applying = try XCTUnwrap(view.arc.presentation()).strokeEnd
        XCTAssertGreaterThanOrEqual(applying, filling)
        XCTAssertLessThan(applying, 1)
        XCTAssertGreaterThan((1 - applying) * 2 * .pi * 11, view.arc.lineWidth)
        view.update(.applied, reduceMotion: false)
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(80))
        let closing = try XCTUnwrap(view.arc.presentation())
        XCTAssertLessThan(closing.strokeEnd, 1)
        let yellow = try XCTUnwrap(NSColor(cgColor: try XCTUnwrap(closing.strokeColor))?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(yellow.redComponent, yellow.greenComponent)
        try await Task.sleep(for: .milliseconds(1000))
        let complete = try XCTUnwrap(view.arc.presentation())
        XCTAssertEqual(complete.strokeEnd, 1, accuracy: 0.001)
        let green = try XCTUnwrap(NSColor(cgColor: try XCTUnwrap(complete.strokeColor))?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(green.greenComponent, green.redComponent)
    }

    func testPillReactivityRespectsReduceMotionAndKeepsReviewExplicit() {
        var requests = 0
        let view = StatusPillView { requests += 1 }
        view.update(.correcting, reduceMotion: false)
        view.setVisible(true)
        XCTAssertNotNil(view.capsule.animation(forKey: "entrance"))
        XCTAssertFalse(view.accessibilityPerformPress())
        let width = view.capsule.bounds.width
        view.update(.applied, reduceMotion: false)
        XCTAssertEqual(view.capsule.bounds.width, width) // No width shift between text-free states.
        XCTAssertNil(view.capsule.animation(forKey: "resize"))
        var layers = view.layer.map { [$0] } ?? []
        var index = 0
        while index < layers.count {
            XCTAssertFalse(layers[index] is CATextLayer)
            layers.append(contentsOf: layers[index].sublayers ?? []); index += 1
        }
        XCTAssertFalse(view.accessibilityLabel()?.isEmpty ?? true)
        XCTAssertEqual(view.glyph.strokeEnd, 1)
        XCTAssertFalse(view.accessibilityPerformPress())
        view.update(.review, reduceMotion: true)
        XCTAssertNil(view.capsule.animationKeys())
        XCTAssertNil(view.arc.animationKeys())
        XCTAssertTrue(view.accessibilityPerformPress())
        XCTAssertEqual(requests, 1)
        view.update(.failed, reduceMotion: true)
        XCTAssertTrue(view.accessibilityPerformPress())
        XCTAssertEqual(requests, 2)
        view.reset()
        view.update(.correcting, reduceMotion: true)
        view.setVisible(true)
        XCTAssertNil(view.layer?.animationKeys())
        XCTAssertNil(view.capsule.animationKeys())
    }

    func testAccessibilityCoordinatesUsePrimaryDisplayOriginForOtherDisplays() {
        let abovePrimary = CGRect(x: -800, y: -600, width: 300, height: 24)
        let result = CorrectionStatusPresenter.appKitRect(abovePrimary, primaryTop: 1117)
        XCTAssertEqual(result, NSRect(x: -800, y: 1693, width: 300, height: 24))
        XCTAssertEqual(CorrectionStatusPresenter.appKitRect(CGRect(x: 200, y: 100, width: 300, height: 24), primaryTop: 1117).minY, 993)
    }

    func testStatusHidesAfterAppOrFieldFocusChanges() async throws {
        var focused: pid_t? = 123
        let presenter = CorrectionStatusPresenter(frontmost: { focused }, details: {})
        presenter.show(.correcting, sourcePID: 123)
        XCTAssertTrue(presenter.panel.isVisible)
        focused = 456
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(presenter.panel.isVisible)
        presenter.show(.applied, sourcePID: 123)
        XCTAssertFalse(presenter.panel.isVisible)
        focused = 123
        presenter.hide() // A new shortcut resets feedback suppressed by a focus change.
        presenter.show(.correcting, sourcePID: 123, follow: { nil })
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(presenter.panel.isVisible)
        presenter.show(.applied, sourcePID: 123)
        XCTAssertFalse(presenter.panel.isVisible) // Completion must not revive stale feedback.
        presenter.hide()
    }

    func testAutoReviewExpandsAndCollapsePreservesCorrection() async throws {
        let coordinator = ProofreadingCoordinator(service: AutoProofreader(), capture: AutoCapture(autoSafe: false))
        coordinator.proofreadSelection(pid: 123, limit: 1500, mode: .clean)
        XCTAssertEqual(coordinator.correctionStatus, .correcting)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(coordinator.correctionStatus, .review)
        XCTAssertTrue(coordinator.reviewRequested)
        coordinator.requestReview()
        XCTAssertTrue(coordinator.reviewRequested)
        coordinator.collapseReview()
        XCTAssertFalse(coordinator.reviewRequested)
        XCTAssertNotNil(coordinator.result)
        XCTAssertEqual(coordinator.statusTarget?.pid, 123)
        coordinator.requestReview()
        XCTAssertTrue(coordinator.reviewRequested)
        coordinator.cancel()
        XCTAssertNil(coordinator.correctionStatus)
        coordinator.proofreadSelection(pid: 123, limit: 1500, mode: .clean)
        XCTAssertFalse(coordinator.reviewRequested)
        coordinator.cancel()
    }

    func testAutoReviewExpandsSamePanelAndUserCollapseRemainsRespected() async throws {
        var pastes = 0
        let presenter = CorrectionStatusPresenter(frontmost: { 123 }, details: {})
        let coordinator = ProofreadingCoordinator(service: AutoProofreader(), capture: AutoCapture(autoSafe: false),
            insert: { _, _ in pastes += 1 })
        defer { coordinator.changed = nil; coordinator.cancel(); presenter.hide() }
        coordinator.changed = {
            guard let status = coordinator.correctionStatus else { return }
            if coordinator.reviewRequested && !coordinator.working && !coordinator.applying {
                presenter.showReview(coordinator: coordinator, sourcePID: 123, focus: false,
                    apply: {}, collapse: { coordinator.collapseReview() })
            } else { presenter.show(status, sourcePID: 123) }
        }
        coordinator.proofreadSelection(pid: 123, limit: 1500, mode: .clean)
        let window = presenter.panel.windowNumber
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(presenter.isReviewExpanded)
        XCTAssertEqual(presenter.panel.windowNumber, window)
        XCTAssertEqual(pastes, 0)
        coordinator.collapseReview()
        try await Task.sleep(for: .milliseconds(400))
        coordinator.changed?()
        XCTAssertFalse(presenter.isReviewExpanded)
        XCTAssertNotNil(coordinator.result)
        XCTAssertEqual(pastes, 0)
    }

    func testExpandedIslandKeepsAttachmentEdgeAndFitsScreen() {
        let screen = NSRect(x: -1440, y: 120, width: 1440, height: 900)
        for field in [NSRect(x: -1200, y: 180, width: 900, height: 280),
                      NSRect(x: -1250, y: 930, width: 1000, height: 32)] {
            let compact = CorrectionStatusPresenter.frame(anchor: field, field: field, visibleFrame: screen)
            let expanded = CorrectionStatusPresenter.expandedFrame(pill: compact, field: field, visibleFrame: screen)
            XCTAssertTrue(screen.contains(expanded))
            XCTAssertFalse(expanded.intersects(field))
            XCTAssertEqual(expanded.midX, compact.midX)
            if compact.midY < field.midY { XCTAssertEqual(expanded.maxY, compact.maxY) }
            else { XCTAssertEqual(expanded.minY, compact.minY) }
        }
    }

    func testEnterAndEscapeAreScopedToFocusedExpandedReview() {
        func event(_ key: UInt16, flags: NSEvent.ModifierFlags = [], repeating: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: repeating, keyCode: key)!
        }
        for key: UInt16 in [36, 76, 53] {
            XCTAssertNil(StatusPanel.action(for: event(key), expanded: false, focused: true))
            XCTAssertNil(StatusPanel.action(for: event(key), expanded: true, focused: false))
            XCTAssertNil(StatusPanel.action(for: event(key, flags: .command), expanded: true, focused: true))
            XCTAssertNil(StatusPanel.action(for: event(key, repeating: true), expanded: true, focused: true))
        }
        XCTAssertEqual(StatusPanel.action(for: event(36), expanded: true, focused: true), .apply)
        XCTAssertEqual(StatusPanel.action(for: event(76), expanded: true, focused: true), .apply)
        XCTAssertEqual(StatusPanel.action(for: event(53), expanded: true, focused: true), .collapse)
        XCTAssertNil(StatusPanel.action(for: event(0), expanded: true, focused: true))
    }

    func testHeldEnterCommitsOnceOnReleaseAndNeverForwardsRepeats() {
        func event(_ type: NSEvent.EventType, key: UInt16, repeating: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: repeating, keyCode: key)!
        }
        let panel = StatusPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        var actions: [ReviewKeyAction] = []
        panel.reviewKeyAction = { actions.append($0) }
        panel.allowsReviewFocus = true
        for key: UInt16 in [36, 76, 53] {
            XCTAssertTrue(panel.consumeReviewKey(event(.keyDown, key: key), focused: true))
            for _ in 0..<4 {
                XCTAssertTrue(panel.consumeReviewKey(event(.keyDown, key: key, repeating: true), focused: true))
            }
            XCTAssertEqual(actions.count, key == 36 ? 0 : key == 76 ? 1 : 2)
            XCTAssertTrue(panel.consumeReviewKey(event(.keyUp, key: key), focused: true))
        }
        XCTAssertEqual(actions, [.apply, .apply, .collapse])
        // A repeat arriving without its initial down must not reach a default button.
        XCTAssertTrue(panel.consumeReviewKey(event(.keyDown, key: 36, repeating: true), focused: true))
        XCTAssertFalse(panel.consumeReviewKey(event(.keyDown, key: 36), focused: false))
        XCTAssertEqual(actions.count, 3)
        XCTAssertTrue(panel.consumeReviewKey(event(.keyDown, key: 36), focused: true))
        panel.resignKey()
        XCTAssertTrue(panel.consumeReviewKey(event(.keyUp, key: 36), focused: true))
        XCTAssertEqual(actions.count, 3) // Returning to the window can't commit an old press.
        panel.allowsReviewFocus = false
        XCTAssertFalse(panel.consumeReviewKey(event(.keyDown, key: 36), focused: true))
        panel.allowsReviewFocus = true
        XCTAssertTrue(panel.consumeReviewKey(event(.keyUp, key: 36), focused: true))
    }

    func testExpandedReviewActivatesAndKeepsItsWindowFocusedUntilUserSwitchesApps() async throws {
        var active: pid_t? = 123
        var activations = 0
        var fieldQueries = 0
        let presenter = CorrectionStatusPresenter(frontmost: { active }, ownPID: 321,
            activateReview: { activations += 1; active = 321 }, activateSource: { _ in false },
            reviewIsKey: { _ in true }, details: {})
        let coordinator = ProofreadingCoordinator(service: AutoProofreader(), capture: AutoCapture(autoSafe: false))
        defer { presenter.hide() }
        presenter.show(.correcting, sourcePID: 123)
        presenter.showReview(coordinator: coordinator, sourcePID: 123,
            follow: { await MainActor.run { fieldQueries += 1 }; return nil }, apply: {}, collapse: {})
        XCTAssertEqual(activations, 1)
        XCTAssertTrue(presenter.panel.firstResponder === presenter.panel.contentView)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertTrue(presenter.isReviewExpanded)
        XCTAssertTrue(presenter.panel.isVisible)
        XCTAssertEqual(fieldQueries, 0) // The deliberately inactive source isn't queried.
        presenter.showReview(coordinator: coordinator, sourcePID: 123, apply: {}, collapse: {})
        XCTAssertEqual(activations, 1) // Ordinary observation updates don't steal focus again.
        active = 999
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(presenter.panel.isVisible)
        XCTAssertFalse(presenter.panel.canBecomeKey)
        XCTAssertEqual(activations, 1)
    }

    func testExpandingReviewDuringCompactFadeRestoresItsVisibility() {
        let view = StatusPillView(details: {})
        view.update(.review, reduceMotion: true)
        view.setVisible(true)
        view.setVisible(false)
        XCTAssertEqual(view.layer?.opacity, 0)
        view.expand(with: NSView(), from: view.capsule.bounds, position: view.capsule.position)
        XCTAssertEqual(view.layer?.opacity, 1)
        XCTAssertTrue(view.acceptsFirstResponder)
    }

    func testReviewContentStaysFixedWhileItsMaskCollapsesToTheAnchoredRing() async throws {
        let view = StatusPillView(details: {})
        let window = NSPanel(contentRect: NSRect(x: -10000, y: -10000, width: 440, height: 300),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.contentView = view; window.orderFrontRegardless()
        defer { view.reset(); window.orderOut(nil) }
        view.update(.review, reduceMotion: false); view.setVisible(true)
        let review = NSView()
        view.expand(with: review, from: CGRect(x: 0, y: 0, width: 48, height: 38), position: CGPoint(x: 220, y: 29))
        let textFrame = review.frame
        let clip = try XCTUnwrap(review.superview)
        let clipFrame = clip.frame
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(80))
        // An interrupted expansion must keep the text's layout and reverse its mask.
        view.contract(to: CGRect(x: 100, y: 0, width: 240, height: 58))
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(review.frame, textFrame)
        XCTAssertEqual(clip.frame, clipFrame)
        XCTAssertNil(clip.layer?.animation(forKey: "islandShape"))
        XCTAssertNotNil(view.reviewMask.animation(forKey: "islandMask"))
        let ring = try XCTUnwrap(view.arc.presentation())
        let center = ring.convert(CGPoint(x: 13, y: 13), to: view.layer?.presentation())
        XCTAssertEqual(center.x, 220, accuracy: 0.5)
        XCTAssertEqual(center.y, 29, accuracy: 0.5)
        view.update(.review, reduceMotion: true)
        XCTAssertNil(view.reviewMask.animationKeys())
    }

    func testExpandedReviewSurvivesSlowOrRejectedFocusAcquisition() async throws {
        var active: pid_t? = 123
        var key = false
        var activations = 0
        let presenter = CorrectionStatusPresenter(frontmost: { active }, ownPID: 321,
            activateReview: { activations += 1 }, activateSource: { _ in false },
            reviewIsKey: { _ in key }, details: {})
        let coordinator = ProofreadingCoordinator(service: AutoProofreader())
        defer { presenter.hide() }
        presenter.showReview(coordinator: coordinator, sourcePID: 123, apply: {}, collapse: {})
        XCTAssertGreaterThan(presenter.panel.frame.width, StatusPillView.canvasSize.width)
        XCTAssertTrue(presenter.isReviewWaitingForFocus)
        XCTAssertNil(presenter.panel.reviewKeyAction)
        try await Task.sleep(for: .milliseconds(1050)) // Past the focus-acquisition deadline.
        XCTAssertTrue(presenter.panel.isVisible)
        XCTAssertTrue(presenter.isReviewExpanded)
        XCTAssertTrue(presenter.isReviewWaitingForFocus)
        XCTAssertGreaterThan(presenter.panel.frame.width, StatusPillView.canvasSize.width)
        XCTAssertNil(presenter.panel.reviewKeyAction)
        XCTAssertFalse(presenter.panel.ignoresMouseEvents)
        XCTAssertTrue(presenter.panel.canBecomeKey)
        key = true; active = 321 // Clicking the retained preview can focus it later.
        presenter.showReview(coordinator: coordinator, sourcePID: 123, apply: {}, collapse: {})
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(presenter.panel.isVisible)
        XCTAssertFalse(presenter.isReviewWaitingForFocus)
        XCTAssertGreaterThan(presenter.panel.frame.width, StatusPillView.canvasSize.width)
        XCTAssertEqual(activations, 2) // The explicit retry may request activation again.
    }

    func testReviewIsVisibleButCannotApplyWhileTheSourceStillOwnsActivation() async throws {
        var pastes = 0
        let presenter = CorrectionStatusPresenter(frontmost: { 123 }, ownPID: 321,
            activateReview: {}, activateSource: { _ in XCTFail("Must not hand off without review focus"); return false },
            reviewIsKey: { _ in true }, details: {})
        let coordinator = ProofreadingCoordinator(service: AutoProofreader(), capture: AutoCapture(autoSafe: false),
            insert: { _, _ in pastes += 1 })
        defer { presenter.hide() }
        coordinator.proofreadSelection(pid: 123, limit: 1500, mode: .clean)
        try await Task.sleep(for: .milliseconds(250))
        presenter.showReview(coordinator: coordinator, sourcePID: 123, apply: { coordinator.apply() }, collapse: {})
        try await Task.sleep(for: .milliseconds(850))
        XCTAssertTrue(presenter.isReviewWaitingForFocus)
        XCTAssertTrue(presenter.panel.isVisible)
        XCTAssertGreaterThan(presenter.panel.frame.width, StatusPillView.canvasSize.width)
        XCTAssertNil(presenter.panel.reviewKeyAction)
        let view = try XCTUnwrap(presenter.panel.contentView?.subviews.first?.subviews.first as? NSHostingView<IslandReviewView>)
        XCTAssertFalse(view.rootView.focus.keyboardReady)
        view.rootView.apply() // Mouse approval also requires confirmed review focus.
        do { try await presenter.restoreSourceFocus(); XCTFail("Accepted unconfirmed focus") }
        catch { XCTAssertEqual(error as? AppFailure, .focusChanged) }
        XCTAssertEqual(pastes, 0)
        XCTAssertNotNil(coordinator.result)
    }

    func testApprovalAutomaticallyShowsChangesInEveryModeWithoutWaitingForActivation() async throws {
        for mode in AutoMode.allCases {
            var active: pid_t? = 123
            var activations = 0
            let presenter = CorrectionStatusPresenter(frontmost: { active }, ownPID: 321,
                activateReview: { activations += 1 }, reviewIsKey: { _ in false }, details: {
                    XCTFail("Approval must not require a details click")
                })
            let coordinator = ProofreadingCoordinator(service: AutoProofreader(), capture: AutoCapture(autoSafe: false),
                insert: { _, _ in XCTFail("Unfocused review must not paste") })
            defer { coordinator.changed = nil; presenter.hide() }
            coordinator.changed = { [weak coordinator] in
                guard let coordinator, let status = coordinator.correctionStatus else { presenter.hide(); return }
                if coordinator.reviewRequested && !coordinator.working {
                    presenter.showReview(coordinator: coordinator, sourcePID: 123, apply: {}, collapse: {})
                } else { presenter.show(status, sourcePID: 123) }
            }
            coordinator.proofreadSelection(pid: 123, limit: 1500, mode: mode)
            let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(2))
            while coordinator.working && clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(coordinator.working)
            XCTAssertTrue(coordinator.reviewRequested)
            XCTAssertEqual(coordinator.correctionStatus, .review)
            XCTAssertEqual(activations, 1)
            XCTAssertTrue(presenter.panel.isVisible)
            XCTAssertGreaterThan(presenter.panel.frame.width, StatusPillView.canvasSize.width)
            XCTAssertTrue(presenter.isReviewWaitingForFocus)
            XCTAssertNil(presenter.panel.reviewKeyAction)
            active = 999
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertFalse(presenter.panel.isVisible)
            XCTAssertEqual(activations, 1) // Never reclaim focus after a user switch.
        }
    }

    func testExpandedReviewClosesWhenKeyboardFocusLeavesAndCanBeExplicitlyReopened() async throws {
        var active: pid_t? = 123
        var key = true
        var activations = 0
        let presenter = CorrectionStatusPresenter(frontmost: { active }, ownPID: 321,
            activateReview: { active = 321; activations += 1 }, activateSource: { _ in false },
            reviewIsKey: { _ in key }, details: {})
        let coordinator = ProofreadingCoordinator(service: AutoProofreader())
        defer { presenter.hide() }
        presenter.showReview(coordinator: coordinator, sourcePID: 123, apply: {}, collapse: {})
        XCTAssertTrue(presenter.isReviewWaitingForFocus)
        XCTAssertGreaterThan(presenter.panel.frame.width, StatusPillView.canvasSize.width)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(presenter.isReviewWaitingForFocus)
        XCTAssertGreaterThan(presenter.panel.frame.width, StatusPillView.canvasSize.width)
        key = false
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(presenter.panel.isVisible)
        XCTAssertFalse(presenter.isReviewExpanded)
        XCTAssertEqual(activations, 1) // Never steal focus back from the user's next window.
        key = true; active = 123
        presenter.resumeReview()
        presenter.showReview(coordinator: coordinator, sourcePID: 123, apply: {}, collapse: {})
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(presenter.panel.isVisible)
        XCTAssertFalse(presenter.isReviewWaitingForFocus)
        presenter.panel.resignKey() // The native notification closes it immediately.
        XCTAssertFalse(presenter.panel.isVisible)
        XCTAssertFalse(presenter.panel.canBecomeKey)
    }

    func testClipboardReviewTracksItsCapturedAppWithoutAnExplicitSourcePID() async throws {
        var active: pid_t? = 123
        let presenter = CorrectionStatusPresenter(frontmost: { active }, ownPID: 321,
            activateReview: { active = 321 }, activateSource: { _ in false },
            reviewIsKey: { _ in true }, details: {})
        let coordinator = ProofreadingCoordinator(service: AutoProofreader())
        defer { presenter.hide() }
        presenter.showReview(coordinator: coordinator, apply: {}, collapse: {})
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(presenter.panel.isVisible)
        active = 999
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(presenter.panel.isVisible)
    }

    func testApplicationDeactivationImmediatelyHidesReviewEvenIfThePanelStillReportsKey() async throws {
        var active: pid_t? = 123
        let presenter = CorrectionStatusPresenter(frontmost: { active }, ownPID: 321,
            activateReview: { active = 321 }, reviewIsKey: { _ in true }, details: {})
        let coordinator = ProofreadingCoordinator(service: AutoProofreader(), capture: AutoCapture(autoSafe: false))
        defer { presenter.hide() }
        coordinator.proofreadSelection(pid: 123, limit: 1500, mode: .clean)
        try await Task.sleep(for: .milliseconds(250))
        presenter.showReview(coordinator: coordinator, sourcePID: 123, apply: {}, collapse: {})
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(presenter.isReviewWaitingForFocus)
        XCTAssertTrue(presenter.panel.isVisible)
        active = 123
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApplication.shared)
        XCTAssertFalse(presenter.panel.isVisible) // No polling interval with an unfocused review still visible.
        XCTAssertFalse(presenter.panel.canBecomeKey)
        XCTAssertNotNil(coordinator.result)
    }

    func testEnterIsConsumedDuringFocusAcquisitionAndAppliesOnlyOnceAfterFocusIsConfirmed() async throws {
        var active: pid_t? = 123
        var key = false
        var applies = 0
        let presenter = CorrectionStatusPresenter(frontmost: { active }, ownPID: 321,
            activateReview: { active = 321 }, reviewIsKey: { _ in key }, details: {})
        let coordinator = ProofreadingCoordinator(service: AutoProofreader(), capture: AutoCapture(autoSafe: false))
        defer { presenter.hide() }
        coordinator.proofreadSelection(pid: 123, limit: 1500, mode: .clean)
        try await Task.sleep(for: .milliseconds(250))
        presenter.showReview(coordinator: coordinator, sourcePID: 123, apply: { applies += 1 }, collapse: {})
        func event(_ type: NSEvent.EventType, repeating: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: presenter.panel.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: repeating, keyCode: 36)!
        }
        XCTAssertTrue(presenter.panel.consumeReviewKey(event(.keyDown), focused: true))
        XCTAssertTrue(presenter.panel.consumeReviewKey(event(.keyUp), focused: true))
        XCTAssertEqual(applies, 0) // Visibility alone doesn't authorize keyboard approval.
        XCTAssertTrue(presenter.isReviewWaitingForFocus)
        key = true
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(presenter.isReviewWaitingForFocus)
        XCTAssertTrue(presenter.panel.consumeReviewKey(event(.keyDown), focused: true))
        XCTAssertTrue(presenter.panel.consumeReviewKey(event(.keyDown, repeating: true), focused: true))
        XCTAssertEqual(applies, 0)
        XCTAssertTrue(presenter.panel.consumeReviewKey(event(.keyUp), focused: true))
        XCTAssertTrue(presenter.panel.consumeReviewKey(event(.keyUp), focused: true))
        XCTAssertEqual(applies, 1)
    }

    func testReviewedApplyWaitsForSourceActivationBeforeClipboardOrPaste() async throws {
        let capture = AutoCapture(autoSafe: false)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString("synthetic clipboard", forType: .string)
        var active: pid_t? = 123
        var requested: pid_t?
        var pastes = 0
        let presenter = CorrectionStatusPresenter(frontmost: { active }, ownPID: 321,
            activateReview: { active = 321 }, activateSource: { requested = $0; return true },
            reviewIsKey: { _ in true }, details: {})
        let coordinator = ProofreadingCoordinator(service: AutoProofreader(), capture: capture,
            insert: { correction, target in
                XCTAssertEqual(active, target.pid)
                XCTAssertFalse(presenter.panel.canBecomeKey)
                try await TextInserter(capture: capture, clipboard: ClipboardGuard(pasteboard: board),
                    frontmost: { active }, paste: { pastes += 1 }, settleTime: .zero).apply(correction, to: target)
            })
        defer { presenter.hide() }
        coordinator.proofreadSelection(pid: 123, limit: 1500, mode: .clean)
        try await Task.sleep(for: .milliseconds(250))
        presenter.showReview(coordinator: coordinator, sourcePID: 123, apply: {}, collapse: {})
        try await Task.sleep(for: .milliseconds(100))
        let apply = Task { @MainActor in
            try await presenter.restoreSourceFocus()
            coordinator.collapseReview()
            presenter.show(.applying, sourcePID: 123)
            coordinator.apply()
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(requested, 123)
        XCTAssertEqual(pastes, 0)
        XCTAssertFalse(coordinator.applying)
        XCTAssertEqual(board.string(forType: .string), "synthetic clipboard")
        active = 123
        try await apply.value
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(pastes, 1)
        XCTAssertNotNil(coordinator.appliedCorrection)
        XCTAssertEqual(board.string(forType: .string), "synthetic clipboard")
    }

    func testUserSwitchDuringReviewHandoffNeverPastesOrReactivatesReview() async throws {
        var active: pid_t? = 123
        var activations = 0
        var requests = 0
        var pastes = 0
        let presenter = CorrectionStatusPresenter(frontmost: { active }, ownPID: 321,
            activateReview: { activations += 1; active = 321 },
            activateSource: { _ in requests += 1; return true }, reviewIsKey: { _ in true }, details: {})
        let coordinator = ProofreadingCoordinator(service: AutoProofreader(), capture: AutoCapture(autoSafe: false),
            insert: { _, _ in pastes += 1 })
        defer { presenter.hide() }
        coordinator.proofreadSelection(pid: 123, limit: 1500, mode: .clean)
        try await Task.sleep(for: .milliseconds(250))
        presenter.showReview(coordinator: coordinator, sourcePID: 123, apply: {}, collapse: {})
        try await Task.sleep(for: .milliseconds(100))
        let apply = Task { @MainActor in
            do { try await presenter.restoreSourceFocus(); coordinator.apply() }
            catch { coordinator.blockReviewedApply(error) }
        }
        try await Task.sleep(for: .milliseconds(40))
        active = 999
        await apply.value
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(activations, 1)
        XCTAssertEqual(pastes, 0)
        XCTAssertNotNil(coordinator.result)
        XCTAssertFalse(coordinator.canApply)
        XCTAssertTrue(coordinator.reviewRequested)
        XCTAssertEqual(coordinator.message, AppFailure.focusChanged.message)
        coordinator.apply()
        XCTAssertEqual(pastes, 0)
    }

    func testRejectedSourceActivationKeepsFailureFocusedAndDoesNotPaste() async throws {
        var active: pid_t? = 123
        var requests = 0
        var pastes = 0
        let presenter = CorrectionStatusPresenter(frontmost: { active }, ownPID: 321,
            activateReview: { active = 321 }, activateSource: { _ in requests += 1; return false },
            reviewIsKey: { _ in true }, details: {})
        let coordinator = ProofreadingCoordinator(service: AutoProofreader(), capture: AutoCapture(autoSafe: false),
            insert: { _, _ in pastes += 1 })
        defer { presenter.hide() }
        coordinator.proofreadSelection(pid: 123, limit: 1500, mode: .clean)
        try await Task.sleep(for: .milliseconds(250))
        presenter.showReview(coordinator: coordinator, sourcePID: 123, apply: {}, collapse: {})
        try await Task.sleep(for: .milliseconds(100))
        do { try await presenter.restoreSourceFocus(); XCTFail("Rejected activation accepted") }
        catch { coordinator.blockReviewedApply(error) }
        presenter.showReview(coordinator: coordinator, sourcePID: 123, apply: {}, collapse: {})
        XCTAssertTrue(presenter.isReviewExpanded)
        XCTAssertTrue(presenter.panel.isVisible)
        XCTAssertTrue(presenter.panel.canBecomeKey)
        XCTAssertFalse(coordinator.canApply)
        XCTAssertNotNil(coordinator.result)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(pastes, 0)
    }

    func testReviewContractsSamePanelAndReleasesFocusBeforeApply() async throws {
        let presenter = CorrectionStatusPresenter(frontmost: { 123 }, details: {})
        var insertions = 0
        let coordinator = ProofreadingCoordinator(service: AutoProofreader(), capture: AutoCapture(autoSafe: false),
            insert: { _, _ in
                XCTAssertFalse(presenter.panel.canBecomeKey)
                XCTAssertFalse(presenter.isReviewExpanded)
                insertions += 1
            })
        defer { presenter.hide() }
        coordinator.proofreadSelection(pid: 123, limit: 1500, mode: .clean)
        try await Task.sleep(for: .milliseconds(250))
        presenter.show(.review, sourcePID: 123)
        let originalWindow = presenter.panel.windowNumber
        presenter.showReview(coordinator: coordinator, sourcePID: 123, focus: false, apply: {
            coordinator.collapseReview()
            presenter.show(.applying, sourcePID: 123)
            coordinator.apply()
        }, collapse: { coordinator.collapseReview() })
        XCTAssertTrue(presenter.isReviewExpanded)
        XCTAssertTrue(presenter.panel.canBecomeKey)
        XCTAssertFalse(presenter.panel.canBecomeMain)
        XCTAssertEqual(presenter.panel.windowNumber, originalWindow)
        XCTAssertGreaterThan(presenter.panel.frame.width, StatusPillView.canvasSize.width)
        presenter.panel.reviewKeyAction?(.apply)
        XCTAssertFalse(presenter.isReviewExpanded)
        XCTAssertFalse(presenter.panel.canBecomeKey)
        presenter.panel.reviewKeyAction?(.apply) // Repeated Return cannot paste again.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(insertions, 1)
        XCTAssertNotNil(coordinator.appliedCorrection)
        presenter.show(.applied, sourcePID: 123)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(presenter.panel.frame.size, StatusPillView.canvasSize)
        XCTAssertEqual(presenter.panel.windowNumber, originalWindow)
    }

    func testExplicitReviewCanReopenAfterFocusLossButCompletionCannot() async throws {
        var focused: pid_t? = 123
        let presenter = CorrectionStatusPresenter(frontmost: { focused }, details: {})
        let coordinator = ProofreadingCoordinator(service: AutoProofreader(), capture: AutoCapture(autoSafe: false))
        defer { presenter.hide() }
        coordinator.proofreadSelection(pid: 123, limit: 1500, mode: .clean)
        try await Task.sleep(for: .milliseconds(250))
        presenter.showReview(coordinator: coordinator, sourcePID: 123, focus: false, apply: {}, collapse: {})
        focused = 999
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(presenter.panel.isVisible)
        focused = 123
        presenter.show(.applied, sourcePID: 123)
        XCTAssertFalse(presenter.panel.isVisible)
        presenter.resumeReview()
        presenter.showReview(coordinator: coordinator, sourcePID: 123, focus: false, apply: {}, collapse: {})
        XCTAssertTrue(presenter.isReviewExpanded)
        XCTAssertTrue(presenter.panel.isVisible)
    }

    func testFailedReviewedApplyReexpandsAndCannotPasteAgain() async throws {
        let presenter = CorrectionStatusPresenter(frontmost: { 123 }, details: {})
        var attempts = 0
        let coordinator = ProofreadingCoordinator(service: AutoProofreader(), capture: AutoCapture(autoSafe: false),
            insert: { _, _ in attempts += 1; throw AppFailure.pasteFailed })
        defer { coordinator.changed = nil; presenter.hide() }
        coordinator.proofreadSelection(pid: 123, limit: 1500, mode: .clean)
        try await Task.sleep(for: .milliseconds(250))
        let apply: () -> Void = {
            coordinator.collapseReview()
            coordinator.apply()
        }
        coordinator.changed = {
            if coordinator.reviewRequested {
                presenter.showReview(coordinator: coordinator, sourcePID: 123, focus: false, apply: apply,
                    collapse: { coordinator.collapseReview() })
            } else if let status = coordinator.correctionStatus { presenter.show(status, sourcePID: 123) }
        }
        coordinator.requestReview()
        let window = presenter.panel.windowNumber
        presenter.panel.reviewKeyAction?(.apply)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(presenter.isReviewExpanded)
        XCTAssertEqual(presenter.panel.windowNumber, window)
        XCTAssertEqual(coordinator.correctionStatus, .failed)
        XCTAssertNotNil(coordinator.result)
        XCTAssertFalse(coordinator.canApply)
        presenter.panel.reviewKeyAction?(.apply)
        XCTAssertEqual(attempts, 1)
    }

    func testExpandedCopyOnlyReviewCannotApplyFromEnter() async throws {
        let presenter = CorrectionStatusPresenter(frontmost: { 123 }, details: {})
        let coordinator = ProofreadingCoordinator(service: AutoProofreader(), capture: IslandCopyCapture())
        var requests = 0
        defer { presenter.hide() }
        coordinator.proofreadSelection(pid: 123, limit: 1500, mode: .clean)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(coordinator.copyOnly)
        XCTAssertFalse(coordinator.canApply)
        presenter.showReview(coordinator: coordinator, sourcePID: 123, focus: false,
            apply: { requests += 1 }, collapse: { coordinator.collapseReview() })
        presenter.panel.reviewKeyAction?(.apply)
        XCTAssertEqual(requests, 0)
        XCTAssertTrue(presenter.isReviewExpanded)
        presenter.panel.reviewKeyAction?(.collapse)
        XCTAssertFalse(coordinator.reviewRequested)
        XCTAssertNotNil(coordinator.result)
    }

    func testNativeEvidenceAcceptsReportedCasualMessage() throws {
        let result = try OutputValidator.validate(
            original: "hi im adam i wanted to test if this works can you helpme",
            corrected: "Hi, I'm Adam. I wanted to test if this works. Can you help me?")
        XCTAssertTrue(NativeSpellingEvidence.allowsAuto(result, command: .proofread))
    }

    func testSentenceImprovementsPreviewInCleanMode() async throws {
        let coordinator = ProofreadingCoordinator(service: AutoProofreader(), capture: AutoCapture(autoSafe: true), autoCheck: { _, _ in true }, insert: { _, _ in XCTFail("Clean must review sentence improvements") })
        coordinator.proofreadSelection(pid: 123, limit: 1500, command: .improveSentences, mode: .clean)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNotNil(coordinator.result)
        XCTAssertNil(coordinator.appliedCorrection)
        XCTAssertEqual(coordinator.command, .improveSentences)
    }

    func testAutoCaptureModelAndDeadlineErrorsStayCompactUntilRequested() async throws {
        let coordinators = [
            ProofreadingCoordinator(service: AutoProofreader(), capture: AutoFailureCapture()),
            ProofreadingCoordinator(service: AutoFailureProofreader(), capture: AutoCapture(autoSafe: true)),
            ProofreadingCoordinator(service: AutoProofreader(), timeout: 0.03, capture: AutoCapture(autoSafe: true))
        ]
        for (index, coordinator) in coordinators.enumerated() {
            var expansions: [Bool] = []
            coordinator.changed = { [weak coordinator] in expansions.append(coordinator?.reviewRequested ?? false) }
            coordinator.proofreadSelection(pid: 123, limit: 1500, mode: .clean)
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertEqual(coordinator.correctionStatus, index == 0 ? .noText : .failed)
            XCTAssertNotNil(coordinator.message)
            XCTAssertFalse(expansions.contains(true))
            XCTAssertFalse(coordinator.reviewRequested)
            XCTAssertFalse(coordinator.canApply)
            coordinator.requestReview()
            XCTAssertTrue(coordinator.reviewRequested)
        }
    }

    func testAutoExplicitReviewRequestDuringGenerationIsPreserved() async throws {
        for autoSafe in [false, true] {
            var pastes = 0
            let coordinator = ProofreadingCoordinator(service: AutoProofreader(), capture: AutoCapture(autoSafe: autoSafe),
                autoCheck: { _, _ in true }, insert: { _, _ in pastes += 1 })
            coordinator.proofreadSelection(pid: 123, limit: 1500, mode: .clean)
            coordinator.requestReview()
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertTrue(coordinator.reviewRequested)
            XCTAssertEqual(coordinator.correctionStatus, .review)
            XCTAssertEqual(pastes, 0)
        }
    }

    func testAutoIneligibleEditOpensReviewWithoutPasting() async throws {
        var pastes = 0
        let coordinator = ProofreadingCoordinator(service: AutoProofreader(), capture: AutoCapture(autoSafe: true),
            autoCheck: { _, _ in false }, insert: { _, _ in pastes += 1 })
        coordinator.proofreadSelection(pid: 123, limit: 1500, mode: .clean)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(pastes, 0)
        XCTAssertEqual(coordinator.correctionStatus, .review)
        XCTAssertTrue(coordinator.reviewRequested)
        XCTAssertTrue(coordinator.canApply)
        coordinator.requestReview()
        XCTAssertTrue(coordinator.reviewRequested)
        coordinator.apply()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(pastes, 1)
    }

    func testAutoCopyOnlySelectionOpensReviewWithoutReplacement() async throws {
        var pastes = 0
        let coordinator = ProofreadingCoordinator(service: AutoProofreader(), capture: IslandCopyCapture(),
            insert: { _, _ in pastes += 1 })
        coordinator.proofreadSelection(pid: 123, limit: 1500, mode: .clean)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(coordinator.copyOnly)
        XCTAssertTrue(coordinator.reviewRequested)
        XCTAssertEqual(coordinator.correctionStatus, .review)
        XCTAssertNotNil(coordinator.result)
        coordinator.requestReview()
        XCTAssertTrue(coordinator.reviewRequested)
        coordinator.apply()
        XCTAssertFalse(coordinator.canApply)
        XCTAssertEqual(pastes, 0)
    }

    func testExcludedAutoMessageStaysCompactAndManualMessageOpensReview() {
        let coordinator = ProofreadingCoordinator(service: AutoProofreader())
        coordinator.externalMessage(AppFailure.deniedApp.message)
        XCTAssertTrue(coordinator.reviewRequested)
        coordinator.externalMessage(AppFailure.deniedApp.message, mode: .clean)
        XCTAssertFalse(coordinator.reviewRequested)
        XCTAssertEqual(coordinator.correctionStatus, .failed)
        XCTAssertTrue(coordinator.usesAutoStatus)
        coordinator.requestReview()
        XCTAssertTrue(coordinator.reviewRequested)
        coordinator.externalMessage(AppFailure.noSelection.message)
        XCTAssertTrue(coordinator.reviewRequested)
        XCTAssertFalse(coordinator.usesAutoStatus)
    }

    func testExternalAutoRequiresKnownFormattingAndExpandsReview() async throws {
        var insertions = 0
        let coordinator = ProofreadingCoordinator(service: AutoProofreader(), capture: AutoCapture(autoSafe: false),
            autoCheck: { _, _ in true }, insert: { _, _ in insertions += 1 })
        coordinator.proofreadSelection(pid: 123, limit: 1500, mode: .clean)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(insertions, 0)
        XCTAssertNotNil(coordinator.result)
        XCTAssertTrue(coordinator.reviewRequested)
        XCTAssertEqual(coordinator.correctionStatus, .review)
        coordinator.requestReview()
        XCTAssertTrue(coordinator.reviewRequested)
    }
    func testExternalAutoStaysHiddenThroughGenerationPasteAndSuccessUntilRequested() async throws {
        var presentations: [Bool] = []
        var insertions = 0
        let coordinator = ProofreadingCoordinator(service: AutoProofreader(), capture: AutoCapture(autoSafe: true),
            autoCheck: { _, _ in true }, insert: { _, _ in
                insertions += 1
                try await Task.sleep(for: .milliseconds(50))
            })
        coordinator.changed = { [weak coordinator] in presentations.append(coordinator?.reviewRequested ?? false) }
        coordinator.proofreadSelection(pid: 123, limit: 1500, mode: .clean)
        XCTAssertTrue(coordinator.working)
        XCTAssertFalse(coordinator.reviewRequested)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(insertions, 1)
        XCTAssertFalse(presentations.isEmpty)
        XCTAssertFalse(presentations.contains(true))
        coordinator.cancel()
        XCTAssertFalse(coordinator.reviewRequested)
    }
    func testNoChangesAndAutoFailureStayCompactUntilRequested() async throws {
        let unchanged = ProofreadingCoordinator(service: AutoProofreader(unchanged: true), capture: AutoCapture(autoSafe: true))
        unchanged.proofreadSelection(pid: 123, limit: 1500, mode: .clean)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(unchanged.result?.isUnchanged == true)
        XCTAssertFalse(unchanged.reviewRequested)
        let failed = ProofreadingCoordinator(service: AutoProofreader(), capture: AutoCapture(autoSafe: true),
            autoCheck: { _, _ in true }, insert: { _, _ in throw AppFailure.focusChanged })
        failed.proofreadSelection(pid: 123, limit: 1500, mode: .clean)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(failed.reviewRequested)
        XCTAssertEqual(failed.correctionStatus, .failed)
        failed.requestReview()
        XCTAssertTrue(failed.reviewRequested)
        XCTAssertEqual(failed.message, AppFailure.focusChanged.message)
    }
    func testFailedExternalApplyDisablesRepeatPasteUntilANewRequest() async throws {
        for failure in [AppFailure.pasteFailed, .formattingChanged, .focusChanged] {
            var pastes = 0
            let coordinator = ProofreadingCoordinator(service: AutoProofreader(), capture: AutoCapture(autoSafe: true),
                autoCheck: { _, _ in true }, insert: { _, _ in pastes += 1; throw failure })
            coordinator.proofreadSelection(pid: 123, limit: 1500, mode: .clean)
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertFalse(coordinator.canApply)
            XCTAssertNotNil(coordinator.result)
            XCTAssertFalse(coordinator.reviewRequested)
            coordinator.apply()
            XCTAssertEqual(pastes, 1)
            coordinator.proofreadSelection(pid: 123, limit: 1500, mode: .clean)
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertEqual(pastes, 2)
        }
    }
    func testManualAndSentenceRequestsOpenReviewWhenReady() async throws {
        for command: Command in [.proofread, .improveSentences] {
            let coordinator = ProofreadingCoordinator(service: AutoProofreader(), capture: AutoCapture(autoSafe: true))
            coordinator.proofreadSelection(pid: 123, limit: 1500, command: command, mode: command == .improveSentences ? .clean : .off)
            XCTAssertEqual(coordinator.correctionStatus, .correcting)
            XCTAssertFalse(coordinator.reviewRequested, "The UI waits until generation completes to open review")
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertTrue(coordinator.reviewRequested)
            coordinator.cancel()
            XCTAssertFalse(coordinator.reviewRequested)
        }
    }
    func testExternalAutoChecksFocusPreservesClipboardAndDoesNotOfferAutomatedUndo() async throws {
        let capture = AutoCapture(autoSafe: true)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString("synthetic saved clipboard", forType: .string)
        var focused: pid_t = 123
        var pastes = 0
        let coordinator = ProofreadingCoordinator(service: AutoProofreader(), capture: capture,
            autoCheck: { _, _ in true }, insert: { correction, target in
                try await TextInserter(capture: capture, clipboard: ClipboardGuard(pasteboard: board),
                    frontmost: { focused }, paste: { pastes += 1 }, settleTime: .zero).apply(correction, to: target)
            })
        coordinator.proofreadSelection(pid: 123, limit: 1500, mode: .clean)
        focused = 999
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(pastes, 0)
        XCTAssertEqual(board.string(forType: .string), "synthetic saved clipboard")
        XCTAssertNotNil(coordinator.result)
        XCTAssertFalse(coordinator.reviewRequested)
        focused = 123
        coordinator.proofreadSelection(pid: 123, limit: 1500, mode: .clean)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(pastes, 1)
        XCTAssertEqual(board.string(forType: .string), "synthetic saved clipboard")
        XCTAssertFalse(coordinator.reviewRequested)
        XCTAssertEqual(pastes, 1)
    }
}
