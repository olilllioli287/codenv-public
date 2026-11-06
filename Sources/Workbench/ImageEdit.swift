import AppKit

/// 輸入框縮圖的標註編輯器：用 image-shelf 的那一支（alan890104/claude-code-paste-preview 的 editor.swift＋editor.html）。
/// 單張模式：editor <editor.html> <圖> <輸出.png> <標籤> [語言]，存檔印 SAVED、取消印 CANCELLED 後結束。
/// image-shelf 自己編好的放在 /private/tmp/image-shelf/bin（重開機會被清），找不到就自己編一份放在 Application Support。
enum ImageEditor {
    /// 要執行的編輯器可不可以信：是檔案（不是 symlink）、自己的、別人不能寫，所在資料夾也是自己的、別人不能寫
    /// （/private/tmp 是大家都寫得進去的地方，別人放一個 editor-xxx 進去就會被這邊執行）
    static func trusted(_ path: String) -> Bool {
        let fm = FileManager.default
        func ok(_ p: String, dir: Bool) -> Bool {
            var st = stat()
            guard lstat(p, &st) == 0 else { return false }
            let kind = st.st_mode & S_IFMT
            guard kind == (dir ? S_IFDIR : S_IFREG) else { return false }
            return st.st_uid == getuid() && (st.st_mode & (S_IWGRP | S_IWOTH)) == 0
        }
        return fm.isExecutableFile(atPath: path) && ok(path, dir: false) && ok((path as NSString).deletingLastPathComponent, dir: true)
    }

    /// editor.html：image-shelf 外掛最新版的，沒有就用原始碼資料夾的
    static func page() -> URL? {
        let fm = FileManager.default
        let cache = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/plugins/cache/image-shelf/image-shelf")
        let versions = ((try? fm.contentsOfDirectory(atPath: cache.path)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for v in versions {
            let u = cache.appendingPathComponent(v).appendingPathComponent("editor/editor.html")
            if fm.fileExists(atPath: u.path) { return u }
        }
        guard let dir = Edition.imageShelfSource else { return nil }
        let src = URL(fileURLWithPath: dir + "/editor/editor.html")
        return fm.fileExists(atPath: src.path) ? src : nil
    }

    /// 編好的編輯器：image-shelf 的、或自己編過的；都沒有就編一份（第一次要十幾秒）
    static func binary(page: URL, _ done: @escaping (URL?) -> Void) {
        let fm = FileManager.default
        let shelfBin = URL(fileURLWithPath: "/private/tmp/image-shelf/bin")
        if let names = try? fm.contentsOfDirectory(atPath: shelfBin.path),
           let n = names.filter({ $0.hasPrefix("editor-") }).sorted().last {
            let u = shelfBin.appendingPathComponent(n)
            if trusted(u.path) { return done(u) }      // 不可信的（別人放的、別人寫得進去的）當作沒有，往下用自己編的
        }
        let dir = Edition.supportDir
        let mine = dir.appendingPathComponent("image-editor")
        let source = page.deletingLastPathComponent().appendingPathComponent("editor.swift")
        let srcDate = (try? source.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        let binDate = (try? mine.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        if fm.isExecutableFile(atPath: mine.path), binDate >= srcDate { return done(mine) }
        guard fm.fileExists(atPath: source.path) else { return done(nil) }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            p.arguments = ["swiftc", "-O", "-o", mine.path, source.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            let ok = (try? p.run()) != nil && { p.waitUntilExit(); return p.terminationStatus == 0 }()
            DispatchQueue.main.async { done(ok ? mine : nil) }
        }
    }

    /// 打開一張圖來編輯；存檔了就把編好的 PNG 交回來（取消、失敗交回 nil）
    static func edit(_ data: Data, mediaType: String, label: String, _ done: @escaping (Data?) -> Void) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("wb-image-edit", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let input = dir.appendingPathComponent(id + (mediaType == "image/jpeg" ? ".jpg" : ".png"))
        let output = dir.appendingPathComponent(id + "-edited.png")
        guard (try? data.write(to: input)) != nil else { return done(nil) }
        guard let page = page() else {
            // 沒有 image-shelf：用預覽程式打開（改了不會自動帶回來）
            NSWorkspace.shared.open(input)
            return done(nil)
        }
        binary(page: page) { bin in
            guard let bin else { NSWorkspace.shared.open(input); return done(nil) }
            let p = Process()
            p.executableURL = bin
            p.arguments = [page.path, input.path, output.path, label, "zh-Hant"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { _ in
                let said = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let result = said.contains("SAVED") ? try? Data(contentsOf: output) : nil
                try? fm.removeItem(at: input)
                try? fm.removeItem(at: output)
                DispatchQueue.main.async { done(result) }
            }
            guard (try? p.run()) != nil else { NSWorkspace.shared.open(input); done(nil); return }
            try? out.fileHandleForWriting.close()      // 父程序不用寫入端：關掉，子程序結束才讀得到 EOF
        }
    }
}
