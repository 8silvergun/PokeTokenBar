#if os(Windows)
import Foundation
import XCTest
import WinSDK
@testable import PokeTokenBar

final class WSLSecurityTests: XCTestCase {
    func testRejectsAmbiguousUNCComponents() {
        let invalidHomes = ["//home/user", "/home//user", "/home/user/", "/home/./user",
                            "/home/../user", "/home/user.", "/home/user ", "/home/user:stream",
                            "/home/user\n", "/home/nu\0ll", "/home/a\\b", "/home/NUL", "/home/COM1.txt"]
        for home in invalidHomes {
            XCTAssertNil(WSLUsage.uncBasePath(distribution: "Ubuntu", linuxHome: home), home.debugDescription)
        }
        for name in [".", "..", "-Ubuntu", "Ubuntu.", "Ubuntu ", "Ubuntu:stream", "Ubuntu\n", "Ubuntu\"", "a/b", "a\\b"] {
            XCTAssertFalse(WSLUsage.isSafeDistributionName(name), name.debugDescription)
        }
        XCTAssertEqual(WSLUsage.uncBasePath(distribution: "Ubuntu 24.04", linuxHome: "/home/한글 사용자"),
                       "\\\\wsl.localhost\\Ubuntu 24.04\\home\\한글 사용자")
        XCTAssertNotNil(WSLUsage.uncBasePath(distribution: "Ubuntu", linuxHome: "/"))
    }

    func testOutputDecodingPreservesUnicodeAndRejectsNUL() throws {
        let value = "Ubuntu\r\n배포판\r\n"
        XCTAssertEqual(WSLUsage.decodeProcessOutput(Data(value.utf8)), value)
        let utf16 = try XCTUnwrap(value.data(using: .utf16LittleEndian))
        XCTAssertEqual(WSLUsage.decodeProcessOutput(utf16, allowUTF16: true), value)
        XCTAssertEqual(WSLUsage.decodeProcessOutput(Data([0xFF, 0xFE]) + utf16, allowUTF16: true), value)
        XCTAssertNil(WSLUsage.decodeProcessOutput(utf16))  // Linux HOME is UTF-8, not a WSL list
        XCTAssertNil(WSLUsage.decodeProcessOutput(Data("/home/us\0er\n".utf8)))
    }

    func testArgumentQuotingRoundTripsWithoutShellInterpretation() throws {
        let arguments = ["tool.exe", "", "Ubuntu 24.04", "한글", "tail\\", "a\\\"b", "&|><%"]
        let line = arguments.map(WindowsProcess.quoteArgument).joined(separator: " ")
        let wide = Array(line.utf16) + [0]
        var count: Int32 = 0
        let argv = try XCTUnwrap(wide.withUnsafeBufferPointer { CommandLineToArgvW($0.baseAddress, &count) })
        defer { _ = LocalFree(UnsafeMutableRawPointer(argv)) }
        let decoded = (0..<Int(count)).map { String(decodingCString: argv[$0]!, as: UTF16.self) }
        XCTAssertEqual(decoded, arguments)
    }

    func testCaptureKeepsStdoutSeparateAndPreservesExitCode() throws {
        let result = try powerShell("[Console]::Out.Write('ok'); [Console]::Error.Write('diagnostic'); exit 7")
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertEqual(String(data: result.stdout, encoding: .utf8), "ok")
        XCTAssertTrue(result.processStopped)
    }

    func testCaptureBoundsBothOutputStreams() throws {
        for stream in ["Out", "Error"] {
            let result = try powerShell("[Console]::\(stream).Write(('x' * 4096)); Start-Sleep -Seconds 30",
                                        maxOutputBytes: 1024)
            XCTAssertEqual(result.failure, .outputLimit, stream)
            XCTAssertTrue(result.stdout.isEmpty)
            XCTAssertTrue(result.processStopped)
        }
    }

    func testCaptureTimeoutTerminatesWindowsClient() throws {
        let start = Date()
        let result = try powerShell("Start-Sleep -Seconds 30", timeout: 0.2)
        XCTAssertEqual(result.failure, .timeout)
        XCTAssertTrue(result.processStopped)
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testCaptureLaunchFailure() throws {
        let executable = try XCTUnwrap(WindowsProcess.systemExecutable("poketokenbar-missing-test-tool.exe"))
        let result = WindowsProcess.capture(executable: executable, arguments: [])
        XCTAssertEqual(result.failure, .launch)
        XCTAssertTrue(result.stdout.isEmpty)
    }

    func testFileBackedProcessAndRepeatedCleanup() throws {
        let root = try temporaryDirectory()
        let executable = try XCTUnwrap(WindowsProcess.systemExecutable("where.exe"))
        let output = root.appendingPathComponent("stdout.txt")
        let error = root.appendingPathComponent("stderr.txt")
        let command = [executable, "cmd.exe"].map(WindowsProcess.quoteArgument).joined(separator: " ")
        let process = try XCTUnwrap(WindowsProcess(commandLine: command, stdoutPath: output.path,
                                                  stderrPath: error.path, createNewOutputFiles: true))
        process.closeStdin()
        let exited = process.waitFor(8)
        if !exited { process.terminate(); _ = process.waitFor(1) }
        XCTAssertTrue(exited)
        XCTAssertEqual(process.exitCode, 0)
        process.cleanup()
        process.cleanup()
        XCTAssertFalse(try Data(contentsOf: output).isEmpty)
        XCTAssertNoThrow(try FileManager.default.removeItem(at: output))
    }

    func testCreateNewCollisionPreservesFilesAndClosesPartialSetup() throws {
        let root = try temporaryDirectory()
        let output = root.appendingPathComponent("stdout.txt")
        let error = root.appendingPathComponent("existing-stderr.txt")
        let sentinel = Data("must remain unchanged".utf8)
        try sentinel.write(to: error)
        let process = WindowsProcess(commandLine: "unused.exe", stdoutPath: output.path,
                                     stderrPath: error.path, createNewOutputFiles: true)
        XCTAssertNil(process)
        XCTAssertEqual(try Data(contentsOf: error), sentinel)
        // The first file opened successfully before stderr failed. Without closing
        // that handle, Windows denies this deletion because it was not shared for delete.
        XCTAssertNoThrow(try FileManager.default.removeItem(at: output))
    }

    func testUNCAncestorsStayWithinTheShare() {
        XCTAssertTrue(WindowsUsageFile.isWSLUNCPath("\\wsl.localhost\Ubuntu\home\user"))
        XCTAssertTrue(WindowsUsageFile.isWSLUNCPath("\\WSL.LOCALHOST\Ubuntu\home\user"))
        XCTAssertFalse(WindowsUsageFile.isWSLUNCPath("\\server\share\home\user"))
        XCTAssertFalse(WindowsUsageFile.isWSLUNCPath("C:\Users\user"))
        XCTAssertEqual(WindowsUsageFile.pathPrefixes("\\\\wsl.localhost\\Ubuntu\\home\\user\\.codex\\sessions"), [
            "\\\\wsl.localhost\\Ubuntu\\home", "\\\\wsl.localhost\\Ubuntu\\home\\user",
            "\\\\wsl.localhost\\Ubuntu\\home\\user\\.codex", "\\\\wsl.localhost\\Ubuntu\\home\\user\\.codex\\sessions",
        ])
        XCTAssertNil(WindowsUsageFile.pathPrefixes("\\\\wsl.localhost\\Ubuntu\\home\\..\\etc"))
        XCTAssertNil(WindowsUsageFile.pathPrefixes("\\\\.\\PIPE\\unsafe"))
    }

    func testBoundedRegularFileReadAndMissingMetadata() throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("normal.jsonl")
        try Data("12345".utf8).write(to: file)
        XCTAssertFalse(WindowsUsageFile.isUnsafe(file))
        XCTAssertEqual(WindowsUsageFile.read(file, maxBytes: 5), Data("12345".utf8))
        XCTAssertNil(WindowsUsageFile.read(file, maxBytes: 4))
        XCTAssertNil(WindowsUsageFile.read(root))
        let missing = root.appendingPathComponent("missing.jsonl")
        XCTAssertTrue(WindowsUsageFile.isUnsafe(missing))
        XCTAssertNil(WindowsUsageFile.read(missing))
    }

    func testJunctionRootAncestorsAndRecursiveScanAreRejected() async throws {
        let root = try temporaryDirectory()
        let logs = root.appendingPathComponent("logs", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        let sessions = outside.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let sample = Data("""
        {"type":"assistant","timestamp":"2026-09-11T00:00:00Z","requestId":"r1","message":{"id":"m1","model":"claude","usage":{"input_tokens":1}}}
        """.utf8)
        let normal = logs.appendingPathComponent("normal.jsonl")
        try sample.write(to: normal)
        try sample.write(to: sessions.appendingPathComponent("outside.jsonl"))
        try FileManager.default.createDirectory(at: logs.appendingPathComponent("directory.jsonl"), withIntermediateDirectories: true)
        let junction = logs.appendingPathComponent("redirect", isDirectory: true)
        let result = try powerShell("New-Item -ItemType Junction -Path \(psLiteral(junction.path)) -Target \(psLiteral(outside.path)) | Out-Null")
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(WindowsUsageFile.isUnsafe(junction))
        let redirectedRoot = junction.appendingPathComponent("sessions", isDirectory: true)
        XCTAssertTrue(WindowsUsageFile.isUnsafe(redirectedRoot))
        XCTAssertNil(WindowsUsageFile.read(redirectedRoot.appendingPathComponent("outside.jsonl")))
        XCTAssertEqual(LocalUsageReader.jsonlFiles(in: logs, modifiedSince: .distantPast).map(\.lastPathComponent), ["normal.jsonl"])
        XCTAssertTrue(LocalUsageReader.jsonlFiles(in: redirectedRoot, modifiedSince: .distantPast).isEmpty)
        XCTAssertEqual(LocalUsageReader.claudeEntries(modifiedSince: .distantPast, root: logs).count, 1)
        let cache = LocalUsageCache(claudeRoot: redirectedRoot,
                                    fileURL: root.appendingPathComponent("test-cache.json"))
        let cached = await cache.claudeEntries(modifiedSince: .distantPast)
        XCTAssertTrue(cached.isEmpty)
    }

    func testSymbolicLinkFileIsRejectedWhenSupported() throws {
        let root = try temporaryDirectory()
        let target = root.appendingPathComponent("target.jsonl")
        let link = root.appendingPathComponent("link.jsonl")
        try Data("not a log".utf8).write(to: target)
        let linkPath = Array(link.path.utf16) + [0]
        let targetPath = Array(target.path.utf16) + [0]
        let created = linkPath.withUnsafeBufferPointer { l in
            targetPath.withUnsafeBufferPointer { t in CreateSymbolicLinkW(l.baseAddress, t.baseAddress, 0x2) }
        }
        if created == 0 {
            let code = GetLastError()
            if code == DWORD(ERROR_PRIVILEGE_NOT_HELD) { throw XCTSkip("Runner does not allow unprivileged file symlinks") }
            XCTFail("CreateSymbolicLinkW failed: \(code)")
            return
        }
        XCTAssertTrue(WindowsUsageFile.isUnsafe(link))
        XCTAssertNil(WindowsUsageFile.read(link))
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("poketokenbar-security-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func psLiteral(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }

    private func powerShell(_ script: String, timeout: Double = 8, maxOutputBytes: Int = 64 * 1024) throws -> WindowsProcess.CaptureResult {
        let directory = try XCTUnwrap(WindowsProcess.systemExecutable("WindowsPowerShell"))
        let encoded = try XCTUnwrap(script.data(using: .utf16LittleEndian)).base64EncodedString()
        return WindowsProcess.capture(executable: directory + "\\v1.0\\powershell.exe",
                                      arguments: ["-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded],
                                      timeout: timeout, maxOutputBytes: maxOutputBytes)
    }
}
#endif
