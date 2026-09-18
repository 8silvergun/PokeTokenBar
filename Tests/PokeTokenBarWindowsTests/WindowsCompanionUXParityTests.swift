#if os(Windows)
import Foundation
import XCTest
@testable import PokeTokenBar

private struct WindowsCompanionUXStubProvider: PokeProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine {
        EvoLine(baseID: baseSpeciesID,
                tree: EvoNode(speciesID: baseSpeciesID, children: []),
                rarity: .common,
                names: [baseSpeciesID: ["en": "Mon\(baseSpeciesID)"]])
    }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
}

final class WindowsCompanionUXParityTests: XCTestCase {
    private func makeStateURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("windows-companion-ux-\(UUID().uuidString).json")
        let dex: [[String: Any]] = [[
            "id": "saved",
            "baseID": 25,
            "finalID": 25,
            "chainOrder": [25],
            "rarity": "common",
            "caughtAt": 800_000_000.0,
            "isShiny": true,
            "nature": "jolly",
            "names": ["25": ["en": "Pikachu"]],
        ]]
        let obj: [String: Any] = [
            "installBaselineSet": true,
            "usedSinceInstall": 1_000_000_000,
            "spentTokens": 0,
            "eggUsage": 0,
            "claimedTodayTokens": 0,
            "lastDate": "d1",
            "dex": dex,
            "collectedFinals": [],
            "inventory": [:],
            "candyGrantTier": [:],
            "candyFeatureSeeded": true,
            "language": "en",
        ]
        try JSONSerialization.data(withJSONObject: obj).write(to: url)
        return url
    }

    func testRepresentativeSelectionPersistsAndDrivesVisualSubject() async throws {
        let url = try makeStateURL(); defer { try? FileManager.default.removeItem(at: url) }
        let store = await CompanionStore(provider: WindowsCompanionUXStubProvider(), fileURL: url)

        let selected = await store.setRepresentativeSpeciesID(25)
        XCTAssertTrue(selected)
        let first = await store.windowsDisplay
        XCTAssertEqual(first.representativeSpeciesID, 25)
        XCTAssertEqual(first.visualSpeciesID, 25)
        XCTAssertTrue(first.visualIsShiny)

        let reloaded = await CompanionStore(provider: WindowsCompanionUXStubProvider(), fileURL: url)
        let persistedID = await reloaded.representativeSpeciesID
        XCTAssertEqual(persistedID, 25)

        let invalidSelection = await reloaded.setRepresentativeSpeciesID(999)
        XCTAssertFalse(invalidSelection, "unowned species must be rejected")
        let afterInvalid = await reloaded.representativeSpeciesID
        XCTAssertEqual(afterInvalid, 25, "failed selection must not clear the previous choice")

        let reset = await reloaded.setRepresentativeSpeciesID(nil)
        XCTAssertTrue(reset)
        let resetID = await reloaded.representativeSpeciesID
        XCTAssertNil(resetID)
    }

    func testHomeVisualSubjectStaysEggWhenRepresentativeIsPinned() {
        var display = CompanionDisplay()
        display.isEgg = true
        display.speciesID = nil
        display.isShiny = false
        display.visualSpeciesID = 47      // e.g. pinned Parasect
        display.visualIsShiny = false

        XCTAssertEqual(display.homeVisualKey, "egg")
        XCTAssertEqual(display.trayVisualKey, "47-false")
        XCTAssertFalse(display.canReuseTrayAnimationForHome,
                       "representative animation must not paint over the Home egg")

        display.isEgg = false
        display.speciesID = 47
        XCTAssertEqual(display.homeVisualKey, display.trayVisualKey)
        XCTAssertTrue(display.canReuseTrayAnimationForHome)
    }

    func testFloatingPetSizeIsBounded() {
        XCTAssertEqual(WindowsFloatingPet.clampedSize(1), WindowsFloatingPet.minSize)
        XCTAssertEqual(WindowsFloatingPet.clampedSize(96), 96)
        XCTAssertEqual(WindowsFloatingPet.clampedSize(999), WindowsFloatingPet.maxSize)
    }
}
#endif
