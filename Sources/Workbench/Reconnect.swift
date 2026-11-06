import AppKit

// 打開 App（包括 ⌘ Q 之後再開）時，把版面裡每一格聊天的 Claude 先開起來，不送訊息。
// 原本要等那格送出第一則才開 claude，沒開的格子別的聊天室就聯絡不到（ListAgents 看不到）。
// claude 用聊天室的名字開（ChatSession.nameProvider → --name），重開後名字不變。

extension MainWindowController {
    func reconnectPlaced() {
        guard Prefs.shared.reconnectOnLaunch else { return }
        var ids: [UUID] = []
        for s in store.sessions { for w in s.windows { for id in w.root?.leaves ?? [] where !ids.contains(id) { ids.append(id) } } }
        let convs = ids.compactMap { store.conversation($0) }.filter { $0.terminal != true && !$0.isBrowser && $0.draft != true && !store.isArchived($0) }
        // 一格隔一秒，不要同時開一堆 claude
        for (i, c) in convs.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 + Double(i)) { [weak self] in
                // 等的這幾秒裡可能被改了模型、封存、換成終端機：用現在的資料，不是啟動時抓的舊副本
                guard let self, let now = self.store.conversation(c.id), now.terminal != true, now.draft != true, !self.store.isArchived(now),
                      let p = self.workspace.pane(for: now) as? ChatPane else { return }
                p.warmStart(until: Date().addingTimeInterval(600))
            }
        }
    }
}

extension MainWindowController {
    /// codenv-todo wake <名字>：把那段聊天室的 claude 開起來（不送訊息），等到登錄檔（sessions/<pid>.json）出現、名字對了才回成功；最多等 20 秒。
    /// 不在版面上的也開，但不擺進版面（Workspace.woken 讓它不被 releaseUnplaced 收掉）；終端機、瀏覽器、草稿、封存的不開
    func wake(name raw: String, done: @escaping ([String: Any]) -> Void) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return done(["ok": false, "error": "要寫聊天室的名字（側欄上的名字）"]) }
        let hits = store.conversations.filter { $0.title == name && !$0.isGadget }
        guard !hits.isEmpty else { return done(["ok": false, "error": "找不到叫「\(name)」的聊天室（名字要跟側欄上一樣）"]) }
        guard hits.count == 1, let c = hits.first else {
            let ids = hits.map { String($0.id.uuidString.prefix(8)).lowercased() }.joined(separator: "、")
            return done(["ok": false, "error": "有 \(hits.count) 個聊天室都叫「\(name)」（\(ids)），先在 codenv 裡改成不同的名字再喚醒"])
        }
        guard Store.isChat(c) else { return done(["ok": false, "error": "「\(name)」是終端機、瀏覽器或草稿，不喚醒"]) }
        guard !store.isArchived(c) else { return done(["ok": false, "error": "「\(name)」已經封存，不喚醒"]) }
        guard let p = workspace.pane(for: c) as? ChatPane else { return done(["ok": false, "error": "開不出這格"]) }
        workspace.woken.insert(c.id)
        if let why = p.wakeStart() { workspace.woken.remove(c.id); return done(["ok": false, "error": why]) }
        let deadline = Date().addingTimeInterval(20)
        func poll() {
            if let r = ClaudeSessions.registration(of: c.claudeSession), r.pid == p.session.pid {
                return done(["ok": true, "name": r.name, "pid": Int(r.pid), "placed": store.locate(c.id) != nil])
            }
            if !p.session.isRunning {   // 程序開了馬上又結束：不用等到逾時
                workspace.woken.remove(c.id)
                return done(["ok": false, "error": "claude 程序開了又結束了，原因看 codenv 那格的紀錄"])
            }
            if Date() > deadline {
                let alive = p.session.isRunning
                if !alive || store.locate(c.id) == nil { workspace.woken.remove(c.id) }   // 逾時：不在版面上的別一直標著「喚醒中」，不然 releaseUnplaced 永遠不收
                return done(["ok": false, "error": alive ? "claude 程序開了（\(p.session.pid.map(String.init) ?? "?")），但 20 秒內登錄檔（sessions/<pid>.json）沒出現，ListAgents 可能還找不到" : "claude 程序開了又結束了，原因看 codenv 那格的紀錄"])
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { poll() }
        }
        poll()
    }
}

extension ChatPane {
    /// 先把 claude 開起來（接回原本的對話），不送訊息。沒有紀錄檔的（還沒聊過）、本機模型的不開。
    /// 正在別處跑的（claude 的執行登記查得到）不開；只看「紀錄檔 3 分鐘內被寫過」那條不算：⌘ Q 馬上重開時，寫的人就是剛結束的自己。
    /// until：舊的 claude 還活著（例如 App 被砍時它正在做一輪事，要做完才會結束）就每 3 秒再看一次，等它結束再開，直到這個時間為止；
    /// 以前只看一次，剛好撞到舊的還沒走就永遠不開，要等使用者在那格打一句話才會重新出現在 ListAgents
    func warmStart(until deadline: Date? = nil) {
        // 不是 Claude 的聊天室（本機大模型會把模型載進記憶體）不預先開；跟 wakeStart 同一套判斷
        guard !session.isRunning, session.forkFrom == nil, session.localEndpoint == nil,
              session.agyModel == nil, session.codexModel == nil, session.copilotModel == nil, session.mlxModel == nil, session.appleModel == nil,
              Store.claudeHasSession(session.claudeSession, path: session.directory) else { return }
        if let l = liveElsewhere(), l.kind != "recent" {
            if let deadline, Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.warmStart(until: deadline) }
            }
            return
        }
        session.start()
        ownSessionStarted()
    }

    /// 喚醒（codenv-todo wake）：只把這段的 claude 程序開起來，不送任何訊息、不改模型和權限模式。
    /// 回傳 nil＝開了或本來就在跑；不然是原因。沒有紀錄檔（還沒聊過）的也開（用這段的編號開新的，不花模型回合）
    func wakeStart() -> String? {
        let s = session
        if s.agyModel != nil || s.codexModel != nil || s.copilotModel != nil || s.mlxModel != nil || s.appleModel != nil || s.localEndpoint != nil {
            return L("這段用的不是 Claude，沒有 Claude 程序可以喚醒")
        }
        if s.isRunning { return nil }
        if s.forkFrom != nil { return L("這段對話正在等「接手」複製，先在 codenv 裡處理") }
        if let l = liveElsewhere(), l.kind != "recent" { return L("這段對話正在別處進行（程序 \(l.pid)），不重複開") }
        guard s.start() else { return L("claude 開不起來（看 codenv 那格的錯誤訊息）") }
        ownSessionStarted()
        return nil
    }
}

extension MainWindowController {
    /// codenv-todo show <目標編號>：打開右邊協作看板、切到目標分頁、展開那個目標並捲過去（Hub 的「到 codenv 處理」用）。
    /// 編號可以只寫開頭幾碼；activate＝把 codenv 視窗叫到前面（使用者在 Hub 按按鈕時要；測試時關掉不搶焦點）
    func showGoal(_ raw: String, activate: Bool, done: @escaping ([String: Any]) -> Void) {
        let want = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !want.isEmpty else { return done(["ok": false, "error": "要寫目標編號（codenv-todo goal ls 看）"]) }
        let goals = CollabBoardModel.loadTodos().1
        let exact = goals.filter { $0.id.lowercased() == want }
        let hits = exact.count == 1 ? exact : goals.filter { $0.id.lowercased().hasPrefix(want) }
        guard !hits.isEmpty else { return done(["ok": false, "error": "找不到目標 \(want)（codenv-todo goal ls 看編號）"]) }
        guard hits.count == 1, let g = hits.first else { return done(["ok": false, "error": "有 \(hits.count) 個目標的編號開頭是 \(want)，多寫幾碼"]) }
        guard ["proposed", "active", "done"].contains(g.status) else { return done(["ok": false, "error": "目標 \(g.id) 的狀態是 \(g.status)，看板上不顯示"]) }
        let m = CollabBoardModel.shared
        m.tab = "goals"
        if m.collapsed.contains(g.id) { m.toggleCollapsed(g.id) }
        m.open = true
        if activate {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        // 看板停在「往來」「發現」時，目標清單不在畫面上、捲不過去，藍框也收不掉：先切回「目標」（agy Argon 11/6）
        m.tab = "goals"
        m.refresh()
        // 等看板畫出來（剛打開時、或剛切分頁時目標卡片還不在）再捲
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            m.focusGoal = nil
            m.focusGoal = g.id
            done(["ok": true, "goal": g.id, "title": g.title, "status": g.status])
        }
    }
}
