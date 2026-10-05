import AppKit
import BouncerCore
import CryptoKit
import Darwin
import Foundation

enum UpdateInstaller {
    static let argument = "--install-verified-update"
    static let failurePreference = "updateInstallFailed"

    /// Runs only fixed Apple utilities, with arguments passed directly (never through a shell).
    static func runTool(_ path: String, _ arguments: [String]) throws -> Data {
        guard ["/usr/bin/hdiutil", "/usr/bin/ditto", "/usr/sbin/spctl"].contains(path) else {
            throw UpdateFailure.installFailed
        }
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        try process.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timeout)
        defer { timeout.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateFailure.installFailed }
        return data
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func makeStage(for installed: URL) throws -> URL {
        guard UpdateTrust.installationIsWritable(installed) else { throw UpdateFailure.unsupportedInstall }
        let stage = installed.deletingLastPathComponent().appending(path: ".TypoBouncer-update.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        return stage
    }

    static func prepare(image: URL, stage: URL, installed: URL, manifest: UpdateManifest) throws {
        guard try sha256(image) == manifest.sha256 else { throw UpdateFailure.invalidDownload }
        let mount = stage.appending(path: "mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
        _ = try runTool("/usr/bin/hdiutil", ["verify", image.path])
        _ = try runTool("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, image.path])
        var mounted = true
        defer { if mounted { _ = try? runTool("/usr/bin/hdiutil", ["detach", mount.path]) } }
        let app = mount.appending(path: "TypoBouncer.app")
        try rejectSymlinks(in: app)
        try UpdateTrust.validate(app, installed: installed, manifest: manifest)
        _ = try runTool("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
        let candidate = stage.appending(path: "TypoBouncer.app")
        _ = try runTool("/usr/bin/ditto", ["--rsrc", "--extattr", app.path, candidate.path])
        try UpdateTrust.validate(candidate, installed: installed, manifest: manifest)
        _ = try runTool("/usr/bin/hdiutil", ["detach", mount.path])
        mounted = false
        try FileManager.default.removeItem(at: mount)
        try JSONEncoder().encode(manifest).write(to: stage.appending(path: "update.json"), options: .atomic)
    }

    static func rejectSymlinks(in app: URL) throws {
        guard app.resolvingSymlinksInPath().path == app.path,
              let iterator = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey],
                                                           errorHandler: { _, _ in false }) else {
            throw UpdateFailure.invalidSignature
        }
        // This app ships no embedded frameworks or intentional symlinks.
        for case let file as URL in iterator {
            guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw UpdateFailure.invalidSignature
            }
        }
    }

    static func launchHelper(stage: URL) async throws {
        guard let executable = Bundle.main.executableURL else { throw UpdateFailure.installFailed }
        let process = Process()
        process.executableURL = executable
        process.arguments = [argument, stage.path, String(ProcessInfo.processInfo.processIdentifier)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: stage.appending(path: "ready").path) {
            guard process.isRunning, Date() < deadline else {
                if process.isRunning { process.terminate() }
                throw UpdateFailure.installFailed
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    static func swap(_ left: URL, _ right: URL) throws {
        // Both bundles are on the same local volume. There is never a gap at the installed path.
        guard renameatx_np(AT_FDCWD, left.path, AT_FDCWD, right.path, UInt32(RENAME_SWAP)) == 0 else {
            throw UpdateFailure.installFailed
        }
    }

    @MainActor static func runHelper(arguments: [String]) async -> Int32 {
        let installed = Bundle.main.bundleURL.standardizedFileURL
        guard arguments.count == 4, arguments[1] == argument,
              let parent = Int32(arguments[3]), parent > 1, parent == getppid(),
              NSRunningApplication(processIdentifier: parent)?.bundleURL?.standardizedFileURL == installed,
              UpdateTrust.installationIsWritable(installed) else { return 1 }
        let stage = URL(filePath: arguments[2]).standardizedFileURL
        let prefix = ".TypoBouncer-update."
        guard stage.deletingLastPathComponent() == installed.deletingLastPathComponent(),
              stage.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(stage.lastPathComponent.dropFirst(prefix.count))) != nil,
              stage.resolvingSymlinksInPath().path == stage.path,
              let attrs = try? FileManager.default.attributesOfItem(atPath: stage.path),
              attrs[.ownerAccountID] as? UInt32 == getuid(),
              (attrs[.posixPermissions] as? Int).map({ $0 & 0o777 == 0o700 }) == true else { return 1 }
        let candidate = stage.appending(path: "TypoBouncer.app")
        var cleanupStage = true
        defer { if cleanupStage { try? FileManager.default.removeItem(at: stage) } }
        var swapped = false
        do {
            let manifest = try JSONDecoder().decode(UpdateManifest.self, from: Data(contentsOf: stage.appending(path: "update.json")))
            try rejectSymlinks(in: candidate)
            try UpdateTrust.validate(candidate, installed: installed, manifest: manifest)
            try Data().write(to: stage.appending(path: "ready"), options: .atomic)
            // No permission/model/shortcut code is initialized in this process.
            let ready = await Task.detached {
                let deadline = Date().addingTimeInterval(30)
                while kill(parent, 0) == 0 {
                    guard Date() < deadline else { return false }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                return errno == ESRCH
            }.value
            guard ready else { throw UpdateFailure.busy }
            try rejectSymlinks(in: candidate)
            try UpdateTrust.validate(candidate, installed: installed, manifest: manifest)
            _ = try runTool("/usr/sbin/spctl", ["--assess", "--type", "execute", candidate.path])
            try swap(installed, candidate)
            swapped = true
            // The old, trusted bundle now occupies candidate's path.
            try UpdateTrust.validate(installed, installed: candidate, manifest: manifest)
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            _ = try await NSWorkspace.shared.openApplication(at: installed, configuration: config)
            return 0
        } catch {
            if swapped {
                do { try swap(installed, candidate) }
                catch {
                    // Keep the previous app available for recovery if the rollback itself fails.
                    // Rename out of the cleanup directory rather than deleting the backup.
                    cleanupStage = false
                    let backup = installed.deletingLastPathComponent().appending(path: "TypoBouncer-recovery-\(UUID().uuidString).app")
                    try? FileManager.default.moveItem(at: candidate, to: backup)
                    return 1
                }
            }
            UserDefaults.standard.set(true, forKey: failurePreference)
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            _ = try? await NSWorkspace.shared.openApplication(at: installed, configuration: config)
            return 1
        }
    }
}

/// Start the updater helper before constructing SwiftUI, the AppModel or any text services.
@main enum TypoBouncerMain {
    @MainActor static func main() async {
        if CommandLine.arguments.dropFirst().first == UpdateInstaller.argument {
            exit(await UpdateInstaller.runHelper(arguments: CommandLine.arguments))
        }
        TypoBouncerApp.main()
    }
}
