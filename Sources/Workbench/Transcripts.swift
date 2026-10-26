import Foundation

// 非 Claude 聊天室（本機／Gemini／Codex／Copilot／Apple）的好讀紀錄：AI 工作台/transcripts/<聊天室名稱>.md
// 起因（10/25）：Claude 聊天室要檢查 Qwen 講的對不對，可是 Qwen 的紀錄是 uuid 檔名的 jsonl、沒有時間。
// 每回答完一則（狀態回到閒著）就從 jsonl 重寫一份 md：每則「時間｜誰」＋內容，工具輸出拿掉、工具呼叫只留一行（讀了 X），
// codenv 自己附的那幾段（換模型交接、程式碼區位置）藏掉。聊天室改名時檔名跟著改；同名的兩段用短 id 分開。

enum Transcripts {
    /// 測試 App 放 --state-dir 裡，不碰平常的
    static let dir: URL = {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--state-dir"), i + 1 < a.count { return URL(fileURLWithPath: a[i + 1]).appendingPathComponent("transcripts") }
        return Edition.support("transcripts")
    }()
    /// 聊天室 → 目前用的檔名（改名時找得到舊檔）
    private static var indexURL: URL { dir.appendingPathComponent(".index.json") }
    private static let queue = DispatchQueue(label: "transcripts")

    private static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    /// 紀錄每筆的 timestamp（跟 Claude 紀錄一樣的 ISO 8601）
    static func stamp() -> String { iso.string(from: Date()) }

    struct Turn { let time: Date?; let user: Bool; var text: String; let model: String }

    /// 一份 jsonl → 一則一則（同一邊連著的併起來）
    static func turns(_ url: URL, model: String) -> [Turn] {
        guard let data = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let plain = ISO8601DateFormatter()
        var out: [Turn] = []
        for line in data.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = o["type"] as? String, type == "user" || type == "assistant",
                  o["isMeta"] as? Bool != true, o["isReplay"] as? Bool != true,
                  let msg = o["message"] as? [String: Any] else { continue }
            let time = (o["timestamp"] as? String).flatMap { iso.date(from: $0) ?? plain.date(from: $0) }
            // 自動壓縮的摘要（LocalCompact）：自己一則、標明是摘要，不算使用者說的話
            if o["isCompactSummary"] as? Bool == true {
                let s = (msg["content"] as? String ?? "").replacingOccurrences(of: LocalCompact.marker, with: "")
                out.append(Turn(time: time, user: false, text: s.trimmingCharacters(in: .whitespacesAndNewlines), model: "（自動壓縮摘要）"))
                continue
            }
            var parts: [String] = []
            if let s = msg["content"] as? String { parts = [s] }
            else if let blocks = msg["content"] as? [[String: Any]] {
                for b in blocks {
                    switch b["type"] as? String {
                    case "text": if let t = b["text"] as? String { parts.append(t) }
                    case "image": parts.append("（附了一張圖）")
                    case "tool_use": parts.append(toolLine(b["name"] as? String ?? "", b["input"] as? [String: Any] ?? [:]))
                    default: break   // tool_result、thinking：拿掉
                    }
                }
            }
            var text = parts.joined(separator: "\n")
            if type == "user" {
                if text.hasPrefix("<local-command") || text.hasPrefix("<command-") { continue }
                for m in ["\n\n" + ModelCarry.marker, "\n\n" + ModelCarry.codeLabMarker] { if let r = text.range(of: m) { text = String(text[..<r.lowerBound]) } }
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let user = type == "user"
            if let last = out.last, last.user == user, last.model == model { out[out.count - 1].text += "\n" + text }
            else { out.append(Turn(time: time, user: user, text: text, model: model)) }
        }
        return out
    }

    /// 工具呼叫只留一行
    private static func toolLine(_ name: String, _ input: [String: Any]) -> String {
        let path = (input["file_path"] ?? input["path"] ?? input["notebook_path"]) as? String
        let short = { (s: String) in s.count > 80 ? String(s.prefix(80)) + "…" : s }
        switch name {
        case "Read": return "（讀了 \(path ?? "檔案")）"
        case "Write", "Edit", "MultiEdit", "NotebookEdit": return "（改了 \(path ?? "檔案")）"
        case "Bash": return "（執行 \(short((input["command"] as? String ?? "").replacingOccurrences(of: "\n", with: " ")))）"
        case "Grep", "Glob": return "（搜尋 \(short(input["pattern"] as? String ?? ""))）"
        case "WebFetch", "WebSearch": return "（查網路 \(short((input["url"] ?? input["query"]) as? String ?? ""))）"
        default: return "（用了 \(name)）"
        }
    }

    /// 紀錄放在哪個資料夾 → 哪一家（測試 App 的資料夾叫 codenv-test-agy 之類）
    static func family(_ url: URL) -> String {
        var folder = url.deletingLastPathComponent().lastPathComponent
        if folder.hasPrefix("codenv-test-") { folder = String(folder.dropFirst(12)) }
        return ["agy": "Gemini", "codex": "Codex", "copilot": "Copilot", "local": "本機模型", "apple": "Apple 模型"][folder] ?? "前一個模型"
    }

    /// 檔名：聊天室名稱去掉不合法字元；跟別的聊天室同名就加短 id
    static func fileName(title: String, id: UUID, taken: Set<String>) -> String {
        var base = String(title.map { "/:\\\0".contains($0) ? "_" : $0 }).trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasPrefix(".") { base = "_" + base.dropFirst() }
        if base.isEmpty { base = "聊天室" }
        base = String(base.prefix(80))
        let name = base + ".md"
        return taken.contains(name) ? base + "-" + id.uuidString.prefix(6).lowercased() + ".md" : name
    }

    private static func loadIndex() -> [String: String] {
        (try? Data(contentsOf: indexURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
    }
    private static func saveIndex(_ idx: [String: String]) {
        if let d = try? JSONSerialization.data(withJSONObject: idx, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: indexURL, options: .atomic) }
    }

    /// 這個聊天室該用的檔名（已經有就沿用，名稱變了才換）；同時把舊檔改名過去
    private static func placeFile(id: UUID, title: String, idx: inout [String: String]) -> URL {
        let key = id.uuidString
        let others = Set(idx.filter { $0.key != key }.map(\.value))
        let old = idx[key]
        // 舊檔名還符合現在的名稱（含加了短 id 的版本）就不動
        let plain = fileName(title: title, id: id, taken: [])
        let withID = fileName(title: title, id: id, taken: [plain])
        if let old, old == plain || old == withID, !others.contains(old) { return dir.appendingPathComponent(old) }
        let name = fileName(title: title, id: id, taken: others.union(existingNames(except: old)))
        let url = dir.appendingPathComponent(name)
        if let old, old != name {
            let from = dir.appendingPathComponent(old)
            if FileManager.default.fileExists(atPath: from.path), !FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.moveItem(at: from, to: url) }
        }
        idx[key] = name
        return url
    }

    /// 資料夾裡現有的檔名（不是 index 記的、別人放的也算，免得蓋掉）
    private static func existingNames(except: String?) -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".md") && $0 != except })
    }

    /// 重寫一段聊天室的 md。files：這段對話用過的非 Claude 紀錄（目前這家排第一）＋各自的模型名稱
    static func update(id: UUID, title: String, files: [(url: URL, model: String)], done: ((URL?) -> Void)? = nil) {
        queue.async {
            let all = files.flatMap { turns($0.url, model: $0.model) }
            guard !all.isEmpty else { DispatchQueue.main.async { done?(nil) }; return }
            // 照時間排；沒時間的（加時間戳之前的舊紀錄）排最前面，順序不變
            let sorted = all.enumerated().sorted { a, b in
                switch (a.element.time, b.element.time) {
                case let (x?, y?): return x == y ? a.offset < b.offset : x < y
                case (nil, _?): return true
                case (_?, nil): return false
                default: return a.offset < b.offset
                }
            }.map(\.element)
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"
            var md = "# \(title)\n\n"
            md += "codenv 的聊天室紀錄（精簡版：只留雙方說的話，工具輸出拿掉，工具呼叫只留一行）。原始紀錄：\n"
            md += files.map { "- \($0.model)：\($0.url.path)" }.joined(separator: "\n") + "\n\n"
            for t in sorted {
                md += "## \(t.time.map(df.string) ?? "（較早）")｜\(t.user ? "使用者" : t.model)\n\n\(t.text)\n\n"
            }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var idx = loadIndex()
            let url = placeFile(id: id, title: title, idx: &idx)
            try? md.write(to: url, atomically: true, encoding: .utf8)
            saveIndex(idx)
            DispatchQueue.main.async { done?(url) }
        }
    }

    /// 聊天室改名：已經有 md 的跟著改檔名（內容等下一則回答再更新）
    static func renamed(_ titles: [UUID: String]) {
        queue.async {
            var idx = loadIndex()
            guard !idx.isEmpty else { return }
            var changed = false
            for (key, name) in idx {
                guard let id = UUID(uuidString: key), let title = titles[id] else { continue }
                if placeFile(id: id, title: title, idx: &idx).lastPathComponent != name { changed = true }
            }
            if changed { saveIndex(idx) }
        }
    }

    /// 測試用：等前面排隊的寫完
    static func flush(_ done: @escaping () -> Void) { queue.async { DispatchQueue.main.async(execute: done) } }
}
