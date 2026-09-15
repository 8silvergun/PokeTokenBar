from pathlib import Path


def rep(s: str, old: str, new: str, label: str, count: int = 1) -> str:
    actual = s.count(old)
    if actual != count:
        raise SystemExit(f"{label}: expected {count} occurrence(s), found {actual}")
    return s.replace(old, new, count)

# -----------------------------------------------------------------------------
# WindowsCore CompanionState / CompanionStore: representative Pokémon parity.
# -----------------------------------------------------------------------------
model_path = Path("Sources/PokeTokenBar/WindowsCore/CompanionModel.swift")
m = model_path.read_text(encoding="utf-8")
m = rep(
    m,
    '''    // 현재 포켓몬(없으면 알)\n    var active: MonState?\n    // 도감\n''',
    '''    // 현재 포켓몬(없으면 알)\n    var active: MonState?\n    // 트레이/플로팅 펫에 고정할 대표 종. nil = 현재 육성 개체(또는 알)를 따라간다.\n    var representativeSpeciesID: Int?\n    // 도감\n''',
    "representative state field",
)
m = rep(
    m,
    '''        active = try c.decodeIfPresent(MonState.self, forKey: .active)\n        dex = try c.decodeIfPresent([DexEntry].self, forKey: .dex) ?? []\n''',
    '''        active = try c.decodeIfPresent(MonState.self, forKey: .active)\n        representativeSpeciesID = try c.decodeIfPresent(Int.self, forKey: .representativeSpeciesID)\n        dex = try c.decodeIfPresent([DexEntry].self, forKey: .dex) ?? []\n''',
    "representative state decode",
)
m = rep(
    m,
    '''        candyFeatureSeeded = try c.decodeIfPresent(Bool.self, forKey: .candyFeatureSeeded) ?? false\n    }\n}\n\n// NOTE: 부화 후보는 더 이상 하드코딩하지 않는다 — CompanionStore.chooseBase() 가\n''',
    '''        candyFeatureSeeded = try c.decodeIfPresent(Bool.self, forKey: .candyFeatureSeeded) ?? false\n    }\n\n    /// 졸업 기록 또는 현재 개체가 실제 도달한 단계에 이 종이 포함되는가.\n    func ownsSpecies(_ speciesID: Int) -> Bool {\n        if dex.contains(where: { $0.chainOrder.contains(speciesID) }) { return true }\n        guard let active else { return false }\n        let reached = active.pathIDs.prefix(max(1, min(active.stageIndex + 1, active.pathIDs.count)))\n        return reached.contains(speciesID)\n    }\n\n    /// 보유한 특정 종 중 이로치 개체가 있는가. 위장 중 메타몽은 공개 전까지 숨긴다.\n    func ownsShinySpecies(_ speciesID: Int) -> Bool {\n        if dex.contains(where: { $0.isShiny && $0.chainOrder.contains(speciesID) }) { return true }\n        guard let active, active.isShiny else { return false }\n        if active.dittoDisguise != nil && !active.dittoRevealed { return false }\n        let reached = active.pathIDs.prefix(max(1, min(active.stageIndex + 1, active.pathIDs.count)))\n        return reached.contains(speciesID)\n    }\n}\n\n// NOTE: 부화 후보는 더 이상 하드코딩하지 않는다 — CompanionStore.chooseBase() 가\n''',
    "representative ownership helpers",
)
model_path.write_text(m, encoding="utf-8")

store_path = Path("Sources/PokeTokenBar/WindowsCore/CompanionStore.swift")
c = store_path.read_text(encoding="utf-8")
c = rep(
    c,
    '''    var currentNature: PokemonNature? { state.active?.nature }\n\n    var isEgg: Bool { state.active == nil }\n''',
    '''    var currentNature: PokemonNature? { state.active?.nature }\n\n    var representativeSpeciesID: Int? { state.representativeSpeciesID }\n    var representativeVisualSpeciesID: Int? { state.representativeSpeciesID ?? currentSpeciesID }\n    var representativeVisualIsShiny: Bool {\n        guard let selected = state.representativeSpeciesID else { return currentIsShiny }\n        return state.ownsShinySpecies(selected)\n    }\n\n    /// nil은 현재 개체 자동 추적. 도감에 없는 종은 기존 선택을 유지한 채 거부한다.\n    @discardableResult\n    func setRepresentativeSpeciesID(_ id: Int?) -> Bool {\n        if let id, !state.ownsSpecies(id) { return false }\n        state.representativeSpeciesID = id\n        save()\n        return true\n    }\n\n    var isEgg: Bool { state.active == nil }\n''',
    "representative store API",
)
store_path.write_text(c, encoding="utf-8")

# -----------------------------------------------------------------------------
# Win32 floating pet implementation. Uses the tray-owned HICON frames (borrowed,
# never destroyed here), so no duplicate network fetch/cache and animation quality
# automatically applies to both tray + floating pet.
# -----------------------------------------------------------------------------
floating = r'''#if os(Windows)
import Foundation
import WinSDK

/// Lightweight Win32 counterpart of macOS FloatingPetPanel.
///
/// - opt-in via `floatingPetEnabled`
/// - borderless/top-most/color-key transparent window
/// - drag to reposition, position persisted across launches
/// - left click opens the normal PokeTokenBar popover
/// - right click forwards to the tray context menu
/// - size is persisted in the same `floatingPetSize` key used by macOS
/// - sprite HICON is borrowed from WindowsTray; this type never destroys it
///
/// The tray message loop and this window live on the same thread. Background refresh
/// only posts snapshots to the tray; all HWND/GDI mutation remains on that UI thread.
enum WindowsFloatingPet {
    private static let className = "PokeTokenBarFloatingPet"
    private static let timerID = UINT_PTR(77)
    private static let transparentKey = rgb(1, 0, 1)
    private static let originXKey = "floatingPetOriginX"
    private static let originYKey = "floatingPetOriginY"

    nonisolated(unsafe) private static var hwnd: HWND?
    nonisolated(unsafe) private static var borrowedIcon: HICON?
    nonisolated(unsafe) private static var dragCursorStart = POINT()
    nonisolated(unsafe) private static var dragWindowStart = POINT()
    nonisolated(unsafe) private static var dragging = false

    static let minSize: Int32 = 48
    static let maxSize: Int32 = 384
    static let defaultSize: Int32 = 96

    static func clampedSize(_ value: Double) -> Int32 {
        min(maxSize, max(minSize, Int32(value.rounded())))
    }

    private static var configuredSize: Int32 {
        let raw = UserDefaults.standard.object(forKey: "floatingPetSize") as? Double ?? Double(defaultSize)
        return clampedSize(raw)
    }

    private static var enabled: Bool {
        UserDefaults.standard.object(forKey: "floatingPetEnabled") as? Bool ?? false
    }

    static func prepare() {
        let hInstance = GetModuleHandleW(nil)
        let cls = className.wide
        _ = cls.withUnsafeBufferPointer { p -> Bool in
            var wc = WNDCLASSEXW()
            wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            wc.lpfnWndProc = windowProc
            wc.hInstance = hInstance
            wc.hCursor = LoadCursorW(nil, UnsafePointer<WCHAR>(bitPattern: 32512))
            wc.lpszClassName = p.baseAddress
            return RegisterClassExW(&wc) != 0 || GetLastError() == DWORD(ERROR_CLASS_ALREADY_EXISTS)
        }

        let size = configuredSize
        let origin = restoredOrigin(size: size)
        hwnd = cls.withUnsafeBufferPointer { p in
            CreateWindowExW(
                DWORD(WS_EX_TOOLWINDOW) | DWORD(WS_EX_TOPMOST) | DWORD(WS_EX_LAYERED) | DWORD(WS_EX_NOACTIVATE),
                p.baseAddress, p.baseAddress, DWORD(WS_POPUP),
                origin.x, origin.y, size, size,
                nil, nil, hInstance, nil)
        }
        if let hwnd {
            // LWA_COLORKEY = 0x1. Keep the sprite alpha in the HICON itself and key out only the
            // otherwise solid background. No global alpha is applied to the Pokémon sprite.
            _ = SetLayeredWindowAttributes(hwnd, transparentKey, 255, DWORD(0x1))
            _ = SetTimer(hwnd, timerID, 1000, nil)   // settings reconciliation / external toggle
            syncSettings()
        }
    }

    /// Called by WindowsTray whenever the displayed tray frame changes.
    static func updateIcon(_ icon: HICON?) {
        borrowedIcon = icon
        syncSettings()
        if let hwnd, IsWindowVisible(hwnd) { InvalidateRect(hwnd, nil, true) }
    }

    static func syncSettings() {
        guard let hwnd else { return }
        guard enabled, borrowedIcon != nil else {
            _ = ShowWindow(hwnd, SW_HIDE)
            return
        }
        let size = configuredSize
        var wr = RECT(); _ = GetWindowRect(hwnd, &wr)
        var x = wr.left, y = wr.top
        if wr.right <= wr.left || wr.bottom <= wr.top {
            let d = restoredOrigin(size: size); x = d.x; y = d.y
        }
        let clamped = clampOrigin(x: x, y: y, size: size)
        _ = SetWindowPos(hwnd, HWND(bitPattern: -1), clamped.x, clamped.y, size, size,
                         UINT(SWP_NOACTIVATE | SWP_SHOWWINDOW))
        InvalidateRect(hwnd, nil, true)
    }

    private static func restoredOrigin(size: Int32) -> POINT {
        let d = UserDefaults.standard
        if d.object(forKey: originXKey) != nil, d.object(forKey: originYKey) != nil {
            return clampOrigin(x: Int32(d.double(forKey: originXKey)),
                               y: Int32(d.double(forKey: originYKey)), size: size)
        }
        var wa = RECT(); _ = SystemParametersInfoW(UINT(SPI_GETWORKAREA), 0, &wa, 0)
        return POINT(x: max(wa.left, wa.right - size - 24),
                     y: max(wa.top, wa.bottom - size - 24))
    }

    private static func clampOrigin(x: Int32, y: Int32, size: Int32) -> POINT {
        var wa = RECT(); _ = SystemParametersInfoW(UINT(SPI_GETWORKAREA), 0, &wa, 0)
        let maxX = max(wa.left, wa.right - size)
        let maxY = max(wa.top, wa.bottom - size)
        return POINT(x: min(maxX, max(wa.left, x)), y: min(maxY, max(wa.top, y)))
    }

    private static func saveOrigin(_ hWnd: HWND) {
        var wr = RECT(); guard GetWindowRect(hWnd, &wr) != 0 else { return }
        let d = UserDefaults.standard
        d.set(Double(wr.left), forKey: originXKey)
        d.set(Double(wr.top), forKey: originYKey)
    }

    private static func postTrayMessage(_ message: UINT, event: UINT = 0) {
        let sinkClass = "PokeTokenBarTraySink".wide
        let sink = sinkClass.withUnsafeBufferPointer { p in
            FindWindowExW(HWND(bitPattern: -3), nil, p.baseAddress, nil)   // HWND_MESSAGE
        }
        guard let sink else { return }
        if event == 0 { _ = PostMessageW(sink, message, 0, 0) }
        else { _ = PostMessageW(sink, message, 0, LPARAM(event)) }
    }

    private static func openPopover() { postTrayMessage(UINT(WM_APP) + 3) }
    private static func openTrayMenu() { postTrayMessage(UINT(WM_APP) + 1, event: UINT(WM_CONTEXTMENU)) }

    private static let windowProc: WNDPROC = { hWnd, uMsg, wParam, lParam in
        switch uMsg {
        case UINT(WM_TIMER):
            if UINT_PTR(wParam) == WindowsFloatingPet.timerID { WindowsFloatingPet.syncSettings() }
            return 0
        case UINT(WM_ERASEBKGND):
            return 1
        case UINT(WM_PAINT):
            var ps = PAINTSTRUCT()
            let hdc = BeginPaint(hWnd, &ps)
            var rc = RECT(); GetClientRect(hWnd, &rc)
            let bg = CreateSolidBrush(WindowsFloatingPet.transparentKey)
            FillRect(hdc, &rc, bg); DeleteObject(bg)
            if let icon = WindowsFloatingPet.borrowedIcon {
                let side = min(rc.right - rc.left, rc.bottom - rc.top)
                DrawIconEx(hdc, 0, 0, icon, side, side, 0, nil, UINT(DI_NORMAL))
            }
            EndPaint(hWnd, &ps)
            return 0
        case UINT(WM_LBUTTONDOWN):
            _ = SetCapture(hWnd)
            GetCursorPos(&WindowsFloatingPet.dragCursorStart)
            var wr = RECT(); _ = GetWindowRect(hWnd, &wr)
            WindowsFloatingPet.dragWindowStart = POINT(x: wr.left, y: wr.top)
            WindowsFloatingPet.dragging = false
            return 0
        case UINT(WM_MOUSEMOVE):
            if GetCapture() == hWnd {
                var now = POINT(); GetCursorPos(&now)
                let dx = now.x - WindowsFloatingPet.dragCursorStart.x
                let dy = now.y - WindowsFloatingPet.dragCursorStart.y
                if dx * dx + dy * dy >= 16 { WindowsFloatingPet.dragging = true }
                let size = WindowsFloatingPet.configuredSize
                let p = WindowsFloatingPet.clampOrigin(
                    x: WindowsFloatingPet.dragWindowStart.x + dx,
                    y: WindowsFloatingPet.dragWindowStart.y + dy,
                    size: size)
                _ = SetWindowPos(hWnd, HWND(bitPattern: -1), p.x, p.y, 0, 0,
                                 UINT(SWP_NOSIZE | SWP_NOACTIVATE))
            }
            return 0
        case UINT(WM_LBUTTONUP):
            if GetCapture() == hWnd { _ = ReleaseCapture() }
            WindowsFloatingPet.saveOrigin(hWnd)
            if !WindowsFloatingPet.dragging { WindowsFloatingPet.openPopover() }
            return 0
        case UINT(WM_RBUTTONUP), UINT(WM_CONTEXTMENU):
            WindowsFloatingPet.openTrayMenu()
            return 0
        case UINT(WM_CLOSE):
            UserDefaults.standard.set(false, forKey: "floatingPetEnabled")
            WindowsFloatingPet.syncSettings()
            return 0
        case UINT(WM_DESTROY):
            _ = KillTimer(hWnd, WindowsFloatingPet.timerID)
            return 0
        default:
            return DefWindowProcW(hWnd, uMsg, wParam, lParam)
        }
    }
}
#endif
'''
Path("Sources/PokeTokenBar/WindowsFloatingPet.swift").write_text(floating, encoding="utf-8")

# -----------------------------------------------------------------------------
# WindowsMain: install the floating-pet HWND before entering the shared message loop.
# -----------------------------------------------------------------------------
main_path = Path("Sources/PokeTokenBar/WindowsMain.swift")
wmain = main_path.read_text(encoding="utf-8")
wmain = rep(
    wmain,
    '''        guard args.contains(where: cliFlags.contains) else {\n            WindowsTray.run()\n            return\n        }\n''',
    '''        guard args.contains(where: cliFlags.contains) else {\n            WindowsFloatingPet.prepare()\n            WindowsTray.run()\n            return\n        }\n''',
    "floating pet startup",
)
main_path.write_text(wmain, encoding="utf-8")

# -----------------------------------------------------------------------------
# WindowsTray: visual subject, representative selection, floating settings/hooks.
# Runs after windows_ops_patch.py, so animation/status/update helpers already exist.
# -----------------------------------------------------------------------------
tray_path = Path("Sources/PokeTokenBar/WindowsTray.swift")
t = tray_path.read_text(encoding="utf-8")

# macOS default is powerSaver; keep Windows parity for existing/new installs.
t = t.replace('d.string(forKey: "animationQuality") ?? "balanced"',
              'd.string(forKey: "animationQuality") ?? "powerSaver"')
t = t.replace('UserDefaults.standard.string(forKey: "animationQuality") ?? "balanced"',
              'UserDefaults.standard.string(forKey: "animationQuality") ?? "powerSaver"')

# Representative controls add one General row.
t = rep(
    t,
    '''        let genH = 8 + rowH * 6 + (openDropdown == 1 ? optH * 3 : 0) + (openDropdown == 2 ? optH * 5 : 0) + (openDropdown == 3 ? optH * Int32(wslOptions.count) : 0) + (openDropdown == 4 ? optH * 3 : 0)\n''',
    '''        let genH = 8 + rowH * 7 + (openDropdown == 1 ? optH * 3 : 0) + (openDropdown == 2 ? optH * 5 : 0) + (openDropdown == 3 ? optH * Int32(wslOptions.count) : 0) + (openDropdown == 4 ? optH * 3 : 0)\n''',
    "general representative row height",
)
t = rep(
    t,
    '''        if openDropdown == 1 {\n            for (label, code, act) in [("English", "en", 10), ("한국어", "ko", 11), ("日本語", "ja", 12)] {\n                drawOptionRow(hdc, ry, label, selected: disp.languageCode == code, action: act); ry += optH\n            }\n        }\n        let sec = d.object(forKey: "refreshIntervalSec") as? Int ?? 120\n''',
    '''        if openDropdown == 1 {\n            for (label, code, act) in [("English", "en", 10), ("한국어", "ko", 11), ("日本語", "ja", 12)] {\n                drawOptionRow(hdc, ry, label, selected: disp.languageCode == code, action: act); ry += optH\n            }\n        }\n        let representativeText = disp.representativeSpeciesID.map { id in\n            let name = disp.representativeName.isEmpty ? "#\\(id)" : "#\\(id) \\(disp.representativeName)"\n            return name\n        } ?? L("현재 포켓몬 따라가기", "Follow current Pokémon", "現在のポケモンを追従")\n        drawActionRow(hdc, ry, L("대표 포켓몬", "Representative Pokémon", "代表ポケモン"),\n                      button: L("도감 선택", "Choose in Dex", "図鑑で選択"), action: 67)\n        // Show the current choice as a small secondary line without consuming another settings row.\n        let rf = makeFont(-10, bold: false); let ro = SelectObject(hdc, rf)\n        SetTextColor(hdc, rgb(130, 150, 170))\n        var rr = RECT(left: 28, top: ry + 27, right: popupWidth - 130, bottom: ry + 40)\n        drawText(representativeText, in: hdc, rect: &rr, format: UINT(DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS))\n        SelectObject(hdc, ro); DeleteObject(rf)\n        ry += rowH\n        let sec = d.object(forKey: "refreshIntervalSec") as? Int ?? 120\n''',
    "representative settings row",
)

# Floating pet settings section between General and tray-tooltip settings.
t = rep(
    t,
    '''        drawSwitchRow(hdc, ry, L("로그인 시 자동 시작", "Launch at login", "ログイン時に起動"), sub: nil, on: WindowsAutostart.isEnabled(), action: 53)\n        y += genH + 12\n\n        // ===== Show in tray tooltip (the Windows analog of the macOS menu-bar display options) =====\n''',
    '''        drawSwitchRow(hdc, ry, L("로그인 시 자동 시작", "Launch at login", "ログイン時に起動"), sub: nil, on: WindowsAutostart.isEnabled(), action: 53)\n        y += genH + 12\n\n        // ===== Floating pet =====\n        settingsLabel(hdc, y, L("플로팅 펫", "Floating pet", "フローティングペット")); y += 24\n        let petH = 8 + rowH * 2\n        drawCard(hdc, y, petH)\n        ry = y + 4\n        let petEnabled = d.object(forKey: "floatingPetEnabled") as? Bool ?? false\n        drawSwitchRow(hdc, ry, L("데스크톱에 표시", "Show on desktop", "デスクトップに表示"),\n                      sub: L("드래그로 이동 · 클릭하면 앱 열기", "Drag to move · click to open", "ドラッグで移動・クリックで開く"),\n                      on: petEnabled, action: 64); ry += rowH\n        let petSize = Int(d.object(forKey: "floatingPetSize") as? Double ?? 96)\n        drawStepRow(hdc, ry, L("크기", "Size", "サイズ"), value: "\\(petSize)px", minusAction: 65, plusAction: 66)\n        y += petH + 12\n\n        // ===== Show in tray tooltip (the Windows analog of the macOS menu-bar display options) =====\n''',
    "floating pet settings section",
)

# Stepper helper next to action row helper.
t = rep(
    t,
    '''    private static func drawActionRow(_ hdc: HDC?, _ y: Int32, _ label: String, button: String, action: Int) {\n''',
    '''    private static func drawStepRow(_ hdc: HDC?, _ y: Int32, _ label: String, value: String,\n                                    minusAction: Int, plusAction: Int) {\n        let lf = makeFont(-14, bold: false); var o = SelectObject(hdc, lf)\n        SetTextColor(hdc, rgb(214, 214, 222))\n        var lr = RECT(left: 28, top: y, right: popupWidth - 170, bottom: y + setRowH)\n        drawText(label, in: hdc, rect: &lr, format: UINT(DT_LEFT | DT_VCENTER | DT_SINGLELINE))\n        SelectObject(hdc, o); DeleteObject(lf)\n        let vf = makeFont(-12, bold: true); o = SelectObject(hdc, vf)\n        SetTextColor(hdc, rgb(190, 200, 215))\n        var vr = RECT(left: popupWidth - 166, top: y, right: popupWidth - 96, bottom: y + setRowH)\n        drawText(value, in: hdc, rect: &vr, format: UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE))\n        SelectObject(hdc, o); DeleteObject(vf)\n        let minus = RECT(left: popupWidth - 92, top: y + 7, right: popupWidth - 62, bottom: y + setRowH - 7)\n        let plus = RECT(left: popupWidth - 58, top: y + 7, right: popupWidth - 28, bottom: y + setRowH - 7)\n        drawButton(hdc, minus, "−", enabled: true); drawButton(hdc, plus, "+", enabled: true)\n        buttonHits.append((minus, minusAction)); buttonHits.append((plus, plusAction))\n    }\n\n    private static func drawActionRow(_ hdc: HDC?, _ y: Int32, _ label: String, button: String, action: Int) {\n''',
    "floating pet stepper helper",
)

# Action routing for floating pet + representative mode.
t = rep(
    t,
    '''            case 63: toggleDropdown(4)   // animation quality dropdown\n            case 70...74: selectInterval(action - 70)   // interval preset\n''',
    '''            case 63: toggleDropdown(4)   // animation quality dropdown\n            case 64: toggleFloatingPet()\n            case 65: adjustFloatingPetSize(-16)\n            case 66: adjustFloatingPetSize(16)\n            case 67:\n                popupView = 3; dexMode = 0; dexFilter = 0; dexPage = 0; dexScroll = 0\n                if let popupHwnd { InvalidateRect(popupHwnd, nil, true) }\n            case 70...74: selectInterval(action - 70)   // interval preset\n''',
    "floating/representative action routing",
)
t = rep(
    t,
    '''            case 321:\n                dexPage += 1; if let popupHwnd { InvalidateRect(popupHwnd, nil, true) }\n            case 400: openLogFile()\n''',
    '''            case 321:\n                dexPage += 1; if let popupHwnd { InvalidateRect(popupHwnd, nil, true) }\n            case 4000...4999:\n                selectRepresentative(action - 4000)\n            case 400: openLogFile()\n''',
    "representative dex action routing",
)

# Floating helpers before intervalLabel.
t = rep(
    t,
    '''    private static func intervalLabel(_ sec: Int) -> String {\n''',
    '''    private static func toggleFloatingPet() {\n        let d = UserDefaults.standard\n        let on = d.object(forKey: "floatingPetEnabled") as? Bool ?? false\n        d.set(!on, forKey: "floatingPetEnabled")\n        WindowsFloatingPet.syncSettings()\n        if let popupHwnd { InvalidateRect(popupHwnd, nil, true) }\n    }\n\n    private static func adjustFloatingPetSize(_ delta: Int) {\n        let d = UserDefaults.standard\n        let old = d.object(forKey: "floatingPetSize") as? Double ?? 96\n        let next = Double(WindowsFloatingPet.clampedSize(old + Double(delta)))\n        d.set(next, forKey: "floatingPetSize")\n        WindowsFloatingPet.syncSettings()\n        if let popupHwnd { InvalidateRect(popupHwnd, nil, true) }\n    }\n\n    private static func selectRepresentative(_ speciesID: Int) {\n        guard let companion else { return }\n        Task {\n            let current = await companion.representativeSpeciesID\n            _ = await companion.setRepresentativeSpeciesID(current == speciesID ? nil : speciesID)\n            let disp = await companion.windowsDisplay\n            lock.withLock { currentDisplay = disp }\n            if let popupHwnd { InvalidateRect(popupHwnd, nil, true) }\n            scheduleRefresh()   // refresh tray/floating sprite to the selected visual subject\n        }\n    }\n\n    private static func intervalLabel(_ sec: Int) -> String {\n''',
    "floating/representative helpers",
)

# Tray/floating visual subject uses representative Pokémon when selected.
t = rep(
    t,
    '''        let animKey = disp.isEgg ? "egg" : (disp.speciesID.map { "\\($0)-\\(disp.isShiny)" } ?? "none")\n        if lock.withLock({ animSpeciesKey != animKey && pendingAnimKey != animKey }) {\n            var frames: [HICON] = []\n            if !disp.isEgg, let id = disp.speciesID,\n               let gif = await SpriteStore.shared.data(speciesID: id, animated: true, shiny: disp.isShiny) {\n                frames = WindowsImaging.hiconsFromGIF(gif) ?? []\n            }\n            lock.withLock { pendingAnim = frames; pendingAnimKey = animKey }\n        }\n''',
    '''        let animKey = disp.visualSpeciesID.map { "\\($0)-\\(disp.visualIsShiny)" } ?? "egg"\n        if lock.withLock({ animSpeciesKey != animKey && pendingAnimKey != animKey }) {\n            var frames: [HICON] = []\n            if let id = disp.visualSpeciesID,\n               let gif = await SpriteStore.shared.data(speciesID: id, animated: true, shiny: disp.visualIsShiny) {\n                frames = WindowsImaging.hiconsFromGIF(gif) ?? []\n            }\n            lock.withLock { pendingAnim = frames; pendingAnimKey = animKey }\n        }\n''',
    "representative animation subject",
)
t = rep(
    t,
    '''    private static func companionIcon(_ disp: CompanionDisplay) async -> HICON? {\n        let png: Data?\n        if disp.isEgg {\n            png = await SpriteStore.shared.eggData()\n        } else if let id = disp.speciesID {\n            png = await SpriteStore.shared.data(speciesID: id, animated: false, shiny: disp.isShiny)\n        } else {\n            png = nil\n        }\n        guard let png else { return nil }\n        return WindowsImaging.hicon(fromPNG: png)\n    }\n''',
    '''    private static func companionIcon(_ disp: CompanionDisplay) async -> HICON? {\n        let png: Data?\n        if let id = disp.visualSpeciesID {\n            png = await SpriteStore.shared.data(speciesID: id, animated: false, shiny: disp.visualIsShiny)\n        } else {\n            png = await SpriteStore.shared.eggData()\n        }\n        guard let png else { return nil }\n        return WindowsImaging.hicon(fromPNG: png)\n    }\n''',
    "representative static icon subject",
)

# Keep floating window in lockstep with the currently displayed HICON frame.
t = rep(
    t,
    '''        nid.hIcon = displayedIcon()\n        _ = Shell_NotifyIconW(DWORD(NIM_MODIFY), &nid)\n        if let popupHwnd, IsWindowVisible(popupHwnd) { InvalidateRect(popupHwnd, nil, true) }\n''',
    '''        nid.hIcon = displayedIcon()\n        _ = Shell_NotifyIconW(DWORD(NIM_MODIFY), &nid)\n        WindowsFloatingPet.updateIcon(displayedIcon())\n        if let popupHwnd, IsWindowVisible(popupHwnd) { InvalidateRect(popupHwnd, nil, true) }\n''',
    "floating icon snapshot sync",
)
t = rep(
    t,
    '''        nid.hIcon = animFrames[animIndex]\n        _ = Shell_NotifyIconW(DWORD(NIM_MODIFY), &nid)\n        if let popupHwnd, IsWindowVisible(popupHwnd), popupView == 0 {\n''',
    '''        nid.hIcon = animFrames[animIndex]\n        _ = Shell_NotifyIconW(DWORD(NIM_MODIFY), &nid)\n        WindowsFloatingPet.updateIcon(animFrames[animIndex])\n        if let popupHwnd, IsWindowVisible(popupHwnd), popupView == 0 {\n''',
    "floating animation frame sync",
)

# Dex cells: selected representative highlight + click target. Clicking selected again restores auto-follow.
t = rep(
    t,
    '''            let nameFont = makeFont(-10, bold: false); let nOld = SelectObject(hdc, nameFont)\n            for (i, item) in pageItems.enumerated() {\n                let col = Int32(i) % dexCols, row = Int32(i) / dexCols\n                let cx = 12 + col * cellW\n                let cy = gridTop + row * cellH\n                if item.isRaising {\n                    fillRound(hdc, RECT(left: cx + 4, top: cy, right: cx + cellW - 4, bottom: cy + cellH - 4),\n                              10, rgb(38, 54, 70))\n                }\n''',
    '''            let nameFont = makeFont(-10, bold: false); let nOld = SelectObject(hdc, nameFont)\n            let representativeID = lock.withLock { currentDisplay.representativeSpeciesID }\n            for (i, item) in pageItems.enumerated() {\n                let col = Int32(i) % dexCols, row = Int32(i) / dexCols\n                let cx = 12 + col * cellW\n                let cy = gridTop + row * cellH\n                let cellRect = RECT(left: cx + 4, top: cy, right: cx + cellW - 4, bottom: cy + cellH - 4)\n                if item.speciesID == representativeID {\n                    fillRound(hdc, cellRect, 10, rgb(54, 84, 122))\n                } else if item.isRaising {\n                    fillRound(hdc, cellRect, 10, rgb(38, 54, 70))\n                }\n''',
    "representative dex highlight",
)
t = rep(
    t,
    '''                let label = (item.isShiny ? "* " : "") + item.name\n                drawText(label, in: hdc, rect: &nr, format: UINT(DT_CENTER | DT_SINGLELINE | DT_END_ELLIPSIS))\n            }\n''',
    '''                let label = (item.isShiny ? "* " : "") + item.name\n                drawText(label, in: hdc, rect: &nr, format: UINT(DT_CENTER | DT_SINGLELINE | DT_END_ELLIPSIS))\n                buttonHits.append((cellRect, 4000 + item.speciesID))\n            }\n''',
    "representative dex click target",
)

# Snapshot fields + construction.
t = rep(
    t,
    '''    var isShiny = false\n    var speciesID: Int?\n    // Shop / inventory / dex (for the interactive popover actions).\n''',
    '''    var isShiny = false\n    var speciesID: Int?\n    // Visual subject for tray/floating pet. Representative selection may differ from current companion.\n    var visualSpeciesID: Int?\n    var visualIsShiny = false\n    var representativeSpeciesID: Int?\n    var representativeName = ""\n    // Shop / inventory / dex (for the interactive popover actions).\n''',
    "representative display fields",
)
t = rep(
    t,
    '''            rarityText: rarity.map { String(describing: $0) }, isShiny: currentIsShiny, speciesID: currentSpeciesID,\n            wallet: availableTokens, candyCount: rareCandyCount, mintCount: itemCount(.mint), dexCount: dexEntries.count,\n''',
    '''            rarityText: rarity.map { String(describing: $0) }, isShiny: currentIsShiny, speciesID: currentSpeciesID,\n            visualSpeciesID: representativeVisualSpeciesID, visualIsShiny: representativeVisualIsShiny,\n            representativeSpeciesID: representativeSpeciesID,\n            representativeName: representativeSpeciesID.flatMap { selected in\n                dexSpecies.first(where: { $0.id == selected })?.name\n            } ?? "",\n            wallet: availableTokens, candyCount: rareCandyCount, mintCount: itemCount(.mint), dexCount: dexEntries.count,\n''',
    "representative display construction",
)

tray_path.write_text(t, encoding="utf-8")

# -----------------------------------------------------------------------------
# Windows tests: representative persistence/validation + floating-size bounds.
# -----------------------------------------------------------------------------
test = r'''#if os(Windows)
import Foundation
import XCTest
@testable import PokeTokenBar

private struct WindowsCompanionUXStubProvider: PokeProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine {
        EvoLine(baseID: baseSpeciesID,
                tree: EvoNode(speciesID: baseSpeciesID, children: []),
                rarity: .common,
                names: [baseSpeciesID: ["en": "Mon\(baseSpeciesID)"]])
    }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
}

final class WindowsCompanionUXParityTests: XCTestCase {
    private func makeStateURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("windows-companion-ux-\(UUID().uuidString).json")
        let dex: [[String: Any]] = [[
            "id": "saved",
            "baseID": 25,
            "finalID": 25,
            "chainOrder": [25],
            "rarity": "common",
            "caughtAt": 800_000_000.0,
            "isShiny": true,
            "nature": "jolly",
            "names": ["25": ["en": "Pikachu"]],
        ]]
        let obj: [String: Any] = [
            "installBaselineSet": true,
            "usedSinceInstall": 1_000_000_000,
            "spentTokens": 0,
            "eggUsage": 0,
            "claimedTodayTokens": 0,
            "lastDate": "d1",
            "dex": dex,
            "collectedFinals": [],
            "inventory": [:],
            "candyGrantTier": [:],
            "candyFeatureSeeded": true,
            "language": "en",
        ]
        try JSONSerialization.data(withJSONObject: obj).write(to: url)
        return url
    }

    func testRepresentativeSelectionPersistsAndDrivesVisualSubject() async throws {
        let url = try makeStateURL(); defer { try? FileManager.default.removeItem(at: url) }
        let store = await CompanionStore(provider: WindowsCompanionUXStubProvider(), fileURL: url)
        XCTAssertTrue(await store.setRepresentativeSpeciesID(25))
        let first = await store.windowsDisplay
        XCTAssertEqual(first.representativeSpeciesID, 25)
        XCTAssertEqual(first.visualSpeciesID, 25)
        XCTAssertTrue(first.visualIsShiny)

        let reloaded = await CompanionStore(provider: WindowsCompanionUXStubProvider(), fileURL: url)
        XCTAssertEqual(await reloaded.representativeSpeciesID, 25)
        XCTAssertFalse(await reloaded.setRepresentativeSpeciesID(999), "unowned species must be rejected")
        XCTAssertEqual(await reloaded.representativeSpeciesID, 25, "failed selection must not clear the previous choice")
        XCTAssertTrue(await reloaded.setRepresentativeSpeciesID(nil))
        XCTAssertNil(await reloaded.representativeSpeciesID)
    }

    func testFloatingPetSizeIsBounded() {
        XCTAssertEqual(WindowsFloatingPet.clampedSize(1), WindowsFloatingPet.minSize)
        XCTAssertEqual(WindowsFloatingPet.clampedSize(96), 96)
        XCTAssertEqual(WindowsFloatingPet.clampedSize(999), WindowsFloatingPet.maxSize)
    }
}
#endif
'''
Path("Tests/PokeTokenBarWindowsTests/WindowsCompanionUXParityTests.swift").write_text(test, encoding="utf-8")

print("patched Windows companion UX parity")
