import XCTest
@testable import CursorMeter

/// #54 credential chain: IDE-first resolution, 401 fallthrough to the captured
/// cookie, all-sources-exhausted expiry, and activeAuthSource reporting.
@MainActor
final class CredentialChainTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func makeViewModel() -> UsageViewModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let vm = UsageViewModel(apiClient: CursorAPIClient(configuration: config))
        vm.updateCheckRunner = { .upToDate }
        vm.keychainDeleteHandler = {}
        vm.sessionExpiredNotifier = {}
        vm.refreshFailingNotifier = {}
        return vm
    }

    private nonisolated static let ideCredential = IDECredential(
        cookieHeader: "WorkosCursorSessionToken=user_ide%3A%3AJ.W.T",
        expiresAt: Date().addingTimeInterval(3600)
    )

    /// 200 for every endpoint; captures the Cookie header of each request.
    private static func successHandler(
        seenCookies: @escaping @Sendable (String?) -> Void
    ) -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            seenCookies(request.value(forHTTPHeaderField: "Cookie"))
            let url = request.url!
            let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            switch url.path {
            case "/api/usage-summary":
                let json = """
                {"billingCycleStart":"2026-07-01T00:00:00.000Z","billingCycleEnd":"2026-08-01T00:00:00.000Z",
                 "membershipType":"pro","limitType":"user","isUnlimited":false,
                 "individualUsage":{"plan":{"enabled":true,"used":8,"limit":2000,"remaining":1992,"totalPercentUsed":0.1}}}
                """
                return (ok, Data(json.utf8))
            case "/api/auth/me":
                return (ok, Data("{\"email\":\"t@t.com\",\"name\":\"T\"}".utf8))
            case "/api/usage":
                return (ok, Data("{\"startOfMonth\":\"2026-07-01T00:00:00.000Z\"}".utf8))
            default:
                return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
            }
        }
    }

    private static let unauthorizedHandler: (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
        (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
    }

    // MARK: - Chain resolution

    func testIDECredentialUsedWhenAvailable() async {
        let vm = makeViewModel()
        vm.ideCredentialProvider = { Self.ideCredential }
        let box = CookieBox()
        MockURLProtocol.requestHandler = Self.successHandler { box.append($0) }

        await vm.refresh()

        XCTAssertEqual(vm.activeAuthSource, .cursorIDE)
        XCTAssertEqual(vm.authState, .loggedIn)
        XCTAssertNotNil(vm.usageData)
        XCTAssertTrue(box.all.allSatisfy { $0 == Self.ideCredential.cookieHeader })
    }

    func testNoIDEFallsBackToCapturedCookie() async {
        let vm = makeViewModel()  // provider nil
        vm.testHook_setCookieHeader("WorkosCursorSessionToken=captured")
        vm.authState = .loggedIn
        let box = CookieBox()
        MockURLProtocol.requestHandler = Self.successHandler { box.append($0) }

        await vm.refresh()

        XCTAssertEqual(vm.activeAuthSource, .browserLogin)
        XCTAssertTrue(box.all.allSatisfy { $0 == "WorkosCursorSessionToken=captured" })
    }

    func testNeitherSourceMeansLoginRequiredWithoutNetwork() async {
        let vm = makeViewModel()
        let box = CookieBox()
        MockURLProtocol.requestHandler = Self.successHandler { box.append($0) }

        await vm.refresh()

        XCTAssertEqual(vm.authState, .loginRequired)
        XCTAssertNil(vm.activeAuthSource)
        XCTAssertTrue(box.all.isEmpty, "no API call without any credential")
    }

    // MARK: - 401 fallthrough

    func testIDE401FallsThroughToCapturedCookieWithinOneRefresh() async {
        let vm = makeViewModel()
        vm.ideCredentialProvider = { Self.ideCredential }
        vm.testHook_setCookieHeader("WorkosCursorSessionToken=captured")
        vm.authState = .loggedIn
        var keychainDeletes = 0
        vm.keychainDeleteHandler = { keychainDeletes += 1 }
        let box = CookieBox()
        // 401 for the IDE cookie, 200 for the captured one.
        let success = Self.successHandler { box.append($0) }
        MockURLProtocol.requestHandler = { request in
            if request.value(forHTTPHeaderField: "Cookie") == Self.ideCredential.cookieHeader {
                return try Self.unauthorizedHandler(request)
            }
            return try success(request)
        }

        await vm.refresh()

        XCTAssertEqual(vm.activeAuthSource, .browserLogin, "fell back within one refresh")
        XCTAssertEqual(vm.authState, .loggedIn)
        XCTAssertEqual(keychainDeletes, 0, "IDE 401 must not delete the captured cookie")
        XCTAssertNotNil(vm.usageData)
    }

    func testAllSources401RunsExpiryFlowOnce() async {
        let vm = makeViewModel()
        vm.ideCredentialProvider = { Self.ideCredential }
        vm.testHook_setCookieHeader("WorkosCursorSessionToken=captured")
        vm.authState = .loggedIn
        var expiredNotifications = 0
        vm.sessionExpiredNotifier = { expiredNotifications += 1 }
        MockURLProtocol.requestHandler = Self.unauthorizedHandler

        await vm.refresh()

        XCTAssertEqual(vm.authState, .loginRequired)
        XCTAssertNil(vm.activeAuthSource)
        XCTAssertEqual(expiredNotifications, 1, "single expiry flow for the whole chain")
    }
}

/// Reference box so the @Sendable capture-handler can accumulate cookies.
final class CookieBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String?] = []
    func append(_ v: String?) { lock.lock(); storage.append(v); lock.unlock() }
    var all: [String?] { lock.lock(); defer { lock.unlock() }; return storage }
}
