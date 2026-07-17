# Issue #81 — ThresholdRangeSlider design

Approved 2026-07-17 (mockup reviewed 2026-07-04, re-confirmed on screen today).
Supersedes nothing; consolidates the agreed design in issue #81 plus the one
open decision resolved today (track bounds).

## Goal

Replace the two independent Warning/Critical `NSSlider`s in Settings →
Notifications with a single dual-thumb range slider. The ordering constraint
(warning < critical) becomes structural, and the track itself shows what the
thresholds mean. Vertical footprint ~92pt → ~58pt.

## Decisions

| Decision | Value | Source |
|----------|-------|--------|
| Track range | **0–100%** full track (old 50–90 / 55–100 bounds dropped) | user, 2026-07-17 |
| Zones | green `[0, W)` → amber `[W, C)` → red `[C, 100]`, colors from `CircularProgressIcon.accentColor` / `warnColor` / `critColor` | issue #81 |
| Value bubbles | `W 60%` / `C 90%` above thumbs; when close, dodge vertically (one above, one below) | mockup |
| Snap | 5% steps | issue #81 |
| Thumb constraint | no crossing, minimum gap 5% → `W ∈ [0, C−5]`, `C ∈ [W+5, 100]` | issue #81 |
| Persistence | `warningThreshold` / `criticalThreshold` keys unchanged; `NotificationManager.evaluateThreshold` untouched | issue #81 |

## Component

New file `Sources/CursorMeter/ThresholdRangeSlider.swift` — custom `NSView`
(AppKit has no native range slider).

API (thin, value-only):

```swift
var warningValue: Int
var criticalValue: Int
var onChange: ((_ warning: Int, _ critical: Int) -> Void)?
```

- Mouse: mousedown grabs the nearest thumb, drag converts x → snapped value
  through a **pure static resolver** (see Testing), mouseup commits.
- Keyboard/VoiceOver: two `NSAccessibilityElement` children with slider role,
  arrow keys ±5% per thumb — preserves what two native `NSSlider`s gave for
  free.
- Drawing: flat track bar with the three zones, round white thumbs, bubbles
  drawn with `NSAttributedString`; uses dynamic system colors where applicable
  so light/dark both work.

## Integration

`SettingsViewController.makeNotificationsSection()`: `warningGrid` +
`warningSlider` + `criticalGrid` + `criticalSlider` (4 views) → one
`ThresholdRangeSlider` (plus the existing section header/checkbox).
`updateUI()` drops the dynamic `criticalSlider.minValue` juggling — the
constraint lives inside the control. On load, clamp `C = max(C, W+5)` in case
of corrupted defaults.

## Testing (critical logic only)

Pure static resolver funcs unit-tested; drawing/mouse excluded:

- x-coordinate → snapped value conversion (5% steps, track inset handling)
- boundary clamps at 0 and 100
- crossing attempt clamps to the 5% gap (both thumbs)
- corrupted-defaults clamp on load (via view-model round trip)
