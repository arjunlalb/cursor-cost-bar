import XCTest
@testable import CursorMeter

/// Tests for #83 app-status notifications: release-available and
/// refresh-failing decision logic, dedup, and settings persistence.
@MainActor
final class AppStatusNotificationTests: XCTestCase {

    private static let enabledKey = "appStatusNotificationEnabled"
    private static let lastNotifiedKey = "lastNotifiedUpdateVersion"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.enabledKey)
        UserDefaults.standard.removeObject(forKey: Self.lastNotifiedKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.enabledKey)
        UserDefaults.standard.removeObject(forKey: Self.lastNotifiedKey)
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    // MARK: - shouldNotifyUpdate

    func testShouldNotifyUpdateFiresForNewVersion() {
        XCTAssertTrue(UsageViewModel.shouldNotifyUpdate(version: "0.8.0", lastNotified: "0.7.1", enabled: true))
    }

    func testShouldNotifyUpdateFiresWhenNeverNotified() {
        XCTAssertTrue(UsageViewModel.shouldNotifyUpdate(version: "0.8.0", lastNotified: nil, enabled: true))
    }

    func testShouldNotifyUpdateSuppressedForSameVersion() {
        XCTAssertFalse(UsageViewModel.shouldNotifyUpdate(version: "0.8.0", lastNotified: "0.8.0", enabled: true))
    }

    func testShouldNotifyUpdateSuppressedWhenDisabled() {
        XCTAssertFalse(UsageViewModel.shouldNotifyUpdate(version: "0.8.0", lastNotified: nil, enabled: false))
    }

    // MARK: - shouldNotifyRefreshFailing

    func testShouldNotifyRefreshFailingFiresExactlyAtThreshold() {
        XCTAssertFalse(UsageViewModel.shouldNotifyRefreshFailing(failureCount: 4, enabled: true))
        XCTAssertTrue(UsageViewModel.shouldNotifyRefreshFailing(failureCount: 5, enabled: true))
        XCTAssertFalse(UsageViewModel.shouldNotifyRefreshFailing(failureCount: 6, enabled: true))
    }

    func testShouldNotifyRefreshFailingSuppressedWhenDisabled() {
        XCTAssertFalse(UsageViewModel.shouldNotifyRefreshFailing(failureCount: 5, enabled: false))
    }

    // MARK: - Settings persistence

    func testAppStatusNotificationDefaultsToEnabled() {
        let vm = UsageViewModel()
        XCTAssertTrue(vm.appStatusNotificationEnabled)
    }

    func testSetAppStatusNotificationPersistsAndReloads() {
        let vm = UsageViewModel()
        vm.setAppStatusNotificationEnabled(false)
        XCTAssertFalse(vm.appStatusNotificationEnabled)
        XCTAssertEqual(UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool, false)

        let reloaded = UsageViewModel()
        XCTAssertFalse(reloaded.appStatusNotificationEnabled)
    }
}
