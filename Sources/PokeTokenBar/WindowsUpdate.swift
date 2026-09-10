#if os(Windows)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession/URLRequest live here on Windows
#endif
import WinSDK

/// Windows update check — the counterpart to the macOS `UpdateChecker`.
///
/// macOS installs via Homebrew, so its checker can run `brew upgrade`. Windows has no brew:
/// this detects a newer public GitHub release and, on "apply", downloads and runs the installer,
/// falling back to opening the release page in the browser if the download can't complete.
///
/// `normalize` accepts `v<semver>` / `win-<semver>` / bare `<semver>` tags interchangeably.
enum WindowsUpdate {
    /// Baked build version (Windows has no Info.plist bundle to read `CFBundleShortVersionString`).
    /// Compared against the latest release tag; bump it alongside each Windows release.
    static let currentVersion = "2.4.5"

    /// Windows builds are distributed by this fork. Do not silently cross the trust boundary back to
    /// upstream: whoever controls this repository's releases controls the bytes offered as updates.
    static let repo = "8silvergun/PokeTokenBar"

    /// Authenticode certificate thumbprint trusted for unattended installer execution.
    ///
    /// SECURITY: keep this empty until the Windows release binary is signed with a real code-signing
    /// certificate. `WindowsProcess` fails closed for the detached updater when this value is empty,
    /// so the UI falls back to the GitHub release page instead of executing an unverified download.
    /// The thumbprint is public certificate metadata, not a secret. After obtaining the certificate,
    /// paste its uppercase SHA-1 thumbprint here and sign every Windows release with that certificate.
    static let trustedInstallerSignerThumbprint = ""

    struct Available: Sendable, Equatable {
        let version: String
        let url: String
        let installerURL: String
    }

    /// Query the latest release; return it only when strictly newer than `currentVersion`.
    /// Returns nil when up to date, when the exact Windows installer asset is absent, or on any
    /// network/parse failure. Requiring an exact asset name prevents a broad wildcard from selecting
    /// an unintended executable if additional release assets are added later.
    static func check() async -> Available? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("PokeTokenBar-Windows", forHTTPHeaderField: "User-Agent")   // GitHub API requires a UA
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return available(fromReleaseJSON: data)
    }

    /// Parse and validate GitHub's release response. Kept pure so trust-boundary checks can be unit tested.
    static func available(fromReleaseJSON data: Data) -> Available? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let html = json["html_url"] as? String,
              let htmlURL = URL(string: html),
              htmlURL.scheme?.lowercased() == "https", htmlURL.host?.lowercased() == "github.com",
              htmlURL.path.hasPrefix("/\(repo)/releases/")
        else { return nil }

        let latest = normalize(tag)
        guard latest.range(of: #"^\d+\.\d+\.\d+(?:\.\d+)?$"#, options: .regularExpression) != nil,
              isNewer(latest, than: currentVersion) else { return nil }

        // Respect a "Later" (skip) choice — don't resurface a version the user dismissed.
        let skipped = UserDefaults.standard.string(forKey: "skippedUpdateVersion")
        guard latest != skipped else { return nil }

        let expectedName = "PokeTokenBar-Setup-\(latest).exe"
        guard let assets = json["assets"] as? [[String: Any]],
              let asset = assets.first(where: { ($0["name"] as? String) == expectedName }),
              let download = asset["browser_download_url"] as? String,
              trustedInstallerAssetURL(download, tag: tag, expectedName: expectedName) != nil
        else { return nil }

        return Available(version: latest, url: html, installerURL: download)
    }

    /// Only accept the exact installer asset under this fork's GitHub release-download namespace.
    /// Redirects to GitHub's CDN are handled by URLSession later, but the release metadata itself must
    /// point at github.com/8silvergun/PokeTokenBar/releases/download/<tag>/<exact-name>.
    static func trustedInstallerAssetURL(_ raw: String, tag: String, expectedName: String) -> URL? {
        guard let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com",
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              url.query == nil, url.fragment == nil else { return nil }
        let expectedPath = "/\(repo)/releases/download/\(tag)/\(expectedName)"
        guard url.path == expectedPath else { return nil }
        return url
    }

    /// Open the release page in the default browser (manual download — no brew on Windows).
    static func openReleasePage(_ urlString: String) {
        guard let url = URL(string: urlString), url.scheme == "https", url.host == "github.com",
              url.path.hasPrefix("/\(repo)/releases/") else { return }
        _ = urlString.withCString(encodedAs: UTF16.self) { p in
            ShellExecuteW(nil, nil, p, nil, nil, 1)   // SW_SHOWNORMAL
        }
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
