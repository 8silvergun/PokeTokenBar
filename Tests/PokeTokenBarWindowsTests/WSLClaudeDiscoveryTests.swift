#if os(Windows)
import Foundation
import XCTest
@testable import PokeTokenBar

final class WSLClaudeDiscoveryTests: XCTestCase {
    func testNativeDiscoveryFindsClaudeJSONLRecursively() throws {
        let root = try temporaryDirectory()
        let project = root.appendingPathComponent("project", isDirectory: true)
        let nested = project.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let log = nested.appendingPathComponent("session.jsonl")
        let metadata = nested.appendingPathComponent("session.json")
        let ignored = nested.appendingPathComponent("notes.txt")
        let sample = Data("""
        {"type":"assistant","timestamp":"2026-09-14T00:00:00Z","requestId":"r1","message":{"id":"m1","model":"claude-sonnet-4-5","usage":{"input_tokens":12,"output_tokens":3,"cache_creation_input_tokens":4,"cache_read_input_tokens":5}}}
        """.utf8)
        try sample.write(to: log)
        try Data("{}".utf8).write(to: metadata)
        try Data("ignored".utf8).write(to: ignored)

        let files = WindowsUsageFile.nativeJSONLFiles(in: root, modifiedSince: .distantPast)
        XCTAssertEqual(files.map { $0.url.lastPathComponent }, ["session.jsonl"])
        XCTAssertEqual(files.first?.size, sample.count)

        let fmt = LocalUsageReader.localDayFormatter()
        let entries = try XCTUnwrap(files.first).url
        let parsed = LocalUsageReader.parseClaudeFile(entries, fmt: fmt)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.input, 12)
        XCTAssertEqual(parsed.first?.output, 3)
        XCTAssertEqual(parsed.first?.cacheWrite, 4)
        XCTAssertEqual(parsed.first?.cacheRead, 5)
    }

    func testNativeDiscoveryHonorsModificationWindow() throws {
        let root = try temporaryDirectory()
        let log = root.appendingPathComponent("old.jsonl")
        try Data("{}".utf8).write(to: log)
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: log.path)

        XCTAssertEqual(WindowsUsageFile.nativeJSONLFiles(in: root, modifiedSince: old.addingTimeInterval(-1)).count, 1)
        XCTAssertTrue(WindowsUsageFile.nativeJSONLFiles(in: root, modifiedSince: old.addingTimeInterval(1)).isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("poketokenbar-claude-wsl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
#endif
