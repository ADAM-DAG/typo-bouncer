import Foundation

public enum ValidationFailure: Error, Equatable, Sendable {
    case empty, markers, preamble, lineBreaks, protectedTokens, length, language, style, shorthand
}

public enum ValidationWarning: Equatable, Sendable {
    case extensiveChanges, possibleName
}

public struct ValidatedCorrection: Equatable, Sendable {
    public let original: String
    public let corrected: String
    public let warnings: [ValidationWarning]
    public let segments: [DiffSegment]
    public var isUnchanged: Bool { original.utf8.elementsEqual(corrected.utf8) }
}

public enum OutputValidator {
    public static func validate(original: String, corrected: String, command: Command = .proofread,
                                nonce: String? = nil, expandShorthand: Bool = false) throws -> ValidatedCorrection {
        guard !corrected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ValidationFailure.empty }
        if let nonce, corrected.contains("<text-\(nonce)>") || corrected.contains("</text-\(nonce)>") {
            throw ValidationFailure.markers
        }
        let prefixes = ["here is the corrected", "here's the corrected", "corrected text:", "hier is de gecorrigeerde", "gecorrigeerde tekst:"]
        let old = original.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let new = corrected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if prefixes.contains(where: { new.hasPrefix($0) && !old.hasPrefix($0) }) { throw ValidationFailure.preamble }
        if original.filter(\.isNewline).count != corrected.filter(\.isNewline).count {
            throw ValidationFailure.lineBreaks
        }
        guard ProtectedTokens.preserved(original: original, corrected: corrected) else { throw ValidationFailure.protectedTokens }
        guard PlainWritingStyle.preservesStyle(original: original, corrected: corrected) else { throw ValidationFailure.style }
        let baseline = ProofreadingTypography.removeTrailingWhitespace(
            expandShorthand ? ChatShorthand.expand(original) : original)
        guard ChatShorthand.preserved(original: baseline, corrected: corrected) else { throw ValidationFailure.shorthand }
        if baseline.count >= 40 {
            let ratio = Double(corrected.count) / Double(baseline.count)
            let bounds = command == .improveSentences ? (0.6...1.6) : (0.7...1.4)
            guard bounds.contains(ratio) else { throw ValidationFailure.length }
        }
        if LanguageGate.changed(original: baseline, corrected: corrected) { throw ValidationFailure.language }
        var warnings: [ValidationWarning] = []
        if WordDiff.wordEditRatio(original: original, corrected: corrected) > 0.25 { warnings.append(.extensiveChanges) }
        if WordDiff.changedPossibleName(original: original, corrected: corrected) { warnings.append(.possibleName) }
        return ValidatedCorrection(original: original, corrected: corrected, warnings: warnings,
                                   segments: WordDiff.segments(original: original, corrected: corrected))
    }
}
