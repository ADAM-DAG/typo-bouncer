import Foundation

public struct PreparedPrompt: Equatable, Sendable {
    public let instructions: String
    public let prompt: String
    public let nonce: String
}

public enum PromptBuilder {
    public static func make(text: String, command: Command) -> PreparedPrompt {
        while true {
            let nonce = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
            if let prepared = try? make(text: text, command: command, nonce: nonce) {
                return prepared
            }
        }
    }

    /// Internal deterministic entry point for tests. Never interpolates text into instructions.
    static func make(text: String, command: Command, nonce: String) throws -> PreparedPrompt {
        guard nonce.utf8.count == 8,
              nonce.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw PromptError.invalidNonce
        }
        let opening = "<text-\(nonce)>"
        let closing = "</text-\(nonce)>"
        guard !text.contains(opening), !text.contains(closing) else {
            throw PromptError.markerCollision
        }
        let action: String
        switch command {
        case .proofread: action = "Proofread"
        case .improveSentences: action = "Improve the sentence structure of"
        }
        return PreparedPrompt(
            instructions: command.instructions(language: LanguageGate.detect(text)?.code),
            prompt: "\(action) the TEXT between these markers.\n\(opening)\n\(text)\n\(closing)",
            nonce: nonce
        )
    }
}

enum PromptError: Error, Equatable {
    case invalidNonce
    case markerCollision
}
