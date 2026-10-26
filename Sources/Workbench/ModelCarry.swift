import Foundation

// 換模型交接：換到另一家（Claude ↔ Gemini／Codex／Copilot／本機／Apple，紀錄檔不同）時，
// 把前一段的紀錄整理成精簡文字——只留使用者和 AI 說的話，工具輸出、思考、codenv 自己附的那幾行都拿掉。
// 最近的一段直接附在下一則訊息裡（新模型不用先讀檔就接得上），全文存成一個檔，需要時再讀。
// 同一家換模型（Opus ↔ Sonnet）紀錄是同一份，不會走到這裡。

enum ModelCarry {
    /// 全文放哪：Application Support/AI 工作台/carry（不放專案資料夾，免得弄髒使用者的 repo）；測試 App 放 --state-dir 裡
    static let dir: URL = {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--state-dir"), i + 1 < a.count {
            return URL(fileURLWithPath: a[i + 1]).appendingPathComponent("carry")
        }
        return Edition.support("carry")
    }()

    /// 訊息裡附的那段開頭（chat.js 從這裡一路藏到最後，泡泡只顯示使用者打的字）
    static let marker = "〔codenv 換模型〕"
    /// 程式碼區開著時，訊息後面附的那行開頭（CodeLab.contextLine；藏泡泡、交接、md 紀錄都靠它）
    static let codeLabMarker = "〔codenv 程式碼區〕"

    /// 紀錄檔 → 一則一則（誰、說了什麼）
    static func turns(_ url: URL) -> [(user: Bool, text: String)] {
        guard let data = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [(Bool, String)] = []
        for line in data.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = o["type"] as? String, type == "user" || type == "assistant",
                  o["isMeta"] as? Bool != true, o["isReplay"] as? Bool != true,
                  o["isCompactSummary"] as? Bool != true,   // 自動壓縮的摘要不是使用者說的話（前面的原文都還在紀錄裡）
                  let msg = o["message"] as? [String: Any] else { continue }
            var parts: [String] = []
            if let s = msg["content"] as? String { parts = [s] }
            else if let blocks = msg["content"] as? [[String: Any]] {
                parts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                if type == "user", blocks.contains(where: { $0["type"] as? String == "image" }) { parts.append(L("（附了一張圖）")) }
            }
            var text = parts.joined(separator: "\n")
            if type == "user" {
                if text.hasPrefix("<local-command") || text.hasPrefix("<command-") { continue }
                // codenv 自己附的：程式碼區的位置、上一次的交接
                for m in ["\n\n" + marker, "\n\n" + codeLabMarker] { if let r = text.range(of: m) { text = String(text[..<r.lowerBound]) } }
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            // 同一個人連著幾則（AI 叫工具前後各說一點）併成一則
            if let last = out.last, last.0 == (type == "user") { out[out.count - 1].1 += "\n" + text } else { out.append((type == "user", text)) }
        }
        return out
    }

    /// 前一個模型讀過／改過的檔案（工具的內容不交接，至少告訴新模型有哪些檔、要用自己再讀）：照最後一次碰的順序，同一個檔只列一次。
    /// 各家翻譯層都把工具記成 Claude 的 tool_use（Read／Edit／Write…，路徑在 file_path；少數用 path／notebook_path）
    static func files(_ url: URL, max: Int = 40) -> [(path: String, edited: Bool)] {
        guard let data = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var order: [String] = [], edited: Set<String> = []
        for line in data.split(separator: "\n") where line.contains("\"tool_use\"") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let blocks = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            for b in blocks where b["type"] as? String == "tool_use" {
                let name = (b["name"] as? String ?? "").lowercased()
                let input = b["input"] as? [String: Any] ?? [:]
                let fileTool = name.contains("read") || name.contains("edit") || name.contains("write")
                guard let p = (input["file_path"] ?? input["notebook_path"] ?? (fileTool ? input["path"] : nil)) as? String, !p.isEmpty else { continue }
                order.removeAll { $0 == p }; order.append(p)
                if name.contains("edit") || name.contains("write") { edited.insert(p) }
            }
        }
        return order.suffix(max).map { ($0, edited.contains($0)) }
    }

    static func renderFiles(_ fs: [(path: String, edited: Bool)]) -> String {
        fs.map { "- \($0.path)（\($0.edited ? "改過" : "讀過")）" }.joined(separator: "\n")
    }

    /// 不是 Claude 的紀錄：看放在哪個資料夾（AI 工作台/agy、codex…）
    static func family(_ url: URL) -> String {
        ["agy": "Gemini", "codex": "Codex", "copilot": "Copilot", "local": "本機模型", "apple": "Apple 模型"][url.deletingLastPathComponent().lastPathComponent] ?? "前一個模型"
    }

    static func render(_ turns: [(user: Bool, text: String)], model: String) -> String {
        turns.map { ($0.user ? "【使用者】" : "【\(model)】") + "\n" + $0.text }.joined(separator: "\n\n")
    }

    /// 交接那段（附在訊息後面）：最近的對話（最多 limit 個字）＋全文檔的位置；前面沒聊過什麼就 nil。
    /// canRead＝新模型有讀檔工具（Apple 模型沒有，就不提檔案）
    static func note(from url: URL, session: UUID, model: String? = nil, limit: Int, canRead: Bool) -> String? {
        let all = turns(url)
        guard !all.isEmpty else { return nil }
        let name = model.flatMap { $0.isEmpty ? nil : $0 } ?? ChatSession.claudeModelName(url) ?? family(url)
        let full = render(all, model: name)
        // 讀過／改過的檔（Apple 模型讀不了檔，列了也沒用）
        let fs = canRead ? files(url) : []
        var file: URL?
        if canRead {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let f = dir.appendingPathComponent(session.uuidString.lowercased() + ".md")
            var doc = "# 換模型前的對話（\(name)，精簡版：只留雙方說的話）\n\n" + full + "\n"
            if !fs.isEmpty { doc += "\n# \(name) 讀過／改過的檔案（最近的在最後）\n\n" + renderFiles(fs) + "\n" }
            if (try? doc.write(to: f, atomically: true, encoding: .utf8)) != nil { file = f }
        }
        // 從最後一則往前收，收到 limit 為止；太長的單則從後面留
        var recent: [String] = []
        var used = 0
        for t in all.reversed() {
            var s = (t.user ? "【使用者】" : "【\(name)】") + "\n" + t.text
            if used + s.count > limit {
                let room = limit - used
                if room > 200 { s = "…" + String(s.suffix(room)); recent.insert(s, at: 0) }
                break
            }
            recent.insert(s, at: 0); used += s.count
        }
        var note = "\n\n" + marker + "這個聊天室前面是用「\(name)」聊的，那段對話不在你的紀錄裡。下面是交接：最近的對話（精簡版，工具輸出已拿掉）"
        note += recent.count < all.count ? "，更早的省略了" : ""
        note += "。\n<<<\n" + recent.joined(separator: "\n\n") + "\n>>>"
        if !fs.isEmpty {
            note += "\n「\(name)」讀過／改過這些檔案（最近的在最後；當時看到的內容沒有交接，要用就自己再讀，內容可能已經變了）：\n" + renderFiles(fs)
        }
        if let file { note += "\n完整的精簡紀錄在 \(file.path)，需要更早的內容時再讀。" }
        note += "\n接著回答我上面這則訊息。"
        return note
    }
}
