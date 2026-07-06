import XCTest
@testable import CursorMeter

final class NotificationManagerTests: XCTestCase {

    // MARK: - Threshold Evaluation (Pure Logic)

    func testBelowWarningReturnsNone() {
        let result = NotificationManager.evaluateThreshold(
            percentUsed: 50,
            warningThreshold: 80,
            criticalThreshold: 90,
            notifiedThresholds: []
        )
        XCTAssertEqual(result, .none)
    }

    func testAtWarningReturnsWarning() {
        let result = NotificationManager.evaluateThreshold(
            percentUsed: 80,
            warningThreshold: 80,
            criticalThreshold: 90,
            notifiedThresholds: []
        )
        XCTAssertEqual(result, .warning)
    }

    func testAboveWarningBelowCriticalReturnsWarning() {
        let result = NotificationManager.evaluateThreshold(
            percentUsed: 85,
            warningThreshold: 80,
            criticalThreshold: 90,
            notifiedThresholds: []
        )
        XCTAssertEqual(result, .warning)
    }

    func testAtCriticalReturnsCritical() {
        let result = NotificationManager.evaluateThreshold(
            percentUsed: 90,
            warningThreshold: 80,
            criticalThreshold: 90,
            notifiedThresholds: []
        )
        XCTAssertEqual(result, .critical)
    }

    func testAboveCriticalReturnsCritical() {
        let result = NotificationManager.evaluateThreshold(
            percentUsed: 95,
            warningThreshold: 80,
            criticalThreshold: 90,
            notifiedThresholds: []
        )
        XCTAssertEqual(result, .critical)
    }

    func testWarningAlreadyNotifiedReturnsNone() {
        let result = NotificationManager.evaluateThreshold(
            percentUsed: 85,
            warningThreshold: 80,
            criticalThreshold: 90,
            notifiedThresholds: [80]
        )
        XCTAssertEqual(result, .none)
    }

    func testCriticalAlreadyNotifiedReturnsNone() {
        let result = NotificationManager.evaluateThreshold(
            percentUsed: 95,
            warningThreshold: 80,
            criticalThreshold: 90,
            notifiedThresholds: [80, 90]
        )
        XCTAssertEqual(result, .none)
    }

    func testCriticalNotNotifiedButWarningWasReturnsCritical() {
        let result = NotificationManager.evaluateThreshold(
            percentUsed: 92,
            warningThreshold: 80,
            criticalThreshold: 90,
            notifiedThresholds: [80]
        )
        XCTAssertEqual(result, .critical)
    }

    func testJumpPastBothReturnsCritical() {
        // When usage jumps from below warning to above critical,
        // critical takes priority
        let result = NotificationManager.evaluateThreshold(
            percentUsed: 95,
            warningThreshold: 80,
            criticalThreshold: 90,
            notifiedThresholds: []
        )
        XCTAssertEqual(result, .critical)
    }

    func testCustomThresholds() {
        let result = NotificationManager.evaluateThreshold(
            percentUsed: 65,
            warningThreshold: 60,
            criticalThreshold: 75,
            notifiedThresholds: []
        )
        XCTAssertEqual(result, .warning)
    }

    func testZeroPercentReturnsNone() {
        let result = NotificationManager.evaluateThreshold(
            percentUsed: 0,
            warningThreshold: 80,
            criticalThreshold: 90,
            notifiedThresholds: []
        )
        XCTAssertEqual(result, .none)
    }

    // MARK: - NotificationManager State

    @MainActor
    func testResetClearsNotifiedThresholds() {
        let manager = NotificationManager()
        // Simulate having notified
        Task {
            await manager.checkAndNotify(
                percentUsed: 85,
                warningThreshold: 80,
                criticalThreshold: 90,
                enabled: false, // disabled to avoid actual notification
                mode: .requestQuota(used: 0, limit: 0)
            )
        }
        manager.resetNotifications()
        XCTAssertTrue(manager.notifiedThresholds.isEmpty)
    }

    // MARK: - Usage Jump Notification

    func testUsageJumpBodyFormatIncludesDeltaAndCurrent() {
        let body = NotificationManager.makeUsageJumpBody(
            displayDelta: "+$0.30",
            currentUsage: "$2.10"
        )
        XCTAssertTrue(body.contains("+$0.30"))
        XCTAssertTrue(body.contains("$2.10"))
        XCTAssertTrue(body.contains("Max mode"))
    }

    func testUsageJumpBodyFormatExactWording() {
        let body = NotificationManager.makeUsageJumpBody(
            displayDelta: "+30 / 50",
            currentUsage: "45 / 50"
        )
        XCTAssertEqual(
            body,
            "Used +30 / 50 since last refresh — possible Max mode query. Now at 45 / 50."
        )
    }

    func testUsageJumpBodyHandlesPercentDelta() {
        let body = NotificationManager.makeUsageJumpBody(
            displayDelta: "+15.0%",
            currentUsage: "78.0%"
        )
        XCTAssertTrue(body.contains("+15.0%"))
        XCTAssertTrue(body.contains("78.0%"))
    }

    // MARK: - NotificationMode body / titleSuffix

    func test_body_requestQuota_isKorean() {
        let s = NotificationMode.requestQuota(used: 757, limit: 500).body(forPercent: 80)
        XCTAssertEqual(s, "월 요청 한도의 80%를 초과했습니다 (757 / 500)")
    }

    func test_body_creditPlan_includesUSD() {
        let s = NotificationMode.creditPlan(usedCents: 1600, limitCents: 2000).body(forPercent: 80)
        XCTAssertEqual(s, "월 플랜의 80%를 사용했습니다 ($16.00 / $20.00)")
    }

    func test_body_onDemand_includesUSD() {
        let s = NotificationMode.onDemand(usedCents: 3200, limitCents: 4000).body(forPercent: 80)
        XCTAssertEqual(s, "On-demand 청구의 80%를 사용했습니다 ($32.00 / $40.00)")
    }

    func test_titleSuffix_eachMode() {
        XCTAssertEqual(NotificationMode.requestQuota(used: 0, limit: 0).titleSuffix, "Request Quota")
        XCTAssertEqual(NotificationMode.creditPlan(usedCents: 0, limitCents: 0).titleSuffix, "Plan")
        XCTAssertEqual(NotificationMode.onDemand(usedCents: 0, limitCents: 0).titleSuffix, "On-demand")
    }

    func testUsageJumpIdentifierPrefixIsDistinct() {
        // Sanity check: the prefix used for jump notifications must not collide
        // with any of the integer threshold values used by checkAndNotify.
        XCTAssertEqual(NotificationManager.usageJumpIdentifierPrefix, "usage-jump")
    }

    // Note: a runtime test for `notifyUsageJump` is intentionally omitted —
    // `UNUserNotificationCenter.current()` aborts when invoked outside an
    // app bundle (the swift-test host has no bundle identifier). The body and
    // identifier-prefix tests above exercise the user-visible contract; the
    // remaining authorization/dispatch path is covered by manual smoke testing.

    // MARK: - Notification Click Routing (#79, #83)

    func testClickActionSessionExpiredOpensLoginWindow() {
        XCTAssertEqual(
            NotificationManager.clickAction(
                forNotificationIdentifier: NotificationManager.sessionExpiredIdentifier,
                userInfo: [:]
            ),
            .openLoginWindow
        )
    }

    func testClickActionLegacyIdentifiersAreNoOps() {
        for id in ["\(NotificationManager.usageJumpIdentifierPrefix)-ABC", UUID().uuidString, ""] {
            XCTAssertEqual(
                NotificationManager.clickAction(forNotificationIdentifier: id, userInfo: [:]),
                .none
            )
        }
    }

    func testClickActionUpdateAvailableParsesReleaseURL() {
        let action = NotificationManager.clickAction(
            forNotificationIdentifier: NotificationManager.updateAvailableIdentifier,
            userInfo: [NotificationManager.releaseURLUserInfoKey: "https://github.com/WoojinAhn/CursorMeter/releases/tag/v0.8.0"]
        )
        XCTAssertEqual(
            action,
            .openReleaseURL(URL(string: "https://github.com/WoojinAhn/CursorMeter/releases/tag/v0.8.0")!)
        )
    }

    func testClickActionUpdateAvailableMissingOrMalformedURLIsNoOp() {
        XCTAssertEqual(
            NotificationManager.clickAction(
                forNotificationIdentifier: NotificationManager.updateAvailableIdentifier,
                userInfo: [:]
            ),
            .none
        )
        XCTAssertEqual(
            NotificationManager.clickAction(
                forNotificationIdentifier: NotificationManager.updateAvailableIdentifier,
                userInfo: [NotificationManager.releaseURLUserInfoKey: ""]
            ),
            .none
        )
        XCTAssertEqual(
            NotificationManager.clickAction(
                forNotificationIdentifier: NotificationManager.updateAvailableIdentifier,
                userInfo: [NotificationManager.releaseURLUserInfoKey: 42]
            ),
            .none
        )
    }

    func testClickActionRefreshFailingOpensPopover() {
        XCTAssertEqual(
            NotificationManager.clickAction(
                forNotificationIdentifier: NotificationManager.refreshFailingIdentifier,
                userInfo: [:]
            ),
            .openPopover
        )
    }

    // MARK: - Update-available body (#83)

    func testMakeUpdateAvailableBody() {
        XCTAssertEqual(
            NotificationManager.makeUpdateAvailableBody(version: "0.8.0"),
            "v0.8.0 is out — click to see what's new."
        )
    }
}
