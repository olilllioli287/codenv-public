import AppKit
import CoreGraphics

// 版面：照 tmux 的三層 Session → Window → Pane，但每個 Pane 放的是一段對話。
// Window 裡的 Pane 是一棵二元樹（跟 Ghostty 的 SplitTree 一樣）：葉子是對話，節點是左右或上下切開。
// 版面只「連到」對話，不擁有對話：關掉 Pane 對話還在側欄，之後可以再打開。

indirect enum PaneNode: Codable, Equatable {
    case leaf(UUID)                                   // 對話的 id
    case split(vertical: Bool, ratio: Double, a: PaneNode, b: PaneNode)   // vertical＝上下切（a 在上）

    var leaves: [UUID] {
        switch self {
        case .leaf(let id): return [id]
        case .split(_, _, let a, let b): return a.leaves + b.leaves
        }
    }

    func contains(_ id: UUID) -> Bool { leaves.contains(id) }

    /// 把某片葉子換成別的子樹
    func replacing(_ id: UUID, with node: PaneNode) -> PaneNode {
        switch self {
        case .leaf(let x): return x == id ? node : self
        case .split(let v, let r, let a, let b): return .split(vertical: v, ratio: r, a: a.replacing(id, with: node), b: b.replacing(id, with: node))
        }
    }

    /// 兩片葉子互換位置（版面形狀、比例都不變）
    func swapping(_ x: UUID, _ y: UUID) -> PaneNode {
        switch self {
        case .leaf(let id): return id == x ? .leaf(y) : id == y ? .leaf(x) : self
        case .split(let v, let r, let a, let b): return .split(vertical: v, ratio: r, a: a.swapping(x, y), b: b.swapping(x, y))
        }
    }

    /// 拿掉某片葉子；它的兄弟頂上來。整棵沒了回傳 nil
    func removing(_ id: UUID) -> PaneNode? {
        switch self {
        case .leaf(let x): return x == id ? nil : self
        case .split(let v, let r, let a, let b):
            let na = a.removing(id), nb = b.removing(id)
            if let na, let nb { return .split(vertical: v, ratio: r, a: na, b: nb) }
            return na ?? nb
        }
    }

    /// 某片葉子的上一層：怎麼切、比例、它在前面（a）還是後面（b）、另一邊是什麼（⌘ ⇧ T 把關掉的格子放回原位用）
    func parent(of id: UUID) -> (vertical: Bool, ratio: Double, first: Bool, sibling: PaneNode)? {
        guard case .split(let v, let r, let a, let b) = self else { return nil }
        if a == .leaf(id) { return (v, r, true, b) }
        if b == .leaf(id) { return (v, r, false, a) }
        return a.parent(of: id) ?? b.parent(of: id)
    }

    /// 把某棵子樹（完全一樣的）換掉；找不到回傳 nil
    func replacingSubtree(_ old: PaneNode, with new: PaneNode) -> PaneNode? {
        if self == old { return new }
        guard case .split(let v, let r, let a, let b) = self else { return nil }
        if let na = a.replacingSubtree(old, with: new) { return .split(vertical: v, ratio: r, a: na, b: b) }
        if let nb = b.replacingSubtree(old, with: new) { return .split(vertical: v, ratio: r, a: a, b: nb) }
        return nil
    }

    /// 每片葉子在 0～1 正方形裡的位置（y 往下）
    func rects(in r: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> [UUID: CGRect] {
        switch self {
        case .leaf(let id): return [id: r]
        case .split(let v, let ratio, let a, let b):
            let (ra, rb) = Self.divide(r, vertical: v, ratio: ratio)
            return a.rects(in: ra).merging(b.rects(in: rb)) { x, _ in x }
        }
    }

    static func divide(_ r: CGRect, vertical: Bool, ratio: Double) -> (CGRect, CGRect) {
        if vertical {
            let h = r.height * ratio
            return (CGRect(x: r.minX, y: r.minY, width: r.width, height: h), CGRect(x: r.minX, y: r.minY + h, width: r.width, height: r.height - h))
        }
        let w = r.width * ratio
        return (CGRect(x: r.minX, y: r.minY, width: w, height: r.height), CGRect(x: r.minX + w, y: r.minY, width: r.width - w, height: r.height))
    }

    /// 調大小：找離這片葉子最近、方向對的那個切口，把分界線往 dir 推一點
    /// dir：左右切口用 -1（往左）/+1（往右）；上下切口用 -1（往上）/+1（往下）
    func resizing(_ id: UUID, vertical: Bool, by delta: Double) -> PaneNode {
        func go(_ n: PaneNode) -> (PaneNode, Bool) {
            guard case .split(let v, let r, let a, let b) = n else { return (n, false) }
            let inA = a.contains(id), inB = b.contains(id)
            guard inA || inB else { return (n, false) }
            let (na, da) = inA ? go(a) : (a, false)
            let (nb, db) = inB ? go(b) : (b, false)
            if da || db { return (.split(vertical: v, ratio: r, a: na, b: nb), true) }
            if v == vertical { return (.split(vertical: v, ratio: min(0.9, max(0.1, r + delta)), a: a, b: b), true) }
            return (n, false)
        }
        return go(self).0
    }

    /// 改某個切口的比例（拖分隔線用）：path 是從根走下來的 a/b（false＝a）
    func settingRatio(path: [Bool], _ ratio: Double) -> PaneNode {
        guard case .split(let v, let r, let a, let b) = self else { return self }
        if path.isEmpty { return .split(vertical: v, ratio: min(0.92, max(0.08, ratio)), a: a, b: b) }
        let rest = Array(path.dropFirst())
        return path[0] ? .split(vertical: v, ratio: r, a: a, b: b.settingRatio(path: rest, ratio))
                       : .split(vertical: v, ratio: r, a: a.settingRatio(path: rest, ratio), b: b)
    }
}

struct WindowLayout: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var root: PaneNode?
    var focused: UUID?        // 目前在打字的那格（對話 id）
    var zoomed = false        // Ctrl+A z：只顯示目前那格
    /// 使用者自己取過名字；沒取的話名字跟著目前那格的對話標題
    var renamed = false
    /// 拉出去變成獨立視窗了（⌘ Q 再回來不用再移動位置，所以存檔、重開還原）。獨立的 Window 一律排在 Session 的 windows 最後面，主視窗的分頁用前面那幾個，位置編號不會錯
    var detached = false
    /// 獨立視窗的位置和大小：x、y、寬、高，x、y 是相對它所在螢幕左下角的位移（螢幕排列變了也不會跑掉）；detachedScreen＝那個螢幕的名字（NSScreen.localizedName）
    var detachedFrame: [Double]? = nil
    var detachedScreen: String? = nil
    /// 那個螢幕的 frame 原點（x、y）：兩台同型號螢幕名字一樣，還原時先找名字和原點都對得上的
    var detachedScreenOrigin: [Double]? = nil
}

/// 舊存檔沒有 zoomed、renamed 這些後來加的欄位：缺了用預設值（自動產生的解碼不吃屬性預設值）
extension WindowLayout {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        root = try c.decodeIfPresent(PaneNode.self, forKey: .root)
        focused = try c.decodeIfPresent(UUID.self, forKey: .focused)
        zoomed = try c.decodeIfPresent(Bool.self, forKey: .zoomed) ?? false
        renamed = try c.decodeIfPresent(Bool.self, forKey: .renamed) ?? false
        detached = try c.decodeIfPresent(Bool.self, forKey: .detached) ?? false
        detachedFrame = try c.decodeIfPresent([Double].self, forKey: .detachedFrame)
        detachedScreen = try c.decodeIfPresent(String.self, forKey: .detachedScreen)
        detachedScreenOrigin = try c.decodeIfPresent([Double].self, forKey: .detachedScreenOrigin)
    }
}

struct SessionLayout: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var windows: [WindowLayout]
    var current: UUID?
    /// 屬於哪一區：nil＝首頁、"codelab"＝程式碼學習專區（codelab 的 Session／Window 跟首頁分開）。舊存檔沒有這欄＝首頁
    var area: String? = nil
    /// 總指揮涵蓋的頂層組（查詢時包含所有子組）；nil＝一般版面，空陣列仍是已設定的總指揮
    var groups: [UUID]? = nil
    /// 總指揮聊天室；只記關聯，不代表要啟動程序或搬動 Window
    var chief: UUID? = nil
    /// 總指揮類型："single"＝整個總指揮是一個專案；"multi"＝底下的子群組各是一個子專案；nil＝依群組結構推斷（有子群組＝multi）
    var commanderKind: String? = nil
}

/// 舊存檔沒有總指揮欄位，照 WindowLayout 的慣例用手寫解碼保留相容性
extension SessionLayout {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        windows = try c.decode([WindowLayout].self, forKey: .windows)
        current = try c.decodeIfPresent(UUID.self, forKey: .current)
        area = try c.decodeIfPresent(String.self, forKey: .area)
        groups = try c.decodeIfPresent([UUID].self, forKey: .groups)
        chief = try c.decodeIfPresent(UUID.self, forKey: .chief)
        commanderKind = try c.decodeIfPresent(String.self, forKey: .commanderKind)
    }
}

extension Store {
    // MARK: 目前的 Session／Window

    var sessionIndex: Int? {
        // 範圍（scope）：獨立視窗拿到鍵盤焦點時，所有「改目前的 Window」的操作（切格、拖曳、關格、比例…）都落在它身上，不動主視窗現在看的那個
        // 指著的 Window 已經不在（獨立視窗的版面被搬空、刪掉）：回 nil，不要退回主視窗那個——不然獨立視窗會畫主視窗的格子，把主視窗的聊天畫面搶走
        if let sc = scope { return sessions.firstIndex(where: { $0.windows.contains { $0.id == sc } }) }
        return sessions.firstIndex { $0.id == currentSession && inArea($0) } ?? sessions.firstIndex(where: inArea)
    }

    /// 在某個 Window 的範圍裡做事（nil＝主視窗那邊）：做完還原
    func scoped<T>(_ id: UUID?, _ f: () -> T) -> T {
        let old = scope
        scope = id
        defer { scope = old }
        return f()
    }

    // MARK: 兩區（首頁／程式碼學習專區）各一套 Session

    static let codeLabArea = "codelab"
    /// 目前這區的 Session 在 area 欄位存什麼（首頁是 nil）
    var areaKey: String? { area == Store.codeLabArea ? Store.codeLabArea : nil }
    func inArea(_ s: SessionLayout) -> Bool { s.area == areaKey }
    var areaSessions: [SessionLayout] { sessions.filter(inArea) }

    /// 目前的 Session 換到另一區的（點了那區的對話、⌘ ⇧ T 找回之類）：側欄跟著換區；也記下每區上次看的是哪個 Session
    func followSessionArea() {
        guard let id = currentSession, let s = sessions.first(where: { $0.id == id }) else { return }
        let a = s.area ?? "home"
        appDefaults.set(id.uuidString, forKey: "areaSession." + a)
        if area != a { area = a }
    }

    /// 側欄圖示列換區：上面的 Session／Window 換成那一區的那一套（回到上次看的那個）
    func switchArea(_ a: String) {
        guard a != area else { return }
        scope = nil      // 換區是主視窗的事：不要讓後面的 editWindow 落在獨立視窗身上
        area = a
        ensureAreaSession()
        if let last = appDefaults.string(forKey: "areaSession." + a).flatMap(UUID.init(uuidString:)),
           sessions.contains(where: { $0.id == last && inArea($0) }) { currentSession = last }
        else { currentSession = areaSessions.first?.id }
        syncSelection()
    }

    /// 這一區還沒有 Session（第一次進 codelab、或關光了）：開一個空的
    func ensureAreaSession() {
        guard areaSessions.isEmpty else { return }
        let w = WindowLayout(name: "1")
        var s = SessionLayout(name: area == Store.codeLabArea ? "codelab" : "main", windows: [w], current: w.id)
        s.area = areaKey
        sessions.append(s)
    }

    var currentSessionLayout: SessionLayout? { sessionIndex.map { sessions[$0] } }

    var windowIndex: Int? {
        guard let si = sessionIndex else { return nil }
        let s = sessions[si]
        if let sc = scope, let wi = s.windows.firstIndex(where: { $0.id == sc }) { return wi }
        // 主視窗：獨立視窗不算（它們排在最後面）
        let shown = s.windows.firstIndex { $0.id == s.current && !$0.detached }
        return shown ?? s.windows.firstIndex { !$0.detached } ?? (s.windows.isEmpty ? nil : 0)
    }

    /// 加一個 Window 到 Session 的最後（獨立視窗的 Window 一律排在最後面，新的插在它們前面，主視窗分頁的位置編號才不會錯）
    func appendWindow(_ w: WindowLayout, at si: Int) {
        sessions[si].windows.insert(w, at: sessions[si].windows.firstIndex { $0.detached } ?? sessions[si].windows.count)
        partitionDetached(si)      // 新 Window 裡有總指揮聊天室的話，要排到最前面
    }

    /// 這個 Session 主視窗分頁列上的 Window 數（沒拉出去的）
    func visibleWindowCount(_ si: Int) -> Int { sessions[si].windows.filter { !$0.detached }.count }

    /// 不變量：獨立視窗的 Window 一律排在 Session 最後面（主視窗分頁列的編號才不會錯）。穩定排序，一般 Window 彼此的順序不變
    func partitionDetached(_ si: Int) {
        let w = sessions[si].windows
        var vis = w.filter { !$0.detached }
        // 總指揮模式：放總指揮聊天室的那個 Window 固定排主視窗分頁列的最前面（＝⌘ 1、最左邊的紫色方塊）
        if let ci = chiefWindowIndex(si, in: vis), ci != 0 { vis.insert(vis.remove(at: ci), at: 0) }
        let sorted = vis + w.filter { $0.detached }
        if sorted.map(\.id) != w.map(\.id) { sessions[si].windows = sorted }
    }

    // MARK: 總指揮 Window（分頁列最左邊的紫色方塊）

    /// 這個 Session 的總指揮聊天室 id（只有總指揮模式、而且聊天室還在才算）
    func chiefID(_ si: Int) -> UUID? {
        guard Prefs.shared.sidebarMode == "commander", sessions.indices.contains(si), sessions[si].area == nil,
              let c = sessions[si].chief, conversation(c) != nil else { return nil }
        return c
    }
    /// 一串 Window 裡放著總指揮聊天室的那個（只看主視窗分頁列上的，所以傳進來的是沒拉出去的）
    func chiefWindowIndex(_ si: Int, in vis: [WindowLayout]) -> Int? {
        guard let c = chiefID(si) else { return nil }
        return vis.firstIndex { $0.root?.contains(c) == true }
    }
    /// 總指揮在分頁列上的狀態：0＝不是總指揮模式；1＝總指揮 Window 就在分頁列最前面（它就是第 0 個分頁，畫成紫色方塊）；
    /// 2＝總指揮沒擺在任何 Window、或已經拉出去變獨立視窗（方塊獨立在最左邊，不佔分頁；⌘ 1 是它，其他分頁的 ⌘ 數字順延一個）
    func chiefTabMode(_ si: Int) -> Int {
        guard chiefID(si) != nil else { return 0 }
        let vis = sessions[si].windows.filter { !$0.detached }
        return chiefWindowIndex(si, in: vis) == nil ? 2 : 1
    }
    /// 這個 Window 是不是不能關的總指揮 Window（沒拉出去、裡面有總指揮聊天室；拉出去的獨立視窗可以關）
    func isChiefProtected(_ si: Int, _ wi: Int) -> Bool {
        guard let c = chiefID(si), sessions[si].windows.indices.contains(wi) else { return false }
        let w = sessions[si].windows[wi]
        return !w.detached && w.root?.contains(c) == true
    }
    /// 點紫色方塊／⌘ 1（總指揮沒在分頁列上時）：叫總指揮聊天室回來——在獨立視窗就叫到最前面，沒擺著就開一個 Window 放它
    func summonChief() {
        scope = nil
        guard let si = sessionIndex, let c = chiefID(si) else { return }
        windowSelected = false
        show(c)
        if let si = sessionIndex { partitionDetached(si) }
        syncSelection()
    }
    /// Ctrl+A 數字（只切過去、不選取整個 Window）：位置的算法同 toggleWindowSelection(slot:)
    func selectWindow(slot n: Int) {
        if let si = scoped(nil, { sessionIndex }), scoped(nil, { chiefTabMode(si) }) == 2 {
            if n == 0 { summonChief() } else { selectWindow(at: n - 1) }
        } else { selectWindow(at: n) }
    }
    /// ⌘ 數字用（0 起算的第幾個位置）：總指揮方塊算第 0 個
    func toggleWindowSelection(slot n: Int) {
        if let si = scoped(nil, { sessionIndex }), scoped(nil, { chiefTabMode(si) }) == 2 {
            if n == 0 { summonChief() } else { toggleWindowSelection(at: n - 1) }
        } else { toggleWindowSelection(at: n) }
    }

    /// 主視窗分頁列上一個可見的 Window 都沒有了（最後一個被關掉、刪掉、搬走）：在最前面補一個空的（獨立視窗不算主視窗的分頁）。回傳補的那個的 id
    @discardableResult
    func ensureVisibleWindow(_ si: Int) -> UUID? {
        guard visibleWindowCount(si) == 0 else { return nil }
        let p = WindowLayout(name: "1")
        sessions[si].windows.insert(p, at: 0)
        return p.id
    }

    /// 主視窗的 current 要指向可見的 Window：不是（被關掉了、或指到獨立視窗）就挑離 near 最近的那個可見的
    func normalizeCurrent(_ si: Int, near wi: Int) {
        let vis = sessions[si].windows.filter { !$0.detached }
        guard !vis.isEmpty else { sessions[si].current = nil; return }
        if let c = sessions[si].current, vis.contains(where: { $0.id == c }) { return }
        sessions[si].current = vis[min(max(0, wi), vis.count - 1)].id
    }

    /// 切到某個 Window：一般的 Window 變成主視窗的 current；在獨立視窗裡的不動主視窗（不然主視窗會跳回第一頁），改成把那個獨立視窗叫到最前面
    func makeCurrent(_ si: Int, _ wi: Int) {
        let w = sessions[si].windows[wi]
        if w.detached {
            scope = w.id
            onRaiseWindow?(w.id)
        } else {
            currentSession = sessions[si].id
            sessions[si].current = w.id
        }
        syncSelection()
    }

    /// Window 拉出去變成獨立視窗：回傳 true＝成功（至少要留一個在主視窗的分頁列上）
    @discardableResult
    func detachWindow(_ id: UUID) -> Bool {
        guard let si = sessions.firstIndex(where: { $0.windows.contains { $0.id == id } }),
              let wi = sessions[si].windows.firstIndex(where: { $0.id == id }), !sessions[si].windows[wi].detached,
              sessions[si].windows[wi].root != nil else { return false }     // 空的 Window 拉出去沒意義
        sessions[si].windows[wi].detached = true
        sessions[si].windows.append(sessions[si].windows.remove(at: wi))      // 獨立的排最後面
        // 只有一個也能拉出去：主視窗補一個空的 Window 當分頁，不會整條空掉
        ensureVisibleWindow(si)
        if sessions[si].current == id { sessions[si].current = sessions[si].windows.first { !$0.detached }?.id }
        syncSelection()
        return true
    }

    /// 獨立視窗關掉：回到主視窗的分頁列（排在可見的最後一個、變成目前的 Window）
    func attachWindow(_ id: UUID) {
        guard let si = sessions.firstIndex(where: { $0.windows.contains { $0.id == id } }),
              let wi = sessions[si].windows.firstIndex(where: { $0.id == id }), sessions[si].windows[wi].detached else { return }
        var w = sessions[si].windows.remove(at: wi)
        w.detached = false
        w.detachedFrame = nil; w.detachedScreen = nil; w.detachedScreenOrigin = nil
        let at = sessions[si].windows.firstIndex { $0.detached } ?? sessions[si].windows.count
        sessions[si].windows.insert(w, at: at)
        sessions[si].current = id
        if scope == id { scope = nil }
        syncSelection()
    }

    var currentWindow: WindowLayout? {
        guard let si = sessionIndex, let wi = windowIndex else { return nil }
        return sessions[si].windows[wi]
    }

    /// 改目前的 Window（改完同步「選中的對話」）
    func editWindow(_ f: (inout WindowLayout) -> Void) {
        guard let si = sessionIndex, let wi = windowIndex else { return }
        f(&sessions[si].windows[wi])
        syncSelection()
    }

    /// 側欄的選取跟著目前 Window 的那格走
    func syncSelection() {
        if let si = sessionIndex { partitionDetached(si) }      // 總指揮 Window 永遠排最前面（只在順序不對時才會動）
        let f = currentWindow?.focused
        if selected != f { selected = f }
        if let f { unread.remove(f); if let i = conversations.firstIndex(where: { $0.id == f }) { conversations[i].lastOpened = Date(); selectedProject = conversations[i].projectID } }
    }

    /// 第一次啟動（或舊的存檔沒有版面）：開一個 Session、一個 Window
    func ensureLayout() {
        if sessions.isEmpty {
            var w = WindowLayout(name: "1")
            if let s = selected, conversation(s) != nil { w.root = .leaf(s); w.focused = s }
            sessions = [SessionLayout(name: "main", windows: [w], current: w.id)]
            currentSession = sessions[0].id
        }
        // 對話被刪掉了：版面裡的格子也拿掉
        // 空格子不是被刪掉的對話，留著。App 剛開的第一次：版面裡對不到對話的就是上次留下的空格子
        // （刪對話時這裡會馬上把那格拿掉，所以存檔裡對不到的只會是空格子）
        if !Store.layoutLoaded {
            Store.layoutLoaded = true
            let ids = Set(conversations.map(\.id))
            for s in sessions { for w in s.windows { for id in w.root?.leaves ?? [] where !ids.contains(id) { Store.emptySlots.insert(id) } } }
        }
        let alive = Set(conversations.map(\.id)).union(Store.emptySlots)
        for si in sessions.indices {
            for wi in sessions[si].windows.indices {
                var w = sessions[si].windows[wi]
                for id in w.root?.leaves ?? [] where !alive.contains(id) { w.root = w.root?.removing(id) }
                if let f = w.focused, !(w.root?.contains(f) ?? false) { w.focused = w.root?.leaves.first }
                sessions[si].windows[wi] = w
            }
            if sessions[si].windows.isEmpty { sessions[si].windows = [WindowLayout(name: "1")] }
            // 還原獨立視窗之後：獨立的排最後、至少留一個可見的 Window、主視窗的 current 要是可見的
            partitionDetached(si)
            ensureVisibleWindow(si)
            normalizeCurrent(si, near: 0)
        }
        ensureAreaSession()
        // 存檔裡記的 Session 不在目前這一區（例：上次關 App 時側欄停在 codelab，可是記的是首頁的 Session）：對齊畫面上的那個
        if let s = currentSessionLayout, s.id != currentSession { currentSession = s.id }
        syncSelection()
    }

    /// 這段對話現在擺在哪（Session、Window 的位置）
    func locate(_ id: UUID) -> (Int, Int)? {
        for (si, s) in sessions.enumerated() {
            for (wi, w) in s.windows.enumerated() where w.root?.contains(id) == true { return (si, wi) }
        }
        return nil
    }

    // MARK: 打開對話

    /// 打開一段對話：已經擺在某格就跳過去；不然放進目前那格（換掉原本的對話）
    func show(_ id: UUID, replaceFocused: Bool = false) {
        guard Prefs.shared.webFeaturesEnabled || conversation(id)?.isBrowser != true else { return }
        if windowSelected { windowSelected = false }
        // 這段對話屬於哪一區（codelab 的對話放 codelab 那套 Session，其他放首頁那套）
        let want = conversation(id).map(wantsCodeLab) == true ? Store.codeLabArea : "home"
        // 擺在另一區、可是它本來屬於這一區（例：codelab 的對話以前開在首頁的 Window 裡）：從那邊拿下來，放到這一區
        if let (si, _) = locate(id), sessions[si].area != areaKey, want == area { unplace(id) }
        if let (si, wi) = locate(id) {
            sessions[si].windows[wi].focused = id
            makeCurrent(si, wi)
            return
        }
        // 還沒擺著：放進它那一區的 Session
        if want != area { switchArea(want) }
        routeUnplacedToCommander(id)
        // 所有 Window 裡都沒有這個聊天室，就開在新的 Window（目前的 Window 是空的就開在那裡），不再換掉紫框那格；
        // 它在掛件框裡，框裡還沒擺出來的聊天室和掛件一起開。瀏覽器、終端機、草稿、codelab 那一區照舊
        if !replaceFocused, want == "home", let c = conversation(id), Store.isChat(c) { openUnplaced(c); return }
        editWindow { w in
            // 焦點那格要真的在版面上；不在（舊資料）就在旁邊切開，不要把對話弄丟
            if let f = w.focused, let root = w.root, root.contains(f) { w.root = root.replacing(f, with: .leaf(id)) }
            else if let root = w.root { w.root = .split(vertical: false, ratio: 0.5, a: root, b: .leaf(id)) }
            else { w.root = .leaf(id) }
            w.focused = id
        }
    }

    /// 未擺出的聊天室先回到所屬總指揮；版面已經有它時，保留原本的跨組協作配置。
    func routeUnplacedToCommander(_ id: UUID) {
        guard Prefs.shared.sidebarMode == "commander", locate(id) == nil,
              let c = conversation(id), !wantsCodeLab(c),
              let g = groupOf(c), let sid = commanderSessionID(forGroup: g) else { return }
        scope = nil
        if area != "home" { switchArea("home") }
        selectSession(sid)
    }

    /// 右欄「叫出來」只在安全的單格版面間搬移，其餘保留原 Window 並切過去。
    func summonConversation(_ id: UUID, inSession sid: UUID) {
        guard let c = conversation(id), Prefs.shared.webFeaturesEnabled || !c.isBrowser,
              let target = sessionPosition(sid) else { return }
        scope = nil
        windowSelected = false
        if let (si, wi) = locate(id) {
            let w = sessions[si].windows[wi]
            if w.detached {
                sessions[si].windows[wi].focused = id
                makeCurrent(si, wi)
                return
            }
            if si == target || w.root?.leaves.count != 1 || w.renamed {
                let a = sessions[si].area ?? "home"
                if area != a { switchArea(a) }
                sessions[si].windows[wi].focused = id
                makeCurrent(si, wi)
                return
            }
        }
        let a = sessions[target].area ?? "home"
        if area != a { switchArea(a) }
        movePaneToNewWindow(id, inSession: sid, reuseEmpty: true)
    }

    /// 還沒擺在任何 Window 的聊天室：開在空的目前 Window、不然新開一個 Window；掛件框裡還沒擺出來的聊天室左右平分一起開，框的掛件（沒擺在別處的）排最右邊，焦點在點的那一格。
    /// 框裡已經擺在別的 Window 的不動
    private func openUnplaced(_ c: Conversation) {
        scope = nil      // 開在主視窗：scope 還指著獨立視窗的話，後面的 editWindow 會把獨立視窗的版面整個蓋掉
        // 「空」的 Window：沒有任何格子，或每一格都是空格子（⌘ T 開出來的就是一格空格子）：聊天室開在這裡、把空格子換掉
        let blank = currentWindow?.root.map { $0.leaves.allSatisfy { isEmptySlot($0) } } ?? true
        if !blank { newWindow(with: nil) }
        else { for slot in currentWindow?.root?.leaves ?? [] { Store.emptySlots.remove(slot) } }
        var members = [c.id]
        if Prefs.shared.webFeaturesEnabled, let b = c.bundle {
            members = conversations.filter { $0.bundle == b && Store.isChat($0) && locate($0.id) == nil }.sorted(by: orderedBefore).map(\.id)
            if !members.contains(c.id) { members.insert(c.id, at: 0) }
        }
        var root: PaneNode = .leaf(members[0])
        for (i, m) in members.enumerated().dropFirst() {
            root = .split(vertical: false, ratio: Double(i) / Double(i + 1), a: root, b: .leaf(m))     // 一格一格接在右邊，寬度平分
        }
        editWindow { w in
            w.root = root
            w.focused = c.id
            w.zoomed = false
        }
        if Prefs.shared.webFeaturesEnabled, let b = c.bundle {
            for g in gadgets(of: b) where locate(g.id) == nil { appendRight(g.id) }
            editWindow { $0.focused = c.id }      // appendRight 會把焦點給掛件：還給使用者點的那格
        }
    }

    // MARK: Pane

    /// 在目前 Window 的最右邊加一欄：整棵樹包一層左右切，新格在右邊（掛件用）。
    /// 新欄寬度＝跟每欄平分（1 格→1/2、2 格→1/3…），最窄 1/4
    /// animated：從右邊彈進來（WindowHost 的 PaneSlide；掛件用）
    func appendRight(_ conv: UUID, animated: Bool = false) {
        unplace(conv)
        if animated { PaneSlide.shared.slideIn(conv) }
        editWindow { w in
            guard let root = w.root else { w.root = .leaf(conv); w.focused = conv; return }
            let share = max(0.25, 1 / Double(root.leaves.count + 1))
            w.root = .split(vertical: false, ratio: 1 - share, a: root, b: .leaf(conv))
            w.focused = conv
            w.zoomed = false
        }
    }

    /// 從目前那格切開，新的一格放 conv（vertical＝往下切）
    func split(vertical: Bool, with conv: UUID) {
        unplace(conv)   // 已經在別格：先從那裡拿掉（連那個 Window 的焦點一起換好）
        editWindow { w in
            guard let root = w.root else { w.root = .leaf(conv); w.focused = conv; return }
            guard let f = w.focused, root.contains(f) else {
                let anchor = root.leaves.first!       // 焦點不在版面上：接在第一格旁邊，其他格原樣留著
                w.root = root.replacing(anchor, with: .split(vertical: vertical, ratio: 0.5, a: .leaf(anchor), b: .leaf(conv)))
                w.focused = conv
                w.zoomed = false
                return
            }
            w.root = root.replacing(f, with: .split(vertical: vertical, ratio: 0.5, a: .leaf(f), b: .leaf(conv)))
            w.focused = conv
            w.zoomed = false
        }
    }

    /// ⌘ W：Window 裡有兩格以上只關目前那格，只剩一格才關整個 Window。
    /// 掛件不算格子
    /// 一般格子（聊天室、終端機、空格子…）只有一格、其他都是掛件，就關整個 Window；有兩個以上一般格子，照舊只關紫框那格
    func closePaneOrWindow() {
        let normal = (currentWindow?.root?.leaves ?? []).filter { conversation($0)?.isGadget != true }.count
        if normal >= 2 { closePane() } else { closeWindow() }
    }

    /// 關掉目前那格（對話留著）。關之前記下整個 Window 的版面，⌘ ⇧ T 可以放回原位、原比例；空格子不記
    func closePane() {
        // 總指揮聊天室那格不能關（要關先把它的 Window 拉出成獨立視窗）
        if let si = sessionIndex, let wi = windowIndex, isChiefProtected(si, wi), sessions[si].windows[wi].focused == chiefID(si) { NSSound.beep(); return }
        if let si = sessionIndex, let wi = windowIndex, let w = Optional(sessions[si].windows[wi]), let f = w.focused, let root = w.root,
           root.leaves.count >= 2, conversation(f) != nil {
            Store.closed.append(.pane(session: sessions[si].id, window: w.id, before: root, pane: f))
            if Store.closed.count > 20 { Store.closed.removeFirst() }
        }
        editWindow { w in
            guard let f = w.focused, let root = w.root else { return }
            let rects = root.rects()
            w.root = root.removing(f)
            w.zoomed = false
            // 焦點給離它最近的那格
            let c = rects[f].map { CGPoint(x: $0.midX, y: $0.midY) } ?? .zero
            w.focused = w.root?.leaves.min { a, b in
                let ra = rects[a]!, rb = rects[b]!
                return hypot(ra.midX - c.x, ra.midY - c.y) < hypot(rb.midX - c.x, rb.midY - c.y)
            }
        }
    }

    /// 換到旁邊那格：dx/dy 是方向（-1、0、1）
    func focus(dx: Int, dy: Int) {
        if windowSelected { windowSelected = false }
        editWindow { w in
            guard let f = w.focused, let root = w.root else { return }
            let rects = root.rects()
            guard let me = rects[f] else { return }
            let candidates = rects.filter { id, r in
                guard id != f else { return false }
                if dx < 0 { return r.maxX <= me.minX + 0.001 && r.maxY > me.minY && r.minY < me.maxY }
                if dx > 0 { return r.minX >= me.maxX - 0.001 && r.maxY > me.minY && r.minY < me.maxY }
                if dy < 0 { return r.maxY <= me.minY + 0.001 && r.maxX > me.minX && r.minX < me.maxX }
                return r.minY >= me.maxY - 0.001 && r.maxX > me.minX && r.minX < me.maxX
            }
            let best = candidates.min { a, b in
                let da = dx != 0 ? abs(a.value.midX - me.midX) * 10 + abs(a.value.midY - me.midY) : abs(a.value.midY - me.midY) * 10 + abs(a.value.midX - me.midX)
                let db = dx != 0 ? abs(b.value.midX - me.midX) * 10 + abs(b.value.midY - me.midY) : abs(b.value.midY - me.midY) * 10 + abs(b.value.midX - me.midX)
                // 一樣近（例如左邊一大格往右，右邊上下各一格）：固定先上再左。不然看字典順序，每次開 App 跳的格子不一樣
                if abs(da - db) > 0.0001 { return da < db }
                return (a.value.minY, a.value.minX) < (b.value.minY, b.value.minX)
            }
            if let best { w.focused = best.key; w.zoomed = false }
        }
    }

    /// ⌘ [ ／ ⌘ ]（學 Ghostty）：照版面順序換到上一格／下一格，到頭繞回來
    func focusCycle(_ step: Int) {
        if windowSelected { windowSelected = false }
        editWindow { w in
            guard let leaves = w.root?.leaves, leaves.count > 1 else { return }
            let i = w.focused.flatMap { leaves.firstIndex(of: $0) } ?? 0
            w.focused = leaves[((i + step) % leaves.count + leaves.count) % leaves.count]
            w.zoomed = false
        }
    }

    /// Ctrl+A Ctrl+h/j/k/l：把目前那格的邊往那個方向推
    func resize(dx: Int, dy: Int) {
        editWindow { w in
            guard let f = w.focused, let root = w.root else { return }
            w.root = dx != 0 ? root.resizing(f, vertical: false, by: 0.04 * Double(dx)) : root.resizing(f, vertical: true, by: 0.04 * Double(dy))
        }
    }

    func setFocus(_ id: UUID) {
        if windowSelected { windowSelected = false }
        editWindow { w in if w.root?.contains(id) == true { w.focused = id } }
    }

    // MARK: Window

    func newWindow(with conv: UUID?) {
        scope = nil      // 新 Window 開在主視窗的分頁列
        guard let si = sessionIndex else { return }
        if let conv { unplace(conv) }
        var w = WindowLayout(name: "\(visibleWindowCount(si) + 1)")
        if let conv { w.root = .leaf(conv); w.focused = conv }
        appendWindow(w, at: si)
        sessions[si].current = w.id
        syncSelection()
    }

    /// 剛關掉的格子和 Window（⌘ ⇧ T 照相反順序一個一個找回來，不管是關格還是關 Window）：只記這次開 App 期間，最多 20 個。
    /// window 的 placeholder：關的是最後一個時補上的空 Window，找回來時它還空著就換掉。
    /// pane 的 before：關之前整個 Window 的版面（放回原位、原比例用）
    enum Closed {
        case window(session: UUID, index: Int, window: WindowLayout, placeholder: UUID?)
        case pane(session: UUID, window: UUID, before: PaneNode, pane: UUID)
    }
    static var closed: [Closed] = []

    func closeWindow() {
        guard let si = sessionIndex, let wi = windowIndex else { return }
        if isChiefProtected(si, wi) { NSSound.beep(); return }     // 總指揮 Window 不能關，只能拉出成獨立視窗
        var closed = sessions[si].windows.remove(at: wi)
        // 存進 closed 的不再是獨立的（獨立視窗已經跟著關了）：不然 ⌘ ⇧ T 找回來會變成一個看不見的幽靈 Window
        closed.detached = false
        if scope == closed.id { scope = nil }
        // 主視窗分頁列沒有可見的 Window 了（獨立視窗不算）：補一個空的
        let placeholder = ensureVisibleWindow(si)
        if closed.root != nil {   // 空的 Window 不記：找回一個空白的沒用
            // 同一段聊天室只記最後一份（側欄點它要找回的是最近那次關掉的版面）：先前記的 Window，裡面的聊天室全都在這次這份裡，就丟掉；
            // 只重疊一部分的留著（不然另一段聊天室的版面就找不回來；還原時已經在別處的格子會略過）。掛件和空格子不列入比對
            func chats(_ n: PaneNode?) -> Set<UUID> { Set((n?.leaves ?? []).filter { conversation($0).map { !$0.isGadget } ?? false }) }
            let mine = chats(closed.root)
            Store.closed.removeAll { item in
                guard case .window(_, _, let w, _) = item else { return false }
                let old = chats(w.root)
                return !old.isEmpty && old.isSubset(of: mine)
            }
            Store.closed.append(.window(session: sessions[si].id, index: wi, window: closed, placeholder: placeholder))
            if Store.closed.count > 20 { Store.closed.removeFirst() }
        }
        normalizeCurrent(si, near: wi)
        syncSelection()
    }

    /// ⌘ ⇧ T：找回最近關掉的格子或 Window，放回原本的位置。裡面的對話已經刪掉、或已經擺到別的格子的就略過（不從別處搶回來）。
    /// 它所在的 Session／Window 已經關了就再往前找。沒有可以找回的回傳 false
    @discardableResult
    func reopenClosedWindow() -> Bool {
        while let item = Store.closed.popLast() {
            if case .pane(let sid, let wid, let before, let pane) = item {
                if reopenPane(session: sid, window: wid, before: before, pane: pane) { return true }
                continue
            }
            guard case .window(let session, let index, let window, let placeholder) = item else { continue }
            if restoreWindow(session: session, index: index, window: window, placeholder: placeholder) { return true }
        }
        return false
    }

    /// 側欄點一段聊天室、它現在不在任何 Window 裡：最近關掉的 Window 裡有它的話，整個 Window 找回來（掛件、比例、紫框都照原樣）。
    /// 找到並放回去了回傳 true（呼叫的人就不用再把它擺進目前那格）
    @discardableResult
    func reopenClosedWindow(containing conv: UUID) -> Bool {
        guard locate(conv) == nil else { return false }
        for (i, item) in Store.closed.enumerated().reversed() {
            guard case .window(let session, let index, let window, let placeholder) = item, window.root?.contains(conv) == true else { continue }
            Store.closed.remove(at: i)
            // 記下點擊前的主視窗；還原成功後，若它是同一 Session 的空 Window，就由找回的 Window 接替原位。
            let current = currentWindow
            let currentSessionID = sessionIndex.map { sessions[$0].id }
            let currentIsBlank = current?.root.map { $0.leaves.allSatisfy { isEmptySlot($0) } } ?? true
            let currentSlots = current?.root?.leaves ?? []
            if restoreWindow(session: session, index: index, window: window, placeholder: placeholder, focus: conv) {
                if let current, currentIsBlank, currentSessionID == session,
                   let si = sessions.firstIndex(where: { $0.id == session }),
                   let wi = sessions[si].windows.firstIndex(where: { $0.id == current.id }),
                   !sessions[si].windows[wi].detached {
                    // 移除空視窗及其空格子；還原的 Window 插回原位置並成為目前視窗。
                    if let ri = sessions[si].windows.firstIndex(where: { $0.id == window.id }) {
                        for slot in currentSlots { Store.emptySlots.remove(slot) }
                        let restored = sessions[si].windows[ri]
                        sessions[si].windows[wi] = restored          // 直接蓋掉空 Window 那一格，位置不跑
                        sessions[si].windows.remove(at: ri)
                        currentSession = session
                        sessions[si].current = restored.id
                        syncSelection()
                    }
                }
                return true
            }
            Store.closed.insert(item, at: min(i, Store.closed.count))      // 還原不了（原本的 Session 已經關了）：紀錄放回去，不能白白消失
            return false
        }
        return false
    }

    /// 把關掉的 Window 放回去。裡面的對話已經刪掉、或已經擺到別的格子的就略過（不從別處搶回來）；它所在的 Session 已經關了回傳 false
    private func restoreWindow(session: UUID, index: Int, window: WindowLayout, placeholder: UUID?, focus: UUID? = nil) -> Bool {
        guard let si = sessions.firstIndex(where: { $0.id == session }) else { return false }
        var w = window
        w.detached = false
        let alive = Set(conversations.map(\.id)).union(Store.emptySlots)
        for id in w.root?.leaves ?? [] where !alive.contains(id) || locate(id) != nil { w.root = w.root?.removing(id) }
        if w.root == nil { return false }   // 裡面的對話都已經不在了：不放一個空 Window 回去，讓 ⌘ ⇧ T 繼續找更早的
        if let f = focus, w.root?.contains(f) == true { w.focused = f }   // 側欄點的那段：紫框給它
        else if let f = w.focused, !(w.root?.contains(f) ?? false) { w.focused = w.root?.leaves.first }
        if w.root == nil { w.zoomed = false }
        if let p = placeholder, let pi = sessions[si].windows.firstIndex(where: { $0.id == p }), sessions[si].windows[pi].root == nil, visibleWindowCount(si) == 1 {
            sessions[si].windows.remove(at: pi)
        }
        // 插在獨立視窗前面（獨立的一律排最後）
        sessions[si].windows.insert(w, at: min(index, sessions[si].windows.firstIndex { $0.detached } ?? sessions[si].windows.count))
        currentSession = sessions[si].id
        sessions[si].current = w.id
        syncSelection()
        return true
    }

    /// 把關掉的那格放回去：Window 從那之後沒變過就整個還原（原位、原比例）；變過的話放回它原本旁邊那格的同一側，找不到就切開目前那格
    private func reopenPane(session sid: UUID, window wid: UUID, before: PaneNode, pane: UUID) -> Bool {
        guard conversation(pane) != nil, locate(pane) == nil,
              let si = sessions.firstIndex(where: { $0.id == sid }), let wi = sessions[si].windows.firstIndex(where: { $0.id == wid }) else { return false }
        var w = sessions[si].windows[wi]
        if let cur = w.root {
            if before.removing(pane) == cur { w.root = before }
            else if let p = before.parent(of: pane) {
                let node: (PaneNode) -> PaneNode = { s in .split(vertical: p.vertical, ratio: p.ratio, a: p.first ? .leaf(pane) : s, b: p.first ? s : .leaf(pane)) }
                if let r = cur.replacingSubtree(p.sibling, with: node(p.sibling)) { w.root = r }
                else if let near = p.sibling.leaves.first(where: { cur.contains($0) }) { w.root = cur.replacing(near, with: node(.leaf(near))) }
                else if let f = (w.focused.flatMap { cur.contains($0) ? $0 : nil }) ?? cur.leaves.first { w.root = cur.replacing(f, with: .split(vertical: false, ratio: 0.5, a: .leaf(f), b: .leaf(pane))) }
            } else if let f = (w.focused.flatMap { cur.contains($0) ? $0 : nil }) ?? cur.leaves.first { w.root = cur.replacing(f, with: .split(vertical: false, ratio: 0.5, a: .leaf(f), b: .leaf(pane))) }
        } else {
            w.root = .leaf(pane)
        }
        guard w.root?.contains(pane) == true else { return false }
        w.focused = pane
        w.zoomed = false
        sessions[si].windows[wi] = w
        makeCurrent(si, wi)
        return true
    }

    func selectWindow(at i: Int) {
        // 分頁列和 Session 是主視窗的：獨立視窗在前景（scope 指著它）時按快捷鍵，也要照主視窗算，不然會切錯、關錯 Session。
        // 只在這次操作裡切回主視窗範圍，做完還原（直接清掉 scope 的話，獨立視窗還在前景，之後的分割、關格會落到主視窗）
        if scope != nil { scoped(nil) { selectWindow(at: i) }; return }
        if windowSelected { windowSelected = false }
        guard let si = sessionIndex, sessions[si].windows.indices.contains(i), !sessions[si].windows[i].detached else { return }   // 主視窗的分頁只有一般的 Window
        sessions[si].current = sessions[si].windows[i].id
        syncSelection()
    }

    /// 點上方的 Window 分頁、或按 ⌘ 數字：選取整個 Window；再點同一個 Window 一次＝回到原本那一格
    /// （紫框那格 focused 在選取期間沒變；原本那格被關掉了，focused 已經由關格子時換到別格，直接用它）
    func toggleWindowSelection(at i: Int) {
        let again = windowSelected && windowIndex == i
        selectWindow(at: i)
        windowSelected = !again
    }

    func selectWindow(offset: Int) {
        if scope != nil { scoped(nil) { selectWindow(offset: offset) }; return }
        guard let si = sessionIndex else { return }
        // 只在主視窗分頁列上的 Window 之間循環（獨立視窗不算）
        let vis = sessions[si].windows.indices.filter { !sessions[si].windows[$0].detached }
        let n = vis.count
        guard n > 0 else { return }
        let cur = windowIndex.flatMap { vis.firstIndex(of: $0) } ?? 0
        selectWindow(at: vis[((cur + offset) % n + n) % n])
    }

    func renameWindow(_ name: String) {
        let t = name.trimmingCharacters(in: .whitespaces)
        // 清空＝改回預設名字（Window N），側欄的 Window 框跟著拿掉
        guard !t.isEmpty else { if let wi = windowIndex { editWindow { $0.name = "\(wi + 1)"; $0.renamed = false } }; return }
        editWindow { $0.name = t; $0.renamed = true }
    }

    func toggleZoom() { editWindow { w in if (w.root?.leaves.count ?? 0) > 1 { w.zoomed.toggle() } } }

    // MARK: Session

    func newSession(named name: String) {
        let w = WindowLayout(name: "1")
        var s = SessionLayout(name: name, windows: [w], current: w.id)
        s.area = areaKey
        sessions.append(s)
        currentSession = s.id
        syncSelection()
    }

    func selectSession(_ id: UUID) { currentSession = id; syncSelection() }

    func selectSession(offset: Int) {
        if scope != nil { scoped(nil) { selectSession(offset: offset) }; return }
        let list = areaSessions
        guard let cur = currentSessionLayout, let i = list.firstIndex(where: { $0.id == cur.id }) else { return }
        let n = list.count
        currentSession = list[((i + offset) % n + n) % n].id
        syncSelection()
    }

    func renameSession(_ name: String) {
        let t = name.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let si = sessionIndex else { return }
        sessions[si].name = t
    }

    func closeSession() {
        if scope != nil { scoped(nil) { closeSession() }; return }
        guard let si = sessionIndex else { return }
        let i = areaSessions.firstIndex { $0.id == sessions[si].id } ?? 0
        sessions.remove(at: si)
        ensureAreaSession()     // 這一區關光了：補一個空的
        let list = areaSessions
        currentSession = list[min(i, list.count - 1)].id
        syncSelection()
    }

    /// 顯示用的 Window 名字：沒自己取名就用目前那格的對話標題
    /// Window 的名字：取過名字就用那個，沒取過叫「Window 第幾個」（不拿格子裡對話的標題）
    func displayName(_ w: WindowLayout) -> String {
        if w.renamed { return w.name }
        for s in sessions { if let i = s.windows.firstIndex(where: { $0.id == w.id }) { return "Window \(i + 1)" } }
        return "Window"
    }
}
