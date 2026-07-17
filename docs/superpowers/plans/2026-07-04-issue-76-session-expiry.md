# Issue #76 — Session Expiry Detection + User Awareness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the stored Cursor session cookie expires, the app must detect it (regardless of which endpoint signals it and how), transition to `loginRequired`, and make the user notice: badge icon in the menu bar, expired-session popover state, and a one-shot system notification.

**Architecture:** Detection layer first (API client treats 204/empty body as `unauthorized`; `refresh()` captures all three endpoint results and checks *every* one for 401 before any decode error can abort), then awareness layer (new `CircularProgressIcon.loginRequiredImage()`, `loginRequired` branch in the popover's `applyStatus()`, `NotificationManager.notifySessionExpired()` fired only on the `loggedIn → loginRequired` transition).

**Tech Stack:** Swift 6 strict concurrency, pure AppKit, XCTest with `MockURLProtocol`, zero external dependencies.

**Scope note:** Covers issue #76 plan items 1, 2, 5, 6, 7. Items 3 (consecutive-failure stale indicator) and 4 (base-URL migration) are explicitly follow-ups per the agreed order in the issue comments — the final task files them as separate issues.

**Deliberate scope limit (Codex review 2026-07-04):** the secondary/dashboard endpoints (`fetchTeams`, `fetchTeamSpend`, `fetchHardLimit`, `fetchWeeklyUsage`) keep swallowing `unauthorized` (`try?` / nil-on-failure), unchanged. The three primary endpoints re-validate the session on every refresh, so an expiry that first surfaces on a secondary call is caught by the primaries within one refresh interval (≤ 2 min with Task 1's 204 rule). Expanding the 401 check to secondaries would couple the logout path to endpoints that legitimately fail on non-enterprise accounts.

## Global Constraints

- Swift 6 strict concurrency: `@MainActor`, `actor`, `Sendable`. CI (Xcode 16.4 / macOS 15.5 SDK) is stricter than local Xcode about Sendable across `await`.
- Zero external dependencies — macOS SDK only.
- `UsageViewModel` uses `@Observable`; new observed state must be read inside the relevant `withObservationTracking` block or UI won't update.
- Tests must NEVER touch the real Keychain item (`service: com.cursormeter.session`) or `UNUserNotificationCenter.current()` (the latter crashes in the SPM test host). Use the injection seams added in Task 3.
- User-facing strings in English (matches popover UI and the usage-jump notification).
- Commit format: `[#76] <type>: description`. Work on branch `fix/76-session-expiry`.
- Run tests with `swift test` (requires Xcode). All tests must pass before every commit.

---

### Task 0: Branch setup

- [ ] **Step 1: Create the working branch**

```bash
git checkout -b fix/76-session-expiry main
```

---

### Task 1: CursorAPIClient — treat 2xx empty body as `unauthorized`

`/api/auth/me` answers an invalid/expired cookie with **204 No Content** instead of 401 (verified via curl 2026-07-03; valid sessions always return 200 with a JSON body). Every endpoint in this client decodes JSON, so a 2xx with an empty body can never be a success — treat it as the session-expiry signal it is.

**Files:**
- Modify: `Sources/CursorMeter/CursorAPIClient.swift:162-166` (end of `performRequest`)
- Test: `Tests/CursorMeterTests/CursorAPIClientTests.swift`

**Interfaces:**
- Consumes: existing `APIError.unauthorized`, `performRequest` (private).
- Produces: behavior change only — all `fetch*` methods now throw `APIError.unauthorized` on 204 or empty-body 2xx responses. Task 3's view-model logic relies on this.

- [ ] **Step 1: Write the failing tests**

Add to `CursorAPIClientTests.swift` (follow the existing `setMockResponse` helper pattern in that file; if the helper only takes JSON strings, use `MockURLProtocol.requestHandler` directly as below):

```swift
// MARK: - Session expiry (#76)

func testFetchUserInfo204EmptyBodyThrowsUnauthorized() async {
    MockURLProtocol.requestHandler = { request in
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
        return (response, Data())
    }

    do {
        _ = try await client.fetchUserInfo(cookieHeader: "session=expired")
        XCTFail("Expected APIError.unauthorized")
    } catch APIError.unauthorized {
        // expected — 204 means anonymous/invalid session on /api/auth/me
    } catch {
        XCTFail("Expected APIError.unauthorized, got \(error)")
    }
}

func testFetchUsageSummary200EmptyBodyThrowsUnauthorized() async {
    MockURLProtocol.requestHandler = { request in
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (response, Data())
    }

    do {
        _ = try await client.fetchUsageSummary(cookieHeader: "session=expired")
        XCTFail("Expected APIError.unauthorized")
    } catch APIError.unauthorized {
        // expected — a 2xx empty body can never decode; treat as expiry
    } catch {
        XCTFail("Expected APIError.unauthorized, got \(error)")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CursorAPIClientTests 2>&1 | tail -20`
Expected: both new tests FAIL (currently a 204/empty body falls through to `JSONDecoder` and throws `DecodingError`, which is caught by the generic `catch` branch in the test → "Expected APIError.unauthorized, got dataCorrupted…").

- [ ] **Step 3: Implement**

In `Sources/CursorMeter/CursorAPIClient.swift`, `performRequest`, after the existing `guard (200...299)` block and before `return data`:

```swift
        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        // Cursor answers an invalid/expired session with 204 No Content on
        // /api/auth/me instead of 401 (verified 2026-07-03). Every endpoint
        // here decodes JSON, so a 2xx with an empty body can never be a
        // success — treat it as the session-expiry signal it is (#76).
        if httpResponse.statusCode == 204 || data.isEmpty {
            throw APIError.unauthorized
        }

        return data
```

- [ ] **Step 4: Run the full suite**

Run: `swift test 2>&1 | tail -5`
Expected: all tests PASS (existing decode tests unaffected — they all supply non-empty bodies).

- [ ] **Step 5: Commit**

```bash
git add Sources/CursorMeter/CursorAPIClient.swift Tests/CursorMeterTests/CursorAPIClientTests.swift
git commit -m "[#76] fix: treat 2xx empty-body responses as session expiry"
```

---

### Task 2: Pure error-priority helper — `UsageViewModel.hasUnauthorized`

The decision "does any endpoint's failure mean the session is gone?" must be a pure function so the priority rule is unit-testable without networking.

**Files:**
- Modify: `Sources/CursorMeter/UsageViewModel.swift` (add static helper near the other `nonisolated static` helpers, e.g. next to `fallbackErrorMessage`)
- Test: `Tests/CursorMeterTests/UsageViewModelTests.swift`

**Interfaces:**
- Produces: `nonisolated static func hasUnauthorized(_ errors: [Error?]) -> Bool` on `UsageViewModel`. Task 3 calls it with the three captured refresh failures.

- [ ] **Step 1: Write the failing tests**

Add to `UsageViewModelTests.swift`:

```swift
    // MARK: - hasUnauthorized (#76)

    func testHasUnauthorizedTrueWhenAnyErrorIsUnauthorized() {
        let decodeError = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad"))
        XCTAssertTrue(UsageViewModel.hasUnauthorized([decodeError, APIError.unauthorized, nil]))
    }

    func testHasUnauthorizedFalseForOtherFailures() {
        let decodeError = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad"))
        XCTAssertFalse(UsageViewModel.hasUnauthorized([decodeError, APIError.forbidden, nil]))
    }

    func testHasUnauthorizedFalseWhenAllNil() {
        XCTAssertFalse(UsageViewModel.hasUnauthorized([nil, nil, nil]))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter UsageViewModelTests 2>&1 | tail -10`
Expected: COMPILE ERROR — `hasUnauthorized` does not exist yet. (A compile failure is the failing state for a new symbol.)

- [ ] **Step 3: Implement**

In `UsageViewModel.swift`:

```swift
    /// True when any captured refresh failure is `.unauthorized`. Session
    /// expiry may surface on ANY of the three endpoints (all unofficial, all
    /// respond differently to an invalid cookie), so the 401 check must run
    /// over every result before a decode error from one endpoint can abort
    /// the refresh (#76).
    nonisolated static func hasUnauthorized(_ errors: [Error?]) -> Bool {
        errors.contains { error in
            guard let apiError = error as? APIError else { return false }
            if case .unauthorized = apiError { return true }
            return false
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter UsageViewModelTests 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CursorMeter/UsageViewModel.swift Tests/CursorMeterTests/UsageViewModelTests.swift
git commit -m "[#76] feat: add pure unauthorized-priority helper"
```

---

### Task 3: `refresh()` restructure + expiry notification + test seams

Core fix. Capture all three endpoint calls as `Result`s **while keeping structured concurrency** (`async let` + an async capture helper — unstructured `Task {}` handles would detach the calls from `refresh()`'s cancellation lifecycle; Codex review 2026-07-04), check every one for 401 *first*, and fire a one-shot system notification on the `loggedIn → loginRequired` transition. Adds three injection seams so this is integration-testable without touching the real Keychain or `UNUserNotificationCenter` (which crashes in the SPM test host).

**Files:**
- Modify: `Sources/CursorMeter/UsageViewModel.swift` (init at ~line 190, `apiClient` property at ~line 151, `refresh()` lines 258-280 and the `catch APIError.unauthorized` block at ~line 387, testHook section at ~line 871)
- Modify: `Sources/CursorMeter/NotificationManager.swift` (new `notifySessionExpired`, identifier param on `sendNotification`)
- Test: `Tests/CursorMeterTests/SessionExpiryTests.swift` (new file)

**Interfaces:**
- Consumes: `APIError.unauthorized` behavior from Task 1, `UsageViewModel.hasUnauthorized` from Task 2.
- Produces:
  - `UsageViewModel.init(apiClient: CursorAPIClient = CursorAPIClient())`
  - `@ObservationIgnored internal var keychainDeleteHandler: () throws -> Void` (default: `KeychainStore.deleteCookieHeader`)
  - `@ObservationIgnored internal var sessionExpiredNotifier: (@MainActor () async -> Void)?` (default nil → real `NotificationManager` path)
  - `internal func testHook_setCookieHeader(_ header: String)`
  - `NotificationManager.notifySessionExpired() async`
  - `NotificationManager.sessionExpiredIdentifier`, `.sessionExpiredTitle`, `.sessionExpiredBody` (nonisolated static)

- [ ] **Step 1: Write the failing integration tests**

Create `Tests/CursorMeterTests/SessionExpiryTests.swift`:

```swift
import XCTest
@testable import CursorMeter

/// Integration tests for the #76 regression: an expired session must reach
/// the logout path no matter which endpoint signals it or how the others fail.
///
/// NOTE: `MockURLProtocol.requestHandler` is a single global serving all three
/// parallel requests — keep handlers STATELESS (pure routing on url.path).
/// Counting or ordering assertions inside the handler would be racy.
@MainActor
final class SessionExpiryTests: XCTestCase {

    @MainActor final class NotifySpy {
        var count = 0
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    /// View model wired to MockURLProtocol with all real side effects
    /// (Keychain, UNUserNotificationCenter) stubbed out.
    private func makeViewModel(spy: NotifySpy) -> UsageViewModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let vm = UsageViewModel(apiClient: CursorAPIClient(configuration: config))
        vm.keychainDeleteHandler = {}          // never touch the real Keychain
        vm.sessionExpiredNotifier = { spy.count += 1 }  // UNUserNotificationCenter crashes in SPM tests
        vm.testHook_setCookieHeader("WorkosCursorSessionToken=test")
        vm.authState = .loggedIn
        return vm
    }

    /// The 2026-07-03 incident was auth/me 204 masking the other 401s; Task 1
    /// already converts 204 → unauthorized, so this test uses 200 + an
    /// undecodable body to keep proving the deeper invariant on its own: a
    /// decode failure on one endpoint must NEVER mask another endpoint's 401.
    func test_refresh_userInfoDecodeFailure_summary401_firesLogoutPath() async {
        let spy = NotifySpy()
        let vm = makeViewModel(spy: spy)
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            if url.path == "/api/auth/me" {
                let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (ok, Data("not json".utf8))
            }
            let unauthorized = HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (unauthorized, Data("{\"error\":\"unauthorized\"}".utf8))
        }

        await vm.refresh()

        XCTAssertEqual(vm.authState, .loginRequired)
        XCTAssertNil(vm.usageData)
        XCTAssertEqual(spy.count, 1, "expiry notification fires exactly once on the transition")
    }

    /// /api/auth/me 204 empty body ALONE (Task 1 behavior) must reach the
    /// logout path — the other endpoints fail with 500 here so the 204 is
    /// the only expiry signal in play.
    func test_refresh_authMe204_firesLogoutPath() async {
        let spy = NotifySpy()
        let vm = makeViewModel(spy: spy)
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            if url.path == "/api/auth/me" {
                let noContent = HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)!
                return (noContent, Data())
            }
            let serverError = HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (serverError, Data("oops".utf8))
        }

        await vm.refresh()

        XCTAssertEqual(vm.authState, .loginRequired)
        XCTAssertEqual(spy.count, 1)
    }

    /// userInfo decodes FINE but summary/usage return 401 — the logout path
    /// must not depend on /api/auth/me being the endpoint that fails.
    func test_refresh_userInfoOK_summary401_firesLogoutPath() async {
        let spy = NotifySpy()
        let vm = makeViewModel(spy: spy)
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            if url.path == "/api/auth/me" {
                let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (ok, Data("{\"email\":\"test@test.com\",\"name\":\"Test\"}".utf8))
            }
            let unauthorized = HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (unauthorized, Data())
        }

        await vm.refresh()

        XCTAssertEqual(vm.authState, .loginRequired)
        XCTAssertEqual(spy.count, 1)
    }

    /// A second refresh in the expired state must not re-notify — the cookie
    /// is already cleared, so refresh() early-returns before any API call.
    func test_refresh_repeatedInExpiredState_doesNotRenotify() async {
        let spy = NotifySpy()
        let vm = makeViewModel(spy: spy)
        MockURLProtocol.requestHandler = { request in
            let unauthorized = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (unauthorized, Data())
        }

        await vm.refresh()
        await vm.refresh()

        XCTAssertEqual(vm.authState, .loginRequired)
        XCTAssertEqual(spy.count, 1, "only the loggedIn → loginRequired transition notifies")
    }

    /// Non-401 failures (e.g. server error) must NOT trigger the logout path.
    func test_refresh_serverError_keepsSession() async {
        let spy = NotifySpy()
        let vm = makeViewModel(spy: spy)
        MockURLProtocol.requestHandler = { request in
            let serverError = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (serverError, Data("oops".utf8))
        }

        await vm.refresh()

        XCTAssertEqual(vm.authState, .loggedIn)
        XCTAssertEqual(spy.count, 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SessionExpiryTests 2>&1 | tail -10`
Expected: COMPILE ERROR — `init(apiClient:)`, `keychainDeleteHandler`, `sessionExpiredNotifier`, `testHook_setCookieHeader` don't exist yet.

- [ ] **Step 3: Add the NotificationManager method**

In `Sources/CursorMeter/NotificationManager.swift`:

3a. Change the private `sendNotification` signature to accept an identifier (existing callers unaffected — default keeps current behavior):

```swift
    private func sendNotification(
        title: String,
        body: String,
        identifier: String = UUID().uuidString
    ) async {
```

and use it in the request:

```swift
            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: nil
            )
```

3b. Add the session-expiry API (place after the Usage Jump Notification section):

```swift
    // MARK: - Session Expiry Notification (#76)

    /// Fixed identifier (not UUID-suffixed) so a re-fire replaces any previous
    /// banner instead of stacking duplicates in Notification Center.
    nonisolated static let sessionExpiredIdentifier = "session-expired"
    nonisolated static let sessionExpiredTitle = "Cursor session expired"
    nonisolated static let sessionExpiredBody = "Log in again to keep monitoring your Cursor usage."

    func notifySessionExpired() async {
        await sendNotification(
            title: Self.sessionExpiredTitle,
            body: Self.sessionExpiredBody,
            identifier: Self.sessionExpiredIdentifier
        )
    }
```

- [ ] **Step 4: Add the UsageViewModel seams**

In `Sources/CursorMeter/UsageViewModel.swift`:

4a. Replace the `apiClient` property (~line 151):

```swift
    private let apiClient: CursorAPIClient
```

4b. Replace `init()` (~line 190):

```swift
    init(apiClient: CursorAPIClient = CursorAPIClient()) {
        self.apiClient = apiClient
        loadSettings()
        Task { lastUpdateCheckResult = await UpdateChecker.shared.check() }
    }
```

4c. Add the side-effect seams next to the other private properties (near `notificationManager`, ~line 154). Both exist so tests can run `refresh()` end-to-end without deleting the developer's real session cookie or crashing on `UNUserNotificationCenter.current()` (unavailable in the SPM test host):

```swift
    /// Keychain deletion, injectable for tests — the default deletes the real
    /// `com.cursormeter.session` item, which tests must never touch.
    @ObservationIgnored internal var keychainDeleteHandler: () throws -> Void =
        KeychainStore.deleteCookieHeader

    /// Expiry-notification hook, injectable for tests. nil → real
    /// NotificationManager path (UNUserNotificationCenter crashes in the SPM
    /// test host, so tests always override this).
    @ObservationIgnored internal var sessionExpiredNotifier: (@MainActor () async -> Void)?
```

4d. Add the test hook in the testHook section (~line 871):

```swift
    /// Test-only — seeds the in-memory cookie so refresh() proceeds past the
    /// auth guard without touching the Keychain.
    internal func testHook_setCookieHeader(_ header: String) {
        cachedCookieHeader = header
    }
```

- [ ] **Step 5: Restructure `refresh()`**

5a. Replace the fetch block (lines 258-280, from `async let summaryResult` through `let usage = try? await usageResult`) with:

```swift
            let apiClient = self.apiClient
            // `async let` (not unstructured `Task {}`) keeps the three calls
            // tied to refresh()'s cancellation lifecycle; `capture` turns each
            // outcome into a Result so the expiry check below can inspect ALL
            // failures before any single error aborts the refresh.
            async let summaryCapture = Self.capture { try await apiClient.fetchUsageSummary(cookieHeader: cookieHeader) }
            async let usageCapture = Self.capture { try await apiClient.fetchUsage(cookieHeader: cookieHeader) }
            async let userInfoCapture = Self.capture { try await apiClient.fetchUserInfo(cookieHeader: cookieHeader) }

            // Optimistic weekly fetch — runs in parallel with the primary batch
            // once we have a cached teamId + email from a prior refresh. Saves
            // one round-trip on every subsequent enterprise refresh. First
            // refresh after login falls back to the sequential path inside
            // `refreshWeeklyChart`.
            let optimisticWeekly: Task<[DayUsage], Error>? =
                makeOptimisticWeeklyTask(cookieHeader: cookieHeader)

            // Optimistic hard-limit fetch — same prior-refresh teamId gating as
            // the weekly task. Runs in parallel once a teamId is cached.
            let optimisticHardLimit: Task<HardLimitResponse?, Never>? =
                makeOptimisticHardLimitTask(cookieHeader: cookieHeader)

            let userInfoRes = await userInfoCapture
            let summaryRes = await summaryCapture
            let usageRes = await usageCapture

            // Expiry check runs over ALL results before any decode failure can
            // abort the refresh — the 2026-07-03 incident: /api/auth/me decode
            // error masked usage-summary's 401 and the logout path never fired.
            if Self.hasUnauthorized([userInfoRes.failure, summaryRes.failure, usageRes.failure]) {
                throw APIError.unauthorized
            }

            let userInfo = try userInfoRes.get()
            let summary = try? summaryRes.get()
            let usage = try? usageRes.get()
```

5b. Add the capture helper (near `hasUnauthorized`) and the `Result.failure` convenience at file scope (bottom of `UsageViewModel.swift`):

```swift
    /// Runs `body` and captures its outcome as a Result. Used with `async let`
    /// so the three primary refresh calls stay structured — cancelled together
    /// with refresh() — while still letting the caller inspect every failure
    /// instead of aborting on the first thrown error (#76).
    nonisolated private static func capture<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async -> Result<T, Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }
```

```swift
private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
```

5c. Replace the `catch APIError.unauthorized` block (~line 387):

```swift
        } catch APIError.unauthorized {
            Log.info("Session expired, clearing keychain")
            let wasLoggedIn = (authState == .loggedIn)
            cachedCookieHeader = nil
            do {
                try keychainDeleteHandler()
            } catch {
                Log.error("Keychain delete failed: \(error.localizedDescription)")
            }
            authState = .loginRequired
            usageData = nil
            stopAutoRefresh()
            // Notify only on the loggedIn → loginRequired transition so a
            // manual refresh in the expired state can't re-fire the banner.
            if wasLoggedIn {
                if let sessionExpiredNotifier {
                    await sessionExpiredNotifier()
                } else {
                    await notificationManager.notifySessionExpired()
                }
            }
        } catch APIError.forbidden {
```

- [ ] **Step 6: Run the full suite**

Run: `swift test 2>&1 | tail -5`
Expected: all tests PASS, including the four new `SessionExpiryTests`.

If CI-strictness Sendable warnings appear around the `capture { … }` closures, note that `CursorAPIClient` is an actor (Sendable) and `cookieHeader` is a `String` — both safe to capture; the local `let apiClient = self.apiClient` exists precisely so the `@Sendable` closure never captures the non-Sendable `self`.

- [ ] **Step 7: Commit**

```bash
git add Sources/CursorMeter/UsageViewModel.swift Sources/CursorMeter/NotificationManager.swift Tests/CursorMeterTests/SessionExpiryTests.swift
git commit -m "[#76] fix: no endpoint decode failure can mask another's 401; notify on session expiry"
```

---

### Task 4: Menu bar badge icon + wiring

Mockup candidate C (agreed): the existing "Cursor/Meter" idle logo with a small `warnColor` "!" badge at the top-right, so expired-session and fresh-launch idle stop looking identical. Mockup: `docs/mockup-issue-76-login-icon.html`.

**Files:**
- Modify: `Sources/CursorMeter/CircularProgressIcon.swift` (new method after `idleImage()`, ~line 190)
- Modify: `Sources/CursorMeter/CursorMeterApp.swift:82-84` (`currentRingImage`) and `:234-245` (`observeStatusItem`)
- Test: `Tests/CursorMeterTests/CircularProgressIconTests.swift`

**Interfaces:**
- Produces: `CircularProgressIcon.loginRequiredImage() -> NSImage`. Task 5's manual verification relies on the menu bar wiring here.

- [ ] **Step 1: Write the failing test**

Add to `CircularProgressIconTests.swift`:

```swift
    // MARK: - Login Required Image (#76)

    func testLoginRequiredImageIsWiderThanIdle() {
        // Badge overhangs the top-right corner — canvas must grow so it never clips.
        let idle = CircularProgressIcon.idleImage()
        let badged = CircularProgressIcon.loginRequiredImage()
        XCTAssertGreaterThan(badged.size.width, idle.size.width)
        XCTAssertEqual(badged.size.height, idle.size.height)
        XCTAssertFalse(badged.isTemplate)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CircularProgressIconTests 2>&1 | tail -10`
Expected: COMPILE ERROR — `loginRequiredImage` does not exist.

- [ ] **Step 3: Implement the image**

In `CircularProgressIcon.swift`, after `idleImage()`:

```swift
    /// Idle logo + warning badge — shown when the stored session has expired
    /// and the user must log in again. Distinct from `idleImage()` so the
    /// expired state doesn't look identical to fresh-launch idle (#76,
    /// docs/mockup-issue-76-login-icon.html candidate C).
    ///
    /// Composites the existing `idleImage()` rather than redrawing the logo —
    /// the drawing handler re-runs at render time, so `labelColor` inside the
    /// nested image stays appearance-dynamic.
    static func loginRequiredImage() -> NSImage {
        let logo = idleImage()
        let badgeRadius: CGFloat = 4
        // Badge overhangs the logo's top-right corner; widen the canvas so it never clips.
        let size = NSSize(width: logo.size.width + badgeRadius, height: logo.size.height)

        let image = NSImage(size: size, flipped: false) { _ in
            logo.draw(
                at: .zero, from: .zero, operation: .sourceOver, fraction: 1)

            // Warning badge, top-right. Black "!" on warnColor reads in both
            // light and dark menu bars.
            let badgeCenter = NSPoint(x: size.width - badgeRadius, y: size.height - badgeRadius)
            let badgeRect = NSRect(
                x: badgeCenter.x - badgeRadius, y: badgeCenter.y - badgeRadius,
                width: badgeRadius * 2, height: badgeRadius * 2)
            warnColor.setFill()
            NSBezierPath(ovalIn: badgeRect).fill()

            let bang = NSAttributedString(string: "!", attributes: [
                .font: NSFont.systemFont(ofSize: 7, weight: .heavy),
                .foregroundColor: NSColor.black,
            ])
            let bangSize = bang.size()
            bang.draw(at: NSPoint(
                x: badgeCenter.x - bangSize.width / 2,
                y: badgeCenter.y - bangSize.height / 2))
            return true
        }
        image.isTemplate = false
        return image
    }
```

- [ ] **Step 4: Wire the menu bar**

In `CursorMeterApp.swift`:

4a. `currentRingImage()` (~line 82) — branch the no-data fallback:

```swift
        guard let data = viewModel.usageData else {
            return viewModel.authState == .loginRequired
                ? CircularProgressIcon.loginRequiredImage()
                : CircularProgressIcon.idleImage()
        }
```

4b. `observeStatusItem()` (~line 235) — the tracking block must read `authState` or the icon won't refresh on the expiry transition:

```swift
        withObservationTracking {
            _ = viewModel.usageData
            _ = viewModel.menuBarDisplayMode
            _ = viewModel.authState
        } onChange: { [weak self] in
```

- [ ] **Step 5: Run the full suite**

Run: `swift test 2>&1 | tail -5`
Expected: all tests PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/CursorMeter/CircularProgressIcon.swift Sources/CursorMeter/CursorMeterApp.swift Tests/CursorMeterTests/CircularProgressIconTests.swift
git commit -m "[#76] feat: warning-badged menu bar icon for expired sessions"
```

---

### Task 5: Popover expired-session state

Replace the bare "Not logged in" label with an explanation + prominent Log In button when `authState == .loginRequired`. Click behavior on the status item stays conventional (opens the popover). Pure AppKit — no unit test possible; verified manually in Task 6.

**Files:**
- Modify: `Sources/CursorMeter/MenuBarView.swift` (`applyStatus()` at ~line 501, new helper + action below it)

**Interfaces:**
- Consumes: `viewModel.authState`, existing `onLogin` closure (already a stored property, line 10).
- Produces: UI behavior only.

- [ ] **Step 1: Implement the branch**

In `applyStatus()` (~line 501), after the arranged-subview cleanup loop and before the `let label` line, insert:

```swift
        if viewModel.authState == .loginRequired {
            applyLoginRequiredStatus()
            return
        }
```

- [ ] **Step 2: Add the helper and action**

Below `applyStatus()`:

```swift
    /// Expired-session state: explanation + prominent login action instead of
    /// the bare "Not logged in" label, so the user learns *why* data is gone
    /// and how to recover without hunting for the small auth row (#76).
    private func applyLoginRequiredStatus() {
        statusStack.orientation = .vertical
        statusStack.alignment   = .centerX
        statusStack.spacing     = 6

        let title = NSTextField(labelWithString: "⚠️ Session expired")
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        let body = NSTextField(wrappingLabelWithString: "Log in again to see your Cursor usage.")
        body.font      = NSFont.systemFont(ofSize: 11)
        body.textColor = NSColor.secondaryLabelColor
        body.alignment = .center
        body.preferredMaxLayoutWidth = 220

        let loginButton = NSButton(
            title: "Log In",
            target: self,
            action: #selector(loginRequiredLoginTapped))
        loginButton.bezelStyle    = .rounded
        loginButton.keyEquivalent = "\r"

        statusStack.addArrangedSubview(title)
        statusStack.addArrangedSubview(body)
        statusStack.addArrangedSubview(loginButton)
    }

    @objc private func loginRequiredLoginTapped() {
        onLogin()
    }
```

Note: the generic path keeps working with whatever orientation is set — it only ever adds a single label — so no reset is needed there. If the popover looks off in verification, set `statusStack.orientation = .vertical` unconditionally at the top of `applyStatus()` instead.

- [ ] **Step 3: Build and run existing tests**

Run: `swift build && swift test 2>&1 | tail -5`
Expected: builds clean, all tests PASS (no behavior change outside the new branch).

- [ ] **Step 4: Commit**

```bash
git add Sources/CursorMeter/MenuBarView.swift
git commit -m "[#76] feat: expired-session popover state with prominent login action"
```

---

### Task 6: End-to-end manual verification + merge + close-out

The awareness layer (notification banner, badge icon, popover) can only be verified against the real app. **Warning:** this procedure overwrites the developer's stored session cookie — re-login afterwards is expected and part of the test.

- [ ] **Step 1: Reinstall the app** (sequence from CLAUDE.md — a running binary can't be overwritten)

```bash
pkill -9 -x CursorMeter
rm -rf /Applications/CursorMeter.app
bash Scripts/package_app.sh
cp -r CursorMeter.app /Applications/
open /Applications/CursorMeter.app
```

- [ ] **Step 2: Log in and confirm normal operation** (pie icon shows in the menu bar).

- [ ] **Step 3: Simulate expiry** — overwrite the Keychain cookie with an invalid value, then relaunch so `checkExistingSession()` loads it:

```bash
security add-generic-password -U -s com.cursormeter.session -a cursor-cookie-header -w "WorkosCursorSessionToken=INVALID"
pkill -9 -x CursorMeter
open /Applications/CursorMeter.app
```

- [ ] **Step 4: Verify all three signals within one refresh cycle:**
  1. System notification "Cursor session expired" appears exactly once.
  2. Menu bar icon shows the badged Cursor/Meter logo (not the plain idle logo).
  3. Clicking the icon opens the popover showing "⚠️ Session expired" + Log In button; the button opens the login window.
  4. Log in again → pie icon returns, data refreshes. Confirm in the unified log that auto-refresh stopped while expired:

```bash
/usr/bin/log show --predicate 'subsystem == "com.cursormeter"' --info --debug --last 10m | grep -i "session\|refresh"
```

- [ ] **Step 5: Merge and push** (solo workflow — direct merge, no PR):

```bash
git checkout main && git merge --no-ff fix/76-session-expiry -m "Merge fix/76-session-expiry (#76)" && git push origin main
git branch -d fix/76-session-expiry
```

- [ ] **Step 6: File follow-up issues and close #76**

Create two issues (English, matching #76's style):
- `feat: surface stale-data indicator after N consecutive refresh failures` — body from #76 plan item 3 (generic-catch skips `errorMessage` when `usageData != nil`; add consecutive-failure counter, threshold ~5).
- `chore: migrate API base URLs from www.cursor.com to cursor.com` — body from #76 plan item 4 (308 redirect costs one round-trip per call; not a correctness issue).

Then close #76 with a comment linking the merge commit and both follow-ups, and per CLAUDE.md run:

```bash
gh issue list --state open
```

and show the remaining issues to the user.
