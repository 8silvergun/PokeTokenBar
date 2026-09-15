from pathlib import Path

path = Path("Sources/PokeTokenBar/WindowsTray.swift")
s = path.read_text(encoding="utf-8")


def rep(old: str, new: str, count: int = 1) -> None:
    global s
    actual = s.count(old)
    if actual != count:
        raise SystemExit(f"expected {count} occurrence(s), found {actual}: {old[:140]!r}")
    s = s.replace(old, new, count)


# Collection view state: macOS parity uses a Dex/Catch Log sub-view, rarity filter and paged dex.
rep(
    "    nonisolated(unsafe) private static var dexScroll: Int32 = 0           // dex grid scroll offset (px)\n"
    "    nonisolated(unsafe) private static var shopScroll: Int32 = 0          // shop cards scroll offset (px)\n",
    "    nonisolated(unsafe) private static var dexScroll: Int32 = 0           // catch-log scroll offset (px)\n"
    "    nonisolated(unsafe) private static var dexMode = 0                    // 0=dex species, 1=catch log\n"
    "    nonisolated(unsafe) private static var dexFilter = 0                  // 0=all, 1=common..4=legendary\n"
    "    nonisolated(unsafe) private static var dexPage = 0                    // 24 species/page (4 x 6)\n"
    "    nonisolated(unsafe) private static var shopScroll: Int32 = 0          // shop cards scroll offset (px)\n",
)

# Replace the old single final-species grid with the two-axis collection UI.
start = s.index("    private static func paintDex(_ hdc: HDC?, _ disp: CompanionDisplay) {")
end = s.index("    private static func shopMaxScroll() -> Int32 {", start)
new_dex = r'''    private static func dexRarityKey(_ filter: Int) -> String? {
        switch filter {
        case 1: return "common"
        case 2: return "uncommon"
        case 3: return "rare"
        case 4: return "legendary"
        default: return nil
        }
    }

    private static func filteredDex(_ items: [DexItem]) -> [DexItem] {
        guard let key = dexRarityKey(dexFilter) else { return items }
        return items.filter { $0.rarity == key }
    }

    private static func filteredCatchLog(_ items: [CatchLogItem]) -> [CatchLogItem] {
        guard let key = dexRarityKey(dexFilter) else { return items }
        return items.filter { $0.rarity == key }
    }

    private static func drawDexControls(_ hdc: HDC?, _ disp: CompanionDisplay) {
        let segTop = contentTop + 28
        let gap: Int32 = 6
        let segW = (popupWidth - 40 - gap) / 2
        let dexRect = RECT(left: 20, top: segTop, right: 20 + segW, bottom: segTop + 28)
        let logRect = RECT(left: dexRect.right + gap, top: segTop, right: popupWidth - 20, bottom: segTop + 28)
        drawButton(hdc, dexRect, L("도감", "Pokédex", "図鑑"), enabled: true, selected: dexMode == 0)
        drawButton(hdc, logRect, L("포획 로그", "Catch log", "捕獲ログ"), enabled: true, selected: dexMode == 1)
        buttonHits.append((dexRect, 300)); buttonHits.append((logRect, 301))

        let labels = [
            L("전체", "All", "すべて"),
            L("일반", "Common", "ノーマル"),
            L("고급", "Uncommon", "アンコモン"),
            L("희귀", "Rare", "レア"),
            L("전설", "Legend", "伝説"),
        ]
        let top = segTop + 36
        let filterGap: Int32 = 4
        let cellW = (popupWidth - 32 - filterGap * 4) / 5
        let f = makeFont(-11, bold: true); let old = SelectObject(hdc, f)
        for i in 0..<labels.count {
            let left = 16 + Int32(i) * (cellW + filterGap)
            let r = RECT(left: left, top: top, right: left + cellW, bottom: top + 24)
            fillRound(hdc, r, 8, dexFilter == i ? rgb(48, 82, 120) : rgb(42, 42, 50))
            SetTextColor(hdc, dexFilter == i ? rgb(230, 240, 255) : rgb(160, 160, 172))
            var tr = r
            drawText(labels[i], in: hdc, rect: &tr, format: UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE))
            buttonHits.append((r, 310 + i))
        }
        SelectObject(hdc, old); DeleteObject(f)
    }

    private static func paintDex(_ hdc: HDC?, _ disp: CompanionDisplay) {
        let species = filteredDex(disp.dex)
        let log = filteredCatchLog(disp.catchLog)
        let count = dexMode == 0 ? species.count : log.count
        sectionHeader(hdc, "\(L("컬렉션", "Collection", "コレクション")) (\(count))")
        drawDexControls(hdc, disp)
        if dexMode == 0 { paintDexSpecies(hdc, species) }
        else { paintCatchLog(hdc, log) }
    }

    private static func paintDexSpecies(_ hdc: HDC?, _ items: [DexItem]) {
        let pageSize = 24
        let pageCount = max(1, (items.count + pageSize - 1) / pageSize)
        dexPage = min(max(0, dexPage), pageCount - 1)
        let pageItems = Array(items.dropFirst(dexPage * pageSize).prefix(pageSize))
        let gridTop: Int32 = 148

        if pageItems.isEmpty {
            SetTextColor(hdc, rgb(150, 150, 158))
            let f = makeFont(-14, bold: false); let o = SelectObject(hdc, f)
            var r = RECT(left: 24, top: 250, right: popupWidth - 24, bottom: 310)
            drawText(L("이 조건에 등록된 포켓몬이 없어요.", "No Pokémon in this filter.", "この条件のポケモンはいません。"),
                     in: hdc, rect: &r, format: UINT(DT_CENTER | DT_WORDBREAK))
            SelectObject(hdc, o); DeleteObject(f)
        } else {
            let cellW = (popupWidth - 24) / dexCols
            let cellH: Int32 = 68
            let saved = SaveDC(hdc)
            IntersectClipRect(hdc, 0, gridTop - 2, popupWidth, popupHeight - 68)
            let nameFont = makeFont(-10, bold: false); let nOld = SelectObject(hdc, nameFont)
            for (i, item) in pageItems.enumerated() {
                let col = Int32(i) % dexCols, row = Int32(i) / dexCols
                let cx = 12 + col * cellW
                let cy = gridTop + row * cellH
                if item.isRaising {
                    fillRound(hdc, RECT(left: cx + 4, top: cy, right: cx + cellW - 4, bottom: cy + cellH - 4),
                              10, rgb(38, 54, 70))
                }
                if let ic = lock.withLock({ dexIcons[item.speciesID] }) {
                    DrawIconEx(hdc, cx + (cellW - 40) / 2, cy + 2, ic, 40, 40, 0, nil, UINT(DI_NORMAL))
                }
                if item.isRaising {
                    let mf = makeFont(-10, bold: true); let mo = SelectObject(hdc, mf)
                    SetTextColor(hdc, rgb(120, 200, 255))
                    var mr = RECT(left: cx + 6, top: cy + 2, right: cx + 24, bottom: cy + 18)
                    drawText("●", in: hdc, rect: &mr, format: UINT(DT_LEFT | DT_SINGLELINE))
                    SelectObject(hdc, mo); DeleteObject(mf)
                }
                SetTextColor(hdc, rarityColor(item.rarity))
                var nr = RECT(left: cx + 2, top: cy + 43, right: cx + cellW - 2, bottom: cy + 61)
                let label = (item.isShiny ? "* " : "") + item.name
                drawText(label, in: hdc, rect: &nr, format: UINT(DT_CENTER | DT_SINGLELINE | DT_END_ELLIPSIS))
            }
            SelectObject(hdc, nOld); DeleteObject(nameFont)
            RestoreDC(hdc, saved)
        }

        let navY = popupHeight - 58
        let prev = RECT(left: 20, top: navY, right: 78, bottom: navY + 28)
        let next = RECT(left: popupWidth - 78, top: navY, right: popupWidth - 20, bottom: navY + 28)
        drawButton(hdc, prev, "‹", enabled: dexPage > 0)
        drawButton(hdc, next, "›", enabled: dexPage + 1 < pageCount)
        if dexPage > 0 { buttonHits.append((prev, 320)) }
        if dexPage + 1 < pageCount { buttonHits.append((next, 321)) }
        let f = makeFont(-12, bold: true); let o = SelectObject(hdc, f)
        SetTextColor(hdc, rgb(160, 160, 172))
        var pr = RECT(left: 86, top: navY, right: popupWidth - 86, bottom: navY + 28)
        drawText("\(dexPage + 1) / \(pageCount)", in: hdc, rect: &pr, format: UINT(DT_CENTER | DT_VCENTER | DT_SINGLELINE))
        SelectObject(hdc, o); DeleteObject(f)
    }

    private static func paintCatchLog(_ hdc: HDC?, _ items: [CatchLogItem]) {
        let logTop: Int32 = 144
        let rowH: Int32 = 82
        let saved = SaveDC(hdc)
        IntersectClipRect(hdc, 0, logTop, popupWidth, popupHeight)
        let df = DateFormatter()
        df.locale = Locale(identifier: uiLang)
        df.dateStyle = .short; df.timeStyle = .short

        if items.isEmpty {
            SetTextColor(hdc, rgb(150, 150, 158))
            let f = makeFont(-14, bold: false); let o = SelectObject(hdc, f)
            var r = RECT(left: 24, top: 250, right: popupWidth - 24, bottom: 310)
            drawText(L("이 조건의 포획 기록이 없어요.", "No catches in this filter.", "この条件の捕獲記録はありません。"),
                     in: hdc, rect: &r, format: UINT(DT_CENTER | DT_WORDBREAK))
            SelectObject(hdc, o); DeleteObject(f)
            RestoreDC(hdc, saved)
            return
        }

        for (i, item) in items.enumerated() {
            let y = logTop + Int32(i) * rowH - dexScroll
            if y + rowH < logTop || y > popupHeight { continue }
            let card = RECT(left: 16, top: y + 3, right: popupWidth - 16, bottom: y + rowH - 5)
            fillRound(hdc, card, 10, item.isRaising ? rgb(38, 54, 70) : rgb(32, 32, 38))
            if let ic = lock.withLock({ dexIcons[item.speciesID] }) {
                DrawIconEx(hdc, 24, y + 12, ic, 44, 44, 0, nil, UINT(DI_NORMAL))
            }
            let titleFont = makeFont(-13, bold: true); var o = SelectObject(hdc, titleFont)
            SetTextColor(hdc, rarityColor(item.rarity))
            var tr = RECT(left: 78, top: y + 9, right: popupWidth - 24, bottom: y + 28)
            drawText((item.isShiny ? "* " : "") + item.name, in: hdc, rect: &tr,
                     format: UINT(DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS))
            SelectObject(hdc, o); DeleteObject(titleFont)

            let status: String
            if item.isRaising { status = L("키우는 중", "Raising", "育成中") }
            else if item.isReleased { status = L("놓아줌", "Released", "手放し") }
            else { status = L("졸업", "Graduated", "卒業") }
            let when = item.caughtAt.map { df.string(from: $0) } ?? ""
            let info = [status, item.nature, when].filter { !$0.isEmpty }.joined(separator: " · ")
            let infoFont = makeFont(-11, bold: false); o = SelectObject(hdc, infoFont)
            SetTextColor(hdc, rgb(150, 150, 162))
            var ir = RECT(left: 78, top: y + 29, right: popupWidth - 24, bottom: y + 47)
            drawText(info, in: hdc, rect: &ir, format: UINT(DT_LEFT | DT_SINGLELINE | DT_END_ELLIPSIS))
            SelectObject(hdc, o); DeleteObject(infoFont)

            var x: Int32 = 78
            for id in item.chainIDs.prefix(7) {
                if let ic = lock.withLock({ dexIcons[id] }) { DrawIconEx(hdc, x, y + 49, ic, 22, 22, 0, nil, UINT(DI_NORMAL)) }
                x += 28
            }
        }
        RestoreDC(hdc, saved)
    }

'''
s = s[:start] + new_dex + s[end:]

# Old grid scroll helper becomes catch-log-only scroll helper.
old_scroll = '''    /// Max scroll offset for the current dex (rows below the fold).
    private static func dexMaxScroll(_ count: Int) -> Int32 {
        let rows = Int32((count + Int(dexCols) - 1) / Int(dexCols))
        let contentH = rows * dexCellH
        let visibleH = popupHeight - dexGridTop - 8
        return max(0, contentH - visibleH)
    }
'''
new_scroll = '''    private static func dexLogMaxScroll(_ count: Int) -> Int32 {
        let logTop: Int32 = 144, rowH: Int32 = 82
        let visibleH = popupHeight - logTop - 8
        return max(0, Int32(count) * rowH - visibleH)
    }
'''
rep(old_scroll, new_scroll)

# Reset collection paging when entering the Collection tab; handle subview/filter/page controls.
rep(
    "                if popupView == 3 { dexScroll = 0 }\n",
    "                if popupView == 3 { dexScroll = 0; dexPage = 0 }\n",
)
rep(
    "            case 70...74: selectInterval(action - 70)   // interval preset\n"
    "            case 80...199: selectWSL(action - 80)\n",
    "            case 70...74: selectInterval(action - 70)   // interval preset\n"
    "            case 80...199: selectWSL(action - 80)\n"
    "            case 300, 301:\n"
    "                dexMode = action - 300; dexScroll = 0; dexPage = 0\n"
    "                if let popupHwnd { InvalidateRect(popupHwnd, nil, true) }\n"
    "            case 310...314:\n"
    "                dexFilter = action - 310; dexScroll = 0; dexPage = 0\n"
    "                if let popupHwnd { InvalidateRect(popupHwnd, nil, true) }\n"
    "            case 320:\n"
    "                dexPage = max(0, dexPage - 1); if let popupHwnd { InvalidateRect(popupHwnd, nil, true) }\n"
    "            case 321:\n"
    "                dexPage += 1; if let popupHwnd { InvalidateRect(popupHwnd, nil, true) }\n",
)

# Mouse wheel only scrolls the Catch Log; the Pokédex is paged like macOS.
rep(
    "            } else if WindowsTray.popupView == 3, let h = WindowsTray.popupHwnd {   // dex view\n"
    "                let count = WindowsTray.lock.withLock { WindowsTray.currentDisplay.dex.count }\n"
    "                let maxS = WindowsTray.dexMaxScroll(count)\n"
    "                WindowsTray.dexScroll = min(maxS, max(0, WindowsTray.dexScroll - delta / 120 * 52))\n"
    "                InvalidateRect(h, nil, true)\n",
    "            } else if WindowsTray.popupView == 3, WindowsTray.dexMode == 1, let h = WindowsTray.popupHwnd {   // catch log\n"
    "                let count = WindowsTray.lock.withLock { WindowsTray.filteredCatchLog(WindowsTray.currentDisplay.catchLog).count }\n"
    "                let maxS = WindowsTray.dexLogMaxScroll(count)\n"
    "                WindowsTray.dexScroll = min(maxS, max(0, WindowsTray.dexScroll - delta / 120 * 52))\n"
    "                InvalidateRect(h, nil, true)\n",
)

# Sendable snapshot now carries species-folded dex and individual catch-log records.
rep(
    "    var dex: [DexItem] = []\n"
    "    var lineNodes: [EvoThumb] = []   // evolution line thumbnails for the Home card\n",
    "    var dex: [DexItem] = []\n"
    "    var catchLog: [CatchLogItem] = []\n"
    "    var lineNodes: [EvoThumb] = []   // evolution line thumbnails for the Home card\n",
)
rep(
    '''/// One caught Pokémon for the Windows dex grid.
struct DexItem: Sendable {
    var speciesID: Int
    var name: String
    var rarity: String
    var isShiny: Bool
}
''',
    '''/// One species cell for the Windows Pokédex. This is species-folded (not one row per catch).
struct DexItem: Sendable {
    var speciesID: Int
    var name: String
    var rarity: String
    var isShiny: Bool
    var isRaising: Bool
}

/// One individual record for the Windows Catch Log.
struct CatchLogItem: Sendable {
    var id: String
    var speciesID: Int
    var chainIDs: [Int]
    var name: String
    var rarity: String
    var isShiny: Bool
    var nature: String
    var caughtAt: Date?
    var isReleased: Bool
    var isRaising: Bool
}
''',
)

# Map the shared Core collection semantics directly into the Windows snapshot.
old_mapping = '''            dex: dexEntriesSorted.map { e in
                DexItem(speciesID: e.finalID,
                        name: dexStoredChainNames(e)?[e.finalID] ?? "#\(e.finalID)",
                        rarity: String(describing: e.rarity), isShiny: e.isShiny)
            },
            lineNodes: hasActive ? lineNodes.map { EvoThumb(id: $0.id, kind: $0.kind) } : [],
'''
new_mapping = '''            dex: dexSpecies.map { sp in
                DexItem(speciesID: sp.id, name: sp.name,
                        rarity: String(describing: sp.rarity), isShiny: sp.isShiny, isRaising: sp.isRaising)
            },
            catchLog: dexEntriesSorted.map { e in
                CatchLogItem(id: e.id, speciesID: e.finalID, chainIDs: e.chainOrder,
                             name: dexStoredChainNames(e)?[e.finalID] ?? "#\(e.finalID)",
                             rarity: String(describing: e.rarity), isShiny: e.isShiny,
                             nature: e.nature.map { $0.name(language) } ?? "",
                             caughtAt: e.caughtAt, isReleased: e.isReleased, isRaising: isActiveDexEntry(e))
            },
            lineNodes: hasActive ? lineNodes.compactMap { item in
                guard case .species(let id) = item.subject else { return nil }
                let kind: String
                switch item.state { case .done: kind = "done"; case .current: kind = "cur"; case .future: kind = "future" }
                return EvoThumb(id: id, kind: kind)
            } : [],
'''
rep(old_mapping, new_mapping)

path.write_text(s, encoding="utf-8")
print("patched", path)
