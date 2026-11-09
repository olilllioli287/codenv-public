import Foundation
import Darwin

// agy 走 magpie 閘道（yetone/magpie，把兩個 agy 帳號組成號池，由 magpie 輪替）。
// 開著而且閘道連得上時，codenv 啟動 agy 會帶兩個環境變數與單次 customModels 設定，並把模型換成 magpie/antigravity/<id>：
//   GEMINI_API_KEY=magpie-agy  GOOGLE_GEMINI_BASE_URL=http://127.0.0.1:3425
// 閘道連不上（magpie 沒在跑）就照舊用 agy 自己的登入，並記一筆事件。agy -p=/usage（Usage.swift）永遠直接跑，不經 magpie。
// 限制：agy 的思考強度寫在模型名尾巴（-low／-medium／-high）；magpie 的模型名是 magpie/antigravity/<不帶強度的 id>，
// 強度由 magpie 那邊決定，所以走 magpie 時拉桿的強度不會傳過去。
// 測試（只有帶 --state-dir 才認）：--magpie-port <埠> 指到假閘道
enum AgyMagpie {
    static let key = "magpie-agy"
    static var port: Int {
        let a = CommandLine.arguments
        if a.contains("--state-dir"), let i = a.firstIndex(of: "--magpie-port"), i + 1 < a.count, let p = Int(a[i + 1]) { return p }
        return 3425
    }
    static var baseURL: String { "http://127.0.0.1:\(port)" }
    static var env: [String: String] { ["GEMINI_API_KEY": key, "GOOGLE_GEMINI_BASE_URL": baseURL] }
    static var enabled: Bool { Prefs.shared.agyMagpie }

    /// agy 的模型 → magpie 的名字；不認得的回 nil（那個模型直接走 agy 自己的登入）
    static func map(_ model: String) -> String? {
        let base = AgyBridge.base(model)
        let known = ["gemini-3.8-flash", "gemini-4-argon", "claude-opus-5-5", "claude-sonnet-5-5"]
        return known.contains(base) ? "magpie/antigravity/" + base : nil
    }

    /// 閘道連得上嗎（本機 TCP 連一下，最多等 0.4 秒；不送任何資料）
    static func gatewayUp() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if r == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, 400) > 0 else { return false }
        var err: Int32 = 0; var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err == 0
    }

    private static var lastUp: Bool?
    /// 這次開 agy 要用的模型與額外環境變數。沒開、閘道連不上、模型不認得 → 原樣（直接用 agy 的登入）
    static func settings() -> String {
        let models = ["gemini-3.8-flash", "gemini-4-argon", "claude-opus-5-5", "claude-sonnet-5-5"]
        let custom = models.map { id in
            "\"magpie/antigravity/\(id)\":{\"apiProvider\":\"API_PROVIDER_GOOGLE_GEMINI\",\"modelName\":\"antigravity/\(id)\"}"
        }.joined(separator: ",")
        return "{\"modelProvider\":\"gemini\",\"customModelsConfig\":{\"customModels\":{\(custom)}}}"
    }

    static func route(_ model: String) -> (model: String, env: [String: String], settings: String?) {
        guard enabled else { return (model, [:], nil) }
        guard let mapped = map(model) else { return (model, [:], nil) }
        let up = gatewayUp()
        if lastUp != up {
            lastUp = up
            EventLog.log("agy magpie", up ? "閘道連上了（\(baseURL)），agy 改走號池" : "閘道連不上（\(baseURL)，magpie 沒在跑？），agy 先用自己的登入")
        }
        return up ? (mapped, env, settings()) : (model, [:], nil)
    }
}
