# Weekly chart `requestsCosts` unit migration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the weekly chart's y-axis from `agent_requests` count (old `/api/v2/analytics/team/usage` endpoint) to `requestsCosts` per-day sum (new `/api/dashboard/get-filtered-usage-events` endpoint) so heavy/Max-mode calls visually outweigh light ones.

**Architecture:** Hard replacement of one Cursor API endpoint with another. Data flow stays similar: `UsageViewModel.refresh()` → `CursorAPIClient.fetchWeeklyUsage(...)` → `[DayUsage]` → `WeeklyUsageChartView`. The old WeeklyUsageResponse / WeeklyUsageRow types are replaced by FilteredUsageEventsResponse / UsageEvent. The `sevenDayRolling(today:calendar:)` entry point keeps the same name and return shape (`[DayUsage]`) so chart wiring stays untouched. The dashed daily-budget reference line is removed per the α decision.

**Tech Stack:** Swift 6, AppKit, Foundation, XCTest. macOS SDK only — no new external dependencies. Existing `MockURLProtocol` test infrastructure reused.

**Spec:** `docs/superpowers/specs/2026-06-07-weekly-chart-requests-costs-design.md`

**Issue:** To be filed in CursorMeter repo before Task 2 begins (per project Issue-First Workflow).

---

## Task 0: File the issue

This change qualifies as a non-trivial behavior change ("CSS/layout/tone changes that the user will see" per global CLAUDE.md, and more — the chart's y-axis semantics change). Per project Issue-First Workflow, file the issue first.

**Files:** none (GitHub only)

- [ ] **Step 1: Create issue in CursorMeter repo**

```bash
gh issue create --repo WoojinAhn/CursorMeter --title "feat: weekly chart switches y-axis to requestsCosts (weighted billing unit)" --body "$(cat <<'EOF'
## Goal

Replace the weekly bar chart's y-axis from raw API-call count (\`agent_requests\`) to Cursor's weighted billing unit (\`requestsCosts\` summed per day). Heavy Max-mode calls (e.g. 100+ requestsCosts per Opus call) visually outweigh light auto-completes (1 requestsCosts per call), making day-to-day relative comparison reflect actual usage intensity.

## Why

Two structural problems with the current chart:

1. **Count is misleading.** A day with 10 light completions looks identical to a day with 10 Max-mode Opus calls.
2. **Data source omits days.** The current endpoint (\`/api/v2/analytics/team/usage\`) returns sparse rows — observed 4 of 7 days returned for a heavy usage week.

The new endpoint (\`/api/dashboard/get-filtered-usage-events\`) returns every event with per-event \`requestsCosts\` and complete coverage.

## Design

Spec: \`docs/superpowers/specs/2026-06-07-weekly-chart-requests-costs-design.md\` (in repo)

Key decisions:
- Unit: \`requestsCosts\` summed per local-calendar day
- Layout: bars only (no daily-budget reference line)
- Window: rolling 7-day (preserved)
- Scope: enterprise team accounts only
- Rollout: hard replace (no fallback to old endpoint)

## Out of scope

- Personal Pro/Free account support (separate issue)
- Standalone \$ chart
- Dynamic on-demand cap display
EOF
)"
```

Expected: prints new issue URL (e.g. `https://github.com/WoojinAhn/CursorMeter/issues/67`). Record this number — every subsequent commit message uses `[#NN]` prefix.

- [ ] **Step 2: Note the issue number locally**

Set a local shell variable for the rest of the plan, e.g. `export ISSUE=67`. (Plan code blocks below assume the placeholder `$ISSUE`.)

---

## Task 1: Document the new endpoint in `API_REFERENCE.md`

Document the endpoint and Origin-header bypass before writing any code. The doc captures the contract the code will implement.

**Files:**
- Modify: `docs/API_REFERENCE.md`

- [ ] **Step 1: Read the current `API_REFERENCE.md`**

Read the whole file. Identify (a) the section that currently mentions `/api/v2/analytics/team/usage` under both "used" and "observed", (b) the section listing Dashboard POST endpoints.

- [ ] **Step 2: Add `/api/dashboard/get-filtered-usage-events` to the "used" section**

Replace any existing "used" block referencing `/api/v2/analytics/team/usage` (weekly chart) with the new endpoint:

```markdown
### `POST /api/dashboard/get-filtered-usage-events`

Per-event usage stream. Used by the weekly bar graph (enterprise team accounts only). Returns events newest-first; pagination via `page` / `pageSize`.

Request:

- Method: `POST`
- Headers:
  - `Cookie: <session cookie header>`
  - `Origin: https://cursor.com` — **required.** Without it the server returns `{"error":"Invalid origin for state-changing request"}` with no events.
  - `Content-Type: application/json`
- Body: `{ "teamId": <int>, "userId": <int>, "page": <int, 1-indexed>, "pageSize": <int> }`

Response shape (truncated):

```json
{
  "totalUsageEventsCount": 1397,
  "usageEventsDisplay": [
    {
      "timestamp": "1780402687672",
      "model": "composer-2.5-fast",
      "kind": "USAGE_EVENT_KIND_INCLUDED_IN_BUSINESS",
      "requestsCosts": 2,
      "usageBasedCosts": "-",
      "isTokenBasedCall": false,
      "tokenUsage": {
        "inputTokens": 3914,
        "outputTokens": 1390,
        "cacheReadTokens": 298176,
        "totalCents": 18.167999267578125
      },
      "owningUser": "232352588",
      "owningTeam": "13403082",
      "chargedCents": 8,
      "isChargeable": true
    }
  ]
}
```

Important shape notes:

- **`timestamp` is a string of UTC epoch milliseconds.** Convert to `Date` via `TimeInterval(timestamp)! / 1000`.
- **`requestsCosts` is the weighted billing unit** — light auto-complete calls weigh 1–2, Max-mode Opus calls can weigh 100+. Cursor's plan limit (e.g. 2000) is denominated in this same unit.
- **Events are returned newest-first by timestamp** within a page. Pagination walks backwards in time; stop when the oldest event in the latest page is older than your window.
- `chargedCents` is the dollar charge for the event. Ratio `chargedCents / requestsCosts` is usually 4 (= \$0.04/unit) but some models (gpt-5.5-medium, claude-opus-4-7-high) use 2, and errored / non-chargeable events use 0.
```

- [ ] **Step 3: Mark the old endpoint as removed**

In the "Endpoints observed (not yet used)" section, find any entry for `/api/v2/analytics/team/usage` (the older one used by v0.3.0 weekly chart) and replace its description with:

```markdown
### `GET /api/v2/analytics/team/usage` (removed in v0.4.x)

Previously used for the weekly chart. Replaced by `POST /api/dashboard/get-filtered-usage-events` because:

1. The old endpoint omits days at cycle boundaries (observed: 5/30, 5/31, 6/1 missing from a known-active week).
2. The old endpoint exposes only request *counts*, not weighted billing units — a Max-mode Opus call and a light auto-complete both contribute 1.

Documented here only for archeology.
```

- [ ] **Step 4: Commit**

```bash
git add docs/API_REFERENCE.md
git commit -m "$(cat <<'EOF'
[#$ISSUE] docs: document get-filtered-usage-events endpoint

Capture the new endpoint, Origin header requirement, response shape, and
the rationale for replacing /api/v2/analytics/team/usage before the code
change lands.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Expected: 1 file changed.

---

## Task 2: Rewrite `WeeklyUsageModels.swift` (new types + same `sevenDayRolling` entry point)

Replace the old ClickHouse-shaped response and per-day row types with the new event-stream types. Keep `DayUsage` and the `sevenDayRolling(today:calendar:)` function name/signature so the chart wiring stays put.

**Files:**
- Modify: `Sources/CursorMeter/WeeklyUsageModels.swift`
- Test: `Tests/CursorMeterTests/WeeklyUsageTests.swift` (will be rewritten in Task 6 — for now we expect it to break)

- [ ] **Step 1: Read current `WeeklyUsageModels.swift`**

Note: `DayUsage` is the chart's consumption shape; preserve it verbatim. `TeamsResponse` and `Team` are independent (used by team-id discovery) and must stay.

- [ ] **Step 2: Replace the file's contents**

Overwrite the file with:

```swift
import Foundation

// MARK: - API Response: /api/dashboard/get-filtered-usage-events

/// Per-event usage stream from Cursor's dashboard backend. Used by the weekly
/// bar graph (enterprise team accounts). See `docs/API_REFERENCE.md` for the
/// request shape and the Origin-header requirement.
struct FilteredUsageEventsResponse: Codable, Sendable {
    let totalUsageEventsCount: Int?
    let usageEventsDisplay: [UsageEvent]
}

struct UsageEvent: Codable, Sendable {
    /// UTC epoch milliseconds as a string (e.g. "1780402687672").
    let timestamp: String
    /// Cursor's weighted billing unit — light auto-completes weigh 1, Max-mode
    /// Opus calls can weigh 100+. Same unit as the plan limit (`Requests: 519 / 2000`).
    /// Nullable on errored / non-chargeable events.
    let requestsCosts: Double?

    /// `Date` parsed from `timestamp`. Returns nil for malformed input.
    var date: Date? {
        guard let ms = Double(timestamp) else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    /// Defensive accessor — nil / non-finite values count as 0 so a single
    /// malformed event can't crash or skew the daily sum.
    var requestsCostsSafe: Double {
        guard let v = requestsCosts, v.isFinite else { return 0 }
        return v
    }
}

// MARK: - API Response: /api/dashboard/teams (unchanged from previous version)

/// Minimal shape — only the fields needed to pick a `teamId` for the
/// dashboard endpoint. The real Cursor dashboard response carries more fields;
/// everything outside `id`/`name` is ignored.
struct TeamsResponse: Codable, Sendable {
    let teams: [Team]
}

struct Team: Codable, Sendable {
    let id: Int
    let name: String?
}

// MARK: - 7-day rolling display model

struct DayUsage: Sendable, Equatable {
    let date: Date
    let requests: Int
    let isToday: Bool
}

extension Array where Element == UsageEvent {
    /// Builds an ordered 7-day array ending on `today` (rightmost). Sums each
    /// event's `requestsCosts` into its local-calendar day; rounds the final
    /// per-day sum to the nearest Int for the chart's display shape. Events
    /// older than the 7-day window are silently ignored.
    ///
    /// `calendar` controls day boundary interpretation (pass `Calendar.current`
    /// in production for KST handling; inject a UTC calendar in tests for
    /// determinism).
    func sevenDayRolling(today: Date = Date(), calendar: Calendar = .current) -> [DayUsage] {
        let startOfToday = calendar.startOfDay(for: today)
        let cutoff = calendar.date(byAdding: .day, value: -6, to: startOfToday)!
        let formatter = Self.dayKeyFormatter(for: calendar)

        var sums: [String: Double] = [:]
        for event in self {
            guard let eventDate = event.date else { continue }
            let day = calendar.startOfDay(for: eventDate)
            guard day >= cutoff, day <= startOfToday else { continue }
            let key = formatter.string(from: day)
            sums[key, default: 0] += event.requestsCostsSafe
        }

        return (0..<7).reversed().map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: startOfToday)!
            let key = formatter.string(from: day)
            let total = sums[key] ?? 0
            return DayUsage(
                date: day,
                requests: Int(total.rounded()),
                isToday: offset == 0
            )
        }
    }

    /// Returns the oldest event's date in the receiver, or nil if none parses.
    /// Used by the paginator to decide whether to fetch another page.
    func oldestEventDate() -> Date? {
        var oldest: Date?
        for event in self {
            guard let d = event.date else { continue }
            if let curr = oldest {
                if d < curr { oldest = d }
            } else {
                oldest = d
            }
        }
        return oldest
    }

    /// Cached `yyyy-MM-dd` formatter keyed by calendar timezone. The rolling
    /// fold runs once per refresh; allocating a fresh `DateFormatter` (~100µs)
    /// each time is wasteful when the timezone is effectively fixed in
    /// production. MainActor-only callsites today, but the cache itself is
    /// read-only after first miss per timezone so concurrent reads are safe.
    private nonisolated(unsafe) static var formatterCache: [String: DateFormatter] = [:]

    private static func dayKeyFormatter(for calendar: Calendar) -> DateFormatter {
        let key = calendar.timeZone.identifier
        if let cached = formatterCache[key] { return cached }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        formatterCache[key] = f
        return f
    }
}
```

- [ ] **Step 3: Run `swift build` to see callers break**

Run: `swift build 2>&1 | head -40`
Expected: build errors mentioning `WeeklyUsageResponse` and `WeeklyUsageRow` in `CursorAPIClient.swift`, `UsageViewModel.swift`, and tests. This is intentional — those callers are migrated in Tasks 3–5.

- [ ] **Step 4: Do NOT commit yet**

The build is broken; commit after Tasks 3–5 land. Leave the working tree dirty.

---

## Task 3: Update `CursorAPIClient` to call the new endpoint

Change `fetchWeeklyUsage(...)`'s signature, switch to `POST` with a JSON body, and add the `Origin` header. Extend `performRequest(...)` to accept an optional body + origin.

**Files:**
- Modify: `Sources/CursorMeter/CursorAPIClient.swift`

- [ ] **Step 1: Replace the endpoint constant**

In `CursorAPIClient.swift`, replace:

```swift
private static let weeklyUsageBase = "https://www.cursor.com/api/v2/analytics/team/usage"
```

with:

```swift
private static let filteredUsageEventsURL = URL(string: "https://www.cursor.com/api/dashboard/get-filtered-usage-events")!
```

- [ ] **Step 2: Replace `fetchWeeklyUsage(...)`**

Replace the entire `fetchWeeklyUsage` function with:

```swift
/// Fetches one page of usage events from the dashboard. Events are returned
/// newest-first; callers paginate by incrementing `page` until the oldest
/// event in a page is older than the desired window (or `totalUsageEventsCount`
/// is reached).
///
/// Requires the `Origin: https://cursor.com` header — the endpoint enforces
/// origin checks on POST. Without it the server returns
/// `{"error":"Invalid origin for state-changing request"}`.
func fetchWeeklyUsage(
    cookieHeader: String,
    teamId: Int,
    userId: Int,
    page: Int,
    pageSize: Int = 100
) async throws -> FilteredUsageEventsResponse {
    let bodyDict: [String: Any] = [
        "teamId": teamId,
        "userId": userId,
        "page": page,
        "pageSize": pageSize,
    ]
    let body = try JSONSerialization.data(withJSONObject: bodyDict, options: [])
    let data = try await performRequest(
        url: Self.filteredUsageEventsURL,
        cookieHeader: cookieHeader,
        method: "POST",
        body: body,
        origin: "https://cursor.com"
    )
    return try JSONDecoder().decode(FilteredUsageEventsResponse.self, from: data)
}
```

- [ ] **Step 3: Extend `performRequest(...)` to accept body + origin**

Replace the existing `performRequest` function with:

```swift
private func performRequest(
    url: URL,
    cookieHeader: String,
    method: String = "GET",
    body: Data? = nil,
    origin: String? = nil
) async throws -> Data {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
    request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
    if let origin {
        request.setValue(origin, forHTTPHeaderField: "Origin")
    }
    if let body {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
    }

    let data: Data
    let response: URLResponse
    do {
        (data, response) = try await session.data(for: request)
    } catch {
        throw APIError.networkError(error)
    }

    guard let httpResponse = response as? HTTPURLResponse else {
        throw APIError.networkError(
            NSError(domain: "CursorMeter", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid response"]))
    }

    if httpResponse.statusCode == 401 {
        throw APIError.unauthorized
    }
    if httpResponse.statusCode == 403 {
        throw APIError.forbidden
    }

    guard (200...299).contains(httpResponse.statusCode) else {
        throw APIError.httpError(statusCode: httpResponse.statusCode)
    }

    return data
}
```

- [ ] **Step 4: Run `swift build`**

Run: `swift build 2>&1 | head -40`
Expected: errors now isolated to `UsageViewModel.swift` (call site) and tests. `CursorAPIClient.swift` itself compiles.

---

## Task 4: Update `UsageViewModel` paginator

Replace both `applyOptimisticWeekly` and `refreshWeeklyChart` to use the new endpoint + pagination loop. Both still produce `[DayUsage]` via the same `sevenDayRolling` call.

**Files:**
- Modify: `Sources/CursorMeter/UsageViewModel.swift`

- [ ] **Step 1: Add userId cache property**

The new endpoint requires `userId` (numeric int), not just email. The existing `UserInfoResponse` exposes a numeric id field. Verify by grepping:

Run: `grep -n "struct UserInfoResponse" -A 12 Sources/CursorMeter/UsageModels.swift`
Expected: see fields like `email`, `name`, and `sub` (string) — but **not** a numeric user id directly.

Cursor's `/api/auth/me` returns `sub` (workos id like `user_01JZ...`), not the numeric `userId` (e.g. `232352588`) the dashboard endpoint expects. The numeric id appears in `get-team-spend` responses. **We need to source it elsewhere.**

Probe: the `get-filtered-usage-events` endpoint also accepts the call without `userId` — it then returns the *team's* events. For per-user filtering we need the numeric id.

For this plan, **fetch the numeric `userId` from `/api/dashboard/get-team-spend`** (already documented in `API_REFERENCE.md`). Add a new fetch and cache it like `cachedTeamId`.

Read `Sources/CursorMeter/UsageViewModel.swift` and locate the `cachedTeamId: Int?` declaration. Add right below it:

```swift
    /// Numeric user id (e.g. 232352588) for the dashboard filtered-usage endpoint.
    /// Discovered from `/api/dashboard/get-team-spend` and cached across refreshes.
    private var cachedUserId: Int?
```

Also extend `resetPerAccountState()` to clear it. Find the function and add:

```swift
        cachedUserId = nil
```

between `cachedTeamId = nil` and `cachedUserEmail = nil`.

And `logout()` similarly — add `cachedUserId = nil` near the `cachedTeamId = nil` line.

- [ ] **Step 2: Add `TeamSpendResponse` + `fetchTeamSpend` to discover `userId`**

In `Sources/CursorMeter/WeeklyUsageModels.swift`, append below the `Team` struct:

```swift
// MARK: - API Response: /api/dashboard/get-team-spend (used solely to discover numeric userId)

struct TeamSpendResponse: Codable, Sendable {
    let teamMemberSpend: [TeamMember]
}

struct TeamMember: Codable, Sendable {
    let userId: Int
    let email: String?
}
```

In `Sources/CursorMeter/CursorAPIClient.swift`, add this constant alongside the others:

```swift
private static let teamSpendURL = URL(string: "https://www.cursor.com/api/dashboard/get-team-spend")!
```

And add this method just below `fetchTeams`:

```swift
/// Fetches the team's member-spend roster solely to discover the caller's
/// numeric `userId`. Required because `/api/auth/me` returns a workos id but
/// the dashboard endpoint expects the numeric id. Same Origin-header
/// requirement as the filtered-usage endpoint.
func fetchTeamSpend(cookieHeader: String, teamId: Int) async throws -> TeamSpendResponse {
    let body = try JSONSerialization.data(withJSONObject: ["teamId": teamId], options: [])
    let data = try await performRequest(
        url: Self.teamSpendURL,
        cookieHeader: cookieHeader,
        method: "POST",
        body: body,
        origin: "https://cursor.com"
    )
    return try JSONDecoder().decode(TeamSpendResponse.self, from: data)
}
```

- [ ] **Step 3: Replace the weekly chart paginator**

In `UsageViewModel.swift`, locate the section between the comment `// MARK: - Weekly chart refresh` and the `func logout()` function.

Replace `makeOptimisticWeeklyTask`, `weeklyWindow`, `applyOptimisticWeekly`, and `refreshWeeklyChart` (delete all four) with the following block. Also delete the `weeklyDateFormatter` static — it's no longer used.

```swift
    // MARK: - Weekly chart refresh

    /// Max pages to walk before giving up. Safety cap — realistic 7-day volume
    /// is ~30 events for an active user, so even a 100-event/day burst stops
    /// well within 5 pages of size 100.
    private static let weeklyMaxPages = 5
    private static let weeklyPageSize = 100

    /// Returns an optimistic weekly task only when we have *both* a cached
    /// teamId and userId — otherwise we have to discover one first via the
    /// sequential path.
    private func makeOptimisticWeeklyTask(
        cookieHeader: String
    ) -> Task<[DayUsage], Error>? {
        guard let teamId = cachedTeamId, let userId = cachedUserId else { return nil }
        let apiClient = self.apiClient
        let pageSize = Self.weeklyPageSize
        let maxPages = Self.weeklyMaxPages
        return Task {
            try await Self.collectWeeklyEvents(
                apiClient: apiClient,
                cookieHeader: cookieHeader,
                teamId: teamId,
                userId: userId,
                pageSize: pageSize,
                maxPages: maxPages
            ).sevenDayRolling(today: Date(), calendar: .current)
        }
    }

    /// Walks pages newest-first, stopping once a page contains events older
    /// than the 7-day cutoff. Returns the flattened event list (caller folds
    /// via `sevenDayRolling`).
    nonisolated static func collectWeeklyEvents(
        apiClient: CursorAPIClient,
        cookieHeader: String,
        teamId: Int,
        userId: Int,
        pageSize: Int,
        maxPages: Int,
        today: Date = Date(),
        calendar: Calendar = .current
    ) async throws -> [UsageEvent] {
        let cutoff = calendar.date(
            byAdding: .day,
            value: -6,
            to: calendar.startOfDay(for: today)
        )!
        var collected: [UsageEvent] = []
        for page in 1...maxPages {
            let response = try await apiClient.fetchWeeklyUsage(
                cookieHeader: cookieHeader,
                teamId: teamId,
                userId: userId,
                page: page,
                pageSize: pageSize
            )
            let events = response.usageEventsDisplay
            collected.append(contentsOf: events)
            if events.isEmpty { break }
            guard let oldest = events.oldestEventDate() else { break }
            if oldest < cutoff { break }
        }
        return collected
    }

    private func applyOptimisticWeekly(_ task: Task<[DayUsage], Error>) async {
        do {
            weeklyData = try await task.value
            isEnterpriseTeam = true
        } catch APIError.forbidden {
            Log.info("Weekly fetch returned 403 — clearing enterprise cache")
            cachedTeamId = nil
            cachedUserId = nil
            isEnterpriseTeam = false
            weeklyData = nil
        } catch {
            Log.info("Weekly fetch failed: \(error.localizedDescription)")
            if weeklyData == nil {
                isEnterpriseTeam = false
            }
        }
    }

    private func refreshWeeklyChart(
        cookieHeader: String,
        data: UsageDisplayData,
        userInfo: UserInfoResponse
    ) async {
        guard data.membershipType?.lowercased() == "enterprise" else {
            isEnterpriseTeam = false
            weeklyData = nil
            return
        }

        // Discover team id if absent.
        if cachedTeamId == nil {
            do {
                let teams = try await apiClient.fetchTeams(cookieHeader: cookieHeader)
                cachedTeamId = teams.teams.first?.id
            } catch {
                Log.info("Teams fetch failed (treating as non-enterprise): \(error.localizedDescription)")
            }
        }
        guard let teamId = cachedTeamId else {
            isEnterpriseTeam = false
            weeklyData = nil
            return
        }

        // Discover numeric userId if absent. Matched by email against team-spend roster.
        if cachedUserId == nil, let email = userInfo.email, !email.isEmpty {
            do {
                let spend = try await apiClient.fetchTeamSpend(cookieHeader: cookieHeader, teamId: teamId)
                cachedUserId = spend.teamMemberSpend.first(where: { $0.email?.lowercased() == email.lowercased() })?.userId
            } catch {
                Log.info("Team-spend fetch failed: \(error.localizedDescription)")
            }
        }
        guard let userId = cachedUserId else {
            isEnterpriseTeam = false
            weeklyData = nil
            return
        }

        do {
            let events = try await Self.collectWeeklyEvents(
                apiClient: apiClient,
                cookieHeader: cookieHeader,
                teamId: teamId,
                userId: userId,
                pageSize: Self.weeklyPageSize,
                maxPages: Self.weeklyMaxPages
            )
            weeklyData = events.sevenDayRolling(today: Date(), calendar: .current)
            isEnterpriseTeam = true
        } catch APIError.forbidden {
            Log.info("Weekly fetch returned 403 — clearing enterprise cache")
            cachedTeamId = nil
            cachedUserId = nil
            isEnterpriseTeam = false
            weeklyData = nil
        } catch {
            Log.info("Weekly fetch failed: \(error.localizedDescription)")
            if weeklyData == nil {
                isEnterpriseTeam = false
            }
        }
    }
```

- [ ] **Step 4: Run `swift build`**

Run: `swift build 2>&1 | head -40`
Expected: only test file errors remain (`Tests/CursorMeterTests/WeeklyUsageTests.swift` references the deleted `WeeklyUsageResponse`/`WeeklyUsageRow`). Main target builds clean.

---

## Task 5: Remove the dashed reference line from `WeeklyUsageChartView`

Per the α decision the chart shows bars only — drop the `dailyBudget` parameter and the line-drawing call.

**Files:**
- Modify: `Sources/CursorMeter/WeeklyUsageChartView.swift`

- [ ] **Step 1: Remove the `dailyBudget` property and update signature**

In `WeeklyUsageChartView.swift`, replace:

```swift
    private var days: [DayUsage] = []
    private var dailyBudget: Int?
    private var style: WeeklyChartStyle = .outline
```

with:

```swift
    private var days: [DayUsage] = []
    private var style: WeeklyChartStyle = .outline
```

Replace the `update(...)` method:

```swift
    func update(days: [DayUsage], style: WeeklyChartStyle) {
        self.days = days
        self.style = style
        self.hoverIndex = nil
        needsDisplay = true
    }
```

- [ ] **Step 2: Drop the budget-aware y-axis ceiling**

In `draw(_:)`, replace:

```swift
        let weeklyMax = days.map(\.requests).max() ?? 0
        let yMaxRaw = max(Double(weeklyMax) * 1.05, Double(dailyBudget ?? 0))
        let yMax: Double = yMaxRaw > 0 ? yMaxRaw : 1

        drawBars(in: ctx, chart: chart, weeklyMax: weeklyMax, yMax: yMax)
        drawBudgetLine(in: ctx, chart: chart, yMax: yMax)
        drawHoverTooltip(in: ctx, chart: chart, yMax: yMax)
```

with:

```swift
        let weeklyMax = days.map(\.requests).max() ?? 0
        let yMaxRaw = Double(weeklyMax) * 1.05
        let yMax: Double = yMaxRaw > 0 ? yMaxRaw : 1

        drawBars(in: ctx, chart: chart, weeklyMax: weeklyMax, yMax: yMax)
        drawHoverTooltip(in: ctx, chart: chart, yMax: yMax)
```

- [ ] **Step 3: Delete `drawBudgetLine(...)`**

Remove the entire `drawBudgetLine(in:chart:yMax:)` function. It is no longer called.

- [ ] **Step 4: Update the call site in `MenuBarView.swift`**

In `Sources/CursorMeter/MenuBarView.swift`, replace the existing `weeklyChartView.update(...)` block (around line 467) with:

```swift
            weeklyChartView.update(
                days: weekly,
                style: viewModel.weeklyChartStyle
            )
```

- [ ] **Step 5: Run `swift build`**

Run: `swift build 2>&1 | head -40`
Expected: main target builds. Only test file errors remain.

---

## Task 6: Rewrite `WeeklyUsageTests.swift` against the new model

The test file currently references the deleted `WeeklyUsageResponse` / `WeeklyUsageRow`. Replace with fixtures and assertions for the new `[UsageEvent]` flow.

**Files:**
- Modify: `Tests/CursorMeterTests/WeeklyUsageTests.swift`

- [ ] **Step 1: Read the current test file**

Note the test helpers (`utcCalendar`, `date(_:)`, `makeDisplayData(...)`, `clearWeeklyChartDefaults()`) — preserve them. Note the existing tests for `dailyRequestBudget`, `WeeklyChartStyle` round-trip, and settings persistence — those stay (they cover non-weekly-specific concerns).

- [ ] **Step 2: Replace the file's contents**

Overwrite `Tests/CursorMeterTests/WeeklyUsageTests.swift` with:

```swift
import XCTest
@testable import CursorMeter

final class WeeklyUsageTests: XCTestCase {

    // MARK: - Helpers

    private var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ ymd: String) -> Date {
        let f = DateFormatter()
        f.calendar = utcCalendar
        f.timeZone = utcCalendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: ymd)!
    }

    private func event(_ ymd: String, cost: Double, hour: Int = 12) -> UsageEvent {
        var comps = DateComponents()
        let day = utcCalendar.dateComponents([.year, .month, .day], from: date(ymd))
        comps.year = day.year; comps.month = day.month; comps.day = day.day
        comps.hour = hour
        comps.timeZone = utcCalendar.timeZone
        let d = utcCalendar.date(from: comps)!
        let ms = Int(d.timeIntervalSince1970 * 1000)
        return UsageEvent(timestamp: String(ms), requestsCosts: cost)
    }

    // MARK: - Response parsing

    func testParseEventsResponse() throws {
        let json = """
        {
          "totalUsageEventsCount": 2,
          "usageEventsDisplay": [
            {"timestamp": "1780402687672", "requestsCosts": 2},
            {"timestamp": "1780402643496", "requestsCosts": 30.5}
          ]
        }
        """
        let response = try JSONDecoder().decode(
            FilteredUsageEventsResponse.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(response.totalUsageEventsCount, 2)
        XCTAssertEqual(response.usageEventsDisplay.count, 2)
        XCTAssertEqual(response.usageEventsDisplay[0].requestsCosts, 2)
        XCTAssertEqual(response.usageEventsDisplay[1].requestsCosts, 30.5)
    }

    func testParseEmptyEventsResponse() throws {
        let json = """
        { "totalUsageEventsCount": 0, "usageEventsDisplay": [] }
        """
        let response = try JSONDecoder().decode(
            FilteredUsageEventsResponse.self,
            from: Data(json.utf8)
        )
        XCTAssertTrue(response.usageEventsDisplay.isEmpty)
    }

    func testParseEventIgnoresExtraFields() throws {
        // Real payload has many extra keys; only timestamp + requestsCosts are read.
        let json = """
        {
          "timestamp": "1780402687672",
          "requestsCosts": 2,
          "model": "composer-2.5-fast",
          "kind": "USAGE_EVENT_KIND_INCLUDED_IN_BUSINESS",
          "tokenUsage": {"totalCents": 18.17},
          "chargedCents": 8
        }
        """
        let event = try JSONDecoder().decode(UsageEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.timestamp, "1780402687672")
        XCTAssertEqual(event.requestsCosts, 2)
    }

    // MARK: - UsageEvent helpers

    func testEventDateParsesMillis() {
        let e = UsageEvent(timestamp: "1780402687672", requestsCosts: 1)
        XCTAssertEqual(e.date?.timeIntervalSince1970, 1780402687.672)
    }

    func testEventDateReturnsNilForMalformedTimestamp() {
        let e = UsageEvent(timestamp: "not-a-number", requestsCosts: 1)
        XCTAssertNil(e.date)
    }

    func testRequestsCostsSafeFallsBackOnNil() {
        let e = UsageEvent(timestamp: "1780402687672", requestsCosts: nil)
        XCTAssertEqual(e.requestsCostsSafe, 0)
    }

    func testRequestsCostsSafeFallsBackOnInfinity() {
        let e = UsageEvent(timestamp: "1780402687672", requestsCosts: .infinity)
        XCTAssertEqual(e.requestsCostsSafe, 0)
    }

    // MARK: - sevenDayRolling

    func testSevenDayRollingProducesSevenEntries() {
        let days = ([] as [UsageEvent]).sevenDayRolling(today: date("2026-05-13"), calendar: utcCalendar)
        XCTAssertEqual(days.count, 7)
    }

    func testSevenDayRollingTodayIsRightmost() {
        let days = ([] as [UsageEvent]).sevenDayRolling(today: date("2026-05-13"), calendar: utcCalendar)
        XCTAssertTrue(days.last!.isToday)
        XCTAssertFalse(days.dropLast().contains(where: { $0.isToday }))
    }

    func testSevenDayRollingZeroFillsMissingDates() {
        let days = ([] as [UsageEvent]).sevenDayRolling(today: date("2026-05-13"), calendar: utcCalendar)
        XCTAssertTrue(days.allSatisfy { $0.requests == 0 })
    }

    func testSevenDayRollingSumsCostsPerDay() {
        let events: [UsageEvent] = [
            event("2026-05-08", cost: 13),
            event("2026-05-08", cost: 2),
            event("2026-05-13", cost: 7),
        ]
        let days = events.sevenDayRolling(today: date("2026-05-13"), calendar: utcCalendar)
        // Window: 05-07, 05-08, 05-09, 05-10, 05-11, 05-12, 05-13
        XCTAssertEqual(days[0].requests, 0, "2026-05-07 missing")
        XCTAssertEqual(days[1].requests, 15, "2026-05-08: 13 + 2")
        XCTAssertEqual(days[6].requests, 7, "today (2026-05-13)")
    }

    func testSevenDayRollingIgnoresEventsOutsideWindow() {
        let events: [UsageEvent] = [
            event("2026-05-01", cost: 999),
            event("2026-05-20", cost: 999),
        ]
        let days = events.sevenDayRolling(today: date("2026-05-13"), calendar: utcCalendar)
        XCTAssertEqual(days.map(\.requests), [0, 0, 0, 0, 0, 0, 0])
    }

    func testSevenDayRollingRoundsFractionalCosts() {
        let events: [UsageEvent] = [
            event("2026-05-13", cost: 2.7),
            event("2026-05-13", cost: 3.5),
        ]
        let days = events.sevenDayRolling(today: date("2026-05-13"), calendar: utcCalendar)
        XCTAssertEqual(days[6].requests, 6, "2.7 + 3.5 = 6.2 → rounds to 6")
    }

    func testSevenDayRollingSkipsMalformedTimestamps() {
        let events: [UsageEvent] = [
            UsageEvent(timestamp: "nope", requestsCosts: 999),
            event("2026-05-13", cost: 5),
        ]
        let days = events.sevenDayRolling(today: date("2026-05-13"), calendar: utcCalendar)
        XCTAssertEqual(days[6].requests, 5)
    }

    func testSevenDayRollingTreatsNilCostAsZero() {
        let events: [UsageEvent] = [
            UsageEvent(timestamp: String(Int(date("2026-05-13").timeIntervalSince1970 * 1000)), requestsCosts: nil),
            event("2026-05-13", cost: 4),
        ]
        let days = events.sevenDayRolling(today: date("2026-05-13"), calendar: utcCalendar)
        XCTAssertEqual(days[6].requests, 4)
    }

    // MARK: - oldestEventDate

    func testOldestEventDateOnEmpty() {
        XCTAssertNil(([] as [UsageEvent]).oldestEventDate())
    }

    func testOldestEventDatePicksMin() {
        let events: [UsageEvent] = [
            event("2026-05-13", cost: 1),
            event("2026-05-08", cost: 1),
            event("2026-05-10", cost: 1),
        ]
        let oldest = events.oldestEventDate()
        XCTAssertEqual(oldest?.timeIntervalSince1970, event("2026-05-08", cost: 1).date?.timeIntervalSince1970)
    }

    // MARK: - collectWeeklyEvents pagination

    func testCollectWeeklyEventsStopsOnOldEvent() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = CursorAPIClient(configuration: config)
        defer { MockURLProtocol.requestHandler = nil }

        var pagesRequested: [Int] = []
        MockURLProtocol.requestHandler = { request in
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let page = body["page"] as? Int ?? 0
            pagesRequested.append(page)
            // Page 1: events from yesterday + 8 days ago — second event triggers stop.
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let oldMs = Int(self.date("2026-05-05").timeIntervalSince1970 * 1000)
            let newMs = Int(self.date("2026-05-12").timeIntervalSince1970 * 1000)
            let json = """
            { "totalUsageEventsCount": 2,
              "usageEventsDisplay": [
                {"timestamp": "\(newMs)", "requestsCosts": 1},
                {"timestamp": "\(oldMs)", "requestsCosts": 1}
              ] }
            """
            return (resp, Data(json.utf8))
        }

        let events = try await UsageViewModel.collectWeeklyEvents(
            apiClient: client,
            cookieHeader: "session=x",
            teamId: 42,
            userId: 232352588,
            pageSize: 100,
            maxPages: 5,
            today: date("2026-05-13"),
            calendar: utcCalendar
        )

        XCTAssertEqual(pagesRequested, [1], "stopped after page 1 because oldest event < cutoff")
        XCTAssertEqual(events.count, 2)
    }

    func testCollectWeeklyEventsHitsMaxPagesCap() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = CursorAPIClient(configuration: config)
        defer { MockURLProtocol.requestHandler = nil }

        var pagesRequested: [Int] = []
        MockURLProtocol.requestHandler = { request in
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let page = body["page"] as? Int ?? 0
            pagesRequested.append(page)
            // Every page returns events within the 7-day window — paginator never stops naturally.
            let newMs = Int(self.date("2026-05-13").timeIntervalSince1970 * 1000)
            let json = """
            { "totalUsageEventsCount": 600,
              "usageEventsDisplay": [
                {"timestamp": "\(newMs)", "requestsCosts": 1}
              ] }
            """
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(json.utf8))
        }

        _ = try await UsageViewModel.collectWeeklyEvents(
            apiClient: client,
            cookieHeader: "session=x",
            teamId: 42,
            userId: 232352588,
            pageSize: 100,
            maxPages: 5,
            today: date("2026-05-13"),
            calendar: utcCalendar
        )

        XCTAssertEqual(pagesRequested, [1, 2, 3, 4, 5])
    }

    func testCollectWeeklyEventsStopsOnEmptyPage() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = CursorAPIClient(configuration: config)
        defer { MockURLProtocol.requestHandler = nil }

        var pagesRequested: [Int] = []
        MockURLProtocol.requestHandler = { request in
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let page = body["page"] as? Int ?? 0
            pagesRequested.append(page)
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
            { "totalUsageEventsCount": 0, "usageEventsDisplay": [] }
            """
            return (resp, Data(json.utf8))
        }

        let events = try await UsageViewModel.collectWeeklyEvents(
            apiClient: client,
            cookieHeader: "session=x",
            teamId: 42,
            userId: 232352588,
            pageSize: 100,
            maxPages: 5,
            today: date("2026-05-13"),
            calendar: utcCalendar
        )

        XCTAssertEqual(pagesRequested, [1])
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - fetchWeeklyUsage (CursorAPIClient request shape)

    func testFetchWeeklyUsageSendsOriginAndBody() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = CursorAPIClient(configuration: config)
        defer { MockURLProtocol.requestHandler = nil }

        var captured: URLRequest?
        MockURLProtocol.requestHandler = { request in
            captured = request
            let json = """
            { "totalUsageEventsCount": 0, "usageEventsDisplay": [] }
            """
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(json.utf8))
        }

        _ = try await client.fetchWeeklyUsage(
            cookieHeader: "session=x",
            teamId: 42,
            userId: 232352588,
            page: 3,
            pageSize: 50
        )

        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "session=x")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://cursor.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertTrue(request.url!.path.hasSuffix("/api/dashboard/get-filtered-usage-events"))

        // MockURLProtocol drops httpBody; the implementation also exposes it
        // via httpBodyStream. Read whichever is present so the assertion is
        // resilient to URLProtocol's body-handling quirks.
        let bodyData: Data = {
            if let direct = request.httpBody { return direct }
            guard let stream = request.httpBodyStream else { return Data() }
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var out = Data()
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                out.append(buffer, count: read)
            }
            return out
        }()
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        XCTAssertEqual(parsed["teamId"] as? Int, 42)
        XCTAssertEqual(parsed["userId"] as? Int, 232352588)
        XCTAssertEqual(parsed["page"] as? Int, 3)
        XCTAssertEqual(parsed["pageSize"] as? Int, 50)
    }

    func testFetchWeeklyUsage403ThrowsForbidden() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = CursorAPIClient(configuration: config)
        defer { MockURLProtocol.requestHandler = nil }

        MockURLProtocol.requestHandler = { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }

        do {
            _ = try await client.fetchWeeklyUsage(
                cookieHeader: "session=x",
                teamId: 42,
                userId: 232352588,
                page: 1
            )
            XCTFail("Expected forbidden")
        } catch APIError.forbidden {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    // MARK: - dailyRequestBudget (still used by other call sites — leave covered)

    private func makeDisplayData(
        requestsLimit: Int,
        cycleStart: String?,
        cycleEnd: String?
    ) -> UsageDisplayData {
        UsageDisplayData(
            email: "x", name: "x", membershipType: "enterprise",
            planUsedCents: nil, planLimitCents: nil,
            serverPercentUsed: nil,
            requestsUsed: 0,
            requestsLimit: requestsLimit,
            onDemandUsedCents: nil, onDemandLimitCents: nil,
            onDemandEnabled: nil,
            isOnDemandActive: false,
            cycleStartDate: cycleStart.map { date($0) },
            resetDate: cycleEnd.map { date($0) },
            daysUntilReset: nil
        )
    }

    func testDailyRequestBudgetStillReturnsValue() {
        // Property is no longer consumed by the chart but other display logic
        // may still reference it. Keep coverage to catch accidental removal.
        let data = makeDisplayData(
            requestsLimit: 1500,
            cycleStart: "2026-05-01",
            cycleEnd: "2026-06-01"
        )
        XCTAssertEqual(data.dailyRequestBudget, 1500 / 31)
    }

    // MARK: - WeeklyChartStyle + UsageViewModel settings persistence

    @MainActor
    func testWeeklyChartStyleRawValueRoundTrip() {
        for style in WeeklyChartStyle.allCases {
            XCTAssertEqual(WeeklyChartStyle(rawValue: style.rawValue), style)
        }
    }

    @MainActor
    func testWeeklyChartSettingsDefaults() {
        clearWeeklyChartDefaults()
        let vm = UsageViewModel()
        XCTAssertTrue(vm.weeklyChartEnabled)
        XCTAssertEqual(vm.weeklyChartStyle, .outline)
    }

    @MainActor
    func testSetWeeklyChartEnabledPersists() {
        clearWeeklyChartDefaults()
        let vm = UsageViewModel()
        vm.setWeeklyChartEnabled(false)

        XCTAssertFalse(vm.weeklyChartEnabled)
        XCTAssertEqual(UserDefaults.standard.bool(forKey: "weeklyChartEnabled"), false)

        let reloaded = UsageViewModel()
        XCTAssertFalse(reloaded.weeklyChartEnabled)
    }

    @MainActor
    func testSetWeeklyChartStylePersists() {
        clearWeeklyChartDefaults()
        let vm = UsageViewModel()
        vm.setWeeklyChartStyle(.both)

        XCTAssertEqual(vm.weeklyChartStyle, .both)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "weeklyChartStyle"), WeeklyChartStyle.both.rawValue)

        let reloaded = UsageViewModel()
        XCTAssertEqual(reloaded.weeklyChartStyle, .both)
    }

    private func clearWeeklyChartDefaults() {
        UserDefaults.standard.removeObject(forKey: "weeklyChartEnabled")
        UserDefaults.standard.removeObject(forKey: "weeklyChartStyle")
    }
}
```

- [ ] **Step 3: Run `swift test` and watch for failures**

Run: `swift test 2>&1 | tail -40`
Expected: all tests pass. If any fail, fix in place — every test in this file is fully specified above.

- [ ] **Step 4: Commit the full code change set**

```bash
git add Sources/CursorMeter/WeeklyUsageModels.swift Sources/CursorMeter/CursorAPIClient.swift Sources/CursorMeter/UsageViewModel.swift Sources/CursorMeter/WeeklyUsageChartView.swift Sources/CursorMeter/MenuBarView.swift Tests/CursorMeterTests/WeeklyUsageTests.swift
git commit -m "$(cat <<'EOF'
[#$ISSUE] feat: weekly chart y-axis becomes requestsCosts sum

Swap data source from GET /api/v2/analytics/team/usage (request count) to
POST /api/dashboard/get-filtered-usage-events (per-event requestsCosts).
The new unit captures model/mode heaviness automatically — a single
Max-mode Opus call can weigh 100+ units while a light auto-complete
weighs 1, so daily relative comparison reflects actual usage intensity
rather than call frequency.

Also drops the dashed daily-budget reference line (α decision: bars
only).

Origin: https://cursor.com header is required on the new POST endpoint;
documented in API_REFERENCE.md.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Expected: 1 commit, ~6 files changed.

---

## Task 7: Build the app bundle and verify manually

The data swap is invisible until launched. Per project CLAUDE.md, AppKit changes must be tested in the real app.

**Files:** none (verification only)

- [ ] **Step 1: Kill any running instance and rebuild**

```bash
pkill -9 -x CursorMeter || true
rm -rf /Applications/CursorMeter.app
bash Scripts/package_app.sh
cp -r CursorMeter.app /Applications/
open /Applications/CursorMeter.app
```

Expected: app launches, menu bar icon appears.

- [ ] **Step 2: Verify the popover chart**

Open the popover. Confirm:

- 7 bars visible (assuming an enterprise account with usage)
- **No dashed daily-budget line** within the chart area
- Bar heights now reflect weighted activity (Max-mode/Opus days should look proportionally taller than before)
- Hover tooltip displays integer count of requestsCosts ("Mon: 87")
- "Resets in N days" text unchanged below the chart

If a day that used heavy Max-mode Opus calls now towers over days with many light completions, the migration is working as intended.

- [ ] **Step 3: Verify error paths**

Optional spot-checks:

- Log out (Settings → Log Out) — chart disappears, popover stays functional
- Log back in — chart re-populates after one refresh cycle

- [ ] **Step 4: Capture a screenshot for the issue**

```bash
# Use the system screenshot binding (Cmd+Shift+4) or `screencapture` to grab the popover.
screencapture -i ~/Desktop/issue-$ISSUE-after.png
```

Attach to the issue as visual confirmation. Comment on the issue with a one-line summary and the screenshot.

---

## Task 8: Wrap-up

**Files:** none

- [ ] **Step 1: Close the issue**

```bash
gh issue close $ISSUE --comment "Shipped on main. Weekly chart now sums requestsCosts per day."
```

- [ ] **Step 2: Verify clean working tree**

```bash
git status
```

Expected: clean.

- [ ] **Step 3: Show remaining open issues per project workflow**

```bash
gh issue list --state open
```

Report the list to the user (per project CLAUDE.md issue post-close convention).

---

## Self-Review Notes

Coverage check against spec sections:

- §1 Goal & Scope → Tasks 1 (docs), 6 (test "scope check" via fixtures matching spec assumptions), 7 (manual verify)
- §2 Data Flow → Task 4 (paginator implementation)
- §3 UI Changes → Task 5 (chart cleanup) + Task 4 (call site)
- §4 Files Affected → Tasks 2, 3, 4, 5, 6 cover every file in the spec table
- §5 Error Handling → Task 4 (403 cache reset, generic catch keeps stale data) + Task 6 (`testFetchWeeklyUsage403ThrowsForbidden`)
- §6 Testing Strategy → Task 6 (every row in the spec's test table has a corresponding `func test...` in the new file)
- §7 Out-of-Scope Discoveries → recorded in spec, not in plan (correctly)
- §8 Open Questions → none

No placeholders, no "TBD", no "similar to Task N". Method names cross-checked: `collectWeeklyEvents`, `oldestEventDate`, `sevenDayRolling`, `fetchWeeklyUsage`, `fetchTeamSpend`, `cachedUserId` all consistent across tasks.
