import AppKit
import BouncerCore
import ApplicationServices
import CryptoKit

/// Accessibility screen coordinates: origin at the top-left of the primary display.
/// Geometry is optional and never makes an otherwise unsafe field eligible for Apply.
struct SelectionAnchor: Sendable, Equatable {
    var selection: CGRect?
    var field: CGRect?
    static func valid(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite)
            && rect.width > 0 && rect.height > 0
    }
}

// AX references are confined to this actor; callers carry only an opaque selection handle.
struct CapturedSelection: @unchecked Sendable {
    let element: AXUIElement
    let canReplace: Bool
    let canAutoReplace: Bool
    let pid: pid_t
    let text: String
    let range: CFRange?
    let fullValue: String?
    let digest: Data?
    let formatting: SelectionFormatting
    let anchor: SelectionAnchor
    init(element: AXUIElement, canReplace: Bool, pid: pid_t, text: String, range: CFRange? = nil,
         fullValue: String? = nil, digest: Data? = nil, canAutoReplace: Bool = false, formatting: SelectionFormatting = .unknown, anchor: SelectionAnchor = SelectionAnchor()) {
        self.element = element
        self.canReplace = canReplace && range != nil && fullValue != nil && digest != nil
        self.canAutoReplace = self.canReplace && canAutoReplace
        self.pid = pid; self.text = text; self.range = range; self.fullValue = fullValue; self.digest = digest; self.formatting = formatting; self.anchor = anchor
    }
}

protocol SelectionVerifying: Sendable {
    func verify(_ target: CapturedSelection) async throws
    func confirms(_ target: CapturedSelection, replacement: String) async -> Bool
}

protocol SelectionCapturing: SelectionVerifying {
    func capture(pid: pid_t) async throws -> CapturedSelection
    func capture(pid: pid_t, selectFocusedText: Bool, limit: Int) async throws -> CapturedSelection
    func presentationAnchor(for target: CapturedSelection) async -> SelectionAnchor?
    func focusedFieldAnchor(pid: pid_t) async -> SelectionAnchor?
    func containsDraft(_ target: CapturedSelection, replacement: String?) async -> Bool
}

extension SelectionCapturing {
    func capture(pid: pid_t, selectFocusedText: Bool, limit: Int) async throws -> CapturedSelection {
        try await capture(pid: pid)
    }
    func presentationAnchor(for target: CapturedSelection) async -> SelectionAnchor? { target.anchor }
    func focusedFieldAnchor(pid: pid_t) async -> SelectionAnchor? { nil }
    func containsDraft(_ target: CapturedSelection, replacement: String?) async -> Bool { true }
}

// Small injectable boundary so native/web capability combinations can be exercised
// without reading the user's apps or changing the real clipboard in tests.
protocol SelectionAccessibility: Sendable {
    func focusedElement(pid: pid_t) -> AXUIElement?
    func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef?
    func parameter(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) -> CFTypeRef?
    func isSettable(_ element: AXUIElement, _ name: String) -> Bool
    func setSelectedRange(_ element: AXUIElement, _ range: CFRange) -> Bool
}

struct SystemSelectionAccessibility: SelectionAccessibility {
    func focusedElement(pid: pid_t) -> AXUIElement? {
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.2)
        guard let focused = attribute(root, kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.2)
        return element
    }
    func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }
    func parameter(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, value, &result) == .success else { return nil }
        return result
    }
    func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }
    func setSelectedRange(_ element: AXUIElement, _ range: CFRange) -> Bool {
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }
}

actor SelectionCapture: SelectionCapturing {
    private let accessibility: any SelectionAccessibility
    private let frontmost: @Sendable () -> pid_t?
    private static let maximumValueBytes = 1_048_576
    init(accessibility: any SelectionAccessibility = SystemSelectionAccessibility(),
         frontmost: @escaping @Sendable () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }) {
        self.accessibility = accessibility; self.frontmost = frontmost
    }

    func capture(pid: pid_t) async throws -> CapturedSelection {
        try await captureSelection(pid: pid, selectFocusedText: false, limit: SelectionPolicy.defaultLimit)
    }

    func capture(pid: pid_t, selectFocusedText: Bool, limit: Int) async throws -> CapturedSelection {
        try await captureSelection(pid: pid, selectFocusedText: selectFocusedText, limit: limit)
    }

    private func captureSelection(pid: pid_t, selectFocusedText: Bool, limit: Int) async throws -> CapturedSelection {
        guard let element = accessibility.focusedElement(pid: pid) else { throw AppFailure.noSelection }
        try rejectSecureField(element)
        let role = attribute(element, kAXRoleAttribute) as? String
        // Custom editors may expose AXGroup or AXUnknown. The text capabilities,
        // not the role label, establish whether a selection can be replaced.
        let range = try selectedRange(element)
        let reported = text(attribute(element, kAXSelectedTextAttribute))
        if let range, range.length == 0 {
            guard selectFocusedText else { throw AppFailure.noSelection }
            return try await selectFocusedField(element, pid: pid, caret: range, reported: reported, limit: limit)
        }
        guard let value = fullValue(element), let range else {
            // Read-only preview for editors that expose only their selected text.
            // Do not synthesize Cmd-C, guess offsets or manufacture a full value.
            guard let reported, !reported.isEmpty,
                  reported.utf8.count <= Self.maximumValueBytes,
                  range == nil || range?.length == reported.utf16.count else { throw AppFailure.noSelection }
            return CapturedSelection(element: element, canReplace: false, pid: pid, text: reported, anchor: anchor(element, range: range))
        }
        guard let swiftRange = Range(NSRange(location: range.location, length: range.length), in: value) else { throw AppFailure.noSelection }
        let selected = String(value[swiftRange])
        if let reported,
           !reported.utf8.elementsEqual(selected.utf8) { throw AppFailure.focusChanged }
        // Readable/selectable is not proof of editability. Some editors expose
        // selected-text editing or AXEditable instead of a writable entire value.
        let canReplace = isEditable(element)
        let formatting = selectionFormatting(element, range: range, selected: selected, role: role)
        return CapturedSelection(element: element, canReplace: canReplace, pid: pid, text: selected,
            range: range, fullValue: value, digest: hash(value), canAutoReplace: canReplace && formatting.supportsAuto,
            formatting: formatting, anchor: anchor(element, range: range))
    }

    private func isEditable(_ element: AXUIElement) -> Bool {
        attribute(element, kAXEnabledAttribute) as? Bool != false
            && attribute(element, "AXReadOnly") as? Bool != true
            && (accessibility.isSettable(element, kAXValueAttribute)
                || accessibility.isSettable(element, kAXSelectedTextAttribute)
                || attribute(element, "AXEditable") as? Bool == true)
    }

    private func selectFocusedField(_ element: AXUIElement, pid: pid_t, caret: CFRange,
                                    reported: String?, limit: Int) async throws -> CapturedSelection {
        guard isEditable(element), accessibility.isSettable(element, kAXSelectedTextRangeAttribute),
              let value = fullValue(element),
              Range(NSRange(location: caret.location, length: 0), in: value) != nil else { throw AppFailure.noSelection }
        guard reported == nil || reported?.isEmpty == true else { throw AppFailure.focusChanged }
        // Validate before changing the selection. Never select a large document,
        // whitespace-only field, or a control whose complete value is unavailable.
        try SelectionPolicy(maximumCharacters: limit).validate(value)
        let whole = CFRange(location: 0, length: value.utf16.count)
        guard frontmost() == pid, let focused = accessibility.focusedElement(pid: pid),
              CFEqual(focused, element), let currentCaret = try selectedRange(element),
              currentCaret.location == caret.location, currentCaret.length == 0,
              fullValue(element)?.utf8.elementsEqual(value.utf8) == true else { throw AppFailure.focusChanged }
        try Task.checkCancellation()
        guard accessibility.setSelectedRange(element, whole) else { throw AppFailure.noSelection }
        // Some editors accept the write before updating their AX range/text.
        // Wait for that one write; never reselect, retry another field or infer a range.
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .milliseconds(600))
        while true {
            try Task.checkCancellation()
            guard frontmost() == pid, let focused = accessibility.focusedElement(pid: pid),
                  CFEqual(focused, element), isEditable(element),
                  fullValue(element)?.utf8.elementsEqual(value.utf8) == true,
                  let range = try selectedRange(element) else { throw AppFailure.focusChanged }
            try rejectSecureField(element)
            let reported = text(attribute(element, kAXSelectedTextAttribute))
            let ready = range.location == whole.location && range.length == whole.length
            let unchangedCaret = range.location == caret.location && range.length == 0
            guard ready || unchangedCaret,
                  reported == nil || reported?.isEmpty == true || reported?.utf8.elementsEqual(value.utf8) == true else {
                throw AppFailure.focusChanged
            }
            if ready, reported == nil || reported?.utf8.elementsEqual(value.utf8) == true {
                let selected = try await capture(pid: pid)
                guard frontmost() == pid, CFEqual(selected.element, element), selected.canReplace,
                      selected.range?.location == whole.location, selected.range?.length == whole.length,
                      selected.fullValue?.utf8.elementsEqual(value.utf8) == true,
                      selected.text.utf8.elementsEqual(value.utf8) else { throw AppFailure.focusChanged }
                return selected
            }
            guard clock.now < deadline else { throw AppFailure.focusChanged }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // Geometry tracking is separate from draft validity: review deliberately takes
    // focus away from this field, but must still disappear if its draft is cleared.
    func presentationAnchor(for target: CapturedSelection) async -> SelectionAnchor? {
        guard let focused = accessibility.focusedElement(pid: target.pid),
              CFEqual(focused, target.element) else { return nil }
        // Use the current range so feedback follows the corrected selection too.
        return anchor(focused, range: try? selectedRange(focused))
    }

    /// Empty-selection feedback needs only geometry, never a replacement target
    /// or a second attempt to read/select the field's text.
    func focusedFieldAnchor(pid: pid_t) async -> SelectionAnchor? {
        guard !Task.isCancelled, frontmost() == pid,
              let focused = accessibility.focusedElement(pid: pid), isEditable(focused) else { return nil }
        do { try rejectSecureField(focused) } catch { return nil }
        let geometry = anchor(focused, range: nil)
        guard geometry.field != nil, !Task.isCancelled, frontmost() == pid,
              let current = accessibility.focusedElement(pid: pid), CFEqual(current, focused) else { return nil }
        return geometry
    }

    func containsDraft(_ target: CapturedSelection, replacement: String?) async -> Bool {
        if let original = target.fullValue, let digest = target.digest {
            guard let current = fullValue(target.element) else { return false }
            guard let replacement else { return hash(current) == digest }
            guard let capturedRange = target.range,
                  let range = Range(NSRange(location: capturedRange.location, length: capturedRange.length), in: original) else { return false }
            return hash(current) == hash(original.replacingCharacters(in: range, with: replacement))
        }
        // Copy-only editors may expose just selected text. A cleared composer can
        // leave a stale AXSelectedText value, so check an available empty value/count first.
        if let value = fullValue(target.element), value.isEmpty { return false }
        if let count = attribute(target.element, kAXNumberOfCharactersAttribute) as? Int, count == 0 { return false }
        guard let selected = text(attribute(target.element, kAXSelectedTextAttribute)) else { return false }
        return selected.utf8.elementsEqual(target.text.utf8)
    }

    private func anchor(_ element: AXUIElement, range: CFRange?) -> SelectionAnchor {
        var field: CGRect?
        var point = CGPoint.zero, size = CGSize.zero
        if let position = attribute(element, kAXPositionAttribute), let dimensions = attribute(element, kAXSizeAttribute),
           CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(dimensions) == AXValueGetTypeID(),
           AXValueGetValue(position as! AXValue, .cgPoint, &point),
           AXValueGetValue(dimensions as! AXValue, .cgSize, &size) {
            let rect = CGRect(origin: point, size: size)
            if SelectionAnchor.valid(rect) { field = rect }
        }
        var selection: CGRect?
        if let range, range.length > 0, let input = rangeValue(range),
           let raw = accessibility.parameter(element, kAXBoundsForRangeParameterizedAttribute, input),
           CFGetTypeID(raw) == AXValueGetTypeID() {
            var rect = CGRect.zero
            if AXValueGetValue(raw as! AXValue, .cgRect, &rect), SelectionAnchor.valid(rect) {
                // A scrolled selection may be partly outside the editor viewport.
                let clipped = field.map { rect.intersection($0) } ?? rect
                if SelectionAnchor.valid(clipped) { selection = clipped }
            }
        }
        return SelectionAnchor(selection: selection, field: field)
    }

    func verify(_ target: CapturedSelection) async throws {
        guard target.canReplace, let targetRange = target.range else { throw AppFailure.focusChanged }
        let now = try await capture(pid: target.pid)
        guard CFEqual(now.element, target.element), now.canReplace, let nowRange = now.range,
              nowRange.location == targetRange.location, nowRange.length == targetRange.length,
              now.digest == target.digest, now.text.utf8.elementsEqual(target.text.utf8),
              target.formatting.matches(now.formatting) else { throw AppFailure.focusChanged }
    }

    func confirms(_ target: CapturedSelection, replacement: String) -> Bool {
        guard target.canReplace, let targetRange = target.range, let originalValue = target.fullValue,
              let range = Range(NSRange(location: targetRange.location, length: targetRange.length), in: originalValue),
              let current = fullValue(target.element) else { return false }
        let expected = originalValue.replacingCharacters(in: range, with: replacement)
        return hash(current) == hash(expected)
    }

    private func rejectSecureField(_ element: AXUIElement) throws {
        var ancestor = element
        var visited: [AXUIElement] = []
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        // Web/Electron composers routinely have more than 16 layout ancestors.
        // Keep the traversal bounded by time and cycles, not a shallow DOM limit.
        for _ in 0..<128 {
            guard ContinuousClock.now < deadline,
                  !visited.contains(where: { CFEqual($0, ancestor) }) else { throw AppFailure.noSelection }
            visited.append(ancestor)
            if attribute(ancestor, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole { throw AppFailure.secureField }
            guard let parent = attribute(ancestor, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return }
            let next = parent as! AXUIElement
            ancestor = next
        }
        // Cannot establish that a deeply nested control is outside a secure field.
        throw AppFailure.noSelection
    }

    private func fullValue(_ element: AXUIElement) -> String? {
        if let value = text(attribute(element, kAXValueAttribute)) {
            return value.utf8.count <= Self.maximumValueBytes ? value : nil
        }
        guard let count = attribute(element, kAXNumberOfCharactersAttribute) as? Int,
              count >= 0, count <= Self.maximumValueBytes,
              let range = rangeValue(CFRange(location: 0, length: count)),
              let value = text(accessibility.parameter(element, kAXStringForRangeParameterizedAttribute, range)),
              value.utf16.count == count, value.utf8.count <= Self.maximumValueBytes else { return nil }
        return value
    }

    private func selectedRange(_ element: AXUIElement) throws -> CFRange? {
        // Never turn multiple selections into a paste at an arbitrary first range.
        if let raw = attribute(element, kAXSelectedTextRangesAttribute) {
            guard let ranges = raw as? [CFTypeRef], ranges.count == 1,
                  let range = decodeRange(ranges[0]) else { throw AppFailure.noSelection }
            if let primary = attribute(element, kAXSelectedTextRangeAttribute) {
                guard let primaryRange = decodeRange(primary), primaryRange.location == range.location,
                      primaryRange.length == range.length else { throw AppFailure.noSelection }
            }
            return range
        }
        guard let raw = attribute(element, kAXSelectedTextRangeAttribute) else { return nil }
        guard let range = decodeRange(raw) else { throw AppFailure.noSelection }
        return range
    }

    private func selectionFormatting(_ element: AXUIElement, range: CFRange, selected: String, role: String?) -> SelectionFormatting {
        guard let rawRange = rangeValue(range) else { return .unknown }
        // Native rich editors can provide real RTF, including font/style runs.
        if let data = accessibility.parameter(element, kAXRTFForRangeParameterizedAttribute, rawRange) as? Data {
            return SelectionFormatting.richText(data, matching: selected) ?? .unknown
        }
        if let attributed = accessibility.parameter(element, kAXAttributedStringForRangeParameterizedAttribute, rawRange) as? NSAttributedString,
           attributed.string.utf8.elementsEqual(selected.utf8) {
            return SelectionFormatting.uniformText(attributed) ?? .unknown
        }
        // Standard single-line controls are plain text; multiline/unknown editors
        // need affirmative formatting evidence or RTF before silent replacement.
        return role == kAXTextFieldRole || role == kAXComboBoxRole ? .plain : .unknown
    }

    private func text(_ value: CFTypeRef?) -> String? {
        if let string = value as? String { return string }
        return (value as? NSAttributedString)?.string
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? { accessibility.attribute(element, name) }
    private func decodeRange(_ raw: CFTypeRef) -> CFRange? {
        guard CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0,
              range.location <= Int.max - range.length else { return nil }
        return range
    }
    private func rangeValue(_ range: CFRange) -> AXValue? {
        var copy = range
        return AXValueCreate(.cfRange, &copy)
    }
    private func hash(_ string: String) -> Data { Data(SHA256.hash(data: Data(string.utf8))) }
}
