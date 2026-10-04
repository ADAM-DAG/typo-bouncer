import Foundation
import Testing
@testable import BouncerCore

@Test func newAssistantFormattingIsRejectedForBothActions() throws {
    for command in [Command.proofread, .improveSentences] {
        for pair in [
            ("It works, thanks.", "It works—thanks."),
            ("It works, thanks.", "It works – thanks."),
            ("It works, thanks.", "It works -- thanks."),
            ("It works. Thanks.", "It works; thanks."),
            ("It works.", "**It works.**"), ("It works.", "*It works.*"),
            ("It works.", "_It works._"), ("It works.", "__It works.__"),
            ("It works.", "~~It works.~~"), ("It works.", "# It works."),
            ("It works.", "- It works."), ("It works.", "> It works."),
            ("1 item", "1. Item"), ("It works.", "• It works.")
        ] {
            #expect(throws: ValidationFailure.style) {
                try OutputValidator.validate(original: pair.0, corrected: pair.1, command: command)
            }
        }
    }
}

@Test func existingFormattingDashesAndProtectedContentArePreserved() throws {
    for text in ["It works—thanks!", "It works – thanks!", "**My draft**", "_My draft_",
                 "- Apples\n- Pears", "# My heading", "> A quote", "1. First item",
                 "`idk; a—b`", "https://example.com/idk", "idk@example.com"] {
        #expect(try OutputValidator.validate(original: text, corrected: text).isUnchanged)
    }
    #expect(try OutputValidator.validate(original: "**teh draft**", corrected: "**the draft**").corrected == "**the draft**")
}

@Test func shorthandExpandsOnlyWholeKnownWordsOutsideProtectedContent() {
    #expect(ChatShorthand.expand("idk. TBH, btw rn lmk") == "I don't know. to be honest, by the way right now let me know")
    let protected = "`idk` @idk #idk idk@example.com https://example.com/idk my_idk idk.txt idkCount /idk idk's rn-idk"
    #expect(ChatShorthand.expand(protected) == protected)
    #expect(ChatShorthand.expand(" 👩🏽‍💻 idk\r\n\tbtw ") == " 👩🏽‍💻 I don't know\r\n\tby the way ")
    #expect(ChatShorthand.expand("u ur r ig lol") == "u ur r ig lol")
}

@Test func shorthandRequiresExplicitOptInAndKeepsOriginalDiff() throws {
    let original = "idk what to say tbh idk what to do rn btw lmk"
    let expanded = ChatShorthand.expand(original)
    #expect(throws: ValidationFailure.shorthand) {
        try OutputValidator.validate(original: original, corrected: expanded)
    }
    let correction = try OutputValidator.validate(original: original, corrected: expanded, expandShorthand: true)
    #expect(correction.original == original)
    #expect(correction.corrected == expanded)
    #expect(correction.segments.filter { $0.kind != .inserted }.map(\.text).joined() == original)
    #expect(throws: ValidationFailure.protectedTokens) {
        try OutputValidator.validate(original: "idk at 15:30", corrected: "I don't know at 16:30", expandShorthand: true)
    }
    #expect(try OutputValidator.validate(original: "idk yet", corrected: "Idk yet.").corrected == "Idk yet.")
}

@Test func allLanguagePromptsPreservePlainStyle() {
    for command in [Command.proofread, .improveSentences] {
        for language in ["en", "nl"] {
            #expect(command.instructions(language: language).contains(PlainWritingStyle.instructions))
        }
    }
}

@Test func unwantedShorthandExpansionsRestoreOnlyTheirOwnWordEdits() {
    let fixtures = [
        ("idk what the plan is", "I don't know what the plan is.", "idk what the plan is."),
        ("idk what teh plan is", "I do not know what the plan is.", "idk what the plan is."),
        ("I don't know why, idk what to do", "I don't know why. I don't know what to do.", "I don't know why. idk what to do."),
        ("btw idk why", "By the way, I don't know why.", "btw, idk why."),
        ("idk why idk when", "I don't know why. I don't know when.", "idk why. idk when."),
        ("idk why. I have no clue.", "I'm not sure why. I don't know.", "I'm not sure why. I don't know."),
        ("Read `I don't know` idk why", "Read `I don't know`. I don't know why.", "Read `I don't know`. idk why.")
    ]
    for (original, corrected, expected) in fixtures {
        #expect(ChatShorthand.restoringExpansions(original: original, corrected: corrected) == expected)
    }
}
