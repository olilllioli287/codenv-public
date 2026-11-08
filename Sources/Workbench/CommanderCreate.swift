import SwiftUI

/// 新增／刪除總指揮：以前只能靠私人版的一次性遷移建出來，公版（不跑遷移）完全沒有入口
extension Store {
    /// 新建總指揮要填的東西。existing＝涵蓋的既有分組；newGroup＝順便新建一個分組並指到某個資料夾
    struct NewCommander {
        var name: String
        var groups: [UUID] = []
        var newGroupName: String? = nil
        var newGroupFolder: String? = nil
        var kind: String? = nil          // nil＝自動；"single"／"multi"
    }

    /// 這個分組已經被哪個總指揮「直接」涵蓋（另一個總指揮若要涵蓋同一組，同深度時先建的勝出，新的拿不到，所以表單不讓選）
    func commanderDirectlyCovering(_ g: UUID) -> SessionLayout? {
        sessions.first { $0.area == nil && ($0.groups ?? []).contains(g) }
    }

    /// 涵蓋這些分組的資料夾（專案）：總指揮聊天室的工作資料夾從這裡挑第一個
    func projectsCovered(by roots: [UUID]) -> [Project] {
        projects.filter { p in p.groupID.map { g in roots.contains { isGroup(g, within: $0) } } ?? false }
    }

    /// 建立總指揮：新分組（要的話）、總指揮聊天室（只建資料，不啟動 Claude）、首頁 Session。回傳 Session id；失敗回 nil 並寫原因
    @discardableResult
    func createCommander(_ req: NewCommander, error: inout String?) -> UUID? {
        let name = req.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { error = L("請填總指揮的名稱"); return nil }
        guard !sessions.contains(where: { $0.area == nil && $0.groups != nil && $0.name == name }) else {
            error = L("已經有叫「\(name)」的總指揮"); return nil
        }
        var roots = req.groups.filter { g in groups.contains { $0.id == g } && commanderDirectlyCovering(g) == nil }
        var folderProject: Project?
        if let gname = req.newGroupName?.trimmingCharacters(in: .whitespacesAndNewlines), !gname.isEmpty {
            guard let folder = req.newGroupFolder, !folder.isEmpty, FileManager.default.fileExists(atPath: folder) else {
                error = L("新建分組要選一個存在的資料夾"); return nil
            }
            // 第一次用分組：先放一個「其他」，沒歸組的聊天室留在那裡，不會全被新分組吞掉
            if groups.isEmpty { addGroup(named: Store.otherGroupName) }
            let g = addGroup(named: gname)
            let p = addProject(path: folder)
            if let i = projects.firstIndex(where: { $0.id == p.id }) { projects[i].groupID = g.id; folderProject = projects[i] }
            if commanderDirectlyCovering(g.id) == nil { roots.append(g.id) }
        }
        guard !roots.isEmpty else { error = L("至少要涵蓋一個分組（選既有的，或新建一個）"); return nil }
        guard let project = folderProject ?? projectsCovered(by: roots).first else {
            error = L("涵蓋的分組裡還沒有任何資料夾：請改選有資料夾的分組，或新建一個分組並選資料夾"); return nil
        }
        var chief = Conversation(projectID: project.id, title: name + "總指揮")
        chief.renamed = true
        chief.groupID = roots.first
        chief.order = (conversations.compactMap(\.order).min() ?? 0) - 1
        chief.model = Prefs.shared.defaultModel
        chief.effort = Prefs.shared.defaultEffort
        conversations.append(chief)
        let w = WindowLayout(name: "1", root: .leaf(chief.id), focused: chief.id)
        var s = SessionLayout(name: name, windows: [w], current: w.id)
        s.groups = roots
        s.chief = chief.id
        s.commanderKind = req.kind
        sessions.append(s)
        // 使用者自己管總指揮了：私人版的一次性遷移不要在刪光之後又把九個建回來
        appDefaults.set(true, forKey: Store.commanderMigrationDoneKey)
        selectSession(s.id)
        return s.id
    }

    static let commanderMigrationDoneKey = "commandersManaged.1"

    /// 只移除這個總指揮（Session）：聊天室、分組、資料夾都不動，回到一般樹狀照樣看得到
    /// 刪掉一個總指揮後，沒人涵蓋的分組歸誰：有涵蓋「其他」的總指揮就歸它，沒有就歸第一個總指揮（Groups.commanderSessionID 的兜底）。回名字給刪除確認對話框
    func commanderFallbackName(excluding id: UUID?) -> String {
        let other = groups.first { $0.name == Store.otherGroupName && $0.parentID == nil }?.id
        let rest = sessions.filter { $0.area == nil && $0.groups != nil && $0.id != id }
        let pick = rest.first { s in other != nil && (s.groups ?? []).contains(other!) } ?? rest.first
        return pick?.name ?? L("（沒有其他總指揮）")
    }

    func deleteCommander(_ id: UUID) {
        guard sessions.contains(where: { $0.id == id && $0.area == nil && $0.groups != nil }) else { return }
        appDefaults.set(true, forKey: Store.commanderMigrationDoneKey)
        deleteSession(id)
    }
}

/// 「新增總指揮」小表單
struct CommanderCreateForm: View {
    @ObservedObject var store: Store
    @Environment(\.uiScale) private var s
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var picked = Set<UUID>()
    @State private var makeNewGroup = false
    @State private var newGroupName = ""
    @State private var newFolder = ""
    @State private var kind = "auto"
    @State private var problem: String?

    private var groupRows: [(group: ConvGroup, depth: Int)] {
        store.groupTree().filter { $0.group.name != Store.codeLabGroupName }.map { ($0.group, $0.depth) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("新增總指揮")).font(.system(size: 16 * s, weight: .semibold))
            Text(L("總指揮管一批分組：左欄列出它底下的聊天室，並同時開一個總指揮聊天室來派工。")).font(.system(size: 12 * s)).foregroundStyle(.secondary)
            TextField(L("總指揮名稱（例如：網站）"), text: $name).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("commander-name")

            VStack(alignment: .leading, spacing: 4) {
                Text(L("涵蓋哪些分組")).font(.system(size: 12 * s, weight: .medium))
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if groupRows.isEmpty {
                            Text(L("還沒有任何分組。請在下面新建一個。")).font(.system(size: 12 * s)).foregroundStyle(.tertiary)
                        }
                        ForEach(groupRows, id: \.group.id) { row in
                            let owner = store.commanderDirectlyCovering(row.group.id)
                            Toggle(isOn: Binding(get: { picked.contains(row.group.id) },
                                                 set: { if $0 { picked.insert(row.group.id) } else { picked.remove(row.group.id) } })) {
                                Text(String(repeating: "　", count: row.depth) + row.group.name + (owner.map { "（" + L("已歸「\($0.name)」") + "）" } ?? ""))
                            }
                            .disabled(owner != nil)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 110)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            }

            Toggle(L("新建一個分組（並指到一個資料夾）"), isOn: $makeNewGroup)
            if makeNewGroup {
                HStack {
                    TextField(L("分組名稱"), text: $newGroupName).textFieldStyle(.roundedBorder)
                    TextField(L("資料夾路徑"), text: $newFolder).textFieldStyle(.roundedBorder)
                    Button(L("選…")) {
                        let p = NSOpenPanel()
                        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
                        if p.runModal() == .OK, let u = p.url {
                            newFolder = u.path
                            if newGroupName.isEmpty { newGroupName = u.lastPathComponent }
                        }
                    }
                }
            }

            Picker(L("類型"), selection: $kind) {
                Text(L("自動（依分組結構）")).tag("auto")
                Text(L("單一專案")).tag("single")
                Text(L("多個子專案")).tag("multi")
            }
            Text(L("單一專案＝整個總指揮是一個專案；多個子專案＝底下的子分組各是一個專案。")).font(.system(size: 11 * s)).foregroundStyle(.tertiary)

            if let problem { Text(problem).font(.system(size: 12 * s)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(L("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("建立")) { create() }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 460)
    }

    private func create() {
        var err: String?
        let req = Store.NewCommander(name: name, groups: Array(picked),
                                     newGroupName: makeNewGroup ? newGroupName : nil,
                                     newGroupFolder: makeNewGroup ? newFolder : nil,
                                     kind: kind == "auto" ? nil : kind)
        if store.createCommander(req, error: &err) != nil { dismiss() } else { problem = err }
    }
}
