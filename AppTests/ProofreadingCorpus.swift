import Foundation

struct ProofreadingCase {
    let id: String
    let language: String
    let text: String
    let required: [String]
    let forbidden: [String]

    func passed(_ output: String) -> Bool {
        let normalized = output.lowercased().replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "does not", with: "doesn't")
            .replacingOccurrences(of: "do not", with: "don't")
            .replacingOccurrences(of: "they are", with: "they're")
        return required.allSatisfy { normalized.contains($0.lowercased()) }
            && forbidden.allSatisfy { !normalized.contains($0.lowercased()) }
    }
}

enum ProofreadingCorpus {
    static let errors: [ProofreadingCase] = [
        .init(id: "en-context-nest", language: "en", text: "adam is the nest", required: ["adam", "the best"], forbidden: ["the nest"]),
        .init(id: "en-context-unfamiliar-name", language: "en", text: "sanne is the nest", required: ["sanne", "the best"], forbidden: ["the nest"]),
        .init(id: "en-context-food", language: "en", text: "I hope you have a food day.", required: ["good day"], forbidden: ["food day"]),
        .init(id: "en-context-weight", language: "en", text: "I can't weight to see you again.", required: ["can't wait"], forbidden: ["can't weight"]),
        .init(id: "en-agreement", language: "en", text: "She don't know where the keys is.", required: ["doesn't", "keys are"], forbidden: ["don't", "keys is"]),
        .init(id: "en-past", language: "en", text: "I has went to the store yesterday and buyed three apple's.", required: ["bought", "apples"], forbidden: ["has went", "have went", "buyed", "apple's"]),
        .init(id: "en-auxiliary", language: "en", text: "He have already finish his homework.", required: ["has", "finished"], forbidden: ["he have"]),
        .init(id: "en-plural", language: "en", text: "These document needs to be signed before Friday.", required: ["documents need"], forbidden: ["document needs"]),
        .init(id: "en-their", language: "en", text: "Their going to bring there own food to the party.", required: ["they're going", "their own"], forbidden: ["their going", "there own"]),
        .init(id: "en-typos", language: "en", text: "I recieved your mesage and will reply tomorow.", required: ["received", "message", "tomorrow"], forbidden: ["recieved", "mesage", "tomorow"]),
        .init(id: "en-capitals", language: "en", text: "can you help me? i dont understand this sentence", required: ["don't"], forbidden: ["dont"]),
        .init(id: "en-multiline", language: "en", text: "Hi Sanne,\nThanks for teh help at 15:30 🙏🏻.\nI will reply tomorow.", required: ["the help", "tomorrow", "15:30", "🙏🏻"], forbidden: ["teh", "tomorow"]),
        .init(id: "nl-auxiliary", language: "nl", text: "Ik heb gisteren naar de winkel gegaan.", required: ["ik ben", "gegaan"], forbidden: ["ik heb"]),
        .init(id: "nl-dt", language: "nl", text: "Hij word morgen dertig en ik wordt er blij van.", required: ["hij wordt", "ik word er"], forbidden: ["hij word morgen", "ik wordt"]),
        .init(id: "nl-participle", language: "nl", text: "Wat is er gebeurt? Het gebeurd vaak.", required: ["is er gebeurd", "het gebeurt"], forbidden: ["is er gebeurt", "het gebeurd"]),
        .init(id: "nl-comparative", language: "nl", text: "Mijn broer is groter als ik.", required: ["groter dan"], forbidden: ["groter als"]),
        .init(id: "nl-pronoun", language: "nl", text: "Hun hebben het zelf gezegd.", required: ["hebben het zelf gezegd"], forbidden: ["hun hebben"]),
        .init(id: "nl-accent-repeat", language: "nl", text: "Ik ben geinteresseerd in een een afspraak volgende week.", required: ["geïnteresseerd", "een afspraak"], forbidden: ["een een"]),
        .init(id: "nl-typos", language: "nl", text: "Ik ben morgen weer tuis en stuur je dan een antword.", required: ["thuis", "antwoord"], forbidden: ["tuis", "antword"]),
        .init(id: "nl-multiline", language: "nl", text: "Hoi Sanne,\nkan je morgen om 10 uur bellen? ik ben de hele dag tuis.\nGroetjes, Adam 😊", required: ["thuis", "10", "😊"], forbidden: ["tuis"])
    ]
}
