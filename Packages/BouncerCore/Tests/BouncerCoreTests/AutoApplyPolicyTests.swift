import Testing
@testable import BouncerCore

@Test func cleanAllowsTrailingWhitespaceRemovalWithoutAllowingOtherSpacingChanges() throws {
    for (original, corrected) in [
        ("Keep this.  \t", "Keep this."),
        ("  Keep this.  \r\n\tKeep that. \n", "  Keep this.\r\n\tKeep that.\n"),
        ("can you help me  ", "Can you help me?")
    ] {
        let result = try OutputValidator.validate(original: original, corrected: corrected)
        #expect(AutoApplyPolicy.allows(result, command: .proofread, misspelledWords: [], correctedMisspellings: []))
        #expect(AutoApplyPolicy.allowsPunctuation(original: original, corrected: corrected))
    }
    for (original, corrected) in [
        ("Keep  this.  ", "Keep this."),
        ("  Keep this.  ", "Keep this."),
        ("Keep this.", "Keep this.  ")
    ] {
        let result = try OutputValidator.validate(original: original, corrected: corrected)
        #expect(!AutoApplyPolicy.allows(result, command: .proofread, misspelledWords: [], correctedMisspellings: []))
        #expect(!AutoApplyPolicy.allowsPunctuation(original: original, corrected: corrected))
    }
}

@Test func autoAllowsDictionaryConfirmedTyposAndRejectsSemanticOrLargeChanges() throws {
    let typo = try OutputValidator.validate(original: "This is teh first draft.", corrected: "This is the first draft.")
    #expect(AutoApplyPolicy.allows(typo, command: .proofread, misspelledWords: ["teh"], correctedMisspellings: []))
    #expect(!AutoApplyPolicy.allows(typo, command: .proofread, misspelledWords: [], correctedMisspellings: []))
    #expect(!AutoApplyPolicy.allows(typo, command: .proofread, misspelledWords: ["teh"], correctedMisspellings: ["the"]))
    #expect(!AutoApplyPolicy.allows(typo, command: .improveSentences, misspelledWords: ["teh"], correctedMisspellings: []))
    let meaning = try OutputValidator.validate(original: "I hope you have a food day.", corrected: "I hope you have a good day.")
    #expect(!AutoApplyPolicy.allows(meaning, command: .proofread, misspelledWords: [], correctedMisspellings: []))
    let name = try OutputValidator.validate(original: "Sanne wrote this message to me.", corrected: "Anne wrote this message to me.")
    #expect(!AutoApplyPolicy.allows(name, command: .proofread, misspelledWords: ["sanne"], correctedMisspellings: []))
    let negation = try OutputValidator.validate(original: "I dont want to go there.", corrected: "I don't want to go there.")
    #expect(AutoApplyPolicy.allows(negation, command: .proofread, misspelledWords: ["dont"], correctedMisspellings: []))
    for (original, corrected) in [("Let's eat, grandma!", "Let's eat grandma!"), ("You are coming today?", "You are coming today.")] {
        let punctuation = try OutputValidator.validate(original: original, corrected: corrected)
        #expect(!AutoApplyPolicy.allows(punctuation, command: .proofread, misspelledWords: [], correctedMisspellings: []))
    }
}

@Test func autoAllowsOnlyRecognizableQuestionPunctuationRepairs() throws {
    for (original, corrected) in [("can you help me", "Can you help me?"), ("how are you", "How are you?"), ("Kun je mij helpen", "Kun je mij helpen?"), ("Where are you going.", "Where are you going?")] {
        let result = try OutputValidator.validate(original: original, corrected: corrected)
        #expect(AutoApplyPolicy.allows(result, command: .proofread, misspelledWords: [], correctedMisspellings: []))
    }
    for (original, corrected) in [("You are coming today.", "You are coming today?"), ("Can you help me!", "Can you help me?"), ("Can you help me", "Can you call me?")] {
        let result = try OutputValidator.validate(original: original, corrected: corrected)
        #expect(!AutoApplyPolicy.allows(result, command: .proofread, misspelledWords: [], correctedMisspellings: []))
    }
}

@Test func structureValidationPreservesParagraphsAndProtectedTokens() throws {
    #expect(throws: ValidationFailure.lineBreaks) {
        try OutputValidator.validate(original: "One paragraph.\nAnother paragraph.", corrected: "One paragraph. Another paragraph.", command: .improveSentences)
    }
    #expect(throws: ValidationFailure.protectedTokens) {
        try OutputValidator.validate(original: "The meeting at 15:30 it is tomorrow.", corrected: "The meeting is tomorrow at 16:30.", command: .improveSentences)
    }
    let rewrite = try OutputValidator.validate(original: "The report I sent yesterday it has the numbers.", corrected: "The report I sent yesterday contains the numbers.", command: .improveSentences)
    #expect(!rewrite.isUnchanged)
    #expect(!AutoApplyPolicy.allows(rewrite, command: .improveSentences, misspelledWords: [], correctedMisspellings: []))
}

@Test func autoAppliesCasualProofreadingWithoutAllowingRewrites() throws {
    let original = "hi im adam i wanted to test if this works can you helpme"
    let correction = try OutputValidator.validate(original: original,
        corrected: "Hi, I'm Adam. I wanted to test if this works. Can you help me?")
    #expect(AutoApplyPolicy.allows(correction, command: .proofread, misspelledWords: ["im", "helpme"], correctedMisspellings: []))
    #expect(!AutoApplyPolicy.allows(correction, command: .proofread, misspelledWords: ["im"], correctedMisspellings: []))
    #expect(!AutoApplyPolicy.allows(correction, command: .proofread, misspelledWords: ["im", "helpme"], correctedMisspellings: ["help"]))
    for (old, new) in [
        ("i got the file is it the final version", "I got the file. Is it the final version?"),
        ("hello im maya i have finished the draft", "Hello, I'm Maya. I have finished the draft."),
        ("I dont want to go there", "I don't want to go there.")
    ] {
        let result = try OutputValidator.validate(original: old, corrected: new)
        #expect(AutoApplyPolicy.allows(result, command: .proofread, misspelledWords: [], correctedMisspellings: []))
    }
    for (old, new) in [
        ("I got the file is it the final version", "I received the file. Is it the final version?"),
        ("I really want to go there", "I want to go there."),
        ("I do not want to go there", "I do want to go there."),
        ("I dont want to go there", "I do want to go there."),
        ("I want to go nowhere today", "I want to go now here today."),
        ("The US team will arrive today", "The us team will arrive today."),
        ("Let's eat grandma", "Let's eat, grandma."),
        ("You are coming today", "You are coming today?"),
        ("I can help you", "I can. Help you?"),
        ("I have a file\ncan you check it", "I have a\nfile. Can you check it?")
    ] {
        let result = try OutputValidator.validate(original: old, corrected: new)
        #expect(!AutoApplyPolicy.allows(result, command: .proofread, misspelledWords: [], correctedMisspellings: []), "Rejected: \(new)")
    }
}
