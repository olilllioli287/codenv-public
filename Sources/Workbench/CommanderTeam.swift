import Foundation

/// 總指揮知道自己底下有誰（在某個總指揮說，它卻去列 codenv 的聊天室）。
/// 兩個入口：總指揮聊天室啟動時附在系統提示的角色說明；codenv-todo team 隨時查最新名單。
extension Store {
    /// 這段聊天室是某個總指揮的聊天室：回傳角色說明；不是就 nil（一般聊天室不加任何東西）
    func commanderRoleNote(for id: UUID) -> String? {
        guard Prefs.shared.sidebarMode == "commander",
              let session = sessions.first(where: { $0.area == nil && $0.chief == id }) else { return nil }
        let members = commanderMembers(session).filter { $0.id != id }
        let list = members.isEmpty ? "（目前沒有別的聊天室）" : members.map { m in "「\(m.title)」" + (Store.cleanTopic(m.topic ?? "").map { "（負責：\(Store.oneLine($0, 80))）" } ?? "") }.joined(separator: "、")
        return """
        你是 codenv 裡「\(session.name)」這個總指揮的總指揮聊天室。你底下的聊天室（未封存）：\(list)。
        「交給某某」「大家」時，指的是這份名單裡的聊天室，不是 codenv 裡其他總指揮的聊天室。
        \(kindNote(session))
        開新聊天室或派工時，順手替它寫一句說明（它負責什麼，約 20～60 字；使用者在 codenv 右欄看得到，聊天室自己的 Claude 也會在系統提示看到「你負責：…」）：`codenv-todo new "<名字>" --topic "<說明>"`，已存在的用 `codenv-todo topic "<名字或 id>" "<說明>"`（使用者自己寫的說明會被拒絕）。
        派工或接手新分支時，用 `codenv-todo rename "<原名字或 id>" "<新名字>"` 把底下聊天室改成看得出在做什麼的短名（約 4～10 字，例如「浮動終端機」）；不要改使用者自己取的名字（會被拒絕），也不要改總指揮自己的名字。已經做完、不再需要的聊天室可用 `codenv-todo archive "<名字或 id>"` 封存（工作中的會被拒絕）。
        開分支預設用 Sonnet（`codenv-todo new` 沒給 --model 就是 Sonnet）；難題才加 `--model opus`，簡單的跑腿用 `--model haiku`。已存在的聊天室要換模型：`codenv-todo model "<名字或 id>" <sonnet|opus|haiku> [--effort low|medium|high]`（工作中的會被拒絕，等它閒下來再換）。不能用 Fable。
        聊天室載入哪些 MCP（外部工具）：`codenv-todo mcp "<名字或 id|self>" lite|none|full`（lite 只留 deja、none 全不載，下次啟動才生效，工作中的也可以改）。需要瀏覽器工具（chrome-devtools、claude-in-chrome）時用 `codenv-todo mcp self full`，再請使用者或總指揮重啟你。
        聊天室多了就分區：`codenv-todo area add "<區名>" [--parent "<上層區>"]` 建區（可以一層一層套，例如 研究區 › Hermes研究），`codenv-todo area move "<聊天室名字或 id>" "<區名>"` 搬進去（區名寫 root 放回總指揮本身），`codenv-todo area ls` 看目前的區。開分支時用 `codenv-todo new "<名字>" --area "<區名>"` 直接放進對的區；使用者在 codenv 右欄看得到區的分組與關聯圖。
        讀程式／審查／量大批次優先開 codex 或 copilot 聊天室（不花 Claude 額度）：`codenv-todo new "<名字>" --engine codex`（copilot 同；agy 預設 Flash，Argon 很耗額度留給難題）。非 Claude 聊天室用 `codenv-todo send "<名字>" "<訊息>" --wait` 派工並讀回答；SendMessage 只通 Claude 聊天室。它們不能用 codenv-todo 指令，結果靠 `send --wait` 或 `last` 讀。
        派給 Claude 聊天室時先 `codenv-todo wake "<名字>"` 再用 SendMessage；派給非 Claude 聊天室直接用 `codenv-todo send`。名單、狀態用 `codenv-todo team` 查。
        只在使用者要你派工時才派；別的聊天室的工作交給它們自己做，不要替它們做完。
        """
    }

    /// 角色說明裡依類型不同的那段（開新聊天室怎麼開）
    private func kindNote(_ session: SessionLayout) -> String {
        if commanderIsMulti(session) {
            let subs = subProjects(session).map { "「\($0.name)」" }.joined(separator: "、")
            return "這個總指揮是「多個子專案」型：底下的子專案有 \(subs.isEmpty ? "（目前沒有）" : subs)，每個聊天室屬於其中一個。需要新的分支就用 `codenv-todo new \"<名字>\" --project \"<子專案名>\"` 開一個並取好名字（一定要指定子專案；子專案還不存在就加 `--dir <資料夾>`，會在這個總指揮底下新建那個子專案），再 SendMessage 派工；只在使用者要你派工時才開。"
        }
        return "這個總指揮是「單一專案」型：底下的聊天室都在同一個專案裡，按任務分（不是按子專案分）。需要新的分支就用 `codenv-todo new \"<名字>\"` 開一個並取好名字，再 SendMessage 派工；只在使用者要你派工時才開。"
    }

    /// 這個總指揮底下未封存的聊天室（不含掛件、瀏覽器、終端機），總指揮排第一
    func commanderMembers(_ session: SessionLayout) -> [Conversation] {
        let all = conversations(inCommander: session).filter { Store.isChat($0) && !isArchived($0) }
        return all.sorted { a, b in (a.id == session.chief) && (b.id != session.chief) }
    }

    /// codenv-todo team 的資料：conv＝呼叫者的聊天室 id（CODENV_CONVERSATION），或 name＝總指揮名稱／聊天室名字
    func teamInfo(conversation: String?, name: String?, running: (UUID) -> Bool) -> [String: Any] {
        var session: SessionLayout?
        if let conv = conversation?.lowercased(), !conv.isEmpty,
           let c = self.conversation(callerPrefix: conv),
           let g = groupOf(c), let sid = commanderSessionID(forGroup: g) {
            session = sessions.first { $0.id == sid }
        }
        if session == nil, let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty {
            session = sessions.first { $0.area == nil && $0.groups != nil && $0.name == n }
            if session == nil, let c = conversations.first(where: { $0.title == n }), let g = groupOf(c), let sid = commanderSessionID(forGroup: g) {
                session = sessions.first { $0.id == sid }
            }
        }
        guard let s = session else {
            return ["ok": false, "error": "找不到你屬於哪個總指揮（在 codenv 的聊天室裡跑會自動認出；不然加 --by <總指揮名稱或聊天室名字>）"]
        }
        let multi = commanderIsMulti(s)
        let members: [[String: Any]] = commanderMembers(s).map { c in
            let st = status[c.id]
            let isClaude = c.model == nil || !c.model!.contains(":")
            let isRunning = running(c.id)
            let state = st == .working ? "工作中" : st == .waiting ? "等你回答" : isRunning ? "待命（程序開著）" : "休眠"
            var m: [String: Any] = ["name": c.title, "chief": c.id == s.chief, "state": state, "placed": locate(c.id) != nil,
                                    "id": String(c.id.uuidString.prefix(8)).lowercased(), "engine": isClaude ? "claude" : String(c.model!.prefix(while: { $0 != ":" }))]
            if let t = Store.cleanTopic(c.topic ?? "") { m["topic"] = t }
            let nodes = areaNodes(s)
            m["area"] = areaID(of: c, in: nodes).map { areaPath($0, in: s) } ?? ""
            if multi { m["project"] = subProject(of: c, in: s)?.name ?? (c.id == s.chief ? "" : "未分子專案") }
            return m
        }
        return ["ok": true, "kind": multi ? "multi" : "single", "subProjects": multi ? subProjects(s).map(\.name) : [], "commander": s.name, "chief": s.chief.flatMap { self.conversation($0)?.title } ?? "", "members": members]
    }
}

/// 總指揮自己管底下聊天室的名字、開新聊天室（codenv-todo rename／new）
extension Store {
    private func callerInfo(_ conv: String?) -> (caller: Conversation, session: SessionLayout, chief: Bool)? {
        guard let cv = conv?.lowercased(), !cv.isEmpty,
              let c = conversation(callerPrefix: cv),
              let s = commander(of: c.id) else { return nil }
        return (c, s, s.chief == c.id)
    }

    /// 右鍵「MCP」：下次啟動 claude 時生效（正在跑的不動）
    func setMcp(_ id: UUID, _ mode: McpMode) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[i].mcp = mode == .full ? nil : mode.rawValue
    }

    /// 右鍵「讓總指揮改名」：使用者放行，總指揮才能改他自己取的名字（只能在 App 裡勾，指令沒有對應旗標）
    func setCommanderMayRename(_ id: UUID, _ on: Bool) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[i].commanderMayRename = on ? true : nil
    }

    private func cleanName(_ raw: String) -> String {
        raw.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 同一個總指揮底下（含封存的）有沒有別的聊天室叫這個名字
    private func nameTaken(_ name: String, in session: SessionLayout, except: UUID?) -> Bool {
        conversations(inCommander: session).contains { $0.id != except && $0.title == name }
    }

    func commanderRename(caller: String?, target: String, name raw: String) -> [String: Any] {
        func fail(_ m: String) -> [String: Any] { ["ok": false, "error": m] }
        guard let me = callerInfo(caller) else { return fail("找不到你屬於哪個總指揮（要在 codenv 的聊天室裡跑）") }
        let name = cleanName(raw)
        guard !name.isEmpty else { return fail("新名字不能是空的") }
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        var hit: Conversation?
        if t.isEmpty { hit = me.caller }
        else {
            let members = conversations(inCommander: me.session).filter { Store.isChat($0) }
            let byId = t.count >= 4 ? members.filter { $0.id.uuidString.lowercased().hasPrefix(t.lowercased()) } : []
            let byName = members.filter { $0.title == t }
            let pool = byId.count == 1 ? byId : byName
            if pool.count > 1 {
                let ids = pool.map { String($0.id.uuidString.prefix(8)).lowercased() }.joined(separator: "、")
                return fail("有 \(pool.count) 個聊天室都叫「\(t)」，請改用 id（\(ids)）")
            }
            hit = pool.first
        }
        guard let c = hit else { return fail("在你的總指揮底下找不到「\(t)」（codenv-todo team 看名單）") }
        if c.id != me.caller.id && !me.chief { return fail("只有總指揮能改別的聊天室的名字，你只能改自己的") }
        if c.renamed && c.namedByCommander != true && c.commanderMayRename != true {
            return fail("這是使用者取的名字；要改請他在聊天室右鍵勾「讓總指揮改名」")
        }
        if nameTaken(name, in: me.session, except: c.id) { return fail("這個總指揮底下已經有叫「\(name)」的聊天室，換一個名字") }
        let old = c.title
        rename(c.id, to: name, byUser: true)           // 走使用者改名同一條（onUserRename → ChatSession.syncName）
        if let i = conversations.firstIndex(where: { $0.id == c.id }) { conversations[i].namedByCommander = true }
        return ["ok": true, "old": old, "name": name, "id": String(c.id.uuidString.prefix(8)).lowercased()]
    }

    /// 說明壓成一行（名單、指令輸出用）
    static func oneLine(_ s: String, _ max: Int) -> String {
        let t = s.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return t.count > max ? String(t.prefix(max)) + "…" : t
    }

    /// codenv-todo topic：改聊天室說明。權限同 rename（總指揮改底下的、任何聊天室改自己）；使用者在 App 裡寫的說明受同樣的保護
    /// （要他右鍵勾「讓總指揮改名」）；說明是空字串＝清掉。回傳 ok 時帶 uuid（呼叫端通知正在跑的 Claude）
    func commanderSetTopic(caller: String?, target: String, topic raw: String) -> [String: Any] {
        func fail(_ m: String) -> [String: Any] { ["ok": false, "error": m] }
        guard let me = callerInfo(caller) else { return fail("找不到你屬於哪個總指揮（要在 codenv 的聊天室裡跑）") }
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        var hit: Conversation?
        if t.isEmpty || t == "self" { hit = me.caller }
        else {
            let members = conversations(inCommander: me.session).filter { Store.isChat($0) }
            let byId = t.count >= 4 ? members.filter { $0.id.uuidString.lowercased().hasPrefix(t.lowercased()) } : []
            let byName = members.filter { $0.title == t }
            let pool = byId.count == 1 ? byId : byName
            if pool.count > 1 {
                let ids = pool.map { String($0.id.uuidString.prefix(8)).lowercased() }.joined(separator: "、")
                return fail("有 \(pool.count) 個聊天室都叫「\(t)」，請改用 id（\(ids)）")
            }
            hit = pool.first
        }
        guard let c = hit else { return fail("在你的總指揮底下找不到「\(t)」（codenv-todo team 看名單）") }
        if c.id != me.caller.id && !me.chief { return fail("只有總指揮能改別的聊天室的說明，你只能改自己的") }
        if Store.cleanTopic(c.topic ?? "") != nil && c.topicByCommander != true && c.commanderMayRename != true {
            return fail("這是使用者寫的說明；要改請他在聊天室右鍵勾「讓總指揮改名」")
        }
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).count > Store.topicLimit { return fail("說明太長（上限 \(Store.topicLimit) 字）") }
        setTopic(c.id, raw, byUser: false)
        let busy = status[c.id].map { $0 == .working || $0 == .waiting } ?? false
        return ["ok": true, "id": String(c.id.uuidString.prefix(8)).lowercased(), "name": c.title, "topic": Store.cleanTopic(raw) ?? "", "working": busy, "uuid": c.id.uuidString]
    }

    /// codenv-todo archive：總指揮封存自己底下、目前沒在工作的聊天室；工作中的拒絕並說明
    func commanderArchive(caller: String?, target: String) -> [String: Any] {
        func fail(_ m: String) -> [String: Any] { ["ok": false, "error": m] }
        guard let me = callerInfo(caller) else { return fail("找不到你屬於哪個總指揮（要在 codenv 的聊天室裡跑）") }
        guard me.chief else { return fail("只有總指揮能封存底下的聊天室") }
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return fail("要指定哪個聊天室") }
        var hit: Conversation?
        if t == "self" { hit = me.caller }
        else {
            let members = conversations(inCommander: me.session).filter { Store.isChat($0) }
            let byId = t.count >= 4 ? members.filter { $0.id.uuidString.lowercased().hasPrefix(t.lowercased()) } : []
            let byName = members.filter { $0.title == t }
            let pool = byId.count == 1 ? byId : byName
            if pool.count > 1 {
                let ids = pool.map { String($0.id.uuidString.prefix(8)).lowercased() }.joined(separator: "、")
                return fail("有 \(pool.count) 個聊天室都叫「\(t)」，請改用 id（\(ids)）")
            }
            hit = pool.first
        }
        guard let c = hit else { return fail("在你的總指揮底下找不到「\(t)」（codenv-todo team 看名單）") }
        if c.id == me.session.chief { return fail("不能封存總指揮聊天室自己") }
        if let st = status[c.id], st == .working || st == .waiting {
            return fail("「\(c.title)」正在工作中，請等它閒下來再封存（codenv-todo team 看狀態）")
        }
        setArchived(c.id, true)
        return ["ok": true, "id": String(c.id.uuidString.prefix(8)).lowercased(), "name": c.title]
    }

    /// 無視窗自測（main.swift 在建立 NSApplication 前呼叫）：只用指定的暫存 --state-dir，不開視窗、不碰正式資料
    static func runArchiveSelfTest(in dir: URL, out: String, waitStop: Bool = false) -> Bool {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let st = Store(directory: dir)
        let g1 = ConvGroup(name: "G1"), g2 = ConvGroup(name: "G2")
        st.groups.append(contentsOf: [g1, g2])
        let p1 = Project(name: "p1", path: "/tmp", groupID: g1.id), p2 = Project(name: "p2", path: "/tmp", groupID: g2.id)
        st.projects.append(contentsOf: [p1, p2])
        var chief1 = Conversation(projectID: p1.id, title: "總指揮甲"); chief1.groupID = g1.id
        var idle = Conversation(projectID: p1.id, title: "閒置分支"); idle.groupID = g1.id
        var cliIdle = Conversation(projectID: p1.id, title: "指令分支"); cliIdle.groupID = g1.id
        var busy = Conversation(projectID: p1.id, title: "工作分支"); busy.groupID = g1.id
        var wait = Conversation(projectID: p1.id, title: "等待分支"); wait.groupID = g1.id
        var dup1 = Conversation(projectID: p1.id, title: "同名分支"); dup1.groupID = g1.id
        var dup2 = Conversation(projectID: p1.id, title: "同名分支"); dup2.groupID = g1.id
        var chief2 = Conversation(projectID: p2.id, title: "總指揮乙"); chief2.groupID = g2.id
        var other = Conversation(projectID: p2.id, title: "別組分支"); other.groupID = g2.id
        st.conversations.append(contentsOf: [chief1, idle, cliIdle, busy, wait, dup1, dup2, chief2, other])
        let s1 = SessionLayout(name: "S1", windows: [], groups: [g1.id], chief: chief1.id)
        let s2 = SessionLayout(name: "S2", windows: [], groups: [g2.id], chief: chief2.id)
        st.sessions.append(contentsOf: [s1, s2])
        st.status[busy.id] = .working
        st.status[wait.id] = .waiting
        BrowserServer.shared.archiveChat = { conv, target, done in
            done(st.commanderArchive(caller: conv, target: target))
        }
        BrowserServer.shared.start()
        let rNonChief = st.commanderArchive(caller: idle.id.uuidString, target: "閒置分支")
        let rSelf = st.commanderArchive(caller: chief1.id.uuidString, target: "self")
        let rOther = st.commanderArchive(caller: chief1.id.uuidString, target: "別組分支")
        let rBusy = st.commanderArchive(caller: chief1.id.uuidString, target: "工作分支")
        let rWait = st.commanderArchive(caller: chief1.id.uuidString, target: "等待分支")
        let rDup = st.commanderArchive(caller: chief1.id.uuidString, target: "同名分支")
        let rIdle = st.commanderArchive(caller: chief1.id.uuidString, target: "閒置分支")
        let rById = st.commanderArchive(caller: chief1.id.uuidString, target: String(dup1.id.uuidString.prefix(8)))
        let lines = [
            "chief1_id=\(chief1.id.uuidString)",
            "nonChief_ok=\(rNonChief["ok"] as? Bool ?? true)",
            "self_ok=\(rSelf["ok"] as? Bool ?? true)",
            "other_ok=\(rOther["ok"] as? Bool ?? true)",
            "other_archived=\(st.conversation(other.id).map { st.isArchived($0) } ?? true)",
            "busy_ok=\(rBusy["ok"] as? Bool ?? true)",
            "busy_err=\(rBusy["error"] as? String ?? "")",
            "busy_archived=\(st.conversation(busy.id).map { st.isArchived($0) } ?? true)",
            "wait_ok=\(rWait["ok"] as? Bool ?? true)",
            "wait_archived=\(st.conversation(wait.id).map { st.isArchived($0) } ?? true)",
            "dup_ok=\(rDup["ok"] as? Bool ?? true)",
            "idle_ok=\(rIdle["ok"] as? Bool ?? false)",
            "idle_archived=\(st.conversation(idle.id).map { st.isArchived($0) } ?? false)",
            "byId_ok=\(rById["ok"] as? Bool ?? false)",
            "dup1_archived=\(st.conversation(dup1.id).map { st.isArchived($0) } ?? false)",
            "dup2_archived=\(st.conversation(dup2.id).map { st.isArchived($0) } ?? true)",
        ]
        try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
        if waitStop {
            let stopFile = dir.appendingPathComponent("stop-selftest").path
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline && !FileManager.default.fileExists(atPath: stopFile) {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
        }
        BrowserServer.shared.stop()
        return (rIdle["ok"] as? Bool == true) && (rBusy["ok"] as? Bool == false) && (rNonChief["ok"] as? Bool == false) && (rOther["ok"] as? Bool == false)
    }

    /// 模型名稱檢查：只收 sonnet／opus／haiku／claude- 開頭的完整 id；任何含 fable 的寫法一律拒絕（使用者嚴禁）
    static func normalizeModel(_ raw: String) -> (value: String?, error: String?) {
        let m = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if m.isEmpty { return (nil, "模型名稱是空的") }
        if m.contains("fable") { return (nil, "不能用 Fable（使用者嚴禁）") }
        if ["sonnet", "opus", "haiku"].contains(m) || (m.hasPrefix("claude-") && m.range(of: #"^[a-z0-9.\-\[\]]+$"#, options: .regularExpression) != nil) { return (m, nil) }
        return (nil, "模型只接受 sonnet、opus、haiku，或 claude- 開頭的完整 id")
    }

    static func normalizeEffort(_ raw: String) -> (value: String?, error: String?) {
        let e = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["low", "medium", "high"].contains(e) ? (e, nil) : (nil, "--effort 只接受 low、medium、high")
    }

    /// codenv-todo model：改已存在聊天室的模型。權限同 rename（總指揮改底下的、任何聊天室改自己）；工作中的拒絕。
    /// 回傳 ok 時帶 id；pane 的套用由呼叫端（MainWindow）做
    func commanderSetModel(caller: String?, target: String, model rawModel: String, effort rawEffort: String?) -> [String: Any] {
        func fail(_ m: String) -> [String: Any] { ["ok": false, "error": m] }
        guard let me = callerInfo(caller) else { return fail("找不到你屬於哪個總指揮（要在 codenv 的聊天室裡跑）") }
        let nm = Store.normalizeModel(rawModel)
        guard let model = nm.value else { return fail(nm.error ?? "模型不對") }
        var effort: String?
        if let re = rawEffort, !re.isEmpty {
            let ne = Store.normalizeEffort(re)
            guard let e = ne.value else { return fail(ne.error ?? "強度不對") }
            effort = e
        }
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        var hit: Conversation?
        if t.isEmpty || t == "self" { hit = me.caller }
        else {
            let members = conversations(inCommander: me.session).filter { Store.isChat($0) }
            let byId = t.count >= 4 ? members.filter { $0.id.uuidString.lowercased().hasPrefix(t.lowercased()) } : []
            let byName = members.filter { $0.title == t }
            let pool = byId.count == 1 ? byId : byName
            if pool.count > 1 {
                let ids = pool.map { String($0.id.uuidString.prefix(8)).lowercased() }.joined(separator: "、")
                return fail("有 \(pool.count) 個聊天室都叫「\(t)」，請改用 id（\(ids)）")
            }
            hit = pool.first
        }
        guard let c = hit else { return fail("在你的總指揮底下找不到「\(t)」（codenv-todo team 看名單）") }
        if c.id != me.caller.id && !me.chief { return fail("只有總指揮能改別的聊天室的模型，你只能改自己的") }
        if let st = status[c.id], st == .working || st == .waiting {
            return fail("「\(c.title)」正在工作中，請等它閒下來再換（codenv-todo team 看狀態）")
        }
        return ["ok": true, "id": String(c.id.uuidString.prefix(8)).lowercased(), "name": c.title, "model": model, "effort": effort ?? "", "uuid": c.id.uuidString]
    }

    /// codenv-todo mcp：改聊天室下次啟動要載入的 MCP（full／lite／none，寫進 Conversation.mcp）。權限同 model（總指揮改底下的、任何聊天室改自己）。
    /// 工作中的也可以改，只是已經在跑的 claude 程序不會變，下次啟動才生效
    func commanderSetMcp(caller: String?, target: String, mode rawMode: String) -> [String: Any] {
        func fail(_ m: String) -> [String: Any] { ["ok": false, "error": m] }
        guard let me = callerInfo(caller) else { return fail("找不到你屬於哪個總指揮（要在 codenv 的聊天室裡跑）") }
        let nm = McpMode.normalize(rawMode)
        guard let mode = nm.value else { return fail(nm.error.map { $0.replacingOccurrences(of: "--mcp ", with: "") } ?? "要寫 full、lite 或 none") }
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        var hit: Conversation?
        if t.isEmpty || t == "self" { hit = me.caller }
        else {
            let members = conversations(inCommander: me.session).filter { Store.isChat($0) }
            let byId = t.count >= 4 ? members.filter { $0.id.uuidString.lowercased().hasPrefix(t.lowercased()) } : []
            let byName = members.filter { $0.title == t }
            let pool = byId.count == 1 ? byId : byName
            if pool.count > 1 {
                let ids = pool.map { String($0.id.uuidString.prefix(8)).lowercased() }.joined(separator: "、")
                return fail("有 \(pool.count) 個聊天室都叫「\(t)」，請改用 id（\(ids)）")
            }
            hit = pool.first
        }
        guard let c = hit else { return fail("在你的總指揮底下找不到「\(t)」（codenv-todo team 看名單）") }
        if c.id != me.caller.id && !me.chief { return fail("只有總指揮能改別的聊天室的 MCP，你只能改自己的") }
        setMcp(c.id, mode)
        let busy = status[c.id].map { $0 == .working || $0 == .waiting } ?? false
        return ["ok": true, "id": String(c.id.uuidString.prefix(8)).lowercased(), "name": c.title, "mcp": mode.rawValue, "working": busy]
    }

    /// 把模型寫進存檔（pane 沒載入時下次開就用這個）
    func storeModel(_ id: UUID, model: String, effort: String?) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[i].model = model
        if let effort { conversations[i].effort = effort }
        liveModel[id] = nil
    }

    /// 建一個聊天室放進呼叫者（要是總指揮聊天室）的總指揮底下，名字算總指揮取的；不擺進版面。回傳 ok 時帶 conversation
    func commanderCreate(caller: String?, name raw: String, dir: String?, project: String? = nil, model rawModel: String? = nil, effort rawEffort: String? = nil, mcp rawMcp: String? = nil, topic rawTopic: String? = nil, area rawArea: String? = nil) -> (reply: [String: Any], conversation: Conversation?) {
        func fail(_ m: String) -> ([String: Any], Conversation?) { (["ok": false, "error": m], nil) }
        guard let me = callerInfo(caller) else { return fail("找不到你屬於哪個總指揮（要在 codenv 的聊天室裡跑）") }
        guard me.chief else { return fail("只有總指揮聊天室能開新聊天室") }
        if (rawTopic?.trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0) > Store.topicLimit { return fail("說明太長（上限 \(Store.topicLimit) 字）") }
        let name = cleanName(raw)
        guard !name.isEmpty else { return fail("要給新聊天室取名字") }
        // 總指揮開的分支預設 Sonnet（不跟 Prefs.defaultModel）；Fable 一律拒絕
        let nm = Store.normalizeModel((rawModel?.isEmpty == false) ? rawModel! : "sonnet")
        guard let newModel = nm.value else { return fail(nm.error ?? "模型不對") }
        // 分支聊天室的 MCP 預設精簡（只留 deja）：每個聊天室各開一整套 MCP 程序很吃記憶體；要完整的加 --mcp full
        let nmcp = McpMode.normalize(rawMcp)
        if let e = nmcp.error { return fail(e) }
        let newMcp = nmcp.value ?? .lite
        var newEffort: String?
        if let re = rawEffort, !re.isEmpty {
            let ne = Store.normalizeEffort(re)
            guard let e = ne.value else { return fail(ne.error ?? "強度不對") }
            newEffort = e
        }
        if nameTaken(name, in: me.session, except: nil) { return fail("這個總指揮底下已經有叫「\(name)」的聊天室，換一個名字") }
        guard var g = groupOf(me.caller) else { return fail("找不到總指揮聊天室所在的組") }
        // 這次呼叫新建的資料夾與子群組：後面任何一步失敗都要全部回復，不留孤兒
        var madeGroup: UUID?, madeProject: UUID?
        func rollback() {
            if let m = madeProject { removeProject(m) }
            if let m = madeGroup { removeGroup(m) }
        }
        // multi：一定要指定子專案，放進那個子群組、資料夾預設用子專案的；single 忽略 --project
        var subFolder: String?
        // --area：直接指定區（multi 的子專案也是區）；有給就不再要求 --project
        let areaWant = rawArea?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !areaWant.isEmpty {
            let r = findArea(areaWant, in: me.session)
            guard let a = r.area else { return fail(r.error ?? "找不到區") }
            g = a.id
            if commanderIsMulti(me.session) { subFolder = folder(ofGroup: a.id) }
        } else if commanderIsMulti(me.session) {
            let subs = subProjects(me.session)
            let want = project?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let list = subs.map { "「\($0.name)」" }.joined(separator: "、")
            let usage = "用法：`codenv-todo new \"<名字>\" --project \"<子專案名>\"`；子專案還不存在時加 `--dir <資料夾>` 就會在這個總指揮底下新建。目前的子專案：\(list.isEmpty ? "（還沒有）" : list)"
            guard !want.isEmpty else { return fail("這個總指揮是多個子專案型，要用 --project 指定子專案。\(usage)") }
            let hits = subs.filter { $0.name == want }
            if hits.count > 1 { return fail("有 \(hits.count) 個子專案都叫「\(want)」，請先在 codenv 裡改成不同的名字") }
            if let sp = hits.first {
                g = sp.id
                subFolder = folder(ofGroup: sp.id)
            } else {
                // 子專案還不存在：有給 --dir 才建（子群組放在總指揮涵蓋的頂層組底下，資料夾設成這個子群組的預設資料夾）
                guard let d = dir?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty else { return fail("找不到子專案「\(want)」。\(usage)") }
                let path = ((d as NSString).expandingTildeInPath as NSString).standardizingPath
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return fail("資料夾不存在：\(path)") }
                let roots = me.session.groups ?? []
                let root = roots.first(where: { isGroup(g, within: $0) }) ?? roots.first ?? g
                let sgExisted = groups.contains { $0.name == want && $0.parentID == root }
                let sg = addGroup(named: want, parent: root)
                if !sgExisted { madeGroup = sg.id }
                let keepSel = selectedProject
                let pExisted = projects.contains { $0.path == path }
                let p = addProject(path: path)
                if !pExisted { madeProject = p.id }
                selectedProject = keepSel
                if let pi = projects.firstIndex(where: { $0.id == p.id }), projects[pi].groupID == nil { projects[pi].groupID = sg.id }
                g = sg.id
                subFolder = path
            }
        }
        let pid: UUID
        if let d = dir?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
            let path = ((d as NSString).expandingTildeInPath as NSString).standardizingPath
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { rollback(); return fail("資料夾不存在：\(path)") }
            if let ex = projects.first(where: { $0.path == path }) { pid = ex.id }
            else { let np = addProject(path: path); pid = np.id; if madeProject == nil { madeProject = np.id } }
        } else if let sf = subFolder {
            if let ex = projects.first(where: { $0.path == sf }) { pid = ex.id }
            else { let np = addProject(path: sf); pid = np.id; if madeProject == nil { madeProject = np.id } }
        } else { pid = me.caller.projectID }
        let keepSelected = selectedProject
        var c = createConversation(in: pid)
        selectedProject = keepSelected               // 新建不要順手改掉使用者目前選的資料夾
        move(c.id, toGroup: g)
        guard let i = conversations.firstIndex(where: { $0.id == c.id }) else { rollback(); return fail("建立失敗") }
        conversations[i].title = name
        conversations[i].renamed = true
        conversations[i].namedByCommander = true
        if let t = Store.cleanTopic(rawTopic ?? "") { conversations[i].topic = t; conversations[i].topicByCommander = true }
        conversations[i].model = newModel
        conversations[i].mcp = newMcp == .full ? nil : newMcp.rawValue
        conversations[i].effort = newEffort          // 不沿用 Prefs.defaultEffort（Sonnet 不一定支援）
        c = conversations[i]
        guard belongsToCommander(c, session: me.session) else {
            conversations.removeAll { $0.id == c.id }
            selectedProject = keepSelected
            rollback()          // 新建的資料夾與子群組也一併收掉
            return fail("新聊天室沒有落在你的總指揮底下（資料夾所在的組不對），已取消")
        }
        return (["ok": true, "name": name, "id": String(c.id.uuidString.prefix(8)).lowercased(), "model": newModel, "mcp": newMcp.rawValue], c)
    }
}

extension MainWindowController {
    /// codenv-todo new：建好之後在背景把 claude 開起來（wake），這樣 team 看得到、SendMessage 找得到
    func commanderNewChat(caller: String?, name: String, dir: String?, project: String? = nil, model: String? = nil, effort: String? = nil, mcp: String? = nil, topic: String? = nil, area: String? = nil, sandboxed: Bool = false, done: @escaping ([String: Any]) -> Void) {
        let r = store.commanderCreate(caller: caller, name: name, dir: dir, project: project, model: model, effort: effort, mcp: mcp, topic: topic, area: area)
        guard var c = r.conversation else { return done(r.reply) }
        // 沙盒聊天室開出來的聊天室一律也在沙盒裡（先設再 wake：喚醒時才會包 nono）
        if sandboxed, let i = store.conversations.firstIndex(where: { $0.id == c.id }) {
            store.conversations[i].sandbox = true
            c = store.conversations[i]
        }
        wake(name: c.title, caller: caller) { w in
            var out = r.reply
            if w["ok"] as? Bool != true { out["warn"] = "已建立，但喚醒失敗：" + String(describing: w["error"] ?? "不明原因") }
            else { out["pid"] = w["pid"] }
            done(out)
        }
    }
}

extension MainWindowController {
    /// codenv-todo model：驗過權限與狀態後，套到已載入的格子（set_model 讓在跑的程序下一則起換模型，對話接續不丟），沒載入的只改存檔
    func commanderSetModelChat(caller: String?, target: String, model: String, effort: String?, done: @escaping ([String: Any]) -> Void) {
        var r = store.commanderSetModel(caller: caller, target: target, model: model, effort: effort)
        guard r["ok"] as? Bool == true, let m = r["model"] as? String, let u = (r["uuid"] as? String).flatMap(UUID.init(uuidString:)) else { return done(r) }
        let e = (r["effort"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        store.storeModel(u, model: m, effort: e)
        if let pane = workspace.panes[u] as? ChatPane {
            pane.applyModel(m)
            if let e { pane.applyEffort(e) }
        }
        r["uuid"] = nil
        done(r)
    }
}

extension MainWindowController {
    /// codenv-todo topic：改完存檔；正在跑的 Claude 下一則（使用者在 codenv 打的）訊息後面會補一行新說明，沒在跑的下次啟動用系統提示帶
    func commanderSetTopicChat(caller: String?, target: String, topic: String, done: @escaping ([String: Any]) -> Void) {
        var r = store.commanderSetTopic(caller: caller, target: target, topic: topic)
        r["uuid"] = nil
        done(r)
    }
}
