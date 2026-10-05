import AppKit
import BouncerCore
import NaturalLanguage

struct SpellingCandidate: Sendable {
    let range: NSRange
    let sentences: [String]
    let words: [String]
}

@MainActor
enum SpellingHints {
    private static let negations: Set<String> = ["no", "not", "never", "none", "nor", "cannot", "without"]
    /// Context decisions can fill in a missed real-word typo only when the main
    /// proofreader kept the original words. Never splice competing rewrites.
    nonisolated static func mergeContext(original: String, generated: String, reviewed: String) -> String {
        let old = WordDiff.tokens(original).filter { $0.contains(where: \.isLetter) }
        let reviewedWords = WordDiff.tokens(reviewed).filter { $0.contains(where: \.isLetter) }
        var output = WordDiff.tokens(generated)
        let indices = output.indices.filter { output[$0].contains(where: \.isLetter) }
        guard old.count == reviewedWords.count, indices.count == old.count,
              zip(indices, old).allSatisfy({ output[$0.0].lowercased() == $0.1.lowercased() }) else { return generated }
        for (wordIndex, tokenIndex) in indices.enumerated() where old[wordIndex] != reviewedWords[wordIndex] {
            // A newly capitalized name or changed token is left to the main result.
            guard output[tokenIndex] == old[wordIndex] else { continue }
            output[tokenIndex] = reviewedWords[wordIndex]
        }
        return output.joined()
    }
    /// Native dictionary guesses supply alternatives, never automatic substitutions.
    static func candidates(_ text: String, language: String?) -> [SpellingCandidate] {
        guard text.count <= 300, text.split(whereSeparator: \.isWhitespace).count <= 6 else { return [] }
        // Questions do not assert a literal fact. Ranking alternative statements
        // by plausibility adds latency and can guess at what the user is asking.
        // The main model still checks their grammar and spelling.
        var question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if question.last == "?" { question.removeLast() }
        guard QuestionPunctuation.addMissingMark(question) == question else { return [] }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hint = recognizer.languageHypotheses(withMaximum: 3).max { $0.value < $1.value }
        // Routing short phrases is a hint, not the confidence gate used for validation.
        guard language == "en" || (language == nil && hint?.key == .english && (hint?.value ?? 0) >= 0.35) else { return [] }
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        tagger.string = text
        // Keep this extra model pass narrow: noun/adjective predicates of "be"
        // can catch a missed real-word typo such as "Adam is the nest". Ranking
        // objects of actions ("send the file", "bring the book") adds a model
        // request and can invent a different fact. The main proofreader still
        // checks spelling and grammar throughout the entire passage.
        let predicates = predicateRanges(text, tagger: tagger)
        guard !predicates.isEmpty else { return [] }
        let checker = NSSpellChecker.shared
        let tag = NSSpellChecker.uniqueSpellDocumentTag()
        defer { checker.closeSpellDocument(withTag: tag) }
        let stops: Set<String> = ["the", "and", "for", "with", "that", "this", "you", "are", "was", "have", "has", "will", "can", "not"]
        let protected = ProtectedTokens.extract(text)
        var groups: [SpellingCandidate] = []
        var seen: Set<String> = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, range, _, stop in
            guard predicates.contains(NSRange(range, in: text)),
                  let word, word.count >= 3, word.count <= 18, word.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),
                  !stops.contains(word.lowercased()), !negations.contains(word.lowercased()),
                  ChatShorthand.expand(word) == word,
                  seen.insert(word).inserted else { return }
            guard range.lowerBound != text.startIndex, word.first?.isUppercase != true,
                  !["'", "’"].contains(text[text.index(before: range.lowerBound)]),
                  (range.upperBound == text.endIndex || !["'", "’"].contains(text[range.upperBound])),
                  !protected.contains(where: { $0.value.contains(word) }) else { return }
            // Function words and adverbs carry relationships, time and emphasis.
            // Ranking dictionary neighbours of "now", for example, can invent
            // "how" or "not" even though the original sentence is already correct.
            let lexicalClass = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lexicalClass).0
            guard [.noun, .verb, .adjective].contains(lexicalClass) else { return }
            let alternatives = (checker.guesses(forWordRange: NSRange(range, in: text), in: text,
                                                language: "en", inSpellDocumentWithTag: tag) ?? [])
                .filter { alternative in
                    let original = Array(word.lowercased().utf8), guess = Array(alternative.lowercased().utf8)
                    return !negations.contains(alternative.lowercased()) &&
                        original.count == guess.count && guess.allSatisfy { (97...122).contains($0) }
                        && zip(original, guess).filter { $0 != $1 }.count == 1
                }
                .prefix(4)
            guard !alternatives.isEmpty else { return }
            let words = [word] + alternatives
            groups.append(SpellingCandidate(range: NSRange(range, in: text),
                sentences: words.map { text.replacingCharacters(in: range, with: $0) }, words: words))
            if groups.count >= 4 { stop = true }
        }
        return groups
    }

    private static func predicateRanges(_ text: String, tagger: NLTagger) -> Set<NSRange> {
        var ranges: Set<NSRange> = []
        var followsCopula = false
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            if tag == .verb {
                followsCopula = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue == "be"
            } else if tag == .preposition || tag == .conjunction {
                followsCopula = false
            } else if followsCopula, tag == .noun || tag == .adjective {
                ranges.insert(NSRange(range, in: text))
            }
            return true
        }
        return ranges
    }
}
