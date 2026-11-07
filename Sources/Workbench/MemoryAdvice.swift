import Foundation

/// 記憶整理的「只提示」功能（Hermes 研究報告 #1、#2、#3）。
/// 絕不碰記憶檔：容量檢查是唯讀的 scripts/memory-check，交接時產生的提議只進協作看板「提議中」，使用者同意後才會有人去寫。
enum MemoryAdvice {
    static let boardBy = "記憶提議"
    private static let testing = CommandLine.arguments.contains("--state-dir")

    private static func testArg(_ name: String) -> String? {
        guard testing, let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[i + 1]
    }

    /// 找 memory-check：正式用 ~/.local/bin（release.sh 裝）；測試實例用 --memory-check-bin 指定
    private static var checkTool: String? {
        if testing { return testArg("--memory-check-bin") }
        return CLITools.path("memory-check")
    }

    /// 跑一次容量檢查（背景執行緒，不花任何額度）；超過上限才在看板開一張「提議中」提醒，沒超過什麼都不做
    static func checkCapacity() {
        guard let tool = checkTool else { EventLog.log("記憶整理", "找不到 memory-check，略過容量檢查"); return }
        var args = ["--json"]
        if let root = testArg("--memory-root") { args += ["--root", root] }
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return EventLog.log("記憶整理", "memory-check 開不起來：\(error.localizedDescription)") }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return EventLog.log("記憶整理", "memory-check 沒有輸出可讀的結果（結束碼 \(p.terminationStatus)）")
            }
            guard o["over"] as? Bool == true else { return EventLog.log("記憶整理", "容量檢查：正常") }
            let summary = summarize(o["results"] as? [[String: Any]] ?? [])
            DispatchQueue.main.async {
                EventLog.log("記憶整理", "容量超過上限，開看板提議")
                CollabBoardModel.shared.addMemoryProposal(
                    title: "記憶檔太大，該整理了",
                    done: "只是提示，沒有改任何記憶檔。挑要整併／歸檔的，同意後再請 Claude 做（舊的移到 archive/，不刪）。\n" + summary,
                    step: "讀建議，決定要整理哪幾個", by: boardBy, limit: 10)
            }
        }
    }

    private static func summarize(_ results: [[String: Any]]) -> String {
        var lines: [String] = []
        func kb(_ n: Double) -> String { String(format: "%.1f KB", n / 1024) }
        for r in results {
            let folder = ((r["folder"] as? String).map { URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent }) ?? "?"
            if let idx = r["index"] as? [String: Any], idx["over"] as? Bool == true {
                lines.append("・\(folder) 的索引 MEMORY.md 太長：\(kb((idx["bytes"] as? Double) ?? 0))、\((idx["lines"] as? Int) ?? 0) 行")
            }
            for f in (r["oversized"] as? [[String: Any]] ?? []).prefix(5) {
                lines.append("・\(folder)/\((f["file"] as? String) ?? "?")：\(kb((f["bytes"] as? Double) ?? 0))（建議把舊的移到 archive/）")
            }
        }
        let text = lines.prefix(12).joined(separator: "\n")
        return text.count > 900 ? String(text.prefix(900)) + "…" : text + "\n詳細：memory-check（指令）"
    }

    /// 交接時模型提議的記憶：只進看板「提議中」。標題短、原話放完成條件，使用者同意前不會有人寫進記憶
    static func submit(_ proposals: [Handoff.MemoryProposal], from conversationTitle: String) {
        guard !proposals.isEmpty else { return EventLog.log("記憶整理", "交接：\(conversationTitle) 沒有新的記憶提議") }
        for p in proposals {
            var done = "要記的內容：\(p.content)"
            if !p.source.isEmpty { done += "\n／出處：\(p.source)" }
            done += "\n來源聊天室：\(conversationTitle)（交接時由模型提議，沒有人驗證過；同意後才寫進記憶檔，不同意就刪掉）"
            DispatchQueue.main.async {
                CollabBoardModel.shared.addMemoryProposal(
                    title: "記憶：" + p.title, done: done,
                    step: "讀過內容，同意就請 Claude 寫進記憶", by: boardBy, limit: 10)
            }
        }
        EventLog.log("記憶整理", "交接：\(conversationTitle) 提議 \(proposals.count) 條記憶，已放看板待審")
    }
}
