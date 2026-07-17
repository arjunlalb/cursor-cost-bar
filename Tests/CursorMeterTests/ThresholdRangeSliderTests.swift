import XCTest
@testable import CursorMeter

/// #81: pure geometry/constraint logic of the dual-thumb threshold slider.
/// Drawing and mouse handling are excluded (verified visually).
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

    func test_snappedPercent_zeroTrackWidth_returnsZero() {
        XCTAssertEqual(ThresholdRangeSlider.snappedPercent(forX: 50, trackMinX: 10, trackWidth: 0), 0)
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

    // MARK: setValues normalization (corrupted defaults defense)

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

    func test_setValues_neverFiresOnChange() {
        let slider = ThresholdRangeSlider()
        var fired = false
        slider.onChange = { _, _ in fired = true }
        slider.setValues(warning: 30, critical: 70)
        XCTAssertFalse(fired)
    }
}
