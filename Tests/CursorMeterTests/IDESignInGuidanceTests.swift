import XCTest
@testable import CursorMeter

/// #88: IDE-availability detection + sign-in watch. Drives the
/// `ideCredentialProvider` / `ideAppLauncher` seams with shortened watch
/// timings. The isRefreshing-collision tick rule is covered by code guards
/// only (isRefreshing is private and refresh() double-guards anyway).
@MainActor
final class IDESignInGuidanceTests: XCTestCase {

    /// Thread-safe credential source for the @Sendable provider seam.
    /// `gate` (when locked before a read) blocks the provider so tests can
    /// interleave logout/restart with a pending read.
    final class CredentialBox: @unchecked Sendable {
        private let lock = NSLock()
        private var credential: IDECredential?
        private(set) var readCount = 0
        private let gate = NSLock()

        /// Sync wrappers — NSLock.lock() is unavailable directly in async
        /// test bodies.
        func holdReads() { gate.lock() }
        func releaseReads() { gate.unlock() }

        func set(_ value: IDECredential?) {
            lock.lock(); defer { lock.unlock() }
            credential = value
        }

        func read() -> IDECredential? {
            gate.lock(); gate.unlock()   // park here while the test holds the gate
            lock.lock(); defer { lock.unlock() }
            readCount += 1
            return credential
        }
    }

    static let testCredential = IDECredential(
        cookieHeader: "WorkosCursorSessionToken=test",
        expiresAt: Date().addingTimeInterval(3600)
    )

    // logout() persists ideAuthSuppressed=true into the real UserDefaults;
    // without cleanup it leaks into later tests (their view models load it
    // in init and silently skip chain step 1).
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "ideAuthSuppressed")
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        UserDefaults.standard.removeObject(forKey: "ideAuthSuppressed")
        super.tearDown()
    }

    private func makeViewModel(box: CredentialBox) -> UsageViewModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let vm = UsageViewModel(apiClient: CursorAPIClient(configuration: config))
        vm.keychainDeleteHandler = {}
        vm.sessionExpiredNotifier = {}   // UNUserNotificationCenter crashes in SPM tests
        vm.updateCheckRunner = { .upToDate }
        vm.ideCredentialProvider = { box.read() }
        vm.watchTickInterval = .milliseconds(20)
        vm.watchTimeout = .milliseconds(300)
        return vm
    }

    /// Minimal always-succeeding API mock (borrowed shape from StaleDataTests).
    private static let successHandler: (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
        let url = request.url!
        let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        switch url.path {
        case "/api/usage-summary":
            let json = """
            {
                "billingCycleStart": "2026-03-01T07:29:44.000Z",
                "billingCycleEnd": "2026-04-01T07:29:44.000Z",
                "membershipType": "pro",
                "isUnlimited": false,
                "individualUsage": {
                    "plan": { "enabled": true, "used": 8, "limit": 2000, "remaining": 1992, "totalPercentUsed": 0.1 },
                    "onDemand": { "enabled": true, "used": 0, "limit": 2000, "remaining": 2000 }
                }
            }
            """
            return (ok, Data(json.utf8))
        case "/api/auth/me":
            return (ok, Data("{\"email\":\"t@t.com\",\"name\":\"T\"}".utf8))
        default:
            return (ok, Data("{}".utf8))
        }
    }

    private func waitUntil(
        _ timeoutMs: Int = 2000,
        _ condition: @MainActor () -> Bool
    ) async {
        var waited = 0
        while !condition() && waited < timeoutMs {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 10
        }
    }

    // MARK: - refreshIDEAvailability

    func test_refreshIDEAvailability_noProvider_flagStaysNil() async {
        let box = CredentialBox()
        let vm = makeViewModel(box: box)
        vm.ideCredentialProvider = nil

        vm.refreshIDEAvailability()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(vm.ideCredentialAvailable)
    }

    func test_refreshIDEAvailability_credentialPresent_setsTrue() async {
        let box = CredentialBox()
        box.set(Self.testCredential)
        let vm = makeViewModel(box: box)

        vm.refreshIDEAvailability()
        await waitUntil { vm.ideCredentialAvailable == true }
        XCTAssertEqual(vm.ideCredentialAvailable, true)
    }

    func test_refreshIDEAvailability_credentialAbsent_setsFalse() async {
        let box = CredentialBox()
        let vm = makeViewModel(box: box)

        vm.refreshIDEAvailability()
        await waitUntil { vm.ideCredentialAvailable == false }
        XCTAssertEqual(vm.ideCredentialAvailable, false)
    }

    func test_refreshIDEAvailability_pendingReadInvalidatedByLogout() async {
        let box = CredentialBox()
        box.set(Self.testCredential)
        let vm = makeViewModel(box: box)

        box.holdReads()                    // park the provider read
        vm.refreshIDEAvailability()
        try? await Task.sleep(for: .milliseconds(50))
        vm.logout()                        // bumps generation
        box.releaseReads()                  // late result arrives

        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(vm.ideCredentialAvailable, "stale read must not write the flag")
    }

    // MARK: - refresh() publishes availability (chain step 1 side effect)

    func test_refresh_chainStep1Absence_publishesUnavailable() async {
        let box = CredentialBox()   // empty → provider returns nil
        let vm = makeViewModel(box: box)
        vm.authState = .loggedIn

        await vm.refresh()
        XCTAssertEqual(vm.ideCredentialAvailable, false)
    }

    func test_refresh_chainStep1Presence_publishesAvailable() async {
        let box = CredentialBox()
        box.set(Self.testCredential)
        let vm = makeViewModel(box: box)
        MockURLProtocol.requestHandler = Self.successHandler

        await vm.refresh()
        XCTAssertEqual(vm.ideCredentialAvailable, true)
        XCTAssertEqual(vm.activeAuthSource, .cursorIDE)
    }

    // MARK: - openIDEAndWatch / watch

    func test_openIDEAndWatch_launchFailure_noWatchStarts() async {
        let box = CredentialBox()
        box.set(Self.testCredential)
        let vm = makeViewModel(box: box)
        MockURLProtocol.requestHandler = Self.successHandler
        vm.ideAppLauncher = { completion in completion(false) }

        vm.openIDEAndWatch()
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(vm.authState, .loggedOut, "failed launch must not start the watch")
        XCTAssertEqual(box.readCount, 0)
    }

    func test_watch_signInDiscoveredMidPoll_autoConnects() async {
        let box = CredentialBox()   // starts signed-out
        let vm = makeViewModel(box: box)
        MockURLProtocol.requestHandler = Self.successHandler
        vm.ideAppLauncher = { completion in completion(true) }

        vm.openIDEAndWatch()
        try? await Task.sleep(for: .milliseconds(60))   // a few empty ticks
        box.set(Self.testCredential)                    // user signed in to the IDE

        await waitUntil { vm.authState == .loggedIn }
        XCTAssertEqual(vm.authState, .loggedIn)
        await waitUntil { vm.activeAuthSource == .cursorIDE }
        XCTAssertEqual(vm.activeAuthSource, .cursorIDE)
    }

    func test_watch_timeout_stopsWithoutConnect() async {
        let box = CredentialBox()   // never signs in
        let vm = makeViewModel(box: box)
        vm.ideAppLauncher = { completion in completion(true) }

        vm.openIDEAndWatch()
        try? await Task.sleep(for: .milliseconds(500))  // past the 300ms timeout
        XCTAssertEqual(vm.authState, .loggedOut)
        let countAtTimeout = box.readCount
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(box.readCount, countAtTimeout, "watch must stop polling after timeout")
    }

    func test_watch_stopsWhenLoggedInViaBrowser() async {
        let box = CredentialBox()
        let vm = makeViewModel(box: box)
        MockURLProtocol.requestHandler = Self.successHandler
        vm.ideAppLauncher = { completion in completion(true) }

        vm.openIDEAndWatch()
        try? await Task.sleep(for: .milliseconds(60))
        vm.onLoginSuccess(cookieHeader: "WorkosCursorSessionToken=browser")   // browser login mid-poll

        await waitUntil { vm.authState == .loggedIn }
        try? await Task.sleep(for: .milliseconds(80))   // let the watch observe loggedIn
        let countAfterStop = box.readCount
        try? await Task.sleep(for: .milliseconds(100))
        // onLoginSuccess's own refresh may read the provider once; the watch
        // itself must stop ticking afterwards.
        XCTAssertEqual(box.readCount, countAfterStop, "watch must stop once logged in")
    }

    func test_logout_duringPendingWatchRead_doesNotConnect() async {
        let box = CredentialBox()
        box.set(Self.testCredential)
        let vm = makeViewModel(box: box)
        MockURLProtocol.requestHandler = Self.successHandler
        vm.ideAppLauncher = { completion in completion(true) }

        box.holdReads()                    // park the first watch read
        vm.openIDEAndWatch()
        try? await Task.sleep(for: .milliseconds(50))
        vm.logout()
        box.releaseReads()                  // late read returns a credential

        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(vm.authState, .loggedOut, "late read after logout must not connect")
        XCTAssertTrue(vm.ideAuthSuppressed, "logout suppression must survive the pending read")
    }

    func test_watchRestart_invalidatesPriorPendingRead() async {
        let box = CredentialBox()
        box.set(Self.testCredential)
        let vm = makeViewModel(box: box)
        MockURLProtocol.requestHandler = Self.successHandler
        vm.ideAppLauncher = { completion in completion(true) }

        box.holdReads()
        vm.openIDEAndWatch()               // watch #1 parks on the read
        try? await Task.sleep(for: .milliseconds(50))
        vm.openIDEAndWatch()               // restart while #1's read is pending
        box.releaseReads()

        await waitUntil { vm.authState == .loggedIn }
        XCTAssertEqual(vm.authState, .loggedIn, "restarted watch still connects")
    }
}
