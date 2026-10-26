import SwiftUI
import AppKit

// 「整理對話」視窗（⌘ ⇧ O）：一張表列出全部對話，可以多選一次改組、封存、改名、刪除。
// 側欄只剩「組 → 對話」之後，資料夾的設定（預設組、在 Finder 打開、移除）也放在這裡的「資料夾」分頁。

struct OrganizerRow: Identifiable {
    let id: UUID
    let title: String
    let group: String
    let folder: String
    let lastUsed: Date
    let size: Int64
    let archived: Bool
    let busy: Bool
}

final class OrganizerModel: ObservableObject {
    @Published var sizes: [UUID: Int64] = [:]

    /// 紀錄檔大小（在背景量，一百多個檔案一下就好）
    func loadSizes(_ store: Store) {
        let list = store.conversations.map { c in (c.id, Store.claudeTranscript(c.claudeSession, path: store.project(c.projectID)?.path ?? NSHomeDirectory())) }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var out: [UUID: Int64] = [:]
            for (id, url) in list {
                out[id] = ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize).map(Int64.init) ?? 0
            }
            DispatchQueue.main.async { self?.sizes = out }
        }
    }
}

extension Store {
    /// 整理對話列的對話：掛件（掛件框底下藏起來的瀏覽器格子）不列，也不算進資料夾的對話數
    var organizerConversations: [Conversation] { conversations.filter { !$0.isGadget } }
}

struct OrganizerView: View {
    @Environment(\.uiScale) private var s
    @ObservedObject var store: Store
    @ObservedObject var model: OrganizerModel
    var open: (UUID) -> Void
    var delete: ([UUID]) -> Void
    var removeFolder: (UUID) -> Void

    @State private var tab = 0
    @State private var search = ""
    @State private var filter = "all"           // all、archived、組的 id
    @State private var selection = Set<UUID>()
    @State private var sortOrder = [KeyPathComparator(\OrganizerRow.lastUsed, order: .reverse)]
    @State private var renaming: UUID?
    @State private var renameText = ""

    private var rows: [OrganizerRow] {
        store.organizerConversations.map { c in
            OrganizerRow(id: c.id, title: c.title,
                         group: store.group(store.groupOf(c))?.name ?? "",
                         folder: store.project(c.projectID).map { ClaudeEnvs.tilde($0.path) } ?? "",
                         lastUsed: store.lastTouched(c),
                         size: model.sizes[c.id] ?? 0,
                         archived: store.isArchived(c),
                         busy: store.status[c.id] != nil)
        }
        .filter { r in
            switch filter {
            case "all": return true
            case "archived": return r.archived
            case "active": return !r.archived
            case "empty": return r.size == 0 && !r.busy
            default: return store.conversation(r.id).flatMap { store.groupOf($0) }?.uuidString == filter
            }
        }
        .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.folder.localizedCaseInsensitiveContains(search) }
        .sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text(L("對話")).tag(0)
                Text(L("資料夾")).tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 220).padding(.top, 12).padding(.bottom, 8)
            if tab == 0 { conversationsTab } else { foldersTab }
        }
        .frame(minWidth: 760, minHeight: 460)
        .onAppear { model.loadSizes(store) }
        .alert(L("重新命名對話"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L("名稱"), text: $renameText)
            Button(L("好")) { if let r = renaming { store.rename(r, to: renameText, byUser: true) }; renaming = nil }
            Button(L("取消"), role: .cancel) { renaming = nil }
        }
    }

    // MARK: 對話

    private var conversationsTab: some View {
        let list = rows
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField(L("搜尋標題或資料夾"), text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Picker("", selection: $filter) {
                    Text(L("全部")).tag("all")
                    Text(L("沒封存的")).tag("active")
                    Text(L("封存的")).tag("archived")
                    Text(L("空的（沒傳過訊息）")).tag("empty")
                    Divider()
                    ForEach(store.groupTree(), id: \.group.id) { t in Text(store.groupPath(t.group.id)).tag(t.group.id.uuidString) }
                }
                .labelsHidden().frame(width: 150)
                Spacer()
                Text(L("\(list.count) 段") + (selection.isEmpty ? "" : L("，選了 \(selection.count) 段"))).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.bottom, 8)

            Table(list, selection: $selection, sortOrder: $sortOrder) {
                TableColumn(L("標題"), value: \.title) { r in
                    HStack(spacing: 6) {
                        if r.busy { Circle().fill(Color.blue).frame(width: 6, height: 6) }
                        Text(r.title).lineLimit(1).foregroundStyle(r.archived ? .secondary : .primary)
                    }
                }
                .width(min: 180, ideal: 320)
                TableColumn(L("組"), value: \.group) { r in Text(r.group).lineLimit(1) }.width(min: 70, ideal: 110)
                TableColumn(L("資料夾"), value: \.folder) { r in Text(r.folder).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary) }.width(min: 90, ideal: 230)
                TableColumn(L("最後使用"), value: \.lastUsed) { r in Text(Self.relative(r.lastUsed)).foregroundStyle(.secondary) }.width(min: 70, ideal: 90)
                TableColumn(L("紀錄大小"), value: \.size) { r in Text(Self.bytes(r.size)).monospacedDigit().foregroundStyle(.secondary) }.width(min: 60, ideal: 75)
                TableColumn(L("封存"), value: \.archivedKey) { r in Text(r.archived ? L("封存") : "").foregroundStyle(.secondary) }.width(min: 40, ideal: 50)
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                actions(for: ids)
            } primaryAction: { ids in
                if let id = ids.first { open(id) }
            }

            HStack(spacing: 10) {
                Menu(L("移到…")) {
                    ForEach(store.groupTree(), id: \.group.id) { t in Button(store.groupPath(t.group.id)) { for id in selection { store.move(id, toGroup: t.group.id) } } }
                }
                .fixedSize()
                Button(L("封存")) { for id in selection { store.setArchived(id, true) } }
                Button(L("取消封存")) { for id in selection { store.setArchived(id, false) } }
                Button(L("重新命名…")) { if let id = selection.first, let c = store.conversation(id) { renameText = c.title; renaming = id } }
                    .disabled(selection.count != 1)
                Spacer()
                Button(L("刪除…"), role: .destructive) { delete(Array(selection)); selection = selection.filter { store.conversation($0) != nil } }
            }
            .disabled(selection.isEmpty)
            .padding(12)
            Text(L("點兩下打開。刪除會把 Claude 的紀錄檔丟進垃圾桶（可以從垃圾桶救回）；正在跑的不會刪。"))
                .font(.caption).foregroundStyle(.secondary).padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private func actions(for ids: Set<UUID>) -> some View {
        if ids.count == 1, let id = ids.first {
            Button(L("打開")) { open(id) }
            Button(L("重新命名…")) { if let c = store.conversation(id) { renameText = c.title; renaming = id } }
            Divider()
        }
        Menu(L("移到…")) { ForEach(store.groupTree(), id: \.group.id) { t in Button(store.groupPath(t.group.id)) { for id in ids { store.move(id, toGroup: t.group.id) } } } }
        Button(L("封存")) { for id in ids { store.setArchived(id, true) } }
        Button(L("取消封存")) { for id in ids { store.setArchived(id, false) } }
        Divider()
        Button(L("刪除…"), role: .destructive) { delete(Array(ids)) }
    }

    // MARK: 資料夾

    private var foldersTab: some View {
        List {
            ForEach(store.projects) { p in
                let n = store.organizerConversations.filter { $0.projectID == p.id }.count
                HStack(spacing: 12) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).lineLimit(1)
                        Text(ClaudeEnvs.tilde(p.path)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Text(L("\(n) 段")).foregroundStyle(.secondary).monospacedDigit()
                    if !store.groups.isEmpty {
                        Picker(L("新對話放在"), selection: Binding(get: { p.groupID ?? store.fallbackGroupID ?? UUID() }, set: { store.setDefaultGroup(p.id, to: $0) })) {
                            ForEach(store.groupTree(), id: \.group.id) { t in Text(store.groupPath(t.group.id)).tag(t.group.id) }
                        }
                        .frame(width: 190)
                    }
                    Button("Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: p.path) }
                    Button(role: .destructive) { removeFolder(p.id) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help(L("從側欄和 claude 選單清單移除（不會刪資料夾，也不會刪對話紀錄）"))
                }
                .padding(.vertical, 3)
            }
        }
    }

    static func relative(_ d: Date) -> String {
        let t = Date().timeIntervalSince(d)
        if t < 3600 { return L("\(max(1, Int(t / 60))) 分鐘前") }
        if t < 86400 { return L("\(Int(t / 3600)) 小時前") }
        if t < 86400 * 60 { return L("\(Int(t / 86400)) 天前") }
        let f = DateFormatter(); f.dateFormat = "yyyy/M/d"
        return f.string(from: d)
    }

    static func bytes(_ n: Int64) -> String {
        if n <= 0 { return "—" }
        if n < 1_000_000 { return "\(max(1, n / 1000)) KB" }
        return String(format: "%.1f MB", Double(n) / 1e6)
    }
}

extension OrganizerRow {
    var archivedKey: Int { archived ? 1 : 0 }
}

final class OrganizerWindowController: NSWindowController {
    let model = OrganizerModel()
    init(store: Store, open: @escaping (UUID) -> Void, delete: @escaping ([UUID]) -> Void, removeFolder: @escaping (UUID) -> Void) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = L("整理對話")
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName(appDefaults === UserDefaults.standard ? "OrganizerWindow" : "")
        super.init(window: w)
        let view = OrganizerView(store: store, model: model, open: open, delete: delete, removeFolder: removeFolder)
            .environment(\.uiScale, 1)
        let hc = NSHostingController(rootView: view)
        hc.sizingOptions = [.minSize]   // 不要讓 SwiftUI 把視窗縮成最小尺寸
        w.contentViewController = hc
        if !w.setFrameUsingName("OrganizerWindow") { w.setContentSize(NSSize(width: 1040, height: 660)); w.center() }
    }
    required init?(coder: NSCoder) { fatalError() }
}
