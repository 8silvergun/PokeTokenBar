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

        XCTAssertTrue(await store.buy(.mint))
        XCTAssertEqual(await store.availableTokens, 400_000_000)
        XCTAssertEqual(await store.itemCount(.mint), 1)

        // Loading the active line makes the companion fully usable; mint itself does not require the line.
        let before = await store.currentNature
        let changed = await store.useMint()
        XCTAssertNotNil(changed)
        XCTAssertNotEqual(changed, before)
        XCTAssertEqual(await store.itemCount(.mint), 0)

        let reloaded = await CompanionStore(provider: WindowsShopStubProvider(), fileURL: url)
        XCTAssertEqual(await reloaded.state.spentTokens, Mint.price)
        XCTAssertEqual(await reloaded.itemCount(.mint), 0)
        XCTAssertEqual(await reloaded.currentNature, changed)
    }

    func testRareCandyPurchaseUseAndPersistence() async throws {
        let (store, url) = try await makeStore(used: 1_000_000_000, active: false)
        defer { try? FileManager.default.removeItem(at: url) }

        // Direct test hatch loads currentLine, then candy use can exercise the actual XP path.
        await store.hatch(baseID: 1)
        XCTAssertTrue(await store.buyRareCandy())
        XCTAssertEqual(await store.rareCandyCount, 1)
        XCTAssertEqual(await store.availableTokens, 500_000_000)
        XCTAssertEqual(await store.useRareCandy(), .progressed)
        XCTAssertEqual(await store.rareCandyCount, 0)
        XCTAssertEqual(await store.state.active?.usedAtStage, RareCandy.xp)

        let reloaded = await CompanionStore(provider: WindowsShopStubProvider(), fileURL: url)
        XCTAssertEqual(await reloaded.state.spentTokens, RareCandy.price)
        XCTAssertEqual(await reloaded.rareCandyCount, 0)
    }

    func testPremiumEggGuaranteeSurvivesRejectedHatchAndIsConsumedOnSuccess() async throws {
        let (store, url) = try await makeStore(used: 5_000_000_000)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(await store.buyEgg(.rare))
        XCTAssertEqual(await store.state.eggTier, .rare)
        XCTAssertNil(await store.state.active)
        XCTAssertEqual(await store.state.spentTokens, FreshEgg.price(guaranteeing: .rare))

        // A common roll must never silently violate the purchased guarantee.
        await store.hatch(baseID: 1)
        XCTAssertNil(await store.state.active)
        XCTAssertEqual(await store.state.eggTier, .rare)

        // A qualifying roll consumes the guarantee.
        await store.hatch(baseID: 2)
        XCTAssertEqual(await store.state.active?.rarity, .rare)
        XCTAssertNil(await store.state.eggTier)
    }

    func testEggPurchaseGateRejectsUnsupportedLegendaryTier() async throws {
        let (store, url) = try await makeStore(used: 10_000_000_000)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(await store.canBuyEgg(.legendary))
        XCTAssertFalse(await store.buyEgg(.legendary))
        XCTAssertEqual(await store.state.spentTokens, 0)
    }

    func testCandyGrantEdgeDedupAndRearm() async throws {
        let (store, url) = try await makeStore(used: 0, active: false, candyFeatureSeeded: true)
        defer { try? FileManager.default.removeItem(at: url) }

        let session99 = CandyWindow(key: "claude.fiveHour", name: "Claude 5h", kind: .session, utilization: 99)
        let session100 = CandyWindow(key: "claude.fiveHour", name: "Claude 5h", kind: .session, utilization: 100)

        await store.grantCandies(from: [session99], limitsReady: true)
        XCTAssertEqual(await store.rareCandyCount, 0)

        await store.grantCandies(from: [session100], limitsReady: true)
        XCTAssertEqual(await store.rareCandyCount, 1)
        await store.grantCandies(from: [session100], limitsReady: true)
        XCTAssertEqual(await store.rareCandyCount, 1, "same 100% window must not grant twice")

        await store.grantCandies(from: [session99], limitsReady: true)
        await store.grantCandies(from: [session100], limitsReady: true)
        XCTAssertEqual(await store.rareCandyCount, 2, "dropping below 100% rearms the edge")

        let weekly100 = CandyWindow(key: "claude.sevenDay", name: "Claude weekly", kind: .weekly, utilization: 100)
        await store.grantCandies(from: [weekly100], limitsReady: true)
        XCTAssertEqual(await store.rareCandyCount, 2 + RareCandy.weeklyGrant)
    }

    func testFirstLimitObservationSeedsWithoutRetroactiveGrant() async throws {
        let (store, url) = try await makeStore(used: 0, active: false, candyFeatureSeeded: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let alreadyFull = CandyWindow(key: "claude.sevenDay", name: "Claude weekly", kind: .weekly, utilization: 100)
        await store.grantCandies(from: [alreadyFull], limitsReady: true)
        XCTAssertEqual(await store.rareCandyCount, 0)
        XCTAssertTrue(await store.state.candyFeatureSeeded)
    }
}
#endif
