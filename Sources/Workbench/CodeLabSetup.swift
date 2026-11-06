import AppKit

// 程式碼學習專區（CodeLab）的新使用者首次準備：
// 1. 開發工具偵測：用 xcode-select -p 靜默檢查有沒有裝 Command Line Tools（沒裝時 /usr/bin/g++ 與 /usr/bin/python3
//    是會彈出系統安裝視窗的 xcrun 替身，不能直接試跑），並一併掃描 Homebrew、python.org 等獨立安裝路徑。
// 2. 安裝引導與輪詢：缺工具時用大一新生看得懂的白話說明，點「安裝開發工具」呼叫 xcode-select --install，背景每 3 秒重測，裝好主動通知。
// 3. 練習資料夾與範例檔：預設用 Edition.practiceFolder；若因 macOS「文件」權限被拒無法寫入，讓使用者用 NSOpenPanel 另選並記進
//    appDefaults（codeLabPracticeFolder）。資料夾為空時寫入 hello.cpp、hello.py 與「先看這裡.txt」。

enum CodeLabSetup {
    static let practiceFolderKey = "codeLabPracticeFolder"
    static let firstCheckKey = "codeLabToolchainChecked"

    struct Toolchain: Equatable {
        /// 是否已安裝 Apple Command Line Tools（或完整 Xcode）
        let hasCLT: Bool
        /// 真實可用的 g++ 路徑（nil＝尚未安裝）
        let gpp: String?
        /// 真實可用的 gcc 路徑（nil＝尚未安裝）
        let gcc: String?
        /// 真實可用的 python3 路徑（nil＝尚未安裝）
        let python3: String?

        var hasCpp: Bool { gpp != nil }
        var hasPython: Bool { python3 != nil }
        var allReady: Bool { hasCpp && hasPython }

        /// 這個檔案執行或檢查前需要的工具是否已就緒（例如已裝 python.org 的 Python 時，沒裝 CLT 也能先跑 .py）
        func isReady(for file: String) -> Bool {
            if CodeRunner.isPython(file) { return hasPython }
            // 純 C 檔執行與檢查端寫死使用 gcc（C11），因此必須確認 gcc 存在，不能在只有 g++ 時誤放行
            if CodeRunner.isC(file) { return gcc != nil }
            if CodeRunner.isCpp(file) { return hasCpp }
            return true
        }
    }

    // MARK: 工具偵測與快取

    private static let lock = NSLock()
    private static var cached: Toolchain?
    private static var cachedAt: Date = .distantPast
    private static var isDetecting = false
    private static var waitingCallbacks: [(Toolchain) -> Void] = []

    /// 目前快取的偵測結果（還沒測過為 nil）
    static var cachedToolchain: Toolchain? {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    /// 在背景執行緒偵測工具鏈，結果快取後回主執行緒回報。
    /// 工具齊全時直接沿用快取；缺工具時快取只保留 3 秒，讓使用者在外部裝好工具後再按執行能馬上偵測到。
    static func detectToolchain(forceRefresh: Bool = false, _ done: @escaping (Toolchain) -> Void) {
        lock.lock()
        if !forceRefresh, let c = cached, (c.allReady || Date().timeIntervalSince(cachedAt) < 3) {
            lock.unlock()
            DispatchQueue.main.async { done(c) }
            return
        }
        waitingCallbacks.append(done)
        if isDetecting {
            lock.unlock()
            return
        }
        isDetecting = true
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async {
            let status = probeToolchain()
            lock.lock()
            cached = status
            cachedAt = Date()
            isDetecting = false
            let callbacks = waitingCallbacks
            waitingCallbacks.removeAll()
            lock.unlock()

            DispatchQueue.main.async {
                for cb in callbacks { cb(status) }
            }
        }
    }

    /// 實際探測（只在背景執行緒跑）：絕不呼叫未裝 CLT 時的 /usr/bin/g++ 或 /usr/bin/python3
    private static func probeToolchain() -> Toolchain {
        // 測試專用：假造偵測結果（CODENV_FAKE_TOOLCHAIN=none＝什麼工具都沒有；python＝只有 Python），只在 --state-dir 的測試實例有效
        if CommandLine.arguments.contains("--state-dir"), let fake = ProcessInfo.processInfo.environment["CODENV_FAKE_TOOLCHAIN"] {
            return fake == "python" ? Toolchain(hasCLT: false, gpp: nil, gcc: nil, python3: "/usr/bin/python3") : Toolchain(hasCLT: false, gpp: nil, gcc: nil, python3: nil)
        }
        let hasCLT = checkCommandLineToolsInstalled()
        let home = Edition.home.path

        let gppCandidates = [
            "/opt/homebrew/bin/g++",
            "/usr/local/bin/g++",
            "/usr/bin/g++",
        ]
        let gccCandidates = [
            "/opt/homebrew/bin/gcc",
            "/usr/local/bin/gcc",
            "/usr/bin/gcc",
        ]
        let pyCandidates = [
            (home as NSString).appendingPathComponent(".local/bin/python3"),
            "/opt/homebrew/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]

        let gpp = gppCandidates.first { usableExecutable($0, hasCLT: hasCLT) }
        let gcc = gccCandidates.first { usableExecutable($0, hasCLT: hasCLT) }
        let py = pyCandidates.first { usableExecutable($0, hasCLT: hasCLT) }
        return Toolchain(hasCLT: hasCLT, gpp: gpp, gcc: gcc, python3: py)
    }

    /// 用 xcode-select -p 靜默檢查：回傳 0 且開發者目錄裡真的有 clang 才算裝好（防系統升級或刪掉 Xcode 後殘留空資料夾）
    private static func checkCommandLineToolsInstalled() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["-p"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return false }
        let devDir = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !devDir.isEmpty else { return false }
        let fm = FileManager.default
        let cltClang = (devDir as NSString).appendingPathComponent("usr/bin/clang")
        let xcodeClang = (devDir as NSString).appendingPathComponent("Toolchains/XcodeDefault.xctoolchain/usr/bin/clang")
        return fm.isExecutableFile(atPath: cltClang) || fm.isExecutableFile(atPath: xcodeClang)
    }

    /// 檢查執行檔是否可用；若路徑本身（或 symlink 解析後）落在 /usr/bin/ 底下，它是 xcrun 替身，必須已安裝 CLT 才算可用
    private static func usableExecutable(_ path: String, hasCLT: Bool) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if resolved.hasPrefix("/usr/bin/") { return hasCLT }
        return true
    }

    // MARK: 執行／檢查前的準備確認與安裝引導

    private static var isAlertShowing = false
    private static var isInstalling = false
    private static var isPollingCheck = false
    private static var pollTimer: Timer?
    private static var pollStartedAt: Date = .distantPast
    private static weak var installWindow: NSWindow?

    /// 給執行（F10）／檢查（F9）前呼叫：該檔案所需的工具已就緒時回傳 true；缺少時跳出引導面板並回傳 false。
    static func ensureReady(for file: String, from window: NSWindow?, then: @escaping (Bool) -> Void) {
        // 快取已經顯示可用就直接通過；還沒測過或上次缺工具就強制重測一次，免得剛裝好還被舊快取擋下
        let force = !(cachedToolchain?.isReady(for: file) ?? false)
        detectToolchain(forceRefresh: force) { status in
            if status.isReady(for: file) {
                then(true)
            } else {
                then(false)
                presentMissingToolsAlert(status: status, from: window)
            }
        }
    }

    /// 第一次進入程式碼學習專區時在背景檢查一次工具：缺工具就跳引導，不擋住建立聊天室
    static func checkToolchainOnFirstEntry(from window: NSWindow?) {
        guard !appDefaults.bool(forKey: firstCheckKey) else { return }
        appDefaults.set(true, forKey: firstCheckKey)
        detectToolchain { status in
            guard !status.allReady else { return }
            presentMissingToolsAlert(status: status, from: window)
        }
    }

    /// 測試專用：CODENV_CODELAB_ALERT_LOG＝檔案路徑（只在 --state-dir 的測試實例有效）時，對話框不真的跳出來：
    /// 把標題和按鈕寫進這個檔案，再「按」CODENV_CODELAB_ALERT_PRESS 指定的按鈕（預設最後一顆）
    private static var testAlertLog: String? {
        CommandLine.arguments.contains("--state-dir") ? ProcessInfo.processInfo.environment["CODENV_CODELAB_ALERT_LOG"] : nil
    }
    private static var suppressUI: Bool { CommandLine.arguments.contains("--background") && testAlertLog == nil }

    private static func presentMissingToolsAlert(status: Toolchain, from window: NSWindow?) {
        guard !isAlertShowing, !suppressUI else { return }
        let a = NSAlert()
        if isInstalling {
            a.messageText = L("正在等待開發工具安裝完成…")
            a.informativeText = L("請確認已在系統跳出的小視窗按下「安裝」。下載與安裝大約需要 3～8 分鐘，codenv 正在背景自動檢查，一裝好就會通知你，不需要重開 App。\n\n如果剛才不小心關掉了系統小視窗，可以再點一次「安裝開發工具」。")
        } else {
            a.messageText = L("還差一步：安裝程式編譯工具")
            if !status.hasCpp && !status.hasPython {
                a.informativeText = L("這台 Mac 還沒安裝執行 C／C++ 和 Python 3 需要的開發工具。\n\n點「安裝開發工具」後，系統會跳出一個小視窗，請按裡面的「安裝」。Apple 官方的「命令列開發者工具」裝好後，C／C++（g++）和 Python 3 就能一起使用（下載與安裝大約 3～8 分鐘，裝好不用重開 codenv）。\n\n你現在還是可以先看範例、寫程式碼，或問左邊的 AI。")
            } else if !status.hasCpp {
                a.informativeText = L("這台 Mac 已經可以跑 Python 3，但還沒有安裝 C／C++ 編譯器（g++）。\n\n如果要寫 C 或 C++ 作業，點「安裝開發工具」後系統會跳出小視窗，請按裡面的「安裝」（下載與安裝大約 3～8 分鐘，裝好不用重開 codenv）。如果目前只寫 Python，按「稍後」就可以直接開始。")
            } else {
                a.informativeText = L("這台 Mac 已經有 C／C++ 編譯器，但還沒安裝 Python 3。\n\n點「安裝開發工具」可安裝 Apple 官方的命令列開發者工具（內含 Python 3，約 3～8 分鐘，裝好不用重開 codenv），或自行到 python.org 下載安裝。")
            }
        }
        a.addButton(withTitle: L("安裝開發工具"))
        a.addButton(withTitle: L("稍後"))

        isAlertShowing = true
        presentAlert(a, from: window) { resp in
            isAlertShowing = false
            if resp == .alertFirstButtonReturn {
                requestInstallCommandLineTools(from: window)
            }
        }
    }

    /// 呼叫 /usr/bin/xcode-select --install 叫出系統安裝小視窗，並開始背景輪詢
    private static func requestInstallCommandLineTools(from window: NSWindow?) {
        if testAlertLog != nil { return }      // 測試實例絕不真的執行 xcode-select --install
        installWindow = window
        startPolling()
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
            p.arguments = ["--install"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do {
                try p.run()
            } catch {
                let errMsg = error.localizedDescription
                DispatchQueue.main.async {
                    stopPolling()
                    let a = NSAlert()
                    a.alertStyle = .warning
                    a.messageText = L("無法啟動安裝程式")
                    a.informativeText = L("執行 xcode-select --install 失敗：\(errMsg)\n\n你可以在「終端機」輸入 xcode-select --install 手動安裝。")
                    a.addButton(withTitle: L("好"))
                    presentAlert(a, from: window) { _ in }
                }
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self).lowercased()
            // 若其實剛在外面裝好了，立刻重測一次，不用再等下一個週期
            if output.contains("already installed") {
                DispatchQueue.main.async { pollOnce() }
            }
        }
    }

    private static func startPolling() {
        isInstalling = true
        pollStartedAt = Date()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
            pollOnce()
        }
    }

    private static func stopPolling() {
        isInstalling = false
        isPollingCheck = false
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private static func pollOnce() {
        // 超過 45 分鐘仍未完成（例如使用者在系統視窗按了取消），自動收掉計時器
        if Date().timeIntervalSince(pollStartedAt) > 2700 {
            stopPolling()
            return
        }
        guard !isPollingCheck else { return }
        isPollingCheck = true
        detectToolchain(forceRefresh: true) { status in
            isPollingCheck = false
            guard isInstalling, status.hasCLT || status.allReady else { return }
            let win = installWindow
            stopPolling()
            notifyInstallFinished(from: win)
        }
    }

    private static func notifyInstallFinished(from window: NSWindow?) {
        guard !CommandLine.arguments.contains("--background") else { return }
        let a = NSAlert()
        a.messageText = L("開發工具安裝完成")
        a.informativeText = L("C／C++ 和 Python 3 的編譯與執行工具都準備好了！現在可以按工具列的「執行」（或鍵盤 F10）跑程式。")
        a.addButton(withTitle: L("好"))
        presentAlert(a, from: window) { _ in }
    }

    // MARK: 練習資料夾準備與範例寫入

    /// 練習資料夾：使用者另選過（存在 appDefaults 的 codeLabPracticeFolder）就優先用，否則用 Edition.practiceFolder
    static var practiceFolder: URL {
        if let custom = appDefaults.string(forKey: practiceFolderKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            let expanded = (custom as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        return Edition.practiceFolder
    }

    /// 確保練習資料夾存在且可讀寫；正常情況下同步呼叫 then(path)，無權限時引導使用者以 NSOpenPanel 另選並存入 appDefaults。
    static func preparePracticeFolder(from window: NSWindow?, then: @escaping (String?) -> Void) {
        let target = practiceFolder
        do {
            try ensureDirectoryWritable(target)
            then(target.path)
        } catch {
            promptAlternativeFolder(failedURL: target, from: window, then: then)
        }
    }

    /// 同時驗證建立、讀取清單與寫入權限（資料夾已存在但 macOS「文件」權限被關掉時，只呼叫 createDirectory 不一定會拋錯）
    private static func ensureDirectoryWritable(_ url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        _ = try fm.contentsOfDirectory(atPath: url.path)
        if !fm.isWritableFile(atPath: url.path) {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    private static func promptAlternativeFolder(failedURL: URL, from window: NSWindow?, then: @escaping (String?) -> Void) {
        guard !suppressUI else { then(nil); return }
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = L("無法寫入練習資料夾")
        a.informativeText = L("codenv 沒有權限在「\(Edition.display(failedURL))」建立或寫入檔案（可能是系統詢問「文件」資料夾權限時按了不允許）。\n\n你可以另外選一個資料夾來放練習程式，或到「系統設定 → 隱私權與安全性 → 檔案與檔案夾」開啟權限。")
        a.addButton(withTitle: L("選擇其他資料夾…"))
        a.addButton(withTitle: L("取消"))
        a.addButton(withTitle: L("打開系統設定"))

        presentAlert(a, from: window) { resp in
            switch resp {
            case .alertFirstButtonReturn:
                choosePracticeFolder(from: window, then: then)
            case .alertThirdButtonReturn:
                if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
                    NSWorkspace.shared.open(u)
                }
                then(nil)
            default:
                then(nil)
            }
        }
    }

    /// 打開 NSOpenPanel 讓使用者自選練習資料夾（可以現場新增資料夾），驗證可寫後存進 appDefaults
    static func choosePracticeFolder(from window: NSWindow?, then: @escaping (String?) -> Void) {
        guard !CommandLine.arguments.contains("--background") else { then(nil); return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = Edition.home
        panel.message = L("選一個資料夾來放程式碼學習專區的練習檔案")
        panel.prompt = L("使用這個資料夾")

        let finish: (NSApplication.ModalResponse) -> Void = { resp in
            guard resp == .OK, let chosen = panel.url else { then(nil); return }
            do {
                try ensureDirectoryWritable(chosen)
                appDefaults.set(chosen.path, forKey: practiceFolderKey)
                then(chosen.path)
            } catch {
                let errAlert = NSAlert()
                errAlert.alertStyle = .warning
                errAlert.messageText = L("這個資料夾無法寫入")
                errAlert.informativeText = L("無法在「\(Edition.display(chosen))」寫入檔案（\(error.localizedDescription)）。請換一個你有權限的位置，例如在桌面或家目錄底下新增一個資料夾。")
                errAlert.addButton(withTitle: L("好"))
                presentAlert(errAlert, from: window) { _ in
                    choosePracticeFolder(from: window, then: then)
                }
            }
        }

        if let win = hostWindow(from: window) {
            panel.beginSheetModal(for: win, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    /// 資料夾是空的（忽略 Finder 自動產生的 .DS_Store）時，寫入 hello.cpp、hello.py 範例與「先看這裡.txt」說明；已有任何檔案就不動。
    static func seedExamplesIfEmpty(in folderPath: String) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: folderPath) else { return }
        guard items.filter({ $0 != ".DS_Store" }).isEmpty else { return }

        let tip1 = L("按工具列的「執行」（或鍵盤 F10）跑跑看這支程式")
        let tip2 = L("F9 檢查語法錯誤、⌘ S 存檔；更多用法請點左上角檔名選單看「先看這裡.txt」")

        let cpp = """
        // \(tip1)
        // \(tip2)

        #include <iostream>
        using namespace std;

        int main() {
            cout << "Hello, codenv!" << endl;
            return 0;
        }
        """ + "\n"

        let py = """
        # \(tip1)
        # \(tip2)

        print("Hello, codenv!")
        """ + "\n"

        let guide = L("歡迎使用 codenv 程式碼學習專區！\n\n基本操作：\n・⌘ S 存檔：隨時儲存目前的檔案（按檢查或執行時也會自動先存檔）。\n・F9 檢查：只檢查語法有沒有打錯，不執行程式；錯的那一行會畫上紅線。\n・F10 執行：編譯並執行目前的程式，下方（或執行視窗）可以直接打字輸入並看結果。\n\n測試輸入檔（<檔名>.in）：\n・如果題目有很多行測試資料不想每次重打，可以在同一個資料夾建立「<檔名>.in」（例如 hw1.cpp 配 hw1.in，或放一份 input.txt）。\n・執行時會自動拿它當程式的輸入（stdin）；也可以在工具列的「輸入：…」選單切換成自己打字或改選其他檔案。\n\n問 AI 家教：\n・檢查或執行出錯時，工具列會出現「問 AI」按鈕；點一下會把錯誤訊息和輸入方式整理進左邊聊天框，你看過再送出。\n・平常寫作業卡住也可以直接在左邊發問（AI 看得到你目前打開哪個檔案、游標在第幾行，以及最後一次執行的輸出），請它提示思路、不要直接給答案。\n")

        // CodeLabView 的檔案選單照修改時間由新到舊排，並預設打開第一個檔案：
        // 明確拉開修改時間，讓順序固定為 hello.cpp（預設打開，直接按 F10 就能跑）→ hello.py → 先看這裡.txt
        let now = Date()
        let entries: [(String, String, TimeInterval)] = [
            ("先看這裡.txt", guide, -2),
            ("hello.py", py, -1),
            ("hello.cpp", cpp, 0),
        ]
        for (name, content, offset) in entries {
            let p = (folderPath as NSString).appendingPathComponent(name)
            try? content.write(toFile: p, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.modificationDate: now.addingTimeInterval(offset)], ofItemAtPath: p)
        }
    }

    // MARK: 對話框呈現輔助

    /// 優先掛成視窗上的 sheet（不卡死其他視窗與背景工作）；視窗還沒顯示或已掛著別的 sheet 時退回 modal
    private static func hostWindow(from window: NSWindow?) -> NSWindow? {
        for cand in [window, NSApp.keyWindow, NSApp.mainWindow] {
            if let w = cand, w.isVisible, w.attachedSheet == nil { return w }
        }
        return nil
    }

    private static func presentAlert(_ alert: NSAlert, from window: NSWindow?, handler: @escaping (NSApplication.ModalResponse) -> Void) {
        if let log = testAlertLog {
            let titles = alert.buttons.map(\.title)
            let press = ProcessInfo.processInfo.environment["CODENV_CODELAB_ALERT_PRESS"]
            let idx = press.flatMap { p in titles.firstIndex(of: p) } ?? (titles.count - 1)
            let line = "對話框「\(alert.messageText)」按鈕=\(titles) 按下=\(titles.indices.contains(idx) ? titles[idx] : "?")\n"
            if let h = FileHandle(forWritingAtPath: log) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() } else { try? line.write(toFile: log, atomically: true, encoding: .utf8) }
            handler(NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + idx))
            return
        }
        if let win = hostWindow(from: window) {
            alert.beginSheetModal(for: win, completionHandler: handler)
        } else {
            let resp = alert.runModal()
            handler(resp)
        }
    }
}
