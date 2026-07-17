# ThresholdRangeSlider (#81) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the two Warning/Critical NSSliders in Settings → Notifications with one dual-thumb range slider (custom NSView) per the approved spec.

**Architecture:** A self-contained `ThresholdRangeSlider: NSView` owns all geometry/constraint logic as pure static functions (unit-testable without a window), plus drawing (zones, colored pill thumbs, chip bubbles, ticks, legend), mouse tracking, keyboard, and two virtual accessibility elements. `SettingsViewController` swaps four views for one retained property with explicit width pins and deletes its cross-slider clamping code. Persistence keys and `NotificationManager` are untouched.

**Revision note (2026-07-17):** updated after codex:rescue spec review — see spec Revision note. Key deltas vs the first draft: colored pill thumbs 14×24 (not white circles), chip-style bubbles, critical bubble dodges BELOW the track, ticks 0/25/50/75/100 + legend inside the control (intrinsic height 76), a11y elements carry min/max + screen frames + .valueChanged posts, `setValues` clamps W to ≤95 before raising C, Task 3 keeps explicit leading/trailing pins on the new control.

**Tech Stack:** Swift 6 strict concurrency, AppKit only (zero external deps), XCTest.

## Global Constraints

- Swift 6 strict concurrency: UI types are `@MainActor` (NSView subclasses implicitly)
- Zero external dependencies — macOS SDK only
- Track range 0–100%, snap 5%, min gap 5% (`W ∈ [0, C−5]`, `C ∈ [W+5, 100]`)
- Zone colors: `CircularProgressIcon.accentColor` / `.warnColor` / `.critColor`
- Persistence keys `warningThreshold` / `criticalThreshold` unchanged
- Tests must not touch UNUserNotificationCenter or the real Keychain

---

### Task 1: Pure resolver logic (TDD)

**Files:**
- Create: `Sources/CursorMeter/ThresholdRangeSlider.swift`
- Test: `Tests/CursorMeterTests/ThresholdRangeSliderTests.swift`

**Interfaces:**
- Produces:
  - `enum ThresholdRangeSlider.Thumb { case warning, critical }`
  - `static func snappedPercent(forX x: CGFloat, trackMinX: CGFloat, trackWidth: CGFloat) -> Int`
  - `static func resolve(dragging thumb: Thumb, toRaw raw: Int, warning: Int, critical: Int) -> (warning: Int, critical: Int)`
  - `static func nearestThumb(toPercent p: Int, warning: Int, critical: Int) -> Thumb`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import CursorMeter

@MainActor
final class ThresholdRangeSliderTests: XCTestCase {

    // MARK: snappedPercent

    func test_snappedPercent_midTrack_snapsTo5() {
        // track from x=10, width 200 → x=112 is 51% → snaps to 50
        XCTAssertEqual(ThresholdRangeSlider.snappedPercent(forX: 112, trackMinX: 10, trackWidth: 200), 50)
    }

    func test_snappedPercent_clampsToTrackEnds() {
        XCTAssertEqual(ThresholdRangeSlider.snappedPercent(forX: -50, trackMinX: 10, trackWidth: 200), 0)
        XCTAssertEqual(ThresholdRangeSlider.snappedPercent(forX: 999, trackMinX: 10, trackWidth: 200), 100)
    }

    // MARK: resolve — gap + bounds

    func test_resolve_warningCannotCrossCritical() {
        let r = ThresholdRangeSlider.resolve(dragging: .warning, toRaw: 95, warning: 60, critical: 90)
        XCTAssertEqual(r.warning, 85)   // clamped to critical − 5
        XCTAssertEqual(r.critical, 90)
    }

    func test_resolve_criticalCannotCrossWarning() {
        let r = ThresholdRangeSlider.resolve(dragging: .critical, toRaw: 40, warning: 60, critical: 90)
        XCTAssertEqual(r.warning, 60)
        XCTAssertEqual(r.critical, 65)  // clamped to warning + 5
    }

    func test_resolve_boundsHold() {
        XCTAssertEqual(ThresholdRangeSlider.resolve(dragging: .warning, toRaw: -10, warning: 60, critical: 90).warning, 0)
        XCTAssertEqual(ThresholdRangeSlider.resolve(dragging: .critical, toRaw: 200, warning: 60, critical: 90).critical, 100)
    }

    // MARK: nearestThumb

    func test_nearestThumb_picksCloser_tieGoesToWarning() {
        XCTAssertEqual(ThresholdRangeSlider.nearestThumb(toPercent: 61, warning: 60, critical: 90), .warning)
        XCTAssertEqual(ThresholdRangeSlider.nearestThumb(toPercent: 89, warning: 60, critical: 90), .critical)
        XCTAssertEqual(ThresholdRangeSlider.nearestThumb(toPercent: 75, warning: 60, critical: 90), .warning)
    }

    // MARK: value setters clamp (corrupted defaults defense)

    func test_setValues_clampsGapViolation() {
        let slider = ThresholdRangeSlider()
        slider.setValues(warning: 88, critical: 60)
        XCTAssertEqual(slider.warningValue, 88)
        XCTAssertEqual(slider.criticalValue, 93)   // max(60, 88+5)
    }

    func test_setValues_corruptedBothOutOfRange_normalizesWithin0to100() {
        let slider = ThresholdRangeSlider()
        slider.setValues(warning: 120, critical: 3)
        XCTAssertEqual(slider.warningValue, 95)    // clamped to 100 − gap first
        XCTAssertEqual(slider.criticalValue, 100)  // then raised to W+5, capped at 100
    }

    func test_snappedPercent_zeroTrackWidth_returnsZero() {
        XCTAssertEqual(ThresholdRangeSlider.snappedPercent(forX: 50, trackMinX: 10, trackWidth: 0), 0)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter ThresholdRangeSliderTests` → FAIL (type not found)

- [ ] **Step 3: Minimal implementation (logic-only skeleton)**

```swift
import AppKit

/// Dual-thumb range slider for the Warning/Critical notification thresholds
/// (#81). AppKit has no native range slider, so this custom view owns the
/// track drawing, two thumbs, value bubbles, mouse/keyboard input, and
/// per-thumb accessibility. All geometry/constraint math lives in pure
/// static funcs so it is testable without a window.
final class ThresholdRangeSlider: NSView {

    enum Thumb { case warning, critical }

    static let step = 5
    static let minGap = 5

    private(set) var warningValue = 80
    private(set) var criticalValue = 90
    var onChange: ((_ warning: Int, _ critical: Int) -> Void)?

    func setValues(warning: Int, critical: Int) {
        warningValue = min(max(warning, 0), 100 - Self.minGap)
        criticalValue = min(max(critical, warningValue + Self.minGap), 100)
        needsDisplay = true
    }

    static func snappedPercent(forX x: CGFloat, trackMinX: CGFloat, trackWidth: CGFloat) -> Int {
        guard trackWidth > 0 else { return 0 }
        let fraction = (x - trackMinX) / trackWidth
        let raw = Int((fraction * 100).rounded())
        let snapped = Int((Double(raw) / Double(step)).rounded()) * step
        return min(max(snapped, 0), 100)
    }

    static func resolve(dragging thumb: Thumb, toRaw raw: Int, warning: Int, critical: Int) -> (warning: Int, critical: Int) {
        switch thumb {
        case .warning:
            return (min(max(raw, 0), critical - minGap), critical)
        case .critical:
            return (warning, min(max(raw, warning + minGap), 100))
        }
    }

    static func nearestThumb(toPercent p: Int, warning: Int, critical: Int) -> Thumb {
        abs(p - warning) <= abs(p - critical) ? .warning : .critical
    }
}
```

- [ ] **Step 4: Run to verify pass** — `swift test --filter ThresholdRangeSliderTests` → PASS
- [ ] **Step 5: Commit** — `[#81] feat: range-slider resolver logic + tests`

### Task 2: Drawing, mouse, keyboard, accessibility

**Files:**
- Modify: `Sources/CursorMeter/ThresholdRangeSlider.swift`

**Interfaces:**
- Consumes: Task 1 statics
- Produces: fully rendering/interactive control; `intrinsicContentSize` height 58

Add to the class (complete code; geometry constants at top):

```swift
    // Layout metrics (mockup: bubbles above track, 58pt total)
    private static let trackHeight: CGFloat = 4
    private static let thumbRadius: CGFloat = 8
    private static let bubbleHeight: CGFloat = 17
    private static let trackInsetX: CGFloat = 10

    private var activeThumb: Thumb?

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 58) }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var trackRect: NSRect {
        NSRect(x: Self.trackInsetX,
               y: bounds.midY + 6,
               width: bounds.width - Self.trackInsetX * 2,
               height: Self.trackHeight)
    }

    private func thumbCenter(_ value: Int) -> NSPoint {
        let t = trackRect
        return NSPoint(x: t.minX + t.width * CGFloat(value) / 100, y: t.midY)
    }

    override func draw(_ dirtyRect: NSRect) {
        let t = trackRect
        let wx = thumbCenter(warningValue).x
        let cx = thumbCenter(criticalValue).x
        // zones
        func fill(_ rect: NSRect, _ color: NSColor) {
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }
        fill(NSRect(x: t.minX, y: t.minY, width: wx - t.minX, height: t.height), CircularProgressIcon.accentColor)
        fill(NSRect(x: wx, y: t.minY, width: cx - wx, height: t.height), CircularProgressIcon.warnColor)
        fill(NSRect(x: cx, y: t.minY, width: t.maxX - cx, height: t.height), CircularProgressIcon.critColor)
        // thumbs
        for value in [warningValue, criticalValue] {
            let c = thumbCenter(value)
            let knob = NSRect(x: c.x - Self.thumbRadius, y: c.y - Self.thumbRadius,
                              width: Self.thumbRadius * 2, height: Self.thumbRadius * 2)
            NSColor.controlColor.setFill()
            let path = NSBezierPath(ovalIn: knob)
            path.fill()
            NSColor.separatorColor.setStroke()
            path.stroke()
        }
        drawBubbles(warningX: wx, criticalX: cx)
    }

    private func drawBubbles(warningX: CGFloat, criticalX: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let wText = NSAttributedString(string: "W \(warningValue)%", attributes: attrs)
        let cText = NSAttributedString(string: "C \(criticalValue)%", attributes: attrs)
        let wSize = wText.size(), cSize = cText.size()
        let topY = trackRect.minY - Self.thumbRadius - Self.bubbleHeight
        var wOrigin = NSPoint(x: clampBubbleX(warningX - wSize.width / 2, width: wSize.width), y: topY)
        let cOrigin = NSPoint(x: clampBubbleX(criticalX - cSize.width / 2, width: cSize.width), y: topY)
        // dodge: if bubbles would overlap horizontally, drop warning below track
        if wOrigin.x + wSize.width + 4 > cOrigin.x {
            wOrigin.y = trackRect.maxY + Self.thumbRadius + 2
        }
        wText.draw(at: wOrigin)
        cText.draw(at: cOrigin)
    }

    private func clampBubbleX(_ x: CGFloat, width: CGFloat) -> CGFloat {
        min(max(x, 0), bounds.width - width)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        let p = Self.snappedPercent(forX: x, trackMinX: trackRect.minX, trackWidth: trackRect.width)
        activeThumb = Self.nearestThumb(toPercent: p, warning: warningValue, critical: criticalValue)
        applyDrag(toPercent: p)
    }

    override func mouseDragged(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        applyDrag(toPercent: Self.snappedPercent(forX: x, trackMinX: trackRect.minX, trackWidth: trackRect.width))
    }

    override func mouseUp(with event: NSEvent) { activeThumb = nil }

    private func applyDrag(toPercent p: Int) {
        guard let thumb = activeThumb else { return }
        let r = Self.resolve(dragging: thumb, toRaw: p, warning: warningValue, critical: criticalValue)
        guard r.warning != warningValue || r.critical != criticalValue else { return }
        warningValue = r.warning
        criticalValue = r.critical
        needsDisplay = true
        onChange?(warningValue, criticalValue)
    }

    // MARK: Keyboard (←/→ = warning, ⇧←/⇧→ = critical)

    override func keyDown(with event: NSEvent) {
        let delta: Int
        switch event.specialKey {
        case .leftArrow:  delta = -Self.step
        case .rightArrow: delta = Self.step
        default: super.keyDown(with: event); return
        }
        let thumb: Thumb = event.modifierFlags.contains(.shift) ? .critical : .warning
        nudge(thumb, by: delta)
    }

    private func nudge(_ thumb: Thumb, by delta: Int) {
        let raw = (thumb == .warning ? warningValue : criticalValue) + delta
        activeThumb = thumb
        applyDrag(toPercent: raw)
        activeThumb = nil
    }
```

Accessibility (two virtual slider elements):

```swift
    private lazy var axWarning = makeAXThumb(.warning, label: "Warning threshold")
    private lazy var axCritical = makeAXThumb(.critical, label: "Critical threshold")

    private func makeAXThumb(_ thumb: Thumb, label: String) -> ThumbAXElement {
        let el = ThumbAXElement()
        el.thumb = thumb
        el.owner = self
        el.setAccessibilityRole(.slider)
        el.setAccessibilityLabel(label)
        el.setAccessibilityParent(self)
        return el
    }

    override func accessibilityChildren() -> [Any]? { [axWarning, axCritical] }
    override func isAccessibilityElement() -> Bool { false }

    fileprivate func axValue(for thumb: Thumb) -> Int { thumb == .warning ? warningValue : criticalValue }
    fileprivate func axNudge(_ thumb: Thumb, by delta: Int) { nudge(thumb, by: delta) }
}

private final class ThumbAXElement: NSAccessibilityElement {
    weak var owner: ThresholdRangeSlider?
    var thumb: ThresholdRangeSlider.Thumb = .warning

    override func accessibilityValue() -> Any? { "\(owner?.axValue(for: thumb) ?? 0)%" }
    override func accessibilityPerformIncrement() -> Bool { owner?.axNudge(thumb, by: ThresholdRangeSlider.step); return true }
    override func accessibilityPerformDecrement() -> Bool { owner?.axNudge(thumb, by: -ThresholdRangeSlider.step); return true }
}
```

- [ ] **Step 1: implement** (code above)
- [ ] **Step 2: `swift build` + `swift test`** → all green (Task 1 tests still pass)
- [ ] **Step 3: Commit** — `[#81] feat: range-slider drawing, input, accessibility`

### Task 3: SettingsViewController integration

**Files:**
- Modify: `Sources/CursorMeter/SettingsViewController.swift`

**Interfaces:**
- Consumes: `ThresholdRangeSlider` (`setValues`, `onChange`)

- [ ] **Step 1: Replace controls**

Declarations: delete `warningSlider`, `criticalSlider`, `warningValueLabel`, `criticalValueLabel`; add `private var thresholdSlider = ThresholdRangeSlider()`.

`makeNotificationsSection()` — threshold block becomes:

```swift
        thresholdSlider = ThresholdRangeSlider()
        thresholdSlider.translatesAutoresizingMaskIntoConstraints = false
        thresholdSlider.onChange = { [weak self] warning, critical in
            self?.viewModel.setWarningThreshold(warning)
            self?.viewModel.setCriticalThreshold(critical)
        }
        let thresholdStack = NSStackView(views: [thresholdSlider])
```

`updateUI()` threshold block becomes (clamp defends corrupted defaults):

```swift
        thresholdSlider.setValues(
            warning: viewModel.warningThreshold,
            critical: viewModel.criticalThreshold
        )
```

Delete `warningSliderChanged` / `criticalSliderChanged` actions and `makeThresholdGrid` if now unused. Keep the width pins on `thresholdBox` (`thresholdSlider` replaces the old slider pins at `SettingsViewController.swift:95-100`).

- [ ] **Step 2: `swift test`** → all green
- [ ] **Step 3: Commit** — `[#81] feat: settings uses ThresholdRangeSlider`

### Task 4: Verification + ship

- [ ] Reinstall app (CLAUDE.md sequence), open Settings, screenshot → compare against `docs/mockup-issue-81.html` (zones, bubbles, dodge when thumbs close)
- [ ] Drag both thumbs; confirm persisted values change (relaunch Settings shows same)
- [ ] codex:rescue code review, apply verified findings
- [ ] Push, close #81 with evidence, `gh issue list --state open`
