import Foundation

// 對話全文搜尋的 App 端：呼叫 ~/.local/bin/codenv-todo search --json（索引、分詞、遮金鑰都在那邊做，CLI 和右欄「歷史」共用同一份 search.sqlite）。
// 資料夾：索引放 <state>/search.sqlite；測試 App（有 --state-dir）用自己的 state，Claude 紀錄資料夾沒給 --claude-home 時指到一個不存在的資料夾，
// 絕不會替真的 ~/.claude 建索引。找不到指令或失敗就回 nil，呼叫端退回逐檔掃描。

enum SearchIndexClient {
    struct Hit { let conv: UUID; let chat: String; let role: String; let snippet: String }
    struct Result { let hits: [Hit]; let chats: Int }

    /// 平常用 codenv 出版時裝的 ~/.local/bin/codenv-todo；測試 App（有 --state-dir）可以用環境變數 CODENV_SEARCH_SCRIPT 指到還沒安裝的新版
    static var script: URL {
        if CommandLine.arguments.contains("--state-dir"), let o = ProcessInfo.processInfo.environment["CODENV_SEARCH_SCRIPT"] { return URL(fileURLWithPath: o) }
        return URL(fileURLWithPath: CLITools.path("codenv-todo") ?? Edition.home.appendingPathComponent(".local/bin/codenv-todo").path)
    }
    static var available: Bool { FileManager.default.isExecutableFile(atPath: script.path) && FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") }

    static func search(_ query: String, convs: [UUID], limit: Int, cancel: RPCancel) -> Result? {
        let a = CommandLine.arguments
        let testMode = a.contains("--state-dir")
        let state = Transcripts.dir.deletingLastPathComponent()
        var env = ProcessInfo.processInfo.environment
        env["CODENV_STATE_DIR"] = state.path
        env["CODENV_CLAUDE_HOME"] = testMode && !a.contains("--claude-home") ? state.appendingPathComponent("no-claude-home").path : ClaudeSessions.home.path
        env.removeValue(forKey: "CODENV_COLLAB_FILE")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [script.path, "search", query, "--json", "--limit", String(limit), "--conv", convs.map(\.uuidString).joined(separator: ",")]
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        var data = Data()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global().async { data = out.fileHandleForReading.readDataToEndOfFile(); reader.leave() }
        while p.isRunning {
            if cancel.isCancelled { p.terminate(); break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        p.waitUntilExit()
        reader.wait()
        guard !cancel.isCancelled, p.terminationStatus == 0,
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = o["hits"] as? [[String: Any]] else { return nil }
        let hits = raw.compactMap { h -> Hit? in
            guard let c = (h["conv"] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
            return Hit(conv: c, chat: h["chat"] as? String ?? "", role: h["role"] as? String ?? "", snippet: h["snippet"] as? String ?? "")
        }
        return Result(hits: hits, chats: o["chats"] as? Int ?? 0)
    }
}
