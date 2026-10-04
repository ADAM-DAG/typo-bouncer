import BouncerCore
import Foundation

// Static user-facing messages only. Never print error metadata or selected text.
enum AppFailure: Error, Equatable {
    case noSelection, secureField, deniedApp, focusChanged
    case clipboardUnavailable, clipboardTooLarge, clipboardChanged, pasteFailed, formattingChanged
    case contextLimit, timedOut, modelBusy, modelUnavailable, modelRefused, generationFailed
    case unsupportedLanguage(String?)

    var message: String {
        switch self {
        case .noSelection: return String(localized: "Select some text in an editable field, then use your shortcut again.")
        case .secureField: return String(localized: "Password and secure fields are left alone.")
        case .deniedApp: return String(localized: "Typo Bouncer is turned off for this app.")
        case .focusChanged: return String(localized: "The text or focus changed. Copy the correction or proofread again.")
        case .clipboardUnavailable: return String(localized: "The clipboard could not be saved safely. Nothing was pasted.")
        case .clipboardTooLarge: return String(localized: "The clipboard is too large to preserve. Nothing was pasted.")
        case .clipboardChanged: return String(localized: "The clipboard changed. Nothing was pasted.")
        case .pasteFailed: return String(localized: "The paste could not be confirmed. Check your text before trying again.")
        case .formattingChanged: return String(localized: "This edit cannot preserve the selection’s formatting. Copy the correction to apply it yourself.")
        case .contextLimit: return String(localized: "This text exceeds the model’s safe context budget. Try a shorter selection.")
        case .timedOut: return String(localized: "That took too long. Your original text is unchanged.")
        case .modelBusy: return String(localized: "The previous request is still finishing. Try again shortly.")
        case .modelUnavailable: return String(localized: "Apple’s on-device model is unavailable. Check Apple Intelligence in System Settings.")
        case .modelRefused: return String(localized: "Apple’s model could not proofread this text. Your original is unchanged.")
        case .generationFailed: return String(localized: "The correction could not be generated safely. Try again.")
        case .unsupportedLanguage(let code):
            if let code {
                let name = Locale.current.localizedString(forLanguageCode: code) ?? code
                return String(localized: "\(name) is not supported by Apple’s on-device model yet.")
            }
            return String(localized: "This language is not supported by Apple’s on-device model yet.")
        }
    }

    static func message(for error: Error) -> String {
        if let failure = error as? AppFailure { return failure.message }
        if let selection = error as? SelectionError {
            switch selection {
            case .tooManyBytes: return String(localized: "This text is too large. Try a shorter selection.")
            case .empty: return AppFailure.noSelection.message
            case .tooLong(let count, let limit): return String(localized: "\(count) characters is too much. The current limit is \(limit).")
            }
        }
        if let validation = error as? ValidationFailure {
            switch validation {
            case .protectedTokens: return String(localized: "The model changed a number, link, code or emoji. Your original is unchanged.")
            case .style: return String(localized: "The correction changed your writing style. Your original is unchanged.")
            case .shorthand: return String(localized: "The correction expanded shorthand while that setting is off. Your original is unchanged.")
            case .language: return String(localized: "The model changed the language. Your original is unchanged.")
            case .lineBreaks: return String(localized: "The model changed the line breaks. Your original is unchanged.")
            default: return String(localized: "The model’s output did not pass the safety checks. Your original is unchanged.")
            }
        }
        return AppFailure.generationFailed.message
    }
}
