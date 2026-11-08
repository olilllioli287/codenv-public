import Foundation

/// 「區」＝總指揮涵蓋的頂層組底下的子組（可以任意層）。沿用 ConvGroup 的 parentID，不另起一套資料：
/// 研究區 › Hermes研究，在存檔裡就是兩個巢狀的組。multi 總指揮的子專案本來就是第一層子組，所以也是區。
/// 子組如果歸別的總指揮管（commanderSessionID 最深涵蓋勝出），就不算這個總指揮的區。
struct AreaNode {
    let group: ConvGroup
    let depth: Int            // 1＝直接掛在總指揮涵蓋的頂層組底下
    let parent: UUID?         // 上一層的區；nil＝直接連總指揮
}

extension Store {
    /// 這個總指揮底下所有的區，樹狀前序（同層照群組排列順序）
    func areaNodes(_ s: SessionLayout) -> [AreaNode] {
        guard s.groups != nil else { return [] }
        var out: [AreaNode] = []
        var seen = Set<UUID>(s.groups ?? [])
        func walk(_ g: ConvGroup, depth: Int, parent: UUID?) {
            guard g.name != Store.codeLabGroupName, !seen.contains(g.id), commanderSessionID(forGroup: g.id) == s.id else { return }
            seen.insert(g.id)
            out.append(AreaNode(group: g, depth: depth, parent: parent))
            for c in childGroups(of: g.id) { walk(c, depth: depth + 1, parent: g.id) }
        }
        for r in s.groups ?? [] { for c in childGroups(of: r) { walk(c, depth: 1, parent: nil) } }
        return out
    }

    /// 聊天室所在的區；放在總指揮涵蓋的頂層組本身（或不在任何區裡）＝nil＝直接連總指揮
    func areaID(of c: Conversation, in nodes: [AreaNode]) -> UUID? {
        guard let g = groupOf(c), nodes.contains(where: { $0.group.id == g }) else { return nil }
        return g
    }

    /// 「研究區 › Hermes研究」
    func areaPath(_ id: UUID, in s: SessionLayout) -> String {
        var names: [String] = []
        var cur: UUID? = id
        var seen = Set<UUID>()
        let roots = Set(s.groups ?? [])
        while let c = cur, !roots.contains(c), let g = group(c), seen.insert(c).inserted { names.insert(g.name, at: 0); cur = g.parentID }
        return names.joined(separator: " › ")
    }

    /// 總指揮用來放新區的頂層組：總指揮聊天室所在的那個，沒有就第一個
    func areaRoot(_ s: SessionLayout) -> UUID? {
        let roots = s.groups ?? []
        if let ch = s.chief, let c = conversation(ch), let g = groupOf(c), let r = roots.first(where: { isGroup(g, within: $0) }) { return r }
        return roots.first
    }

    /// 依名字（或「上層 › 下層」路徑、或 id 前綴）找區；找不到或有兩個以上同名會給錯誤訊息
    func findArea(_ raw: String, in s: SessionLayout) -> (area: ConvGroup?, error: String?) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let nodes = areaNodes(s)
        let byPath = nodes.filter { areaPath($0.group.id, in: s) == t }
        let byName = nodes.filter { $0.group.name == t }
        let byId = t.count >= 4 ? nodes.filter { $0.group.id.uuidString.lowercased().hasPrefix(t.lowercased()) } : []
        let pool = !byPath.isEmpty ? byPath : (byId.count == 1 ? byId : byName)
        if pool.count > 1 { return (nil, "有 \(pool.count) 個區都叫「\(t)」，請用完整路徑（例如「\(areaPath(pool[0].group.id, in: s))」）") }
        guard let hit = pool.first else {
            let list = nodes.map { "「\(areaPath($0.group.id, in: s))」" }.joined(separator: "、")
            return (nil, "找不到區「\(t)」。目前的區：\(list.isEmpty ? "（還沒有，用 codenv-todo area add 建）" : list)")
        }
        return (hit.group, nil)
    }

    private func areaCaller(_ conv: String?) -> (caller: Conversation, session: SessionLayout, chief: Bool)? {
        guard let cv = conv?.lowercased(), !cv.isEmpty,
              let c = conversations.first(where: { $0.id.uuidString.lowercased().hasPrefix(cv) }),
              let s = commander(of: c.id) else { return nil }
        return (c, s, s.chief == c.id)
    }

    /// codenv-todo area add "<區名>" [--parent "<上層區>"]：只有總指揮聊天室能建；只新增一個組，不動使用者原本的分組
    func commanderAreaAdd(caller: String?, name raw: String, parent rawParent: String?) -> [String: Any] {
        func fail(_ m: String) -> [String: Any] { ["ok": false, "error": m] }
        guard let me = areaCaller(caller) else { return fail("找不到你屬於哪個總指揮（要在 codenv 的聊天室裡跑）") }
        guard me.chief else { return fail("只有總指揮聊天室能建區") }
        let name = raw.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return fail("要給區取名字") }
        guard name.count <= 40, !name.contains("›"), name != Store.otherGroupName, name != Store.codeLabGroupName else { return fail("區名不能用（太長、含 ›，或是保留名稱）") }
        guard let root = areaRoot(me.session) else { return fail("這個總指揮沒有涵蓋任何組") }
        var parentID = root
        if let p = rawParent?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            let r = findArea(p, in: me.session)
            guard let a = r.area else { return fail(r.error ?? "找不到上層區") }
            parentID = a.id
        }
        // 區名在同一個總指揮底下不能重複（用名字指定時才不會搞混）
        if areaNodes(me.session).contains(where: { $0.group.name == name }) { return fail("已經有叫「\(name)」的區了，換個名字或直接用它") }
        // 同一層已經有同名的組（可能是使用者自己的、或別的總指揮的）：絕不借用它，更不能走下面的 removeGroup 把它刪掉
        if groups.contains(where: { $0.name == name && $0.parentID == parentID }) {
            return fail("那一層已經有叫「\(name)」的組了（不是這個總指揮的區），換個名字")
        }
        let g = addGroup(named: name, parent: parentID)
        guard commanderSessionID(forGroup: g.id) == me.session.id else {
            removeGroup(g.id)
            return fail("新區沒有落在你的總指揮底下，已取消")
        }
        return ["ok": true, "name": name, "path": areaPath(g.id, in: me.session), "id": String(g.id.uuidString.prefix(8)).lowercased()]
    }

    /// codenv-todo area move "<聊天室|id>" "<區名>"：只有總指揮能搬；區名寫 root（或空）＝放回總指揮本身（不屬於任何區）
    func commanderAreaMove(caller: String?, target: String, area rawArea: String) -> [String: Any] {
        func fail(_ m: String) -> [String: Any] { ["ok": false, "error": m] }
        guard let me = areaCaller(caller) else { return fail("找不到你屬於哪個總指揮（要在 codenv 的聊天室裡跑）") }
        guard me.chief else { return fail("只有總指揮聊天室能把聊天室搬到別的區") }
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return fail("要指定哪個聊天室") }
        let members = conversations(inCommander: me.session).filter { Store.isChat($0) }
        let byId = t.count >= 4 ? members.filter { $0.id.uuidString.lowercased().hasPrefix(t.lowercased()) } : []
        let byName = members.filter { $0.title == t }
        let pool = byId.count == 1 ? byId : byName
        if pool.count > 1 {
            let ids = pool.map { String($0.id.uuidString.prefix(8)).lowercased() }.joined(separator: "、")
            return fail("有 \(pool.count) 個聊天室都叫「\(t)」，請改用 id（\(ids)）")
        }
        guard let c = pool.first else { return fail("在你的總指揮底下找不到「\(t)」（codenv-todo team 看名單）") }
        if c.id == me.session.chief { return fail("總指揮聊天室留在中心，不能搬進區") }
        let a = rawArea.trimmingCharacters(in: .whitespacesAndNewlines)
        let dest: UUID
        var label: String
        if a.isEmpty || a.lowercased() == "root" || a == "/" {
            guard let r = areaRoot(me.session) else { return fail("這個總指揮沒有涵蓋任何組") }
            dest = r; label = "（總指揮本身）"
        } else {
            let r = findArea(a, in: me.session)
            guard let g = r.area else { return fail(r.error ?? "找不到區") }
            dest = g.id; label = areaPath(g.id, in: me.session)
        }
        move(c.id, toGroup: dest)
        guard belongsToCommander(conversation(c.id) ?? c, session: me.session) else { return fail("搬動後聊天室不在你的總指揮底下，這是不該發生的錯誤") }
        if label.isEmpty { label = "（總指揮本身）" }
        return ["ok": true, "name": c.title, "id": String(c.id.uuidString.prefix(8)).lowercased(), "area": label]
    }

    /// codenv-todo area ls：區的樹，每個區底下的聊天室（未封存）
    func commanderAreaList(conversation conv: String?, name: String?, running: (UUID) -> Bool) -> [String: Any] {
        var session: SessionLayout?
        if let me = areaCaller(conv) { session = me.session }
        if session == nil, let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            session = sessions.first { $0.area == nil && $0.groups != nil && $0.name == n }
        }
        guard let s = session else { return ["ok": false, "error": "找不到你屬於哪個總指揮（在 codenv 的聊天室裡跑會自動認出；不然加 --by <總指揮名稱>）"] }
        let nodes = areaNodes(s)
        let members = commanderMembers(s)
        func row(_ c: Conversation) -> [String: Any] {
            let st = status[c.id]
            return ["name": c.title, "chief": c.id == s.chief, "id": String(c.id.uuidString.prefix(8)).lowercased(),
                    "state": st == .working ? "工作中" : st == .waiting ? "等你回答" : running(c.id) ? "待命（程序開著）" : "休眠"]
        }
        let areas: [[String: Any]] = nodes.map { n in
            ["name": n.group.name, "path": areaPath(n.group.id, in: s), "depth": n.depth,
             "chats": members.filter { areaID(of: $0, in: nodes) == n.group.id }.map(row)]
        }
        return ["ok": true, "commander": s.name, "areas": areas, "rootChats": members.filter { areaID(of: $0, in: nodes) == nil }.map(row)]
    }
}
