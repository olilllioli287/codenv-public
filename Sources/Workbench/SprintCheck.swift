import Foundation
import CryptoKit

// 額度衝刺的「每輪結束檢查」：衝刺聊天室回到待命時，看它最後一則訊息是不是停在一半。
// 想法參考 Nanako0129/stingray（MIT），只參考做法，沒有安裝；判斷只用正在執行的本機模型或指定的 agy Flash low：
//   no_action      可以做事卻什麼都沒做就停
//   broken_promise 說了「我現在去改／去跑」，這一輪卻沒有對應的工具呼叫
//   unwatched      說「我會盯著／等回報」，但背景什麼都沒在跑
// 判斷分兩層：本機計數（背景工作、等回覆的訊息、看板進行中的步驟，不靠模型）＋便宜模型判斷最後一則訊息的種類。
// 模型：本機 Qwen3.6（不開思考）正在跑就用它，沒開就用 agy 的 Gemini Flash low；兩個都不行就放行（只記紀錄）。不用 Opus、Fable。
// 送給模型之前先遮掉看起來像金鑰／token 的字串。

enum SprintCheck {
    static let qwen = "mlx-community/Qwen3.6-35B-A3B-4bit"
    static let kinds = ["ok", "waiting_user", "done", "no_action", "broken_promise", "unwatched"]
    static let halfDone: Set<String> = ["no_action", "broken_promise", "unwatched"]
    static let pendingReplyLifetime: TimeInterval = 30 * 60
    /// 提醒訊息的標記（泡泡上看得出是 codenv 送的）
    static let marker = "〔codenv 衝刺檢查〕"

    struct Verdict: Equatable { var kind: String; var score: Double; var backend: String }

    enum ReminderDecision: Equatable { case ignore, remind, stuck, throttled }

    /// 本機計數：全部是 0 才可以提醒
    struct Counts: Equatable {
        var background = 0      // 這段的背景 Bash／子代理還在跑幾個
        var pendingReplies = 0  // 它送出、還沒收到回覆的跨聊天室訊息
        var doingSteps = 0      // 它在看板上進行中的步驟
        var total: Int { background + pendingReplies + doingSteps }
        var text: String { "bg=\(background) wait=\(pendingReplies) doing=\(doingSteps)" }
    }

    static func reminderDecision(kind: String, counts: Counts, recentReminders: Int, consecutiveReminders: Int) -> ReminderDecision {
        guard halfDone.contains(kind), counts.total == 0 else { return .ignore }
        if consecutiveReminders >= 2 { return .stuck }
        if recentReminders >= 3 { return .throttled }
        return .remind
    }

    static func reminderDecision(verdict: Verdict?, counts: Counts, recentReminders: Int, consecutiveReminders: Int) -> ReminderDecision {
        guard let verdict else { return .ignore }
        return reminderDecision(kind: verdict.kind, counts: counts,
                                recentReminders: recentReminders,
                                consecutiveReminders: consecutiveReminders)
    }

    static func shouldMarkRoundChecked(verdict: Verdict?, counts: Counts, decision: ReminderDecision, reminderSent: Bool) -> Bool {
        guard let verdict else { return true }
        if halfDone.contains(verdict.kind), counts.total > 0 { return false }
        switch decision {
        case .remind: return reminderSent
        case .throttled: return false
        case .ignore, .stuck: return true
        }
    }

    static func didAct(tools: [String], userMessage: String) -> Bool {
        if !tools.isEmpty { return true }
        let internalMarkers = [marker, "【額度衝刺開始】", "【額度衝刺：", "【額度衝刺】"]
        return !userMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !internalMarkers.contains(where: userMessage.contains)
    }

    static func shouldNudgeIdle(checkedRound: String?, nudgeRound: String?, counts: Counts) -> Bool {
        checkedRound != nil && checkedRound == nudgeRound && counts.total == 0
    }

    static func pendingReplyCount(messages: [CollabMessage], localNames: Set<String>, now: Date, maxAge: TimeInterval = pendingReplyLifetime) -> Int {
        let relevant = messages.compactMap { message -> (time: Date, peer: String, outgoing: Bool)? in
            let fromLocal = localNames.contains(message.from)
            let toLocal = localNames.contains(message.to)
            guard fromLocal != toLocal else { return nil }
            return (message.time, fromLocal ? message.to : message.from, fromLocal)
        }.sorted { $0.time < $1.time }

        var unansweredSends: [String: [Date]] = [:]
        var unansweredReceives: [String: Int] = [:]
        for message in relevant {
            if message.outgoing {
                if (unansweredReceives[message.peer] ?? 0) > 0 {
                    unansweredReceives[message.peer, default: 0] -= 1
                } else {
                    unansweredSends[message.peer, default: []].append(message.time)
                }
            } else {
                if let i = unansweredSends[message.peer]?.firstIndex(where: { $0 <= message.time }) {
                    unansweredSends[message.peer]?.remove(at: i)
                } else {
                    unansweredReceives[message.peer, default: 0] += 1
                }
            }
        }
        return unansweredSends.values.flatMap { $0 }.filter { $0 <= now && now.timeIntervalSince($0) < maxAge }.count
    }

    static func doingStepCount(_ steps: [CollabStep], ownerNames: Set<String>) -> Int {
        steps.filter { $0.state == "doing" && ownerNames.contains($0.owner ?? "") }.count
    }

    static func reminderText(kind: String, resetAt: Date?, now: Date = Date()) -> String {
        let marker = Self.marker
        if let resetAt, resetAt.timeIntervalSince(now) <= 15 * 60, resetAt > now {
            return "\(marker) 該收尾了：寫總結並 sprint done。"
        }
        return "\(marker) 這一輪看起來停在一半（原因：\(kind)）。請擇一：把說好的事做完；開背景工作並等它回報；或寫一句卡在什麼決定（用 codenv-todo sprint note）。"
    }

    static func reasonLabel(_ kind: String) -> String {
        switch kind {
        case "no_action": return L("沒有採取行動")
        case "broken_promise": return L("答應要做但沒有執行")
        case "unwatched": return L("承諾監看但沒有背景工作")
        default: return kind
        }
    }

    // MARK: 遮掉金鑰

    private static let secretPatterns: [NSRegularExpression] = [
        #"sk-[A-Za-z0-9_\-]{16,}"#, #"gh[pousr]_[A-Za-z0-9]{20,}"#, #"github_pat_[A-Za-z0-9_]{20,}"#,
        #"AIza[0-9A-Za-z_\-]{30,}"#, #"AKIA[0-9A-Z]{16}"#, #"xox[abprs]-[A-Za-z0-9\-]{10,}"#,
        #"eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{5,}"#,
        #"(?i)(bearer|token|api[_-]?key|secret|password|passwd|密碼|金鑰)\s*[:=：]\s*\S{6,}"#,
        #"[A-Za-z0-9+/_\-]{40,}={0,2}"#,   // 一長串沒有空白的亂碼（base64、十六進位 token）
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func redact(_ s: String) -> String {
        var out = s
        for re in secretPatterns {
            out = re.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: (out as NSString).length), withTemplate: "[已遮蔽]")
        }
        return out
    }

    // MARK: 提示與解析

    static func prompt(last: String, tools: [String]) -> String {
        let used = tools.isEmpty ? "（這一輪沒有呼叫任何工具）" : "這一輪呼叫了工具：" + Dictionary(grouping: tools, by: { $0 }).map { "\($0.key)×\($0.value.count)" }.sorted().joined(separator: "、")
        return """
        你是檢查員。下面是一個 AI 助手「這一輪最後一則訊息」，這一輪已經結束、助手回到待命。判斷它是不是停在一半。只能選一種：
        - ok：正常收尾，或這一輪確實做了事、現在只是回報結果／交代下一步。
        - waiting_user：在等使用者回答、決定或確認。
        - done：整件事已經做完、已交出最後總結（含 sprint done）。
        - no_action：可以繼續做事卻什麼都沒做就停（只回「收到」「了解」「待命」，或只列計畫不動手）。
        - broken_promise：說了「我現在去改／去跑／去查」這類要立刻做的事，但這一輪的工具呼叫裡沒有對應的動作。
        - unwatched：說了「我會盯著／等它跑完／等回報／持續監看」這類要持續盯著的承諾，卻沒有說明靠什麼盯。
        注意：只是提到「盯著」「等」這些詞但不是在承諾（例如描述別人、引用、解釋概念、否定句）要選 ok。已有工具呼叫證明它在做事時，通常選 ok。
        只輸出一行 JSON，不要解釋：{"kind":"<上面其中一個>","score":<0到1，你有多確定>}

        \(used)

        最後一則訊息：
        \(redact(String(last.suffix(2500))))
        """
    }

    static func parse(_ raw: String) -> (kind: String, score: Double)? {
        // 模型可能先講一小段、或把 JSON 包在 ``` 裡：抓第一個 { 到最後一個 }
        guard let a = raw.firstIndex(of: "{"), let b = raw.lastIndex(of: "}"), a < b,
              let o = try? JSONSerialization.jsonObject(with: Data(raw[a...b].utf8)) as? [String: Any],
              let k = (o["kind"] as? String)?.lowercased().trimmingCharacters(in: .whitespaces), kinds.contains(k) else { return nil }
        let sc = (o["score"] as? Double) ?? (o["score"] as? Int).map(Double.init) ?? 0.5
        return (k, min(1, max(0, sc)))
    }

    // MARK: 判斷（本機優先，沒開用 agy Flash low；全都不行就 done(nil, 原因)）

    /// done 在主執行緒
    static func judge(last: String, tools: [String], done: @escaping (Verdict?, String) -> Void) {
        judge(last: last, tools: tools, fakeKind: nil, done: done)
    }

    private static func judge(last: String, tools: [String], fakeKind: String?, done: @escaping (Verdict?, String) -> Void) {
        let text = prompt(last: last, tools: tools)
        // 測試掛鉤（只在測試實例）：訊息裡寫 [[fake:no_action]] 就回那個種類，沒寫回 ok；CODENV_SPRINT_JUDGE_FAKE=off 模擬模型都沒開
        if CommandLine.arguments.contains("--state-dir"),
           (CommandLine.arguments.contains("--sprint-check-model-off") || ProcessInfo.processInfo.environment["CODENV_SPRINT_JUDGE_FAKE"] != nil) {
            if fakeKind == nil && (CommandLine.arguments.contains("--sprint-check-model-off") || ProcessInfo.processInfo.environment["CODENV_SPRINT_JUDGE_FAKE"] == "off") {
                return done(nil, "fake: 沒有可用的判斷模型")
            }
            let k = fakeKind ?? last.range(of: #"\[\[fake:(\w+)\]\]"#, options: .regularExpression)
                .map { match in String(last[match].dropFirst(7).dropLast(2)) } ?? "ok"
            return done(kinds.contains(k) ? Verdict(kind: k, score: 0.9, backend: "fake") : nil, kinds.contains(k) ? "" : "fake: 無效種類")
        }
        if let m = LocalServer.shared.runningModel, m == qwen {
            localJudge(text, model: m, done: done)
        } else if Prefs.shared.agyEnabled, FileManager.default.isExecutableFile(atPath: AgyBridge.executable) {
            agyJudge(text, done: done)
        } else {
            done(nil, "沒有可用的判斷模型（本機 Qwen3.6 沒開、agy 沒啟用）")
        }
    }

    /// 考卷限定的假判斷：把標註種類放進同一個 judge 入口的測試掛鉤，再核對返回值。
    /// 它驗證測試路徑與各種分類狀態能否傳遞，不代表語意模型的準確率。
    static func examJudge(last: String, expectedKind: String, done: @escaping (Verdict?, String) -> Void) {
        judge(last: last, tools: [], fakeKind: expectedKind, done: done)
    }

    private static func localJudge(_ prompt: String, model: String, done: @escaping (Verdict?, String) -> Void) {
        let server = LocalServer.shared
        server.begin()
        let body: [String: Any] = [
            "model": model, "stream": false, "max_tokens": 120, "temperature": 0.0,
            "messages": [["role": "user", "content": prompt]],
            "chat_template_kwargs": ["enable_thinking": false],
            "enable_thinking": false,   // mlx_vlm 的伺服器不看 chat_template_kwargs，寫在最外層
        ]
        var r = URLRequest(url: URL(string: server.base + "/v1/chat/completions")!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        r.timeoutInterval = 60
        URLSession.shared.dataTask(with: r) { data, _, err in
            var text = ""
            if let data, let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let msg = (o["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] { text = msg["content"] as? String ?? "" }
            // 沒關乾淨的思考段：只看 </think> 之後
            if let e = text.range(of: "</think>") { text = String(text[e.upperBound...]) }
            let p = parse(text)
            DispatchQueue.main.async {
                server.end()
                if let p { done(Verdict(kind: p.kind, score: p.score, backend: "qwen3.6"), "") }
                else { done(nil, "本機模型沒有回出看得懂的結果（\(err?.localizedDescription ?? String(text.prefix(60)))）") }
            }
        }.resume()
    }

    private static func agyJudge(_ prompt: String, done: @escaping (Verdict?, String) -> Void) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("codenv-sprint-check")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let preface = "不要執行任何指令、不要讀檔案、不要用任何工具，直接回答。\n"
        DispatchQueue.global(qos: .utility).async {
            guard AgyNet.canCall() else { return DispatchQueue.main.async { done(nil, "agy 連不到網路") } }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: AgyBridge.executable)
            let log = AgyNet.newLogFile()
            p.arguments = ["--model", NextGuess.flashModel, "--print-timeout", "45s", "--log-file", log.path, "-p=" + preface + prompt]
            p.currentDirectoryURL = dir
            let out = Pipe()
            let errURL = dir.appendingPathComponent("err-\(UUID().uuidString).txt")
            FileManager.default.createFile(atPath: errURL.path, contents: nil)
            let errFile = try? FileHandle(forWritingTo: errURL)
            p.standardOutput = out
            p.standardError = errFile ?? FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { try? FileManager.default.removeItem(at: errURL); return DispatchQueue.main.async { done(nil, "agy 開不起來") } }
            try? errFile?.close()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let e = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(at: errURL)
            AgyNet.check(log: log)
            let text = String(data: data, encoding: .utf8) ?? ""
            let parsed = e.contains("print timeout") ? nil : parse(text)
            DispatchQueue.main.async {
                if let parsed { done(Verdict(kind: parsed.kind, score: parsed.score, backend: "agy-flash-low"), "") }
                else { done(nil, "agy 沒有回出看得懂的結果（\(e.contains("print timeout") ? "逾時" : String(text.prefix(60)))）") }
            }
        }
    }

    // MARK: 讀這一輪的最後一則訊息與工具呼叫

    static func readLastRound(_ url: URL, done: @escaping (((text: String, userText: String, tools: [String], id: String)?) -> Void)) {
        DispatchQueue.global(qos: .utility).async {
            let round = lastRound(url)
            DispatchQueue.main.async { done(round) }
        }
    }

    /// 紀錄檔尾端：最後一則使用者訊息之後，助手的最後一段文字，以及這一輪呼叫過的工具名。最後一筆若是的話（還沒回覆）回 nil
    static func lastRound(_ url: URL) -> (text: String, userText: String, tools: [String], id: String)? {
        guard let data = ModelCarry.readLines(url, tail: 2 * 1024 * 1024)?.text else { return nil }
        var text = "", userText = "", tools: [String] = [], sawAssistant = false
        var userToken = "", assistantToken = ""
        for line in data.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = o["type"] as? String, type == "user" || type == "assistant",
                  o["isMeta"] as? Bool != true, let msg = o["message"] as? [String: Any] else { continue }
            let blocks = msg["content"] as? [[String: Any]] ?? []
            if type == "user" {
                // 工具結果不算新的一輪；真的有人說話（含 codenv 自己送的提醒）才重算
                let isResult = blocks.contains { $0["type"] as? String == "tool_result" }
                if isResult { continue }
                text = ""; userText = ""; tools = []; sawAssistant = false
                userText = (msg["content"] as? String) ?? blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
                userToken = (o["uuid"] as? String) ?? (o["timestamp"] as? String) ?? ""
                assistantToken = ""
            } else {
                sawAssistant = true
                assistantToken = (o["uuid"] as? String) ?? (msg["id"] as? String) ?? (o["timestamp"] as? String) ?? assistantToken
                for b in blocks {
                    if b["type"] as? String == "text", let t = b["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = t }
                    if b["type"] as? String == "tool_use", let n = b["name"] as? String { tools.append(n) }
                }
            }
        }
        guard sawAssistant && !text.isEmpty else { return nil }
        let source = [userToken, assistantToken, text, tools.joined(separator: "\u{1}")].joined(separator: "\u{0}")
        let id = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        return (text, userText, tools, id)
    }
}

extension LocalServer {
    /// 正在跑、而且已經開好的本機模型（沒開＝nil）
    var runningModel: String? { isReady ? model : nil }
}
