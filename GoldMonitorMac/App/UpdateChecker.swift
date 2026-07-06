import Foundation
import AppKit

@MainActor
final class UpdateChecker: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case updateAvailable(version: String, body: String)
        case downloading
        case upToDate
        case error(String)
    }

    @Published var state: State = .idle
    @Published var downloadProgress: Double = 0

    private let repoOwner = "pouyaam"
    private let repoName = "HelixTradingAssistant"
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    var currentVersion: String {
        AppInfo.version
    }

    func checkForUpdates() async {
        state = .checking
        downloadProgress = 0

        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest") else {
            state = .error("Invalid URL")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                state = .error("Could not reach GitHub (\((response as? HTTPURLResponse)?.statusCode ?? -1))")
                return
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)

            let latestVersion = release.tagName.replacingOccurrences(of: "v", with: "")
            let current = currentVersion

            if compareVersions(latestVersion, isNewerThan: current) {
                state = .updateAvailable(version: latestVersion, body: release.body ?? "")
            } else {
                state = .upToDate
            }
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func downloadAndUpdate() async {
        guard case .updateAvailable(let version, _) = state else { return }

        state = .downloading
        downloadProgress = 0

        do {
            let (data, response) = try await fetchRelease(tag: "v\(version)")
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                state = .error("Could not reach GitHub")
                return
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard let asset = release.assets.first(where: { $0.name.hasSuffix(".dmg") }) else {
                state = .error("No .dmg found in this release")
                return
            }

            let dmgURL = try await downloadDMG(from: asset.browserDownloadURL)
            NSWorkspace.shared.open(dmgURL)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func fetchRelease(tag: String) async throws -> (Data, URLResponse) {
        let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/tags/\(tag)")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        return try await session.data(for: request)
    }

    private func downloadDMG(from urlString: String) async throws -> URL {
        guard let remoteURL = URL(string: urlString) else {
            throw UpdateError.invalidURL
        }

        let (tempURL, response) = try await session.download(from: remoteURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.downloadFailed
        }

        let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let filename = remoteURL.lastPathComponent
        let destination = downloadsDir.appendingPathComponent(filename)

        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }

        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }

    private func compareVersions(_ newer: String, isNewerThan current: String) -> Bool {
        let a = newer.split(separator: ".").compactMap { Int($0) }
        let b = current.split(separator: ".").compactMap { Int($0) }
        let count = max(a.count, b.count)
        for i in 0..<count {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }
}

// MARK: - GitHub API Models

private struct GitHubRelease: Decodable {
    let tagName: String
    let body: String?
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case assets
    }
}

private struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

// MARK: - Errors

private enum UpdateError: LocalizedError {
    case invalidURL
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid download URL"
        case .downloadFailed: return "Download failed"
        }
    }
}
