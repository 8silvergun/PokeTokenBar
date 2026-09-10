#if os(Windows)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession/URLRequest live here on Windows
#endif
import WinSDK

/// Windows update check — the counterpart to the macOS `UpdateChecker`.
///
/// Automatic installer execution is intentionally disabled until Windows release artifacts are
/// cryptographically verified (SHA-256 manifest + Authenticode signer). This keeps the updater
/// fail-closed instead of executing an unverified downloaded EXE.
///
/// `normalize` accepts `v<semver>` / `win-<semver>` / bare `<semver>` tags interchangeably.
enum WindowsUpdate {
    /// Baked build version (Windows has no Info.plist bundle to read `CFBundleShortVersionString`).
    /// Compared against the latest release tag; bump it alongside each Windows release.
    static let currentVersion = "2.4.5"

    /// Windows releases for this port must come from the fork that builds the Windows artifacts.
    static let repo = "8silvergun/PokeTokenBar"

    /// SECURITY: Do not enable this until downloaded installers are verified before execution.
    /// Required controls: trusted release origin, SHA-256 manifest verification and Authenticode
    /// signer verification. Keeping this false makes the existing installer path unreachable.
    static let automaticInstallerEnabled = false

    struct Available: Sendable, Equatable { let version: String; let url: String }

    /// Query the latest release; return it only when strictly newer than `currentVersion`.
    /// Returns nil while automatic installer updates are disabled, when up to date, or on failure.
    static func check() async -> Available? {
        guard automaticInstallerEnabled else { return nil }
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("PokeTokenBar-Windows", forHTTPHeaderField: "User-Agent")   // GitHub API requires a UA
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let html = json["html_url"] as? String,
              isTrustedReleasePage(html)
        else { return nil }
        let latest = normalize(tag)
        // Respect a "Later" (skip) choice — don't resurface a version the user dismissed.
        let skipped = UserDefaults.standard.string(forKey: "skippedUpdateVersion")
        guard isNewer(latest, than: currentVersion), latest != skipped else { return nil }
        return Available(version: latest, url: html)
    }

    /// Open a trusted release page in the default browser. Validate at the sink as defense in depth;
    /// callers must not be able to turn ShellExecuteW into an arbitrary scheme/host launcher.
    static func openReleasePage(_ urlString: String) {
        guard isTrustedReleasePage(urlString) else { return }
        _ = urlString.withCString(encodedAs: UTF16.self) { p in
            ShellExecuteW(nil, nil, p, nil, nil, 1)   // SW_SHOWNORMAL
        }
    }

    static func isTrustedReleasePage(_ value: String) -> Bool {
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        let expectedPrefix = "/\(repo)/releases/"
        return url.path.hasPrefix(expectedPrefix)
    }

    /// `win-2.4.5` / `v2.4.5` / `2.4.5` → `2.4.5`.
    static func normalize(_ tag: String) -> String {
        var s = Substring(tag)
        if s.hasPrefix("win-") { s = s.dropFirst(4) }
        if s.hasPrefix("v") { s = s.dropFirst() }
        return String(s)
    }

    /// Numeric semver compare — is `a` strictly newer than `b`? ("2.4.10" > "2.4.9").
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
#endif
