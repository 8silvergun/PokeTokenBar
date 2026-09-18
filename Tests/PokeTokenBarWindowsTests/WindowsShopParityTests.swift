#if os(Windows)
import Foundation
import XCTest
@testable import PokeTokenBar

private struct WindowsShopStubProvider: PokeProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine {
        let rarity: Rarity = baseSpeciesID == 2 ? .rare : .common
        return EvoLine(
            baseID: baseSpeciesID,
            tree: EvoNode(speciesID: baseSpeciesID, children: []),
            rarity: rarity,
            names: [baseSpeciesID: ["en": baseSpeciesID == 2 ? "Raremon" : "Commonmon"]]
        )
    }

    func baseSpeciesIndex() async throws -> [BaseSpecies] {
        [BaseSpecies(id: 1, captureRate: 255), BaseSpecies(id: 2, captureRate: 45)]
    }

    func baseSpecies(id: Int) async throws -> BaseSpecies? {
        BaseSpecies(id: id, captureRate: id == 2 ? 45 : 255)
    }
}

final class WindowsShopParityTests: XCTestCase {
    private func stateURL(used: Int, spent: Int = 0, active: Bool = true,
                          candyFeatureSeeded: Bool = true) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("windows-shop-\(UUID().uuidString).json")
        var obj: [String: Any] = [
            "installBaselineSet": true,
            "usedSinceInstall": used,
            "spentTokens": spent,
            "lastDate": "d1",
            "dex": [],
            "collectedFinals": [],
            "inventory": [:],
            "candyGrantTier": [:],
            "candyFeatureSeeded": candyFeatureSeeded,
        ]
        if active {
            obj["active"] = [
                "baseID": 1,
                "pathIDs": [1],
                "stageIndex": 0,
                "usedAtStage": 0,
                "rarity": "common",
                "totalForms": 1,
                "isShiny": false,
                "nature": "hardy",
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: obj)
        try data.write(to: url)
        return url
    }

    private func makeStore(used: Int, spent: Int = 0, active: Bool = true,
                           candyFeatureSeeded: Bool = true) async throws -> (CompanionStore, URL) {
        let url = try stateURL(used: used, spent: spent, active: active,
                               candyFeatureSeeded: candyFeatureSeeded)
        let store = await CompanionStore(provider: WindowsShopStubProvider(), fileURL: url)
        return (store, url)
    }

    func testPriceRatioAppliesToWindowsShopDisplayAndPurchase() async throws {
        let previous = ShopPriceSettings.percent
        defer { ShopPriceSettings.percent = previous }
        ShopPriceSettings.percent = 50

        XCTAssertEqual(ShopEntry.item(.mint).price, Mint.price / 2)
        XCTAssertEqual(ShopEntry.egg(.rare).price, FreshEgg.price(guaranteeing: .rare) / 2)

        let (store, url) = try await makeStore(used: Mint.price / 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let bought = await store.buy(.mint)
        let state = await store.state
        XCTAssertTrue(bought)
        XCTAssertEqual(state.spentTokens, Mint.price / 2)
    }

    func testPremiumEggPricesAndOrderingMatchMacOS() async throws {
        XCTAssertEqual(FreshEgg.price(guaranteeing: nil), 1_000_000_000)
        XCTAssertEqual(FreshEgg.price(guaranteeing: .uncommon), 2_500_000_000)
        XCTAssertEqual(FreshEgg.price(guaranteeing: .rare), 4_000_000_000)
        XCTAssertEqual(FreshEgg.shopTiers.count, 3)

        let (store, url) = try await makeStore(used: 5_000_000_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let entries = await store.shopEntries
        XCTAssertEqual(entries, [
            .item(.mint),
            .item(.rareCandy),
            .egg(nil),
            .egg(.uncommon),
            .item(.shinyCharm),
            .egg(.rare),
        ])
    }

    func testMintPurchaseUseAndPersistence() async throws {
        let (store, url) = try await makeStore(used: 500_000_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let bought = await store.buy(.mint)
        let walletAfterBuy = await store.availableTokens
        let mintAfterBuy = await store.itemCount(.mint)
        XCTAssertTrue(bought)
        XCTAssertEqual(walletAfterBuy, 400_000_000)
        XCTAssertEqual(mintAfterBuy, 1)

        let before = await store.currentNature
        let changed = await store.useMint()
        let mintAfterUse = await store.itemCount(.mint)
        XCTAssertNotNil(changed)
        XCTAssertNotEqual(changed, before)
        XCTAssertEqual(mintAfterUse, 0)

        let reloaded = await CompanionStore(provider: WindowsShopStubProvider(), fileURL: url)
        let reloadedState = await reloaded.state
        let reloadedMint = await reloaded.itemCount(.mint)
        let reloadedNature = await reloaded.currentNature
        XCTAssertEqual(reloadedState.spentTokens, Mint.price)
        XCTAssertEqual(reloadedMint, 0)
        XCTAssertEqual(reloadedNature, changed)
    }

    func testRareCandyPurchaseUseAndPersistence() async throws {
        let (store, url) = try await makeStore(used: 1_000_000_000, active: false)
        defer { try? FileManager.default.removeItem(at: url) }

        await store.hatch(baseID: 1)
        let bought = await store.buyRareCandy()
        let candyAfterBuy = await store.rareCandyCount
        let walletAfterBuy = await store.availableTokens
        let result = await store.useRareCandy()
        let candyAfterUse = await store.rareCandyCount
        let usedAtStage = await store.state.active?.usedAtStage
        XCTAssertTrue(bought)
        XCTAssertEqual(candyAfterBuy, 1)
        XCTAssertEqual(walletAfterBuy, 500_000_000)
        XCTAssertEqual(result, .progressed)
        XCTAssertEqual(candyAfterUse, 0)
        XCTAssertEqual(usedAtStage, RareCandy.xp)

        let reloaded = await CompanionStore(provider: WindowsShopStubProvider(), fileURL: url)
        let reloadedState = await reloaded.state
        let reloadedCandy = await reloaded.rareCandyCount
        XCTAssertEqual(reloadedState.spentTokens, RareCandy.price)
        XCTAssertEqual(reloadedCandy, 0)
    }

    func testPremiumEggGuaranteeSurvivesRejectedHatchAndIsConsumedOnSuccess() async throws {
        let (store, url) = try await makeStore(used: 5_000_000_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let bought = await store.buyEgg(.rare)
        var state = await store.state
        XCTAssertTrue(bought)
        XCTAssertEqual(state.eggTier, .rare)
        XCTAssertNil(state.active)
        XCTAssertEqual(state.spentTokens, FreshEgg.price(guaranteeing: .rare))

        await store.hatch(baseID: 1)
        state = await store.state
        XCTAssertNil(state.active)
        XCTAssertEqual(state.eggTier, .rare)

        await store.hatch(baseID: 2)
        state = await store.state
        XCTAssertEqual(state.active?.rarity, .rare)
        XCTAssertNil(state.eggTier)
    }

    func testEggPurchaseGateRejectsUnsupportedLegendaryTier() async throws {
        let (store, url) = try await makeStore(used: 10_000_000_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let canBuy = await store.canBuyEgg(.legendary)
        let bought = await store.buyEgg(.legendary)
        let state = await store.state
        XCTAssertFalse(canBuy)
        XCTAssertFalse(bought)
        XCTAssertEqual(state.spentTokens, 0)
    }

    func testCandyGrantEdgeDedupAndRearm() async throws {
        let (store, url) = try await makeStore(used: 0, active: false, candyFeatureSeeded: true)
        defer { try? FileManager.default.removeItem(at: url) }

        let session99 = CandyWindow(key: "claude.fiveHour", name: "Claude 5h", kind: .session, utilization: 99)
        let session100 = CandyWindow(key: "claude.fiveHour", name: "Claude 5h", kind: .session, utilization: 100)

        await store.grantCandies(from: [session99], limitsReady: true)
        var candy = await store.rareCandyCount
        XCTAssertEqual(candy, 0)

        await store.grantCandies(from: [session100], limitsReady: true)
        candy = await store.rareCandyCount
        XCTAssertEqual(candy, 1)
        await store.grantCandies(from: [session100], limitsReady: true)
        candy = await store.rareCandyCount
        XCTAssertEqual(candy, 1, "same 100% window must not grant twice")

        await store.grantCandies(from: [session99], limitsReady: true)
        await store.grantCandies(from: [session100], limitsReady: true)
        candy = await store.rareCandyCount
        XCTAssertEqual(candy, 2, "dropping below 100% rearms the edge")

        let weekly100 = CandyWindow(key: "claude.sevenDay", name: "Claude weekly", kind: .weekly, utilization: 100)
        await store.grantCandies(from: [weekly100], limitsReady: true)
        candy = await store.rareCandyCount
        XCTAssertEqual(candy, 2 + RareCandy.weeklyGrant)
    }

    func testFirstLimitObservationSeedsWithoutRetroactiveGrant() async throws {
        let (store, url) = try await makeStore(used: 0, active: false, candyFeatureSeeded: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let alreadyFull = CandyWindow(key: "claude.sevenDay", name: "Claude weekly", kind: .weekly, utilization: 100)
        await store.grantCandies(from: [alreadyFull], limitsReady: true)
        let candy = await store.rareCandyCount
        let state = await store.state
        XCTAssertEqual(candy, 0)
        XCTAssertTrue(state.candyFeatureSeeded)
    }
}
#endif
