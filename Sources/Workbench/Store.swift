import Foundation
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
    /// 用終端機（舊的方式）打開，而不是聊天介面；nil＝聊天
    var terminal: Bool? = nil
    /// 這段對話選的模型（Claude 的別名或全名，例如 opus、fable；本機模型用「local:<名稱>」）；nil＝預設
    var model: String? = nil
    /// 思考強度（low、medium、high、xhigh、max）；nil＝跟 Claude 的設定
    var effort: String? = nil
    /// 權限模式（⇧ Tab 換的）；nil＝照設定頁
    var permissionMode: String? = nil
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
}

final class Store: ObservableObject {
    @Published var projects: [Project] = []
    @Published var conversations: [Conversation] = []
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
    /// 在背景替這段對話跑的模型（本機模型自動壓縮時請 Claude Haiku 整理摘要）：右側欄「使用中」也列出來（使用者 10/25）
    @Published var backgroundModel: [UUID: String] = [:]

    /// 右側欄顯示的模型名稱：自己選過的照選的；沒選（預設）而 Claude 回報過實際模型的，照實際的（使用者 10/25：輸入框寫 Opus、右側欄卻寫 Sonnet）
    func displayModel(_ id: UUID) -> String {
        guard let c = conversation(id) else { return UsagePool.modelName(nil) }
        if c.isBrowser { return "瀏覽器" }
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
    /// 側欄最上層的分組（學業、RTS…）；空的就照舊只列資料夾
    @Published var groups: [ConvGroup] = []
    /// 瀏覽器格子的縮放比例，每個網站一份（gemini.google.com → 1.25）；100% 的不記
    @Published var browserZoom: [String: Double] = [:]
    @Published var currentSession: UUID? { didSet { followSessionArea() } }
    /// 目前看哪一區：home＝首頁、codelab＝程式碼學習專區（側欄最左邊的圖示列）。兩區各有自己的一套 Session／Window（Layout.swift）
    @Published var area: String = appDefaults.string(forKey: "sidebarMode") == Store.codeLabArea ? Store.codeLabArea : "home" {
        didSet { appDefaults.set(area, forKey: "sidebarMode") }
    }

    private let url: URL
    /// 存檔所在的資料夾（分類檔 classification.json 也放這裡）
    var directory: URL { url.deletingLastPathComponent() }
    private var saveWork: DispatchWorkItem?
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
        if let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(State.self, from: data) {
            projects = s.projects
            conversations = s.conversations
            selected = s.selected
            selectedProject = s.selectedProject
            sessions = s.sessions ?? []
            currentSession = s.currentSession
            groups = s.groups ?? []
            browserZoom = s.browserZoom ?? [:]
            Store.closed = (s.closedWindows ?? []).map { .window(session: $0.session, index: $0.index, window: $0.window, placeholder: $0.placeholder) }
        } else if let data = try? Data(contentsOf: url), !data.isEmpty {
            // 讀不懂（檔案壞了、或是新版的格式）：先另存一份，不然等一下存檔會把整份清單蓋成空的
            let f = DateFormatter(); f.dateFormat = "MMdd-HHmmss"
            let bad = dir.appendingPathComponent("state.json.讀不到-\(f.string(from: Date()))")
            try? data.write(to: bad)
            NSLog("AI 工作台：state.json 讀不到，已另存成 \(bad.lastPathComponent)")
        }
        ensureLayout()
        refreshActivity()
        // 有變動就（稍等一下合併成一次）存檔
        objectWillChange.sink { [weak self] _ in self?.scheduleSave() }.store(in: &bag)
    }

    func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    func saveNow() {
        let s = State(projects: projects, conversations: conversations, selected: selected, selectedProject: selectedProject,
                      sessions: sessions, currentSession: currentSession, groups: groups, browserZoom: browserZoom,
                      closedWindows: Store.closed.compactMap { if case .window(let s, let i, let w, let p) = $0 { return ClosedWindow(session: s, index: i, window: w, placeholder: p) } else { return nil } })
        guard let data = try? JSONEncoder().encode(s) else { return }
        let tmp = url.appendingPathExtension("tmp")
        try? data.write(to: tmp)
        _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
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
        conversations.removeAll { $0.projectID == id }
        if selectedProject == id { selectedProject = projects.first?.id }
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

    func open(_ id: UUID) {
        guard conversation(id) != nil else { return }
        // 剛用 ⌘ W 關掉的 Window 裡有它：整個 Window 照原樣找回來（掛件、比例、紫框）；已經在別的 Window 就照原本的跳過去
        if reopenClosedWindow(containing: id) { return }
        show(id)
    }

    func rename(_ id: UUID, to title: String, byUser: Bool) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        if !byUser && conversations[i].renamed { return }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, conversations[i].title != t else { return }
        conversations[i].title = t
        if byUser { conversations[i].renamed = true }
    }

    func removeConversation(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        ensureLayout()
        pruneBundles()   // 框裡最後一段被刪：掛件也收掉
    }

    func conversation(_ id: UUID) -> Conversation? { conversations.first { $0.id == id } }

    // MARK: Claude Code 的對話紀錄

    /// Claude Code 把每段對話存在 ~/.claude/projects/<資料夾路徑，非英數字換成 -> /<編號>.jsonl
    static func claudeTranscript(_ session: UUID, path: String) -> URL {
        let slug = String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(slug)/\(session.uuidString.lowercased()).jsonl")
    }

    static func claudeHasSession(_ session: UUID, path: String) -> Bool {
        FileManager.default.fileExists(atPath: claudeTranscript(session, path: path).path)
    }
}
