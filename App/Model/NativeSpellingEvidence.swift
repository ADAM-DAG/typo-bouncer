import AppKit
import BouncerCore
import NaturalLanguage

@MainActor
enum NativeSpellingEvidence {
    static func allowsAuto(_ correction: ValidatedCorrection, command: Command) -> Bool {
        guard command == .proofread, correction.original.count <= 400 else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(correction.original)
        guard let language = recognizer.languageHypotheses(withMaximum: 3).max(by: { $0.value < $1.value }),
              language.value >= 0.60, ["en", "nl"].contains(language.key.rawValue) else { return false }
        let checker = NSSpellChecker.shared
        guard checker.availableLanguages.contains(where: { $0 == language.key.rawValue || $0.hasPrefix(language.key.rawValue + "_") || $0.hasPrefix(language.key.rawValue + "-") }) else { return false }
        let tag = NSSpellChecker.uniqueSpellDocumentTag()
        defer { checker.closeSpellDocument(withTag: tag) }
        return AutoApplyPolicy.allows(correction, command: command,
            misspelledWords: misspellings(correction.original, language: language.key.rawValue, checker: checker, tag: tag),
            correctedMisspellings: misspellings(correction.corrected, language: language.key.rawValue, checker: checker, tag: tag))
    }

    private static func misspellings(_ text: String, language: String, checker: NSSpellChecker, tag: Int) -> Set<String> {
        var words: Set<String> = []
        var offset = 0
        while offset < text.utf16.count {
            let found = checker.checkSpelling(of: text, startingAt: offset, language: language,
                                             wrap: false, inSpellDocumentWithTag: tag, wordCount: nil)
            guard found.location != NSNotFound, found.length > 0,
                  let range = Range(found, in: text) else { break }
            words.insert(String(text[range]).lowercased())
            let next = NSMaxRange(found)
            guard next > offset else { break }
            offset = next
        }
        return words
    }
}
