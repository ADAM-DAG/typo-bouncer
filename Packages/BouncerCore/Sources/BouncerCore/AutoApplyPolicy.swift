import Foundation

public enum AutoApplyPolicy {
    public static func allowsPunctuation(original: String, corrected: String) -> Bool {
        let before = Passage(ProofreadingTypography.removeTrailingWhitespace(original)), after = Passage(corrected)
        guard before.words.count == after.words.count, before.gaps.first == after.gaps.first else { return false }
        for index in before.words.indices {
            guard before.words[index].lowercased() == after.words[index].lowercased(),
                  cosmetic(before.words[index], after.words[index]),
                  allowsGap(before.gaps[index + 1], after.gaps[index + 1], after: after, wordEnd: index + 1) else { return false }
        }
        return true
    }

    /// Independently check each edit. Cosmetic corrections do not consume the typo
    /// budget; inserted/deleted/reordered words and real-word substitutions fail.
    public static func allows(_ correction: ValidatedCorrection, command: Command,
                              misspelledWords: Set<String>, correctedMisspellings: Set<String>) -> Bool {
        guard command == .proofread, !correction.isUnchanged, correction.original.count <= 400,
              !ProtectedTokens.extract(correction.original).contains(where: { $0.kind == .code }) else { return false }
        let before = Passage(ProofreadingTypography.removeTrailingWhitespace(correction.original)), after = Passage(correction.corrected)
        guard before.gaps.first == after.gaps.first else { return false }
        var left = 0, right = 0, typos = 0
        while left < before.words.count && right < after.words.count {
            let old = before.words[left], new = after.words[right]
            var consumed = 1
            if cosmetic(old, new) {
                // Case and explicit contractions retain the same word.
            } else if misspelledWords.contains(old.lowercased()), old.first?.isLowercase == true,
                      right + 1 < after.words.count,
                      after.gaps[right + 1] == " ",
                      old == (new + after.words[right + 1]).lowercased(),
                      [new, after.words[right + 1]].allSatisfy({
                          $0.count >= 2 && $0.allSatisfy(\.isLetter) &&
                          !correctedMisspellings.contains($0.lowercased()) && !negations.contains(plain($0))
                      }), !negations.contains(plain(old)) {
                // A dictionary-rejected joined word may be split, never merged.
                consumed = 2
                typos += 1
            } else {
                guard !negations.contains(plain(old)), !negations.contains(plain(new)),
                      old.first?.isLowercase == true, new.first?.isLowercase == true,
                      misspelledWords.contains(old.lowercased()), !correctedMisspellings.contains(new.lowercased()),
                      old.count >= 3, new.count >= 3, editDistance(old, new) <= 2 else { return false }
                typos += 1
            }
            let end = right + consumed
            guard allowsGap(before.gaps[left + 1], after.gaps[end], after: after, wordEnd: end) else { return false }
            left += 1; right = end
        }
        return left == before.words.count && right == after.words.count && typos <= 2 &&
            Double(typos) / Double(max(before.words.count, 1)) <= 0.20
    }

    private static let negations: Set<String> = ["no", "not", "never", "cannot", "cant", "wont", "dont", "doesnt", "didnt", "isnt", "arent", "wasnt", "werent", "shouldnt", "couldnt", "wouldnt", "without", "geen", "niet", "nooit", "zonder"]
    private static func plain(_ word: String) -> String { word.lowercased().filter(\.isLetter) }
    private static func cosmetic(_ old: String, _ new: String) -> Bool {
        let old = old.replacingOccurrences(of: "’", with: "'")
        let new = new.replacingOccurrences(of: "’", with: "'")
        if old == new { return true }
        // Do not silently lowercase names/acronyms or capitalize entire words.
        if old == old.lowercased(), new == old.prefix(1).uppercased() + old.dropFirst() { return true }
        let contractions = ["im": "I'm", "ive": "I've", "dont": "don't", "doesnt": "doesn't",
                            "didnt": "didn't", "isnt": "isn't", "arent": "aren't", "wasnt": "wasn't",
                            "werent": "weren't", "couldnt": "couldn't", "wouldnt": "wouldn't",
                            "shouldnt": "shouldn't", "havent": "haven't", "hasnt": "hasn't", "hadnt": "hadn't"]
        guard let expanded = contractions[old.lowercased()], old == old.lowercased() || old == "Im" || old == "Ive" else { return false }
        return new == expanded || new == expanded.prefix(1).uppercased() + expanded.dropFirst()
    }

    private struct Passage {
        var words: [String] = []
        var gaps: [String] = [""]
        init(_ text: String) {
            for token in WordDiff.tokens(text) {
                if token.contains(where: { $0.isLetter || $0.isNumber }) {
                    words.append(token); gaps.append("")
                } else { gaps[gaps.count - 1] += token }
            }
        }
    }

    private static func allowsGap(_ old: String, _ new: String, after: Passage, wordEnd: Int) -> Bool {
        if old == new { return true }
        // Preserve existing punctuation and whitespace. Only add sentence marks
        // or a greeting comma; a period may become a verified question mark.
        let mark: Character
        if old.allSatisfy(\.isWhitespace), let first = new.first,
           String(new.dropFirst()) == old, ".?,".contains(first) { mark = first }
        else if old.first == ".", new.first == "?", old.dropFirst() == new.dropFirst() { mark = "?" }
        else { return false }
        if mark == "," { return wordEnd == 1 && ["hi", "hello", "hey", "hallo", "hoi"].contains(after.words[0].lowercased()) }
        if mark == "." { return true }
        var start = wordEnd - 1
        while start > 0 && !after.gaps[start].contains(where: { ".!?".contains($0) || $0.isNewline }) { start -= 1 }
        var sentence = ""
        for index in start..<wordEnd {
            sentence += after.words[index]
            if index + 1 < wordEnd { sentence += after.gaps[index + 1] }
        }
        return QuestionPunctuation.addMissingMark(sentence) != sentence
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let right = Array(rhs.lowercased())
        var previous = Array(0...right.count)
        for (row, letter) in lhs.lowercased().enumerated() {
            var next = [row + 1]
            for (column, other) in right.enumerated() {
                next.append(min(previous[column + 1] + 1, next[column] + 1,
                                previous[column] + (letter == other ? 0 : 1)))
            }
            previous = next
        }
        return previous.last ?? 0
    }
}
