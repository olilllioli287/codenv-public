import Foundation

/// codenv 附的命令列工具（codenv-todo、codenv-browser、memory-check）。
/// App 包內 Resources/bin 帶一份；~/.local/bin 裡有的（私人版出版時會裝）優先用，沒有就用包內那份，
/// 所以公版不用安裝到使用者家目錄也能用（聊天室裡的 Claude 靠 PATH 找到包內那份）。
enum CLITools {
    static let names = ["codenv-todo", "codenv-browser", "memory-check"]

    /// App 包內放工具的資料夾（跑在 swift run 之類沒有 Resources 的環境就是 nil）
    static var bundleDir: String? {
        guard let r = Bundle.main.resourcePath else { return nil }
        let d = (r as NSString).appendingPathComponent("bin")
        return FileManager.default.fileExists(atPath: d) ? d : nil
    }

    /// 測試（--state-dir 才有用）：CODENV_LOCAL_BIN 換掉 ~/.local/bin，模擬使用者家目錄沒裝工具
    static var localBin: String {
        if CommandLine.arguments.contains("--state-dir"), let o = ProcessInfo.processInfo.environment["CODENV_LOCAL_BIN"] { return o }
        return Edition.home.appendingPathComponent(".local/bin").path
    }

    /// 工具的路徑：~/.local/bin 有就用，沒有用包內的；都沒有回 nil
    static func path(_ name: String) -> String? {
        let local = (localBin as NSString).appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: local) { return local }
        if let b = bundleDir {
            let p = (b as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// 給聊天室的 PATH：~/.local/bin 後面接包內資料夾
    static func pathEntries(home: String) -> String {
        ["\(home)/.local/bin", bundleDir].compactMap { $0 }.joined(separator: ":")
    }

    /// 設定頁的「安裝命令列工具」：在 ~/.local/bin 建 symlink 指到包內那份。
    /// 已經有東西的：指到這個 App 包內（舊位置也算）的 symlink 更新；其他一律不碰，回報給使用者
    static func install() -> String {
        guard let b = bundleDir else { return L("這個版本沒有附命令列工具") }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: localBin, withIntermediateDirectories: true)
        var done: [String] = [], kept: [String] = []
        for n in names {
            let src = (b as NSString).appendingPathComponent(n), dst = (localBin as NSString).appendingPathComponent(n)
            guard fm.isExecutableFile(atPath: src) else { continue }
            if let cur = try? fm.destinationOfSymbolicLink(atPath: dst) {
                if cur == src { done.append(n); continue }
                if cur.contains("/codenv.app/Contents/Resources/bin/") { try? fm.removeItem(atPath: dst) }
                else { kept.append(n); continue }
            } else if fm.fileExists(atPath: dst) { kept.append(n); continue }
            do { try fm.createSymbolicLink(atPath: dst, withDestinationPath: src); done.append(n) }
            catch { kept.append(n) }
        }
        var s = done.isEmpty ? "" : L("已安裝到 ~/.local/bin：") + done.joined(separator: "、")
        if !kept.isEmpty { s += (s.isEmpty ? "" : "\n") + L("沒有動（那裡已經有別的檔）：") + kept.joined(separator: "、") }
        return s.isEmpty ? L("沒有可安裝的工具") : s
    }
}
