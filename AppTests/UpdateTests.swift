import BouncerCore
import Foundation
import XCTest
@testable import TypoBouncer

final class UpdateTests: XCTestCase {
    func testNetworkScopeRejectsOtherRepositoriesCredentialsPortsAndRedirectHosts() {
        XCTAssertTrue(UpdateTransport.isAllowed(UpdateTransport.latest))
        for name in ["TypoBouncer-update.json", "TypoBouncer-update.dmg"] {
            XCTAssertTrue(UpdateTransport.isAllowed(URL(string: "https://github.com/ADAM-DAG/typo-bouncer/releases/download/v0.1.0/\(name)")!))
        }
        XCTAssertTrue(UpdateTransport.isAllowed(URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/123?signature=example")!))
        for address in [
            "http://api.github.com/repos/ADAM-DAG/typo-bouncer/releases/latest",
            "https://api.github.com/repos/other/app/releases/latest",
            "https://github.com/other/app/releases/download/v1/TypoBouncer-update.dmg",
            "https://github.com/ADAM-DAG/typo-bouncer/releases/download/v1/other.dmg",
            "https://github.com/ADAM-DAG/typo-bouncer/releases/download/v1/TypoBouncer-update.dmg?override=true",
            "https://user:password@release-assets.githubusercontent.com/a",
            "https://release-assets.githubusercontent.com:444/a",
            "https://release-assets.githubusercontent.com.attacker.example/a",
            "https://raw.githubusercontent.com/a", "file:///tmp/update.dmg"
        ] { XCTAssertFalse(UpdateTransport.isAllowed(URL(string: address)!), address) }
    }

    func testDraftPrereleaseDuplicateMissingOversizeAndExternalAssetsAreRejected() throws {
        func release(draft: Bool = false, prerelease: Bool = false, count: Int = 1, size: Int = 20,
                     url: String = "https://github.com/ADAM-DAG/typo-bouncer/releases/download/v1/TypoBouncer-update.json") throws -> GitHubRelease {
            let data = try JSONSerialization.data(withJSONObject: ["draft": draft, "prerelease": prerelease,
                "assets": Array(repeating: ["name": "TypoBouncer-update.json", "size": size, "browser_download_url": url], count: count)])
            return try JSONDecoder().decode(GitHubRelease.self, from: data)
        }
        XCTAssertEqual(try release().asset(named: "TypoBouncer-update.json", maximumSize: 100).size, 20)
        for value in try [release(draft: true), release(prerelease: true), release(count: 0), release(count: 2),
                          release(size: 0), release(size: 101), release(url: "https://attacker.example/update.json")] {
            XCTAssertThrowsError(try value.asset(named: "TypoBouncer-update.json", maximumSize: 100))
        }
    }

    func testAtomicExchangeAndRollbackPreserveBothBundlesAndFailedSwapPreservesOriginal() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let installed = directory.appending(path: "installed")
        let candidate = directory.appending(path: "candidate")
        try Data("old".utf8).write(to: installed)
        try Data("new".utf8).write(to: candidate)
        try UpdateInstaller.swap(installed, candidate)
        XCTAssertEqual(try Data(contentsOf: installed), Data("new".utf8))
        XCTAssertEqual(try Data(contentsOf: candidate), Data("old".utf8))
        try UpdateInstaller.swap(installed, candidate)
        XCTAssertEqual(try Data(contentsOf: installed), Data("old".utf8))
        XCTAssertThrowsError(try UpdateInstaller.swap(installed, directory.appending(path: "missing")))
        XCTAssertEqual(try Data(contentsOf: installed), Data("old".utf8))
    }

    func testAppDirectoryURLsAcceptDirectoryHintsAndRejectSymbolicLinks() throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appending(path: "Example.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        try Data("fixture".utf8).write(to: app.appending(path: "file"))
        XCTAssertNoThrow(try UpdateInstaller.rejectSymlinks(in: app))
        XCTAssertNoThrow(try UpdateInstaller.rejectSymlinks(in: URL(filePath: app.path, directoryHint: .isDirectory)))
        let alias = directory.appending(path: "Alias.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: app)
        XCTAssertThrowsError(try UpdateInstaller.rejectSymlinks(in: alias))
        let linkedFile = app.appending(path: "linked-file")
        try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: app.appending(path: "file"))
        XCTAssertThrowsError(try UpdateInstaller.rejectSymlinks(in: app))
    }

    func testChecksumAndUntrustedSigningAndInstallLocations() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try UpdateInstaller.sha256(file), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertThrowsError(try UpdateTrust.requirement(for: file))
        XCTAssertFalse(UpdateTrust.installationIsWritable(URL(filePath: "/Volumes/Update/TypoBouncer.app")))
        XCTAssertFalse(UpdateTrust.installationIsWritable(URL(filePath: "/private/tmp/TypoBouncer.app")))
        XCTAssertThrowsError(try UpdateInstaller.makeStage(for: URL(filePath: "/Volumes/Update/TypoBouncer.app")))
        // The ad-hoc XCTest app must never accept or migrate release signing implicitly.
        XCTAssertThrowsError(try UpdateTrust.requirement(for: Bundle.main.bundleURL))
    }

    @MainActor func testUpdaterPreferencesPersistWithoutStartingNetworking() {
        let name = "TypoBouncerUpdateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let updater = AppUpdater(defaults: defaults)
        XCTAssertTrue(updater.automaticChecks)
        XCTAssertFalse(updater.isReleaseInstall)
        updater.automaticChecks = false
        updater.check()
        XCTAssertFalse(updater.busy)
        XCTAssertFalse(AppUpdater(defaults: defaults).automaticChecks)
        defaults.set(true, forKey: UpdateInstaller.failurePreference)
        XCTAssertNotNil(AppUpdater(defaults: defaults).message)
        XCTAssertFalse(defaults.bool(forKey: UpdateInstaller.failurePreference))
    }

    func testDeveloperIDContinuityAndSealedMetadataWithLocalFixtures() throws {
        // Optional local fixtures use an existing key; CI never creates signing credentials.
        let fixtures = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "build/UpdateFixtures")
        let installed = fixtures.appending(path: "current.app")
        guard FileManager.default.fileExists(atPath: installed.path) else {
            throw XCTSkip("Developer ID fixtures were not prepared on this runner")
        }
        let candidate = fixtures.appending(path: "newer.app")
        let info = try XCTUnwrap(Bundle(url: candidate)?.infoDictionary)
        let data = try JSONSerialization.data(withJSONObject: ["schema": 1,
            "version": try XCTUnwrap(info["CFBundleShortVersionString"] as? String),
            "build": Int(try XCTUnwrap(info["CFBundleVersion"] as? String))!,
            "minimumSystemVersion": try XCTUnwrap(info["LSMinimumSystemVersion"] as? String),
            "architecture": "arm64", "sha256": String(repeating: "a", count: 64)])
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
        XCTAssertNoThrow(try UpdateTrust.requirement(for: installed))
        XCTAssertNoThrow(try UpdateTrust.validate(candidate, installed: installed, manifest: manifest))
        for name in ["current.app", "tampered.app", "adhoc.app", "debug-entitlement.app"] {
            XCTAssertThrowsError(try UpdateTrust.validate(fixtures.appending(path: name), installed: installed, manifest: manifest), name)
        }
        XCTAssertThrowsError(try UpdateTrust.validate(candidate, installed: fixtures.appending(path: "adhoc.app"), manifest: manifest))
    }
}
