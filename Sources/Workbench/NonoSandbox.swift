import Foundation

/// 單一聊天室的 Claude 跑在 nono 沙盒裡。
/// 放行清單在 Resources/nono/codenv-claude.json：聊天室資料夾可讀寫；~/.claude 只開會寫的子資料夾（設定、hooks、外掛、技能、~/.claude.json 只能讀，
/// 改了會影響沙盒外的 Claude）；鑰匙圈不開。登入權杖在沙盒外取出、用 CLAUDE_CODE_OAUTH_TOKEN 帶進去：
/// 優先用鑰匙圈「codenv-nono-claude」裡的長效權杖（`claude setup-token` 產生），沒有就暫用 Claude Code 目前的登入權杖（幾小時會過期）。
/// 不開鑰匙圈的原因：開了之後沙盒裡的 Claude 寫不進鑰匙圈時會改把憑證明碼寫進 ~/.claude/.credentials.json（11/5 實測）
enum NonoSandbox {
    struct Prepared { let prefix: [String]; let env: [String: String]; let longLived: Bool }

    static var nonoPath: String? {
        ["/opt/homebrew/bin/nono", "/usr/local/bin/nono"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static var profilePath: String? {
        Bundle.main.url(forResource: "codenv-claude", withExtension: "json", subdirectory: "nono")?.path
    }
    /// 右鍵選單要不要出現：有裝 nono、App 裡有設定檔
    static var available: Bool { nonoPath != nil && profilePath != nil }
    /// 長效權杖放的鑰匙圈項目（service）
    static let tokenService = "codenv-nono-claude"

    static func prepare(directory: String) -> Result<Prepared, SandboxError> {
        // 沙盒會把聊天室的工作資料夾整個開放讀寫：資料夾是家目錄或根目錄＝等於沒擋，不啟動
        let dir = URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath().path
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        // APFS 預設不分大小寫：路徑只差大小寫也是同一個資料夾
        let d = dir.lowercased(), h = home.lowercased()
        if d == "/" || d == h || h.hasPrefix(d + "/") {
            return .failure(.text(L("這段對話的工作資料夾是 \(directory)，開沙盒等於整個家目錄都能改。先「換工作資料夾…」到專案資料夾再開")))
        }
        // 憑證與 codenv 自己的資料夾：設成工作資料夾（或其子資料夾）等於把它們整個開放讀寫
        if let bad = sensitiveRoots(home: h).first(where: { d == $0 || d.hasPrefix($0 + "/") }) {
            return .failure(.text(L("這段對話的工作資料夾是 \(directory)，位於敏感資料夾（\(bad)）內，開沙盒會把它整個開放讀寫。先「換工作資料夾…」到專案資料夾再開")))
        }
        guard let nono = nonoPath else { return .failure(.text(L("找不到 nono（brew install nono）"))) }
        guard let profile = profilePath else { return .failure(.text(L("App 裡少了沙盒設定檔，請重新編譯安裝"))) }
        var env = ["NONO_NO_UPDATE_CHECK": "1"]
        let longLived: Bool
        switch token(allowBlocking: !Thread.isMainThread) {
        case .some(let t):
            env["CLAUDE_CODE_OAUTH_TOKEN"] = t.value; longLived = t.longLived
        case .none where !Thread.isMainThread:
            return .failure(.text(L("拿不到 Claude 的登入權杖。請在終端機跑 claude setup-token，再跑 security add-generic-password -s codenv-nono-claude -a \"$USER\" -w（最後不要接權杖，它會問你，貼上就好；權杖才不會留在終端機紀錄裡）")))
        case .none:
            // 主執行緒不等 security（最多會卡 6 秒、整個畫面不動）：已改在背景讀，讀好會放進快取，請使用者再送一次
            prewarm()
            return .failure(.text(L("正在背景向鑰匙圈取 Claude 的登入權杖（最多約 6 秒），請稍後再送一次。如果一直不行，請在終端機跑 claude setup-token，再跑 security add-generic-password -s codenv-nono-claude -a \"$USER\" -w")))
        }
        return .success(Prepared(prefix: [nono, "run", "-s", "--profile", profile, "--allow-cwd", "--"], env: env, longLived: longLived))
    }

    struct Token { let value: String; let longLived: Bool }
    private static let cacheLock = NSLock()
    private static var cached: (token: Token, at: Date)?
    private static var prefetching = false
    static var cacheTTL: TimeInterval = 300

    /// 讀權杖（長效的優先；沒有就用 Claude Code 目前的登入權杖）。會呼叫 security，最多卡 keychainTimeout × 2 秒：不要在主執行緒呼叫
    static func fetchToken() -> Token? {
        if let t = keychain(service: tokenService)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return Token(value: t, longLived: true) }
        if let json = keychain(service: "Claude Code-credentials"), let d = json.data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let t = (o["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String, !t.isEmpty { return Token(value: t, longLived: false) }
        return nil
    }

    /// allowBlocking＝false（主執行緒）：只看快取、絕不等 security；true：快取沒有就當場讀並存進快取
    static func token(allowBlocking: Bool) -> Token? {
        cacheLock.lock()
        if let c = cached, Date().timeIntervalSince(c.at) < cacheTTL { cacheLock.unlock(); return c.token }
        cacheLock.unlock()
        guard allowBlocking else { return nil }
        guard let t = fetchToken() else { return nil }
        cacheLock.lock(); cached = (t, Date()); cacheLock.unlock()
        return t
    }

    /// 背景先把權杖讀進快取（開沙盒、準備啟動前呼叫）；已經在讀就不重複
    static func prewarm() {
        cacheLock.lock()
        if prefetching { cacheLock.unlock(); return }
        prefetching = true
        cacheLock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            _ = token(allowBlocking: true)
            cacheLock.lock(); prefetching = false; cacheLock.unlock()
        }
    }

    static func resetCacheForTest() { cacheLock.lock(); cached = nil; prefetching = false; cacheLock.unlock() }

    /// 不准當沙盒工作資料夾的敏感資料夾（小寫比對；h 是小寫的家目錄）
    static func sensitiveRoots(home h: String) -> [String] {
        [".ssh", ".claude", ".gnupg", ".aws", ".config", "library/keychains", "library/application support/ai 工作台"].map { h + "/" + $0 }
    }

    enum SandboxError: Error, CustomStringConvertible {
        case text(String)
        var description: String { if case .text(let s) = self { return s }; return "" }
    }

    static var keychainTimeout: TimeInterval = 3

    /// 測試實例只能執行 /private/tmp 下由 --security-bin 指定的假程式；未指定時 fail closed。
    /// 正式啟動仍使用系統 security，且只讀服務項目，不指定鑰匙圈檔案。
    static var securityPath = "/usr/bin/security"
    static func configureSecurityBinary(arguments: [String]) {
        guard KeyVault.isTestInstance(arguments) else {
            securityPath = "/usr/bin/security"
            return
        }
        guard let i = arguments.firstIndex(of: "--security-bin"), i + 1 < arguments.count else {
            securityPath = "/usr/bin/false"
            return
        }
        let suppliedPath = arguments[i + 1]
        let path = URL(fileURLWithPath: suppliedPath).resolvingSymlinksInPath().path
        let resolvesInsidePrivateTemp = path.hasPrefix("/private/tmp/") || path.hasPrefix("/tmp/")
        guard suppliedPath.hasPrefix("/private/tmp/"), resolvesInsidePrivateTemp,
              FileManager.default.isExecutableFile(atPath: path) else {
            securityPath = "/usr/bin/false"
            return
        }
        securityPath = path
    }

    /// `security find-generic-password -s <service> -w`；測試實例只會透過 --security-bin 呼叫假程式。
    static func keychain(service: String, timeout: TimeInterval? = nil) -> String? {
        runSecurity(["find-generic-password", "-s", service, "-w"], timeout: timeout, wantsOutput: true)
    }

    /// 只判斷項目存在：不帶 -w／-g，只回屬性、不讀祕密內容，也不會要授權。存在回 true。
    static func keychainExists(service: String, timeout: TimeInterval? = nil) -> Bool {
        runSecurity(["find-generic-password", "-s", service], timeout: timeout, wantsOutput: false) != nil
    }

    private static func runSecurity(_ arguments: [String], timeout: TimeInterval?, wantsOutput: Bool) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: securityPath)
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        let limit = max(0, timeout ?? keychainTimeout)
        // 逾時從呼叫開始計算，預留 250ms 給程序終止與排程，讓實際返回早於呼叫端上限。
        let deadline = DispatchTime.now() + max(0, limit - 0.25)
        guard (try? p.run()) != nil else { return nil }
        // 鑰匙圈鎖住、或要跳授權視窗等使用者按時，security 會一直等：prepare 是在啟動聊天室時同步呼叫的，不加逾時整個畫面會卡死。
        // 在背景讀輸出，最多等 3 秒；逾時就砍掉它、當作拿不到（呼叫端會給「拿不到登入權杖」的說明）
        var data = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            done.signal()
        }
        if done.wait(timeout: deadline) == .timedOut {
            p.terminate()
            if done.wait(timeout: .now() + .milliseconds(25)) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
            }
            return nil
        }
        guard p.terminationStatus == 0 else { return nil }
        guard wantsOutput else { return "" }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
