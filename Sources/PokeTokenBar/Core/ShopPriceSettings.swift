import Foundation

/// User-configurable shop price ratio. This is app configuration, not save-game state:
/// changing it affects future purchases only and never rewrites historical spentTokens.
enum ShopPriceSettings {
    static let key = "companionShopPricePercent"
    static let allowedPercents = Array(stride(from: 10, through: 200, by: 10))

    static func normalizedPercent(_ value: Int) -> Int {
        min(allowedPercents.last ?? 200, max(allowedPercents.first ?? 10, value))
    }

    static var percent: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: key)
            return normalizedPercent(stored == 0 ? 100 : stored)
        }
        set {
            UserDefaults.standard.set(normalizedPercent(newValue), forKey: key)
        }
    }

    /// Apply the selected percentage to a base price.
    /// All current balance prices are large integers, but the generic helper still rounds to nearest
    /// token and never returns zero for a positive base price.
    static func adjustedPrice(_ base: Int, percent: Int) -> Int {
        guard base > 0 else { return 0 }
        let safe = normalizedPercent(percent)
        return max(1, Int((Double(base) * Double(safe) / 100.0).rounded()))
    }

    static func adjustedPrice(_ base: Int) -> Int {
        adjustedPrice(base, percent: percent)
    }
}
