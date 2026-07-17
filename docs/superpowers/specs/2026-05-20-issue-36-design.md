# Issue #36 — Switch progress display to on-demand when quota exhausted

**Status**: design approved, pre-implementation
**Issue**: https://github.com/WoojinAhn/CursorMeter/issues/36
**Mockups**: `docs/mockup-issue-36.html`, `docs/mockup-issue-36-settings.html`

## Problem

When a Cursor user's request quota is fully consumed (e.g. 757/500 = 151%), the menu bar icon and popover progress bar are stuck at red 100%. The on-demand spend (`$5.84 / $40.00`) is only shown as a passive secondary row. There is no visual progress signal for the dimension that now actually matters — incremental billing.

## Goal

Once the request quota (or credit plan limit) is exhausted **and** on-demand billing is active, swap the primary progress display to on-demand spend. The previous Requests/Credit dimension moves to the secondary row.

## Scope decisions (recorded from brainstorming)

| Decision | Choice | Why |
|---|---|---|
| Apply to credit-based plans? | Yes (A1) | Same mental model — quota exhausted → on-demand. Branching cost trivial. |
| Notification copy mode-aware? | Yes (B1) | Re-firing 80/90% notifications without saying which dimension confuses users. |
| Jump effect in on-demand mode? | Yes (C1) | Add `.onDemand` mode + `previousOnDemandUsedCents` baseline. |
| Mode oscillation handling? | Sticky latch (D1.i) | Once on-demand mode is entered, stay until billing cycle rollover. Prevents notification re-fire loops from API jitter. |
| First on-demand delta when entering mode? | First observation is baseline (D2.i) | No tier-2 jump on initial mode entry. Subsequent deltas tracked normally. |
| New settings toggle? | No (YAGNI) | No use case where a user would want to disable this. |

## Trigger logic

```
wouldActivate = (
  (requestsLimit > 0 && requestsUsed >= requestsLimit)
  ||
  (isCreditBased
    && (planLimitCents ?? 0) > 0
    && (planUsedCents ?? 0) >= (planLimitCents ?? 0))
) && hasOnDemand

isOnDemandActive = isOnDemandLatched || wouldActivate
```

**Latch update rules** (live in `UsageViewModel`):
- On first refresh where `wouldActivate == true`: set `isOnDemandLatched = true`, call `notificationManager.resetNotifications()` once.
- On billing-cycle rollover (detected via existing `previousCycleStart != newStart` block): set `isOnDemandLatched = false`. Existing rollover code already resets notifications, so we get re-arming for free.
- On `resetPerAccountState()` (logout / account switch): set `isOnDemandLatched = false`.

This means within a single billing cycle the mode is monotonic (request → on-demand only, never back). Eliminates oscillation entirely.

## `hasOnDemand` refinement

Current:
```swift
var hasOnDemand: Bool {
    onDemandLimitCents != nil && onDemandLimitCents! > 0
}
```

Add `enabled` check so admin-disabled mid-cycle states don't trigger mode flip:
```swift
var hasOnDemand: Bool {
    guard let limit = onDemandLimitCents, limit > 0 else { return false }
    return onDemandEnabled ?? true   // default true if field absent
}
```

(Requires plumbing `enabled` flag through `OnDemandUsage` → `UsageDisplayData`. Field already exists in the model.)

## `teamUsage.onDemand` fallback

`UsageDisplayData.from(summary:usage:userInfo:)` currently reads only `summary.individualUsage?.onDemand`. Some Enterprise team members likely receive on-demand via `summary.teamUsage?.onDemand` instead — this would make the on-demand row silently disappear today.

Fix:
```swift
let onDemand =
  summary.individualUsage?.onDemand
  ?? summary.teamUsage?.onDemand
```

This is a pre-existing gap surfaced by this work; ship it together.

## UI behavior (final)

### Menu bar
- Render path unchanged (`CursorMeterApp.currentRingImage` already feeds from `percentUsed`, `menuBarUsedText`, `menuBarLimitText`).
- Those three properties branch on `isOnDemandActive`:
  - Active: `5.8 / 40` text (no `$` prefix to keep menu bar compact), ring fills against on-demand % (e.g. 14.6%).
  - Inactive: existing behavior.

### Popover (`MenuBarView.swift`)
- Main row: `usageLabel` + `usageText` already branch via `UsageDisplayData`. Active mode: `On-demand` + `$5.84 / $40.00`.
- Secondary row: current `onDemandRow` is repurposed as a generic "secondary metric" row with `secondaryUsageLabel` + `secondaryUsageValue`:
  - Active mode: label = `Requests` (or `Plan` for credit-based), value = `757 / 500` with red color when over.
  - Inactive mode: label = `On-demand`, value = `$5.84 / $40.00` (current behavior).
- Color thresholds unchanged (60% blue → 80% amber → 100% red), applied to whichever percentage is primary.

## Model changes (`UsageModels.swift`)

Per Codex review: keep new properties **computed** where possible to avoid disturbing memberwise initializer call sites in tests. The one exception is `isOnDemandActive`, which requires latch state from `UsageViewModel` and is therefore a stored property with a default value of `false`.

### New stored property
```swift
let isOnDemandActive: Bool   // default: false — injected by UsageViewModel after latch logic
let onDemandEnabled: Bool?   // plumbed from API for hasOnDemand refinement
```

Default values keep all existing `UsageDisplayData(...)` test constructions valid (Swift memberwise init uses labeled args + defaults).

### New computed properties
- `wouldActivateOnDemand: Bool` — pure derived snapshot, no latch
- `secondaryUsageLabel: String?`
- `secondaryUsageValue: String?`
- `secondaryUsageIsOverLimit: Bool` — for red color on the over-quota requests value

### Modified computed properties (branch on `isOnDemandActive`)
- `percentUsed`
- `usageText`
- `usageLabel`
- `menuBarUsedText`
- `menuBarLimitText`

## Notification copy

```swift
// NotificationManager.swift — add mode parameter
enum NotificationMode { case requestQuota, creditPlan, onDemand }

// Body text per mode:
// requestQuota: "월 요청 한도의 80%를 초과했습니다 (757 / 500)"
// creditPlan:   "월 플랜의 80%를 사용했습니다 ($16.00 / $20.00)"
// onDemand:     "On-demand 청구의 80%를 사용했습니다 ($32.00 / $40.00)"
```

`UsageViewModel.checkNotificationThresholds()` passes the active mode based on `isOnDemandActive` + plan type.

## Jump effect (`UsageViewModel.swift`)

### Enum extension
```swift
enum Mode: Sendable, Equatable {
    case credit, request, percent, onDemand
}
```

Three switch sites must add the case (compiler-enforced):
- `updateJumpState`
- `absoluteThresholds`
- `formatJumpDelta`

### New baseline
```swift
private var previousOnDemandUsedCents: Int?
```

Must also appear in:
- `resetPerAccountState()` — line 193-204
- Logout / 401 paths if they reset state (verify during implementation)

### Delta computation in on-demand mode
- Canonical unit: cents (same formatting as `.credit`)
- Threshold computation: against `onDemandLimitCents` as the % denominator
- First observation in on-demand mode: store baseline, return no jump (D2.i)
- Existing `modeChanged` guard handles the request → onDemand transition refresh automatically

## Out of scope

- Settings UI changes
- Weekly chart (aggregates requests; on-demand is cents — orthogonal)
- API token paste migration (#54)
- Backfilling missed on-demand jumps from before app launch

## Test plan

Located in `Tests/CursorMeterTests/`. Naming follows existing `UsageDisplayDataTests` conventions.

### `UsageDisplayDataTests`
| Case | Expectation |
|---|---|
| `757/500` + `$5.84/$40` | `isOnDemandActive=true` (injected), `percentUsed ≈ 14.6`, `usageLabel == "On-demand"`, `secondaryUsageLabel == "Requests"`, `secondaryUsageValue == "757 / 500"`, `secondaryUsageIsOverLimit == true` |
| `500/500` + `$0/$40` | boundary: `wouldActivateOnDemand == true`, `percentUsed == 0` when active |
| `400/500` + `$0/$40` | `wouldActivateOnDemand == false`; defaults preserve request-mode display |
| credit-based `$20/$20` + `$5/$40` | `wouldActivateOnDemand == true` for credit branch |
| `requestsLimit > 0` && `!hasOnDemand` | no activation — preserves legacy red 151% behavior |
| `onDemand.enabled == false` && `limit > 0` | `hasOnDemand == false`, no activation |
| `teamUsage.onDemand` only (individualUsage absent) | on-demand fields populated from team |

### `UsageViewModelTests` (latch & notification re-arm)
| Case | Expectation |
|---|---|
| Refresh sequence: `400/500 → 600/500` | `isOnDemandLatched` flips false→true on second refresh; `resetNotifications()` called exactly once |
| Refresh sequence: `600/500 → 480/500` (oscillation guard) | latch stays true; no extra `resetNotifications()`; no notification re-fire |
| Billing cycle rollover with latch true | latch resets to false; rollover-side `resetNotifications()` runs |
| Logout (`resetPerAccountState`) | `previousOnDemandUsedCents == nil`, `isOnDemandLatched == false` |

### `JumpEffectTests`
| Case | Expectation |
|---|---|
| Mode transition request → onDemand | first on-demand refresh sets baseline, no jump event emitted |
| Subsequent on-demand `$5 → $10` (`+$5` on `$40` limit = 12.5%-points) | tier-N jump fires in `.onDemand` mode |
| `formatJumpDelta` for `.onDemand` | `+$5.00` format (same as `.credit`) |
| `absoluteThresholds` for `.onDemand` | configured (sanity that we didn't leave a switch fallthrough) |

### Observability for tests
Codex flagged that `notificationManager`, `apiClient`, `updateJumpState` are private/concrete with no observation points. Implementation may need to:
- Expose `NotificationManager` injection in `UsageViewModel.init` (default = real impl)
- Add a `@testable` window or move the latch logic into a pure function we can call from tests with crafted snapshots

Will decide concrete approach during implementation; principle is **no production behavior change for testability**, only widening access.

## Build sequence (for the implementation plan)

1. `UsageModels.swift` — add `onDemandEnabled` plumbing, `isOnDemandActive` stored prop, computed `wouldActivateOnDemand` / `secondaryUsage*` / refined `hasOnDemand`, branch existing computeds, `teamUsage.onDemand` fallback. Tests first per CursorMeter `swift test` discipline.
2. `UsageViewModel.swift` — latch state (`isOnDemandLatched`, reset paths), `previousOnDemandUsedCents`, mode-aware notification dispatch, `JumpEvent.Mode.onDemand` plumbing.
3. `NotificationManager.swift` — mode parameter, body copy.
4. Jump effect switch sites — `updateJumpState`, `absoluteThresholds`, `formatJumpDelta`.
5. `MenuBarView.swift` — repurpose on-demand row as generic secondary metric row.
6. Manual verification via release build (limited — local account isn't in exhausted state). Document this in the PR.

## Risks & follow-ups

| Risk | Mitigation |
|---|---|
| API schema differs from inference (esp. `teamUsage.onDemand` shape) | Defensive coding: `nil`-safe everywhere. Add diagnostic log on first observed activation. |
| User's local account never enters this state | Can't end-to-end verify. Ship behind explicit unit tests + structured logging so first real user can be diagnosed via `/usr/bin/log show`. |
| Latch persists past app restart? | No — `isOnDemandLatched` is in-memory only. On relaunch, latch starts false; if API still shows quota exhausted, it re-latches on first refresh (with one `resetNotifications()` call — acceptable). |

## Acceptance criteria

- All existing 197 tests pass.
- New tests above pass.
- Mockup `docs/mockup-issue-36.html` After state matches actual popover render for a real exhausted-quota account (verified by first user who hits this state, via screenshot back).
- Notification copy matches the table above.
- No `Settings` UI changes visible.
