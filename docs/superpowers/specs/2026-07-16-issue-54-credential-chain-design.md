# Credential Chain: Cursor IDE Token (Primary) + WebView Capture (Fallback) — Design

**Date:** 2026-07-16 (rev 2, 2026-07-17, after Codex review)
**Issue:** #54
**Status:** Approved design, pending implementation plan

## Problem

The app captures `WorkosCursorSessionToken` once via WKWebView login and replays
it statically. Cursor's WorkOS-backed server invalidates sessions early
regardless of the JWT's nominal `exp` (measured lifetime ~4h20m on 2026-07-14;
staff-confirmed "12h per session" dashboard policy), and API responses carry no
`Set-Cookie` rotation to honor. Static replay is architecturally doomed — users
re-login several times a day.

## Chosen Approach

Stop *storing* credentials as the primary strategy; **re-source them on every
refresh from the Cursor IDE's own local state**, which the IDE keeps fresh:

`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
(SQLite) → key `cursorAuth/accessToken` (a JWT) → synthesize
`WorkosCursorSessionToken=<userID>%3A%3A<jwt>`.

This is CodexBar's production-proven pattern (its `CursorAppAuthStore`),
implementable with `import SQLite3` — a macOS SDK system library, so the
zero-external-dependency rule holds. The existing WebView capture remains as
fallback for Macs without a signed-in Cursor IDE and as automatic degradation
if Cursor changes the DB schema.

Rejected alternatives:
- **Remove WebView entirely** — loses the no-IDE use case and the schema-drift
  safety net; keeping it costs nothing (code is done and stable).
- **Implement the WorkOS refresh-token exchange ourselves** (the
  `cursorAuth/refreshToken` key also exists) — reverse-engineering a private
  refresh protocol, handling a more powerful secret, and a much larger breakage
  surface, for the same outcome the IDE already provides. We never read
  `refreshToken`.

Validated on this machine (2026-07-16): DB present, `cursorAuth/accessToken`
is a well-formed JWT (`exp` ~2 months out, refreshed by the IDE), `sub`
contains the expected `|`-delimited user id.

## Design

### 1. New unit: `CursorAppAuthReader.swift`

```swift
struct IDECredential: Sendable, Equatable {
    let cookieHeader: String   // "WorkosCursorSessionToken=<id>%3A%3A<jwt>"
    let expiresAt: Date
}

struct CursorAppAuthReader: Sendable {
    let dbPath: String         // injectable; default = real state.vscdb path
    func read(now: Date = Date()) -> IDECredential?
}
```

- Opens the DB **read-only** (`SQLITE_OPEN_READONLY`, `busy_timeout` 250ms) —
  never blocks or mutates the IDE's store. Any SQLite error → nil (fallback).
- Concurrency (rev 2): no stored `sqlite3*` handle — open, query, finalize,
  close within a single `read()` call; no state shared across tasks, so plain
  `Sendable` holds without `@unchecked`. Because busy_timeout can block up to
  250ms, `refresh()` invokes it OFF the MainActor:
  `await Task.detached { reader.read() }.value`.
- `SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'`.
- Pure helpers, each unit-tested without I/O:
  - `parseJWTClaims(_ jwt: String) -> (sub: String, exp: Date)?` —
    base64url-decode payload; nil on malformed input.
  - `userID(fromSub sub: String) -> String?` — substring after the last `|`.
  - `makeCookieHeader(userID: String, jwt: String) -> String` —
    `WorkosCursorSessionToken=<userID>%3A%3A<jwt>`.
- Validity gate: return nil unless `exp > now + 60s` — a stale token is never
  replayed (CodexBar's `isUsable` rule).
- No caching: called at most once per refresh cycle; a single indexed SELECT
  on a local SQLite file is negligible.

### 2. Credential chain in `UsageViewModel`

Per refresh, resolve in order:

1. **IDE token** — `ideCredentialProvider()`; if non-nil (and not suppressed,
   see Logout below), use it.
2. **Captured cookie** — existing `cachedCookieHeader` (memory, backed by
   Keychain at launch via `checkExistingSession`).
3. Neither → `authState = .loginRequired` (no API call attempted).

**Attempt boundary (rev 2):** `refresh()` keeps sole ownership of
`isRefreshing`; the per-credential work moves into a non-recursive private
`runRefreshAttempt(cookieHeader:) async throws` helper. The outer `refresh()`
runs the IDE attempt, and on `APIError.unauthorized` runs the captured-cookie
attempt at most once — no recursive `refresh()` call (which the `isRefreshing`
guard would swallow). A failed attempt's concurrent endpoint tasks are already
collapsed into the thrown error by the existing batch logic; the fallback
attempt starts a fresh batch.

**401/unauthorized fallthrough (one refresh cycle):**

- Request made with the IDE credential fails `unauthorized` → retry the same
  refresh once with the captured cookie (if present). The IDE credential's
  failure must NOT delete the captured cookie or fire the expiry flow — they
  are unrelated credentials.
- Request made with the captured cookie fails `unauthorized` → existing #76
  flow unchanged (clear keychain, record #84 timestamp, notify, loginRequired)
  — but only after the IDE source was also unavailable/failed this cycle, so
  the notification now means "all sources exhausted".
- Network errors delete nothing (existing behavior preserved).
- `authState == .loggedIn` whenever either source yields a usable credential —
  a user with a signed-in IDE never sees the login window.

Seam (rev 2 — strengthened): `@ObservationIgnored internal var
ideCredentialProvider: (@Sendable () -> IDECredential?)? = nil`. The default
is **nil**; production wires the real reader in
`CursorMeterApp.applicationDidFinishLaunching` (before
`checkExistingSession()`), exactly like the #83 notifier seams. Every bare
`UsageViewModel()` in the test host therefore has NO IDE source — no test can
accidentally read the developer's real `state.vscdb`, with zero per-suite
injection burden.

### 2b. Logout semantics (rev 2)

With an IDE-primary chain, a naive "Log Out" would resurrect on the next
refresh. Redefined:

- **Log Out** = existing behavior (clear captured cookie + keychain + state)
  **plus** persist `ideAuthSuppressed = true` (new UserDefaults key). While
  suppressed, chain step 1 is skipped → the app is genuinely logged out.
- Logged-out popover buttons: primary `"Connect Cursor IDE"` (sets
  `ideAuthSuppressed = false`, triggers a refresh; if the IDE has no token the
  status line explains the fallback), secondary `"Log in with Browser"`
  (existing WebView flow; a successful browser login also clears the
  suppression flag — explicit user intent to reconnect).
- Fresh installs: flag defaults to false → zero-config onboarding preserved.

### 2c. Account-switch reset (rev 2)

The IDE credential can silently belong to a different account than the
captured cookie (or the IDE user can switch accounts between refreshes).
`resetPerAccountState()` currently runs only on browser login. New rule: track
the account identity of each successful refresh — `email` from
`/api/auth/me` (already fetched every cycle). When it differs from the
previous refresh's identity, run the full per-account reset (caches, weekly
data, notification dedup set, on-demand latch, jump baselines) BEFORE applying
the new data, so no cross-account deltas or stale team caches leak.

### 3. UX changes

- **Popover logged-out status text** (statusStack), copy locked (English,
  matching existing UI language):
  - Status line: `"Sign in to the Cursor IDE to connect automatically."`
  - Existing login button relabeled: `"Log in with Browser"` (secondary path).
- **Settings window**: one informational line in the existing About/Updates
  area: `Auth: Cursor IDE` / `Auth: Browser login` / `Auth: —` (logged out).
  Driven by a new observable `var activeAuthSource: AuthSource?`
  (`enum AuthSource { case cursorIDE, browserLogin }`) set during refresh.
  Rev 2: no settings observation path exists today (settings `updateUI()` is
  pull-based) — add a dedicated `withObservationTracking` block in
  `CursorMeterApp` tracking `viewModel.activeAuthSource` (and re-arming, per
  the standard pattern) whose onChange calls
  `(settingsWindow?.contentViewController as? SettingsViewController)?.updateUI()`.
  `SettingsViewController.updateUI()` reads the property directly (nil-safe
  when the window is closed).
- Session-expired notification (#76) and #84 timestamp recording now fire only
  on all-sources-exhausted unauthorized — for IDE users this becomes rare by
  design.

### 4. Security & docs

- SECURITY.md new section: what is read (`state.vscdb`, key
  `cursorAuth/accessToken` only), how (read-only SQLite, 250ms busy timeout),
  what is never read (`cursorAuth/refreshToken`), never logged (existing
  LogRedactor policy applies to the synthesized header), and that the value is
  the user's own credential on the user's own machine — same threat model as
  the existing Keychain-stored cookie.
- README: onboarding section rewritten — zero-config path first (IDE signed
  in → it just works), browser login as fallback.

### 5. Testing

Per CLAUDE.md seam rules (no real Keychain, no UNUserNotificationCenter, and
now: no real `state.vscdb`):

1. **Reader unit tests** (fixture SQLite file built in a temp dir per test):
   valid JWT → correct header + expiresAt; `exp` within 60s → nil; key absent
   → nil; DB file absent → nil; malformed JWT/base64 → nil; non-`|` sub → nil.
2. **Pure helpers**: `parseJWTClaims`, `userID(fromSub:)`, `makeCookieHeader`
   boundary cases.
3. **Chain integration** (MockURLProtocol + injected `ideCredentialProvider`):
   - Logout while IDE source active → stays logged out across a subsequent
     refresh (suppression flag honored); "Connect Cursor IDE" path re-enables.
   - Account switch (auth/me email changes between refreshes) → per-account
     state reset (weekly cache cleared, jump baseline nil, notification dedup
     reset) before the new account's data lands.
   - IDE credential present + API 200 → data refreshed, `activeAuthSource == .cursorIDE`, no keychain read needed.
   - IDE 401 + captured cookie 200 → fallback works within one refresh, `activeAuthSource == .browserLogin`, captured cookie NOT deleted, no expiry notification.
   - IDE 401 + captured 401 → single #76 expiry flow (keychain delete, one notification, one #84 record).
   - IDE nil + captured present → current behavior unchanged (regression guard for SessionExpiryTests/StaleDataTests).
   - IDE nil + captured nil → loginRequired without network calls.
4. Existing suites must stay green with `ideCredentialProvider = { nil }` as
   the test-host default (constructor keeps real reader default for
   production; test helpers inject nil — verify no suite accidentally reads
   the real DB).

## Out of Scope

- Proactive "session expiring soon" warnings from JWT `exp` (decided: separate
  issue if ever needed — the chain makes expiry rare).
- Reading `cursorAuth/refreshToken` or implementing WorkOS refresh exchange.
- Browser cookie import (CodexBar's SweetCookieKit path) — external dependency.
- Removing the WebView login.

## Workflow Notes

- Issue #54 retitled to match this scope.
- Rev 2: the reader seam defaults to **nil** and production wires it in
  `CursorMeterApp` (see §2) — this supersedes the rev-1 note about test
  helpers injecting nil; bare `UsageViewModel()` constructions are safe by
  construction. Add the new UserDefaults keys (`ideAuthSuppressed`) to
  `SettingsKey` and load/persist via the existing pattern.
