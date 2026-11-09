import Foundation
import CryptoKit

/// 沙盒聊天室的看板讀寫（nono 收緊 11/8）。沙盒裡讀不到 AI 工作台資料夾，codenv-todo 改經 socket 要資料：
///   board_read  → {data: 整份 collab.json, rev: 檔案內容的 SHA-256}
///   board_write → {data: 改完的整份, rev: 讀到的那份的 rev}；rev 對不上（中間有人改過）回 conflict，呼叫端重讀重做
/// 寫入沿用 CollabBoard 的做法：同一個 .lock 的 flock、覆蓋前留 .bak、暫存檔＋改名。
/// 伺服器端驗證（沙盒裡的 Claude 不可信）：
///   1. 沙盒不可建立 autoApprove；其他未知最上層欄位也不能變
///   2. 新目標一律是 proposed、不能帶 autoApproved；既有目標不能從 proposed 變成 active（同意只有使用者在看板上按）
///   3. 新增或改過的步驟不能有 mode＝edit／run（那會讓沙盒外的 agy 不經詢問動手）
enum ScopedBoard {
    private static let allowedTop: Set<String> = ["items", "goals", "findings"]
    private static let maxBytes = 6_000_000

    private static func rev(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    private static func withLock<T>(_ body: () -> T) -> T? {
        let url = CollabBoardModel.todoFile
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = Darwin.open(url.path + ".lock", O_CREAT | O_RDWR, 0o600)
        guard fd >= 0, flock(fd, LOCK_EX) == 0 else { if fd >= 0 { close(fd) }; return nil }
        defer { flock(fd, LOCK_UN); close(fd) }
        return body()
    }

    static func read() -> [String: Any] {
        let url = CollabBoardModel.todoFile
        guard let r = withLock({ () -> [String: Any] in
            guard FileManager.default.fileExists(atPath: url.path) else { return ["ok": true, "data": [String: Any](), "rev": ""] }
            guard let d = try? Data(contentsOf: url), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
                return ["ok": false, "error": "collab.json 讀不了（空檔或格式壞了）"]
            }
            return ["ok": true, "data": o, "rev": rev(d)]
        }) else { return ["ok": false, "error": "看板檔的鎖拿不到"] }
        return r
    }

    static func write(data: Any?, rev given: String) -> [String: Any] {
        guard let new = data as? [String: Any] else { return ["ok": false, "error": "board_write 要帶整份 data（物件）"] }
        let url = CollabBoardModel.todoFile
        guard let r = withLock({ () -> [String: Any] in
            var old: [String: Any] = [:]
            var oldRev = ""
            if FileManager.default.fileExists(atPath: url.path) {
                guard let d = try? Data(contentsOf: url), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
                    return ["ok": false, "error": "collab.json 讀不了或格式壞了，沒有改任何東西"]
                }
                old = o; oldRev = rev(d)
            }
            if oldRev != given { return ["ok": false, "conflict": true, "error": "看板剛被別人改過，請重讀再改"] }
            for key in ["items", "goals", "findings"] where old[key] != nil && new[key] == nil {
                return ["ok": false, "error": "看板修改不能省略既有欄位「\(key)」"]
            }
            if let why = validate(old: old, new: new) { return ["ok": false, "error": "沙盒聊天室的看板修改被擋下：" + why] }
            guard let out = try? JSONSerialization.data(withJSONObject: new, options: [.prettyPrinted, .sortedKeys]), out.count <= maxBytes else {
                return ["ok": false, "error": "看板資料太大或無法編碼"]
            }
            if FileManager.default.fileExists(atPath: url.path) {
                let bak = URL(fileURLWithPath: url.path + ".bak")
                try? FileManager.default.removeItem(at: bak)
                try? FileManager.default.copyItem(at: url, to: bak)
            }
            let tmp = url.deletingLastPathComponent().appendingPathComponent(".collab.\(getpid()).scoped.tmp")
            guard FileManager.default.createFile(atPath: tmp.path, contents: out, attributes: [.posixPermissions: 0o600]), rename(tmp.path, url.path) == 0 else {
                try? FileManager.default.removeItem(at: tmp)
                return ["ok": false, "error": "看板檔寫不進去"]
            }
            return ["ok": true, "rev": rev(out)]
        }) else { return ["ok": false, "error": "看板檔的鎖拿不到"] }
        return r
    }

    /// 回傳原因＝拒絕
    static func validate(old: [String: Any], new: [String: Any]) -> String? {
        // autoApprove 不屬於沙盒可寫的欄位；既有值可原樣保留，但不能由沙盒建立。
        if old["autoApprove"] == nil && new["autoApprove"] != nil { return "不能改 autoApprove" }
        for key in Set(old.keys).union(new.keys) where !allowedTop.contains(key) {
            if !valuesEqual(old[key], new[key]) { return "不能改最上層欄位「\(key)」" }
        }
        let oldGoals = (old["goals"] as? [[String: Any]]) ?? []
        let newGoalsRaw = new["goals"] ?? []
        guard let newGoals = newGoalsRaw as? [[String: Any]] else { return "goals 格式不對" }
        var oldByID: [String: [String: Any]] = [:]
        for g in oldGoals { if let id = g["id"] as? String { oldByID[id] = g } }
        for g in newGoals {
            guard let id = g["id"] as? String else { return "目標缺 id" }
            let prev = oldByID[id]
            let status = g["status"] as? String
            if let prev {
                if status == "active", (prev["status"] as? String) != "active" { return "目標「\(id)」不能由沙盒同意（只有使用者在看板上按同意）" }
                if !valuesEqual(prev["autoApproved"], g["autoApproved"]) { return "不能改 autoApproved" }
            } else {
                if status != "proposed" { return "新目標只能是提議中（proposed）" }
                if g["autoApproved"] != nil { return "新目標不能帶 autoApproved" }
            }
            let oldSteps = ((prev?["steps"] as? [[String: Any]]) ?? [])
            var oldStepByID: [String: [String: Any]] = [:]
            for st in oldSteps { if let sid = st["id"] as? String { oldStepByID[sid] = st } }
            guard let steps = (g["steps"] ?? []) as? [[String: Any]] else { return "目標「\(id)」的 steps 格式不對" }
            for st in steps {
                let mode = st["mode"] as? String
                guard mode == "edit" || mode == "run" else { continue }
                if let sid = st["id"] as? String, let was = oldStepByID[sid], valuesEqual(was, st) { continue }   // 本來就有且沒動
                return "步驟不能設 mode＝\(mode!)（會讓沙盒外的 agy 不經詢問動手）"
            }
        }
        return nil
    }

    private static func valuesEqual(_ a: Any?, _ b: Any?) -> Bool {
        if a == nil && b == nil { return true }
        guard let a, let b else { return false }
        return (a as AnyObject).isEqual(b)
    }
}
