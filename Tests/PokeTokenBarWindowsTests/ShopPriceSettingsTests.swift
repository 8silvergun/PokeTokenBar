#if os(Windows)
import XCTest
@testable import PokeTokenBar

final class ShopPriceSettingsTests: XCTestCase {
    func testPercentNormalizationClampsToSupportedRange() {
        XCTAssertEqual(ShopPriceSettings.normalizedPercent(-100), 10)
        XCTAssertEqual(ShopPriceSettings.normalizedPercent(10), 10)
        XCTAssertEqual(ShopPriceSettings.normalizedPercent(100), 100)
        XCTAssertEqual(ShopPriceSettings.normalizedPercent(200), 200)
        XCTAssertEqual(ShopPriceSettings.normalizedPercent(999), 200)
    }

    func testAdjustedPricePreservesOneHundredPercent() {
        XCTAssertEqual(ShopPriceSettings.adjustedPrice(500_000_000, percent: 100), 500_000_000)
    }

    func testAdjustedPriceScalesDownAndUp() {
        XCTAssertEqual(ShopPriceSettings.adjustedPrice(500_000_000, percent: 50), 250_000_000)
        XCTAssertEqual(ShopPriceSettings.adjustedPrice(4_000_000_000, percent: 150), 6_000_000_000)
    }
}
#endif
