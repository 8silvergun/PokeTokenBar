#if os(Windows)
import Foundation
import XCTest
@testable import PokeTokenBar

final class WindowsSpriteNetworkingTests: XCTestCase {
    func testSpriteRemoteURLTrustBoundary() {
        XCTAssertTrue(SpriteStore.isAllowedRemoteURL(
            URL(string: "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/315.png")!))
        XCTAssertTrue(SpriteStore.isAllowedRemoteURL(
            URL(string: "https://raw.githubusercontent.com/googlefonts/noto-emoji/main/png/128/emoji_u1f33f.png")!))

        XCTAssertFalse(SpriteStore.isAllowedRemoteURL(
            URL(string: "http://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/315.png")!))
        XCTAssertFalse(SpriteStore.isAllowedRemoteURL(
            URL(string: "https://raw.githubusercontent.com/other/repo/main/315.png")!))
        XCTAssertFalse(SpriteStore.isAllowedRemoteURL(
            URL(string: "https://user:pass@raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/315.png")!))
        XCTAssertFalse(SpriteStore.isAllowedRemoteURL(
            URL(string: "https://raw.githubusercontent.com:444/PokeAPI/sprites/master/sprites/pokemon/315.png")!))
    }
}
#endif
