import Foundation

/// 포켓몬 성장 속도 설정. 세이브 게임이 아니라 앱 환경 설정으로 보관해
/// 도감/인벤토리/토큰 원장과 독립적으로 바꿀 수 있게 한다.
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

    /// n배 성장 = 동일한 실제 토큰 사용량으로 임계치의 1/n만 채우면 다음 단계에 도달.
    /// 올림 나눗셈으로 1토큰 미만 임계치가 생기지 않게 하고, 토큰 통계/상점 재화는 건드리지 않는다.
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
