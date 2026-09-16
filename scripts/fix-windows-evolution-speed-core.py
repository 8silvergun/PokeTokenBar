from pathlib import Path

store_path = Path("Sources/PokeTokenBar/WindowsCore/CompanionStore.swift")
store = store_path.read_text(encoding="utf-8")
needle = "PokemonBalance.phaseThreshold"
count = store.count(needle)
if count != 4:
    raise SystemExit(f"WindowsCore threshold sweep: expected 4 call sites, found {count}")
store = store.replace(needle, "EvolutionSpeedSettings.phaseThreshold")
store_path.write_text(store, encoding="utf-8")

settings_path = Path("Sources/PokeTokenBar/WindowsCore/EvolutionSpeedSettings.swift")
if settings_path.exists():
    raise SystemExit(f"{settings_path} already exists")
settings_path.write_text('''import Foundation

/// Windows companion growth-speed preference. Core/ is excluded from the Windows SwiftPM target,
/// so the compatibility snapshot owns the same implementation independently.
enum EvolutionSpeedSettings {
    static let key = "companionEvolutionSpeedMultiplier"
    static let allowedMultipliers = Array(1...20)

    static func normalizedMultiplier(_ value: Int) -> Int {
        min(allowedMultipliers.last ?? 20, max(allowedMultipliers.first ?? 1, value))
    }

    static var multiplier: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: key)
            return normalizedMultiplier(stored == 0 ? 1 : stored)
        }
        set {
            UserDefaults.standard.set(normalizedMultiplier(newValue), forKey: key)
        }
    }

    static func adjustedThreshold(_ base: Int, multiplier: Int) -> Int {
        let safeMultiplier = normalizedMultiplier(multiplier)
        return max(1, (max(1, base) + safeMultiplier - 1) / safeMultiplier)
    }

    static func phaseThreshold(rarity: Rarity, totalForms: Int, stageIndex: Int) -> Int {
        adjustedThreshold(
            PokemonBalance.phaseThreshold(rarity: rarity, totalForms: totalForms, stageIndex: stageIndex),
            multiplier: multiplier
        )
    }
}
''', encoding="utf-8")

test_path = Path("Tests/PokeTokenBarWindowsTests/EvolutionSpeedSettingsTests.swift")
if test_path.exists():
    raise SystemExit(f"{test_path} already exists")
test_path.write_text('''#if os(Windows)
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
''', encoding="utf-8")

print("WindowsCore evolution-speed implementation added")
