import Foundation

/// 背景自動跑的 git 共用的設定：不執行專案資料夾裡的設定指定的指令、逾時整群砍掉
enum GitProcess {
    static var path = "/usr/bin/git"        // 測試用：換成會卡住的假 git

    /// 自動跑的唯讀 git 前面要加的設定。擋住的：core.fsmonitor 指定的指令（設成 false）；呼叫端另外加 --no-ext-diff、--no-textconv 擋外部 diff 與 textconv。
    /// 沒擋住的（已知限制）：filter.<name>.clean／smudge／process。它們來自 repo 自己的 .git/config 加 .gitattributes（或 .git/info/attributes），
    /// clone 不會帶過來，只有使用者自己或本機程式寫得進去；試過 --attr-source=<空樹> 擋不住 .git/info/attributes 寫的 filter，
    /// 還會讓 `* text eol=crlf` 的 repo 多出假的變更，所以不用。
    static let safeOptions = ["-c", "core.fsmonitor=false"]

    /// 建一個 git 程序。用 perl 包一層讓它自己當一個 process group 的組長（setpgrp 後 exec，pid 不變），
    /// 逾時才能連 git 的子程序（ssh、git-remote-https）一起砍；不然子程序握著 stdout 管線，讀的一方永遠等不到結束
    static func makeProcess(_ args: [String]) -> Process { wrap(path, args) }

    /// 任何外部指令都包成自己一個 process group。exec 失敗（找不到執行檔）要用 127 結束，不然 perl 會正常結束（0），
    /// 呼叫端就拿到「成功但沒有輸出」
    /// exe 要用絕對路徑（相對路徑會改成相對於子程序的資料夾，或走 PATH 搜尋，跟 URL(fileURLWithPath:) 不一樣；目前的呼叫端都是絕對路徑）
    static func wrap(_ exe: String, _ args: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", "setpgrp(0,0); exec { $ARGV[0] } @ARGV; exit 127", exe] + args
        return p
    }

    /// 馬上結束整個 process group：先 TERM，2 秒後群組還在就 KILL
    static func terminateGroup(_ p: Process) {
        let pid = p.processIdentifier
        killpg(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if killpg(pid, 0) == 0 { killpg(pid, SIGKILL) } }
    }

    /// 逾時看門狗：先 SIGTERM 整個 process group，2 秒後不管 git 還在不在都補 SIGKILL（子程序可能還活著）。回傳要用 cancel() 取消的工作
    @discardableResult
    static func arm(_ p: Process, after timeout: TimeInterval, onTimeout: @escaping () -> Void = {}) -> DispatchWorkItem {
        let item = DispatchWorkItem {
            onTimeout()
            terminateGroup(p)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
        return item
    }
}
