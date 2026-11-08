import AppKit

/// 額度衝刺的執行端：開始時送說明、每 20 秒看一次有沒有重置、重置就通知收尾、沒交總結就自己從聊天室最後一則回覆擷取。
final class SprintRunner {
    unowned let host: MainWindowController
    private var timer: Timer?
    private let sprint = SprintStore.shared
    /// 通知後最久等總結多久（秒）；測試可用 CODENV_SPRINT_WIND_TIMEOUT 縮短
    private let windTimeout: TimeInterval = Double(ProcessInfo.processInfo.environment["CODENV_SPRINT_WIND_TIMEOUT"] ?? "") ?? 15 * 60
    /// 衝刺中聊天室閒置多久就提醒它接著做（秒），最多提醒幾次
    private let nudgeAfter: TimeInterval = Double(ProcessInfo.processInfo.environment["CODENV_SPRINT_NUDGE_AFTER"] ?? "") ?? 120
    private let maxNudges = 40
    private var idleSince: Date?
    private var sawWorkingAfterWind = false

    init(host: MainWindowController) {
        self.host = host
        sprint.startHandler = { [weak self] in self?.askAndStart() }
        sprint.stopHandler = { [weak self] in self?.beginWinding(reason: "manual") }
        // 上次 codenv 關掉時衝刺還在：重開後接著盯（重置時間已過就立刻收尾）
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.tick() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.tick() }
    }

    private var store: Store { host.store }
    private var chat: Conversation? { sprint.state.convID.flatMap(UUID.init(uuidString:)).flatMap { store.conversation($0) } }
    private func log(_ s: String) {
        guard CommandLine.arguments.contains("--state-dir") else { return }
        let url = SprintStore.fileURL.deletingLastPathComponent().appendingPathComponent("sprint.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() } else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }

    // MARK: 開始

    /// 能當衝刺對象的聊天室：各總指揮的總指揮聊天室（Claude）
    private func candidates() -> [Conversation] {
        store.sessions.filter { $0.area == nil && $0.chief != nil }.compactMap { s in s.chief.flatMap { store.conversation($0) } }
            .filter { !store.isArchived($0) && Store.isChat($0) }
    }

    private func askAndStart() {
        guard !sprint.isActive else { return }
        let list = candidates()
        guard !list.isEmpty else { return alert(L("找不到總指揮聊天室"), L("衝刺預設交給總指揮聊天室；目前沒有。可以用 codenv-todo sprint start \"<聊天室名字>\" 指定。")) }
        let a = NSAlert()
        a.messageText = L("開始額度衝刺？")
        let (label, target) = watchTarget()
        a.informativeText = L("選一個聊天室去規劃並執行會消耗額度的工作。額度（\(label)）重置時，codenv 會通知它收尾並總結。\n注意：衝刺期間它會持續用額度，也可能開其他聊天室幫忙。") + (target.map { L("\n預計重置：") + UsageMonitor.when($0) } ?? L("\n（查不到重置時間，改以 5 小時後當作結束）"))
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        pop.addItems(withTitles: list.map(\.title))
        a.accessoryView = pop
        a.addButton(withTitle: L("開始衝刺")); a.addButton(withTitle: L("取消"))
        let go: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard r == .alertFirstButtonReturn, pop.indexOfSelectedItem >= 0 else { return }
            _ = self?.start(chat: list[pop.indexOfSelectedItem])
        }
        if let w = host.window { a.beginSheetModal(for: w, completionHandler: go) } else { go(a.runModal()) }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.addButton(withTitle: L("好"))
        if let w = host.window { a.beginSheetModal(for: w) } else { a.runModal() }
    }

    /// 盯哪一格：Claude 的「5 小時」（衝刺的聊天室用的就是它）；沒有就挑重置最近的 5 小時；都沒有就 nil
    private func watchTarget() -> (label: String, at: Date?) {
        let m = UsageMonitor.shared
        if let b = m.buckets.first(where: { $0.label.contains("5") && $0.resetAt != nil }) { return (b.label, b.resetAt) }
        let others = (m.agyBuckets + m.codexBuckets).filter { $0.label.hasSuffix("5 小時") && $0.resetAt != nil }.sorted { $0.resetAt! < $1.resetAt! }
        if let b = others.first { return (b.label, b.resetAt) }
        return ("5 小時", nil)
    }

    /// 開始衝刺；回傳錯誤文字（nil＝成功）
    @discardableResult
    func start(chat c: Conversation) -> String? {
        guard !sprint.isActive else { return "已經有衝刺在進行中" }
        guard let pane = host.workspace.pane(for: c) as? ChatPane else { return "開不出這格" }
        let (label, at) = watchTarget()
        let target = at ?? Date().addingTimeInterval(5 * 3600)
        let used = UsageMonitor.shared.buckets.first(where: { $0.label == label })?.used ?? 0
        sprint.update {
            $0 = SprintState(phase: "running", convID: c.id.uuidString, convTitle: c.title, startedAt: Date(), watchLabel: label,
                             targetReset: target, baselineUsed: used, targetKnown: at != nil)
        }
        host.workspace.woken.insert(c.id)
        let ok = pane.sendText(startMessage(target: target, known: at != nil))
        log("start chat=\(c.title) target=\(target) sent=\(ok)")
        if !ok { sprint.update { $0 = SprintState() }; host.workspace.woken.remove(c.id); return "訊息送不出去，聊天室目前無法接收" }
        idleSince = nil
        return nil
    }

    private func usageLines() -> String {
        let m = UsageMonitor.shared
        func lines(_ title: String, _ bs: [UsageBucket]) -> String? {
            bs.isEmpty ? nil : "- \(title)：" + bs.map { "\($0.label) 剩 \($0.remaining)%" + ($0.resets.isEmpty ? "" : "（\($0.resets) 重置）") }.joined(separator: "；")
        }
        return [lines("Claude", m.buckets), lines("Gemini／agy", m.agyBuckets), lines("Codex／ChatGPT", m.codexBuckets), lines("Copilot", m.copilotBuckets)].compactMap { $0 }.joined(separator: "\n")
    }

    private func startMessage(target: Date, known: Bool) -> String {
        """
        【額度衝刺開始】使用者要把快重置的額度用掉。codenv 會盯著 \(sprint.state.watchLabel) 額度，\(UsageMonitor.when(target)) 重置\(known ? "" : "（查不到真實重置時間，暫以 5 小時後計）")；重置時會再通知你「已重置」，到時請收尾。

        目前各家額度：
        \(usageLines())

        請你：
        1. 規劃可以消耗額度、而且真的有用的工作（待辦、尚未驗收的功能、審查、補測試、寫文件、整理……），挑能在重置前做完或做到一個安全停點的。大量讀程式、批次、審查優先交給 Codex／Copilot／agy 聊天室（不花 Claude 額度，但這次的目的是用掉快重置的額度，所以 Claude 這邊也要真的用）；難題交給 Astra（Codex gpt-6-astra）或 Argon（agy gemini-4-argon-high，一次只問一份）；不用 Opus、不用 Fable。
        2. 先登記目標：`codenv-todo sprint goal "<這次衝刺的工作目標，一兩句>"`；之後每做完一件用 `codenv-todo sprint note "<做了什麼>"` 回報進度（使用者回來會在 codenv 右欄看到）。
        3. 規矩：只做本機、可還原的事，改動留在分支或工作區並 commit；不 push、不出版、不寄信發文、不刪使用者的檔案、不動設定檔。遇到需要使用者決定的事就記在 note 跳過，換下一件，不要停下來等。
        4. 做完一件就接著下一件，不要閒著；codenv 會在你閒置時提醒你繼續。
        收到「額度已重置」的通知後：不要再開新工作，把手上的收到安全停點，然後執行 `codenv-todo sprint done "<總結：做了什麼、結果、還沒完成的、需要使用者決定的>"`，並在聊天室裡也貼一份總結。
        """
    }

    // MARK: 盯重置

    func tick() {
        let st = sprint.state
        if st.phase == "running" {
            if !st.targetKnown, let at = watchTarget().at, at > Date() {
                let (label, _) = watchTarget()
                let used = (UsageMonitor.shared.buckets + UsageMonitor.shared.agyBuckets + UsageMonitor.shared.codexBuckets).first(where: { $0.label == label })?.used ?? st.baselineUsed
                sprint.update { $0.watchLabel = label; $0.targetReset = at; $0.baselineUsed = used; $0.targetKnown = true }
                log("adopt real reset \(at)")
                return
            }
            if resetDetected(st) { return beginWinding(reason: "reset") }
            nudgeIfIdle(st)
        } else if st.phase == "winding" {
            checkWinding(st)
        }
    }

    private func resetDetected(_ st: SprintState) -> Bool {
        guard let target = st.targetReset else { return false }
        if Date() >= target { return true }
        // 重置時間提早（例如手動重置）：同一格的下次重置時間往後跳了，或用量大幅掉下來
        if let b = UsageMonitor.shared.buckets.first(where: { $0.label == st.watchLabel }) ?? (UsageMonitor.shared.agyBuckets + UsageMonitor.shared.codexBuckets).first(where: { $0.label == st.watchLabel }) {
            if let r = b.resetAt, r > target.addingTimeInterval(600) { return true }
            if st.baselineUsed >= 30, b.used <= st.baselineUsed - 30 { return true }
        }
        return false
    }

    private func beginWinding(reason: String) {
        let st = sprint.state
        guard st.phase == "running" else { return }
        sprint.update { $0.phase = "winding"; $0.windingAt = Date(); $0.endReason = reason; $0.windSent = false }
        sawWorkingAfterWind = false
        sendWindMessage(reason: reason)
    }

    private func sendWindMessage(reason: String) {
        let st = sprint.state
        let why = reason == "reset" ? "額度已重置" : "使用者要你收尾"
        let msg = "【額度衝刺：\(why)】做到這裡就好。請不要再開新工作，把手上的收到安全停點，然後執行 `codenv-todo sprint done \"<總結：做了什麼、結果、還沒完成的、需要使用者決定的>\"`，並在聊天室裡貼一份同樣的總結。"
        let ok = (st.convID.flatMap(UUID.init(uuidString:)).flatMap { store.conversation($0) }).flatMap { host.workspace.pane(for: $0) as? ChatPane }?.sendText(msg) ?? false
        log("wind reason=\(reason) sent=\(ok)")
        // 送不出去（聊天室忙著被擋、剛好重開）：留在收尾狀態，每 20 秒補送，到逾時才放棄
        if ok { sprint.update { $0.windSent = true } }
    }

    private func checkWinding(_ st: SprintState) {
        guard let c = chat, let at = st.windingAt else { return finish(summary: st.summary.isEmpty ? "（聊天室已不存在）" : st.summary, auto: true) }
        if !st.windSent {
            if Date().timeIntervalSince(at) >= windTimeout { return finish(summary: "（收尾通知一直送不出去，聊天室目前無法接收。）", auto: true) }
            return sendWindMessage(reason: st.endReason)
        }
        let status = store.status[c.id] ?? .idle
        if status != .idle { sawWorkingAfterWind = true }
        let elapsed = Date().timeIntervalSince(at)
        if elapsed >= windTimeout || (status == .idle && (sawWorkingAfterWind || elapsed >= 60) && elapsed >= 30) {
            finish(summary: lastReply(of: c) ?? "（它沒有交總結，聊天室也沒有可擷取的回覆。）", auto: true)
        }
    }

    private func lastReply(of c: Conversation) -> String? {
        guard let pane = host.workspace.panes[c.id] as? ChatPane, let url = pane.session.transcriptURL else { return nil }
        return Transcripts.turns(url, model: c.model ?? "", tail: 4 * 1024 * 1024).last(where: { !$0.user })?.text
    }

    private func nudgeIfIdle(_ st: SprintState) {
        guard let c = chat else { return }
        let status = store.status[c.id] ?? .idle
        guard status == .idle else { idleSince = nil; return }
        if idleSince == nil { idleSince = Date(); return }
        guard Date().timeIntervalSince(idleSince!) >= nudgeAfter, st.nudges < maxNudges else { return }
        let left = st.targetReset.map { max(0, Int($0.timeIntervalSinceNow / 60)) } ?? 0
        let ok = (host.workspace.panes[c.id] as? ChatPane)?.sendText("【額度衝刺】離重置還有約 \(left) 分鐘，額度還沒用完。請接著做下一件有用的工作（或交給其他聊天室），完成後 `codenv-todo sprint note \"…\"` 回報。") ?? false
        log("nudge ok=\(ok)")
        sprint.update { $0.nudges += 1; $0.lastNudgeAt = Date() }
        idleSince = nil
    }

    // MARK: 結束

    func finish(summary: String, auto: Bool) {
        sprint.update {
            $0.phase = "done"; $0.endedAt = Date()
            $0.summary = summary; $0.summaryAuto = auto
        }
        log("done auto=\(auto)")
    }

    // MARK: codenv-todo sprint

    func command(_ req: [String: Any]) -> [String: Any] {
        let sub = (req["sub"] as? String) ?? "status"
        let text = ((req["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let caller = store.conversation(callerPrefix: req["conv"] as? String)
        func isSprintChat() -> Bool { caller != nil && caller?.id.uuidString == sprint.state.convID }
        let st = sprint.state
        switch sub {
        case "status":
            var o: [String: Any] = ["ok": true, "phase": st.phase, "goal": st.goal, "summary": st.summary, "chat": st.convTitle, "notes": st.notes.suffix(10).map { $0.text }]
            if let t = st.targetReset { o["reset"] = UsageMonitor.when(t); o["minutesLeft"] = Int(t.timeIntervalSinceNow / 60) }
            return o
        case "start":
            if sprint.isActive { return ["ok": false, "error": "已經有衝刺在進行中（\(st.convTitle)）"] }
            let name = text.isEmpty ? nil : text
            let pool = candidates()
            let hit = name == nil ? (caller.flatMap { c in pool.first { $0.id == c.id } } ?? pool.first) : pool.first(where: { $0.title == name }) ?? store.conversations.first(where: { ($0.title == name || (name!.count >= 8 && $0.id.uuidString.lowercased().hasPrefix(name!.lowercased()))) && Store.isChat($0) && !store.isArchived($0) })
            guard let c = hit else { return ["ok": false, "error": "找不到聊天室「\(name ?? "總指揮")」"] }
            if let e = start(chat: c) { return ["ok": false, "error": e] }
            return ["ok": true, "chat": c.title]
        case "stop":
            guard sprint.state.phase == "running" else { return ["ok": false, "error": "目前沒有進行中的衝刺"] }
            if caller != nil && !isSprintChat() { return ["ok": false, "error": "只有衝刺的聊天室（\(st.convTitle)）或使用者能收尾"] }
            beginWinding(reason: "manual"); return ["ok": true]
        case "goal", "note", "done":
            guard sprint.isActive else { return ["ok": false, "error": "目前沒有進行中的衝刺"] }
            guard isSprintChat() else { return ["ok": false, "error": "只有衝刺的聊天室（\(st.convTitle)）能回報"] }
            guard !text.isEmpty else { return ["ok": false, "error": "內容不能是空的"] }
            let clipped = String(text.prefix(8000))
            if sub == "goal" { sprint.update { $0.goal = String(clipped.prefix(500)) } }
            else if sub == "note" { sprint.update { $0.notes.append(SprintNote(at: Date(), text: String(clipped.prefix(500)))) } }
            else { finish(summary: clipped, auto: false) }
            return ["ok": true]
        default:
            return ["ok": false, "error": "sprint 只有 status、start、stop、goal、note、done"]
        }
    }
}
