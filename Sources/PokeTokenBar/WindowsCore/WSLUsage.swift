#if os(Windows)
import Foundation

/// Resolves the WSL distribution selected by the installer and exposes its Linux home
/// directory through the Windows UNC projection (`\\wsl.localhost\<distro>\...`).
///
/// WSL is deliberately opt-in. A Windows installation can run without WSL, and an
/// unavailable/removed distribution simply contributes no entries instead of making
/// the tray refresh fail.
enum WSLUsage {
    enum Provider: String {
        case claude
        case codex
        case gemini
    }

    static let configurationFileName = "wsl-distro.txt"

    private struct CachedRoot {
        let distribution: String
        let base: URL?
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedRoot: CachedRoot?
    private static let distributionLock = NSLock()
    nonisolated(unsafe) private static var cachedDistributions: [String] = []

    /// The installer writes this under the same Application Support directory used by
    /// the Windows usage cache (`%APPDATA%\\PokeTokenBar\\wsl-distro.txt`).
    static var configurationURL: URL {
        let base = ProcessInfo.processInfo.environment["APPDATA"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("PokeTokenBar")
            .appendingPathComponent(configurationFileName)
    }

    static var selectedDistribution: String? {
        guard let raw = try? String(contentsOf: configurationURL, encoding: .utf8) else { return nil }
        let value = raw.replacingOccurrences(of: "\u{FEFF}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, isSafeDistributionName(value) else { return nil }
        return value
    }

    static var installedDistributions: [String] {
        distributionLock.lock()
        let result = cachedDistributions
        distributionLock.unlock()
        return result
    }

    /// Refreshes the cached distro list off the tray paint path. `wsl.exe` can take
    /// seconds to start when WSL is cold, so this must never run during WM_PAINT.
    static func refreshInstalledDistributions() {
        guard let output = runWSL(["--list", "--quiet"]) else { return }
        let values = output
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { line in
                var value = line
                while value.first == "*" { value.removeFirst(); value = value.trimmingCharacters(in: .whitespaces) }
                return value
            }
            .filter { !$0.isEmpty && !$0.localizedCaseInsensitiveContains("no installed distributions") && isSafeDistributionName($0) }
        distributionLock.lock()
        var unique: [String] = []
        for value in values where !unique.contains(value) { unique.append(value) }
        cachedDistributions = unique
        distributionLock.unlock()
    }

    @discardableResult
    static func setSelectedDistribution(_ distribution: String?) -> Bool {
        let value = distribution?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard value.isEmpty || isSafeDistributionName(value) else { return false }
        do {
            try FileManager.default.createDirectory(at: configurationURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try value.write(to: configurationURL, atomically: true, encoding: .utf8)
            invalidateCache()
            return true
        } catch {
            return false
        }
    }

    /// Returns the WSL log root for one provider. The returned URL is a Windows UNC
    /// path, so Foundation's normal directory enumerator can scan it without copying
    /// logs out of the Linux filesystem.
    static func root(for provider: Provider) -> URL? {
        guard let base = resolvedBaseRoot() else { return nil }
        switch provider {
        case .claude:
            return base.appendingPathComponent(".claude/projects", isDirectory: true)
        case .codex:
            return base.appendingPathComponent(".codex/sessions", isDirectory: true)
        case .gemini:
            return base.appendingPathComponent(".gemini/tmp", isDirectory: true)
        }
    }

    static var configuredBaseRoot: URL? { resolvedBaseRoot() }

    private static func resolvedBaseRoot() -> URL? {
        guard let distribution = selectedDistribution else {
            invalidateCache()
            return nil
        }

        cacheLock.lock()
        if let cachedRoot, cachedRoot.distribution == distribution {
            let value = cachedRoot.base
            cacheLock.unlock()
            return value
        }
        cacheLock.unlock()

        let base = linuxHome(for: distribution).flatMap { makeUNCBase(distribution: distribution, linuxHome: $0) }
        cacheLock.lock()
        cachedRoot = CachedRoot(distribution: distribution, base: base)
        cacheLock.unlock()
        return base
    }

    private static func invalidateCache() {
        cacheLock.lock()
        cachedRoot = nil
        cacheLock.unlock()
    }

    private static func makeUNCBase(distribution: String, linuxHome: String) -> URL? {
        guard let path = uncBasePath(distribution: distribution, linuxHome: linuxHome) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Pure path construction is kept internal so the Windows test target can verify
    /// distro names containing spaces and reject path traversal without requiring WSL.
    static func uncBasePath(distribution: String, linuxHome: String) -> String? {
        let home = linuxHome.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSafeLinuxHomePath(home), isSafeDistributionName(distribution) else {
            return nil
        }
        let windowsHome = home.replacingOccurrences(of: "/", with: "\\")
        return "\\\\wsl.localhost\\\(distribution)\(windowsHome)"
    }

    /// Resolve the actual Linux `$HOME`; it is not safe to assume `/home/<name>` because
    /// a distro may use a custom user, root, or a nonstandard home directory.
    private static func linuxHome(for distribution: String) -> String? {
        guard let output = runWSL([
            "--distribution", distribution,
            "--exec", "/usr/bin/printenv", "HOME",
        ]) else { return nil }
        let home = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return isSafeLinuxHomePath(home) ? home : nil
    }

    private static func isSafeLinuxHomePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains { $0 == "." || $0 == ".." }
    }

    private static func isSafeDistributionName(_ value: String) -> Bool {
        // Names returned by `wsl --list --quiet` may contain spaces, but never path
        // separators. Rejecting separators also prevents a malformed config from
        // escaping the `\\wsl.localhost` UNC host component.
        !value.isEmpty && !value.hasPrefix("-") &&
        !value.contains("/") && !value.contains("\\") && !value.contains("\0") &&
        !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func runWSL(_ arguments: [String]) -> String? {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("poketokenbar-wsl-\(UUID().uuidString).out")
        let errorURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("poketokenbar-wsl-\(UUID().uuidString).err")
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }

        let systemRoot = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
        let executable = "\(systemRoot)\\System32\\wsl.exe"
        let commandLine = ([quote(executable)] + arguments.map(quote)).joined(separator: " ")
        guard let process = WindowsProcess(
            commandLine: commandLine, stdoutPath: outputURL.path, stderrPath: errorURL.path,
            createNewOutputFiles: true),
            process.launched else { return nil }
        process.closeStdin()
        defer { process.cleanup() }
        guard process.waitFor(8), process.exitCode == 0,
              let data = try? Data(contentsOf: outputURL), !data.isEmpty else { return nil }
        return decodeProcessOutput(data)
    }

    /// `wsl.exe` has emitted UTF-16 output on older Windows builds and UTF-8 on newer
    /// builds. Accept both and remove any NUL padding before parsing.
    private static func decodeProcessOutput(_ data: Data) -> String? {
        let decoded = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16LittleEndian)
            ?? String(data: data, encoding: .utf16BigEndian)
        return decoded?.replacingOccurrences(of: "\0", with: "")
    }

    /// Quote one argument for CreateProcess' command-line parser. WSL distro names
    /// commonly contain spaces, so passing an unquoted name would select the wrong distro.
    private static func quote(_ value: String) -> String {
        var escaped = ""
        var backslashes = 0
        for character in value {
            if character == "\\" {
                backslashes += 1
            } else if character == "\"" {
                escaped += String(repeating: "\\", count: backslashes * 2 + 1)
                escaped.append("\"")
                backslashes = 0
            } else {
                if backslashes > 0 {
                    escaped += String(repeating: "\\", count: backslashes)
                    backslashes = 0
                }
                escaped.append(character)
            }
        }
        if backslashes > 0 { escaped += String(repeating: "\\", count: backslashes * 2) }
        return "\"\(escaped)\""
    }
}
#endif
