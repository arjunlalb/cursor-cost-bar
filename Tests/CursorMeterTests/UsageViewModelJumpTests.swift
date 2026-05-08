import XCTest
@testable import CursorMeter

/// Unit tests for jump-tier classification and delta formatting.
/// These exercise nonisolated static helpers on `UsageViewModel`, which mirror the
/// canonical-unit math used by `UsageViewModel.refresh()`.
final class UsageViewModelJumpTests: XCTestCase {

    // MARK: - Tier classification (with limit > 0)

    func testTierZeroJustBelow5Percent() {
        // 4.9% of 1000 cents = 49 cents
        let tier = UsageViewModel.classifyTier(mode: .credit, delta: 49, limit: 1000)
        XCTAssertEqual(tier, .zero)
    }

    func testTierOneAt5PercentBoundary() {
        let tier = UsageViewModel.classifyTier(mode: .credit, delta: 50, limit: 1000)
        XCTAssertEqual(tier, .one)
    }

    func testTierOneJustBelow15Percent() {
        // 14.9% of 1000 cents = 149 cents
        let tier = UsageViewModel.classifyTier(mode: .credit, delta: 149, limit: 1000)
        XCTAssertEqual(tier, .one)
    }

    func testTierTwoAt15PercentBoundary() {
        let tier = UsageViewModel.classifyTier(mode: .credit, delta: 150, limit: 1000)
        XCTAssertEqual(tier, .two)
    }

    func testTierZeroForZeroDelta() {
        let tier = UsageViewModel.classifyTier(mode: .credit, delta: 0, limit: 1000)
        XCTAssertEqual(tier, .zero)
    }

    func testTierZeroForNegativeDelta() {
        // Cycle reset: classify-helper itself returns zero rather than firing.
        let tier = UsageViewModel.classifyTier(mode: .credit, delta: -100, limit: 1000)
        XCTAssertEqual(tier, .zero)
    }

    // MARK: - Fixed-threshold fallback (limit ≤ 0)

    func testCreditFallbackTierBoundaries() {
        // limit ≤ 0 → cents-based fixed thresholds: 5 / 15
        XCTAssertEqual(UsageViewModel.classifyTier(mode: .credit, delta: 4, limit: 0), .zero)
        XCTAssertEqual(UsageViewModel.classifyTier(mode: .credit, delta: 5, limit: 0), .one)
        XCTAssertEqual(UsageViewModel.classifyTier(mode: .credit, delta: 14, limit: 0), .one)
        XCTAssertEqual(UsageViewModel.classifyTier(mode: .credit, delta: 15, limit: 0), .two)
    }

    func testRequestFallbackTierBoundaries() {
        // limit ≤ 0 → request-based fixed thresholds: 1 / 5
        XCTAssertEqual(UsageViewModel.classifyTier(mode: .request, delta: 0.9, limit: 0), .zero)
        XCTAssertEqual(UsageViewModel.classifyTier(mode: .request, delta: 1, limit: 0), .one)
        XCTAssertEqual(UsageViewModel.classifyTier(mode: .request, delta: 4, limit: 0), .one)
        XCTAssertEqual(UsageViewModel.classifyTier(mode: .request, delta: 5, limit: 0), .two)
    }

    // MARK: - Percent-only mode (5%p / 15%p)

    func testPercentModeTierBoundaries() {
        // Percent-only: limit is 100, deltas are %-points
        XCTAssertEqual(UsageViewModel.classifyTier(mode: .percent, delta: 4.9, limit: 100), .zero)
        XCTAssertEqual(UsageViewModel.classifyTier(mode: .percent, delta: 5.0, limit: 100), .one)
        XCTAssertEqual(UsageViewModel.classifyTier(mode: .percent, delta: 14.9, limit: 100), .one)
        XCTAssertEqual(UsageViewModel.classifyTier(mode: .percent, delta: 15.0, limit: 100), .two)
    }

    // MARK: - displayDelta formatting

    func testDisplayDeltaCreditUSDFormat() {
        // 30 cents -> "+$0.30"
        let event = UsageViewModel.makeJumpEvent(mode: .credit, delta: 30, limit: 1000)
        XCTAssertEqual(event.displayDelta, "+$0.30")
    }

    func testDisplayDeltaCreditWholeDollar() {
        let event = UsageViewModel.makeJumpEvent(mode: .credit, delta: 150, limit: 1000)
        XCTAssertEqual(event.displayDelta, "+$1.50")
    }

    func testDisplayDeltaRequestFormat() {
        let event = UsageViewModel.makeJumpEvent(mode: .request, delta: 30, limit: 500)
        XCTAssertEqual(event.displayDelta, "+30")
    }

    func testDisplayDeltaPercentFormat() {
        let event = UsageViewModel.makeJumpEvent(mode: .percent, delta: 15.0, limit: 100)
        XCTAssertEqual(event.displayDelta, "+15.0%")
    }

    // MARK: - JumpEvent end-to-end shape

    func testMakeJumpEventPopulatesFields() {
        let event = UsageViewModel.makeJumpEvent(mode: .credit, delta: 200, limit: 1000)
        XCTAssertEqual(event.tier, .two)
        XCTAssertEqual(event.deltaCanonical, 200)
        XCTAssertEqual(event.deltaPct, 20.0, accuracy: 0.001)
        XCTAssertEqual(event.mode, .credit)
        XCTAssertEqual(event.displayDelta, "+$2.00")
    }

    func testMakeJumpEventDeltaPctWithZeroLimitIsZero() {
        // No meaningful percent when limit is 0 — avoids divide-by-zero noise in UI.
        let event = UsageViewModel.makeJumpEvent(mode: .request, delta: 10, limit: 0)
        XCTAssertEqual(event.deltaPct, 0)
        XCTAssertEqual(event.tier, .two)  // fallback: 10 ≥ 5 requests
    }

    // MARK: - Settings persistence + setters

    @MainActor
    func testJumpSettingsDefaults() {
        UserDefaults.standard.removeObject(forKey: "jumpEffectEnabled")
        UserDefaults.standard.removeObject(forKey: "jumpIntensity")
        let vm = UsageViewModel()
        XCTAssertTrue(vm.jumpEffectEnabled)
        XCTAssertEqual(vm.jumpIntensity, .normal)
    }

    @MainActor
    func testJumpSettingsSettersPersist() {
        let vm = UsageViewModel()
        vm.setJumpEffectEnabled(false)
        vm.setJumpIntensity(.bold)
        XCTAssertFalse(vm.jumpEffectEnabled)
        XCTAssertEqual(vm.jumpIntensity, .bold)
        XCTAssertEqual(UserDefaults.standard.bool(forKey: "jumpEffectEnabled"), false)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "jumpIntensity"), JumpIntensity.bold.rawValue)

        // Cleanup so other tests aren't affected.
        UserDefaults.standard.removeObject(forKey: "jumpEffectEnabled")
        UserDefaults.standard.removeObject(forKey: "jumpIntensity")
    }
}
