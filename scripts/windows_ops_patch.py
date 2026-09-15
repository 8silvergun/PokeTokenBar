from pathlib import Path


def rep(s: str, old: str, new: str, label: str, count: int = 1) -> str:
    actual = s.count(old)
    if actual != count:
        raise SystemExit(f"{label}: expected {count} occurrence(s), found {actual}")
    return s.replace(old, new, count)

# --- WindowsUpdate: separate safe availability checks from unverified automatic installer execution.
update_path = Path("Sources/PokeTokenBar/WindowsUpdate.swift")
u = update_path.read_text(encoding="utf-8")
u = rep(
    u,
    '''    /// Query the latest release; return it only when strictly newer than `currentVersion`.
    /// Returns nil while automatic installer updates are disabled, when up to date, or on failure.
    static func check() async -> Available? {
        guard automaticInstallerEnabled else { return nil }
''',
    '''    /// Query the latest release; return it only when strictly newer than `currentVersion`.
    /// Availability checking is safe even while automatic installer execution is disabled: the
    /// UI can surface the trusted GitHub release page without downloading/running an EXE.
    static func check() async -> Available? {
''',
    "WindowsUpdate check gate",
)
update_path.write_text(u, encoding="utf-8")

# --- Provider status: only two endpoints; serialize them on Windows to avoid overlapping URLSession
# work with the tray's other network fetches (a known corelibs stress point in this port).
status_path = Path("Sources/PokeTokenBar/WindowsCore/ProviderStatusChecker.swift")
p = status_path.read_text(encoding="utf-8")
old_fetch = '''    func fetch() async -> [String: ProviderStatus] {
        var out: [String: ProviderStatus] = [:]
        await withTaskGroup(of: (String, ProviderStatus?).self) { group in
            for (id, url) in Self.endpoints {
                group.addTask { (id, await Self.fetchOne(url)) }
            }
            for await (id, status) in group where status != nil {
                out[id] = status
            }
        }
        return out
    }
'''
new_fetch = '''    func fetch() async -> [String: ProviderStatus] {
        var out: [String: ProviderStatus] = [:]
        #if os(Windows)
        // Windows corelibs URLSession has previously been unstable under overlapping companion/status
        // requests in this app. Two status pages every few minutes do not benefit from parallelism.
        for (id, url) in Self.endpoints {
            if let status = await Self.fetchOne(url) { out[id] = status }
        }
        #else
        await withTaskGroup(of: (String, ProviderStatus?).self) { group in
            for (id, url) in Self.endpoints {
                group.addTask { (id, await Self.fetchOne(url)) }
            }
            for await (id, status) in group where status != nil { out[id] = status }
        }
        #endif
        return out
    }
'''
p = rep(p, old_fetch, new_fetch, "ProviderStatus fetch")
status_path.write_text(p, encoding="utf-8")

# --- Windows tray/UI.
tray_path = Path("Sources/PokeTokenBar/WindowsTray.swift")
s = tray_path.read_text(encoding="utf-8")

# Runtime status state.
s = rep(
    s,
    '''    nonisolated(unsafe) private static var lastLimitFetch: Date?   // throttle oauth/usage to ≥25s apart
    nonisolated(unsafe) private static var availableUpdate: WindowsUpdate.Available?   // newer release, if any
''',
    '''    nonisolated(unsafe) private static var lastLimitFetch: Date?   // throttle oauth/usage to ≥25s apart
    nonisolated(unsafe) private static var providerStatuses: [String: ProviderStatus] = [:]
    nonisolated(unsafe) private static var lastStatusFetch: Date?        // statuspage throttle (5 min)
    nonisolated(unsafe) private static var availableUpdate: WindowsUpdate.Available?   // newer release, if any
''',
    "status state",
)
s = rep(
    s,
    '''    nonisolated(unsafe) private static var openDropdown = 0   // Settings: 0=none, 1=language, 2=interval, 3=WSL
''',
    '''    nonisolated(unsafe) private static var openDropdown = 0   // Settings: 0=none, 1=language, 2=interval, 3=WSL, 4=animation
''',
    "dropdown comment",
)

# Use the same animation quality semantics as macOS: 2.5 / 5 / 10 fps caps.
s = rep(
    s,
    '''        applyRefreshInterval()   // usage-refresh timer from the configured interval (default 2 min)
        _ = SetTimer(sinkHwnd, animTimerID, 120, nil)   // sprite animation ~8fps
''',
    '''        applyRefreshInterval()   // usage-refresh timer from the configured interval (default 2 min)
        applyAnimationQuality()        // power saver ≈2.5fps / balanced ≈5fps / smooth ≈10fps
''',
    "animation timer startup",
)

# Provider status fetch after companion/limits state is ready. Missing providers preserve last good status.
s = rep(
    s,
    '''        await companion.grantCandies(from: candyWindows, limitsReady: !candyWindows.isEmpty)
        disp = await companion.windowsDisplay   // inventory may have changed after a reward

        // Codex rate-limit fetch is skipped on Windows: codex 0.145.0's account/rateLimits/read
''',
    '''        await companion.grantCandies(from: candyWindows, limitsReady: !candyWindows.isEmpty)
        disp = await companion.windowsDisplay   // inventory may have changed after a reward

        // Provider incidents are display-only. Fetch at most every five minutes and retain the last
        // good value for an endpoint that temporarily fails, matching macOS UsageStore semantics.
        let statusEnabled = UserDefaults.standard.object(forKey: "statusChecksEnabled") as? Bool ?? true
        if statusEnabled {
            let statusDue = lock.withLock { () -> Bool in
                let due = lastStatusFetch.map { now.timeIntervalSince($0) >= 300 } ?? true
                if due { lastStatusFetch = now }
                return due
            }
            if statusDue {
                let fetched = await StatuspageStatusProvider().fetch()
                lock.withLock {
                    for (id, status) in fetched { providerStatuses[id] = status }
                }
            }
        }

        // Codex rate-limit fetch is skipped on Windows: codex 0.145.0's account/rateLimits/read
''',
    "status refresh",
)

# Current local rolling 5h block, paired with the official Claude 5h limit.
s = rep(
    s,
    '''        us.claudeIn = ct?.inputTokens ?? 0; us.claudeOut = ct?.outputTokens ?? 0
        us.claudeCacheW = ct?.cacheCreationTokens ?? 0; us.claudeCacheR = ct?.cacheReadTokens ?? 0
        us.claude5h = claude5h; us.claude7d = claude7d
''',
    '''        us.claudeIn = ct?.inputTokens ?? 0; us.claudeOut = ct?.outputTokens ?? 0
        us.claudeCacheW = ct?.cacheCreationTokens ?? 0; us.claudeCacheR = ct?.cacheReadTokens ?? 0
        if let block = LocalUsageReader.activeBlock(entries: claude, now: now) {
            us.claudeBlockTokens = block.totalTokens
            us.claudeBlockTPM = block.tokensPerMinute ?? 0
        }
        us.claude5h = claude5h; us.claude7d = claude7d
''',
    "local block snapshot",
)

# Tooltip limit numbers honor used/remaining mode too (without suffix, like macOS menu bar).
s = rep(
    s,
    '''            let lim = [claude5h.map { "5h \\($0)%" }, claude7d.map { "7d \\($0)%" }].compactMap { $0 }
''',
    '''            let lim = [claude5h.map { "5h \\(displayLimitPercent($0))%" },
                       claude7d.map { "7d \\(displayLimitPercent($0))%" }].compactMap { $0 }
''',
    "tooltip limit mode",
)

# Update banner becomes a safe browser link when installer verification is still disabled.
s = rep(
    s,
    '''        drawButton(hdc, get, L("받기", "Get", "取得"), enabled: true, selected: true)
''',
    '''        let getLabel = WindowsUpdate.automaticInstallerEnabled
            ? L("받기", "Get", "取得") : L("열기", "Open", "開く")
        drawButton(hdc, get, getLabel, enabled: true, selected: true)
''',
    "update banner label",
)

# Limit row: display number may be remaining, but risk color + progress bar remain utilization-based.
old_limit = '''    private static func limitRow(_ hdc: HDC?, y: Int32, _ label: String, _ pct: Int?) {
        let lf = makeFont(-15, bold: true); let o = SelectObject(hdc, lf)
        SetTextColor(hdc, rgb(230, 230, 238))
        var lr = RECT(left: 20, top: y, right: 250, bottom: y + 22)
        drawText(label, in: hdc, rect: &lr, format: UINT(DT_LEFT | DT_SINGLELINE))
        let p = pct ?? 0
        let color = p >= 90 ? rgb(232, 96, 96) : (p >= 70 ? rgb(232, 184, 72) : rgb(96, 200, 120))
        SetTextColor(hdc, pct == nil ? rgb(120, 120, 132) : color)
        var pr = RECT(left: popupWidth - 96, top: y, right: popupWidth - 16, bottom: y + 22)
        drawText(pct == nil ? "—" : "\\(p)%", in: hdc, rect: &pr, format: UINT(DT_RIGHT | DT_SINGLELINE))
        SelectObject(hdc, o); DeleteObject(lf)
        drawProgress(hdc, RECT(left: 20, top: y + 26, right: popupWidth - 16, bottom: y + 34), Double(p) / 100.0, color)
    }
'''
new_limit = '''    private static var showsRemainingLimits: Bool {
        UserDefaults.standard.string(forKey: "limitDisplayMode") == "remaining"
    }

    private static func displayLimitPercent(_ used: Int) -> Int {
        showsRemainingLimits ? max(0, 100 - used) : used
    }

    private static func limitRow(_ hdc: HDC?, y: Int32, _ label: String, _ pct: Int?) {
        let lf = makeFont(-15, bold: true); let o = SelectObject(hdc, lf)
        SetTextColor(hdc, rgb(230, 230, 238))
        var lr = RECT(left: 20, top: y, right: 250, bottom: y + 22)
        drawText(label, in: hdc, rect: &lr, format: UINT(DT_LEFT | DT_SINGLELINE))
        let p = pct ?? 0
        let color = p >= 90 ? rgb(232, 96, 96) : (p >= 70 ? rgb(232, 184, 72) : rgb(96, 200, 120))
        SetTextColor(hdc, pct == nil ? rgb(120, 120, 132) : color)
        var pr = RECT(left: popupWidth - 116, top: y, right: popupWidth - 16, bottom: y + 22)
        let pctText: String
        if pct == nil { pctText = "—" }
        else if showsRemainingLimits { pctText = "\\(displayLimitPercent(p))% " + L("남음", "left", "残り") }
        else { pctText = "\\(p)%" }
        drawText(pctText, in: hdc, rect: &pr, format: UINT(DT_RIGHT | DT_SINGLELINE))
        SelectObject(hdc, o); DeleteObject(lf)
        // Color/bar always represent *used* utilization even when the numeric label is remaining.
        drawProgress(hdc, RECT(left: 20, top: y + 26, right: popupWidth - 16, bottom: y + 34), Double(p) / 100.0, color)
    }

    private static func drawProviderStatusBanner(_ hdc: HDC?, y: Int32, providerID: String, name: String) {
        guard UserDefaults.standard.object(forKey: "statusChecksEnabled") as? Bool ?? true,
              let status = lock.withLock({ providerStatuses[providerID] }), status.indicator.hasIssue else { return }
        let label: String
        switch status.indicator {
        case .minor: label = L("일부 장애", "Minor issues", "一部障害")
        case .major: label = L("장애", "Major outage", "障害")
        case .critical: label = L("심각한 장애", "Critical outage", "重大障害")
        case .maintenance: label = L("점검 중", "Maintenance", "メンテナンス")
        case .unknown: label = L("상태 불명", "Status unknown", "状態不明")
        case .operational: return
        }
        let r = RECT(left: 16, top: y, right: popupWidth - 16, bottom: y + 38)
        fillRound(hdc, r, 9, rgb(74, 52, 42))
        let f = makeFont(-12, bold: true); let o = SelectObject(hdc, f)
        SetTextColor(hdc, rgb(246, 190, 130))
        var tr = RECT(left: 26, top: y + 5, right: popupWidth - 24, bottom: y + 22)
        drawText("⚠ \\(name) · \\(label)", in: hdc, rect: &tr, format: UINT(DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS))
        SelectObject(hdc, o); DeleteObject(f)
        if !status.description.isEmpty {
            let sf = makeFont(-10, bold: false); let so = SelectObject(hdc, sf)
            SetTextColor(hdc, rgb(190, 165, 145))
            var sr = RECT(left: 26, top: y + 21, right: popupWidth - 24, bottom: y + 35)
            drawText(status.description, in: hdc, rect: &sr, format: UINT(DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS))
            SelectObject(hdc, so); DeleteObject(sf)
        }
    }
'''
s = rep(s, old_limit, new_limit, "limit row")

# Claude local block row + shifted official-limit section + incident banner. Codex gets a compact banner too.
old_claude = '''            divider(hdc, 364 + evoH)
            SetTextColor(hdc, rgb(150, 150, 162))
            let liFont = makeFont(-13, bold: false); o = SelectObject(hdc, liFont)
            var liRect = RECT(left: 20, top: 372 + evoH, right: popupWidth - 16, bottom: 392 + evoH); drawText(L("공식 한도", "Limits (official)", "公式リミット"), in: hdc, rect: &liRect, format: UINT(DT_LEFT | DT_SINGLELINE))
            SelectObject(hdc, o); DeleteObject(liFont)
            limitRow(hdc, y: 396 + evoH, L("5시간 세션", "5-hour session", "5時間セッション"), u.claude5h)
            limitRow(hdc, y: 440 + evoH, L("주간", "Weekly", "週間"), u.claude7d)
        }
'''
new_claude = '''            // Local rolling five-hour block — complements the official percent with the actual
            // token volume observed in Claude logs on this machine/selected WSL distro.
            let blockFont = makeFont(-11, bold: false); o = SelectObject(hdc, blockFont)
            SetTextColor(hdc, rgb(145, 145, 158))
            var blockRect = RECT(left: 20, top: 356 + evoH, right: popupWidth - 16, bottom: 376 + evoH)
            let blockLabel = L("현재 5h 로컬 블록", "Current local 5h block", "現在のローカル5hブロック")
            let blockRate = u.claudeBlockTPM > 0 ? " · \\(TokenFormatter.compact(Int(u.claudeBlockTPM)))/min" : ""
            drawText("\\(blockLabel)  \\(TokenFormatter.compact(u.claudeBlockTokens))\\(blockRate)", in: hdc, rect: &blockRect,
                     format: UINT(DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS))
            SelectObject(hdc, o); DeleteObject(blockFont)

            divider(hdc, 384 + evoH)
            SetTextColor(hdc, rgb(150, 150, 162))
            let liFont = makeFont(-13, bold: false); o = SelectObject(hdc, liFont)
            var liRect = RECT(left: 20, top: 392 + evoH, right: popupWidth - 16, bottom: 412 + evoH); drawText(L("공식 한도", "Limits (official)", "公式リミット"), in: hdc, rect: &liRect, format: UINT(DT_LEFT | DT_SINGLELINE))
            SelectObject(hdc, o); DeleteObject(liFont)
            limitRow(hdc, y: 416 + evoH, L("5시간 세션", "5-hour session", "5時間セッション"), u.claude5h)
            limitRow(hdc, y: 460 + evoH, L("주간", "Weekly", "週間"), u.claude7d)
            drawProviderStatusBanner(hdc, y: 506 + evoH, providerID: "claude_code", name: "Claude")
        } else if sel == 1 {
            drawProviderStatusBanner(hdc, y: 350 + evoH, providerID: "codex", name: "OpenAI")
        }
'''
s = rep(s, old_claude, new_claude, "Claude block/status UI")

# General settings: animation quality + used/remaining mode.
s = rep(
    s,
    '''        let genH = 8 + rowH * 4 + (openDropdown == 1 ? optH * 3 : 0) + (openDropdown == 2 ? optH * 5 : 0) + (openDropdown == 3 ? optH * Int32(wslOptions.count) : 0)
''',
    '''        let genH = 8 + rowH * 6 + (openDropdown == 1 ? optH * 3 : 0) + (openDropdown == 2 ? optH * 5 : 0) + (openDropdown == 3 ? optH * Int32(wslOptions.count) : 0) + (openDropdown == 4 ? optH * 3 : 0)
''',
    "general height",
)
s = rep(
    s,
    '''        if openDropdown == 2 {
            for (i, p) in [0, 60, 120, 300, 900].enumerated() {
                drawOptionRow(hdc, ry, intervalLabel(p), selected: sec == p, action: 70 + i); ry += optH
            }
        }
        let wslValue = WSLUsage.selectedDistribution ?? wslOptions[0]
''',
    '''        if openDropdown == 2 {
            for (i, p) in [0, 60, 120, 300, 900].enumerated() {
                drawOptionRow(hdc, ry, intervalLabel(p), selected: sec == p, action: 70 + i); ry += optH
            }
        }
        let animation = d.string(forKey: "animationQuality") ?? "balanced"
        drawDropdownHeader(hdc, ry, L("애니메이션 품질", "Animation quality", "アニメーション品質"),
                           value: animationQualityLabel(animation), open: openDropdown == 4, action: 63); ry += rowH
        if openDropdown == 4 {
            for (i, value) in ["powerSaver", "balanced", "smooth"].enumerated() {
                drawOptionRow(hdc, ry, animationQualityLabel(value), selected: animation == value, action: 200 + i); ry += optH
            }
        }
        drawSwitchRow(hdc, ry, L("남은 한도로 표시", "Show remaining limits", "残り上限を表示"),
                      sub: nil, on: showsRemainingLimits, action: 58); ry += rowH
        let wslValue = WSLUsage.selectedDistribution ?? wslOptions[0]
''',
    "general animation/limit controls",
)

# Notifications status checker toggle.
s = rep(
    s,
    '''        let notifH = 8 + rowH + 48 + (limitOn ? 68 : 0)
''',
    '''        let notifH = 8 + rowH * 2 + 48 + (limitOn ? 68 : 0)
''',
    "notification height",
)
s = rep(
    s,
    '''        drawSwitchRow(hdc, ry, L("Companion 이벤트", "Companion events", "コンパニオンイベント"),
                      sub: L("부화 · 진화 · 졸업", "Hatch · evolve · graduate", "孵化・進化・卒業"),
                      on: d.object(forKey: "companionNotifications") as? Bool ?? true, action: 13)
        y += notifH + 12

        // ===== Version =====
''',
    '''        drawSwitchRow(hdc, ry, L("Companion 이벤트", "Companion events", "コンパニオンイベント"),
                      sub: L("부화 · 진화 · 졸업", "Hatch · evolve · graduate", "孵化・進化・卒業"),
                      on: d.object(forKey: "companionNotifications") as? Bool ?? true, action: 13); ry += 48
        drawSwitchRow(hdc, ry, L("프로바이더 상태 확인", "Provider status checks", "プロバイダー状態確認"),
                      sub: L("Claude · OpenAI 장애를 표시", "Show Claude / OpenAI incidents", "Claude・OpenAI の障害を表示"),
                      on: d.object(forKey: "statusChecksEnabled") as? Bool ?? true, action: 59)
        y += notifH + 12

        // ===== Version =====
''',
    "status toggle",
)

# Replace passive version text with actionable update section, plus support actions.
old_version = '''        // ===== Version =====
        settingsLabel(hdc, y, L("버전", "Version", "バージョン")); y += 22
        let upToDate = lock.withLock { availableUpdate } == nil
        let vf = makeFont(-14, bold: false); let vo = SelectObject(hdc, vf)
        SetTextColor(hdc, upToDate ? rgb(150, 150, 160) : rgb(120, 180, 130))
        var vr = RECT(left: 24, top: y, right: popupWidth - 24, bottom: y + 22)
        let vtext = upToDate ? WindowsUpdate.currentVersion
                             : "\\(WindowsUpdate.currentVersion) → \\(lock.withLock { availableUpdate }?.version ?? "")"
        drawText(vtext, in: hdc, rect: &vr, format: UINT(DT_LEFT | DT_SINGLELINE))
        SelectObject(hdc, vo); DeleteObject(vf)
        y += 28

        RestoreDC(hdc, saved)
'''
new_version = '''        // ===== Updates =====
        settingsLabel(hdc, y, L("업데이트", "Updates", "アップデート")); y += 22
        drawCard(hdc, y, 8 + rowH)
        let latest = lock.withLock { availableUpdate }
        let versionText = latest.map { "\\(WindowsUpdate.currentVersion) → \\($0.version)" } ?? WindowsUpdate.currentVersion
        drawActionRow(hdc, y + 4, versionText,
                      button: L("지금 확인", "Check now", "今すぐ確認"), action: 402)
        y += 8 + rowH + 12

        // ===== About & Support =====
        settingsLabel(hdc, y, L("정보 & 지원", "About & Support", "情報とサポート")); y += 22
        drawCard(hdc, y, 8 + rowH * 2)
        drawActionRow(hdc, y + 4, L("로그 파일 보기", "Show log file", "ログファイルを表示"),
                      button: L("열기", "Open", "開く"), action: 400)
        drawActionRow(hdc, y + 4 + rowH, L("문제점 알리기", "Report a problem", "問題を報告"),
                      button: L("메일", "Email", "メール"), action: 401)
        y += 8 + rowH * 2 + 12

        RestoreDC(hdc, saved)
'''
s = rep(s, old_version, new_version, "updates/support settings")

# Reusable settings action row.
s = rep(
    s,
    '''    /// Row: label (+ optional subtitle) on the left, a macOS-style toggle switch on the right.
    private static func drawSwitchRow(_ hdc: HDC?, _ y: Int32, _ label: String, sub: String?, on: Bool, action: Int) {
''',
    '''    private static func drawActionRow(_ hdc: HDC?, _ y: Int32, _ label: String, button: String, action: Int) {
        let lf = makeFont(-14, bold: false); var o = SelectObject(hdc, lf)
        SetTextColor(hdc, rgb(214, 214, 222))
        var lr = RECT(left: 28, top: y, right: popupWidth - 126, bottom: y + setRowH)
        drawText(label, in: hdc, rect: &lr, format: UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS))
        SelectObject(hdc, o); DeleteObject(lf)
        let bf = makeFont(-12, bold: true); o = SelectObject(hdc, bf)
        let br = RECT(left: popupWidth - 118, top: y + 7, right: popupWidth - 28, bottom: y + setRowH - 7)
        drawButton(hdc, br, button, enabled: true)
        buttonHits.append((br, action))
        SelectObject(hdc, o); DeleteObject(bf)
    }

    /// Row: label (+ optional subtitle) on the left, a macOS-style toggle switch on the right.
    private static func drawSwitchRow(_ hdc: HDC?, _ y: Int32, _ label: String, sub: String?, on: Bool, action: Int) {
''',
    "draw action row",
)

# Animation helper/select + limit/status toggles.
s = rep(
    s,
    '''    private static func intervalLabel(_ sec: Int) -> String {
''',
    '''    private static func animationQualityLabel(_ value: String) -> String {
        switch value {
        case "powerSaver": return L("절전", "Power saver", "省電力")
        case "smooth": return L("부드럽게", "Smooth", "スムーズ")
        default: return L("균형", "Balanced", "バランス")
        }
    }

    private static func animationIntervalMS() -> UINT {
        switch UserDefaults.standard.string(forKey: "animationQuality") ?? "balanced" {
        case "powerSaver": return 400
        case "smooth": return 100
        default: return 200
        }
    }

    private static func applyAnimationQuality() {
        guard let sinkHwnd else { return }
        _ = KillTimer(sinkHwnd, animTimerID)
        _ = SetTimer(sinkHwnd, animTimerID, animationIntervalMS(), nil)
    }

    private static func selectAnimationQuality(_ index: Int) {
        let values = ["powerSaver", "balanced", "smooth"]
        guard values.indices.contains(index) else { return }
        UserDefaults.standard.set(values[index], forKey: "animationQuality")
        openDropdown = 0
        applyAnimationQuality()
        if let popupHwnd { InvalidateRect(popupHwnd, nil, true) }
    }

    private static func toggleLimitDisplayMode() {
        UserDefaults.standard.set(showsRemainingLimits ? "used" : "remaining", forKey: "limitDisplayMode")
        if let popupHwnd { InvalidateRect(popupHwnd, nil, true) }
        scheduleRefresh()
    }

    private static func toggleStatusChecks() {
        let d = UserDefaults.standard
        let on = d.object(forKey: "statusChecksEnabled") as? Bool ?? true
        d.set(!on, forKey: "statusChecksEnabled")
        if on { lock.withLock { providerStatuses.removeAll() } }
        else { lock.withLock { lastStatusFetch = nil }; scheduleRefresh() }
        if let popupHwnd { InvalidateRect(popupHwnd, nil, true) }
    }

    private static func intervalLabel(_ sec: Int) -> String {
''',
    "settings helpers",
)

# Actions for new settings/support controls.
s = rep(
    s,
    '''            case 57: toggleTip("tipShowLimit")
            case 60: toggleDropdown(1)   // language dropdown
            case 61: toggleDropdown(2)   // interval dropdown
            case 62: toggleDropdown(3)   // WSL distribution dropdown
            case 70...74: selectInterval(action - 70)   // interval preset
            case 80...199: selectWSL(action - 80)
''',
    '''            case 57: toggleTip("tipShowLimit")
            case 58: toggleLimitDisplayMode()
            case 59: toggleStatusChecks()
            case 60: toggleDropdown(1)   // language dropdown
            case 61: toggleDropdown(2)   // interval dropdown
            case 62: toggleDropdown(3)   // WSL distribution dropdown
            case 63: toggleDropdown(4)   // animation quality dropdown
            case 70...74: selectInterval(action - 70)   // interval preset
            case 80...199: selectWSL(action - 80)
            case 200...202: selectAnimationQuality(action - 200)
''',
    "new settings actions",
)
s = rep(
    s,
    '''            case 321:
                dexPage += 1; if let popupHwnd { InvalidateRect(popupHwnd, nil, true) }
            default: doAction(action)
''',
    '''            case 321:
                dexPage += 1; if let popupHwnd { InvalidateRect(popupHwnd, nil, true) }
            case 400: openLogFile()
            case 401: reportProblem()
            case 402: manualUpdateCheck()
            default: doAction(action)
''',
    "support action routing",
)

# Safe support/update actions before doAction.
s = rep(
    s,
    '''    private static func doAction(_ id: Int) {
''',
    '''    private static func openLogFile() {
        let url = AppLog.logFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            let exe = "explorer.exe".wide
            let params = "/select,\\\"\\(url.path)\\\"".wide
            _ = exe.withUnsafeBufferPointer { e in
                params.withUnsafeBufferPointer { p in ShellExecuteW(nil, nil, e.baseAddress, p.baseAddress, nil, 1) }
            }
        } else {
            let folder = url.deletingLastPathComponent().path.wide
            _ = folder.withUnsafeBufferPointer { p in ShellExecuteW(nil, nil, p.baseAddress, nil, nil, 1) }
        }
    }

    private static func reportProblem() {
        let log = AppLog.logFileURL.path
        let subject = L("[PokeTokenBar] 문제 리포트 (v\\(WindowsUpdate.currentVersion))",
                        "[PokeTokenBar] Problem report (v\\(WindowsUpdate.currentVersion))",
                        "[PokeTokenBar] 問題レポート (v\\(WindowsUpdate.currentVersion))")
        let body = L("문제 내용:\\n(언제, 어떤 화면에서, 어떻게 되었는지 적어주세요)\\n\\n---\\nWindows 앱: v\\(WindowsUpdate.currentVersion)\\n로그 파일(첨부 권장): \\(log)",
                     "What happened:\\n(Describe when, where, and what you saw)\\n\\n---\\nWindows app: v\\(WindowsUpdate.currentVersion)\\nLog file (please attach): \\(log)",
                     "問題の内容:\\n（いつ・どの画面で・どうなったか）\\n\\n---\\nWindows アプリ: v\\(WindowsUpdate.currentVersion)\\nログファイル（添付推奨）: \\(log)")
        guard let url = SupportMail.mailtoURL(subject: subject, body: body) else { return }
        let target = url.absoluteString.wide
        _ = target.withUnsafeBufferPointer { p in ShellExecuteW(nil, nil, p.baseAddress, nil, nil, 1) }
    }

    private static func manualUpdateCheck() {
        lock.withLock { lastUpdateCheck = Date() }
        Task.detached {
            let upd = await WindowsUpdate.check()
            lock.withLock { availableUpdate = upd }
            resizePopupForBanner()
        }
    }

    private static func doAction(_ id: Int) {
''',
    "support functions",
)

# Auto updater remains fail-closed: update button opens trusted release page while verification is disabled.
s = rep(
    s,
    '''    private static func applyUpdate() {
        guard let upd = lock.withLock({ availableUpdate }) else { return }
        // Guard against double-clicks; flip on the full-cover overlay immediately for instant feedback.
''',
    '''    private static func applyUpdate() {
        guard let upd = lock.withLock({ availableUpdate }) else { return }
        if !WindowsUpdate.automaticInstallerEnabled {
            WindowsUpdate.openReleasePage(upd.url)
            return
        }
        // Guard against double-clicks; flip on the full-cover overlay immediately for instant feedback.
''',
    "safe applyUpdate",
)

# Snapshot fields for local block.
s = rep(
    s,
    '''    var claudeIn = 0, claudeOut = 0, claudeCacheW = 0, claudeCacheR = 0
    var claude5h: Int?, claude7d: Int?
''',
    '''    var claudeIn = 0, claudeOut = 0, claudeCacheW = 0, claudeCacheR = 0
    var claudeBlockTokens = 0
    var claudeBlockTPM = 0.0
    var claude5h: Int?, claude7d: Int?
''',
    "usage snapshot block fields",
)

tray_path.write_text(s, encoding="utf-8")
print("patched Windows settings/ops parity")
