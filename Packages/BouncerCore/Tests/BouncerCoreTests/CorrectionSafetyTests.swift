import Foundation
import Testing
@testable import BouncerCore

@Test func trailingWhitespaceDoesNotMaskOrBlockLengthValidation() throws {
    let sentence = "We should keep every important detail in this message."
    let padded = sentence + String(repeating: " ", count: 300)
    for command in Command.allCases {
        #expect(try OutputValidator.validate(original: padded, corrected: sentence, command: command).corrected == sentence)
        #expect(throws: ValidationFailure.length) {
            try OutputValidator.validate(original: padded, corrected: "We should.", command: command)
        }
    }
}

@Test func boundaryWhitespaceAndMixedNewlinesAreRestored() {
    let original = " \tHoi Sanne,\r\nIk ben tuis.\nGroetjes!\r\n "
    let peel = TextPeel(original)
    #expect(peel.normalizedBody == "Hoi Sanne,\nIk ben tuis.\nGroetjes!")
    #expect(peel.restore("Hoi Sanne,\nIk ben thuis.\nGroetjes!\n") == " \tHoi Sanne,\r\nIk ben thuis.\nGroetjes!\r\n ")
    #expect(TextPeel(" \r\n ").restore("") == " \r\n ")
}

@Test(arguments: [
    ("Thanks 👩🏽‍💻 for teh help 🙏🏻", "Thanks 👩🏽‍💻 for the help 🙏🏻"),
    ("one two three", "one four three"),
    ("hello", ""),
    ("", "hello"),
    ("a\r\nb", "a\r\nc"),
    ("Meeting with أحمد tomorow", "Meeting with أحمد tomorrow"),
    ("cafe\u{0301} hello", "cafe\u{0301} world")
])
func diffReconstructsBothSides(pair: (String, String)) {
    let segments = WordDiff.segments(original: pair.0, corrected: pair.1)
    #expect(segments.filter { $0.kind != .inserted }.map(\.text).joined() == pair.0)
    #expect(segments.filter { $0.kind != .removed }.map(\.text).joined() == pair.1)
}

@Test(arguments: [
    ("Invoice €1.250,00 at 15:30", "Invoice €1.250,01 at 15:30"),
    ("Visit https://example.com/a?b=1", "Visit https://example.com/a?b=2"),
    ("Mail adam@example.com", "Mail adam@other.com"),
    ("Hello @adam #hello", "Hello @Adam #hello"),
    ("Thanks 👩🏽‍💻 🙏🏻", "Thanks 👩🏽‍💻 🙏"),
    ("Code: `teh = 1`", "Code: `the = 1`"),
    ("```swift\nlet cafe\u{0301} = 1\n```", "```swift\nlet café = 1\n```"),
    ("Due on 14-03-2026", "Due on 15-03-2026")
])
func protectedChangesAreRejected(pair: (String, String)) {
    #expect(throws: ValidationFailure.protectedTokens) {
        try OutputValidator.validate(original: pair.0, corrected: pair.1)
    }
}

@Test func normalCorrectionsKeepProtectedContentAndHaveAUsableDiff() throws {
    let old = "Thanks 👩🏽‍💻 for teh help 🙏🏻 at 15:30."
    let new = "Thanks 👩🏽‍💻 for the help 🙏🏻 at 15:30."
    let result = try OutputValidator.validate(original: old, corrected: new)
    #expect(!result.isUnchanged)
    #expect(result.warnings.isEmpty)
    #expect(result.segments.contains { $0.kind == .inserted && $0.text.contains("the") })
}

@Test func noOpIsRecognizedAndLineChangesAreRefused() throws {
    #expect(try OutputValidator.validate(original: "Hello!", corrected: "Hello!").isUnchanged)
    #expect(throws: ValidationFailure.lineBreaks) {
        try OutputValidator.validate(original: "Hello\nworld", corrected: "Hello world")
    }
}

@Test func emptyPreamblesAndCurrentNonceAreRefused() {
    #expect(throws: ValidationFailure.empty) { try OutputValidator.validate(original: "Hello", corrected: " ") }
    #expect(throws: ValidationFailure.preamble) { try OutputValidator.validate(original: "teh cat", corrected: "Corrected text: the cat") }
    #expect(throws: ValidationFailure.markers) { try OutputValidator.validate(original: "hello", corrected: "<text-deadbeef>hello", nonce: "deadbeef") }
}

@Test func NamesAndLargeRewritesWarn() throws {
    let result = try OutputValidator.validate(original: "Meet Jeroen tomorrow.", corrected: "Meet Jerome tomorrow.")
    #expect(result.warnings.contains(.possibleName))
    let rewrite = try OutputValidator.validate(original: "one two three", corrected: "four five six")
    #expect(rewrite.warnings.contains(.extensiveChanges))
}

@Test func languageGateRejectsClearUnsupportedTextAndTranslation() {
    let arabic = "هذا نص باللغة العربية ولا ينبغي ترجمته إلى لغة أخرى أبداً."
    #expect(LanguageGate.unsupportedLanguage(in: arabic, supported: ["en", "nl"]) == "ar")
    #expect(LanguageGate.unsupportedLanguage(in: "teh", supported: ["en", "nl"]) == nil)
    #expect(LanguageGate.changed(original: "Ik heb gisteren een lange wandeling gemaakt en daarna heb ik boodschappen gedaan.", corrected: "I took a long walk yesterday and then I went shopping at the supermarket."))
}

@Test func oversizedCombiningSequenceIsRefusedBeforeModelUse() {
    let text = "a" + String(repeating: "\u{0301}", count: 40_000)
    #expect(throws: SelectionError.tooManyBytes) { try SelectionPolicy().validate(text) }
}
@Test func unicodeNormalizationIsVisibleInTheDiff() {
    let old = "cafe\u{0301}"
    let new = "café"
    let diff = WordDiff.segments(original: old, corrected: new)
    #expect(diff.contains { $0.kind == .removed })
    #expect(diff.filter { $0.kind != .inserted }.map(\.text).joined().utf8.elementsEqual(old.utf8))
}
