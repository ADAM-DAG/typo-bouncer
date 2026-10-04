import Testing
@testable import BouncerCore

@Test func trailingWhitespaceCleanupPreservesLayoutAndProtectedCode() {
    for (original, expected) in [
        ("  Keep  these words.  \t\r\n\tNext 👩🏽‍💻.  \n   \nEnd. \t", "  Keep  these words.\r\n\tNext 👩🏽‍💻.\n\nEnd."),
        ("One. \rTwo.\t\u{2028}Three. \u{2029}", "One.\rTwo.\u{2028}Three.\u{2029}"),
        ("Keep this\u{00A0} \t", "Keep this\u{00A0}"),
        ("```swift\nlet count = 1  \n```  \nText.  ", "```swift\nlet count = 1  \n```\nText."),
        ("Code: `keep  `  ", "Code: `keep  `"),
        ("```swift\nlet count = 1  ", "```swift\nlet count = 1  ")
    ] {
        let cleaned = ProofreadingTypography.removeTrailingWhitespace(original)
        #expect(cleaned.utf8.elementsEqual(expected.utf8))
        #expect(ProofreadingTypography.removeTrailingWhitespace(cleaned) == cleaned)
    }
}

@Test func englishPronounsDoNotRewriteAmbiguousWordsOrProtectedText() {
    #expect(ProofreadingTypography.repairEnglishPronouns("hi im alex i wanted to ask you a question about the meeting tomorrow") == "hi I'm alex I wanted to ask you a question about the meeting tomorrow")
    #expect(ProofreadingTypography.repairEnglishPronouns("ive finished the work and i can send it") == "I've finished the work and I can send it")
    for text in ["The ill patient has an id card.", "Ich bin im Haus und warte auf dich.", "The variable `i` is used in this example.", "Visit https://example.com/i for more information.", "The im_value and obj.i identifiers stay as written.", "The path /im/ is used for the output."] {
        #expect(ProofreadingTypography.repairEnglishPronouns(text) == text)
    }
}

@Test func runOnQuestionsNeedBoundaryPassButOrdinaryTextDoesNot() throws {
    #expect(QuestionPunctuation.needsBoundaryReview("Hi I'm Adam I wanted to test if this works can you help me"))
    #expect(QuestionPunctuation.needsBoundaryReview("I got the file is it the final version?"))
    for text in ["Can you help me", "Hi, I'm Adam. Can you help me?", "I wonder where you are", "Please bring the book home.", "Hi Adam,\nCan you help me", "`can you help me` stays unchanged"] {
        #expect(!QuestionPunctuation.needsBoundaryReview(text))
    }
    let correction = try OutputValidator.validate(original: "I got the file is it the final version", corrected: "I got the file. Is it the final version?")
    #expect(AutoApplyPolicy.allows(correction, command: .proofread, misspelledWords: [], correctedMisspellings: []))
}

@Test func sentenceStartCapitalizationPreservesMixedCaseAndProtectedContent() {
    #expect(ProofreadingTypography.capitalizeStart("adam is the best") == "Adam is the best")
    #expect(ProofreadingTypography.capitalizeStart("i'm here") == "I'm here")
    #expect(ProofreadingTypography.capitalizeStart("iPhone is ready.") == "iPhone is ready.")
    for text in ["www.example.com is live", "`code` stays", "@adam is here", "Adam found the nest.", "😊 hello", "  hello"] {
        #expect(ProofreadingTypography.capitalizeStart(text) == text)
    }
}

@Test func missingQuestionMarksPreserveMeaningAndWhitespace() {
    for text in ["Can you help me", "Where are you going.", "Kun je mij helpen", "Hoe gaat het met je", "Hoe laat is het", "what time is the meeting", "What's next", "Why can't you help", "Isn't it ready"] {
        #expect(QuestionPunctuation.addMissingMark(text).hasSuffix("?"))
    }
    #expect(QuestionPunctuation.addMissingMark(" \tCan you help me\r\n") == " \tCan you help me?\r\n")
    #expect(QuestionPunctuation.addMissingMark("What is 2 + 2") == "What is 2 + 2?")
    for text in ["Do the dishes", "Have a good day", "Was je handen", "Doe je werk", "I wonder where you are", "When I arrive", "What a lovely day", "Can you", "Who is", "Can you help me!", "Can you help me?", "Where are you going. I am lost.", "Can you help\nme", "What does `f()` return", "Why:", "Where is this URL https://example.com"] {
        #expect(QuestionPunctuation.addMissingMark(text) == text)
    }
}

@Test func acceptedDutchCasualWordingIsPreservedWithoutMaskingOtherEdits() {
    #expect(LanguageGate.detect("Hoe gaat het met je") == nil)
    #expect(ProofreadingTypography.preserveAcceptedVariants(original: "Hoe gaat het met je", corrected: "Hoe gaat het met jou?") == "Hoe gaat het met je?")
    #expect(ProofreadingTypography.preserveAcceptedVariants(original: "Ik heb het gister gedaan.", corrected: "Ik heb het gisteren gedaan.") == "Ik heb het gister gedaan.")
    #expect(ProofreadingTypography.preserveAcceptedVariants(original: "Dit is voor jij.", corrected: "Dit is voor jou.") == "Dit is voor jou.")
    #expect(ProofreadingTypography.preserveAcceptedVariants(original: "Ik kom morgen bij je.", corrected: "Ik kom vandaag bij jou.") == "Ik kom vandaag bij jou.")
    #expect(ProofreadingTypography.preserveAcceptedVariants(original: "Ik kom om 3 uur bij je.", corrected: "Ik kom om 4 uur bij jou.") == "Ik kom om 4 uur bij jou.")
}

@Test func questionsInsideMessagesKeepSentenceAndLineBoundaries() {
    #expect(QuestionPunctuation.addMissingMarks("Hi Adam. Can you help me") == "Hi Adam. Can you help me?")
    #expect(QuestionPunctuation.addMissingMarks("Where are you going. I am lost.") == "Where are you going? I am lost.")
    #expect(QuestionPunctuation.addMissingMarks("Hoi,\r\n\r\nKun je morgen bellen\r\nDank je.") == "Hoi,\r\n\r\nKun je morgen bellen?\r\nDank je.")
    #expect(QuestionPunctuation.addMissingMarks("How many files are there\nWeet je waar het is") == "How many files are there?\nWeet je waar het is?")
    for text in ["Where is Dr. Smith", "Can you run `help()`", "```\nCan you help me\n```", "Please help me. Thanks.", "Was je handen\nDoe je werk", "Kom je moeder helpen", "Ga je werk doen", "Vind je sleutels", "When I arrive. We can start."] {
        #expect(QuestionPunctuation.addMissingMarks(text) == text)
    }
}
@Test func nameCapitalizationRestoresCaseOnlyEditsInsideProtectedTokens() throws {
    let original = " 👩🏽‍💻 ask adam: @adam #sanne adam@example.com https://example.com/adam `let adam = true`\r\n "
    let generated = " 👩🏽‍💻 ask Adam: @Adam #Sanne Adam@example.com https://example.com/Adam `let Adam = true`\r\n "
    let expected = " 👩🏽‍💻 ask Adam: @adam #sanne adam@example.com https://example.com/adam `let adam = true`\r\n "
    let restored = ProofreadingTypography.restoreProtectedCapitalization(original: original, corrected: generated)
    #expect(restored == expected)
    #expect(try OutputValidator.validate(original: original, corrected: restored).corrected == expected)
}

@Test func protectedCapitalizationRepairDoesNotHideSubstantiveChanges() {
    let original = "Ask adam via @adam at adam@example.com."
    for changed in ["Ask Adam via @alex at adam@example.com.",
                    "Ask Adam via @adam at alex@example.com.",
                    "Ask Adam at adam@example.com.",
                    "Ask Adam via @adam and @sanne at adam@example.com."] {
        let restored = ProofreadingTypography.restoreProtectedCapitalization(original: original, corrected: changed)
        #expect(throws: ValidationFailure.protectedTokens) {
            try OutputValidator.validate(original: original, corrected: restored)
        }
    }
    let reordered = "Ask Adam via adam@example.com at @adam."
    #expect(ProofreadingTypography.restoreProtectedCapitalization(original: original, corrected: reordered) == reordered)
}

@Test func alignedPersonalNamesKeepTheirOriginalSpellingAndAccents() {
    #expect(ProofreadingTypography.restoreAlignedNameSpelling(original: "Kun je youssef en mariam vragen of ze komen?", corrected: "Kun je Yusuf en Mariam vragen of ze komen?") == "Kun je Youssef en Mariam vragen of ze komen?")
    #expect(ProofreadingTypography.restoreAlignedNameSpelling(original: "Please ask zoë and josé to join us.", corrected: "Please ask Zoe and José to join us.") == "Please ask Zoë and José to join us.")
}

@Test func nameSpellingRepairPreservesRewritesSentenceStartsAndProtectedText() {
    for (original, corrected) in [
        ("She go to school.", "She goes to school."),
        ("this is a message.", "This is a message."),
        ("because I was tired I went home.", "Since I was tired, I went home."),
        ("Please ask @youssef to join us.", "Please ask @Yusuf to join us."),
        ("Kun je youssef vragen of ze komen?", "Kun je Yusuf en Mariam vragen of ze komen?")
    ] {
        #expect(ProofreadingTypography.restoreAlignedNameSpelling(original: original, corrected: corrected) == corrected)
    }
}
