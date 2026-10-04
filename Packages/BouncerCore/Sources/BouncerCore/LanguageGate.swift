import Foundation
import NaturalLanguage

public struct DetectedLanguage: Sendable, Equatable {
    public let code: String
    public let confidence: Double
}

public enum LanguageGate {
    public static func detect(_ text: String, minimumLetters: Int = 20) -> DetectedLanguage? {
        guard text.filter(\.isLetter).count >= max(1, minimumLetters) else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 3).max(by: { $0.value < $1.value }) else { return nil }
        return DetectedLanguage(code: best.key.rawValue, confidence: best.value)
    }

    public static func unsupportedLanguage(in text: String, supported: Set<String>) -> String? {
        guard let language = detect(text), language.confidence >= 0.65, !supported.contains(language.code) else { return nil }
        return language.code
    }

    public static func changed(original: String, corrected: String) -> Bool {
        guard let before = detect(original), let after = detect(corrected),
              before.confidence >= 0.75, after.confidence >= 0.75 else { return false }
        return before.code != after.code
    }
}
