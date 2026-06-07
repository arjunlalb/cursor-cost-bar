import Foundation

/// Outcome of an update check. The previous `Release?` shape collapsed four
/// distinct paths (up-to-date / 4xx / decoding error / network) into a single
/// `nil`, making a broken update mechanism indistinguishable from being
/// current. The enum separates them so the UI can surface "check failed"
/// instead of silently telling the user they're up to date.
enum UpdateCheckResult: Sendable, Equatable {
    case upToDate
    case available(UpdateChecker.Release)
    case failed(reason: String)
}

@MainActor
final class UpdateChecker: Sendable {
    struct Release: Sendable, Equatable {
        let tagName: String
        let htmlURL: String
        let version: String
    }

    static let shared = UpdateChecker()
    private init() {}

    private static let releasesURL = URL(string: "https://api.github.com/repos/WoojinAhn/CursorMeter/releases/latest")!

    /// Dedicated ephemeral session — no shared cookie/cache storage with
    /// the rest of the app, consistent with `CursorAPIClient`'s policy.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    func check() async -> UpdateCheckResult {
        do {
            var request = URLRequest(url: Self.releasesURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 10

            let (data, response) = try await session.data(for: request)
            let result = Self.classify(
                data: data,
                response: response,
                currentVersion: currentAppVersion()
            )
            Self.log(result, currentVersion: currentAppVersion())
            return result
        } catch {
            Log.error("Update check failed: \(error)")
            return .failed(reason: "Couldn't reach GitHub")
        }
    }

    /// Pure result classifier — turns a network response into a `UpdateCheckResult`
    /// without touching `URLSession`. Exposed for unit tests; production code
    /// calls this from `check()` after the awaited `data(for:)`.
    nonisolated static func classify(
        data: Data,
        response: URLResponse,
        currentVersion: String,
        isNewer: ((String, String) -> Bool)? = nil
    ) -> UpdateCheckResult {
        guard let httpResponse = response as? HTTPURLResponse else {
            return .failed(reason: "Invalid response from GitHub")
        }
        guard httpResponse.statusCode == 200 else {
            return .failed(reason: "GitHub returned \(httpResponse.statusCode)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String,
              let htmlURL = json["html_url"] as? String
        else {
            return .failed(reason: "Couldn't read release info")
        }

        let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        let compare = isNewer ?? defaultIsNewer
        guard compare(remoteVersion, currentVersion) else {
            return .upToDate
        }
        return .available(Release(tagName: tagName, htmlURL: htmlURL, version: remoteVersion))
    }

    nonisolated private static func defaultIsNewer(remote: String, current: String) -> Bool {
        let remoteParts = remote.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(remoteParts.count, currentParts.count) {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let c = i < currentParts.count ? currentParts[i] : 0
            if r > c { return true }
            if r < c { return false }
        }
        return false
    }

    private static func log(_ result: UpdateCheckResult, currentVersion: String) {
        switch result {
        case .upToDate:
            Log.info("App is up to date (current: \(currentVersion))")
        case .available(let release):
            Log.info("Update available: \(currentVersion) → \(release.version)")
        case .failed(let reason):
            Log.error("Update check failed: \(reason)")
        }
    }

    private func currentAppVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// Simple semver comparison: returns true if remote > current.
    /// Kept as an instance method for back-compat with existing tests; the
    /// production code path uses `defaultIsNewer` via `classify`.
    func isNewer(remote: String, current: String) -> Bool {
        Self.defaultIsNewer(remote: remote, current: current)
    }
}
