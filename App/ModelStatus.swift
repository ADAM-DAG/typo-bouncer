import Foundation
import FoundationModels

enum ModelStatus: Equatable {
    case ready
    case deviceNotEligible
    case intelligenceDisabled
    case modelNotReady
    case unknown

    init(availability: SystemLanguageModel.Availability) {
        switch availability {
        case .available: self = .ready
        case .unavailable(.deviceNotEligible): self = .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): self = .intelligenceDisabled
        case .unavailable(.modelNotReady): self = .modelNotReady
        case .unavailable: self = .unknown
        }
    }

    var title: String {
        switch self {
        case .ready: String(localized: "Model ready")
        case .deviceNotEligible: String(localized: "This Mac is not supported")
        case .intelligenceDisabled: String(localized: "Apple Intelligence is off")
        case .modelNotReady: String(localized: "Model is getting ready")
        case .unknown: String(localized: "Model unavailable")
        }
    }

    var detail: String {
        switch self {
        case .ready: String(localized: "Apple’s on-device model is available on this Mac.")
        case .deviceNotEligible: String(localized: "Typo Bouncer needs a Mac that supports Apple Intelligence.")
        case .intelligenceDisabled: String(localized: "Enable Apple Intelligence in System Settings to use proofreading.")
        case .modelNotReady: String(localized: "Apple’s model is still downloading or preparing. Check again shortly.")
        case .unknown: String(localized: "Apple’s on-device model is currently unavailable.")
        }
    }
}
