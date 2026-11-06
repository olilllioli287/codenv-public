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
    /// 模型已經知道的聊天室名稱（沒帶過是 nil）。Claude 開程序時用 --append-system-prompt 帶，其他家和改名之後在下一則訊息後面附一行（ChatPane.send），送出成功才記
    var announcedName: String?
    static let nameMarker = "〔codenv 聊天室名稱〕"
    /// 給模型的一句話（不用 L()：這是提示詞）。要它被問到直接照答，不要依內容編
    static func nameNote(_ name: String) -> String {
        nameMarker + "這段對話在 codenv 裡的聊天室名稱目前是「\(name)」（使用者在側欄看到的名字，不是對話主題）。使用者問聊天室名稱時直接回這個名字，不要依對話內容自己編。改名後我會再附一行，以最新的為準。"
    }
    /// 下一則訊息要不要附名稱：名字有而且跟模型知道的不一樣才回傳（名字、要記的值）
    func pendingNameNote() -> (note: String, name: String)? {
        guard let n = nameProvider?()?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty, n != announcedName else { return nil }
        return (Self.nameNote(n), n)
    }
    /// 複製出新的對話編號後通知（要存回對話）
    var onForked: ((UUID) -> Void)?
    let directory: String
    /// 收到一行 JSON：原始文字（直接交給網頁）和解析後的物件
    var onLine: ((String, [String: Any]) -> Void)?
    var onStatus: ((ChatStatus) -> Void)?
    /// 程序結束（正常或出錯）；stderr 最後幾行
    var onExit: ((Int32, String) -> Void)?
    /// 主動 terminate()（換模型、關格、停 agy）：舊程序的 terminationHandler 會略過、onExit 不會來，靠這個清它留下的活動紀錄
    var onTerminated: (() -> Void)?
    /// 程序結束時仍未收到 UUID 回送：送達狀態不確定，寄件匣繼續保留。
    var onLost: (([(uuid: String, text: String, images: [(data: Data, mediaType: String)], quotes: [MessageQuote])]) -> Void)?
    private var unacked: [(uuid: String, text: String, images: [(data: Data, mediaType: String)], quotes: [MessageQuote])] = []
    var outboxPersistence: OutboxPersistence?
    var onOutboxError: ((String) -> Void)?
    /// result 後仍可能有未回送的排隊訊息，不能只靠 status 判斷畫面能否卸載。
    var hasUnacknowledgedInput: Bool { !unacked.isEmpty }
    /// 這次程序裡已送出、還在等回送的訊息編號（寄件匣對照時要排除：它們還在路上，不是「上次沒送到」）
    var inFlightIDs: Set<String> { Set(unacked.map(\.uuid)) }
    /// Claude 回報可以選的模型（啟動時），和目前用的模型
    var onModels: (([ModelChoice]) -> Void)?
    var onCommands: (([SlashCommand]) -> Void)?
    var onModel: ((String) -> Void)?
    /// 權限模式（default、acceptEdits、plan、auto）；nil＝照設定頁。Claude 回報換了（例如計畫通過後離開 plan）也會通知
    var permissionMode: String?
    /// Claude 包在 nono 沙盒裡跑（NonoSandbox.swift）；下次開程序才生效
    var sandboxed = false
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
    /// 寫進程序 stdin 的序列佇列：大訊息（貼圖、長文）超過 pipe 緩衝 64 KB 時，對方還沒讀（剛啟動、卡住）寫入會阻塞，
    /// 放主執行緒會讓整個 App 沒回應（實測不讀 stdin 的假 claude＋120 KB 訊息：卡到它結束）。序列佇列保證送出順序（agy Argon 11/6）
    /// 每個程序一條（spawn 時換新的）：舊程序不理結束訊號、寫入一直卡著時，新程序的寫入不能排在它後面
    private var writeQueue = DispatchQueue(label: "codenv.chat.stdin")
    /// 這個程序的寫入閘：terminate 時關上，佇列裡還沒寫出去的就不寫了，保證「沒寫出去＝沒送到」，onLost 放回輸入框才不會跟 Claude 收到的重複（agy Opus 11/6）
    private var writeGate = WriteGate()
    private var buffer = Data()
    private var stderrTail = ""
    private var pending: Set<String> = []          // 還沒回答的權限詢問
    private(set) var status: ChatStatus = .idle { didSet { if status != oldValue { onStatus?(status) } } }
    /// 測試時可以換掉（例如加 --model）；平常就是使用者 shell 找得到的 claude
    static var testClaude: String? = {
        let a = CommandLine.arguments
        guard a.contains("--state-dir"), let i = a.firstIndex(of: "--chat-claude"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }()
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
    /// 事件紀錄專用的模型分類（claude、agy、codex、copilot、local、apple）
    var modelCategory: String {
        if agyModel != nil { return "agy" }
        if codexModel != nil { return "codex" }
        if copilotModel != nil { return "copilot" }
        if mlxModel != nil { return "local" }
        if appleModel != nil { return "apple" }
        if localEndpoint != nil { return "local" }
        return "claude"
    }
    /// 事件紀錄專用的對話識別標籤：不記標題自由文字，只記 UUID 前 8 碼與模型類別
    var convTag: String {
        "對話 \(String(claudeSession.uuidString.prefix(8).uppercased()))（\(modelCategory)）"
    }

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
        // 沙盒只包得住 Claude：換成 Gemini、ChatGPT、Copilot、本機、Apple 時不要假裝有包（agy Sonnet 11/6）
        if sandboxed, agyModel != nil || codexModel != nil || copilotModel != nil || mlxModel != nil || appleModel != nil {
            emit(["type": "result", "subtype": "error_during_execution", "is_error": true, "result": L("沙盒目前只支援 Claude 模型。換回 Claude，或右鍵關掉「在沙盒裡跑」")])
            return false
        }
        let id = claudeSession.uuidString.lowercased()
        announcedName = nil      // 新的程序還沒聽過名字（Claude 下面用系統提示帶；其他家等第一則訊息附）
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
            if spawn(AgyBridge.executable, args, env: [:], bridge: b) {
                let pIdentifier = process?.processIdentifier ?? 0
                EventLog.log("聊天程序", "\(convTag)：已啟動（pid \(pIdentifier)）")
                return true
            } else {
                EventLog.log("聊天程序", "\(convTag)：啟動失敗")
                return false
            }
        }
        // ChatGPT（codex app-server）：一直開著，訊息、權限都走 JSON-RPC
        if let m = codexModel {
            let b = CodexBridge(session: claudeSession, directory: directory, model: m)
            b.mode = permissionMode ?? Prefs.shared.permissionMode
            b.effort = effort
            b.send = { [weak self] in self?.rawWrite($0) }
            b.emit = { [weak self] in self?.emit($0) }
            if spawn("codex", ["app-server"], env: [:], bridge: nil) {
                codex = b
                b.start()
                let pIdentifier = process?.processIdentifier ?? 0
                EventLog.log("聊天程序", "\(convTag)：已啟動（pid \(pIdentifier)）")
                return true
            } else {
                EventLog.log("聊天程序", "\(convTag)：啟動失敗")
                return false
            }
        }
        // 本機模型（MLX）：沒有程序，LocalBridge 自己發 HTTP、自己做工具
        if let m = mlxModel {
            let b = LocalBridge(session: claudeSession, directory: directory, model: m)
            b.mode = permissionMode ?? Prefs.shared.permissionMode
            b.effort = effort
            b.chatName = { [weak self] in self?.nameProvider?() }
            b.emit = { [weak self] in self?.emit($0) }
            mlx = b
            b.start()
            EventLog.log("聊天程序", "\(convTag)：已啟動")
            return true
        }
        // Apple 內建的模型：一樣沒有程序，AppleBridge 直接呼叫系統的 Foundation Models
        if appleModel != nil {
            let b = AppleBridge(session: claudeSession, directory: directory)
            b.chatName = { [weak self] in self?.nameProvider?() }
            b.emit = { [weak self] in self?.emit($0) }
            apple = b
            b.start()
            EventLog.log("聊天程序", "\(convTag)：已啟動")
            return true
        }
        // GitHub Copilot（copilot --acp）：跟 codex 一樣一直開著；模型、強度只能開的時候帶
        if let m = copilotModel {
            let b = CopilotBridge(session: claudeSession, directory: directory, model: m)
            b.mode = permissionMode ?? Prefs.shared.permissionMode
            b.send = { [weak self] in self?.rawWrite($0) }
            b.emit = { [weak self] in self?.emit($0) }
            if spawn("copilot", CopilotBridge.arguments(model: m, effort: effort), env: [:], bridge: nil) {
                copilot = b
                b.start()
                let pIdentifier = process?.processIdentifier ?? 0
                EventLog.log("聊天程序", "\(convTag)：已啟動（pid \(pIdentifier)）")
                return true
            } else {
                EventLog.log("聊天程序", "\(convTag)：啟動失敗")
                return false
            }
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
        // 名字也放進系統提示（不進紀錄檔、不會出現在泡泡）：--resume 也每次重帶；改名後改在下一則訊息附一行
        if !shownName.isEmpty, !Self.extraArgs.contains("--append-system-prompt") {
            args += ["--append-system-prompt", Self.nameNote(shownName)]
            announcedName = shownName
        }
        // 除錯紀錄（設定裡打開）：一個 claude 一個檔，查 MCP 斷線等問題用
        if Prefs.shared.claudeDebugLog, !Self.extraArgs.contains("--debug-file"), let f = Self.debugLogPath(name: shownName.isEmpty ? String(id.prefix(8)) : shownName) {
            args += ["--debug-file", f]
        }
        if let mode = permissionMode ?? Prefs.shared.permissionMode, !Self.extraArgs.contains("--permission-mode") { args += ["--permission-mode", mode] }
        args += Self.extraArgs
        var env: [String: String] = [:]
        if let local = localEndpoint {
            // 位址不合規定（http 連到非本機）：不啟動，金鑰和對話不會明文送出去（設定頁的紅字說明原因）
            if let why = local.addressProblem {
                emit(["type": "result", "subtype": "error_during_execution", "is_error": true, "result": L("「\(local.name)」沒有啟動：") + why])
                return false
            }
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
        // 沙盒：nono 擋掉鑰匙圈，登入權杖由這裡（沙盒外）取出、用環境變數帶進去
        var wrap: [String]? = nil
        // 本機模型（自己的伺服器）不包沙盒：不要假裝有包，直接說
        if sandboxed, localEndpoint != nil {
            emit(["type": "result", "subtype": "error_during_execution", "is_error": true, "result": L("沙盒目前不支援本機模型。換回 Claude 模型，或右鍵關掉「在沙盒裡跑」")])
            return false
        }
        if sandboxed {
            switch NonoSandbox.prepare(directory: directory) {
            case .failure(let why):
                emit(["type": "result", "subtype": "error_during_execution", "is_error": true, "result": L("沙盒沒有啟動：") + why.description])
                EventLog.log("聊天程序", "\(convTag)：沙盒沒有啟動（\(why.description)）")
                return false
            case .success(let s):
                wrap = s.prefix
                env.merge(s.env) { $1 }
                EventLog.log("聊天程序", "\(convTag)：用 nono 沙盒啟動（\(s.longLived ? "長效權杖" : "暫用目前的登入權杖")）")
            }
        }
        guard spawn("claude", args, env: env, bridge: nil, wrap: wrap) else {
            EventLog.log("聊天程序", "\(convTag)：啟動失敗")
            return false
        }
        if let forked {
            claudeSession = forked
            forkFrom = nil
            onForked?(forked)
        }
        // initialize 寫入成功代表 Claude 真的接受控制，才記已啟動；失敗就記啟動失敗加代碼
        if write(["type": "control_request", "request_id": UUID().uuidString, "request": ["subtype": "initialize"]]) {
            let pIdentifier = process?.processIdentifier ?? 0
            EventLog.log("聊天程序", "\(convTag)：已啟動（pid \(pIdentifier)）")
            return true
        } else {
            let code = process?.isRunning == false ? process!.terminationStatus : -1      // 還沒結束時讀 terminationStatus 會丟例外讓 App 當掉
            EventLog.log("聊天程序", "\(convTag)：啟動失敗（代碼 \(code)）")
            return false
        }
    }

    /// 開程序：用登入 shell 找（PATH 跟平常一樣），exec 之後就是 claude（或 agy）本人。env 是要另外加的
    private func spawn(_ command: String, _ args: [String], env extra: [String: String], bridge: AgyBridge?, wrap: [String]? = nil) -> Bool {
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // 測試（--state-dir 才有用）：--chat-claude <路徑> 把聊天室的 claude 換成假的，看它收到什麼
        var exe = command == "claude" ? (Self.testClaude.map(q) ?? command) : q(command)
        if let wrap { exe = wrap.map(q).joined(separator: " ") + " " + exe }
        p.arguments = ["-l", "-c", "exec \(exe) \(args.map(q).joined(separator: " "))"]
        p.currentDirectoryURL = URL(fileURLWithPath: directory)
        var env: [String: String] = [:]
        for kv in Workspace.environment() {
            if let i = kv.firstIndex(of: "=") { env[String(kv[..<i])] = String(kv[kv.index(after: i)...]) }
        }
        // 隔離測試的假 Claude 也要寫到 --claude-home 指定的暫存紀錄資料夾。
        if Self.testClaude != nil {
            env["AI_WORKBENCH_TEST_CWD"] = directory
            if let i = CommandLine.arguments.firstIndex(of: "--claude-home"),
               i + 1 < CommandLine.arguments.count {
                env["CLAUDE_CONFIG_DIR"] = CommandLine.arguments[i + 1]
            }
        }
        env.merge(extra) { $1 }
        p.environment = env
        // 新程序開始：前一個程序留下的半行輸出和 stderr 不能黏到新程序的第一行
        buffer = Data()
        stderrTail = ""
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        // 讀到空的＝對方關了：把 handler 拿掉，不然格子關掉或程序換掉之後它會一直空轉
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            // 只收「現在這個程序」的輸出：舊程序被 terminate 之後、管線還沒 EOF 前晚到的輸出不能混進新的對話
            DispatchQueue.main.async { guard let self, self.process === p else { return }; self.received(d) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            let s = String(decoding: d, as: UTF8.self)
            DispatchQueue.main.async {
                guard let self, self.process === p else { return }
                self.stderrTail = String((self.stderrTail + s).suffix(2000))
            }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, self.process === proc else { return }
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                EventLog.log("聊天程序", "\(self.convTag)：程序結束（pid \(proc.processIdentifier)，代碼 \(proc.terminationStatus)）")
                self.process = nil
                self.input = nil
                self.agy = nil
                self.codex = nil
                self.copilot = nil
                self.pending.removeAll()
                let callbacks = self.defaultRequests.values
                self.defaultRequests.removeAll()
                callbacks.forEach { $0(false) }
                self.status = .idle
                let lost = self.unacked
                self.unacked.removeAll()
                if !lost.isEmpty { self.onLost?(lost) }
                self.onExit?(proc.terminationStatus, self.stderrTail)
            }
        }
        do { try p.run() } catch {
            onExit?(-1, L("開不了 \(bridge == nil ? "claude" : "agy")：\(error.localizedDescription)"))
            return false
        }
        process = p
        input = inPipe.fileHandleForWriting
        writeQueue = DispatchQueue(label: "codenv.chat.stdin")
        writeGate = WriteGate()
        agy = bridge
        return true
    }

    /// 送出使用者的訊息（文字＋圖片 PNG/JPEG）。uuid 用來對回 Claude 讀進去的那份回送；
    /// now：Claude 還在做的話叫它停下目前這一步、先讀這則（終端機的 ⌃ Enter）
    @discardableResult
    func send(text: String, images: [(data: Data, mediaType: String)], uuid: String, now: Bool = false, displayText: String? = nil, quotes: [MessageQuote] = [], filePaths: [String] = [], imageDrafts: [DraftPersistence.Image] = []) -> Bool {
        guard start() else { return false }
        let uuid = uuid.lowercased()   // 寄件匣、unacked、回送比對、插話一律小寫（呼叫端現在都給小寫，這裡保險）
        let wasBusy = status != .idle
        // 聊天室名稱：模型還不知道這個名字（第一則、或剛改名）才在後面附一行，之後不重複。
        // 開程序時 Claude 已用系統提示帶過（start 會記 announcedName）；斜線指令後面不能接字；Apple 和本機模型每次組系統提示時直接帶名字
        let original = text
        var text = text
        let nameNote = text.hasPrefix("/") || appleModel != nil || mlxModel != nil ? nil : pendingNameNote()
        if let n = nameNote { text += "\n\n" + n.note }
        var content: [[String: Any]] = images.map {
            ["type": "image", "source": ["type": "base64", "media_type": $0.mediaType, "data": $0.data.base64EncodedString()]]
        }
        if !text.isEmpty { content.append(["type": "text", "text": text]) }
        guard !content.isEmpty else { return false }
        do {
            // 先保存送出快照，再交給任何後端；讀不懂既有寄件匣時 append 會拋錯，不能覆蓋原檔。
            // 沒有寄件匣（沒有對話編號的格子）：照舊直接送，不要整個聊天室送不出去（agy Sonnet 11/6）
            if let outboxPersistence {
                do {
                    try outboxPersistence.append(id: uuid, text: displayText ?? original, wireText: text, quotes: quotes,
                                                 filePaths: filePaths, images: images, transcriptURLs: allTranscripts.map(\.url), imageDrafts: imageDrafts)
                } catch where outboxPersistence.isUnreadable {
                    // 既有寄件匣讀不懂（壞檔、資料夾搬家後路徑對不上）：原檔改名留著，開新的一份再存，不卡死送出
                    try outboxPersistence.quarantine()
                    onOutboxError?(L("舊的寄件匣讀不懂，已改名保留（outbox 資料夾裡的 .bad 檔），這則照常送出。"))
                    try outboxPersistence.append(id: uuid, text: displayText ?? original, wireText: text, quotes: quotes,
                                                 filePaths: filePaths, images: images, transcriptURLs: allTranscripts.map(\.url), imageDrafts: imageDrafts)
                }
            }
        } catch {
            onOutboxError?(L("寄件匣存不進去，這則沒有送出。輸入已保留，請檢查磁碟或權限後再試。"))
            return false
        }
        // 本機／Apple 會在 write 裡同步回送，必須先登記，不能在回送後才加入 unacked。
        unacked.append((uuid: uuid.lowercased(), text: displayText ?? original, images: images, quotes: quotes))
        // 正在等權限回答（waiting）時排隊送一則：維持 waiting，不要蓋成 working（agy Argon 11/6）
        if pending.isEmpty { status = .working }
        guard write(["type": "user", "uuid": uuid, "message": ["role": "user", "content": content]]) else {
            unacked.removeAll { $0.uuid == uuid.lowercased() }
            if !wasBusy { status = .idle }
            // 管線可能只寫入一部分，保留磁碟快照，下次仍需對照紀錄。
            emit(["type": "result", "subtype": "error_during_execution", "is_error": true, "result": L("訊息沒有送到（Claude 剛好結束了），請再送一次。")])
            return false
        }
        if let n = nameNote { announcedName = n.name }
        // ⌃ Enter：不看 status 決定送不送（它可能慢一拍，以為閒著就只會排隊）；真的閒著 claude 會回 nothing_waiting，沒影響。
        // 本來就閒著的不重試（訊息會直接被讀，只是要等幾秒才回送）
        if now { sendNow(uuid, tries: wasBusy ? 0 : 5) }
        return true
    }

    // MARK: 改名同步

    /// 使用者在 codenv 裡改了聊天室名字：正在跑的 claude 也改 session 名字（等於在聊天室打 /rename，登錄檔 sessions/<pid>.json 的 name 會變，
    /// ListAgents 和別的聊天室看到的名字跟著變）。/rename 是 claude 本地處理的：不花模型回合、不花錢。
    /// 它的回應（一則合成的 assistant 和 result）不交給畫面；Claude 正在做事就等這一輪結束；沒在跑的下次啟動時用 --name 帶
    private var pendingName: String?
    private var silentRenames = 0
    func syncName(_ name: String) {
        guard process?.isRunning == true, agy == nil, codex == nil, copilot == nil, mlx == nil, apple == nil else { return }
        let n = name.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        if status != .idle { pendingName = n; return }
        sendRename(n)
    }
    private func sendRename(_ n: String) {
        pendingName = nil
        silentRenames += 1
        // 萬一 claude 沒回 result（出錯、被停掉）：幾秒後計數歸零，不會一直卡在「要吃掉下一則」
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.silentRenames = 0 }
        write(["type": "user", "message": ["role": "user", "content": [["type": "text", "text": "/rename " + n]]]])
    }
    /// 這行是 /rename 的回應嗎（是就吃掉）。回傳 true＝不交給畫面。
    /// 只吃內容是「Session renamed to…」的那幾種：不是它的（例如這時剛好有別的回覆）照常交給畫面，不會吞到正常訊息
    private func swallowRename(_ obj: [String: Any]) -> Bool {
        guard silentRenames > 0 else { return false }
        func textOf(_ c: Any?) -> String { (c as? String) ?? ((c as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()) ?? "" }
        switch obj["type"] as? String {
        case "assistant":
            return textOf((obj["message"] as? [String: Any])?["content"]).hasPrefix("Session renamed to")
        case "result":
            guard (obj["result"] as? String ?? "").hasPrefix("Session renamed to") else { return false }
            silentRenames = max(0, silentRenames - 1)
            return true
        case "user":
            let t = textOf((obj["message"] as? [String: Any])?["content"])
            return t.contains("<command-name>/rename") || t.contains("<local-command-stdout>Session renamed to") || t.hasPrefix("/rename ")
        default: return false
        }
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
        let uuid = uuid.lowercased()
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

    /// 停掉一個背景工作（Claude Code 的 control request：stop_task，task_id 就是 background_tasks_changed 事件裡的 task_id）
    func stopTask(_ taskID: String) {
        write(["type": "control_request", "request_id": UUID().uuidString, "request": ["subtype": "stop_task", "task_id": taskID]])
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
        if let pid = process?.processIdentifier {
            EventLog.log("聊天程序", "\(convTag)：要求結束（pid \(pid)）")
        } else if mlx != nil || apple != nil {
            EventLog.log("聊天程序", "\(convTag)：要求結束")
        }
        // 先結束程序再關 stdin：背景佇列可能正卡在寫入，程序一死讀端關掉，那次寫入就會失敗返回；
        // 關閉排在同一條佇列，等進行中的寫入結束才關，避免檔案描述子被關掉後重用、寫進別的檔
        let h = input, q = writeQueue
        writeGate.close()
        input = nil
        if let p = process {
            p.terminate()
            // 不理 SIGTERM（或寫入一直卡著）的舊程序：5 秒後還活著就強制結束，卡住的寫入才會失敗返回、佇列和檔案描述子才放得掉（agy Opus 11/6）
            let pid = p.processIdentifier
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak p] in
                if let p, p.isRunning { EventLog.log("聊天程序", "pid \(pid) 5 秒沒結束，強制結束"); kill(pid, SIGKILL) }
            }
        }
        process = nil
        if let h { q.async { try? h.close() } }
        // 停掉了：還在等控制回覆的（設定頁的「設為預設」）不會再收到，直接回報失敗，免得一直等
        let waiting = defaultRequests.values; defaultRequests.removeAll(); waiting.forEach { $0(false) }
        agy = nil
        codex = nil
        copilot = nil
        mlx?.close()
        mlx = nil
        apple?.close()
        apple = nil
        pending.removeAll()
        status = .idle
        // 主動關掉時 terminationHandler 會因為 process 已換掉而直接 return，這裡要自己處理還沒確認的訊息：
        // 不處理的話它們一直掛在 unacked，網頁永遠不卸載、寄件匣也一直當成「還在路上」不放回（agy Argon 11/6）。
        // onLost 會拿紀錄檔對照：已送到的標已讀，不確定的放回輸入框，寄件匣不刪
        let lost = unacked
        unacked.removeAll()
        // 排到下一輪再交出去：呼叫端（換模型、重開）常是 terminate(); 改設定; start()，同步呼叫 onLost 可能在中間重入（agy Opus 11/6）
        if !lost.isEmpty { DispatchQueue.main.async { [weak self] in self?.onLost?(lost) } }
        onTerminated?()
    }

    // MARK: -

    /// 回傳 false＝真的寫進 claude 的標準輸入失敗（其他走法、agy 沒有的控制指令不送，都算 true）
    @discardableResult
    private func write(_ obj: [String: Any]) -> Bool {
        if let codex { codex.outgoing(obj); return true }   // codex 自己翻成 JSON-RPC 再寫
        if let copilot { copilot.outgoing(obj); return true }
        if mlx != nil || apple != nil {   // 本機沒有程序：測試紀錄在這裡記
            if let d = try? JSONSerialization.data(withJSONObject: obj) { Self.log?.write(Data("→ ".utf8) + d + Data([0x0a])) }
            if let mlx { mlx.outgoing(obj) } else { apple?.outgoing(obj) }
            return true
        }
        var obj = obj
        if let agy { guard let o = agy.outgoing(obj) else { return true }; obj = o }   // agy 的格式；它沒有的功能（控制指令）不送
        return rawWrite(obj)
    }

    @discardableResult
    private func rawWrite(_ obj: [String: Any]) -> Bool {
        guard let input, let d = try? JSONSerialization.data(withJSONObject: obj) else { return false }
        let line = d + Data([0x0a])
        let q = writeQueue, gate = writeGate
        // 背景寫：主執行緒不等對方讀。失敗（claude 剛好結束、關了 stdin）回主執行緒處理；
        // 這時這則已經登記在 unacked／寄件匣，程序結束時 onLost 會對照紀錄、沒送到的放回輸入框
        q.async { [weak self] in
            guard gate.isOpen else { return }   // 這個程序已經被關掉：不寫（見 writeGate）
            do {
                try input.write(contentsOf: line)
                Self.log?.write(Data("→ ".utf8) + line)
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.input === input else { return }   // 已經換了新程序：舊管子的錯誤不管
                    self.input = nil
                    // 管子壞了但程序還活著（claude 關了 stdin 卻沒結束）：start() 會一直以為還在跑、不重開。結束它，termination handler 會收尾，下一次送就會重開
                    if self.process?.isRunning == true { self.process?.terminate() }
                }
            }
        }
        return true
    }

    private func received(_ d: Data) {
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0a) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] else { continue }
            Self.log?.write(Data("← ".utf8) + lineData + Data([0x0a]))
            if let agy { agy.incoming(obj).forEach(emit) } else if let codex { codex.incoming(obj) } else if let copilot { copilot.incoming(obj) } else {
                if swallowRename(obj) { track(obj); if let n = pendingName, status == .idle, silentRenames == 0 { sendRename(n) }; continue }
                track(obj); onLine?(line, obj)
                // Claude 做事時改的名字：這一輪結束（變閒置）後補送
                if let n = pendingName, status == .idle { sendRename(n) }
            }
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
            // result 只代表這一輪結束，不能確認排隊中的其他訊息。
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
            // A 的 token 不能確認仍在排隊的 B；所有後端都等各則 UUID 回送。
            if pending.isEmpty { status = .working }
        case "user":
            // Claude 讀進了排隊的訊息（回送）：下一輪開始了
            if o["isReplay"] as? Bool == true {
                // 只有我們送出、還在等確認的那則回送才算「開工」：/effort、換模型這類本機指令的回送沒有 uuid、後面不一定有 result，
                // 當成開工會一直轉圈。真的開工時第一個 stream_event／assistant 也會設 working（agy Argon 11/6）
                var ours = false
                if let u = o["uuid"] as? String {
                    taken.insert(u.lowercased())
                    ours = unacked.contains { $0.uuid == u.lowercased() }
                    unacked.removeAll { $0.uuid == u.lowercased() }
                    do { try outboxPersistence?.remove(ids: [u.lowercased()]) }
                    catch { onOutboxError?(L("寄件匣更新失敗，已保留原檔；重開時會再對照對話紀錄。")) }
                }
                // 換模型的回報（從預設換過去時 claude 會回一則「Set model to …」）不是一輪的開始：後面沒有 result，當成開工會一直轉圈
                let local = ((o["message"] as? [String: Any])?["content"] as? String)?.hasPrefix("<local-command-stdout>") == true
                if pending.isEmpty, !local, ours { status = .working }
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

/// 背景寫入佇列用的開關：主執行緒關、背景執行緒讀
final class WriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true
    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return open }
    func close() { lock.lock(); open = false; lock.unlock() }
}
