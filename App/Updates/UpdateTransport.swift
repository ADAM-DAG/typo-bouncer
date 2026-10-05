import Foundation

struct GitHubRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let size: Int64
        let browser_download_url: String
    }
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    func asset(named name: String, maximumSize: Int64) throws -> Asset {
        let matches = assets.filter { $0.name == name }
        guard !draft, !prerelease, matches.count == 1, let asset = matches.first,
              asset.size > 0, asset.size <= maximumSize,
              let url = URL(string: asset.browser_download_url),
              UpdateTransport.isReleaseAsset(url, name: name) else { throw UpdateFailure.invalidRelease }
        return asset
    }
}

enum UpdateFailure: Error {
    case invalidRelease, unavailable, invalidSignature, unsupportedInstall, invalidDownload, installFailed, busy
}

/// The only network client in the app. It never receives selection/model/clipboard data.
final class UpdateTransport: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let latest = URL(string: "https://api.github.com/repos/ADAM-DAG/typo-bouncer/releases/latest")!
    static let maximumDownload: Int64 = 128 * 1_024 * 1_024

    static func isReleaseAsset(_ url: URL, name: String) -> Bool {
        let parts = url.path.split(separator: "/")
        return isHTTPS(url) && url.host == "github.com" && parts.count == 6
            && parts.prefix(4).map(String.init) == ["ADAM-DAG", "typo-bouncer", "releases", "download"]
            && parts.last == Substring(name) && url.query == nil
    }

    static func isAllowed(_ url: URL) -> Bool {
        guard isHTTPS(url) else { return false }
        if url == latest { return true }
        if url.host == "github.com" {
            return isReleaseAsset(url, name: "TypoBouncer-update.json")
                || isReleaseAsset(url, name: "TypoBouncer-update.dmg")
        }
        return ["release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(url.host ?? "")
    }

    private static func isHTTPS(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443) && url.fragment == nil
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    private func request(_ url: URL) throws -> URLRequest {
        guard Self.isAllowed(url) else { throw UpdateFailure.invalidRelease }
        var request = URLRequest(url: url)
        request.setValue("TypoBouncer-Updater", forHTTPHeaderField: "User-Agent")
        if url == Self.latest {
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        }
        return request
    }

    func metadata(at url: URL, limit: Int = 1_024 * 1_024) async throws -> Data? {
        let session = session()
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request(url))
        guard let response = response as? HTTPURLResponse else { throw UpdateFailure.unavailable }
        if response.statusCode == 404, url == Self.latest { return nil }
        guard response.statusCode == 200, response.expectedContentLength <= limit else { throw UpdateFailure.unavailable }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw UpdateFailure.invalidDownload }
            data.append(byte)
        }
        return data
    }

    func download(_ asset: GitHubRelease.Asset, to destination: URL) async throws {
        guard let url = URL(string: asset.browser_download_url),
              Self.isReleaseAsset(url, name: "TypoBouncer-update.dmg") else { throw UpdateFailure.invalidRelease }
        let session = session()
        defer { session.invalidateAndCancel() }
        let (temporary, response) = try await session.download(for: request(url))
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              Int64(size) == asset.size, Int64(size) <= Self.maximumDownload else { throw UpdateFailure.invalidDownload }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.map(Self.isAllowed) == true ? request : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > Self.maximumDownload || totalBytesExpectedToWrite > Self.maximumDownload {
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
