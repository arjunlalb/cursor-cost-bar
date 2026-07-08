# Fine-Grained Billing-Cycle Countdown — Design

**Date:** 2026-07-09
**Issue:** #85
**Status:** Approved design, pending implementation plan

## Goal

When the billing-cycle end is imminent, the popover's reset line shows an
hour- or minute-level countdown instead of whole days. Today
`Calendar.dateComponents([.day], ...)` collapses anything under 24h into
"Resets tomorrow"/"today" even when the boundary is a specific timestamp
hours away.

## Approach (chosen)

Compute the countdown **at render time** from the already-stored
`resetDate: Date?` on `UsageDisplayData`, via a pure static function with an
injectable `now`. The previous design — a `daysUntilReset: Int?` stored
property frozen at refresh-parse time — would display values up to one
refresh interval (15 min) stale, which is unacceptable at minute
granularity. Rejected alternatives: keeping the frozen value (staleness),
`RelativeDateTimeFormatter` (no control over the fixed English copy, opaque
boundary behavior in tests).

## Design

### 1. Countdown logic

New pure function on `UsageDisplayData`:

```swift
nonisolated static func resetCountdownText(until reset: Date, now: Date) -> String
```

with `delta = reset.timeIntervalSince(now)`:

| Condition | Output | Rationale |
|---|---|---|
| `delta <= 0` | `"Resets today"` | Deadline passed, awaiting API rollover — preserves the legacy fallback meaning |
| `delta < 60` | `"Resets in <1m"` | Sub-minute precision is noise |
| `delta < 3600` | `"Resets in 40m"` | `Int(delta / 60)` — floor |
| `delta < 48 * 3600` | `"Resets in 31h"` | `Int(delta / 3600)` — floor |
| otherwise | `"Resets in N days"` | `Int(delta / 86400)` — elapsed-seconds floor, always ≥ 2 in this branch |

Days are computed from elapsed seconds, not `Calendar.dateComponents([.day], ...)`
(rev 2, Codex review): pure delta math is DST/timezone-independent and keeps
every zone deterministic under injected-`now` tests. The behavioral shift
(calendar days → 24h blocks) is imperceptible at ≥ 48h remaining.

Floor everywhere: no unit overflow ("60m"/"48h" are never rendered), and
each zone hands off smoothly to the next ("1h" → … → "59m" → … → "<1m").
"Resets tomorrow" disappears — its zone is now hour-level.

`resetText` becomes a computed property calling the pure function with
`Date()`; returns nil when `resetDate` is nil (unchanged nil contract).
It is evaluated on every `MenuBarView.updateUI()`. **`showPopover()` today
does not call `updateUI()`** (updates are observation- and timer-driven
only), so freshness-on-open requires adding one `updateUI()` call in
`CursorMeterApp.showPopover()` — part of this change (rev 2, Codex review).
No live tick while the popover stays open (decided: popover is a transient
surface). Accepted consequence: with the popover held open near a boundary,
the label can lag until the next refresh or reopen.

### 2. Absolute-time tooltip

New computed property:

```swift
var resetAbsoluteText: String?   // e.g. "7/10 07:24" (local time zone)
```

Formatted with a `DateFormatter` created locally per call (rev 2: a shared
`nonisolated(unsafe)` mutable `DateFormatter` global is a concurrency
footgun, and the call rate — once per `updateUI()` — makes caching
pointless). Pinned: `locale = en_US_POSIX`, `calendar = .gregorian`,
`dateFormat = "M/d HH:mm"`, time zone left at the user's current zone
(local wall-clock display is the point).
`MenuBarView.updateUI()` assigns it to `resetLabel.toolTip` unconditionally
(nil clears the tooltip). Always set, not only when imminent — one line,
zero cost.

### 3. Cleanup (orphan removal)

`daysUntilReset` — stored property, memberwise-init parameter,
`withOnDemandActive` pass-through, and the private
`daysUntilReset(to:)` factory helper — is deleted: `resetText` was its only
consumer. (`dailyRequestBudget` already reads `cycleStartDate`/`resetDate`
directly and is untouched.)

## Error Handling

- `resetDate == nil` → `resetText` and `resetAbsoluteText` are nil; the
  label renders empty and the tooltip clears (existing behavior).
- Clock skew / API lag past the boundary → the `delta <= 0` branch shows
  "Resets today" until the next refresh delivers the new cycle.

## Testing

Pure-function boundary sweep on `resetCountdownText(until:now:)` with
injected `now` (all offsets relative to a fixed date):

| delta | expected |
|---|---|
| −1h | "Resets today" |
| 0 | "Resets today" |
| 59s | "Resets in <1m" |
| 60s | "Resets in 1m" |
| 59m59s | "Resets in 59m" |
| 60m | "Resets in 1h" |
| 1h01m | "Resets in 1h" |
| 47h59m | "Resets in 47h" |
| 48h | "Resets in 2 days" |
| 49h | "Resets in 2 days" |
| 14d | "Resets in 14 days" |

Plus: `resetText` nil when `resetDate` nil; `resetAbsoluteText` format
check with a fixed Date; existing `UsageDisplayDataTests` resetText cases
migrate from `daysUntilReset:`-based fixtures to `resetDate:`-based ones.

Migration scope (rev 2): every `UsageDisplayData(...)` memberwise call site
loses the `daysUntilReset:` argument — `UsageDisplayDataTests`,
`UsageViewModelTests`, `UsageViewModelJumpTests`, `WeeklyUsageTests` — and
direct `daysUntilReset` assertions in `UsageDisplayDataTests` are replaced
with `resetDate`/`resetText` assertions.

## Workflow Notes

- Display-only change; no API or observation-tracking changes
  (`resetText` is already consumed inside `updateUI()`; freshness comes
  from existing update triggers, not new observable state).
- UI verification after install: popover screenshot not applicable
  (AppKit); verify via `resetLabel` text with a near-boundary fixture in
  tests + manual popover check.
