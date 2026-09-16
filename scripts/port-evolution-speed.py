from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly 1 match, found {count}")
    return text.replace(old, new, 1)


# 1) Share the same growth-threshold behavior as main. Egg incubation remains unchanged.
store_path = Path("Sources/PokeTokenBar/Core/CompanionStore.swift")
store = store_path.read_text(encoding="utf-8")
needle = "PokemonBalance.phaseThreshold"
count = store.count(needle)
if count != 5:
    raise SystemExit(f"CompanionStore threshold sweep: expected 5 call sites, found {count}")
store = store.replace(needle, "EvolutionSpeedSettings.phaseThreshold")
store_path.write_text(store, encoding="utf-8")

settings_path = Path("Sources/PokeTokenBar/Core/EvolutionSpeedSettings.swift")
if settings_path.exists():
    raise SystemExit(f"{settings_path} already exists")
settings_path.write_text('''import Foundation

/// Pokemon growth-speed preference. This is app configuration rather than save-game state,
/// so changing it never rewrites the Dex, inventory, or token ledger.
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

    /// n× growth means the same real token usage reaches a phase at 1/n of its base threshold.
    /// Ceiling division avoids a zero-token phase while leaving token stats/shop currency untouched.
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

# 2) Add the native Win32 setting. Windows uses WindowsTray.swift rather than SwiftUI SettingsView.
tray_path = Path("Sources/PokeTokenBar/WindowsTray.swift")
tray = tray_path.read_text(encoding="utf-8")
tray = replace_once(
    tray,
    'let genH = 8 + rowH * 7 + (openDropdown == 1 ? optH * 3 : 0) + (openDropdown == 2 ? optH * 5 : 0) + (openDropdown == 3 ? optH * Int32(wslOptions.count) : 0) + (openDropdown == 4 ? optH * 3 : 0)',
    'let genH = 8 + rowH * 8 + (openDropdown == 1 ? optH * 3 : 0) + (openDropdown == 2 ? optH * 5 : 0) + (openDropdown == 3 ? optH * Int32(wslOptions.count) : 0) + (openDropdown == 4 ? optH * 3 : 0)',
    "Windows General row count",
)

row_marker = '''        if openDropdown == 4 {
            for (i, value) in ["powerSaver", "balanced", "smooth"].enumerated() {
                drawOptionRow(hdc, ry, animationQualityLabel(value), selected: animation == value, action: 200 + i); ry += optH
            }
        }
        drawSwitchRow(hdc, ry, L("남은 한도로 표시", "Show remaining limits", "残り上限を表示"),
'''
row_replacement = '''        if openDropdown == 4 {
            for (i, value) in ["powerSaver", "balanced", "smooth"].enumerated() {
                drawOptionRow(hdc, ry, animationQualityLabel(value), selected: animation == value, action: 200 + i); ry += optH
            }
        }
        drawStepRow(hdc, ry, L("진화 속도", "Evolution speed", "進化速度"),
                    value: "\\(EvolutionSpeedSettings.multiplier)×", minusAction: 68, plusAction: 69); ry += rowH
        drawSwitchRow(hdc, ry, L("남은 한도로 표시", "Show remaining limits", "残り上限を表示"),
'''
tray = replace_once(tray, row_marker, row_replacement, "Windows evolution speed row")

action_marker = '''            case 67:
                popupView = 3; dexMode = 0; dexFilter = 0; dexPage = 0; dexScroll = 0
                if let popupHwnd { InvalidateRect(popupHwnd, nil, true) }
            case 70...74: selectInterval(action - 70)   // interval preset
'''
action_replacement = '''            case 67:
                popupView = 3; dexMode = 0; dexFilter = 0; dexPage = 0; dexScroll = 0
                if let popupHwnd { InvalidateRect(popupHwnd, nil, true) }
            case 68: adjustEvolutionSpeed(-1)
            case 69: adjustEvolutionSpeed(1)
            case 70...74: selectInterval(action - 70)   // interval preset
'''
tray = replace_once(tray, action_marker, action_replacement, "Windows evolution speed actions")

func_marker = '''    private static func toggleFloatingPet() {
'''
func_replacement = '''    private static func adjustEvolutionSpeed(_ delta: Int) {
        let current = EvolutionSpeedSettings.multiplier
        let next = EvolutionSpeedSettings.normalizedMultiplier(current + delta)
        guard next != current else { return }
        EvolutionSpeedSettings.multiplier = next

        // Lowering the threshold can make already-earned progress eligible immediately. Re-run the
        // zero-delta evolution loop instead of waiting for another token event; token ledgers stay intact.
        guard let companion else {
            if let popupHwnd { InvalidateRect(popupHwnd, nil, true) }
            return
        }
        Task {
            await companion.applyUsage(0)
            let disp = await companion.windowsDisplay
            lock.withLock { currentDisplay = disp }
            if let popupHwnd { InvalidateRect(popupHwnd, nil, true) }
            scheduleRefresh()
        }
    }

    private static func toggleFloatingPet() {
'''
tray = replace_once(tray, func_marker, func_replacement, "Windows evolution speed handler")
tray_path.write_text(tray, encoding="utf-8")

# 3) Regression coverage for clamping and threshold math.
test_path = Path("Tests/PokeTokenBarTests/EvolutionSpeedSettingsTests.swift")
if test_path.exists():
    raise SystemExit(f"{test_path} already exists")
test_path.write_text('''import XCTest
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
''', encoding="utf-8")

print("Windows evolution-speed port applied successfully")
