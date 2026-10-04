import Foundation

public struct ProtectedToken: Equatable, Sendable {
    public enum Kind: CaseIterable, Sendable { case code, url, email, tag, number, emoji }
    public let kind: Kind
    public let value: String

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.value.utf8.elementsEqual(rhs.value.utf8)
    }
}

public enum ProtectedTokens {
    public static func extract(_ text: String) -> [ProtectedToken] {
        matches(text).map(\.token)
    }

    public static func ranges(in text: String, kinds: [ProtectedToken.Kind] = ProtectedToken.Kind.allCases) -> [NSRange] {
        matches(text).filter { kinds.contains($0.token.kind) }.map(\.range)
    }

    private static func matches(_ text: String) -> [(range: NSRange, token: ProtectedToken)] {
        var occupied: [NSRange] = []
        var found: [(range: NSRange, token: ProtectedToken)] = []
        let patterns: [(ProtectedToken.Kind, String)] = [
            (.code, #"(?s)```.*?```|~~~.*?~~~|`[^`\r\n]+`|```.*\z|~~~.*\z"#),
            (.url, #"(?i)\b(?:https?://|www\.)[^\s<>]+"#),
            (.email, #"[\p{L}\p{N}._%+\-]+@[\p{L}\p{N}.\-]+\.[\p{L}]{2,}"#),
            (.tag, #"(?<![\p{L}\p{N}_])[@#][\p{L}\p{N}_]+"#),
            (.number, #"(?:[€$£¥]\s*)?[+\-]?\p{N}+(?:[.,:/\-]\p{N}+)*(?:\s?(?:%|€|USD|EUR|GBP))?"#)
        ]
        func add(_ kind: ProtectedToken.Kind, _ range: NSRange) {
            guard range.length > 0, !occupied.contains(where: { NSIntersectionRange($0, range).length > 0 }),
                  let swiftRange = Range(range, in: text) else { return }
            occupied.append(range)
            found.append((range, ProtectedToken(kind: kind, value: String(text[swiftRange]))))
        }
        for (kind, pattern) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                var range = match.range
                if kind == .url, let swiftRange = Range(range, in: text) {
                    var value = String(text[swiftRange])
                    while let last = value.last, ".,!?;:)]}\"’”".contains(last) {
                        if last == ")" && value.filter({ $0 == "(" }).count >= value.filter({ $0 == ")" }).count { break }
                        value.removeLast()
                    }
                    range.length = value.utf16.count
                }
                add(kind, range)
            }
        }
        var offset = 0
        for character in text {
            let length = String(character).utf16.count
            if character.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 127) }) {
                add(.emoji, NSRange(location: offset, length: length))
            }
            offset += length
        }
        return found.sorted { $0.range.location < $1.range.location }
    }

    public static func preserved(original: String, corrected: String) -> Bool {
        let before = extract(original)
        let after = extract(corrected)
        return ProtectedToken.Kind.allCases.allSatisfy { kind in
            before.filter { $0.kind == kind } == after.filter { $0.kind == kind }
        }
    }
}
