import Foundation
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
}

struct SessionLayout: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var windows: [WindowLayout]
    var current: UUID?
    /// 屬於哪一區：nil＝首頁、"codelab"＝程式碼學習專區（使用者 10/25：codelab 的 Session／Window 跟首頁分開）。舊存檔沒有這欄＝首頁
    var area: String? = nil
}

extension Store {
    // MARK: 目前的 Session／Window

    var sessionIndex: Int? { sessions.firstIndex { $0.id == currentSession && inArea($0) } ?? sessions.firstIndex(where: inArea) }

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
        return s.windows.firstIndex { $0.id == s.current } ?? (s.windows.isEmpty ? nil : 0)
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
    func show(_ id: UUID) {
        // 這段對話屬於哪一區（codelab 的對話放 codelab 那套 Session，其他放首頁那套）
        let want = conversation(id).map(wantsCodeLab) == true ? Store.codeLabArea : "home"
        // 擺在另一區、可是它本來屬於這一區（例：codelab 的對話以前開在首頁的 Window 裡）：從那邊拿下來，放到這一區
        if let (si, _) = locate(id), sessions[si].area != areaKey, want == area { unplace(id) }
        if let (si, wi) = locate(id) {
            currentSession = sessions[si].id
            sessions[si].current = sessions[si].windows[wi].id
            sessions[si].windows[wi].focused = id
            syncSelection()
            return
        }
        // 還沒擺著：放進它那一區的 Session
        if want != area { switchArea(want) }
        editWindow { w in
            // 焦點那格要真的在版面上；不在（舊資料）就在旁邊切開，不要把對話弄丟
            if let f = w.focused, let root = w.root, root.contains(f) { w.root = root.replacing(f, with: .leaf(id)) }
            else if let root = w.root { w.root = .split(vertical: false, ratio: 0.5, a: root, b: .leaf(id)) }
            else { w.root = .leaf(id) }
            w.focused = id
        }
    }

    // MARK: Pane

    /// 在目前 Window 的最右邊加一欄：整棵樹包一層左右切，新格在右邊（掛件用；使用者 10/25「優先顯示在最右邊，之後使用者再調整位置」）。
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
            guard let f = w.focused, let root = w.root else { w.root = .leaf(conv); w.focused = conv; return }
            w.root = root.replacing(f, with: .split(vertical: vertical, ratio: 0.5, a: .leaf(f), b: .leaf(conv)))
            w.focused = conv
            w.zoomed = false
        }
    }

    /// ⌘ W（使用者 10/25：「紫框選中的，按下 ⌘ W 會單純關掉那個 pane」）：Window 裡有兩格以上只關目前那格，只剩一格才關整個 Window。
    /// 掛件不算格子（使用者 10/26：「Windows 內只有一個聊天室，掛件 gemini 或其他的面板時，⌘ W 可以直接關掉整個 Windows」）：
    /// 一般格子（聊天室、終端機、空格子…）只有一格、其他都是掛件，就關整個 Window；有兩個以上一般格子，照舊只關紫框那格
    func closePaneOrWindow() {
        let normal = (currentWindow?.root?.leaves ?? []).filter { conversation($0)?.isGadget != true }.count
        if normal >= 2 { closePane() } else { closeWindow() }
    }

    /// 關掉目前那格（對話留著）。關之前記下整個 Window 的版面，⌘ ⇧ T 可以放回原位、原比例；空格子不記
    func closePane() {
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

    /// Ctrl+A Ctrl+h/j/k/l：把目前那格的邊往那個方向推
    func resize(dx: Int, dy: Int) {
        editWindow { w in
            guard let f = w.focused, let root = w.root else { return }
            w.root = dx != 0 ? root.resizing(f, vertical: false, by: 0.04 * Double(dx)) : root.resizing(f, vertical: true, by: 0.04 * Double(dy))
        }
    }

    func setFocus(_ id: UUID) {
        editWindow { w in if w.root?.contains(id) == true { w.focused = id } }
    }

    // MARK: Window

    func newWindow(with conv: UUID?) {
        guard let si = sessionIndex else { return }
        if let conv { unplace(conv) }
        var w = WindowLayout(name: "\(sessions[si].windows.count + 1)")
        if let conv { w.root = .leaf(conv); w.focused = conv }
        sessions[si].windows.append(w)
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
        let closed = sessions[si].windows.remove(at: wi)
        var placeholder: UUID?
        if sessions[si].windows.isEmpty { let p = WindowLayout(name: "1"); placeholder = p.id; sessions[si].windows = [p] }
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
        sessions[si].current = sessions[si].windows[min(wi, sessions[si].windows.count - 1)].id
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
            if restoreWindow(session: session, index: index, window: window, placeholder: placeholder, focus: conv) { return true }
            return false
        }
        return false
    }

    /// 把關掉的 Window 放回去。裡面的對話已經刪掉、或已經擺到別的格子的就略過（不從別處搶回來）；它所在的 Session 已經關了回傳 false
    private func restoreWindow(session: UUID, index: Int, window: WindowLayout, placeholder: UUID?, focus: UUID? = nil) -> Bool {
        guard let si = sessions.firstIndex(where: { $0.id == session }) else { return false }
        var w = window
        let alive = Set(conversations.map(\.id)).union(Store.emptySlots)
        for id in w.root?.leaves ?? [] where !alive.contains(id) || locate(id) != nil { w.root = w.root?.removing(id) }
        if w.root == nil { return false }   // 裡面的對話都已經不在了：不放一個空 Window 回去，讓 ⌘ ⇧ T 繼續找更早的
        if let f = focus, w.root?.contains(f) == true { w.focused = f }   // 側欄點的那段：紫框給它
        else if let f = w.focused, !(w.root?.contains(f) ?? false) { w.focused = w.root?.leaves.first }
        if w.root == nil { w.zoomed = false }
        if let p = placeholder, sessions[si].windows.count == 1, sessions[si].windows[0].id == p, sessions[si].windows[0].root == nil {
            sessions[si].windows = []
        }
        sessions[si].windows.insert(w, at: min(index, sessions[si].windows.count))
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
                else if let f = w.focused ?? cur.leaves.first { w.root = cur.replacing(f, with: .split(vertical: false, ratio: 0.5, a: .leaf(f), b: .leaf(pane))) }
            } else if let f = w.focused ?? cur.leaves.first { w.root = cur.replacing(f, with: .split(vertical: false, ratio: 0.5, a: .leaf(f), b: .leaf(pane))) }
        } else {
            w.root = .leaf(pane)
        }
        w.focused = pane
        w.zoomed = false
        sessions[si].windows[wi] = w
        currentSession = sessions[si].id
        sessions[si].current = w.id
        syncSelection()
        return true
    }

    func selectWindow(at i: Int) {
        guard let si = sessionIndex, sessions[si].windows.indices.contains(i) else { return }
        sessions[si].current = sessions[si].windows[i].id
        syncSelection()
    }

    func selectWindow(offset: Int) {
        guard let si = sessionIndex, let wi = windowIndex else { return }
        let n = sessions[si].windows.count
        selectWindow(at: ((wi + offset) % n + n) % n)
    }

    func renameWindow(_ name: String) {
        let t = name.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
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
