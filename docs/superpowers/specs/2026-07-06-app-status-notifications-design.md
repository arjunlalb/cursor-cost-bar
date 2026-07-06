# App Status Notifications (Release + Error) — Design

**Date:** 2026-07-06
**Status:** Approved design, pending implementation plan

## Goal

Add two new system notification types, independent of the Bold/jump-effect settings:

1. **Release notification** — notify once per new version when the periodic update check detects a newer GitHub release.
2. **Error notification** — notify once per outage when auto-refresh fails repeatedly (monitoring is effectively down).

Announcement ("공지") notifications were considered and excluded from scope — no announcement source exists and no need identified.

## Non-Goals

- No new notification infrastructure class. Extend `NotificationManager` (approach A; a separate `AppStatusNotifier` was rejected as over-engineering for two notification types).
- No per-type settings toggles — one unified toggle covers both.
- No change to existing threshold, usage-jump, or session-expired notifications.

## Design

### 1. Release notification

- **Funnel:** the three call sites that assign `lastUpdateCheckResult` (startup check, periodic re-check (#80), manual refresh) are consolidated into one `UsageViewModel` helper, e.g. `recordUpdateCheckResult(_:)`. It assigns the property and evaluates notification eligibility.
- **Dedup:** new UserDefaults key `lastNotifiedUpdateVersion`. Notify only when `release.version != lastNotifiedUpdateVersion`; store the version after sending. One notification per version across app restarts. (Dev builds stamped 0.1.0 see "update available" permanently; dedup makes that a single notification, not noise.)
- **Decision logic** is a `nonisolated static` pure function for testability:
  `shouldNotifyUpdate(version:lastNotified:enabled:) -> Bool`.
- **Content:** title `"CursorMeter update available"`, body `"v<version> is out — click to see what's new."` English, matching the session-expired notification and settings-window language. Identifier fixed: `update-available` (re-fire replaces the banner).
- **Click action:** notification `userInfo` carries the release `htmlURL`. Click opens it via the existing host-validated `ExternalURL` wrapper.

### 2. Error notification

- **Trigger:** reuse the existing `consecutiveFailureCount` in `UsageViewModel`. Fire exactly when the count **reaches `staleThreshold` (5)** — the same moment the UI marks data as stale — and not again at 6, 7, … A success resets the counter (existing behavior), which re-arms the notification for the next outage.
- **Session expiry is excluded:** the unauthorized path already routes to the #76 session-expired notification and does not double-fire this one.
- **Content:** title `"Cursor connection trouble"`, body `"Usage refresh has failed 5 times in a row. Data may be stale."` Identifier fixed: `refresh-failing`.
- **Click action:** open the popover (the error message is already displayed there).

### 3. Notification click routing

Extend the pure routing function in `NotificationManager` (currently `opensLoginWindow(forNotificationIdentifier:)`) into an enum-returning router:

```swift
enum NotificationClickAction: Equatable {
    case openLoginWindow      // session-expired (#76/#79)
    case openReleaseURL       // update-available (URL from userInfo)
    case openPopover          // refresh-failing
    case none                 // threshold / usage-jump (unchanged)
}
static func clickAction(forNotificationIdentifier: String) -> NotificationClickAction
```

The existing `opensLoginWindow` call site migrates to the enum; behavior for existing identifiers is unchanged.

### 4. Settings

- One checkbox in the settings window: **"App status notifications (new version · connection errors)"**, default ON.
- New UserDefaults key `appStatusNotificationEnabled`, following the existing pattern (`var appStatusNotificationEnabled: Bool = true` + load-if-present in settings restore, setter persists).
- Fully independent of `notificationEnabled` (usage thresholds) and jump/Bold settings.

### 5. Sending

Two new `NotificationManager` methods following the session-expired pattern (fixed identifier, `sendNotification` reuse, authorization handling unchanged):

- `notifyUpdateAvailable(version:releaseURL:)` — adds `userInfo["releaseURL"]`.
- `notifyRefreshFailing()`.

`UsageViewModel` calls them through injectable closure seams (same pattern as `sessionExpiredNotifier`):
`updateAvailableNotifier`, `refreshFailingNotifier`. Tests inject stubs; production wires them in `CursorMeterApp`.

## Error Handling

- Notification authorization denied → silent no-op with a log line (existing `sendNotification` behavior).
- Invalid/missing `releaseURL` in userInfo at click time → `ExternalURL` host validation rejects; no-op.
- Update check `.failed` results never notify (only `.available` does).

## Testing

Per CLAUDE.md seam rules — no `UNUserNotificationCenter.current()`, no real Keychain in tests:

1. `shouldNotifyUpdate` — new version fires; same version suppressed; disabled toggle suppressed; nil lastNotified fires.
2. Failure-notification decision — fires exactly at count == 5, not at 4, not again at 6; counter reset re-arms.
3. `clickAction(forNotificationIdentifier:)` — all four routes, including legacy identifiers mapping to their previous behavior.
4. ViewModel integration via `MockURLProtocol` + injected notifier closures: repeated failures invoke `refreshFailingNotifier` once; recovery + second outage invokes it again; unauthorized path invokes only `sessionExpiredNotifier`.
5. Settings persistence round-trip for `appStatusNotificationEnabled`.

## Workflow Notes

- GitHub issue to be filed before implementation (Issue-First).
- Observation tracking: no new UI-read observable state is introduced (notifications are side effects; the settings toggle is written, not observed), so no `withObservationTracking` block changes expected. Verify during implementation.
