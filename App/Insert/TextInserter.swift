import AppKit

@MainActor
final class TextInserter {
    private let capture: any SelectionVerifying
    private let frontmost: () -> pid_t?
    private let paste: () throws -> Void
    private let settleTime: Duration
    private let clipboard: ClipboardGuard
    init(capture: any SelectionVerifying, clipboard: ClipboardGuard = ClipboardGuard(),
         frontmost: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
         paste: @escaping () throws -> Void = { try TextInserter.postPaste() }, settleTime: Duration = .milliseconds(400)) {
        self.frontmost = frontmost; self.paste = paste; self.settleTime = settleTime
        self.capture = capture
        self.clipboard = clipboard
    }

    func apply(_ corrected: String, to target: CapturedSelection) async throws {
        guard target.canReplace else { throw AppFailure.noSelection }
        try Task.checkCancellation()
        let rtf = try target.formatting.replacementRTF(original: target.text, corrected: corrected)
        let snapshot = try clipboard.snapshot()
        try await capture.verify(target)
        try Task.checkCancellation()
        guard frontmost() == target.pid else { throw AppFailure.focusChanged }
        let ownership = try clipboard.writeTemporary(corrected, rtf: rtf, after: snapshot)
        defer { clipboard.restore(snapshot, ifOwned: ownership) }
        // No suspension between the final focus/clipboard checks and posting the paste.
        guard frontmost() == target.pid else { throw AppFailure.focusChanged }
        guard clipboard.owns(ownership) else { throw AppFailure.clipboardChanged }
        try paste()
        // Restore as soon as the exact field replacement is confirmed. Slow apps
        // get the same bounded grace period, and no failure ever retries a paste.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: settleTime)
        while true {
            if await capture.confirms(target, replacement: corrected) { return }
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { throw AppFailure.pasteFailed }
            let delay = min(remaining, .milliseconds(40))
            // Clipboard consumption/restoration must finish even on cancellation.
            await Task.detached { try? await Task.sleep(for: delay) }.value
        }
    }

    private static func postPaste() throws {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { throw AppFailure.pasteFailed }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }

}
