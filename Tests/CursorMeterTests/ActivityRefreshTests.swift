import XCTest
@testable import CursorMeter

/// Thread-safe hit counter for MockURLProtocol handlers (which run off-main).
final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func increment() { lock.withLock { _count += 1 } }
}

@MainActor
final class ActivityRefreshTests: XCTestCase {

    nonisolated private static let enabledKey = "activityRefreshEnabled"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.enabledKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.enabledKey)
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func makeViewModel(counting counter: RequestCounter) -> UsageViewModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            if url.path == "/api/usage-summary" { counter.increment() }
            let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (ok, Data("{}".utf8))
        }
        let vm = UsageViewModel(apiClient: CursorAPIClient(configuration: config))
        vm.keychainDeleteHandler = {}
        vm.sessionExpiredNotifier = {}   // UNUserNotificationCenter crashes in SPM tests
        vm.updateCheckRunner = { .upToDate }
        vm.testHook_setCookieHeader("WorkosCursorSessionToken=TEST")
        vm.activityDebounceInterval = .milliseconds(30)
        vm.activityMinRefreshInterval = .milliseconds(150)
        return vm
    }

    private func waitUntil(_ timeoutMs: Int = 2000, _ condition: () -> Bool) async {
        var waited = 0
        while !condition() && waited < timeoutMs {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 10
        }
    }

    func testBurstCollapsesToSingleRefresh() async {
        let counter = RequestCounter()
        let vm = makeViewModel(counting: counter)
        for _ in 0..<5 { vm.noteActivity() }
        await waitUntil { counter.count >= 1 }
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(counter.count, 1)
    }

    func testGuardDefersButNeverDrops() async {
        let counter = RequestCounter()
        let vm = makeViewModel(counting: counter)
        await vm.refresh()                       // any-source refresh stamps the guard
        XCTAssertEqual(counter.count, 1)

        vm.noteActivity()                        // debounce 30ms < guard 150ms
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(counter.count, 1)         // deferred: not fired early...
        await waitUntil { counter.count >= 2 }
        XCTAssertEqual(counter.count, 2)         // ...and not dropped
    }

    func testToggleOffCancelsPendingDebounce() async {
        let counter = RequestCounter()
        let vm = makeViewModel(counting: counter)
        vm.noteActivity()
        vm.setActivityRefreshEnabled(false)
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(counter.count, 0)
        XCTAssertFalse(vm.activityRefreshEnabled)
    }

    func testNoteActivityWhileDisabledIsNoOp() async {
        let counter = RequestCounter()
        let vm = makeViewModel(counting: counter)
        vm.setActivityRefreshEnabled(false)
        vm.noteActivity()
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(counter.count, 0)
    }
}
