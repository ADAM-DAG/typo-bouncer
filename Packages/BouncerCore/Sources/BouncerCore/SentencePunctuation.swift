import Foundation
import NaturalLanguage

public enum SentencePunctuation {
    /// Longer unpunctuated prose may contain run-ons. Short statements use the
    /// local completion rule below instead of another generative pass.
    public static func needsReview(_ text: String) -> Bool {
        guard text.count <= 1_500,
              !ProtectedTokens.extract(text).contains(where: { $0.kind == .code }) else { return false }
        return text.components(separatedBy: .newlines).contains { line in
            let body = line.trimmingCharacters(in: .whitespaces)
            guard let first = body.first, first.isLetter || "\"“‘".contains(first) else { return false }
            let ending = body.reversed().drop(while: { "\"”’')]".contains($0) }).first
            guard let ending, ending.isLetter || ending.isNumber else { return false }
            var prose = body
            for token in ProtectedTokens.extract(body) {
                prose = prose.replacingOccurrences(of: token.value, with: " ")
            }
            return WordDiff.tokens(prose).filter { $0.contains(where: \.isLetter) }.count >= 8
        }
    }

    public static func isProtectedOnly(_ text: String) -> Bool {
        var remainder = text
        let tokens = ProtectedTokens.extract(text)
        guard !tokens.isEmpty else { return false }
        for token in tokens { remainder = remainder.replacingOccurrences(of: token.value, with: "") }
        return remainder.allSatisfy(\.isWhitespace)
    }

    /// A boundary model can emit a comma splice instead of two sentences.
    /// Normalize only newly introduced commas between independently complete
    /// clauses; never alter a comma supplied by the writer.
    public static func separateIntroducedClauses(original: String, corrected: String) -> String {
        guard !original.contains(","),
              !ProtectedTokens.extract(original).contains(where: { $0.kind == .code }) else { return corrected }
        return corrected.components(separatedBy: "\n").map { line in
            let parts = line.components(separatedBy: ",")
            guard var output = parts.first else { return line }
            var clause = output
            for part in parts.dropFirst() {
                let before = clause.components(separatedBy: CharacterSet(charactersIn: ".!?")).last ?? clause
                let after = TextPeel(part)
                if clearStatement(before.trimmingCharacters(in: .whitespaces)), clearStatement(after.body) {
                    output += "." + after.restore(ProofreadingTypography.capitalizeStart(after.body))
                    clause = part
                } else {
                    output += "," + part
                    clause += "," + part
                }
            }
            return output
        }.joined(separator: "\n")
    }

    /// Complete clear English/Dutch prose without inventing punctuation for labels,
    /// subordinate fragments, lists, code or intentionally expressive endings.
    public static func addMissingPeriods(_ text: String) -> String {
        guard !ProtectedTokens.extract(text).contains(where: { $0.kind == .code }) else { return text }
        return text.components(separatedBy: "\n").map { line in
            let peel = TextPeel(line)
            let body = peel.body
            guard body.first?.isLetter == true, body.last?.isLetter == true || body.last?.isNumber == true else { return line }
            // A complete earlier sentence must not make a trailing heading look complete.
            let tail = body.components(separatedBy: CharacterSet(charactersIn: ".!?")).last ?? body
            let sentence = tail.trimmingCharacters(in: .whitespaces)
            guard clearStatement(sentence) else { return line }
            return peel.restore(body + ".")
        }.joined(separator: "\n")
    }

    private static func clearStatement(_ text: String) -> Bool {
        guard !isProtectedOnly(text) else { return false }
        let words = WordDiff.tokens(text).filter { $0.contains(where: \.isLetter) }.map { $0.lowercased() }
        guard words.count >= 3, let first = words.first else { return false }
        let fragments: Set<String> = ["if", "when", "because", "although", "while", "unless", "before", "after", "until",
            "what", "where", "why", "who", "how", "which", "whose", "whether",
            "als", "wanneer", "omdat", "hoewel", "terwijl", "voordat", "nadat", "wat", "waar", "waarom", "wie", "hoe"]
        guard !fragments.contains(first), QuestionPunctuation.addMissingMark(text) == text else { return false }
        if ["thanks", "thank", "bedankt"].contains(first) { return true }
        // Dutch lexical tagging is unavailable on some macOS language assets.
        // Recognize only explicit subject + common finite verb forms in that case.
        let subjects: Set<String> = ["ik", "jij", "je", "u", "hij", "zij", "ze", "wij", "we", "jullie", "het", "dit", "dat"]
        let verbs: Set<String> = ["ben", "bent", "is", "zijn", "was", "waren", "heb", "hebt", "heeft", "hebben",
            "had", "hadden", "kan", "kunnen", "zal", "zullen", "wil", "willen", "moet", "moeten",
            "kom", "komt", "komen", "ga", "gaat", "gaan", "werk", "werkt", "werken",
            "stuur", "stuurt", "sturen", "vind", "vindt", "vinden", "weet", "weten"]
        if subjects.contains(first), verbs.contains(words[1]) { return true }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var subject = false, predicate = false, previous = ""
        var fragment = false
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            let word = text[range].lowercased()
            if !predicate, !previous.isEmpty, ["who", "which", "that"].contains(word) { fragment = true }
            if !predicate, tag == .pronoun, subject { fragment = true }
            if tag == .verb && subject && previous != "to" && !word.hasSuffix("ing") { predicate = true }
            if tag == .noun || tag == .pronoun || tag == .determiner { subject = true }
            previous = word
            return true
        }
        return predicate && !fragment
    }

    /// The punctuation pass can insert sentence marks and capitalize starts, but
    /// cannot rewrite words or turn a declarative clause into an invented question.
    public static func isPunctuationRepair(original: String, corrected: String) -> Bool {
        AutoApplyPolicy.allowsPunctuation(original: original, corrected: corrected)
    }
}
