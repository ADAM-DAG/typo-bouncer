import Foundation

public struct DiffSegment: Equatable, Sendable {
    public enum Kind: Sendable { case unchanged, removed, inserted }
    public let kind: Kind
    public let text: String
}

public enum WordDiff {
    public static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        var pending = ""
        var previousKind: Int?
        for character in text {
            let kind = character.isWhitespace ? 0 : (character.isLetter || character.isNumber || character == "'" || character == "’" ? 1 : 2)
            if kind != previousKind || kind == 2 {
                if !pending.isEmpty { result.append(pending) }
                pending = ""
            }
            pending.append(character)
            previousKind = kind
        }
        if !pending.isEmpty { result.append(pending) }
        return result
    }

    public static func segments(original: String, corrected: String) -> [DiffSegment] {
        let old = tokens(original)
        let new = tokens(corrected)
        let difference = new.map { Data($0.utf8) }.difference(from: old.map { Data($0.utf8) })
        var removals: Set<Int> = []
        var insertions: Set<Int> = []
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removals.insert(offset)
            case .insert(let offset, _, _): insertions.insert(offset)
            }
        }
        var result: [DiffSegment] = []
        var left = 0
        var right = 0
        func append(_ kind: DiffSegment.Kind, _ text: String) {
            if let last = result.last, last.kind == kind {
                result[result.count - 1] = DiffSegment(kind: kind, text: last.text + text)
            } else { result.append(DiffSegment(kind: kind, text: text)) }
        }
        while left < old.count || right < new.count {
            if left < old.count && removals.contains(left) {
                append(.removed, old[left]); left += 1
            } else if right < new.count && insertions.contains(right) {
                append(.inserted, new[right]); right += 1
            } else if left < old.count && right < new.count {
                append(.unchanged, new[right]); left += 1; right += 1
            } else if left < old.count {
                append(.removed, old[left]); left += 1
            } else {
                append(.inserted, new[right]); right += 1
            }
        }
        return result
    }

    public static func wordEditRatio(original: String, corrected: String) -> Double {
        func words(_ text: String) -> [String] { tokens(text).filter { $0.contains(where: \.isLetter) } }
        let old = words(original)
        let new = words(corrected)
        let changed = new.difference(from: old).count
        return Double(changed) / Double(max(old.count + new.count, 1))
    }

    public static func changedPossibleName(original: String, corrected: String) -> Bool {
        let removed = Set(tokens(corrected).difference(from: tokens(original)).compactMap { change -> Int? in
            if case .remove(let offset, _, _) = change { return offset }
            return nil
        })
        var sentenceStart = true
        for (index, token) in tokens(original).enumerated() {
            if token.contains(where: \.isLetter) {
                if !sentenceStart && token.first?.isUppercase == true && removed.contains(index) { return true }
                sentenceStart = false
            } else if token.contains(where: { $0.isNewline || ".!?".contains($0) }) {
                sentenceStart = true
            }
        }
        return false
    }
}
