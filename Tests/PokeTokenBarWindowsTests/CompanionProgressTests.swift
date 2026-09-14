#if os(Windows)
import Foundation
import XCTest
@testable import PokeTokenBar

private struct CompanionProgressStubProvider: PokeProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine {
        EvoLine(
            baseID: baseSpeciesID,
            tree: EvoNode(speciesID: baseSpeciesID, children: []),
            rarity: .common,
            names: [baseSpeciesID: ["en": "Testmon"]]
        )
    }

    func baseSpeciesIndex() async throws -> [BaseSpecies] {
        [BaseSpecies(id: 1, captureRate: 255)]
    }

    func baseSpecies(id: Int) async throws -> BaseSpecies? {
        BaseSpecies(id: id, captureRate: 255)
    }
}

final class CompanionProgressTests: XCTestCase {
    private func makeStore() async -> (CompanionStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("windows-companion-\(UUID().uuidString).json")
        let store = await CompanionStore(provider: CompanionProgressStubProvider(), fileURL: url)
        return (store, url)
    }

    func testUsageIncreaseAfterValidDropContinuesEggProgress() async {
        let (store, url) = await makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        await store.update(todayTokens: 0, todayDate: "d1", monthTotal: 0,
                           burnTier: .idle, limitWarning: false, hasUsageData: true)
        await store.update(todayTokens: 200, todayDate: "d1", monthTotal: 0,
                           burnTier: .idle, limitWarning: false, hasUsageData: true)
        var state = await store.state
        XCTAssertEqual(state.eggUsage, 200)
        XCTAssertEqual(state.claimedTodayTokens, 200)

        // Local log replay/dedup can make a valid daily snapshot smaller. It must become
        // the new baseline without subtracting already-earned companion progress.
        await store.update(todayTokens: 40, todayDate: "d1", monthTotal: 0,
                           burnTier: .idle, limitWarning: false, hasUsageData: true)
        state = await store.state
        XCTAssertEqual(state.eggUsage, 200)
        XCTAssertEqual(state.claimedTodayTokens, 40)

        // Growth after the rebased value must be credited instead of waiting for the
        // old high-water mark (200) to be exceeded again.
        await store.update(todayTokens: 75, todayDate: "d1", monthTotal: 0,
                           burnTier: .idle, limitWarning: false, hasUsageData: true)
        state = await store.state
        XCTAssertEqual(state.eggUsage, 235)
        XCTAssertEqual(state.usedSinceInstall, 235)
        XCTAssertEqual(state.claimedTodayTokens, 75)
    }

    func testEmptySnapshotDoesNotRebaseDailyLedger() async {
        let (store, url) = await makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        await store.update(todayTokens: 0, todayDate: "d1", monthTotal: 0,
                           burnTier: .idle, limitWarning: false, hasUsageData: true)
        await store.update(todayTokens: 200, todayDate: "d1", monthTotal: 0,
                           burnTier: .idle, limitWarning: false, hasUsageData: true)

        // A transient empty/failed refresh must not reset the baseline to zero; otherwise
        // the next healthy snapshot would credit the whole day a second time.
        await store.update(todayTokens: 0, todayDate: "d1", monthTotal: 0,
                           burnTier: .idle, limitWarning: false, hasUsageData: false)
        var state = await store.state
        XCTAssertEqual(state.eggUsage, 200)
        XCTAssertEqual(state.claimedTodayTokens, 200)

        await store.update(todayTokens: 250, todayDate: "d1", monthTotal: 0,
                           burnTier: .idle, limitWarning: false, hasUsageData: true)
        state = await store.state
        XCTAssertEqual(state.eggUsage, 250)
        XCTAssertEqual(state.usedSinceInstall, 250)
        XCTAssertEqual(state.claimedTodayTokens, 250)
    }
}
#endif
