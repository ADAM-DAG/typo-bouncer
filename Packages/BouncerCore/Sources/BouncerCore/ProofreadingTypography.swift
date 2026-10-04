import Foundation
import NaturalLanguage

public enum ProofreadingTypography {
    /// Remove ordinary spaces and tabs at line ends, retaining indentation,
    /// line separators, nonbreaking spaces and whitespace inside protected code.
    public static func removeTrailingWhitespace(_ text: String) -> String {
        guard let pattern = try? NSRegularExpression(pattern: #"[ \t]+(?=[\r\n\u0085\u2028\u2029]|\z)"#) else { return text }
        let protected = ProtectedTokens.ranges(in: text, kinds: [.code])
        var result = text
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                  let range = Range(match.range, in: result) else { continue }
            result.removeSubrange(range)
        }
        return result
    }

    /// A model may substitute a more familiar spelling while capitalizing a name.
    /// Restore only an isolated, word-aligned replacement recognized as a personal
    /// name, with unchanged neighbouring words and no protected-token overlap.
    public static func restoreAlignedNameSpelling(original: String, corrected: String) -> String {
        guard let language = LanguageGate.detect(original, minimumLetters: 1),
              ["en", "nl"].contains(language.code) else { return corrected }
        func words(_ text: String) -> [(value: String, range: NSRange, startsSentence: Bool)] {
            var offset = 0, sentenceStart = true
            var result: [(String, NSRange, Bool)] = []
            for token in WordDiff.tokens(text) {
                if token.contains(where: \.isLetter) {
                    result.append((token, NSRange(location: offset, length: token.utf16.count), sentenceStart))
                    sentenceStart = false
                } else if token.contains(where: { $0.isNewline || ".!?".contains($0) }) {
                    sentenceStart = true
                }
                offset += token.utf16.count
            }
            return result
        }
        let before = words(original), after = words(corrected)
        guard before.count == after.count else { return corrected }
        let protectedBefore = ProtectedTokens.ranges(in: original)
        let protectedAfter = ProtectedTokens.ranges(in: corrected)
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = corrected
        // English name tagging also recognizes capitalized personal names inside
        // Dutch prose, whose local assets may not offer the name-type scheme.
        tagger.setLanguage(.english, range: corrected.startIndex..<corrected.endIndex)
        var result = corrected
        for index in after.indices.reversed() {
            let old = before[index], new = after[index]
            guard !new.startsSentence, old.value.count >= 3,
                  old.value.allSatisfy({ $0.isLetter && $0.isLowercase }),
                  new.value.first?.isUppercase == true, new.value.dropFirst().allSatisfy({ $0.isLetter && $0.isLowercase }),
                  old.value.lowercased() != new.value.lowercased(),
                  old.value.first?.lowercased() == new.value.first?.lowercased(),
                  index > 0, before[index - 1].value.lowercased() == after[index - 1].value.lowercased(),
                  index + 1 == after.count || before[index + 1].value.lowercased() == after[index + 1].value.lowercased(),
                  !protectedBefore.contains(where: { NSIntersectionRange($0, old.range).length > 0 }),
                  !protectedAfter.contains(where: { NSIntersectionRange($0, new.range).length > 0 }),
                  let sourceRange = Range(new.range, in: corrected),
                  tagger.tag(at: sourceRange.lowerBound, unit: .word, scheme: .nameType).0 == .personalName,
                  let range = Range(new.range, in: result) else { continue }
            result.replaceSubrange(range, with: old.value.prefix(1).uppercased() + old.value.dropFirst())
        }
        return result
    }

    /// Capitalizing a prose name must not change the same letters in a handle,
    /// address or code. Restore only case-only edits with matching token order.
    /// Missing, added or substantively changed protected tokens still fail validation.
    public static func restoreProtectedCapitalization(original: String, corrected: String) -> String {
        let before = ProtectedTokens.extract(original)
        let after = ProtectedTokens.extract(corrected)
        let ranges = ProtectedTokens.ranges(in: corrected)
        guard before.count == after.count else { return corrected }
        let restorable: Set<ProtectedToken.Kind> = [.code, .url, .email, .tag]
        var result = corrected
        for index in after.indices.reversed() {
            let old = before[index], new = after[index]
            guard old.kind == new.kind, restorable.contains(old.kind),
                  !old.value.utf8.elementsEqual(new.value.utf8),
                  old.value.lowercased().utf8.elementsEqual(new.value.lowercased().utf8),
                  let range = Range(ranges[index], in: result) else { continue }
            result.replaceSubrange(range, with: old.value)
        }
        return result
    }

    /// Unambiguous English first-person typography. Do not guess ambiguous forms
    /// such as "ill"/"id", or touch code, identifiers, links and other tokens.
    public static func repairEnglishPronouns(_ text: String) -> String {
        guard let language = LanguageGate.detect(text), language.code == "en", language.confidence >= 0.75,
              ProtectedTokens.extract(text).isEmpty else { return text }
        let repairs = ["i": "I", "im": "I'm", "ive": "I've", "i'm": "I'm", "i’m": "I’m", "i've": "I've", "i’ve": "I’ve"]
        let tokens = WordDiff.tokens(text)
        return tokens.indices.map { index in
            let before = index > 0 ? tokens[index - 1] : ""
            let after = index + 1 < tokens.count ? tokens[index + 1] : ""
            if [before, after].contains(where: { $0.contains(where: { "_/\\".contains($0) }) }) || before == "." { return tokens[index] }
            if after == ".", index + 2 < tokens.count, tokens[index + 2].first?.isLetter == true { return tokens[index] }
            return repairs[tokens[index]] ?? tokens[index]
        }.joined()
    }
    /// Sentence-start capitalization is deterministic; preserve mixed-case names and code.
    public static func capitalizeStart(_ text: String) -> String {
        guard let first = text.first, first.isASCII, first.isLowercase,
              let word = text.split(whereSeparator: \.isWhitespace).first else { return text }
        let letters = word.filter(\.isLetter)
        guard !letters.isEmpty, letters.allSatisfy(\.isLowercase),
              !ProtectedTokens.extract(text).contains(where: { word.hasPrefix($0.value) }) else { return text }
        return String(first).uppercased() + text.dropFirst()
    }

    /// Preserve accepted Dutch casual forms rather than expanding them for style.
    public static func preserveAcceptedVariants(original: String, corrected: String) -> String {
        guard LanguageGate.detect(original, minimumLetters: 1)?.code == "nl" else { return corrected }
        var result = corrected
        if original.range(of: #"\bgister\b"#, options: .regularExpression) != nil,
           original.range(of: #"\bgisteren\b"#, options: .regularExpression) == nil {
            result = result.replacingOccurrences(of: #"\bgisteren\b"#, with: "gister", options: .regularExpression)
        }
        if original.range(of: #"\bje\b"#, options: .regularExpression) != nil,
           original.range(of: #"\bjou\b"#, options: .regularExpression) == nil {
            let neutral = result.replacingOccurrences(of: #"\bjou\b"#, with: "je", options: .regularExpression)
            func words(_ text: String) -> [String] {
                WordDiff.tokens(text).filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }.map { $0.lowercased() }
            }
            // Only undo a pronoun-only style expansion. Real grammar/fact/word edits
            // remain the model's reviewed proposal; no Auto policy is weakened.
            if words(original) == words(neutral) { result = neutral }
        }
        return result
    }
}
