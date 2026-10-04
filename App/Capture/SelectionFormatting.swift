import AppKit
import BouncerCore

// Immutable attributed snapshots stay in memory with the captured selection.
// AX attributed strings use accessibility keys, not AppKit's RTF style keys.
enum SelectionFormatting: @unchecked Sendable {
    case plain
    case uniform(NSAttributedString)
    case rich(Data)
    case unknown

    var supportsAuto: Bool {
        if case .unknown = self { return false }
        return true
    }
    var usesRichText: Bool {
        if case .rich = self { return true }
        return false
    }
    func matches(_ other: SelectionFormatting) -> Bool {
        switch (self, other) {
        case (.plain, .plain), (.unknown, .unknown): return true
        case (.uniform(let first), .uniform(let second)): return first.isEqual(to: second)
        case (.rich(let first), .rich(let second)):
            guard let a = Self.decode(first), let b = Self.decode(second) else { return false }
            return a.isEqual(to: b)
        default: return false
        }
    }

    static func richText(_ data: Data, matching text: String) -> SelectionFormatting? {
        guard let attributed = decode(data), attributed.string.utf8.elementsEqual(text.utf8),
              !containsAttachments(attributed) else { return nil }
        return .rich(data)
    }

    static func uniformText(_ attributed: NSAttributedString) -> SelectionFormatting? {
        guard attributed.length > 0 else { return nil }
        let snapshot = NSMutableAttributedString(attributedString: attributed)
        // These flags describe spelling/language, not formatting. They commonly
        // split otherwise plain browser and Electron text into several AX runs.
        for key in [NSAttributedString.Key.accessibilityMisspelled, NSAttributedString.Key.accessibilityMarkedMisspelled,
                    NSAttributedString.Key.accessibilityAutocorrected, NSAttributedString.Key.accessibilityLanguage] {
            snapshot.removeAttribute(key, range: NSRange(location: 0, length: snapshot.length))
        }
        let allowed: Set<NSAttributedString.Key> = [NSAttributedString.Key.accessibilityFont,
            NSAttributedString.Key.accessibilityForegroundColor, NSAttributedString.Key.accessibilityBackgroundColor,
            NSAttributedString.Key.accessibilityAlignment, NSAttributedString.Key.accessibilityFontBoldAttribute, NSAttributedString.Key.accessibilityFontItalicAttribute,
            .font, .foregroundColor, .backgroundColor]
        var uniform = true
        let baseline = snapshot.attributes(at: 0, effectiveRange: nil) as NSDictionary
        snapshot.enumerateAttributes(in: NSRange(location: 0, length: snapshot.length)) { attributes, _, stop in
            guard Set(attributes.keys).isSubset(of: allowed), baseline.isEqual(to: attributes),
                  attributes[NSAttributedString.Key.accessibilityFontBoldAttribute] as? Bool != true,
                  attributes[NSAttributedString.Key.accessibilityFontItalicAttribute] as? Bool != true else { uniform = false; stop.pointee = true; return }
            if let font = attributes[.font] as? NSFont,
               font.fontDescriptor.symbolicTraits.intersection([.bold, .italic]).isEmpty == false {
                uniform = false; stop.pointee = true
            }
            if let font = attributes[NSAttributedString.Key.accessibilityFont] as? [String: Any],
               let name = font[NSAccessibility.FontAttributeKey.fontName.rawValue] as? String,
               ["bold", "italic", "oblique"].contains(where: { name.lowercased().contains($0) }) {
                uniform = false; stop.pointee = true
            }
        }
        return uniform ? .uniform(NSAttributedString(attributedString: snapshot)) : nil
    }

    func replacementRTF(original: String, corrected: String) throws -> Data? {
        guard case .rich(let data) = self else { return nil }
        guard let source = Self.decode(data), source.string.utf8.elementsEqual(original.utf8),
              !Self.containsAttachments(source) else { throw AppFailure.formattingChanged }
        let output = NSMutableAttributedString(string: "")
        var offset = 0
        var removedAttributes: [NSAttributedString.Key: Any]?
        for segment in WordDiff.segments(original: original, corrected: corrected) {
            let length = segment.text.utf16.count
            switch segment.kind {
            case .unchanged:
                output.append(source.attributedSubstring(from: NSRange(location: offset, length: length)))
                offset += length; removedAttributes = nil
            case .removed:
                let range = NSRange(location: offset, length: length)
                let attributes = source.attributes(at: offset, effectiveRange: nil)
                var uniform = true
                source.enumerateAttributes(in: range) { run, _, stop in
                    if !(attributes as NSDictionary).isEqual(to: run) { uniform = false; stop.pointee = true }
                }
                // Never choose an arbitrary style for a rewritten mixed-style word.
                guard uniform else { throw AppFailure.formattingChanged }
                removedAttributes = attributes; offset += length
            case .inserted:
                let nearby = min(max(offset - 1, 0), source.length - 1)
                let attributes = removedAttributes ?? (source.length > 0 ? source.attributes(at: nearby, effectiveRange: nil) : [:])
                output.append(NSAttributedString(string: segment.text, attributes: attributes))
                removedAttributes = nil
            }
        }
        guard offset == source.length, output.string.utf8.elementsEqual(corrected.utf8),
              let result = output.rtf(from: NSRange(location: 0, length: output.length), documentAttributes: [:]),
              result.count <= 1_048_576 else { throw AppFailure.formattingChanged }
        return result
    }

    private static func decode(_ data: Data) -> NSAttributedString? {
        guard data.count <= 1_048_576 else { return nil }
        return try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
    }
    private static func containsAttachments(_ attributed: NSAttributedString) -> Bool {
        var found = false
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }
}
