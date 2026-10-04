import BouncerCore
import Foundation
import Observation

@MainActor @Observable
final class AppSettings {
    var autoMode: AutoMode { didSet { defaults.set(autoMode.rawValue, forKey: "autoMode") } }
    var selectFocusedText: Bool { didSet { defaults.set(selectFocusedText, forKey: "selectFocusedText") } }
    var expandShorthand: Bool { didSet { defaults.set(expandShorthand, forKey: "expandShorthand") } }
    var action: Command { didSet { defaults.set(action.rawValue, forKey: "action") } }
    var correctionTrigger: CorrectionTrigger { didSet { defaults.set(correctionTrigger.rawValue, forKey: "correctionTrigger") } }
    var shortcut: HotkeyShortcut { didSet { if let data = try? JSONEncoder().encode(shortcut) { defaults.set(data, forKey: "shortcut") } } }
    var deniedApps: [String] { didSet { defaults.set(deniedApps, forKey: "deniedApps") } }
    private static let defaultDeniedApps = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "com.1password.1password", "com.1password.1password-macos", "com.agilebits.onepassword7", "com.apple.keychainaccess", "com.apple.systempreferences"]
    @ObservationIgnored private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.string(forKey: "autoMode") {
            autoMode = AutoMode(rawValue: stored) ?? .off
        } else {
            autoMode = defaults.bool(forKey: "autoApply") ? .clean : .off
        }
        correctionTrigger = CorrectionTrigger(rawValue: defaults.string(forKey: "correctionTrigger") ?? "") ?? .keyCombination
        selectFocusedText = defaults.bool(forKey: "selectFocusedText")
        expandShorthand = defaults.bool(forKey: "expandShorthand")
        let savedAction = Command(rawValue: defaults.string(forKey: "action") ?? "proofread")
        action = savedAction == .improveSentences ? .improveSentences : .proofread
        let storedShortcut = defaults.data(forKey: "shortcut").flatMap { try? JSONDecoder().decode(HotkeyShortcut.self, from: $0) }
        shortcut = storedShortcut.flatMap { $0.isValid ? $0 : nil } ?? .proofread
        deniedApps = defaults.stringArray(forKey: "deniedApps") ?? Self.defaultDeniedApps
        // Freeze migration so an old boolean cannot override a later mode choice.
        defaults.set(autoMode.rawValue, forKey: "autoMode")
        for key in ["autoApply", "quickTrigger", "quickSide", "tapGap", "maximumSelectionCharacters"] {
            defaults.removeObject(forKey: key)
        }
    }

}

extension AutoMode {
    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .clean: String(localized: "Clean")
        case .full: String(localized: "Full Auto")
        }
    }
    var detail: String {
        switch self {
        case .off: String(localized: "Review each correction before applying it.")
        case .clean: String(localized: "Automatically apply punctuation, capitalization and small typos. Review wording changes and sentence improvements.")
        case .full: String(localized: "Automatically apply the complete correction, including grammar, wording and sentence improvements.")
        }
    }
}

extension CorrectionTrigger {
    var title: String {
        switch self {
        case .keyCombination: String(localized: "Key combination")
        case .doubleFunction: String(localized: "Double-tap Fn / Globe")
        case .doubleControl: String(localized: "Double-tap Control")
        }
    }
}
