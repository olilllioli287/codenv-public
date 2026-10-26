import Foundation

// GitHub Copilot 經 Copilot CLI（GitHub 官方的命令列工具 copilot，用 GitHub 帳號登入）：
// 開一個 `copilot --acp`（Agent Client Protocol：stdin／stdout 一行一個 JSON-RPC 訊息），這裡把它的事件翻成 Claude Code 的格式，畫面照舊。
// 協定：initialize → session/new（或 session/load 接回）→ 每則訊息一個 session/prompt，回覆帶 stopReason 就是這一輪結束；
// 中間 session/update 送文字、思考、工具（tool_call／tool_call_update），要權限時反過來發 session/request_permission。
// 跟 Codex 不一樣的地方：沒有插話（⌃ Enter 改成停下這一輪、馬上送這則）；模型只能開的時候指定（免費方案只有 Auto），
// 強度是 Auto 的偏好（--auto-tier），換了要重開；接回時會先把舊對話重播一遍，那段丟掉，畫面讀自己記的紀錄。

final class CopilotBridge {
    /// 選單上的模型（Copilot Free 只有 Auto：每次由 Copilot 自己挑 GPT／Claude／Gemini）
    static let models: [(id: String, name: String)] = [
        ("auto", "Copilot Auto"),
    ]
    /// 思考強度 → Auto 的偏好：低＝省（efficiency）、中＝平衡（balance）、高＝聰明（intelligence）
    static let levels = ["low", "medium", "high"]
    static let defaultLevel = "medium"
    static func tier(_ effort: String?) -> String {
        switch effort { case "low": "efficiency"; case "high": "intelligence"; default: "balance" }
    }
    static func name(_ model: String) -> String { models.first { $0.id == model }?.name ?? model }

    /// 有沒有裝 copilot（brew 的 copilot-cli 裝在 /opt/homebrew/bin）
    static var installed: Bool {
        ["/opt/homebrew/bin/copilot", "/usr/local/bin/copilot"].contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 開程序的參數
    static func arguments(model: String, effort: String?) -> [String] {
        var a = ["--acp", "--disable-client-telemetry", "--model", model]
        if model == "auto" { a += ["--auto-tier", tier(effort)] }
        return a
    }

    /// 工作台的對話編號 → Copilot 的 sessionId（第一次開的時候它給）
    static func sessionID(for id: UUID) -> String? {
        (appDefaults.dictionary(forKey: "copilotSessions") as? [String: String])?[id.uuidString]
    }
    static func setSessionID(_ s: String, for id: UUID) {
        var all = appDefaults.dictionary(forKey: "copilotSessions") as? [String: String] ?? [:]
        all[id.uuidString] = s
        appDefaults.set(all, forKey: "copilotSessions")
    }

    /// 自己記的 Claude 格式紀錄（給 loadHistory 讀）；測試 App 寫到暫存資料夾
    static func transcript(for id: UUID) -> URL {
        let base = appDefaults === UserDefaults.standard
            ? Edition.support("copilot")
            : URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("codenv-test-copilot")
        return base.appendingPathComponent(id.uuidString.lowercased() + ".jsonl")
    }

    static let agentMode = "https://agentclientprotocol.com/protocol/session-modes#agent"
    static let planMode = "https://agentclientprotocol.com/protocol/session-modes#plan"

    let session: UUID
    let directory: String
    let transcriptURL: URL
    let model: String
    var mode: String? { didSet { if mode != oldValue { applyMode() } } }
    /// 寫一行 JSON-RPC 給 copilot（ChatSession 給的，不經過翻譯）
    var send: (([String: Any]) -> Void)?
    /// 交給畫面的事件（Claude 格式）
    var emit: (([String: Any]) -> Void)?

    private var nextID = 0
    private var calls: [Int: String] = [:]             // 還沒回的請求：id → 方法
    private var sessionID: String?
    private var loading = false                         // session/load 重播中：這段的 session/update 不要
    private var busy = false                            // 有一個 session/prompt 還沒回
    private var queue: [(uuid: String, prompt: [[String: Any]], msg: [String: Any])] = []
    private var approvals: [String: (id: Any, options: [[String: Any]])] = [:]   // 畫面上的 request_id → copilot 請求的 id、選項
    private var open: (id: String, kind: String, text: String)?                  // 正在串流的文字或思考
    private var tools: [String: (name: String, input: [String: Any])] = [:]     // toolCallId → 畫面上的工具
    private var toolOutput: [String: String] = [:]
    private var toolDone: Set<String> = []
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
        call("initialize", ["protocolVersion": 1, "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false]])
    }

    /// 工作台要寫給 claude 的東西 → 翻成 copilot 的（使用者訊息、權限回覆）
    func outgoing(_ obj: [String: Any]) {
        switch obj["type"] as? String {
        case "user":
            guard let msg = obj["message"] as? [String: Any] else { return }
            if let s = msg["content"] as? String, s.hasPrefix("/") { return }   // /effort 之類是給 Claude 的
            let uuid = (obj["uuid"] as? String)?.lowercased() ?? UUID().uuidString.lowercased()
            queue.append((uuid, Self.prompt(msg), msg))   // 真的送出（next）時才寫紀錄：排隊時就記會排在上一輪回答前面
            next()
        case "control_response":
            guard let r = obj["response"] as? [String: Any], let rid = r["request_id"] as? String,
                  let a = approvals.removeValue(forKey: rid) else { return }
            let ans = r["response"] as? [String: Any] ?? [:]
            let allow = ans["behavior"] as? String == "allow"
            let kind = allow ? (ans["updatedPermissions"] != nil ? "allow_always" : "allow_once") : "reject_once"
            answer(a.id, a.options, kind)
        default:
            break   // initialize 等控制指令：copilot 沒有對應的
        }
    }

    /// 停止這一輪（Esc）：還在等的權限一併回「取消」
    func interrupt() {
        guard let s = sessionID, busy else { return }
        for (_, a) in approvals { send?(["jsonrpc": "2.0", "id": a.id, "result": ["outcome": ["outcome": "cancelled"]]]) }
        approvals.removeAll()
        send?(["jsonrpc": "2.0", "method": "session/cancel", "params": ["sessionId": s]])
    }

    /// ⌃ Enter：ACP 沒有插話，改成這則排到最前面、停下正在做的這一輪，停好馬上送
    func steer(_ uuid: String) {
        guard let i = queue.firstIndex(where: { $0.uuid == uuid.lowercased() }) else { return }
        queue.insert(queue.remove(at: i), at: 0)
        interrupt()
    }

    /// 閒著、有排隊的就送下一則
    private func next() {
        guard let s = sessionID, !busy, !loading, !queue.isEmpty else { return }
        let q = queue.removeFirst()
        record(["type": "user", "message": q.msg])
        busy = true
        started = Date()
        emit?(["type": "user", "isReplay": true, "uuid": q.uuid, "message": ["role": "user", "content": []]])
        call("session/prompt", ["sessionId": s, "prompt": q.prompt])
    }

    /// 權限模式：規劃＝Copilot 的 Plan；其他用 Agent，要不要問由這裡決定（見 request）
    private func applyMode() {
        guard let s = sessionID else { return }
        call("session/set_mode", ["sessionId": s, "modeId": mode == "plan" ? Self.planMode : Self.agentMode])
    }

    private func call(_ method: String, _ params: [String: Any]) {
        nextID += 1
        calls[nextID] = method
        send?(["jsonrpc": "2.0", "id": nextID, "method": method, "params": params])
    }

    private func answer(_ id: Any, _ options: [[String: Any]], _ kind: String) {
        // 照種類挑它給的選項；找不到「永遠允許」就退回「允許一次」
        let pick = options.first { $0["kind"] as? String == kind } ?? options.first { ($0["kind"] as? String)?.hasPrefix(kind.hasPrefix("allow") ? "allow" : "reject") == true }
        guard let opt = pick?["optionId"] as? String else {
            send?(["jsonrpc": "2.0", "id": id, "result": ["outcome": ["outcome": "cancelled"]]])
            return
        }
        send?(["jsonrpc": "2.0", "id": id, "result": ["outcome": ["outcome": "selected", "optionId": opt]]])
    }

    /// Claude 格式的訊息內容 → ACP 的 prompt（文字、圖片）
    private static func prompt(_ msg: [String: Any]) -> [[String: Any]] {
        if let s = msg["content"] as? String { return [["type": "text", "text": s]] }
        var out: [[String: Any]] = []
        for b in msg["content"] as? [[String: Any]] ?? [] {
            if b["type"] as? String == "text", let t = b["text"] as? String { out.append(["type": "text", "text": t]) }
            if b["type"] as? String == "image", let src = b["source"] as? [String: Any], let d = src["data"] as? String {
                out.append(["type": "image", "mimeType": src["media_type"] as? String ?? "image/png", "data": d])
            }
        }
        return out
    }

    // MARK: 讀出來

    func incoming(_ o: [String: Any]) {
        // 回覆（有 id、沒有 method）；copilot 反過來問的請求也有 id，編號跟我們的會撞，要看有沒有 method
        if o["method"] == nil, let id = (o["id"] as? NSNumber)?.intValue, let m = calls.removeValue(forKey: id) {
            reply(m, o["result"] as? [String: Any], o["error"] as? [String: Any])
            return
        }
        guard let method = o["method"] as? String else { return }
        let p = o["params"] as? [String: Any] ?? [:]
        if let id = o["id"] { request(method, id, p); return }
        if method == "session/update", !loading, let u = p["update"] as? [String: Any] { update(u) }
    }

    private func reply(_ method: String, _ r: [String: Any]?, _ err: [String: Any]?) {
        switch method {
        case "initialize":
            if let err { fail(L("Copilot 開不起來：") + (err["message"] as? String ?? "")); return }
            if let s = Self.sessionID(for: session) {
                loading = true
                call("session/load", ["sessionId": s, "cwd": directory, "mcpServers": []])
            } else {
                call("session/new", ["cwd": directory, "mcpServers": []])
            }
        case "session/new", "session/load":
            loading = false
            if let err {
                // 接不回去（例如紀錄被刪了）：開一段新的
                if method == "session/load" { call("session/new", ["cwd": directory, "mcpServers": []]) }
                else { fail(L("Copilot 開不了對話：") + (err["message"] as? String ?? "")) }
                return
            }
            let s = r?["sessionId"] as? String ?? Self.sessionID(for: session)
            guard let s else { return }
            sessionID = s
            Self.setSessionID(s, for: session)
            if mode == "plan" { applyMode() }
            emit?(["type": "system", "subtype": "init", "model": "copilot-" + model, "cwd": directory, "session_id": session.uuidString.lowercased()])
            next()
        case "session/prompt":
            closeOpen()
            busy = false
            let reason = r?["stopReason"] as? String
            if let err {
                fail(L("Copilot：") + (err["message"] as? String ?? L("送不出去")))
            } else if reason == "cancelled" {
                emit?(["type": "user", "message": ["role": "user", "content": "[Request interrupted by user]"]])
                emit?(["type": "result", "subtype": "error_during_execution", "is_error": true, "duration_ms": ms()])
            } else {
                var out: [String: Any] = ["type": "result", "subtype": "success", "is_error": false, "duration_ms": ms()]
                if reason == "refusal" { out["subtype"] = "error_during_execution"; out["is_error"] = true; out["result"] = L("Copilot 拒絕回答") }
                if reason == "max_tokens" || reason == "max_turn_requests" { out["result"] = L("Copilot 到了長度上限，停在這裡") }
                emit?(out)
            }
            tools.removeAll(); toolOutput.removeAll(); toolDone.removeAll()
            next()
        default:
            if let err, method != "session/set_mode" { emit?(["type": "system", "subtype": "api_retry", "attempt": 0, "error": err["message"] ?? ""]) }
        }
    }

    private func ms() -> Int { Int(Date().timeIntervalSince(started) * 1000) }

    /// 這一輪還沒開始就失敗：畫面上收尾
    private func fail(_ msg: String) {
        emit?(["type": "result", "subtype": "error_during_execution", "is_error": true, "result": msg, "duration_ms": 0])
    }

    private func request(_ method: String, _ id: Any, _ p: [String: Any]) {
        guard method == "session/request_permission" else {
            // 還沒支援的：回「不支援」，不然 copilot 會一直等
            send?(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "codenv 不支援 \(method)"]])
            return
        }
        let tc = p["toolCall"] as? [String: Any] ?? [:]
        let options = p["options"] as? [[String: Any]] ?? []
        let kind = tc["kind"] as? String ?? ""
        // 不用問的模式：全部允許、自動；接受修改＝讀檔、改檔直接允許，跑指令還是問
        if mode == "bypassPermissions" || mode == "auto" || (mode == "acceptEdits" && ["read", "edit", "search"].contains(kind)) {
            answer(id, options, "allow_once")
            return
        }
        let callID = tc["toolCallId"] as? String ?? UUID().uuidString
        // 請求裡的參數比 tool_call 那時候完整（寫檔有差異），畫面用新的
        let (name, input) = tool(tc, fallback: tools[callID])
        tools[callID] = (name, input)
        let rid = "copilot-\(UUID().uuidString.prefix(8))"
        approvals[rid] = (id, options)
        emit?(["type": "control_request", "request_id": rid,
               "request": ["subtype": "can_use_tool", "tool_name": name, "input": input, "tool_use_id": callID]])
    }

    private func update(_ u: [String: Any]) {
        switch u["sessionUpdate"] as? String {
        case "agent_message_chunk":
            chunk("text", (u["content"] as? [String: Any])?["text"] as? String)
        case "agent_thought_chunk":
            chunk("thinking", (u["content"] as? [String: Any])?["text"] as? String)
        case "tool_call":
            closeOpen()
            guard let id = u["toolCallId"] as? String else { return }
            let (name, input) = tool(u, fallback: nil)
            tools[id] = (name, input)
            emit?(toolUse(id, name, input))
        case "tool_call_update":
            guard let id = u["toolCallId"] as? String, !toolDone.contains(id) else { return }
            // 每次送來的 content 是整份（蓋掉前一次的，不是接在後面）；寫檔的差異在 content 的 diff 裡
            let texts = (u["content"] as? [[String: Any]] ?? []).compactMap { c in c["type"] as? String == "content" ? (c["content"] as? [String: Any])?["text"] as? String : nil }
            if !texts.isEmpty { toolOutput[id] = texts.joined() }
            for c in u["content"] as? [[String: Any]] ?? [] {
                if c["type"] as? String == "diff", let path = c["path"] as? String {
                    let old = c["oldText"] as? String ?? "", new = c["newText"] as? String ?? ""
                    tools[id] = old.isEmpty ? ("Write", ["file_path": path, "content": new]) : ("Edit", ["file_path": path, "old_string": old, "new_string": new])
                }
            }
            let status = u["status"] as? String
            guard status == "completed" || status == "failed" else { return }
            toolDone.insert(id)
            let (name, input) = tools[id] ?? ("tool", [:])
            let use = toolUse(id, name, input)
            emit?(use); record(use)
            let raw = u["rawOutput"] as? [String: Any]
            var content = toolOutput[id] ?? ""
            if content.isEmpty { content = raw?["content"] as? String ?? raw?["message"] as? String ?? "" }
            if raw?["code"] as? String == "rejected" { content = "使用者拒絕" }
            // 指令結果最後一行是 Copilot 自己的標記（<shellId: 0 completed with exit code 0>），畫面不需要
            if let r = content.range(of: "\n<shellId:", options: .backwards) { content = String(content[..<r.lowerBound]) }
            content = content.trimmingCharacters(in: .newlines)
            if content.isEmpty { content = status == "failed" ? "失敗" : "完成" }
            let res: [String: Any] = ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": content,
                                                                                              "is_error": status == "failed"]]]]
            emit?(res); record(res)
        default:
            break   // 用量、標題、指令清單、模式變化：畫面用不到
        }
    }

    /// 串流的文字／思考：同一種連續的算一則；換種類或來了工具就收尾
    private func chunk(_ kind: String, _ t: String?) {
        guard let t, !t.isEmpty else { return }
        if open?.kind != kind {
            closeOpen()
            let id = "copilot-" + UUID().uuidString.prefix(8).lowercased()
            open = (id, kind, "")
            emit?(stream(["type": "message_start", "message": ["id": id, "role": "assistant"]], id))
            emit?(stream(["type": "content_block_start", "index": 0, "content_block": kind == "text" ? ["type": "text", "text": ""] : ["type": "thinking", "thinking": ""]], id))
        }
        open?.text += t
        guard let id = open?.id else { return }
        emit?(stream(["type": "content_block_delta", "index": 0, "delta": kind == "text" ? ["type": "text_delta", "text": t] : ["type": "thinking_delta", "thinking": t]], id))
    }

    private func closeOpen() {
        guard let o = open else { return }
        open = nil
        // 整則要在 content_block_stop 之前送：畫面收到 stop 就把那塊標成完成，之後來的整則會當成新的一塊（思考會畫兩次）
        if !o.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let block: [String: Any] = o.kind == "text" ? ["type": "text", "text": o.text] : ["type": "thinking", "thinking": o.text]
            let a: [String: Any] = ["type": "assistant", "message": ["id": o.id, "role": "assistant", "content": [block]]]
            emit?(a); record(a)
        }
        emit?(stream(["type": "content_block_stop", "index": 0], o.id))
        emit?(stream(["type": "message_stop"], o.id))
    }

    /// ACP 的工具（kind＋rawInput）→ Claude 的工具名稱和參數（畫面才畫得出指令、檔名、差異）
    private func tool(_ tc: [String: Any], fallback: (name: String, input: [String: Any])?) -> (String, [String: Any]) {
        let kind = tc["kind"] as? String ?? ""
        let raw = tc["rawInput"]
        let args = raw as? [String: Any] ?? [:]
        let path = args["path"] as? String ?? args["fileName"] as? String ?? ((tc["locations"] as? [[String: Any]])?.first?["path"] as? String)
        switch kind {
        case "execute":
            var input: [String: Any] = ["command": args["command"] as? String ?? (tc["title"] as? String ?? "")]
            if let d = args["description"] as? String { input["description"] = d }
            return ("Bash", input)
        case "read":
            return ("Read", ["file_path": path ?? (tc["title"] as? String ?? "")])
        case "edit":
            if let diff = args["diff"] as? String, let path {
                let (old, new) = CodexBridge.sides(Self.body(diff))
                return old.isEmpty ? ("Write", ["file_path": path, "content": new]) : ("Edit", ["file_path": path, "old_string": old, "new_string": new])
            }
            if let patch = raw as? String { return Self.patchTool(patch) }
            return fallback ?? ("Edit", ["file_path": path ?? ""])
        case "search":
            return ("Grep", ["pattern": args["pattern"] as? String ?? args["query"] as? String ?? (tc["title"] as? String ?? "")])
        case "fetch":
            return ("WebFetch", ["url": args["url"] as? String ?? (tc["title"] as? String ?? "")])
        default:
            return fallback ?? (tc["title"] as? String ?? "tool", args)
        }
    }

    /// git diff 去掉檔頭（diff --git、index、---、+++），留下 @@ 之後的
    private static func body(_ diff: String) -> String {
        diff.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("diff --git") && !$0.hasPrefix("index ") && !$0.hasPrefix("new file") && !$0.hasPrefix("deleted file") }
            .joined(separator: "\n")
    }

    /// apply_patch 的內容（*** Add File: …／*** Update File: …）→ 寫檔或改檔卡
    private static func patchTool(_ patch: String) -> (String, [String: Any]) {
        var files: [String] = []
        var adds: [String: [Substring]] = [:]
        var current: String?
        for l in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            for pre in ["*** Add File: ", "*** Update File: ", "*** Delete File: "] where l.hasPrefix(pre) {
                current = String(l.dropFirst(pre.count))
                files.append(current!)
                if pre == "*** Add File: " { adds[current!] = [] }
            }
            if let c = current, adds[c] != nil, l.hasPrefix("+") { adds[c]!.append(l.dropFirst()) }
        }
        if files.count == 1, let f = files.first, let lines = adds[f] { return ("Write", ["file_path": f, "content": lines.joined(separator: "\n")]) }
        if files.count == 1, let f = files.first { return ("Edit", ["file_path": f, "old_string": "", "new_string": ""]) }
        return ("ApplyPatch", ["files": files])
    }

    private func toolUse(_ id: String, _ name: String, _ input: [String: Any]) -> [String: Any] {
        ["type": "assistant", "message": ["id": "copilot-tool-" + id, "role": "assistant", "content": [["type": "tool_use", "id": id, "name": name, "input": input]]]]
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
