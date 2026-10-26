import Foundation
import PDFKit

// Gemini 經 agy（Google 官方的 Antigravity 命令列工具，~/.local/bin/agy）：
// agy -p= --input-format stream-json --output-format stream-json 跟 claude -p 很像，只是格式不同。
// 這裡把 agy 吐的事件翻成 Claude Code 的格式（stream_event／assistant／user／result），畫面那邊照舊。
// 限制：agy 在這種模式不能跳出權限詢問（要寫檔、跑指令會直接被拒，除非用「改檔不問」或「自動」模式開）；
// 也不給思考內容（只有思考用了幾個 token）；不能插話、不能半途換模型（下次開程序才換）。
// agy 自己有對話紀錄，但格式不是 Claude 的：這裡另外記一份 Claude 格式的（只有訊息），重開時畫面才看得到舊對話。

final class AgyBridge {
    /// 選單上的 Gemini 模型（agy models 列得出來的；思考強度已經在名字裡）
    static let models: [(id: String, name: String)] = [
        ("gemini-4-argon-high", "Gemini 4 Argon"),
        ("gemini-3.8-flash-high", "Gemini 3.8 Flash"),
        ("claude-opus-5-5-high", "Claude Opus 5.5"),
        ("claude-sonnet-5-5-high", "Claude Sonnet 5.5"),
    ]
    static func name(_ model: String) -> String { models.first { base($0.id) == base(model) }?.name ?? model }
    /// 思考強度：agy 沒有另外的參數，是換名字尾巴（-low／-medium／-high）
    static let levels = ["low", "medium", "high"]
    static func level(_ model: String) -> String? { levels.first { model.hasSuffix("-" + $0) } }
    static func base(_ model: String) -> String { level(model).map { String(model.dropLast($0.count + 1)) } ?? model }
    /// 實際要開的模型：拉桿選了這三段之一就換尾巴；其他（從 Claude 帶來的 xhigh、max）照選單上的
    static func resolve(_ model: String, effort: String?) -> String {
        guard let e = effort, levels.contains(e), level(model) != nil else { return model }
        return base(model) + "-" + e
    }

    /// agy 功能有沒有打開（設定頁；公版預設關）。關著時：模型清單不列 agy、不查 agy 用量、不用 agy 猜下一句、看板不自動叫 agy
    static var enabled: Bool { Prefs.shared.agyEnabled }

    /// agy 的位置：裝在 ~/.local/bin（官方安裝方式），登入 shell 的 PATH 不一定有
    static var executable: String {
        let p = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/agy").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : "agy"
    }

    /// 工作台的對話編號 → agy 的對話編號（agy 不能指定編號，第一次開的時候它給）
    static func conversation(for id: UUID) -> String? {
        (appDefaults.dictionary(forKey: "agyConversations") as? [String: String])?[id.uuidString]
    }
    static func setConversation(_ c: String, for id: UUID) {
        var all = appDefaults.dictionary(forKey: "agyConversations") as? [String: String] ?? [:]
        all[id.uuidString] = c
        appDefaults.set(all, forKey: "agyConversations")
    }

    /// 自己記的 Claude 格式紀錄（給 loadHistory 讀）；測試 App 寫到暫存資料夾，不碰平常的
    static func transcript(for id: UUID) -> URL {
        let base = appDefaults === UserDefaults.standard
            ? Edition.support("agy")
            : URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("codenv-test-agy")
        return base.appendingPathComponent(id.uuidString.lowercased() + ".jsonl")
    }

    /// 開 agy 的參數。mode 是工作台的權限模式（default、acceptEdits、plan、auto、bypassPermissions）
    static func arguments(model: String, mode: String?, conversation: String?) -> [String] {
        var a = ["--input-format", "stream-json", "--output-format", "stream-json", "--model", model]
        switch mode {
        case "acceptEdits": a += ["--mode", "accept-edits"]
        case "plan": a += ["--mode", "plan"]
        case "auto", "bypassPermissions": a += ["--dangerously-skip-permissions"]
        default: break
        }
        if let conversation { a += ["--conversation", conversation] }
        return a + ["-p="]   // -p 要接東西，不然會把下一個參數當成提問；空的＝從 stdin 讀
    }

    let session: UUID
    let transcriptURL: URL
    /// 送進去還沒被讀的訊息（agy 照順序一則一則讀，讀到就回送一份給畫面，跟 --replay-user-messages 一樣）。
    /// 讀到才寫進紀錄：回覆途中送的那則會排隊，太早記會排在上一輪的回答前面，重開時順序錯亂
    private var waiting: [(uuid: String?, msg: [String: Any])] = []
    private var texts: [Int: String] = [:]        // step → 目前累積的文字
    private var before: [Int: String] = [:]       // 改檔前的內容（畫差異用）
    private var started = Date()
    private var deniedHint = false
    private var toolIDs: [String: String] = [:]   // 這一輪：agy 的工具名稱 → 最後一張卡片的 id（被拒時標回去）
    private var deniedIDs: Set<String> = []
    private let model: String
    private var current: [String: Any]?           // 這一輪 agy 正在回答的那則（讀進了、還沒做完）
    /// 上一個 agy 被 ⌃ C／停止 關掉時正在做的那幾則：下一則送出時附一句請它忽略（agy 用 --conversation 接回，取消的那則還在它的歷史裡）
    var cancelled: [String] = []

    init(session: UUID, model: String) {
        self.session = session
        self.model = model
        transcriptURL = Self.transcript(for: session)
    }

    // MARK: 送進去

    /// 工作台要寫給 claude 的東西 → 要寫給 agy 的（nil＝agy 沒有這個功能，不送）
    func outgoing(_ obj: [String: Any]) -> [String: Any]? {
        guard obj["type"] as? String == "user", let msg = obj["message"] as? [String: Any] else { return nil }
        // /effort 之類的斜線指令是給 Claude 的；/compact（＋可接一句話）agy 自己也有，照送
        if let s = msg["content"] as? String, s.hasPrefix("/"), s != "/compact", !s.hasPrefix("/compact ") { return nil }
        waiting.append(((obj["uuid"] as? String)?.lowercased(), msg))   // 紀錄留原本的圖（重開時畫面看得到）
        var send = msg
        if let blocks = msg["content"] as? [[String: Any]] { send["content"] = blocks.map(Self.textOnly) }
        if !cancelled.isEmpty {
            let quoted = cancelled.map { "「" + ($0.count > 200 ? String($0.prefix(200)) + "…" : $0) + "」" }.joined(separator: "、")
            let note = "（codenv 自動附註，不是使用者打的：使用者剛才按了停止，取消了 \(quoted) 這則訊息。那則不用回答，也不要把它的內容當成這次問題的一部分。下面才是使用者這次的訊息。）\n\n"
            cancelled = []
            if let t = send["content"] as? String { send["content"] = note + t }
            else { send["content"] = [["type": "text", "text": note]] + (send["content"] as? [[String: Any]] ?? []) }
        }
        return ["event": "user", "message": send]
    }

    /// 被 ⌃ C／停止 中斷時正在做的那則（沒有就是還在排隊、agy 還沒讀的第一則）的文字
    func interruptedText() -> String? {
        guard let m = current ?? waiting.first?.msg else { return nil }
        if let t = m["content"] as? String { return t }
        let t = (m["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        return t.isEmpty ? "（一張圖片）" : t
    }

    /// agy 的串流輸入只收文字區塊（送圖片會整輪報錯）：圖片存成檔，換成一句話請它用 read_file 打開（實測看得到圖）
    static func textOnly(_ b: [String: Any]) -> [String: Any] {
        guard b["type"] as? String == "image", let src = b["source"] as? [String: Any],
              let s = src["data"] as? String, let d = Data(base64Encoded: s) else { return b }
        let ext = (src["media_type"] as? String).map { $0 == "image/jpeg" ? "jpg" : String($0.split(separator: "/").last ?? "png") } ?? "png"
        let url = imageDir().appendingPathComponent("\(UUID().uuidString).\(ext)")
        guard (try? d.write(to: url)) != nil else { return ["type": "text", "text": "（使用者附了一張圖片，但存檔失敗，看不到）"] }
        return ["type": "text", "text": "（使用者附了一張圖片：\(url.path) ，請用 read_file 打開來看）"]
    }

    /// 存圖的資料夾：~/Library/Caches/codenv/agy-images；第一次用時順便清掉 7 天前的
    private static func imageDir() -> URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("codenv/agy-images")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if !imagesCleaned {
            imagesCleaned = true
            let old = Date().addingTimeInterval(-7 * 86400)
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                if let m = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m < old { try? fm.removeItem(at: f) }
            }
        }
        return dir
    }
    private static var imagesCleaned = false

    // MARK: 讀出來

    /// agy 的一行事件 → 給畫面的（Claude 格式）
    func incoming(_ o: [String: Any]) -> [[String: Any]] {
        switch o["event"] as? String {
        case "init":
            if let c = o["conversation_id"] as? String { Self.setConversation(c, for: session) }
            let i = o["init"] as? [String: Any] ?? [:]
            return [["type": "system", "subtype": "init", "model": model, "cwd": i["cwd"] ?? "", "session_id": session.uuidString.lowercased()]]
        case "step_update":
            return step(o["step_update"] as? [String: Any] ?? [:])
        case "result":
            current = nil
            let r = o["result"] as? [String: Any] ?? [:]
            let ok = r["status"] as? String == "SUCCESS"
            var out: [String: Any] = ["type": "result", "subtype": ok ? "success" : "error_during_execution", "is_error": !ok,
                                      "duration_ms": Int(Date().timeIntervalSince(started) * 1000)]   // agy 自己算的會把排隊等待也算進去
            if !ok { out["result"] = (r["error"] as? String).map { "Gemini：" + $0 } ?? "Gemini 回報錯誤" }
            // 有時候被拒的工具步驟照樣回「完成」，只在結果裡列出被拒的動作：卡片標回「沒有權限」
            var notes: [[String: Any]] = []
            for a in (r["denied_actions"] as? [[String: Any]] ?? []).compactMap({ $0["action"] as? String }) {
                guard let id = toolIDs[a] ?? toolIDs[a == "command" ? "run_command" : a], !deniedIDs.contains(id) else { continue }
                notes += denied(id, a)
            }
            texts.removeAll(); before.removeAll(); toolIDs.removeAll(); deniedIDs.removeAll()
            return notes + [out]
        default:
            return []
        }
    }

    private func step(_ s: [String: Any]) -> [[String: Any]] {
        guard let idx = s["step_index"] as? Int else { return [] }
        let state = s["state"] as? String ?? ""
        let msgID = "agy-\(session.uuidString.prefix(8))-\(idx)"
        switch s["step_type"] as? String {
        case "user_input":
            // agy 讀進了一則：回送給畫面（排隊的泡泡移進對話），新的一輪開始
            guard state == "DONE", !waiting.isEmpty else { return [] }
            started = Date()
            let w = waiting.removeFirst()
            record(["type": "user", "message": w.msg])
            current = w.msg
            guard let u = w.uuid else { return [] }
            return [["type": "user", "isReplay": true, "uuid": u, "message": ["role": "user", "content": []]]]
        case "agent_response":
            var out: [[String: Any]] = []
            let delta = s["text_delta"] as? String ?? ""
            let first = texts[idx] == nil
            if first, !delta.isEmpty {
                texts[idx] = ""
                out.append(stream(["type": "message_start", "message": ["id": msgID, "role": "assistant"]], msgID))
                out.append(stream(["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]], msgID))
            }
            if !delta.isEmpty, texts[idx] != nil {
                texts[idx]! += delta
                out.append(stream(["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": delta]], msgID))
            }
            if state == "DONE", let full = texts[idx] {
                out.append(stream(["type": "content_block_stop", "index": 0], msgID))
                out.append(stream(["type": "message_stop"], msgID))
                let text = full.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    var m: [String: Any] = ["id": msgID, "role": "assistant", "content": [["type": "text", "text": full]]]
                    // agy 這一步讀了多少（input＋快取讀）：換成 Claude 的 usage，右側欄的上下文就有數字（重開時從紀錄讀）
                    if let u = s["usage"] as? [String: Any] {
                        let n = { (k: String) in (u[k] as? NSNumber)?.intValue ?? Int(u[k] as? String ?? "") ?? 0 }
                        m["usage"] = ["input_tokens": n("input_tokens"), "cache_read_input_tokens": n("cache_read_tokens"), "output_tokens": n("output_tokens")]
                    }
                    let a: [String: Any] = ["type": "assistant", "message": m]
                    out.append(a)
                    record(a)
                }
            }
            return out
        case "checkpoint":
            // agy 壓縮對話（打 /compact 或快滿時自己壓）：翻成 Claude 的 compact_boundary，畫面顯示「對話已壓縮」
            // 壓縮後多大要等下一輪的 usage 才知道，所以不帶 compact_metadata
            guard state == "DONE" else { return [] }
            let b: [String: Any] = ["type": "system", "subtype": "compact_boundary"]
            record(b)
            return [b]
        case "tool":
            let info = s["tool_info"] as? [String: Any] ?? [:]
            let raw = info["name"] as? String ?? s["tool_name"] as? String ?? "tool"
            let params = info["parameters"] as? [String: Any] ?? [:]
            let id = "agy-tool-\(session.uuidString.prefix(8))-\(idx)"
            let path = params["Path"] as? String ?? params["TargetFile"] as? String ?? params["AbsolutePath"] as? String
            if state == "ACTIVE" {
                if raw == "edit_file" || raw == "write_file", let path { before[idx] = Self.peek(path) ?? "" }
                return [toolUse(id, idx, msgID, raw, params, path, done: false)]
            }
            guard state == "DONE" || state == "ERROR" else { return [] }
            var out: [[String: Any]] = []
            let use = toolUse(id, idx, msgID, raw, params, path, done: true)
            out.append(use)
            record(use)
            let err = (info["error"] as? [String: Any])?["message"] as? String
            var content = info["output"] as? String ?? ""
            if raw == "run_command" { content = Self.commandOutput(content) }
            if raw == "read_file", err == nil, let path {
                // PDF 不是純文字，peek 讀不出來（卡片只剩「完成」）：另外抽每頁的文字給畫面看
                if path.lowercased().hasSuffix(".pdf") { if let t = Self.pdfText(path) { content = t } }
                else if let c = Self.peek(path) { content = c }
            }
            if let err { content = err }
            if content.isEmpty, err == nil { content = "完成" }
            let res: [String: Any] = ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": content, "is_error": err != nil]]]]
            out.append(res)
            // 自己的紀錄檔只存前 2 萬字（讀一次大 PDF 就是幾百 KB，重開時要整份讀回來）
            if content.count > Self.recordLimit {
                let short = String(content.prefix(Self.recordLimit)) + "\n…（紀錄只存前 \(Self.recordLimit / 10000) 萬字，完整內容在原檔）"
                record(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": short, "is_error": err != nil]]]])
            } else {
                record(res)
            }
            toolIDs[raw] = id
            if let err, err.contains("permission") { out += denied(id, raw) }
            return out
        default:
            return []
        }
    }

    /// 工具被拒：卡片標成「沒有權限」，第一次再加一行說明怎麼放行
    private func denied(_ id: String, _ raw: String) -> [[String: Any]] {
        deniedIDs.insert(id)
        var out: [[String: Any]] = [["type": "system", "subtype": "permission_denied", "tool_use_id": id, "tool_name": raw]]
        if !deniedHint {
            deniedHint = true
            out.append(["type": "system", "subtype": "permission_denied",
                        "tool_name": "\(raw)。agy 不能跳出詢問：要讓它改檔，按 ⇧ Tab 換成「改檔不問」；連指令也要跑，換成「自動」（下一則訊息生效）"])
        }
        return out
    }

    private func stream(_ event: [String: Any], _ msgID: String) -> [String: Any] {
        ["type": "stream_event", "event": event, "api_message_id": msgID]
    }

    /// agy 的工具 → Claude 的工具名稱和參數（畫面才畫得出指令、檔名、內容、差異）
    private func toolUse(_ id: String, _ idx: Int, _ msgID: String, _ raw: String, _ p: [String: Any], _ path: String?, done: Bool) -> [String: Any] {
        var name = raw
        var input = p
        switch raw {
        case "run_command":
            name = "Bash"; input = ["command": p["CommandLine"] as? String ?? ""]
        case "read_file", "view_file":
            name = "Read"; input = ["file_path": path ?? ""]
        case "write_file", "write_to_file":
            name = "Write"; input = ["file_path": path ?? ""]
            if done, let path { input["content"] = Self.peek(path) ?? "" }
        case "edit_file", "replace_file_content", "multi_replace_file_content":
            name = "Edit"; input = ["file_path": path ?? ""]
            if done, let path { input["old_string"] = before[idx] ?? ""; input["new_string"] = Self.peek(path) ?? "" }
        case "list_dir":
            name = "LS"; input = ["path": path ?? p["DirectoryPath"] as? String ?? ""]
        case "grep_search":
            name = "Grep"; input = ["pattern": p["Query"] as? String ?? "", "path": p["SearchPath"] as? String ?? ""]
        case "search_web":
            name = "WebSearch"; input = ["query": p["Query"] as? String ?? ""]
        case "read_url_content":
            name = "WebFetch"; input = ["url": p["Url"] as? String ?? ""]
        default: break
        }
        return ["type": "assistant", "message": ["id": msgID, "role": "assistant", "content": [["type": "tool_use", "id": id, "name": name, "input": input]]]]
    }

    /// 「Command exited with code 0.\n\nCommand output:\n…」→ 輸出本身；不是 0 的照 Claude 的寫法加「Exit code N」
    static func commandOutput(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\r\n", with: "\n")
        var code = 0
        if let r = t.range(of: #"^Command exited with code (-?\d+)\.\s*"#, options: .regularExpression) {
            code = Int(t[r].filter { $0.isNumber || $0 == "-" }) ?? 0
            t.removeSubrange(r)
        }
        if let r = t.range(of: #"^Command output:\n?"#, options: .regularExpression) { t.removeSubrange(r) }
        t = t.trimmingCharacters(in: .newlines)
        return code == 0 ? t : "Exit code \(code)\n\(t)"
    }

    static let recordLimit = 20_000

    /// PDF 每頁的文字給畫面看（標「第 n 頁」，最多約 10 萬字）；掃描的圖片 PDF 抽不到字就回 nil，照舊顯示「完成」
    static func pdfText(_ path: String, limit: Int = 100_000) -> String? {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { return nil }
        var out = "", any = false
        for i in 0..<doc.pageCount {
            let t = (doc.page(at: i)?.string ?? "").replacingOccurrences(of: "\u{FFFC}", with: "")
                .replacingOccurrences(of: #"\n[ \t]*(\n[ \t]*)+"#, with: "\n", options: .regularExpression)   // 圖片的位置留下的空行
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { any = true }
            out += (i == 0 ? "" : "\n\n") + "── 第 \(i + 1) 頁 ──\n" + t
            if out.count > limit {
                out = String(out.prefix(limit)) + "\n…（只顯示前 \(limit / 10000) 萬字，共 \(doc.pageCount) 頁）"
                break
            }
        }
        return any ? out : nil
    }

    /// 讀檔給畫面看（太大的不讀）
    static func peek(_ path: String) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path), (a[.size] as? Int ?? 0) < 400_000 else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// 記一筆進自己的紀錄檔（只記訊息，不記串流片段）
    private func record(_ obj: [String: Any]) {
        var obj = obj
        obj["timestamp"] = obj["timestamp"] ?? Transcripts.stamp()   // 跟 Claude 紀錄同欄位：md 和交接看得到時間
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: transcriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: transcriptURL.path) { fm.createFile(atPath: transcriptURL.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: transcriptURL) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: d + Data([0x0a]))
    }
}
