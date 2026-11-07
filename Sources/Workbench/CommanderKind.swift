import Foundation

/// 兩種總指揮：single＝整個總指揮就是一個專案（例：一個獨立專案）；
/// multi＝底下的子群組各是一個子專案（例：一個專案分成幾個子專案）。沒明確選就依群組結構推斷
extension Store {
    /// 總指揮涵蓋的頂層組底下的第一層子組（＝multi 的子專案），照群組排列順序
    func subProjects(_ s: SessionLayout) -> [ConvGroup] {
        let roots = s.groups ?? []
        let kids = roots.flatMap { childGroups(of: $0) }   // 子組本身也列在涵蓋範圍裡的照樣算子專案
        var seen = Set<UUID>()
        // 子組已經歸別的總指揮管的（B 組底下的 A 組歸另一個總指揮）不算：放進去在這個總指揮底下看不到
        return kids.filter { commanderSessionID(forGroup: $0.id) == s.id && seen.insert($0.id).inserted }
    }

    func inferredKind(_ s: SessionLayout) -> String { subProjects(s).isEmpty ? "single" : "multi" }

    func commanderIsMulti(_ s: SessionLayout) -> Bool { (s.commanderKind ?? inferredKind(s)) == "multi" }

    /// 聊天室屬於哪個子專案：它的組往上走到「總指揮涵蓋的頂層組」底下第一層；在頂層組本身（例如總指揮聊天室）＝nil
    func subProject(of c: Conversation, in s: SessionLayout) -> ConvGroup? {
        let roots = Set(s.groups ?? [])
        var cur = groupOf(c)
        var seen = Set<UUID>()
        while let g = cur, !seen.contains(g), let grp = group(g) {
            seen.insert(g)
            if let p = grp.parentID, roots.contains(p) { return grp }
            cur = grp.parentID
        }
        return nil
    }

    /// 一次性：還沒選類型的總指揮，依這個分類套（範例專案＝多個子專案）。
    /// 不在名單的照推斷；用 appDefaults 記錄已做過，之後使用者自己改回「自動」也不會再被蓋掉
    func migrateCommanderKinds() {
        let key = "commanderKindsMigrated.1"
        guard !appDefaults.bool(forKey: key) else { return }
        let multi: Set<String> = ["範例專案"]
        let single: Set<String> = ["範例專案（單一）"]
        var any = false
        for i in sessions.indices where sessions[i].area == nil && sessions[i].groups != nil {
            any = true
            guard sessions[i].commanderKind == nil else { continue }
            if multi.contains(sessions[i].name) { sessions[i].commanderKind = "multi" }
            else if single.contains(sessions[i].name) { sessions[i].commanderKind = "single" }
        }
        if any { appDefaults.set(true, forKey: key) }
    }

    func setCommanderKind(_ session: UUID, _ kind: String?) {
        guard let i = sessions.firstIndex(where: { $0.id == session && $0.area == nil && $0.groups != nil }) else { return }
        sessions[i].commanderKind = kind
    }

    /// single 總指揮固定用的專案資料夾：總指揮聊天室的資料夾
    func commanderProjectPath(_ s: SessionLayout) -> (name: String, path: String)? {
        guard let ch = s.chief, let c = conversation(ch), let p = project(c.projectID) else { return nil }
        return (p.name, p.path)
    }
}
