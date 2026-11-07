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
        guard let nono = nonoPath else { return .failure(.text(L("找不到 nono（brew install nono）"))) }
        guard let profile = profilePath else { return .failure(.text(L("App 裡少了沙盒設定檔，請重新編譯安裝"))) }
        var env = ["NONO_NO_UPDATE_CHECK": "1"]
        let longLived: Bool
        if let t = keychain(service: tokenService)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            env["CLAUDE_CODE_OAUTH_TOKEN"] = t; longLived = true
        } else if let json = keychain(service: "Claude Code-credentials"), let d = json.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let t = (o["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String, !t.isEmpty {
            env["CLAUDE_CODE_OAUTH_TOKEN"] = t; longLived = false
        } else {
            return .failure(.text(L("拿不到 Claude 的登入權杖。請在終端機跑 claude setup-token，再跑 security add-generic-password -s codenv-nono-claude -a \"$USER\" -w（最後不要接權杖，它會問你，貼上就好；權杖才不會留在終端機紀錄裡）")))
        }
        return .success(Prepared(prefix: [nono, "run", "-s", "--profile", profile, "--allow-cwd", "--"], env: env, longLived: longLived))
    }

    enum SandboxError: Error, CustomStringConvertible {
        case text(String)
        var description: String { if case .text(let s) = self { return s }; return "" }
    }

    /// `security find-generic-password -s <service> -w`（只讀，不跳視窗；項目不在就回 nil）
    private static func keychain(service: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: d, encoding: .utf8)
    }
}
