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
        ("gemini-4-hydrogen-high", "Gemini 4 Hydrogen"),
        ("gemini-4-argon-high", "Gemini 4 Argon"),
        ("claude-opus-5-5-high", "Claude Opus 5.5"),
        ("claude-sonnet-5-5-high", "Claude Sonnet 5.5"),
        ("gemini-3.8-flash-high", "Gemini 3.8 Flash"), // 舊聊天室仍可顯示
        ("gemini-pro-orchestrator-g1-pro", "Orchestrator (Argon)"),
        ("gpt-oss-120b-medium", "GPT-OSS 120B"),
    ]
    /// 固定模型名稱本身已決定強度，不能套用尾碼拉桿。
    static let fixedModels: Set<String> = ["gemini-pro-orchestrator-g1-pro", "gpt-oss-120b-medium"]
    static func name(_ model: String) -> String { models.first { base($0.id) == base(model) }?.name ?? model }
    /// 一般 agy 模型可用的強度；Hydrogen 另外支援 xhigh。
    static let levels = ["low", "medium", "high"]
    static func levels(for model: String) -> [String] {
        if fixedModels.contains(model) { return [] }
        return base(model) == "gemini-4-hydrogen" ? levels + ["xhigh"] : levels
    }
    static func level(_ model: String) -> String? {
        if fixedModels.contains(model) { return nil }
        if model.hasSuffix("gemini-4-hydrogen-xhigh") { return "xhigh" }
        return levels.first { model.hasSuffix("-" + $0) }
    }
    static func base(_ model: String) -> String { level(model).map { String(model.dropLast($0.count + 1)) } ?? model }
    /// 實際要開的模型：拉桿選了支援的強度就換尾巴；不支援的值照選單上的模型開。
    static func resolve(_ model: String, effort: String?) -> String {
        guard let e = effort, levels(for: model).contains(e), level(model) != nil else { return model }
        return base(model) + "-" + e
    }

    /// 舊存檔中的 agy Flash 模型遷移到 Hydrogen；只接受帶 agy 引擎前綴的值。
    static func hydrogenModel(forLegacy model: String) -> String? {
        let prefix = "agy:"
        guard model.hasPrefix(prefix) else { return nil }
        let id = String(model.dropFirst(prefix.count))
        let oldBase = "gemini-3.8-flash"
        guard id == oldBase || id.hasPrefix(oldBase + "-") else { return nil }
        let level: String
        switch id {
        case oldBase + "-low": level = "low"
        case oldBase + "-medium": level = "medium"
        case oldBase + "-high": level = "high"
        default: level = "high"
        }
        return prefix + "gemini-4-hydrogen-" + level
    }

    /// agy 功能有沒有打開（設定頁；預設開）（提醒只告知、不擋功能，見 AgyNotice.swift）。沒打開時：模型清單不列 agy、不查 agy 用量、不用 agy 猜下一句、看板不自動叫 agy
    static var enabled: Bool { Prefs.shared.agyEnabled }

    /// 測試實例提供的假 agy；沒提供時測試模式不可退回使用正式安裝。
    private static var configuredTestExecutable: String? {
        let args = CommandLine.arguments
        guard args.contains("--state-dir"), let i = args.firstIndex(of: "--agy-bin"), i + 1 < args.count,
              !args[i + 1].isEmpty, FileManager.default.isExecutableFile(atPath: args[i + 1]) else { return nil }
        return args[i + 1]
    }

    static var isTestInstance: Bool { CommandLine.arguments.contains("--state-dir") }
    static var canLaunchInCurrentInstance: Bool {
        !isTestInstance || testMode != nil || configuredTestExecutable != nil
    }

    /// 本機有沒有裝 agy；測試實例只把明確提供的假執行檔當成已安裝。
    static var installed: Bool {
        if isTestInstance { return canLaunchInCurrentInstance }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"].contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// agy 的位置：裝在 ~/.local/bin（官方安裝方式），登入 shell 的 PATH 不一定有
    static var executable: String {
        // 測試用的假 agy（只有帶 --state-dir 才認）
        let a = CommandLine.arguments
        if testMode != nil {
            // 內建假程式建立失敗時也不能退回正式 agy，以免測試旗標意外連網或讀取正式登入資料。
            return testExecutable ?? "/__codenv_test_agy_unavailable__"
        }
        if a.contains("--state-dir") {
            return configuredTestExecutable ?? "/__codenv_test_agy_unavailable__"
        }
        let p = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/agy").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : "agy"
    }

    /// 可控的內建假 agy 僅在 --state-dir 下啟用，避免測試探針碰到正式 agy 或網路。
    static var testMode: String? {
        let args = CommandLine.arguments
        guard args.contains("--state-dir"), let i = args.firstIndex(of: "--agy-test-mode"), i + 1 < args.count,
              ["busy", "ordinary-error", "retry-interrupt"].contains(args[i + 1]) else { return nil }
        return args[i + 1]
    }

    private static var testStateDirectory: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--state-dir"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true).standardizedFileURL
    }

    private static func isolatedTestPath(_ flag: String) -> URL? {
        let args = CommandLine.arguments
        guard args.contains("--state-dir"), let i = args.firstIndex(of: flag), i + 1 < args.count,
              let root = testStateDirectory else { return nil }
        let url = URL(fileURLWithPath: args[i + 1]).standardizedFileURL
        return url.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/") ? url : nil
    }

    private static var testProbeURL: URL? { isolatedTestPath("--agy-test-probe") }
    private static var testReleaseURL: URL? { isolatedTestPath("--agy-test-release") }
    private static let testProbeLock = NSLock()

    private static var testExecutable: String? {
        guard testMode != nil, let root = testStateDirectory else { return nil }
        let url = root.appendingPathComponent("agy-test-driver.py")
        let script = #"""
        #!/usr/bin/python3
        import json, os, sys, time
        mode = os.environ.get("CODENV_AGY_TEST_MODE", "ordinary-error")
        probe = os.environ.get("CODENV_AGY_TEST_PROBE", "")
        release = os.environ.get("CODENV_AGY_TEST_RELEASE", "")
        def emit(value):
            sys.stdout.write(json.dumps(value, ensure_ascii=False) + "\n")
            sys.stdout.flush()
        def signal(name):
            if probe:
                with open(probe + "." + name, "w", encoding="utf-8") as f: f.write(str(time.time()))
        def text_of(event):
            message = event.get("message", {})
            content = message.get("content", "")
            if isinstance(content, list):
                return "\n".join(str(block.get("text", "")) for block in content if isinstance(block, dict))
            return str(content)
        def result(ok, error=None):
            value = {"event":"result", "result":{"status":"SUCCESS" if ok else "ERROR"}}
            if error: value["result"]["error"] = error
            emit(value)
        def reply(idx, text):
            emit({"event":"step_update", "step_update":{"step_type":"agent_response", "state":"DONE", "step_index":idx, "text_delta":"假 agy 回覆：" + text}})
            result(True)
        emit({"event":"init", "conversation_id":"codenv-test-agy", "init":{"cwd":os.getcwd()}})
        turn = 0
        idx = 1
        for line in sys.stdin:
            try: event = json.loads(line)
            except Exception: continue
            if event.get("event") != "user": continue
            turn += 1
            text = text_of(event)
            emit({"event":"step_update", "step_update":{"step_type":"user_input", "state":"DONE", "step_index":idx}})
            if mode == "busy" and turn == 1:
                signal("busy")
                while release and not os.path.exists(release): time.sleep(0.05)
                reply(idx, text)
            elif mode == "ordinary-error" and turn == 1:
                signal("ordinary-error-window")
                time.sleep(0.5)
                result(False, "simulated ordinary request error")
            elif mode == "retry-interrupt" and turn == 1:
                result(False, "overloaded")
                time.sleep(0.15)
                signal("retry-window")
            else:
                reply(idx, text)
            idx += 1
        """#
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url.path
        } catch { return nil }
    }

    static func testEnvironment() -> [String: String] {
        guard let mode = testMode, let root = testStateDirectory else { return [:] }
        return ["CODENV_AGY_TEST_MODE": mode,
                "CODENV_AGY_TEST_PROBE": testProbeURL?.path ?? root.appendingPathComponent("agy-test-probe.jsonl").path,
                "CODENV_AGY_TEST_RELEASE": testReleaseURL?.path ?? root.appendingPathComponent("agy-test-release").path]
    }

    static func recordTestProbe(_ row: [String: Any]) {
        guard CommandLine.arguments.contains("--state-dir"), let url = testProbeURL,
              let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        testProbeLock.lock()
        defer { testProbeLock.unlock() }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data([0x0a]))
    }

    private func testSnapshot(_ event: String, extras: [String: Any] = [:]) {
        guard Self.testMode != nil else { return }
        func messageText(_ msg: [String: Any]) -> String {
            if let text = msg["content"] as? String { return text }
            return ((msg["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        let queue = waiting.map { ["uuid": $0.uuid ?? "", "text": messageText($0.msg), "retry": $0.isRetry] as [String: Any] }
        var row: [String: Any] = ["event": event, "conversation": session.uuidString.lowercased(),
                                  "current": current.map { messageText($0.msg) } ?? "",
                                  "waiting": queue, "retryPending": retryAwaitingSend,
                                  "requiresRestart": requiresRestart]
        for (key, value) in extras { row[key] = value }
        Self.recordTestProbe(row)
    }

    func testProbeEvent(_ event: String) { testSnapshot(event) }

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
    private struct QueuedUser { let uuid: String?; let msg: [String: Any]; let retryKey: String; let isRetry: Bool }
    private var waiting: [QueuedUser] = []
    private var texts: [Int: String] = [:]        // step → 目前累積的文字
    private var before: [Int: String] = [:]       // 改檔前的內容（畫差異用）
    private var started = Date()
    private var deniedHint = false
    /// 部分 agy 會先送 error/error_event，再以非零結束碼退出；保留已遮蔽的串流錯誤，
    /// 避免 termination handler 的 send --wait 結果只剩程序結束碼或 stderr。
    private var lastStreamError: String?
    /// 非 fatal 的 error 事件已為當前這輪（含尚在排隊的訊息）送出 is_error result，
    /// 避免程序緊接著非零退出時 processExitFailure 再度為同一輪送出重複錯誤。
    private var errorResultEmittedForTurn = false
    /// 非 fatal error 送出 is_error result 當下的 waiting.count（該 result 代表這批排隊訊息）；
    /// 只有退出時 waiting.count 未增加（<= 此值）才抑制第二個失敗 result，避免新排入的訊息漏報。
    private var errorReportedWaitingCount = 0
    private var toolIDs: [String: String] = [:]   // 這一輪：agy 的工具名稱 → 最後一張卡片的 id（被拒時標回去）
    private var deniedIDs: Set<String> = []
    private(set) var requiresRestart = false
    private let model: String
    private var current: QueuedUser?               // 這一輪 agy 正在回答的那則（讀進了、還沒做完）
    private var retryAttempts: [String: Int] = [:] // 同時排隊時，各訊息分開計次
    private var retryRequest: (key: String, event: [String: Any], attempt: Int, delay: TimeInterval)?
    private(set) var retryAwaitingSend = false
    /// 上一個 agy 被 ⌃ C／停止 關掉時正在做的那幾則：下一則送出時附一句請它忽略（agy 用 --conversation 接回，取消的那則還在它的歷史裡）
    var cancelled: [String] = []

    init(session: UUID, model: String) {
        self.session = session
        self.model = model
        transcriptURL = Self.transcript(for: session)
    }

    /// 程序在收到本輪完成事件前結束時，轉成聊天裡看得到的失敗結果。
    var hasIncompleteTurn: Bool { current != nil || !waiting.isEmpty }

    private func clearAfterExitOrProtocolFailure() {
        errorResultEmittedForTurn = false
        errorReportedWaitingCount = 0
        lastStreamError = nil
        requiresRestart = true
        retryAwaitingSend = false
        current = nil
        waiting.removeAll()
        texts.removeAll(); before.removeAll(); toolIDs.removeAll(); deniedIDs.removeAll()
    }

    func processExitFailure(code: Int32, stderr: String) -> [String: Any]? {
        guard hasIncompleteTurn else { return nil }
        if errorResultEmittedForTurn && waiting.count <= errorReportedWaitingCount {
            clearAfterExitOrProtocolFailure()
            return nil
        }
        let stderrDetail = KeyScan.redact(stderr.trimmingCharacters(in: .whitespacesAndNewlines), strongOnly: true)
        let details = [lastStreamError, stderrDetail].compactMap { $0 }.filter { !$0.isEmpty }
        // 串流錯誤也可能再次出現在 stderr；移除完全重複的段落，保留不同來源的診斷。
        var uniqueDetails: [String] = []
        for detail in details where !uniqueDetails.contains(detail) { uniqueDetails.append(detail) }
        let detail = uniqueDetails.joined(separator: "；")
        let lower = detail.lowercased()
        let quota = ["insufficient_quota", "quota exceeded", "resource exhausted", "billing", "usage limit", "rate limit", "429"].contains { lower.contains($0) }
        var message: String
        if quota {
            message = L("agy 額度或服務限制（程序結束碼 \(code)）")
        } else {
            message = L("agy 程序在本輪完成前結束（程序結束碼 \(code)）")
        }
        if !detail.isEmpty { message += "：" + String(detail.suffix(900)) }
        clearAfterExitOrProtocolFailure()
        let result: [String: Any] = ["type": "result", "subtype": "error_during_execution", "is_error": true, "result": message]
        record(result)
        return result
    }

    // MARK: 送進去

    /// 工作台要寫給 claude 的東西 → 要寫給 agy 的（nil＝agy 沒有這個功能，不送）
    func outgoing(_ obj: [String: Any]) -> [String: Any]? {
        guard obj["type"] as? String == "user", let msg = obj["message"] as? [String: Any] else { return nil }
        let isRetry = obj["agyRetry"] as? Bool == true
        if isRetry { retryAwaitingSend = false }
        // /effort 之類的斜線指令是給 Claude 的；/compact（＋可接一句話）agy 自己也有，照送
        let text = (msg["content"] as? String) ?? ((msg["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n"))
        // 內部送的沒有 uuid；使用者打的一定有。使用者打的 / 開頭路徑或 /help 不能吃掉（吃掉了狀態會一直是工作中）
        if obj["uuid"] == nil, text.hasPrefix("/"), text != "/compact", !text.hasPrefix("/compact ") { return nil }
        let uuid = (obj["uuid"] as? String)?.lowercased()
        let retryKey = (obj["retryKey"] as? String) ?? uuid ?? UUID().uuidString
        waiting.append(QueuedUser(uuid: uuid, msg: msg, retryKey: retryKey, isRetry: isRetry))
        testSnapshot(isRetry ? "retry_queued" : "queued", extras: ["uuid": uuid ?? "", "text": (msg["content"] as? String) ?? ""])
        var send = msg
        if let blocks = msg["content"] as? [[String: Any]] { send["content"] = blocks.map(Self.textOnly) }
        // /compact 要在開頭 agy 才認得：附註留到下一則一般訊息再附
        let isCompact = text == "/compact" || text.hasPrefix("/compact ")
        if !isRetry, !cancelled.isEmpty, !isCompact {
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
        guard let m = current?.msg ?? waiting.first?.msg else { return nil }
        if let t = m["content"] as? String { return t }
        let t = (m["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        return t.isEmpty ? "（一張圖片）" : t
    }

    func pendingForLidInterrupt() -> [LidQueuedMessage] {
        ([current].compactMap { $0 } + waiting).compactMap { item in
            guard let uuid = item.uuid?.lowercased(), !uuid.isEmpty else { return nil }
            return LidQueuedMessage(id: uuid, text: LidQueuedMessage.text(in: item.msg))
        }
    }

    func clearForLidInterrupt() {
        waiting.removeAll()
        current = nil
        errorResultEmittedForTurn = false
        errorReportedWaitingCount = 0
        cancelRetryWait()
    }

    /// agy 的串流輸入只收文字區塊（送圖片會整輪報錯）：圖片存成檔，換成一句話請它用 read_file 打開（實測看得到圖）
    static func textOnly(_ b: [String: Any]) -> [String: Any] {
        guard b["type"] as? String == "image", let src = b["source"] as? [String: Any],
              let s = src["data"] as? String, let d = Data(base64Encoded: s) else { return b }
        let ext = (src["media_type"] as? String).map { $0 == "image/jpeg" ? "jpg" : String($0.split(separator: "/").last ?? "png") } ?? "png"
        let url = imageDir().appendingPathComponent("\(UUID().uuidString).\(ext)")
        guard ImageCache.write(d, to: url) else { return ["type": "text", "text": "（使用者附了一張圖片，但存檔失敗，看不到）"] }
        return ["type": "text", "text": "（使用者附了一張圖片：\(url.path) ，請用 read_file 打開來看）"]
    }

    /// 存圖的資料夾：~/Library/Caches/codenv/agy-images（0700、檔案 0600）；第一次用時順便清掉 7 天前的
    private static func imageDir() -> URL { ImageCache.directory("agy-images") }

    // MARK: 讀出來

    /// agy 的一行事件 → 給畫面的（Claude 格式）
    func incoming(_ o: [String: Any]) -> [[String: Any]] {
        switch (o["event"] as? String) ?? (o["type"] as? String) {
        case "init":
            if let c = o["conversation_id"] as? String { Self.setConversation(c, for: session) }
            let i = o["init"] as? [String: Any] ?? [:]
            return [["type": "system", "subtype": "init", "model": model, "cwd": i["cwd"] ?? "", "session_id": session.uuidString.lowercased()]]
        case "step_update":
            return step(o["step_update"] as? [String: Any] ?? [:])
        case "result":
            // result 已結束上一輪；下個回合不應沿用先前的串流錯誤。
            lastStreamError = nil
            errorResultEmittedForTurn = false
            errorReportedWaitingCount = 0
            let r = o["result"] as? [String: Any] ?? [:]
            let ok = r["status"] as? String == "SUCCESS"
            let error = (r["error"] as? String) ?? L("Gemini 回報錯誤")
            // Agy may already have run external tools before returning an error; do not replay a message with tool side effects.
            if !ok, toolIDs.isEmpty, let current, let plan = RetryPolicy.plan(error: error, completedRetries: retryAttempts[current.retryKey, default: 0]) {
                retryAttempts[current.retryKey] = plan.attempt
                // 重送已在 UI 顯示過的同一則訊息；agy 的 user_input 回應不會再次建立泡泡或改變 transcript 順序。
                var retryEvent: [String: Any] = ["type": "user", "agyRetry": true, "retryKey": current.retryKey, "message": current.msg]
                if let uuid = current.uuid { retryEvent["uuid"] = uuid }
                retryRequest = (current.retryKey, retryEvent, plan.attempt, plan.delay)
                retryAwaitingSend = true
                testSnapshot("retry_waiting", extras: ["attempt": plan.attempt, "delay": plan.delay, "text": (current.msg["content"] as? String) ?? ""])
                texts.removeAll(); before.removeAll(); toolIDs.removeAll(); deniedIDs.removeAll()
                return [RetryPolicy.event(attempt: plan.attempt, delay: plan.delay)]
            }
            if let current { retryAttempts.removeValue(forKey: current.retryKey) }
            current = nil
            var out: [String: Any] = ["type": "result", "subtype": ok ? "success" : "error_during_execution", "is_error": !ok,
                                      "duration_ms": Int(Date().timeIntervalSince(started) * 1000)]   // agy 自己算的會把排隊等待也算進去
            if !ok { out["result"] = L("Gemini：") + error }
            // 有時候被拒的工具步驟照樣回「完成」，只在結果裡列出被拒的動作：卡片標回「沒有權限」
            var notes: [[String: Any]] = []
            for a in (r["denied_actions"] as? [[String: Any]] ?? []).compactMap({ $0["action"] as? String }) {
                guard let id = toolIDs[a] ?? toolIDs[a == "command" ? "run_command" : a], !deniedIDs.contains(id) else { continue }
                notes += denied(id, a)
            }
            texts.removeAll(); before.removeAll(); toolIDs.removeAll(); deniedIDs.removeAll()
            if !ok { record(out) }
            testSnapshot(ok ? "turn_success" : "turn_error", extras: ["message": error])
            return notes + [out]
        case "error", "error_event", "fatal_error":
            let raw = KeyScan.redact(Self.errorMessage(o) ?? L("agy 回報未附錯誤內容"), strongOnly: true)
            lastStreamError = raw
            let fatal = (o["event"] as? String) == "fatal_error" || (o["type"] as? String) == "fatal_error"
            requiresRestart = fatal
            current = nil
            if fatal { waiting.removeAll() }
            errorResultEmittedForTurn = !fatal
            errorReportedWaitingCount = fatal ? 0 : waiting.count
            texts.removeAll(); before.removeAll(); toolIDs.removeAll(); deniedIDs.removeAll()
            let result: [String: Any] = ["type": "result", "subtype": "error_during_execution", "is_error": true,
                                         "result": L("agy 錯誤：") + raw]
            record(result)
            testSnapshot(fatal ? "fatal_error" : "error_event", extras: ["message": raw])
            return [result]
        default:
            return []
        }
    }

    private static func errorMessage(_ object: [String: Any]) -> String? {
        if let text = object["error"] as? String, !text.isEmpty { return text }
        if let error = object["error"] as? [String: Any] {
            if let text = error["message"] as? String, !text.isEmpty { return text }
            if let text = error["details"] as? String, !text.isEmpty { return text }
        }
        if let text = object["message"] as? String, !text.isEmpty { return text }
        return nil
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
            lastStreamError = nil
            errorResultEmittedForTurn = false
            errorReportedWaitingCount = 0
            if !w.isRetry {
                record(["type": "user", "message": w.msg])
                retryAttempts[w.retryKey] = 0
            }
            current = w
            let processedText = (w.msg["content"] as? String)
                ?? ((w.msg["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
            testSnapshot("processed", extras: ["uuid": w.uuid ?? "", "text": processedText, "retry": w.isRetry])
            if w.isRetry { return [] }
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
                if ["edit_file", "write_file", "replace_file_content", "multi_replace_file_content"].contains(raw), let path { before[idx] = Self.peek(path) ?? "" }
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
            // read_file：工具沒回內容時才自己補（PDF 要另外抽文字，peek 讀不出來）；工具有回的（只讀某幾行）照它的，不拿整份檔案蓋掉
            if raw == "read_file", err == nil, content.isEmpty, let path {
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

    /// Retry is pulled by ChatSession after the notice event is delivered, keeping delay cancellation there.
    func takeRetryRequest() -> (key: String, event: [String: Any], attempt: Int, delay: TimeInterval)? {
        defer { retryRequest = nil }
        return retryRequest
    }

    func cancelRetryWait() { retryAwaitingSend = false; retryRequest = nil }

    func protocolFailure(_ message: String) -> [String: Any] {
        clearAfterExitOrProtocolFailure()
        let result: [String: Any] = ["type": "result", "subtype": "error_during_execution", "is_error": true,
                                     "result": L("agy 串流協定錯誤，程序需要重啟：") + message]
        record(result)
        return result
    }

    /// Fake transient result exercises agy retry scheduling without launching its CLI or writing a transcript.
    static func runRetrySelfTest(out path: String) -> Bool {
        let id = "fake-agy-message"
        let message: [String: Any] = ["role": "user", "content": "retry this request"]
        let bridge = AgyBridge(session: UUID(), model: "fake")
        bridge.current = QueuedUser(uuid: id, msg: message, retryKey: id, isRetry: false)
        bridge.retryAttempts[id] = 0
        let failed = bridge.incoming(["event": "result", "result": ["status": "ERROR", "error": "overloaded"]])
        let retry = bridge.takeRetryRequest()
        let wire = retry.flatMap { bridge.outgoing($0.event) }
        let queuedRetry = bridge.waiting.first?.isRetry == true && bridge.waiting.first?.retryKey == id
        _ = bridge.outgoing(["type": "user", "uuid": "later-message", "message": ["role": "user", "content": "later message"]])
        let retryBubbleSuppressed = bridge.step(["step_type": "user_input", "state": "DONE", "step_index": 99]).isEmpty
        let retryWasFirst = (bridge.current?.msg["content"] as? String) == "retry this request"
            && bridge.waiting.first?.uuid == "later-message"
        let succeeded = bridge.incoming(["event": "result", "result": ["status": "SUCCESS"]])
        _ = bridge.step(["step_type": "user_input", "state": "DONE", "step_index": 100])
        let laterWasSecond = (bridge.current?.msg["content"] as? String) == "later message"

        let ordinary = AgyBridge(session: UUID(), model: "fake")
        ordinary.current = QueuedUser(uuid: "ordinary-message", msg: message, retryKey: "ordinary-message", isRetry: false)
        _ = ordinary.outgoing(["type": "user", "uuid": "waiting-message", "message": ["role": "user", "content": "waiting message"]])
        _ = ordinary.incoming(["event": "result", "result": ["status": "ERROR", "error": "invalid request"]])
        let ordinaryErrorKeepsProcessAndQueue = !ordinary.requiresRestart && ordinary.current == nil && ordinary.waiting.count == 1
        let values: [(String, Bool)] = [
            ("fake_overloaded_result_retries_without_duplicate_bubble", failed.first?["subtype"] as? String == "api_retry" && queuedRetry && retryBubbleSuppressed),
            ("retry_message_stays_ahead_of_new_user_message", retryWasFirst && laterWasSecond),
            ("ordinary_error_preserves_process_and_waiting_messages", ordinaryErrorKeepsProcessAndQueue),
            ("agy_retry_uses_one_second_delay_and_finishes_successfully", retry?.attempt == 1 && retry?.delay == 1 && succeeded.first?["subtype"] as? String == "success"),
            ("retry_is_sent_through_existing_agy_input", wire?["event"] as? String == "user")
        ]
        let text = values.map { "\($0.0)=\($0.1)" }.joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        return values.allSatisfy(\.1)
    }

    /// 工具被拒：卡片標成「沒有權限」，第一次再加一行說明怎麼放行
    private func denied(_ id: String, _ raw: String) -> [[String: Any]] {
        deniedIDs.insert(id)
        var out: [[String: Any]] = [["type": "system", "subtype": "permission_denied", "tool_use_id": id, "tool_name": raw]]
        if !deniedHint {
            deniedHint = true
            out.append(["type": "system", "subtype": "permission_denied",
                        "tool_name": L("\(raw)。agy 不能跳出詢問：要讓它改檔，按 ⇧ Tab 換成「改檔不問」；連指令也要跑，換成「自動」（下一則訊息生效）")])
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
            if done { input["content"] = p["Content"] as? String ?? p["content"] as? String ?? p["CodeContent"] as? String ?? (path.flatMap { Self.peek($0) }) ?? "" }
        case "edit_file", "replace_file_content", "multi_replace_file_content":
            name = "Edit"; input = ["file_path": path ?? ""]
            if done, let path { input["old_string"] = before[idx] ?? ""; input["new_string"] = Self.peek(path) ?? "" }
        case "list_dir":
            name = "LS"; input = ["path": path ?? p["DirectoryPath"] as? String ?? ""]
        case "grep_search":
            name = "Grep"; input = ["pattern": p["Query"] as? String ?? "", "path": p["SearchPath"] as? String ?? ""]
        case "search_web":
            name = "WebSearch"; input = ["query": p["query"] as? String ?? p["Query"] as? String ?? ""]
        case "read_url_content":
            name = "WebFetch"; input = ["url": p["url"] as? String ?? p["Url"] as? String ?? ""]
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
        guard let d = Transcripts.redactedJSON(obj) else { return }
        Transcripts.append(d + Data([0x0a]), to: transcriptURL)      // 寫不進去會記進事件紀錄（Transcripts.append）
    }
}
