import Foundation

// 側欄最上層的分組：只是工作台裡的分類，不搬任何實體資料夾、不改 Claude 的對話紀錄。
// 對話歸哪一組：自己指定的（Conversation.groupID）優先，沒有就跟著資料夾的預設組（Project.groupID），都沒有就放「其他」。

struct ConvGroup: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var expanded = true
    var archiveOpen = false
    /// 上一層的組（組可以套組）；nil＝最上層。舊的存檔沒有這欄，讀進來就是最上層
    var parentID: UUID? = nil
}

extension Store {
    static let otherGroupName = "其他"

    func group(_ id: UUID?) -> ConvGroup? { id.flatMap { g in groups.first { $0.id == g } } }

    /// 這段對話實際歸在哪一組（沒有分組功能時回 nil）
    func groupOf(_ c: Conversation) -> UUID? {
        guard !groups.isEmpty else { return nil }
        if let g = c.groupID, group(g) != nil { return g }
        if let g = project(c.projectID)?.groupID, group(g) != nil { return g }
        return fallbackGroupID
    }

    /// 沒歸組的對話、資料夾放哪一組（「其他」；沒有就最後一組）
    var fallbackGroupID: UUID? { groups.first { $0.name == Store.otherGroupName }?.id ?? groups.last?.id }

    func conversations(inGroup g: UUID) -> [Conversation] {
        conversations.filter { groupOf($0) == g && !$0.isGadget }.sorted(by: orderedBefore)
    }

    func move(_ conv: UUID, toGroup g: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == conv }) else { return }
        // 跟資料夾預設的一樣就不用特別記
        conversations[i].groupID = project(conversations[i].projectID)?.groupID == g ? nil : g
        // 掛件框只框同一組的：移到別組就離開框
        if let b = conversations[i].bundle, bundleMembers(b).contains(where: { $0.id != conv && groupOf($0) != g }) { setBundle(conv, nil) }
    }

    /// 組對應的資料夾：預設放這組、又在 claude 選單清單（~/.claude/envs）裡的資料夾 → 跟組同名的資料夾（「文庫」組＝專案根資料夾底下的「文庫」）
    /// → 其他預設放這組的資料夾 → 上一層組的資料夾裡跟組同名的子資料夾（文庫 › 小生＝文庫資料夾底下的「小生」）→ 上一層組的資料夾
    func folder(ofGroup g: UUID, seen: Set<UUID> = []) -> String? {
        guard let x = group(g), !seen.contains(g) else { return nil }
        let defaults = projects.filter { $0.groupID == g }
        let envs = ClaudeEnvs.load()
        if let p = envs.first(where: { e in defaults.contains { $0.path == e } }) { return p }
        if let p = projects.first(where: { ($0.path as NSString).lastPathComponent == x.name }) { return p.path }
        if let p = defaults.first { return p.path }
        guard let parent = x.parentID, let up = folder(ofGroup: parent, seen: seen.union([g])) else { return nil }
        var d: ObjCBool = false
        let sub = (up as NSString).appendingPathComponent(x.name)
        return FileManager.default.fileExists(atPath: sub, isDirectory: &d) && d.boolValue ? sub : up
    }

    /// 群組右鍵「在這一組開新對話」：組沒有資料夾，挑一個——組對應的資料夾（folder(ofGroup:)）→ 這組最近打開的對話的資料夾 → 目前選的 → 第一個
    @discardableResult
    func newConversation(inGroup g: UUID) -> Conversation? {
        let recent = conversations(inGroup: g).filter { $0.draft != true }.max { $0.lastOpened < $1.lastOpened }
        let mapped = folder(ofGroup: g).map { path in projects.first(where: { $0.path == path })?.id ?? addProject(path: path).id }
        guard let pid = mapped ?? recent?.projectID
                ?? selectedProject.flatMap({ project($0)?.id }) ?? projects.first?.id else { return nil }
        let c = createConversation(in: pid)
        move(c.id, toGroup: g)
        // 組（和上面每一層）收著的話打開，才看得到新的那一列
        var cur: UUID? = g
        var seen = Set<UUID>()
        while let id = cur, !seen.contains(id), let i = groups.firstIndex(where: { $0.id == id }) {
            seen.insert(id)
            if !groups[i].expanded { groups[i].expanded = true }
            cur = groups[i].parentID
        }
        show(c.id)
        return c
    }

    /// 資料夾的新對話放在哪個最上層的組（新對話選單分段用）：資料夾的預設組往上找到最上層，沒設就「其他」
    func topGroup(ofPath path: String) -> UUID? {
        var cur = projects.first(where: { $0.path == path })?.groupID.flatMap { group($0)?.id } ?? fallbackGroupID
        var seen = Set<UUID>()
        while let c = cur, let p = group(c)?.parentID, group(p) != nil, !seen.contains(c) { seen.insert(c); cur = p }
        return cur
    }

    func setDefaultGroup(_ project: UUID, to g: UUID?) {
        guard let i = projects.firstIndex(where: { $0.id == project }) else { return }
        projects[i].groupID = g
    }

    // MARK: 組套組

    /// 最上層的組（上一層不存在的也算最上層，免得被藏起來）
    var topGroups: [ConvGroup] { groups.filter { $0.parentID == nil || group($0.parentID) == nil } }
    func childGroups(of g: UUID) -> [ConvGroup] { groups.filter { $0.parentID == g && $0.id != g } }

    /// a 是不是 b 本身或 b 底下（任何一層）的組
    func isGroup(_ a: UUID, within b: UUID) -> Bool {
        var cur: UUID? = a
        var seen = Set<UUID>()
        while let c = cur, !seen.contains(c) {
            if c == b { return true }
            seen.insert(c)
            cur = group(c)?.parentID
        }
        return false
    }

    /// 「學業 › 計概」：選單裡顯示完整路徑
    func groupPath(_ g: UUID) -> String {
        var names: [String] = []
        var cur: UUID? = g
        var seen = Set<UUID>()
        while let c = cur, let x = group(c), !seen.contains(c) { names.insert(x.name, at: 0); seen.insert(c); cur = x.parentID }
        return names.joined(separator: " › ")
    }

    /// 依樹狀順序列出所有組（選單用），depth＝第幾層
    func groupTree() -> [(group: ConvGroup, depth: Int)] {
        var out: [(ConvGroup, Int)] = []
        func walk(_ g: ConvGroup, _ d: Int) {
            guard !out.contains(where: { $0.0.id == g.id }) else { return }
            out.append((g, d))
            for c in childGroups(of: g.id) { walk(c, d + 1) }
        }
        for g in topGroups { walk(g, 0) }
        return out.map { (group: $0.0, depth: $0.1) }
    }

    /// 把 g 放到 parent 底下（nil＝最上層）。不能放進自己或自己底下的組
    func setGroupParent(_ g: UUID, to parent: UUID?) {
        if let parent, isGroup(parent, within: g) { return }
        guard let i = groups.firstIndex(where: { $0.id == g }) else { return }
        groups[i].parentID = parent
        if let parent, let pi = groups.firstIndex(where: { $0.id == parent }) { groups[pi].expanded = true }
    }

    /// 把組 g 排到 target 的前面／後面（跟 target 同一層：子組拖到最上層的組旁邊就變成最上層）
    func reorderGroup(_ g: UUID, before target: UUID) { placeGroup(g, near: target, after: false) }
    func reorderGroup(_ g: UUID, after target: UUID) { placeGroup(g, near: target, after: true) }
    private func placeGroup(_ g: UUID, near target: UUID, after: Bool) {
        guard g != target, !isGroup(target, within: g), let i = groups.firstIndex(where: { $0.id == g }) else { return }
        var moved = groups.remove(at: i)
        guard let t = groups.firstIndex(where: { $0.id == target }) else { groups.insert(moved, at: i); return }
        moved.parentID = groups[t].parentID
        groups.insert(moved, at: after ? t + 1 : t)
    }

    func toggleGroup(_ g: UUID) {
        if let i = groups.firstIndex(where: { $0.id == g }) { groups[i].expanded.toggle() }
    }

    /// 全部收起／全部展開（⌥ 點組名、分類右邊的按鈕、組的右鍵）
    func setAllGroups(expanded: Bool) {
        for i in groups.indices { groups[i].expanded = expanded }
    }
    var allGroupsCollapsed: Bool { !groups.isEmpty && groups.allSatisfy { !$0.expanded } }

    func toggleGroupArchive(_ g: UUID) {
        if let i = groups.firstIndex(where: { $0.id == g }) { groups[i].archiveOpen.toggle() }
    }

    @discardableResult
    func addGroup(named name: String, parent: UUID? = nil) -> ConvGroup {
        if let g = groups.first(where: { $0.name == name && $0.parentID == parent }) { return g }
        let g = ConvGroup(name: name, parentID: parent)
        groups.append(g)
        if let parent, let pi = groups.firstIndex(where: { $0.id == parent }) { groups[pi].expanded = true }
        return g
    }

    func renameGroup(_ g: UUID, to name: String) {
        let t = name.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty, let i = groups.firstIndex(where: { $0.id == g }) { groups[i].name = t }
    }

    func removeGroup(_ g: UUID) {
        // 底下的子組往上提一層（不跟著刪）
        let up = group(g)?.parentID
        for i in groups.indices where groups[i].parentID == g { groups[i].parentID = up }
        groups.removeAll { $0.id == g }
        // 這組的對話、資料夾回到上一層的組（最上層的組就回「其他」）
        for i in conversations.indices where conversations[i].groupID == g { conversations[i].groupID = up }
        for i in projects.indices where projects[i].groupID == g { projects[i].groupID = up }
    }

    // MARK: 分類檔：放在資料夾裡的 classification.json，啟動時套用一次（套完改名成 .applied）

    struct Classification: Decodable {
        var groups: [String]
        var projectGroup: [String: String]        // 資料夾路徑 → 組名
        var sessionGroup: [String: String]        // Claude 對話編號 → 組名
        var renames: [String: String]?           // Claude 對話編號 → 工作台裡的新標題
        var importSessions: [String]?            // 要匯入的 Claude 對話編號（還沒在工作台的）
    }

    func applyClassification(in dir: URL) {
        let url = dir.appendingPathComponent("classification.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let c: Classification
        do { c = try JSONDecoder().decode(Classification.self, from: try Data(contentsOf: url)) }
        catch { NSLog("AI 工作台：分類檔讀不了：%@", "\(error)"); return }
        for n in c.groups { addGroup(named: n) }
        if let ids = c.importSessions {
            let want = Set(ids.compactMap { UUID(uuidString: $0) })
            importSessions(ClaudeSessions.scan().filter { want.contains($0.id) })
        }
        let byName = Dictionary(groups.map { ($0.name, $0.id) }, uniquingKeysWith: { a, _ in a })
        for (path, name) in c.projectGroup {
            if let g = byName[name] {
                if !projects.contains(where: { $0.path == path }), FileManager.default.fileExists(atPath: path) { addProject(path: path) }
                if let i = projects.firstIndex(where: { $0.path == path }) { projects[i].groupID = g }
            }
        }
        for (sid, name) in c.sessionGroup {
            guard let g = byName[name], let u = UUID(uuidString: sid), let i = conversations.firstIndex(where: { $0.claudeSession == u }) else { continue }
            conversations[i].groupID = projects.first { $0.id == conversations[i].projectID }?.groupID == g ? nil : g
        }
        for (sid, title) in c.renames ?? [:] {
            guard let u = UUID(uuidString: sid), let i = conversations.firstIndex(where: { $0.claudeSession == u }) else { continue }
            conversations[i].title = title
            conversations[i].renamed = true
        }
        // 套用過就改名（加上時間，避免跟上次的撞名而改名失敗、每次啟動都重套一次）
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let done = dir.appendingPathComponent("classification-\(f.string(from: Date())).json.applied")
        do { try FileManager.default.moveItem(at: url, to: done) } catch { try? FileManager.default.removeItem(at: url) }
        saveNow()
    }
}
