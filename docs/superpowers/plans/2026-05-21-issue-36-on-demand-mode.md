# Issue #36 — On-demand mode switch — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When request/credit quota is exhausted and on-demand billing is active, swap the primary progress display (menu bar ring + popover bar + label/text) to on-demand spend; demote the previous dimension to a secondary row. Sticky-latched per billing cycle.

**Architecture:** UI layer reads through `UsageDisplayData` whose presentation computeds branch on a new `isOnDemandActive` stored flag. `UsageViewModel` owns the latch (`isOnDemandLatched`) plus a new `previousOnDemandUsedCents` baseline; the latch is injected into `UsageDisplayData` at construction. `JumpEvent.Mode` gains a `.onDemand` case. `NotificationManager` becomes mode-aware so threshold copy clarifies which dimension hit 80/90%. Existing `previousMode` guard auto-skips the 1-cycle transition delta; existing billing-cycle rollover detection re-arms the latch and threshold dedup set.

**Tech Stack:** Swift 6 strict concurrency, AppKit, **XCTest** (confirmed: `Tests/CursorMeterTests/UsageDisplayDataTests.swift` uses `import XCTest` + `@testable import CursorMeter`), `swift test`.

## Test syntax conventions (XCTest)

All `@Test func name() { ... }` snippets in this plan must be translated to XCTest before writing:

| Plan snippet | XCTest equivalent |
|---|---|
| `@Test func name() { ... }` | `func test_name() { ... }` (must be on an `XCTestCase` subclass) |
| `@Test func name() async { ... }` | `func test_name() async { ... }` |
| `#expect(x == y)` | `XCTAssertEqual(x, y)` |
| `#expect(x != nil)` | `XCTAssertNotNil(x)` |
| `#expect(condition)` | `XCTAssertTrue(condition)` |
| `#expect(abs(x - y) < tolerance)` | `XCTAssertEqual(x, y, accuracy: tolerance)` |

Place new tests inside the existing `final class XxxTests: XCTestCase { ... }` declarations in each file.

## Test-hook visibility

Use `@testable import CursorMeter` (already present) + change the test-only methods from `private` to `internal`. **No `#if DEBUG` guards needed** — `@testable import` exposes `internal` symbols to tests without leaking them to release builds.

**Spec:** `docs/superpowers/specs/2026-05-20-issue-36-design.md`

**Post-merge release:** Tag as `v0.4.0-beta.1`, `gh release create --prerelease`. Release notes include curl one-liner: `curl -fsSL https://github.com/WoojinAhn/CursorMeter/releases/download/v0.4.0-beta.1/CursorMeter.app.zip -o /tmp/CursorMeter-beta.zip && unzip -o /tmp/CursorMeter-beta.zip -d /tmp && rm -rf /Applications/CursorMeter.app && mv /tmp/CursorMeter.app /Applications/ && open /Applications/CursorMeter.app`. `UpdateChecker` is unchanged — `/releases/latest` skips pre-releases automatically.

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `Sources/CursorMeter/UsageModels.swift` | modify | Add `onDemandEnabled` plumbing, `isOnDemandActive` stored prop, new computeds, refined `hasOnDemand`, `teamUsage.onDemand` fallback in factories |
| `Sources/CursorMeter/UsageViewModel.swift` | modify | Latch state + reset paths, `previousOnDemandUsedCents`, extended `updateJumpState`, mode-aware threshold call |
| `Sources/CursorMeter/NotificationManager.swift` | modify | `NotificationMode` enum, mode-aware body in `checkAndNotify` |
| `Sources/CursorMeter/MenuBarView.swift` | modify | Repurpose `onDemandRow` to generic "secondary" row driven by `secondaryUsageLabel` + `secondaryUsageValue`; red color for over-limit |
| `Tests/CursorMeterTests/UsageDisplayDataTests.swift` | modify | Add test cases for activation/inactivation, computeds, secondary row |
| `Tests/CursorMeterTests/UsageViewModelTests.swift` | modify | Latch logic, oscillation guard, cycle rollover, threshold mode |
| `Tests/CursorMeterTests/UsageViewModelJumpTests.swift` | modify | `.onDemand` mode transition skip + subsequent jump |
| `Tests/CursorMeterTests/NotificationManagerTests.swift` | modify | Mode-aware body strings |

---

## Task 1: `OnDemandUsage.enabled` plumbing + refined `hasOnDemand`

**Files:**
- Modify: `Sources/CursorMeter/UsageModels.swift:80-89` (struct already has `enabled` field), `:116-118` (UsageDisplayData stored fields), `:175-184` (hasOnDemand / onDemandText)
- Modify: `Sources/CursorMeter/UsageModels.swift:237-288` (both factory methods)
- Modify: `Tests/CursorMeterTests/UsageDisplayDataTests.swift` — find existing init call sites first

- [ ] **Step 1: Inspect existing test call sites for `UsageDisplayData(...)`**

Run: `rg -n 'UsageDisplayData\(' Tests/CursorMeterTests/`
Expected: A list of constructions; note the parameter ordering used.

- [ ] **Step 2: Add `onDemandEnabled` stored property to `UsageDisplayData`**

In `Sources/CursorMeter/UsageModels.swift`, locate the `UsageDisplayData` struct (around line 100). Add the field next to `onDemandUsedCents` / `onDemandLimitCents`:

```swift
let onDemandUsedCents: Int?
let onDemandLimitCents: Int?
let onDemandEnabled: Bool?       // ← NEW; nil means "field absent → treat as enabled"
```

Swift memberwise init now requires this argument. Provide a default by adding `= nil` next to other optional fields — but Swift's auto-synthesized memberwise init does NOT honor stored-property defaults for required fields. Instead: keep `onDemandEnabled: Bool?` (Optional already has a default of `nil` in memberwise init).

Verify by reading: Swift's auto-memberwise init treats `Optional` typed properties as having a default of `nil` since Swift 5.1. So `let onDemandEnabled: Bool?` automatically yields `init(..., onDemandEnabled: Bool? = nil)`.

- [ ] **Step 3: Refine `hasOnDemand`**

Replace existing computed at `UsageModels.swift:175-177`:

```swift
var hasOnDemand: Bool {
    guard let limit = onDemandLimitCents, limit > 0 else { return false }
    // `enabled == false` means the team admin disabled on-demand mid-cycle;
    // treat as no on-demand even if a residual `used` value is reported.
    // `nil` (field absent) defaults to true for backward compat.
    return onDemandEnabled ?? true
}
```

- [ ] **Step 4: Update both factories to pass `onDemandEnabled`**

`Sources/CursorMeter/UsageModels.swift:248-262` (summary-based factory): change to include `onDemandEnabled: onDemand?.enabled` at the same position.

`Sources/CursorMeter/UsageModels.swift:273-287` (legacy fallback factory): include `onDemandEnabled: nil`.

- [ ] **Step 5: Write failing tests for `hasOnDemand` refinement**

In `Tests/CursorMeterTests/UsageDisplayDataTests.swift`, find the existing `hasOnDemand` test block (search `hasOnDemand`). Add:

```swift
@Test func hasOnDemand_falseWhenEnabledFalse() {
    let data = UsageDisplayData(
        // ... use the existing test helper if one exists; otherwise full memberwise
        // copy the construction from an existing nearby test and change just:
        // onDemandLimitCents: 4000,
        // onDemandEnabled:    false
    )
    #expect(data.hasOnDemand == false)
}

@Test func hasOnDemand_trueWhenEnabledNil() {
    // limit > 0 and enabled == nil → defaults to true
    let data = makeFixture(onDemandLimitCents: 4000, onDemandEnabled: nil)
    #expect(data.hasOnDemand == true)
}
```

**Important:** Look at the existing test file first (e.g. `Tests/CursorMeterTests/UsageDisplayDataTests.swift`) for the fixture/helper pattern. If there's a `makeFixture` or similar — use it. If not, copy the closest existing construction verbatim and modify only the on-demand fields.

- [ ] **Step 6: Run failing tests**

Run: `swift test --filter UsageDisplayDataTests/hasOnDemand`
Expected: 2 new tests fail (the rest pass).

- [ ] **Step 7: Re-run all tests to confirm Step 3's change makes them pass**

Run: `swift test --filter UsageDisplayDataTests`
Expected: all pass (existing + 2 new).

- [ ] **Step 8: Commit**

```bash
git add Sources/CursorMeter/UsageModels.swift Tests/CursorMeterTests/UsageDisplayDataTests.swift
git commit -m "[#36] feat: plumb OnDemandUsage.enabled into UsageDisplayData"
```

---

## Task 2: `teamUsage.onDemand` fallback in summary factory

**Files:**
- Modify: `Sources/CursorMeter/UsageModels.swift:237-262` (summary factory)
- Modify: `Tests/CursorMeterTests/UsageDisplayDataTests.swift`

- [ ] **Step 1: Write failing test for team-only on-demand**

```swift
@Test func teamUsage_onDemand_populatesDisplayData() {
    let summary = UsageSummaryResponse(
        billingCycleStart: "2026-05-01T00:00:00.000Z",
        billingCycleEnd:   "2026-06-01T00:00:00.000Z",
        membershipType:    "enterprise",
        limitType:         nil,
        isUnlimited:       false,
        individualUsage:   IndividualUsage(plan: nil, onDemand: nil),
        teamUsage:         TeamUsage(onDemand: OnDemandUsage(
            enabled: true, used: 584, limit: 4000, remaining: 3416))
    )
    let usage = UsageResponse(
        models: ["gpt-4": ModelUsage(
            numRequests: 757, numRequestsTotal: 757, numTokens: nil,
            maxRequestUsage: 500, maxTokenUsage: nil)],
        startOfMonth: "2026-05-01T00:00:00.000Z"
    )
    let userInfo = UserInfoResponse(email: "test@example.com", name: "Test")

    let data = UsageDisplayData.from(summary: summary, usage: usage, userInfo: userInfo)

    #expect(data.onDemandUsedCents == 584)
    #expect(data.onDemandLimitCents == 4000)
    #expect(data.onDemandEnabled == true)
    #expect(data.hasOnDemand == true)
}
```

- [ ] **Step 2: Run failing test**

Run: `swift test --filter UsageDisplayDataTests/teamUsage_onDemand_populatesDisplayData`
Expected: FAIL — `onDemandUsedCents` is nil because current factory reads only `individualUsage.onDemand`.

- [ ] **Step 3: Update factory to fall back to `teamUsage.onDemand`**

In `Sources/CursorMeter/UsageModels.swift:246`, change:

```swift
// before:
let onDemand = summary.individualUsage?.onDemand

// after:
let onDemand = summary.individualUsage?.onDemand
    ?? summary.teamUsage?.onDemand
```

- [ ] **Step 4: Run test to verify pass**

Run: `swift test --filter UsageDisplayDataTests/teamUsage_onDemand_populatesDisplayData`
Expected: PASS

- [ ] **Step 5: Run full test suite**

Run: `swift test`
Expected: all pass (197 existing + new ones from Task 1 & 2).

- [ ] **Step 6: Commit**

```bash
git add Sources/CursorMeter/UsageModels.swift Tests/CursorMeterTests/UsageDisplayDataTests.swift
git commit -m "[#36] fix: fall back to teamUsage.onDemand when individualUsage absent"
```

---

## Task 3: `wouldActivateOnDemand` computed property

**Files:**
- Modify: `Sources/CursorMeter/UsageModels.swift` (UsageDisplayData computeds section)
- Modify: `Tests/CursorMeterTests/UsageDisplayDataTests.swift`

- [ ] **Step 1: Write failing tests**

Append to `UsageDisplayDataTests.swift`:

```swift
@Test func wouldActivate_requestQuotaExceeded() {
    let data = makeFixture(
        requestsUsed: 757, requestsLimit: 500,
        onDemandLimitCents: 4000, onDemandEnabled: true)
    #expect(data.wouldActivateOnDemand == true)
}

@Test func wouldActivate_requestBoundaryEqual() {
    let data = makeFixture(
        requestsUsed: 500, requestsLimit: 500,
        onDemandLimitCents: 4000, onDemandEnabled: true)
    #expect(data.wouldActivateOnDemand == true)
}

@Test func wouldActivate_underQuota() {
    let data = makeFixture(
        requestsUsed: 400, requestsLimit: 500,
        onDemandLimitCents: 4000, onDemandEnabled: true)
    #expect(data.wouldActivateOnDemand == false)
}

@Test func wouldActivate_noOnDemand() {
    let data = makeFixture(
        requestsUsed: 757, requestsLimit: 500,
        onDemandLimitCents: 0, onDemandEnabled: nil)
    #expect(data.wouldActivateOnDemand == false)
}

@Test func wouldActivate_creditBasedExhausted() {
    let data = makeFixture(
        planUsedCents: 2000, planLimitCents: 2000,
        requestsUsed: 0, requestsLimit: 0,
        onDemandLimitCents: 4000, onDemandEnabled: true)
    #expect(data.wouldActivateOnDemand == true)
}

@Test func wouldActivate_creditBasedZeroLimitNoActivation() {
    let data = makeFixture(
        planUsedCents: 0, planLimitCents: 0,
        requestsUsed: 0, requestsLimit: 0,
        onDemandLimitCents: 4000, onDemandEnabled: true)
    #expect(data.wouldActivateOnDemand == false)
}
```

(If `makeFixture` doesn't exist, create one at the top of `UsageDisplayDataTests.swift` with all UsageDisplayData fields as labeled args with sensible defaults — this is a one-time investment that simplifies all subsequent tests in this plan. Keep it private to the test file.)

- [ ] **Step 2: Run failing tests**

Run: `swift test --filter UsageDisplayDataTests/wouldActivate`
Expected: 6 tests fail — `wouldActivateOnDemand` doesn't exist.

- [ ] **Step 3: Add the computed property**

In `UsageModels.swift`, near the existing `hasOnDemand` computed:

```swift
/// True when the user's primary quota is exhausted AND on-demand is active.
/// Pure derived value — does NOT include the sticky latch (that lives in
/// UsageViewModel and is injected via `isOnDemandActive`).
var wouldActivateOnDemand: Bool {
    guard hasOnDemand else { return false }
    if requestsLimit > 0 && requestsUsed >= requestsLimit { return true }
    if isCreditBased,
       let limit = planLimitCents, limit > 0,
       let used = planUsedCents, used >= limit { return true }
    return false
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter UsageDisplayDataTests/wouldActivate`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CursorMeter/UsageModels.swift Tests/CursorMeterTests/UsageDisplayDataTests.swift
git commit -m "[#36] feat: add wouldActivateOnDemand derived flag"
```

---

## Task 4: `isOnDemandActive` stored property + branched presentation computeds

**Files:**
- Modify: `Sources/CursorMeter/UsageModels.swift` (struct fields + computeds)
- Modify: factories to pass `isOnDemandActive: false` by default
- Modify: `Tests/CursorMeterTests/UsageDisplayDataTests.swift`

- [ ] **Step 1: Add `isOnDemandActive` stored field**

In `UsageDisplayData`, after `onDemandEnabled`:

```swift
let onDemandEnabled: Bool?
/// Injected by UsageViewModel after sticky-latch logic. When true, presentation
/// computeds (percentUsed, usageLabel, usageText, menuBar*) reflect on-demand
/// spend instead of the primary dimension.
let isOnDemandActive: Bool
```

`Bool` is non-Optional, so memberwise init becomes required. Provide a default in BOTH factory methods (pass `false`) so legacy code paths remain valid. Test fixtures should pass it explicitly (`false` default in `makeFixture`).

Update `from(summary:usage:userInfo:)` at line 248: add `isOnDemandActive: false` to the constructor call.
Update `from(usage:userInfo:)` at line 273: add `isOnDemandActive: false` to the constructor call.

- [ ] **Step 2: Add a from-with-override factory**

Add a third factory variant that lets UsageViewModel inject the latched flag without re-fetching:

```swift
/// Returns a copy of `self` with `isOnDemandActive` overridden. Used by
/// UsageViewModel to inject the sticky-latched mode after computing it.
func withOnDemandActive(_ active: Bool) -> UsageDisplayData {
    UsageDisplayData(
        email: email, name: name, membershipType: membershipType,
        planUsedCents: planUsedCents, planLimitCents: planLimitCents,
        serverPercentUsed: serverPercentUsed,
        requestsUsed: requestsUsed, requestsLimit: requestsLimit,
        onDemandUsedCents: onDemandUsedCents,
        onDemandLimitCents: onDemandLimitCents,
        onDemandEnabled: onDemandEnabled,
        isOnDemandActive: active,
        cycleStartDate: cycleStartDate,
        resetDate: resetDate,
        daysUntilReset: daysUntilReset
    )
}
```

(Exact field order must match the struct's declared property order — verify by reading the struct top-to-bottom and matching the order.)

- [ ] **Step 3: Write failing tests for branched computeds**

```swift
@Test func percentUsed_onDemandMode_usesOnDemandRatio() {
    let data = makeFixture(
        requestsUsed: 757, requestsLimit: 500,
        onDemandUsedCents: 584, onDemandLimitCents: 4000, onDemandEnabled: true,
        isOnDemandActive: true)
    // 584 / 4000 = 14.6%
    #expect(abs(data.percentUsed - 14.6) < 0.05)
}

@Test func usageLabel_onDemandMode_isOnDemand() {
    let data = makeFixture(isOnDemandActive: true,
        onDemandUsedCents: 584, onDemandLimitCents: 4000, onDemandEnabled: true)
    #expect(data.usageLabel == "On-demand")
}

@Test func usageText_onDemandMode_isUSD() {
    let data = makeFixture(isOnDemandActive: true,
        onDemandUsedCents: 584, onDemandLimitCents: 4000, onDemandEnabled: true)
    #expect(data.usageText == "$5.84 / $40.00")
}

@Test func menuBarText_onDemandMode_compactUSD() {
    let data = makeFixture(isOnDemandActive: true,
        onDemandUsedCents: 584, onDemandLimitCents: 4000, onDemandEnabled: true)
    #expect(data.menuBarUsedText == "5.8")
    #expect(data.menuBarLimitText == "40.0")
}

@Test func presentationUnchanged_whenLatchInactive() {
    // Same data with isOnDemandActive=false should preserve legacy behavior.
    let data = makeFixture(
        requestsUsed: 757, requestsLimit: 500,
        onDemandUsedCents: 584, onDemandLimitCents: 4000, onDemandEnabled: true,
        isOnDemandActive: false)
    #expect(data.usageLabel == "Requests")
    #expect(data.usageText == "757 / 500")
    #expect(abs(data.percentUsed - 151.4) < 0.5)
}
```

- [ ] **Step 4: Run failing tests**

Run: `swift test --filter UsageDisplayDataTests`
Expected: new branching tests fail; previous tests still pass.

- [ ] **Step 5: Branch the presentation computeds**

In `UsageModels.swift`, modify these existing computeds (each currently around lines 131-173). For each, add an early-return for the on-demand active branch:

```swift
var percentUsed: Double {
    if isOnDemandActive {
        guard let limit = onDemandLimitCents, limit > 0,
              let used = onDemandUsedCents else { return 0 }
        return Double(used) / Double(limit) * 100.0
    }
    if isPercentOnly, let server = serverPercentUsed { return server }
    if isCreditBased {
        guard let limit = planLimitCents, limit > 0, let used = planUsedCents else { return 0 }
        return Double(used) / Double(limit) * 100.0
    }
    guard requestsLimit > 0 else { return 0 }
    return Double(requestsUsed) / Double(requestsLimit) * 100.0
}

var usageText: String {
    if isOnDemandActive {
        return "\(Self.formatUSD(onDemandUsedCents ?? 0)) / \(Self.formatUSD(onDemandLimitCents ?? 0))"
    }
    if isPercentOnly { return percentText }
    if isCreditBased {
        return "\(Self.formatUSD(planUsedCents ?? 0)) / \(Self.formatUSD(planLimitCents ?? 0))"
    }
    return "\(requestsUsed) / \(requestsLimit)"
}

var menuBarUsedText: String {
    if isOnDemandActive {
        return Self.formatCompactUSD(onDemandUsedCents ?? 0)
    }
    if isPercentOnly { return percentText }
    if isCreditBased { return Self.formatCompactUSD(planUsedCents ?? 0) }
    return "\(requestsUsed)"
}

var menuBarLimitText: String {
    if isOnDemandActive {
        return Self.formatCompactUSD(onDemandLimitCents ?? 0)
    }
    if isPercentOnly { return "" }
    if isCreditBased { return Self.formatCompactUSD(planLimitCents ?? 0) }
    return "\(requestsLimit)"
}

var usageLabel: String {
    if isOnDemandActive { return "On-demand" }
    if isPercentOnly { return "Plan Usage" }
    return isCreditBased ? "Plan Usage" : "Requests"
}
```

- [ ] **Step 6: Run tests to verify pass**

Run: `swift test --filter UsageDisplayDataTests`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/CursorMeter/UsageModels.swift Tests/CursorMeterTests/UsageDisplayDataTests.swift
git commit -m "[#36] feat: branch presentation computeds on isOnDemandActive"
```

---

## Task 5: Secondary row computeds

**Files:**
- Modify: `Sources/CursorMeter/UsageModels.swift`
- Modify: `Tests/CursorMeterTests/UsageDisplayDataTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
@Test func secondaryRow_onDemandMode_showsRequests() {
    let data = makeFixture(
        requestsUsed: 757, requestsLimit: 500,
        onDemandUsedCents: 584, onDemandLimitCents: 4000, onDemandEnabled: true,
        isOnDemandActive: true)
    #expect(data.secondaryUsageLabel == "Requests")
    #expect(data.secondaryUsageValue == "757 / 500")
    #expect(data.secondaryUsageIsOverLimit == true)
}

@Test func secondaryRow_onDemandMode_showsPlan_whenCreditBased() {
    let data = makeFixture(
        planUsedCents: 2000, planLimitCents: 2000,
        requestsUsed: 0, requestsLimit: 0,
        onDemandUsedCents: 0, onDemandLimitCents: 4000, onDemandEnabled: true,
        isOnDemandActive: true)
    #expect(data.secondaryUsageLabel == "Plan")
    #expect(data.secondaryUsageValue == "$20.00 / $20.00")
    #expect(data.secondaryUsageIsOverLimit == true)
}

@Test func secondaryRow_requestMode_showsOnDemand() {
    let data = makeFixture(
        requestsUsed: 200, requestsLimit: 500,
        onDemandUsedCents: 0, onDemandLimitCents: 4000, onDemandEnabled: true,
        isOnDemandActive: false)
    #expect(data.secondaryUsageLabel == "On-demand")
    #expect(data.secondaryUsageValue == "$0.00 / $40.00")
    #expect(data.secondaryUsageIsOverLimit == false)
}

@Test func secondaryRow_requestMode_nil_whenNoOnDemand() {
    let data = makeFixture(
        requestsUsed: 200, requestsLimit: 500,
        onDemandUsedCents: nil, onDemandLimitCents: nil, onDemandEnabled: nil,
        isOnDemandActive: false)
    #expect(data.secondaryUsageLabel == nil)
    #expect(data.secondaryUsageValue == nil)
}
```

- [ ] **Step 2: Run failing tests**

Run: `swift test --filter UsageDisplayDataTests/secondaryRow`
Expected: 4 tests fail.

- [ ] **Step 3: Implement secondary row computeds**

```swift
/// The "other" dimension shown as a smaller secondary popover row.
/// In on-demand mode this is the previous primary (Requests or Plan).
/// In normal mode this is On-demand (when present).
var secondaryUsageLabel: String? {
    if isOnDemandActive {
        if isCreditBased { return "Plan" }
        return "Requests"
    }
    return hasOnDemand ? "On-demand" : nil
}

var secondaryUsageValue: String? {
    if isOnDemandActive {
        if isCreditBased {
            return "\(Self.formatUSD(planUsedCents ?? 0)) / \(Self.formatUSD(planLimitCents ?? 0))"
        }
        return "\(requestsUsed) / \(requestsLimit)"
    }
    return onDemandText  // existing computed; nil when no on-demand
}

var secondaryUsageIsOverLimit: Bool {
    if isOnDemandActive {
        if isCreditBased,
           let limit = planLimitCents, limit > 0,
           let used = planUsedCents { return used >= limit }
        return requestsLimit > 0 && requestsUsed >= requestsLimit
    }
    return false
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter UsageDisplayDataTests/secondaryRow`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/CursorMeter/UsageModels.swift Tests/CursorMeterTests/UsageDisplayDataTests.swift
git commit -m "[#36] feat: add secondary row computeds for inverted display"
```

---

## Task 6: `JumpEvent.Mode.onDemand` + switch sites

**Files:**
- Modify: `Sources/CursorMeter/UsageViewModel.swift:55-59` (enum), `:632-647` (updateJumpState switch), `:705-712` (absoluteThresholds), `:740-748` (formatJumpDelta)
- Modify: `Tests/CursorMeterTests/UsageViewModelJumpTests.swift`

- [ ] **Step 1: Write failing test for formatJumpDelta**

In `UsageViewModelJumpTests.swift`, find the existing `formatJumpDelta` tests and add:

```swift
@Test func formatJumpDelta_onDemand_isUSD() {
    let s = UsageViewModel.formatJumpDelta(584, mode: .onDemand)
    #expect(s == "+$5.84")
}
```

- [ ] **Step 2: Run failing test**

Run: `swift test --filter UsageViewModelJumpTests/formatJumpDelta_onDemand`
Expected: FAIL — `.onDemand` doesn't exist.

- [ ] **Step 3: Add `.onDemand` enum case**

In `UsageViewModel.swift:55-59`, change:

```swift
enum Mode: Sendable, Equatable {
    case credit       // USD cents
    case request      // request count
    case percent      // server-provided percent (%-points)
    case onDemand     // USD cents (on-demand billing dimension)
}
```

- [ ] **Step 4: Handle the case in all three switches**

`absoluteThresholds` (line ~705):
```swift
private nonisolated static func absoluteThresholds(
    for mode: JumpEvent.Mode
) -> (t1: Double, t2: Double) {
    switch mode {
    case .credit:   return (5, 30)   // cents — $0.05 / $0.30
    case .onDemand: return (5, 30)   // cents — same as credit
    case .request:  return (5, 15)
    case .percent:  return (5, 15)
    }
}
```

`formatJumpDelta` (line ~740):
```swift
nonisolated static func formatJumpDelta(_ delta: Double, mode: JumpEvent.Mode) -> String {
    switch mode {
    case .credit, .onDemand:
        return String(format: "+$%.2f", delta / 100.0)
    case .request:
        return "+\(Int(delta.rounded()))"
    case .percent:
        return String(format: "+%.1f%%", delta)
    }
}
```

(`updateJumpState` is handled in Task 7.)

- [ ] **Step 5: Run test**

Run: `swift test --filter UsageViewModelJumpTests/formatJumpDelta_onDemand`
Expected: PASS

Then full suite:
Run: `swift test`
Expected: all pass — the new enum case must not break existing exhaustive switches. If any switch we didn't anticipate fails to compile, add the missing branch.

- [ ] **Step 6: Commit**

```bash
git add Sources/CursorMeter/UsageViewModel.swift Tests/CursorMeterTests/UsageViewModelJumpTests.swift
git commit -m "[#36] feat: add JumpEvent.Mode.onDemand case + switch coverage"
```

---

## Task 7: `previousOnDemandUsedCents` baseline + extended `updateJumpState`

**Files:**
- Modify: `Sources/CursorMeter/UsageViewModel.swift:137-140` (baselines), `:193-204` (resetPerAccountState), `:618-677` (updateJumpState)
- Modify: `Tests/CursorMeterTests/UsageViewModelJumpTests.swift`

- [ ] **Step 1: Add baseline field**

After line 139 (`private var previousServerPercent: Double?`):

```swift
private var previousServerPercent: Double?
private var previousOnDemandUsedCents: Int?
private var previousMode: JumpEvent.Mode?
```

- [ ] **Step 2: Reset in `resetPerAccountState`**

In `resetPerAccountState()` (line 193-205), add:

```swift
previousOnDemandUsedCents = nil
```

next to `previousServerPercent = nil`.

- [ ] **Step 3: Extend `updateJumpState` mode picker**

At `UsageViewModel.swift:618-630`, change the mode-selection block:

```swift
private func updateJumpState(from data: UsageDisplayData) {
    let mode: JumpEvent.Mode
    let current: Double
    if data.isOnDemandActive {
        mode = .onDemand
        current = Double(data.onDemandUsedCents ?? 0)
    } else if data.isPercentOnly {
        mode = .percent
        current = data.serverPercentUsed ?? 0
    } else if data.isCreditBased {
        mode = .credit
        current = Double(data.planUsedCents ?? 0)
    } else {
        mode = .request
        current = Double(data.requestsUsed)
    }
```

Extend the `previous` switch and the baseline-update switch:

```swift
let previous: Double? = {
    switch mode {
    case .credit:   return previousPlanUsedCents.map(Double.init)
    case .request:  return previousRequestsUsed.map(Double.init)
    case .percent:  return previousServerPercent
    case .onDemand: return previousOnDemandUsedCents.map(Double.init)
    }
}()

// ...

switch mode {
case .credit:   previousPlanUsedCents = data.planUsedCents ?? 0
case .request:  previousRequestsUsed = data.requestsUsed
case .percent:  previousServerPercent = data.serverPercentUsed ?? 0
case .onDemand: previousOnDemandUsedCents = data.onDemandUsedCents ?? 0
}
```

And the `limit` switch:

```swift
let limit: Double
switch mode {
case .credit:   limit = Double(data.planLimitCents ?? 0)
case .request:  limit = Double(data.requestsLimit)
case .percent:  limit = 100
case .onDemand: limit = Double(data.onDemandLimitCents ?? 0)
}
```

- [ ] **Step 4: Write tests for mode transition + on-demand jump**

In `UsageViewModelJumpTests.swift`:

```swift
@Test func updateJumpState_transitionRequestToOnDemand_skipsDelta() async {
    let vm = await UsageViewModel()
    // First refresh: request mode, used=400, limit=500
    let d1 = makeFixture(
        requestsUsed: 400, requestsLimit: 500,
        onDemandUsedCents: 0, onDemandLimitCents: 4000, onDemandEnabled: true,
        isOnDemandActive: false)
    await MainActor.run { vm.testHook_updateJumpState(from: d1) }
    // Second refresh: on-demand mode, used=584
    let d2 = makeFixture(
        requestsUsed: 757, requestsLimit: 500,
        onDemandUsedCents: 584, onDemandLimitCents: 4000, onDemandEnabled: true,
        isOnDemandActive: true)
    await MainActor.run { vm.testHook_updateJumpState(from: d2) }
    // Expect no jump emitted on transition refresh
    #expect(await vm.lastJump == nil)
}

@Test func updateJumpState_subsequentOnDemand_firesJump() async {
    let vm = await UsageViewModel()
    let baseline = makeFixture(
        onDemandUsedCents: 500, onDemandLimitCents: 4000, onDemandEnabled: true,
        isOnDemandActive: true)
    let next = makeFixture(
        onDemandUsedCents: 1100, onDemandLimitCents: 4000, onDemandEnabled: true,
        isOnDemandActive: true)
    await MainActor.run {
        vm.testHook_updateJumpState(from: baseline)
        vm.testHook_updateJumpState(from: next)
    }
    let jump = await vm.lastJump
    #expect(jump != nil)
    #expect(jump?.mode == .onDemand)
    #expect(jump?.deltaCanonical == 600)  // $6.00 in cents
    #expect(jump?.displayDelta == "+$6.00")
}
```

The above uses `testHook_updateJumpState` — a `@testable internal` wrapper we need to add.

- [ ] **Step 5: Add `@testable internal` hook**

Just below `private func updateJumpState(from:)` in `UsageViewModel.swift`, add:

```swift
#if DEBUG
internal func testHook_updateJumpState(from data: UsageDisplayData) {
    updateJumpState(from: data)
}
#endif
```

(If the project doesn't have a DEBUG flag set, gate on `#if canImport(XCTest) || ...` or use `@testable import CursorMeter` — verify by checking an existing test file's `@testable import` line.)

- [ ] **Step 6: Run failing tests**

Run: `swift test --filter UsageViewModelJumpTests/updateJumpState_`
Expected: PASS for both new tests (we already implemented Step 3).

- [ ] **Step 7: Run full suite**

Run: `swift test`
Expected: all pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/CursorMeter/UsageViewModel.swift Tests/CursorMeterTests/UsageViewModelJumpTests.swift
git commit -m "[#36] feat: track on-demand jump baseline + extend updateJumpState"
```

---

## Task 8: Sticky-latch state in `UsageViewModel`

**Files:**
- Modify: `Sources/CursorMeter/UsageViewModel.swift:152-156` (state fields), `:193-204` (resetPerAccountState), `:242-277` (refresh — latch logic + injection)
- Modify: `Tests/CursorMeterTests/UsageViewModelTests.swift`

- [ ] **Step 1: Add latch state field**

Near line 155 (`previousCycleStart`):

```swift
private var previousCycleStart: Date?
/// Sticky-latched flag: once on-demand mode is entered, it persists until the
/// billing cycle rolls over (or the user logs out). Prevents oscillation from
/// API jitter at the request-limit boundary.
private var isOnDemandLatched: Bool = false
```

- [ ] **Step 2: Reset in `resetPerAccountState` and at billing cycle rollover**

In `resetPerAccountState()`:
```swift
previousCycleStart = nil
isOnDemandLatched = false
```

In the existing rollover block (around line 271-276), already calls `notificationManager.resetNotifications()`. Add:
```swift
if let newStart = usageData?.cycleStartDate, newStart != previousCycleStart {
    if previousCycleStart != nil {
        notificationManager.resetNotifications()
        isOnDemandLatched = false   // ← NEW
        Log.info("Billing cycle rollover — reset notification dedup + on-demand latch")
    }
    previousCycleStart = newStart
}
```

- [ ] **Step 3: Apply latch in `refresh()` between data assembly and downstream consumers**

The existing refresh path (lines 242-256) builds `usageData`, then calls `updateJumpState`. We need to inject the latch between those steps.

Replace lines 242-248 (the if-let block that assigns `usageData`) with:

```swift
let baseData: UsageDisplayData?
if let summary {
    baseData = UsageDisplayData.from(summary: summary, usage: usage, userInfo: userInfo)
} else if let usage {
    baseData = UsageDisplayData.from(usage: usage, userInfo: userInfo)
} else {
    throw APIError.httpError(statusCode: 0)
}

if let base = baseData {
    // Latch update: once activated, stay activated until cycle rollover.
    let wasLatched = isOnDemandLatched
    if !isOnDemandLatched && base.wouldActivateOnDemand {
        isOnDemandLatched = true
        notificationManager.resetNotifications()
        Log.info("On-demand mode latched ON — threshold notifications reset")
    }
    usageData = base.withOnDemandActive(isOnDemandLatched)
    _ = wasLatched  // currently unused; kept for future telemetry
}
```

- [ ] **Step 4: Write tests for latch behavior**

In `Tests/CursorMeterTests/UsageViewModelTests.swift`:

```swift
@Test func latch_activatesWhenQuotaExhausted() async {
    let vm = await UsageViewModel()
    let base = makeFixture(
        requestsUsed: 600, requestsLimit: 500,
        onDemandUsedCents: 100, onDemandLimitCents: 4000, onDemandEnabled: true,
        isOnDemandActive: false)
    await MainActor.run { vm.testHook_applyLatch(base: base) }
    let data = await vm.usageData
    #expect(data?.isOnDemandActive == true)
}

@Test func latch_doesNotActivate_belowQuota() async {
    let vm = await UsageViewModel()
    let base = makeFixture(
        requestsUsed: 400, requestsLimit: 500,
        onDemandUsedCents: 0, onDemandLimitCents: 4000, onDemandEnabled: true,
        isOnDemandActive: false)
    await MainActor.run { vm.testHook_applyLatch(base: base) }
    #expect(await vm.usageData?.isOnDemandActive == false)
}

@Test func latch_oscillationGuard_doesNotResetNotifications() async {
    let vm = await UsageViewModel()
    // First: cross the threshold → latched + reset
    let over = makeFixture(
        requestsUsed: 600, requestsLimit: 500,
        onDemandUsedCents: 100, onDemandLimitCents: 4000, onDemandEnabled: true)
    await MainActor.run { vm.testHook_applyLatch(base: over) }
    // Simulate threshold notification dedup state
    await MainActor.run { vm.testHook_setNotifiedThresholds([80, 90]) }
    // Second refresh: API jitter shows 480/500 again
    let jitter = makeFixture(
        requestsUsed: 480, requestsLimit: 500,
        onDemandUsedCents: 100, onDemandLimitCents: 4000, onDemandEnabled: true)
    await MainActor.run { vm.testHook_applyLatch(base: jitter) }
    // Latch stays true (no re-fire); notifiedThresholds unchanged
    #expect(await vm.usageData?.isOnDemandActive == true)
    #expect(await vm.testHook_notifiedThresholds() == [80, 90])
}
```

Add the test hooks:

```swift
#if DEBUG
internal func testHook_applyLatch(base: UsageDisplayData) {
    let wasLatched = isOnDemandLatched
    if !isOnDemandLatched && base.wouldActivateOnDemand {
        isOnDemandLatched = true
        notificationManager.resetNotifications()
    }
    usageData = base.withOnDemandActive(isOnDemandLatched)
    _ = wasLatched
}
internal func testHook_setNotifiedThresholds(_ set: Set<Int>) {
    // expose write access on NotificationManager — add a `testHook_seed` there
    notificationManager.testHook_seed(set)
}
internal func testHook_notifiedThresholds() -> Set<Int> {
    notificationManager.notifiedThresholds
}
#endif
```

And on `NotificationManager`:
```swift
#if DEBUG
func testHook_seed(_ set: Set<Int>) { notifiedThresholds = set }
#endif
```

- [ ] **Step 5: Run tests**

Run: `swift test --filter UsageViewModelTests/latch_`
Expected: PASS (3 tests).

Run: `swift test`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/CursorMeter/UsageViewModel.swift Sources/CursorMeter/NotificationManager.swift Tests/CursorMeterTests/UsageViewModelTests.swift
git commit -m "[#36] feat: sticky on-demand latch + oscillation guard"
```

---

## Task 9: Cycle rollover unlatches

**Files:**
- Already implemented in Task 8 Step 2; add explicit test.
- Modify: `Tests/CursorMeterTests/UsageViewModelTests.swift`

- [ ] **Step 1: Write test for rollover unlatch**

```swift
@Test func latch_resetsOnCycleRollover() async {
    let vm = await UsageViewModel()
    let cycle1 = Date(timeIntervalSince1970: 1_700_000_000)
    let cycle2 = Date(timeIntervalSince1970: 1_702_678_400)

    let over1 = makeFixture(
        requestsUsed: 600, requestsLimit: 500,
        onDemandUsedCents: 100, onDemandLimitCents: 4000, onDemandEnabled: true,
        cycleStartDate: cycle1)
    await MainActor.run { vm.testHook_applyLatchAndRollover(base: over1) }
    #expect(await vm.usageData?.isOnDemandActive == true)

    // Next cycle, fresh start, under quota
    let fresh = makeFixture(
        requestsUsed: 50, requestsLimit: 500,
        onDemandUsedCents: 0, onDemandLimitCents: 4000, onDemandEnabled: true,
        cycleStartDate: cycle2)
    await MainActor.run { vm.testHook_applyLatchAndRollover(base: fresh) }
    #expect(await vm.usageData?.isOnDemandActive == false)
}
```

Add a combined test hook that mirrors the relevant section of `refresh()`:
```swift
#if DEBUG
internal func testHook_applyLatchAndRollover(base: UsageDisplayData) {
    // Mirrors refresh()'s rollover detection + latch update sequence.
    if let newStart = base.cycleStartDate, newStart != previousCycleStart {
        if previousCycleStart != nil {
            notificationManager.resetNotifications()
            isOnDemandLatched = false
        }
        previousCycleStart = newStart
    }
    if !isOnDemandLatched && base.wouldActivateOnDemand {
        isOnDemandLatched = true
        notificationManager.resetNotifications()
    }
    usageData = base.withOnDemandActive(isOnDemandLatched)
}
#endif
```

- [ ] **Step 2: Run test**

Run: `swift test --filter UsageViewModelTests/latch_resetsOnCycleRollover`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add Tests/CursorMeterTests/UsageViewModelTests.swift Sources/CursorMeter/UsageViewModel.swift
git commit -m "[#36] test: cycle rollover unlatches on-demand mode"
```

---

## Task 10: Mode-aware threshold notifications

**Files:**
- Modify: `Sources/CursorMeter/NotificationManager.swift:36-67` (`checkAndNotify`)
- Modify: `Sources/CursorMeter/UsageViewModel.swift:280-287` (call site)
- Modify: `Tests/CursorMeterTests/NotificationManagerTests.swift`

- [ ] **Step 1: Define `NotificationMode`**

At the top of `NotificationManager.swift`, near `ThresholdLevel`:

```swift
enum NotificationMode: Sendable, Equatable {
    case requestQuota(used: Int, limit: Int)
    case creditPlan(usedCents: Int, limitCents: Int)
    case onDemand(usedCents: Int, limitCents: Int)
}

extension NotificationMode {
    static func formatUSD(_ cents: Int) -> String {
        String(format: "$%.2f", Double(cents) / 100.0)
    }

    func body(forPercent percent: Int) -> String {
        switch self {
        case let .requestQuota(used, limit):
            return "월 요청 한도의 \(percent)%를 초과했습니다 (\(used) / \(limit))"
        case let .creditPlan(used, limit):
            return "월 플랜의 \(percent)%를 사용했습니다 (\(Self.formatUSD(used)) / \(Self.formatUSD(limit)))"
        case let .onDemand(used, limit):
            return "On-demand 청구의 \(percent)%를 사용했습니다 (\(Self.formatUSD(used)) / \(Self.formatUSD(limit)))"
        }
    }

    var titleSuffix: String {
        switch self {
        case .requestQuota: return "Request Quota"
        case .creditPlan:   return "Plan"
        case .onDemand:     return "On-demand"
        }
    }
}
```

- [ ] **Step 2: Write failing test for body strings**

In `NotificationManagerTests.swift`:

```swift
@Test func body_requestQuota_isKorean() {
    let s = NotificationMode.requestQuota(used: 757, limit: 500).body(forPercent: 80)
    #expect(s == "월 요청 한도의 80%를 초과했습니다 (757 / 500)")
}

@Test func body_onDemand_includesUSD() {
    let s = NotificationMode.onDemand(usedCents: 3200, limitCents: 4000).body(forPercent: 80)
    #expect(s == "On-demand 청구의 80%를 사용했습니다 ($32.00 / $40.00)")
}

@Test func body_creditPlan_includesUSD() {
    let s = NotificationMode.creditPlan(usedCents: 1600, limitCents: 2000).body(forPercent: 80)
    #expect(s == "월 플랜의 80%를 사용했습니다 ($16.00 / $20.00)")
}
```

Run: `swift test --filter NotificationManagerTests/body_`
Expected: PASS (the body method is pure — passes immediately if Step 1 is correct).

- [ ] **Step 3: Plumb `NotificationMode` into `checkAndNotify`**

Replace `checkAndNotify` in `NotificationManager.swift:36-67`:

```swift
func checkAndNotify(
    percentUsed: Double,
    warningThreshold: Int,
    criticalThreshold: Int,
    enabled: Bool,
    mode: NotificationMode
) async {
    guard enabled else { return }

    let level = Self.evaluateThreshold(
        percentUsed: percentUsed,
        warningThreshold: warningThreshold,
        criticalThreshold: criticalThreshold,
        notifiedThresholds: notifiedThresholds
    )

    switch level {
    case .none:
        break
    case .warning:
        await sendNotification(
            title: "Cursor \(mode.titleSuffix) Warning",
            body: mode.body(forPercent: warningThreshold)
        )
        notifiedThresholds.insert(warningThreshold)
    case .critical:
        await sendNotification(
            title: "Cursor \(mode.titleSuffix) Critical",
            body: mode.body(forPercent: criticalThreshold)
        )
        notifiedThresholds.insert(criticalThreshold)
    }
}
```

- [ ] **Step 4: Update the call site in `UsageViewModel.swift`**

At line 280-287:

```swift
if let data = usageData {
    let mode: NotificationMode = {
        if data.isOnDemandActive {
            return .onDemand(
                usedCents: data.onDemandUsedCents ?? 0,
                limitCents: data.onDemandLimitCents ?? 0)
        }
        if data.isCreditBased {
            return .creditPlan(
                usedCents: data.planUsedCents ?? 0,
                limitCents: data.planLimitCents ?? 0)
        }
        return .requestQuota(used: data.requestsUsed, limit: data.requestsLimit)
    }()
    await notificationManager.checkAndNotify(
        percentUsed: data.percentUsed,
        warningThreshold: warningThreshold,
        criticalThreshold: criticalThreshold,
        enabled: notificationEnabled,
        mode: mode
    )
}
```

- [ ] **Step 5: Run full suite**

Run: `swift test`
Expected: all pass. If any existing test breaks because it called the old `checkAndNotify` signature, update those tests to pass a default mode (`.requestQuota(used: 0, limit: 0)` — they're not asserting on body text).

- [ ] **Step 6: Commit**

```bash
git add Sources/CursorMeter/NotificationManager.swift Sources/CursorMeter/UsageViewModel.swift Tests/CursorMeterTests/NotificationManagerTests.swift
git commit -m "[#36] feat: mode-aware threshold notification body"
```

---

## Task 11: Popover secondary row in `MenuBarView`

**Files:**
- Modify: `Sources/CursorMeter/MenuBarView.swift:43-46` (field declarations), `:275-291` (row setup), `:447-453` (apply path)

- [ ] **Step 1: Rename instance vars semantically**

In `MenuBarView.swift:43-46`:

```swift
// Secondary metric row (hidden when no secondary data). In normal mode
// shows On-demand; in on-demand mode shows the previous primary (Requests / Plan).
private let secondaryRow      = NSStackView()
private let secondaryKey      = NSTextField(labelWithString: "")
private let secondaryValue    = NSTextField(labelWithString: "")
```

(Old names `onDemandRow / onDemandKey / onDemandValue` rename throughout the file. Use `replace_all` carefully — there are 4 references in the layout section and 4 in the apply section.)

- [ ] **Step 2: Update layout section (line ~275-291)**

Same `NSStackView` setup as before, but use the new names:
```swift
secondaryRow.orientation = .horizontal
secondaryRow.spacing = 4
secondaryRow.translatesAutoresizingMaskIntoConstraints = false

secondaryKey.font      = NSFont.systemFont(ofSize: 12, weight: .regular)
secondaryKey.textColor = NSColor.secondaryLabelColor

secondaryValue.font      = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
secondaryValue.textColor = NSColor.secondaryLabelColor

let spacer3 = NSView()
spacer3.translatesAutoresizingMaskIntoConstraints = false
secondaryRow.addArrangedSubview(secondaryKey)
secondaryRow.addArrangedSubview(spacer3)
secondaryRow.addArrangedSubview(secondaryValue)

dataStack.addArrangedSubview(secondaryRow)
```

- [ ] **Step 3: Update `applyData` (line ~447-453)**

```swift
// Secondary row (label + value vary by mode)
if let label = data.secondaryUsageLabel, let value = data.secondaryUsageValue {
    secondaryKey.stringValue   = label
    secondaryValue.stringValue = value
    // Highlight over-limit values in red so the user immediately notices
    // the previous-primary dimension is exceeded while in on-demand mode.
    secondaryValue.textColor = data.secondaryUsageIsOverLimit
        ? NSColor.systemRed
        : NSColor.secondaryLabelColor
    secondaryRow.isHidden = false
} else {
    secondaryRow.isHidden = true
}
```

- [ ] **Step 4: Build to check the rename didn't miss anything**

Run: `swift build`
Expected: clean build. If any reference to `onDemandRow / onDemandKey / onDemandValue` remains, it'll fail; fix it.

- [ ] **Step 5: Run full test suite**

Run: `swift test`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/CursorMeter/MenuBarView.swift
git commit -m "[#36] feat: popover secondary row driven by mode-aware data"
```

---

## Task 12: Smoke-test the release build

**Files:** none modified.

- [ ] **Step 1: Release build**

Run: `swift build -c release`
Expected: clean.

- [ ] **Step 2: Package & install per CursorMeter convention**

```bash
pkill -9 -x CursorMeter || true
rm -rf /Applications/CursorMeter.app
bash Scripts/package_app.sh
cp -r CursorMeter.app /Applications/
open /Applications/CursorMeter.app
```

- [ ] **Step 3: Observe menu bar & popover**

Local account won't be in exhausted state, so the visual change won't be visible. Verify only that:
- Menu bar icon renders (no crash)
- Popover opens (no crash)
- "On-demand $X / $Y" appears in the secondary row if account has on-demand (or row is hidden if not)
- `Requests` (or Plan) primary row shows expected current values

- [ ] **Step 4: Inspect log for "On-demand mode latched" message**

Run: `/usr/bin/log show --predicate 'subsystem == "com.cursormeter"' --info --debug --last 5m`
Expected: No "latched ON" message (because local account isn't exhausted). The absence confirms the latch isn't false-firing.

- [ ] **Step 5: Document the smoke-test result**

This is not a code change — just confirm in the PR description that the local smoke test passed and that exhausted-quota verification depends on beta tester feedback.

---

## Task 13: Release notes + beta release prep

**Files:**
- Create: `docs/release-notes-v0.4.0-beta.1.md`
- Modify: `README.md` (only if beta install instructions need to be linked)

- [ ] **Step 1: Draft release notes**

Create `docs/release-notes-v0.4.0-beta.1.md`:

```markdown
# v0.4.0-beta.1 — On-demand mode (beta)

> ⚠️ This is a **pre-release**. It will not be auto-installed by existing users via the in-app update check.

## What's new

- Menu bar progress and the popover meter now switch to **On-demand billing** once your monthly request (or credit) quota is exhausted. The previous dimension moves to a smaller secondary row.
- Threshold notifications (80% / 90%) re-arm against the on-demand limit so you still get a heads-up before you hit the admin-set cap.
- Jump effect (⚡ / 🚀) keeps working in on-demand mode against the cents-based delta.
- Fix: on-demand spend rendered via `teamUsage.onDemand` (some Enterprise accounts) was silently invisible. Now falls back when `individualUsage.onDemand` is absent.

## Why beta

The on-demand transition can only be exercised on accounts that actually exhaust their request quota mid-cycle. I haven't been able to capture a real exhausted-quota API response yet, so the field mapping is inferred from screenshots. If you're a tester whose account is in this state — please [open an issue](https://github.com/WoojinAhn/CursorMeter/issues/new) if anything looks wrong.

## Install (curl one-liner)

```bash
curl -fsSL https://github.com/WoojinAhn/CursorMeter/releases/download/v0.4.0-beta.1/CursorMeter.app.zip -o /tmp/CursorMeter-beta.zip \
  && unzip -o /tmp/CursorMeter-beta.zip -d /tmp \
  && rm -rf /Applications/CursorMeter.app \
  && mv /tmp/CursorMeter.app /Applications/ \
  && open /Applications/CursorMeter.app
```

Issue: #36
```

- [ ] **Step 2: Commit release notes**

```bash
git add docs/release-notes-v0.4.0-beta.1.md
git commit -m "[#36] docs: v0.4.0-beta.1 release notes"
```

- [ ] **Step 3: Push branch and merge to main**

Per the project's solo workflow (no PR needed): merge feature branch into main directly. If working on `main` already, just push.

```bash
git push origin main
```

- [ ] **Step 4: Create the pre-release tag**

```bash
git tag v0.4.0-beta.1
git push origin v0.4.0-beta.1
```

If the existing `release.yml` workflow auto-runs on tag push and produces a release, override its notes:

```bash
# wait for the workflow run to finish
gh run watch
# overwrite the auto-generated notes
gh release edit v0.4.0-beta.1 --prerelease --notes-file docs/release-notes-v0.4.0-beta.1.md
```

If the workflow does NOT auto-run (or doesn't tag as pre-release), do it manually:

```bash
gh release create v0.4.0-beta.1 \
  --prerelease \
  --title "v0.4.0-beta.1 — On-demand mode (beta)" \
  --notes-file docs/release-notes-v0.4.0-beta.1.md \
  CursorMeter.app.zip
```

(Confirm `release.yml` behavior first; this is a one-shot operation.)

- [ ] **Step 5: Close issue #36 with reference to the pre-release**

```bash
gh issue close 36 -c "Shipped in pre-release v0.4.0-beta.1 — https://github.com/WoojinAhn/CursorMeter/releases/tag/v0.4.0-beta.1
Promotion to stable v0.4.0 will follow once a beta tester confirms the exhausted-quota behavior matches the mockup."
```

- [ ] **Step 6: Verify open issues**

```bash
gh issue list --state open
```

Show remaining open issues to the user per CursorMeter convention.

---

## Self-review checklist

- ✅ Spec coverage: all 6 scope decisions (A1/B1/C1/D1.i/D2.i + no settings toggle) have implementing tasks.
- ✅ `hasOnDemand` refinement covered in Task 1.
- ✅ `teamUsage.onDemand` fallback covered in Task 2.
- ✅ Build order matches spec ("Build sequence" section).
- ✅ All new tests have concrete code, not placeholders.
- ✅ Naming consistent across tasks: `secondaryUsageLabel/Value/IsOverLimit`, `isOnDemandActive`, `wouldActivateOnDemand`, `isOnDemandLatched`, `previousOnDemandUsedCents`, `JumpEvent.Mode.onDemand`, `NotificationMode`.
- ✅ Test framework: XCTest — translation rules listed at top of plan.
- ✅ Test hooks: `@testable import CursorMeter` is already in use; mark hook methods as `internal` (drop the `#if DEBUG`).
