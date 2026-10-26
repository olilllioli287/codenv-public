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
                guard size(a) == size(b) else { throw Failure.copy(b.path) }
            }
        } catch {
            for b in copied { try? fm.removeItem(at: b) }     // 複製到一半：新的那份拿掉，舊的沒動
            throw error
        }
        // 測試模式的是暫存的假紀錄：直接刪，不要丟進使用者的垃圾桶
        let testing = CommandLine.arguments.contains("--state-dir")
        for (a, _) in items { testing ? try? fm.removeItem(at: a) : try? fm.trashItem(at: a, resultingItemURL: nil) }
    }

    /// 檔案或資料夾的總大小
    private static func size(_ u: URL) -> Int64 {
        let fm = FileManager.default
        var d: ObjCBool = false
        guard fm.fileExists(atPath: u.path, isDirectory: &d) else { return -1 }
        if !d.boolValue { return (try? fm.attributesOfItem(atPath: u.path)[.size] as? Int64) ?? -1 }
        var total: Int64 = 0
        for case let f as URL in fm.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey]) ?? FileManager.DirectoryEnumerator() {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

extension MainWindowController {
    /// 右鍵「換工作資料夾…」：選資料夾 → 問一次 → 搬
    func changeFolder(_ id: UUID) {
        guard let window, let c = store.conversation(id), let old = store.project(c.projectID)?.path else { return }
        if store.status[id] != nil || (workspace.panes[id] == nil && ClaudeSessions.live()[c.claudeSession] != nil) {
            confirm("這段對話還在跑", "等它停下來（或按停止）再換資料夾。", button: "好") {}
            return
        }
        let o = NSOpenPanel()
        o.canChooseDirectories = true
        o.canChooseFiles = false
        o.canCreateDirectories = true
        o.prompt = "換到這裡"
        o.message = "「\(c.title)」之後在哪個資料夾工作（現在是 \(ClaudeEnvs.tilde(old))）"
        o.directoryURL = URL(fileURLWithPath: old).deletingLastPathComponent()
        o.beginSheetModal(for: window) { [weak self] r in
            guard let self, r == .OK, let new = o.url?.path, new != old else { return }
            self.confirm("把「\(c.title)」換到 \(ClaudeEnvs.tilde(new))？",
                         "會先停掉這段對話的 Claude，把紀錄搬過去（舊的那份丟垃圾桶，救得回來），再從新資料夾接回。側欄的分組不變。",
                         button: "換資料夾") { [weak self] in self?.moveConversation(id, to: new) }
        }
    }

    /// 不問、直接搬（測試的 --move-folder 也叫這個）
    func moveConversation(_ id: UUID, to new: String) {
        guard let c = store.conversation(id), let old = store.project(c.projectID)?.path, new != old else { return }
        let group = store.groupOf(c)
        workspace.close(id)
        do {
            try ConversationMover.move(session: c.claudeSession, from: old, to: new)
        } catch ConversationMover.Failure.exists(let p) {
            confirm("沒有搬", "新資料夾那邊已經有同一段對話的紀錄（\(ClaudeEnvs.tilde(p))），怕蓋掉就先不動。", button: "好") {}
            host.invalidate(id); return
        } catch {
            confirm("沒有搬", "複製紀錄失敗，原本的紀錄沒動：\(error.localizedDescription)", button: "好") {}
            host.invalidate(id); return
        }
        let pid = store.projects.first(where: { $0.path == new })?.id ?? store.addProject(path: new).id
        if let i = store.conversations.firstIndex(where: { $0.id == id }) { store.conversations[i].projectID = pid }
        if let group { store.move(id, toGroup: group) }
        host.invalidate(id)
    }
}
