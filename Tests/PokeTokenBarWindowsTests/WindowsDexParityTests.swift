#if os(Windows)
import Foundation
import XCTest
@testable import PokeTokenBar

private struct WindowsDexStubProvider: PokeProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine {
        let child = EvoNode(speciesID: 2, children: [])
        return EvoLine(
            baseID: 1,
            tree: EvoNode(speciesID: 1, children: [child]),
            rarity: .common,
            names: [
                1: ["en": "Firstmon"],
                2: ["en": "Secondmon"],
            ]
        )
    }

    func baseSpeciesIndex() async throws -> [BaseSpecies] {
        [BaseSpecies(id: 1, captureRate: 255)]
    }

    func baseSpecies(id: Int) async throws -> BaseSpecies? {
        id == 1 ? BaseSpecies(id: 1, captureRate: 255) : nil
    }
}

final class WindowsDexParityTests: XCTestCase {
    private func stateURL(active: Bool, dex: [[String: Any]] = []) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("windows-dex-\(UUID().uuidString).json")
        var obj: [String: Any] = [
            "installBaselineSet": true,
            "usedSinceInstall": 2_000_000_000,
            "spentTokens": 0,
            "lastDate": "d1",
            "dex": dex,
            "collectedFinals": [],
            "inventory": [:],
            "candyGrantTier": [:],
            "candyFeatureSeeded": true,
            "language": "en",
        ]
        if active {
            obj["active"] = [
                "baseID": 1,
                "pathIDs": [1, 2],
                "plannedPathIDs": [1, 2],
                "stageIndex": 1,
                "usedAtStage": 10,
                "rarity": "common",
                "totalForms": 2,
                "isShiny": false,
                "nature": "hardy",
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: obj)
        try data.write(to: url)
        return url
    }

    func testRaisingPokemonAppearsImmediatelyInDexAndCatchLog() async throws {
        let url = try stateURL(active: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = await CompanionStore(provider: WindowsDexStubProvider(), fileURL: url)

        let display = await store.windowsDisplay
        XCTAssertEqual(display.dex.map(\.speciesID), [1, 2],
                       "Dex must include every reached species, not only graduated finals")
        XCTAssertFalse(display.dex[0].isRaising)
        XCTAssertTrue(display.dex[1].isRaising,
                      "Only the current form should carry the raising marker")
        XCTAssertEqual(display.catchLog.count, 1)
        XCTAssertTrue(display.catchLog[0].isRaising)
        XCTAssertFalse(display.catchLog[0].isReleased)
        XCTAssertEqual(display.catchLog[0].chainIDs, [1, 2])
    }

    func testBuyingFreshEggPreservesReleasedPokemonInDexAndCatchLog() async throws {
        let url = try stateURL(active: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = await CompanionStore(provider: WindowsDexStubProvider(), fileURL: url)

        let bought = await store.buyEgg(nil)
        XCTAssertTrue(bought)
        let state = await store.state
        XCTAssertNil(state.active)

        let display = await store.windowsDisplay
        XCTAssertEqual(display.dex.map(\.speciesID), [1, 2],
                       "Reached species must remain owned after the individual is released")
        XCTAssertEqual(display.catchLog.count, 1)
        XCTAssertTrue(display.catchLog[0].isReleased)
        XCTAssertFalse(display.catchLog[0].isRaising)
        XCTAssertEqual(display.catchLog[0].chainIDs, [1, 2])
    }

    func testDexFoldsDuplicateSpeciesWhileCatchLogKeepsIndividuals() async throws {
        let first: [String: Any] = [
            "id": "one",
            "baseID": 1,
            "finalID": 1,
            "chainOrder": [1],
            "rarity": "common",
            "caughtAt": "2026-09-14T00:00:00Z",
            "isShiny": false,
            "nature": "hardy",
        ]
        let second: [String: Any] = [
            "id": "two",
            "baseID": 1,
            "finalID": 1,
            "chainOrder": [1],
            "rarity": "common",
            "caughtAt": "2026-09-15T00:00:00Z",
            "isShiny": true,
            "nature": "jolly",
        ]
        let url = try stateURL(active: false, dex: [first, second])
        defer { try? FileManager.default.removeItem(at: url) }
        let store = await CompanionStore(provider: WindowsDexStubProvider(), fileURL: url)

        let display = await store.windowsDisplay
        XCTAssertEqual(display.dex.count, 1, "Pokédex is species-based")
        XCTAssertEqual(display.dex[0].speciesID, 1)
        XCTAssertTrue(display.dex[0].isShiny, "Species cell retains shiny ownership across catches")
        XCTAssertEqual(display.catchLog.count, 2, "Catch Log is individual-based")
    }
}
#endif
