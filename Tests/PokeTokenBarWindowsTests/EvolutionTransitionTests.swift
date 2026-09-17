#if os(Windows)
import Foundation
import XCTest
@testable import PokeTokenBar

private struct EvolutionTransitionStubProvider: PokeProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine {
        EvoLine(
            baseID: 46,
            tree: EvoNode(speciesID: 46, children: [
                EvoNode(speciesID: 47, children: [])
            ]),
            rarity: .common,
            names: [46: ["en": "Paras"], 47: ["en": "Parasect"]]
        )
    }

    func baseSpeciesIndex() async throws -> [BaseSpecies] {
        [BaseSpecies(id: 46, captureRate: 255)]
    }

    func baseSpecies(id: Int) async throws -> BaseSpecies? {
        BaseSpecies(id: id, captureRate: 255)
    }
}

final class EvolutionTransitionTests: XCTestCase {
    func testLargeBatchedUsageStopsAfterVisibleEvolution() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("windows-evolution-transition-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = await CompanionStore(provider: EvolutionTransitionStubProvider(), fileURL: url)
        await store.hatch(baseID: 46)

        // For a two-form common line the unaccelerated thresholds total 750M tokens.
        // 1B therefore crosses both thresholds for every supported 1x...20x multiplier
        // without mutating the process-global UserDefaults evolution-speed setting.
        await store.applyUsage(1_000_000_000)

        var snapshot = await store.state
        guard let active = snapshot.active else {
            XCTFail("Large batched usage must not evolve and graduate in the same application")
            return
        }
        XCTAssertEqual(active.currentID, 47)
        XCTAssertEqual(active.stageIndex, 1)
        XCTAssertTrue(snapshot.dex.isEmpty)
        XCTAssertGreaterThanOrEqual(
            active.usedAtStage,
            EvolutionSpeedSettings.phaseThreshold(rarity: .common, totalForms: 2, stageIndex: 1)
        )

        // The excess tokens are deferred, not discarded. A later application can graduate normally.
        await store.applyUsage(0)
        snapshot = await store.state
        XCTAssertNil(snapshot.active)
        XCTAssertEqual(snapshot.dex.last?.finalID, 47)
    }
}
#endif
