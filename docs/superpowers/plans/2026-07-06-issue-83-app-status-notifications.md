# App Status Notifications (Release + Error) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add release-available and refresh-failing system notifications behind one unified settings toggle (issue #83, spec `docs/superpowers/specs/2026-07-06-app-status-notifications-design.md`).

**Architecture:** Extend `NotificationManager` with two fixed-identifier notifications and an enum click router; funnel update-check results through one `UsageViewModel` helper that notifies on automatic checks only (write-before-send dedup per version); fire the error notification exactly when `consecutiveFailureCount` reaches `staleThreshold`. Seams mirror `sessionExpiredNotifier`; nil seam = silent skip (protects SPM test host from `UNUserNotificationCenter`).

**Tech Stack:** Swift 6 strict concurrency, AppKit, UserNotifications, XCTest + MockURLProtocol. Zero external dependencies.

## Global Constraints

- Tests must never call `UNUserNotificationCenter.current()` or touch the real Keychain (CLAUDE.md).
- `UsageViewModel` is `@Observable`; seams carry `@ObservationIgnored`. No new UI-read observable state → no `withObservationTracking` changes.
- Notification copy (exact): title `"CursorMeter update available"`, body `"v<version> is out — click to see what's new."`; title `"Cursor connection trouble"`, body `"Usage refresh has failed 5 times in a row. Data may be stale."`
- Identifiers (exact): `"update-available"`, `"refresh-failing"`; userInfo key `"releaseURL"` (String value).
- Settings toggle label (exact): `"App status notifications (new version · connection errors)"`, default ON.
- Commit format: `[#83] <type>: description`.
- Tests that write UserDefaults keys `appStatusNotificationEnabled` / `lastNotifiedUpdateVersion` must remove them in `setUp` and `tearDown`.

---

### Task 1: Decision logic + settings persistence (UsageViewModel)

**Files:**
- Modify: `Sources/CursorMeter/UsageViewModel.swift` (SettingsKey enum ~line 12; Settings vars ~line 137; setters ~line 734; `loadSettings` ~line 801)
- Test: `Tests/CursorMeterTests/AppStatusNotificationTests.swift` (create)

**Interfaces:**
- Produces: `UsageViewModel.shouldNotifyUpdate(version:lastNotified:enabled:) -> Bool`, `UsageViewModel.shouldNotifyRefreshFailing(failureCount:enabled:) -> Bool` (both `nonisolated static`), `var appStatusNotificationEnabled: Bool` (default true), `func setAppStatusNotificationEnabled(_:)`, SettingsKey cases `.appStatusNotificationEnabled` / `.lastNotifiedUpdateVersion`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/CursorMeterTests/AppStatusNotificationTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AppStatusNotificationTests 2>&1 | tail -20`
Expected: compile FAILURE — `shouldNotifyUpdate`, `shouldNotifyRefreshFailing`, `appStatusNotificationEnabled` not defined.

- [ ] **Step 3: Implement**

In `Sources/CursorMeter/UsageViewModel.swift`:

Add to `SettingsKey` (after `case weeklyChartStyle`):

```swift
    case appStatusNotificationEnabled
    case lastNotifiedUpdateVersion
```

Add to Settings vars (after `var menuBarDisplayMode: Int = 0`):

```swift
    /// Unified toggle for app-status notifications (#83): new-release and
    /// refresh-failing. Independent of usage-threshold and jump settings.
    var appStatusNotificationEnabled: Bool = true
```

Add pure decision functions (near `staleThreshold`, after `isDataStale`):

```swift
    /// Release notification eligibility (#83). Pure so dedup logic is unit-testable.
    nonisolated static func shouldNotifyUpdate(version: String, lastNotified: String?, enabled: Bool) -> Bool {
        enabled && version != lastNotified
    }

    /// Error notification fires exactly on the transition to stale (== not >=),
    /// so failures 6, 7, … don't re-fire; a success resets the counter and re-arms.
    nonisolated static func shouldNotifyRefreshFailing(failureCount: Int, enabled: Bool) -> Bool {
        enabled && failureCount == staleThreshold
    }
```

Add setter (after `setMenuBarDisplayMode`):

```swift
    func setAppStatusNotificationEnabled(_ enabled: Bool) {
        appStatusNotificationEnabled = enabled
        UserDefaults.standard.set(enabled, for: .appStatusNotificationEnabled)
    }
```

Add to `loadSettings()` (after the `.menuBarDisplayMode` block):

```swift
        if let val = defaults.object(for: .appStatusNotificationEnabled) as? Bool {
            appStatusNotificationEnabled = val
        }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AppStatusNotificationTests 2>&1 | tail -5`
Expected: all listed tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CursorMeter/UsageViewModel.swift Tests/CursorMeterTests/AppStatusNotificationTests.swift
git commit -m "[#83] feat: app-status notification decision logic + unified toggle persistence

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: NotificationManager — notify methods + enum click router

**Files:**
- Modify: `Sources/CursorMeter/NotificationManager.swift` (`sendNotification` ~line 176; Click Routing section ~line 219)
- Modify: `Sources/CursorMeter/CursorMeterApp.swift:271` (only the `opensLoginWindow` call site — full delegate rework is Task 4, but the build must stay green when the boolean router is removed)
- Test: `Tests/CursorMeterTests/NotificationManagerTests.swift` (~line 200: replace the three `opensLoginWindow` tests)

**Interfaces:**
- Produces: `NotificationClickAction` enum (`.openLoginWindow` / `.openReleaseURL(URL)` / `.openPopover` / `.none`), `NotificationManager.clickAction(forNotificationIdentifier:userInfo:)`, `NotificationManager.updateAvailableIdentifier`, `.refreshFailingIdentifier`, `.releaseURLUserInfoKey`, `makeUpdateAvailableBody(version:)`, `func notifyUpdateAvailable(version:releaseURL:)`, `func notifyRefreshFailing()`.
- Consumes: `UsageViewModel.staleThreshold` (for the body text count).

- [ ] **Step 1: Write the failing tests**

In `Tests/CursorMeterTests/NotificationManagerTests.swift`, DELETE the three tests that call `NotificationManager.opensLoginWindow` (around lines 205–230) and add:

```swift
    // MARK: - Click routing (#79, #83)

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
```

Note: `URL(string: "")` returns nil on modern SDKs; if it ever returns non-nil, `ExternalURL` host validation is the second gate — the test asserts the router contract only. Do NOT call `notifyUpdateAvailable`/`notifyRefreshFailing` in tests (UNUserNotificationCenter crashes the SPM test host).

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter NotificationManagerTests 2>&1 | tail -20`
Expected: compile FAILURE — `clickAction`, `NotificationClickAction`, new identifiers not defined.

- [ ] **Step 3: Implement**

In `Sources/CursorMeter/NotificationManager.swift`:

Add `userInfo` to `sendNotification` (existing call sites unaffected by the default):

```swift
    private func sendNotification(
        title: String,
        body: String,
        identifier: String = UUID().uuidString,
        userInfo: [AnyHashable: Any]? = nil
    ) async {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            if let userInfo {
                content.userInfo = userInfo
            }

            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: nil
            )
            try await center.add(request)
            Log.info("Notification sent: \(title)")
        } catch {
            Log.error("Notification failed: \(error)")
        }
    }
```

Add a new section before `// MARK: - Notification Click Routing (#79)`:

```swift
    // MARK: - App Status Notifications (#83)

    /// Fixed identifiers so a re-fire replaces the previous banner instead of
    /// stacking duplicates in Notification Center.
    nonisolated static let updateAvailableIdentifier = "update-available"
    nonisolated static let refreshFailingIdentifier = "refresh-failing"
    /// userInfo key carrying the GitHub release page URL as a String.
    nonisolated static let releaseURLUserInfoKey = "releaseURL"

    /// Pure body formatter, unit-tested without UNUserNotificationCenter.
    nonisolated static func makeUpdateAvailableBody(version: String) -> String {
        "v\(version) is out — click to see what's new."
    }

    func notifyUpdateAvailable(version: String, releaseURL: String) async {
        await sendNotification(
            title: "CursorMeter update available",
            body: Self.makeUpdateAvailableBody(version: version),
            identifier: Self.updateAvailableIdentifier,
            userInfo: [Self.releaseURLUserInfoKey: releaseURL]
        )
    }

    func notifyRefreshFailing() async {
        await sendNotification(
            title: "Cursor connection trouble",
            body: "Usage refresh has failed \(UsageViewModel.staleThreshold) times in a row. Data may be stale.",
            identifier: Self.refreshFailingIdentifier
        )
    }
```

REPLACE the `// MARK: - Notification Click Routing (#79)` section (the doc comment + `opensLoginWindow` function) with:

```swift
    // MARK: - Notification Click Routing (#79, #83)

    /// Pure routing decision for a clicked notification, including userInfo
    /// parsing so malformed payloads are unit-testable. Threshold and
    /// usage-jump notifications keep the default (no-op) click behavior.
    nonisolated static func clickAction(
        forNotificationIdentifier id: String,
        userInfo: [AnyHashable: Any]
    ) -> NotificationClickAction {
        switch id {
        case sessionExpiredIdentifier:
            return .openLoginWindow
        case updateAvailableIdentifier:
            guard let urlString = userInfo[releaseURLUserInfoKey] as? String,
                  let url = URL(string: urlString)
            else { return .none }
            return .openReleaseURL(url)
        case refreshFailingIdentifier:
            return .openPopover
        default:
            return .none
        }
    }
```

Add the enum at file scope (after the `NotificationMode` extension, before `// MARK: - Notification Manager`):

```swift
// MARK: - Notification Click Action

/// What the app should do when the user clicks a delivered notification.
enum NotificationClickAction: Sendable, Equatable {
    case openLoginWindow
    case openReleaseURL(URL)
    case openPopover
    case none
}
```

In `Sources/CursorMeter/CursorMeterApp.swift:271`, keep the build green by migrating the call site minimally (full switch lands in Task 4):

```swift
        if NotificationManager.clickAction(
            forNotificationIdentifier: identifier,
            userInfo: response.notification.request.content.userInfo
        ) == .openLoginWindow {
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter NotificationManagerTests 2>&1 | tail -5`
Expected: PASS (including migrated routing tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CursorMeter/NotificationManager.swift Sources/CursorMeter/CursorMeterApp.swift Tests/CursorMeterTests/NotificationManagerTests.swift
git commit -m "[#83] feat: update-available/refresh-failing notifications + enum click router

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: UsageViewModel — update-check funnel, seams, failure trigger

**Files:**
- Modify: `Sources/CursorMeter/UsageViewModel.swift` (init ~line 220; refresh success path ~line 398; forbidden/generic catch ~lines 469/472; seams near `sessionExpiredNotifier` ~line 180; `checkForUpdate` ~line 779)
- Test: `Tests/CursorMeterTests/AppStatusNotificationTests.swift` (extend)

**Interfaces:**
- Consumes: Task 1's `shouldNotifyUpdate`/`shouldNotifyRefreshFailing`, Task 1's SettingsKey cases.
- Produces: `enum UpdateCheckSource { case automatic, manual }`, `func recordUpdateCheckResult(_ result: UpdateCheckResult, source: UpdateCheckSource) async` (internal for tests), seams `updateAvailableNotifier: (@MainActor (_ version: String, _ releaseURL: String) async -> Void)?` and `refreshFailingNotifier: (@MainActor () async -> Void)?`.

- [ ] **Step 1: Write the failing tests**

Append to `AppStatusNotificationTests.swift` (inside the class). Reuse the `StaleDataTests` fixture pattern — MockURLProtocol handlers must stay stateless:

```swift
    // MARK: - recordUpdateCheckResult funnel

    private static let release = UpdateChecker.Release(
        tagName: "v9.9.9",
        htmlURL: "https://github.com/WoojinAhn/CursorMeter/releases/tag/v9.9.9",
        version: "9.9.9"
    )

    func testAutomaticAvailableResultNotifiesOncePerVersion() async {
        let vm = UsageViewModel()
        var notified: [(String, String)] = []
        vm.updateAvailableNotifier = { version, url in notified.append((version, url)) }

        await vm.recordUpdateCheckResult(.available(Self.release), source: .automatic)
        await vm.recordUpdateCheckResult(.available(Self.release), source: .automatic)

        XCTAssertEqual(notified.count, 1)
        XCTAssertEqual(notified.first?.0, "9.9.9")
        XCTAssertEqual(notified.first?.1, Self.release.htmlURL)
        XCTAssertEqual(vm.availableUpdate, Self.release)
        // Write-before-send: version persisted even though notifier is user code.
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: Self.lastNotifiedKey), "9.9.9")
    }

    func testManualCheckRecordsButNeverNotifies() async {
        let vm = UsageViewModel()
        var notifyCount = 0
        vm.updateAvailableNotifier = { _, _ in notifyCount += 1 }

        await vm.recordUpdateCheckResult(.available(Self.release), source: .manual)

        XCTAssertEqual(notifyCount, 0)
        XCTAssertEqual(vm.availableUpdate, Self.release)
        XCTAssertNil(UserDefaults.standard.string(forKey: Self.lastNotifiedKey))
    }

    func testDisabledToggleSuppressesUpdateNotification() async {
        let vm = UsageViewModel()
        vm.setAppStatusNotificationEnabled(false)
        var notifyCount = 0
        vm.updateAvailableNotifier = { _, _ in notifyCount += 1 }

        await vm.recordUpdateCheckResult(.available(Self.release), source: .automatic)

        XCTAssertEqual(notifyCount, 0)
        XCTAssertNil(UserDefaults.standard.string(forKey: Self.lastNotifiedKey))
    }

    func testUpToDateAndFailedResultsNeverNotify() async {
        let vm = UsageViewModel()
        var notifyCount = 0
        vm.updateAvailableNotifier = { _, _ in notifyCount += 1 }

        await vm.recordUpdateCheckResult(.upToDate, source: .automatic)
        await vm.recordUpdateCheckResult(.failed(reason: "offline"), source: .automatic)

        XCTAssertEqual(notifyCount, 0)
    }

    // MARK: - refresh-failing integration (MockURLProtocol)

    @MainActor final class Spy {
        var refreshFailingCount = 0
        var sessionExpiredCount = 0
    }

    private func makeFailingViewModel(spy: Spy) -> UsageViewModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let vm = UsageViewModel(apiClient: CursorAPIClient(configuration: config))
        vm.keychainDeleteHandler = {}
        vm.sessionExpiredNotifier = { spy.sessionExpiredCount += 1 }
        vm.refreshFailingNotifier = { spy.refreshFailingCount += 1 }
        vm.testHook_setCookieHeader("WorkosCursorSessionToken=test")
        vm.authState = .loggedIn
        return vm
    }

    private static let serverErrorHandler: (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
        let serverError = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
        return (serverError, Data("oops".utf8))
    }

    func testRefreshFailingNotifiesExactlyOnceAtThreshold() async {
        let spy = Spy()
        let vm = makeFailingViewModel(spy: spy)
        MockURLProtocol.requestHandler = Self.serverErrorHandler

        for _ in 0..<4 {
            await vm.refresh()
        }
        XCTAssertEqual(spy.refreshFailingCount, 0)

        await vm.refresh()  // 5th failure — the transition
        XCTAssertEqual(spy.refreshFailingCount, 1)

        await vm.refresh()  // 6th failure — no re-fire
        XCTAssertEqual(spy.refreshFailingCount, 1)
        XCTAssertEqual(spy.sessionExpiredCount, 0)
    }

    func testUnauthorizedPathFiresOnlySessionExpiredNotifier() async {
        let spy = Spy()
        let vm = makeFailingViewModel(spy: spy)
        MockURLProtocol.requestHandler = { request in
            let unauthorized = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (unauthorized, Data())
        }

        await vm.refresh()

        XCTAssertEqual(spy.sessionExpiredCount, 1)
        XCTAssertEqual(spy.refreshFailingCount, 0)
    }

    func testDisabledToggleSuppressesRefreshFailingNotification() async {
        let spy = Spy()
        let vm = makeFailingViewModel(spy: spy)
        vm.setAppStatusNotificationEnabled(false)
        MockURLProtocol.requestHandler = Self.serverErrorHandler

        for _ in 0..<6 {
            await vm.refresh()
        }
        XCTAssertEqual(spy.refreshFailingCount, 0)
    }
```

Re-arm-after-recovery is covered by the existing counter-reset behavior (`consecutiveFailureCount = 0` on success) plus `testRefreshFailingNotifiesExactlyOnceAtThreshold`; a full success-then-second-outage integration needs a threshold-safe success fixture — copy `StaleDataTests.successHandler` verbatim into this file and add:

```swift
    func testRecoveryReArmsRefreshFailingNotification() async {
        let spy = Spy()
        let vm = makeFailingViewModel(spy: spy)

        MockURLProtocol.requestHandler = Self.serverErrorHandler
        for _ in 0..<5 { await vm.refresh() }
        XCTAssertEqual(spy.refreshFailingCount, 1)

        MockURLProtocol.requestHandler = Self.successHandler
        await vm.refresh()  // success resets the counter

        MockURLProtocol.requestHandler = Self.serverErrorHandler
        for _ in 0..<5 { await vm.refresh() }
        XCTAssertEqual(spy.refreshFailingCount, 2)
    }
```

(`successHandler` is the static fixture from `Tests/CursorMeterTests/StaleDataTests.swift:41-70` — copy it whole, comment included, so percent-used stays low and no threshold notification path is reachable.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AppStatusNotificationTests 2>&1 | tail -20`
Expected: compile FAILURE — `recordUpdateCheckResult`, `UpdateCheckSource`, `updateAvailableNotifier`, `refreshFailingNotifier` not defined.

- [ ] **Step 3: Implement**

In `Sources/CursorMeter/UsageViewModel.swift`:

Add after the `sessionExpiredNotifier` declaration (~line 180):

```swift
    /// App-status notification hooks (#83), injectable for tests. Unlike
    /// `sessionExpiredNotifier` these have NO real fallback: nil → skip.
    /// Production wires them in CursorMeterApp; a nil seam must never reach
    /// UNUserNotificationCenter (SPM test host crash) or queue work.
    @ObservationIgnored internal var updateAvailableNotifier: (@MainActor (_ version: String, _ releaseURL: String) async -> Void)?
    @ObservationIgnored internal var refreshFailingNotifier: (@MainActor () async -> Void)?
```

Add near `UpdateCheckResult` usage (file scope, above the class or right after `RefreshInterval`):

```swift
/// Origin of an update-check result. Only automatic checks may notify —
/// a manual check's result is already on screen in the settings window.
enum UpdateCheckSource: Sendable, Equatable {
    case automatic
    case manual
}
```

Add the funnel (new section after `checkForUpdate()`):

```swift
    /// Single recording point for update-check results (#83). Assigns
    /// `lastUpdateCheckResult` and, for automatic sources only, fires the
    /// release notification with write-before-send dedup: the version is
    /// persisted before dispatch so overlapping check paths can't double-fire.
    func recordUpdateCheckResult(_ result: UpdateCheckResult, source: UpdateCheckSource) async {
        lastUpdateCheckResult = result
        guard source == .automatic, case .available(let release) = result else { return }
        let defaults = UserDefaults.standard
        guard Self.shouldNotifyUpdate(
            version: release.version,
            lastNotified: defaults.object(for: .lastNotifiedUpdateVersion) as? String,
            enabled: appStatusNotificationEnabled
        ) else { return }
        defaults.set(release.version, for: .lastNotifiedUpdateVersion)
        if let updateAvailableNotifier {
            await updateAvailableNotifier(release.version, release.htmlURL)
        }
    }
```

Replace the three result-assignment sites:

init (~line 220):

```swift
        Task {
            let result = await UpdateChecker.shared.check()
            await recordUpdateCheckResult(result, source: .automatic)
        }
```

refresh success path (~line 398-401) — the `shouldRecheckUpdate` gate and `lastUpdateCheckAt` stamping stay exactly as they are:

```swift
            if Self.shouldRecheckUpdate(lastCheck: lastUpdateCheckAt, now: Date()) {
                lastUpdateCheckAt = Date()
                Task {
                    let result = await UpdateChecker.shared.check()
                    await recordUpdateCheckResult(result, source: .automatic)
                }
            }
```

`checkForUpdate()` (~line 784): replace `lastUpdateCheckResult = await result` with:

```swift
        await recordUpdateCheckResult(await result, source: .manual)
```

Add the failure trigger. In the `catch APIError.forbidden` block (after `consecutiveFailureCount += 1`) and in the generic `catch` block (after `consecutiveFailureCount += 1`), insert the same call:

```swift
            await maybeNotifyRefreshFailing()
```

and add the private helper (next to `recordUpdateCheckResult`):

```swift
    /// Fires the refresh-failing notification on the 4→5 transition only.
    /// The unauthorized path never reaches this (it resets the counter and
    /// routes to the session-expired notification, #76).
    private func maybeNotifyRefreshFailing() async {
        guard Self.shouldNotifyRefreshFailing(
            failureCount: consecutiveFailureCount,
            enabled: appStatusNotificationEnabled
        ), let refreshFailingNotifier else { return }
        await refreshFailingNotifier()
    }
```

- [ ] **Step 4: Run the full suite**

Run: `swift test 2>&1 | tail -10`
Expected: ALL tests pass (StaleDataTests and SessionExpiryTests must stay green — they don't inject the new seams, and nil seams are no-ops).

- [ ] **Step 5: Commit**

```bash
git add Sources/CursorMeter/UsageViewModel.swift Tests/CursorMeterTests/AppStatusNotificationTests.swift
git commit -m "[#83] feat: update-check funnel + refresh-failing trigger with notifier seams

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: AppDelegate — click-action switch + notifier wiring

**Files:**
- Modify: `Sources/CursorMeter/CursorMeterApp.swift` (`applicationDidFinishLaunching` ~line 33; `userNotificationCenter(_:didReceive:)` ~line 265)

**Interfaces:**
- Consumes: `NotificationManager.clickAction(forNotificationIdentifier:userInfo:)`, `NotificationClickAction`, `notifyUpdateAvailable(version:releaseURL:)`, `notifyRefreshFailing()`, `ExternalURL.openGitHub(_:)`, existing `showPopover()` / `showLogin()`.
- No unit tests — thin glue over pure-tested router; verified by build + manual click check after install.

- [ ] **Step 1: Replace the delegate callback**

Replace the body of `userNotificationCenter(_:didReceive:withCompletionHandler:)` (including the Task 2 interim `if`):

```swift
    /// Routes a clicked notification via the pure `clickAction` router (#79, #83):
    /// session-expired → login window, update-available → GitHub release page
    /// (host-validated), refresh-failing → popover. Threshold/usage-jump keep
    /// the default no-op since the app has no main window to activate into.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = NotificationManager.clickAction(
            forNotificationIdentifier: response.notification.request.identifier,
            userInfo: response.notification.request.content.userInfo
        )
        switch action {
        case .openLoginWindow:
            Task { @MainActor [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.showLogin()
            }
        case .openReleaseURL(let url):
            Task { @MainActor in
                ExternalURL.openGitHub(url)
            }
        case .openPopover:
            Task { @MainActor [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.showPopover()
            }
        case .none:
            break
        }
        completionHandler()
    }
```

- [ ] **Step 2: Wire the notifier seams**

In `applicationDidFinishLaunching`, immediately after the existing early setup (before any long-running work; exact insertion point: first lines of the method body):

```swift
        // #83: app-status notification seams. Wired here (not defaulted in the
        // view model) so a nil seam in the SPM test host can never reach
        // UNUserNotificationCenter.
        viewModel.updateAvailableNotifier = { [manager = notificationManager] version, releaseURL in
            await manager.notifyUpdateAvailable(version: version, releaseURL: releaseURL)
        }
        viewModel.refreshFailingNotifier = { [manager = notificationManager] in
            await manager.notifyRefreshFailing()
        }
```

(The startup update check kicked off in `UsageViewModel.init` may theoretically complete before this wiring; per spec the notification is then skipped silently — next automatic check re-evaluates because write-before-send only happens when eligibility passes AND write precedes dispatch; a nil-seam skip does write the version. Accepted: the popover still shows the update, and the next release re-notifies. Do not add ordering machinery.)

- [ ] **Step 3: Build and run the suite**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: build succeeds, all tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/CursorMeter/CursorMeterApp.swift
git commit -m "[#83] feat: route notification clicks via enum router; wire app-status notifiers

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Settings toggle UI

**Files:**
- Modify: `Sources/CursorMeter/SettingsViewController.swift` (property list ~line 16; `updateUI()` ~line 156; `makeNotificationsSection()` ~line 222; actions ~line 472)

**Interfaces:**
- Consumes: `viewModel.appStatusNotificationEnabled`, `viewModel.setAppStatusNotificationEnabled(_:)` (Task 1).

- [ ] **Step 1: Add the checkbox**

Add property (next to `notificationToggle`):

```swift
    private var appStatusToggle = NSButton()
```

In `makeNotificationsSection()`, after the `thresholdBox` assignment block, create the toggle and include it in the section stack:

```swift
        appStatusToggle = makeCheckbox(
            title: "App status notifications (new version · connection errors)",
            action: #selector(appStatusToggleChanged)
        )

        let sectionStack = NSStackView(views: [notificationToggle, thresholdBox, appStatusToggle])
```

(The `let sectionStack = NSStackView(views: [notificationToggle, thresholdBox])` line at ~255 is replaced by the three-view version above.)

In `updateUI()` (Notifications block, after `thresholdBox.isHidden`):

```swift
        appStatusToggle.state = viewModel.appStatusNotificationEnabled ? .on : .off
```

Add the action (next to `notificationToggleChanged`):

```swift
    @objc private func appStatusToggleChanged() {
        viewModel.setAppStatusNotificationEnabled(appStatusToggle.state == .on)
    }
```

- [ ] **Step 2: Build + full suite**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: build succeeds, all tests pass.

- [ ] **Step 3: Commit**

```bash
git add Sources/CursorMeter/SettingsViewController.swift
git commit -m "[#83] feat: unified app-status notifications toggle in settings

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Ship — push, package, reinstall, verify

**Files:** none (operations only)

- [ ] **Step 1: Full verification**

Run: `swift test 2>&1 | tail -5`
Expected: `Test Suite 'All tests' passed`.

- [ ] **Step 2: Merge to main and push** (solo-work direct merge per user preference)

```bash
git checkout main && git merge --no-ff feature/83-app-status-notifications -m "Merge feature/83-app-status-notifications (#83)" && git push origin main
```

- [ ] **Step 3: Reinstall the local app** (CLAUDE.md sequence)

```bash
pkill -9 -x CursorMeter
rm -rf /Applications/CursorMeter.app CursorMeter.app
bash Scripts/package_app.sh
cp -r CursorMeter.app /Applications/
open /Applications/CursorMeter.app
```

- [ ] **Step 4: Verify via unified log** (local build stamps 0.1.0 → the release notification should fire once for the current latest GitHub version)

```bash
sleep 20 && /usr/bin/log show --predicate 'subsystem == "com.cursormeter"' --info --debug --last 2m | grep -i "notification\|update"
```

Expected: `Update available: 0.1.0 → <latest>` and `Notification sent: CursorMeter update available` (first run only; relaunching must NOT re-send — dedup via `lastNotifiedUpdateVersion`).

- [ ] **Step 5: Close the issue**

```bash
gh issue close 83 --comment "Shipped: release + refresh-failing notifications behind unified toggle. Spec: docs/superpowers/specs/2026-07-06-app-status-notifications-design.md"
gh issue list --state open
```
