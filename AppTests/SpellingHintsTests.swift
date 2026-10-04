import BouncerCore
import XCTest
@testable import TypoBouncer

@MainActor final class SpellingHintsTests: XCTestCase {
    func testContextCandidatesDoNotReplaceCorrectAdverbsOrInventNegation() {
        for text in ["This works much better now", "The file is already here", "We can meet there tomorrow"] {
            let candidates = SpellingHints.candidates(text, language: "en")
            for candidate in candidates {
                XCTAssertFalse(["now", "already", "here", "there", "tomorrow"].contains(candidate.words[0]))
                XCTAssertTrue(Set(candidate.words).isDisjoint(with: ["no", "not", "never", "none", "nor", "cannot", "without"]))
            }
        }
    }

    func testDirectQuestionsUseTheMainProofreaderWithoutSpeculativeContextRanking() {
        for text in ["Can you help me", "Where are you going?", "Why can't you help", "How many files are there"] {
            XCTAssertTrue(SpellingHints.candidates(text, language: "en").isEmpty)
        }
    }
    func testParallelContextMergeKeepsPunctuationAndNeverCombinesDifferentRewrites() {
        XCTAssertEqual(SpellingHints.mergeContext(original: "adam is the nest", generated: "Adam is the nest.", reviewed: "adam is the best"), "Adam is the best.")
        XCTAssertEqual(SpellingHints.mergeContext(original: "adam is the nest", generated: "Adam found the nest.", reviewed: "adam is the best"), "Adam found the nest.")
        XCTAssertEqual(SpellingHints.mergeContext(original: "adam is the nest", generated: "Adam is the Nest.", reviewed: "adam is the best"), "Adam is the Nest.")
        XCTAssertEqual(SpellingHints.mergeContext(original: "adam is the nest", generated: "Adam is the nest.", reviewed: "adam is best"), "Adam is the nest.")
    }
    func testNativeCandidatesIncludeContextualTypoWithoutHardcodedReplacement() {
        for text in ["adam is the nest", "Adam is the nest.", "sanne is the nest"] {
            let candidates = SpellingHints.candidates(text, language: nil)
            XCTAssertEqual(candidates.count, 1)
            XCTAssertTrue(candidates.first?.words.contains("best") == true)
            XCTAssertEqual(candidates.first?.words.first, "nest")
        }
    }
    func testNamesCodeAndOtherLanguagesAreNotSpeculativelyChanged() {
        XCTAssertTrue(SpellingHints.candidates("Adam is the Nest", language: "en").isEmpty)
        XCTAssertTrue(SpellingHints.candidates("adam is the `nest`", language: "en").isEmpty)
        XCTAssertTrue(SpellingHints.candidates("Ik ben thuis.", language: nil).isEmpty)
        XCTAssertTrue(SpellingHints.candidates("The colour of this café is lovely.", language: "en").isEmpty)
    }
    func testCandidatesOnlyChangeOneAsciiLetterAndKeepTheOriginalChoice() {
        for candidate in SpellingHints.candidates("this is a nest", language: "en") {
            let original = Array(candidate.words[0].lowercased().utf8)
            for word in candidate.words.dropFirst() {
                let next = Array(word.lowercased().utf8)
                XCTAssertEqual(original.count, next.count)
                XCTAssertEqual(zip(original, next).filter { $0 != $1 }.count, 1)
            }
        }
    }
}
