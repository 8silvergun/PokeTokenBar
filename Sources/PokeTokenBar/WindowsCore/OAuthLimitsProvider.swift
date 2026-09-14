import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLSession/URLRequest live here on non-Darwin (Windows/Linux)
#endif
#if os(macOS)
import Security
#endif

enum LimitsError: Error {
    case keychainAccessDisabled
    #if os(macOS)
    case keychainUnavailable(OSStatus)
    #endif
    case keychainInteractionNotAllowed
    case credentialFormat
    /// 사용할 수 있는 자격증명 소스가 없음(예: 비-macOS 에서 `.credentials.json` 부재 — 키체인 폴백 없음).
    case credentialUnavailable
    case httpStatus(Int)
    /// 429 — 서버가 지정한 Retry-After(초, 없으면 nil). 폴링 백오프 판단에 사용.
    case rateLimited(retryAfter: TimeInterval?)
}

/// Claude 한도 조회 추상화 — 실 구현(OAuthLimitsProvider) 또는 테스트 스텁 주입.
protocol ClaudeLimitsProviding: Sendable {
    func fetch(allowKeychainPrompt: Bool) async throws -> LimitStatus
}

/// 공식 한도 % 조회 — Claude Code 자격증명의 OAuth 토큰으로 usage endpoint 호출.
/// 토큰 소스: `~/.claude/.credentials.json`(크로스플랫폼) → macOS 한정 Keychain 폴백.
/// Windows 에서 WSL 배포판을 선택한 경우 그 Linux HOME 의 Claude 자격증명을 우선 사용한다.
/// 비공식 endpoint 이므로 실패해도 토큰 표시에는 영향 없음 (한도 섹션만 숨김).
struct OAuthLimitsProvider: ClaudeLimitsProviding, Sendable {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let accessTokenCache = OAuthAccessTokenCache.shared

    func fetch(allowKeychainPrompt: Bool = false) async throws -> LimitStatus {
        let token = try await accessTokenCache.accessToken(allowKeychainPrompt: allowKeychainPrompt)
        var status: LimitStatus
        do {
            status = try await fetchStatus(accessToken: token)
        } catch let error as LimitsError {
            guard case .httpStatus(let httpStatus) = error, httpStatus == 401 || httpStatus == 403 else {
                throw error
            }
            await accessTokenCache.invalidate(removePersistentCache: true)
            let refreshed = try await accessTokenCache.accessToken(
                allowKeychainPrompt: allowKeychainPrompt, bypassCache: true)
            guard refreshed != token else { throw error }
            status = try await fetchStatus(accessToken: refreshed)
        }
        // 플랜은 usage 응답이 아니라 방금 읽은 자격증명(캐시)에 담겨 있다 — 추가 Keychain 접근 없음.
        let plan = await accessTokenCache.planInfo()
        status.subscriptionType = plan.subscriptionType
        status.rateLimitTier = plan.rateLimitTier
        return status
    }

    private func fetchStatus(accessToken: String) async throws -> LimitStatus {
        var request = URLRequest(url: Self.usageURL, timeoutInterval: 15)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            if http.statusCode == 429 {
                throw LimitsError.rateLimited(retryAfter: Self.retryAfterSeconds(http))
            }
            throw LimitsError.httpStatus(http.statusCode)
        }
        return try Self.decodeStatus(data)
    }

    /// Anthropic usage 응답은 계정/배포 시점에 따라 레거시 `five_hour`/`seven_day`와
    /// 신형 `limits[]`(`session`/`weekly_all`) 중 한쪽만 채워질 수 있다. Windows 트레이는
    /// 두 대표 창을 고정 행으로 표시하므로 신형 응답도 같은 내부 필드로 정규화한다.
    static func decodeStatus(_ data: Data) throws -> LimitStatus {
        var status = try JSONDecoder().decode(LimitStatus.self, from: data)
        if status.fiveHour == nil,
           let entry = status.limits?.first(where: { $0.kind == "session" && $0.isActive != false }),
           let percent = entry.percent {
            status.fiveHour = LimitWindow(utilization: percent, resetsAt: entry.resetsAt)
        }
        if status.sevenDay == nil,
           let entry = status.limits?.first(where: { $0.kind == "weekly_all" && $0.isActive != false }),
           let percent = entry.percent {
            status.sevenDay = LimitWindow(utilization: percent, resetsAt: entry.resetsAt)
        }
        return status
    }

    /// Retry-After 헤더(초 형식만) 파싱 — HTTP-date 형식·비정상 값은 nil(백오프 기본값 사용).
    /// 서버가 과도한 값을 줘도 1시간으로 캡.
    static func retryAfterSeconds(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)),
              seconds > 0 else { return nil }
        return min(seconds, 3600)
    }
}

private actor OAuthAccessTokenCache {
    static let shared = OAuthAccessTokenCache()
    private var cachedCredential: OAuthCredentialData.Credential?

    func accessToken(allowKeychainPrompt: Bool, bypassCache: Bool = false) throws -> String {
        if !bypassCache, let cachedCredential, !cachedCredential.isExpired {
            return cachedCredential.accessToken
        }

        // 파일 크리덴셜 — 키체인 무관, 프롬프트 없음, 크로스플랫폼.
        // Windows 에서는 사용량 스캐너와 동일하게 '선택된 WSL HOME'을 먼저 본다. Claude Code를
        // WSL에서 쓰는데 Windows 사용자 홈만 보면 토큰 사용량은 잡히면서 공식 5h/주간만 항상 `—`가 된다.
        if let credential = try Self.readClaudeCredentialsFile() {
            cachedCredential = credential
            return credential.accessToken
        }

        #if os(macOS)
        // 자동(타이머) 경로는 Claude Keychain 을 일절 읽지 않는다. no-UI 쿼리(kSecUseAuthenticationUIFail
        // /LAContext)로도 잠긴·미승인 login 키체인의 '암호 입력' 다이얼로그는 억제되지 않는다 —
        // 실측: 캐시 만료 폴 도중 SecItemCopyMatching 이 13초간 블록하며 팝업을 띄웠다(하루 몇 회).
        // → Keychain 읽기는 명시적 사용자 동작(설정/팝오버의 갱신 버튼, allowKeychainPrompt=true)에서만
        // 수행한다. 캐시된 토큰이 살아있는 동안은 자동 폴링이 그 토큰으로 계속 한도를 갱신하고, 만료되면
        // 한도는 마지막 값으로 stale 표시된 뒤 사용자가 갱신을 누를 때 재취득된다.
        guard allowKeychainPrompt else {
            throw LimitsError.keychainInteractionNotAllowed
        }

        // 사용자 동작 경로: 무프롬프트로 먼저 시도(과거 '항상 허용'했다면 조용히 성공), 안 되면 프롬프트를
        // 동반해 읽어 최초 1회 '항상 허용'을 유도한다.
        if let credential = Self.readClaudeKeychainSilently() {
            cachedCredential = credential
            return credential.accessToken
        }
        let credential = try Self.readClaudeKeychain(allowKeychainPrompt: true)
        cachedCredential = credential
        return credential.accessToken
        #else
        // Windows/Linux: 키체인 폴백 없음 — 파일이 유일한 소스다.
        throw LimitsError.credentialUnavailable
        #endif
    }

    /// 마지막으로 사용한 자격증명의 플랜 정보. accessToken() 이 모든 경로에서 cachedCredential 을
    /// 반환 토큰과 일치시키므로, fetch 가 토큰 취득 직후 호출하면 동일 자격증명 기준이다.
    func planInfo() -> (subscriptionType: String?, rateLimitTier: String?) {
        (cachedCredential?.subscriptionType, cachedCredential?.rateLimitTier)
    }

    func invalidate(removePersistentCache: Bool = false) {
        // 앱 자체 키체인 캐시는 코드서명이 바뀔 때마다(재빌드·실사용자 매 업그레이드) 항목 ACL 이
        // 안 맞아 write/삭제 시 접근 허용 프롬프트를 유발했다(no-UI 로도 억제 안 됨) → 제거.
        // 토큰은 Claude 키체인 무UI 읽기/.credentials.json 로 조용히 재취득한다. 인메모리만 비운다.
        cachedCredential = nil
    }

    private nonisolated static func readClaudeCredentialsFile() throws -> OAuthCredentialData.Credential? {
        #if os(Windows)
        // WSL 사용량을 선택한 경우 자격증명도 같은 Linux HOME 기준으로 맞춘다. WSL UNC 는
        // Foundation Data(contentsOf:)가 빈 결과/실패를 낼 수 있어 사용량 스캐너에서 검증된 Win32
        // same-handle reader를 재사용한다. 자격증명 파일은 비정상 대용량을 읽지 않도록 1 MiB 상한.
        if let wslHome = WSLUsage.configuredBaseRoot {
            let wslURL = wslHome.appendingPathComponent(".claude/.credentials.json")
            if let data = WindowsUsageFile.read(wslURL, maxBytes: 1024 * 1024),
               let credential = OAuthCredentialData.credential(from: data), !credential.isExpired {
                return credential
            }
        }
        #endif

        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let credential = OAuthCredentialData.credential(from: data), !credential.isExpired else {
            return nil
        }
        return credential
    }

    #if os(macOS)
    /// 무프롬프트 Keychain 읽기 — no-UI 쿼리라 권한이 없으면 프롬프트 대신 errSecInteractionNotAllowed.
    /// '아직 항상 허용 전'(interactionNotAllowed)은 정상 흐름이라 조용히 nil. 그 외(형식 오류·접근 불가)는
    /// 진단을 위해 로그를 남기고 nil — 자동 경로가 왜 토큰을 못 구했는지 추적 가능하게.
    private nonisolated static func readClaudeKeychainSilently() -> OAuthCredentialData.Credential? {
        do {
            return try readClaudeKeychain(allowKeychainPrompt: false)
        } catch LimitsError.keychainInteractionNotAllowed {
            return nil
        } catch {
            AppLog.write("silent claude keychain read failed: \(error)")
            return nil
        }
    }

    private nonisolated static func readClaudeKeychain(
        allowKeychainPrompt: Bool) throws -> OAuthCredentialData.Credential
    {
        if KeychainAccessGate.isDisabled {
            throw LimitsError.keychainAccessDisabled
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: OAuthCredentialData.claudeKeychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if !allowKeychainPrompt {
            KeychainNoUIQuery.apply(to: &query)
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecInteractionNotAllowed {
            throw LimitsError.keychainInteractionNotAllowed
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw LimitsError.keychainUnavailable(status)
        }
        guard let credential = OAuthCredentialData.credential(from: data) else {
            throw LimitsError.credentialFormat
        }
        return credential
    }
    #endif
}

enum OAuthCredentialData {
    static let claudeKeychainService = "Claude Code-credentials"

    struct Credential {
        let accessToken: String
        let expiresAt: Date?
        let data: Data
        /// 구독 등급(max/pro/free)과 rate limit 티어(default_claude_max_20x 등) — 플랜 표시용.
        let subscriptionType: String?
        let rateLimitTier: String?

        var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt <= Date().addingTimeInterval(60)
        }
    }

    static func credential(from data: Data) -> Credential? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = json["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String, !token.isEmpty
        else {
            return nil
        }
        return Credential(
            accessToken: token,
            expiresAt: expiresAt(from: oauth["expiresAt"]),
            data: data,
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String)
    }

    private static func expiresAt(from raw: Any?) -> Date? {
        let value: Double?
        switch raw {
        case let raw as Double:
            value = raw
        case let raw as Int:
            value = Double(raw)
        case let raw as Int64:
            value = Double(raw)
        case let raw as String:
            value = Double(raw)
        default:
            value = nil
        }
        guard let value, value > 0 else { return nil }
        let seconds = value > 10_000_000_000 ? value / 1000 : value
        return Date(timeIntervalSince1970: seconds)
    }
}
