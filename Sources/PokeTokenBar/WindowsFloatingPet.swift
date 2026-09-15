#if os(Windows)
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
            // Only one instance calls prepare(); if registration ever races, CreateWindowExW below
            // is still the authoritative success/failure signal, so no imported ERROR_* constant needed.
            return RegisterClassExW(&wc) != 0
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
        else { _ = PostMessageW(sink, message, 0, LPARAM(Int(event))) }
    }

    private static func openPopover() { postTrayMessage(UINT(WM_APP) + 3) }
    private static func openTrayMenu() { postTrayMessage(UINT(WM_APP) + 1, event: UINT(WM_CONTEXTMENU)) }

    private static let windowProc: WNDPROC = { hWnd, uMsg, wParam, lParam in
        switch uMsg {
        case UINT(WM_TIMER):
            if wParam == WPARAM(WindowsFloatingPet.timerID) { WindowsFloatingPet.syncSettings() }
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
