import AppKit
import UniformTypeIdentifiers

// 把檔案、圖片拖進終端機：跟 iTerm 一樣貼上路徑（特殊字元加跳脫），Claude 看到圖片路徑就會當成附圖。
// 接三種：檔案網址（Finder、ShotLine）、承諾式檔案（照片 App 之類，放開後才寫出檔案）、純圖片資料（先存成暫存檔）。
extension TerminalPane {
    static let dropTypes: [NSPasteboard.PasteboardType] =
        [.fileURL, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    /// 拖進來的圖片存在這裡（App 每次啟動清一次）
    static let dropFolder: URL = {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("AI 工作台拖放", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        // 1. 一般檔案
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            // 圖片先複製一份到自己的暫存資料夾再貼路徑：ShotLine 之類的 App 拖出去之後會把原檔搬走，送出時路徑就失效了
            pastePaths(urls.map { u in ChatTextView.isImage(u) ? (Self.keepCopy(u) ?? u) : u })
            return true
        }
        // 2. 承諾式檔案：等對方寫完再貼
        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !promises.isEmpty {
            let dest = Self.dropFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            var got: [URL] = []
            let group = DispatchGroup()
            for p in promises {
                group.enter()
                p.receivePromisedFiles(atDestination: dest, options: [:], operationQueue: .main) { url, err in
                    if err == nil { got.append(url) }
                    group.leave()
                }
            }
            group.notify(queue: .main) { [weak self] in self?.pastePaths(got) }
            return true
        }
        // 3. 純圖片資料
        if let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            let f = Self.dropFolder.appendingPathComponent("拖放-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).png")
            do {
                try FileManager.default.createDirectory(at: Self.dropFolder, withIntermediateDirectories: true)
                try png.write(to: f)
                pastePaths([f]); return true
            } catch {
                let ns = error as NSError
                NSLog("無法儲存拖放圖片：%@", error.localizedDescription)
                EventLog.log(L("檔案"), L("無法儲存拖放圖片（\(ns.domain) \(ns.code)）"))
            }
        }
        return false
    }

    /// 清掉拖放暫存資料夾裡超過 maxAge 的項目，但草稿（drafts）和寄件匣（outbox）還指著的不刪：
    /// 草稿放過夜、隔天重開，裡面的檔案路徑還要有效（寄件匣只複製圖片，不複製 filePaths 的檔案）。
    /// 引用判斷：草稿／寄件匣的 JSON 原文裡有出現這個項目的路徑（斜線可能被轉成 \/，兩種寫法都找）。回傳刪掉幾個
    @discardableResult
    static func cleanDropFolder(folder: URL, stateDir: URL, maxAge: TimeInterval = 86400, now: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let old = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return 0 }
        var referenced = ""
        for sub in ["drafts", "outbox"] {
            let dir = stateDir.appendingPathComponent(sub, isDirectory: true)
            // 資料夾存在卻列不出來＝不知道哪些被引用，什麼都不刪
            if fm.fileExists(atPath: dir.path), (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) == nil { return 0 }
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                let name = f.lastPathComponent
                // 讀不懂而被隔離的（xxx.json.bad、xxx.json.bad-時間）也當引用來源：使用者可能還要從裡面救回草稿
                guard f.pathExtension == "json" || name.contains(".json.bad") else { continue }
                // 草稿／寄件匣讀不出來＝不知道哪些還被引用，這次什麼都不刪（寧可多留）。隔離檔本來就可能不是合法 UTF-8，容錯讀
                guard let data = try? Data(contentsOf: f) else { return 0 }
                referenced += String(decoding: data, as: UTF8.self) + "\n"
            }
        }
        // JSON 裡的路徑可能被跳脫（斜線 \/、引號、反斜線）：原樣和 JSON 跳脫後的寫法都找
        func jsonEscaped(_ s: String) -> String {
            guard let d = try? JSONEncoder().encode(s), let t = String(data: d, encoding: .utf8) else { return s }
            return String(t.dropFirst().dropLast())
        }
        var removed = 0
        for f in old where ((try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < now.addingTimeInterval(-maxAge) {
            // /tmp、/var 是 /private/... 的捷徑：草稿裡可能是任一種寫法，都要認
            var variants: Set<String> = [f.path, f.resolvingSymlinksInPath().path]
            for v in variants where v.hasPrefix("/private/") { variants.insert(String(v.dropFirst(8))) }
            for v in variants where !v.hasPrefix("/private/") { variants.insert("/private" + v) }
            if variants.contains(where: { referenced.contains($0) || referenced.contains(jsonEscaped($0)) }) { continue }
            try? fm.removeItem(at: f); removed += 1
        }
        return removed
    }

    static func keepCopy(_ u: URL) -> URL? {
        let dir = dropFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(u.lastPathComponent)
        return (try? FileManager.default.copyItem(at: u, to: dest)) != nil ? dest : nil
    }

    func pastePaths(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let text = urls.map { Self.shellEscape($0.path) }.joined(separator: " ") + " "
        var bracketed = false
        terminal.withTerminalPublic { bracketed = $0.bracketedPasteMode }
        hideScrollback()
        terminal.send(txt: bracketed ? "\u{1b}[200~" + text + "\u{1b}[201~" : text)
        window?.makeFirstResponder(terminal)
    }

    /// 跟 iTerm 一樣用反斜線跳脫。檔名含換行、Esc 之類的控制字元時反斜線擋不住（換行會直接把一行拆成兩個指令，
    /// Esc[201~ 還能提早結束括號貼上），整個路徑改用 $'…' 的寫法（bash、zsh 都懂），控制字元寫成 \xHH
    static func shellEscape(_ s: String) -> String {
        if s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) {
            var out = "$'"
            for u in s.unicodeScalars {
                switch u {
                case "\\": out += "\\\\"
                case "'": out += "\\'"
                default: out += (u.value < 0x20 || u.value == 0x7f) ? String(format: "\\x%02x", u.value) : String(u)
                }
            }
            return out + "'"
        }
        let special = Set(" \\'\"`$!&*()[]{}<>|;?#~=%^,\t")
        var out = ""
        for ch in s { if special.contains(ch) { out.append("\\") }; out.append(ch) }
        return out
    }
}
