import BouncerCore
import Foundation
import Security

enum UpdateTrust {
    private static let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)

    static func code(at url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateFailure.invalidSignature
        }
        return code
    }

    static func requirement(for installed: URL) throws -> SecRequirement {
        let code = try code(at: installed)
        // Development/ad-hoc builds never migrate to the release signing identity implicitly.
        var release: SecRequirement?
        let expression = "anchor apple generic and identifier \"com.itsadamdag.TypoBouncer\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        guard SecRequirementCreateWithString(expression as CFString, [], &release) == errSecSuccess,
              let release, SecStaticCodeCheckValidity(code, flags, release) == errSecSuccess else {
            throw UpdateFailure.unsupportedInstall
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateFailure.invalidSignature
        }
        var information: CFDictionary?
        var designated: CFString?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
              team.count == 10, team.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }),
              SecRequirementCopyString(requirement, [], &designated) == errSecSuccess, let designated else {
            throw UpdateFailure.invalidSignature
        }
        var pinned: SecRequirement?
        let pinnedExpression = "(\(designated)) and (\(expression)) and certificate leaf[subject.OU] = \"\(team)\""
        guard SecRequirementCreateWithString(pinnedExpression as CFString, [], &pinned) == errSecSuccess, let pinned else {
            throw UpdateFailure.invalidSignature
        }
        return pinned
    }

    static func validate(_ candidate: URL, installed: URL, manifest: UpdateManifest) throws {
        let requirement = try requirement(for: installed)
        guard SecStaticCodeCheckValidity(try code(at: candidate), flags, requirement) == errSecSuccess else {
            throw UpdateFailure.invalidSignature
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(try code(at: candidate), SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let signature = information as? [String: Any],
              let codeFlags = signature[kSecCodeInfoFlags as String] as? UInt32,
              codeFlags & SecCodeSignatureFlags.runtime.rawValue != 0 else { throw UpdateFailure.invalidSignature }
        let entitlements = signature[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        guard entitlements["com.apple.security.get-task-allow"] as? Bool != true,
              entitlements["com.apple.security.app-sandbox"] as? Bool != true else { throw UpdateFailure.invalidSignature }
        let executable = try FileHandle(forReadingFrom: candidate.appending(path: "Contents/MacOS/TypoBouncer"))
        defer { try? executable.close() }
        guard let header = try executable.read(upToCount: 16), UpdateBinaryPolicy.isARM64ExecutableHeader(header) else {
            throw UpdateFailure.invalidRelease
        }
        // Read sealed metadata only after verifying the signature.
        let data = try Data(contentsOf: candidate.appending(path: "Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "com.itsadamdag.TypoBouncer",
              info["CFBundleExecutable"] as? String == "TypoBouncer",
              info["CFBundleVersion"] as? String == String(manifest.build),
              info["CFBundleShortVersionString"] as? String == manifest.version,
              info["LSMinimumSystemVersion"] as? String == manifest.minimumSystemVersion,
              let current = try PropertyListSerialization.propertyList(
                from: Data(contentsOf: installed.appending(path: "Contents/Info.plist")), format: nil) as? [String: Any],
              let currentBuild = Int(current["CFBundleVersion"] as? String ?? ""),
              try manifest.isNewer(thanBuild: currentBuild, version: current["CFBundleShortVersionString"] as? String ?? "",
                                   systemVersion: systemVersion) else { throw UpdateFailure.invalidRelease }
    }

    static var systemVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    static func installationIsWritable(_ target: URL) -> Bool {
        // App Translocation, disk images, network volumes and read-only installs are ineligible.
        let manager = FileManager.default
        let parent = target.deletingLastPathComponent()
        let applications = [URL(filePath: "/Applications"), manager.homeDirectoryForCurrentUser.appending(path: "Applications")]
        guard applications.contains(parent), target.lastPathComponent == "TypoBouncer.app",
              target.resolvingSymlinksInPath().path == target.path,
              let values = try? parent.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsReadOnlyKey]),
              values.volumeIsLocal == true, values.volumeIsReadOnly == false,
              manager.isWritableFile(atPath: parent.path), manager.isWritableFile(atPath: target.path) else { return false }
        return true
    }
}
