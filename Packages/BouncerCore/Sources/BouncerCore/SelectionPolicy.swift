import Foundation

public struct SelectionPolicy: Equatable, Sendable {
    public static let defaultLimit = 1_500
    public static let allowedLimits = 250...5_000

    public let maximumCharacters: Int

    public init(maximumCharacters: Int = Self.defaultLimit) {
        self.maximumCharacters = Self.clamp(maximumCharacters)
    }

    public static func clamp(_ limit: Int) -> Int {
        min(max(limit, allowedLimits.lowerBound), allowedLimits.upperBound)
    }

    /// Counts user-perceived characters, keeping emoji and combining marks together.
    /// A later model gate must also enforce the token/context budget.
    public func validate(_ text: String) throws {
        guard text.utf8.count <= 65_536 else { throw SelectionError.tooManyBytes }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SelectionError.empty
        }
        let count = text.count
        guard count <= maximumCharacters else {
            throw SelectionError.tooLong(count: count, limit: maximumCharacters)
        }
    }
}

public enum SelectionError: Error, Equatable, Sendable {
    case tooManyBytes
    case empty
    case tooLong(count: Int, limit: Int)
}
