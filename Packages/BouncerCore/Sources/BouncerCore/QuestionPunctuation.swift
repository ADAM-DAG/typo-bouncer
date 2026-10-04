import Foundation

public enum QuestionPunctuation {
    /// A question after an unpunctuated clause needs reviewed sentence boundaries,
    /// not an automatic question mark guessed from the start of the whole message.
    public static func needsBoundaryReview(_ text: String) -> Bool {
        guard text.count <= 1_500, !ProtectedTokens.extract(text).contains(where: { $0.kind == .code }) else { return false }
        let tokens = WordDiff.tokens(text)
        var words = 0
        for index in tokens.indices {
            guard tokens[index].contains(where: \.isLetter) else { continue }
            defer { words += 1 }
            guard words >= 3, index > 0 else { continue }
            let prefix = tokens[..<index].joined()
            guard !prefix.hasSuffix("\n"), !prefix.hasSuffix("\r"),
                  let last = prefix.last(where: { !$0.isWhitespace }), !".!?,;:".contains(last) else { continue }
            var tail = tokens[index...].joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if tail.last == "?" { tail.removeLast() }
            if addMissingMark(tail) != tail { return true }
        }
        return false
    }
    /// Apply the conservative single-question rule at existing sentence and line
    /// boundaries. Keep every separator, blank line and protected token intact.
    public static func addMissingMarks(_ text: String) -> String {
        guard !ProtectedTokens.extract(text).contains(where: { $0.kind == .code }) else { return text }
        var output = ""
        var start = text.startIndex
        var index = start
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character.isNewline {
                output += addMissingMark(String(text[start..<index])) + String(character)
                start = next
            } else if ".!?".contains(character), next == text.endIndex || text[next].isWhitespace {
                let segment = String(text[start..<next])
                let lastWord = segment.dropLast().split(whereSeparator: \.isWhitespace).last?.lowercased() ?? ""
                if character == "." && ["mr", "mrs", "ms", "dr", "prof", "st", "vs", "etc", "dhr", "mevr"].contains(lastWord) {
                    index = next
                    continue
                }
                output += addMissingMark(segment)
                start = next
            }
            index = next
        }
        output += addMissingMark(String(text[start...]))
        return output
    }
    /// Repair a single, clearly interrogative EN/NL sentence. Ambiguous fragments,
    /// commands, indirect questions, code and multi-sentence passages stay untouched.
    public static func addMissingMark(_ text: String) -> String {
        let peel = TextPeel(text)
        var body = peel.body
        guard body.count <= 400, !body.contains(where: \.isNewline),
              !ProtectedTokens.extract(body).contains(where: { $0.kind == .code }),
              body.last != "?", body.last != "!" else { return text }
        if body.last == "." { body.removeLast() }
        guard !body.contains(where: { ".!?;:".contains($0) }),
              body.first?.isLetter == true else { return text }
        let words = body.lowercased().replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
        guard words.count >= 2 else { return text }
        let first = words[0], second = words[1]
        let enAux: Set<String> = ["am", "is", "are", "was", "were", "do", "does", "did", "can", "could", "will", "would", "should", "has", "have", "had", "may", "must", "isn't", "aren't", "wasn't", "weren't", "don't", "doesn't", "didn't", "can't", "couldn't", "won't", "wouldn't", "shouldn't", "hasn't", "haven't"]
        let nlAux: Set<String> = ["ben", "bent", "is", "zijn", "was", "waren", "heb", "heeft", "hebben", "had", "hadden", "doe", "doet", "doen", "kan", "kun", "kunt", "kunnen", "zal", "zullen", "wil", "wilt", "willen", "mag", "mogen", "moet", "moeten"]
        let enWh: Set<String> = ["what", "where", "when", "why", "who", "how", "which", "whom", "whose"]
        let nlWh: Set<String> = ["wat", "waar", "wanneer", "waarom", "wie", "hoe"]
        let enPronouns: Set<String> = ["i", "you", "we", "they", "he", "she", "it", "this", "that", "these", "those", "there"]
        let nlPronouns: Set<String> = ["ik", "je", "jij", "u", "we", "wij", "ze", "zij", "hij", "het", "dit", "dat", "deze", "die", "er"]
        let whQuestion = (enWh.contains(first) && enAux.contains(second)) || (nlWh.contains(first) && nlAux.contains(second))
        let contracted = ["what's", "where's", "when's", "why's", "who's", "how's"].contains(first)
        guard words.count >= 3 || contracted else { return text }
        let enYesNo = enAux.contains(first) && enPronouns.contains(second)
        // "Was je handen" and "Doe je werk" are Dutch commands, not questions.
        let nlYesNo = nlAux.contains(first) && nlPronouns.contains(second) && !["was", "doe", "doet", "doen"].contains(first)
        let commonDutch = first == "hoe" && second == "gaat"
        let timeQuestion = words.count >= 3 && ((first == "what" && second == "time" && enAux.contains(words[2])) || (first == "hoe" && second == "laat" && nlAux.contains(words[2])))
        let measuredQuestion = words.count >= 4 && first == "how" && ["many", "much", "long", "often", "far", "old"].contains(second)
            && words.dropFirst(2).prefix(3).contains(where: enAux.contains)
        let choiceQuestion = words.count >= 4 && ["which", "whose"].contains(first) && enAux.contains(words[2])
        // "Kom je moeder helpen", "Ga je werk doen" and "Vind je sleutels"
        // can be commands: do not infer a question from those verbs plus "je".
        let nlInverted = ["weet", "weten", "komt", "gaat"].contains(first) && nlPronouns.contains(second)
        let nlLocation = ["waar", "wanneer", "hoe"].contains(first) && ["woon", "woont", "wonen", "kom", "komt", "komen", "ga", "gaat", "gaan", "werkt", "werken"].contains(second)
        guard whQuestion || contracted || enYesNo || nlYesNo || commonDutch || timeQuestion || measuredQuestion || choiceQuestion || nlInverted || nlLocation else { return text }
        return peel.restore(body + "?")
    }
}
