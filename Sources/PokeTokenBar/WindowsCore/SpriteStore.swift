import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession lives here on non-Darwin (Windows/Linux)
#endif

/// 포켓몬 스프라이트를 런타임에 받아 로컬(Application Support)에 캐시. 레포/번들에 미포함.
///
/// 순수 Foundation(URLSession + 파일 캐시) — macOS 메뉴바와 Windows 트레이/팝오버가 공유한다.
/// 이미지 디코딩(NSImage / WIC HICON)은 각 플랫폼 코드가 담당하고, 이 액터는 바이트만 다룬다.
actor SpriteStore {
    static let shared = SpriteStore()
    private let base = "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon"
    private let itemBase = "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/items"
    private var mem: [String: Data] = [:]
    private var memOrder: [String] = []   // LRU 순서(최근 접근이 뒤). 상한 초과 시 앞(오래된 것)부터 evict
    private let memLimit = 24              // in-memory 스프라이트 캐시 상한 — 세션 중 종 변경 누적 무한증가 방지(#H1)
    // A failed remote sprite should not be retried several times in the same refresh (static/Home/GIF)
    // or on every polling tick. This is especially important on Windows, where a TLS failure used to
    // keep the serialized refresh occupied after every evolution cache miss.
    private var retryAfter: [String: Date] = [:]
    private let retryBackoff: TimeInterval = 30
    /// Remote sprites are tiny in normal operation. Reject unexpectedly large payloads before they
    /// reach WIC or the cache, limiting memory/disk amplification from compromised remote content.
    static let maxPayloadBytes = 8 * 1024 * 1024
    private let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PokeTokenBar/sprites")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// 캐시 파일명 키 — 기존 "\(id)-a"/"\(id)-s" 유지, shiny 는 "sh" 접두(구캐시 그대로 유효).
    static func cacheKey(speciesID: Int, animated: Bool, shiny: Bool) -> String {
        "\(speciesID)-\(shiny ? "sh" : "")\(animated ? "a" : "s")"
    }

    func data(speciesID: Int, animated: Bool, shiny: Bool = false) async -> Data? {
        let key = Self.cacheKey(speciesID: speciesID, animated: animated, shiny: shiny)
        if let d = mem[key] { touch(key); return d }
        let ext = animated ? "gif" : "png"
        let file = dir.appendingPathComponent("\(key).\(ext)")
        if let d = cachedData(at: file) { remember(key, d); return d }
        let urlStr: String
        switch (animated, shiny) {
        case (true, false):  urlStr = "\(base)/versions/generation-v/black-white/animated/\(speciesID).gif"
        case (true, true):   urlStr = "\(base)/versions/generation-v/black-white/animated/shiny/\(speciesID).gif"
        case (false, false): urlStr = "\(base)/\(speciesID).png"
        case (false, true):  urlStr = "\(base)/shiny/\(speciesID).png"
        }
        guard let url = URL(string: urlStr),
              let d = await remoteData(url, cacheKey: key) else { return nil }
        try? d.write(to: file, options: .atomic)   // torn write 방지 — 크래시/강제종료 시 손상 캐시가 남지 않게
        remember(key, d)
        return d
    }

    /// 아이템 스프라이트(정적 PNG, 이름 기반). 포켓몬과 같은 메모리/디스크 캐시 사용(키 "item-<name>",
    /// 포켓몬 파일 "<id>-..." 과 안 겹침). 미제공(404)/오프라인이면 nil → 뷰가 이모지로 폴백.
    func data(itemName: String) async -> Data? {
        let key = "item-\(itemName)"
        if let d = mem[key] { touch(key); return d }
        let file = dir.appendingPathComponent("\(key).png")
        if let d = cachedData(at: file) { remember(key, d); return d }
        guard let url = URL(string: "\(itemBase)/\(itemName).png"),
              let d = await remoteData(url, cacheKey: key) else { return nil }
        try? d.write(to: file, options: .atomic)
        remember(key, d)
        return d
    }

    /// 알 스프라이트(정적, pokemon/egg.png) — 애니메이션 알은 없음. 포켓몬/아이템과 같은 메모리·디스크 캐시(키 "egg").
    func eggData() async -> Data? {
        let key = "egg"
        if let d = mem[key] { touch(key); return d }
        let file = dir.appendingPathComponent("egg.png")
        if let d = cachedData(at: file) { remember(key, d); return d }
        guard let url = URL(string: "\(base)/egg.png"),
              let d = await remoteData(url, cacheKey: key) else { return nil }
        try? d.write(to: file, options: .atomic)
        remember(key, d)
        return d
    }

    /// 컬러 이모지 이미지(Noto Emoji PNG, Apache-2.0/OFL) — 런타임 fetch·캐시(키 "noto-<name>").
    /// Windows GDI 는 컬러 이모지를 못 그려(단색 글리프) 스프라이트 없는 아이템(예: 민트 🌿)을 이 이미지로
    /// 그린다. macOS 는 네이티브 컬러 이모지 폰트를 쓰므로 호출하지 않는다. 미제공/오프라인이면 nil.
    func emojiData(_ emoji: String) async -> Data? {
        // Noto 파일명: 코드포인트(소문자 hex)를 "_"로 join, 변이 선택자(FE0F)는 제외. 예: 🌿 → emoji_u1f33f.
        let cps = emoji.unicodeScalars.filter { $0.value != 0xFE0F }.map { String($0.value, radix: 16) }
        guard !cps.isEmpty else { return nil }
        let name = "emoji_u" + cps.joined(separator: "_")
        let key = "noto-\(name)"
        if let d = mem[key] { touch(key); return d }
        let file = dir.appendingPathComponent("\(key).png")
        if let d = cachedData(at: file) { remember(key, d); return d }
        guard let url = URL(string: "https://raw.githubusercontent.com/googlefonts/noto-emoji/main/png/128/\(name).png"),
              let d = await remoteData(url, cacheKey: key) else { return nil }
        try? d.write(to: file, options: .atomic)
        remember(key, d)
        return d
    }

    /// Remote image trust boundary. Item names/species IDs eventually become URL path components,
    /// so keep the Windows curl fallback locked to the two repositories this store intentionally uses.
    nonisolated static func isAllowedRemoteURL(_ url: URL) -> Bool {
        guard url.scheme == "https",
              url.host == "raw.githubusercontent.com",
              url.port == nil || url.port == 443,
              url.user == nil, url.password == nil else { return false }
        return url.path.hasPrefix("/PokeAPI/sprites/master/sprites/")
            || url.path.hasPrefix("/googlefonts/noto-emoji/main/png/128/")
    }

    private func remoteData(_ url: URL, cacheKey key: String) async -> Data? {
        if let until = retryAfter[key], until > Date() { return nil }
        guard Self.isAllowedRemoteURL(url) else {
            retryAfter[key] = Date().addingTimeInterval(retryBackoff)
            return nil
        }

        #if os(Windows)
        // Windows FoundationNetworking uses libcurl+Schannel and has already shown the same
        // CRYPT_E_NO_REVOCATION_CHECK / non-returning HTTPS behavior on PokéAPI. A species change is
        // normally the first time a new sprite hits the network, so use the inbox curl.exe with the
        // same best-effort revocation policy as WindowsCore/PokeAPIClient and hard deadlines.
        guard let curl = WindowsProcess.systemExecutable("curl.exe") else {
            retryAfter[key] = Date().addingTimeInterval(retryBackoff)
            return nil
        }
        let tmp = dir.appendingPathComponent(".download-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let result = WindowsProcess.capture(
            executable: curl,
            arguments: [
                "--silent", "--show-error", "--fail", "--location",
                "--proto", "=https", "--proto-redir", "=https",
                "--connect-timeout", "3", "--max-time", "8",
                "--ssl-revoke-best-effort",
                "--max-filesize", String(Self.maxPayloadBytes),
                "--output", tmp.path,
                url.absoluteString
            ],
            timeout: 10,
            maxOutputBytes: 64 * 1024)
        guard result.failure == nil, result.exitCode == 0,
              let data = cachedData(at: tmp) else {
            retryAfter[key] = Date().addingTimeInterval(retryBackoff)
            AppLog.write("sprite curl failed key=\(key) path=\(url.path) exit=\(result.exitCode.map(String.init) ?? "nil") failure=\(String(describing: result.failure))")
            return nil
        }
        retryAfter.removeValue(forKey: key)
        return data
        #else
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              accepted(data, response: response) else {
            retryAfter[key] = Date().addingTimeInterval(retryBackoff)
            return nil
        }
        retryAfter.removeValue(forKey: key)
        return data
        #endif
    }

    private func accepted(_ data: Data, response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              !data.isEmpty,
              data.count <= Self.maxPayloadBytes else { return false }
        let expected = response.expectedContentLength
        return expected < 0 || expected <= Int64(Self.maxPayloadBytes)
    }

    /// Do not trust a previously cached file merely because it exists. An oversized/corrupted cache
    /// must not bypass the same byte limit applied to fresh network responses.
    private func cachedData(at file: URL) -> Data? {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           let size = attrs[.size] as? NSNumber,
           size.int64Value > Int64(Self.maxPayloadBytes) {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        guard let data = try? Data(contentsOf: file),
              !data.isEmpty,
              data.count <= Self.maxPayloadBytes else { return nil }
        return data
    }

    /// in-memory 캐시에 넣고 LRU 상한 유지(#H1) — 세션 중 종이 여러 번 바뀌어도 무한 성장 방지.
    private func remember(_ key: String, _ data: Data) {
        mem[key] = data
        touch(key)
        while memOrder.count > memLimit {
            let old = memOrder.removeFirst()
            mem.removeValue(forKey: old)
        }
    }
    /// 접근/삽입 키를 최근(뒤)으로 이동 — 활성 종이 evict 되지 않게 하는 LRU.
    private func touch(_ key: String) {
        if let i = memOrder.firstIndex(of: key) { memOrder.remove(at: i) }
        memOrder.append(key)
    }
}
