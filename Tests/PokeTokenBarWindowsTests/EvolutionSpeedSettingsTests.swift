#if os(Windows)
import XCTest
@testable import PokeTokenBar

final class EvolutionSpeedSettingsTests: XCTestCase {
    func testMultiplierNormalizationClampsToSupportedRange() {
        XCTAssertEqual(EvolutionSpeedSettings.normalizedMultiplier(-10), 1)
        XCTAssertEqual(EvolutionSpeedSettings.normalizedMultiplier(1), 1)
        XCTAssertEqual(EvolutionSpeedSettings.normalizedMultiplier(7), 7)
        XCTAssertEqual(EvolutionSpeedSettings.normalizedMultiplier(20), 20)
        XCTAssertEqual(EvolutionSpeedSettings.normalizedMultiplier(99), 20)
    }

    func testAdjustedThresholdPreservesOneX() {
        XCTAssertEqual(EvolutionSpeedSettings.adjustedThreshold(125_000_000, multiplier: 1), 125_000_000)
    }

    func testAdjustedThresholdUsesCeilingDivision() {
        XCTAssertEqual(EvolutionSpeedSettings.adjustedThreshold(125_000_001, multiplier: 2), 62_500_001)
        XCTAssertEqual(EvolutionSpeedSettings.adjustedThreshold(125_000_000, multiplier: 5), 25_000_000)
    }

    func testAdjustedThresholdNeverFallsBelowOneToken() {
        XCTAssertEqual(EvolutionSpeedSettings.adjustedThreshold(1, multiplier: 20), 1)
    }
}
#endif
