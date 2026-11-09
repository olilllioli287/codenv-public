import AppKit
import Combine

// 工作台的資料：專案（一個資料夾）底下有很多對話（每個對話是一格跑 Claude Code 的終端機）。
// 存在 ~/Library/Application Support/<資料夾（Edition.supportDir）>/state.json，關掉再開都還在。

struct Project: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var path: String
    var expanded = true
    /// 「封存」那一區有沒有展開
    var archiveOpen: Bool? = nil
    /// 這個資料夾的對話預設歸在哪一組（Groups.swift）
    var groupID: UUID? = nil
}

struct Conversation: Codable, Identifiable, Hashable {
    var id = UUID()
    var projectID: UUID
    var title: String
    /// 交給 Claude Code 的對話編號：新開用 --session-id，之後用 --resume 接回同一段
    var claudeSession = UUID()
    var createdAt = Date()
    var lastOpened = Date()
    /// 使用者自己改過名字就不再跟著終端機標題變
    var renamed = false
    /// 名字是總指揮（codenv-todo rename／new）取的，不是使用者自己取的；使用者手動改名就清掉。總指揮只能改這種名字
    var namedByCommander: Bool? = nil
    /// 使用者在右鍵勾了「讓總指揮改名」：這段使用者自己取的名字，總指揮也可以改（改完算總指揮取的，勾選留著）
    var commanderMayRename: Bool? = nil
    /// 用終端機（舊的方式）打開，而不是聊天介面；nil＝聊天
    var terminal: Bool? = nil
    /// 這段對話選的模型（Claude 的別名或全名，例如 opus、fable；本機模型用「local:<名稱>」）；nil＝預設
    var model: String? = nil
    /// 思考強度（low、medium、high、xhigh、max）；nil＝跟 Claude 的設定
    var effort: String? = nil
    /// 權限模式（⇧ Tab 換的）；nil＝照設定頁
    var permissionMode: String? = nil
    /// 這段的 Claude 跑在 nono 沙盒裡（右鍵「在沙盒裡跑」；NonoSandbox.swift）。nil／false＝一般
    var sandbox: Bool? = nil
    /// 自己指定的組（沒指定就跟著資料夾的預設組）
    var groupID: UUID? = nil
    /// 側欄的固定順序（小的在上面）；點開不會變，拖曳或右鍵「上移／下移」才變
    var order: Double? = nil
    /// 右鍵「封存」的：true＝自己封存（打開也留在封存）；nil＝照一個禮拜沒碰的規則
    var manualArchive: Bool? = nil
    /// 側欄「新對話」（⌘ N）開的草稿：只列在「最近項目」，沒聊就自動刪（Drafts.swift）；nil＝一般對話
    var draft: Bool? = nil
    /// 瀏覽器格子（BrowserPane.swift）：目前的網址；nil＝聊天／終端機
    var browser: String? = nil
    /// 在哪個掛件框裡（Bundles.swift）；nil＝沒有
    var bundle: UUID? = nil
    /// 這格瀏覽器是哪個掛件框的掛件（不列在側欄）；nil＝一般的
    var gadgetOf: UUID? = nil
    /// 這格瀏覽器在 Gemini、NotebookLM 各自最後停在哪個網址（key＝GadgetKind.rawValue：gemini／notebooklm）；
    /// ⌥ 八宮格在這一格原地切換網站時，切回去接續最後那段對話／筆記本。掛件格也一樣（跟著同一筆 Conversation 存檔，不另存一份）。舊存檔沒有這欄就是 nil
    var lastURLs: [String: String]? = nil
    /// 上次交接成功的時間（每日交接用，DailyHandoff.swift）；交接出來的新聊天室繼承這個時間。nil＝從沒交接過
    var lastHandoffAt: Date? = nil
    /// 啟動 claude 時載入哪些 MCP（full／lite／none，McpMode.swift）；nil＝完整。下次啟動生效。`codenv-todo new` 開的分支預設 lite
    var mcp: String? = nil
    /// 聊天室說明（類似 Discord 頻道主題，上限 1024 字）：這個聊天室負責什麼。給它自己的 Claude（系統提示「你負責…」）、總指揮的名單、使用者的資訊卡看。舊存檔沒有這欄＝nil
    var topic: String? = nil
    /// 說明是總指揮（codenv-todo topic／new --topic）寫的；使用者在 App 裡改過就清掉。總指揮只能改這種說明或空的說明（除非右鍵勾了「讓總指揮改名」）
    var topicByCommander: Bool? = nil
}

extension Conversation {
    /// 模型類別（事件紀錄與分類用，不含標題或細節參數）：claude、agy、codex、copilot、local、apple、browser
    var modelCategory: String {
        if browser != nil { return "browser" }
        let m = (model ?? "").lowercased()
        if m.hasPrefix("agy") || m.hasPrefix("gemini") { return "agy" }
        if m.hasPrefix("codex") || m.hasPrefix("chatgpt") { return "codex" }
        if m.hasPrefix("copilot") { return "copilot" }
        if m.hasPrefix("local") || m.hasPrefix("mlx") { return "local" }
        if m.hasPrefix("apple") { return "apple" }
        return "claude"
    }
}

final class Store: ObservableObject {
    @Published var projects: [Project] = []
    @Published var conversations: [Conversation] = []
    /// 「選取整個 Window」（點上方 Window 分頁、或 ⌘ 數字之後，當成框選目前 Window 的全部格子；此時 F2 改的是 Window 名字）。
    /// 點任一格、換紫框、打字就離開；不存檔
    @Published var windowSelected = false
    @Published var selected: UUID?          // 目前打開的對話
    @Published var selectedProject: UUID?   // 「新對話」要開在哪個專案
    /// 每段對話現在的狀態（側欄燈號用，不存檔）：工作中、等你；做完但還沒看的放 unread
    @Published var status: [UUID: ChatStatus] = [:] {
        didSet {   // 從閒著變成工作中／等你的那一刻（「正在跑」的 main 那行算時間用）
            for id in Set(status.keys).union(oldValue.keys) {
                let now = status[id] ?? .idle, was = oldValue[id] ?? .idle
                if now == .idle { busySince[id] = nil } else if was == .idle { busySince[id] = Date() }
            }
        }
    }
    private(set) var busySince: [UUID: Date] = [:]
    /// 每段對話 Claude 實際回報在用的模型（claude-opus-5-5…，不存檔）：沒自己選模型時「預設」到底是哪個，看這裡
    @Published var liveModel: [UUID: String] = [:]
    /// 在背景替這段對話跑的模型（本機模型自動壓縮時請 Claude Haiku 整理摘要）：右側欄「使用中」也列出來
    @Published var backgroundModel: [UUID: String] = [:]

    /// 右側欄顯示的模型名稱：自己選過的照選的；沒選（預設）而 Claude 回報過實際模型的，照實際的（輸入框寫 Opus、右側欄卻寫 Sonnet）
    func displayModel(_ id: UUID) -> String {
        guard let c = conversation(id) else { return UsagePool.modelName(nil) }
        if c.isBrowser { return L("瀏覽器") }
        let m = c.terminal == true ? nil : c.model
        // 還沒跑起來的：用上次「預設」實際跑出來的模型（Claude 清單說預設是 Sonnet，實際卻可能是 Opus）
        if m == nil || m == "default", let live = liveModel[id] ?? appDefaults.string(forKey: "lastDefaultModel"), !live.isEmpty {
            return ModelChoice.known.first { $0.resolved == live && $0.value != "default" }?.name ?? live
        }
        return UsagePool.modelName(m)
    }
    @Published var unread: Set<UUID> = []
    /// 每段對話最後一次有新內容的時間（讀紀錄檔的修改時間；不存檔，啟動和切回 App 時重讀）
    @Published var lastActivity: [UUID: Date] = [:]
    /// 版面：Session → Window → Pane（Layout.swift）
    @Published var sessions: [SessionLayout] = []
    /// 側欄最上層的分組（A 組、B 組…）；空的就照舊只列資料夾
    @Published var groups: [ConvGroup] = []
    /// 瀏覽器格子的縮放比例，每個網站一份（gemini.google.com → 1.25）；100% 的不記
    @Published var browserZoom: [String: Double] = [:]
    @Published var currentSession: UUID? { didSet { followSessionArea() } }
    /// 目前看哪一區：home＝首頁、codelab＝程式碼學習專區（側欄最左邊的圖示列）。兩區各有自己的一套 Session／Window（Layout.swift）
    @Published var area: String = {
        // 舊版把首頁／codelab 記在 sidebarMode；先保留區域記憶，讓新左欄模式能獨立使用原本的鍵。
        let saved = appDefaults.string(forKey: "workspaceArea") ?? appDefaults.string(forKey: "sidebarMode")
        let area = saved == Store.codeLabArea ? Store.codeLabArea : "home"
        appDefaults.set(area, forKey: "workspaceArea")
        return area
    }() {
        didSet { appDefaults.set(area, forKey: "workspaceArea") }
    }

    private let url: URL
    /// 存檔所在的資料夾（分類檔 classification.json 也放這裡）
    var directory: URL { url.deletingLastPathComponent() }
    private var saveWork: DispatchWorkItem?
    /// 上次把 state.json 複製成 state.json.bak 的時間：每次開 App 第一次存檔前備一份，之後最多一小時一次
    private var lastBackup: Date?
    /// 連續存檔失敗幾次（成功就歸零）；第一次失敗通知畫面（onSaveProblem），之後每 30 秒自己再試
    private(set) var saveFailures = 0
    /// 已經排了 30 秒後重試：不要每次失敗都再排一個
    private var retryPending = false
    var onSaveProblem: ((String) -> Void)?
    /// 獨立視窗拿到焦點時指向它那個 Window（Layout.swift 的 sessionIndex／windowIndex 看這個）；不存檔
    var scope: UUID?
    /// 側欄點的對話在獨立視窗裡：把那個獨立視窗叫到最前面（MainWindowController 接）
    var onRaiseWindow: ((UUID) -> Void)?
    /// 獨立視窗搬了位置或調了大小：記下來（存檔），重開 App 還原用
    func setDetachedFrame(_ id: UUID, frame: NSRect, screen: NSScreen?) {
        guard let (si, wi) = windowPosition(id), sessions[si].windows[wi].detached else { return }
        let s = screen ?? NSScreen.main
        let o = s?.frame.origin ?? .zero
        let f = [Double(frame.minX - o.x), Double(frame.minY - o.y), Double(frame.width), Double(frame.height)]
        if sessions[si].windows[wi].detachedFrame != f { sessions[si].windows[wi].detachedFrame = f }
        if sessions[si].windows[wi].detachedScreen != s?.localizedName { sessions[si].windows[wi].detachedScreen = s?.localizedName }
        let so = [Double(o.x), Double(o.y)]
        if sessions[si].windows[wi].detachedScreenOrigin != so { sessions[si].windows[wi].detachedScreenOrigin = so }
    }
    /// state.json 讀不懂、又沒能另存備份：保護原檔，不存檔
    private var lastProtectedWarn: Date?
    private var protectOriginal = false
    /// 這次啟動沒讀到 state.json（讀不出來、或解不開已另存備份）：對話清單是空的不代表使用者真的沒有對話，排程、搬資料夾這類依賴對話清單的事都不能動
    private(set) var loadFailed = false
    /// 設定檔現在不能存（保護原檔中）
    var isSaveProtected: Bool { protectOriginal }
    /// 對話真的被刪掉時通知（排程跟著清）；差集清理會在 state.json 壞掉時把排程全刪，所以改成只認明確的刪除
    var onConversationRemoved: ((UUID) -> Void)?
    /// 啟動時發現的大問題（讀不到 state.json）：App 開起來後跳一次提示，不能靜默不存檔
    var startupProblem: String?
    /// 開 App 提示的標題（nil＝「設定檔讀不到，這次不會存檔」）；用備份還原時換成還原的說法
    var startupTitle: String?
    private var bag: Set<AnyCancellable> = []

    private struct State: Codable {
        var projects: [Project]
        var conversations: [Conversation]
        var selected: UUID?
        var selectedProject: UUID?
        var sessions: [SessionLayout]? = nil
        var currentSession: UUID? = nil
        var groups: [ConvGroup]? = nil
        var browserZoom: [String: Double]? = nil
        /// ⌘ W 關掉的 Window（重開 App 後 ⌘ ⇧ T、側欄點聊天室還找得回來）。只存關整個 Window 的，關單一格的不存
        var closedWindows: [ClosedWindow]? = nil
    }
    struct ClosedWindow: Codable { var session: UUID; var index: Int; var window: WindowLayout; var placeholder: UUID? }

    init(directory: URL? = nil) {
        let dir = directory ?? Edition.supportDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("state.json")
        var raw = try? Data(contentsOf: url)
        // 空檔（0 位元組）或讀不懂：有能讀的 state.json.bak 就用它還原（壞掉的原檔照下面的規則另存一份）
        let bakURL = dir.appendingPathComponent("state.json.bak")
        // 整個檔被刪掉（不存在）但有備份：也用備份（Flash 11/6：不然開成空工作台，一小時後備份輪替會把好的備份蓋成空的）
        if raw.map({ $0.isEmpty || (try? JSONDecoder().decode(State.self, from: $0)) == nil }) ?? !FileManager.default.fileExists(atPath: url.path),
           let b = try? Data(contentsOf: bakURL), (try? JSONDecoder().decode(State.self, from: b)) != nil {
            if let bad = raw, !bad.isEmpty {
                let f = DateFormatter(); f.dateFormat = "MMdd-HHmmss"
                try? bad.write(to: dir.appendingPathComponent("state.json.讀不到-\(f.string(from: Date()))"))
            }
            raw = b
            let when = ((try? FileManager.default.attributesOfItem(atPath: bakURL.path))?[.modificationDate] as? Date).map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? "?"
            startupTitle = L("設定檔已用備份還原")
            startupProblem = L("設定檔 state.json 是空的或壞掉了，已經用備份（\(when)）還原。之後的改動照常存檔。")
            EventLog.log("檔案", "state.json 空檔或讀不懂，用 state.json.bak（\(when)）還原")
        }
        if let data = raw, let s = try? JSONDecoder().decode(State.self, from: data) {
            projects = s.projects
            conversations = s.conversations
            selected = s.selected
            selectedProject = s.selectedProject
            sessions = s.sessions ?? []
            currentSession = s.currentSession
            groups = s.groups ?? []
            browserZoom = s.browserZoom ?? [:]
            Store.closed = (s.closedWindows ?? []).map { .window(session: $0.session, index: $0.index, window: $0.window, placeholder: $0.placeholder) }
        } else if let data = raw, !data.isEmpty {
            // 讀不懂（檔案壞了、或是新版的格式）：先另存一份，不然等一下存檔會把整份清單蓋成空的
            let f = DateFormatter(); f.dateFormat = "MMdd-HHmmss"
            let bad = dir.appendingPathComponent("state.json.讀不到-\(f.string(from: Date()))")
            let savedBadCopy: Bool
            do { try data.write(to: bad); savedBadCopy = true } catch { savedBadCopy = false; protectOriginal = true }     // 連備份都寫不成：原檔是唯一一份，一律不覆蓋
            loadFailed = true
            // 原檔與備份都解不開：不能用空狀態開起來再存檔——空狀態會蓋掉 state.json，一小時後 .bak 也被輪替成空的。
            // 這次執行不存檔（保護原檔），並告訴使用者；另存的 讀不到- 副本也留著
            protectOriginal = true
            let copyNote = savedBadCopy ? L("原檔另存了一份「\(bad.lastPathComponent)」在 \(dir.path)，請先留著。") : L("原檔另存副本失敗，原檔仍保留在原位置；請先複製保存後再處理。")
            startupProblem = L("codenv 的設定檔 state.json 讀不懂（檔案壞了，或是比這個版本更新的格式），備份也還原不了。為了不蓋掉它，這次執行不會存檔，改動關掉就沒了。\(copyNote)可以改用較新版的 codenv 開，或把備份放回 state.json 再重開。")
            if savedBadCopy {
                NSLog("AI 工作台：state.json 讀不到，已另存成 \(bad.lastPathComponent)")
                EventLog.log("檔案", "state.json 無法讀取，已備份為 \(bad.lastPathComponent)")
            } else {
                NSLog("AI 工作台：state.json 讀不到，另存副本失敗；原檔仍保留")
                EventLog.log("檔案", "state.json 無法讀取，另存副本失敗；原檔仍受保護")
            }
        } else if raw == nil, FileManager.default.fileExists(atPath: url.path) {
            // 檔案在但讀不出來（權限、暫時讀不到）：只有確認為 0 byte 時才能當空檔重建；屬性也讀不到就保護原檔。
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.intValue
            if size == 0 {
                // 空檔沒有可保留的資料，照預設空狀態繼續；saveNow 會正常重建。
            } else {
                protectOriginal = true
                loadFailed = true
                startupProblem = L("codenv 讀不到設定檔 state.json（可能是權限或磁碟問題）。為了不蓋掉它，這次執行不會存檔，改動關掉就沒了。請先確認「\(url.path)」讀得到（權限、iCloud 或外接碟），再重開 codenv。")
                EventLog.log("檔案", "state.json 存在但讀不出來，本次不存檔以保護原檔")
            }
        }
        ensureLayout()
        refreshActivity()
        // 有變動就（稍等一下合併成一次）存檔
        objectWillChange.sink { [weak self] _ in self?.scheduleSave() }.store(in: &bag)
        // Published 在 willSet 發送，排到下一輪再讀完整資料；切回首頁、切模式或首次加入專案都可補做遷移
        Publishers.CombineLatest3($area, Prefs.shared.$sidebarMode, $projects).dropFirst().sink { [weak self] _, _, _ in
            DispatchQueue.main.async { [weak self] in self?.migrateCommandersIfNeeded() }
        }.store(in: &bag)
        migrateCommandersIfNeeded()
        migrateCommanderKinds()
        // 用備份還原的：馬上寫回 state.json，不要讓硬碟上一直是壞的那份
        if startupTitle != nil { scheduleSave() }
    }

    func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    /// 回傳寫成功沒有（要「先確定存好才做下一步」的呼叫端看這個）
    @discardableResult
    func saveNow() -> Bool {
        let s = State(projects: projects, conversations: conversations, selected: selected, selectedProject: selectedProject,
                      sessions: sessions, currentSession: currentSession, groups: groups, browserZoom: browserZoom,
                      closedWindows: Store.closed.compactMap { if case .window(let s, let i, let w, let p) = $0 { return ClosedWindow(session: s, index: i, window: w, placeholder: p) } else { return nil } })
        guard !protectOriginal else {
            // 保護模式：有改動要存的時候（不是只有啟動那一次）每 10 分鐘提醒一次「這次的改動不會存」，免得使用者忙了半天才發現
            if lastProtectedWarn.map({ Date().timeIntervalSince($0) > 600 }) ?? true {
                lastProtectedWarn = Date()
                onSaveProblem?(L("codenv 的設定檔 state.json 這次讀不懂，為了不蓋掉它，這次執行不會存檔。剛才的改動（聊天室、分組、版面）關掉 codenv 就沒了。請先處理設定檔（原檔另存了「讀不到」副本），再重開 codenv。"))
            }
            return false
        }
        guard let data = try? JSONEncoder().encode(s) else { return false }
        // 備份：覆蓋前先把現在這份（讀得懂的才算）複製成 .bak，壞掉時開 App 會自動拿它還原
        if lastBackup.map({ Date().timeIntervalSince($0) > 3600 }) ?? true,
           let cur = try? Data(contentsOf: url), !cur.isEmpty, (try? JSONDecoder().decode(State.self, from: cur)) != nil {
            let bak = url.deletingLastPathComponent().appendingPathComponent("state.json.bak")
            let bt = bak.appendingPathExtension("tmp-\(getpid())")
            if (try? cur.write(to: bt)) != nil {
                let ok = FileManager.default.fileExists(atPath: bak.path)
                    ? (try? FileManager.default.replaceItemAt(bak, withItemAt: bt)) != nil
                    : (try? FileManager.default.moveItem(at: bt, to: bak)) != nil
                try? FileManager.default.removeItem(at: bt)
                // 真的換上去才算備份過；失敗就下次存檔再試，不要空等一小時（agy Flash 11/6）
                // 失敗：60 秒後再試（不要每次存檔都整份重寫一次暫存檔，agy Sonnet 11/6）
                lastBackup = ok ? Date() : Date().addingTimeInterval(-3600 + 60)
            }
        }
        // 暫存檔名帶程序編號：兩個 codenv 同時存檔不會互相蓋掉對方寫到一半的暫存檔
        let tmp = url.appendingPathExtension("tmp-\(getpid())")
        do {
            try data.write(to: tmp)
            if FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp) }
            else { try FileManager.default.moveItem(at: tmp, to: url) }      // 第一次存、或檔案被刪了：沒有東西可以替換，直接放進去
            if saveFailures > 0 { EventLog.log("檔案", "state.json 存檔恢復（之前連續失敗 \(saveFailures) 次）") }
            saveFailures = 0
            return true
        } catch {
            let ns = error as NSError
            try? FileManager.default.removeItem(at: tmp)
            EventLog.log("檔案", "state.json 存檔失敗（\(ns.domain) \(ns.code)）")
            saveFailures += 1
            // 只講一次（Astra 11/5：存檔失敗原本只記事件紀錄，使用者不知道改動沒存）；30 秒後自己再試，成功就恢復
            if saveFailures == 1 { onSaveProblem?(L("codenv 的設定檔 state.json 存不進去（\(ns.localizedDescription)）。剛才的改動（聊天室、分組、版面）還沒存好，先不要關掉 codenv；它會每 30 秒自動再試，磁碟空間或權限恢復後就會存好。")) }
            if !retryPending {
                retryPending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                    guard let self else { return }
                    self.retryPending = false
                    if self.saveFailures > 0 { self.scheduleSave() }
                }
            }
            return false
        }
    }

    // MARK: 專案

    @discardableResult
    func addProject(path: String) -> Project {
        if let p = projects.first(where: { $0.path == path }) { selectedProject = p.id; return p }
        // 名字裡看不見的控制字元（例如誤按的 Esc）不要顯示出來；路徑本身照舊（對話紀錄靠它找）
        let name = String((path as NSString).lastPathComponent.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        let p = Project(name: name, path: path)
        projects.append(p)
        selectedProject = p.id
        return p
    }

    func removeProject(_ id: UUID) {
        projects.removeAll { $0.id == id }
        let gone = conversations.filter { $0.projectID == id }.map(\.id)
        conversations.removeAll { $0.projectID == id }
        gone.forEach { onConversationRemoved?($0) }
        if selectedProject == id { selectedProject = projects.first?.id }
        pruneBundles()      // 刪掉的專案裡的聊天室若是別處掛件框的最後成員，框和掛件跟著收掉
        ensureLayout()
    }

    func project(_ id: UUID) -> Project? { projects.first { $0.id == id } }

    // MARK: 對話

    func conversations(in project: UUID) -> [Conversation] {
        conversations.filter { $0.projectID == project && !$0.isGadget }.sorted(by: orderedBefore)
    }

    var recent: [Conversation] {
        // 封存的（一個禮拜沒碰）不算最近
        Array(conversations.filter { !isArchived($0) && !$0.isGadget }.sorted { $0.lastOpened > $1.lastOpened }.prefix(8))
    }

    @discardableResult
    func newConversation(in project: UUID) -> Conversation {
        let c = createConversation(in: project)
        show(c.id)
        return c
    }

    /// 瀏覽器格子：也是一段「對話」，側欄看得到、可以拖；不是草稿（沒聊天也不會自動刪）
    func createBrowser(in project: UUID, url: String = BrowserPane.home) -> Conversation {
        var c = Conversation(projectID: project, title: "瀏覽器")
        c.browser = url
        c.order = (conversations.compactMap(\.order).min() ?? 0) - 1
        conversations.append(c)
        selectedProject = project
        return c
    }

    /// 只建立對話，不擺進版面（切開、新 Window 時用）；draft＝草稿（Drafts.swift）
    func createConversation(in project: UUID, draft: Bool = false) -> Conversation {
        var c = Conversation(projectID: project, title: "新對話")
        if draft { c.draft = true }
        c.order = (conversations.compactMap(\.order).min() ?? 0) - 1      // 新的放最上面
        c.model = Prefs.shared.defaultModel                               // 設定頁的預設模型、思考強度
        c.effort = Prefs.shared.defaultEffort
        conversations.append(c)
        selectedProject = project
        return c
    }

    /// 側欄點一段對話。⇧ 點（replaceFocused）：舊的開法，放進目前紫框那格、換掉它原本的內容，不開新 Window；
    /// 已經擺出來的照樣跳到它那格。⌥ 點是八宮格（RadialMenu 在事件最前面就吃掉了），不會進到這裡
    func open(_ id: UUID, replaceFocused: Bool? = nil) {
        guard let c = conversation(id), Prefs.shared.webFeaturesEnabled || !c.isBrowser else { return }
        routeUnplacedToCommander(id)   // 總指揮模式：還沒擺出來的聊天室先回到它所屬的總指揮 Session
        let shift = replaceFocused ?? (NSApp.currentEvent.map { $0.modifierFlags.intersection([.command, .control, .option, .shift]) == .shift } ?? false)
        if shift, locate(id) == nil { show(id, replaceFocused: true); return }
        // 剛用 ⌘ W 關掉的 Window 裡有它：整個 Window 照原樣找回來（掛件、比例、紫框）；已經在別的 Window 就照原本的跳過去
        if reopenClosedWindow(containing: id) { return }
        show(id)
    }

    func rename(_ id: UUID, to title: String, byUser: Bool) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        if !byUser && conversations[i].renamed { return }
        let t = KeyScan.redact(title.trimmingCharacters(in: .whitespacesAndNewlines), strongOnly: true)      // 標題會寫進 state.json 與 Claude 的 sessions：金鑰樣式只留末四碼
        guard !t.isEmpty else { return }
        if byUser { conversations[i].namedByCommander = nil }   // 使用者動手改了：之後是他的名字，總指揮不能再改
        if conversations[i].title == t {      // 使用者確認了同一個名字：也算他定的，之後自動標題不能再蓋掉
            if byUser, !conversations[i].renamed { conversations[i].renamed = true; onUserRename?(id, t) }
            return
        }
        conversations[i].title = t
        if byUser { conversations[i].renamed = true; onUserRename?(id, t) }
    }
    /// 使用者自己改名之後通知：正在跑的 Claude 要跟著改 session 名字（ChatSession.syncName），別的聊天室才找得到
    var onUserRename: ((UUID, String) -> Void)?

    static let topicLimit = 1024
    /// 說明整理：去頭尾空白、超過上限截掉；空的回 nil
    static func cleanTopic(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : String(t.prefix(topicLimit))
    }
    /// 設定聊天室說明。byUser＝使用者在 App 裡改（之後總指揮不能改，除非他放行）；否則是總指揮改（標記成總指揮寫的）
    func setTopic(_ id: UUID, _ raw: String, byUser: Bool) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        let t = Store.cleanTopic(raw)
        conversations[i].topic = t
        conversations[i].topicByCommander = byUser || t == nil ? nil : true
    }

    func removeConversation(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        onConversationRemoved?(id)
        ensureLayout()
        pruneBundles()   // 框裡最後一段被刪：掛件也收掉
    }

    func conversation(_ id: UUID) -> Conversation? { conversations.first { $0.id == id } }

    // MARK: Claude Code 的對話紀錄

    /// Claude Code 把每段對話存在 ~/.claude/projects/<資料夾路徑，非英數字換成 -> /<編號>.jsonl
    static func claudeTranscript(_ session: UUID, path: String) -> URL {
        let slug = String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        return ClaudeSessions.home.appendingPathComponent("projects/\(slug)/\(session.uuidString.lowercased()).jsonl")
    }

    static func claudeHasSession(_ session: UUID, path: String) -> Bool {
        FileManager.default.fileExists(atPath: claudeTranscript(session, path: path).path)
    }
}

/// 設定類小檔讀不懂（壞了或新版格式）時，原檔另存一份「<檔名>.讀不到-MMdd-HHmmss」再照空的開起來：
/// 不然下次存檔會把原檔蓋掉。空檔不算（沒東西可保護）。回傳另存成功沒有（沒有原檔可存＝true）
enum UnreadableFile {
    @discardableResult
    static func setAside(_ url: URL, data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        let f = DateFormatter(); f.dateFormat = "MMdd-HHmmss"
        let bad = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".讀不到-\(f.string(from: Date()))")
        let ok = (try? data.write(to: bad)) != nil
        NSLog("%@ 讀不到，已另存成 %@", url.lastPathComponent, bad.lastPathComponent)
        EventLog.log("檔案", "\(url.lastPathComponent) 無法讀取，已備份為 \(bad.lastPathComponent)")
        return ok
    }
}
