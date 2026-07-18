# IDE not-signed-in guidance (#88) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement `docs/superpowers/specs/2026-07-18-issue-88-ide-signin-guidance-design.md` — proactive IDE-availability detection in the login-required popover plus an [Open Cursor IDE] inducement that auto-connects when the user signs in.

**Architecture:** All state/logic in `UsageViewModel` (availability flag with generation-guarded async reads; a single watch task; launcher/presence seams). `MenuBarView.applyLoginRequiredStatus()` branches on the flag. `CursorMeterApp` wires production seams and adds the flag to the popover observation-tracking block (CLAUDE.md pitfall: unobserved state silently never updates the UI).

**Tech Stack:** Swift 6 strict concurrency, AppKit only, XCTest.

## Global Constraints

- Spec is authoritative for behavior rules (tick rule, cancellation set, generation guards, per-state Enter key)
- Cursor IDE bundle id on this machine: `com.todesktop.230313mzl4w4u92` (verified via `osascript`); keep by-name "Cursor" fallback
- Tests: never touch UNUserNotificationCenter / real Keychain; drive `ideCredentialProvider`, `ideAppLauncher` seams with shortened `watchTickInterval`

### Task 1: UsageViewModel — availability + watch (TDD)

**Files:** Modify `Sources/CursorMeter/UsageViewModel.swift`; Test `Tests/CursorMeterTests/IDESignInGuidanceTests.swift`

Produces (consumed by Tasks 2–3):
- `var ideCredentialAvailable: Bool?` (observable)
- `@ObservationIgnored var ideAppPresenceCheck: (() -> Bool)?`
- `@ObservationIgnored var ideAppLauncher: ((@escaping @MainActor (Bool) -> Void) -> Void)?`
- `func refreshIDEAvailability()`, `func openIDEAndWatch()`
- `@ObservationIgnored internal var watchTickInterval/watchTimeout` (Duration; defaults 3s/60s)

Steps: failing tests per the spec's Testing list (10 cases, grouped) → verify RED → implement per spec (generation counter shared by availability reads and watch; refresh() chain step 1 publishes the flag; logout() cancels watch) → GREEN → full `swift test` → commit `[#88] feat: IDE availability + sign-in watch in view model`.

### Task 2: MenuBarView — layout branch

**Files:** Modify `Sources/CursorMeter/MenuBarView.swift`

`applyLoginRequiredStatus()`: kick `viewModel.refreshIDEAvailability()`; branch per spec table (available/nil → current layout; unavailable+installed → hint + [Open Cursor IDE] + browser button with Enter; unavailable+absent → browser-only hint). [Open Cursor IDE] → `viewModel.openIDEAndWatch()`. Commit `[#88] feat: login layout branches on IDE availability`.

### Task 3: CursorMeterApp — wiring + observation

**Files:** Modify `Sources/CursorMeter/CursorMeterApp.swift`

- Wire production seams next to the existing `ideCredentialProvider` wiring (line ~48): presence via `NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.todesktop.230313mzl4w4u92")` (fallback by-name), launcher via `NSWorkspace.openApplication` completion → main-actor Bool
- **Add `_ = viewModel.ideCredentialAvailable` to `observePopover()`** tracking block
- `swift test` → commit `[#88] feat: wire IDE presence/launcher seams + observation`.

### Task 4: Verify + ship

- Reinstall; machine is already IDE-signed-out. Verify: guidance layout renders (hint + Open IDE + browser default), [Open Cursor IDE] launches Cursor, sign in → auto-connect within poll window; screenshots
- codex:rescue code review → triage → apply
- Merge → push → close #88 → `gh issue list --state open`
