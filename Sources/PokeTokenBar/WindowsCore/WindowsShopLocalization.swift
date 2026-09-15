import Foundation

/// Windows 전용 상점 보강 문자열.
/// WindowsCore.Localization은 아직 3개 언어(ko/en/ja)만 지원하므로 P0 상점 parity도 같은 범위에서 제공한다.
extension L {
    func windowsEggName(_ tier: Rarity?) -> String {
        switch (lang, tier) {
        case (.ko, nil), (.ko, .common?): return "포켓몬 알"
        case (.ko, .uncommon?): return "고급 알"
        case (.ko, .rare?): return "희귀 알"
        case (.ko, .legendary?): return "전설 알"
        case (.ja, nil), (.ja, .common?): return "ポケモンのタマゴ"
        case (.ja, .uncommon?): return "アンコモンのタマゴ"
        case (.ja, .rare?): return "レアのタマゴ"
        case (.ja, .legendary?): return "でんせつのタマゴ"
        case (.en, nil), (.en, .common?): return "Pokémon Egg"
        case (.en, .uncommon?): return "Uncommon Egg"
        case (.en, .rare?): return "Rare Egg"
        case (.en, .legendary?): return "Legendary Egg"
        }
    }

    func windowsEggDescription(_ tier: Rarity?) -> String {
        guard let tier, tier != .common else {
            switch lang {
            case .ko: return "지금 포켓몬을 놓아주고 새 알로 다시 시작해요."
            case .en: return "Send off your current Pokémon and start fresh with a new egg."
            case .ja: return "いまのポケモンを手放して新しいタマゴからやり直します。"
            }
        }
        let rarity = rarityLabel(tier)
        switch lang {
        case .ko: return "지금 포켓몬을 놓아주고 \(rarity) 이상이 확정으로 나오는 알을 받아요."
        case .en: return "Send off your current Pokémon for an egg guaranteed to hatch \(rarity) or better."
        case .ja: return "いまのポケモンを手放して \(rarity) 以上が確定で孵るタマゴをもらいます。"
        }
    }

    func windowsNeedMoreTokens(_ amount: String) -> String {
        switch lang {
        case .ko: return "\(amount) 더 필요"
        case .en: return "Need \(amount)"
        case .ja: return "あと\(amount)"
        }
    }

    var windowsEggLockedShort: String {
        switch lang {
        case .ko: return "부화 후 구매"
        case .en: return "After hatch"
        case .ja: return "孵化後"
        }
    }
}
