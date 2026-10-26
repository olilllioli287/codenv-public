import Foundation

// 設定視窗「視窗」頁用的版面操作：用 id 指定 Session／Window（不限於目前的），
// 可以把 Pane 搬到別的 Window、Window 換位置或搬到別的 Session、Session 換順序。
// 只連到對話、不擁有對話：這裡的「拿掉」「刪除」都只動版面，對話本身留著。

extension Store {
    // MARK: 找位置

    func sessionPosition(_ id: UUID) -> Int? { sessions.firstIndex { $0.id == id } }

    /// Window 在哪個 Session 的第幾個
    func windowPosition(_ id: UUID) -> (Int, Int)? {
        for (si, s) in sessions.enumerated() {
            if let wi = s.windows.firstIndex(where: { $0.id == id }) { return (si, wi) }
        }
        return nil
    }

    /// 這段對話在它那個 Window 的分割樹裡，從根走下來的路：每一步是（vertical, 在 b 邊）
    func panePath(_ conv: UUID) -> [(vertical: Bool, second: Bool)] {
        guard let (si, wi) = locate(conv), let root = sessions[si].windows[wi].root else { return [] }
        func go(_ n: PaneNode) -> [(Bool, Bool)]? {
            switch n {
            case .leaf(let id): return id == conv ? [] : nil
            case .split(let v, _, let a, let b):
                if let p = go(a) { return [(v, false)] + p }
                if let p = go(b) { return [(v, true)] + p }
                return nil
            }
        }
        return (go(root) ?? []).map { (vertical: $0.0, second: $0.1) }
    }

    /// 沒擺在任何 Window 的對話
    var unplacedConversations: [Conversation] {
        let placed = Set(sessions.flatMap { $0.windows.flatMap { $0.root?.leaves ?? [] } })
        return conversations.filter { !placed.contains($0.id) }
    }

    // MARK: 切換（主畫面跟著過去）

    func selectWindow(id: UUID) {
        guard let (si, _) = windowPosition(id) else { return }
        currentSession = sessions[si].id
        sessions[si].current = id
        syncSelection()
    }

    /// 把焦點設到某格（並切到它那個 Session／Window）
    func focusPane(_ conv: UUID) {
        guard locate(conv) != nil else { return }
        show(conv)
    }

    // MARK: Pane

    /// 版面上 old 那格直接換成 new（焦點跟著換）；old 不在版面上回傳 false
    @discardableResult
    func replacePane(_ old: UUID, with new: UUID) -> Bool {
        guard locate(old) != nil else { return false }
        unplace(new)
        guard let (si2, wi2) = locate(old) else { return false }
        sessions[si2].windows[wi2].root = sessions[si2].windows[wi2].root?.replacing(old, with: .leaf(new))
        if sessions[si2].windows[wi2].focused == old { sessions[si2].windows[wi2].focused = new }
        currentSession = sessions[si2].id
        sessions[si2].current = sessions[si2].windows[wi2].id
        syncSelection()
        return true
    }

    /// 從版面拿掉這段對話（對話本身不刪）。它那個 Window 的焦點換給剩下的第一格
    func unplace(_ conv: UUID) {
        guard let (si, wi) = locate(conv) else { return }
        var w = sessions[si].windows[wi]
        w.root = w.root?.removing(conv)
        if w.focused == conv || !(w.root?.contains(w.focused ?? UUID()) ?? false) { w.focused = w.root?.leaves.first }
        if (w.root?.leaves.count ?? 0) <= 1 { w.zoomed = false }
        sessions[si].windows[wi] = w
        syncSelection()
    }

    /// 把對話放進某個 Window：從 beside 那格（沒給就用那個 Window 目前那格）往右切開；Window 是空的就變成唯一一格。
    /// 對話原本擺在別的地方會先從那裡拿掉。
    func movePane(_ conv: UUID, toWindow wid: UUID, beside: UUID? = nil) {
        guard conversation(conv) != nil, windowPosition(wid) != nil else { return }
        if beside == conv { return }
        if let (si, wi) = locate(conv), sessions[si].windows[wi].id == wid, beside == nil { return }   // 已經在這個 Window
        unplace(conv)
        guard let (si, wi) = windowPosition(wid) else { return }
        var w = sessions[si].windows[wi]
        if let root = w.root {
            let anchor = beside.flatMap { root.contains($0) ? $0 : nil } ?? w.focused.flatMap { root.contains($0) ? $0 : nil } ?? root.leaves.last!
            w.root = root.replacing(anchor, with: .split(vertical: false, ratio: 0.5, a: .leaf(anchor), b: .leaf(conv)))
        } else {
            w.root = .leaf(conv)
        }
        w.focused = conv
        w.zoomed = false
        sessions[si].windows[wi] = w
        syncSelection()
    }

    /// 在某個 Session 最後開一個新 Window 放這段對話
    func movePaneToNewWindow(_ conv: UUID, inSession sid: UUID) {
        guard conversation(conv) != nil, let si = sessionPosition(sid) else { return }
        unplace(conv)
        var w = WindowLayout(name: "\(sessions[si].windows.count + 1)")
        w.root = .leaf(conv)
        w.focused = conv
        sessions[si].windows.append(w)
        syncSelection()
    }

    // MARK: Window

    /// 在某個 Session 最後加一個空的 Window，回傳它的 id
    @discardableResult
    func addWindow(toSession sid: UUID) -> UUID? {
        guard let si = sessionPosition(sid) else { return nil }
        let w = WindowLayout(name: "\(sessions[si].windows.count + 1)")
        sessions[si].windows.append(w)
        return w.id
    }

    func renameWindow(_ id: UUID, to name: String) {
        let t = name.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let (si, wi) = windowPosition(id) else { return }
        sessions[si].windows[wi].name = t
        sessions[si].windows[wi].renamed = true
    }

    /// 刪掉一個 Window（只刪版面）。Session 空了就補一個空的 Window
    func deleteWindow(_ id: UUID) {
        guard let (si, wi) = windowPosition(id) else { return }
        sessions[si].windows.remove(at: wi)
        if sessions[si].windows.isEmpty { sessions[si].windows = [WindowLayout(name: "1")] }
        if sessions[si].current == id || !sessions[si].windows.contains(where: { $0.id == sessions[si].current }) {
            sessions[si].current = sessions[si].windows[min(wi, sessions[si].windows.count - 1)].id
        }
        syncSelection()
    }

    /// 把 Window 搬到某個 Session 的第 index 個位置（index 是搬之前那個 Session 的位置，跟 Array.move 一樣）。
    /// 同一個 Session 就是換順序。原本的 Session 空了就補一個空的 Window。
    func moveWindow(_ id: UUID, toSession sid: UUID, at index: Int) {
        guard let (si, wi) = windowPosition(id), let ti = sessionPosition(sid) else { return }
        if si == ti {
            let to = max(0, min(index, sessions[si].windows.count))
            Self.move(&sessions[si].windows, from: wi, to: to)
            return
        }
        let wasShown = currentSession == sessions[si].id && (sessions[si].current ?? sessions[si].windows.first?.id) == id
        let w = sessions[si].windows.remove(at: wi)
        if sessions[si].windows.isEmpty { sessions[si].windows = [WindowLayout(name: "1")] }
        if sessions[si].current == id { sessions[si].current = sessions[si].windows[min(wi, sessions[si].windows.count - 1)].id }
        let to = max(0, min(index, sessions[ti].windows.count))
        sessions[ti].windows.insert(w, at: to)
        // 搬過去的是目前在看的 Window：主畫面跟著到新的 Session
        if wasShown {
            currentSession = sessions[ti].id
            sessions[ti].current = id
        }
        syncSelection()
    }

    // MARK: Session

    /// 加一個 Session（裡面一個空的 Window），不切過去；回傳 id
    @discardableResult
    func addSession(named name: String? = nil) -> UUID {
        var n = sessions.count + 1
        let names = Set(sessions.map(\.name))
        while names.contains("session \(n)") { n += 1 }
        let w = WindowLayout(name: "1")
        let s = SessionLayout(name: name ?? "session \(n)", windows: [w], current: w.id)
        sessions.append(s)
        return s.id
    }

    func renameSession(_ id: UUID, to name: String) {
        let t = name.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let si = sessionPosition(id) else { return }
        sessions[si].name = t
    }

    /// 刪掉一個 Session（只刪版面）。刪光了就重新開一個
    func deleteSession(_ id: UUID) {
        guard let si = sessionPosition(id) else { return }
        sessions.remove(at: si)
        ensureAreaSession()
        if currentSession == id || !sessions.contains(where: { $0.id == currentSession }) {
            currentSession = areaSessions.first?.id
        }
        syncSelection()
    }

    /// Session 換順序（index 跟 Array.move 一樣）
    func moveSession(_ id: UUID, to index: Int) {
        guard let si = sessionPosition(id) else { return }
        Self.move(&sessions, from: si, to: max(0, min(index, sessions.count)))
    }

    /// 跟 SwiftUI 的 Array.move(fromOffsets:toOffset:) 一樣：to 是搬之前的位置
    private static func move<T>(_ a: inout [T], from: Int, to: Int) {
        guard a.indices.contains(from) else { return }
        let x = a.remove(at: from)
        a.insert(x, at: to > from ? to - 1 : to)
    }
}
