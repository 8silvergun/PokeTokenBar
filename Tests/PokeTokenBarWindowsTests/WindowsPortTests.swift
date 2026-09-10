#if os(Windows)
import XCTest
import WinSDK
@testable import PokeTokenBar

/// Windows-port unit tests — deterministic checks of the new Win32-facing helpers.
final class WindowsPortTests: XCTestCase {
    /// `rgb` must pack components as COLORREF 0x00BBGGRR (Win32 order), not RGB.
    func testRGBPacksBGROrder() {
        XCTAssertEqual(rgb(0x12, 0x34, 0x56), COLORREF(0x0056_3412))
        XCTAssertEqual(rgb(255, 0, 0), COLORREF(0x0000_00FF))   // red → low byte
        XCTAssertEqual(rgb(0, 0, 255), COLORREF(0x00FF_0000))   // blue → high byte
    }

    /// `String.wide` yields a NUL-terminated UTF-16 buffer for Win32 wide-string APIs.
    func testWideIsNulTerminatedUTF16() {
        XCTAssertEqual("Hi".wide, [72, 105, 0])
        XCTAssertEqual("".wide, [0])
        XCTAssertEqual("한".wide, [0xD55C, 0])   // BMP codepoint stays one UTF-16 unit
    }

    /// The autostart Run-key command points at this exe (quoted) and launches the tray.
    func testAutostartCommandFormat() {
        let cmd = WindowsAutostart.command
        XCTAssertTrue(cmd.hasPrefix("\""), "exe path must be quoted")
        XCTAssertTrue(cmd.hasSuffix("--tray"), "must launch the tray, got: \(cmd)")
    }

    /// Update tags (`win-2.4.5` / `v2.4.5` / `2.4.5`) normalize to a bare version, 4-segment included.
    func testUpdateTagNormalize() {
        XCTAssertEqual(WindowsUpdate.normalize("win-2.4.5"), "2.4.5")
        XCTAssertEqual(WindowsUpdate.normalize("v2.4.5"), "2.4.5")
        XCTAssertEqual(WindowsUpdate.normalize("2.4.5"), "2.4.5")
        XCTAssertEqual(WindowsUpdate.normalize("win-2.4.4.1"), "2.4.4.1")   // Windows MAJOR.MINOR.PATCH.WINFIX
    }

    /// Version compare is numeric (not lexical), strict, and handles the 4-segment Windows scheme
    /// (shorter side zero-padded, so `win-2.4.4` == `2.4.4.0` < `2.4.4.1`).
    func testUpdateIsNewer() {
        XCTAssertTrue(WindowsUpdate.isNewer("2.4.5", than: "2.4.4"))
        XCTAssertTrue(WindowsUpdate.isNewer("2.4.10", than: "2.4.9"))   // numeric, not "10" < "9"
        XCTAssertTrue(WindowsUpdate.isNewer("2.5.0", than: "2.4.99"))
        XCTAssertFalse(WindowsUpdate.isNewer("2.4.4", than: "2.4.4"))   // equal is not newer
        XCTAssertFalse(WindowsUpdate.isNewer("2.4.3", than: "2.4.4"))
        // 4-segment Windows build counter
        XCTAssertTrue(WindowsUpdate.isNewer("2.4.4.1", than: "2.4.4"))    // .1 beats the padded .0
        XCTAssertTrue(WindowsUpdate.isNewer("2.4.4.2", than: "2.4.4.1"))
        XCTAssertTrue(WindowsUpdate.isNewer("2.4.5.0", than: "2.4.4.9"))  // upstream base wins
        XCTAssertFalse(WindowsUpdate.isNewer("2.4.4", than: "2.4.4.1"))   // .0 is older than .1
        XCTAssertFalse(WindowsUpdate.isNewer("2.4.4.1", than: "2.4.4.1"))
    }

    func testWindowsUpdateRepositoryIsForkOwned() {
        XCTAssertEqual(WindowsUpdate.repo, "8silvergun/PokeTokenBar")
    }

    func testTrustedInstallerAssetURLIsExactAndForkOwned() {
        let tag = "win-9.9.9"
        let name = "PokeTokenBar-Setup-9.9.9.exe"
        let good = "https://github.com/8silvergun/PokeTokenBar/releases/download/\(tag)/\(name)"
        XCTAssertNotNil(WindowsUpdate.trustedInstallerAssetURL(good, tag: tag, expectedName: name))

        XCTAssertNil(WindowsUpdate.trustedInstallerAssetURL(
            "http://github.com/8silvergun/PokeTokenBar/releases/download/\(tag)/\(name)",
            tag: tag, expectedName: name))
        XCTAssertNil(WindowsUpdate.trustedInstallerAssetURL(
            "https://github.com/chattymin/PokeTokenBar/releases/download/\(tag)/\(name)",
            tag: tag, expectedName: name))
        XCTAssertNil(WindowsUpdate.trustedInstallerAssetURL(
            "https://github.com/8silvergun/PokeTokenBar/releases/download/\(tag)/evil-Setup.exe",
            tag: tag, expectedName: name))
        XCTAssertNil(WindowsUpdate.trustedInstallerAssetURL(
            good + "?redirect=evil",
            tag: tag, expectedName: name))
    }

    func testUpdaterScriptDetectionOnlyMatchesDetachedUpdater() {
        let path = "C:\\Users\\me\\AppData\\Local\\Temp\\ptb-apply-123.cmd"
        let command = "\"C:\\Windows\\System32\\cmd.exe\" /c \"\(path)\""
        XCTAssertEqual(WindowsProcess.updaterScriptPath(in: command), path)
        XCTAssertNil(WindowsProcess.updaterScriptPath(in: "\"C:\\Users\\me\\AppData\\Roaming\\npm\\codex.cmd\" app-server"))
    }

    func testPersistentLogRedactsCommonCredentialShapes() {
        let bearer = "Authorization: Bearer super-secret-token-value"
        let json = "{\"access_token\":\"another-secret-token-value\"}"
        let apiKey = "sk-abcdefghijklmnopqrstuvwxyz012345"
        for input in [bearer, json, apiKey] {
            let output = AppLog.redacted(input)
            XCTAssertTrue(output.contains("[REDACTED]"), "expected redaction: \(output)")
            XCTAssertFalse(output.contains("super-secret-token-value"))
            XCTAssertFalse(output.contains("another-secret-token-value"))
            XCTAssertFalse(output.contains("abcdefghijklmnopqrstuvwxyz012345"))
        }
    }

    func testWindowsImageDecoderResourceLimits() {
        XCTAssertTrue(WindowsImaging.dimensionsAreSafe(width: 128, height: 128))
        XCTAssertTrue(WindowsImaging.dimensionsAreSafe(width: 4096, height: 4096))
        XCTAssertFalse(WindowsImaging.dimensionsAreSafe(width: 4097, height: 1))
        XCTAssertFalse(WindowsImaging.dimensionsAreSafe(width: 1, height: 4097))
        XCTAssertFalse(WindowsImaging.dimensionsAreSafe(width: 0, height: 128))
    }
}
#endif
