import Foundation
import FoundationModels

// Apple 內建的模型（Foundation Models：Apple Intelligence 跑在本機的那個）：系統自己帶，不用下載、不用開伺服器，App 直接呼叫。
// 跟 LocalBridge 一樣把回覆翻成 Claude Code 的格式，畫面照舊；只做聊天（上下文只有約 8K token，工具結果很快就塞滿）。
// 每一輪開一個新的 LanguageModelSession，前面的對話放進 instructions（放在提問裡它會起疑、拒答，實測），
// 提問只放使用者這一句；塞不下就從最舊的丟（tokenCount 要 macOS 26.4）。

final class AppleBridge {
    static let model = "on-device"
    static func name(_ model: String) -> String { "Apple 模型" }

    /// 這台能不能用（系統夠新、Apple Intelligence 開著、模型下載好了）
    static var available: Bool {
        guard #available(macOS 26.4, *) else { return false }
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// 自己記的 Claude 格式紀錄（給 loadHistory 讀，也拿來接回對話）；測試 App 寫到暫存資料夾
    static func transcript(for id: UUID) -> URL {
        let base = appDefaults === UserDefaults.standard
            ? Edition.support("apple")
            : URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("codenv-test-apple")
        return base.appendingPathComponent(id.uuidString.lowercased() + ".jsonl")
    }

    let session: UUID
    let directory: String
    let transcriptURL: URL
    /// 交給畫面的事件（Claude 格式）
    var emit: (([String: Any]) -> Void)?

    private var history: [(user: Bool, text: String)] = []   // 前面的對話（接進提示用）
    private var queue: [(uuid: String, text: String, msg: [String: Any])] = []   // msg：輪到它時才記進紀錄（排隊時記會插在上一則回覆前面）
    private var busy = false
    private var turn = 0                                       // 每輪加一：停止之後晚到的串流看這個丟掉
    private var task: Task<Void, Never>?
    private var open: (id: String, text: String)?
    private var started = Date()

    init(session: UUID, directory: String) {
        self.session = session
        self.directory = directory
        transcriptURL = Self.transcript(for: session)
        history = Self.rebuild(transcriptURL)
    }

    // MARK: 送進去

    func start() {
        emit?(["type": "system", "subtype": "init", "model": "apple-" + Self.model, "cwd": directory, "session_id": session.uuidString.lowercased()])
    }

    /// 工作台要寫給 claude 的東西：只認使用者訊息（沒有工具，也就沒有權限卡）
    func outgoing(_ obj: [String: Any]) {
        guard obj["type"] as? String == "user", let msg = obj["message"] as? [String: Any] else { return }
        if let s = msg["content"] as? String, s.hasPrefix("/") { return }   // /effort 之類是給 Claude 的
        let uuid = (obj["uuid"] as? String)?.lowercased() ?? UUID().uuidString.lowercased()
        queue.append((uuid, Self.text(msg), msg))
        next()
    }

    /// 停止這一輪（Esc）
    func interrupt() {
        guard busy else { return }
        turn += 1
        task?.cancel(); task = nil
        closeOpen(usage: nil)
        emit?(["type": "user", "message": ["role": "user", "content": "[Request interrupted by user]"]])
        emit?(["type": "result", "subtype": "error_during_execution", "is_error": true, "duration_ms": ms()])
        done()
    }

    /// ⌃ Enter：這則排到最前面、停下正在做的這一輪，停好馬上送
    func steer(_ uuid: String) {
        guard let i = queue.firstIndex(where: { $0.uuid == uuid.lowercased() }) else { return }
        queue.insert(queue.remove(at: i), at: 0)
        if busy { interrupt() }
    }

    /// 格子關掉：停下來，不再送事件
    func close() {
        turn += 1
        task?.cancel(); task = nil
        emit = nil
    }

    private func next() {
        guard !busy, !queue.isEmpty else { return }
        let q = queue.removeFirst()
        record(["type": "user", "message": q.msg])
        busy = true
        started = Date()
        emit?(["type": "user", "isReplay": true, "uuid": q.uuid, "message": ["role": "user", "content": []]])
        let past = history
        history.append((true, q.text))
        guard #available(macOS 26.4, *) else { fail("Apple 模型要 macOS 26.4 以上"); return }
        let t = turn
        task = Task { @MainActor [weak self] in await self?.generate(q.text, past: past, turn: t) }
    }

    private func done() {
        busy = false
        next()
    }

    private func fail(_ msg: String) {
        closeOpen(usage: nil)
        emit?(["type": "result", "subtype": "error_during_execution", "is_error": true, "result": msg, "duration_ms": ms()])
        done()
    }

    private func ms() -> Int { Int(Date().timeIntervalSince(started) * 1000) }

    @available(macOS 26.4, *)
    @MainActor private func generate(_ text: String, past: [(user: Bool, text: String)], turn t: Int) async {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            fail("Apple 模型現在不能用（\(model.availability)）：要在系統設定打開 Apple Intelligence，模型下載完才能用")
            return
        }
        // 上下文只有 contextSize（實測 8192）：留 1500 給回答，前面的對話從最舊的開始丟
        let limit = model.contextSize - 1500
        var keep = Self.withoutRefusals(past)
        func size(_ i: String) async -> Int { (try? await model.tokenCount(for: i + "\n" + text)) ?? (i.count + text.count) }
        var instructions = systemPrompt(keep)
        var used = await size(instructions)
        while used > limit, !keep.isEmpty {
            keep.removeFirst(min(2, keep.count))
            instructions = systemPrompt(keep)
            used = await size(instructions)
        }
        guard turn == t else { return }
        if used > limit {
            fail("這則太長了：Apple 模型一次只能讀大約 \(model.contextSize) 個 token（幾千個字）。請分段貼，或改用 LFM2.5")
            return
        }
        let s = LanguageModelSession(model: model, instructions: instructions)
        var shown = ""
        do {
            for try await snap in s.streamResponse(to: text) {
                guard turn == t else { return }
                let full = snap.content
                // 串流給的是到目前為止的整段：只送多出來的部分（偶爾改寫前面的，最後整則會蓋過去）
                if full.hasPrefix(shown), full.count > shown.count { chunk(String(full.dropFirst(shown.count))) }
                shown = full
            }
        } catch {
            guard turn == t, !(error is CancellationError) else { return }
            fail(Self.describe(error))
            return
        }
        guard turn == t else { return }
        if open == nil, !shown.isEmpty { chunk(shown) }
        open?.text = shown
        closeOpen(usage: used)
        history.append((false, shown))
        emit?(["type": "result", "subtype": "success", "is_error": false, "duration_ms": ms(), "usage": ["input_tokens": used, "output_tokens": 0]])
        done()
    }

    /// 拿掉它自己拒答的那幾輪（連同那則提問）：前文裡有「無法處理該請求」，它之後同樣的請求也會照著拒絕（實測）
    private static func withoutRefusals(_ past: [(user: Bool, text: String)]) -> [(user: Bool, text: String)] {
        var out: [(user: Bool, text: String)] = []
        for m in past {
            if !m.user, m.text.count < 60, m.text.hasPrefix("無法") || m.text.hasPrefix("抱歉，我無法") || m.text.hasPrefix("I can't") || m.text.hasPrefix("I cannot") {
                if out.last?.user == true { out.removeLast() }
                continue
            }
            out.append(m)
        }
        return out
    }

    /// 系統說明＋前面的對話（每則最多帶前 1200 字：一則超長的，例如貼了整章講義，不要把其他對話都擠掉）
    private func systemPrompt(_ past: [(user: Bool, text: String)]) -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd EEEE"; df.locale = Locale(identifier: "zh_TW")
        var s = """
        你是在使用者 Mac 上執行的 Apple 本機模型，由 codenv 工作台呼叫。
        一律用繁體中文（台灣用語）回答，語氣自然、冷靜，先講重點。
        今天：\(df.string(from: Date()))
        不確定的事實直接說不確定，不要編造。
        """
        guard !past.isEmpty else { return s }
        s += "\n\n以下是你跟使用者到目前為止的對話，回答時接著這段脈絡：\n"
        s += past.map { ($0.user ? "使用者：" : "你：") + ($0.text.count > 1200 ? $0.text.prefix(1200) + "…（後面省略）" : $0.text) }.joined(separator: "\n")
        return s
    }

    /// 錯誤翻成看得懂的話（macOS 26 和 27 的錯誤型別不一樣，用名字認）
    private static func describe(_ error: Error) -> String {
        let s = String(describing: error)
        if s.contains("guardrailViolation") { return "Apple 模型的安全過濾擋下了這則（它對某些主題很敏感），換個說法試試" }
        if s.contains("contextSizeExceeded") || s.contains("exceededContextWindowSize") { return "超過 Apple 模型能讀的長度（約 8K token），請開新對話或分段問" }
        if s.contains("unsupportedLanguageOrLocale") { return "Apple 模型不支援這個語言" }
        if s.contains("rateLimited") { return "Apple 模型忙不過來，等一下再試" }
        if s.contains("assetsUnavailable") { return "Apple 模型的檔案還沒準備好（系統可能正在下載或更新 Apple Intelligence）" }
        if s.contains("refusal") { return "Apple 模型拒絕回答這則" }
        return "Apple 模型：" + error.localizedDescription
    }

    // MARK: 讀出來

    private func chunk(_ t: String) {
        guard !t.isEmpty else { return }
        if open == nil {
            let id = "apple-" + UUID().uuidString.prefix(8).lowercased()
            open = (id, "")
            emit?(stream(["type": "message_start", "message": ["id": id, "role": "assistant"]], id))
            emit?(stream(["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]], id))
        }
        open?.text += t
        guard let id = open?.id else { return }
        emit?(stream(["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": t]], id))
    }

    private func closeOpen(usage: Int?) {
        guard let o = open else { return }
        open = nil
        // 整則要在 content_block_stop 之前送（畫面收到 stop 就把那塊標成完成，之後來的整則會當成新的一塊）
        let body = o.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            var msg: [String: Any] = ["id": o.id, "role": "assistant", "content": [["type": "text", "text": body]]]
            if let usage { msg["usage"] = ["input_tokens": usage, "output_tokens": 0] }   // 上下文大小（ContextSize 看 input_tokens）
            let a: [String: Any] = ["type": "assistant", "message": msg]
            emit?(a); record(a)
        }
        emit?(stream(["type": "content_block_stop", "index": 0], o.id))
        emit?(stream(["type": "message_stop"], o.id))
    }

    private func stream(_ event: [String: Any], _ msgID: String) -> [String: Any] {
        ["type": "stream_event", "event": event, "api_message_id": msgID]
    }

    /// Claude 格式的訊息內容 → 純文字（這個模型在這裡不收圖）
    private static func text(_ msg: [String: Any]) -> String {
        if let s = msg["content"] as? String { return s }
        var parts: [String] = []
        for b in msg["content"] as? [[String: Any]] ?? [] {
            if b["type"] as? String == "text", let t = b["text"] as? String { parts.append(t) }
            if b["type"] as? String == "image" { parts.append("（使用者附了一張圖片，但你看不到圖片；需要的話請使用者用文字描述）") }
        }
        return parts.joined(separator: "\n")
    }

    /// 重開 App 接回對話：從自己記的紀錄排回前面的對話
    private static func rebuild(_ url: URL) -> [(user: Bool, text: String)] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        var out: [(user: Bool, text: String)] = []
        for raw in d.split(separator: 0x0a) {
            guard let o = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any], let msg = o["message"] as? [String: Any] else { continue }
            switch o["type"] as? String {
            case "user":
                let t = text(msg)
                if !t.isEmpty, t != "[Request interrupted by user]" { out.append((true, t)) }
            case "assistant":
                let t = (msg["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
                if !t.isEmpty { out.append((false, t)) }
            default:
                break
            }
        }
        return out
    }

    /// 記一筆進自己的紀錄檔
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
