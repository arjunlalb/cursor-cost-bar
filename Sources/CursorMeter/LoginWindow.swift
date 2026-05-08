import AppKit
import WebKit

@MainActor
final class LoginWindow: NSObject {
    private enum LoginState { case idle, navigating, completed }

    private var webView: WKWebView?
    private var window: NSWindow?
    private var onComplete: ((String?) -> Void)?
    private var state: LoginState = .idle

    // Tier 1: exact-match hosts. Tightened from suffix matching for parents
    // with large attack surface (google.com, github.com, stripe.com) where
    // a subdomain takeover or open redirect could pivot through this WebView.
    private nonisolated static let exactHosts: Set<String> = [
        // Cursor primary
        "cursor.com", "www.cursor.com",
        "authenticator.cursor.sh", "authenticate.cursor.sh",
        // Google OAuth
        "accounts.google.com", "oauth2.googleapis.com",
        // GitHub OAuth
        "github.com", "api.github.com",
        // Stripe (Cursor dashboard payment widgets)
        "js.stripe.com", "m.stripe.network",
        // WorkOS API (non-tenant)
        "api.workos.com",
        // Azure AD entry
        "login.microsoftonline.com",
    ]

    // Tier 2: suffix matching kept only where exact enumeration is impractical
    // (internal Cursor service segmentation, tenant-scoped SSO).
    private nonisolated static let allowedSuffixes: [String] = [
        ".cursor.com",
        ".cursor.sh",
        ".workos.com",
        ".microsoftonline.com",
    ]

    nonisolated static func isAllowedHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if exactHosts.contains(h) { return true }
        return allowedSuffixes.contains { h.hasSuffix($0) }
    }

    func open(onComplete: @escaping (String?) -> Void) {
        self.onComplete = onComplete
        self.state = .idle

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(
            frame: NSRect(x: 0, y: 0, width: 480, height: 640),
            configuration: config)
        webView.navigationDelegate = self
        self.webView = webView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Cursor Login"
        window.contentView = webView
        window.center()
        window.delegate = self
        // MenuBarExtra apps use .accessory policy — temporarily switch to .regular
        // so the login window can receive keyboard focus
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        let url = URL(string: "https://www.cursor.com/dashboard")!
        webView.load(URLRequest(url: url))
        Log.info("Login window opened")
    }

    private func complete(cookieHeader: String?) {
        guard state != .completed else { return }
        state = .completed
        onComplete?(cookieHeader)
        window?.close()
        webView = nil
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }

    private func captureAndComplete(isRetry: Bool = false) {
        guard state != .completed, let webView else { return }
        Task {
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            let cursorCookies = cookies.filter {
                $0.domain.contains("cursor.com") || $0.domain.contains("cursor.sh")
            }

            guard !cursorCookies.isEmpty else {
                if !isRetry {
                    Log.info("No cursor cookies found, retrying in 1s")
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    captureAndComplete(isRetry: true)
                } else {
                    Log.error("No cursor cookies found after retry")
                    complete(cookieHeader: nil)
                }
                return
            }

            let header = cursorCookies
                .map { "\($0.name)=\($0.value)" }
                .joined(separator: "; ")

            Log.info("Captured \(cursorCookies.count) cookies")
            complete(cookieHeader: header)
        }
    }
}

// MARK: - WKNavigationDelegate

extension LoginWindow: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url, let host = url.host else {
            decisionHandler(.cancel)
            return
        }

        if Self.isAllowedHost(host) {
            decisionHandler(.allow)
        } else {
            Log.info("Blocked navigation to: \(host)")
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        let urlString = url.absoluteString

        if !urlString.contains("cursor.com/dashboard") {
            state = .navigating
        }

        // After auth redirect back to dashboard, wait briefly for cookies to be written
        if urlString.contains("cursor.com/dashboard"), state == .navigating {
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                captureAndComplete()
            }
        }
    }
}

// MARK: - NSWindowDelegate

extension LoginWindow: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        complete(cookieHeader: nil)
    }
}
