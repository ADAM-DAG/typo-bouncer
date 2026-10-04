import Foundation

/// Deliberately bounded: no ambiguous single-letter substitutions or invented meaning.
public enum ChatShorthand {
    private static let expansions = [
        "idk": "I don't know", "tbh": "to be honest", "btw": "by the way",
        "imo": "in my opinion", "imho": "in my humble opinion",
        "brb": "be right back", "omw": "on my way", "rn": "right now",
        "lmk": "let me know", "nvm": "never mind"
    ]

    private static func matches(_ text: String) -> [NSTextCheckingResult] {
        // Do not touch identifiers, file names, possessives, handles or protected content.
        let pattern = #"(?i)(?<![\p{L}\p{N}_/@#.'’\-])(?:idk|tbh|btw|imo|imho|brb|omw|rn|lmk|nvm)(?![\p{L}\p{N}_/@#'’\-]|\.[\p{L}\p{N}])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let protected = ProtectedTokens.ranges(in: text)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).filter { match in
            !protected.contains { NSIntersectionRange($0, match.range).length > 0 }
        }
    }

    public static func expand(_ text: String) -> String {
        var result = text
        for match in matches(text).reversed() {
            guard let range = Range(match.range, in: text), let replacement = expansions[String(text[range]).lowercased()],
                  let outputRange = Range(match.range, in: result) else { continue }
            result.replaceSubrange(outputRange, with: replacement)
        }
        return result
    }

    /// Restore an unwanted expansion only inside its corresponding word edit.
    /// Unchanged neighboring words anchor it so a separate, original phrase is untouched.
    public static func restoringExpansions(original: String, corrected: String) -> String {
        guard !preserved(original: original, corrected: corrected),
              let regex = try? NSRegularExpression(pattern: #"[\p{L}\p{N}_]+(?:['’][\p{L}\p{N}_]+)*"#) else { return corrected }
        func wordRanges(_ text: String) -> [NSRange] {
            regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
        }
        func value(_ text: String, _ range: NSRange) -> String {
            (text as NSString).substring(with: range).lowercased().replacingOccurrences(of: "’", with: "'")
        }
        let oldRanges = wordRanges(original), newRanges = wordRanges(corrected)
        let oldWords = oldRanges.map { value(original, $0) }, newWords = newRanges.map { value(corrected, $0) }
        let diff = newWords.difference(from: oldWords)
        var removed: Set<Int> = [], inserted: Set<Int> = []
        for change in diff {
            switch change {
            case .remove(let index, _, _): removed.insert(index)
            case .insert(let index, _, _): inserted.insert(index)
            }
        }
        let anchors = Array(zip(oldWords.indices.filter { !removed.contains($0) },
                                newWords.indices.filter { !inserted.contains($0) }))
        let protected = ProtectedTokens.ranges(in: corrected)
        var repairs: [(NSRange, String)] = []
        for match in matches(original) {
            guard let oldIndex = oldRanges.firstIndex(of: match.range), removed.contains(oldIndex),
                  let expansion = expansions[oldWords[oldIndex]] else { continue }
            let lower = anchors.last { $0.0 < oldIndex }.map { $0.1 + 1 } ?? 0
            let upper = anchors.first { $0.0 > oldIndex }.map { $0.1 } ?? newWords.count
            let variants = expansion == "I don't know" ? [expansion, "I do not know"] : [expansion]
            var found = false
            for variant in variants where !found {
                let expected = wordRanges(variant).map { value(variant, $0) }
                guard upper - lower >= expected.count else { continue }
                for start in lower...(upper - expected.count) {
                    let indices = start..<(start + expected.count)
                    guard indices.allSatisfy({ inserted.contains($0) }), Array(newWords[indices]) == expected else { continue }
                    let range = NSUnionRange(newRanges[start], newRanges[start + expected.count - 1])
                    guard !protected.contains(where: { NSIntersectionRange($0, range).length > 0 }),
                          !repairs.contains(where: { NSIntersectionRange($0.0, range).length > 0 }) else { continue }
                    // Avoid eating punctuation or a line break between model-added words.
                    let phrase = (corrected as NSString).substring(with: range)
                    guard !phrase.contains(where: { $0.isNewline || (!($0.isLetter || $0.isWhitespace) && $0 != "'" && $0 != "’") }) else { continue }
                    repairs.append((range, (original as NSString).substring(with: match.range)))
                    found = true
                    break
                }
            }
        }
        let result = NSMutableString(string: corrected)
        for (range, word) in repairs.sorted(by: { $0.0.location > $1.0.location }) {
            result.replaceCharacters(in: range, with: word)
        }
        return result as String
    }

    /// With the preference off, generation cannot silently expand or drop shorthand.
    public static func preserved(original: String, corrected: String) -> Bool {
        func words(_ text: String) -> [String] {
            matches(text).compactMap { Range($0.range, in: text).map { String(text[$0]).lowercased() } }
        }
        return words(original) == words(corrected)
    }
}
