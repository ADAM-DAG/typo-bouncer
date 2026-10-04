import Testing
@testable import BouncerCore

@Test func completeStatementsReceivePeriodsWithoutGeneration() {
    for text in ["The upload has finished", "Your changes look correct", "We received the proposal",
                 "This is the message I received", "I will send it tomorrow", "I know who sent it",
                 "Thanks for sending this", "Ik heb de documenten ontvangen", "Dat werkt nu goed",
                 "Wij zijn er morgen weer", "Bedankt voor het bericht"] {
        #expect(SentencePunctuation.addMissingPeriods(text) == text + ".")
    }
}

@Test func punctuationKeepsFragmentsHeadingsCodeAndIntentionalEndings() {
    for text in ["Project status", "Weekly project status", "Project planning meeting", "Things to do",
                 "The changes I made", "The man who lives next door", "On Monday morning",
                 "Because of the weather", "When I arrive", "# Release notes", "- Buy some milk",
                 "I got the file. Project status", "Thanks!", "Wait…", "I agree...", "Are you ready",
                 "https://example.com", "Use `make build`", "I am ready 😊"] {
        #expect(SentencePunctuation.addMissingPeriods(text) == text)
    }
}

@Test func completionPreservesLineBreaksAndWhitespace() {
    let text = " \tThe draft is ready  \r\n\r\nIk stuur het morgen\nProject status\n "
    #expect(SentencePunctuation.addMissingPeriods(text) == " \tThe draft is ready.  \r\n\r\nIk stuur het morgen.\nProject status\n ")
}

@Test func onlyLongUnfinishedProseNeedsSentenceBoundaryReview() {
    #expect(SentencePunctuation.needsReview("The upload has finished the file is ready to download"))
    #expect(SentencePunctuation.needsReview("Ik heb de documenten ontvangen ik stuur ze morgen terug"))
    for text in ["The upload has finished", "The file is ready to download.", "# The file is ready to download", "- The file is ready to download", "`the file is ready to download now`"] {
        #expect(!SentencePunctuation.needsReview(text))
    }
    #expect(SentencePunctuation.isProtectedOnly(" https://example.com "))
    #expect(SentencePunctuation.isProtectedOnly("`let ready = true`"))
    #expect(!SentencePunctuation.isProtectedOnly("The link is https://example.com"))
}

@Test func punctuationPassCannotInventQuestionsChangeWordsOrEraseMarks() {
    #expect(SentencePunctuation.isPunctuationRepair(original: "the file is ready it can be sent", corrected: "The file is ready. It can be sent."))
    #expect(SentencePunctuation.isPunctuationRepair(original: "I got the file can you check it", corrected: "I got the file. Can you check it?"))
    for (original, corrected) in [
        ("I will send it tomorrow.", "I will send it tomorrow.?"),
        ("I will send it tomorrow", "I will send it tomorrow?"),
        ("This works better now", "This works better not."),
        ("Let's eat, grandma!", "Let's eat grandma."),
        ("My US friend is here", "My us friend is here.")
    ] {
        #expect(!SentencePunctuation.isPunctuationRepair(original: original, corrected: corrected))
    }
}

@Test func onlyModelIntroducedCommaSplicesBecomeSentenceBoundaries() {
    let en = "The window is open the spinner is still visible"
    #expect(SentencePunctuation.separateIntroducedClauses(original: en,
        corrected: "The window is open, the spinner is still visible.") ==
        "The window is open. The spinner is still visible.")
    let nl = "Ik heb het bestand ontvangen ik stuur het morgen terug"
    #expect(SentencePunctuation.separateIntroducedClauses(original: nl,
        corrected: "Ik heb het bestand ontvangen, ik stuur het morgen terug.") ==
        "Ik heb het bestand ontvangen. Ik stuur het morgen terug.")
    for text in ["Hi, I'm here.", "When I arrive, we can start.", "I came, I saw, I conquered."] {
        #expect(SentencePunctuation.separateIntroducedClauses(original: text, corrected: text) == text)
    }
    #expect(SentencePunctuation.separateIntroducedClauses(original: "When I arrive we can start",
        corrected: "When I arrive, we can start.") == "When I arrive, we can start.")
}
