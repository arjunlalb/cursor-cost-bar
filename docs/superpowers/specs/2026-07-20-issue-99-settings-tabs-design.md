# Issue #99 — Settings Window: Toolbar Tabs + Card Rows

**Date:** 2026-07-20
**Issue:** [#99](https://github.com/WoojinAhn/CursorMeter/issues/99)
**Mockup:** `docs/mockup-issue-99.html` (Option A agreed)

## Problem

The Settings window is a single scrolling pane with 7 flat sections
(Refresh / Notifications / Menu Bar / Usage Jump / Weekly Chart /
General / Version). Sections keep accumulating and the scroll is getting
long; row alignment is inconsistent (some controls left-flow, some
right-aligned).

## Survey result (drove the decision)

Menu-bar utilities split by section count, not by "modernity":

- Toolbar tabs: Rectangle, Itsycal, MonitorControl (4–6 sections)
- Sidebar: Ice, Stats, iStat Menus (10+ categories)

CursorMeter has 7 thin sections → 3 tabs. A sidebar is scale-mismatched
and expensive in pure AppKit. Chosen direction: **toolbar tabs for
structure + Cursor-IDE-style card rows for visuals** (Option A of the
mockup; user approved 2026-07-20).

## Design

### 1. Window structure — `NSTabViewController`

- `SettingsTabViewController: NSTabViewController` (new file), 
  `tabStyle = .toolbar`. It becomes the settings window's
  `contentViewController` in `CursorMeterApp.openSettings()`.
- Three tab items, each an `NSViewController` child:

| Tab | SF Symbol | Sections |
|-----|-----------|----------|
| General | `gearshape` | Refresh (interval popup, activity-refresh toggle) · Startup (launch at login, browser login) · Version/Update (version row, check/download, auth source, credits) |
| Notifications | `bell.badge` | Usage alerts master toggle · threshold range slider card · app status notifications |
| Appearance | `paintbrush` | Menu Bar text mode · Usage Jump (toggle, intensity, style) · Weekly Chart (toggle, today style) |

- Per-tab window resize: AppKit animates the frame when child
  `preferredContentSize`/fitting sizes differ — no custom code beyond
  setting each child's view to hug its content.
- Window title follows the selected tab
  (`canPropagateSelectedChildViewControllerTitle = true`, child
  `title` = tab label). System Settings convention.
- Fixed content width 420 pt (current 350 pt is too tight for
  title+caption left column next to a segmented control).

### 2. Card visual language

Two factory helpers (in a small `SettingsCardFactory.swift` or as
private helpers on the owning VC — implementer's choice, but shared
across tabs):

- `makeCard(rows: [NSView]) -> NSView` — layer-backed container:
  `NSColor.quaternarySystemFill`-family background, 1 px separator
  border (`separatorColor`), corner radius 10, rows stacked vertically
  with 1 px inset dividers between rows.
- `makeCardRow(title:caption:control:) -> NSView` — horizontal stack:
  left column = title (13 pt label) + optional caption
  (11 pt, `secondaryLabelColor`, wraps); right = control, trailing-
  aligned, fixed compression resistance. A `fullWidth` variant hosts
  wide content (threshold slider) as a stacked row spanning the card.
- Section headers (`Refresh`, `Menu Bar`, …) render **outside** cards:
  12 pt medium, `secondaryLabelColor`, sentence case — replacing the
  current UPPERCASE headers.

### 3. State & behavior — unchanged by contract

- All control instance variables, `@objc` action selectors, and
  `updateUI()` logic are preserved. This change is layout-only; no
  persistence, no ViewModel, no API changes.
- `NSTabViewController` instantiates all children up front (or on first
  display); `updateUI()` must keep working regardless of which tab is
  frontmost. Ownership: **each child VC owns its controls and its own
  `updateUI()`**; `SettingsTabViewController.updateUI()` force-loads
  views if needed and fans out to all three children. External callers
  (`CursorMeterApp` observation tracking) keep calling the single
  public entry point, same behavior as today.
- Conditional visibility carried over:
  - Weekly Chart card + its header hide entirely when
    `!viewModel.isEnterpriseTeam` (wrap header+card in one container).
  - Jump sub-rows (`Intensity`, `Style`) hide when the jump toggle is
    off — inside a card this collapses rows; card must re-layout
    without artifacts (same `isHidden` on the row views inside the
    card's stack).
  - Threshold card hides when usage alerts are off.
  - `percentOnly` still disables the Ratio menu item.
- Threshold slider keeps the full-width pinning fix from #75 — the
  full-width card row replaces the manual leading/trailing constraints.

### 4. Window lifecycle (#93 preservation)

`CursorMeterApp` keeps: `isReleasedWhenClosed = false`, strong-ref drop
+ `contentViewController` detach in `windowWillClose`. The tab
controller (holding 3 children) is the new "heavy view tree" — the
teardown path must release it exactly as it releases the current VC.
`window.styleMask` needs no manual toolbar flag; setting a toolbar-style
tab controller as content installs the toolbar.

## Out of scope

- No new settings, no reordering of what a control does.
- Popover (`MenuBarView`) untouched.
- No SwiftUI, no external deps (project constraint).

## Verification

- `swift test` green — no logic change expected, existing suite is the
  regression gate. No new unit tests: tab/card composition is view
  construction, outside SPM test scope (project policy: test critical
  business logic only).
- AX-path verification (osascript, element paths only): open each of
  the 3 tabs, toggle nothing persisted (#81 lesson), confirm control
  presence; capture per-tab screenshots via AX frame + `screencapture`.
- `docs/screenshots/settings.png` recapture (PII rule: no real
  name/email — settings window has none, but inspect before `git add`).
  Whether to ship 1 shot (General) or 3 is decided at capture time by
  what the README references.
- Memory note: #93 measured ~12 MB retained on close; after the tab
  restructure, re-verify the close path still releases (footprint spot
  check, not a formal A/B).

## Risks

- `NSTabViewController` + hand-built window plumbing has interaction
  edges (toolbar install timing, first-layout size). Mitigation: keep
  `openSettings()` the single construction path; verify resize
  animation manually per tab.
- 686-line `SettingsViewController` is rewritten into 3 children + tab
  controller + card factory; regression risk concentrates in
  `updateUI()` fan-out and conditional visibility. Mitigation: AX pass
  over every conditional state (enterprise on/off via mock is not
  reachable in the real app — verify weekly-chart hiding with the
  non-enterprise account state actually present on this machine).
