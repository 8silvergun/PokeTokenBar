from pathlib import Path


def rep(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected 1 occurrence, found {count}")
    return text.replace(old, new, 1)

# Windows excludes Sources/PokeTokenBar/Core at build time, so the collection semantics must be
# forward-ported into WindowsCore as well as exposed by WindowsTray.
model_path = Path("Sources/PokeTokenBar/WindowsCore/CompanionModel.swift")
model = model_path.read_text(encoding="utf-8")
old_dex_entry = '''/// 도감 항목 — 라인 전체(초기→최종) 순서 보존.
struct DexEntry: Codable, Sendable, Identifiable {
    var id = UUID().uuidString
    var baseID: Int
    var finalID: Int
    var chainOrder: [Int]   // 초기→최종 종 id
    var rarity: Rarity
    var caughtAt: Date?
    var isShiny = false
    var nature: PokemonNature?
    /// 진화 체인 각 종의 다국어 이름(speciesID → langCode → name). 졸업 시 로드된 라인에서 저장 →
    /// 도감의 단계별 스프라이트 밑 이름 표시가 네트워크 없이 즉시 + 언어 전환 대응. 구버전 저장분엔
    /// 없어(nil) 뷰가 line fetch 로 조회 후 백필한다.
    var names: [Int: [String: String]]?

    init(baseID: Int, finalID: Int, chainOrder: [Int], rarity: Rarity,
         caughtAt: Date?, isShiny: Bool = false, nature: PokemonNature? = nil,
         names: [Int: [String: String]]? = nil) {
        self.baseID = baseID
        self.finalID = finalID
        self.chainOrder = chainOrder
        self.rarity = rarity
        self.caughtAt = caughtAt
        self.isShiny = isShiny
        self.nature = nature
        self.names = names
    }

    // 하위호환 디코딩 (MonState 와 동일 이유).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        baseID = try c.decode(Int.self, forKey: .baseID)
        finalID = try c.decode(Int.self, forKey: .finalID)
        chainOrder = try c.decode([Int].self, forKey: .chainOrder)
        rarity = try c.decode(Rarity.self, forKey: .rarity)
        caughtAt = try c.decodeIfPresent(Date.self, forKey: .caughtAt)
        isShiny = try c.decodeIfPresent(Bool.self, forKey: .isShiny) ?? false
        nature = try c.decodeIfPresent(PokemonNature.self, forKey: .nature)
        // try? — 구버전(최종체 단일 [String:String]) 형식이 남아 있어도 종별 맵 디코딩 실패 시 nil 로
        // 강등(항목 전체 로드는 유지). 뷰가 line 조회로 백필한다.
        names = (try? c.decodeIfPresent([Int: [String: String]].self, forKey: .names)) ?? nil
    }
}
'''
new_dex_entry = '''/// 도감/포획 로그 항목 — 라인 전체(초기→현재/최종) 순서 보존.
struct DexEntry: Codable, Sendable, Identifiable {
    var id = UUID().uuidString
    var baseID: Int
    var finalID: Int
    var chainOrder: [Int]
    var rarity: Rarity
    var caughtAt: Date?
    var isShiny = false
    var nature: PokemonNature?
    var names: [Int: [String: String]]?
    /// 새 알 구매로 육성을 중단한 시각. nil이면 졸업 기록(또는 구버전 기록).
    var releasedAt: Date?
    var isReleased: Bool { releasedAt != nil }

    init(id: String = UUID().uuidString,
         baseID: Int, finalID: Int, chainOrder: [Int], rarity: Rarity,
         caughtAt: Date?, isShiny: Bool = false, nature: PokemonNature? = nil,
         names: [Int: [String: String]]? = nil, releasedAt: Date? = nil) {
        self.id = id
        self.baseID = baseID
        self.finalID = finalID
        self.chainOrder = chainOrder
        self.rarity = rarity
        self.caughtAt = caughtAt
        self.isShiny = isShiny
        self.nature = nature
        self.names = names
        self.releasedAt = releasedAt
    }

    // releasedAt 이전 세이브는 nil(=졸업)로 읽어 그대로 호환한다.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        baseID = try c.decode(Int.self, forKey: .baseID)
        finalID = try c.decode(Int.self, forKey: .finalID)
        chainOrder = try c.decode([Int].self, forKey: .chainOrder)
        rarity = try c.decode(Rarity.self, forKey: .rarity)
        caughtAt = try c.decodeIfPresent(Date.self, forKey: .caughtAt)
        isShiny = try c.decodeIfPresent(Bool.self, forKey: .isShiny) ?? false
        nature = try c.decodeIfPresent(PokemonNature.self, forKey: .nature)
        names = (try? c.decodeIfPresent([Int: [String: String]].self, forKey: .names)) ?? nil
        releasedAt = try c.decodeIfPresent(Date.self, forKey: .releasedAt)
    }
}
'''
model = rep(model, old_dex_entry, new_dex_entry, "DexEntry")
model_path.write_text(model, encoding="utf-8")

store_path = Path("Sources/PokeTokenBar/WindowsCore/CompanionStore.swift")
store = store_path.read_text(encoding="utf-8")
old_collection = '''    var dexEntries: [DexEntry] { state.dex }

    var dexEntriesSorted: [DexEntry] {
        state.dex.sorted { a, b in
            if a.rarity.sortRank != b.rarity.sortRank { return a.rarity.sortRank > b.rarity.sortRank }
            let ta = a.caughtAt ?? .distantPast
            let tb = b.caughtAt ?? .distantPast
            return ta > tb
        }
    }

    func dexCount(_ rarity: Rarity) -> Int { state.dex.lazy.filter { $0.rarity == rarity }.count }

    func dexStoredChainNames(_ entry: DexEntry) -> [Int: String]? {
        guard let names = entry.names, !names.isEmpty else { return nil }
        return names.compactMapValues { state.language.resolveName($0) }
    }

    func dexResolveChainNames(_ entry: DexEntry) async -> [Int: String] {
        if let stored = dexStoredChainNames(entry) { return stored }
        guard let line = try? await provider.line(baseSpeciesID: entry.baseID) else {
            return Dictionary(uniqueKeysWithValues: entry.chainOrder.map { ($0, "#\\($0)") })
        }
        let chainNames = Dictionary(uniqueKeysWithValues:
            entry.chainOrder.compactMap { id in line.names[id].map { (id, $0) } })
        if !chainNames.isEmpty, let idx = state.dex.firstIndex(where: { $0.id == entry.id }) {
            state.dex[idx].names = chainNames
            save()
        }
        return Dictionary(uniqueKeysWithValues: entry.chainOrder.map { id in
            (id, chainNames[id].flatMap { state.language.resolveName($0) } ?? "#\\(id)")
        })
    }
'''
new_collection = '''    /// 현재 육성 개체를 영속 dex에 중복 저장하지 않고 Catch Log 화면용 항목으로 합성한다.
    private var activeDexEntry: DexEntry? {
        guard let active = state.active else { return nil }
        let reached = Array(active.pathIDs.prefix(max(1, active.stageIndex + 1)))
        let chain = reached.isEmpty ? [active.baseID] : reached
        return DexEntry(
            id: "active-\\(active.baseID)-\\(active.currentID)",
            baseID: active.baseID,
            finalID: active.currentID,
            chainOrder: chain,
            rarity: active.rarity,
            caughtAt: nil,
            isShiny: currentIsShiny,
            nature: active.nature,
            names: currentLine.map { line in
                Dictionary(uniqueKeysWithValues:
                    chain.compactMap { id in line.names[id].map { (id, $0) } })
            })
    }

    /// fresh/premium egg 구매로 놓아준 개체의 영구 기록. 실제 도달한 형태만 남긴다.
    private func releasedDexEntry(from active: MonState) -> DexEntry {
        let reached = Array(active.pathIDs.prefix(max(1, active.stageIndex + 1)))
        let chain = reached.isEmpty ? [active.baseID] : reached
        let now = clock()
        return DexEntry(
            baseID: active.baseID,
            finalID: chain.last ?? active.baseID,
            chainOrder: chain,
            rarity: active.rarity,
            caughtAt: now,
            isShiny: currentIsShiny,
            nature: active.nature,
            names: currentLine.map { line in
                Dictionary(uniqueKeysWithValues:
                    chain.compactMap { id in line.names[id].map { (id, $0) } })
            },
            releasedAt: now)
    }

    var dexEntries: [DexEntry] {
        guard let activeDexEntry else { return state.dex }
        return state.dex + [activeDexEntry]
    }

    func isActiveDexEntry(_ entry: DexEntry) -> Bool {
        entry.id == activeDexEntry?.id
    }

    /// Catch Log는 현재 개체를 맨 앞에, 나머지는 기록 시각 최신순으로 보여준다.
    var dexEntriesSorted: [DexEntry] {
        let stored = state.dex.sorted {
            ($0.caughtAt ?? .distantPast) > ($1.caughtAt ?? .distantPast)
        }
        guard let activeDexEntry else { return stored }
        return [activeDexEntry] + stored
    }

    func dexCount(_ rarity: Rarity) -> Int { dexEntries.lazy.filter { $0.rarity == rarity }.count }

    /// species-based Pokédex 한 칸. 같은 종의 여러 개체/기록은 한 칸으로 접힌다.
    struct DexSpecies: Identifiable, Sendable {
        let id: Int
        let name: String
        let rarity: Rarity
        let isShiny: Bool
        let isRaising: Bool
    }

    private struct DexAccumulator {
        let rarity: Rarity
        var names: [String: String]?
        var isShiny = false
    }

    /// 영구 기록의 chainOrder + 현재 개체가 실제 도달한 path prefix를 합쳐 종 번호순으로 만든다.
    var dexSpecies: [DexSpecies] {
        var acc: [Int: DexAccumulator] = [:]
        for entry in state.dex {
            for id in entry.chainOrder {
                var item = acc[id] ?? DexAccumulator(rarity: entry.rarity)
                if let names = entry.names?[id] { item.names = names }
                if entry.isShiny { item.isShiny = true }
                acc[id] = item
            }
        }
        if let active = state.active {
            for id in active.pathIDs.prefix(max(1, active.stageIndex + 1)) {
                var item = acc[id] ?? DexAccumulator(rarity: active.rarity)
                if let names = currentLine?.names[id] { item.names = names }
                if currentIsShiny { item.isShiny = true }
                acc[id] = item
            }
        }
        return acc.sorted { $0.key < $1.key }.map { id, item in
            DexSpecies(
                id: id,
                name: item.names.flatMap { state.language.resolveName($0) } ?? "#\\(id)",
                rarity: item.rarity,
                isShiny: item.isShiny,
                isRaising: id == state.active?.currentID)
        }
    }

    func dexStoredChainNames(_ entry: DexEntry) -> [Int: String]? {
        guard let names = entry.names, !names.isEmpty else { return nil }
        return names.compactMapValues { state.language.resolveName($0) }
    }

    func dexResolveChainNames(_ entry: DexEntry) async -> [Int: String] {
        if let stored = dexStoredChainNames(entry) { return stored }
        guard let line = try? await provider.line(baseSpeciesID: entry.baseID) else {
            return Dictionary(uniqueKeysWithValues: entry.chainOrder.map { ($0, "#\\($0)") })
        }
        let chainNames = Dictionary(uniqueKeysWithValues:
            entry.chainOrder.compactMap { id in line.names[id].map { (id, $0) } })
        if !chainNames.isEmpty, let idx = state.dex.firstIndex(where: { $0.id == entry.id }) {
            state.dex[idx].names = chainNames
            save()
        }
        return Dictionary(uniqueKeysWithValues: entry.chainOrder.map { id in
            (id, chainNames[id].flatMap { state.language.resolveName($0) } ?? "#\\(id)")
        })
    }
'''
store = rep(store, old_collection, new_collection, "collection block")
old_buy = '''        state.spentTokens += FreshEgg.price(guaranteeing: tier)
        state.active = nil
        currentLine = nil
'''
new_buy = '''        state.spentTokens += FreshEgg.price(guaranteeing: tier)
        if let active = state.active {
            // 놓아준 개체도 수집 기록에 남긴다. 졸업은 아니므로 collectedFinals에는 손대지 않는다.
            state.dex.append(releasedDexEntry(from: active))
        }
        state.active = nil
        currentLine = nil
'''
store = rep(store, old_buy, new_buy, "buyEgg release preservation")
store_path.write_text(store, encoding="utf-8")

tray_path = Path("Sources/PokeTokenBar/WindowsTray.swift")
tray = tray_path.read_text(encoding="utf-8")
old_line_nodes = '''            lineNodes: hasActive ? lineNodes.compactMap { item in
                guard case .species(let id) = item.content else { return nil }
                let kind: String
                switch item.state { case .done: kind = "done"; case .current: kind = "cur"; case .future: kind = "future" }
                return EvoThumb(id: id, kind: kind)
            } : [],
'''
new_line_nodes = '''            lineNodes: hasActive ? lineNodes.map { EvoThumb(id: $0.id, kind: $0.kind) } : [],
'''
tray = rep(tray, old_line_nodes, new_line_nodes, "WindowsCore lineNodes mapping")
tray_path.write_text(tray, encoding="utf-8")

print("forward-ported collection parity into WindowsCore")
