import Foundation

public enum PlainWritingStyle {
    public static let instructions = """
    Keep the writer's everyday voice and existing layout. Use plain, natural sentences.
    Do not introduce em dashes, en dashes, double-hyphen asides, semicolons, Markdown,
    headings, bullets, bold, italics or a polished assistant-like introduction or conclusion.
    Prefer periods and ordinary commas. Preserve formatting and dashes already present.
    Keep chat shorthand such as idk, tbh and btw; do not expand abbreviations yourself.
    """

    public static func preservesStyle(original: String, corrected: String) -> Bool {
        func visible(_ text: String) -> String {
            let result = NSMutableString(string: text)
            for range in ProtectedTokens.ranges(in: text, kinds: [.code, .url, .email, .emoji]).reversed() {
                result.replaceCharacters(in: range, with: String(repeating: " ", count: range.length))
            }
            return result as String
        }
        let before = visible(original), after = visible(corrected)
        for symbol in ["—", "–", " -- ", ";"] {
            if after.components(separatedBy: symbol).count > before.components(separatedBy: symbol).count { return false }
        }
        let patterns = [
            #"(?m)^[ \t]{0,3}#{1,6}[ \t]+"#,
            #"(?m)^[ \t]*(?:[-+*•]|[0-9]+[.)])[ \t]+"#,
            #"(?m)^[ \t]*>[ \t]*"#,
            #"\*\*(?=\S).+?(?<=\S)\*\*|__(?=\S).+?(?<=\S)__"#,
            #"(?<!\*)\*(?![\s*]).+?(?<=\S)\*(?!\*)|(?<![\p{L}\p{N}_])_(?![\s_]).+?(?<=\S)_(?![\p{L}\p{N}_])"#,
            #"~~(?=\S).+?(?<=\S)~~"#,
            #"\[[^\]\r\n]+\]\("#,
            #"(?m)^[ \t]*(?:---+|___+|\*\*\*+)[ \t]*$"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            func count(_ text: String) -> Int { regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) }
            if count(after) > count(before) { return false }
        }
        return true
    }
}
