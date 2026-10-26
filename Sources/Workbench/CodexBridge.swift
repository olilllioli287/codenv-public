import Foundation

// ChatGPT 經 Codex（OpenAI 官方的命令列工具 codex，用 ChatGPT 帳號登入）：
// 開一個 `codex app-server`（stdin／stdout 一行一個 JSON-RPC 訊息），這裡把它的事件翻成 Claude Code 的格式，畫面照舊。
// 跟 agy 不一樣的地方：會真的來問權限（item/…/requestApproval → 畫面的權限卡片）、能停止這一輪（turn/interrupt）、
// 能插話（turn/steer）、有思考摘要；模型、思考強度、權限模式每一輪都能換（turn/start 帶參數），不用重開程序。
// 對話紀錄跟 agy 一樣另外記一份 Claude 格式的，重開時畫面看得到；接回用 thread/resume。

final class CodexBridge {
    /// 選單上的模型（ChatGPT 免費方案 model/list 列出來的）
    static let models: [(id: String, name: String)] = [
        ("gpt-6-luna", "GPT-6 Luna"),
        ("gpt-5.6-terra", "GPT-5.6 Terra"),
        ("gpt-5.6-luna", "GPT-5.6 Luna"),
    ]
    /// 思考強度：~/.codex/models_cache.json 裡這幾個都支援 low～max，沒指定時是 medium
    static let levels = Effort.order
    static let defaultLevel = "medium"
    static func name(_ model: String) -> String { models.first { $0.id == model }?.name ?? model }

    /// 有沒有裝 codex（brew 裝在 /opt/homebrew/bin）
    static var installed: Bool {
        ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"].contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 工作台的對話編號 → Codex 的 thread id（第一次開的時候它給）
    static func thread(for id: UUID) -> String? {
        (appDefaults.dictionary(forKey: "codexThreads") as? [String: String])?[id.uuidString]
    }
    static func setThread(_ t: String, for id: UUID) {
        var all = appDefaults.dictionary(forKey: "codexThreads") as? [String: String] ?? [:]
        all[id.uuidString] = t
        appDefaults.set(all, forKey: "codexThreads")
    }

    /// 自己記的 Claude 格式紀錄（給 loadHistory 讀）；測試 App 寫到暫存資料夾
    static func transcript(for id: UUID) -> URL {
        let base = appDefaults === UserDefaults.standard
            ? Edition.support("codex")
            : URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("codenv-test-codex")
        return base.appendingPathComponent(id.uuidString.lowercased() + ".jsonl")
    }

    /// 工作台的權限模式 → Codex 的（什麼時候問、沙盒能碰哪裡）
    static func policy(_ mode: String?) -> (approval: String, sandbox: String, sandboxPolicy: [String: Any]) {
        switch mode {
        case "acceptEdits", "auto": return ("on-request", "workspace-write", ["type": "workspaceWrite"])   // 專案資料夾裡改檔、跑指令不問，要出去才問
        case "plan": return ("on-request", "read-only", ["type": "readOnly"])
        case "bypassPermissions": return ("never", "danger-full-access", ["type": "dangerFullAccess"])
        default: return ("untrusted", "workspace-write", ["type": "workspaceWrite"])                       // 改檔、跑指令都先問
        }
    }

    let session: UUID
    let directory: String
    let transcriptURL: URL
    var model: String
    var effort: String?
    var mode: String?
    /// 寫一行 JSON-RPC 給 codex（ChatSession 給的，不經過翻譯）
    var send: (([String: Any]) -> Void)?
    /// 交給畫面的事件（Claude 格式）
    var emit: (([String: Any]) -> Void)?

    private var nextID = 0
    private var calls: [Int: String] = [:]            // 還沒回的請求：id → 方法
    private var threadID: String?
    private var turnID: String?
    private var queue: [(uuid: String, input: [[String: Any]], text: [String: Any])] = []
    private var starting: String?                      // 送出 turn/start、還沒開始的那則訊息 uuid
    private var approvals: [String: Any] = [:]         // 畫面上的 request_id → codex 請求的 id
    private var texts: [String: String] = [:]          // itemId → 累積的文字／思考
    private var thinkingOpen: Set<String> = []
    private var started = Date()

    init(session: UUID, directory: String, model: String) {
        self.session = session
        self.directory = directory
        self.model = model
        transcriptURL = Self.transcript(for: session)
    }

    // MARK: 送進去

    /// 程序開起來後：握手，接回（或新開）對話
    func start() {
        call("initialize", ["clientInfo": ["name": "codenv", "title": "codenv", "version": "1"]])
        send?(["jsonrpc": "2.0", "method": "initialized"])
        let p = Self.policy(mode)
        var params: [String: Any] = ["cwd": directory, "model": model, "approvalPolicy": p.approval, "sandbox": p.sandbox]
        if let t = Self.thread(for: session) {
            params["threadId"] = t
            params["excludeTurns"] = true
            call("thread/resume", params)
        } else {
            call("thread/start", params)
        }
    }

    /// 工作台要寫給 claude 的東西 → 翻成 codex 的（使用者訊息、權限回覆）
    func outgoing(_ obj: [String: Any]) {
        switch obj["type"] as? String {
        case "user":
            guard let msg = obj["message"] as? [String: Any] else { return }
            if let s = msg["content"] as? String, s.hasPrefix("/") { return }   // /effort 之類是給 Claude 的
            let uuid = (obj["uuid"] as? String)?.lowercased() ?? UUID().uuidString.lowercased()
            queue.append((uuid, Self.input(msg), msg))   // 真的送出（next／steer）時才寫紀錄：排隊時就記會排在上一輪回答前面
            next()
        case "control_response":
            guard let r = obj["response"] as? [String: Any], let rid = r["request_id"] as? String,
                  let id = approvals.removeValue(forKey: rid) else { return }
            let ans = r["response"] as? [String: Any] ?? [:]
            let allow = ans["behavior"] as? String == "allow"
            let always = allow && ans["updatedPermissions"] != nil
            send?(["jsonrpc": "2.0", "id": id, "result": ["decision": allow ? (always ? "acceptForSession" : "accept") : "decline"]])
        default:
            break   // initialize 等控制指令：codex 沒有對應的
        }
    }

    /// 停止這一輪（Esc）
    func interrupt() {
        guard let t = threadID, let turn = turnID else { return }
        call("turn/interrupt", ["threadId": t, "turnId": turn])
    }

    /// ⌃ Enter：排隊中的這則馬上插進正在做的這一輪
    func steer(_ uuid: String) {
        guard let t = threadID, let turn = turnID, let i = queue.firstIndex(where: { $0.uuid == uuid.lowercased() }) else { return }
        let q = queue.remove(at: i)
        record(["type": "user", "message": q.text])
        call("turn/steer", ["threadId": t, "expectedTurnId": turn, "input": q.input])
        emit?(["type": "user", "isReplay": true, "uuid": q.uuid, "message": ["role": "user", "content": []]])
    }

    /// 閒著、有排隊的就開下一輪
    private func next() {
        guard let t = threadID, turnID == nil, starting == nil, !queue.isEmpty else { return }
        let q = queue.removeFirst()
        record(["type": "user", "message": q.text])
        starting = q.uuid
        let p = Self.policy(mode)
        var params: [String: Any] = ["threadId": t, "input": q.input, "model": model,
                                     "approvalPolicy": p.approval, "sandboxPolicy": p.sandboxPolicy, "summary": "auto"]
        if let effort { params["effort"] = effort }
        call("turn/start", params)
    }

    private func call(_ method: String, _ params: [String: Any]) {
        nextID += 1
        calls[nextID] = method
        send?(["jsonrpc": "2.0", "id": nextID, "method": method, "params": params])
    }

    /// Claude 格式的訊息內容 → codex 的 input（文字；圖片先存成暫存檔再給路徑）
    private static func input(_ msg: [String: Any]) -> [[String: Any]] {
        if let s = msg["content"] as? String { return [["type": "text", "text": s]] }
        var out: [[String: Any]] = []
        for b in msg["content"] as? [[String: Any]] ?? [] {
            if b["type"] as? String == "text", let t = b["text"] as? String { out.append(["type": "text", "text": t]) }
            if b["type"] as? String == "image", let src = b["source"] as? [String: Any], let s = src["data"] as? String, let d = Data(base64Encoded: s) {
                let ext = (src["media_type"] as? String)?.contains("png") == true ? "png" : "jpg"
                let f = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("codenv-codex-\(UUID().uuidString.prefix(8)).\(ext)")
                if (try? d.write(to: f)) != nil { out.append(["type": "localImage", "path": f.path]) }
            }
        }
        return out
    }

    // MARK: 讀出來

    func incoming(_ o: [String: Any]) {
        // 回覆（有 id、有 result 或 error、沒有 method）
        if o["method"] == nil, let id = (o["id"] as? NSNumber)?.intValue, let m = calls.removeValue(forKey: id) {
            reply(m, o["result"] as? [String: Any], o["error"] as? [String: Any])
            return
        }
        guard let method = o["method"] as? String else { return }
        let p = o["params"] as? [String: Any] ?? [:]
        if let id = o["id"] { request(method, id, p); return }   // codex 反過來問（權限）
        notification(method, p)
    }

    private func reply(_ method: String, _ r: [String: Any]?, _ err: [String: Any]?) {
        switch method {
        case "thread/start", "thread/resume":
            if let err {
                // 接不回去（例如紀錄被刪了）：開一段新的
                if method == "thread/resume" {
                    let p = Self.policy(mode)
                    call("thread/start", ["cwd": directory, "model": model, "approvalPolicy": p.approval, "sandbox": p.sandbox])
                } else {
                    fail("Codex 開不了對話：" + (err["message"] as? String ?? ""))
                }
                return
            }
            guard let t = (r?["thread"] as? [String: Any])?["id"] as? String else { return }
            threadID = t
            Self.setThread(t, for: session)
            emit?(["type": "system", "subtype": "init", "model": model, "cwd": directory, "session_id": session.uuidString.lowercased()])
            next()
        case "turn/start":
            if let err { starting = nil; fail("Codex：" + (err["message"] as? String ?? "送不出去")); next(); return }
            if let t = (r?["turn"] as? [String: Any])?["id"] as? String, turnID == nil { turnID = t }
        default:
            if let err, method != "turn/interrupt" { emit?(["type": "system", "subtype": "api_retry", "attempt": 0, "error": err["message"] ?? ""]) }
        }
    }

    /// 這一輪還沒開始就失敗：畫面上收尾
    private func fail(_ msg: String) {
        emit?(["type": "result", "subtype": "error_during_execution", "is_error": true, "result": msg, "duration_ms": 0])
    }

    private func request(_ method: String, _ id: Any, _ p: [String: Any]) {
        let item = p["itemId"] as? String ?? ""
        switch method {
        case "item/commandExecution/requestApproval":
            let rid = "codex-\(UUID().uuidString.prefix(8))"
            approvals[rid] = id
            let cmd = Self.unwrap(p["command"] as? String ?? "")
            var input: [String: Any] = ["command": cmd]
            if let r = p["reason"] as? String { input["description"] = r }
            emit?(["type": "control_request", "request_id": rid,
                   "request": ["subtype": "can_use_tool", "tool_name": "Bash", "input": input, "tool_use_id": item]])
        case "item/fileChange/requestApproval":
            let rid = "codex-\(UUID().uuidString.prefix(8))"
            approvals[rid] = id
            let (name, input) = pendingChange[item] ?? ("Edit", ["file_path": p["grantRoot"] as? String ?? ""])
            emit?(["type": "control_request", "request_id": rid,
                   "request": ["subtype": "can_use_tool", "tool_name": name, "input": input, "tool_use_id": item]])
        default:
            // 還沒支援的（回答問題、MCP 授權…）：回「不支援」，不然 codex 會一直等
            send?(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "codenv 不支援 \(method)"]])
        }
    }
    private var pendingChange: [String: (String, [String: Any])] = [:]

    private func notification(_ m: String, _ p: [String: Any]) {
        switch m {
        case "turn/started":
            turnID = (p["turn"] as? [String: Any])?["id"] as? String ?? turnID
            started = Date()
            if let u = starting {
                starting = nil
                emit?(["type": "user", "isReplay": true, "uuid": u, "message": ["role": "user", "content": []]])
            }
        case "item/started":
            itemStarted(p["item"] as? [String: Any] ?? [:])
        case "item/completed":
            itemCompleted(p["item"] as? [String: Any] ?? [:])
        case "item/agentMessage/delta":
            guard let id = p["itemId"] as? String, let d = p["delta"] as? String, !d.isEmpty else { return }
            texts[id, default: ""] += d
            emit?(stream(["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": d]], id))
        case "item/reasoning/summaryTextDelta":
            guard let id = p["itemId"] as? String, let d = p["delta"] as? String, !d.isEmpty else { return }
            if !thinkingOpen.contains(id) {
                thinkingOpen.insert(id)
                emit?(stream(["type": "message_start", "message": ["id": id, "role": "assistant"]], id))
                emit?(stream(["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": ""]], id))
            }
            texts[id, default: ""] += d
            emit?(stream(["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": d]], id))
        case "turn/completed":
            let t = p["turn"] as? [String: Any] ?? [:]
            let status = t["status"] as? String ?? "completed"
            var out: [String: Any] = ["type": "result", "subtype": status == "completed" ? "success" : "error_during_execution",
                                      "is_error": status != "completed",
                                      "duration_ms": (t["durationMs"] as? NSNumber)?.intValue ?? Int(Date().timeIntervalSince(started) * 1000)]
            if status == "failed" { out["result"] = "Codex：" + Self.errorText((t["error"] as? [String: Any])?["message"] as? String) }
            if status == "interrupted" { emit?(["type": "user", "message": ["role": "user", "content": "[Request interrupted by user]"]]) }
            turnID = nil
            texts.removeAll(); thinkingOpen.removeAll(); pendingChange.removeAll()
            emit?(out)
            next()
        case "error":
            // 會自己重試的錯誤：提示一下；不重試的會跟著 turn/completed failed 收尾
            if p["willRetry"] as? Bool == true { emit?(["type": "system", "subtype": "api_retry", "attempt": 1]) }
        default:
            break
        }
    }

    /// 錯誤訊息常常是一整段 JSON：挑出裡面的 message
    static func errorText(_ s: String?) -> String {
        guard let s else { return "發生錯誤" }
        if let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let m = (o["error"] as? [String: Any])?["message"] as? String { return m }
        return s
    }

    private func itemStarted(_ it: [String: Any]) {
        guard let id = it["id"] as? String else { return }
        switch it["type"] as? String {
        case "agentMessage":
            emit?(stream(["type": "message_start", "message": ["id": id, "role": "assistant"]], id))
            emit?(stream(["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]], id))
        case "commandExecution", "fileChange", "mcpToolCall", "webSearch", "dynamicToolCall":
            let (name, input) = tool(it)
            if it["type"] as? String == "fileChange" { pendingChange[id] = (name, input) }
            emit?(toolUse(id, name, input))
        default: break
        }
    }

    private func itemCompleted(_ it: [String: Any]) {
        guard let id = it["id"] as? String else { return }
        switch it["type"] as? String {
        case "agentMessage":
            let full = it["text"] as? String ?? texts[id] ?? ""
            // 整則要在 content_block_stop 之前送：畫面收到 stop 就把那塊標成完成，之後來的整則會當成新的一塊
            if !full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let a: [String: Any] = ["type": "assistant", "message": ["id": id, "role": "assistant", "content": [["type": "text", "text": full]]]]
                emit?(a); record(a)
            }
            emit?(stream(["type": "content_block_stop", "index": 0], id))
            emit?(stream(["type": "message_stop"], id))
        case "reasoning":
            guard thinkingOpen.contains(id) || !((it["summary"] as? [String])?.isEmpty ?? true) else { return }
            let full = (it["summary"] as? [String])?.joined(separator: "\n\n") ?? texts[id] ?? ""
            let a: [String: Any] = ["type": "assistant", "message": ["id": id, "role": "assistant", "content": [["type": "thinking", "thinking": full]]]]
            emit?(a); record(a)   // 先送整則再 stop（不然思考會畫兩次）
            if thinkingOpen.contains(id) {
                emit?(stream(["type": "content_block_stop", "index": 0], id))
                emit?(stream(["type": "message_stop"], id))
            }
        case "commandExecution", "fileChange", "mcpToolCall", "webSearch", "dynamicToolCall":
            let (name, input) = tool(it)
            let use = toolUse(id, name, input)
            emit?(use); record(use)
            let status = it["status"] as? String ?? "completed"
            var content: String
            switch it["type"] as? String {
            case "commandExecution":
                content = (it["aggregatedOutput"] as? String ?? "").trimmingCharacters(in: .newlines)
                let code = (it["exitCode"] as? NSNumber)?.intValue ?? 0
                if code != 0 { content = "Exit code \(code)\n" + content }
            case "mcpToolCall":
                content = (it["result"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }.flatMap { String(data: $0, encoding: .utf8) }
                    ?? ((it["error"] as? [String: Any])?["message"] as? String ?? "")
            default:
                content = status == "completed" ? "完成" : ""
            }
            if status == "declined" { content = "使用者拒絕" }
            if content.isEmpty { content = status == "failed" ? "失敗" : "完成" }
            let res: [String: Any] = ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": content,
                                                                                              "is_error": status == "failed" || status == "declined"]]]]
            emit?(res); record(res)
        default: break
        }
    }

    /// codex 的工具項目 → Claude 的工具名稱和參數（畫面才畫得出指令、檔名、差異）
    private func tool(_ it: [String: Any]) -> (String, [String: Any]) {
        switch it["type"] as? String {
        case "commandExecution":
            let cmd = Self.unwrap(it["command"] as? String ?? "")
            // 只是讀一個檔（cat 之類）：畫成讀檔卡
            if let acts = it["commandActions"] as? [[String: Any]], acts.count == 1, acts[0]["type"] as? String == "read",
               let path = acts[0]["path"] as? String { return ("Read", ["file_path": path]) }
            return ("Bash", ["command": cmd])
        case "fileChange":
            let changes = it["changes"] as? [[String: Any]] ?? []
            guard changes.count == 1, let c = changes.first, let path = c["path"] as? String else {
                return ("ApplyPatch", ["files": changes.compactMap { $0["path"] as? String }])
            }
            let diff = c["diff"] as? String ?? ""
            switch (c["kind"] as? [String: Any])?["type"] as? String {
            case "add": return ("Write", ["file_path": path, "content": diff])
            case "delete": return ("Delete", ["file_path": path])
            default:
                let (old, new) = Self.sides(diff)
                return ("Edit", ["file_path": path, "old_string": old, "new_string": new])
            }
        case "webSearch":
            return ("WebSearch", ["query": it["query"] as? String ?? ""])
        case "mcpToolCall":
            return ("mcp__\(it["server"] as? String ?? "")__\(it["tool"] as? String ?? "")", it["arguments"] as? [String: Any] ?? [:])
        default:
            return (it["tool"] as? String ?? "tool", it["arguments"] as? [String: Any] ?? [:])
        }
    }

    /// 「/bin/zsh -lc 'cat a.txt'」→「cat a.txt」
    static func unwrap(_ s: String) -> String {
        for pre in ["/bin/zsh -lc ", "/bin/bash -lc ", "zsh -lc ", "bash -lc "] where s.hasPrefix(pre) {
            var t = String(s.dropFirst(pre.count))
            if t.count >= 2, let f = t.first, f == t.last, f == "'" || f == "\"" { t = String(t.dropFirst().dropLast()) }
            return t.replacingOccurrences(of: "'\\''", with: "'")
        }
        return s
    }

    /// unified diff → 改之前／改之後（畫差異用）
    static func sides(_ diff: String) -> (String, String) {
        var old: [Substring] = [], new: [Substring] = []
        for l in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if l.hasPrefix("@@") || l.hasPrefix("---") || l.hasPrefix("+++") { continue }
            if l.hasPrefix("-") { old.append(l.dropFirst()) }
            else if l.hasPrefix("+") { new.append(l.dropFirst()) }
            else { let t = l.hasPrefix(" ") ? l.dropFirst() : l; old.append(t); new.append(t) }
        }
        return (old.joined(separator: "\n"), new.joined(separator: "\n"))
    }

    private func toolUse(_ id: String, _ name: String, _ input: [String: Any]) -> [String: Any] {
        ["type": "assistant", "message": ["id": "codex-tool-" + id, "role": "assistant", "content": [["type": "tool_use", "id": id, "name": name, "input": input]]]]
    }

    private func stream(_ event: [String: Any], _ msgID: String) -> [String: Any] {
        ["type": "stream_event", "event": event, "api_message_id": msgID]
    }

    /// 記一筆進自己的紀錄檔（只記訊息；太長的工具結果截掉，重開才不會慢）
    private func record(_ obj: [String: Any]) {
        var obj = obj
        obj["timestamp"] = obj["timestamp"] ?? Transcripts.stamp()   // 跟 Claude 紀錄同欄位：md 和交接看得到時間
        if var msg = obj["message"] as? [String: Any], var blocks = msg["content"] as? [[String: Any]] {
            for i in blocks.indices {
                if blocks[i]["type"] as? String == "tool_result", let c = blocks[i]["content"] as? String, c.count > 20_000 {
                    blocks[i]["content"] = String(c.prefix(20_000)) + "\n…（紀錄只存前 2 萬字）"
                }
            }
            msg["content"] = blocks
            obj["message"] = msg
        }
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
