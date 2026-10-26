import AppKit

// 本機模型（MLX）：自己開一個 mlx_lm（看得懂圖的模型用 mlx_vlm）的伺服器（CodenvLocalPython 指到的 Python 環境、Hugging Face 快取裡的模型），
// 講 OpenAI 的 chat completions 格式。這裡把它的串流翻成 Claude Code 的格式，畫面照舊。
// 跟 agy／Codex／Copilot 不一樣：沒有別人幫忙跑工具，讀檔、寫檔、改檔、跑指令都是這裡自己做（權限卡也是這裡發）；
// 對話也是這裡自己記（每次把整段送過去，伺服器有前綴快取，不會每次重算）。
// 伺服器整個 App 共用一個（模型吃 13～15 GB 記憶體），閒置 15 分鐘自動關掉，下一則訊息再開。

final class LocalServer {
    static let shared = LocalServer()
    static let python = Edition.localPython ?? "/nonexistent/python"   // 沒設＝這台沒有本機模型的環境（選單不列、不啟動）
    /// 測試 App 用另一個埠，不跟正式版搶
    var port: Int { appDefaults === UserDefaults.standard ? 8790 : 8792 }
    var base: String { "http://127.0.0.1:\(port)" }

    private var process: Process?
    private(set) var model: String?
    private var ready = false
    private var waiters: [(String?) -> Void] = []
    private var users = 0                   // 正在用的（一輪還沒做完的）
    private var idle: Timer?
    private var logTail = ""

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in self?.stop() }
    }

    /// 這個模型的伺服器開好了就 done(nil)，開不起來 done(原因)
    func ensure(_ model: String, _ done: @escaping (String?) -> Void) {
        if process?.isRunning == true, self.model == model {
            if ready { done(nil) } else { waiters.append(done) }
            return
        }
        // 一次只開得了一個本機模型：別的聊天室的模型正在回答（users 含自己這一輪，所以 > 1），不要把它半路關掉
        if process?.isRunning == true, let other = self.model, users > 1 {
            done("另一個聊天室的 \(LocalBridge.name(other)) 正在回答。本機模型一次只能開一個，等它答完再送")
            return
        }
        stop()
        launch(model, done)
    }

    /// 包一層：每 2 秒看一次開它的 App 還在不在，不在了（當掉、被強制結束，收不到 willTerminate）就自己結束，不會留著吃記憶體
    private static let launcher = """
    import os, sys, threading, time, runpy
    parent = os.getppid()
    def watch():
        while True:
            time.sleep(2)
            if os.getppid() != parent: os._exit(0)
    threading.Thread(target=watch, daemon=True).start()
    mod = sys.argv[1]
    sys.argv = [mod] + sys.argv[2:]
    runpy.run_module(mod, run_name="__main__", alter_sys=True)
    """

    private func launch(_ model: String, _ done: @escaping (String?) -> Void) {
        guard FileManager.default.isExecutableFile(atPath: Self.python) else { done("找不到 \(Self.python)（mlx_lm 的 Python 環境）"); return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.python)
        var args = ["-c", Self.launcher]
        if LocalBridge.info(model)?.vision == true {
            // mlx_vlm 預設聽 0.0.0.0（整個網路都連得到），只開給本機
            args += ["mlx_vlm.server", "--host", "127.0.0.1", "--port", "\(port)", "--model", model]
        } else {
            args += ["mlx_lm", "server", "--model", model, "--port", "\(port)", "--max-tokens", "8192"]
            if let t = LocalBridge.template(model) { args += ["--chat-template", t] }
        }
        p.arguments = args
        var env: [String: String] = [:]
        for kv in Workspace.environment() { if let i = kv.firstIndex(of: "=") { env[String(kv[..<i])] = String(kv[kv.index(after: i)...]) } }
        env["HF_HUB_OFFLINE"] = "1"   // 模型已經在快取裡，不用每次問 Hugging Face
        p.environment = env
        let err = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = err
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            let s = String(decoding: d, as: UTF8.self)
            DispatchQueue.main.async { guard let self else { return }; self.logTail = String((self.logTail + s).suffix(1500)) }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, self.process === proc else { return }
                self.process = nil
                self.ready = false
                self.flush("本機模型伺服器結束了：" + self.logTail.split(separator: "\n").suffix(3).joined(separator: "\n"))
            }
        }
        do { try p.run() } catch { done("開不了本機模型伺服器：\(error.localizedDescription)"); return }
        process = p
        self.model = model
        ready = false
        waiters = [done]
        logTail = ""
        wait(p, tries: 0)
    }

    /// 等埠開起來（模型本身第一個請求時才讀進記憶體）
    private func wait(_ p: Process, tries: Int) {
        guard process === p else { return }
        probe { [weak self] ok in
            guard let self, self.process === p else { return }
            if ok { self.ready = true; self.flush(nil); return }
            if tries > 120 { self.stop(); self.flush("本機模型伺服器 60 秒還沒開好"); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.wait(p, tries: tries + 1) }
        }
    }

    private func probe(_ done: @escaping (Bool) -> Void) {
        var r = URLRequest(url: URL(string: base + "/v1/models")!)
        r.timeoutInterval = 1
        URLSession.shared.dataTask(with: r) { _, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { done(ok) }
        }.resume()
    }

    private func flush(_ err: String?) {
        let w = waiters
        waiters = []
        w.forEach { $0(err) }
    }

    /// 一輪開始／結束：閒著 15 分鐘就關掉，把記憶體還回去
    func begin() { users += 1; idle?.invalidate(); idle = nil }
    func end() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        idle?.invalidate()
        idle = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: false) { [weak self] _ in
            guard let self, self.users == 0 else { return }
            self.stop()
        }
    }

    func stop() {
        idle?.invalidate(); idle = nil
        if let p = process { process = nil; p.terminate() }
        ready = false
        model = nil
        if !waiters.isEmpty { flush("本機模型伺服器被關掉了") }
    }
}

final class LocalBridge {
    /// 怎麼開關思考：lfm＝範本自己補 </think>（template）；qwen＝範本本來就認 enable_thinking；
    /// harmony＝gpt-oss 的 reasoning_effort；none＝不會思考（面板不給拉桿）
    enum Think { case lfm, qwen, harmony, none }
    struct Model {
        let id: String, name: String
        let gb: Int               // 大約吃多少記憶體（選單提示用）
        let think: Think
        let temperature: Double   // 各家建議的取樣溫度
        var tools = true          // 會用工具（讀檔、跑指令）；不會的就當純聊天，不送工具清單（實測小模型不叫、或吐出伺服器看不懂的格式）
        var vision = false        // 看得懂圖：改用 mlx_vlm 的伺服器（mlx_lm 只吃文字），圖片照 OpenAI 格式送進去
    }
    /// 選單上的模型：快取裡有、Python 環境在才列（下載用本機模型資料夾裡的 mlx-get）
    static let models: [Model] = [
        Model(id: "LiquidAI/LFM2.5-24B-A2B-MLX-4bit", name: "LFM2.5 24B", gb: 14, think: .lfm, temperature: 0.1),
        // 下面幾個權重裡都有視覺的部分（vision_tower／multi_modal_projector），走 mlx_vlm 才看得到圖（10/25 實測藍底 42）
        Model(id: "mlx-community/Qwen3.6-35B-A3B-4bit", name: "Qwen3.6 35B", gb: 20, think: .qwen, temperature: 0.7, vision: true),
        Model(id: "mlx-community/Qwen3-VL-30B-A3B-Instruct-4bit", name: "Qwen3-VL 30B", gb: 17, think: .none, temperature: 0.7, vision: true),
        // GPT-OSS 20B 不列：mlx_lm 不懂它的 harmony 格式，回答混著 <|channel|> 控制符號、想完就停沒有正式回答（10/24 實測）
        Model(id: "mlx-community/Qwen3.5-4B-MLX-4bit", name: "Qwen3.5 4B", gb: 3, think: .qwen, temperature: 0.7, vision: true),   // 看得到圖但小，42 讀成 47
        Model(id: "mlx-community/gemma-3-4b-it-qat-4bit", name: "Gemma 3 4B", gb: 3, think: .none, temperature: 1.0, tools: false, vision: true),
        Model(id: "mlx-community/Ministral-3-3B-Instruct-2512-4bit", name: "Ministral 3 3B", gb: 3, think: .none, temperature: 0.15, tools: false, vision: true),
        Model(id: "MXLouis/Llama-Breeze2-3B-Instruct-Text-mlx-8Bit", name: "Breeze2 3B", gb: 4, think: .none, temperature: 0.7, tools: false),
    ]
    static var available: [Model] {
        guard FileManager.default.isExecutableFile(atPath: LocalServer.python) else { return [] }
        return models.filter { (!$0.vision || hasVLM) && (snapshot($0.id).map(complete) ?? false) }
    }
    /// Python 環境裡裝了 mlx_vlm（pip install mlx-vlm）
    static var hasVLM: Bool {
        let lib = URL(fileURLWithPath: LocalServer.python).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib")
        return ((try? FileManager.default.contentsOfDirectory(atPath: lib.path)) ?? []).contains {
            FileManager.default.fileExists(atPath: lib.appendingPathComponent("\($0)/site-packages/mlx_vlm").path)
        }
    }

    /// 真的下載完了：權重檔都到齊、沒有下載到一半的檔案。下載時 config.json 這類小檔先到，只看它會把下載中的模型列出來
    static func complete(_ snap: URL) -> Bool {
        let fm = FileManager.default
        let blobs = snap.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("blobs")
        if ((try? fm.contentsOfDirectory(atPath: blobs.path)) ?? []).contains(where: { $0.hasSuffix(".incomplete") }) { return false }
        // 單一權重檔在就算（有的模型包同時留著過時的分割清單，例如 gemma-3-4b-it-qat，照清單找會以為沒下載完）
        if fm.fileExists(atPath: snap.appendingPathComponent("model.safetensors").path) { return true }
        let index = snap.appendingPathComponent("model.safetensors.index.json")
        if let d = try? Data(contentsOf: index), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let map = o["weight_map"] as? [String: String] {
            if Set(map.values).allSatisfy({ fm.fileExists(atPath: snap.appendingPathComponent($0).path) }) { return true }
        }
        // 分割清單也可能是過時的（Qwen3-VL-30B 清單寫 of-00013，實際下載的是 of-00004）：
        // 改看資料夾裡實際的 model-XXXXX-of-NNNNN.safetensors，某個 N 的 1～N 全在就算完整（mlx_lm 載入時也是直接抓資料夾裡的權重檔）
        let names = (try? fm.contentsOfDirectory(atPath: snap.path)) ?? []
        var parts: [Int: Set<Int>] = [:]
        for n in names where n.hasPrefix("model-") && n.hasSuffix(".safetensors") {
            let nums = n.dropFirst(6).dropLast(12).components(separatedBy: "-of-").compactMap { Int($0) }
            if nums.count == 2 { parts[nums[1], default: []].insert(nums[0]) }
        }
        return parts.contains { total, have in total > 0 && have == Set(1...total) }
    }
    static func info(_ model: String) -> Model? { models.first { $0.id == model } }
    /// 思考強度：低＝直接回答（LFM 想起來很久還會鬼打牆），高＝先想再答；不會思考的模型沒有拉桿
    static func levels(_ model: String?) -> [String] {
        switch model.flatMap(info)?.think {
        case .none?: return []
        case .harmony?: return ["low", "medium", "high"]
        default: return ["low", "high"]
        }
    }
    static func defaultLevel(_ model: String?) -> String? { levels(model).first }
    static func name(_ model: String) -> String { info(model)?.name ?? model }

    /// Hugging Face 快取裡這個模型的資料夾
    static func snapshot(_ model: String) -> URL? {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--" + model.replacingOccurrences(of: "/", with: "--") + "/snapshots")
        let snaps = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return snaps.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("config.json").path) }
    }

    /// 模型的對話範本，加一個 enable_thinking 開關：關掉時直接補上 </think>（跳過思考）
    static func template(_ model: String) -> String? {
        guard info(model)?.think == .lfm, let s = snapshot(model), var t = try? String(contentsOf: s.appendingPathComponent("chat_template.jinja"), encoding: .utf8) else { return nil }
        let gen = #"{{- "<|im_start|>assistant\n<think>" -}}"#
        guard t.contains(gen) else { return nil }
        t = t.replacingOccurrences(of: gen, with: gen + #"{%- if enable_thinking is defined and not enable_thinking -%}{{- "</think>" -}}{%- endif -%}"#)
        return t
    }

    /// 自己記的 Claude 格式紀錄（給 loadHistory 讀，也拿來接回對話）；測試 App 寫到暫存資料夾
    static func transcript(for id: UUID) -> URL {
        let base = appDefaults === UserDefaults.standard
            ? Edition.support("local")
            : URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("codenv-test-local")
        return base.appendingPathComponent(id.uuidString.lowercased() + ".jsonl")
    }

    let session: UUID
    let directory: String
    let transcriptURL: URL
    let model: String
    var mode: String?
    var effort: String?
    /// 交給畫面的事件（Claude 格式）
    var emit: (([String: Any]) -> Void)?

    private var messages: [[String: Any]] = []          // 送給模型的整段對話（OpenAI 格式，不含系統提示）
    private var queue: [(uuid: String, text: String, msg: [String: Any])] = []   // msg：輪到它時才記進紀錄（排隊時記會插在上一則回覆前面）
    private var busy = false
    private var turn = 0                                // 每輪加一：停止之後晚到的回呼看這個丟掉
    private var rounds = 0
    private var sse: SSE?
    private var shell: Process?
    private var calls: [(id: String, name: String, args: String)] = []   // 這次回覆要的工具，一個一個做
    private var approvals: [String: (id: String, name: String, input: [String: Any])] = [:]
    private var always: Set<String> = []                // 選了「永遠允許」的工具
    private var open: (id: String, kind: String, text: String)?
    private var usage: [String: Any]?
    private var started = Date()
    private var lastTokens = 0                          // 上一輪結束時上下文多大（超過門檻就先壓縮，LocalCompact.swift）
    private var compacting = false

    init(session: UUID, directory: String, model: String) {
        self.session = session
        self.directory = directory
        self.model = model
        transcriptURL = Self.transcript(for: session)
        messages = Self.rebuild(transcriptURL, vision: Self.info(model)?.vision == true)
    }

    // MARK: 送進去

    func start() {
        emit?(["type": "system", "subtype": "init", "model": "local-" + Self.name(model).lowercased().replacingOccurrences(of: " ", with: "-"),
               "cwd": directory, "session_id": session.uuidString.lowercased()])
    }

    /// 工作台要寫給 claude 的東西 → 使用者訊息排隊、權限回覆接著做
    func outgoing(_ obj: [String: Any]) {
        switch obj["type"] as? String {
        case "user":
            guard let msg = obj["message"] as? [String: Any] else { return }
            if let s = msg["content"] as? String, s.hasPrefix("/") { return }   // /effort 之類是給 Claude 的
            let uuid = (obj["uuid"] as? String)?.lowercased() ?? UUID().uuidString.lowercased()
            queue.append((uuid, Self.text(msg), msg))
            next()
        case "control_response":
            guard let r = obj["response"] as? [String: Any], let rid = r["request_id"] as? String,
                  let a = approvals.removeValue(forKey: rid) else { return }
            let ans = r["response"] as? [String: Any] ?? [:]
            if ans["behavior"] as? String == "allow" {
                if ans["updatedPermissions"] != nil { always.insert(a.name) }
                run(a.id, a.name, a.input)
            } else {
                denied(a.id)
            }
        default:
            break
        }
    }

    /// 停止這一輪（Esc）：斷掉串流、殺掉正在跑的指令，還在等的權限卡收掉
    func interrupt() {
        guard busy, !compacting else { return }   // 壓縮中按停止：等 Claude 整理完（最多幾分鐘），不中斷
        turn += 1
        sse?.cancel(); sse = nil
        if shell?.isRunning == true { shell?.terminate() }
        shell = nil
        for rid in approvals.keys { emit?(["type": "control_cancel_request", "request_id": rid]) }
        approvals.removeAll()
        closeOpen()
        // 模型要了工具但還沒做完的：補上結果，不然下一輪的對話格式不對
        for c in calls { messages.append(["role": "tool", "tool_call_id": c.id, "content": "Interrupted by the user."]) }
        calls.removeAll()
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
        if busy { turn += 1; sse?.cancel(); if shell?.isRunning == true { shell?.terminate() }; LocalServer.shared.end() }
        emit = nil
    }

    private func next() {
        guard !busy, !queue.isEmpty else { return }
        let q = queue.removeFirst()
        record(["type": "user", "message": q.msg])
        busy = true
        started = Date()
        rounds = 0
        LocalServer.shared.begin()
        emit?(["type": "user", "isReplay": true, "uuid": q.uuid, "message": ["role": "user", "content": []]])
        messages.append(["role": "user", "content": Self.content(q.msg, vision: Self.info(model)?.vision == true)])
        ask()
    }

    private func done() {
        busy = false
        LocalServer.shared.end()
        if lastTokens >= LocalCompact.threshold(model: model), messages.count > 2 { compact() } else { next() }
    }

    /// 上下文太長：先請 Claude 把前面整理成摘要，再送下一則（排隊中的訊息等它做完）。失敗就照原樣繼續
    private func compact() {
        compacting = true
        busy = true
        let pre = lastTokens
        emit?(["type": "system", "subtype": "status", "status": "compacting"])
        LocalCompact.summarize(messages, model: Self.name(model)) { [weak self] summary, err in
            guard let self else { return }
            self.compacting = false
            self.busy = false
            if let summary {
                let note = LocalCompact.summaryMessage(summary)
                self.messages = [["role": "user", "content": note], ["role": "assistant", "content": LocalCompact.ack]]
                let meta: [String: Any] = ["trigger": "auto", "pre_tokens": pre, "post_tokens": LocalCompact.estimateTokens(note), "summarized_by": "claude-haiku"]
                self.record(["type": "system", "subtype": "compact_boundary", "compact_metadata": meta])
                self.record(["type": "user", "isCompactSummary": true, "message": ["role": "user", "content": note]])
                self.emit?(["type": "system", "subtype": "status", "status": NSNull()])
                self.emit?(["type": "system", "subtype": "compact_boundary", "compact_metadata": meta])
                self.lastTokens = 0
            } else {
                // 這次不壓（下一輪還超過會再試）；照原樣送，紀錄不動
                self.emit?(["type": "system", "subtype": "status", "status": "compact_failed", "message": "自動壓縮沒成功，照原樣繼續：" + (err ?? "")])
                self.lastTokens = 0
            }
            self.next()
        }
    }

    private func fail(_ msg: String) {
        closeOpen()
        emit?(["type": "result", "subtype": "error_during_execution", "is_error": true, "result": msg, "duration_ms": ms()])
        done()
    }

    private func ms() -> Int { Int(Date().timeIntervalSince(started) * 1000) }

    /// 問模型一次（一輪裡可能好幾次：每做完一批工具就再問）
    private func ask() {
        rounds += 1
        guard rounds <= 40 else { fail("本機模型這一輪叫了太多次工具，先停在這裡"); return }
        let t = turn
        LocalServer.shared.ensure(model) { [weak self] err in
            guard let self, self.turn == t else { return }
            if let err { self.fail(err); return }
            self.request()
        }
    }

    private func request() {
        let m = Self.info(model)
        // 這個模型認得的強度（從別的模型帶來的 xhigh 之類就用它的預設）
        let level = effort.flatMap { Self.levels(model).contains($0) ? $0 : nil } ?? Self.defaultLevel(model)
        var body: [String: Any] = [
            "model": model, "stream": true, "stream_options": ["include_usage": true], "max_tokens": 8192,
            "temperature": m?.temperature ?? 0.7,
            "messages": [["role": "system", "content": systemPrompt()]] + messages,
        ]
        switch m?.think {
        case .lfm?:
            body["top_k"] = 50; body["repetition_penalty"] = 1.05   // LFM2.5 建議的取樣
            body["chat_template_kwargs"] = ["enable_thinking": level == "high"]   // 範本加的開關（template）
        case .qwen?:
            body["chat_template_kwargs"] = ["enable_thinking": level == "high"]
            // mlx_vlm 的伺服器不看 chat_template_kwargs，要寫在最外層（不寫就照範本預設，Qwen3.6 會一直想）
            if m?.vision == true { body["enable_thinking"] = level == "high" }
        case .harmony?: body["chat_template_kwargs"] = ["reasoning_effort": level ?? "low"]
        default: break
        }
        if m?.tools ?? true { body["tools"] = Self.toolSpecs(plan: mode == "plan") }
        var r = URLRequest(url: URL(string: LocalServer.shared.base + "/v1/chat/completions")!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        r.timeoutInterval = 600   // 第一次要把模型讀進記憶體
        usage = nil
        var pending: [Int: (id: String, name: String, args: String)] = [:]
        // LFM 關掉思考時還是常常先講一小段、吐一個 </think> 才正式回答（實測）：開頭先壓著，
        // 看到 </think> 就把前面那段當思考；壓了 200 字還沒看到、或講完了，就當一般回答放出來。其他模型不用壓
        var held = "", decided = m?.think != .lfm || level == "high"
        func release() {
            guard !decided else { return }
            decided = true
            chunk("text", held.trimmingCharacters(in: .newlines))
        }
        func content(_ s: String) {
            if decided { chunk("text", s.replacingOccurrences(of: "</think>", with: "")); return }
            held += s
            if let r = held.range(of: "</think>") {
                decided = true
                chunk("thinking", String(held[..<r.lowerBound]))
                closeOpen()
                chunk("text", String(held[r.upperBound...]).trimmingCharacters(in: .newlines))
            } else if held.count > 200 { release() }
        }
        let t = turn
        sse = SSE(r, onEvent: { [weak self] o in
            guard let self, self.turn == t else { return }
            if let u = o["usage"] as? [String: Any] { self.usage = u }
            for c in o["choices"] as? [[String: Any]] ?? [] {
                let d = c["delta"] as? [String: Any] ?? [:]
                if let s = d["reasoning"] as? String { self.chunk("thinking", s) }
                if let s = d["content"] as? String { content(s) }
                for tc in d["tool_calls"] as? [[String: Any]] ?? [] {
                    release()
                    let i = (tc["index"] as? NSNumber)?.intValue ?? pending.count
                    let f = tc["function"] as? [String: Any] ?? [:]
                    var cur = pending[i] ?? (tc["id"] as? String ?? "call_" + UUID().uuidString.prefix(8).lowercased(), "", "")
                    if let n = f["name"] as? String { cur.name += n }
                    if let a = f["arguments"] as? String { cur.args += a }
                    pending[i] = cur
                }
            }
        }, onDone: { [weak self] err in
            guard let self, self.turn == t else { return }
            self.sse = nil
            if let err { self.fail("本機模型：" + err); return }
            release()
            self.replied(pending.keys.sorted().compactMap { pending[$0] })
        })
    }

    /// 模型這次講完了：有要工具就一個一個做，做完再問；沒有就是這一輪結束
    private func replied(_ tools: [(id: String, name: String, args: String)]) {
        let text = open?.kind == "text" ? open!.text : ""
        closeOpen()
        var a: [String: Any] = ["role": "assistant", "content": text.trimmingCharacters(in: .whitespacesAndNewlines)]
        if !tools.isEmpty {
            a["tool_calls"] = tools.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.args.isEmpty ? "{}" : $0.args]] }
        }
        messages.append(a)
        guard !tools.isEmpty else {
            var out: [String: Any] = ["type": "result", "subtype": "success", "is_error": false, "duration_ms": ms()]
            if let u = usage { out["usage"] = ["input_tokens": u["prompt_tokens"] ?? 0, "output_tokens": u["completion_tokens"] ?? 0] }
            if let u = usage { lastTokens = ((u["prompt_tokens"] as? NSNumber)?.intValue ?? 0) + ((u["completion_tokens"] as? NSNumber)?.intValue ?? 0) }
            emit?(out)
            done()
            return
        }
        calls = tools
        nextTool()
    }

    private func nextTool() {
        guard let c = calls.first else { ask(); return }
        let input = (try? JSONSerialization.jsonObject(with: Data(c.args.utf8))) as? [String: Any] ?? [:]
        let use = toolUse(c.id, c.name, input)
        emit?(use); record(use)
        guard Self.toolNames.contains(c.name) else {
            finishTool(c.id, "沒有這個工具：\(c.name)", error: true, toModel: "Unknown tool \(c.name). Available tools: \(Self.toolNames.joined(separator: ", ")).")
            return
        }
        if c.name != "Read", mode == "plan" {
            finishTool(c.id, "規劃模式不能改東西", error: true, toModel: "Plan mode: you may only read files. Describe the plan instead.")
            return
        }
        // 不用問的：讀檔；接受修改＝讀、寫、改檔；自動、全部允許＝都不問；選過「永遠允許」的
        let auto = c.name == "Read" || always.contains(c.name) || mode == "auto" || mode == "bypassPermissions"
            || (mode == "acceptEdits" && c.name != "Bash")
        if auto { run(c.id, c.name, input); return }
        let rid = "local-\(UUID().uuidString.prefix(8))"
        approvals[rid] = (c.id, c.name, input)
        emit?(["type": "control_request", "request_id": rid,
               "request": ["subtype": "can_use_tool", "tool_name": c.name, "input": input, "tool_use_id": c.id]])
    }

    /// 做工具（在背景做，做完回主執行緒）
    private func run(_ id: String, _ name: String, _ input: [String: Any]) {
        let t = turn
        let dir = directory
        if name == "Bash" {
            let p = Process()
            shell = p
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let (out, ok) = Self.bash(input["command"] as? String ?? "", dir: dir, process: p)
                DispatchQueue.main.async {
                    guard let self, self.turn == t else { return }
                    self.shell = nil
                    self.finishTool(id, out, error: !ok)
                }
            }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (out, ok) = Self.file(name, input, dir: dir)
            DispatchQueue.main.async {
                guard let self, self.turn == t else { return }
                self.finishTool(id, out, error: !ok)
            }
        }
    }

    /// 拒絕：跟 Claude Code 一樣這一輪就停下來等使用者（實測這個模型被拒絕後會假裝沒事、換個指令再試）
    private func denied(_ id: String) {
        let res: [String: Any] = ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": "使用者拒絕", "is_error": true]]]]
        emit?(res); record(res)
        for c in calls {
            messages.append(["role": "tool", "tool_call_id": c.id,
                             "content": c.id == id ? "The user denied this tool call. Wait for the user's next instruction." : "Skipped: the user denied an earlier tool call."])
        }
        calls.removeAll()
        emit?(["type": "user", "message": ["role": "user", "content": "[Request interrupted by user for tool use]"]])
        emit?(["type": "result", "subtype": "error_during_execution", "is_error": true, "duration_ms": ms()])
        done()
    }

    /// 一個工具做完：畫面上放結果，對話裡記給模型看的版本，接著做下一個
    private func finishTool(_ id: String, _ shown: String, error: Bool, toModel: String? = nil) {
        let res: [String: Any] = ["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": shown, "is_error": error]]]]
        emit?(res); record(res)
        messages.append(["role": "tool", "tool_call_id": id, "content": toModel ?? shown])
        calls.removeAll { $0.id == id }
        nextTool()
    }

    private func systemPrompt() -> String {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd EEEE"; df.locale = Locale(identifier: "zh_TW")
        var s = """
        你是在使用者 Mac 上執行的本機 AI 助手（\(Self.name(model))），由 codenv 工作台呼叫。
        一律用繁體中文（台灣用語）回答，語氣自然、冷靜，先講重點，不要過度條列。
        工作資料夾：\(directory)
        今天：\(df.string(from: Date()))
        不確定的事實直接說不確定，不要編造。
        """
        if Self.info(model)?.tools ?? true {
            s += "\n要看檔案、跑指令、建立或修改檔案時，用提供的工具；路徑用絕對路徑。工具結果回來之前不要假設結果。"
            s += "\n使用者說「這個資料夾」「這個專案」就是工作資料夾；只給檔名沒給路徑時，先自己在工作資料夾裡找，不要反問使用者。"
        } else {
            s += "\n你沒有讀檔、跑指令的工具：要看檔案內容就請使用者貼上來。"
        }
        if mode == "plan" { s += "\n現在是規劃模式：只能讀檔，不能改東西或跑指令；先把計畫講清楚。" }
        return s
    }

    // MARK: 工具

    static let toolNames = ["Read", "Write", "Edit", "Bash"]

    static func toolSpecs(plan: Bool) -> [[String: Any]] {
        func f(_ name: String, _ desc: String, _ props: [String: [String: String]], _ req: [String]) -> [String: Any] {
            ["type": "function", "function": ["name": name, "description": desc,
                                              "parameters": ["type": "object", "properties": props, "required": req]]]
        }
        let read = f("Read", "Read a text file. Returns lines with line numbers.",
                     ["file_path": ["type": "string", "description": "Absolute path"],
                      "offset": ["type": "integer", "description": "First line (1-based), optional"],
                      "limit": ["type": "integer", "description": "Number of lines, optional (default 2000)"]], ["file_path"])
        if plan { return [read] }
        return [read,
                f("Write", "Create or overwrite a file with the given content.",
                  ["file_path": ["type": "string", "description": "Absolute path"], "content": ["type": "string"]], ["file_path", "content"]),
                f("Edit", "Replace an exact string in a file. old_string must appear exactly once.",
                  ["file_path": ["type": "string", "description": "Absolute path"], "old_string": ["type": "string"], "new_string": ["type": "string"]],
                  ["file_path", "old_string", "new_string"]),
                f("Bash", "Run a shell command (zsh) in the working directory. Times out after 2 minutes.",
                  ["command": ["type": "string"], "description": ["type": "string", "description": "What the command does, in a few words"]], ["command"])]
    }

    private static func path(_ input: [String: Any], _ dir: String) -> String {
        let p = (input["file_path"] as? String ?? "") as NSString
        let e = p.expandingTildeInPath
        return e.hasPrefix("/") ? e : (dir as NSString).appendingPathComponent(e)
    }

    /// Read／Write／Edit
    static func file(_ name: String, _ input: [String: Any], dir: String) -> (String, Bool) {
        let p = path(input, dir)
        let fm = FileManager.default
        switch name {
        case "Read":
            guard let s = try? String(contentsOfFile: p, encoding: .utf8) else {
                return (fm.fileExists(atPath: p) ? "讀不了（不是文字檔？）：\(p)" : "沒有這個檔案：\(p)", false)
            }
            let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
            let from = max(1, (input["offset"] as? NSNumber)?.intValue ?? 1)
            let count = max(1, (input["limit"] as? NSNumber)?.intValue ?? 2000)
            guard from <= lines.count else { return ("檔案只有 \(lines.count) 行", true) }
            var out = ""
            for i in from...(from + min(count, lines.count - from + 1) - 1) {   // 先夾住再加：limit 給 Int.max 會溢位當掉
                let l = lines[i - 1]
                out += String(format: "%6d\t", i) + (l.count > 2000 ? String(l.prefix(2000)) + "…" : String(l)) + "\n"
                if out.count > 100_000 { out += "…（太長，後面截掉）"; break }
            }
            return (out, true)
        case "Write":
            let c = input["content"] as? String ?? ""
            do {
                try fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try c.write(toFile: p, atomically: true, encoding: .utf8)
                return ("已寫入 \(p)", true)
            } catch { return ("寫不進去：\(error.localizedDescription)", false) }
        case "Edit":
            guard let s = try? String(contentsOfFile: p, encoding: .utf8) else { return ("沒有這個檔案：\(p)", false) }
            let old = input["old_string"] as? String ?? "", new = input["new_string"] as? String ?? ""
            guard !old.isEmpty else { return ("old_string 是空的", false) }
            let n = s.components(separatedBy: old).count - 1
            guard n == 1 else { return (n == 0 ? "檔案裡找不到 old_string" : "old_string 出現 \(n) 次，要剛好一次", false) }
            do {
                try s.replacingOccurrences(of: old, with: new).write(toFile: p, atomically: true, encoding: .utf8)
                return ("已修改 \(p)", true)
            } catch { return ("寫不進去：\(error.localizedDescription)", false) }
        default:
            return ("沒有這個工具", false)
        }
    }

    /// Bash：登入 shell、工作資料夾裡跑，2 分鐘到就停；輸出（含錯誤輸出）最多 3 萬字
    static func bash(_ command: String, dir: String, process p: Process) -> (String, Bool) {
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c", command]
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        var env: [String: String] = [:]
        for kv in Workspace.environment() { if let i = kv.firstIndex(of: "=") { env[String(kv[..<i])] = String(kv[kv.index(after: i)...]) } }
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return ("開不了 zsh：\(error.localizedDescription)", false) }
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timer)
        // 不用 readDataToEndOfFile：指令留了背景程序（`sleep 500 & echo hi`）時它握著管子，讀到底要等它結束。
        // 改成邊跑邊收，zsh 結束後再等 0.3 秒收尾巴就交差，背景程序照跑
        let lock = NSLock()
        var data = Data()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }   // 讀到底了
            lock.lock(); data.append(d); lock.unlock()
        }
        p.waitUntilExit()
        timer.cancel()
        Thread.sleep(forTimeInterval: 0.3)
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.lock(); let got = data; lock.unlock()
        var out = String(decoding: got, as: UTF8.self)
        if out.count > 30_000 { out = String(out.prefix(30_000)) + "\n…（輸出太長，後面截掉）" }
        out = out.trimmingCharacters(in: .newlines)
        let code = p.terminationStatus
        if p.terminationReason == .uncaughtSignal { out += (out.isEmpty ? "" : "\n") + "（被停掉了）" }
        else if code != 0 { out += (out.isEmpty ? "" : "\n") + "（結束代碼 \(code)）" }
        return (out.isEmpty ? "（沒有輸出）" : out, code == 0)
    }

    // MARK: 讀出來

    /// 串流的文字／思考：同一種連續的算一則；換種類就收尾
    private func chunk(_ kind: String, _ t: String) {
        guard !t.isEmpty else { return }
        if open?.kind != kind {
            // 開頭的空行不要（跳過思考時會先吐換行）
            if open == nil, t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
            closeOpen()
            let id = "local-" + UUID().uuidString.prefix(8).lowercased()
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
        // 完整內容要在 content_block_stop 之前送：畫面收到 stop 就把那塊標成完成，之後來的整則會當成新的一塊（思考會畫兩次）
        let body = o.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            let block: [String: Any] = o.kind == "text" ? ["type": "text", "text": body] : ["type": "thinking", "thinking": body]
            var msg: [String: Any] = ["id": o.id, "role": "assistant", "content": [block]]
            // 上下文大小（ContextSize 看 input_tokens）
            if let u = usage { msg["usage"] = ["input_tokens": u["prompt_tokens"] ?? 0, "output_tokens": u["completion_tokens"] ?? 0] }
            let a: [String: Any] = ["type": "assistant", "message": msg]
            emit?(a); record(a)
        }
        emit?(stream(["type": "content_block_stop", "index": 0], o.id))
        emit?(stream(["type": "message_stop"], o.id))
    }

    private func toolUse(_ id: String, _ name: String, _ input: [String: Any]) -> [String: Any] {
        ["type": "assistant", "message": ["id": "local-tool-" + id, "role": "assistant", "content": [["type": "tool_use", "id": id, "name": name, "input": input]]]]
    }

    private func stream(_ event: [String: Any], _ msgID: String) -> [String: Any] {
        ["type": "stream_event", "event": event, "api_message_id": msgID]
    }

    /// 送給模型的使用者訊息：看得懂圖的模型有附圖就照 OpenAI 格式（文字＋data URL 圖片）送，其他的只送文字
    private static func content(_ msg: [String: Any], vision: Bool) -> Any {
        let blocks = msg["content"] as? [[String: Any]] ?? []
        guard vision, blocks.contains(where: { $0["type"] as? String == "image" }) else { return text(msg) }
        return blocks.compactMap { b -> [String: Any]? in
            switch b["type"] as? String {
            case "text": return ["type": "text", "text": b["text"] as? String ?? ""]
            case "image":
                guard let src = b["source"] as? [String: Any], let d = src["data"] as? String else { return nil }
                return ["type": "image_url", "image_url": ["url": "data:\(src["media_type"] as? String ?? "image/png");base64,\(d)"]]
            default: return nil
            }
        }
    }

    /// Claude 格式的訊息內容 → 純文字（這個模型看不到圖）
    private static func text(_ msg: [String: Any]) -> String {
        if let s = msg["content"] as? String { return s }
        var parts: [String] = []
        for b in msg["content"] as? [[String: Any]] ?? [] {
            if b["type"] as? String == "text", let t = b["text"] as? String { parts.append(t) }
            if b["type"] as? String == "image" { parts.append("（使用者附了一張圖片，但你看不到圖片；需要的話請使用者用文字描述）") }
        }
        return parts.joined(separator: "\n")
    }

    /// 重開 App 接回對話：從自己記的紀錄排回 OpenAI 格式（思考不送回去）
    private static func rebuild(_ url: URL, vision: Bool) -> [[String: Any]] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        var out: [[String: Any]] = []
        var waiting: [String] = []   // 要了工具還沒有結果的
        func closeTools() {
            for id in waiting { out.append(["role": "tool", "tool_call_id": id, "content": "(no result)"]) }
            waiting.removeAll()
        }
        for raw in d.split(separator: 0x0a) {
            guard let o = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { continue }
            // 自動壓縮過（LocalCompact.swift）：從最後一次的摘要接著算，前面的不送
            if o["type"] as? String == "system", o["subtype"] as? String == "compact_boundary" { out.removeAll(); waiting.removeAll(); continue }
            if o["isCompactSummary"] as? Bool == true, let s = (o["message"] as? [String: Any])?["content"] as? String {
                out.append(["role": "user", "content": s]); out.append(["role": "assistant", "content": LocalCompact.ack]); continue
            }
            guard let msg = o["message"] as? [String: Any] else { continue }
            let blocks = msg["content"] as? [[String: Any]] ?? []
            switch o["type"] as? String {
            case "user":
                if let s = msg["content"] as? String {
                    if s != "[Request interrupted by user]" { closeTools(); out.append(["role": "user", "content": s]) }
                    continue
                }
                let results = blocks.filter { $0["type"] as? String == "tool_result" }
                for r in results {
                    let id = r["tool_use_id"] as? String ?? ""
                    waiting.removeAll { $0 == id }
                    out.append(["role": "tool", "tool_call_id": id, "content": r["content"] as? String ?? ""])
                }
                if results.isEmpty { closeTools(); out.append(["role": "user", "content": content(msg, vision: vision)]) }
            case "assistant":
                for b in blocks {
                    switch b["type"] as? String {
                    case "text":
                        closeTools()
                        out.append(["role": "assistant", "content": b["text"] as? String ?? ""])
                    case "tool_use":
                        let id = b["id"] as? String ?? UUID().uuidString
                        let args = (try? JSONSerialization.data(withJSONObject: b["input"] ?? [:])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                        let call: [String: Any] = ["id": id, "type": "function", "function": ["name": b["name"] as? String ?? "", "arguments": args]]
                        // 接在前一則助手訊息後面（同一次回覆的文字＋工具）；前面已經有工具結果就另開一則
                        if var last = out.last, last["role"] as? String == "assistant" {
                            last["tool_calls"] = (last["tool_calls"] as? [[String: Any]] ?? []) + [call]
                            out[out.count - 1] = last
                        } else {
                            out.append(["role": "assistant", "content": "", "tool_calls": [call]])
                        }
                        waiting.append(id)
                    default:
                        break
                    }
                }
            default:
                break
            }
        }
        closeTools()
        return out
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

/// 讀 server-sent events（一行一個「data: {…}」）；事件、結束都回主執行緒
final class SSE: NSObject, URLSessionDataDelegate {
    private var buffer = Data()
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private let onEvent: ([String: Any]) -> Void
    private let onDone: (String?) -> Void
    private var status = 0
    private var body = Data()   // 不是 200 時的錯誤內容

    init(_ request: URLRequest, onEvent: @escaping ([String: Any]) -> Void, onDone: @escaping (String?) -> Void) {
        self.onEvent = onEvent
        self.onDone = onDone
        super.init()
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
        task = session.dataTask(with: request)
        task?.resume()
    }

    func cancel() { task?.cancel(); session.invalidateAndCancel() }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(.allow)
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard status == 200 else { body.append(data); return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0a) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard line.starts(with: Data("data: ".utf8)) else { continue }
            let payload = line.dropFirst(6)
            if payload.starts(with: Data("[DONE]".utf8)) { continue }
            if let o = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] { onEvent(o) }
        }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        if let e = error as? URLError, e.code == .cancelled { return }
        if let error { onDone(error.localizedDescription); return }
        if status != 200 { onDone("伺服器回 \(status)：" + String(decoding: body.prefix(300), as: UTF8.self)); return }
        onDone(nil)
    }
}
