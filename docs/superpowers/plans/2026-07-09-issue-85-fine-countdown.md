# Fine-Grained Cycle-End Countdown Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the whole-day reset countdown with render-time hour/minute granularity near the cycle boundary, plus an absolute-time tooltip (issue #85, spec `docs/superpowers/specs/2026-07-09-issue-85-fine-countdown-design.md`).

**Architecture:** A pure `resetCountdownText(until:now:)` on `UsageDisplayData` computes the label from the stored `resetDate` at render time; the frozen `daysUntilReset` stored property is deleted (its only consumer was `resetText`). `showPopover()` gains an `updateUI()` call so the value is fresh on open. A locally-created pinned `DateFormatter` renders the tooltip.

**Tech Stack:** Swift 6, AppKit, XCTest. Zero external dependencies.

## Global Constraints

- Copy (exact): `"Resets today"`, `"Resets in <1m"`, `"Resets in 40m"`-style (`Int(delta/60)`), `"Resets in 31h"`-style (`Int(delta/3600)`), `"Resets in N days"` (`Int(delta/86400)`). Floor everywhere; "Resets tomorrow" is removed.
- Zone boundaries: `<= 0` today / `< 60` `<1m` / `< 3600` minutes / `< 48*3600` hours / else days.
- Tooltip format (exact): `"M/d HH:mm"`, locale `en_US_POSIX`, calendar gregorian, user's current time zone, formatter created locally per call.
- Display-only change: no observation-tracking additions.
- Commit format: `[#85] <type>: description`.

---

### Task 1: Pure countdown function + boundary tests

**Files:**
- Modify: `Sources/CursorMeter/UsageModels.swift` (next to `resetText`, ~line 320)
- Test: `Tests/CursorMeterTests/UsageDisplayDataTests.swift` (new MARK section after the resetText tests, ~line 74)

**Interfaces:**
- Produces: `UsageDisplayData.resetCountdownText(until reset: Date, now: Date) -> String` (`nonisolated static`). Task 2 rewires `resetText` onto it.

- [ ] **Step 1: Write the failing tests** — add after `testResetTextMultipleDays` (line 73):

```swift
    // MARK: - resetCountdownText (#85 fine-grained countdown)

    private static let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    private func countdown(_ delta: TimeInterval) -> String {
        UsageDisplayData.resetCountdownText(
            until: Self.fixedNow.addingTimeInterval(delta),
            now: Self.fixedNow
        )
    }

    func testCountdownPastDeadline() {
        XCTAssertEqual(countdown(-3600), "Resets today")
        XCTAssertEqual(countdown(0), "Resets today")
    }

    func testCountdownSubMinute() {
        XCTAssertEqual(countdown(59), "Resets in <1m")
    }

    func testCountdownMinutes() {
        XCTAssertEqual(countdown(60), "Resets in 1m")
        XCTAssertEqual(countdown(40 * 60 + 30), "Resets in 40m")
        XCTAssertEqual(countdown(59 * 60 + 59), "Resets in 59m")
    }

    func testCountdownHours() {
        XCTAssertEqual(countdown(3600), "Resets in 1h")
        XCTAssertEqual(countdown(3600 + 60), "Resets in 1h")
        XCTAssertEqual(countdown(31 * 3600), "Resets in 31h")
        XCTAssertEqual(countdown(48 * 3600 - 60), "Resets in 47h")
    }

    func testCountdownDays() {
        XCTAssertEqual(countdown(48 * 3600), "Resets in 2 days")
        XCTAssertEqual(countdown(49 * 3600), "Resets in 2 days")
        XCTAssertEqual(countdown(14 * 86400), "Resets in 14 days")
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter UsageDisplayDataTests 2>&1 | grep -m2 "error:"`
Expected: compile error — `resetCountdownText` not a member.

- [ ] **Step 3: Implement** — in `Sources/CursorMeter/UsageModels.swift`, directly above `var resetText`:

```swift
    /// Render-time countdown label (#85). Pure so zone boundaries are
    /// unit-testable with an injected `now`. Floor in every zone: no unit
    /// overflow ("60m"/"48h" never render) and each zone hands off smoothly
    /// to the next. Days use elapsed seconds, not calendar days — DST/zone
    /// independent, and indistinguishable at ≥ 48h remaining.
    nonisolated static func resetCountdownText(until reset: Date, now: Date) -> String {
        let delta = reset.timeIntervalSince(now)
        if delta <= 0 { return "Resets today" }
        if delta < 60 { return "Resets in <1m" }
        if delta < 3600 { return "Resets in \(Int(delta / 60))m" }
        if delta < 48 * 3600 { return "Resets in \(Int(delta / 3600))h" }
        return "Resets in \(Int(delta / 86400)) days"
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter UsageDisplayDataTests 2>&1 | tail -3`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CursorMeter/UsageModels.swift Tests/CursorMeterTests/UsageDisplayDataTests.swift
git commit -m "[#85] feat: pure fine-grained reset countdown function

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Rewire `resetText`, delete `daysUntilReset`, migrate call sites

**Files:**
- Modify: `Sources/CursorMeter/UsageModels.swift` (property ~153, `withOnDemandActive` ~168, `resetText` ~320, factory helper ~340, factory calls ~432/~459)
- Modify: `Tests/CursorMeterTests/UsageDisplayDataTests.swift` (resetText tests 50–73, direct asserts 100/124, `makeData` 339/356, inline inits 410/745/766, `makeTokenData`-style init ~997, `makeCreditData` ~1005/1022)
- Modify: `Tests/CursorMeterTests/UsageViewModelTests.swift:199,216`
- Modify: `Tests/CursorMeterTests/UsageViewModelJumpTests.swift:257,274`
- Modify: `Tests/CursorMeterTests/WeeklyUsageTests.swift:593`

**Interfaces:**
- Consumes: Task 1's `resetCountdownText(until:now:)`.
- Produces: `var resetText: String?` computed from `resetDate` (same name, same nil contract). `UsageDisplayData` memberwise init loses the `daysUntilReset:` parameter (its last parameter becomes `resetDate:`).

- [ ] **Step 1: Rewrite the resetText tests** — replace the five tests at lines 50–73 with:

```swift
    func testResetTextNilWhenNoResetDate() {
        let data = makeData(used: 0, limit: 100)
        XCTAssertNil(data.resetText)
    }

    func testResetTextComputedFromResetDate() {
        let data = makeData(used: 0, limit: 100, resetDate: Date().addingTimeInterval(14 * 86400 + 3600))
        XCTAssertEqual(data.resetText, "Resets in 14 days")
    }
```

(`makeData` gains a `resetDate: Date? = nil` parameter in Step 2. The "today"/"tomorrow"/negative cases are now covered by Task 1's pure-function sweep.)

Update the two direct assertions:
- Line 100 `XCTAssertNil(data.daysUntilReset)` → `XCTAssertNil(data.resetText)`
- Line 124 `XCTAssertNotNil(data.daysUntilReset)` → `XCTAssertNotNil(data.resetText)`

- [ ] **Step 2: Remove `daysUntilReset` from source** — in `Sources/CursorMeter/UsageModels.swift`:

1. Delete the stored property (line 153): `let daysUntilReset: Int?`
2. In `withOnDemandActive` (~168), delete the `daysUntilReset: daysUntilReset` argument (and the trailing comma on the `resetDate: resetDate` line above it).
3. Replace `resetText` (~320) with:

```swift
    var resetText: String? {
        guard let resetDate else { return nil }
        return Self.resetCountdownText(until: resetDate, now: Date())
    }
```

4. Delete the factory helper (~340):

```swift
    private static func daysUntilReset(to resetDate: Date?) -> Int? {
        guard let resetDate else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: resetDate).day
    }
```

5. Delete the `daysUntilReset: daysUntilReset(to: resetDate)` argument at both factory call sites (~432, ~459), fixing the trailing comma on the preceding line.

- [ ] **Step 3: Migrate test call sites** — delete the `daysUntilReset:` argument (fixing the preceding line's trailing comma) at every memberwise `UsageDisplayData(...)` call, and drop fixture parameters:

- `UsageDisplayDataTests.swift` `makeData` (~339): replace parameter `daysUntilReset: Int? = 5` with `resetDate: Date? = nil`; in its init call, replace `resetDate: nil,` + `daysUntilReset: daysUntilReset` with `resetDate: resetDate`.
- `UsageDisplayDataTests.swift` inline inits at ~410, ~745, ~766, ~997: drop the `daysUntilReset:` line.
- `UsageDisplayDataTests.swift` `makeCreditData` (~1005): remove the `daysUntilReset: Int? = 5` parameter and the `daysUntilReset: daysUntilReset` argument.
- `UsageViewModelTests.swift` (~199 fixture param, ~216 argument): same removal as `makeCreditData`.
- `UsageViewModelJumpTests.swift` (~257, ~274): same removal.
- `WeeklyUsageTests.swift` (~593): drop the `daysUntilReset: nil` line.

Then `grep -rn "daysUntilReset" Sources Tests` must return nothing.

- [ ] **Step 4: Full suite**

Run: `swift test 2>&1 | grep -E "All tests|failures" | tail -2`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/CursorMeter/UsageModels.swift Tests/CursorMeterTests
git commit -m "[#85] feat: render-time resetText from resetDate; drop frozen daysUntilReset

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Absolute-time tooltip + fresh-on-open popover

**Files:**
- Modify: `Sources/CursorMeter/UsageModels.swift` (below `resetText`)
- Modify: `Sources/CursorMeter/MenuBarView.swift:504` (reset block in `applyData`)
- Modify: `Sources/CursorMeter/CursorMeterApp.swift:144` (`showPopover`)
- Test: `Tests/CursorMeterTests/UsageDisplayDataTests.swift`

**Interfaces:**
- Produces: `var resetAbsoluteText: String?` on `UsageDisplayData`.

- [ ] **Step 1: Write the failing test** — add after the countdown tests:

```swift
    func testResetAbsoluteTextFormat() {
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 10
        components.hour = 7; components.minute = 24
        let date = Calendar.current.date(from: components)!
        let data = makeData(used: 0, limit: 100, resetDate: date)
        XCTAssertEqual(data.resetAbsoluteText, "7/10 07:24")
    }

    func testResetAbsoluteTextNilWhenNoResetDate() {
        let data = makeData(used: 0, limit: 100)
        XCTAssertNil(data.resetAbsoluteText)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter UsageDisplayDataTests 2>&1 | grep -m2 "error:"`
Expected: compile error — `resetAbsoluteText` not a member.

- [ ] **Step 3: Implement** — in `UsageModels.swift`, below `resetText`:

```swift
    /// Local wall-clock cycle end for the tooltip, e.g. "7/10 07:24" (#85).
    /// Formatter is created per call: once per updateUI() makes caching
    /// pointless, and a shared mutable DateFormatter global is a concurrency
    /// footgun. Locale/calendar pinned so digits don't drift by user locale.
    var resetAbsoluteText: String? {
        guard let resetDate else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: resetDate)
    }
```

In `MenuBarView.swift` (reset block, line ~504):

```swift
        // Reset
        resetLabel.stringValue = data.resetText ?? ""
        resetLabel.toolTip = data.resetAbsoluteText
```

In `CursorMeterApp.swift` `showPopover()` (~144), before `popover.show`:

```swift
    private func showPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        // Countdown text is render-time-computed (#85); refresh it at the
        // moment of opening rather than waiting for the next observation tick.
        (popover.contentViewController as? MenuBarPopoverViewController)?.updateUI()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        installPopoverDismissMonitor()
    }
```

- [ ] **Step 4: Build + full suite**

Run: `swift build 2>&1 | tail -2 && swift test 2>&1 | grep -E "All tests" | tail -1`
Expected: build succeeds, all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/CursorMeter/UsageModels.swift Sources/CursorMeter/MenuBarView.swift Sources/CursorMeter/CursorMeterApp.swift Tests/CursorMeterTests/UsageDisplayDataTests.swift
git commit -m "[#85] feat: absolute-time tooltip + fresh countdown on popover open

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Ship — merge, push, reinstall, verify

**Files:** none (operations only)

- [ ] **Step 1: Full verification**

Run: `swift test 2>&1 | grep -E "All tests|failures" | tail -2`
Expected: `Test Suite 'All tests' passed`.

- [ ] **Step 2: Merge to main and push** (solo direct merge)

```bash
git checkout main && git merge --no-ff feature/85-fine-grained-countdown -m "Merge feature/85-fine-grained-countdown (#85)" && git push origin main
```

- [ ] **Step 3: Reinstall the local app** (CLAUDE.md sequence)

```bash
pkill -9 -x CursorMeter
rm -rf /Applications/CursorMeter.app CursorMeter.app
bash Scripts/package_app.sh
cp -r CursorMeter.app /Applications/
open /Applications/CursorMeter.app
```

- [ ] **Step 4: Manual verify** — open the popover; with the real cycle end within 48h the label shows an hour count (e.g. "Resets in 31h"), otherwise "Resets in N days"; hovering the label shows "M/d HH:mm". Report what is actually displayed.

- [ ] **Step 5: Close the issue**

```bash
gh issue close 85 --comment "Shipped: render-time hour/minute countdown + absolute-time tooltip. Spec: docs/superpowers/specs/2026-07-09-issue-85-fine-countdown-design.md"
gh issue list --state open
```
