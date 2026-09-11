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
        guard let output = runWSL(["--list", "--quiet"], allowUTF16: true) else { return }
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
        guard isSafeLinuxHomePath(linuxHome), isSafeDistributionName(distribution) else {
            return nil
        }
        let windowsHome = linuxHome.replacingOccurrences(of: "/", with: "\\")
        return "\\\\wsl.localhost\\\(distribution)\(windowsHome)"
    }

    /// Resolve the actual Linux `$HOME`; it is not safe to assume `/home/<name>` because
    /// a distro may use a custom user, root, or a nonstandard home directory.
    private static func linuxHome(for distribution: String) -> String? {
        guard let output = runWSL([
            "--distribution", distribution,
            "--exec", "/usr/bin/printenv", "HOME",
        ]) else { return nil }
        // Remove only printenv's single record terminator, not arbitrary whitespace
        // supplied as part of HOME (which could conceal a malformed path).
        var home = output
        if home.hasSuffix("\r\n") { home.removeLast(2) }
        else if home.hasSuffix("\n") { home.removeLast() }
        return isSafeLinuxHomePath(home) ? home : nil
    }

    private static func isSafeLinuxHomePath(_ path: String) -> Bool {
        if path == "/" { return true }  // valid root user's custom HOME
        guard path.hasPrefix("/"), path.utf16.count < 32700 else { return false }
        return path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { isSafePathComponent(String($0)) }
    }

    static func isSafeDistributionName(_ value: String) -> Bool {
        !value.hasPrefix("-") && value.utf16.count <= 255 && isSafePathComponent(value)
    }

    /// Linux permits names that Win32 aliases or interprets specially. Reject those
    /// rather than silently reading a different path through the UNC projection.
    static func isSafePathComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != "..",
              !value.hasSuffix("."), !value.hasSuffix(" "),
              !value.contains(where: { "<>:\"/\\|?*".contains($0) }),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
        let stem = value.split(separator: ".", omittingEmptySubsequences: false)[0].uppercased()
        let devices = ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"]
        if devices.contains(stem) { return false }
        if (stem.hasPrefix("COM") || stem.hasPrefix("LPT")), stem.count == 4,
           let last = stem.last, "123456789¹²³".contains(last) { return false }
        return true
    }

    private static func runWSL(_ arguments: [String], allowUTF16: Bool = false) -> String? {
        guard let executable = WindowsProcess.systemExecutable("wsl.exe") else { return nil }
        let result = WindowsProcess.capture(executable: executable, arguments: arguments)
        guard result.failure == nil, result.exitCode == 0, !result.stdout.isEmpty else { return nil }
        return decodeProcessOutput(result.stdout, allowUTF16: allowUTF16)
    }

    /// WSL's distro list may be UTF-16LE; the Linux printenv stream must be UTF-8.
    /// Never delete embedded NULs to turn invalid control data into an accepted path.
    static func decodeProcessOutput(_ data: Data, allowUTF16: Bool = false) -> String? {
        var decoded: String?
        if allowUTF16, data.starts(with: [0xFF, 0xFE]) {
            decoded = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        } else if allowUTF16, data.starts(with: [0xFE, 0xFF]) {
            decoded = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        } else if allowUTF16, data.contains(0), data.count.isMultiple(of: 2) {
            decoded = String(data: data, encoding: .utf16LittleEndian)
        } else {
            decoded = String(data: data, encoding: .utf8)
        }
        guard var value = decoded, !value.contains("\0") else { return nil }
        if value.first == "\u{FEFF}" { value.removeFirst() }
        return value
    }
}
#endif
