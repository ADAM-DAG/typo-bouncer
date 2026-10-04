import Foundation

public struct TextPeel: Sendable {
    public let leading: String
    public let body: String
    public let trailing: String
    private let separators: [String]

    public init(_ text: String) {
        let characters = Array(text)
        let first = characters.firstIndex(where: { !$0.isWhitespace }) ?? characters.count
        let last = characters.lastIndex(where: { !$0.isWhitespace }).map { $0 + 1 } ?? first
        leading = String(characters[..<first])
        body = String(characters[first..<last])
        trailing = String(characters[last...])
        separators = body.filter(\.isNewline).map(String.init)
    }

    public var normalizedBody: String {
        body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    public func restore(_ correction: String) -> String {
        let clean = correction.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = clean.components(separatedBy: "\n")
        guard lines.count == separators.count + 1 else { return leading + clean + trailing }
        var result = lines[0]
        for index in separators.indices { result += separators[index] + lines[index + 1] }
        return leading + result + trailing
    }
}
