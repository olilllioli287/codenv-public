import AppKit
import Foundation

/// 「回報問題」（公版用）：不自己寄任何東西，只幫使用者把內容預先填好，開他的郵件 App 或 GitHub 的新 issue 頁，由使用者看過再送。
/// Info.plist 要同時有 CodenvFeedbackEmail 和 CodenvUpdateRepo 才有這個入口（私人版沒有）。
/// 測試參數（要同時有 --state-dir 才算數）：--feedback-dump <檔案>（把兩種網址各用「不附紀錄」「附紀錄」算一次寫進檔案，不開任何東西）、
///   --feedback-log <檔案>（拿這個檔當錯誤紀錄）
enum Feedback {
    static var available: Bool { Edition.feedbackEmail != nil && Edition.updateRepo != nil }

    static let subject = "codenv 回報："
    /// 網址太長時郵件 App／GitHub 會吃不下，超過就從紀錄最舊的行開始丟
    static let maxURLLength = 7000
    static let logLines = 50

    // MARK: 內容

    static var chip: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "未知" }
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
        var s = "codenv 版本：\(Edition.version)\n\(systemLine)\n晶片：\(chip)\n\n問題描述：\n\n"
        if let log, !log.isEmpty { s += "\n---- 最近的紀錄（最後 \(log.count) 行，家目錄路徑已換成 ~）----\n" + log.joined(separator: "\n") + "\n" }
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
            lines = Array((lines ?? []).suffix((lines ?? []).count / 2))
        }
    }

    // MARK: 視窗

    static func present() {
        guard let email = Edition.feedbackEmail, let repo = Edition.updateRepo else { return }
        let alert = NSAlert()
        alert.messageText = "回報問題"
        alert.informativeText = "選一個管道。內容會先幫你填好 codenv 版本、macOS 版本和晶片，你在郵件或網頁上看過、補上問題描述才會送出；codenv 自己不會寄任何東西。"
        let box = NSButton(checkboxWithTitle: "附上最近的錯誤紀錄（最後 \(logLines) 行）", target: nil, action: nil)
        box.state = .off
        let note = NSTextField(wrappingLabelWithString: "紀錄裡可能有檔名或對話片段，附之前請自己看過；家目錄路徑已換成 ~。")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 300
        let stack = NSStackView(views: [box, note])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 56)
        alert.accessoryView = stack
        alert.addButton(withTitle: "寄 email")
        alert.addButton(withTitle: "到 GitHub 回報")
        alert.addButton(withTitle: "取消")
        let r = alert.runModal()
        guard r == .alertFirstButtonReturn || r == .alertSecondButtonReturn else { return }
        let log = box.state == .on ? recentLog() : nil
        let url = r == .alertFirstButtonReturn ? mailtoURL(email: email, log: log) : issueURL(repo: repo, log: log)
        if let url { NSWorkspace.shared.open(url) }
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
