import AppKit
import Foundation

/// 更新提醒（公版用）：去 GitHub Releases 看有沒有比現在新的版本，有就在側欄標題下面多一行「有新版」，點了跳出說明。
/// 只問一個網址（api.github.com 的 releases/latest），不送任何使用者資料；不會自己下載或換掉 App。
/// Info.plist 沒有 CodenvUpdateRepo（私人版）＝完全不檢查、不連網。
/// 測試參數（要同時有 --state-dir 才算數）：--update-feed <檔案>（用 GitHub 回應格式的 JSON 檔當來源）、--update-url <網址>（假的本機伺服器）、
///   --update-answer 下載|略過|之後（不跳視窗，直接當按了那顆）、--update-out <檔案>（事件一行一行寫進去）、--update-delay <秒>（取代開機後 30 秒）
final class UpdateCheck: ObservableObject {
    static let shared = UpdateCheck()

    struct Release: Equatable {
        var tag: String        // v00.02.12
        var version: String    // 00.02.12
        var notes: String
        var url: URL?
    }

    /// 側欄那一行：有比較新、而且沒被略過的版本才有值
    @Published private(set) var available: Release?

    private var dir: URL?
    private var timer: Timer?
    private var checking = false
    private var popupShown: String?       // 這次開啟已經跳過視窗的 tag，24 小時後再查到也不重複吵
    private var feedFile: String?
    private var feedURL: String?
    private var answer: String?
    private var outFile: String?

    // MARK: 版本比較

    /// "v00.02.12" → [0, 2, 12]；有任何一段不是純數字就當讀不懂（nil）
    static func parts(_ v: String) -> [Int]? {
        var s = v.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        guard !s.isEmpty else { return nil }
        var out: [Int] = []
        for seg in s.split(separator: ".", omittingEmptySubsequences: false) {
            guard let n = Int(seg), n >= 0 else { return nil }
            out.append(n)
        }
        return out
    }

    /// a 比 b 新（一段一段當數字比，不夠長的補 0；任一邊讀不懂就當不新）
    static func isNewer(_ a: String, than b: String) -> Bool {
        guard let x = parts(a), let y = parts(b) else { return false }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// GitHub releases/latest 的回應 → Release
    static func parse(_ data: Data) -> Release? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = j["tag_name"] as? String, parts(tag) != nil else { return nil }
        var v = tag
        if v.hasPrefix("v") || v.hasPrefix("V") { v.removeFirst() }
        return Release(tag: tag, version: v, notes: (j["body"] as? String) ?? "", url: (j["html_url"] as? String).flatMap(URL.init(string:)))
    }

    // MARK: 開始

    /// 啟動時叫一次：開機 30 秒後查一次，之後每 24 小時一次（設定裡關掉「自動檢查更新」就不查）
    func start(directory: URL) {
        guard Edition.updateRepo != nil else { return }
        dir = directory
        let a = CommandLine.arguments
        func opt(_ k: String) -> String? { a.firstIndex(of: k).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil } }
        var delay = 30.0
        if a.contains("--state-dir") {     // 測試參數只在測試用的資料夾下才生效，正式資料夾不會被它們改到
            feedFile = opt("--update-feed"); feedURL = opt("--update-url"); answer = opt("--update-answer"); outFile = opt("--update-out")
            if let d = opt("--update-delay").flatMap(Double.init) { delay = d }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.autoCheck()
            self?.timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in self?.autoCheck() }
        }
    }

    private func autoCheck() {
        guard Prefs.shared.autoCheckUpdates else { log("auto check off"); return }
        check(manual: false)
    }

    // MARK: 檢查

    func check(manual: Bool) {
        guard Edition.updateRepo != nil, !checking else { return }
        checking = true
        log("check manual=\(manual)")
        fetch { [weak self] rel in
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                self.handle(rel, manual: manual)
            }
        }
    }

    private func handle(_ rel: Release?, manual: Bool) {
        guard let rel else {
            log("fetch failed")
            if manual { info(L("查不到更新資訊"), L("可能沒有網路，或 GitHub 暫時連不上。晚一點再試一次。")) }
            return
        }
        guard Self.isNewer(rel.version, than: Edition.version) else {
            log("not newer remote=\(rel.version) local=\(Edition.version)")
            available = nil
            if manual { info(L("已經是最新版"), L("目前是 \(Edition.version)。")) }
            return
        }
        if skipped == rel.tag {
            if manual { setSkipped(nil) } else { log("skipped \(rel.tag)"); available = nil; return }
        }
        available = rel
        log("newer \(rel.tag)")
        if manual || popupShown != rel.tag { showPopup(rel) }
    }

    private func fetch(_ done: @escaping (Release?) -> Void) {
        if let f = feedFile {
            DispatchQueue.global().async { done((try? Data(contentsOf: URL(fileURLWithPath: f))).flatMap(Self.parse)) }
            return
        }
        guard let repo = Edition.updateRepo,
              let url = URL(string: feedURL ?? "https://api.github.com/repos/\(repo)/releases/latest") else { done(nil); return }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("codenv", forHTTPHeaderField: "User-Agent")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForResource = 20      // 整個請求最多 20 秒，不會卡住讓 checking 一直是 true
        URLSession(configuration: cfg).dataTask(with: req) { data, resp, _ in
            guard let data, (resp as? HTTPURLResponse)?.statusCode == 200 else { return done(nil) }
            done(Self.parse(data))
        }.resume()
    }

    // MARK: 視窗

    func showPopup(_ rel: Release) {
        popupShown = rel.tag
        let notes = rel.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        log("popup \(rel.tag)")
        var choice = answer
        if choice == nil {
            let alert = NSAlert()
            alert.messageText = L("codenv 有新版 \(rel.version)")
            alert.informativeText = L("你現在用的是 \(Edition.version)。\n\n") + (notes.isEmpty ? L("（這版沒有寫說明）") : String(notes.prefix(1200)) + (notes.count > 1200 ? "…" : ""))
            alert.addButton(withTitle: L("下載"))
            alert.addButton(withTitle: L("略過這版"))
            alert.addButton(withTitle: L("之後再說"))
            switch alert.runModal() {
            case .alertFirstButtonReturn: choice = "下載"
            case .alertSecondButtonReturn: choice = "略過"
            default: choice = "之後"
            }
        }
        log("answer \(choice ?? "")")
        switch choice {
        case "下載":
            if answer == nil, let u = rel.url ?? URL(string: "https://github.com/\(Edition.updateRepo ?? "")/releases/latest") { NSWorkspace.shared.open(u) }
            else { log("open \(rel.url?.absoluteString ?? "")") }
        case "略過":
            setSkipped(rel.tag)
            available = nil
        default: break
        }
    }

    private func info(_ title: String, _ text: String) {
        log("info \(title)")
        if answer != nil { return }
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.runModal()
    }

    // MARK: 略過的版本（放在 state 資料夾的 update.json，測試用別的資料夾就不會互相影響）

    private var skipFile: URL? { dir?.appendingPathComponent("update.json") }
    private var skipped: String? {
        guard let f = skipFile, let d = try? Data(contentsOf: f),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return j["skipped"] as? String
    }
    private func setSkipped(_ tag: String?) {
        guard let f = skipFile else { return }
        let obj: [String: Any] = tag.map { ["skipped": $0] } ?? [:]
        if let d = try? JSONSerialization.data(withJSONObject: obj) { try? d.write(to: f, options: .atomic) }
    }

    private func log(_ s: String) {
        guard let f = outFile, let d = (s + "\n").data(using: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: f) { h.seekToEndOfFile(); h.write(d); try? h.close() }
        else { try? d.write(to: URL(fileURLWithPath: f)) }
    }
}
