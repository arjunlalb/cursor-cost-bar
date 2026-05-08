import XCTest
@testable import CursorMeter

final class RequiredCookieTests: XCTestCase {

    private func makeCookie(name: String, domain: String = ".cursor.com") -> HTTPCookie {
        HTTPCookie(properties: [
            .name: name,
            .value: "v",
            .domain: domain,
            .path: "/",
        ])!
    }

    @MainActor
    func testAuthCookiePresent_noMissing() {
        let cookies = [
            makeCookie(name: "WorkosCursorSessionToken"),
            makeCookie(name: "csrf"),
            makeCookie(name: "_ga"),
        ]
        let missing = LoginWindow.missingRequiredCookies(in: cookies)
        XCTAssertTrue(missing.isEmpty)
    }

    @MainActor
    func testAuthCookieMissing_reportsMissing() {
        let cookies = [
            makeCookie(name: "csrf"),
            makeCookie(name: "_ga"),
        ]
        let missing = LoginWindow.missingRequiredCookies(in: cookies)
        XCTAssertEqual(missing, ["WorkosCursorSessionToken"])
    }
}
