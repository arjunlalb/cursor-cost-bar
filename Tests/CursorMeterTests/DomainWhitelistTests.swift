import XCTest
@testable import CursorMeter

final class DomainWhitelistTests: XCTestCase {

    // MARK: - Exact Matches

    @MainActor
    func testExactMatchCursorDotCom() {
        XCTAssertTrue(LoginWindow.isAllowedHost("cursor.com"))
    }

    @MainActor
    func testExactMatchWwwCursorDotCom() {
        XCTAssertTrue(LoginWindow.isAllowedHost("www.cursor.com"))
    }

    @MainActor
    func testExactMatchAuthenticatorCursorSh() {
        XCTAssertTrue(LoginWindow.isAllowedHost("authenticator.cursor.sh"))
    }

    @MainActor
    func testExactMatchAuthenticateCursorSh() {
        XCTAssertTrue(LoginWindow.isAllowedHost("authenticate.cursor.sh"))
    }

    @MainActor
    func testExactMatchApiWorkos() {
        XCTAssertTrue(LoginWindow.isAllowedHost("api.workos.com"))
    }

    @MainActor
    func testExactMatchAccountsGoogle() {
        XCTAssertTrue(LoginWindow.isAllowedHost("accounts.google.com"))
    }

    @MainActor
    func testExactMatchAccountsGoogleCcTLDs() {
        // Sample of the ~50 ccTLD locale redirects Google routes through
        // before landing on accounts.google.com. These must not be blocked.
        XCTAssertTrue(LoginWindow.isAllowedHost("accounts.google.co.kr"))
        XCTAssertTrue(LoginWindow.isAllowedHost("accounts.google.de"))
        XCTAssertTrue(LoginWindow.isAllowedHost("accounts.google.com.br"))
        XCTAssertTrue(LoginWindow.isAllowedHost("accounts.google.co.jp"))
        XCTAssertTrue(LoginWindow.isAllowedHost("accounts.google.co.uk"))
    }

    @MainActor
    func testBlocksNonAccountsGoogleCcTLD() {
        // Only accounts.* under each ccTLD is allowed; sites/mail/etc. are not.
        XCTAssertFalse(LoginWindow.isAllowedHost("sites.google.co.kr"))
        XCTAssertFalse(LoginWindow.isAllowedHost("mail.google.de"))
        XCTAssertFalse(LoginWindow.isAllowedHost("evil.google.co.kr"))
        // Unlisted ccTLDs remain blocked (reactive expansion policy).
        XCTAssertFalse(LoginWindow.isAllowedHost("accounts.google.li"))
    }

    @MainActor
    func testExactMatchGithub() {
        XCTAssertTrue(LoginWindow.isAllowedHost("github.com"))
    }

    @MainActor
    func testExactMatchMicrosoftonline() {
        XCTAssertTrue(LoginWindow.isAllowedHost("login.microsoftonline.com"))
    }

    @MainActor
    func testExactMatchStripeJs() {
        XCTAssertTrue(LoginWindow.isAllowedHost("js.stripe.com"))
    }

    @MainActor
    func testExactMatchStripeNetwork() {
        XCTAssertTrue(LoginWindow.isAllowedHost("m.stripe.network"))
    }

    // MARK: - Subdomain Matches

    @MainActor
    func testSubdomainCursorCom() {
        XCTAssertTrue(LoginWindow.isAllowedHost("api.cursor.com"))
        XCTAssertTrue(LoginWindow.isAllowedHost("deep.sub.cursor.com"))
    }

    @MainActor
    func testSubdomainCursorSh() {
        XCTAssertTrue(LoginWindow.isAllowedHost("auth2.cursor.sh"))
    }

    @MainActor
    func testSubdomainWorkos() {
        XCTAssertTrue(LoginWindow.isAllowedHost("auth.workos.com"))
    }

    @MainActor
    func testBlocksGoogleSubdomainNotInExactSet() {
        // Suffix `.google.com` removed — only `accounts.google.com` and
        // `oauth2.googleapis.com` are allowed.
        XCTAssertFalse(LoginWindow.isAllowedHost("oauth2.google.com"))
    }

    @MainActor
    func testExactMatchApiGithub() {
        // api.github.com remains allowed via exactHosts.
        XCTAssertTrue(LoginWindow.isAllowedHost("api.github.com"))
    }

    @MainActor
    func testSubdomainMicrosoftonline() {
        XCTAssertTrue(LoginWindow.isAllowedHost("tenant.login.microsoftonline.com"))
    }

    @MainActor
    func testBlocksStripeApi() {
        // Suffix `.stripe.com` removed — only `js.stripe.com` is allowed.
        XCTAssertFalse(LoginWindow.isAllowedHost("api.stripe.com"))
    }

    @MainActor
    func testBlocksStripeNetworkSubdomain() {
        // Suffix `.stripe.network` removed — only `m.stripe.network` is allowed.
        XCTAssertFalse(LoginWindow.isAllowedHost("r.stripe.network"))
    }

    // MARK: - Negative Cases for Tightened Suffixes

    @MainActor
    func testBlocksEvilGoogle() {
        XCTAssertFalse(LoginWindow.isAllowedHost("evil.google.com"))
    }

    @MainActor
    func testBlocksSitesGoogle() {
        XCTAssertFalse(LoginWindow.isAllowedHost("sites.google.com"))
    }

    @MainActor
    func testBlocksEvilGithub() {
        XCTAssertFalse(LoginWindow.isAllowedHost("evil.github.com"))
    }

    @MainActor
    func testBlocksPagesGithub() {
        XCTAssertFalse(LoginWindow.isAllowedHost("pages.github.com"))
    }

    @MainActor
    func testBlocksEvilStripe() {
        XCTAssertFalse(LoginWindow.isAllowedHost("evil.stripe.com"))
    }

    // MARK: - Case Insensitivity

    @MainActor
    func testCaseInsensitiveExactMatch() {
        XCTAssertTrue(LoginWindow.isAllowedHost("Cursor.com"))
    }

    @MainActor
    func testCaseInsensitiveUppercase() {
        XCTAssertTrue(LoginWindow.isAllowedHost("ACCOUNTS.GOOGLE.COM"))
    }

    // MARK: - Blocked Domains

    @MainActor
    func testBlocksRandomDomain() {
        XCTAssertFalse(LoginWindow.isAllowedHost("evil.com"))
    }

    @MainActor
    func testBlocksGoogleDotCom() {
        // google.com itself is NOT in the allowed set (only accounts.google.com)
        XCTAssertFalse(LoginWindow.isAllowedHost("google.com"))
    }

    @MainActor
    func testBlocksPhishing() {
        XCTAssertFalse(LoginWindow.isAllowedHost("cursor.com.evil.com"))
    }

    @MainActor
    func testBlocksSimilarDomain() {
        XCTAssertFalse(LoginWindow.isAllowedHost("notcursor.com"))
        XCTAssertFalse(LoginWindow.isAllowedHost("fakegithub.com"))
    }

    @MainActor
    func testBlocksPartialSuffix() {
        // "xcursor.com" ends with "cursor.com" but NOT ".cursor.com"
        XCTAssertFalse(LoginWindow.isAllowedHost("xcursor.com"))
    }

    // MARK: - Edge Cases

    @MainActor
    func testEmptyString() {
        XCTAssertFalse(LoginWindow.isAllowedHost(""))
    }

    @MainActor
    func testWorkosComNotAllowed() {
        // "workos.com" is NOT in the exact set (only api.workos.com)
        XCTAssertFalse(LoginWindow.isAllowedHost("workos.com"))
    }

    @MainActor
    func testStripeDotComNotAllowed() {
        // "stripe.com" is NOT in the exact set
        XCTAssertFalse(LoginWindow.isAllowedHost("stripe.com"))
    }

    // MARK: - Scheme Enforcement (isAllowedURL)

    @MainActor
    func testAllowsHttpsWithWhitelistedHost() {
        XCTAssertTrue(LoginWindow.isAllowedURL(URL(string: "https://accounts.google.com/signin")))
    }

    @MainActor
    func testRejectsHttpEvenForWhitelistedHost() {
        XCTAssertFalse(LoginWindow.isAllowedURL(URL(string: "http://accounts.google.com/signin")))
    }

    @MainActor
    func testRejectsNonHttpsSchemes() {
        XCTAssertFalse(LoginWindow.isAllowedURL(URL(string: "file:///etc/passwd")))
        XCTAssertFalse(LoginWindow.isAllowedURL(URL(string: "javascript:alert(1)")))
        XCTAssertFalse(LoginWindow.isAllowedURL(URL(string: "data:text/html,<script>")))
    }

    @MainActor
    func testRejectsHttpsWithDisallowedHost() {
        XCTAssertFalse(LoginWindow.isAllowedURL(URL(string: "https://evil.example.com/login")))
    }

    @MainActor
    func testRejectsNilURL() {
        XCTAssertFalse(LoginWindow.isAllowedURL(nil))
    }
}
