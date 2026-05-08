import XCTest
@testable import CursorMeter

final class ExternalURLTests: XCTestCase {
    // MARK: - Allowed

    func testAllowsGitHubRoot() {
        XCTAssertTrue(ExternalURL.isAllowedGitHub(URL(string: "https://github.com")!))
    }

    func testAllowsGitHubRepoPath() {
        XCTAssertTrue(
            ExternalURL.isAllowedGitHub(
                URL(string: "https://github.com/WoojinAhn/CursorMeter/releases/latest")!
            )
        )
    }

    func testAllowsApiGitHubSubdomain() {
        XCTAssertTrue(
            ExternalURL.isAllowedGitHub(URL(string: "https://api.github.com/repos/foo/bar")!)
        )
    }

    func testAllowsUppercaseHost() {
        // Host comparison is case-insensitive.
        XCTAssertTrue(ExternalURL.isAllowedGitHub(URL(string: "https://GitHub.com/foo")!))
    }

    // MARK: - Rejected

    func testRejectsHttpScheme() {
        XCTAssertFalse(ExternalURL.isAllowedGitHub(URL(string: "http://github.com")!))
    }

    func testRejectsFileScheme() {
        XCTAssertFalse(ExternalURL.isAllowedGitHub(URL(string: "file:///etc/passwd")!))
    }

    func testRejectsUnrelatedHost() {
        XCTAssertFalse(ExternalURL.isAllowedGitHub(URL(string: "https://evil.com/foo")!))
    }

    func testRejectsHostnameSpoofingViaSuffix() {
        // `github.com.evil.com` must NOT match — `hasSuffix(".github.com")`
        // and exact match are the only accepted forms.
        XCTAssertFalse(
            ExternalURL.isAllowedGitHub(URL(string: "https://github.com.evil.com/foo")!)
        )
    }

    func testRejectsHostnameContainingGitHub() {
        XCTAssertFalse(
            ExternalURL.isAllowedGitHub(URL(string: "https://notgithub.com/foo")!)
        )
    }

    func testRejectsCustomScheme() {
        XCTAssertFalse(
            ExternalURL.isAllowedGitHub(URL(string: "x-malicious://github.com/foo")!)
        )
    }

    // MARK: - openGitHub return value

    func testOpenGitHubReturnsFalseForRejected() {
        // Validation path: the URL is rejected before NSWorkspace is invoked,
        // so this is safe to call from a unit test.
        XCTAssertFalse(ExternalURL.openGitHub(URL(string: "https://evil.com")!))
        XCTAssertFalse(ExternalURL.openGitHub(URL(string: "file:///etc/passwd")!))
        XCTAssertFalse(
            ExternalURL.openGitHub(URL(string: "https://github.com.evil.com")!)
        )
    }
}
