import AppKit
import Foundation

/// 「回報問題」（公版用）：不自己寄任何東西，只幫使用者把內容預先填好，開他的郵件 App 或 GitHub 的新 issue 頁，由使用者看過再送。
/// Info.plist 要同時有 CodenvFeedbackEmail 和 CodenvUpdateRepo 才有這個入口（私人版沒有）。
/// 測試參數（要同時有 --state-dir 才算數）：--feedback-dump <檔案>（把兩種網址各用「不附紀錄」「附紀錄」算一次寫進檔案，不開任何東西）、
///   --feedback-log <檔案>（拿這個檔當錯誤紀錄）
enum Feedback {
    static var available: Bool { Edition.feedbackEmail != nil && Edition.updateRepo != nil }

    static let subject = L("codenv 回報：")
    /// 網址太長時郵件 App／GitHub 會吃不下，超過就從紀錄最舊的行開始丟
    static let maxURLLength = 7000
    static let logLines = 50

    // MARK: 內容

    static var chip: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return L("未知") }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    static var systemLine: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// 家目錄路徑換成 ~（先換自己的家目錄，再把同一層底下其他使用者的資料夾也換掉）
    static func scrub(_ s: String) -> String {
        var t = s.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let usersDir = NSRegularExpression.escapedPattern(for: (NSHomeDirectory() as NSString).deletingLastPathComponent)
        t = t.replacingOccurrences(of: usersDir + "/[^/\\s\"']+", with: "~", options: .regularExpression)
        return t
    }

    /// 最近的錯誤紀錄：test 參數指定的檔，否則是 Claude 除錯紀錄資料夾裡最新的那個；只取最後 50 行，每行最多 300 字
    static func recentLog(file: URL? = nil) -> [String] {
        var url = file
        if url == nil {
            let files = (try? FileManager.default.contentsOfDirectory(at: ChatSession.debugLogDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            url = files.max { a, b in
                ((try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    < ((try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
        }
        guard let url, let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 65536 ? size - 65536 : 0)      // 只讀最後 64 KB，不把大檔整個讀進來
        let text = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: true).suffix(logLines).map { scrub(String($0.prefix(300))) }
    }

    static func body(log: [String]?) -> String {
        var s = L("codenv 版本：\(Edition.version)\n\(systemLine)\n晶片：\(chip)\n\n問題描述：\n\n")
        if let log, !log.isEmpty { s += L("\n---- 最近的紀錄（最後 \(log.count) 行，家目錄路徑已換成 ~）----\n") + log.joined(separator: "\n") + "\n" }
        return s
    }

    // MARK: 網址

    private static let unreserved: CharacterSet = {
        var c = CharacterSet.alphanumerics; c.insert(charactersIn: "-._~"); return c
    }()
    /// 除了英數和 -._~ 全部編碼（& + = # 換行都不會被誤讀）
    static func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }

    static func mailtoURL(email: String, log: [String]?) -> URL? {
        fit(log) { URL(string: "mailto:\(email)?subject=\(enc(subject))&body=\(enc(body(log: $0)))") }
    }
    static func issueURL(repo: String, log: [String]?) -> URL? {
        fit(log) { URL(string: "https://github.com/\(repo)/issues/new?title=\(enc(subject))&body=\(enc(body(log: $0)))") }
    }
    /// 網址超過上限就減半紀錄行數（留最新的），直到放得下
    private static func fit(_ log: [String]?, _ make: ([String]?) -> URL?) -> URL? {
        var lines = log
        while true {
            if let u = make(lines), u.absoluteString.count <= maxURLLength || (lines ?? []).isEmpty { return u }
            if (lines ?? []).isEmpty { return nil }
            lines = Array((lines ?? []).suffix((lines ?? []).count / 2))
        }
    }

    // MARK: 回報檔（使用者 10/29：公版的「回報問題」改成產生一份回報 zip）

    /// 測試用（要有 --state-dir）：回報 zip 放 <state-dir>/reports，不放使用者的「下載項目」
    private static var stateDirArg: String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--state-dir"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }
    private static func testNote(_ s: String) {
        guard stateDirArg != nil, let path = ProcessInfo.processInfo.environment["CODENV_REPORT_TEST_LOG"] else { return }
        let line = s + "\n"
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() } else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
    }
    /// 測試：CODENV_REPORT_AUTO="按鈕編號:說明文字"（0 用郵件寄出、1 前往討論區、2 只存檔案、其他取消；要有 --state-dir）→ 不跳對話框、不開任何東西
    private static var autoChoice: (Int, String)? {
        guard stateDirArg != nil, let v = ProcessInfo.processInfo.environment["CODENV_REPORT_AUTO"], let c = v.firstIndex(of: ":"), let n = Int(v[..<c]) else { return nil }
        return (n, String(v[v.index(after: c)...]))
    }

    /// 說明選單的「回報問題…」與瀏覽器格的「回報問題…」共用：browser＝要附截圖的那一格（沒有就不附截圖）
    static func present(browser: BrowserPane? = nil, browserName: String? = nil, over window: NSWindow? = nil) {
        guard Edition.feedbackEmail != nil, Edition.updateRepo != nil else { return }
        if let browser {
            let host = browser.webView.url?.host
            browser.snapshot { shot in showReport(shot: shot, host: host, name: browserName, over: window) }
        } else {
            showReport(shot: nil, host: nil, name: nil, over: window)
        }
    }

    private static func showReport(shot: Data?, host: String?, name: String?, over window: NSWindow?) {
        guard let email = Edition.feedbackEmail, let repo = Edition.updateRepo else { return }
        var choice = 3, note = "", withShot = shot != nil
        if let a = autoChoice {
            (choice, note) = a
        } else {
            let alert = NSAlert()
            alert.messageText = L("回報問題")
            alert.informativeText = L("會產生一個回報檔（zip）：這一格的截圖、最近 3 天的事件紀錄（不含對話內容與完整網址）、codenv 版本、macOS、螢幕編號與解析度，加上你寫的說明。codenv 自己不會寄任何東西，由你決定怎麼送。")
            let label = NSTextField(labelWithString: L("說明（發生了什麼事）："))
            label.font = .systemFont(ofSize: 12)
            let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 90))
            tv.isRichText = false; tv.font = .systemFont(ofSize: 13); tv.isVerticallyResizable = true
            tv.textContainer?.widthTracksTextView = true
            let sc = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 90))
            sc.documentView = tv; sc.hasVerticalScroller = true; sc.borderType = .bezelBorder
            sc.translatesAutoresizingMaskIntoConstraints = false
            sc.widthAnchor.constraint(equalToConstant: 320).isActive = true
            sc.heightAnchor.constraint(equalToConstant: 90).isActive = true
            var views: [NSView] = [label, sc]
            let box = NSButton(checkboxWithTitle: L("附上這一格的截圖（\(host ?? "")）"), target: nil, action: nil)
            box.state = .on
            if shot != nil { views.append(box) }
            let stack = NSStackView(views: views)
            stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
            stack.frame = NSRect(x: 0, y: 0, width: 320, height: stack.fittingSize.height)
            alert.accessoryView = stack
            alert.addButton(withTitle: L("用郵件寄出"))
            alert.addButton(withTitle: L("前往討論區"))
            alert.addButton(withTitle: L("只存成檔案"))
            alert.addButton(withTitle: L("取消"))
            alert.window.initialFirstResponder = tv
            switch alert.runModal() {
            case .alertFirstButtonReturn: choice = 0
            case .alertSecondButtonReturn: choice = 1
            case .alertThirdButtonReturn: choice = 2
            default: choice = 3
            }
            note = tv.string
            withShot = shot != nil && box.state == .on
        }
        guard choice <= 2 else { testNote("取消，沒有產生檔案"); return }
        buildReport(note: note, shot: withShot ? shot : nil, host: host, name: name) { zip in
            guard let zip else {
                testNote("產生回報檔失敗")
                if stateDirArg != nil { return }   // 測試實例不跳 runModal
                let a = NSAlert(); a.messageText = L("沒能產生回報檔"); a.informativeText = L("請再試一次，或直接到討論區描述問題。"); a.runModal(); return
            }
            testNote("zip=\(zip.path)")
            switch choice {
            case 0: sendMail(to: email, zip: zip, note: note)
            case 1: openDiscussion(repo: repo, zip: zip)
            default: reveal(zip)
            }
        }
    }

    private static func reveal(_ zip: URL) {
        if stateDirArg != nil { testNote("（測試）不打開 Finder：\(zip.lastPathComponent)"); return }
        NSWorkspace.shared.activateFileViewerSelecting([zip])
    }

    /// 郵件：用系統的郵件服務帶附件；不行就開 mailto（附件請使用者自己拖進去）並在 Finder 顯示回報檔
    private static func sendMail(to email: String, zip: URL, note: String) {
        let body = L("附上回報檔 \(zip.lastPathComponent)。\n\n問題描述：\n\(note)\n")
        let svc = NSSharingService(named: .composeEmail)
        svc?.recipients = [email]
        svc?.subject = subject + (Edition.version.isEmpty ? "" : Edition.version)
        let ok = svc?.canPerform(withItems: [body, zip]) == true
        if stateDirArg != nil { testNote("郵件：收件人=\(email) 主旨=\(svc?.subject ?? "") 附件=\(zip.lastPathComponent) 系統郵件服務可用=\(ok)（測試不真的開）"); return }
        if ok { svc?.perform(withItems: [body, zip]); return }
        if let u = URL(string: "mailto:\(email)?subject=\(enc(subject))&body=\(enc(body))") { NSWorkspace.shared.open(u) }
        NSWorkspace.shared.activateFileViewerSelecting([zip])
        let a = NSAlert()
        a.messageText = L("請自己把回報檔附到信裡")
        a.informativeText = L("這台 Mac 沒有設定好郵件 App，所以只幫你開了空白信。回報檔已在 Finder 選好，拖進信裡就可以寄出。")
        a.runModal()
    }

    private static func openDiscussion(repo: String, zip: URL) {
        let url = URL(string: "https://github.com/\(repo)/issues")!
        if stateDirArg != nil { testNote("討論區：\(url.absoluteString)（測試不真的開）；回報檔 \(zip.lastPathComponent) 可自己拖進 issue"); return }
        NSWorkspace.shared.open(url)
        NSWorkspace.shared.activateFileViewerSelecting([zip])
    }

    /// 產生回報 zip（放「下載項目」；測試放 <state-dir>/reports）：說明.txt、screenshot.png（有的話）、events.log（最近 3 天）
    static func buildReport(note: String, shot: Data?, host: String?, name: String?, done: @escaping (URL?) -> Void) {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: Date())
        let outDirArg = stateDirArg.map { URL(fileURLWithPath: $0).appendingPathComponent("reports", isDirectory: true) }
        EventLog.recentThreeDaysText { log, count in
            let g = DateFormatter(); g.dateFormat = "yyyy-MM-dd HH:mm:ss"
            var info = "codenv 回報\n時間：\(g.string(from: Date()))\ncodenv 版本：\(Edition.version)\n\(systemLine)\n晶片：\(chip)\n螢幕：\(EventLog.screensSummary())\n"
            if let host, !host.isEmpty { info += "瀏覽器格：\(host)\n" }      // 格子的名稱常是第一句話或網頁標題，不寫進去
            info += "事件紀錄：\(count) 行（最近 3 天）\n\n說明：\n\(note)\n"
            let eventsText = log.isEmpty ? "（沒有事件紀錄）\n" : log + "\n"
            // 寫檔、壓縮都在背景做（截圖可能有幾 MB）；任何一步失敗就清掉暫存與半殘的 zip、回報失敗
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                let outDir = outDirArg ?? (fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? Edition.home)
                let folderName = "codenv-report-\(stamp)-\(UUID().uuidString.prefix(4).lowercased())"   // 同一秒的兩份不會互相覆蓋
                // 外面多包一層唯一的資料夾：兩份回報（或兩個 codenv）不會共用暫存而互相刪掉
                let work = fm.temporaryDirectory.appendingPathComponent("codenv-report-" + UUID().uuidString, isDirectory: true)
                let src = work.appendingPathComponent(folderName, isDirectory: true)
                let zip = outDir.appendingPathComponent(folderName + ".zip")
                func finish(_ ok: Bool) {
                    if !ok { try? fm.removeItem(at: zip) }
                    try? fm.removeItem(at: work)
                    DispatchQueue.main.async { done(ok ? zip : nil) }
                }
                do {
                    try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
                    try fm.createDirectory(at: src, withIntermediateDirectories: true)
                    try info.write(to: src.appendingPathComponent("說明.txt"), atomically: true, encoding: .utf8)
                    if let shot { try shot.write(to: src.appendingPathComponent("screenshot.png")) }
                    try eventsText.write(to: src.appendingPathComponent("events.log"), atomically: true, encoding: .utf8)
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    p.arguments = ["-c", "-k", "--keepParent", "--norsrc", src.path, zip.path]
                    try p.run()
                    p.waitUntilExit()
                    finish(p.terminationStatus == 0 && fm.fileExists(atPath: zip.path))
                } catch {
                    finish(false)
                }
            }
        }
    }

    /// 測試：算出四個網址寫進檔案，不開任何東西
    static func dump(to path: String, logFile: String?) {
        guard let email = Edition.feedbackEmail, let repo = Edition.updateRepo else { try? "no feedback entry\n".write(toFile: path, atomically: true, encoding: .utf8); return }
        let log = recentLog(file: logFile.map { URL(fileURLWithPath: $0) })
        var out = "available=\(available)\nlogLines=\(log.count)\n"
        out += "mailto=\(mailtoURL(email: email, log: nil)?.absoluteString ?? "nil")\n"
        out += "mailto+log=\(mailtoURL(email: email, log: log)?.absoluteString ?? "nil")\n"
        out += "issue=\(issueURL(repo: repo, log: nil)?.absoluteString ?? "nil")\n"
        out += "issue+log=\(issueURL(repo: repo, log: log)?.absoluteString ?? "nil")\n"
        try? out.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
