import Foundation

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
