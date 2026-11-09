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

    /// 同步（主執行緒）交接只讀紀錄檔的最後這麼多位元組：最大的紀錄檔有三百多 MB，整份讀進來逐行解析會卡住送出。
    /// 更早的部分由背景補進全文檔（note 裡的 fullInBackground）
    static let tailBytes = 8 * 1024 * 1024
    private static let fullDocQueue = DispatchQueue(label: "codenv.carry.fulldoc", qos: .utility)

    /// 讀紀錄檔的文字：tail 有給且檔案更大時只讀最後 tail 位元組，並丟掉被切在中間的第一行殘片。
    /// 回傳 (內容, 是否被截短)；讀不到 nil
    static func readLines(_ url: URL, tail: Int?) -> (text: String, truncated: Bool)? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd() else { return nil }
        var start: UInt64 = 0
        if let tail, size > UInt64(tail) { start = size - UInt64(tail) }
        do { try h.seek(toOffset: start) } catch { return nil }
        guard let data = try? h.readToEnd() else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if start > 0 {
            // 切在行中間：第一個換行之前是殘片（也可能切在多位元組字元中間），整段丟掉
            guard let nl = text.firstIndex(of: "\n") else { return ("", true) }
            text = String(text[text.index(after: nl)...])
        }
        return (text, start > 0)
    }

    /// 紀錄檔 → 一則一則（誰、說了什麼）。tail 有給時只看檔尾（主執行緒用）
    static func turns(_ url: URL, tail: Int? = nil) -> [(user: Bool, text: String)] {
        guard let data = readLines(url, tail: tail)?.text else { return [] }
        return turns(text: data)
    }

    static func turns(text data: String) -> [(user: Bool, text: String)] {
        var out: [(Bool, String)] = []
        for line in data.split(separator: "\n") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = o["type"] as? String, type == "user" || type == "assistant",
                  o["isMeta"] as? Bool != true, o["isReplay"] as? Bool != true,
                  o["isCompactSummary"] as? Bool != true,   // 自動壓縮的摘要不是的話（前面的原文都還在紀錄裡）
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
                for m in ["\n\n" + marker, "\n\n" + codeLabMarker, "\n\n" + ChatSession.nameMarker, "\n\n" + QuoteText.marker] { if let r = text.range(of: m) { text = String(text[..<r.lowerBound]) } }
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
    static func files(_ url: URL, max: Int = 40, tail: Int? = nil) -> [(path: String, edited: Bool)] {
        guard let data = readLines(url, tail: tail)?.text else { return [] }
        return files(text: data, max: max)
    }

    static func files(text data: String, max: Int = 40) -> [(path: String, edited: Bool)] {
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

    private static let genLock = NSLock()
    nonisolated(unsafe) private static var generations: [UUID: Int] = [:]
    /// 換代和同步寫檔在同一把鎖裡：背景那邊「比對代數＋寫檔」也在這把鎖，所以不會有舊一代的內容在新一代寫完之後才落地
    private static func bumpAndWrite(_ s: UUID, name: String, turns: [(user: Bool, text: String)], files: [(path: String, edited: Bool)], to f: URL, partial: Bool) -> (Int, Bool) {
        genLock.lock(); defer { genLock.unlock() }
        let g = (generations[s] ?? 0) + 1; generations[s] = g
        return (g, writeDoc(name: name, turns: turns, files: files, to: f, partial: partial))
    }
    private static func isLatestGeneration(_ s: UUID, _ g: Int) -> Bool { genLock.lock(); defer { genLock.unlock() }; return generations[s] == g }
    /// 比對代數和寫檔在同一把鎖裡：比對完到寫完之間，新的交接進不來
    private static func writeDocIfLatest(_ s: UUID, _ g: Int, name: String, turns: [(user: Bool, text: String)], files: [(path: String, edited: Bool)], to f: URL) {
        let doc = renderDoc(name: name, turns: turns, files: files, partial: false)
        genLock.lock(); defer { genLock.unlock() }
        guard generations[s] == g else { return }
        _ = writeRenderedDoc(doc, to: f)
    }

    /// 全文檔（atomically：讀的人只會看到舊版或新版）。partial＝只有檔尾那一段，背景補完整前先這樣
    static func writeDoc(name: String, turns: [(user: Bool, text: String)], files: [(path: String, edited: Bool)], to f: URL, partial: Bool) -> Bool {
        writeRenderedDoc(renderDoc(name: name, turns: turns, files: files, partial: partial), to: f)
    }

    private static func renderDoc(name: String, turns: [(user: Bool, text: String)], files: [(path: String, edited: Bool)], partial: Bool) -> String {
        var doc = "# 換模型前的對話（\(name)，精簡版：只留雙方說的話）\n\n"
        if partial { doc += "（這是先寫的檔尾版，只有最近的一段；完整版幾秒內會蓋過這個檔，更早的內容晚點再讀一次。）\n\n" }
        doc += render(turns, model: name) + "\n"
        if !files.isEmpty { doc += "\n# \(name) 讀過／改過的檔案（最近的在最後）\n\n" + renderFiles(files) + "\n" }
        return doc
    }

    private static func writeRenderedDoc(_ doc: String, to f: URL) -> Bool {
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? doc.write(to: f, atomically: true, encoding: .utf8)) != nil
    }

    /// 不是 Claude 的紀錄：看放在哪個資料夾（AI 工作台/agy、codex…）
    static func family(_ url: URL) -> String {
        ["agy": "Gemini", "codex": "Codex", "copilot": "Copilot", "local": "本機模型", "apple": "Apple 模型"][url.deletingLastPathComponent().lastPathComponent] ?? "前一個模型"
    }

    static func render(_ turns: [(user: Bool, text: String)], model: String) -> String {
        turns.map { ($0.user ? "【使用者】" : "【\(model)】") + "\n" + KeyScan.redact($0.text, strongOnly: true) }.joined(separator: "\n\n")
    }

    /// 交接那段（附在訊息後面）：最近的對話（最多 limit 個字）＋全文檔的位置；前面沒聊過什麼就 nil。
    /// canRead＝新模型有讀檔工具（Apple 模型沒有，就不提檔案）
    static func note(from url: URL, session: UUID, model: String? = nil, limit: Int, canRead: Bool) -> String? {
        // 主執行緒：只讀檔尾（大檔不卡）。窗內解不出任何對話（最後一行超過窗、或只有工具往返）就放大再試，到整份為止
        var all: [(user: Bool, text: String)] = []
        var fs: [(path: String, edited: Bool)] = []
        var truncated = false
        for window in [tailBytes, tailBytes * 4, tailBytes * 16, nil] as [Int?] {
            guard let r = readLines(url, tail: window) else { return nil }
            truncated = r.truncated
            all = turns(text: r.text)
            if !all.isEmpty || !r.truncated {
                // 讀過／改過的檔（Apple 模型讀不了檔，列了也沒用）；跟對話同一份文字，不再讀第二次
                if canRead { fs = files(text: r.text) }
                break
            }
        }
        guard !all.isEmpty else { return nil }
        let name = model.flatMap { $0.isEmpty ? nil : $0 } ?? ChatSession.claudeModelName(url) ?? family(url)
        var file: URL?
        if canRead {
            let f = dir.appendingPathComponent(session.uuidString.lowercased() + ".md")
            // 每次交接（同步寫）都換一代：背景補全文的工作寫之前要確認自己還是最新一代，不然會把較新的內容蓋回舊的
            let (gen, wrote) = bumpAndWrite(session, name: name, turns: all, files: fs, to: f, partial: truncated)
            if wrote { file = f }
            if truncated {
                let d = dir
                fullDocQueue.async {      // 序列佇列：同一個聊天室連換好幾次模型時，一件一件跑
                    guard isLatestGeneration(session, gen) else { return }      // 已經有更新的交接了：不用白解析整份
                    let allTurns = turns(url), allFiles = files(url)
                    guard !allTurns.isEmpty else { return }
                    writeDocIfLatest(session, gen, name: name, turns: allTurns, files: allFiles, to: d.appendingPathComponent(session.uuidString.lowercased() + ".md"))
                }
            }
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
