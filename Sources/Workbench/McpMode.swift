import Foundation

/// 每個聊天室啟動 claude 時要載入哪些 MCP（外部工具伺服器）。
/// stdio 的 MCP 是每個 claude 程序各自開一份（chrome-devtools 一套就是 npm＋node＋mcp 三個程序，每個聊天室兩套），
/// 分支聊天室多半用不到，精簡掉可省下每個聊天室約 300 MB。
/// 只改 codenv 啟動 claude 的參數；不碰 ~/.claude/settings.json 和 ~/.claude.json。
/// Claude Code 2.1.318 實測：`--strict-mcp-config` 會一併關掉外掛（plugin）、claude.ai 連接器和使用者設定的 MCP，
/// 只留 `--mcp-config` 給的；它擋不掉 `--chrome`（claude-in-chrome），所以精簡／不載入時 codenv 也不帶 `--chrome`。
enum McpMode: String, CaseIterable {
    /// 照使用者的設定全載（總指揮聊天室、手開的聊天室的預設）
    case full
    /// 只留 deja（過去對話查詢），其餘不載（`codenv-todo new` 開的分支聊天室預設）
    case lite
    /// 一個都不載
    case none

    /// 精簡模式保留的 MCP 名字（從使用者的 ~/.claude.json 原樣取設定，沒有就等於 none）
    static let liteKeep = ["deja"]

    /// 測試用：換掉讀 MCP 設定的檔案（正式為 ~/.claude.json）
    static var userConfigPath: String = (NSHomeDirectory() as NSString).appendingPathComponent(".claude.json")

    var label: String {
        switch self {
        case .full: return L("完整（全部 MCP）")
        case .lite: return L("精簡（只留 deja）")
        case .none: return L("不載入 MCP")
        }
    }

    /// 存檔裡的值 → 模式；nil、空字串、不認得的都當完整
    static func from(_ raw: String?) -> McpMode { raw.flatMap(McpMode.init(rawValue:)) ?? .full }

    /// 命令列或選單的字 → 模式；不認得的回錯誤訊息
    static func normalize(_ raw: String?) -> (value: McpMode?, error: String?) {
        guard let r = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !r.isEmpty else { return (nil, nil) }
        if let m = McpMode(rawValue: r) { return (m, nil) }
        return (nil, "--mcp 只接受 full、lite、none")
    }

    /// 要加在 claude 命令列的參數（full 不加任何東西）
    var arguments: [String] {
        guard self != .full else { return [] }
        var servers: [String: Any] = [:]
        if self == .lite,
           let data = FileManager.default.contents(atPath: Self.userConfigPath),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let all = root["mcpServers"] as? [String: Any] {
            for k in Self.liteKeep { if let v = all[k] { servers[k] = v } }
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["mcpServers": servers], options: [.sortedKeys])) ?? Data("{\"mcpServers\":{}}".utf8)
        // 設定裡可能有 env（金鑰之類）：放在命令列參數會出現在 ps 裡，所以寫進 state 資料夾裡權限 0600 的檔案再傳路徑。
        // 沒有任何伺服器時才直接用 inline（沒有祕密可洩）
        if servers.isEmpty { return ["--strict-mcp-config", "--mcp-config", String(decoding: data, as: UTF8.self)] }
        let dir = Transcripts.dir.deletingLastPathComponent().appendingPathComponent("mcp", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent("mcp-\(rawValue).json")
        FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])   // 先建好 0600 再寫，內容不會短暫開放
        if let h = try? FileHandle(forWritingTo: file) {
            try? h.truncate(atOffset: 0); h.write(data); try? h.close()
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return ["--strict-mcp-config", "--mcp-config", file.path]
        }
        return ["--strict-mcp-config", "--mcp-config", String(decoding: data, as: UTF8.self)]   // 寫不出檔案才退回（不讓聊天室少一個 MCP）
    }

    /// 精簡／不載入時不帶 --chrome（它是另一條路進來的 MCP，strict 擋不掉）
    var allowsChrome: Bool { self == .full }
}
