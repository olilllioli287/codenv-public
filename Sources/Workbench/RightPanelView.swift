import SwiftUI
import AppKit

// 右欄統一容器（總指揮模式用）：頂端一排「小圖示＋兩字標籤」的分頁，列高 32 點，整體壓扁。
//   視窗：開著的 Window（含獨立視窗）＋這個總指揮的聊天室（叫出來）＋正在跑＋Ports 膠囊
//   檔案：目前專案的檔案樹、檔名／內容搜尋（rg）
//   Git：目前專案的 git 狀態、差異、Worktree（不提供 commit）
//   歷史：這個總指揮底下所有聊天室的全文搜尋
//   看板：嵌入原本的協作看板（目標／往來／發現）
// 最下面的桌寵空位由 WindowHost 畫（PetSlotView），這裡不管。

enum RightTab: String, CaseIterable, Identifiable {
    case windows, files, git, history, board
    var id: String { rawValue }
    var label: String {
        switch self {
        case .windows: return L("視窗")
        case .files: return L("檔案")
        case .git: return "Git"
        case .history: return L("歷史")
        case .board: return L("看板")
        }
    }
    var icon: String {
        switch self {
        case .windows: return "macwindow.on.rectangle"
        case .files: return "folder"
        case .git: return "arrow.triangle.branch"
        case .history: return "clock"
        case .board: return "bubble.left.and.bubble.right"
        }
    }
    /// 測試參數用的名字（--right-tab）
    static func named(_ s: String) -> RightTab? {
        switch s.lowercased() {
        case "視窗", "windows": return .windows
        case "檔案", "files": return .files
        case "git": return .git
        case "歷史", "history": return .history
        case "看板", "board": return .board
        default: return nil
        }
    }
}

final class RightPanelModel: ObservableObject {
    static let shared = RightPanelModel()

    /// 視窗分頁裡單擊選取的聊天室（紫框保持；按 i 開「聊天室資訊」）
    @Published var selectedChat: UUID?
    /// 正在開著「聊天室資訊」表單的聊天室
    @Published var infoChat: UUID?
    @Published var tab: RightTab {
        didSet { appDefaults.set(tab.rawValue, forKey: "rightPanelTab") }
    }
    /// 最下面的桌寵空位要不要留（右欄本身的開關是 F4＝PetSlot.enabled）
    @Published var petSlotOn: Bool {
        didSet { appDefaults.set(petSlotOn, forKey: "rightPanelPet"); NotificationCenter.default.post(name: PetSlot.changed, object: nil) }
    }
    /// 右欄整條開著（跟 PetSlot.enabled 同步，左側協作圖示的亮燈用）
    @Published private(set) var panelOn = PetSlot.enabled
    private var panelObserver: NSObjectProtocol?

    /// 右欄的寬度（拖左緣調整，記起來）
    var width: CGFloat {
        get { let w = appDefaults.double(forKey: "rightPanelWidth"); return w >= 240 ? CGFloat(w) : 330 }
        set { appDefaults.set(Double(min(640, max(240, newValue))), forKey: "rightPanelWidth") }
    }

    let files = FileTreeModel()
    let search = FileSearchModel()
    let git = GitPanelModel()
    let history = HistorySearchModel()
    private(set) var projectPath: String?

    private init() {
        tab = RightTab(rawValue: appDefaults.string(forKey: "rightPanelTab") ?? "") ?? .windows
        petSlotOn = appDefaults.object(forKey: "rightPanelPet") as? Bool ?? true
        panelObserver = NotificationCenter.default.addObserver(forName: PetSlot.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.panelOn != PetSlot.enabled { self.panelOn = PetSlot.enabled }
        }
    }

    /// 目前專案換了：檔案樹、git 都跟著換
    func syncProject(_ path: String?) {
        guard path != projectPath else { return }
        projectPath = path
        files.setRoot(path)
        search.clear()
        git.setProject(path)
    }

    var boardShown: Bool { panelOn && tab == .board }
}

// MARK: 資料

enum RPState: String {
    case working, waiting, idle, asleep
    var label: String {
        switch self {
        case .working: return L("工作中")
        case .waiting: return L("等你")
        case .idle: return L("待命")
        case .asleep: return L("休眠")
        }
    }
    var color: Color {
        switch self {
        case .working: return .green
        case .waiting: return .orange
        case .idle: return Color.blue.opacity(0.75)
        case .asleep: return Color.gray.opacity(0.4)
        }
    }
}

struct RPWindowRow: Identifiable {
    let id: UUID
    let title: String
    let subtitle: String
    let status: String      // current（顯示中）、detached（獨立視窗，顯示中）、background
}

struct RPChatRow: Identifiable {
    let id: UUID
    let title: String
    let state: RPState
    let memory: UInt64?
    let context: Int?
    let placed: Bool
    let chief: Bool
}

struct RPChatSection: Identifiable {
    let name: String?
    let rows: [RPChatRow]
    var id: String { name ?? "·" }
}

struct RPChats {
    var sessionID: UUID?
    var isCommander = false
    var sections: [RPChatSection] = []
    var archived: [RPChatRow] = []
    var count: Int { sections.reduce(0) { $0 + $1.rows.count } }
}

enum RPData {
    /// 狀態點：只查 workspace.panes[id]，不呼叫 pane(for:)（那會把聊天室開起來）
    static func state(_ id: UUID, store: Store, workspace: Workspace) -> RPState {
        switch store.status[id] ?? .idle {
        case .working: return .working
        case .waiting: return .waiting
        case .idle: break
        }
        guard let p = workspace.panes[id] else { return .asleep }
        if let c = p as? ChatPane { return c.session.isRunning ? .idle : .asleep }
        return .idle
    }

    static func windows(_ store: Store) -> [RPWindowRow] {
        guard let s = store.currentSessionLayout else { return [] }
        return s.windows.map { w in
            let names = (w.root?.leaves ?? []).map { store.conversation($0)?.title ?? L("空格") }
            let status = w.detached ? "detached" : (s.current == w.id ? "current" : "background")
            return RPWindowRow(id: w.id, title: store.displayName(w), subtitle: names.isEmpty ? L("（空的）") : names.joined(separator: " · "), status: status)
        }
    }

    static func chats(_ store: Store, workspace: Workspace) -> RPChats {
        guard let s = store.currentSessionLayout else { return RPChats() }
        var out = RPChats(sessionID: s.id, isCommander: s.groups != nil)
        guard s.groups != nil else { return out }
        let mem = MemoryMonitor.shared.perConversation
        let ctx = ContextMonitor.shared.tokens
        func row(_ c: Conversation) -> RPChatRow {
            RPChatRow(id: c.id, title: c.title, state: state(c.id, store: store, workspace: workspace), memory: mem[c.id], context: ctx[c.id],
                      placed: store.locate(c.id) != nil, chief: s.chief == c.id)
        }
        let list = store.conversations(inCommander: s).filter { !$0.isBrowser && !$0.isGadget && $0.draft != true }
        let live = list.filter { !store.isArchived($0) }
        out.archived = list.filter { store.isArchived($0) }.map(row)
        // 總指揮置頂；組是這個總指揮涵蓋的頂層組本身的算「沒分組」，往下一層的子組各自一個小標題
        let roots = Set(s.groups ?? [])
        let multi = store.commanderIsMulti(s)
        var buckets: [UUID?: [RPChatRow]] = [:]
        var order: [UUID?] = [nil]
        for c in live {
            // single：不分小標題，整串；multi：按子專案（第一層子組）分組，更深的子組歸進它所屬的子專案
            let sp = multi ? store.subProject(of: c, in: s) : nil
            let key: UUID? = sp?.id
            if buckets[key] == nil { buckets[key] = []; if key != nil { order.append(key) } }
            buckets[key]!.append(row(c))
        }
        let groupIndex = { (g: UUID?) -> Int in store.groups.firstIndex { $0.id == g } ?? Int.max }
        let named = order.dropFirst().sorted { groupIndex($0) < groupIndex($1) }
        for key in [nil] + Array(named) {
            guard var rows = buckets[key], !rows.isEmpty else { continue }
            if key == nil, let i = rows.firstIndex(where: { $0.chief }) { rows.insert(rows.remove(at: i), at: 0) }
            if key == nil, multi {
                // multi：總指揮自己置頂；直接掛在總指揮組底下、不屬於任何子專案的放「未分子專案」（可收合），不漏掉
                let chief = rows.filter { $0.chief }, rest = rows.filter { !$0.chief }
                if !chief.isEmpty { out.sections.append(RPChatSection(name: nil, rows: chief)) }
                if !rest.isEmpty { out.sections.append(RPChatSection(name: L("未分子專案"), rows: rest)) }
                continue
            }
            out.sections.append(RPChatSection(name: key.flatMap { store.group($0)?.name }, rows: rows))
        }
        // 總指揮聊天室不在未分組裡（例如放在子組）：還是要置頂
        if let ci = out.sections.firstIndex(where: { $0.rows.contains { $0.chief } }), ci != 0,
           let ri = out.sections[ci].rows.firstIndex(where: { $0.chief }) {
            var rows = out.sections[ci].rows
            let chief = rows.remove(at: ri)
            out.sections[ci] = RPChatSection(name: out.sections[ci].name, rows: rows)
            out.sections.insert(RPChatSection(name: nil, rows: [chief]), at: 0)
            out.sections.removeAll { $0.rows.isEmpty }
        }
        return out
    }

    static func historyTargets(_ store: Store) -> [HistorySearchModel.Target] {
        guard let sess = store.currentSessionLayout, sess.groups != nil else { return [] }
        return store.conversations(inCommander: sess).compactMap { c in
            guard !c.isBrowser, c.modelCategory == "claude", let p = store.project(c.projectID)?.path else { return nil }
            return .init(id: c.id, title: c.title, url: Store.claudeTranscript(c.claudeSession, path: p))
        }
    }

    /// 全文索引搜尋的範圍：這個總指揮底下所有聊天室（含非 Claude 的；瀏覽器格子沒有對話紀錄）
    static func historyConvs(_ store: Store) -> [UUID] {
        guard let sess = store.currentSessionLayout, sess.groups != nil else { return [] }
        return store.conversations(inCommander: sess).filter { !$0.isBrowser }.map(\.id)
    }

    static func shortBytes(_ b: UInt64) -> String {
        let mb = Double(b) / 1_048_576
        return mb >= 1024 ? String(format: "%.1fG", mb / 1024) : String(format: "%.0fM", mb)
    }

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

extension Store {
    /// 右欄「目前專案」：目前聚焦格的聊天室資料夾；空格或沒有就退回目前 Session 總指揮聊天室的資料夾
    func rightPanelProject() -> (name: String, path: String)? {
        // single 總指揮：檔案／Git 固定看總指揮的專案資料夾；multi 跟著目前點的聊天室（它所在的子專案）
        if let s = currentSessionLayout, s.groups != nil, !commanderIsMulti(s), let p = commanderProjectPath(s) { return p }
        if let f = currentWindow?.focused, let c = conversation(f), let p = project(c.projectID) { return (p.name, p.path) }
        if let ch = currentSessionLayout?.chief, let c = conversation(ch), let p = project(c.projectID) { return (p.name, p.path) }
        return nil
    }

    /// 右欄點 Window：一般的切過去；獨立視窗叫到前景
    func focusWindowFromPanel(_ wid: UUID) {
        guard let (si, wi) = windowPosition(wid) else { return }
        scope = nil
        windowSelected = false
        let a = sessions[si].area ?? "home"
        if !sessions[si].windows[wi].detached, area != a { switchArea(a) }
        makeCurrent(si, wi)
    }
}

// MARK: 容器

struct RightPanelView: View {
    @Environment(\.uiScale) private var s
    @ObservedObject var store: Store
    let workspace: Workspace
    var pause: (CollabPair) -> Void = { _ in }
    @ObservedObject private var model = RightPanelModel.shared

    var body: some View {
        let project = store.rightPanelProject()
        VStack(spacing: 0) {
            tabBar
            Divider()
            Group {
                switch model.tab {
                case .windows: RPWindowsTab(store: store, workspace: workspace)
                case .files: RPFilesTab(store: store, model: model)
                case .git: RPGitTab(store: store, model: model)
                case .history: RPHistoryTab(store: store, model: model)
                case .board:
                    CollabBoardView(openConversation: { id in store.show(id) }, pause: pause, embedded: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { model.syncProject(project?.path) }
        .onChange(of: project?.path) { _, new in model.syncProject(new) }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(RightTab.allCases) { t in
                Button { model.tab = t } label: {
                    HStack(spacing: 3) {
                        Image(systemName: t.icon).font(.system(size: 11 * s))
                        Text(t.label).font(.system(size: 11 * s, weight: model.tab == t ? .semibold : .regular)).lineLimit(1).fixedSize()
                    }
                    .foregroundStyle(model.tab == t ? Color.accentColor : Color.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottom) {
                        if model.tab == t { Rectangle().fill(Color.accentColor).frame(height: 2) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button { model.petSlotOn.toggle() } label: {
                Image(systemName: "pawprint\(model.petSlotOn ? ".fill" : "")").font(.system(size: 10 * s))
                    .foregroundStyle(model.petSlotOn ? Color.accentColor : Color.secondary)
                    .frame(width: 26 * s).frame(maxHeight: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.petSlotOn ? L("收起最下面的桌寵空位") : L("留一塊桌寵空位在最下面"))
        }
        .frame(height: 32 * s)
    }
}

// MARK: 共用小元件

struct RPProjectBar: View {
    @Environment(\.uiScale) private var s
    let project: (name: String, path: String)?
    var refresh: (() -> Void)?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "folder.fill").font(.system(size: 10 * s)).foregroundStyle(.secondary)
            if let project {
                Text(project.name).font(.system(size: 11.5 * s, weight: .semibold)).lineLimit(1)
                Text(RPData.abbreviate(project.path)).font(.system(size: 10 * s)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
            } else {
                Text(L("沒有目前專案")).font(.system(size: 11 * s)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
            if let refresh {
                Button(action: refresh) { Image(systemName: "arrow.clockwise").font(.system(size: 10 * s)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(L("重新整理"))
            }
        }
        .padding(.horizontal, 10).frame(height: 24 * s)
        .help(project?.path ?? "")
    }
}

/// 列的淡底色：滑鼠停著＝淡、剛單擊＝短暫加深（macOS 清單 hover 的感覺）
struct RPRowHighlight: View {
    let flash: Bool
    let hover: Bool
    var selected = false
    var body: some View {
        let a: Double = flash ? 0.2 : (selected ? 0.1 : (hover ? 0.07 : 0))
        return ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(a))
            // 單擊選取：紫色外框保持（跟版面上紫框那格同一個色）
            if selected { RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: Store.bundleAccent), lineWidth: 2) }
        }.padding(.horizontal, 4)
    }
}

struct RPSmallButton: View {
    @Environment(\.uiScale) private var s
    let title: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 10.5 * s)).lineLimit(1).fixedSize().padding(.horizontal, 6).padding(.vertical, 1.5)
                .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
    }
}

// MARK: 視窗

struct RPWindowsTab: View {
    @Environment(\.uiScale) private var s
    @ObservedObject var store: Store
    let workspace: Workspace
    @ObservedObject private var mem = MemoryMonitor.shared
    @ObservedObject private var ctx = ContextMonitor.shared
    @ObservedObject private var activity = SessionActivity.shared
    @ObservedObject private var ports = PortsMonitor.shared
    @ObservedObject private var colab = ColabMonitor.shared
    @State private var colabOpen = false
    @State private var archivedOpen = false
    @State private var runOpen: Bool?
    @State private var portsOpen = false
    @State private var collapsedSections: Set<String> = []
    @State private var hoverRow: UUID?       // 滑鼠停在哪一列：整列淡底色
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @ObservedObject private var panelModel = RightPanelModel.shared
    @FocusState private var listFocused: Bool
    @State private var windowBox = WindowGrabber.Box()
    private let tick = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        let wins = RPData.windows(store)
        let chats = RPData.chats(store, workspace: workspace)
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    running
                    header(L("Window (\(wins.count))"))
                    ForEach(wins) { windowRow($0) }
                    header(L("聊天室 (\(chats.count))"), trailing: chats.isCommander ? AnyView(columns) : nil)
                    if !chats.isCommander {
                        Text(L("這一區沒有總指揮")).font(.system(size: 11 * s)).foregroundStyle(.tertiary).padding(.horizontal, 10).padding(.vertical, 4)
                    }
                    ForEach(chats.sections) { sec in
                        if let name = sec.name {
                            Button {
                                if collapsedSections.contains(name) { collapsedSections.remove(name) } else { collapsedSections.insert(name) }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: collapsedSections.contains(name) ? "chevron.right" : "chevron.down").font(.system(size: 8 * s, weight: .semibold))
                                    Text(collapsedSections.contains(name) ? "\(name) (\(sec.rows.count))" : name).font(.system(size: 10.5 * s, weight: .semibold))
                                    Spacer()
                                }
                                .foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 5).padding(.bottom, 1).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if sec.name == nil || !collapsedSections.contains(sec.name!) {
                            ForEach(sec.rows) { chatRow($0, session: chats.sessionID) }
                        }
                    }
                    if !chats.archived.isEmpty {
                        Button { archivedOpen.toggle() } label: {
                            HStack(spacing: 4) {
                                Image(systemName: archivedOpen ? "chevron.down" : "chevron.right").font(.system(size: 8 * s, weight: .semibold))
                                Text(L("已封存 (\(chats.archived.count))")).font(.system(size: 10.5 * s))
                                Spacer()
                            }
                            .foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if archivedOpen { ForEach(chats.archived) { chatRow($0, session: chats.sessionID).opacity(0.6) } }
                    }
                }
                .padding(.bottom, 6)
                // 右欄有焦點時按 i：打開選取那列的「聊天室資訊」
                .focusable()
                .focused($listFocused)
                .focusEffectDisabled()
            }
            Divider()
            portsBar
        }
        .background(WindowGrabber(box: windowBox))
        .sheet(item: Binding(get: { panelModel.infoChat.map { InfoTarget(id: $0) } }, set: { if $0 == nil { panelModel.infoChat = nil } })) { t in
            ChatInfoForm(store: store, id: t.id) { panelModel.infoChat = nil; listFocused = true }
        }
        .onAppear { ports.refresh(force: true) }
        .onReceive(tick) { _ in if NSApp.isActive { ports.refresh() } }
    }

    // 按 i 的處理在 MainWindowController.installChatInfoKey（AppKit 監聽：焦點在右欄裡、不在輸入框時才收）
    private struct InfoTarget: Identifiable { let id: UUID }
    private func openInfo(_ id: UUID) {
        ChatInfoCard.shared.cancel()
        panelModel.selectedChat = id
        panelModel.infoChat = id
    }

    private var columns: some View {
        HStack(spacing: 5) {
            Text(L("記憶體")).frame(width: 42 * s, alignment: .trailing)
            Text(L("上下文")).frame(width: 36 * s, alignment: .trailing)
        }
        .font(.system(size: 9.5 * s)).foregroundStyle(.tertiary)
    }

    private func header(_ t: String, trailing: AnyView? = nil) -> some View {
        HStack {
            Text(t).font(.system(size: 10.5 * s, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1).fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
    }

    // 正在跑（沿用 ActivityBlock）：有任務才展開
    @ViewBuilder private var running: some View {
        let ids = (store.currentWindow?.root?.leaves ?? []).filter { store.conversation($0) != nil }
        let n = ids.filter { (store.status[$0] ?? .idle) != .idle || !activity.running($0).isEmpty }.count
        let open = runOpen ?? (n > 0)
        VStack(alignment: .leading, spacing: 0) {
            Button { runOpen = !open } label: {
                HStack(spacing: 4) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 8 * s, weight: .semibold))
                    Text(L("正在跑 (\(n))")).font(.system(size: 10.5 * s, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(n > 0 ? Color.green : Color.secondary)
                .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open { ActivityBlock(store: store).padding(.horizontal, 10).padding(.bottom, 4) }
        }
    }

    private func windowRow(_ w: RPWindowRow) -> some View {
        let shown = w.status != "background"
        return Button { store.focusWindowFromPanel(w.id) } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Text(w.title).font(.system(size: 12 * s, weight: shown ? .semibold : .regular)).lineLimit(1)
                    Text(w.status == "detached" ? L("顯示中 · 獨立視窗") : (shown ? L("顯示中") : L("在背景")))
                        .font(.system(size: 9.5 * s)).foregroundStyle(shown ? Color.green : Color.secondary)
                    Spacer(minLength: 0)
                }
                Text(w.subtitle).font(.system(size: 10.5 * s)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            .padding(.horizontal, 10).padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(w.status == "current" ? Color.accentColor.opacity(0.12) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(w.subtitle)
    }

    @ViewBuilder private func chatRow(_ r: RPChatRow, session: UUID?) -> some View {
        HStack(spacing: 5) {
            Group {
                if r.state == .working { PulseDot(color: r.state.color, size: 7 * s) }
                else { Circle().fill(r.state.color).frame(width: 7 * s, height: 7 * s) }
            }.help(r.state.label)
            if r.chief { Image(systemName: "star.fill").font(.system(size: 8 * s)).foregroundStyle(.orange) }
            Text(r.title).font(.system(size: 12 * s, weight: r.placed ? .medium : .regular)).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(r.placed ? Color.primary : Color.secondary)
            Spacer(minLength: 2)
            // 滑過去才出現的小 ⓘ：點了打開「聊天室資訊」
            if hoverRow == r.id || panelModel.selectedChat == r.id {
                Button { openInfo(r.id) } label: { Image(systemName: "info.circle").font(.system(size: 11 * s)) }
                    .buttonStyle(.plain).foregroundStyle(hoverRow == r.id ? Color.primary.opacity(0.7) : Color.secondary.opacity(0.5))
                    .help(L("聊天室資訊（選取後按 i）"))
            }
            Text(r.memory.map(RPData.shortBytes) ?? "—").frame(width: 42 * s, alignment: .trailing)
            Text(r.context.map(ContextMonitor.text) ?? "—").frame(width: 36 * s, alignment: .trailing)
        }
        .font(.system(size: 10.5 * s)).monospacedDigit().foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 2)
        .frame(minHeight: 20 * s)
        // 不要「叫出來」按鈕；滑鼠移到那一列整列淡底色、單擊選取（紫框保持）、雙擊叫出來（右鍵選單裡還有「叫出來」）；
        // 停 1.5 秒浮出資訊卡
        .background(RPRowHighlight(flash: false, hover: hoverRow == r.id, selected: panelModel.selectedChat == r.id))
        .contentShape(Rectangle())
        .onHover { inside in
            hoverRow = inside ? r.id : (hoverRow == r.id ? nil : hoverRow)
            if inside { ChatInfoCard.shared.hoverBegan(r.id, store: store, workspace: workspace, window: windowBox.window) }
            else { ChatInfoCard.shared.hoverEnded(r.id) }
        }
        .onTapGesture(count: 2) { if let session { store.summonConversation(r.id, inSession: session) } }
        .simultaneousGesture(TapGesture().onEnded {
            panelModel.selectedChat = r.id
            listFocused = true
            ChatInfoCard.shared.cancel()
        })
        .help("\(r.title) · \(r.state.label)")
        // 右鍵：叫出來、移到別的組、封存（總指揮版面找不到）
        .contextMenu {
            Button(L("叫出來")) { if let session { store.summonConversation(r.id, inSession: session) } }
            Button(L("聊天室資訊…")) { openInfo(r.id) }
            Button(L("重新命名…")) { renameText = r.title; renamingID = r.id }
            if let c = store.conversation(r.id), !store.groups.isEmpty {
                Menu(L("移到…")) {
                    ForEach(store.groupTree(), id: \.group.id) { t in
                        Button((store.groupOf(c) == t.group.id ? "✓ " : "") + String(repeating: "　", count: t.depth) + t.group.name) { store.move(c.id, toGroup: t.group.id) }
                    }
                }
                Button(store.isArchived(c) ? L("取消封存") : L("封存")) { store.setArchived(c.id, !store.isArchived(c)) }
            }
            if let c = store.conversation(r.id), Store.isChat(c) {
                Menu(L("MCP（下次啟動生效）")) {
                    ForEach(McpMode.allCases, id: \.self) { m in
                        Button((McpMode.from(c.mcp) == m ? "✓ " : "") + m.label) { store.setMcp(c.id, m) }
                    }
                }
            }
            if let c = store.conversation(r.id), !r.chief {
                Button((c.commanderMayRename == true ? "✓ " : "") + L("讓總指揮改名")) { store.setCommanderMayRename(c.id, c.commanderMayRename != true) }
            }
        }
        .alert(L("重新命名對話"), isPresented: Binding(get: { renamingID == r.id }, set: { if !$0 && renamingID == r.id { renamingID = nil } })) {
            TextField(L("名稱"), text: $renameText)
            Button(L("好")) { store.rename(r.id, to: renameText, byUser: true); renamingID = nil }
            Button(L("取消"), role: .cancel) { renamingID = nil }
        }
        .onAppear {
            if r.context == nil, let c = store.conversation(r.id), let p = store.project(c.projectID)?.path { ctx.load(c, path: p) }
        }
    }

    private var portsBar: some View {
        HStack {
            Button { portsOpen.toggle(); if portsOpen { ports.refresh(force: true) } } label: {
                HStack(spacing: 4) {
                    Image(systemName: "network").font(.system(size: 9.5 * s))
                    Text("Ports (\(ports.entries.count))").font(.system(size: 10.5 * s))
                }
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.16)))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $portsOpen, arrowEdge: .top) { portsList }
            .help(L("監聽中的連接埠（lsof，10 秒更新一次）"))
            if !colab.machines.isEmpty {
                Button { colabOpen.toggle(); if colabOpen { colab.reload(force: true) } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "cloud").font(.system(size: 9.5 * s))
                        Text("Colab (\(colab.machines.count))").font(.system(size: 10.5 * s))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.18)))
                    .foregroundStyle(Color.orange)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $colabOpen, arrowEdge: .top) { ColabPopover() }
                .help(L("開著的 Colab 機器（開著就會一直扣運算單元）"))
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
    }

    private var portsList: some View {
        VStack(alignment: .leading, spacing: 2) {
            if ports.entries.isEmpty {
                Text(L("沒有監聽中的連接埠")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(ports.entries) { e in
                        HStack(spacing: 8) {
                            Text(verbatim: ":\(e.port)").font(.system(size: 11, design: .monospaced)).frame(width: 54, alignment: .leading)
                            Text(e.name).font(.system(size: 11)).lineLimit(1)
                            if e.ours { Text("codenv").font(.system(size: 9.5)).padding(.horizontal, 4).background(Capsule().fill(Color.accentColor.opacity(0.2))).foregroundStyle(Color.accentColor) }
                            Spacer(minLength: 8)
                            Text(verbatim: "pid \(e.pid)").font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                        .help(e.address)
                    }
                }
            }
            .frame(maxHeight: 240)
        }
        .padding(10).frame(minWidth: 260)
    }
}

// MARK: 檔案

struct RPFilesTab: View {
    @Environment(\.uiScale) private var s
    @ObservedObject var store: Store
    @ObservedObject var model: RightPanelModel
    @ObservedObject private var tree: FileTreeModel
    @ObservedObject private var search: FileSearchModel
    @State private var query = ""
    @State private var contentMode = false
    @State private var pending: DispatchWorkItem?

    init(store: Store, model: RightPanelModel) {
        self.store = store
        self.model = model
        tree = model.files
        search = model.search
    }

    var body: some View {
        VStack(spacing: 0) {
            RPProjectBar(project: store.rightPanelProject(), refresh: { tree.reload() })
            Divider().opacity(0.5)
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 10 * s)).foregroundStyle(.secondary)
                TextField(contentMode ? L("搜尋檔案內容") : L("搜尋檔名"), text: $query)
                    .textFieldStyle(.plain).font(.system(size: 11.5 * s))
                    .onSubmit { run(now: true) }
                if search.running { ProgressView().controlSize(.mini) }
                else if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 10 * s)) }.buttonStyle(.plain).foregroundStyle(.tertiary) }
                Picker("", selection: $contentMode) {
                    Text(L("檔名")).tag(false)
                    Text(L("內容")).tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.mini).frame(width: 84 * s)
            }
            .padding(.horizontal, 10).frame(height: 26 * s)
            Divider().opacity(0.5)
            if query.trimmingCharacters(in: .whitespaces).isEmpty { treeList } else { results }
        }
        .onChange(of: query) { _, _ in run(now: false) }
        .onChange(of: contentMode) { _, _ in run(now: true) }
    }

    private func run(now: Bool) {
        pending?.cancel()
        let w = DispatchWorkItem { search.search(query, content: contentMode, root: model.projectPath) }
        pending = w
        if now { w.perform() } else { DispatchQueue.main.asyncAfter(deadline: .now() + (contentMode ? 0.6 : 0.25), execute: w) }
    }

    private var treeList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if tree.rows.isEmpty {
                    Text(model.projectPath == nil ? L("沒有目前專案") : L("這個資料夾是空的")).font(.system(size: 11 * s)).foregroundStyle(.tertiary).padding(10)
                }
                ForEach(tree.rows) { n in
                    HStack(spacing: 4) {
                        Spacer().frame(width: CGFloat(n.depth) * 11 * s)
                        Image(systemName: n.isDir ? (tree.isExpanded(n) ? "chevron.down" : "chevron.right") : "doc")
                            .font(.system(size: 8.5 * s)).foregroundStyle(.secondary).frame(width: 10 * s)
                        Text(n.name).font(.system(size: 11.5 * s)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).frame(height: 20 * s)
                    .contentShape(Rectangle())
                    .onTapGesture { if n.isDir { tree.toggle(n) } else { NSWorkspace.shared.open(URL(fileURLWithPath: n.path)) } }
                    .contextMenu {
                        Button(L("在 Finder 顯示")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: n.path)]) }
                        if !n.isDir { Button(L("打開")) { NSWorkspace.shared.open(URL(fileURLWithPath: n.path)) } }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !search.note.isEmpty { Text(search.note).font(.system(size: 10 * s)).foregroundStyle(.tertiary).padding(.horizontal, 10).padding(.top, 4) }
                if search.hits.isEmpty && !search.running {
                    Text(L("沒有符合的")).font(.system(size: 11 * s)).foregroundStyle(.tertiary).padding(10)
                }
                ForEach(search.hits) { h in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 4) {
                            Text((h.rel as NSString).lastPathComponent).font(.system(size: 11.5 * s, weight: .medium)).lineLimit(1)
                            if let l = h.line { Text(verbatim: ":\(l)").font(.system(size: 10 * s)).foregroundStyle(.secondary) }
                            Text((h.rel as NSString).deletingLastPathComponent).font(.system(size: 10 * s)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                            Spacer(minLength: 0)
                        }
                        if let t = h.text { Text(t).font(.system(size: 10.5 * s, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 2.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: h.path)) }
                    .contextMenu { Button(L("在 Finder 顯示")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: h.path)]) } }
                    .help(h.rel)
                }
            }
        }
    }
}

// MARK: Git

struct RPGitTab: View {
    @Environment(\.uiScale) private var s
    @ObservedObject var store: Store
    @ObservedObject var model: RightPanelModel
    @ObservedObject private var git: GitPanelModel
    @State private var wtOpen: Bool?
    private let tick = Timer.publish(every: 8, on: .main, in: .common).autoconnect()

    init(store: Store, model: RightPanelModel) {
        self.store = store
        self.model = model
        git = model.git
    }

    var body: some View {
        VStack(spacing: 0) {
            RPProjectBar(project: store.rightPanelProject(), refresh: { git.refresh() })
            Divider().opacity(0.5)
            if model.projectPath == nil {
                hint(L("沒有目前專案"))
            } else if git.isRepo == false {
                hint(L("這個資料夾不是 git 專案"))
            } else if git.isRepo == nil {
                hint(L("讀取中…"))
            } else {
                branchLine
                worktrees
                changeList
                if git.selected != nil { Divider(); diffView }
            }
            Spacer(minLength: 0)
        }
        .onAppear { git.refresh() }
        .onReceive(tick) { _ in if NSApp.isActive { git.refresh() } }
    }

    private func hint(_ t: String) -> some View {
        Text(t).font(.system(size: 11 * s)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 16)
    }

    private var branchLine: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 10 * s)).foregroundStyle(.secondary)
            Text(git.branch).font(.system(size: 11.5 * s, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            Text(git.changes.isEmpty ? L("乾淨") : L("\(git.changes.count) 項變更")).font(.system(size: 10 * s)).foregroundStyle(.secondary)
            Spacer()
            if git.loading { ProgressView().controlSize(.mini) }
        }
        .padding(.horizontal, 10).frame(height: 22 * s)
    }

    @ViewBuilder private var worktrees: some View {
        let open = wtOpen ?? (git.worktrees.count > 1)
        VStack(alignment: .leading, spacing: 0) {
            Button { wtOpen = !open } label: {
                HStack(spacing: 4) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 8 * s, weight: .semibold))
                    Text("Worktree (\(git.worktrees.count))").font(.system(size: 10.5 * s, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(.secondary).padding(.horizontal, 10).frame(height: 20 * s).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                ForEach(git.worktrees) { t in
                    HStack(spacing: 5) {
                        Image(systemName: t.isCurrent ? "circle.fill" : "circle").font(.system(size: 6 * s)).foregroundStyle(t.isCurrent ? Color.green : Color.secondary)
                        Text(t.branch).font(.system(size: 11 * s, weight: t.isCurrent ? .semibold : .regular)).lineLimit(1)
                        Text(RPData.abbreviate(t.path)).font(.system(size: 10 * s)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 18).frame(height: 18 * s)
                    .contentShape(Rectangle())
                    .onTapGesture { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: t.path)]) }
                    .help(t.path)
                }
            }
        }
    }

    private var changeList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                section(L("已暫存"), .staged)
                section(L("未暫存"), .unstaged)
                section(L("未追蹤"), .untracked)
            }
        }
        .frame(maxHeight: git.selected == nil ? .infinity : 150 * s)
    }

    @ViewBuilder private func section(_ title: String, _ kind: GitPanelModel.Kind) -> some View {
        let items = git.changes.filter { $0.kind == kind }
        if !items.isEmpty {
            Text("\(title) (\(items.count))").font(.system(size: 10.5 * s, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 5).padding(.bottom, 1)
            ForEach(items) { c in
                HStack(spacing: 6) {
                    Text(c.code).font(.system(size: 10.5 * s, weight: .bold, design: .monospaced)).foregroundStyle(color(c.code)).frame(width: 10 * s)
                    Text((c.path as NSString).lastPathComponent).font(.system(size: 11.5 * s)).lineLimit(1)
                    Text((c.path as NSString).deletingLastPathComponent).font(.system(size: 10 * s)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).frame(height: 19 * s)
                .background(git.selected?.id == c.id ? Color.accentColor.opacity(0.15) : .clear)
                .contentShape(Rectangle())
                .onTapGesture { git.select(c) }
                .help(c.path)
            }
        }
    }

    private func color(_ code: String) -> Color {
        switch code {
        case "A", "?": return .green
        case "D": return .red
        case "R", "C": return .purple
        default: return .orange
        }
    }

    private var diffView: some View {
        let lines = Array(git.diff.split(separator: "\n", omittingEmptySubsequences: false).prefix(3000))
        return VStack(spacing: 0) {
            HStack {
                Text(git.selected?.path ?? "").font(.system(size: 10.5 * s, weight: .semibold)).lineLimit(1).truncationMode(.head)
                Spacer()
                Button { git.selected = nil } label: { Image(systemName: "xmark").font(.system(size: 9 * s)) }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).frame(height: 20 * s)
            if !git.diffNote.isEmpty { Text(git.diffNote).font(.system(size: 10.5 * s)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 4) }
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                        let t = String(l)
                        Text(t.isEmpty ? " " : t).font(.system(size: 10.5 * s, design: .monospaced)).fixedSize()
                            .foregroundStyle(lineColor(t))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(lineBackground(t))
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func lineColor(_ t: String) -> Color {
        if t.hasPrefix("+++") || t.hasPrefix("---") { return .secondary }
        if t.hasPrefix("+") { return Color(nsColor: .systemGreen) }
        if t.hasPrefix("-") { return Color(nsColor: .systemRed) }
        if t.hasPrefix("@@") { return Color(nsColor: .systemCyan) }
        if t.hasPrefix("diff ") || t.hasPrefix("index ") { return .secondary }
        return .primary
    }

    private func lineBackground(_ t: String) -> Color {
        if t.hasPrefix("+++") || t.hasPrefix("---") { return .clear }
        if t.hasPrefix("+") { return Color.green.opacity(0.10) }
        if t.hasPrefix("-") { return Color.red.opacity(0.10) }
        return .clear
    }
}

// MARK: 歷史

struct RPHistoryTab: View {
    @Environment(\.uiScale) private var s
    @ObservedObject var store: Store
    @ObservedObject var model: RightPanelModel
    @ObservedObject private var history: HistorySearchModel
    @State private var query = ""
    @State private var hoverHit: UUID?
    @State private var flashHit: UUID?

    init(store: Store, model: RightPanelModel) {
        self.store = store
        self.model = model
        history = model.history
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 10 * s)).foregroundStyle(.secondary)
                TextField(L("搜尋這個總指揮的所有對話"), text: $query).textFieldStyle(.plain).font(.system(size: 11.5 * s))
                    .onSubmit { start() }
                if history.running {
                    Button(L("取消")) { history.stop() }.buttonStyle(.plain).font(.system(size: 10.5 * s)).foregroundStyle(Color.accentColor)
                } else {
                    RPSmallButton(title: L("搜尋")) { start() }
                }
            }
            .padding(.horizontal, 10).frame(height: 28 * s)
            Divider().opacity(0.5)
            HStack(spacing: 5) {
                if history.running { ProgressView().controlSize(.mini) }
                Text(status).font(.system(size: 10 * s)).foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 10).frame(height: 18 * s)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(history.hits) { h in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text(h.title).font(.system(size: 11.5 * s, weight: .semibold)).lineLimit(1)
                                Spacer(minLength: 2)
                            }
                            Text("\(h.role == "user" ? "› " : "‹ ")\(h.snippet)").font(.system(size: 10.5 * s)).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(RPRowHighlight(flash: flashHit == h.id, hover: hoverHit == h.id))
                        .contentShape(Rectangle())
                        .onHover { inside in hoverHit = inside ? h.id : (hoverHit == h.id ? nil : hoverHit) }
                        .onTapGesture(count: 2) { summon(h.conversation) }
                        .simultaneousGesture(TapGesture().onEnded {
                            withAnimation(.easeOut(duration: 0.08)) { flashHit = h.id }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { withAnimation(.easeOut(duration: 0.15)) { if flashHit == h.id { flashHit = nil } } }
                        })
                        Divider().opacity(0.3)
                    }
                }
            }
        }
    }

    private var status: String {
        if history.total == 0 && !history.running { return query.isEmpty ? L("輸入關鍵字，Enter 搜尋") : "" }
        if history.running && history.usingIndex { return L("搜尋中…第一次要建索引（約一分鐘，在背景跑）") }
        let n = history.hits.count
        let head = history.indexed ? L("找到 \(n) 筆 · 全文索引 \(history.total) 個聊天室") : L("找到 \(n) 筆 · 已看 \(history.scanned)/\(history.total) 個聊天室")
        return head + (n >= HistorySearchModel.limit ? L("（只列前 200 筆）") : "")
    }

    private func start() { history.search(query, targets: RPData.historyTargets(store), convs: RPData.historyConvs(store)) }

    private func summon(_ id: UUID) {
        if let sid = store.currentSessionLayout?.id { store.summonConversation(id, inSession: sid) }
    }
}

// MARK: 測試：--dump-right

extension RightPanelModel {
    func dump(store: Store, workspace: Workspace) -> [String: Any] {
        let chats = RPData.chats(store, workspace: workspace)
        func chat(_ r: RPChatRow) -> [String: Any] {
            ["title": r.title, "state": r.state.rawValue, "memory": r.memory.map { Int($0) } ?? NSNull(), "context": r.context ?? NSNull(),
             "placed": r.placed, "chief": r.chief]
        }
        var o: [String: Any] = [
            "tab": tab.rawValue, "panelOn": PetSlot.enabled, "petSlot": petSlotOn,
            "project": store.rightPanelProject().map { ["name": $0.name, "path": $0.path] } ?? NSNull(),
            "session": store.currentSessionLayout?.name ?? NSNull(),
        ]
        switch tab {
        case .windows:
            o["windows"] = RPData.windows(store).map { ["title": $0.title, "subtitle": $0.subtitle, "status": $0.status] }
            o["chats"] = chats.sections.map { ["group": $0.name ?? NSNull(), "rows": $0.rows.map(chat)] as [String: Any] }
            o["archived"] = chats.archived.map(chat)
            o["ports"] = PortsMonitor.shared.entries.map { ["port": $0.port, "name": $0.name, "pid": Int($0.pid), "ours": $0.ours] as [String: Any] }
        case .files:
            o["tree"] = files.rows.prefix(80).map { String(repeating: "  ", count: $0.depth) + ($0.isDir ? "▸ " : "") + $0.name }
            o["searchHits"] = search.hits.prefix(40).map { "\($0.rel)\($0.line.map { ":\($0)" } ?? "") \($0.text ?? "")" }
            o["searchNote"] = search.note
        case .git:
            o["isRepo"] = git.isRepo.map { $0 as Any } ?? NSNull()
            o["branch"] = git.branch
            o["changes"] = git.changes.map { "\($0.kind.rawValue) \($0.code) \($0.path)" }
            o["worktrees"] = git.worktrees.map { "\($0.branch) \($0.path)\($0.isCurrent ? " *" : "")" }
            o["selected"] = git.selected?.path ?? NSNull()
            o["diffLines"] = git.diff.split(separator: "\n", omittingEmptySubsequences: false).count
        case .history:
            o["hits"] = history.hits.prefix(40).map { "\($0.title) [\($0.role)] \($0.snippet)" }
            o["scanned"] = history.scanned; o["total"] = history.total; o["indexed"] = history.indexed
        case .board:
            o["boardTab"] = CollabBoardModel.shared.tab
            o["goals"] = CollabBoardModel.shared.goals.count
        }
        return o
    }
}
