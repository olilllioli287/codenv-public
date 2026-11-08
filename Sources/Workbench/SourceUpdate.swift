import AppKit
import Foundation

/// 公版原始碼更新：只讀取 git ls-remote；真正合併和編譯交給 public/update.command。
@MainActor
final class SourceUpdate: ObservableObject {
    static let shared = SourceUpdate()
    @Published private(set) var message = L("按「檢查」查看官方原始碼是否有更新。")
    @Published private(set) var hasUpdate = false
    @Published private(set) var busy = false
    private(set) var sourceDirectory: URL?

    private var script: URL? { sourceDirectory.flatMap(Self.updateScript(in:)) }

    /// 公版 repo 的 update.command 在最上層（export-public.sh 把 public/ 的檔案搬到根目錄）；私人版原始碼裡在 public/
    nonisolated static func updateScript(in root: URL) -> URL? {
        ["update.command", "public/update.command"].map { root.appendingPathComponent($0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func check() {
        guard Edition.isPublic else { return }
        guard !busy else { return }
        guard let path = Edition.sourceDir, !path.isEmpty else {
            message = L("找不到原始碼資料夾。請從 codenv 公版原始碼的 build.sh 重新編譯。")
            hasUpdate = false
            return
        }
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) else {
            message = L("原始碼資料夾不存在或不是 Git 倉庫。請確認 CodenvSourceDir，並從 clone 的公版資料夾編譯。")
            hasUpdate = false
            return
        }
        guard Self.updateScript(in: root) != nil else {
            message = L("找不到 update.command。請從完整的 codenv 公版原始碼資料夾編譯。")
            hasUpdate = false
            return
        }
        sourceDirectory = root
        busy = true
        hasUpdate = false
        message = L("正在連線檢查官方版本…")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.latestCommit(in: root)
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                switch result {
                case .success(let (local, latest)):
                    guard !local.isEmpty else {
                        self.message = L("讀不到目前版本的 Git commit。請確認原始碼資料夾完整，並且至少有一個 commit。")
                        return
                    }
                    if local == latest {
                        self.message = L("目前已是官方最新版（\(String(latest.prefix(7)))）。")
                    } else {
                        self.hasUpdate = true
                        self.message = L("有新版可合併（官方 commit \(String(latest.prefix(7)))），按一下更新。")
                    }
                case .failure(let error):
                    self.message = L("無法檢查更新：\(error.localizedDescription)")
                }
            }
        }
    }

    func update() {
        guard Edition.isPublic, hasUpdate, !busy, let script,
              FileManager.default.isExecutableFile(atPath: script.path) else {
            message = L("找不到 update.command。請確認原始碼資料夾後再試。")
            hasUpdate = false
            return
        }
        // 用 Terminal 直接打開 .command（跟在 Finder 點兩下一樣）：看得到合併／編譯過程；不用 AppleScript，就不會跳「允許控制 Terminal」
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", script.path]
        do {
            try process.run()
            message = L("已在 Terminal 開啟更新腳本；請依照畫面中的合併與編譯結果操作。")
            hasUpdate = false
        } catch {
            message = L("無法開啟 Terminal：\(error.localizedDescription)")
        }
    }

    private enum CheckError: LocalizedError {
        case gitMissing, commandFailed(String), badOutput, privateRepository
        var errorDescription: String? {
            switch self {
            case .gitMissing: return L("找不到 git。請安裝 Xcode 命令列工具（xcode-select --install）後再試。")
            case .commandFailed(let detail): return L("無法連線官方 GitHub，請檢查網路後再試。") + (detail.isEmpty ? "" : "\n" + detail)
            case .badOutput: return L("GitHub 回傳的版本資料看不懂，請稍後再試。")
            case .privateRepository: return L("官方倉庫無法存取。請確認網路，或目前帳號是否能讀取該倉庫。")
            }
        }
    }

    nonisolated private static func latestCommit(in root: URL, url urlOverride: String? = nil) -> Result<(String, String), CheckError> {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { return .failure(.gitMissing) }
        let local = runGit(["-C", root.path, "rev-parse", "HEAD"])
        guard case .success(let localText) = local else { return .failure(.commandFailed("讀取本機 commit 失敗")) }
        let url = urlOverride ?? ProcessInfo.processInfo.environment["CODENV_UPSTREAM_URL"] ?? "https://github.com/olilllioli287/codenv-public.git"
        let remote = runGit(["ls-remote", "--", url, "refs/heads/main"])
        guard case .success(let output) = remote else {
            if case .failure(let e) = remote { return .failure(e) }
            return .failure(.commandFailed("git ls-remote 失敗"))
        }
        guard let latest = output.split(whereSeparator: \.isWhitespace).first.map(String.init), latest.count >= 7 else {
            return .failure(.privateRepository)
        }
        let current = String(localText.trimmingCharacters(in: .whitespacesAndNewlines))
        guard current.count >= 7 else { return .failure(.badOutput) }
        // 已是最新：HEAD 就是官方最新，或官方最新已經合進來（改裝過、自己有 commit 的人也一樣）。
        // 官方最新的 commit 本機還沒有＝還沒合，就是有新版；分歧交給 update.command 的合併處理（衝突會停下、不蓋改動）
        if current == latest { return .success((latest, latest)) }
        if case .success = runGit(["-C", root.path, "cat-file", "-e", "\(latest)^{commit}"]),
           case .success = runGit(["-C", root.path, "merge-base", "--is-ancestor", latest, "HEAD"]) {
            return .success((latest, latest))
        }
        return .success((current, latest))
    }

    /// 測試用（--update-check-probe）：對指定網址查一次，回「ok」或失敗說明
    nonisolated static func probeLatest(in root: URL, url: String) -> String {
        switch latestCommit(in: root, url: url) {
        case .success: return "ok"
        case .failure(let e): return "fail: " + (e.errorDescription ?? "")
        }
    }

    /// git 卡住（半開的 TCP、captive portal）最多等這麼久就砍掉，不然 busy 會一直是 true、更新鈕被擋到重開 App
    nonisolated(unsafe) static var gitTimeout: TimeInterval = 20

    nonisolated private static func runGit(_ args: [String]) -> Result<String, CheckError> {
        let p = GitProcess.makeProcess(args)
        // 私人／不存在的 repo：git 不要停下來問帳號密碼（背景執行緒會一直卡著）
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_ASKPASS"] = "/usr/bin/true"
        env["GIT_HTTP_LOW_SPEED_LIMIT"] = "1000"      // 連續 15 秒每秒不到 1 KB 就放棄
        env["GIT_HTTP_LOW_SPEED_TIME"] = "15"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do {
            try p.run()
            var timedOut = false
            let lock = NSLock()
            // 逾時：整個 process group 先 TERM、2 秒後 KILL（子程序握著管線時才不會一直卡住）
            let watchdog = GitProcess.arm(p, after: gitTimeout) { lock.lock(); timedOut = true; lock.unlock() }
            defer { watchdog.cancel() }
            // 先讀完再等結束：輸出塞滿管線時 git 會卡住等人讀，先等結束就互等
            var errData = Data()
            let g = DispatchGroup(); g.enter()
            DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            g.wait(); p.waitUntilExit()
            let stdout = String(data: outData, encoding: .utf8) ?? ""
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            lock.lock(); let didTimeOut = timedOut; lock.unlock()
            if didTimeOut { return .failure(.commandFailed(L("連線逾時（\(Int(gitTimeout)) 秒沒有回應）"))) }
            guard p.terminationStatus == 0 else { return .failure(.commandFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))) }
            return .success(stdout)
        } catch { return .failure(.commandFailed(error.localizedDescription)) }
    }

}
