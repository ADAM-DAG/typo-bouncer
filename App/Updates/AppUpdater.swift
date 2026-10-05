import AppKit
import BouncerCore
import Foundation
import Observation

actor UpdateService {
    struct Available: Sendable {
        let manifest: UpdateManifest
        let image: GitHubRelease.Asset
    }
    private let transport = UpdateTransport()

    func check(installed: URL) async throws -> Available? {
        _ = try UpdateTrust.requirement(for: installed)
        guard let data = try await transport.metadata(at: UpdateTransport.latest) else { return nil }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let metadata = try release.asset(named: "TypoBouncer-update.json", maximumSize: 16_384)
        let image = try release.asset(named: "TypoBouncer-update.dmg", maximumSize: UpdateTransport.maximumDownload)
        guard let url = URL(string: metadata.browser_download_url),
              let data = try await transport.metadata(at: url, limit: 16_384), data.count == metadata.size else {
            throw UpdateFailure.invalidRelease
        }
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
        guard let info = Bundle(url: installed)?.infoDictionary,
              let build = Int(info["CFBundleVersion"] as? String ?? "") else { throw UpdateFailure.invalidRelease }
        guard try manifest.isNewer(thanBuild: build, version: info["CFBundleShortVersionString"] as? String ?? "",
                                  systemVersion: UpdateTrust.systemVersion) else { return nil }
        return Available(manifest: manifest, image: image)
    }

    func stage(_ available: Available, installed: URL) async throws -> URL {
        _ = try UpdateTrust.requirement(for: installed)
        let stage = try UpdateInstaller.makeStage(for: installed)
        do {
            let image = stage.appending(path: "update.dmg")
            try await transport.download(available.image, to: image)
            try Task.checkCancellation()
            try UpdateInstaller.prepare(image: image, stage: stage, installed: installed, manifest: available.manifest)
            try FileManager.default.removeItem(at: image)
            try Task.checkCancellation()
            return stage
        } catch {
            try? FileManager.default.removeItem(at: stage)
            throw error
        }
    }
}

@MainActor @Observable final class AppUpdater {
    enum Phase { case idle, checking, downloading, relaunching }
    private(set) var phase = Phase.idle
    private(set) var available: UpdateService.Available?
    private(set) var message: String?
    private(set) var isReleaseInstall = false
    private(set) var readyToRelaunch = false
    var automaticChecks: Bool {
        didSet {
            defaults.set(automaticChecks, forKey: "automaticUpdateChecks")
            if started { schedule() }
        }
    }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let installed: URL
    @ObservationIgnored private let service = UpdateService()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var job: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, installed: URL = Bundle.main.bundleURL) {
        self.defaults = defaults
        self.installed = installed.standardizedFileURL
        automaticChecks = defaults.object(forKey: "automaticUpdateChecks") as? Bool ?? true
        if defaults.bool(forKey: UpdateInstaller.failurePreference) {
            message = String(localized: "The update failed. Your previous app was kept. Try again.")
            defaults.removeObject(forKey: UpdateInstaller.failurePreference)
        }
    }

    var busy: Bool { phase != .idle }
    var mayTerminate: Bool { phase != .downloading && (phase != .relaunching || readyToRelaunch) }
    var status: String {
        switch phase {
        case .checking: return String(localized: "Checking for updates…")
        case .downloading: return String(localized: "Downloading and verifying…")
        case .relaunching: return String(localized: "Relaunching…")
        case .idle:
            if let message { return message }
            if let available { return String(localized: "Version \(available.manifest.version) is available.") }
            if !isReleaseInstall { return String(localized: "Updates require the GitHub release build.") }
            return String(localized: "Updates come from GitHub. Your text stays on this Mac.")
        }
    }

    func start() {
        guard !started, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        started = true
        job = Task {
            isReleaseInstall = await Task.detached { [installed] in
                (try? UpdateTrust.requirement(for: installed)) != nil
            }.value
            job = nil
            if isReleaseInstall { schedule() }
        }
    }

    private func schedule() {
        timer?.cancel(); timer = nil
        guard automaticChecks, isReleaseInstall else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let last = self.defaults.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
                if Date().timeIntervalSince(last) >= 86_400, !self.busy { self.check() }
                do { try await Task.sleep(for: .seconds(3_600)) } catch { return }
            }
        }
    }

    func check() {
        guard !busy, isReleaseInstall else { return }
        phase = .checking; message = nil
        // Throttle failures too, including GitHub rate limits. Manual checks can always retry.
        defaults.set(Date(), forKey: "lastUpdateCheck")
        job = Task {
            defer { phase = .idle; job = nil }
            do {
                available = try await service.check(installed: installed)
                if available == nil { message = String(localized: "No newer release is available.") }
            } catch is CancellationError { message = String(localized: "Update cancelled.") }
            catch {
                message = error is UpdateManifest.ValidationError
                    ? String(localized: "This release is invalid or needs a newer macOS version.")
                    : String(localized: "Could not check for updates. Try again later.")
            }
        }
    }

    func install(canRelaunch: @escaping @MainActor () -> Bool) {
        guard !busy, let available, canRelaunch() else { return }
        guard UpdateTrust.installationIsWritable(installed) else {
            message = String(localized: "Move Typo Bouncer to a writable Applications folder before updating.")
            return
        }
        phase = .downloading; message = nil; readyToRelaunch = false
        job = Task {
            var stage: URL?
            defer {
                if phase != .relaunching, let stage { try? FileManager.default.removeItem(at: stage) }
                if phase != .relaunching { phase = .idle }
                job = nil
            }
            do {
                stage = try await service.stage(available, installed: installed)
                guard canRelaunch(), let stage else { throw UpdateFailure.busy }
                phase = .relaunching
                try await UpdateInstaller.launchHelper(stage: stage)
                readyToRelaunch = true
                NSApplication.shared.terminate(nil)
            } catch {
                phase = .idle
                message = Task.isCancelled ? String(localized: "Update cancelled.")
                    : String(localized: "The update could not be installed. Your app was kept. Try again.")
            }
        }
    }

    func cancel() {
        if phase == .checking || phase == .downloading { job?.cancel() }
    }
}
