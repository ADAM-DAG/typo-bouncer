import AppKit
import ApplicationServices
import BouncerCore
import XCTest
@testable import TypoBouncer

private final class FixtureAccessibility: SelectionAccessibility, @unchecked Sendable {
    enum SelectionWrite { case normal, delayed, delayedText, rejected, ignored, partial, focusLost, textChanged }
    struct State {
        var value = "This is teh first draft."
        var range = CFRange(location: 0, length: 24)
        var role = kAXTextAreaRole
        var subrole: String?
        var secureParent = false
        var valueReadable = true
        var valueSettable = true
        var selectionSettable = false
        var rangeSettable = true
        var selectionWrite: SelectionWrite = .normal
        var editable: Bool?
        var enabled = true
        var readOnly = false
        var attributed: NSAttributedString?
        var rtf: Data?
        var multipleRanges: [CFRange]?
        var primaryRangeReadable = true
        var reportedText: String?
        var characterCount: Int?
        var rangeValueReadable = true
        var ancestorCount = 0
        var secureDepth: Int?
        var cyclicParents = false
        var focused = true
        var foregroundPID: pid_t = 123
        var fieldBounds: CGRect?
        var selectionBounds: CGRect?
    }
    let element = AXUIElementCreateApplication(123)
    let parent = AXUIElementCreateApplication(456)
    let ancestors = (0..<128).map { AXUIElementCreateApplication(pid_t(1000 + $0)) }
    private let lock = NSLock()
    private var state = State()
    private var writes = 0
    private var pendingRange: CFRange?
    private var delayedReads = 0
    private var pendingReported: String?
    private var delayedTextReads = 0
    var selectionWrites: Int { lock.withLock { writes } }
    var foregroundPID: pid_t { lock.withLock { state.foregroundPID } }
    init() {
        state.range.length = state.value.utf16.count
        state.attributed = NSAttributedString(string: state.value)
    }
    func update(_ change: (inout State) -> Void) { lock.withLock { change(&state) } }
    func focusedElement(pid: pid_t) -> AXUIElement? { lock.withLock { state.focused ? element : nil } }
    func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        lock.withLock {
            if let index = ancestors.firstIndex(where: { CFEqual($0, element) }) {
                if name == kAXSubroleAttribute, state.secureDepth == index + 1 { return kAXSecureTextFieldSubrole as CFString }
                if name == kAXParentAttribute {
                    if index + 1 < state.ancestorCount { return ancestors[index + 1] }
                    return state.cyclicParents ? ancestors[0] : nil
                }
                return nil
            }
            if CFEqual(element, parent) {
                return name == kAXSubroleAttribute && state.secureParent ? kAXSecureTextFieldSubrole as CFString : nil
            }
            switch name {
            case kAXPositionAttribute:
                guard var point = state.fieldBounds?.origin else { return nil }
                return AXValueCreate(.cgPoint, &point)
            case kAXSizeAttribute:
                guard var size = state.fieldBounds?.size else { return nil }
                return AXValueCreate(.cgSize, &size)
            case kAXRoleAttribute: return state.role as CFString
            case kAXSubroleAttribute: return state.subrole as CFString?
            case kAXParentAttribute: return state.secureParent ? parent : (state.ancestorCount > 0 ? ancestors[0] : nil)
            case kAXEnabledAttribute: return state.enabled as CFBoolean
            case "AXReadOnly": return state.readOnly as CFBoolean
            case "AXEditable": return state.editable.map { $0 as CFBoolean }
            case kAXValueAttribute: return state.valueReadable ? state.value as CFString : nil
            case kAXNumberOfCharactersAttribute: return NSNumber(value: state.characterCount ?? state.value.utf16.count)
            case kAXSelectedTextRangeAttribute:
                if let pendingRange {
                    if delayedReads == 0 {
                        state.range = pendingRange
                        if state.reportedText != nil { state.reportedText = state.value }
                        self.pendingRange = nil
                    } else { delayedReads -= 1 }
                }
                return state.primaryRangeReadable ? rangeValue(state.range) : nil
            case kAXSelectedTextRangesAttribute: return state.multipleRanges.map { $0.compactMap(rangeValue) as CFArray }
            case kAXSelectedTextAttribute:
                if let pendingReported {
                    if delayedTextReads == 0 { state.reportedText = pendingReported; self.pendingReported = nil }
                    else { delayedTextReads -= 1 }
                }
                return state.reportedText as CFString?
            default: return nil
            }
        }
    }
    func parameter(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) -> CFTypeRef? {
        lock.withLock {
            switch name {
            case kAXBoundsForRangeParameterizedAttribute:
                var input = CFRange()
                guard CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetValue(value as! AXValue, .cfRange, &input) else { return nil }
                guard var rect = state.selectionBounds else { return nil }
                return AXValueCreate(.cgRect, &rect)
            case kAXStringForRangeParameterizedAttribute: return state.rangeValueReadable ? state.value as CFString : nil
            case kAXAttributedStringForRangeParameterizedAttribute: return state.attributed
            case kAXRTFForRangeParameterizedAttribute: return state.rtf as CFData?
            default: return nil
            }
        }
    }
    func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        lock.withLock {
            switch name {
            case kAXValueAttribute: state.valueSettable
            case kAXSelectedTextAttribute: state.selectionSettable
            case kAXSelectedTextRangeAttribute: state.rangeSettable
            default: false
            }
        }
    }
    func setSelectedRange(_ element: AXUIElement, _ range: CFRange) -> Bool {
        lock.withLock {
            writes += 1
            guard state.rangeSettable, state.selectionWrite != .rejected else { return false }
            if state.selectionWrite == .ignored { return true }
            if state.selectionWrite == .delayed {
                pendingRange = range; delayedReads = 3
                return true
            }
            state.range = state.selectionWrite == .partial ? CFRange(location: 0, length: 1) : range
            if state.multipleRanges != nil { state.multipleRanges = [state.range] }
            if state.reportedText != nil, let selected = Range(NSRange(location: state.range.location, length: state.range.length), in: state.value) {
                if state.selectionWrite == .delayedText {
                    pendingReported = String(state.value[selected]); delayedTextReads = 3
                } else { state.reportedText = String(state.value[selected]) }
            }
            if state.selectionWrite == .focusLost { state.focused = false }
            if state.selectionWrite == .textChanged { state.value = "A newer draft." }
            return true
        }
    }
    private func rangeValue(_ input: CFRange) -> AXValue? {
        var range = input; return AXValueCreate(.cfRange, &range)
    }
}

final class SelectionCompatibilityTests: XCTestCase {
    func testEmptyFieldFeedbackReadsOnlyGeometryAndNeverChangesTheSelection() async throws {
        let fixture = FixtureAccessibility()
        let bounds = CGRect(x: 100, y: 200, width: 600, height: 80)
        fixture.update {
            $0.value = ""; $0.range = CFRange(location: 0, length: 0); $0.fieldBounds = bounds
            $0.valueReadable = false; $0.rangeValueReadable = false; $0.primaryRangeReadable = false
            $0.valueSettable = false; $0.editable = true
        }
        let capture = SelectionCapture(accessibility: fixture, frontmost: { 123 })
        let anchor = await capture.focusedFieldAnchor(pid: 123)
        XCTAssertEqual(anchor, SelectionAnchor(field: bounds))
        XCTAssertEqual(fixture.selectionWrites, 0)
        fixture.update { $0.secureParent = true }
        let secure = await capture.focusedFieldAnchor(pid: 123)
        XCTAssertNil(secure)
        fixture.update { $0.secureParent = false; $0.editable = false }
        let readOnly = await capture.focusedFieldAnchor(pid: 123)
        XCTAssertNil(readOnly)
        fixture.update { $0.editable = true }
        let inactive = SelectionCapture(accessibility: fixture, frontmost: { 456 })
        let background = await inactive.focusedFieldAnchor(pid: 123)
        XCTAssertNil(background)
        XCTAssertEqual(fixture.selectionWrites, 0)
    }

    func testFocusedFieldSelectionRequiresOptInAndSelectsWholeUTF16Value() async throws {
        let fixture = FixtureAccessibility()
        let original = "Hi 👩🏽‍💻, this is teh draft.\nSecond line."
        fixture.update {
            $0.value = original; $0.range = CFRange(location: original.utf16.count, length: 0)
            $0.reportedText = ""; $0.attributed = nil; $0.role = kAXTextFieldRole
        }
        let capture = SelectionCapture(accessibility: fixture, frontmost: { 123 })
        do { _ = try await capture.capture(pid: 123); XCTFail("Selection was expanded without opting in") }
        catch { XCTAssertEqual(error as? AppFailure, .noSelection) }
        XCTAssertEqual(fixture.selectionWrites, 0)
        let target = try await capture.capture(pid: 123, selectFocusedText: true, limit: 1500)
        XCTAssertEqual(target.text, original)
        XCTAssertEqual(target.range?.location, 0)
        XCTAssertEqual(target.range?.length, original.utf16.count)
        XCTAssertTrue(target.canAutoReplace)
        XCTAssertEqual(fixture.selectionWrites, 1)
        try await capture.verify(target)
        XCTAssertEqual(fixture.selectionWrites, 1, "Apply verification must not select again")
        fixture.update { $0.range = CFRange(location: 0, length: 0) }
        do { try await capture.verify(target); XCTFail("A changed selection was reselected") }
        catch { }
        XCTAssertEqual(fixture.selectionWrites, 1)
    }

    func testDelayedFocusedFieldSelectionCompletesWithinOneCapture() async throws {
        for behavior in [FixtureAccessibility.SelectionWrite.delayed, .delayedText] {
            let fixture = FixtureAccessibility()
            fixture.update { $0.range = CFRange(location: 5, length: 0); $0.reportedText = ""; $0.selectionWrite = behavior }
            let capture = SelectionCapture(accessibility: fixture, frontmost: { 123 })
            let target = try await capture.capture(pid: 123, selectFocusedText: true, limit: 1500)
            XCTAssertEqual(target.text, "This is teh first draft.")
            XCTAssertEqual(target.range?.location, 0)
            XCTAssertEqual(target.range?.length, target.text.utf16.count)
            XCTAssertEqual(fixture.selectionWrites, 1)
            try await capture.verify(target)
            XCTAssertEqual(fixture.selectionWrites, 1, "Verification must never select again")
        }
    }

    @MainActor func testPendingSelectionStopsOnFocusTextSecurityAndSelectionChanges() async throws {
        for variant in 0..<8 {
            let fixture = FixtureAccessibility()
            fixture.update { $0.range = CFRange(location: 5, length: 0); $0.selectionWrite = .ignored }
            let capture = SelectionCapture(accessibility: fixture, frontmost: { fixture.foregroundPID })
            let request = Task { try await capture.capture(pid: 123, selectFocusedText: true, limit: 1500) }
            while fixture.selectionWrites == 0 { await Task.yield() }
            fixture.update {
                switch variant {
                case 0: $0.foregroundPID = 456
                case 1: $0.focused = false
                case 2: $0.value = "A newer draft."
                case 3: $0.range = CFRange(location: 0, length: 1)
                case 4: $0.range = CFRange(location: 8, length: 0)
                case 5: $0.secureParent = true
                case 6: $0.readOnly = true
                default: $0.primaryRangeReadable = false
                }
            }
            do { _ = try await request.value; XCTFail("Changed field accepted in variant \(variant)") }
            catch { }
            XCTAssertEqual(fixture.selectionWrites, 1, "Waiting must never issue another selection write")
        }
    }

    @MainActor func testCancellationDuringSelectionReadbackDoesNotRetry() async throws {
        let fixture = FixtureAccessibility()
        fixture.update { $0.range = CFRange(location: 5, length: 0); $0.selectionWrite = .ignored }
        let capture = SelectionCapture(accessibility: fixture, frontmost: { 123 })
        let request = Task { try await capture.capture(pid: 123, selectFocusedText: true, limit: 1500) }
        while fixture.selectionWrites == 0 { await Task.yield() }
        request.cancel()
        do { _ = try await request.value; XCTFail("Cancelled readback returned a target") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(fixture.selectionWrites, 1)
    }

    func testFocusedFieldOptionKeepsExistingPartialSelection() async throws {
        let fixture = FixtureAccessibility()
        fixture.update { $0.range = CFRange(location: 8, length: 3); $0.attributed = nil }
        let capture = SelectionCapture(accessibility: fixture, frontmost: { 123 })
        let target = try await capture.capture(pid: 123, selectFocusedText: true, limit: 1500)
        XCTAssertEqual(target.text, "teh")
        XCTAssertEqual(target.range?.location, 8)
        XCTAssertEqual(fixture.selectionWrites, 0)
    }

    func testFocusedFieldRefusesUnsafeAndUnavailableControlsBeforeSelecting() async throws {
        for variant in 0..<11 {
            let fixture = FixtureAccessibility()
            fixture.update {
                $0.range = CFRange(location: 0, length: 0)
                switch variant {
                case 0: $0.valueSettable = false
                case 1: $0.readOnly = true
                case 2: $0.enabled = false
                case 3: $0.rangeSettable = false
                case 4: $0.secureParent = true
                case 5: $0.valueReadable = false; $0.rangeValueReadable = false
                case 6: $0.multipleRanges = [CFRange(location: 0, length: 0), CFRange(location: 2, length: 0)]
                case 7: $0.primaryRangeReadable = false
                case 8: $0.range = CFRange(location: 999, length: 0)
                case 9: $0.reportedText = "stale selection"
                default: $0.focused = false
                }
            }
            let capture = SelectionCapture(accessibility: fixture, frontmost: { 123 })
            do { _ = try await capture.capture(pid: 123, selectFocusedText: true, limit: 1500); XCTFail("Unsafe variant \(variant) was selected") }
            catch { }
            XCTAssertEqual(fixture.selectionWrites, 0)
        }
    }

    func testFocusedFieldRejectsEmptyWhitespaceAndOverLimitBeforeSelecting() async throws {
        for value in ["", " \t\n", String(repeating: "a", count: 1501)] {
            let fixture = FixtureAccessibility()
            fixture.update { $0.value = value; $0.range = CFRange(location: 0, length: 0) }
            let capture = SelectionCapture(accessibility: fixture, frontmost: { 123 })
            do { _ = try await capture.capture(pid: 123, selectFocusedText: true, limit: 1500); XCTFail("Invalid whole-field text was selected") }
            catch { XCTAssertTrue(error is SelectionError) }
            XCTAssertEqual(fixture.selectionWrites, 0)
        }
    }

    func testFocusedFieldSupportsParameterizedFullValueAndRequiresKnownFormattingForAuto() async throws {
        let fixture = FixtureAccessibility()
        fixture.update { $0.range = CFRange(location: 5, length: 0); $0.valueReadable = false; $0.attributed = nil }
        let capture = SelectionCapture(accessibility: fixture, frontmost: { 123 })
        let target = try await capture.capture(pid: 123, selectFocusedText: true, limit: 1500)
        XCTAssertEqual(target.text, "This is teh first draft.")
        XCTAssertTrue(target.canReplace)
        XCTAssertFalse(target.canAutoReplace)
        try await capture.verify(target)
    }

    func testFocusedFieldRefusesInactiveAppBeforeSelection() async throws {
        let fixture = FixtureAccessibility()
        fixture.update { $0.range = CFRange(location: 0, length: 0) }
        let capture = SelectionCapture(accessibility: fixture, frontmost: { 999 })
        do { _ = try await capture.capture(pid: 123, selectFocusedText: true, limit: 1500); XCTFail("Background app was selected") }
        catch { XCTAssertEqual(error as? AppFailure, .focusChanged) }
        XCTAssertEqual(fixture.selectionWrites, 0)
    }

    func testFocusedFieldRejectsFailedPartialOrStaleSelectionWrites() async throws {
        for behavior in [FixtureAccessibility.SelectionWrite.rejected, .ignored, .partial, .focusLost, .textChanged] {
            let fixture = FixtureAccessibility()
            fixture.update { $0.range = CFRange(location: 0, length: 0); $0.selectionWrite = behavior }
            let capture = SelectionCapture(accessibility: fixture, frontmost: { 123 })
            do { _ = try await capture.capture(pid: 123, selectFocusedText: true, limit: 1500); XCTFail("Invalid selection write was accepted") }
            catch { }
            XCTAssertEqual(fixture.selectionWrites, 1)
        }
    }

    @MainActor func testCancelledFocusedFieldCaptureDoesNotSelect() async throws {
        let fixture = FixtureAccessibility()
        fixture.update { $0.range = CFRange(location: 0, length: 0) }
        let capture = SelectionCapture(accessibility: fixture, frontmost: { 123 })
        let request = Task { try await capture.capture(pid: 123, selectFocusedText: true, limit: 1500) }
        request.cancel()
        do { _ = try await request.value; XCTFail("Cancelled capture selected text") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(fixture.selectionWrites, 0)
    }

    func testDraftValidityDetectsSendAndEditsEvenWhenFieldAndFocusStayTheSame() async throws {
        let fixture = FixtureAccessibility()
        let capture = SelectionCapture(accessibility: fixture)
        let target = try await capture.capture(pid: 123)
        // Review owns focus; checking the original element must still work.
        fixture.update { $0.focused = false }
        let intact = await capture.containsDraft(target, replacement: nil)
        XCTAssertTrue(intact)
        fixture.update { $0.focused = true; $0.value = ""; $0.range = CFRange(location: 0, length: 0) }
        let sent = await capture.containsDraft(target, replacement: nil)
        XCTAssertFalse(sent)
        fixture.update { $0.value = "A different draft." }
        let edited = await capture.containsDraft(target, replacement: nil)
        XCTAssertFalse(edited)
    }

    func testAppliedDraftRemainsCurrentUntilSentAndChecksUnselectedSurroundings() async throws {
        let fixture = FixtureAccessibility()
        fixture.update { $0.range = CFRange(location: 8, length: 3); $0.attributed = nil }
        let capture = SelectionCapture(accessibility: fixture)
        let target = try await capture.capture(pid: 123)
        fixture.update { $0.value = "This is the first draft."; $0.range = CFRange(location: 11, length: 0) }
        let applied = await capture.containsDraft(target, replacement: "the")
        let original = await capture.containsDraft(target, replacement: nil)
        XCTAssertTrue(applied)
        XCTAssertFalse(original)
        fixture.update { $0.value = "This is the second draft." }
        let changedElsewhere = await capture.containsDraft(target, replacement: "the")
        XCTAssertFalse(changedElsewhere)
        fixture.update { $0.value = "" }
        let sent = await capture.containsDraft(target, replacement: "the")
        XCTAssertFalse(sent)
    }

    func testReadOnlyDraftCanExpireWithoutReplacementPermission() async throws {
        let fixture = FixtureAccessibility()
        fixture.update { $0.valueSettable = false }
        let capture = SelectionCapture(accessibility: fixture)
        let target = try await capture.capture(pid: 123)
        XCTAssertFalse(target.canReplace)
        let intact = await capture.containsDraft(target, replacement: nil)
        XCTAssertTrue(intact)
        fixture.update { $0.value = "" }
        let sent = await capture.containsDraft(target, replacement: nil)
        XCTAssertFalse(sent)
    }

    func testSelectedTextOnlyDraftExpiresEvenIfSendLeavesStaleSelectedText() async throws {
        let fixture = FixtureAccessibility()
        fixture.update { $0.valueReadable = false; $0.rangeValueReadable = false; $0.reportedText = $0.value }
        let capture = SelectionCapture(accessibility: fixture)
        let target = try await capture.capture(pid: 123)
        XCTAssertNil(target.fullValue)
        let intact = await capture.containsDraft(target, replacement: nil)
        XCTAssertTrue(intact)
        fixture.update { $0.value = "" } // Selected text deliberately remains stale.
        let sent = await capture.containsDraft(target, replacement: nil)
        XCTAssertFalse(sent)
        fixture.update { $0.value = target.text; $0.reportedText = nil }
        let unavailable = await capture.containsDraft(target, replacement: nil)
        XCTAssertFalse(unavailable)
    }

    func testSelectionGeometryTracksMovementClipsToFieldAndStopsOnFocusLoss() async throws {
        let fixture = FixtureAccessibility()
        fixture.update {
            $0.fieldBounds = CGRect(x: 100, y: 200, width: 400, height: 120)
            $0.selectionBounds = CGRect(x: 110, y: 190, width: 200, height: 30)
        }
        let capture = SelectionCapture(accessibility: fixture)
        let target = try await capture.capture(pid: 123)
        XCTAssertEqual(target.anchor.selection, CGRect(x: 110, y: 200, width: 200, height: 20))
        XCTAssertTrue(target.canAutoReplace)
        fixture.update { $0.selectionBounds = CGRect(x: 120, y: 230, width: 180, height: 22) }
        let moved = await capture.presentationAnchor(for: target)
        XCTAssertEqual(moved?.selection, CGRect(x: 120, y: 230, width: 180, height: 22))
        fixture.update { $0.focused = false }
        let lost = await capture.presentationAnchor(for: target)
        XCTAssertNil(lost)
    }

    func testMissingOrInvalidGeometryDoesNotDisableOtherwiseValidAuto() async throws {
        let fixture = FixtureAccessibility()
        let capture = SelectionCapture(accessibility: fixture)
        let target = try await capture.capture(pid: 123)
        XCTAssertNil(target.anchor.selection)
        XCTAssertNil(target.anchor.field)
        XCTAssertTrue(target.canAutoReplace)
        fixture.update { $0.selectionBounds = CGRect(x: 100, y: 200, width: 0, height: 20) }
        let invalid = await capture.presentationAnchor(for: target)
        XCTAssertNil(invalid?.selection)
        XCTAssertFalse(SelectionAnchor.valid(CGRect(x: CGFloat.infinity, y: 0, width: 20, height: 20)))
    }

    func testDeepElectronComposerIsSupportedButSecureAncestorsAndCyclesAreRejected() async throws {
        let fixture = FixtureAccessibility()
        fixture.update { $0.ancestorCount = 40 }
        let capture = SelectionCapture(accessibility: fixture)
        let selected = try await capture.capture(pid: 123)
        XCTAssertTrue(selected.canAutoReplace)
        try await capture.verify(selected)
        fixture.update { $0.secureDepth = 30 }
        do { _ = try await capture.capture(pid: 123); XCTFail("Deep secure field accepted") }
        catch { XCTAssertEqual(error as? AppFailure, .secureField) }
        fixture.update { $0.secureDepth = nil; $0.cyclicParents = true }
        do { _ = try await capture.capture(pid: 123); XCTFail("Cyclic ancestry accepted") }
        catch { XCTAssertEqual(error as? AppFailure, .noSelection) }
    }
    func testCustomEditorRolesUseCapabilitiesAndRecheckEditability() async throws {
        for role in [kAXGroupRole, kAXUnknownRole] {
            let fixture = FixtureAccessibility()
            fixture.update { $0.role = role }
            let capture = SelectionCapture(accessibility: fixture)
            let selected = try await capture.capture(pid: 123)
            XCTAssertTrue(selected.canAutoReplace)
            fixture.update { $0.valueSettable = false }
            do { try await capture.verify(selected); XCTFail("Read-only custom editor accepted") }
            catch { XCTAssertEqual(error as? AppFailure, .focusChanged) }
        }
    }
    func testSelectedTextWithoutFullSnapshotIsCopyOnlyAndCannotConfirmAPaste() async throws {
        for hasRange in [true, false] {
            let fixture = FixtureAccessibility()
            fixture.update {
                $0.valueReadable = false; $0.rangeValueReadable = false
                $0.primaryRangeReadable = hasRange; $0.reportedText = $0.value
            }
            let capture = SelectionCapture(accessibility: fixture)
            let selected = try await capture.capture(pid: 123)
            XCTAssertEqual(selected.text, "This is teh first draft.")
            XCTAssertFalse(selected.canReplace)
            XCTAssertFalse(selected.canAutoReplace)
            XCTAssertNil(selected.fullValue)
            do { try await capture.verify(selected); XCTFail("Copy-only capture verified for replacement") }
            catch { XCTAssertEqual(error as? AppFailure, .focusChanged) }
            let confirmed = await capture.confirms(selected, replacement: "This is the first draft.")
            XCTAssertFalse(confirmed)
        }
    }
    func testCopyOnlyFallbackDoesNotBypassInvalidOrSecureSelections() async throws {
        for variant in 0..<4 {
            let fixture = FixtureAccessibility()
            fixture.update {
                $0.valueReadable = false; $0.rangeValueReadable = false; $0.reportedText = $0.value
                switch variant {
                case 0: $0.multipleRanges = [$0.range, $0.range]
                case 1: $0.range.length = 0
                case 2: $0.range.length = 1
                default: $0.secureParent = true
                }
            }
            do { _ = try await SelectionCapture(accessibility: fixture).capture(pid: 123); XCTFail("Unsafe fallback accepted") }
            catch { XCTAssertEqual(error as? AppFailure, variant == 3 ? .secureField : .noSelection) }
        }
    }
    func testBrowserAndElectronMultilineFieldsAcceptUniformPresentationAndSpellingRuns() async throws {
        let fixture = FixtureAccessibility()
        fixture.update { state in
            let style: [NSAttributedString.Key: Any] = [.accessibilityFont: ["AXFontName": "Arial", "AXFontSize": 14]]
            let attributed = NSMutableAttributedString(string: state.value, attributes: style)
            attributed.addAttribute(.accessibilityMarkedMisspelled, value: true, range: NSRange(location: 8, length: 3))
            state.attributed = attributed
        }
        let captured = try await SelectionCapture(accessibility: fixture).capture(pid: 123)
        XCTAssertTrue(captured.canReplace)
        XCTAssertTrue(captured.canAutoReplace)
    }
    func testEditorsCanExposeEditableOrSelectedTextWithoutSettableFullValue() async throws {
        for usesEditable in [true, false] {
            let fixture = FixtureAccessibility()
            fixture.update { state in
                state.valueSettable = false
                state.editable = usesEditable ? true : nil
                state.selectionSettable = !usesEditable
            }
            let capture = SelectionCapture(accessibility: fixture)
            let selected = try await capture.capture(pid: 123)
            XCTAssertTrue(selected.canAutoReplace)
            try await capture.verify(selected)
        }
    }
    func testReadOnlyDisabledAndMerelySelectableFieldsCannotReplace() async throws {
        for variant in 0..<3 {
            let fixture = FixtureAccessibility()
            fixture.update { state in
                if variant == 0 { state.readOnly = true }
                if variant == 1 { state.enabled = false }
                if variant == 2 { state.valueSettable = false; state.editable = nil }
            }
            let selected = try await SelectionCapture(accessibility: fixture).capture(pid: 123)
            XCTAssertFalse(selected.canReplace)
            XCTAssertFalse(selected.canAutoReplace)
        }
    }
    func testParameterizedFullValueAndSingleRangeArraySupportUnicodeAndConfirmation() async throws {
        let fixture = FixtureAccessibility()
        let original = "😊 前 This is teh first draft. 後"
        let range = (original as NSString).range(of: "This is teh first draft.")
        fixture.update { state in
            state.value = original; state.range = CFRange(location: range.location, length: range.length)
            state.valueReadable = false; state.primaryRangeReadable = false
            state.multipleRanges = [state.range]
            state.attributed = NSAttributedString(string: "This is teh first draft.")
        }
        let capture = SelectionCapture(accessibility: fixture)
        let selected = try await capture.capture(pid: 123)
        XCTAssertEqual(selected.text, "This is teh first draft.")
        XCTAssertTrue(selected.canAutoReplace)
        try await capture.verify(selected)
        fixture.update { $0.value = original.replacingOccurrences(of: "teh", with: "the") }
        let confirmed = await capture.confirms(selected, replacement: "This is the first draft.")
        XCTAssertTrue(confirmed)
        fixture.update { $0.value += " typed later" }
        let stale = await capture.confirms(selected, replacement: "This is the first draft.")
        XCTAssertFalse(stale)
    }
    func testMultipleInconsistentOverflowAndOutOfBoundsRangesAreRejected() async throws {
        for variant in 0..<4 {
            let fixture = FixtureAccessibility()
            fixture.update { state in
                switch variant {
                case 0: state.multipleRanges = [state.range, CFRange(location: 1, length: 2)]
                case 1: state.multipleRanges = [CFRange(location: 1, length: 2)]
                case 2: state.range = CFRange(location: Int.max, length: 2)
                default: state.range = CFRange(location: 1, length: 999)
                }
            }
            do { _ = try await SelectionCapture(accessibility: fixture).capture(pid: 123); XCTFail("Invalid selection accepted") }
            catch { XCTAssertEqual(error as? AppFailure, .noSelection) }
        }
    }
    func testSecureAncestorAndContradictoryReportedSelectionAreRejected() async throws {
        let fixture = FixtureAccessibility()
        fixture.update { $0.secureParent = true }
        do { _ = try await SelectionCapture(accessibility: fixture).capture(pid: 123); XCTFail("Secure field accepted") }
        catch { XCTAssertEqual(error as? AppFailure, .secureField) }
        fixture.update { $0.secureParent = false; $0.reportedText = "Different selection" }
        do { _ = try await SelectionCapture(accessibility: fixture).capture(pid: 123); XCTFail("Mismatch accepted") }
        catch { XCTAssertEqual(error as? AppFailure, .focusChanged) }
    }
    func testFormattingAndEditabilityAreRecheckedBeforePaste() async throws {
        let fixture = FixtureAccessibility()
        let capture = SelectionCapture(accessibility: fixture)
        let selected = try await capture.capture(pid: 123)
        fixture.update { $0.attributed = NSAttributedString(string: $0.value, attributes: [.accessibilityFontBoldAttribute: true]) }
        do { try await capture.verify(selected); XCTFail("Changed formatting accepted") }
        catch { XCTAssertEqual(error as? AppFailure, .focusChanged) }
        fixture.update { $0.attributed = NSAttributedString(string: $0.value); $0.readOnly = true }
        do { try await capture.verify(selected); XCTFail("Changed editability accepted") }
        catch { XCTAssertEqual(error as? AppFailure, .focusChanged) }
    }
    func testUnknownMixedLinkedOrMalformedFormattingNeedsReview() async throws {
        for variant in 0..<4 {
            let fixture = FixtureAccessibility()
            fixture.update { state in
                switch variant {
                case 0: state.attributed = nil
                case 1:
                    let mixed = NSMutableAttributedString(string: state.value)
                    mixed.addAttribute(.accessibilityFontBoldAttribute, value: true, range: NSRange(location: 0, length: 4))
                    state.attributed = mixed
                case 2: state.attributed = NSAttributedString(string: state.value, attributes: [.accessibilityLink: "link"])
                default: state.rtf = Data("invalid synthetic RTF".utf8)
                }
            }
            let selected = try await SelectionCapture(accessibility: fixture).capture(pid: 123)
            XCTAssertTrue(selected.canReplace)
            XCTAssertFalse(selected.canAutoReplace)
        }
    }
    func testParameterizedValueMustMatchReportedCharacterCount() async throws {
        let fixture = FixtureAccessibility()
        fixture.update { $0.valueReadable = false; $0.characterCount = 999 }
        do { _ = try await SelectionCapture(accessibility: fixture).capture(pid: 123); XCTFail("Partial value accepted") }
        catch { XCTAssertEqual(error as? AppFailure, .noSelection) }
    }
}

@MainActor final class RichReplacementTests: XCTestCase {
    private func rtf(_ source: NSAttributedString) throws -> Data {
        try XCTUnwrap(source.rtf(from: NSRange(location: 0, length: source.length), documentAttributes: [:]))
    }
    func testRichCorrectionPreservesBoldColorLinkEmojiAndUntouchedRuns() throws {
        let original = "😊 This is teh first draft. Link"
        let source = NSMutableAttributedString(string: original, attributes: [.font: NSFont.systemFont(ofSize: 16)])
        let typo = (original as NSString).range(of: "teh")
        source.addAttributes([.font: NSFont.boldSystemFont(ofSize: 16), .foregroundColor: NSColor.red], range: typo)
        source.addAttribute(.link, value: "synthetic-link", range: (original as NSString).range(of: "Link"))
        let data = try rtf(source)
        let formatting = try XCTUnwrap(SelectionFormatting.richText(data, matching: original))
        XCTAssertTrue(formatting.supportsAuto)
        let corrected = original.replacingOccurrences(of: "teh", with: "the")
        let resultData = try XCTUnwrap(formatting.replacementRTF(original: original, corrected: corrected))
        let result = try NSAttributedString(data: resultData, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        let baseline = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        XCTAssertEqual(result.string, corrected)
        XCTAssertTrue((result.attributes(at: typo.location, effectiveRange: nil) as NSDictionary).isEqual(to: baseline.attributes(at: typo.location, effectiveRange: nil)))
        XCTAssertTrue(result.attributedSubstring(from: NSRange(location: 0, length: typo.location)).isEqual(to: baseline.attributedSubstring(from: NSRange(location: 0, length: typo.location))))
        XCTAssertEqual(result.attribute(.link, at: result.length - 1, effectiveRange: nil) as? URL,
                       baseline.attribute(.link, at: baseline.length - 1, effectiveRange: nil) as? URL)
    }
    func testQuestionMarkInheritsStyleAndVariableLengthTypoKeepsFollowingFormatting() throws {
        let original = "Can you help me with teh adress"
        let source = NSMutableAttributedString(string: original, attributes: [.font: NSFont.systemFont(ofSize: 15)])
        source.addAttribute(.foregroundColor, value: NSColor.blue, range: (original as NSString).range(of: "adress"))
        let formatting = try XCTUnwrap(SelectionFormatting.richText(rtf(source), matching: original))
        let corrected = "Can you help me with the address?"
        let resultData = try XCTUnwrap(formatting.replacementRTF(original: original, corrected: corrected))
        let result = try NSAttributedString(data: resultData, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        XCTAssertEqual(result.string, corrected)
        let color = result.attribute(.foregroundColor, at: result.length - 1, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color?.usingColorSpace(.deviceRGB)?.blueComponent ?? 0, 1, accuracy: 0.01)
    }
    func testAmbiguousStyleEditIsRefusedBeforeClipboardWrite() async throws {
        let source = NSMutableAttributedString(string: "teh", attributes: [.font: NSFont.systemFont(ofSize: 15)])
        source.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 1, length: 1))
        let formatting = try XCTUnwrap(SelectionFormatting.richText(rtf(source), matching: "teh"))
        let target = CapturedSelection(element: AXUIElementCreateApplication(123), canReplace: true, pid: 123,
            text: "teh", range: CFRange(location: 0, length: 3), fullValue: "teh", digest: Data(), canAutoReplace: true, formatting: formatting)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString("saved synthetic clipboard", forType: .string)
        let count = board.changeCount
        var pasted = false
        let inserter = TextInserter(capture: RichVerifier(), clipboard: ClipboardGuard(pasteboard: board),
            frontmost: { 123 }, paste: { pasted = true }, settleTime: .zero)
        do { try await inserter.apply("the", to: target); XCTFail("Mixed-style word flattened") }
        catch { XCTAssertEqual(error as? AppFailure, .formattingChanged) }
        XCTAssertFalse(pasted)
        XCTAssertEqual(board.changeCount, count)
    }
    func testRichClipboardPayloadAndPollingConfirmWithoutRepeatingPaste() async throws {
        let source = NSAttributedString(string: "teh", attributes: [.font: NSFont.boldSystemFont(ofSize: 15)])
        let formatting = try XCTUnwrap(SelectionFormatting.richText(rtf(source), matching: "teh"))
        let target = CapturedSelection(element: AXUIElementCreateApplication(123), canReplace: true, pid: 123,
            text: "teh", range: CFRange(location: 0, length: 3), fullValue: "teh", digest: Data(), formatting: formatting)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString("saved synthetic clipboard", forType: .string)
        var pasted = 0
        let inserter = TextInserter(capture: RichVerifier(confirmAfter: 2), clipboard: ClipboardGuard(pasteboard: board),
            frontmost: { 123 }, paste: {
                pasted += 1
                XCTAssertEqual(board.string(forType: .string), "the")
                XCTAssertNotNil(board.data(forType: .rtf))
            }, settleTime: .milliseconds(200))
        try await inserter.apply("the", to: target)
        XCTAssertEqual(pasted, 1)
        XCTAssertEqual(board.string(forType: .string), "saved synthetic clipboard")
        XCTAssertNil(board.data(forType: .rtf))
    }
    func testFocusedFieldSelectionFlowsThroughBothActionsAndAutoModes() async throws {
        for command in [Command.proofread, .improveSentences] {
            for mode in AutoMode.allCases {
                let fixture = FixtureAccessibility()
                fixture.update { $0.range = CFRange(location: 5, length: 0) }
                let capture = SelectionCapture(accessibility: fixture, frontmost: { 123 })
                let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
                board.setString("saved synthetic clipboard", forType: .string)
                var pastes = 0
                let coordinator = ProofreadingCoordinator(service: CompatibilityProofreader(), capture: capture,
                    autoCheck: { _, _ in true }, insert: { corrected, selected in
                        try await TextInserter(capture: capture, clipboard: ClipboardGuard(pasteboard: board),
                            frontmost: { 123 }, paste: { pastes += 1; fixture.update { $0.value = corrected } },
                            settleTime: .zero).apply(corrected, to: selected)
                    })
                coordinator.proofreadSelection(pid: 123, limit: 1500, command: command, mode: mode, selectFocusedText: true)
                for _ in 0..<100 {
                    if !coordinator.working && !coordinator.applying { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let automatic = mode == .full || (mode == .clean && command == .proofread)
                XCTAssertEqual(fixture.selectionWrites, 1)
                XCTAssertEqual(pastes, automatic ? 1 : 0)
                XCTAssertEqual(coordinator.reviewRequested, !automatic)
                if !automatic {
                    XCTAssertEqual(coordinator.result?.original, "This is teh first draft.")
                    coordinator.apply()
                    for _ in 0..<100 {
                        if !coordinator.applying { break }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
                XCTAssertEqual(pastes, 1)
                XCTAssertEqual(fixture.selectionWrites, 1)
                XCTAssertEqual(coordinator.appliedCorrection?.corrected, "This is the first draft.")
                XCTAssertEqual(board.string(forType: .string), "saved synthetic clipboard")
            }
        }
    }

    func testDelayedWholeFieldSelectionAppliesWithOneShortcutRequest() async throws {
        for behavior in [FixtureAccessibility.SelectionWrite.delayed, .delayedText] {
            for command in [Command.proofread, .improveSentences] {
                let fixture = FixtureAccessibility()
                fixture.update { $0.range = CFRange(location: 5, length: 0); $0.reportedText = ""; $0.selectionWrite = behavior }
                let capture = SelectionCapture(accessibility: fixture, frontmost: { 123 })
                let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
                board.setString("saved synthetic clipboard", forType: .string)
                var pastes = 0
                let coordinator = ProofreadingCoordinator(service: CompatibilityProofreader(), capture: capture,
                    insert: { corrected, selected in
                        try await TextInserter(capture: capture, clipboard: ClipboardGuard(pasteboard: board),
                            frontmost: { 123 }, paste: { pastes += 1; fixture.update { $0.value = corrected } },
                            settleTime: .zero).apply(corrected, to: selected)
                    })
                coordinator.proofreadSelection(pid: 123, limit: 1500, command: command, mode: .full, selectFocusedText: true)
                for _ in 0..<100 {
                    if !coordinator.working && !coordinator.applying { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertEqual(coordinator.correctionStatus, .applied)
                XCTAssertEqual(pastes, 1)
                XCTAssertEqual(fixture.selectionWrites, 1)
                XCTAssertEqual(board.string(forType: .string), "saved synthetic clipboard")
            }
        }
    }

    func testAutoPipelineSupportsBrowserPresentationAndNativeRichFormattingSilently() async throws {
        for rich in [false, true] {
            let fixture = FixtureAccessibility()
            if rich {
                let source = NSMutableAttributedString(string: "This is teh first draft.", attributes: [.font: NSFont.systemFont(ofSize: 16)])
                source.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 16), range: NSRange(location: 8, length: 3))
                let data = try rtf(source)
                fixture.update { $0.rtf = data }
            } else {
                fixture.update { state in
                    state.attributed = NSAttributedString(string: state.value, attributes: [.accessibilityFont: ["AXFontName": "Arial", "AXFontSize": 14]])
                }
            }
            let capture = SelectionCapture(accessibility: fixture)
            let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
            board.setString("saved synthetic clipboard", forType: .string)
            var pastes = 0
            var presentations: [Bool] = []
            let coordinator = ProofreadingCoordinator(service: CompatibilityProofreader(), capture: capture, insert: { corrected, selected in
                try await TextInserter(capture: capture, clipboard: ClipboardGuard(pasteboard: board),
                    frontmost: { 123 }, paste: {
                        pastes += 1
                        XCTAssertEqual(board.data(forType: .rtf) != nil, rich)
                        fixture.update { $0.value = corrected }
                    }, settleTime: .zero).apply(corrected, to: selected)
            })
            coordinator.changed = { [weak coordinator] in presentations.append(coordinator?.reviewRequested ?? false) }
            coordinator.proofreadSelection(pid: 123, limit: 1500, mode: .clean, appName: "Synthetic editor")
            for _ in 0..<100 {
                if !coordinator.working && !coordinator.applying { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(pastes, 1)
            XCTAssertEqual(coordinator.appliedCorrection?.corrected, "This is the first draft.")
            XCTAssertFalse(presentations.contains(true))
            XCTAssertEqual(board.string(forType: .string), "saved synthetic clipboard")
        }
    }
    func testUnconfirmedPasteRestoresClipboardAndNeverRetries() async throws {
        let target = CapturedSelection(element: AXUIElementCreateApplication(123), canReplace: true, pid: 123,
            text: "teh", range: CFRange(location: 0, length: 3), fullValue: "teh", digest: Data())
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setString("saved", forType: .string)
        var pastes = 0
        let inserter = TextInserter(capture: RichVerifier(confirmAfter: 99), clipboard: ClipboardGuard(pasteboard: board),
            frontmost: { 123 }, paste: { pastes += 1 }, settleTime: .milliseconds(10))
        do { try await inserter.apply("the", to: target); XCTFail("Unconfirmed replacement accepted") }
        catch { XCTAssertEqual(error as? AppFailure, .pasteFailed) }
        XCTAssertEqual(pastes, 1)
        XCTAssertEqual(board.string(forType: .string), "saved")
    }
}
private actor RichVerifier: SelectionVerifying {
    var checks = 0
    let confirmAfter: Int
    init(confirmAfter: Int = 0) { self.confirmAfter = confirmAfter }
    func verify(_ target: CapturedSelection) { }
    func confirms(_ target: CapturedSelection, replacement: String) -> Bool { checks += 1; return checks > confirmAfter }
}

private actor CompatibilityProofreader: ProofreadingService {
    func prewarm() { }
    func correct(_ text: String, limit: Int, command: BouncerCore.Command) throws -> BouncerCore.ValidatedCorrection {
        try BouncerCore.OutputValidator.validate(original: text, corrected: text.replacingOccurrences(of: "teh", with: "the"), command: command)
    }
}
