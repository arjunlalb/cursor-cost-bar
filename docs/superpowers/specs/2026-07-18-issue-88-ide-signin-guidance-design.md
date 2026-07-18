# Issue #88 — IDE not-signed-in guidance design

Approved 2026-07-18 (conversation). Fixes the silent round-trip of
[Connect Cursor IDE] when the Cursor IDE has no session, and adds an
IDE sign-in inducement path.

## Goal

When both credential sources are absent, the popover's login layout must
(1) tell the user *why* the IDE path won't work before they click, and
(2) actively help them fix it: launch the IDE, detect the sign-in, and
connect automatically.

## Decisions

| Decision | Value |
|----------|-------|
| Detection | `UsageViewModel.ideCredentialAvailable: Bool?` — nil until first check; refreshed off-main via the existing `ideCredentialProvider` seam each time the login-required layout is (re)rendered. Ignores `ideAuthSuppressed` (presence only). |
| Layout: credential available | Unchanged — [Connect Cursor IDE] (default, Enter) + [Log in with Browser]. |
| Layout: unavailable, IDE installed | Hint "Cursor IDE is not signed in." + [Open Cursor IDE] + [Log in with Browser] promoted to default (Enter). |
| Layout: unavailable, IDE absent | [Open Cursor IDE] hidden; hint "Log in with your browser to connect." IDE presence = `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` (fallback: by-name lookup) non-nil. |
| Inducement | [Open Cursor IDE] launches the IDE, then polls the credential every 3s for up to 60s; first discovery runs `connectViaIDE()` once and stops. Poll cancels on timeout, auth-state transition, or a second click (restart). |
| Reactive self-correction | No error banner. A stale layout (race between check and click) is corrected by the next updateUI re-check. |
| Unknown state (nil) | Render as "available" (current layout) — never degrade the primary path on an unfinished check; the async check re-renders promptly. |

## Components

- `UsageViewModel`
  - `ideCredentialAvailable: Bool?` (`@Observable` state, read by MenuBarView)
  - `func refreshIDEAvailability()` — `Task.detached` provider read, then set flag on main. No-op when `ideCredentialProvider == nil` (test hosts): flag stays nil → layout unchanged.
  - `func beginIDESignInWatch()` — cancels any prior watch task; polls provider every 3s (≤ 60s). On first non-nil credential: `connectViaIDE()` and stop. Cancelled when `authState` becomes `.loggedIn` or on `logout()`.
  - Poll interval/timeout as internal constants with a test seam (injectable clock not required — tests drive the provider seam and a shortened interval constant).
- `MenuBarView.applyLoginRequiredStatus()`
  - Branches on `viewModel.ideCredentialAvailable` per the table; kicks `refreshIDEAvailability()` each render (fire-and-forget).
  - [Open Cursor IDE] action: `viewModel.beginIDESignInWatch()` + launch the IDE app via NSWorkspace (launch failure → no-op; layout already offers the browser path).
- IDE app launch helper lives next to `ExternalURL` conventions: resolve app URL by bundle id (verify actual id on-machine during implementation) with by-name fallback, `NSWorkspace.shared.openApplication`.

## Concurrency

Swift 6: the watch task is a `@MainActor` method owning a `Task<Void, Never>` handle; provider reads hop off-main via `Task.detached` exactly like refresh() chain step 1. Single watch task at a time (handle replaced on restart).

## Testing (critical logic only)

Via the `ideCredentialProvider` seam, shortened interval:

- availability refresh: provider nil→flag stays nil; credential present→true; absent→false
- watch: credential appears mid-poll → `connectViaIDE()` effect observed exactly once, task ends
- watch: never appears → stops after timeout without connect
- watch: `authState → .loggedIn` (e.g., browser login during poll) → cancelled, no double connect
- watch restart: second `beginIDESignInWatch()` cancels the first (no duplicate connects)

Layout branching and IDE launch verified live (machine is already in the IDE-signed-out state).
