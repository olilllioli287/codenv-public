import AppKit

// 對話右鍵「換工作資料夾…」：Claude 的紀錄是照資料夾分開存的（~/.claude/projects/<資料夾>/<編號>.jsonl），
// 換資料夾要先停掉 Claude、把紀錄複製到新資料夾那邊、確認大小一樣才把舊的丟垃圾桶（救得回來），再從新資料夾接回。
// 側欄的分組不變（原本歸哪一組，搬完還是那一組）。

enum ConversationMover {
    /// ~/.claude/projects；用 --state-dir 開的測試 App 改用測試資料夾裡的 projects，不碰真的紀錄
    static let root: URL = {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--state-dir"), i + 1 < a.count {
            return URL(fileURLWithPath: a[i + 1]).appendingPathComponent("projects")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }()

    static func slug(_ path: String) -> String { String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" }) }

    enum Failure: Error { case exists(String), copy(String) }

    /// 把一段 Claude 對話的紀錄（jsonl＋同名的子資料夾：子代理、工具結果）從 from 資料夾搬到 to 資料夾
    static func move(session: UUID, from: String, to: String) throws {
        let fm = FileManager.default
        let id = session.uuidString.lowercased()
        let oldDir = root.appendingPathComponent(slug(from)), newDir = root.appendingPathComponent(slug(to))
        // 兩個資料夾的 slug 一樣（非英數字都變成 -，例如字數相同的中文資料夾）：Claude 本來就把它們的紀錄放在同一個資料夾，沒有東西要搬
        if oldDir.standardizedFileURL == newDir.standardizedFileURL { return }
        let items = [id + ".jsonl", id].map { (oldDir.appendingPathComponent($0), newDir.appendingPathComponent($0)) }
            .filter { fm.fileExists(atPath: $0.0.path) }
        guard !items.isEmpty else { return }      // 還沒聊過、沒有紀錄：只換資料夾就好
        if let hit = items.first(where: { fm.fileExists(atPath: $0.1.path) }) { throw Failure.exists(hit.1.path) }
        try fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        var copied: [URL] = []
        do {
            for (a, b) in items {
                try fm.copyItem(at: a, to: b)
                copied.append(b)
                guard let sa = size(a), let sb = size(b), sa == sb else { throw Failure.copy(b.path) }   // 讀不到大小＝無法確認，一律當失敗（不能讓兩邊都讀不到被當成一樣）
            }
        } catch {
            for b in copied { try? fm.removeItem(at: b) }     // 複製到一半：新的那份拿掉，舊的沒動
            throw error
        }
        // 測試模式的是暫存的假紀錄：直接刪，不要丟進使用者的垃圾桶
        let testing = CommandLine.arguments.contains("--state-dir")
        for (a, _) in items { testing ? try? fm.removeItem(at: a) : try? fm.trashItem(at: a, resultingItemURL: nil) }
    }

    /// 正在搬的對話（等 Claude 結束的幾秒裡，同一段對話不能再搬一次）
    static var moving: Set<UUID> = []

    /// 檔案或資料夾的總大小；讀不到（沒有這個檔、沒權限、列舉失敗）回 nil
    private static func size(_ u: URL) -> Int64? {
        let fm = FileManager.default
        var d: ObjCBool = false
        guard fm.fileExists(atPath: u.path, isDirectory: &d) else { return nil }
        if !d.boolValue { return (try? fm.attributesOfItem(atPath: u.path)[.size]) .flatMap { $0 as? Int64 } }
        var failed = false
        guard let en = fm.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey], options: [], errorHandler: { _, _ in failed = true; return true }) else { return nil }
        var total: Int64 = 0
        for case let f as URL in en {
            // 子資料夾本身沒有 fileSize（一定是 nil）：只算一般檔案，一般檔案讀不到才算失敗
            guard let v = try? f.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]) else { failed = true; continue }
            if v.isDirectory == true { continue }
            guard let n = v.fileSize else { failed = true; continue }
            total += Int64(n)
        }
        return failed ? nil : total
    }
}

extension MainWindowController {
    /// 右鍵「換工作資料夾…」：選資料夾 → 問一次 → 搬
    func changeFolder(_ id: UUID) {
        guard let window, let c = store.conversation(id), let old = store.project(c.projectID)?.path else { return }
        // state.json 沒讀到或正在保護原檔：搬了之後新的資料夾位置存不下來，紀錄卻已經搬走，對話會找不到
        if store.isSaveProtected {
            confirm(L("現在不能換資料夾"), L("codenv 的設定檔 state.json 這次沒讀到（或讀不懂），為了保護原檔先不存任何改動。換資料夾會搬走紀錄但位置存不下來。請先處理設定檔（看啟動時的提示或 state.json.讀不到-*）再換。"), button: L("好")) {}
            return
        }
        if store.status[id] != nil || (workspace.panes[id] == nil && ClaudeSessions.live()[c.claudeSession] != nil) {
            confirm(L("這段對話還在跑"), L("等它停下來（或按停止）再換資料夾。"), button: L("好")) {}
            return
        }
        if hasUnsentInput(id) { return warnUnsentInput() }
        let o = NSOpenPanel()
        o.canChooseDirectories = true
        o.canChooseFiles = false
        o.canCreateDirectories = true
        o.prompt = L("換到這裡")
        o.message = L("「\(c.title)」之後在哪個資料夾工作（現在是 \(ClaudeEnvs.tilde(old))）")
        o.directoryURL = URL(fileURLWithPath: old).deletingLastPathComponent()
        o.beginSheetModal(for: window) { [weak self] r in
            guard let self, r == .OK, let new = o.url?.path, new != old else { return }
            self.confirm(L("把「\(c.title)」換到 \(ClaudeEnvs.tilde(new))？"),
                         L("會先停掉這段對話的 Claude，把紀錄搬過去（舊的那份丟垃圾桶，救得回來），再從新資料夾接回。側欄的分組不變。"),
                         button: L("換資料夾")) { [weak self] in self?.moveConversation(id, to: new) }
        }
    }

    /// 輸入框裡打了字、貼了圖還沒送：搬的時候會關掉這一格，字會不見，所以先不搬
    private func hasUnsentInput(_ id: UUID) -> Bool { (workspace.panes[id] as? ChatPane)?.inputBar.hasPendingInput == true }
    private func warnUnsentInput() {
        confirm(L("輸入框裡還有沒送出的內容"), L("換資料夾會關掉這一格，沒送出的字和圖會不見。先送出、或清掉再換。"), button: L("好")) {}
    }

    /// 不問、直接搬（測試的 --move-folder 也叫這個）
    func moveConversation(_ id: UUID, to new: String) {
        guard let c = store.conversation(id), let old = store.project(c.projectID)?.path, new != old else { return }
        if hasUnsentInput(id) { return warnUnsentInput() }
        // 按下確認之後才開始跑（問的時候它可能又動起來了）：再確認一次，還在做事就不搬
        if store.status[id] != nil {
            confirm(L("這段對話還在跑"), L("等它停下來（或按停止）再換資料夾。"), button: L("好")) {}
            return
        }
        guard ConversationMover.moving.insert(id).inserted else { return }    // 已經在搬了（同一段對話按了兩次）
        let group = store.groupOf(c)
        workspace.close(id)
        // close 只是送出結束信號、不等 claude 真的結束；它還在寫紀錄的話，複製到的會少一截、舊的又丟進垃圾桶。等它結束（最多 5 秒）才搬
        awaitStopped(c.claudeSession, tries: 25) { [weak self] stopped in
            guard let self else { ConversationMover.moving.remove(id); return }
            guard stopped else {
                ConversationMover.moving.remove(id)
                self.confirm(L("沒有搬"), L("Claude 還沒結束，為了不弄丟最後幾則，先不搬。過幾秒再試一次。"), button: L("好")) {}
                self.host.invalidate(id)
                return
            }
            self.finishMove(id, c, old, new, group)
        }
    }

    /// 等這段對話的 claude 程序真的結束（每 0.2 秒看一次）；沒有程序就馬上回 true
    private func awaitStopped(_ session: UUID, tries: Int, _ done: @escaping (Bool) -> Void) {
        if ClaudeSessions.live()[session] == nil { return done(true) }
        if tries <= 0 { return done(false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.awaitStopped(session, tries: tries - 1, done) }
    }

    private func finishMove(_ id: UUID, _ c: Conversation, _ old: String, _ new: String, _ group: UUID?) {
        defer { ConversationMover.moving.remove(id) }
        guard store.conversation(id) != nil else { return }   // 等 Claude 結束的幾秒裡，這段對話被刪掉了：不搬
        do {
            try ConversationMover.move(session: c.claudeSession, from: old, to: new)
        } catch ConversationMover.Failure.exists(let p) {
            confirm(L("沒有搬"), L("新資料夾那邊已經有同一段對話的紀錄（\(ClaudeEnvs.tilde(p))），怕蓋掉就先不動。"), button: L("好")) {}
            host.invalidate(id); return
        } catch {
            confirm(L("沒有搬"), L("複製紀錄失敗，原本的紀錄沒動：\(error.localizedDescription)"), button: L("好")) {}
            host.invalidate(id); return
        }
        let pid = store.projects.first(where: { $0.path == new })?.id ?? store.addProject(path: new).id
        if let i = store.conversations.firstIndex(where: { $0.id == id }) { store.conversations[i].projectID = pid }
        if let group { store.move(id, toGroup: group) }
        // 紀錄已經搬走了：state.json 馬上寫，不等延遲存檔（中間閃退的話重開會指著舊資料夾）
        if !store.saveNow() {
            EventLog.log(L("檔案"), L("換工作資料夾後 state.json 沒寫成"))
            confirm(L("設定還沒存好"), L("對話紀錄已經搬到新資料夾，但 codenv 的設定檔暫時寫不進去。先不要關掉 codenv；之後會自動再試，若一直失敗請回報。"), button: L("好")) {}
        }
        host.invalidate(id)
    }
}
