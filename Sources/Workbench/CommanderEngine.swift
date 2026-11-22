import Foundation

extension Store {
    /// 呼叫者（CODENV_CONVERSATION）→ 聊天室：空字串、短於 8 碼、或配到不只一段都當作找不到（空字串會配到第一段，短前綴可能配錯人）
    func conversation(callerPrefix raw: String?) -> Conversation? {
        guard let cv = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), cv.count >= 8 else { return nil }
        let hits = conversations.filter { $0.id.uuidString.lowercased().hasPrefix(cv) }
        return hits.count == 1 ? hits.first : nil
    }

    /// 建立指名引擎的分支；權限與專案歸屬仍由既有建立流程把關。
    func commanderCreateEngine(caller: String?, name: String, engine rawEngine: String, dir: String?, project: String?, model: String?, effort: String?, mcp: String?, topic: String?, area: String? = nil, worktree: String? = nil) -> (reply: [String: Any], conversation: Conversation?) {
        let engine = rawEngine.lowercased()
        guard ["claude", "codex", "copilot", "agy"].contains(engine) else { return (["ok": false, "error": "--engine 只接受 claude、codex、copilot、agy"], nil) }
        let raw = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.lowercased().contains("fable") { return (["ok": false, "error": "不能用 Fable（使用者嚴禁）"], nil) }
        if engine == "claude" {
            let r = commanderCreate(caller: caller, name: name, dir: dir, project: project, model: raw.isEmpty ? nil : raw, effort: effort, mcp: mcp, topic: topic, area: area, worktree: worktree)
            return (r.reply, r.conversation)
        }
        if mcp != nil && !mcp!.isEmpty { return (["ok": false, "error": "非 Claude 引擎不支援 --mcp"], nil) }
        if engine == "codex" && !CodexBridge.installed { return (["ok": false, "error": "找不到 codex，請先安裝 Codex CLI"], nil) }
        if engine == "copilot" && !CopilotBridge.installed { return (["ok": false, "error": "找不到 copilot，請先安裝 Copilot CLI"], nil) }
        if engine == "agy" && !AgyBridge.enabled { return (["ok": false, "error": "agy 尚未啟用，請先在設定完成啟用"], nil) }
        let proposed = raw.isEmpty ? (engine == "codex" ? "gpt-6-luna" : engine == "agy" ? "gemini-4-hydrogen-high" : "auto") : raw
        var id = proposed
        if id.hasPrefix(engine + ":") { id = String(id.dropFirst(engine.count + 1)) }
        let allowed = engine == "codex" ? CodexBridge.models.map(\.id) : engine == "copilot" ? CopilotBridge.models.map(\.id) : AgyBridge.models.map(\.id)
        guard allowed.contains(id) else { return (["ok": false, "error": "\(engine) 的 --model 必須是：\(allowed.joined(separator: "、"))"], nil) }
        var storedID = id
        if engine == "agy", let e = effort, !e.isEmpty {
            let clean = e.lowercased()
            let levels = AgyBridge.levels(for: id)
            guard !levels.isEmpty else { return (["ok": false, "error": "這個 agy 模型沒有強度可調"], nil) }
            guard levels.contains(clean) else { return (["ok": false, "error": "--effort 只接受 \(levels.joined(separator: "、"))"], nil) }
            storedID = AgyBridge.resolve(id, effort: clean)
        } else if let e = effort, !e.isEmpty {
            let levels = engine == "codex" ? CodexBridge.levels(for: id) : CopilotBridge.levels
            guard !levels.isEmpty else { return (["ok": false, "error": "這個模型沒有強度可調"], nil) }
            guard levels.contains(e.lowercased()) else { return (["ok": false, "error": "--effort 只接受 \(levels.joined(separator: "、"))"], nil) }
        }
        let r = commanderCreate(caller: caller, name: name, dir: dir, project: project, model: "sonnet", effort: nil, mcp: "lite", topic: topic, area: area, worktree: worktree)
        guard let c = r.conversation, let i = conversations.firstIndex(where: { $0.id == c.id }) else { return r }
        conversations[i].model = "\(engine):\(storedID)"
        conversations[i].mcp = "none"
        conversations[i].effort = engine == "agy" || (effort ?? "").isEmpty ? nil : effort?.lowercased()
        let permission = Prefs.shared.commanderChatPermission
        conversations[i].permissionMode = permission
        let updated = conversations[i]
        if let commander = commander(of: updated.id) { EventLog.log("總指揮", "總指揮 \(commander.name) 開了 \(updated.title)，權限 \(permission ?? "default")（設定）") }
        var reply: [String: Any] = ["ok": true, "name": updated.title, "id": String(updated.id.uuidString.prefix(8)).lowercased(), "model": storedID, "engine": engine, "permissionMode": permission ?? "default"]
        if let path = updated.worktreePath { reply["worktreePath"] = path; reply["worktreeBranch"] = updated.worktreeBranch ?? "" }
        return (reply, updated)
    }
}

extension Store {
    /// 純暫存自測：非 Claude 的 --area 共用既有歸區規則，區長仍被限制在自己的區，未知區拒絕建立。
    static func runEngineAreaSelfTest(in dir: URL, out: String) -> Bool {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let st = Store(directory: dir)
        st.projects = []; st.conversations = []; st.sessions = []; st.groups = []; st.status = [:]

        let root = ConvGroup(name: "總指揮組")
        let agyArea = ConvGroup(name: "agy區", parentID: root.id)
        let codexArea = ConvGroup(name: "codex區", parentID: root.id)
        let leadArea = ConvGroup(name: "區長區", parentID: root.id)
        st.groups = [root, agyArea, codexArea, leadArea]
        let project = Project(name: "測試專案", path: "/tmp", groupID: root.id)
        st.projects = [project]
        var chief = Conversation(projectID: project.id, title: "總指揮")
        chief.groupID = root.id
        let lead = Conversation(projectID: project.id, title: "區長")
        var leadGroup = leadArea
        leadGroup.areaLeadID = lead.id
        if let i = st.groups.firstIndex(where: { $0.id == leadArea.id }) { st.groups[i] = leadGroup }
        var leadConversation = lead
        leadConversation.groupID = leadArea.id
        st.conversations = [chief, leadConversation]
        st.sessions = [SessionLayout(name: "測試總指揮", windows: [], groups: [root.id], chief: chief.id)]

        func createBaseChat(caller: Conversation, name: String, engine: String, area: String?) -> Bool {
            let result = st.commanderCreate(caller: caller.id.uuidString, name: name, dir: nil, area: area)
            guard result.reply["ok"] as? Bool == true, let created = result.conversation,
                  let index = st.conversations.firstIndex(where: { $0.id == created.id }) else { return false }
            // 與 commanderCreateEngine 完成基本建構後寫入引擎欄位的順序相同；此自測不依賴 CLI 安裝或網路。
            st.conversations[index].model = "\(engine):test-model"
            return true
        }

        let agyCreated = createBaseChat(caller: chief, name: "agy分支", engine: "agy", area: agyArea.name)
        let agyPlaced = st.conversations.first(where: { $0.title == "agy分支" }).map { st.groupOf($0) == agyArea.id } ?? false
        let codexCreated = createBaseChat(caller: chief, name: "codex分支", engine: "codex", area: codexArea.name)
        let codexPlaced = st.conversations.first(where: { $0.title == "codex分支" }).map { st.groupOf($0) == codexArea.id } ?? false
        let leadCreated = createBaseChat(caller: leadConversation, name: "區長codex", engine: "codex", area: "不存在的區")
        let leadPlaced = st.conversations.first(where: { $0.title == "區長codex" }).map { st.groupOf($0) == leadArea.id } ?? false
        let beforeUnknown = st.conversations.count
        let unknown = st.commanderCreate(caller: chief.id.uuidString, name: "錯誤區聊天室", dir: nil, area: "不存在的區")
        let unknownRejected = unknown.reply["ok"] as? Bool == false && unknown.conversation == nil && st.conversations.count == beforeUnknown

        let values: [(String, Bool)] = [
            ("agy_engine_area_placed", agyCreated && agyPlaced),
            ("codex_engine_area_placed", codexCreated && codexPlaced),
            ("area_lead_codex_forced_to_own_area", leadCreated && leadPlaced),
            ("unknown_area_rejected_without_creating", unknownRejected)
        ]
        let text = values.map { "\($0.0)=\($0.1)" }.joined(separator: "\n") + "\n"
        try? text.write(toFile: out, atomically: true, encoding: .utf8)
        return values.allSatisfy(\.1)
    }
}

extension MainWindowController {
    /// 新增非 Claude 格子但不啟動程序。
    func commanderNewEngineChat(caller: String?, name: String, engine: String, dir: String?, project: String?, model: String?, effort: String?, topic: String?, area: String? = nil, worktree: String? = nil, done: @escaping ([String: Any]) -> Void) {
        if engine.lowercased() == "claude" {
            return commanderNewChat(caller: caller, name: name, dir: dir, project: project, model: model, effort: effort, mcp: nil, topic: topic, area: area, worktree: worktree, done: done)
        }
        let result = store.commanderCreateEngine(caller: caller, name: name, engine: engine, dir: dir, project: project, model: model, effort: effort, mcp: nil, topic: topic, area: area, worktree: worktree)
        guard let c = result.conversation else { return done(result.reply) }
        _ = workspace.pane(for: c)
        done(result.reply)
    }

    /// 解析 send／last 目標並套用與改名相同的總指揮權限。
    private func commanderEngineTarget(caller: String?, target: String, allowClaude: Bool = false, allowAreaLeadReport: Bool = false, allowArchived: Bool = false) -> (Conversation?, String?, String?) {
        let callerConversation = store.conversation(callerPrefix: caller)
        if let lead = store.areaLeadContext(caller: caller) {
            if allowAreaLeadReport,
               let reporter = callerConversation,
               let parentLead = store.reportingAreaLead(for: reporter, in: lead.session),
               Self.matchesCommanderTarget(target, conversation: parentLead.lead) {
                return (parentLead.lead, lead.session.name, nil)
            }
            let (c, error) = store.areaLeadTarget(target, context: lead, allowArchived: allowArchived)
            guard let c else { return (nil, nil, error ?? "目標不在區長管理範圍內") }
            return (c, "\(store.areaPath(lead.area.id, in: lead.session))區長「\(lead.caller.title)」", nil)
        }
        guard let me = callerConversation, let commander = store.commander(of: me.id) else { return (nil, nil, "找不到你屬於哪個總指揮") }
        if allowAreaLeadReport, commander.chief != me.id,
           let lead = store.reportingAreaLead(for: me, in: commander), Self.matchesCommanderTarget(target, conversation: lead.lead) {
            return (lead.lead, commander.name, nil)
        }
        let key = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let members = store.conversations(inCommander: commander).filter { Store.isChat($0) }
        let byID = key.count >= 4 ? members.filter { $0.id.uuidString.lowercased().hasPrefix(key.lowercased()) } : []
        let hits = key.isEmpty || key == "self" ? [me] : (byID.count == 1 ? byID : members.filter { $0.title == key })
        guard hits.count == 1, let c = hits.first else {
            let ids = hits.map { String($0.id.uuidString.prefix(8)).lowercased() }.joined(separator: "、")
            return (nil, nil, hits.count > 1 ? "有多個聊天室符合「\(key)」，請用 id（\(ids)）" : "在你的總指揮底下找不到「\(key)」")
        }
        if c.id != me.id && commander.chief != me.id { return (nil, nil, "只有總指揮能送給別的聊天室；你只能送 self") }
        guard allowArchived || !store.isArchived(c) else { return (nil, nil, "「\(c.title)」已封存") }
        if !allowClaude && (c.model == nil || !c.model!.contains(":")) { return (nil, nil, "這是 Claude 聊天室，請用 SendMessage 傳訊息") }
        return (c, commander.name, nil)
    }

    private static func matchesCommanderTarget(_ raw: String, conversation: Conversation) -> Bool {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !key.isEmpty && (conversation.title.lowercased() == key ||
            (key.count >= 4 && conversation.id.uuidString.lowercased().hasPrefix(key)))
    }

    /// 只讓總指揮停止自己 team 中正在工作的聊天室，沿用各引擎的中斷入口。
    func commanderStopChat(caller: String?, target: String) -> [String: Any] {
        let (c, _, error) = commanderEngineTarget(caller: caller, target: target, allowClaude: true, allowArchived: true)
        guard let c else { return ["ok": false, "error": error ?? "目標無效"] }
        if store.areaLeadTargetsSelf(caller: caller, target: c) {
            return ["ok": false, "error": "區長不能停止自己"]
        }
        guard let me = store.conversation(callerPrefix: caller),
              (store.commander(of: me.id)?.chief == me.id || store.areaLeadContext(caller: caller) != nil) else {
            return ["ok": false, "error": "只有總指揮或區長能停止自己管理範圍內的聊天室"]
        }
        guard store.status[c.id] == .working else {
            return ["ok": false, "error": "「\(c.title)」沒在工作"]
        }
        if store.areaLeadContext(caller: caller) != nil {
            let decision = CommanderStuck.shared.areaLeadInterruptDecision(c.id)
            guard decision.accepted else {
                return ["ok": false, "error": decision.message, "reason": decision.reason]
            }
        }
        if let pane = workspace.panes[c.id] as? ChatPane {
            commanderInterrupt(pane)
            if !pane.session.isRunning, store.status[c.id] == .working {
                store.status[c.id] = nil
            }
        } else {
            store.status[c.id] = nil
        }
        EventLog.log("總指揮", "總指揮 \(store.commander(of: c.id)?.name ?? "?") 停止了 \(c.title)")
        return ["ok": true, "id": String(c.id.uuidString.prefix(8)).lowercased(), "name": c.title, "stopped": true]
    }

    /// 預檢本 team 已登記的 worktree 分支；不執行 merge，也不碰任何工作目錄或 index。
    func commanderMergeCheck(caller: String?, branch rawBranch: String, base rawBase: String) -> [String: Any] {
        guard let callerConversation = store.conversation(callerPrefix: caller),
              let team = store.commander(of: callerConversation.id) else {
            return ["ok": false, "error": "找不到你屬於哪個總指揮"]
        }
        let branch = rawBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = rawBase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "main" : rawBase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else { return ["ok": false, "error": "請指定 worktree 分支"] }
        let matches = store.conversations(inCommander: team).filter { $0.worktreeBranch == branch && $0.worktreePath != nil }
        guard matches.count == 1, let conversation = matches.first, let path = conversation.worktreePath else {
            return ["ok": false, "error": matches.isEmpty ? "你的總指揮底下找不到 worktree 分支「\(branch)」" : "有多個聊天室使用「\(branch)」，請先整理重複分支"]
        }
        do {
            switch try CommanderWorktree.check(worktreePath: path, branch: branch, base: base) {
            case .clean:
                return ["ok": true, "state": "clean", "exitCode": 0, "branch": branch, "base": base]
            case .uncommitted(let changes):
                return ["ok": true, "state": "uncommitted", "exitCode": 2, "branch": branch, "base": base, "changes": changes]
            case .conflicts(let files):
                return ["ok": true, "state": "conflicts", "exitCode": 1, "branch": branch, "base": base, "files": files]
            }
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }

    /// 對非 Claude 聊天室送訊息，可非同步等待回答。
    func commanderSendChat(caller: String?, target: String, text: String, wait: Bool, timeout: TimeInterval, interrupt: Bool = false, steer: Bool = false, allowClaudeAfterInterrupt: Bool = false, worktree: String? = nil, supervisedRetry: Bool = false, done: @escaping ([String: Any]) -> Void) {
        guard !(interrupt && steer) else { return done(["ok": false, "error": "--steer 與 --interrupt 不能同時使用"]) }
        let (c, commanderName, error) = commanderEngineTarget(caller: caller, target: target,
                                                               allowClaude: interrupt || steer || worktree != nil || allowClaudeAfterInterrupt,
                                                               allowAreaLeadReport: true)
        guard let c, let commanderName else { return done(["ok": false, "error": error ?? "目標無效"]) }
        if worktree != nil {
            do { try CommanderWorktree.validate(engine: c.modelCategory, isNewChat: false) }
            catch { return done(["ok": false, "error": error.localizedDescription]) }
        }
        if interrupt && store.areaLeadTargetsSelf(caller: caller, target: c) {
            return done(["ok": false, "error": "區長不能用 --interrupt 中斷自己"])
        }
        if interrupt, let sender = store.conversation(callerPrefix: caller),
           let session = store.commander(of: sender.id),
           store.reportingAreaLead(for: sender, in: session)?.lead.id == c.id {
            return done(["ok": false, "error": "施工聊天室回報區長不能帶 --interrupt"])
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return done(["ok": false, "error": "訊息不能是空的"]) }
        if interrupt {
            guard let pane = workspace.pane(for: c) as? ChatPane else { return done(["ok": false, "error": "開不出這格"]) }
            guard let me = store.conversation(callerPrefix: caller),
                  (store.commander(of: me.id)?.chief == me.id || store.areaLeadContext(caller: caller) != nil) else { return done(["ok": false, "error": "只有總指揮或區長能在管理範圍內使用 --interrupt"] ) }
            guard store.status[c.id] == .working else { return done(["ok": false, "error": "「\(c.title)」沒在工作，沒有中斷或送出"] ) }
            if store.areaLeadContext(caller: caller) != nil {
                let decision = CommanderStuck.shared.areaLeadInterruptDecision(c.id)
                guard decision.accepted else {
                    return done(["ok": false, "error": decision.message, "reason": decision.reason])
                }
            }
            commanderInterrupt(pane)
            let deadline = Date().addingTimeInterval(15)
            func waitUntilStopped() {
                if store.status[c.id] != .working {
                    commanderSendChat(caller: caller, target: target, text: text, wait: wait, timeout: timeout, interrupt: false, allowClaudeAfterInterrupt: true, worktree: worktree, done: done)
                } else if Date() >= deadline { done(["ok": false, "error": "中斷後 15 秒仍未確認停止，沒有送出新訊息"] ) }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: waitUntilStopped) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: waitUntilStopped)
            return
        }
        var worktreeAssignment: CommanderWorktree.Assignment?
        if let branch = worktree {
            let cached = workspace.panes[c.id] as? ChatPane
            let sameWorktree = c.worktreeBranch == branch && c.worktreePath != nil
            if !sameWorktree {
                guard store.status[c.id] != .working && store.status[c.id] != .waiting else {
                    return done(["ok": false, "error": "聊天室正在工作；請等這輪結束後再切換 worktree"])
                }
                if let cached, cached.session.hasUnacknowledgedInput || cached.inputBar.hasPendingInput || cached.isBangRunning || cached.codeLab?.hasUnsaved == true {
                    return done(["ok": false, "error": "聊天室有尚未送出的訊息或未存的修改，請先處理再切換 worktree"])
                }
            }
            guard let repoDirectory = store.project(c.projectID)?.path else {
                return done(["ok": false, "error": "找不到聊天室所屬專案，無法建立 worktree"])
            }
            do { worktreeAssignment = try CommanderWorktree.assign(repoDirectory: repoDirectory, branch: branch, engine: c.modelCategory, isNewChat: false) }
            catch { return done(["ok": false, "error": error.localizedDescription]) }
            if !sameWorktree {
                if cached != nil { workspace.close(c.id) }
                guard let i = store.conversations.firstIndex(where: { $0.id == c.id }) else {
                    return done(["ok": false, "error": "找不到聊天室，worktree 已建立但沒有變更對話設定"])
                }
                store.conversations[i].worktreePath = worktreeAssignment?.path
                store.conversations[i].worktreeBranch = worktreeAssignment?.branch
            }
        }
        guard let current = store.conversation(c.id), let pane = workspace.pane(for: current) as? ChatPane else {
            return done(["ok": false, "error": "開不出這格"])
        }
        let modelEngine = String((c.model ?? "").prefix(while: { $0 != ":" }))
        let engine = modelEngine.isEmpty ? c.modelCategory : modelEngine
        let id = String(c.id.uuidString.prefix(8)).lowercased()
        let sender = store.conversation(callerPrefix: caller)
        let header: String
        if let lead = store.areaLeadContext(caller: caller) {
            header = "〔來自「\(store.areaPath(lead.area.id, in: lead.session))」區長「\(lead.caller.title)」〕\n"
        } else if let sender, let session = store.commander(of: sender.id), session.chief != sender.id {
            header = "〔施工聊天室「\(sender.title)」回報〕\n"
        } else {
            header = "〔來自總指揮「\(commanderName)」〕\n"
        }
        let dispatchText = CommanderWorktree.dispatchText(text, worktreePath: worktreeAssignment?.path ?? current.worktreePath)
        let message = QuoteText.neutralize(header + dispatchText)
        workspace.woken.insert(c.id)       // 不在版面上的格子不要在回答到一半被 releaseUnplaced 收掉（程序還在跑就留著，閒置 15 分才由 releaseBackgroundIdle 收）
        let baselineFailure = pane.session.failureGeneration
        let baselineStop = pane.session.stopGeneration
        let beforeSend = store.status[c.id] ?? .idle
        let busy = beforeSend == .working || beforeSend == .waiting
        let supportsSteer = ["codex", "local"].contains(c.modelCategory)
        let steerNow = steer && beforeSend == .working && supportsSteer
        let messageID = UUID().uuidString.lowercased()
        let assignment = commanderDispatchAssigner(caller: sender, target: c)
        // 派工者身分與序號供監督與結果去重；通知開關只控制完成通知。
        let dispatch = !wait ? recordCommanderDispatch(target: c, assigner: assignment, messageID: messageID) : nil
        if let dispatch {
            CommanderStuck.shared.registerDispatch(target: c.id, messageID: messageID,
                                                    assignerID: dispatch.assignerID, text: dispatchText,
                                                    supervisedRetry: supervisedRetry)
        }
        let responseTimeout = max(1, min(1800, timeout))
        var deadline: Date?
        let existingReply = pane.session.transcriptURL.flatMap { Transcripts.turns($0, model: c.model ?? "").last(where: { !$0.user })?.text }
        var base: [String: Any] = ["ok": true, "id": id, "name": c.title, "engine": engine, "sent": true, "messageID": messageID]
        if let path = current.worktreePath { base["worktreePath"] = path; base["worktreeBranch"] = current.worktreeBranch ?? "" }
        var finished = false
        func finish(_ response: [String: Any]) {
            guard !finished else { return }
            finished = true
            AgyBridge.recordTestProbe(["event": "commander_result", "conversation": c.id.uuidString.lowercased(), "response": response])
            done(response)
        }
        func failure(_ fallback: String) -> [String: Any] {
            let currentFailure = pane.session.failureGeneration > baselineFailure ? pane.session.lastFailureMessage : nil
            var out: [String: Any] = ["ok": false, "error": currentFailure ?? fallback,
                                      "id": id, "name": c.title, "engine": engine]
            if let url = pane.session.transcriptURL,
               let turn = Transcripts.turns(url, model: c.model ?? "").last(where: { !$0.user }), turn.text != existingReply {
                out["partial"] = turn.text
            }
            return out
        }
        if !wait && busy {
            var response = base
            response["queued"] = true
            if steer {
                response["steered"] = steerNow
                response["note"] = steerNow ? "已送入不中斷插話，這輪工作會繼續" : "已排隊，這輪結束後送"
            } else {
                response["note"] = "訊息已排入聊天室佇列"
            }
            guard commanderDeliver(pane, message, messageID, steerNow, nil, nil, "來自「\(store.conversation(callerPrefix: caller)?.title ?? "總指揮")」") else {
                if dispatch != nil { removeCommanderDispatch(target: c, messageID: messageID) }
                workspace.woken.remove(c.id)
                return finish(failure("訊息送不出去，聊天室目前無法接收"))
            }
            return finish(response)
        }
        let deliveryTimeout: TimeInterval? = wait ? nil : 60
        let delivered: (Bool) -> Void = { acknowledged in
            guard !finished else { return }
            guard acknowledged else {
                if dispatch != nil { self.removeCommanderDispatch(target: c, messageID: messageID) }
                return finish(failure("引擎未確認讀入訊息；訊息可能仍在排隊，請用 codenv-todo last 確認狀態，不要重送"))
            }
            guard wait else { return finish(base) }
            // timeout 從 isReplay 回條確認目標已開始這則訊息時起算；排隊時間不扣除。
            deadline = Date().addingTimeInterval(responseTimeout)
            // isReplay 是目標已開始處理這則訊息的確認。快速完成時，第一次輪詢
            // 可能已看到 idle；仍應把它視為本次處理完成，而不是等到逾時。
            func poll() {
                guard !finished else { return }
                if pane.session.failureGeneration > baselineFailure {
                    return finish(failure(pane.session.lastFailureMessage ?? "引擎回報執行錯誤"))
                }
                if pane.session.stopGeneration > baselineStop {
                    var out = base
                    out["ok"] = false
                    out["stopped"] = true
                    out["error"] = L("已停止")
                    out["state"] = L("已停止")
                    return finish(out)
                }
                let state = self.store.status[c.id] ?? .idle
                if state == .waiting {
                    var out = base; out["waiting"] = true; out["note"] = "聊天室正在等權限或選擇題回覆"
                    return finish(out)
                }
                if state == .idle {
                    var out = base
                    if let url = pane.session.transcriptURL,
                       let turn = Transcripts.turns(url, model: c.model ?? "").last(where: { !$0.user }), turn.text != existingReply {
                        out["reply"] = turn.text
                    }
                    return finish(out)
                }
                if let deadline, Date() >= deadline { return finish(failure("逾時")) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: poll)
            }
            poll()
        }
        guard commanderDeliver(pane, message, messageID, false, deliveryTimeout, delivered, "來自「\(store.conversation(callerPrefix: caller)?.title ?? "總指揮")」") else {
            if dispatch != nil { removeCommanderDispatch(target: c, messageID: messageID) }
            workspace.woken.remove(c.id)
            return finish(failure("訊息送不出去，聊天室目前無法接收"))
        }
    }

    private func commanderDispatchAssigner(caller: Conversation?, target: Conversation) -> Conversation? {
        guard let caller, caller.id != target.id, caller.modelCategory == "claude",
              let session = store.commander(of: caller.id), !store.isArchived(caller) else { return nil }
        if session.chief == caller.id { return caller }
        guard let lead = store.areaLeadContext(caller: caller.id.uuidString),
              store.areaLeadMembers(lead).contains(where: { $0.id == target.id }) else { return nil }
        return caller
    }

    private func recordCommanderDispatch(target: Conversation, assigner: Conversation?, messageID: String) -> CommanderDispatch? {
        guard let assigner, let index = store.conversations.firstIndex(where: { $0.id == target.id }) else { return nil }
        let sequence = (store.conversations[index].commanderDispatchSequence ?? 0) + 1
        store.conversations[index].commanderDispatchSequence = sequence
        var rows = store.conversations[index].commanderDispatches ?? []
        let record = CommanderDispatch(messageID: messageID, assignerID: assigner.id, sequence: sequence)
        rows.append(record)
        store.conversations[index].commanderDispatches = rows
        _ = store.saveNow()
        return record
    }

    private func removeCommanderDispatch(target: Conversation, messageID: String) {
        guard let index = store.conversations.firstIndex(where: { $0.id == target.id }) else { return }
        store.conversations[index].commanderDispatches?.removeAll { $0.messageID == messageID }
        _ = store.saveNow()
    }

    /// ChatPane 以 replay 標記派工訊息已開始；只在該輪 result 後取走並通知，waiting 不會消耗派工。
    func commanderDispatchEvent(conversationID: UUID, messageID: String, event: [String: Any]) {
        guard let index = store.conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        let type = event["type"] as? String
        if type == "user", !messageID.isEmpty,
           let row = store.conversations[index].commanderDispatches?.firstIndex(where: { $0.messageID == messageID }) {
            store.conversations[index].commanderDispatches?[row].started = true
            _ = store.saveNow()
            return
        }
        guard type == "result" else { return }
        if CommanderStuck.shared.consumeAutomaticStopResult(conversationID) {
            store.conversations[index].commanderDispatches?.removeAll(where: \.started)
            _ = store.saveNow()
            return
        }
        if TerminalTurnTracker.isStopped(event) { return }
        let finished = (store.conversations[index].commanderDispatches ?? []).filter(\.started)
        guard !finished.isEmpty else { return }
        store.conversations[index].commanderDispatches?.removeAll(where: \.started)
        _ = store.saveNow() // 先標記已處理，重複 result 不會重複通知。
        guard Prefs.shared.commanderCompletionNotices,
              let worker = store.conversation(conversationID) else { return }
        let state = TerminalTurnTracker.completionLabel(event)
        let transcriptSummary = event["is_error"] as? Bool == true ? nil : (workspace.panes[conversationID] as? ChatPane)?.session.transcriptURL
            .flatMap { Transcripts.turns($0, model: worker.model ?? "").last(where: { !$0.user })?.text }
        let rawSummary: String
        if let transcriptSummary, !transcriptSummary.isEmpty { rawSummary = transcriptSummary }
        else if let value = event["result"] as? String { rawSummary = value }
        else if let value = event["result"] as? [String: Any] {
            rawSummary = (value["error"] as? String) ?? (value["message"] as? String) ?? (event["subtype"] as? String) ?? "本輪已結束"
        } else { rawSummary = (event["subtype"] as? String) ?? "本輪已結束" }
        let cleaned = KeyScan.redact(rawSummary, strongOnly: false).components(separatedBy: .newlines).joined(separator: " ")
        let summary = cleaned.count > 200 ? String(cleaned.prefix(200)) + "…" : cleaned
        let latestByAssigner = Dictionary(grouping: finished, by: \.assignerID).compactMap { _, records in
            records.max { $0.sequence < $1.sequence }
        }
        for record in latestByAssigner {
            guard let assigner = store.conversation(record.assignerID), Store.isChat(assigner),
                  assigner.modelCategory == "claude", !store.isArchived(assigner) else { continue }
            let notice = "〔施工完成通知・派工 #\(record.sequence)〕「\(worker.title)」\(state)。摘要：\(summary)"
            guard let pane = workspace.pane(for: assigner) as? ChatPane else { continue }
            workspace.woken.insert(assigner.id)
            let senderText = QuoteText.neutralize(notice)
            if !commanderDeliver(pane, senderText, nil, false, nil, nil, "施工完成") {
                workspace.woken.remove(assigner.id)
                EventLog.log("總指揮", "派工 #\(record.sequence) 完成通知送不進「\(assigner.title)」")
            } else {
                AgyBridge.recordTestProbe(["event": "dispatch_notice_sent", "conversation": conversationID.uuidString.lowercased(),
                                           "assigner": assigner.id.uuidString.lowercased(), "sequence": record.sequence,
                                           "status": state, "summary": summary])
            }
        }
    }

    /// 卡住監督使用和 07-1 完成通知相同的即時投遞通道，喚醒閒置區長／總指揮。
    @discardableResult
    func sendCommanderSupervisionNotice(to id: UUID, text: String) -> Bool {
        guard let conversation = store.conversation(id), Store.isChat(conversation),
              !store.isArchived(conversation), let pane = workspace.pane(for: conversation) as? ChatPane else { return false }
        workspace.woken.insert(id)
        if commanderDeliver(pane, QuoteText.neutralize(text), nil, false, nil, nil, "監督通知") { return true }
        workspace.woken.remove(id)
        return false
    }

    /// 回傳最後一則非使用者回答及目前狀態。
    func commanderLastChat(caller: String?, target: String) -> [String: Any] {
        let (c, _, error) = commanderEngineTarget(caller: caller, target: target)
        guard let c else { return ["ok": false, "error": error ?? "目標無效"] }
        let pane = workspace.panes[c.id] as? ChatPane
        let state = store.status[c.id] == .working ? "工作中" : store.status[c.id] == .waiting ? "等你回答"
            : pane?.session.lastFailureMessage != nil ? "錯誤" : pane?.session.isRunning == true ? "待命" : "休眠"
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
