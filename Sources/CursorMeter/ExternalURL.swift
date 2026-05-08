import AppKit
import Foundation

/// Helpers for opening external URLs via `NSWorkspace`, with host validation
/// to prevent silently dispatching tampered URLs (e.g. `file://`, custom
/// schemes, or unrelated hosts) coming from network responses.
enum ExternalURL {
    /// Returns true if the URL is an `https` URL whose host is `github.com`
    /// or a subdomain of `github.com` (e.g. `api.github.com`).
    ///
    /// Pure validation, separated for testability.
    static func isAllowedGitHub(_ url: URL) -> Bool {
        guard url.scheme == "https",
              let host = url.host?.lowercased()
        else { return false }
        return host == "github.com" || host.hasSuffix(".github.com")
    }

    /// Opens a GitHub URL via `NSWorkspace`, only if it passes
    /// `isAllowedGitHub`. Otherwise logs and returns `false`.
    @discardableResult
    static func openGitHub(_ url: URL) -> Bool {
        guard isAllowedGitHub(url) else {
            Log.error("Refusing to open non-GitHub URL: \(url.host ?? "nil")")
            return false
        }
        NSWorkspace.shared.open(url)
        return true
    }
}
