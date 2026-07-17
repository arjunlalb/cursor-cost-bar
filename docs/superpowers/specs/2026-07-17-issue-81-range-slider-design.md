# Issue #81 — ThresholdRangeSlider design

Approved 2026-07-17 (mockup reviewed 2026-07-04, re-confirmed on screen today).
Supersedes nothing; consolidates the agreed design in issue #81 plus the one
open decision resolved today (track bounds).

## Goal

Replace the two independent Warning/Critical `NSSlider`s in Settings →
Notifications with a single dual-thumb range slider. The ordering constraint
(warning < critical) becomes structural, and the track itself shows what the
thresholds mean. Vertical footprint ~92pt → ~76pt (incl. ticks + legend).

## Decisions

| Decision | Value | Source |
|----------|-------|--------|
| Track range | **0–100%** full track (old 50–90 / 55–100 bounds dropped) | user, 2026-07-17 |
| Zones | green `[0, W)` → amber `[W, C)` → red `[C, 100]`, colors from `CircularProgressIcon.accentColor` / `warnColor` / `critColor` | issue #81 |
| Value bubbles | colored chips (`W 60%` amber / `C 90%` red) above thumbs; when close, the **critical** bubble drops below the track | mockup |
| Snap | 5% steps | issue #81 |
| Thumb constraint | no crossing, minimum gap 5% → `W ∈ [0, C−5]`, `C ∈ [W+5, 100]` | issue #81 |
| Persistence | `warningThreshold` / `criticalThreshold` keys unchanged; `NotificationManager.evaluateThreshold` untouched | issue #81 |
| Thumbs | colored pills 14×24pt r7 (warning = `warnColor`, critical = `critColor`), not white circles | mockup, codex review |
| Ticks + legend | tick labels 0/25/50/75/100 under the track; legend row (정상 / Warning / Critical swatches) below — both inside the control; intrinsic height ~76pt | mockup, codex review |
| onChange timing | fires live during drag (matches current continuous NSSlider behavior); programmatic `setValues` never fires it | codex review |
| Normalization | `setValues` clamps **both** values: `W ∈ [0, 95]` first, then `C ∈ [W+5, 100]` — impossible to exceed 100. Display-side only; never writes back to the view model | codex review |
| Tie-break | mousedown at equal distance from both thumbs grabs **warning**; otherwise nearest | codex review |

## Component

New file `Sources/CursorMeter/ThresholdRangeSlider.swift` — custom `NSView`
(AppKit has no native range slider).

API (thin, value-only):

```swift
var warningValue: Int
var criticalValue: Int
var onChange: ((_ warning: Int, _ critical: Int) -> Void)?
```

- Mouse: `mouseDown` converts `event.locationInWindow` into view coordinates,
  grabs the nearest thumb (tie → warning), drag converts x → snapped value
  through a **pure static resolver** (see Testing); `onChange` fires on every
  value change during the drag. Degenerate geometry (track width ≤ 0 during
  early layout) resolves to 0 — no NaN/divide-by-zero.
- Keyboard: the view is a single first responder; ←/→ nudges the warning
  thumb ±5%, ⇧←/⇧→ nudges the critical thumb.
- VoiceOver: two `NSAccessibilityElement` children, each with slider role,
  label ("Warning threshold" / "Critical threshold"), current value, min/max,
  a screen-coordinate `accessibilityFrame` kept in sync on layout and value
  change, and `accessibilityPerformIncrement/Decrement`. Value changes post
  `.valueChanged` notifications.
- Drawing: all in `draw(_:)` (no layer-backed color caching, so appearance
  changes re-resolve dynamic colors): gray base track, three zone fills,
  colored pill thumbs, chip bubbles, tick labels, legend row.
- Swift 6: `NSView` subclass is implicitly `@MainActor`; `onChange` is a
  main-actor closure — no isolation gymnastics needed in the controller.

## Integration

`SettingsViewController.makeNotificationsSection()`: `warningGrid` +
`warningSlider` + `criticalGrid` + `criticalSlider` (4 views) → one retained
`thresholdSlider` property (plus the existing section header/checkbox).
The old sliders' explicit leading/trailing pins to `outerStack`
(`SettingsViewController.swift:95-100`) are replaced by equivalent pins on
`thresholdSlider` — the `.left`-aligned stack would otherwise collapse the
custom view. `updateUI()` drops the dynamic `criticalSlider.minValue`
juggling and pushes values via `setValues(warning:critical:)`, whose
normalization (see Decisions) absorbs corrupted defaults without writing
back to the view model.

## Testing (critical logic only)

Pure static resolver funcs unit-tested; drawing/mouse excluded:

- x-coordinate → snapped value conversion (5% steps, track inset handling)
- degenerate track width (≤ 0) yields 0, no NaN
- boundary clamps at 0 and 100
- crossing attempt clamps to the 5% gap (both thumbs)
- nearest-thumb selection incl. equidistant tie → warning
- `setValues` normalization: gap violation, W > 95, both out of range

## Revision note

2026-07-17: revised after codex:rescue spec review — full normalization rule,
live onChange, explicit layout pins, expanded accessibility contract, visual
spec aligned to mockup (colored pill thumbs, chip bubbles, ticks + legend,
critical-bubble dodge direction), degenerate-geometry guard, tie-break rule.
