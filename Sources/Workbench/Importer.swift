import Foundation

// 把在 App 外面（iTerm、tmux）開的 Claude Code 對話拿進工作台。
// 對話紀錄在 ~/.claude/projects/<資料夾>/<編號>.jsonl；正在跑的對話，Claude 會在 ~/.claude/sessions/<pid>.json
// 寫下程序編號、對話編號、資料夾和它在 tmux 的哪一格（用這個判斷「還開在別處」）。

struct ExternalSession: Identifiable, Hashable {
    let id: UUID              // Claude 的對話編號
    let cwd: String
    let title: String
    let titleIsCustom: Bool   // 使用者用 /rename 取的名字
    let modified: Date
    let size: Int
    var live: LiveSession?
}

struct LiveSession: Hashable {
    let pid: Int32
    let tmux: String          // 例如「小生:@11.%22」；不在 tmux 就是空的
    let kind: String          // interactive、bg…
}

enum ClaudeSessions {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude") }

    /// 現在正在跑的 Claude（程序還活著的）：對話編號 → 資訊
    static func live() -> [UUID: LiveSession] {
        let dir = home.appendingPathComponent("sessions")
        var out: [UUID: LiveSession] = [:]
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "json" {
            guard let d = try? Data(contentsOf: f), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let pid = (o["pid"] as? NSNumber)?.int32Value, let sid = (o["sessionId"] as? String).flatMap(UUID.init) else { continue }
            guard kill(pid, 0) == 0 else { continue }
            out[sid] = LiveSession(pid: pid, tmux: o["tmux"] as? String ?? "", kind: o["kind"] as? String ?? "")
        }
        return out
    }

    /// 掃描所有對話紀錄（只看檔頭和檔尾，100 MB 的檔也很快）
    static func scan(includeTemp: Bool = false) -> [ExternalSession] {
        let root = home.appendingPathComponent("projects")
        let fm = FileManager.default
        let live = live()
        var out: [ExternalSession] = []
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            if !includeTemp && (dir.lastPathComponent.hasPrefix("-private-tmp") || dir.lastPathComponent.hasPrefix("-tmp")) { continue }
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
            for f in files where f.pathExtension == "jsonl" {
                guard let id = UUID(uuidString: f.deletingPathExtension().lastPathComponent) else { continue }
                let rv = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                guard let info = peek(f) else { continue }
                out.append(ExternalSession(id: id, cwd: info.cwd, title: info.title, titleIsCustom: info.custom,
                                           modified: rv?.contentModificationDate ?? .distantPast, size: rv?.fileSize ?? 0, live: live[id]))
            }
        }
        return out.sorted { $0.modified > $1.modified }
    }

    /// 讀檔頭找資料夾和第一句話、檔尾找標題（/rename 的優先，其次 Claude 自動取的）
    static func peek(_ url: URL) -> (cwd: String, title: String, custom: Bool)? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 256 * 1024)) ?? Data()
        let end = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: end > 512 * 1024 ? end - 512 * 1024 : 0)
        let tail = (try? h.readToEnd()) ?? Data()
        var cwd = "", first = "", ai = "", custom = ""
        for raw in head.split(separator: 0x0a) {
            guard let o = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { continue }
            if cwd.isEmpty, let c = o["cwd"] as? String { cwd = c }
            if first.isEmpty, o["type"] as? String == "user", o["isMeta"] as? Bool != true,
               let m = o["message"] as? [String: Any] {
                let t = (m["content"] as? String) ?? ((m["content"] as? [[String: Any]])?.first { $0["type"] as? String == "text" }?["text"] as? String) ?? ""
                if !t.hasPrefix("<") && !t.isEmpty { first = t }
            }
            if !cwd.isEmpty && !first.isEmpty { break }
        }
        for raw in (head + tail).split(separator: 0x0a) {
            // 只解析標題那幾種記錄，其他略過（快）
            guard raw.count < 4000, let s = String(data: raw, encoding: .utf8), s.contains("itle\"") else { continue }
            guard let o = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { continue }
            if o["type"] as? String == "custom-title", let t = o["customTitle"] as? String { custom = t }
            if o["type"] as? String == "ai-title", let t = o["aiTitle"] as? String { ai = t }
        }
        // 開頭是一大段壓縮摘要（超過 256 KB）時檔頭找不到資料夾：往後一段一段找第一個 "cwd"
        if cwd.isEmpty {
            try? h.seek(toOffset: 0)
            let key = Data("\"cwd\":\"".utf8)
            var carry = Data()
            while cwd.isEmpty, let chunk = try? h.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
                let buf = carry + chunk
                if let r = buf.range(of: key), let end = buf[r.upperBound...].firstIndex(of: 0x22) {
                    cwd = String(decoding: buf[r.upperBound..<end], as: UTF8.self)
                }
                carry = buf.suffix(4096)
            }
        }
        guard !cwd.isEmpty else { return nil }
        let title = !custom.isEmpty ? custom : (!ai.isEmpty ? ai : String(first.split(separator: "\n").first ?? "（沒有內容）").prefix(40).description)
        return (cwd, title, !custom.isEmpty)
    }
}

extension Store {
    /// 匯入：沒有的專案（資料夾）自動建立；已經在工作台的對話不重複
    @discardableResult
    func importSessions(_ list: [ExternalSession]) -> [UUID] {
        var added: [UUID] = []
        for s in list {
            if conversations.contains(where: { $0.claudeSession == s.id }) { continue }
            let pid: UUID
            if let p = projects.first(where: { $0.path == s.cwd }) { pid = p.id }
            else { pid = addProject(path: s.cwd).id }
            var c = Conversation(projectID: pid, title: s.title)
            c.claudeSession = s.id
            c.renamed = s.titleIsCustom
            c.createdAt = s.modified
            c.lastOpened = s.modified
            conversations.append(c)
            added.append(c.id)
        }
        return added
    }
}
