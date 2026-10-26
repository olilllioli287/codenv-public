import Foundation
import Darwin

// 讓 Claude（或任何在終端機跑的程式）讀 codenv 瀏覽器格子的內容：codenv-browser 指令透過這個 Unix socket 問。
// 安全（codenv_1 10/25 的要求）：
//   - 用 Unix socket，不開網路埠：網頁的 fetch 打不到，也沒有 DNS rebinding 的問題
//   - 資料夾 0700、socket 和 token 檔 0600，每次啟動換一個隨機 token，請求要帶對才回
//   - 只能讀：列出格子、網址、標題、文字、截圖；不能點、不能打字、不能跑 JS
// 位置：~/Library/Application Support/AI 工作台/browser/（測試 App 在 --state-dir/browser）。
//   裡面 token＝這次的 token、socket＝socket 的路徑（路徑超過 sun_path 的 104 字元就改放 $TMPDIR 底下的 0700 資料夾）。
// 協定：一行 JSON 請求 {"token","cmd":"ls|text|shot","pane":"名稱或 id 開頭","max":字數} → 一行 JSON 回應 {"ok":true,...} 或 {"ok":false,"error":"..."}

final class BrowserServer {
    static let shared = BrowserServer()
    /// 名稱查得到的格子標題（側欄名稱）；MainWindow 設定
    var titleOf: ((UUID) -> String?)?

    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var token = ""
    private let queue = DispatchQueue(label: "browser-server")

    static let dir: URL = {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--state-dir"), i + 1 < a.count { return URL(fileURLWithPath: a[i + 1]).appendingPathComponent("browser") }
        return Edition.support("browser")
    }()

    private static func makePrivateDir(_ u: URL) -> Bool {
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return chmod(u.path, 0o700) == 0
    }

    func start() {
        guard fd < 0, Self.makePrivateDir(Self.dir) else { return }
        var sockPath = Self.dir.appendingPathComponent("ctl.sock").path
        if sockPath.utf8.count >= 104 {
            let t = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(appDefaults === UserDefaults.standard ? "codenv-browser" : "codenv-browser-test-\(getpid())")
            guard Self.makePrivateDir(t) else { return }
            sockPath = t.appendingPathComponent("ctl.sock").path
        }
        guard sockPath.utf8.count < 104 else { return }
        unlink(sockPath)   // 上次沒收乾淨的
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &addr.sun_path) { p in sockPath.withCString { strncpy(p.baseAddress!.assumingMemoryBound(to: CChar.self), $0, 103) } }
        let old = umask(0o077)   // bind 建出來的 socket 檔就是 0600
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
        umask(old)
        guard ok, chmod(sockPath, 0o600) == 0, listen(s, 8) == 0 else { close(s); return }
        fd = s
        // token：32 bytes 隨機，十六進位；寫暫存檔（0600）再改名
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { stop(); return }
        token = bytes.map { String(format: "%02x", $0) }.joined()
        for (name, value) in [("token", token), ("socket", sockPath)] {
            let f = Self.dir.appendingPathComponent(name), tmp = Self.dir.appendingPathComponent(".\(name).\(getpid())")
            FileManager.default.createFile(atPath: tmp.path, contents: Data(value.utf8), attributes: [.posixPermissions: 0o600])
            _ = rename(tmp.path, f.path)
        }
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        src.setEventHandler { [weak self] in self?.accept() }
        src.resume()
        source = src
        atexit { BrowserServer.shared.cleanup() }
    }

    func stop() { source?.cancel(); source = nil; if fd >= 0 { close(fd); fd = -1 }; cleanup() }
    private func cleanup() {
        if let p = try? String(contentsOf: Self.dir.appendingPathComponent("socket"), encoding: .utf8) { unlink(p) }
        unlink(Self.dir.appendingPathComponent("token").path)
    }

    private func accept() {
        let c = Darwin.accept(fd, nil, nil)
        guard c >= 0 else { return }
        // 每個連線各自在背景讀：一個慢的連線（最多等 5 秒）不會卡住後面的請求
        DispatchQueue.global(qos: .userInitiated).async { self.serve(c) }
    }

    private func serve(_ c: Int32) {
        // 只收同一個使用者的連線（socket 已經 0600，這裡再確認一次）
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(c, &uid, &gid) == 0, uid == getuid() else { close(c); return }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var nosig: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        var data = Data(), buf = [UInt8](repeating: 0, count: 4096)
        while data.count < 65_536, !data.contains(0x0A) {
            let n = read(c, &buf, buf.count)
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        let line = data.split(separator: 0x0A).first.map { Data($0) } ?? Data()
        guard let req = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return reply(c, ["ok": false, "error": "看不懂的請求"]) }
        // 比 token 用固定時間的比較，不洩漏猜對幾個字
        let given = Array(((req["token"] as? String) ?? "").utf8), want = Array(token.utf8)
        var diff = given.count ^ want.count
        for i in 0..<min(given.count, want.count) { diff |= Int(given[i] ^ want[i]) }
        guard diff == 0, !want.isEmpty else { return reply(c, ["ok": false, "error": "token 不對（codenv 重開過的話再跑一次）"]) }
        // 網頁一直不回（evaluateJavaScript、takeSnapshot 卡住）：15 秒後回錯誤，連線一定會關；先回的那個算數
        let lock = NSLock()
        var answered = false
        let finish: ([String: Any]) -> Void = { r in
            lock.lock(); let first = !answered; answered = true; lock.unlock()
            if first { DispatchQueue.global().async { self.reply(c, r) } }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) { finish(["ok": false, "error": "網頁 15 秒都沒回應（可能卡住了），再試一次"]) }
        DispatchQueue.main.async { self.handle(req, done: finish) }
    }

    private func reply(_ c: Int32, _ obj: [String: Any]) {
        if var d = try? JSONSerialization.data(withJSONObject: obj) {
            d.append(0x0A)
            d.withUnsafeBytes { p in
                var off = 0
                while off < p.count { let n = write(c, p.baseAddress! + off, p.count - off); if n <= 0 { break }; off += n }
            }
        }
        close(c)
    }

    /// 在主執行緒上做（WebKit 只能在主執行緒碰）
    private func handle(_ req: [String: Any], done: @escaping ([String: Any]) -> Void) {
        let panes = BrowserPane.all
        func info(_ p: BrowserPane) -> [String: Any] {
            ["id": String(p.conversationID.uuidString.prefix(8)).lowercased(), "name": titleOf?(p.conversationID) ?? "", "title": p.currentTitle, "url": p.currentURL]
        }
        switch req["cmd"] as? String {
        case "ls":
            done(["ok": true, "panes": panes.map(info)])
        case "text", "shot", "url":
            let want = (req["pane"] as? String ?? "").lowercased()
            let pick: BrowserPane?
            if want.isEmpty { pick = panes.first }
            else {
                pick = panes.first { $0.conversationID.uuidString.lowercased().hasPrefix(want) }
                    ?? panes.first { (titleOf?($0.conversationID) ?? "").lowercased() == want }
                    ?? panes.first { (titleOf?($0.conversationID) ?? "").lowercased().contains(want) || $0.currentTitle.lowercased().contains(want) }
            }
            guard let p = pick else { return done(["ok": false, "error": panes.isEmpty ? "codenv 現在沒有開著的瀏覽器格子" : "找不到「\(want)」這個瀏覽器格子（codenv-browser ls 看有哪些）"]) }
            var base = info(p); base["ok"] = true
            switch req["cmd"] as? String {
            case "text":
                let max = min(2_000_000, Swift.max(100, (req["max"] as? Int) ?? 100_000))
                p.pageText(max: max) { s in base["text"] = s; done(base) }
            case "shot":
                p.snapshot { d in
                    guard let d else { return done(["ok": false, "error": "截不到圖（格子可能沒在畫面上）"]) }
                    base["png"] = d.base64EncodedString(); done(base)
                }
            default: done(base)
            }
        default:
            done(["ok": false, "error": "不認得的指令（只能 ls、url、text、shot）"])
        }
    }
}
