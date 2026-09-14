import XCTest
@testable import PokeTokenBar

final class ModelPricingTests: XCTestCase {
    func testFable5And51ExactRates() {
        XCTAssertEqual(ModelPricing.rate(for: "claude-fable-5"), .perMillion(10, 50, 12.5, 1.0))
        XCTAssertEqual(ModelPricing.rate(for: "claude-fable-5-1"), .perMillion(10, 50, 12.5, 0.25))
    }

    func testFable51CacheReadCost() {
        XCTAssertEqual(
            ModelPricing.cost(model: "claude-fable-5-1", input: 0, output: 0, cacheWrite: 0, cacheRead: 1_000_000),
            0.25,
            accuracy: 1e-12
        )
    }

    func testLegacyFamilyFallbacksRemainCompatible() {
        XCTAssertEqual(ModelPricing.rate(for: "claude-fable-6"), .perMillion(10, 50, 12.5, 1.0))
        XCTAssertEqual(ModelPricing.rate(for: "gpt-5.6-codex"), .perMillion(5, 30, 0, 0.5))
        XCTAssertEqual(ModelPricing.rate(for: "gemini-3.1-pro-preview"), .perMillion(1.25, 10, 0, 0.3125))
        XCTAssertEqual(ModelPricing.rate(for: "gemini-3-flash-lite"), .perMillion(0.30, 2.5, 0, 0.075))
    }

    func testServerPricedAndSubscriptionNamespacesStayUnpriced() {
        XCTAssertEqual(ModelPricing.rate(for: "grok-codex-next"), .zero)
        XCTAssertEqual(ModelPricing.rate(for: "antigravity/claude-opus-4-8"), .zero)
    }
}
