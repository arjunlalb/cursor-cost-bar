# Credential Chain: Cursor IDE Token (Primary) + WebView Capture (Fallback) — Design

**Date:** 2026-07-16
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

1. **IDE token** — `authReader.read()`; if non-nil, use it.
2. **Captured cookie** — existing `cachedCookieHeader` (memory, backed by
   Keychain at launch via `checkExistingSession`).
3. Neither → `authState = .loginRequired` (no API call attempted).

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

Seam: `@ObservationIgnored internal var ideCredentialProvider: () -> IDECredential?`
defaulting to the real reader — tests inject fixtures and never touch the real
`state.vscdb` (extends the CLAUDE.md seam rules).

### 3. UX changes

- **Popover logged-out status text** (statusStack), copy locked (English,
  matching existing UI language):
  - Status line: `"Sign in to the Cursor IDE to connect automatically."`
  - Existing login button relabeled: `"Log in with Browser"` (secondary path).
- **Settings window**: one informational line in the existing About/Updates
  area: `Auth: Cursor IDE` / `Auth: Browser login` / `Auth: —` (logged out).
  Driven by a new observable `var activeAuthSource: AuthSource?`
  (`enum AuthSource { case cursorIDE, browserLogin }`) set during refresh.
  This is new UI-read observable state → **must be added to the
  `withObservationTracking` blocks** consulted by the settings updateUI path
  (per CLAUDE.md observation rule; verify which block during implementation).
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
- Test-host default for the reader seam must be nil-safe: `UsageViewModel()`
  is constructed bare in several suites; the default provider must not read
  the real `state.vscdb` during tests. Resolution: the DEFAULT stays real (production
  correctness), but `read()` on a foreign machine's real DB in CI simply
  returns data or nil harmlessly — it performs no writes and no network. Local
  dev machines have a real signed-in DB, which would flip `activeAuthSource`
  in unrelated tests; therefore test helpers that construct `UsageViewModel`
  must inject `{ nil }` (add to the standard seam checklist in CLAUDE.md).
