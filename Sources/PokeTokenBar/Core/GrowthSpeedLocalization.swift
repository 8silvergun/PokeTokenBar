extension L {
    var evolutionSpeedLabel: String {
        switch lang {
        case .ko: return "진화 속도"
        case .en: return "Evolution speed"
        case .ja: return "進化速度"
        case .es: return "Velocidad de evolución"
        case .fr: return "Vitesse d’évolution"
        case .pt: return "Velocidade de evolução"
        case .de: return "Entwicklungsgeschwindigkeit"
        }
    }

    var evolutionSpeedHint: String {
        switch lang {
        case .ko: return "포켓몬 성장 임계치만 낮춥니다. 알 부화 속도와 토큰 통계는 그대로입니다."
        case .en: return "Lowers Pokémon growth thresholds only. Egg hatching and token stats stay unchanged."
        case .ja: return "ポケモンの成長しきい値だけを下げます。タマゴの孵化速度とトークン統計は変わりません。"
        case .es: return "Solo reduce los umbrales de crecimiento. La eclosión y las estadísticas de tokens no cambian."
        case .fr: return "Réduit seulement les seuils de croissance. L’éclosion et les statistiques de jetons ne changent pas."
        case .pt: return "Reduz apenas os limites de crescimento. A eclosão e as estatísticas de tokens não mudam."
        case .de: return "Senkt nur die Wachstumsschwellen. Schlüpfen und Token-Statistiken bleiben unverändert."
        }
    }

    func evolutionSpeedMultiplier(_ value: Int) -> String { "\(value)×" }
}
