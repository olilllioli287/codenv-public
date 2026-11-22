import Foundation

/// 「區」＝總指揮涵蓋的頂層組底下的子組（可以任意層）。沿用 ConvGroup 的 parentID，不另起一套資料：
/// 研究區 › Hermes研究，在存檔裡就是兩個巢狀的組。multi 總指揮的子專案本來就是第一層子組，所以也是區。
/// 子組如果歸別的總指揮管（commanderSessionID 最深涵蓋勝出），就不算這個總指揮的區。
struct AreaNode {
    let group: ConvGroup
    let depth: Int            // 1＝直接掛在總指揮涵蓋的頂層組底下
    let parent: UUID?         // 上一層的區；nil＝直接連總指揮
}

struct AreaLeadContext {
    let caller: Conversation
    let session: SessionLayout
    let area: ConvGroup
}

extension Store {
    /// 含空區的完整樹；指令用它列出、尋找及刪除空區。
    func allAreaNodes(_ s: SessionLayout) -> [AreaNode] {
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

    /// 關聯圖與右欄只用有未封存聊天室的區；空區仍保留在完整樹供刪除指令處理。
    func areaNodes(_ s: SessionLayout) -> [AreaNode] {
        let all = allAreaNodes(s)
        let ids = Set(all.map { $0.group.id })
        var hasChats = Set<UUID>()
        for c in conversations where Store.isChat(c) && c.draft != true && !isArchived(c) {
            guard var id = groupOf(c), ids.contains(id) else { continue }
            while true {
                hasChats.insert(id)
                guard let parent = group(id)?.parentID, ids.contains(parent) else { break }
                id = parent
            }
        }
        return all.filter { hasChats.contains($0.group.id) }
    }

    /// 刪除指定總指揮底下的空區；有聊天室或任何子區都拒絕，避免 removeGroup 的提升子區行為。
    func commanderAreaRemove(caller: String?, name raw: String) -> [String: Any] {
        func fail(_ m: String) -> [String: Any] { ["ok": false, "error": m] }
        guard let me = areaCaller(caller) else { return fail("找不到你屬於哪個總指揮（要在 codenv 的聊天室裡跑）") }
        guard me.chief else { return fail("只有總指揮聊天室能刪區") }
        let found = findArea(raw, in: me.session)
        guard let g = found.area else { return fail(found.error ?? "找不到區") }
        guard childGroups(of: g.id).isEmpty else { return fail("不能刪「\(areaPath(g.id, in: me.session))」：裡面還有子區") }
        let inArea = conversations.filter { Store.isChat($0) && $0.draft != true && groupOf($0) == g.id }
        let hasChats = inArea.contains { !isArchived($0) }
        guard !hasChats else { return fail("不能刪「\(areaPath(g.id, in: me.session))」：裡面還有聊天室") }
        let label = areaPath(g.id, in: me.session)
        // 已封存的聊天室不阻止刪區，但先釘到父組；若原本是繼承 Project.groupID，單純刪組會讓它落到不相干的 fallback 組。
        let archived = inArea.filter { isArchived($0) }
        if !archived.isEmpty {
            guard let parent = archivedChatParent(for: g, in: me.session) else {
                return fail("不能刪「\(label)」：找不到有效的上層組，封存聊天室無法歸位")
            }
            for c in archived {
                if let i = conversations.firstIndex(where: { $0.id == c.id }) { conversations[i].groupID = parent }
            }
        }
        removeGroup(g.id)
        return ["ok": true, "path": label]
    }

    /// 封存聊天室刪區時的歸屬目標；驗證組仍存在且屬於同一總指揮，免得丟進 fallback 組。
    func archivedChatParent(for area: ConvGroup, in session: SessionLayout) -> UUID? {
        guard let parent = area.parentID ?? areaRoot(session), group(parent) != nil,
              commanderSessionID(forGroup: parent) == session.id else { return nil }
        return parent
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
        let nodes = allAreaNodes(s)
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
        let destinationIsArea = allAreaNodes(me.session).contains { $0.group.id == dest }
        for i in groups.indices where groups[i].areaLeadID == c.id {
            if !destinationIsArea || groups[i].id != dest { groups[i].areaLeadID = nil }
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
        let nodes = allAreaNodes(s)
        let members = commanderMembers(s)
        func row(_ c: Conversation) -> [String: Any] {
            let st = status[c.id]
            return ["name": c.title, "chief": c.id == s.chief, "id": String(c.id.uuidString.prefix(8)).lowercased(),
                    "state": st == .working ? "工作中" : st == .waiting ? "等你回答" : running(c.id) ? "待命（程序開著）" : "休眠"]
        }
        let areas: [[String: Any]] = nodes.map { n in
            ["name": n.group.name, "path": areaPath(n.group.id, in: s), "depth": n.depth,
             "lead": activeAreaLead(for: n.group, in: s)?.title ?? "",
             "chats": members.filter { areaID(of: $0, in: nodes) == n.group.id }.map(row)]
        }
        return ["ok": true, "commander": s.name, "areas": areas, "rootChats": members.filter { areaID(of: $0, in: nodes) == nil }.map(row)]
    }

    /// codenv-todo area lead：只有總指揮能指派／清除；區長必須是本區直接隸屬、未封存的 Claude 聊天室。
    func commanderAreaSetLead(caller: String?, name raw: String, target: String, clear: Bool) -> [String: Any] {
        func fail(_ m: String) -> [String: Any] { ["ok": false, "error": m] }
        guard let me = areaCaller(caller) else { return fail("找不到你屬於哪個總指揮（要在 codenv 的聊天室裡跑）") }
        guard me.chief else { return fail("只有總指揮聊天室能指派區長") }
        let found = findArea(raw, in: me.session)
        guard let area = found.area, let index = groups.firstIndex(where: { $0.id == area.id }) else { return fail(found.error ?? "找不到區") }
        if clear {
            groups[index].areaLeadID = nil
            _ = saveNow()
            return ["ok": true, "area": areaPath(area.id, in: me.session), "cleared": true]
        }
        let key = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return fail("要指定區長聊天室，取消指派請寫 --clear") }
        let members = conversations(inCommander: me.session).filter {
            Store.isChat($0) && !$0.isBrowser && $0.draft != true && groupOf($0) == area.id && !isArchived($0)
        }
        let byID = key.count >= 4 ? members.filter { $0.id.uuidString.lowercased().hasPrefix(key.lowercased()) } : []
        let matches = byID.count == 1 ? byID : members.filter { $0.title == key }
        guard matches.count == 1, let lead = matches.first else { return fail("區長必須是「\(area.name)」區內唯一符合的未封存聊天室") }
        guard lead.id != me.session.chief else { return fail("總指揮本人不能兼任區長") }
        guard lead.modelCategory == "claude" else { return fail("區長只能指定 Claude 聊天室") }
        for i in groups.indices where groups[i].areaLeadID == lead.id && groups[i].id != area.id {
            groups[i].areaLeadID = nil
        }
        groups[index].areaLeadID = lead.id
        _ = saveNow()
        return ["ok": true, "area": areaPath(area.id, in: me.session), "lead": lead.title, "id": String(lead.id.uuidString.prefix(8)).lowercased()]
    }

    /// 由聊天室 id 反查區長身分。區長只能涵蓋一個直接區節點；巢狀子區各自管理。
    func areaLeadContext(caller raw: String?) -> AreaLeadContext? {
        guard let caller = conversation(callerPrefix: raw), Store.isChat(caller),
              let session = commander(of: caller.id), caller.id != session.chief,
              !isArchived(caller), caller.modelCategory == "claude",
              let areaID = groupOf(caller),
              let area = allAreaNodes(session).first(where: { $0.group.id == areaID && $0.group.areaLeadID == caller.id })?.group else { return nil }
        return AreaLeadContext(caller: caller, session: session, area: area)
    }

    func activeAreaLead(for area: ConvGroup, in session: SessionLayout) -> Conversation? {
        guard allAreaNodes(session).contains(where: { $0.group.id == area.id }),
              commanderSessionID(forGroup: area.id) == session.id,
              let storedArea = group(area.id), let leadID = storedArea.areaLeadID,
              let lead = conversation(leadID), Store.isChat(lead), !isArchived(lead),
              lead.modelCategory == "claude", groupOf(lead) == area.id,
              commander(of: lead.id)?.id == session.id else { return nil }
        return lead
    }

    /// 回傳仍有效的區長；聊天室封存、換引擎或被搬出區後，卡住通知改送總指揮。
    func activeAreaLead(for member: Conversation, in session: SessionLayout) -> Conversation? {
        guard let areaID = groupOf(member), let area = group(areaID) else { return nil }
        return activeAreaLead(for: area, in: session)
    }

    /// 施工聊天室可回報的最近有效區長；若自己所在區沒有區長，沿 parentID 往上找。
    /// 區長本人也可往上回報，因此跳過呼叫者自己。
    func reportingAreaLead(for member: Conversation, in session: SessionLayout) -> (lead: Conversation, area: ConvGroup)? {
        let areaIDs = Set(allAreaNodes(session).map { $0.group.id })
        var current = groupOf(member)
        var seen = Set<UUID>()
        while let id = current, areaIDs.contains(id), seen.insert(id).inserted, let area = group(id) {
            if let lead = activeAreaLead(for: area, in: session), lead.id != member.id { return (lead, area) }
            current = area.parentID
        }
        return nil
    }

    /// 區長不能以 stop 或 --interrupt 中斷自己的回合；一般 send self 仍可用。
    func areaLeadTargetsSelf(caller: String?, target: Conversation) -> Bool {
        areaLeadContext(caller: caller)?.caller.id == target.id
    }

    func areaLeadMembers(_ context: AreaLeadContext, allowArchived: Bool = false) -> [Conversation] {
        conversations(inCommander: context.session).filter {
            Store.isChat($0) && !$0.isBrowser && $0.draft != true && $0.id != context.session.chief
                && groupOf($0) == context.area.id && (allowArchived || !isArchived($0))
        }
    }

    /// 區長解析目標時只在本區內搜尋；空字串／self 指區長本人。
    func areaLeadTarget(_ raw: String, context: AreaLeadContext, allowArchived: Bool = false) -> (Conversation?, String?) {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty || key == "self" { return (context.caller, nil) }
        let members = areaLeadMembers(context, allowArchived: allowArchived)
        let byID = key.count >= 4 ? members.filter { $0.id.uuidString.lowercased().hasPrefix(key.lowercased()) } : []
        let hits = byID.count == 1 ? byID : members.filter { $0.title == key }
        if hits.count > 1 { return (nil, "有多個聊天室符合「\(key)」，請改用 id") }
        guard let c = hits.first else { return (nil, "在「\(areaPath(context.area.id, in: context.session))」區找不到「\(key)」") }
        return (c, nil)
    }

    func areaLeadTeamInfo(_ context: AreaLeadContext, running: (UUID) -> Bool) -> [String: Any] {
        let nodes = allAreaNodes(context.session)
        let members = areaLeadMembers(context)
        let rows: [[String: Any]] = members.map { c in
            let state = status[c.id] == .working ? (CommanderStuck.shared.minutes(c.id).map { "可能卡住（\($0) 分鐘沒輸出）" } ?? "工作中")
                : status[c.id] == .waiting ? "等你回答" : running(c.id) ? "待命（程序開著）" : "休眠"
            return ["name": c.title, "chief": c.id == context.caller.id, "state": state,
                    "placed": locate(c.id) != nil, "id": String(c.id.uuidString.prefix(8)).lowercased(),
                    "engine": c.modelCategory, "topic": Store.cleanTopic(c.topic ?? "") ?? "",
                    "area": areaPath(context.area.id, in: context.session)]
        }
        return ["ok": true, "kind": "area", "commander": context.area.name, "chief": context.caller.title,
                "area": areaPath(context.area.id, in: context.session), "members": rows,
                "areas": nodes.count]
    }

    func areaLeadRoleNote(for id: UUID) -> String? {
        guard let context = areaLeadContext(caller: id.uuidString) else { return nil }
        let members = areaLeadMembers(context).filter { $0.id != id }
        let list = members.isEmpty ? "（目前沒有其他聊天室）" : members.map { "「\($0.title)」" + (Store.cleanTopic($0.topic ?? "").map { "（負責：\(Store.oneLine($0, 80))）" } ?? "") }.joined(separator: "、")
        let commanderName = context.session.chief.flatMap { conversation($0)?.title } ?? context.session.name
        return """
        你是「\(areaPath(context.area.id, in: context.session))」區區長；上面總指揮是「\(commanderName)」。本區未封存成員：\(list)。
        收到總指揮指令後，拆成清楚的小工作交給本區成員，盯進度並驗收；驗收完成後用 SendMessage 回報總指揮。區長負責本區，不代替總指揮指揮其他區。
        `codenv-todo team` 只會列出本區成員；用 `send`、`send --wait`、`send --steer`、`send --interrupt`、`stop`、`last`、`wake`、`model`、`topic`、`rename` 管理本區。`codenv-todo new "<名字>"` 開的新聊天室會自動放進本區。
        你不能管理區外聊天室、總指揮本人，也不能使用 `archive` 或 `handoff`。要回報或升級給上面總指揮，使用 SendMessage。
        """
    }

    /// 純暫存 Store 自測：區長指派、權限邊界、team 範圍、新聊天室歸區與封存聊天室刪區保留。
    static func runAreaLeadSelfTest(in dir: URL, out: String) -> Bool {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let st = Store(directory: dir)
        st.projects = []; st.conversations = []; st.sessions = []; st.groups = []; st.status = [:]
        let root = ConvGroup(name: "總指揮組")
        let area = ConvGroup(name: "施工班", parentID: root.id)
        let secondArea = ConvGroup(name: "第二區", parentID: root.id)
        let archivedArea = ConvGroup(name: "待刪區", parentID: root.id)
        st.groups = [root, area, secondArea, archivedArea]
        let rootProject = Project(name: "root", path: "/tmp", groupID: root.id)
        let archivedProject = Project(name: "archived", path: "/tmp", groupID: archivedArea.id)
        st.projects = [rootProject, archivedProject]
        var chief = Conversation(projectID: rootProject.id, title: "總指揮"); chief.groupID = root.id
        var lead = Conversation(projectID: rootProject.id, title: "區長"); lead.groupID = area.id
        var member = Conversation(projectID: rootProject.id, title: "本區成員"); member.groupID = area.id
        member.model = "codex:gpt-6-luna"
        var outside = Conversation(projectID: rootProject.id, title: "區外成員"); outside.groupID = root.id
        var movingLead = Conversation(projectID: rootProject.id, title: "移區區長"); movingLead.groupID = area.id
        var archived = Conversation(projectID: archivedProject.id, title: "封存成員")
        archived.manualArchive = true
        st.conversations = [chief, lead, member, outside, movingLead, archived]
        st.sessions = [SessionLayout(name: "測試總指揮", windows: [], groups: [root.id], chief: chief.id)]

        let assign = st.commanderAreaSetLead(caller: chief.id.uuidString, name: area.name, target: lead.title, clear: false)
        let nonClaudeAssign = st.commanderAreaSetLead(caller: chief.id.uuidString, name: area.name, target: member.title, clear: false)
        let nonChiefAssign = st.commanderAreaSetLead(caller: outside.id.uuidString, name: area.name, target: lead.title, clear: false)
        let context = st.areaLeadContext(caller: lead.id.uuidString)
        let team = context.map { st.areaLeadTeamInfo($0, running: { _ in false })["members"] as? [[String: Any]] ?? [] } ?? []
        let teamNames = Set(team.compactMap { $0["name"] as? String })
        let activeLeadResolved = context.map { st.activeAreaLead(for: member, in: $0.session)?.id == lead.id } ?? false
        func listedLead(_ areaName: String) -> String? {
            let result = st.commanderAreaList(conversation: chief.id.uuidString, name: nil, running: { _ in false })
            let rows = result["areas"] as? [[String: Any]] ?? []
            return rows.first(where: { $0["name"] as? String == areaName })?["lead"] as? String
        }
        let validLeadListed = listedLead(area.name) == lead.title
        if let i = st.conversations.firstIndex(where: { $0.id == lead.id }) { st.conversations[i].manualArchive = true }
        let archivedLeadHidden = st.activeAreaLead(for: area, in: st.sessions[0]) == nil && listedLead(area.name) == ""
        if let i = st.conversations.firstIndex(where: { $0.id == lead.id }) { st.conversations[i].manualArchive = nil }
        if let i = st.conversations.firstIndex(where: { $0.id == lead.id }) { st.conversations[i].model = "codex:gpt-6-luna" }
        let changedModelLeadHidden = st.activeAreaLead(for: area, in: st.sessions[0]) == nil && listedLead(area.name) == ""
        if let i = st.conversations.firstIndex(where: { $0.id == lead.id }) { st.conversations[i].model = nil }
        let outsideTarget = context.map { st.areaLeadTarget(outside.title, context: $0).0 == nil } ?? false
        let chiefTarget = context.map { st.areaLeadTarget(chief.title, context: $0).0 == nil } ?? false
        let archive = st.commanderArchive(caller: lead.id.uuidString, target: member.title)
        let handoff = st.commanderHandoffInfo(caller: lead.id.uuidString, target: member.title)
        let renameMember = st.commanderRename(caller: lead.id.uuidString, target: member.title, name: "本區成員新名")
        let renameOutside = st.commanderRename(caller: lead.id.uuidString, target: outside.title, name: "越權改名")
        let selfByName = context.flatMap { st.areaLeadTarget(lead.title, context: $0).0 }
        let selfByAlias = context.flatMap { st.areaLeadTarget("self", context: $0).0 }
        let selfByID = context.flatMap { st.areaLeadTarget(String(lead.id.uuidString.prefix(8)), context: $0).0 }
        let selfInterruptBlocked = [selfByName, selfByAlias, selfByID].allSatisfy {
            guard let target = $0 else { return false }
            return st.areaLeadTargetsSelf(caller: lead.id.uuidString, target: target)
        }
        let memberInterruptAllowed = st.areaLeadTargetsSelf(caller: lead.id.uuidString, target: member) == false
        let create = st.commanderCreate(caller: lead.id.uuidString, name: "區內新聊天室", dir: nil)
        let createdInArea = create.conversation.map { st.groupOf($0) == area.id } ?? false
        let ordinaryNew = st.commanderCreate(caller: outside.id.uuidString, name: "越權聊天室", dir: nil)
        let removeArchived = st.commanderAreaRemove(caller: chief.id.uuidString, name: archivedArea.name)
        let archivedReturnedToParent = st.conversation(archived.id).map { $0.groupID == root.id } ?? false
        let broken = Store(directory: dir.appendingPathComponent("missing-parent", isDirectory: true))
        broken.projects = []; broken.conversations = []; broken.sessions = []; broken.groups = []; broken.status = [:]
        let missingRoot = UUID()
        let validRoot = ConvGroup(name: "有效根組")
        let orphanArea = ConvGroup(name: "失聯根區", parentID: missingRoot)
        let chiefProject = Project(name: "chief", path: "/tmp/chief", groupID: validRoot.id)
        let orphanProject = Project(name: "orphan", path: "/tmp/orphan", groupID: orphanArea.id)
        var orphanChief = Conversation(projectID: chiefProject.id, title: "失聯總指揮"); orphanChief.groupID = validRoot.id
        var orphanArchived = Conversation(projectID: orphanProject.id, title: "失聯封存聊天室"); orphanArchived.manualArchive = true
        broken.groups = [validRoot, orphanArea]; broken.projects = [chiefProject, orphanProject]
        broken.conversations = [orphanChief, orphanArchived]
        broken.sessions = [SessionLayout(name: "失聯總指揮", windows: [], groups: [validRoot.id, missingRoot], chief: orphanChief.id)]
        let missingParentResult = broken.commanderAreaRemove(caller: orphanChief.id.uuidString, name: orphanArea.name)
        let missingParentError = missingParentResult["error"] as? String
        let missingArchiveParentRejected = missingParentResult["ok"] as? Bool == false
            && missingParentError?.contains("找不到有效的上層組") == true
            && broken.group(orphanArea.id) != nil && broken.conversation(orphanArchived.id)?.groupID == nil
        let clear = st.commanderAreaSetLead(caller: chief.id.uuidString, name: area.name, target: "", clear: true)
        let clearWorked = clear["ok"] as? Bool == true && st.areaLeadContext(caller: lead.id.uuidString) == nil

        _ = st.commanderAreaSetLead(caller: chief.id.uuidString, name: area.name, target: movingLead.title, clear: false)
        let moved = st.commanderAreaMove(caller: chief.id.uuidString, target: movingLead.title, area: secondArea.name)
        let moveClearedOld = moved["ok"] as? Bool == true && st.group(area.id)?.areaLeadID != movingLead.id
        if let i = st.groups.firstIndex(where: { $0.id == area.id }) { st.groups[i].areaLeadID = movingLead.id } // 舊 state 的重複指標
        let assignedToSecond = st.commanderAreaSetLead(caller: chief.id.uuidString, name: secondArea.name, target: movingLead.title, clear: false)
        let assignmentClearedOther = assignedToSecond["ok"] as? Bool == true && st.group(area.id)?.areaLeadID == nil
        if let i = st.groups.firstIndex(where: { $0.id == area.id }) { st.groups[i].areaLeadID = movingLead.id }
        let contextUsesCurrentArea = st.areaLeadContext(caller: movingLead.id.uuidString)?.area.id == secondArea.id
        let currentAreaListShowsLead = listedLead(secondArea.name) == movingLead.title && listedLead(area.name) == ""

        let stuckStart = Date(timeIntervalSince1970: 1_000)
        func escalation(_ t: Date, _ notifiedAt: Date?, alreadyNotified: Bool = false) -> CommanderStuck.Escalation {
            CommanderStuck.nextEscalation(areaLead: lead.id, subject: member.id, commander: chief.id,
                                          areaNotifiedAt: notifiedAt, commanderAlreadyNotified: alreadyNotified, now: t)
        }
        func isArea(_ v: CommanderStuck.Escalation) -> Bool { if case .areaLead = v { return true }; return false }
        func hasCommanderReason(_ v: CommanderStuck.Escalation, _ expected: CommanderStuck.CommanderEscalationReason) -> Bool {
            if case .commander(let reason) = v { return reason == expected }; return false
        }
        func isNone(_ v: CommanderStuck.Escalation) -> Bool { if case .none = v { return true }; return false }
        let values: [(String, Bool)] = [
            ("chief_can_assign", assign["ok"] as? Bool == true),
            ("non_claude_cannot_be_area_lead", nonClaudeAssign["ok"] as? Bool == false),
            ("non_chief_cannot_assign", nonChiefAssign["ok"] as? Bool == false),
            ("team_only_own_area", teamNames == Set([lead.title, member.title, movingLead.title]) && !teamNames.contains(outside.title)),
            ("stuck_uses_active_area_lead", activeLeadResolved),
            ("active_area_lead_shown_in_area_list", validLeadListed),
            ("archived_area_lead_hidden", archivedLeadHidden),
            ("non_claude_area_lead_hidden", changedModelLeadHidden),
            ("outside_target_refused", outsideTarget),
            ("commander_target_refused", chiefTarget),
            ("area_lead_archive_refused", archive["ok"] as? Bool == false),
            ("area_lead_handoff_refused", handoff["ok"] as? Bool == false),
            ("area_lead_rename_own_member", renameMember["ok"] as? Bool == true),
            ("area_lead_rename_outside_refused", renameOutside["ok"] as? Bool == false),
            ("area_lead_new_in_area", create.reply["ok"] as? Bool == true && createdInArea),
            ("ordinary_member_cannot_new", ordinaryNew.reply["ok"] as? Bool == false),
            ("archived_only_area_removable", removeArchived["ok"] as? Bool == true),
            ("archived_chat_kept_in_parent", archivedReturnedToParent),
            ("missing_archive_parent_rejected", missingArchiveParentRejected),
            ("area_move_clears_old_lead_pointer", moveClearedOld),
            ("area_assign_clears_other_lead_pointer", assignmentClearedOther),
            ("area_context_uses_current_group", contextUsesCurrentArea),
            ("area_list_shows_only_current_lead", currentAreaListShowsLead),
            ("area_lead_self_interrupt_blocked", selfInterruptBlocked),
            ("area_lead_member_interrupt_allowed", memberInterruptAllowed),
            ("chief_can_clear", clearWorked),
            ("stuck_first_notifies_area_lead", isArea(escalation(stuckStart, nil))),
            ("stuck_before_ten_minutes_not_escalated", isNone(escalation(stuckStart.addingTimeInterval(599), stuckStart))),
            ("stuck_after_ten_minutes_notifies_commander", hasCommanderReason(escalation(stuckStart.addingTimeInterval(600), stuckStart), .areaLeadTimeout)),
            ("stuck_removed_lead_reports_invalid", hasCommanderReason(CommanderStuck.nextEscalation(areaLead: nil, subject: member.id,
                commander: chief.id, areaNotifiedAt: stuckStart, commanderAlreadyNotified: false, now: stuckStart.addingTimeInterval(120)), .areaLeadInvalid)),
            ("stuck_without_area_lead_reports_no_lead", hasCommanderReason(CommanderStuck.nextEscalation(areaLead: nil, subject: member.id,
                commander: chief.id, areaNotifiedAt: nil, commanderAlreadyNotified: false, now: stuckStart), .noAreaLead))
        ]
        let text = values.map { "\($0.0)=\($0.1)" }.joined(separator: "\n") + "\nmissing_archive_parent_message=\(missingParentError ?? "<none>")\n"
        try? text.write(toFile: out, atomically: true, encoding: .utf8)
        return values.allSatisfy(\.1)
    }
}
