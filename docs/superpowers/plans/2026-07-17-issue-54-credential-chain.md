# IDE Credential Chain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-source credentials per refresh from the Cursor IDE's `state.vscdb` (primary) with the existing WebView-captured cookie as fallback, per spec `docs/superpowers/specs/2026-07-16-issue-54-credential-chain-design.md` (rev 2, issue #54).

**Architecture:** New `CursorAppAuthReader` (read-only SQLite + JWT decode, pure helpers). `UsageViewModel.refresh()` splits into a chain resolver + non-recursive `runRefreshAttempt(cookieHeader:)`; IDE 401 falls through to the captured cookie once; logout persists an `ideAuthSuppressed` flag; account switches trigger a full per-account reset. Production wires the reader in `CursorMeterApp` (nil-default seam, #83 pattern).

**Tech Stack:** Swift 6, AppKit, SQLite3 (macOS SDK), XCTest + MockURLProtocol. Zero external dependencies.

## Global Constraints

- Copy (exact): status line `"Sign in to the Cursor IDE to connect automatically."`; buttons `"Connect Cursor IDE"` (primary) / `"Log in with Browser"` (secondary); settings line `Auth: Cursor IDE` / `Auth: Browser login` / `Auth: —`.
- Reader: `SQLITE_OPEN_READONLY`, `busy_timeout` 250ms, no stored handle, key `cursorAuth/accessToken` only, never `refreshToken`; validity gate `exp > now + 60s`; invoked off MainActor via `Task.detached`.
- Seam default nil: `ideCredentialProvider: (@Sendable () -> IDECredential?)? = nil`; production wiring in `applicationDidFinishLaunching` BEFORE `checkExistingSession()`.
- Tests: no real Keychain / UNUserNotificationCenter / real `state.vscdb`. Fixture DBs in per-test temp dirs.
- Token values never logged (header strings pass through existing LogRedactor policy).
- Commit format: `[#54] <type>: description`.

---

### Task 1: `CursorAppAuthReader` — pure helpers + fixture-DB reader

**Files:**
- Create: `Sources/CursorMeter/CursorAppAuthReader.swift`
- Test: `Tests/CursorMeterTests/CursorAppAuthReaderTests.swift` (create)

**Interfaces:**
- Produces: `struct IDECredential: Sendable, Equatable { let cookieHeader: String; let expiresAt: Date }`; `struct CursorAppAuthReader: Sendable { let dbPath: String; init(dbPath: String = <real path>); func read(now: Date = Date()) -> IDECredential? }`; `nonisolated static` helpers `parseJWTClaims(_:) -> (sub: String, exp: Date)?`, `userID(fromSub:) -> String?`, `makeCookieHeader(userID:jwt:) -> String`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import SQLite3
@testable import CursorMeter

final class CursorAppAuthReaderTests: XCTestCase {

    // MARK: - Fixtures

    /// Fake JWT: valid base64url payload, garbage header/signature (parse only reads payload).
    private func makeJWT(sub: String = "auth0|user_01ABC", exp: TimeInterval) -> String {
        let payload: [String: Any] = ["sub": sub, "exp": Int(exp)]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let b64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJIUzI1NiJ9.\(b64).sig"
    }

    /// Fixture state.vscdb replica in a fresh temp dir. token == nil → row absent.
    private func makeFixtureDB(token: String?) -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vscdb-fixture-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("state.vscdb").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)", nil, nil, nil)
        if let token {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO ItemTable (key, value) VALUES ('cursorAuth/accessToken', ?)", -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, token, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
            sqlite3_finalize(stmt)
        }
        sqlite3_close(db)
        return path
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Pure helpers

    func testParseJWTClaimsValid() {
        let jwt = makeJWT(sub: "auth0|user_42", exp: now.timeIntervalSince1970 + 3600)
        let claims = CursorAppAuthReader.parseJWTClaims(jwt)
        XCTAssertEqual(claims?.sub, "auth0|user_42")
        XCTAssertEqual(claims?.exp.timeIntervalSince1970 ?? 0,
                       now.timeIntervalSince1970 + 3600, accuracy: 1)
    }

    func testParseJWTClaimsMalformed() {
        XCTAssertNil(CursorAppAuthReader.parseJWTClaims(""))
        XCTAssertNil(CursorAppAuthReader.parseJWTClaims("only.two"))
        XCTAssertNil(CursorAppAuthReader.parseJWTClaims("a.!!!notbase64!!!.c"))
    }

    func testUserIDFromSub() {
        XCTAssertEqual(CursorAppAuthReader.userID(fromSub: "auth0|user_42"), "user_42")
        XCTAssertEqual(CursorAppAuthReader.userID(fromSub: "a|b|user_9"), "user_9")
        XCTAssertNil(CursorAppAuthReader.userID(fromSub: "nopipe"))
    }

    func testMakeCookieHeader() {
        XCTAssertEqual(
            CursorAppAuthReader.makeCookieHeader(userID: "user_42", jwt: "J.W.T"),
            "WorkosCursorSessionToken=user_42%3A%3AJ.W.T"
        )
    }

    // MARK: - Reader

    func testReadValidToken() {
        let jwt = makeJWT(exp: now.timeIntervalSince1970 + 7200)
        let reader = CursorAppAuthReader(dbPath: makeFixtureDB(token: jwt))
        let cred = reader.read(now: now)
        XCTAssertEqual(cred?.cookieHeader, "WorkosCursorSessionToken=user_01ABC%3A%3A\(jwt)")
        XCTAssertEqual(cred?.expiresAt.timeIntervalSince1970 ?? 0,
                       now.timeIntervalSince1970 + 7200, accuracy: 1)
    }

    func testReadRejectsNearExpiredToken() {
        let jwt = makeJWT(exp: now.timeIntervalSince1970 + 30)  // < 60s guard
        let reader = CursorAppAuthReader(dbPath: makeFixtureDB(token: jwt))
        XCTAssertNil(reader.read(now: now))
    }

    func testReadMissingKey() {
        XCTAssertNil(CursorAppAuthReader(dbPath: makeFixtureDB(token: nil)).read(now: now))
    }

    func testReadMissingFile() {
        XCTAssertNil(CursorAppAuthReader(dbPath: "/nonexistent/state.vscdb").read(now: now))
    }

    func testReadMalformedToken() {
        XCTAssertNil(CursorAppAuthReader(dbPath: makeFixtureDB(token: "not-a-jwt")).read(now: now))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter CursorAppAuthReaderTests 2>&1 | grep -m2 "error:"`
Expected: compile error — `CursorAppAuthReader` not found.

- [ ] **Step 3: Implement `Sources/CursorMeter/CursorAppAuthReader.swift`**

```swift
import Foundation
import SQLite3

/// Credential synthesized from the Cursor IDE's own auth state (#54).
struct IDECredential: Sendable, Equatable {
    let cookieHeader: String   // "WorkosCursorSessionToken=<id>%3A%3A<jwt>"
    let expiresAt: Date
}

/// Reads the Cursor IDE's access token from its local state DB and synthesizes
/// the dashboard cookie header (CodexBar's production-proven pattern). The IDE
/// refreshes this token itself, so re-reading per refresh yields a credential
/// that tracks the IDE's live session. Read-only; never touches refreshToken.
///
/// Concurrency: no stored sqlite3 handle — open/query/close within a single
/// read() call, so plain Sendable holds. busy_timeout can block ~250ms;
/// callers invoke off the MainActor.
struct CursorAppAuthReader: Sendable {
    let dbPath: String

    init(dbPath: String = NSHomeDirectory()
        + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb") {
        self.dbPath = dbPath
    }

    func read(now: Date = Date()) -> IDECredential? {
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'",
            -1, &stmt, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cString = sqlite3_column_text(stmt, 0)
        else { return nil }
        // Value may be stored as a bare string or JSON-quoted.
        let jwt = String(cString: cString).trimmingCharacters(in: CharacterSet(charactersIn: "\""))

        guard let claims = Self.parseJWTClaims(jwt),
              claims.exp > now.addingTimeInterval(60),
              let userID = Self.userID(fromSub: claims.sub)
        else { return nil }

        return IDECredential(
            cookieHeader: Self.makeCookieHeader(userID: userID, jwt: jwt),
            expiresAt: claims.exp
        )
    }

    // MARK: - Pure helpers

    nonisolated static func parseJWTClaims(_ jwt: String) -> (sub: String, exp: Date)? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = json["sub"] as? String,
              let exp = json["exp"] as? TimeInterval
        else { return nil }
        return (sub, Date(timeIntervalSince1970: exp))
    }

    /// WorkOS subs look like "auth0|user_xxx" — the dashboard cookie wants the
    /// part after the last pipe.
    nonisolated static func userID(fromSub sub: String) -> String? {
        guard let idx = sub.lastIndex(of: "|"), idx < sub.index(before: sub.endIndex)
        else { return nil }
        return String(sub[sub.index(after: idx)...])
    }

    nonisolated static func makeCookieHeader(userID: String, jwt: String) -> String {
        "WorkosCursorSessionToken=\(userID)%3A%3A\(jwt)"
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter CursorAppAuthReaderTests 2>&1 | grep -E "Executed .* tests, with"`
Expected: 9 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/CursorMeter/CursorAppAuthReader.swift Tests/CursorMeterTests/CursorAppAuthReaderTests.swift
git commit -m "[#54] feat: CursorAppAuthReader — IDE token from state.vscdb (read-only)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Behavior-preserving refactor — extract `runRefreshAttempt`

**Files:**
- Modify: `Sources/CursorMeter/UsageViewModel.swift:329-496` (`refresh()`)

**Interfaces:**
- Produces: `private func runRefreshAttempt(cookieHeader: String) async throws` — the entire current `do`-block body of `refresh()` (the batch, success processing, threshold notifications) moved verbatim; throws instead of catching. `private func handleCapturedCookieExpiry() async` — the current `catch APIError.unauthorized` block body verbatim. `private func handleRefreshError(_ error: Error) async` — the current `catch APIError.forbidden` + generic `catch` bodies merged with an `if case APIError.forbidden` split, preserving exact behavior (errorMessage strings, `consecutiveFailureCount`, `maybeNotifyRefreshFailing`, network-retry scheduling).
- No behavior change: `refresh()` becomes

```swift
    func refresh() async {
        guard !isRefreshing else { return }
        guard let cookieHeader = cachedCookieHeader else {
            authState = .loginRequired
            return
        }
        isRefreshing = true
        isLoading = true
        errorMessage = nil
        do {
            try await runRefreshAttempt(cookieHeader: cookieHeader)
        } catch APIError.unauthorized {
            await handleCapturedCookieExpiry()
        } catch {
            await handleRefreshError(error)
        }
        isLoading = false
        isRefreshing = false
    }
```

- [ ] **Step 1: Perform the extraction** (move code, do not rewrite it; keep all comments)
- [ ] **Step 2: Full suite**

Run: `swift test 2>&1 | grep -E "Executed .* tests, with" | tail -1`
Expected: same test count as before task, 0 failures (pure refactor).

- [ ] **Step 3: Commit**

```bash
git add Sources/CursorMeter/UsageViewModel.swift
git commit -m "[#54] refactor: extract runRefreshAttempt/error handlers from refresh()

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Credential chain + seam + `activeAuthSource` + 401 fallthrough

**Files:**
- Modify: `Sources/CursorMeter/UsageViewModel.swift` (refresh() from Task 2; seams near `sessionExpiredNotifier`; observables near `authState`)
- Test: `Tests/CursorMeterTests/CredentialChainTests.swift` (create)

**Interfaces:**
- Consumes: `IDECredential` (Task 1), `runRefreshAttempt`/handlers (Task 2).
- Produces:

```swift
enum AuthSource: Sendable, Equatable { case cursorIDE, browserLogin }
// observable:
var activeAuthSource: AuthSource?          // nil when logged out
// seam (nil default; production wires in CursorMeterApp):
@ObservationIgnored internal var ideCredentialProvider: (@Sendable () -> IDECredential?)?
```

- [ ] **Step 1: Write the failing tests**

```swift
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

    private static let ideCredential = IDECredential(
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
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter CredentialChainTests 2>&1 | grep -m2 "error:"`
Expected: compile error — `ideCredentialProvider` / `activeAuthSource` not defined.

- [ ] **Step 3: Implement in `UsageViewModel`**

Add near `authState`:

```swift
    /// Which credential source authenticated the most recent successful
    /// refresh (#54). nil while logged out. Read by the settings window.
    var activeAuthSource: AuthSource?
```

Add file-scope (near `AuthState`):

```swift
/// Credential origin for the active session (#54).
enum AuthSource: Sendable, Equatable {
    case cursorIDE
    case browserLogin
}
```

Add seam (after `refreshFailingNotifier`):

```swift
    /// IDE credential source (#54), nil by default so the SPM test host can
    /// never read the developer's real state.vscdb; production wires the real
    /// CursorAppAuthReader in CursorMeterApp (same pattern as the #83 seams).
    @ObservationIgnored internal var ideCredentialProvider: (@Sendable () -> IDECredential?)?
```

Replace `refresh()` (from Task 2) with the chain version:

```swift
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            isRefreshing = false
        }

        // Chain step 1: IDE credential (read off-main; busy_timeout may block).
        if let provider = ideCredentialProvider, !ideAuthSuppressed,
           let ide = await Task.detached(operation: { provider() }).value {
            do {
                try await runRefreshAttempt(cookieHeader: ide.cookieHeader)
                authState = .loggedIn
                activeAuthSource = .cursorIDE
                return
            } catch APIError.unauthorized {
                // Fall through to the captured cookie. The IDE credential is
                // unrelated to it — never clear keychain or notify here.
                Log.error("IDE credential rejected (401) — falling back to captured cookie")
            } catch {
                await handleRefreshError(error)
                return
            }
        }

        // Chain step 2: captured cookie (existing behavior).
        guard let cookieHeader = cachedCookieHeader else {
            authState = .loginRequired
            activeAuthSource = nil
            return
        }
        do {
            try await runRefreshAttempt(cookieHeader: cookieHeader)
            authState = .loggedIn
            activeAuthSource = .browserLogin
        } catch APIError.unauthorized {
            activeAuthSource = nil
            await handleCapturedCookieExpiry()
        } catch {
            await handleRefreshError(error)
        }
    }
```

(`ideAuthSuppressed` arrives in Task 4 — for this task declare it as
`private(set) var ideAuthSuppressed = false` without persistence so the build
compiles; Task 4 completes it.)

Note: `handleCapturedCookieExpiry` already sets `authState = .loginRequired`.
Setting `authState = .loggedIn` on success is new but preserves invariants
(previously success was only reachable when startSession had set it).

- [ ] **Step 4: Full suite** (not just the new file — the chain touches every refresh test)

Run: `swift test 2>&1 | grep -E "Executed .* tests, with" | tail -1`
Expected: all green, including SessionExpiryTests/StaleDataTests (provider nil → unchanged path).

- [ ] **Step 5: Commit**

```bash
git add Sources/CursorMeter/UsageViewModel.swift Tests/CursorMeterTests/CredentialChainTests.swift
git commit -m "[#54] feat: IDE-first credential chain with single 401 fallthrough

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Logout suppression, `connectViaIDE`, launch path, account-switch reset

**Files:**
- Modify: `Sources/CursorMeter/UsageViewModel.swift` (SettingsKey; `loadSettings`; `logout()`; `onLoginSuccess`; `checkExistingSession`; `runRefreshAttempt` account check)
- Test: `Tests/CursorMeterTests/CredentialChainTests.swift` (extend)

**Interfaces:**
- Consumes: chain from Task 3.
- Produces: `private(set) var ideAuthSuppressed: Bool` (persisted, key `ideAuthSuppressed`), `func connectViaIDE()`, account-identity tracking `@ObservationIgnored private var lastAccountEmail: String?`.

- [ ] **Step 1: Write the failing tests** (append to `CredentialChainTests`; UserDefaults key cleaned in setUp/tearDown):

```swift
    private static let suppressedKey = "ideAuthSuppressed"
    // in setUp() and tearDown(): UserDefaults.standard.removeObject(forKey: Self.suppressedKey)

    func testLogoutSuppressesIDESource() async {
        let vm = makeViewModel()
        vm.ideCredentialProvider = { Self.ideCredential }
        let box = CookieBox()
        MockURLProtocol.requestHandler = Self.successHandler { box.append($0) }

        await vm.refresh()
        XCTAssertEqual(vm.authState, .loggedIn)

        vm.logout()
        XCTAssertTrue(vm.ideAuthSuppressed)
        XCTAssertEqual(vm.authState, .loggedOut)
        XCTAssertNil(vm.activeAuthSource)

        let callsBefore = box.all.count
        await vm.refresh()
        XCTAssertEqual(vm.authState, .loginRequired, "suppressed IDE + no cookie = logged out")
        XCTAssertEqual(box.all.count, callsBefore, "no API call while suppressed")
    }

    func testConnectViaIDEClearsSuppressionAndRefreshes() async {
        let vm = makeViewModel()
        vm.ideCredentialProvider = { Self.ideCredential }
        MockURLProtocol.requestHandler = Self.successHandler { _ in }

        vm.logout()
        vm.connectViaIDE()
        XCTAssertFalse(vm.ideAuthSuppressed)
        // connectViaIDE triggers an async refresh via startSession; drive one directly:
        await vm.refresh()
        XCTAssertEqual(vm.activeAuthSource, .cursorIDE)
    }

    func testBrowserLoginClearsSuppression() {
        let vm = makeViewModel()
        MockURLProtocol.requestHandler = Self.successHandler { _ in }
        vm.logout()
        XCTAssertTrue(vm.ideAuthSuppressed)
        vm.onLoginSuccess(cookieHeader: "WorkosCursorSessionToken=fresh")
        XCTAssertFalse(vm.ideAuthSuppressed, "explicit reconnect intent clears suppression")
    }

    func testAccountSwitchResetsPerAccountState() async {
        let vm = makeViewModel()
        vm.ideCredentialProvider = { Self.ideCredential }
        // First refresh as alice.
        MockURLProtocol.requestHandler = Self.emailHandler("alice@t.com")
        await vm.refresh()
        XCTAssertEqual(vm.usageData?.email, "alice@t.com")
        vm.testHook_seedWeeklyData([DayUsage(date: Date(), requests: 1)])

        // Second refresh as bob — weekly cache must not survive the switch.
        MockURLProtocol.requestHandler = Self.emailHandler("bob@t.com")
        await vm.refresh()
        XCTAssertEqual(vm.usageData?.email, "bob@t.com")
        XCTAssertNil(vm.weeklyData, "per-account state reset on account switch")
    }
```

Add fixture (same class):

```swift
    /// successHandler variant with a parameterized auth/me email.
    private static func emailHandler(_ email: String) -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        let base = successHandler { _ in }
        return { request in
            if request.url!.path == "/api/auth/me" {
                let ok = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (ok, Data("{\"email\":\"\(email)\",\"name\":\"T\"}".utf8))
            }
            return try base(request)
        }
    }
```

Also add the test hook to `UsageViewModel` (with the implementation below):
`internal func testHook_seedWeeklyData(_ data: [DayUsage]) { weeklyData = data }`
(Check `DayUsage`'s memberwise init field names in `WeeklyUsageModels.swift` and
adjust the test literal accordingly.)

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter CredentialChainTests 2>&1 | grep -m2 "error:"`
Expected: compile error — `connectViaIDE` / `ideAuthSuppressed` persistence missing.

- [ ] **Step 3: Implement**

SettingsKey: add `case ideAuthSuppressed`. Replace Task 3's stub with:

```swift
    /// True after an explicit Log Out — the IDE source stays disabled until
    /// the user reconnects (Connect Cursor IDE / browser login), otherwise
    /// logout would silently resurrect on the next refresh (#54).
    private(set) var ideAuthSuppressed: Bool = false
```

`loadSettings()`: `if let val = defaults.object(for: .ideAuthSuppressed) as? Bool { ideAuthSuppressed = val }`

`logout()` additions (top of the method):

```swift
        ideAuthSuppressed = true
        UserDefaults.standard.set(true, for: .ideAuthSuppressed)
        activeAuthSource = nil
        lastAccountEmail = nil
```

New method (near `onLoginSuccess`):

```swift
    /// Re-enables the IDE credential source after a logout and starts a
    /// session; the chain resolves the actual credential on refresh (#54).
    func connectViaIDE() {
        ideAuthSuppressed = false
        UserDefaults.standard.set(false, for: .ideAuthSuppressed)
        startSession()
    }
```

`onLoginSuccess` additions (before `startSession()`):

```swift
        ideAuthSuppressed = false
        UserDefaults.standard.set(false, for: .ideAuthSuppressed)
```

`checkExistingSession()` — start a session when the IDE source could carry it:

```swift
    func checkExistingSession() {
        do {
            if let header = try KeychainStore.loadCookieHeader() {
                cachedCookieHeader = header
                startSession()
                return
            }
        } catch {
            Log.error("Failed to load keychain: \(error)")
        }
        // No captured cookie — the IDE source may still authenticate (#54).
        if !ideAuthSuppressed, ideCredentialProvider != nil {
            startSession()
        }
    }
```

Account-switch reset — in `runRefreshAttempt`, immediately after
`let userInfo = try userInfoRes.get()`:

```swift
            resetIfAccountSwitched(newEmail: userInfo.email)
```

and the helper + identity var:

```swift
    /// Identity of the account behind the last successful refresh; the IDE
    /// credential can silently belong to a different account (#54).
    @ObservationIgnored private var lastAccountEmail: String?

    private func resetIfAccountSwitched(newEmail: String?) {
        guard let newEmail else { return }
        defer { lastAccountEmail = newEmail }
        guard let previous = lastAccountEmail, previous != newEmail else { return }
        Log.error("Account switched (\(LogRedactor.redactEmail(previous)) → \(LogRedactor.redactEmail(newEmail))) — resetting per-account state")
        resetPerAccountState()
        notificationManager.resetNotifications()
        previousPlanUsedCents = nil
        previousRequestsUsed = nil
        previousServerPercent = nil
        previousOnDemandUsedCents = nil
        previousMode = nil
        lastJump = nil
    }
```

(Check `LogRedactor` for an email-redaction helper; if none exists, log without
emails: `"Account switched — resetting per-account state"`.)

- [ ] **Step 4: Full suite**

Run: `swift test 2>&1 | grep -E "Executed .* tests, with" | tail -1`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/CursorMeter/UsageViewModel.swift Tests/CursorMeterTests/CredentialChainTests.swift
git commit -m "[#54] feat: logout suppression, connectViaIDE, account-switch reset

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: UI — popover status/buttons, settings auth line, app wiring

**Files:**
- Modify: `Sources/CursorMeter/MenuBarView.swift` (`applyStatus` ~528, `applyLoginRequiredStatus` ~566, `rebuildAuthButton` ~394)
- Modify: `Sources/CursorMeter/SettingsViewController.swift` (property, `updateUI`, `makeUpdatesSection`)
- Modify: `Sources/CursorMeter/CursorMeterApp.swift` (`applicationDidFinishLaunching`, observation blocks)

**Interfaces:**
- Consumes: `viewModel.activeAuthSource`, `viewModel.connectViaIDE()`, `CursorAppAuthReader`.
- No new unit tests (thin AppKit glue over tested view-model methods); verified by build + live check in Task 7.

- [ ] **Step 1: MenuBarView** — `applyLoginRequiredStatus()` becomes the chain-aware guidance (also reused for `.loggedOut`):

```swift
    /// Logged-out / expired state: IDE-first guidance (#54) with the browser
    /// login as the secondary path (#76 kept the prominent recovery layout).
    private func applyLoginRequiredStatus() {
        statusStack.orientation = .vertical
        statusStack.alignment   = .centerX
        statusStack.spacing     = 6

        let title = NSTextField(labelWithString:
            viewModel.authState == .loginRequired ? "⚠️ Session expired" : "Not connected")
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        let body = NSTextField(wrappingLabelWithString: "Sign in to the Cursor IDE to connect automatically.")
        body.font      = NSFont.systemFont(ofSize: 11)
        body.textColor = NSColor.secondaryLabelColor
        body.alignment = .center
        body.preferredMaxLayoutWidth = 220

        let connectButton = NSButton(
            title: "Connect Cursor IDE",
            target: self,
            action: #selector(connectIDETapped))
        connectButton.bezelStyle    = .rounded
        connectButton.keyEquivalent = "\r"

        let browserButton = NSButton(
            title: "Log in with Browser",
            target: self,
            action: #selector(loginRequiredLoginTapped))
        browserButton.bezelStyle = .rounded

        statusStack.addArrangedSubview(title)
        statusStack.addArrangedSubview(body)
        statusStack.addArrangedSubview(connectButton)
        statusStack.addArrangedSubview(browserButton)
    }

    @objc private func connectIDETapped() {
        viewModel.connectViaIDE()
    }
```

In `applyStatus()`, route `.loggedOut` to the same layout — replace the `else { label.stringValue = "Not logged in" ... }` terminal branch by extending the early guard:

```swift
        if viewModel.authState == .loginRequired
            || (viewModel.authState == .loggedOut && !viewModel.isLoading && viewModel.errorMessage == nil) {
            applyLoginRequiredStatus()
            return
        }
```

(and delete the now-unreachable `"Not logged in"` else-branch, keeping Loading/Error branches).

In `rebuildAuthButton()`, relabel the logged-out row: `title = "Log in with Browser..."` (icon unchanged).

- [ ] **Step 2: SettingsViewController** — add property `private var authSourceLabel = NSTextField(labelWithString: "")`; in `makeUpdatesSection()` add the label under the existing update-status row (`authSourceLabel.font = NSFont.systemFont(ofSize: 10); authSourceLabel.textColor = .secondaryLabelColor`, appended to that section's stack); in `updateUI()` add:

```swift
        authSourceLabel.stringValue = {
            switch viewModel.activeAuthSource {
            case .cursorIDE:    return "Auth: Cursor IDE"
            case .browserLogin: return "Auth: Browser login"
            case nil:           return "Auth: —"
            }
        }()
```

- [ ] **Step 3: CursorMeterApp** — in `applicationDidFinishLaunching`, immediately after the #83 notifier wiring (and before `viewModel.checkExistingSession()`):

```swift
        // #54: IDE credential source. Wired here (nil default in the view
        // model) so the SPM test host can never read the real state.vscdb.
        let authReader = CursorAppAuthReader()
        viewModel.ideCredentialProvider = { authReader.read() }
```

Add the settings observation block (next to `observePopover`, self-re-arming like the others) and call it from `applicationDidFinishLaunching` alongside `observePopover()`:

```swift
    // #54: the settings window is pull-based; this is its only push signal.
    private func observeSettings() {
        withObservationTracking {
            _ = viewModel.activeAuthSource
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                (self.settingsWindow?.contentViewController as? SettingsViewController)?.updateUI()
                self.observeSettings()
            }
        }
    }
```

- [ ] **Step 4: Build + full suite**

Run: `swift build 2>&1 | tail -2 && swift test 2>&1 | grep -E "Executed .* tests, with" | tail -1`
Expected: build succeeds, all tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/CursorMeter/MenuBarView.swift Sources/CursorMeter/SettingsViewController.swift Sources/CursorMeter/CursorMeterApp.swift
git commit -m "[#54] feat: IDE-first login UX, settings auth line, reader wiring

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Docs — SECURITY.md + README

**Files:**
- Modify: `SECURITY.md` (new section), `README.md` (onboarding section)

- [ ] **Step 1: SECURITY.md** — append a section titled `## Cursor IDE credential reuse (#54)` stating exactly: what is read (`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`, single key `cursorAuth/accessToken`), how (read-only SQLite connection, 250ms busy timeout, opened and closed per read), what is never read (`cursorAuth/refreshToken` or any other key), that the synthesized header is never logged (LogRedactor policy), and the threat model note (the user's own credential on the user's own machine — same trust boundary as the existing Keychain-stored cookie).
- [ ] **Step 2: README.md** — rewrite the login/onboarding paragraph: primary path "Cursor IDE에 로그인되어 있으면 자동 연결" (README is Korean per project language rules — check existing README language and match), secondary "브라우저 로그인". Mention logout semantics (로그아웃하면 IDE 자동 연결도 중지, 다시 연결 버튼으로 재개).
- [ ] **Step 3: Commit**

```bash
git add SECURITY.md README.md
git commit -m "[#54] docs: security note for state.vscdb read; IDE-first onboarding

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Review + ship

**Files:** none (operations only)

- [ ] **Step 1: Full verification** — `swift test 2>&1 | grep -E "Executed .* tests, with" | tail -1` → all green.
- [ ] **Step 2: code-reviewer agent** on the branch diff (feature-dev:code-reviewer, prompt includes: chain fallthrough correctness vs isRefreshing, suppression persistence, account-switch reset completeness, observation re-arm, SQLite API misuse, Swift 6 Sendable). Apply valid findings, commit.
- [ ] **Step 3: Merge + push** — `git checkout main && git merge --no-ff feature/54-ide-credential-chain -m "Merge feature/54-ide-credential-chain (#54)" && git push origin main`.
- [ ] **Step 4: Monitoring build** — rebase `debug/87-instrumentation` onto main, run `swift test`, then CLAUDE.md reinstall sequence (pkill / rm / package / cp / open), return to main. (Do NOT install plain main — #87 monitoring must stay active, per project memory.)
- [ ] **Step 5: Live verification** — with Cursor IDE signed in: app should reach data WITHOUT any login window. Check `defaults read com.woojin.CursorMeter ideAuthSuppressed` absent/false; unified log shows refreshes; Settings shows `Auth: Cursor IDE`. Then in the popover: Log Out → status shows the two-button guidance; Connect Cursor IDE → data returns without WebView. Report actual observed states.
- [ ] **Step 6: Close** — `gh issue close 54 --comment "..."` summarizing shipped behavior + `gh issue list --state open`.
