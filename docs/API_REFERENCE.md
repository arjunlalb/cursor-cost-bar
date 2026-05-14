# Cursor API — Reference

Internal reference for the (undocumented) Cursor API surface used by CursorMeter. All endpoints are observed via the `cursor.com/dashboard` web client.

> **Status disclaimer**: every endpoint listed here is undocumented and not part of any public contract. Schemas, paths, query parameters, and authentication mechanics can change without notice. Treat as best-effort observation, not as a stable API.

## Authentication

- **Session cookie** captured by `LoginWindow` after web-based login (`https://www.cursor.com/dashboard`).
- The auth-bearing cookie is `WorkosCursorSessionToken` (current as of 2026-05). See `LoginWindow.requiredCookieNames`.
- All endpoints below are GETs/POSTs with cookies attached.
- **Bearer-token Admin API** at `api.cursor.com/teams/*` is a separate surface (team admin only) and is **not used by this app**.

## Endpoints used by CursorMeter (production code)

### `GET /api/auth/me`

User identity. Used to render display name / email and gate UI for logged-in state.

Response (excerpt):
```json
{ "email": "...", "name": "...", "sub": "user_..." }
```

### `GET /api/usage-summary`
### `GET /api/usage-summary?teamId=<id>`

Plan-level summary (billing cycle, plan percentage, membership type, USD-cents counters when on a credit-based plan).

Response shape consumed by `UsageDisplayData.from(summary:)` (see `UsageModels.swift`):
- `billingCycleEnd: ISO-8601 string`
- `planUsedCents`, `planLimitCents` (Int) — present when the plan is credit-based
- `serverPercentUsed` (Double) — for percent-only plans
- `membershipType`, `isPercentOnly`, `isCreditBased`

The `teamId` variant is observed when an enterprise team is active. CursorMeter currently calls the un-suffixed form; this is sufficient on personal accounts.

### `GET /api/usage?user=<sub>`

Per-model request counts for the current billing cycle. Dynamic-key payload — model names appear as top-level keys and CursorMeter parses with `Codable` dictionary handling (`UsageModels.swift`).

Response (excerpt):
```json
{
  "gpt-4o-mini": { "numRequests": 142, "maxRequestUsage": null, ... },
  "claude-sonnet-4": { "numRequests": 47, ... },
  ...
  "startOfMonth": "...",
  "globalRequests": 0
}
```

The `?user=<sub>` query parameter takes the `sub` returned by `/api/auth/me`.

### `GET /api/dashboard/teams`

Sole source of `teamId` for the analytics endpoints. Used by `CursorAPIClient.fetchTeams` to discover the active team once per session (cached afterwards). Response:

```json
{ "teams": [{ "id": 13403082, "name": "..." }] }
```

`GET`, no body. Empty / non-200 on personal plans → CursorMeter treats the account as non-enterprise and hides the weekly chart.

### `GET /api/v2/analytics/team/usage`

Per-day breakdown of request usage. Used by the weekly bar graph (enterprise team accounts only). See "Endpoints observed" below for the full response shape.

## Endpoints observed (not yet used)

### `GET /api/v2/analytics/team/usage`

Per-day breakdown of request usage. Source for a weekly bar graph (#weekly-bar-graph). **Observed on enterprise-team accounts only**; personal-plan compatibility is unverified.

Query parameters:
- `startDate=YYYY-MM-DD` (UTC date, inclusive)
- `endDate=YYYY-MM-DD` (UTC date, inclusive)
- `teamId=<int>` — required on enterprise; behavior without it on personal accounts is unverified
- `user=<email>` — optional. Without it the response covers the whole team (on enterprise); with it the response is filtered to one member.

Response shape (ClickHouse-style `meta` + `data`):
```json
{
  "meta": [
    {"name":"event_date","type":"Date"},
    {"name":"composer_requests","type":"Int64"},
    {"name":"chat","type":"Int64"},
    {"name":"agent_requests","type":"Int64"},
    {"name":"subscription_included_requests","type":"Int64"},
    {"name":"usage_based_requests","type":"Int64"},
    {"name":"bugBot","type":"Int64"},
    {"name":"cmdK","type":"Int64"},
    {"name":"api_key_requests","type":"Int64"}
  ],
  "data": [
    {
      "event_date": "2026-05-08",
      "composer_requests": 0, "chat": 0, "agent_requests": 13,
      "subscription_included_requests": 13, "usage_based_requests": 0,
      "bugBot": 0, "cmdK": 0, "api_key_requests": 0
    },
    ...
  ]
}
```

Important shape notes:
- **Sparse** — days with zero activity are omitted. Clients must zero-fill missing dates when rendering a continuous timeline.
- `subscription_included_requests` is the closest analog to the menu-bar ring's "used vs plan limit" axis (i.e. requests counted against the included quota).
- `usage_based_requests` is the on-demand / overage axis.
- Other columns are a request-type breakdown (orthogonal to per-model breakdown — see `/models` below).

### `GET /api/v2/analytics/team/models`
### `GET /api/v2/analytics/team/models/aggregated`

Per-model usage. `timeseries` form is daily; `aggregated` is one row per model summed over the range. Useful for a "models" breakdown chart (#B).

### `GET /api/v2/analytics/team/composer`
### `GET /api/v2/analytics/team/tabs`
### `GET /api/v2/analytics/team/ai-commits/timeseries`
### `GET /api/v2/analytics/team/leaderboard`

Other observed analytics endpoints, all with the same `startDate=/endDate=/teamId=` shape. Not currently planned for use; documented here for reference.

### Dashboard POST endpoints

Many `/api/dashboard/*` POST endpoints exist (e.g. `get-team-spend`, `get-current-billing-cycle`, `get-hard-limit`, `get-credit-grants-balance`). Not currently planned for use; recorded for future spend/forecast features.

## Known limitations / open questions

- **Personal Pro / Free plan compatibility for `/api/v2/analytics/team/*`** — unverified. Endpoints may require `teamId`, or may not exist at all for non-enterprise users. Implement enterprise-team path first, fall back to local snapshot for personal plans.
- **Pagination** — none observed. All ranges return a single payload.
- **Stability** — all paths are undocumented. Any contributor changing the consumer code should re-verify the response shape against a fresh dashboard capture.
- **Rate limits** — not observed in normal dashboard use; the dashboard issues several dozen requests on load without throttling. The app's `URLSessionConfiguration.ephemeral` already isolates from any shared rate-limit state.

## How to re-verify

1. Open `https://www.cursor.com/dashboard/analytics` in a browser logged in with the relevant account.
2. Open DevTools → Network → XHR filter.
3. Refresh the page; the endpoints under "Endpoints observed" above appear with response bodies viewable in the panel.
4. Update this file if names, query params, or schema have drifted.
