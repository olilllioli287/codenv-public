import Foundation

// ChatGPT 經 Codex（OpenAI 官方的命令列工具 codex，用 ChatGPT 帳號登入）：
// 開一個 `codex app-server`（stdin／stdout 一行一個 JSON-RPC 訊息），這裡把它的事件翻成 Claude Code 的格式，畫面照舊。
// 跟 agy 不一樣的地方：會真的來問權限（item/…/requestApproval → 畫面的權限卡片）、能停止這一輪（turn/interrupt）、
// 能插話（turn/steer）、有思考摘要；模型、思考強度、權限模式每一輪都能換（turn/start 帶參數），不用重開程序。
// 對話紀錄跟 agy 一樣另外記一份 Claude 格式的，重開時畫面看得到；接回用 thread/resume。

final class CodexBridge {
    /// 選單上的模型（ChatGPT 帳號 model/list 列出來的；使用者現在是 Plus）
    static let models: [(id: String, name: String)] = [
        ("gpt-6.1-sol", "GPT-6.1 Sol"),
        ("gpt-6-sol", "GPT-6 Sol"),
        ("gpt-6.1-terra", "GPT-6.1 Terra"),
        ("gpt-6-luna", "GPT-6 Luna"),
        ("gpt-6-astra", "GPT-6 Astra"),
        ("gpt-5.6-sol", "GPT-5.6 Sol"),
        ("gpt-5.6-terra", "GPT-5.6 Terra"),
        ("gpt-5.6-luna", "GPT-5.6 Luna"),
        ("gpt-reserve", "GPT Reserve"),
        ("codex-auto-review", "Codex Auto Review"),
    ]
    /// 舊呼叫相容名稱：一般 Codex 強度；模型專用 UI 與送出路徑應使用 levels(for:)。
    static let levels = Effort.order
    static let defaultLevel = "medium"
    private static let ultraModels: Set<String> = [
        "gpt-6.1-sol", "gpt-6-sol", "gpt-6.1-terra", "gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra",
    ]
    private static let lowDefaultModels: Set<String> = [
        "gpt-6.1-sol", "gpt-6-astra", "gpt-6.1-terra", "gpt-5.6-sol",
    ]
    static func levels(for model: String) -> [String] {
        ultraModels.contains(model) ? Effort.order + ["ultra"] : Effort.order
    }
    static func defaultLevel(for model: String) -> String {
        lowDefaultModels.contains(model) ? "low" : "medium"
    }
    static func name(_ model: String) -> String { models.first { $0.id == model }?.name ?? model }

    /// 有沒有裝 codex（Homebrew 或使用者 PATH）
    static var installed: Bool {
        if CommandLine.arguments.contains("--state-dir") { return testExecutable != nil }
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return (paths + ["/opt/homebrew/bin", "/usr/local/bin"]).contains { FileManager.default.isExecutableFile(atPath: ($0 as NSString).appendingPathComponent("codex")) }
    }

    /// 僅供 --state-dir 測試探針在未提供外部 --codex-bin 時掛入暫存假腳本；正式實例不生效。
    static var probeExecutableOverride: String?

    /// 測試實例只執行明確提供的假 Codex；不借用使用者登入中的 CLI。
    static var testExecutable: String? {
        let args = CommandLine.arguments
        guard args.contains("--state-dir") else { return nil }
        if let override = probeExecutableOverride, !override.isEmpty, FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        guard let i = args.firstIndex(of: "--codex-bin"), i + 1 < args.count,
              !args[i + 1].isEmpty, FileManager.default.isExecutableFile(atPath: args[i + 1]) else { return nil }
        return args[i + 1]
    }

    static var executable: String { CommandLine.arguments.contains("--state-dir") ? (testExecutable ?? "/__codenv_test_codex_unavailable__") : "codex" }

    /// 工作台的對話編號 → Codex 的 thread id（第一次開的時候它給）
    static func thread(for id: UUID) -> String? {
        (appDefaults.dictionary(forKey: "codexThreads") as? [String: String])?[id.uuidString]
    }
    static func setThread(_ t: String, for id: UUID) {
        var all = appDefaults.dictionary(forKey: "codexThreads") as? [String: String] ?? [:]
        all[id.uuidString] = t
        appDefaults.set(all, forKey: "codexThreads")
    }
    static func backupThread(_ t: String, for id: UUID) {
        var all = appDefaults.dictionary(forKey: "codexThreadBackups") as? [String: [String]] ?? [:]
        var history = all[id.uuidString] ?? []
        if history.last != t { history.append(t) }
        all[id.uuidString] = history
        appDefaults.set(all, forKey: "codexThreadBackups")
    }
    static func backedUpThreads(for id: UUID) -> [String] {
        (appDefaults.dictionary(forKey: "codexThreadBackups") as? [String: [String]])?[id.uuidString] ?? []
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
    /// 插話請求送出去、還沒收到回覆的那幾則（請求編號 → 訊息）；已經記進紀錄了
    private var steering: [Int: (uuid: String, input: [[String: Any]], text: [String: Any])] = [:]
    /// 失敗後放回佇列的：紀錄裡已經有了，下一輪開始時不要再記一次
    private var starting: String?                      // 送出 turn/start、還沒開始的那則訊息 uuid
    private var approvals: [String: Any] = [:]         // 畫面上的 request_id → codex 請求的 id
    private var texts: [String: String] = [:]          // itemId → 累積的文字／思考
    private var thinkingOpen: Set<String> = []
    private var started = Date()
    private var resumeRetryCount = 0
    private var providerHandoffPending = false
    private var errorResultEmittedForTurn = false
    private var lastErrorResultTurnID: String?
    private var lastEndedTurnID: String?
    private var endedTurnIDs: Set<String> = []
    private var endedTurnOrder: [String] = []
    private var lastErrorMessage: String?
    /// turn/start 已送出但尚未取得 turnID 時使用者按停止：等 turnID 一設定就立刻送出 turn/interrupt。
    private var pendingStop = false
    /// 已送出的 turn/interrupt 請求 id → 目標 turnID，避免舊輪遲到的錯誤回覆誤殺新輪。
    private var pendingInterrupts: [Int: String] = [:]

    /// 尚有未完成的 turn（供程序意外退出時產生失敗結果；僅排在 queue 的訊息不計入）
    var hasIncompleteTurn: Bool { turnID != nil || starting != nil }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s
    }

    private func markEndedTurn(_ id: String) {
        lastEndedTurnID = id
        if endedTurnIDs.insert(id).inserted {
            endedTurnOrder.append(id)
            if endedTurnOrder.count > 64 {
                let oldest = endedTurnOrder.removeFirst()
                endedTurnIDs.remove(oldest)
            }
        }
    }

    private func markActiveTurn(_ id: String) {
        turnID = id
        if endedTurnIDs.remove(id) != nil {
            endedTurnOrder.removeAll { $0 == id }
        }
        if lastEndedTurnID == id { lastEndedTurnID = nil }
        if lastErrorResultTurnID == id {
            errorResultEmittedForTurn = false
            lastErrorResultTurnID = nil
        }
    }

    private func sendTurnInterrupt(threadID t: String, turnID turn: String) {
        pendingInterrupts[nextID + 1] = turn
        call("turn/interrupt", ["threadId": t, "turnId": turn])
    }

    private func flushPendingStopIfNeeded() {
        guard pendingStop, let t = threadID, let turn = turnID else { return }
        pendingStop = false
        sendTurnInterrupt(threadID: t, turnID: turn)
    }

    private func clearTurnCaches() {
        texts.removeAll()
        thinkingOpen.removeAll()
        pendingChange.removeAll()
        approvals.removeAll()
    }

    /// 程序在回合完成前意外結束：若尚未為此輪送出錯誤結果，轉成可見的失敗 result 讓畫面與狀態收尾。
    func processExitFailure(code: Int32, stderr: String) -> [String: Any]? {
        guard hasIncompleteTurn else { return nil }
        let alreadyReported = errorResultEmittedForTurn
        let detailSource = lastErrorMessage
        if let active = turnID { markEndedTurn(active) }
        turnID = nil
        starting = nil
        pendingStop = false
        pendingInterrupts.removeAll()
        queue.removeAll()
        steering.removeAll()
        errorResultEmittedForTurn = false
        lastErrorResultTurnID = nil
        lastErrorMessage = nil
        clearTurnCaches()
        if alreadyReported { return nil }
        let stderrDetail = KeyScan.redact(stderr.trimmingCharacters(in: .whitespacesAndNewlines), strongOnly: true)
        let details = [detailSource, stderrDetail].compactMap { $0 }.filter { !$0.isEmpty }
        var uniqueDetails: [String] = []
        for detail in details where !uniqueDetails.contains(detail) { uniqueDetails.append(detail) }
        let detail = uniqueDetails.joined(separator: "；")
        let message: String
        if detail.isEmpty {
            message = L("Codex 程序在本輪完成前結束（程序結束碼 \(code)）")
        } else {
            message = L("Codex：") + String(detail.suffix(900))
        }
        let result: [String: Any] = ["type": "result", "subtype": "error_during_execution", "is_error": true,
                                     "result": message, "duration_ms": Int(Date().timeIntervalSince(started) * 1000)]
        record(result)
        return result
    }

    /// 闔蓋時供通知列出尚未送完的內容；starting 即使尚無 turnID 也要保留 UUID。
    func pendingForLidInterrupt() -> [LidQueuedMessage] {
        var result = queue.map { LidQueuedMessage(id: $0.uuid, text: LidQueuedMessage.text(in: $0.text)) }
        result += steering.values.map { LidQueuedMessage(id: $0.uuid, text: LidQueuedMessage.text(in: $0.text)) }
        if let starting, !result.contains(where: { $0.id == starting }) {
            result.append(LidQueuedMessage(id: starting, text: ""))
        }
        return result
    }

    func clearForLidInterrupt() {
        queue.removeAll()
        steering.removeAll()
        starting = nil
        pendingStop = false
        pendingInterrupts.removeAll()
        errorResultEmittedForTurn = false
        lastErrorResultTurnID = nil
        lastEndedTurnID = nil
        endedTurnIDs.removeAll()
        endedTurnOrder.removeAll()
        lastErrorMessage = nil
    }

    /// 隔離闔蓋探針：建立等同 app-server 已接回、有一輪進行中的橋接狀態，不啟動 codex 程序。
    func prepareForLidInterruptProbe(turnPending: Bool, starting message: LidQueuedMessage?,
                                     queued: [LidQueuedMessage], steering: [LidQueuedMessage]) {
        threadID = "lid-probe-thread"
        turnID = turnPending ? nil : "lid-probe-turn"
        starting = message?.id.lowercased()
        queue = queued.map { item in
            let text: [String: Any] = ["role": "user", "content": item.text]
            return (item.id.lowercased(), Self.input(text), text)
        }
        self.steering = Dictionary(uniqueKeysWithValues: steering.enumerated().map { index, item in
            let text: [String: Any] = ["role": "user", "content": item.text]
            return (-index - 1, (item.id.lowercased(), Self.input(text), text))
        })
        calls.removeAll()
        nextID = 0
    }

    init(session: UUID, directory: String, model: String, transcriptURL: URL? = nil) {
        self.session = session
        self.directory = directory
        self.model = model
        self.transcriptURL = transcriptURL ?? Self.transcript(for: session)
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
            // 內部送的 /effort 之類（沒有 uuid）是給 Claude 的；使用者打的 / 開頭路徑或 /help 有 uuid，要照送，吃掉了狀態會一直是工作中
            if obj["uuid"] == nil, let s = msg["content"] as? String, s.hasPrefix("/") { return }
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

    /// 停止這一輪（Esc）；回傳 true＝已送出 turn/interrupt（或於 starting 階段掛起待 turnID 就緒後送出），
    /// false＝目前沒有進行中或啟動中的 turn（只清殘留狀態、不丟排隊訊息，呼叫端應立刻回復 idle）。
    @discardableResult
    func interrupt() -> Bool {
        if let t = threadID, let turn = turnID {
            pendingStop = false
            sendTurnInterrupt(threadID: t, turnID: turn)
            return true
        }
        if turnID == nil, starting != nil {
            pendingStop = true
            return true
        }
        if let active = turnID { markEndedTurn(active) }
        turnID = nil
        pendingStop = false
        errorResultEmittedForTurn = false
        lastErrorResultTurnID = nil
        lastErrorMessage = nil
        clearTurnCaches()
        return false
    }

    /// ⌃ Enter：排隊中的這則馬上插進正在做的這一輪
    func steer(_ uuid: String) {
        guard let t = threadID, let turn = turnID, let i = queue.firstIndex(where: { $0.uuid == uuid.lowercased() }) else { return }
        let q = queue.remove(at: i)
        // 紀錄等 codex 回覆插話成功才寫：失敗會退回佇列等下一輪，先寫會排在這一輪回答前面
        steering[nextID + 1] = q          // call 會用 nextID + 1 當這個請求的編號；回覆說失敗時靠它把這則放回佇列
        call("turn/steer", ["threadId": t, "expectedTurnId": turn, "input": q.input])
    }

    /// 閒著、有排隊的就開下一輪
    private func next() {
        guard let t = threadID, turnID == nil, starting == nil, !queue.isEmpty else { return }
        let q = queue.removeFirst()
        record(["type": "user", "message": q.text])
        starting = q.uuid
        pendingStop = false
        errorResultEmittedForTurn = false
        lastErrorResultTurnID = nil
        lastEndedTurnID = nil
        lastErrorMessage = nil
        let p = Self.policy(mode)
        var params: [String: Any] = ["threadId": t, "input": q.input, "model": model,
                                     "approvalPolicy": p.approval, "sandboxPolicy": p.sandboxPolicy, "summary": "auto"]
        if let effort, Self.levels(for: model).contains(effort) { params["effort"] = effort }
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
                let f = ImageCache.directory("codex-images").appendingPathComponent("codenv-codex-\(UUID().uuidString.prefix(8)).\(ext)")
                if ImageCache.write(d, to: f) { out.append(["type": "localImage", "path": f.path]) }
            }
        }
        return out
    }

    // MARK: 讀出來

    func incoming(_ o: [String: Any]) {
        // 回覆（有 id、有 result 或 error、沒有 method）
        if o["method"] == nil, let id = (o["id"] as? NSNumber)?.intValue, let m = calls.removeValue(forKey: id) {
            let interruptedTurn = pendingInterrupts.removeValue(forKey: id)
            if let q = steering.removeValue(forKey: id) {
              if o["error"] == nil {
                record(["type": "user", "message": q.text])
                emit?(["type": "user", "isReplay": true, "uuid": q.uuid, "message": ["role": "user", "content": []]])
              } else {
                // 插話沒送進去：不要讓這則無聲消失，放回佇列最前面，這一輪結束後會照一般排隊的送出（那時才寫紀錄）；畫面上提示一下
                queue.insert(q, at: 0)
                emit?(["type": "system", "subtype": "api_retry", "attempt": 0, "error": L("插話沒送進去，這則改排在這一輪結束後再送")])
                next()      // 插話的錯誤回覆比這一輪結束晚到：那時已經沒有下一次 next() 了，訊息會卡在佇列（next 自己會擋「這一輪還沒結束」）
              }
            }
            reply(m, o["result"] as? [String: Any], o["error"] as? [String: Any], interruptedTurn: interruptedTurn)
            return
        }
        guard let method = o["method"] as? String else { return }
        let p = o["params"] as? [String: Any] ?? [:]
        if let id = o["id"] { request(method, id, p); return }   // codex 反過來問（權限）
        notification(method, p)
    }

    private func reply(_ method: String, _ r: [String: Any]?, _ err: [String: Any]?, interruptedTurn: String? = nil) {
        switch method {
        case "initialize":
            if let err {
                fail(L("Codex：") + Self.errorText(err["message"] as? String), persist: true)
            }
        case "thread/start", "thread/resume":
            if let err {
                let message = Self.errorText(err["message"] as? String)
                if method == "thread/resume", let oldThread = Self.thread(for: session) {
                    Self.backupThread(oldThread, for: session)
                    EventLog.log("Codex 接回", "\(session.uuidString)：舊 thread=\(oldThread)，錯誤=\(message)")
                }
                if method == "thread/resume", Self.isProviderMismatch(message),
                   Self.thread(for: session) != nil {
                    providerHandoffPending = true
                    let p = Self.policy(mode)
                    call("thread/start", ["cwd": directory, "model": model, "approvalPolicy": p.approval,
                                          "sandbox": p.sandbox])
                } else if method == "thread/resume", Self.isTemporaryResumeError(message), resumeRetryCount == 0 {
                    resumeRetryCount += 1
                    let p = Self.policy(mode)
                    call("thread/resume", ["cwd": directory, "model": model, "approvalPolicy": p.approval,
                                           "sandbox": p.sandbox, "threadId": Self.thread(for: session) ?? "",
                                           "excludeTurns": true])
                } else {
                    // 聊天室先顯示一行提示（跟「換了服務來源」同一種系統提示），再顯示錯誤細節
                    emit?(["type": "system", "subtype": "api_retry", "message": Self.resumeFailedNotice])
                    fail(L("Codex 接不回舊對話，原對照未變更：") + message)
                }
                return
            }
            guard let t = (r?["thread"] as? [String: Any])?["id"] as? String else {
                fail(L("Codex：") + L("無法建立對話"), persist: true)
                return
            }
            threadID = t
            Self.setThread(t, for: session)
            if providerHandoffPending {
                providerHandoffPending = false
                emit?(["type": "system", "subtype": "api_retry",
                       "message": L("Codex 換了服務來源，已接到新對話。舊對話編號已備份。")])
                let text = Self.providerHandoff(directory: directory, transcript: transcriptURL)
                queue.insert((UUID().uuidString.lowercased(), Self.input(["content": text]),
                              ["role": "user", "content": text]), at: 0)
            }
            emit?(["type": "system", "subtype": "init", "model": model, "cwd": directory, "session_id": session.uuidString.lowercased()])
            next()
        case "turn/start":
            if let err {
                // 沒進到 turn/started／turn/completed：這裡要自己把排隊泡泡移進對話，不然會一直掛在排隊
                if let u = starting { emit?(["type": "user", "isReplay": true, "uuid": u, "message": ["role": "user", "content": []]]) }
                starting = nil
                pendingStop = false
                let msg = Self.errorText(err["message"] as? String ?? L("送不出去"))
                fail(L("Codex：") + msg, persist: true)
                next()
                return
            }
            if let t = Self.nonEmptyString((r?["turn"] as? [String: Any])?["id"]), turnID == nil {
                markActiveTurn(t)
                flushPendingStopIfNeeded()
            }
        case "turn/interrupt":
            if let err, Self.isNoActiveTurnError(err),
               interruptedTurn == nil || turnID == interruptedTurn {
                // 僅在伺服器明確回報沒有可中斷的 turn 且本地仍視該輪為進行中時才本地收尾；其他暫時性錯誤維持等待 turn/completed。
                finishInterruptedLocally()
            }
        default:
            if let err { emit?(["type": "system", "subtype": "api_retry", "attempt": 0, "error": err["message"] ?? ""]) }
        }
    }

    private func finishInterruptedLocally() {
        if let u = starting {
            starting = nil
            emit?(["type": "user", "isReplay": true, "uuid": u, "message": ["role": "user", "content": []]])
        }
        if let active = turnID { markEndedTurn(active) }
        turnID = nil
        pendingStop = false
        errorResultEmittedForTurn = false
        lastErrorResultTurnID = nil
        lastErrorMessage = nil
        clearTurnCaches()
        emit?(["type": "user", "message": ["role": "user", "content": "[Request interrupted by user]"]])
        emit?(["type": "result", "subtype": "stopped", "stopped": true, "is_error": false, "result": L("已停止"),
               "duration_ms": Int(Date().timeIntervalSince(started) * 1000)])
        next()
    }

    static var resumeFailedNotice: String { L("Codex 接不回舊對話，已保留舊對照；請重開或確認服務來源") }

    static func isProviderMismatch(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("this chat uses ") && lower.contains(", but your current provider is ")
    }

    static func isTemporaryResumeError(_ message: String) -> Bool {
        let lower = message.lowercased()
        return ["timeout", "temporar", "connection", "network", "overloaded", "rate limit", "try again"]
            .contains(where: lower.contains)
    }

    static func providerHandoff(directory: String, transcript: URL) -> String {
        let rows = ((try? String(contentsOf: transcript, encoding: .utf8)) ?? "")
            .split(separator: "\n").suffix(12)
        let context = rows.compactMap { row -> String? in
            guard let data = String(row).data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let message = object["message"] as? [String: Any],
                  let role = message["role"] as? String else { return nil }
            let content = message["content"] as? String
                ?? (message["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n")
            guard let content, !content.isEmpty else { return nil }
            return "\(role): \(String(content.suffix(2400)))"
        }.joined(separator: "\n")
        let branch = branchName(directory: directory)
        return """
        〔Codex 對話交接〕先前的 Codex thread 因 provider 不符而無法接回。請延續原工作，不要重做已完成的部分。
        工作資料夾：\(directory)
        Git 分支：\(branch)
        最近對話紀錄：
        \(context.isEmpty ? "（沒有可用的既有對話紀錄）" : context)
        """
    }

    private static func branchName(directory: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory, "branch", "--show-current"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "（無法取得）" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let name = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "（無分支）" : name
    }

    /// 這一輪還沒開始就失敗：畫面上收尾
    private func fail(_ msg: String, persist: Bool = false) {
        let out: [String: Any] = ["type": "result", "subtype": "error_during_execution", "is_error": true, "result": msg, "duration_ms": 0]
        if persist { record(out) }
        emit?(out)
    }

    private func request(_ method: String, _ id: Any, _ p: [String: Any]) {
        let item = p["itemId"] as? String ?? ""
        switch method {
        case "item/commandExecution/requestApproval":
            // app-server 會把指令核准以宿主請求送來；Bridge 原本不看權限模式，一律顯示核准卡。
            // 「全部不問」時直接回覆一次性接受，不等待使用者。
            if Self.policy(mode).approval == "never" {
                send?(["jsonrpc": "2.0", "id": id, "result": ["decision": "accept"]])
                return
            }
            let rid = "codex-\(UUID().uuidString.prefix(8))"
            let cmd = Self.unwrap(p["command"] as? String ?? "")
            var input: [String: Any] = ["command": cmd]
            if let r = p["reason"] as? String { input["description"] = r }
            approvals[rid] = id
            emit?(["type": "control_request", "request_id": rid,
                   "request": ["subtype": "can_use_tool", "tool_name": "Bash", "input": input, "tool_use_id": item]])
        case "item/fileChange/requestApproval":
            // 檔案變更核准是另一種宿主請求；「全部不問」時也直接回覆一次性接受。
            if Self.policy(mode).approval == "never" {
                send?(["jsonrpc": "2.0", "id": id, "result": ["decision": "accept"]])
                return
            }
            let rid = "codex-\(UUID().uuidString.prefix(8))"
            let (name, input) = pendingChange[item] ?? ("Edit", ["file_path": p["grantRoot"] as? String ?? ""])
            approvals[rid] = id
            emit?(["type": "control_request", "request_id": rid,
                   "request": ["subtype": "can_use_tool", "tool_name": name, "input": input, "tool_use_id": item]])
        default:
            // 還沒支援的（回答問題、MCP 授權…）：回「不支援」，不然 codex 會一直等
            send?(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "codenv 不支援 \(method)"]])
        }
    }

    private var pendingChange: [String: (String, [String: Any])] = [:]

    private func isStaleEndedTurnEvent(_ p: [String: Any]) -> Bool {
        if let eventTurn = Self.nonEmptyString(p["turnId"]) ?? Self.nonEmptyString((p["turn"] as? [String: Any])?["id"]) {
            if let active = turnID, eventTurn != active { return true }
            return endedTurnIDs.contains(eventTurn)
        }
        return turnID == nil && starting == nil && lastEndedTurnID != nil
    }

    private func notification(_ m: String, _ p: [String: Any]) {
        switch m {
        case "turn/started":
            if let t = Self.nonEmptyString((p["turn"] as? [String: Any])?["id"]) {
                markActiveTurn(t)
            }
            started = Date()
            errorResultEmittedForTurn = false
            lastErrorResultTurnID = nil
            lastEndedTurnID = nil
            lastErrorMessage = nil
            if let u = starting {
                starting = nil
                emit?(["type": "user", "isReplay": true, "uuid": u, "message": ["role": "user", "content": []]])
            }
            flushPendingStopIfNeeded()
        case "item/started":
            if isStaleEndedTurnEvent(p) { return }
            itemStarted(p["item"] as? [String: Any] ?? [:])
        case "item/completed":
            if isStaleEndedTurnEvent(p) { return }
            itemCompleted(p["item"] as? [String: Any] ?? [:])
        case "item/agentMessage/delta":
            if isStaleEndedTurnEvent(p) { return }
            guard let id = p["itemId"] as? String, let d = p["delta"] as? String, !d.isEmpty else { return }
            texts[id, default: ""] += d
            emit?(stream(["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": d]], id))
        case "item/reasoning/summaryTextDelta":
            if isStaleEndedTurnEvent(p) { return }
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
            let explicitTurnID = Self.nonEmptyString(t["id"]) ?? Self.nonEmptyString(p["turnId"])
            // 事件帶 turnId 且目前 turnID 非 nil 且兩者不同：舊輪遲到事件，只做舊輪去重，不動目前 turnID／starting、不發 result、不呼叫 next()。
            if let explicitTurnID, let activeTurnID = turnID, explicitTurnID != activeTurnID {
                markEndedTurn(explicitTurnID)
                if lastErrorResultTurnID == explicitTurnID {
                    errorResultEmittedForTurn = false
                    lastErrorResultTurnID = nil
                }
                return
            }
            // 同輪已由 error／systemError／finishInterruptedLocally 提早收尾（包含新輪已在 starting 中）：只清去重狀態，不重複發 result／不重複呼叫 next()。
            if let explicitTurnID, endedTurnIDs.contains(explicitTurnID) {
                if lastErrorResultTurnID == explicitTurnID {
                    errorResultEmittedForTurn = false
                    lastErrorResultTurnID = nil
                    lastErrorMessage = nil
                }
                return
            }
            let completedTurnID = explicitTurnID ?? turnID
            let status = t["status"] as? String ?? "completed"
            let isFailure = status != "completed" && status != "interrupted"
            let alreadyEmittedError = errorResultEmittedForTurn && isFailure
                && (lastErrorResultTurnID == nil || completedTurnID == nil || lastErrorResultTurnID == completedTurnID)
            if alreadyEmittedError {
                if let completedTurnID { markEndedTurn(completedTurnID) }
                turnID = nil
                pendingStop = false
                errorResultEmittedForTurn = false
                lastErrorResultTurnID = nil
                lastErrorMessage = nil
                clearTurnCaches()
                return
            }
            if let u = starting {
                starting = nil
                emit?(["type": "user", "isReplay": true, "uuid": u, "message": ["role": "user", "content": []]])
            }
            let rawError = Self.extractErrorMessage(turn: t, params: p) ?? lastErrorMessage
            let cleanError = Self.errorText(rawError)
            turnID = nil
            pendingStop = false
            if let completedTurnID { markEndedTurn(completedTurnID) }
            errorResultEmittedForTurn = false
            lastErrorResultTurnID = nil
            lastErrorMessage = nil
            clearTurnCaches()
            var out: [String: Any] = ["type": "result", "subtype": status == "completed" ? "success" : "error_during_execution",
                                      "is_error": status != "completed",
                                      "duration_ms": (t["durationMs"] as? NSNumber)?.intValue ?? Int(Date().timeIntervalSince(started) * 1000)]
            if isFailure { out["result"] = L("Codex：") + cleanError }
            if status == "interrupted" { emit?(["type": "user", "message": ["role": "user", "content": "[Request interrupted by user]"]]) }
            if isFailure { record(out) }
            emit?(out)
            next()
        case "error":
            // 會自己重試的錯誤：提示一下；不重試的直接結束本輪回復 idle（避免未附 turn/completed 時卡在工作中），
            // 並記錄已回報該輪錯誤，後續若再收到同一輪 turn/completed(failed) 則不重複發出。
            if p["willRetry"] as? Bool == true {
                emit?(["type": "system", "subtype": "api_retry", "attempt": 1])
                return
            }
            let explicitTurnID = Self.nonEmptyString(p["turnId"]) ?? Self.nonEmptyString((p["turn"] as? [String: Any])?["id"])
            if let explicitTurnID, let activeTurnID = turnID, explicitTurnID != activeTurnID {
                markEndedTurn(explicitTurnID)
                return
            }
            if let explicitTurnID, endedTurnIDs.contains(explicitTurnID) {
                return
            }
            let eventTurnID = explicitTurnID ?? turnID
            if errorResultEmittedForTurn
                && (lastErrorResultTurnID == nil || eventTurnID == nil || lastErrorResultTurnID == eventTurnID) {
                return
            }
            if turnID == nil, starting == nil, let eventTurnID, eventTurnID == lastEndedTurnID {
                return
            }
            if let u = starting {
                starting = nil
                emit?(["type": "user", "isReplay": true, "uuid": u, "message": ["role": "user", "content": []]])
            }
            let rawError = Self.extractErrorMessage(turn: nil, params: p)
            let msg = Self.errorText(rawError)
            turnID = nil
            pendingStop = false
            if let eventTurnID { markEndedTurn(eventTurnID) }
            errorResultEmittedForTurn = true
            lastErrorResultTurnID = eventTurnID
            lastErrorMessage = msg
            clearTurnCaches()
            let out: [String: Any] = ["type": "result", "subtype": "error_during_execution", "is_error": true,
                                      "result": L("Codex：") + msg,
                                      "duration_ms": Int(Date().timeIntervalSince(started) * 1000)]
            record(out)
            emit?(out)
            next()
        case "thread/status/changed":
            let statusDict = p["status"] as? [String: Any]
            let statusType = statusDict?["type"] as? String
            guard statusType == "systemError" else { break }
            let explicitTurnID = Self.nonEmptyString(p["turnId"])
                ?? Self.nonEmptyString((p["turn"] as? [String: Any])?["id"])
                ?? Self.nonEmptyString(statusDict?["turnId"])
            if let explicitTurnID, let activeTurnID = turnID, explicitTurnID != activeTurnID {
                markEndedTurn(explicitTurnID)
                return
            }
            if let explicitTurnID, endedTurnIDs.contains(explicitTurnID) {
                return
            }
            guard turnID != nil || starting != nil, !errorResultEmittedForTurn else { break }
            if let u = starting {
                starting = nil
                emit?(["type": "user", "isReplay": true, "uuid": u, "message": ["role": "user", "content": []]])
            }
            let ended = explicitTurnID ?? turnID
            turnID = nil
            pendingStop = false
            if let ended { markEndedTurn(ended) }
            errorResultEmittedForTurn = true
            lastErrorResultTurnID = ended
            let rawError = Self.extractErrorMessage(turn: nil, params: p) ?? lastErrorMessage
            let msg = Self.errorText(rawError)
            clearTurnCaches()
            let out: [String: Any] = ["type": "result", "subtype": "error_during_execution", "is_error": true,
                                      "result": L("Codex：") + msg,
                                      "duration_ms": Int(Date().timeIntervalSince(started) * 1000)]
            record(out)
            emit?(out)
            next()
        default:
            break
        }
    }

    static func extractErrorMessage(turn: [String: Any]?, params: [String: Any]) -> String? {
        let candidates: [String?] = [
            (turn?["error"] as? [String: Any])?["message"] as? String,
            (turn?["error"] as? [String: Any])?["additionalDetails"] as? String,
            turn?["error"] as? String,
            (params["error"] as? [String: Any])?["message"] as? String,
            (params["error"] as? [String: Any])?["additionalDetails"] as? String,
            params["error"] as? String,
            params["message"] as? String
        ]
        return candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }

    static func isNoActiveTurnError(_ err: [String: Any]) -> Bool {
        let raw = [
            err["message"] as? String,
            err["additionalDetails"] as? String,
            (err["data"] as? [String: Any])?["message"] as? String,
            err["data"] as? String
        ].compactMap { $0 }.joined(separator: " ")
        let parsed = errorText(err["message"] as? String)
        let lower = (raw + " " + parsed).lowercased()
        return ["no active turn", "unknown active turn", "not found", "no turn in progress", "no running turn"]
            .contains(where: lower.contains)
    }

    static func isUsageLimitError(errDict: [String: Any]?, message: String) -> Bool {
        if let info = (errDict?["codexErrorInfo"] as? String)?.lowercased(),
           info.contains("usagelimit") || info.contains("usagelimited") {
            return true
        }
        let lower = message.lowercased()
        return ["usage limit", "usage_limit", "quota exceeded", "insufficient_quota", "rate limit", "rate_limit"]
            .contains(where: lower.contains)
    }

    /// 錯誤訊息常常是一整段 JSON：挑出裡面的 message
    static func errorText(_ s: String?) -> String {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return L("發生錯誤") }
        if let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            if let m = (o["error"] as? [String: Any])?["message"] as? String, !m.isEmpty { return m }
            if let m = o["message"] as? String, !m.isEmpty { return m }
        }
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
            let sum = (it["summary"] as? [String])?.joined(separator: "\n\n") ?? ""
            let full = sum.isEmpty ? (texts[id] ?? "") : sum      // summary 是空陣列時 joined 是 ""（不是 nil），不能把串流收到的思考蓋掉
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
                // result 可能是 JSON null（NSNull）：JSONSerialization 對不是陣列／字典的頂層丟的是 ObjC 例外，try? 接不住，整個 App 會崩潰（實跑 exit 134）
                content = (it["result"]).flatMap { JSONSerialization.isValidJSONObject($0) ? (try? JSONSerialization.data(withJSONObject: $0)) : nil }.flatMap { String(data: $0, encoding: .utf8) }
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
        guard let d = Transcripts.redactedJSON(obj) else { return }
        Transcripts.append(d + Data([0x0a]), to: transcriptURL)      // 寫不進去會記進事件紀錄（Transcripts.append）
    }
}
