import Foundation

extension Store {
    /// 呼叫者（CODENV_CONVERSATION）→ 聊天室：空字串、短於 8 碼、或配到不只一段都當作找不到（空字串會配到第一段，短前綴可能配錯人）
    func conversation(callerPrefix raw: String?) -> Conversation? {
        guard let cv = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), cv.count >= 8 else { return nil }
        let hits = conversations.filter { $0.id.uuidString.lowercased().hasPrefix(cv) }
        return hits.count == 1 ? hits.first : nil
    }

    /// 建立指名引擎的分支；權限與專案歸屬仍由既有建立流程把關。
    func commanderCreateEngine(caller: String?, name: String, engine rawEngine: String, dir: String?, project: String?, model: String?, effort: String?, mcp: String?, topic: String?) -> (reply: [String: Any], conversation: Conversation?) {
        let engine = rawEngine.lowercased()
        guard ["claude", "codex", "copilot", "agy"].contains(engine) else { return (["ok": false, "error": "--engine 只接受 claude、codex、copilot、agy"], nil) }
        let raw = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.lowercased().contains("fable") { return (["ok": false, "error": "不能用 Fable（使用者嚴禁）"], nil) }
        if engine == "claude" {
            let r = commanderCreate(caller: caller, name: name, dir: dir, project: project, model: raw.isEmpty ? nil : raw, effort: effort, mcp: mcp, topic: topic)
            return (r.reply, r.conversation)
        }
        if mcp != nil && !mcp!.isEmpty { return (["ok": false, "error": "非 Claude 引擎不支援 --mcp"], nil) }
        if engine == "codex" && !CodexBridge.installed { return (["ok": false, "error": "找不到 codex，請先安裝 Codex CLI"], nil) }
        if engine == "copilot" && !CopilotBridge.installed { return (["ok": false, "error": "找不到 copilot，請先安裝 Copilot CLI"], nil) }
        if engine == "agy" && !AgyBridge.enabled { return (["ok": false, "error": "agy 尚未啟用，請先在設定完成啟用"], nil) }
        let proposed = raw.isEmpty ? (engine == "codex" ? "gpt-6-luna" : engine == "agy" ? "gemini-3.8-flash-high" : "auto") : raw
        var id = proposed
        if id.hasPrefix(engine + ":") { id = String(id.dropFirst(engine.count + 1)) }
        let allowed = engine == "codex" ? CodexBridge.models.map(\.id) : engine == "copilot" ? CopilotBridge.models.map(\.id) : AgyBridge.models.map(\.id)
        guard allowed.contains(id) else { return (["ok": false, "error": "\(engine) 的 --model 必須是：\(allowed.joined(separator: "、"))"], nil) }
        var storedID = id
        if engine == "agy", let e = effort, !e.isEmpty {
            let clean = e.lowercased()
            guard AgyBridge.levels.contains(clean) else { return (["ok": false, "error": "--effort 只接受 \(AgyBridge.levels.joined(separator: "、"))"], nil) }
            storedID = AgyBridge.resolve(id, effort: clean)
        } else if let e = effort, !e.isEmpty {
            let levels = engine == "codex" ? CodexBridge.levels : CopilotBridge.levels
            guard levels.contains(e.lowercased()) else { return (["ok": false, "error": "--effort 只接受 \(levels.joined(separator: "、"))"], nil) }
        }
        let r = commanderCreate(caller: caller, name: name, dir: dir, project: project, model: "sonnet", effort: nil, mcp: "lite", topic: topic)
        guard let c = r.conversation, let i = conversations.firstIndex(where: { $0.id == c.id }) else { return r }
        conversations[i].model = "\(engine):\(storedID)"
        conversations[i].mcp = "none"
        conversations[i].effort = engine == "agy" || (effort ?? "").isEmpty ? nil : effort?.lowercased()
        let updated = conversations[i]
        return (["ok": true, "name": updated.title, "id": String(updated.id.uuidString.prefix(8)).lowercased(), "model": storedID, "engine": engine], updated)
    }
}

extension MainWindowController {
    /// 新增非 Claude 格子但不啟動程序。
    func commanderNewEngineChat(caller: String?, name: String, engine: String, dir: String?, project: String?, model: String?, effort: String?, topic: String?, done: @escaping ([String: Any]) -> Void) {
        if engine.lowercased() == "claude" {
            return commanderNewChat(caller: caller, name: name, dir: dir, project: project, model: model, effort: effort, mcp: nil, topic: topic, done: done)
        }
        let result = store.commanderCreateEngine(caller: caller, name: name, engine: engine, dir: dir, project: project, model: model, effort: effort, mcp: nil, topic: topic)
        guard let c = result.conversation else { return done(result.reply) }
        _ = workspace.pane(for: c)
        done(result.reply)
    }

    /// 解析 send／last 目標並套用與改名相同的總指揮權限。
    private func commanderEngineTarget(caller: String?, target: String) -> (Conversation?, String?, String?) {
        guard let me = store.conversation(callerPrefix: caller), let commander = store.commander(of: me.id) else { return (nil, nil, "找不到你屬於哪個總指揮") }
        let key = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let members = store.conversations(inCommander: commander).filter { Store.isChat($0) }
        let byID = key.count >= 4 ? members.filter { $0.id.uuidString.lowercased().hasPrefix(key.lowercased()) } : []
        let hits = key.isEmpty || key == "self" ? [me] : (byID.count == 1 ? byID : members.filter { $0.title == key })
        guard hits.count == 1, let c = hits.first else {
            let ids = hits.map { String($0.id.uuidString.prefix(8)).lowercased() }.joined(separator: "、")
            return (nil, nil, hits.count > 1 ? "有多個聊天室符合「\(key)」，請用 id（\(ids)）" : "在你的總指揮底下找不到「\(key)」")
        }
        if c.id != me.id && commander.chief != me.id { return (nil, nil, "只有總指揮能送給別的聊天室；你只能送 self") }
        guard !store.isArchived(c) else { return (nil, nil, "「\(c.title)」已封存") }
        if c.model == nil || !c.model!.contains(":") { return (nil, nil, "這是 Claude 聊天室，請用 SendMessage 傳訊息") }
        return (c, commander.name, nil)
    }

    /// 對非 Claude 聊天室送訊息，可非同步等待回答。
    func commanderSendChat(caller: String?, target: String, text: String, wait: Bool, timeout: TimeInterval, done: @escaping ([String: Any]) -> Void) {
        let (c, commanderName, error) = commanderEngineTarget(caller: caller, target: target)
        guard let c, let commanderName else { return done(["ok": false, "error": error ?? "目標無效"]) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return done(["ok": false, "error": "訊息不能是空的"]) }
        guard let pane = workspace.pane(for: c) as? ChatPane else { return done(["ok": false, "error": "開不出這格"]) }
        let engine = String((c.model ?? "").prefix(while: { $0 != ":" }))
        let id = String(c.id.uuidString.prefix(8)).lowercased()
        let message = QuoteText.neutralize("〔來自總指揮「\(commanderName)」〕\n\(text)")
        workspace.woken.insert(c.id)       // 不在版面上的格子不要在回答到一半被 releaseUnplaced 收掉（程序還在跑就留著，閒置 15 分才由 releaseBackgroundIdle 收）
        guard pane.sendText(message) else {
            workspace.woken.remove(c.id)
            return done(["ok": false, "error": "訊息送不出去，聊天室目前無法接收"])
        }
        let base: [String: Any] = ["ok": true, "id": id, "name": c.title, "engine": engine, "sent": true]
        guard wait else { return done(base) }
        let deadline = Date().addingTimeInterval(max(1, min(1800, timeout)))
        let beforeSend = store.status[c.id] ?? .idle
        var sawWorking = false
        let started = Date()
        let existingReply = pane.session.transcriptURL.flatMap { Transcripts.turns($0, model: c.model ?? "").last(where: { !$0.user })?.text }
        func poll() {
            let state = store.status[c.id] ?? .idle
            if state == .working { sawWorking = true }
            if state == .waiting { var out = base; out["waiting"] = true; out["note"] = "聊天室正在等權限或選擇題回覆"; return done(out) }
            if state == .idle && (sawWorking || (beforeSend != .working && Date().timeIntervalSince(started) >= 3)) {
                var out = base
                if let url = pane.session.transcriptURL, let turn = Transcripts.turns(url, model: c.model ?? "").last(where: { !$0.user }), turn.text != existingReply { out["reply"] = turn.text }
                return done(out)
            }
            if Date() >= deadline {
                var out: [String: Any] = ["ok": false, "error": "逾時", "id": id, "name": c.title, "engine": engine]
                if let url = pane.session.transcriptURL, let turn = Transcripts.turns(url, model: c.model ?? "").last(where: { !$0.user }) { out["partial"] = turn.text }
                return done(out)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll)
    }

    /// 回傳最後一則非使用者回答及目前狀態。
    func commanderLastChat(caller: String?, target: String) -> [String: Any] {
        let (c, _, error) = commanderEngineTarget(caller: caller, target: target)
        guard let c else { return ["ok": false, "error": error ?? "目標無效"] }
        let pane = workspace.panes[c.id] as? ChatPane
        let state = store.status[c.id] == .working ? "工作中" : store.status[c.id] == .waiting ? "等你回答" : pane?.session.isRunning == true ? "待命" : "休眠"
        var out: [String: Any] = ["ok": true, "id": String(c.id.uuidString.prefix(8)).lowercased(), "name": c.title, "engine": String((c.model ?? "").prefix(while: { $0 != ":" })), "state": state]
        // 格子被收掉（閒置、不在版面上）時直接讀橋接的紀錄檔，不需要載入格子
        let url = pane?.session.transcriptURL ?? Self.engineTranscript(c)
        if let url, let turn = Transcripts.turns(url, model: c.model ?? "").last(where: { !$0.user }) { out["reply"] = turn.text }
        return out
    }

    private static func engineTranscript(_ c: Conversation) -> URL? {
        switch (c.model ?? "").prefix(while: { $0 != ":" }) {
        case "codex": return CodexBridge.transcript(for: c.claudeSession)
        case "copilot": return CopilotBridge.transcript(for: c.claudeSession)
        case "agy": return AgyBridge.transcript(for: c.claudeSession)
        default: return nil
        }
    }
}
