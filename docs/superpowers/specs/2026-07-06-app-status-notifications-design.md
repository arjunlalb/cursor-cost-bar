# App Status Notifications (Release + Error) — Design

**Date:** 2026-07-06 (rev 2, after Codex review)
**Issue:** #83
**Status:** Approved design, pending implementation plan

## Goal

Add two new system notification types, independent of the Bold/jump-effect settings:

1. **Release notification** — notify once per new version when an *automatic* update check detects a newer GitHub release.
2. **Error notification** — notify once per outage when auto-refresh fails repeatedly (monitoring is effectively down).

Announcement ("공지") notifications were considered and excluded from scope — no announcement source exists and no need identified.

## Non-Goals

- No new notification infrastructure class. Extend `NotificationManager` (approach A; a separate `AppStatusNotifier` was rejected as over-engineering for two notification types).
- No per-type settings toggles — one unified toggle covers both.
- No change to existing threshold, usage-jump, or session-expired notifications.
- No change to the #80 re-check cadence logic (`shouldRecheckUpdate`, `lastUpdateCheckAt`, success-path-only gating) — the funnel below only consolidates *result recording*, not check scheduling.

## Design

### 1. Release notification

- **Funnel:** the call sites that assign `lastUpdateCheckResult` are consolidated into one `UsageViewModel` helper, `recordUpdateCheckResult(_:source:)`. It assigns the property and, for **automatic sources only** (startup check, periodic re-check #80), evaluates notification eligibility. The **manual check** in the settings window (`checkForUpdate`) records the result but never notifies — the user is already looking at the result.
- **Dedup:** new UserDefaults key `lastNotifiedUpdateVersion`. Notify only when `release.version != lastNotifiedUpdateVersion`. **Write-before-send:** the version is persisted *before* the notification is dispatched, so overlapping check paths cannot double-fire; a notification lost to denied authorization is acceptable (denial means the user opted out of notifications anyway). (Rev 3, post-implementation review:) the write happens only when a notifier seam is wired — a version counts as "notified" only if a dispatch was actually attempted, and bare test-host view models never touch the real defaults.
- **Decision logic** is a `nonisolated static` pure function for testability:
  `shouldNotifyUpdate(version:lastNotified:enabled:) -> Bool` (new version fires; same version, disabled toggle suppressed; nil lastNotified fires).
- **Dev builds:** local builds always stamp 0.1.0, so every *new* release triggers exactly one notification on a dev build's next automatic check. Intended — dedup makes it one-shot, not noise.
- **Content:** title `"CursorMeter update available"`, body `"v<version> is out — click to see what's new."` English, matching the session-expired notification and settings-window language. Identifier constant `NotificationManager.updateAvailableIdentifier = "update-available"` (fixed; re-fire replaces the banner).
- **Click action:** notification `userInfo["releaseURL"]` carries the release `htmlURL` as `String`. Click opens it via the existing host-validated `ExternalURL` wrapper (invalid host → no-op, existing behavior).

### 2. Error notification

- **Trigger:** reuse the existing `consecutiveFailureCount` in `UsageViewModel`. Fire exactly when the count **reaches `staleThreshold` (5)** — the same moment the UI marks data as stale — and not again at 6, 7, … A success resets the counter (existing behavior), which re-arms the notification for the next outage.
- **Evaluation site:** at the two increment sites (forbidden path, generic catch path) — i.e. where the 4→5 transition is observable. The **unauthorized path is untouched**: it routes to the #76 session-expired notification before `stopAutoRefresh()` and never reaches this counter logic, so no double-fire.
- **Content:** title `"Cursor connection trouble"`, body `"Usage refresh has failed 5 times in a row. Data may be stale."` Identifier constant `NotificationManager.refreshFailingIdentifier = "refresh-failing"` (fixed).
- **Click action:** open the popover. (Note: with cached data present, the popover shows the stale marker driven by `isDataStale`, not `errorMessage` — that existing surface is sufficient.)

### 3. Notification click routing

Replace the boolean router in `NotificationManager` (`opensLoginWindow(forNotificationIdentifier:)`) with an enum-returning pure router that also owns userInfo parsing, so malformed payloads are unit-testable:

```swift
enum NotificationClickAction: Equatable {
    case openLoginWindow      // session-expired (#76/#79)
    case openReleaseURL(URL)  // update-available; URL parsed from userInfo
    case openPopover          // refresh-failing
    case none                 // threshold / usage-jump / unknown (unchanged no-op)
}
nonisolated static func clickAction(
    forNotificationIdentifier id: String,
    userInfo: [AnyHashable: Any]
) -> NotificationClickAction
```

- Legacy identifiers (threshold UUIDs, `usage-jump-*` prefix, unknown) → `.none`, preserving #79 behavior exactly; `session-expired` → `.openLoginWindow`.
- `update-available` with missing/unparseable `releaseURL` → `.none`.
- The `AppDelegate` delegate callback becomes a thin switch over the returned action (`ExternalURL` open / `showPopover()` / existing login-window path).

### 4. Settings

- One checkbox in the settings window: **"App status notifications (new version · connection errors)"**, default ON.
- New UserDefaults key `appStatusNotificationEnabled`, following the existing pattern (`var appStatusNotificationEnabled: Bool = true` + load-if-present in settings restore, setter persists).
- **Gating sites:** release → passed as `enabled` into `shouldNotifyUpdate` at recording time; error → checked at the 4→5 transition before invoking the notifier.
- Fully independent of `notificationEnabled` (usage thresholds) and jump/Bold settings.

### 5. Sending

Two new `NotificationManager` methods following the session-expired pattern (fixed identifier, authorization handling unchanged):

- `notifyUpdateAvailable(version:releaseURL:)` — includes `userInfo`.
- `notifyRefreshFailing()`.

`sendNotification` gains an optional `userInfo: [AnyHashable: Any]? = nil` parameter; existing call sites are unaffected by the defaulted parameter.

`UsageViewModel` calls the new methods through injectable closure seams, matching the existing `sessionExpiredNotifier` shape exactly:

```swift
@ObservationIgnored internal var updateAvailableNotifier: (@MainActor (_ version: String, _ releaseURL: String) async -> Void)?
@ObservationIgnored internal var refreshFailingNotifier: (@MainActor () async -> Void)?
```

Production wires them in `CursorMeterApp` immediately after creating the view model. If a seam is nil when eligibility fires (e.g. the startup check completes before wiring in an unforeseen ordering), the notification is skipped silently — never crash, never queue.

(Rev 3, post-implementation review:) a third seam decouples the check itself from the network — the SPM test host's Bundle version falls back to "0.0.0", which would make every real release "available" and let the startup check mutate `lastNotifiedUpdateVersion` nondeterministically mid-suite:

```swift
@ObservationIgnored internal var updateCheckRunner: @MainActor () async -> UpdateCheckResult = {
    await UpdateChecker.shared.check()
}
```

All three check paths (startup, periodic, manual) go through it; tests stub it with `{ .upToDate }`.

## Error Handling

- Notification authorization denied → silent no-op (existing `sendNotification` behavior).
- Invalid/missing `releaseURL` in userInfo at click time → router returns `.none`; additionally `ExternalURL` host validation rejects non-GitHub hosts.
- Update check `.failed` results never notify (only `.available` does).

## Testing

Per CLAUDE.md seam rules — no `UNUserNotificationCenter.current()`, no real Keychain in tests:

1. `shouldNotifyUpdate` — new version fires; same version suppressed; disabled toggle suppressed; nil lastNotified fires.
2. Failure-notification decision — fires exactly at count == 5, not at 4, not again at 6; counter reset re-arms; disabled toggle suppresses.
3. `clickAction(forNotificationIdentifier:userInfo:)` — all routes including: legacy threshold/usage-jump identifiers → `.none`; `update-available` with valid URL → `.openReleaseURL`; missing/malformed URL → `.none`; `session-expired` → `.openLoginWindow`; `refresh-failing` → `.openPopover`.
4. ViewModel integration via `MockURLProtocol` + injected notifier closures: repeated failures invoke `refreshFailingNotifier` exactly once; recovery + second outage invokes it again; unauthorized path invokes only `sessionExpiredNotifier` (priority regression guard); automatic update check with new version invokes `updateAvailableNotifier`; manual `checkForUpdate` does not.
5. Settings persistence round-trip for `appStatusNotificationEnabled`.

## Workflow Notes

- GitHub issue: #83 (filed).
- Observation tracking: no new UI-read observable state is introduced (notifications are side effects; the settings toggle is written, not observed), so no `withObservationTracking` block changes expected. Verify during implementation.
- Deferred (noted, not implemented): injectable URL-opener seam on `AppDelegate` for click side-effect integration tests — the enum router carrying a parsed URL reduces the delegate to a trivial switch, so pure-router tests cover the risk (YAGNI).
