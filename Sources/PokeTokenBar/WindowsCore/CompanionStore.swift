import Foundation
#if os(macOS)
import Observation
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

#if !os(macOS)
/// Windows/Linux 전용 직렬 실행기 — macOS 의 `@MainActor` 역할을 대신한다. CompanionStore 의 모든
/// 메서드/프로퍼티와 내부 fire-and-forget `Task` 가 이 단일 액터에서 직렬 실행돼 상태 레이스를 없앤다
/// (Win32 메시지 루프는 메인 스레드에 두고, companion 은 이 액터에서 구동).
@globalActor
actor CompanionActor { static let shared = CompanionActor() }
#endif

/// 게임 상태의 출처. 설치 이후 토큰 사용량으로 포켓몬을 진화시키고, 최종체 + 추가 임계 도달 시
/// 도감(라인 전체)에 보존 + 새 알. 진화 트리/희귀도/이름은 PokeProviding 으로 런타임 주입.
///
/// macOS: `@MainActor @Observable`(SwiftUI 반응형). Windows: `@CompanionActor`(커스텀 직렬 액터) —
/// 트레이가 백그라운드 `Task` 에서 `await` 로 구동하며, 액터가 모든 접근을 직렬화한다.
#if os(macOS)
@MainActor
@Observable
#else
@CompanionActor
#endif
final class CompanionStore {
    /// 이벤트(부화/진화/졸업/사탕) 알림 훅 — macOS 는 UserNotifications, Windows 는 트레이 토스트로 라우팅.
    /// (플랫폼 UI 계층이 주입; 미설정이면 무음.)
    nonisolated(unsafe) var onEvent: ((_ title: String, _ body: String) -> Void)?
    private(set) var state = CompanionState()
    private(set) var displayState: CompanionStateKind = .egg
    private(set) var currentLine: EvoLine?
    private(set) var isHatching = false
    private var isRevealingDitto = false
    private(set) var justEvolvedTo: String?
    private(set) var justGraduated: String?
    private var eventUntil: Date?

    enum Celebration: Equatable { case hatch(shiny: Bool), evolve, dittoReveal(shiny: Bool) }
    private(set) var celebration: Celebration?
    private(set) var celebrationSeq = 0
    private func fireCelebration(_ c: Celebration) { celebration = c; celebrationSeq += 1 }
    func consumeCelebration() { celebration = nil }

    private(set) var candyFeedbackSeq = 0
    private(set) var candyFeedbackAmount = 0
    func consumeCandyFeedback() { candyFeedbackAmount = 0 }

    private(set) var mintFeedbackSeq = 0
    private(set) var mintFeedbackNature: PokemonNature?
    func consumeMintFeedback() { mintFeedbackNature = nil }

    private let provider: any PokeProviding
    private let clock: () -> Date
    private let fileURL: URL
    private var rng: any RandomNumberGenerator

    init(provider: any PokeProviding = PokeAPIClient.shared,
         clock: @escaping () -> Date = Date.init,
         fileURL: URL? = nil,
         rng: any RandomNumberGenerator = SystemRandomNumberGenerator()) {
        self.provider = provider
        self.clock = clock
        self.fileURL = fileURL ?? Self.defaultURL()
        self.rng = rng
        load()
        if state.active != nil { displayState = .idle }
    }

    static func defaultURL() -> URL {
        let override = (ProcessInfo.processInfo.environment["PTB_STATE_DIR"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let dir: URL
        if !override.isEmpty {
            dir = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PokeTokenBar")
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("companion-state.json")
    }

    // MARK: 파생값 (UI)

    var language: AppLanguage { state.language }
    func setLanguage(_ lang: AppLanguage) { state.language = lang; save() }
    var l: L { L(language) }

    var hasActive: Bool { state.active != nil }
    var rarity: Rarity? { state.active?.rarity }
    var currentIsShiny: Bool {
        guard let a = state.active else { return false }
        if a.dittoDisguise != nil && !a.dittoRevealed { return false }
        return a.isShiny
    }
    var currentNature: PokemonNature? { state.active?.nature }

    var representativeSpeciesID: Int? { state.representativeSpeciesID }
    var representativeVisualSpeciesID: Int? { state.representativeSpeciesID ?? currentSpeciesID }
    var representativeVisualIsShiny: Bool {
        guard let selected = state.representativeSpeciesID else { return currentIsShiny }
        return state.ownsShinySpecies(selected)
    }

    /// nil은 현재 개체 자동 추적. 도감에 없는 종은 기존 선택을 유지한 채 거부한다.
    @discardableResult
    func setRepresentativeSpeciesID(_ id: Int?) -> Bool {
        if let id, !state.ownsSpecies(id) { return false }
        state.representativeSpeciesID = id
        save()
        return true
    }

    var isEgg: Bool { state.active == nil }
    var eggStarted: Bool { state.eggUsage > 0 }
    var eggProgress: Double { min(1, max(0, Double(state.eggUsage) / Double(PokemonBalance.eggHatchThreshold))) }
    var eggTokensToHatch: Int { max(0, PokemonBalance.eggHatchThreshold - state.eggUsage) }
    var eggGuarantee: Rarity? { state.active == nil ? state.eggTier : nil }

    var displayName: String {
        guard let a = state.active, let line = currentLine else { return "Token Egg" }
        return line.localizedName(a.currentID, state.language)
    }
    var currentSpeciesID: Int? { state.active?.currentID }
    var isFinalStage: Bool {
        guard let a = state.active, let line = currentLine else { return false }
        return line.tree.node(withID: a.currentID)?.children.isEmpty ?? true
    }
    var stageText: String {
        guard let a = state.active else { return "" }
        return isFinalStage ? l.finalForm : l.stage(a.stageIndex + 1, a.totalForms)
    }
    var threshold: Int {
        guard let a = state.active else { return 1 }
        return PokemonBalance.phaseThreshold(rarity: a.rarity, totalForms: a.totalForms, stageIndex: a.stageIndex)
    }
    var progress: Double {
        guard let a = state.active, threshold > 0 else { return 0 }
        return min(1, max(0, Double(a.usedAtStage) / Double(threshold)))
    }
    var tokensToNext: Int { guard let a = state.active else { return 0 }; return max(0, threshold - a.usedAtStage) }

    var lineNodes: [(id: Int, kind: String)] {
        guard let a = state.active, let line = currentLine else { return [] }
        var out: [(Int, String)] = []
        for (i, id) in a.pathIDs.enumerated() {
            out.append((id, i < a.stageIndex ? "done" : (i == a.stageIndex ? "cur" : "future")))
        }
        if let cur = line.tree.node(withID: a.currentID) {
            for ch in cur.children { out.append((ch.speciesID, "future")) }
        }
        return out
    }
    /// 현재 육성 개체를 영속 dex에 중복 저장하지 않고 Catch Log 화면용 항목으로 합성한다.
    private var activeDexEntry: DexEntry? {
        guard let active = state.active else { return nil }
        let reached = Array(active.pathIDs.prefix(max(1, active.stageIndex + 1)))
        let chain = reached.isEmpty ? [active.baseID] : reached
        return DexEntry(
            id: "active-\(active.baseID)-\(active.currentID)",
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
                name: item.names.flatMap { state.language.resolveName($0) } ?? "#\(id)",
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
            return Dictionary(uniqueKeysWithValues: entry.chainOrder.map { ($0, "#\($0)") })
        }
        let chainNames = Dictionary(uniqueKeysWithValues:
            entry.chainOrder.compactMap { id in line.names[id].map { (id, $0) } })
        if !chainNames.isEmpty, let idx = state.dex.firstIndex(where: { $0.id == entry.id }) {
            state.dex[idx].names = chainNames
            save()
        }
        return Dictionary(uniqueKeysWithValues: entry.chainOrder.map { id in
            (id, chainNames[id].flatMap { state.language.resolveName($0) } ?? "#\(id)")
        })
    }

    // MARK: 갱신

    func update(todayTokens: Int, todayDate: String, monthTotal: Int,
                burnTier: BurnTier, limitWarning: Bool, hasUsageData: Bool) {
        if !state.installBaselineSet {
            guard hasUsageData else { displayState = .egg; return }
            state.installBaselineSet = true
            state.claimedTodayTokens = todayTokens
            state.lastDate = todayDate
            save()
        } else {
            if todayDate != state.lastDate { state.lastDate = todayDate; state.claimedTodayTokens = 0 }
            if todayTokens < state.claimedTodayTokens, hasUsageData {
                let previous = state.claimedTodayTokens
                state.claimedTodayTokens = todayTokens
                AppLog.write("companion usage regression date=\(todayDate) previous=\(previous) current=\(todayTokens) drop=\(previous - todayTokens) — rebased daily ledger")
            }
            if todayTokens > state.claimedTodayTokens {
                let delta = todayTokens - state.claimedTodayTokens
                state.claimedTodayTokens = todayTokens
                state.usedSinceInstall += delta
                if state.active == nil {
                    state.eggUsage += delta
                } else {
                    applyUsage(delta)
                }
            }
        }
        if let until = eventUntil, clock() > until {
            justGraduated = nil; justEvolvedTo = nil; eventUntil = nil
        }
        if state.active == nil, state.installBaselineSet, !isHatching {
            Task { await ensureEggPrefetch() }
        }
        if state.active == nil, state.eggUsage >= PokemonBalance.eggHatchThreshold, !isHatching {
            Task { await hatchIfNeeded() }
        }
        if state.active != nil, currentLine == nil, !isHatching {
            Task { await loadCurrentLine() }
        }
        if let a = state.active, a.dittoDisguise != nil, !a.dittoRevealed, currentLine != nil,
           !isHatching, !isRevealingDitto,
           a.usedAtStage >= PokemonBalance.phaseThreshold(rarity: a.rarity, totalForms: a.totalForms, stageIndex: 0) {
            Task { await revealDitto() }
        }
        displayState = computeState(burnTier: burnTier, limitWarning: limitWarning,
                                    hasUsageData: hasUsageData, today: todayTokens)
        save()
    }

    func applyUsage(_ delta: Int) {
        guard state.active != nil else { return }
        state.active!.usedAtStage += delta
        guard let line = currentLine else { save(); return }
        var guardCount = 0
        while state.active != nil, guardCount < 50 {
            guardCount += 1
            let a = state.active!
            let thr = PokemonBalance.phaseThreshold(rarity: a.rarity, totalForms: a.totalForms, stageIndex: a.stageIndex)
            guard a.usedAtStage >= thr else { break }
            guard let node = line.tree.node(withID: a.currentID) else { break }
            if node.children.isEmpty {
                graduate(); break
            } else {
                if a.dittoDisguise != nil, !a.dittoRevealed {
                    if !isRevealingDitto { Task { await revealDitto() } }
                    break
                }
                let next = pickNextChild(node, baseID: a.baseID)
                state.active!.pathIDs = Array(a.pathIDs.prefix(a.stageIndex + 1)) + [next.speciesID]
                state.active!.stageIndex += 1
                state.active!.usedAtStage = a.usedAtStage - thr
                let newName = line.localizedName(next.speciesID, state.language)
                justEvolvedTo = newName
                fireCelebration(.evolve)
                eventUntil = clock().addingTimeInterval(4)
                notifyCompanionEvent(l.notifEvolveTitle, l.notifEvolveBody(newName))
            }
        }
        save()
    }

    private func pickNextChild(_ node: EvoNode, baseID: Int) -> EvoNode {
        let fresh = node.children.filter { ch in
            ch.finalIDs.contains { !state.collectedFinals.contains("\(baseID):\($0)") }
        }
        let pool = fresh.isEmpty ? node.children : fresh
        return pool[Int(rng.next() % UInt64(pool.count))]
    }

    private func graduate() {
        guard let a = state.active else { return }
        let finalID = a.currentID
        state.collectedFinals.insert("\(a.baseID):\(finalID)")
        state.dex.append(DexEntry(baseID: a.baseID, finalID: finalID,
                                  chainOrder: a.pathIDs, rarity: a.rarity, caughtAt: clock(),
                                  isShiny: a.isShiny, nature: a.nature,
                                  names: currentLine.map { line in
                                      Dictionary(uniqueKeysWithValues:
                                          a.pathIDs.compactMap { id in line.names[id].map { (id, $0) } })
                                  }))
        let name = currentLine?.localizedName(finalID, state.language) ?? ""
        justGraduated = name
        notifyCompanionEvent(l.notifGraduateTitle, l.notifGraduateBody(name))
        eventUntil = clock().addingTimeInterval(6)
        state.active = nil
        currentLine = nil
        state.eggUsage = 0
        state.eggTier = nil
        state.pendingHatchID = nil
        prefetchedLineID = nil
        Task { await self.ensureEggPrefetch() }
    }

    // MARK: 인벤토리 / 이상한 사탕

    var rareCandyCount: Int { itemCount(.rareCandy) }
    func itemCount(_ kind: ItemKind) -> Int { state.inventory[kind.rawValue] ?? 0 }
    var ownsShinyCharm: Bool { itemCount(.shinyCharm) > 0 }

    var ownedItems: [(kind: ItemKind, count: Int)] {
        ItemKind.allCases.compactMap { k in
            let c = itemCount(k)
            return c > 0 ? (k, c) : nil
        }
    }

    var canUseRareCandy: Bool { hasActive && currentLine != nil && rareCandyCount > 0 }

    enum CandyUseResult: Equatable { case evolved, graduated, progressed, unavailable }

    @discardableResult
    func useRareCandy() -> CandyUseResult {
        guard canUseRareCandy else { return .unavailable }
        state.inventory[ItemKind.rareCandy.rawValue] = rareCandyCount - 1
        let beforeStage = state.active?.stageIndex ?? 0
        candyFeedbackAmount = RareCandy.xp
        candyFeedbackSeq += 1
        applyUsage(RareCandy.xp)
        if state.active == nil { return .graduated }
        if state.active!.stageIndex > beforeStage { return .evolved }
        return .progressed
    }

    // MARK: 민트

    var canUseMint: Bool { hasActive && itemCount(.mint) > 0 }

    @discardableResult
    func useMint() -> PokemonNature? {
        guard canUseMint, state.active != nil else { return nil }
        let cur = state.active!.nature
        let pool = PokemonNature.allCases.filter { $0 != cur }
        let new = pool[Int(rng.next() % UInt64(pool.count))]
        state.active!.nature = new
        state.inventory[ItemKind.mint.rawValue] = itemCount(.mint) - 1
        mintFeedbackNature = new
        mintFeedbackSeq += 1
        save()
        return new
    }

    // MARK: 상점

    var availableTokens: Int { max(0, state.usedSinceInstall - state.spentTokens) }

    var purchasableItems: [ItemKind] {
        ItemKind.allCases
            .filter { $0.shopPrice != nil }
            .sorted { a, b in
                let aDone = a.isPassive && itemCount(a) > 0
                let bDone = b.isPassive && itemCount(b) > 0
                if aDone != bDone { return !aDone }
                return (a.shopPrice ?? 0) < (b.shopPrice ?? 0)
            }
    }

    /// macOS와 동일하게 아이템 + 일반/고급/희귀 알을 가격 오름차순으로 항상 노출한다.
    /// 알 상태에선 알 카드가 보이되 `canBuyEgg`가 구매를 막아 이유를 UI에서 설명할 수 있게 한다.
    var shopEntries: [ShopEntry] {
        var entries: [ShopEntry] = purchasableItems.map { ShopEntry.item($0) }
        entries += FreshEgg.shopTiers.map { ShopEntry.egg($0) }
        return entries.sorted { a, b in
            let aDone = isPurchasedPassive(a)
            let bDone = isPurchasedPassive(b)
            if aDone != bDone { return !aDone }
            return a.price < b.price
        }
    }

    private func isPurchasedPassive(_ entry: ShopEntry) -> Bool {
        guard case .item(let kind) = entry else { return false }
        return kind.isPassive && itemCount(kind) > 0
    }

    func canBuy(_ kind: ItemKind) -> Bool {
        guard let price = kind.shopPrice else { return false }
        if kind.isPassive && itemCount(kind) > 0 { return false }
        return availableTokens >= price
    }

    @discardableResult
    func buy(_ kind: ItemKind) -> Bool {
        guard let price = kind.shopPrice, availableTokens >= price else { return false }
        if kind.isPassive && itemCount(kind) > 0 { return false }
        state.spentTokens += price
        state.inventory[kind.rawValue, default: 0] += 1
        save()
        return true
    }

    var canBuyRareCandy: Bool { canBuy(.rareCandy) }
    @discardableResult
    func buyRareCandy() -> Bool { buy(.rareCandy) }

    // MARK: 알 리롤

    func canBuyEgg(_ tier: Rarity?) -> Bool {
        guard FreshEgg.shopTiers.contains(tier) else { return false }
        return hasActive && availableTokens >= FreshEgg.price(guaranteeing: tier)
    }

    @discardableResult
    func buyEgg(_ tier: Rarity?) -> Bool {
        guard canBuyEgg(tier) else { return false }
        state.spentTokens += FreshEgg.price(guaranteeing: tier)
        if let active = state.active {
            // 놓아준 개체도 수집 기록에 남긴다. 졸업은 아니므로 collectedFinals에는 손대지 않는다.
            state.dex.append(releasedDexEntry(from: active))
        }
        state.active = nil
        currentLine = nil
        state.eggUsage = 0
        state.eggTier = tier
        state.pendingHatchID = nil
        prefetchedLineID = nil
        justGraduated = nil; justEvolvedTo = nil; eventUntil = nil
        AppLog.write("egg purchased: discarded active, tier=\(tier?.rawValue ?? "none")")
        Task { await self.ensureEggPrefetch() }
        save()
        return true
    }

    var canBuyFreshEgg: Bool { canBuyEgg(nil) }
    @discardableResult
    func buyFreshEgg() -> Bool { buyEgg(nil) }

    /// 구매 불가 이유를 Windows 카드가 즉시 설명할 수 있도록 순수 상태를 제공한다.
    func shopShortfall(for entry: ShopEntry) -> Int {
        max(0, entry.price - availableTokens)
    }

    // MARK: 한도 보상

    static func evaluateCandyGrants(
        windows: [CandyWindow], grantTier: inout [String: Int]
    ) -> [CandyGrant] {
        var grants: [CandyGrant] = []
        for w in windows {
            guard w.utilization >= 100 else { grantTier[w.key] = nil; continue }
            let previous = grantTier[w.key] ?? 0
            guard previous < 1 else { continue }
            grantTier[w.key] = 1
            let count = w.kind == .weekly ? RareCandy.weeklyGrant : 1
            grants.append(CandyGrant(windowKey: w.key, windowName: w.name, count: count))
        }
        return grants
    }

    func grantCandies(from windows: [CandyWindow], limitsReady: Bool) {
        guard limitsReady else { return }
        if !state.candyFeatureSeeded {
            for w in windows where w.utilization >= 100 { state.candyGrantTier[w.key] = 1 }
            state.candyFeatureSeeded = true
            save()
            return
        }
        let before = state.candyGrantTier
        let grants = Self.evaluateCandyGrants(windows: windows, grantTier: &state.candyGrantTier)
        for g in grants {
            state.inventory[ItemKind.rareCandy.rawValue, default: 0] += g.count
            notifyCompanionEvent(l.notifCandyTitle(item: l.itemName(.rareCandy), count: g.count),
                                 l.notifCandyBody(window: g.windowName))
        }
        if !grants.isEmpty || state.candyGrantTier != before { save() }
    }

    private var notifSeq = 0
    private func notifyCompanionEvent(_ title: String, _ body: String) {
        guard AppEnv.isBundledApp else { return }
        guard UserDefaults.standard.object(forKey: "companionNotifications") as? Bool ?? true else { return }
        notifSeq += 1
        #if canImport(UserNotifications)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "companion-event-\(notifSeq)", content: content, trigger: nil))
        #else
        onEvent?(title, body)
        #endif
    }

    // MARK: 부화

    func hatchIfNeeded() async {
        guard state.active == nil, !isHatching, state.eggUsage >= PokemonBalance.eggHatchThreshold else { return }
        guard state.pendingHatchID != nil || !prefetchInFlight else { return }
        isHatching = true
        defer { isHatching = false }
        let base: Int?
        if let pending = state.pendingHatchID {
            base = pending
        } else {
            base = await chooseBase()
        }
        guard let base else { return }
        state.pendingHatchID = nil
        await hatchCore(baseID: base)
    }

    // MARK: 알 프리패칭

    private var prefetchInFlight = false
    private var prefetchedLineID: Int?

    private func ensureEggPrefetch() async {
        guard state.active == nil, !isHatching, !prefetchInFlight else { return }
        prefetchInFlight = true
        defer { prefetchInFlight = false }

        if state.pendingHatchID == nil {
            guard let id = await chooseBase() else { return }
            guard state.active == nil else { return }
            state.pendingHatchID = id
            save()
        }
        guard let id = state.pendingHatchID, prefetchedLineID != id else { return }
        guard let line = try? await provider.line(baseSpeciesID: id) else { return }
        #if os(macOS)
        if AppEnv.isBundledApp {
            _ = await SpriteStore.shared.data(speciesID: line.baseID, animated: false, shiny: false)
            _ = await SpriteStore.shared.data(speciesID: line.baseID, animated: true, shiny: false)
            _ = await SpriteStore.shared.data(speciesID: line.baseID, animated: true, shiny: true)
        }
        #endif
        prefetchedLineID = id
    }

    func hatch(baseID: Int) async {
        guard !isHatching else { return }
        isHatching = true
        defer { isHatching = false }
        await hatchCore(baseID: baseID)
    }

    // MARK: 메타몽 위장/리빌

    nonisolated static func dittoDisguiseHit(rarity: Rarity, totalForms: Int, roll: UInt64) -> Bool {
        rarity == .common && totalForms >= 2 && roll % PokemonOdds.dittoDisguiseDenominator == 0
    }

    nonisolated static func rollsShiny(roll: UInt64, charmOwned: Bool) -> Bool {
        roll % (charmOwned ? ShinyCharm.shinyDenominator : PokemonOdds.shinyDenominator) == 0
    }

    private func hatchCore(baseID: Int) async {
        guard let line = try? await provider.line(baseSpeciesID: baseID) else {
            AppLog.write("hatch: line fetch failed for base \(baseID) — egg kept, retry next tick")
            return
        }
        // 프리미엄 알의 마지막 보증 관문. stale 인덱스/REST 판정 차이가 있어도 낮은 등급을 내주지 않는다.
        if let tier = state.eggTier, line.rarity.sortRank < tier.sortRank {
            AppLog.write("hatch: rolled \(line.rarity) below guaranteed \(tier) — discarded, re-roll next tick")
            state.pendingHatchID = nil
            prefetchedLineID = nil
            save()
            return
        }
        currentLine = line
        let overflow = max(0, state.eggUsage - PokemonBalance.eggHatchThreshold)
        state.eggUsage = 0
        state.eggTier = nil
        let isShiny = Self.rollsShiny(roll: rng.next(), charmOwned: ownsShinyCharm)
        let nature = PokemonNature.allCases[Int(rng.next() % UInt64(PokemonNature.allCases.count))]
        var dittoDisguise: Int?
        if AppEnv.isBundledApp, Self.dittoDisguiseHit(rarity: line.rarity, totalForms: line.totalForms, roll: rng.next()) {
            dittoDisguise = line.baseID
        }
        let showShiny = isShiny && dittoDisguise == nil
        state.active = MonState(baseID: line.baseID, pathIDs: [line.baseID], stageIndex: 0,
                                usedAtStage: 0, rarity: line.rarity, totalForms: line.totalForms,
                                isShiny: isShiny, nature: nature, dittoDisguise: dittoDisguise)
        AppLog.write("hatch: base=\(line.baseID) rarity=\(line.rarity) shiny=\(isShiny) forms=\(line.totalForms) ditto=\(dittoDisguise != nil)")
        let name = line.localizedName(line.baseID, state.language)
        notifyCompanionEvent(showShiny ? l.notifShinyHatchTitle : l.notifHatchTitle,
                             showShiny ? l.notifShinyHatchBody(name) : l.notifHatchBody(name))
        justEvolvedTo = nil
        displayState = .levelUp
        eventUntil = clock().addingTimeInterval(4)
        if overflow > 0 { applyUsage(overflow) }
        if state.active != nil { fireCelebration(.hatch(shiny: showShiny)) }
        save()
    }

    private func revealDitto() async {
        guard let a = state.active, a.dittoDisguise != nil, !a.dittoRevealed, !isRevealingDitto else { return }
        let firstEvoThr = PokemonBalance.phaseThreshold(rarity: a.rarity, totalForms: a.totalForms, stageIndex: 0)
        guard a.usedAtStage >= firstEvoThr else { return }
        isRevealingDitto = true
        defer { isRevealingDitto = false }
        guard let dittoLine = try? await provider.line(baseSpeciesID: PokemonOdds.dittoSpeciesID) else {
            AppLog.write("ditto reveal: line fetch failed — retry next tick"); return
        }
        guard var m = state.active, m.dittoDisguise != nil, !m.dittoRevealed else { return }
        let disguiseName = currentLine?.localizedName(m.baseID, state.language) ?? "#\(m.baseID)"
        let carryOver = max(0, m.usedAtStage - firstEvoThr)
        m.baseID = dittoLine.baseID
        m.pathIDs = [dittoLine.baseID]
        m.stageIndex = 0
        m.rarity = dittoLine.rarity
        m.totalForms = dittoLine.totalForms
        m.usedAtStage = carryOver
        m.dittoRevealed = true
        let shiny = m.isShiny
        state.active = m
        currentLine = dittoLine
        AppLog.write("ditto reveal: disguise=\(m.dittoDisguise ?? -1) → ditto rarity=\(dittoLine.rarity) shiny=\(shiny)")
        fireCelebration(.dittoReveal(shiny: shiny))
        displayState = .levelUp
        eventUntil = clock().addingTimeInterval(5)
        notifyCompanionEvent(shiny ? l.notifShinyDittoRevealTitle : l.notifDittoRevealTitle,
                             shiny ? l.notifShinyDittoRevealBody(disguiseName) : l.notifDittoRevealBody(disguiseName))
        save()
        applyUsage(0)
    }

    private func loadCurrentLine() async {
        guard let a = state.active, currentLine == nil, !isHatching else { return }
        isHatching = true
        defer { isHatching = false }
        if let line = try? await provider.line(baseSpeciesID: a.baseID) {
            currentLine = line
            applyUsage(0)
        }
    }

    /// 부화 종 선정 — 프리미엄 알이면 capture_rate 기준으로 후보를 먼저 좁힌 뒤 기존 가중치를 적용한다.
    private func chooseBase() async -> Int? {
        let tier = state.eggTier
        if let full = try? await provider.baseSpeciesIndex(), !full.isEmpty {
            let index = tier.map { t in full.filter { t.includes(captureRate: $0.captureRate) } } ?? full
            guard !index.isEmpty else {
                AppLog.write("hatch: no candidate for guaranteed \(tier?.rawValue ?? "none") — egg kept")
                return nil
            }
            let weights = index.map { e in
                state.collectedFinals.contains(where: { $0.hasPrefix("\(e.id):") })
                    ? max(1, e.captureRate / 2) : max(1, e.captureRate)
            }
            let total = weights.reduce(0, +)
            var r = Int(rng.next() % UInt64(total))
            for (i, w) in weights.enumerated() {
                r -= w
                if r < 0 { return index[i].id }
            }
            return index.last?.id
        }
        AppLog.write("hatch: base index unavailable — REST fallback")
        return await chooseBaseViaREST()
    }

    private func chooseBaseViaREST() async -> Int? {
        let tier = state.eggTier
        // 보증 알은 rejection rate가 높아질 수 있어 기본 알보다 시도 횟수를 늘린다.
        let attempts = tier == nil ? 16 : 48
        for attempt in 1...attempts {
            let id = Int(rng.next() % 649) + 1
            do {
                if let bs = try await provider.baseSpecies(id: id) {
                    if let tier, !tier.includes(captureRate: bs.captureRate) { continue }
                    AppLog.write("hatch: REST fallback picked base \(id) (cap \(bs.captureRate), \(attempt) tries)")
                    return id
                }
            } catch {
                AppLog.write("hatch: REST fallback network error — retry next tick: \(error)")
                return nil
            }
        }
        AppLog.write("hatch: REST fallback exhausted \(attempts) tries")
        return nil
    }

    private func computeState(burnTier: BurnTier, limitWarning: Bool, hasUsageData: Bool, today: Int) -> CompanionStateKind {
        if state.active == nil { return .egg }
        if justGraduated != nil || (eventUntil != nil && clock() < eventUntil!) { return .levelUp }
        if limitWarning { return .tired }
        if !hasUsageData || today == 0 { return .sleep }
        switch burnTier {
        case .idle: return .idle
        case .normal: return .working
        case .fast, .blazing: return .focus
        }
    }

    // MARK: 영속
    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let s = try? JSONDecoder().decode(CompanionState.self, from: data) else { return }
        state = s
    }
    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
