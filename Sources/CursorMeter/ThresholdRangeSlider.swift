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

    /// Fires live during drag / keyboard nudge. Never fired by `setValues`.
    var onChange: ((_ warning: Int, _ critical: Int) -> Void)?

    /// Programmatic update (updateUI path). Normalizes both values so any
    /// corrupted persisted pair lands inside 0...100 with the minimum gap:
    /// W first (so C can always fit above it), then C.
    func setValues(warning: Int, critical: Int) {
        warningValue = min(max(warning, 0), 100 - Self.minGap)
        criticalValue = min(max(critical, warningValue + Self.minGap), 100)
        needsDisplay = true
    }

    // MARK: - Pure geometry/constraint logic

    static func snappedPercent(forX x: CGFloat, trackMinX: CGFloat, trackWidth: CGFloat) -> Int {
        guard trackWidth > 0 else { return 0 }
        let fraction = (x - trackMinX) / trackWidth
        let raw = fraction * 100
        let snapped = Int((raw / CGFloat(step)).rounded()) * step
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
