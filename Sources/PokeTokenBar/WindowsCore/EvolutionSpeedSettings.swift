import Foundation

/// Windows companion growth-speed preference. Core/ is excluded from the Windows SwiftPM target,
/// so the compatibility snapshot owns the same implementation independently. Keep the persistence
/// key, supported range, and threshold math aligned with Core/EvolutionSpeedSettings.swift.
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
