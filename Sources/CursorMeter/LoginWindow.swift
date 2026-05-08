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
        // Google OAuth — canonical
        "accounts.google.com", "oauth2.googleapis.com",
        // Google OAuth — ccTLD locale redirects (top ~50 markets).
        // Google routes some users through accounts.google.<ccTLD> before
        // landing on accounts.google.com. Without these entries, those
        // navigations are blocked, forcing Google's fallback path and adding
        // user-visible login friction. Reactively expand if a user reports a
        // missing country. Background: Google began phasing out ccTLDs in
        // 2025-04 in favor of unified .com routing, so this list is expected
        // to shrink in relevance over time.
        "accounts.google.co.uk", "accounts.google.de", "accounts.google.fr",
        "accounts.google.co.jp", "accounts.google.co.kr", "accounts.google.com.br",
        "accounts.google.co.in", "accounts.google.com.au", "accounts.google.com.mx",
        "accounts.google.it", "accounts.google.es", "accounts.google.ca",
        "accounts.google.nl", "accounts.google.ru", "accounts.google.cn",
        "accounts.google.com.tr", "accounts.google.pl", "accounts.google.co.id",
        "accounts.google.com.sg", "accounts.google.co.il", "accounts.google.se",
        "accounts.google.ch", "accounts.google.com.tw", "accounts.google.com.vn",
        "accounts.google.com.ar", "accounts.google.be", "accounts.google.at",
        "accounts.google.no", "accounts.google.dk", "accounts.google.fi",
        "accounts.google.ie", "accounts.google.cz", "accounts.google.gr",
        "accounts.google.pt", "accounts.google.com.hk", "accounts.google.co.th",
        "accounts.google.com.my", "accounts.google.com.ph", "accounts.google.co.za",
        "accounts.google.ae", "accounts.google.com.sa", "accounts.google.com.pk",
        "accounts.google.ro", "accounts.google.hu", "accounts.google.com.ua",
        "accounts.google.cl", "accounts.google.com.co", "accounts.google.co.nz",
        "accounts.google.com.eg", "accounts.google.com.ng",
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

    // Cookie names that must be present before we treat a Cursor login as
    // successful. Without this check, a partial cookie write (CSRF/analytics
    // cookies arriving before the auth cookie) would yield an empty session
    // header that silently fails on every subsequent API call.
    //
    // TODO: validate against additional names observed in real login flows
    // (Google OAuth, GitHub OAuth, WorkOS SSO, Azure AD). The current set
    // reflects the WorkOS-issued session token used by Cursor as of the
    // pre-public-release security review; live verification is required.
    nonisolated static let requiredCookieNames: Set<String> = [
        "WorkosCursorSessionToken",
    ]

    /// Returns the names of `requiredCookieNames` that are missing from
    /// `cookies`. Pure helper for unit testing the validation rule.
    nonisolated static func missingRequiredCookies(in cookies: [HTTPCookie]) -> Set<String> {
        let presentNames = Set(cookies.map { $0.name })
        return requiredCookieNames.subtracting(presentNames)
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

            // VERIFICATION-ONLY (remove before commit): log captured cookie names
            // to validate `requiredCookieNames` against real Cursor login flow.
            Log.info("Verification: captured cookie names = \(cursorCookies.map(\.name).sorted())")

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

            let missing = Self.missingRequiredCookies(in: cursorCookies)
            guard missing.isEmpty else {
                if !isRetry {
                    Log.info("Required cookies missing: \(missing.sorted()), retrying in 1s")
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    captureAndComplete(isRetry: true)
                } else {
                    Log.error("Required cookies still missing after retry: \(missing.sorted())")
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

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        // Defense-in-depth: WKWebView re-triggers navigationAction for each
        // redirect step today, but the contract is not stable. Validate the
        // response host as well so a 302 that bypasses the action delegate
        // cannot deliver content.
        guard let host = navigationResponse.response.url?.host,
              Self.isAllowedHost(host) else {
            Log.info("Blocked response from: \(navigationResponse.response.url?.host ?? "nil")")
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
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
