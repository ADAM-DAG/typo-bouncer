import Foundation

/// Release metadata is untrusted. The installed bundle's signature is the authority.
public struct UpdateManifest: Codable, Equatable, Sendable {
    public let schema: Int
    public let version: String
    public let build: Int
    public let minimumSystemVersion: String
    public let architecture: String
    public let sha256: String

    public enum ValidationError: Error { case invalid, unsupportedSystem }

    public func isNewer(thanBuild currentBuild: Int, version currentVersion: String,
                        systemVersion: String) throws -> Bool {
        guard schema == 1, build > 0, architecture == "arm64",
              let release = Self.components(version), release.count == 3,
              let current = Self.components(currentVersion),
              let minimum = Self.components(minimumSystemVersion),
              let system = Self.components(systemVersion),
              sha256.count == 64, sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw ValidationError.invalid }
        guard Self.compare(system, minimum) >= 0 else { throw ValidationError.unsupportedSystem }
        // Builds increase across all releases. Refuse both build and marketing-version downgrades.
        return build > currentBuild && Self.compare(release, current) >= 0
    }

    public static func components(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        var result: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 8, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = Int(part) else { return nil }
            result.append(number)
        }
        return result
    }

    private static func compare(_ left: [Int], _ right: [Int]) -> Int {
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? -1 : 1 }
        }
        return 0
    }
}

public enum UpdateBinaryPolicy {
    /// Release builds are thin arm64 Mach-O executables. Reading their header needs no developer tools.
    public static func isARM64ExecutableHeader(_ data: Data) -> Bool {
        guard data.count >= 16 else { return false }
        let bytes = Array(data.prefix(16))
        // Little-endian MH_MAGIC_64, CPU_TYPE_ARM64, and MH_EXECUTE.
        return Array(bytes[0..<8]) == [0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01]
            && Array(bytes[12..<16]) == [0x02, 0x00, 0x00, 0x00]
    }
}
