import XCTest
@testable import CursorMeter

/// Tests focus on the pure intensity-policy helper, which is the only piece of
/// `JumpEffectCoordinator` that can be exercised without an `NSStatusItem` and a
/// running NSApplication. The coordinator's image-swap orchestration is verified
/// by manual smoke testing per Issue #55.
final class JumpEffectCoordinatorTests: XCTestCase {

    // MARK: - Tier 0 (always inert)

    func testTierZeroNeverFires() {
        for intensity in JumpIntensity.allCases {
            let result = JumpEffectCoordinator.shouldFire(intensity: intensity, tier: .zero)
            XCTAssertFalse(result.fire, "tier 0 should never fire (intensity=\(intensity))")
            XCTAssertFalse(result.notify, "tier 0 should never notify (intensity=\(intensity))")
        }
    }

    // MARK: - Quiet

    func testQuietIgnoresTierOne() {
        let result = JumpEffectCoordinator.shouldFire(intensity: .quiet, tier: .one)
        XCTAssertFalse(result.fire)
        XCTAssertFalse(result.notify)
    }

    func testQuietFiresOnTierTwoWithoutNotification() {
        let result = JumpEffectCoordinator.shouldFire(intensity: .quiet, tier: .two)
        XCTAssertTrue(result.fire)
        XCTAssertFalse(result.notify)
    }

    // MARK: - Normal

    func testNormalFiresOnTierOneNoNotification() {
        let result = JumpEffectCoordinator.shouldFire(intensity: .normal, tier: .one)
        XCTAssertTrue(result.fire)
        XCTAssertFalse(result.notify)
    }

    func testNormalFiresOnTierTwoNoNotification() {
        let result = JumpEffectCoordinator.shouldFire(intensity: .normal, tier: .two)
        XCTAssertTrue(result.fire)
        XCTAssertFalse(result.notify)
    }

    // MARK: - Bold

    func testBoldFiresOnTierOneWithoutNotification() {
        let result = JumpEffectCoordinator.shouldFire(intensity: .bold, tier: .one)
        XCTAssertTrue(result.fire)
        XCTAssertFalse(result.notify, "Bold should only notify at tier 2")
    }

    func testBoldFiresAndNotifiesOnTierTwo() {
        let result = JumpEffectCoordinator.shouldFire(intensity: .bold, tier: .two)
        XCTAssertTrue(result.fire)
        XCTAssertTrue(result.notify)
    }

    // MARK: - Swap params

    func testSwapParamsTierOneUsesLightningNoGlow() {
        let params = JumpEffectCoordinator.swapParams(for: .one)
        XCTAssertEqual(params.emoji, "⚡")
        XCTAssertFalse(params.glow)
        XCTAssertEqual(params.durationMs, 1500)
    }

    func testSwapParamsTierTwoUsesRocketWithGlow() {
        let params = JumpEffectCoordinator.swapParams(for: .two)
        XCTAssertEqual(params.emoji, "🚀")
        XCTAssertTrue(params.glow)
        XCTAssertEqual(params.durationMs, 3000)
    }
}
