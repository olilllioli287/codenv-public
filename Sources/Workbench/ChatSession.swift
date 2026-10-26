import Foundation

// 一段聊天：在背後跑「不畫畫面、只傳 JSON」的 Claude Code，
// claude -p --input-format stream-json --output-format stream-json --permission-prompt-tool stdio
// 它吐的每一行原封不動交給畫面（docs/chat-protocol.md），權限詢問和選擇題由畫面回答。
// 程序第一次送訊息時才開；結束了（或被關掉）下次送訊息會用 --resume 重新接上。

enum ChatStatus: Equatable {
    case idle        // 沒在跑，或這一輪做完了
    case working     // Claude 正在想／做事
    case waiting     // 在等你（權限、選擇題）
}

final class ChatSession {
    private(set) var claudeSession: UUID
    /// 接手別處的對話：下次開程序時從這段複製一份新的（--fork-session），原本那段不受影響
    var forkFrom: UUID?
    /// 開 claude 時用的名字（--name）：別的聊天室用這個名字聯絡（SendMessage／ListAgents）。開的那一刻才問，改名後下次啟動生效
    var nameProvider: (() -> String?)?
    /// 複製出新的對話編號後通知（要存回對話）
    var onForked: ((UUID) -> Void)?
    let directory: String
    /// 收到一行 JSON：原始文字（直接交給網頁）和解析後的物件
    var onLine: ((String, [String: Any]) -> Void)?
    var onStatus: ((ChatStatus) -> Void)?
    /// 程序結束（正常或出錯）；stderr 最後幾行
    var onExit: ((Int32, String) -> Void)?
    /// Claude 回報可以選的模型（啟動時），和目前用的模型
    var onModels: (([ModelChoice]) -> Void)?
    var onCommands: (([SlashCommand]) -> Void)?
    var onModel: ((String) -> Void)?
    /// 權限模式（default、acceptEdits、plan、auto）；nil＝照設定頁。Claude 回報換了（例如計畫通過後離開 plan）也會通知
    var permissionMode: String?
    var onPermissionMode: ((String) -> Void)?
    /// 換模式被 Claude 拒絕（例如這版不支援某個模式）：原因
    var onPermissionModeError: ((String) -> Void)?
    private var modeRequests: [String: (old: String?, mode: String)] = [:]   // request_id → 換之前的模式、要換成的
    private var defaultRequests: [String: (Bool) -> Void] = [:]              // 「設為預設強度」的 request_id → 做完通知
    /// 開程序時用的模型（nil＝預設）；本機模型另外給連線位址
    var model: String?
    var effort: String?
    var localEndpoint: LocalModel?
    /// 不是 nil：這段改跑 agy（Gemini，AgyBridge.swift），值是 agy 的模型名稱
    var agyModel: String?
    private var agy: AgyBridge?
    private var agyCancelled: [String] = []   // ⌃ C／停止 關掉 agy 時正在做的那則：下一個 agy 送第一則時請它忽略
    /// 不是 nil：這段改跑 codex app-server（ChatGPT，CodexBridge.swift），值是模型名稱
    var codexModel: String?
    private var codex: CodexBridge?
    /// 不是 nil：這段改跑 copilot --acp（GitHub Copilot，CopilotBridge.swift），值是模型名稱（免費方案只有 auto）
    var copilotModel: String?
    private var copilot: CopilotBridge?
    /// 不是 nil：這段改跑本機的 MLX 模型（LocalBridge.swift，不開程序，App 自己跟 mlx_lm 伺服器講話），值是模型名稱
    var mlxModel: String?
    private var mlx: LocalBridge?
    /// 不是 nil：這段改跑 Apple 內建的模型（AppleBridge.swift，也不開程序），值是 AppleBridge.model
    var appleModel: String?
    private var apple: AppleBridge?

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var stderrTail = ""
    private var pending: Set<String> = []          // 還沒回答的權限詢問
    private(set) var status: ChatStatus = .idle { didSet { if status != oldValue { onStatus?(status) } } }
    /// 測試時可以換掉（例如加 --model）；平常就是使用者 shell 找得到的 claude
    static var extraArgs: [String] = []
    /// 測試用：把收發的每一行記到這個檔案（main.swift 的 --chat-log）
    static var log: FileHandle?

    init(claudeSession: UUID, directory: String) {
        self.claudeSession = claudeSession
        self.directory = directory
    }

    var isRunning: Bool { process?.isRunning == true || mlx != nil || apple != nil }

    /// ~/Library/Logs/codenv/<時間>-<聊天室>.log；順便刪掉 3 天前的
    static let debugLogDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/codenv")
    static func debugLogPath(name: String) -> String? {
        let fm = FileManager.default
        try? fm.createDirectory(at: debugLogDir, withIntermediateDirectories: true)
        let old = Date().addingTimeInterval(-3 * 86400)
        for f in (try? fm.contentsOfDirectory(at: debugLogDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where f.pathExtension == "log" {
            if let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, m < old { try? fm.removeItem(at: f) }
        }
        let df = DateFormatter(); df.dateFormat = "MMdd-HHmmss"
        let safe = String(name.map { "/:\\".contains($0) ? "_" : $0 }.prefix(40))
        return debugLogDir.appendingPathComponent("\(df.string(from: Date()))-\(safe).log").path
    }
    var pid: Int32? { process?.processIdentifier }

    /// 這段對話在 ~/.claude/projects 底下的紀錄檔
    var transcriptURL: URL? {
        if codexModel != nil { return CodexBridge.transcript(for: claudeSession) }
        if copilotModel != nil { return CopilotBridge.transcript(for: claudeSession) }
        if mlxModel != nil { return LocalBridge.transcript(for: claudeSession) }
        if appleModel != nil { return AppleBridge.transcript(for: claudeSession) }
        return agyModel != nil ? AgyBridge.transcript(for: claudeSession) : Store.claudeTranscript(claudeSession, path: directory)
    }

    /// 這段對話用過的每一家的紀錄檔（換過模型就有好幾份），目前這家排第一、其他照最後修改時間新到舊；名字給分隔線用
    var allTranscripts: [(url: URL, name: String)] {
        let claude = Store.claudeTranscript(claudeSession, path: directory)
        let all: [(URL, String)] = [(claude, Self.claudeModelName(claude) ?? "Claude"), (AgyBridge.transcript(for: claudeSession), "Gemini（agy）"),
                                    (CodexBridge.transcript(for: claudeSession), "ChatGPT"), (CopilotBridge.transcript(for: claudeSession), "Copilot"),
                                    (LocalBridge.transcript(for: claudeSession), "本機模型"), (AppleBridge.transcript(for: claudeSession), "Apple 模型")]
        func mtime(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
        let cur = transcriptURL
        return all.filter { $0.0 == cur || FileManager.default.fileExists(atPath: $0.0.path) }
            .sorted { a, b in a.0 == cur ? true : b.0 == cur ? false : mtime(a.0) > mtime(b.0) }
            .map { (url: $0.0, name: $0.1) }
    }

    /// Claude 紀錄裡第一個回答用的模型（claude-opus-5-5 → Opus 5.5）：分隔線寫「以下換成 Opus 5.5」；只讀開頭 1 MB
    static func claudeModelName(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: 1_000_000), let s = String(data: d, encoding: .utf8) ?? String(data: d.prefix(through: d.lastIndex(of: 0x0a) ?? d.startIndex), encoding: .utf8),
              let r = s.range(of: #""model":"claude-([a-z]+)-([0-9-]+)""#, options: .regularExpression) else { return nil }
        let parts = s[r].dropFirst(16).dropLast().split(separator: "-")   // ["opus", "5", "5"]
        guard let fam = parts.first, parts.count > 1 else { return nil }
        let ver = parts.dropFirst().prefix { $0.count <= 2 }.joined(separator: ".")   // 去掉日期那段（20251001）
        return fam.prefix(1).uppercased() + fam.dropFirst() + (ver.isEmpty ? "" : " " + ver)
    }

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return input != nil || mlx != nil || apple != nil }
        let id = claudeSession.uuidString.lowercased()
        // Gemini（agy）：另一套參數，沒有 --name、--debug-file、Artifact 這些 claude 才認得的
        if let m = agyModel {
            let run = AgyBridge.resolve(m, effort: effort)
            let args = AgyBridge.arguments(model: run, mode: permissionMode ?? Prefs.shared.permissionMode,
                                           conversation: AgyBridge.conversation(for: claudeSession))
            // 系統說沒網路就先不開 agy（不然它會開瀏覽器登入頁）；只看已知狀態，不卡主執行緒。ChatPane 送出前已經擋過一次
            guard AgyBridge.enabled else { onExit?(-1, L("agy 功能是關著的（設定 ⌘ , → 對話 → agy）。打開前會先請你看一段 Google 的條款說明。")); return false }
            guard AgyNet.quickOK else { onExit?(-1, AgyNet.offlineMessage); return false }
            let b = AgyBridge(session: claudeSession, model: run)
            b.cancelled = agyCancelled
            agyCancelled = []
            return spawn(AgyBridge.executable, args, env: [:], bridge: b)
        }
        // ChatGPT（codex app-server）：一直開著，訊息、權限都走 JSON-RPC
        if let m = codexModel {
            let b = CodexBridge(session: claudeSession, directory: directory, model: m)
            b.mode = permissionMode ?? Prefs.shared.permissionMode
            b.effort = effort
            b.send = { [weak self] in self?.rawWrite($0) }
            b.emit = { [weak self] in self?.emit($0) }
            guard spawn("codex", ["app-server"], env: [:], bridge: nil) else { return false }
            codex = b
            b.start()
            return true
        }
        // 本機模型（MLX）：沒有程序，LocalBridge 自己發 HTTP、自己做工具
        if let m = mlxModel {
            let b = LocalBridge(session: claudeSession, directory: directory, model: m)
            b.mode = permissionMode ?? Prefs.shared.permissionMode
            b.effort = effort
            b.emit = { [weak self] in self?.emit($0) }
            mlx = b
            b.start()
            return true
        }
        // Apple 內建的模型：一樣沒有程序，AppleBridge 直接呼叫系統的 Foundation Models
        if appleModel != nil {
            let b = AppleBridge(session: claudeSession, directory: directory)
            b.emit = { [weak self] in self?.emit($0) }
            apple = b
            b.start()
            return true
        }
        // GitHub Copilot（copilot --acp）：跟 codex 一樣一直開著；模型、強度只能開的時候帶
        if let m = copilotModel {
            let b = CopilotBridge(session: claudeSession, directory: directory, model: m)
            b.mode = permissionMode ?? Prefs.shared.permissionMode
            b.send = { [weak self] in self?.rawWrite($0) }
            b.emit = { [weak self] in self?.emit($0) }
            guard spawn("copilot", CopilotBridge.arguments(model: m, effort: effort), env: [:], bridge: nil) else { return false }
            copilot = b
            b.start()
            return true
        }
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
                    "--include-partial-messages", "--verbose", "--permission-prompt-tool", "stdio",
                    "--replay-user-messages"]   // Claude 真的讀進訊息時會回送一份：排隊中的訊息靠這個知道什麼時候被讀到
        let suggest = Prefs.shared.promptSuggestions && localEndpoint == nil
        if suggest { args += ["--prompt-suggestions"] }
        if Prefs.shared.claudeInChrome, localEndpoint == nil, !Self.extraArgs.contains("--no-chrome") { args += ["--chrome"] }
        // 接手：新的 id 等程序真的開起來才記下（開不起來就還是原本那段，下次再試）
        var forked: UUID?
        if let old = forkFrom {
            let new = UUID()
            args += ["--session-id", new.uuidString.lowercased(), "--fork-session", "--resume", old.uuidString.lowercased()]
            forked = new
        } else {
            let resume = Store.claudeHasSession(claudeSession, path: directory)
            args += resume ? ["--resume", id] : ["--session-id", id]
        }
        if let local = localEndpoint { args += ["--model", local.model] }
        else if let model { args += ["--model", model] }
        if let effort { args += ["--effort", effort] }
        let shownName = nameProvider?()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !shownName.isEmpty, !Self.extraArgs.contains("--name") { args += ["--name", shownName] }
        // 除錯紀錄（設定裡打開）：一個 claude 一個檔，查 MCP 斷線等問題用
        if Prefs.shared.claudeDebugLog, !Self.extraArgs.contains("--debug-file"), let f = Self.debugLogPath(name: shownName.isEmpty ? String(id.prefix(8)) : shownName) {
            args += ["--debug-file", f]
        }
        if let mode = permissionMode ?? Prefs.shared.permissionMode, !Self.extraArgs.contains("--permission-mode") { args += ["--permission-mode", mode] }
        args += Self.extraArgs
        var env: [String: String] = [:]
        if let local = localEndpoint {
            // 本機模型：改連使用者自己的伺服器（要講 Anthropic Messages API 的格式）
            env["ANTHROPIC_BASE_URL"] = local.baseURL
            env["ANTHROPIC_AUTH_TOKEN"] = local.token.isEmpty ? "local" : local.token
        }
        // -p 模式預設不給建議，要用環境變數打開
        if suggest { env["CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION"] = "true" }
        // Artifact（發布網頁到 claude.ai/artifact）在 -p 模式預設關著（sdk_default_off），終端機才有；這個變數打開它
        if Prefs.shared.artifacts, localEndpoint == nil { env["CLAUDE_CODE_ARTIFACT"] = "1" }
        // 自動壓縮的門檻（⌘ , 對話頁「自動壓縮上下文」；使用者 10/25 要能自己調，預設 640K）
        env["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] = String(Prefs.shared.cloudCompactTokens)
        guard spawn("claude", args, env: env, bridge: nil) else { return false }
        if let forked {
            claudeSession = forked
            forkFrom = nil
            onForked?(forked)
        }
        write(["type": "control_request", "request_id": UUID().uuidString, "request": ["subtype": "initialize"]])
        return true
    }

    /// 開程序：用登入 shell 找（PATH 跟平常一樣），exec 之後就是 claude（或 agy）本人。env 是要另外加的
    private func spawn(_ command: String, _ args: [String], env extra: [String: String], bridge: AgyBridge?) -> Bool {
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-l", "-c", "exec \(command == "claude" ? command : q(command)) \(args.map(q).joined(separator: " "))"]
        p.currentDirectoryURL = URL(fileURLWithPath: directory)
        var env: [String: String] = [:]
        for kv in Workspace.environment() {
            if let i = kv.firstIndex(of: "=") { env[String(kv[..<i])] = String(kv[kv.index(after: i)...]) }
        }
        env.merge(extra) { $1 }
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        // 讀到空的＝對方關了：把 handler 拿掉，不然格子關掉或程序換掉之後它會一直空轉
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.received(d) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            let s = String(decoding: d, as: UTF8.self)
            DispatchQueue.main.async {
                guard let self else { return }
                self.stderrTail = String((self.stderrTail + s).suffix(2000))
            }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, self.process === proc else { return }
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                self.input = nil
                self.agy = nil
                self.codex = nil
                self.copilot = nil
                self.pending.removeAll()
                self.status = .idle
                self.onExit?(proc.terminationStatus, self.stderrTail)
            }
        }
        do { try p.run() } catch {
            onExit?(-1, L("開不了 \(bridge == nil ? "claude" : "agy")：\(error.localizedDescription)"))
            return false
        }
        process = p
        input = inPipe.fileHandleForWriting
        agy = bridge
        return true
    }

    /// 送出使用者的訊息（文字＋圖片 PNG/JPEG）。uuid 用來對回 Claude 讀進去的那份回送；
    /// now：Claude 還在做的話叫它停下目前這一步、先讀這則（終端機的 ⌃ Enter）
    func send(text: String, images: [(data: Data, mediaType: String)], uuid: String, now: Bool = false) {
        guard start() else { return }
        let wasBusy = status != .idle
        var content: [[String: Any]] = images.map {
            ["type": "image", "source": ["type": "base64", "media_type": $0.mediaType, "data": $0.data.base64EncodedString()]]
        }
        if !text.isEmpty { content.append(["type": "text", "text": text]) }
        guard !content.isEmpty else { return }
        write(["type": "user", "uuid": uuid, "message": ["role": "user", "content": content]])
        status = .working
        // ⌃ Enter：不看 status 決定送不送（它可能慢一拍，以為閒著就只會排隊）；真的閒著 claude 會回 nothing_waiting，沒影響。
        // 本來就閒著的不重試（訊息會直接被讀，只是要等幾秒才回送）
        if now { sendNow(uuid, tries: wasBusy ? 0 : 5) }
    }

    /// 插話要求：request_id → (訊息 uuid, 試了幾次)
    private var sendNowRequests: [String: (uuid: String, tries: Int)] = [:]
    /// Claude 已經讀進去的訊息（回送過的）
    private var taken: Set<String> = []

    /// 排隊中的訊息馬上送進去：停下目前這一步（不是整個停止），Claude 接著讀這則
    func sendNow(_ uuid: String, tries: Int = 0) {
        if let codex { codex.steer(uuid); return }
        if let copilot { copilot.steer(uuid); return }
        if let mlx { mlx.steer(uuid); return }
        if let apple { apple.steer(uuid); return }
        guard isRunning, agy == nil, !taken.contains(uuid) else { return }   // agy 不能插話：照順序等這一輪做完
        let id = UUID().uuidString
        sendNowRequests[id] = (uuid, tries)
        write(["type": "control_request", "request_id": id, "request": ["subtype": "interrupt", "send_now": true, "message_uuid": uuid]])
    }

    /// 回答權限詢問／選擇題（畫面傳來的）
    func answerPermission(requestID: String, behavior: String, updatedInput: Any?, updatedPermissions: Any?, message: String?) {
        var r: [String: Any] = ["behavior": behavior]
        if behavior == "allow" {
            r["updatedInput"] = updatedInput ?? [String: Any]()
            if let u = updatedPermissions { r["updatedPermissions"] = u }
        } else {
            r["message"] = message ?? "使用者拒絕"
        }
        write(["type": "control_response", "response": ["subtype": "success", "request_id": requestID, "response": r]])
        pending.remove(requestID)
        if pending.isEmpty, status == .waiting { status = .working }
    }

    /// 換模型：程序在跑就直接叫它換（下一則訊息開始用），沒在跑就等下次開的時候帶上
    /// ChatGPT（codex）換模型：在跑的話下一輪就用，不用重開
    func setCodexModel(_ m: String) {
        codexModel = m
        codex?.model = m
    }

    func setModel(_ value: String?) {
        model = value
        if codex != nil || copilot != nil || mlx != nil || apple != nil { return }   // codex、copilot、本機換模型走 ChatPane.applyModel
        guard isRunning else { return }
        var req: [String: Any] = ["subtype": "set_model"]
        if let value { req["model"] = value }
        write(["type": "control_request", "request_id": UUID().uuidString, "request": req])
    }

    /// 換思考強度：程序在跑就送 /effort（這版 Claude 沒有對應的控制指令，斜線指令實測有效），沒在跑就等下次開的時候帶 --effort
    func setEffort(_ value: String?) {
        effort = value
        if let codex { codex.effort = value; return }   // codex 下一輪就用新的
        if let mlx { mlx.effort = value; return }
        if apple != nil { return }   // Apple 模型沒有強度可調
        if agy != nil || copilot != nil { restartAgyIfIdle(); return }   // 開的時候才能帶：閒著就重開
        guard isRunning, let value else { return }
        write(["type": "user", "message": ["role": "user", "content": "/effort \(value)"]])
    }

    /// 把強度存成這個模型的預設：交給 Claude Code 自己寫 ~/.claude/settings.json（update_settings，跟 /effort 存檔同一條路，
    /// 只動 modelSettings.<目前的模型>.effortLevel，其他設定原樣保留；max 它不存）。只有 Claude 本人才有這個指令
    func saveDefaultEffort(_ value: String, done: @escaping (Bool) -> Void) {
        guard agyModel == nil, codexModel == nil, copilotModel == nil, mlxModel == nil, appleModel == nil, localEndpoint == nil,
              start() else { done(false); return }
        let id = UUID().uuidString
        defaultRequests[id] = done
        write(["type": "control_request", "request_id": id,
               "request": ["subtype": "update_settings", "source": "userSettings", "settings": ["effortLevel": value]]])
    }

    /// 換權限模式（像在終端機按 ⇧ Tab）：程序在跑就直接叫它換，沒在跑就等下次開的時候帶 --permission-mode
    func setPermissionMode(_ mode: String) {
        let old = permissionMode
        permissionMode = mode
        if let codex { codex.mode = mode; return }
        if let copilot { copilot.mode = mode; return }
        if let mlx { mlx.mode = mode; return }
        if apple != nil { return }   // 沒有工具，權限模式用不到
        if agy != nil { restartAgyIfIdle(); return }
        guard isRunning else { return }
        let id = UUID().uuidString
        modeRequests[id] = (old, mode)
        write(["type": "control_request", "request_id": id, "request": ["subtype": "set_permission_mode", "mode": mode]])
    }

    /// 停止目前這一輪（像在終端機按 Esc）
    func interrupt() {
        guard isRunning, status != .idle else { return }
        if let codex { codex.interrupt(); return }
        if let copilot { copilot.interrupt(); return }
        if let mlx { mlx.interrupt(); return }
        if let apple { apple.interrupt(); return }
        // agy 沒有「停下這一輪」的指令：直接關掉，下一則用 --conversation 接回去
        if let agy {
            if let t = agy.interruptedText() { agyCancelled.append(t) }
            emit(["type": "user", "message": ["role": "user", "content": "[Request interrupted by user]"]])
            emit(["type": "result", "subtype": "error_during_execution", "is_error": true])
            terminate()
            return
        }
        write(["type": "control_request", "request_id": UUID().uuidString, "request": ["subtype": "interrupt"]])
    }

    /// agy 開了就不能換模式、強度（copilot 不能換強度）：閒著就先關掉，下一則訊息用新的參數開（做到一半的就等下一次）
    private func restartAgyIfIdle() {
        if status == .idle { terminate() }
    }

    /// 關掉程序。馬上放手（不等它真的結束），之後送訊息會直接開新的接回去
    func terminate() {
        try? input?.close()
        input = nil
        process?.terminate()
        process = nil
        agy = nil
        codex = nil
        copilot = nil
        mlx?.close()
        mlx = nil
        apple?.close()
        apple = nil
        pending.removeAll()
        status = .idle
    }

    // MARK: -

    private func write(_ obj: [String: Any]) {
        if let codex { codex.outgoing(obj); return }   // codex 自己翻成 JSON-RPC 再寫
        if let copilot { copilot.outgoing(obj); return }
        if mlx != nil || apple != nil {   // 本機沒有程序：測試紀錄在這裡記
            if let d = try? JSONSerialization.data(withJSONObject: obj) { Self.log?.write(Data("→ ".utf8) + d + Data([0x0a])) }
            if let mlx { mlx.outgoing(obj) } else { apple?.outgoing(obj) }
            return
        }
        var obj = obj
        if let agy { guard let o = agy.outgoing(obj) else { return }; obj = o }   // agy 的格式；它沒有的功能（控制指令）不送
        rawWrite(obj)
    }

    private func rawWrite(_ obj: [String: Any]) {
        guard let input, let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        // claude 剛好結束時寫會失敗；用會丟錯誤的版本，不要讓整個 App 跟著當掉
        do { try input.write(contentsOf: d + Data([0x0a])) } catch { self.input = nil; return }
        Self.log?.write(Data("→ ".utf8) + d + Data([0x0a]))
    }

    private func received(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0a) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] else { continue }
            Self.log?.write(Data("← ".utf8) + lineData + Data([0x0a]))
            if let agy { agy.incoming(obj).forEach(emit) } else if let codex { codex.incoming(obj) } else if let copilot { copilot.incoming(obj) } else { track(obj); onLine?(line, obj) }
        }
    }

    /// 自己做出來的事件（agy 翻好的）交給畫面，跟 claude 吐的一樣處理
    private func emit(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj), let line = String(data: d, encoding: .utf8) else { return }
        if mlx != nil || apple != nil, obj["type"] as? String != "stream_event" { Self.log?.write(Data("← ".utf8) + d + Data([0x0a])) }
        track(obj)
        onLine?(line, obj)
    }

    /// 從事件推出目前狀態（給側欄的燈號）
    private func track(_ o: [String: Any]) {
        switch o["type"] as? String {
        case "control_request":
            if let req = o["request"] as? [String: Any], req["subtype"] as? String == "can_use_tool", let id = o["request_id"] as? String {
                pending.insert(id)
                status = .waiting
            }
        case "control_cancel_request":
            if let id = o["request_id"] as? String { pending.remove(id) }
            if pending.isEmpty, status == .waiting { status = .working }
        case "result":
            pending.removeAll()
            status = .idle
        case "control_response":
            // 插話回「沒有等待中的訊息」：訊息可能還沒排進 claude 的佇列（剛寫進去就要求），等一下再要求，最多 6 次
            if let r = o["response"] as? [String: Any], let id = r["request_id"] as? String, let req = sendNowRequests.removeValue(forKey: id) {
                let said = (r["response"] as? [String: Any])?["send_now"] as? String
                if said == "nothing_waiting", req.tries < 5, !taken.contains(req.uuid) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.sendNow(req.uuid, tries: req.tries + 1) }
                }
            }
            if let r = o["response"] as? [String: Any], let id = r["request_id"] as? String, let req = modeRequests.removeValue(forKey: id),
               r["subtype"] as? String == "error" {
                // 只有還停在這次要換的模式才退回（之後又按了 ⇧ Tab 就不要蓋掉）
                if permissionMode == req.mode { permissionMode = req.old }
                onPermissionModeError?(r["error"] as? String ?? "")
            }
            if let r = o["response"] as? [String: Any], let id = r["request_id"] as? String, let done = defaultRequests.removeValue(forKey: id) {
                done(r["subtype"] as? String == "success")
            }
            // initialize 的回覆裡有可選的模型清單
            if let r = (o["response"] as? [String: Any])?["response"] as? [String: Any], let ms = r["models"] as? [[String: Any]] {
                let list = ms.compactMap(ModelChoice.init)
                if !list.isEmpty { ModelChoice.remember(list); onModels?(list) }
            }
            // 也有斜線指令清單（給輸入框的 / 選單）
            if let r = (o["response"] as? [String: Any])?["response"] as? [String: Any], let cs = r["commands"] as? [[String: Any]] {
                let list = cs.compactMap(SlashCommand.init)
                if !list.isEmpty { SlashCommand.remember(list); onCommands?(list) }
            }
        case "system":
            if o["subtype"] as? String == "init", let m = o["model"] as? String { onModel?(m) }
            if o["subtype"] as? String == "init", let t = o["terminal_slash_commands"] as? [String] { SlashCommand.terminalOnly = Set(t) }
            if let pm = o["permissionMode"] as? String, pm != permissionMode { permissionMode = pm; onPermissionMode?(pm) }
        case "stream_event", "assistant":
            if pending.isEmpty { status = .working }
        case "user":
            // Claude 讀進了排隊的訊息（回送）：下一輪開始了
            if o["isReplay"] as? Bool == true {
                if let u = o["uuid"] as? String { taken.insert(u.lowercased()) }
                // 換模型的回報（從預設換過去時 claude 會回一則「Set model to …」）不是一輪的開始：後面沒有 result，當成開工會一直轉圈
                let local = ((o["message"] as? [String: Any])?["content"] as? String)?.hasPrefix("<local-command-stdout>") == true
                if pending.isEmpty, !local { status = .working }
            }
        default: break
        }
    }
}

/// 權限模式：⇧ Tab 的順序跟 Claude Code 一樣（bypassPermissions 要另外的啟動參數，不放進來）
enum PermissionMode {
    static let cycle = ["default", "acceptEdits", "plan", "auto"]
    static func next(after m: String) -> String {
        guard let i = cycle.firstIndex(of: m) else { return cycle[0] }
        return cycle[(i + 1) % cycle.count]
    }
    /// 輸入框上那顆按鈕的字
    static func label(_ m: String) -> String {
        switch m {
        case "acceptEdits": return L("⏵⏵ 改檔不問")
        case "plan": return L("⏸ 只規劃")
        case "auto": return L("⏵⏵ 自動")
        case "bypassPermissions": return L("⏵⏵ 全部不問")
        default: return L("每次都問")
        }
    }
}

/// 模型選單的一項（Claude 啟動時回報的清單）
struct ModelChoice: Codable, Equatable {
    let value: String          // 傳給 --model／set_model 的
    let resolved: String       // 實際的模型全名
    let name: String           // 顯示的名字
    let detail: String
    /// 這個模型可以選的思考強度（舊存檔沒有這欄）
    var efforts: [String]? = nil

    init?(_ d: [String: Any]) {
        guard let v = d["value"] as? String else { return nil }
        value = v
        resolved = d["resolvedModel"] as? String ?? v
        name = d["displayName"] as? String ?? v
        detail = d["description"] as? String ?? ""
        efforts = d["supportedEffortLevels"] as? [String]
    }
    init(value: String, resolved: String, name: String, detail: String) {
        self.value = value; self.resolved = resolved; self.name = name; self.detail = detail
    }

    /// 上次 Claude 回報的清單（還沒開過程序時先用這份）
    static var known: [ModelChoice] {
        if let d = appDefaults.data(forKey: "modelChoices"), let l = try? JSONDecoder().decode([ModelChoice].self, from: d), !l.isEmpty { return l }
        return [ModelChoice(value: "default", resolved: "", name: L("預設"), detail: ""),
                ModelChoice(value: "opus", resolved: "", name: "Opus", detail: ""),
                ModelChoice(value: "fable", resolved: "", name: "Fable", detail: ""),
                ModelChoice(value: "sonnet", resolved: "", name: "Sonnet", detail: ""),
                ModelChoice(value: "haiku", resolved: "", name: "Haiku", detail: "")]
    }
    static func remember(_ l: [ModelChoice]) {
        if let d = try? JSONEncoder().encode(l) { appDefaults.set(d, forKey: "modelChoices") }
    }
}

/// 自己架的本機模型伺服器（要能講 Anthropic Messages API，例如 llama.cpp 的 llama-server、LiteLLM 轉接）
struct LocalModel: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String           // 選單上顯示的
    var baseURL: String        // 例如 http://127.0.0.1:8080
    var model: String          // 傳給 --model 的名字
    var token: String = ""

    static var all: [LocalModel] {
        get { (appDefaults.data(forKey: "localModels")).flatMap { try? JSONDecoder().decode([LocalModel].self, from: $0) } ?? [] }
        set { appDefaults.set(try? JSONEncoder().encode(newValue), forKey: "localModels") }
    }
}

enum Effort {
    static let names = ["low": L("低"), "medium": L("中"), "high": L("高"), "xhigh": L("很高"), "max": L("最高")]
    static let order = ["low", "medium", "high", "xhigh", "max"]
    static func name(_ v: String) -> String { names[v] ?? v }
}
