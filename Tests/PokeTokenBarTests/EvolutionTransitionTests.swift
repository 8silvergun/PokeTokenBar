import Foundation
import XCTest
@testable import PokeTokenBar

private struct EvolutionTransitionCoreStubProvider: PokeProviding {
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

@MainActor
final class EvolutionTransitionCoreTests: XCTestCase {
    func testLargeBatchedUsageStopsAfterVisibleEvolution() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("core-evolution-transition-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = CompanionStore(provider: EvolutionTransitionCoreStubProvider(), fileURL: url)
        await store.hatch(baseID: 46)

        // For a two-form common line the unaccelerated thresholds total 750M tokens.
        // 1B therefore crosses both thresholds for every supported 1x...20x multiplier
        // without mutating the process-global UserDefaults evolution-speed setting.
        store.applyUsage(1_000_000_000)

        var snapshot = store.state
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

        store.applyUsage(0)
        snapshot = store.state
        XCTAssertNil(snapshot.active)
        XCTAssertEqual(snapshot.dex.last?.finalID, 47)
    }
}
