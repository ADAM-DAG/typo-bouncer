import AppKit
@preconcurrency import ApplicationServices
import Observation

@MainActor @Observable
final class AccessibilityGate {
    private(set) var isTrusted: Bool
    @ObservationIgnored private let checkTrust: () -> Bool
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored var onChange: (() -> Void)?

    init(checkTrust: @escaping () -> Bool = { AXIsProcessTrustedWithOptions(nil) }) {
        self.checkTrust = checkTrust
        isTrusted = checkTrust()
    }

    /// Always consult macOS, including immediately before a selected-text command.
    /// A displayed Settings switch is not evidence that this build is trusted.
    @discardableResult
    func refresh() -> Bool {
        let trusted = checkTrust()
        if trusted != isTrusted { isTrusted = trusted; onChange?() }
        return trusted
    }

    func start() {
        guard polling == nil else { return }
        refresh()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                refresh()
            }
        }
    }

    func request() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    isolated deinit { polling?.cancel() }
}
