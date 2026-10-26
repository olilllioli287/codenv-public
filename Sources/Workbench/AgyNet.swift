import Foundation
import Network

// 斷網時別叫 agy（使用者 10/25 回報：斷網那段時間 Chrome 開了二十幾個 Google 登入頁）。
// 原因（agy 紀錄）：token 換新連不上 → agy 當成沒登入 → print 模式改走「互動登入」，自己打開瀏覽器的登入頁，60 秒後才放棄；
// codenv 每 5 分鐘查一次 agy 額度，所以每 5 分鐘多一個分頁。
// 三層：
//   1. 系統說沒網路（NWPathMonitor 不是 satisfied）→ 不叫。網路回來時通知（用量馬上補查一次）
//   2. 背景叫之前再真的連一次 https://oauth2.googleapis.com（要登入的 Wi-Fi 頁面、DNS 快取都騙不過）
//   3. 保險：agy 的紀錄裡出現「silent auth failed」「interactive OAuth」→ 30 分鐘內（或網路有變化前）背景都不再叫 agy
// 測試 App：--agy-offline 假裝系統說沒網路；--agy-check-host 換連線檢查的主機（invalid.invalid＝連不上）
enum AgyNet {
    static let back = Notification.Name("AgyNetBack")
    private static let monitor = NWPathMonitor()
    private static let lock = NSLock()
    private static var _up = true
    private static var _blockedUntil: Date?
    private static var started = false

    private static var testOffline: Bool { CommandLine.arguments.contains("--state-dir") && CommandLine.arguments.contains("--agy-offline") }

    static func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { path in
            let now = path.status == .satisfied
            lock.lock(); let was = _up; _up = now; if now != was { _blockedUntil = nil }; lock.unlock()
            if now && !was { DispatchQueue.main.async { NotificationCenter.default.post(name: back, object: nil) } }
        }
        monitor.start(queue: DispatchQueue(label: "agy-net"))
    }

    /// 馬上就能回答（不連網路，主執行緒可以用）：系統說有網路、而且沒有因為剛跳過登入頁而暫停
    static var quickOK: Bool {
        if testOffline { return false }
        lock.lock(); defer { lock.unlock() }
        if let t = _blockedUntil, t > Date() { return false }
        return _up
    }

    /// 背景用：quickOK 加上真的連一次 Google 的登入伺服器（最多等 timeout 秒，會卡住呼叫的執行緒）
    static func canCall(timeout: TimeInterval = 3) -> Bool {
        guard quickOK else { return false }
        var host = "oauth2.googleapis.com"
        let a = CommandLine.arguments
        if a.contains("--state-dir"), let i = a.firstIndex(of: "--agy-check-host"), i + 1 < a.count { host = a[i + 1] }
        guard let url = URL(string: "https://\(host)/") else { return false }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = "HEAD"
        let done = DispatchSemaphore(value: 0)
        let ok = Box()
        // 有回 HTTP 回應（就算是 404）就算連得到；要登入的 Wi-Fi 會卡在 TLS，算連不到
        URLSession.shared.dataTask(with: req) { _, r, _ in ok.set(r is HTTPURLResponse); done.signal() }.resume()
        _ = done.wait(timeout: .now() + timeout + 1)
        return ok.get()
    }

    /// agy 跑完：看它這次的紀錄有沒有走到「互動登入」，有就暫停 30 分鐘（或到網路有變化）
    static func check(log url: URL) {
        defer { try? FileManager.default.removeItem(at: url) }
        guard let s = try? String(contentsOf: url, encoding: .utf8),
              s.contains("silent auth failed") || s.contains("triggering interactive OAuth") else { return }
        lock.lock(); _blockedUntil = Date().addingTimeInterval(30 * 60); lock.unlock()
    }

    /// 給這次 agy 用的紀錄檔（--log-file）：跑完交給 check(log:)
    static func newLogFile() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("codenv-agy-logs")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent(UUID().uuidString + ".log")
    }

    private final class Box: @unchecked Sendable {
        private let l = NSLock(); private var v = false
        func set(_ x: Bool) { l.lock(); v = x; l.unlock() }
        func get() -> Bool { l.lock(); defer { l.unlock() }; return v }
    }

    static let offlineMessage = L("現在連不上 Google，網路恢復後再送（這則留在輸入框）。斷網時叫 agy，它會以為沒登入、一直開瀏覽器登入頁，所以先不開。")
}
