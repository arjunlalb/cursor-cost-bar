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
| Inducement | [Open Cursor IDE] launches the IDE; **the watch starts only after launch succeeds** (launch failure → no watch, layout already offers the browser path). Watch ticks every 3s for up to 60s. Per tick: `authState == .loggedIn` → stop; credential present and `!isRefreshing` → attempt `connectViaIDE()` (a collision with an in-flight refresh is retried on the next tick). Cancels on timeout, `.loggedIn`, `logout()`, or a second click (restart). **Not** cancelled on popover close — clicking the button activates the IDE, which necessarily closes the transient popover; cancelling there would kill the feature. The 60s cap bounds the cost (worst case ~20 SQLite reads). |
| Reactive self-correction | No error banner. `refresh()` publishes availability as a side effect: when chain step 1 resolves (credential present/absent), it updates `ideCredentialAvailable` — so a failed [Connect Cursor IDE] click flips the layout to the guidance state immediately, not just on the next popover open. |
| Unknown state (nil) | Render as "available" (current layout) — never degrade the primary path on an unfinished check; the async check re-renders promptly. The residual race (click during the ~250ms first check) is covered by refresh()'s availability side effect above. |
| Logout boundary | `logout()` cancels the watch, and a generation token guards the pending provider read: a result arriving after cancellation/restart must not call `connectViaIDE()` (which would clear `ideAuthSuppressed` against the user's intent). Availability *display* ignores suppression; the connect path never runs post-logout. |
| Default button per state | available/nil → [Connect Cursor IDE] carries Enter; unavailable → [Log in with Browser] carries Enter. Deterministic per rebuild — the key equivalent never depends on transition history. |

## Components

- `UsageViewModel`
  - `ideCredentialAvailable: Bool?` (`@Observable` state, read by MenuBarView)
  - `func refreshIDEAvailability()` — copies the provider on the main actor, reads it via `Task.detached` (never capture `self` in the detached closure — same shape as refresh() chain step 1), then sets the flag on main. Guards: no-op when `ideCredentialProvider == nil` (test hosts; flag stays nil), in-flight dedupe (at most one read at a time), **monotonic generation counter so an out-of-order result never overwrites a newer one**, and the flag is only written when the value actually changes (avoids an observation → re-render → re-check loop).
  - `func beginIDESignInWatch()` — cancels any prior watch task (generation bump invalidates its in-flight read); polls per the Inducement rule above. Explicit `Task.isCancelled` + generation checks after every sleep and provider read, and immediately before `connectViaIDE()`. Cancelled by `.loggedIn`, `logout()`, timeout, restart.
  - Watch task handle stored `@ObservationIgnored`. Poll interval/timeout as internal `@ObservationIgnored` vars (tests shorten them; no injectable clock needed).
- `MenuBarView.applyLoginRequiredStatus()`
  - Branches on `viewModel.ideCredentialAvailable` per the table; kicks `refreshIDEAvailability()` each render (fire-and-forget).
  - [Open Cursor IDE] action: `viewModel.beginIDESignInWatch()` + launch the IDE app via NSWorkspace (launch failure → no-op; layout already offers the browser path).
- IDE app launch/presence goes through seams (project convention, testable):
  - `ideAppPresenceCheck: () -> Bool` — production: `NSWorkspace.shared.urlForApplication(withBundleIdentifier:)` (verify the actual bundle id on-machine) with by-name fallback
  - `ideAppLauncher: (@escaping (Bool) -> Void) -> Void` — production: `NSWorkspace.openApplication` completion; watch starts only on `true`

## Concurrency

Swift 6: the watch task is a `@MainActor` method owning a `Task<Void, Never>` handle; provider reads hop off-main via `Task.detached` exactly like refresh() chain step 1. Single watch task at a time (handle replaced on restart).

## Testing (critical logic only)

Via the `ideCredentialProvider` seam, shortened interval:

- availability refresh: provider nil→flag stays nil; credential present→true; absent→false
- availability refresh: out-of-order results — stale read never overwrites a newer flag (generation)
- refresh() side effect: chain step 1 absence flips `ideCredentialAvailable` to false
- watch: credential appears mid-poll → connect attempted, task ends at `.loggedIn`
- watch: never appears → stops after timeout without connect
- watch: `authState → .loggedIn` (e.g., browser login during poll) → cancelled, no double connect
- watch: `logout()` during a pending provider read → the late result must NOT connect (suppression preserved)
- watch: launch failure → watch never starts
- watch: discovery while `isRefreshing` → connect deferred to a later tick, still succeeds
- watch restart: second `beginIDESignInWatch()` cancels the first (no duplicate connects)

Layout branching and IDE launch verified live (machine is already in the IDE-signed-out state).

## Revision note

2026-07-18: revised after codex:rescue spec review — watch starts only on
launch success; refresh() publishes availability (closes the nil-window
silent round-trip); logout/generation guards on the connect path;
out-of-order + dedupe + write-on-change rules for the availability check;
per-state default-button rule; launch/presence seams; expanded test list.
Rejected: cancelling the watch on popover close (the button necessarily
closes the popover — cancelling would defeat the feature; 60s cap bounds
cost) and re-ordering the credential chain for browser-vs-IDE account
priority (existing #54 semantics, out of scope).
