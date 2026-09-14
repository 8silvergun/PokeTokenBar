#if os(Windows)
import XCTest
@testable import PokeTokenBar

final class WSLProcessProxyTests: XCTestCase {
    func testAllowsOnlyWSLControlQueriesUsedByUsageReader() {
        XCTAssertTrue(WSLProcessProxy.allowed(arguments: ["--list", "--quiet"]))
        XCTAssertTrue(WSLProcessProxy.allowed(arguments: [
            "--distribution", "Ubuntu", "--exec", "/usr/bin/printenv", "HOME",
        ]))
        XCTAssertTrue(WSLProcessProxy.allowed(arguments: [
            "--distribution", "Ubuntu 24.04", "--exec", "/usr/bin/printenv", "HOME",
        ]))

        XCTAssertFalse(WSLProcessProxy.allowed(arguments: []))
        XCTAssertFalse(WSLProcessProxy.allowed(arguments: ["--list", "--verbose"]))
        XCTAssertFalse(WSLProcessProxy.allowed(arguments: [
            "--distribution", "../Ubuntu", "--exec", "/usr/bin/printenv", "HOME",
        ]))
        XCTAssertFalse(WSLProcessProxy.allowed(arguments: [
            "--distribution", "Ubuntu", "--exec", "/bin/sh", "-c", "id",
        ]))
    }

    func testRejectedProxyRequestFailsClosedWithoutLaunching() {
        let result = WSLProcessProxy.capture(arguments: ["--distribution", "Ubuntu", "--exec", "/bin/sh"])
        XCTAssertEqual(result.failure, .launch)
        XCTAssertNil(result.exitCode)
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertTrue(result.processStopped)
    }
}
#endif
