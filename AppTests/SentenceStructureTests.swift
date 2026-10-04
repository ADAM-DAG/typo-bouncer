import BouncerCore
import FoundationModels
import XCTest
@testable import TypoBouncer

final class SentenceStructureTests: XCTestCase {
    func testRealSentenceImprovementsKeepFactsAndLanguage() async throws {
        guard SystemLanguageModel.default.isAvailable else { throw XCTSkip("On-device model unavailable") }
        let service = OnDeviceModel()
        let fixtures: [(String, [String], [String])] = [
            ("The report I sent yesterday to you it has all the numbers that you need in it.", ["report", "yesterday", "numbers"], ["you it has"]),
            ("Naar de winkel ik gisteren ben gegaan want brood nodig ik had.", ["winkel", "gisteren", "brood"], ["winkel ik gisteren", "brood nodig ik had"]),
            ("Het bestand dat ik naar jou heb gestuurd het bevat alle gegevens die je nodig hebt erin.", ["bestand", "gestuurd", "gegevens"], ["gestuurd het bevat"]),
            ("Sanne, the meeting at 15:30 it is tomorrow and I will be there 😊.", ["Sanne", "15:30", "tomorrow", "😊"], ["15:30 it is"])
        ]
        for (index, fixture) in fixtures.enumerated() {
            let result = try await service.correct(fixture.0, limit: 1500, command: .improveSentences)
            XCTAssertFalse(result.isUnchanged, "Sentence fixture \(index) was unchanged")
            for fact in fixture.1 { XCTAssertTrue(result.corrected.lowercased().contains(fact.lowercased()), "Fact missing in sentence fixture \(index)") }
            for awkward in fixture.2 { XCTAssertFalse(result.corrected.lowercased().contains(awkward), "Awkward structure retained in sentence fixture \(index)") }
        }
    }

    func testActionsDifferOnGrammaticalWordyMessages() async throws {
        guard SystemLanguageModel.default.isAvailable else { throw XCTSkip("On-device model unavailable") }
        let service = OnDeviceModel()
        let fixtures = [
            ("I wanted to explain that I reviewed the draft and that I will email you my feedback on Friday.", ["reviewed", "draft", "feedback", "friday"]),
            ("Ik wilde je vertellen dat ik het verslag heb gelezen en dat ik je maandag mijn opmerkingen zal sturen.", ["verslag", "gelezen", "opmerkingen", "maandag"])
        ]
        for (index, fixture) in fixtures.enumerated() {
            let proofread = try await service.correct(fixture.0, limit: 1500, command: .proofread)
            let improved = try await service.correct(fixture.0, limit: 1500, command: .improveSentences)
            print("Synthetic action contrast \(index): proofread unchanged \(proofread.isUnchanged), improve unchanged \(improved.isUnchanged), characters \(fixture.0.count) -> \(improved.corrected.count)")
            XCTAssertTrue(proofread.isUnchanged, "Grammatical wording should stay unchanged in Proofread fixture \(index)")
            XCTAssertLessThan(improved.corrected.count, Int(Double(fixture.0.count) * 0.85), "Improve should meaningfully remove unnecessary framing in fixture \(index)")
            for fact in fixture.1 {
                XCTAssertTrue(improved.corrected.lowercased().contains(fact), "Required fact missing in fixture \(index)")
            }
        }
    }

}
