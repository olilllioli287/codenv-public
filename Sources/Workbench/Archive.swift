import Foundation

// 封存：一個禮拜沒碰的對話收進那個資料夾的「封存」裡（側欄最下面一個按鈕，展開是灰色字）。
// 「沒碰」＝最後一次打開，和最後一次有新內容（紀錄檔修改時間），兩個都超過 7 天。
// 正在跑的、正擺在畫面某一格的不收；打開封存裡的對話就算碰過，自己回到上面。

extension Store {
    static var archiveAfter: TimeInterval { TimeInterval(Prefs.shared.archiveDays) * 24 * 3600 }

    /// 重讀每段對話紀錄檔的修改時間
    func refreshActivity() {
        var out: [UUID: Date] = [:]
        for c in conversations {
            let path = project(c.projectID)?.path ?? NSHomeDirectory()
            let url = Store.claudeTranscript(c.claudeSession, path: path)
            if let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate { out[c.id] = d }
        }
        if out != lastActivity { lastActivity = out }
        assignMissingOrders()
    }

    func lastTouched(_ c: Conversation) -> Date { max(c.lastOpened, lastActivity[c.id] ?? .distantPast) }

    func isArchived(_ c: Conversation) -> Bool {
        if c.manualArchive == true { return true }               // 自己按了封存
        if status[c.id] != nil { return false }                 // 正在跑
        if locate(c.id) != nil { return false }                  // 擺在畫面上
        return Date().timeIntervalSince(lastTouched(c)) > Store.archiveAfter
    }

    /// 右鍵「封存」／「取消封存」
    func setArchived(_ id: UUID, _ on: Bool) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[i].manualArchive = on ? true : nil
        // 取消封存：當作剛碰過，不然一個禮拜沒碰的規則又會馬上把它收回去
        if !on { conversations[i].lastOpened = Date() }
        if on { pruneBundles() }   // 自己封存＝離開掛件框
    }

    // MARK: 固定順序

    /// 側欄排序：照 order（小的在上）；還沒排過的放最後、照最後碰的時間
    func orderedBefore(_ a: Conversation, _ b: Conversation) -> Bool {
        switch (a.order, b.order) {
        case let (x?, y?): return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return lastTouched(a) > lastTouched(b)
        }
    }

    /// 還沒有順序的對話：照目前的樣子（最後碰的在上）排一次，之後就固定
    func assignMissingOrders() {
        guard conversations.contains(where: { $0.order == nil }) else { return }
        let start = (conversations.compactMap(\.order).max() ?? 0) + 1
        let missing = conversations.indices.filter { conversations[$0].order == nil }
            .sorted { lastTouched(conversations[$0]) > lastTouched(conversations[$1]) }
        for (n, i) in missing.enumerated() { conversations[i].order = start + Double(n) }
    }

    /// 拖到另一段對話上：排到它前面（不同組就順便移過去）
    func reorder(_ id: UUID, before target: UUID) {
        guard id != target, let t = conversation(target), let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        if let g = groupOf(t), groupOf(conversations[i]) != g { move(id, toGroup: g) }
        // 鄰居從目標那一串（畫面上看到的那份清單）找：排在目標正上方那個和目標的中間
        let list = siblings(of: t)
        let to = t.order ?? 0
        let prev = list.last { ($0.order ?? 0) < to && $0.id != id }?.order ?? (to - 1)
        conversations[i].order = (prev + to) / 2
        renumberIfTight()
        setBundle(id, t.bundle)   // 拖到框裡的某段旁邊＝加入那個框；拖到框外＝離開
    }

    /// 拖到另一段對話的下半：排到它後面
    func reorder(_ id: UUID, after target: UUID) {
        guard id != target, let t = conversation(target), let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        if let g = groupOf(t), groupOf(conversations[i]) != g { move(id, toGroup: g) }
        let list = siblings(of: t)
        let to = t.order ?? 0
        let next = list.first { ($0.order ?? 0) > to && $0.id != id }?.order ?? (to + 1)
        conversations[i].order = (to + next) / 2
        renumberIfTight()
        setBundle(id, t.bundle)
    }

    /// 側欄上跟它排在同一串的：有分組＝同一組（不分資料夾）；沒分組＝同一個資料夾。封存的另外一串
    func siblings(of c: Conversation) -> [Conversation] {
        let g = groupOf(c), a = isArchived(c)
        return conversations.filter {
            !$0.isGadget && (groups.isEmpty ? $0.projectID == c.projectID : groupOf($0) == g) && isArchived($0) == a
        }.sorted(by: orderedBefore)
    }

    /// 一直插在同兩個中間，間距會小到分不出前後：太擠就整份照目前順序重新編成 1、2、3…
    private func renumberIfTight() {
        let sorted = conversations.indices.sorted { orderedBefore(conversations[$0], conversations[$1]) }
        let orders = sorted.compactMap { conversations[$0].order }
        guard zip(orders, orders.dropFirst()).contains(where: { $1 - $0 < 1e-6 }) else { return }
        for (n, i) in sorted.enumerated() { conversations[i].order = Double(n + 1) }
    }

    /// 右鍵「上移／下移／移到最上面」：在同一個資料夾的清單裡換位置
    func shift(_ id: UUID, by delta: Int) {
        guard let c = conversation(id) else { return }
        let list = siblings(of: c)
        guard let k = list.firstIndex(where: { $0.id == id }) else { return }
        let j = max(0, min(list.count - 1, k + delta))
        guard j != k, let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        if delta < 0 {
            let above = list[j].order ?? 0
            let before = j > 0 ? (list[j - 1].order ?? above - 1) : above - 1
            conversations[i].order = (before + above) / 2
        } else {
            let below = list[j].order ?? 0
            let after = j + 1 < list.count ? (list[j + 1].order ?? below + 1) : below + 1
            conversations[i].order = (below + after) / 2
        }
        renumberIfTight()
    }

    func toggleArchive(_ project: UUID) {
        guard let i = projects.firstIndex(where: { $0.id == project }) else { return }
        projects[i].archiveOpen = !(projects[i].archiveOpen ?? false)
    }
}
