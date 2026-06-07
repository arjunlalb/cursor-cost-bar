# Weekly chart: switch unit from `agent_requests` count to `requestsCosts` sum

**Status:** Design — pending implementation
**Date:** 2026-06-07
**Scope:** Enterprise team accounts only (current chart audience)

## §1. Goal & Scope

### Goal

Replace the weekly bar chart's y-axis from raw API-call count (`agent_requests`) to Cursor's weighted billing unit (`requestsCosts` summed per day). The new unit captures model/mode heaviness automatically — a single Max-mode Opus call can weigh 100+ units while a light auto-complete weighs 1 unit — so day-to-day relative comparison reflects actual usage intensity rather than call frequency.

### Why this change

The current chart counts every API call equally. Investigation against the live Cursor API shows two problems:

1. **Count is misleading for intensity comparison.** A day with 10 light completions looks identical to a day with 10 Max-mode Opus calls, even though the second consumes far more plan capacity.
2. **The data source omits days entirely.** Probing `/api/v2/analytics/team/usage` against the user's prior cycle showed only 4 of 7 days returned rows; days near the cycle boundary disappear sparsely. Some heavy-usage days are completely invisible.

The new endpoint (`/api/dashboard/get-filtered-usage-events`) returns every event individually with per-event `requestsCosts` and `chargedCents`. Summing `requestsCosts` per day gives a weight-adjusted, complete daily series.

### In scope

- Enterprise team accounts (current chart visibility gating)
- Data source: `POST /api/dashboard/get-filtered-usage-events` (requires `Origin: https://cursor.com` header)
- Rolling 7-day window (current behavior preserved)
- Bars only — no daily-budget reference line (existing dashed line removed)
- Heat-color (green/yellow/red by weekly max) preserved
- Today-highlight Settings option (Outline/Dim/Both) preserved

### Out of scope

- Personal Pro / Free account support (separate issue — endpoint compatibility unverified)
- Standalone $ chart or dual-axis layout
- Daily-budget or limit reference lines
- Per-model breakdown in chart or tooltip
- Dynamic display of `effectivePerUserLimitDollars` cap changes (covered by existing on-demand row)
- "Day N of M" cycle-position text under chart (redundant with existing "Resets in N days")

## §2. Data Flow

```
UsageViewModel.refresh()
  ├─ existing 3 calls (usage-summary, usage, auth/me) — unchanged
  └─ weekly fetch ✅ rewritten
     ├─ POST /api/dashboard/get-filtered-usage-events
     │     Body: { teamId, userId, page, pageSize: 100 }
     │     Headers: Cookie + "Origin: https://cursor.com"
     ├─ for each page (max 5):
     │     - decode FilteredUsageEventsResponse
     │     - if oldest event timestamp < today−7days (KST midnight), stop
     │     - else page++
     ├─ flatten events, convert timestamps (UTC epoch ms) to KST yyyy-MM-dd
     ├─ sum requestsCosts per day key
     └─ build 7-element DayUsage array via sevenDayRolling(...) (zero-fill missing days)
```

### Pagination policy

- Page 1 first; events are returned newest-first.
- After each page, inspect the oldest event's timestamp. If older than the 7-day window cutoff, stop — remaining pages cannot contribute to the window.
- Hard cap: 5 pages (= 500 events). Far exceeds realistic 7-day volume (current user shows ~30 events/week across 11 months of history).

### Call frequency

Same as existing weekly fetch — once per `UsageViewModel.refresh()` cycle. Refresh interval is user-configurable (existing setting).

## §3. UI Changes

Visually almost identical to v0.3.0 — only data and the removed reference line change.

| Element | Current (v0.3.0) | After |
|---------|------------------|-------|
| 7 bars (Fri–Thu) | per-day `agent_requests` count | per-day `requestsCosts` sum |
| Bar heat color | weekly max relative | **unchanged** |
| Today-highlight (Settings) | Outline / Dim others / Both | **unchanged** |
| Hover tooltip | `"Mon: 22 requests"` | `"Mon: 87 requests"` — label "requests" retained for consistency with Cursor's own UI (`Requests: 519 / 2000`) |
| Adaptive y-axis ceiling | by weekly max | **unchanged** (same logic, just different unit) |
| Dashed daily-budget reference line | drawn at `planLimit / cycleDays` | **removed** (α decision: bars only) |
| Cycle context text below chart | `"Resets in 26 days"` | **unchanged** |

## §4. Files Affected

| File | Change | Notes |
|------|--------|-------|
| `Sources/CursorMeter/WeeklyUsageModels.swift` | rewrite | Drop `WeeklyUsageResponse` / `WeeklyUsageRow`. Add `FilteredUsageEventsResponse` / `UsageEvent`. Keep `DayUsage` and `sevenDayRolling` signatures; rewrite internals to sum per-event `requestsCosts` by KST day key |
| `Sources/CursorMeter/CursorAPIClient.swift` | edit | Replace `fetchWeeklyUsage(...)` signature. New: `(teamId, userId, page)` → `FilteredUsageEventsResponse`. POST with JSON body, `Origin` header. Add optional `origin:` parameter to `performRequest` |
| `Sources/CursorMeter/UsageViewModel.swift` | edit | Update call site. Add pagination loop (max 5 pages, stop on 7-day boundary). Flatten/sum/build `[DayUsage]` |
| `Sources/CursorMeter/MenuBarView.swift` | edit | Remove dashed reference line draw call. No new text below chart |
| `Sources/CursorMeter/WeeklyUsageChartView.swift` | edit | Remove reference line rendering (dashed daily-budget line) |
| `Tests/CursorMeterTests/WeeklyUsageTests.swift` | rewrite | Replace fixtures with event-array form. New tests for pagination stop, KST conversion, requestsCosts sum, nil/missing handling |
| `Tests/Resources/usage-events-sample.json` | new | Real masked response capture for golden tests |
| `docs/API_REFERENCE.md` | edit | Move `/api/dashboard/get-filtered-usage-events` to "used" section. Document Origin header bypass. Mark `/api/v2/analytics/team/usage` as deprecated/removed |

### Commit order

1. `docs/API_REFERENCE.md` — endpoint documentation
2. `WeeklyUsageModels.swift` + tests — data model in isolation
3. `CursorAPIClient.swift` — network layer
4. `UsageViewModel.swift` — pagination loop
5. UI (`MenuBarView.swift` / `WeeklyUsageChartView.swift`) — remove reference line

## §5. Error Handling & Edge Cases

| Case | Behavior |
|------|----------|
| 200 + empty events | All 7 bars = 0. Chart visible but flat. No "no usage" label (matches current behavior) |
| 200 + no events in 7-day window | Same as empty — all bars = 0 |
| 401 / 403 (auth failed) | Existing logout flow. Chart hides |
| 404 (endpoint removed) | Existing error toast. Chart hides |
| 5xx | Existing error toast. Previous `weeklyData` retained (stale display) |
| Network timeout | Existing retry/offline logic reused |
| `"Invalid origin"` error (Cursor blocks header bypass) | Treated as generic fetch failure — chart hides silently. Signal to log/investigate but no user-visible disclaimer |
| Pagination page N fails mid-loop | Stop immediately. Display partial data collected so far. No disclaimer |
| 5-page cap exceeded before 7-day boundary | Stop. Use partial data. Should be unreachable in practice (would require ~70+ events/day for a week) |
| Cycle rollover within 7-day window | Bars include prior cycle days. Rolling 7-day decision (가) says: show them anyway, no visual separator |
| Account switch / logout | `clearCachedData()` clears events cache alongside existing `weeklyData` |
| `requestsCosts` nil / non-numeric on an event | Treat as 0 (defensive `?? 0`). Log via existing logging if frequent |

### Assumptions

- **Events returned newest-first.** Verified empirically against pages 1, 10, 28. If this ordering breaks, the 7-day-boundary stop condition becomes incorrect. Covered by a test that asserts the contract.
- **`requestsCosts` is numeric on every billable event.** Verified across 13 models in 300-event probe. Defensive 0-fallback covers anomalies.
- **KST is the user's calendar.** Existing code uses `Calendar.current`; same assumption preserved.

## §6. Testing Strategy

Existing 19 `WeeklyUsageTests` largely reusable (zero-fill, KST keying, sevenDayRolling shape are unchanged). New tests fill the pagination/timestamp/sum dimensions.

| Test | New / Existing | Coverage |
|------|---------------|----------|
| `sevenDayRolling` sums per day | new | Multiple events same date → summed |
| Zero-fill missing days | existing — fixture swap | No events for a date → 0 bar |
| Timestamp → KST day key | new | UTC midnight, KST 09:00 boundary cases |
| Pagination stops on 7-day boundary | new | Events older than cutoff → no further page fetch |
| Pagination 5-page cap | new | Synthetic 600-event stream (pageSize 100) → stop at page 5 with partial sum |
| Empty events array | existing — fixture swap | 7 zero bars |
| Cycle boundary inside 7-day window | existing — fixture swap | Sum across boundary still correct |
| Single-page sufficient case | new | Realistic typical user load (~30 events/week) |
| `requestsCosts` nil/missing | new | Falls back to 0 without crash |
| Real captured fixture golden | new | `usage-events-sample.json` produces expected `[DayUsage]` |

### Untestable in unit form

- Live endpoint behavior (network layer) — mock `URLSession`, existing pattern
- `Origin` header bypass durability — Cursor-side decision. Production logging only

## §7. Out-of-Scope Discoveries (for `.claude/notes.md`)

During investigation we found additional Cursor API behavior worth noting but not fixing here:

- `effectivePerUserLimitDollars` is dynamic (user-extensible via override) but currently hard-handled as $40 in popover. Worth separate issue for accuracy.
- `chargedCents / requestsCosts` ratio is **not** a single constant: most events use $0.04/unit, but `gpt-5.5-medium` and `claude-opus-4-7-high` use $0.02/unit, and some `default` events use $0/unit (errored/free). Affects any future $-conversion display.
- `USAGE_EVENT_KIND_ERRORED_NOT_CHARGED` events exist with `requestsCosts > 0`. Current design includes them in the sum (since they're still observable usage); could be excluded if "billable only" semantics are preferred.
- Older endpoint `/api/v2/analytics/team/usage` reliably omits days at cycle boundaries — root cause unknown. Likely Cursor-side analytics lag. Documenting in `API_REFERENCE.md` removal note.

## §8. Open Questions

None blocking implementation. All four design decisions made:

- Unit: `requestsCosts` per-day sum ✅
- Layout: α (bars only, no reference line) ✅
- Window: Rolling 7-day ✅
- Scope: Enterprise-only ✅
- Rollout: Hard replace (no fallback) ✅
