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
            if (try? png.write(to: f)) != nil { pastePaths([f]); return true }
        }
        return false
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

    /// 跟 iTerm 一樣用反斜線跳脫
    static func shellEscape(_ s: String) -> String {
        let special = Set(" \\'\"`$!&*()[]{}<>|;?#~=%^,\t")
        var out = ""
        for ch in s { if special.contains(ch) { out.append("\\") }; out.append(ch) }
        return out
    }
}
