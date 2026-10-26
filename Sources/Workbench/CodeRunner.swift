import AppKit
import SwiftTerm

// 程式碼學習專區的「檢查（F9）」和「執行（F10）」：照舊版 codenv 的 vimrc 做（舊版 codenv）。
// C/C++ 用 g++ -std=c++17 -Wall，加上 compat（Windows 寫的程式在 Mac 上也能跑：bits/stdc++.h、conio.h、
// system("pause")／system("cls")、輸出不等換行就顯示）；Python 用 python3。
// 執行檔放在程式旁邊的 bin/；每次執行的畫面記在 bin/.codenv-last-run.txt，讓 Claude 讀得到。

struct CodeDiagnostic {
    var line: Int
    var column: Int          // 從 1 開始；0＝整行（Python 只知道第幾行）
    var severity: String     // error | warning
    var message: String      // 開頭是「第 N 行：」
}

enum CodeRunner {
    /// compat 資料夾：App 裡的 Resources/compat；直接跑 .build 裡的執行檔時用原始碼旁邊的
    static var compat: URL {
        if let u = Bundle.main.resourceURL?.appendingPathComponent("compat"), FileManager.default.fileExists(atPath: u.appendingPathComponent("include").path) { return u }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/compat")
    }

    static let cppExtensions: Set<String> = ["cpp", "cc", "cxx", "c", "h", "hpp"]
    static func isCpp(_ file: String) -> Bool { cppExtensions.contains((file as NSString).pathExtension.lowercased()) }
    static func isPython(_ file: String) -> Bool { (file as NSString).pathExtension.lowercased() == "py" }

    /// 執行紀錄檔（給 Claude 讀）
    static func lastRunLog(for file: String) -> String {
        ((file as NSString).deletingLastPathComponent as NSString).appendingPathComponent("bin/.codenv-last-run.txt")
    }

    /// g++ 共用的參數：C++17、警告全開、compat 的標頭檔，輸出不等換行就顯示
    private static var gppFlags: [String] {
        ["-std=c++17", "-Wall", "-I", compat.appendingPathComponent("include").path, "-include", "codenv-unbuffered.h"]
    }
    /// 執行時多加的檢查：整數除以 0、陣列超出範圍（Mac 上不會自己當掉），發生時印出第幾行、代碼 86 結束
    private static let sanitize = ["-fsanitize=integer-divide-by-zero,bounds", "-fno-sanitize-recover=all"]

    // MARK: 檢查（F9）

    /// 只檢查、不執行。背景跑，做完回主執行緒：(錯誤／警告, 給人看的訊息)
    /// 訊息照舊版整理過：只留自己檔案的部分、「檔名:行:字:」換成「第 N 行：」、有 error 時先藏 warning、最後附中文提示
    static func check(file: String, _ done: @escaping ([CodeDiagnostic], String) -> Void) {
        let dir = (file as NSString).deletingLastPathComponent
        let name = (file as NSString).lastPathComponent
        DispatchQueue.global(qos: .userInitiated).async {
            var diags: [CodeDiagnostic] = []
            var text: String
            if isPython(file) {
                // .pyc 放暫存資料夾，作業資料夾不會多出 __pycache__
                let (code, out) = shell(["python3", "-m", "py_compile", name], dir: dir, env: ["PYTHONPYCACHEPREFIX": NSTemporaryDirectory()])
                (diags, text) = code == 0 ? ([], "") : parsePython(out)
            } else if isCpp(file) {
                let (code, out) = shell(["g++"] + gppFlags + ["-fsyntax-only", name], dir: dir)
                (diags, text) = parseGcc(out, file: name, failed: code != 0)
            } else {
                text = L("只支援 C／C++ 和 Python 檔")
            }
            DispatchQueue.main.async { done(diags, text) }
        }
    }

    /// 跑一個指令，拿到結束代碼和輸出（stdout＋stderr）
    private static func shell(_ args: [String], dir: String, env extra: [String: String] = [:]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        var env: [String: String] = [:]
        for kv in Workspace.environment() {
            if let i = kv.firstIndex(of: "=") { env[String(kv[..<i])] = String(kv[kv.index(after: i)...]) }
        }
        env.merge(extra) { _, b in b }
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, L("開不了 \(args[0])：\(error.localizedDescription)")) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// g++ 的訊息：每則第一行是「檔名:行:字: error: 說明」
    static func parseGcc(_ msg: String, file: String, failed: Bool) -> ([CodeDiagnostic], String) {
        let head = try! NSRegularExpression(pattern: #"^(.*?):(\d+):(\d+): (fatal error|error|warning|note): ?(.*)$"#)
        var diags: [CodeDiagnostic] = []
        var lines: [String] = []
        var keep = true, inWarning = false, hidden = 0
        for line in msg.components(separatedBy: "\n") {
            let ns = line as NSString
            if let m = head.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let f = ns.substring(with: m.range(at: 1)), kind = ns.substring(with: m.range(at: 4))
                let ln = Int(ns.substring(with: m.range(at: 2))) ?? 0, col = Int(ns.substring(with: m.range(at: 3))) ?? 0
                keep = f == file
                if failed && kind == "warning" {
                    // 有 error 時先不列 warning（常常是 error 連帶的），連它後面的 note 一起藏
                    if keep { hidden += 1 }
                    keep = false
                    inWarning = true
                } else if kind != "note" {
                    inWarning = false
                } else if inWarning {
                    keep = false
                }
                if keep {
                    let text = L("第 \(ln) 行：") + (kind == "note" ? L("（說明）") : kind == "warning" ? "warning: " : "error: ") + ns.substring(with: m.range(at: 5))
                    if kind != "note" { diags.append(CodeDiagnostic(line: ln, column: col, severity: kind == "warning" ? "warning" : "error", message: text)) }
                    lines.append(text)
                    continue
                }
            } else if line.hasPrefix("In file included from") {
                keep = false
            } else if line.range(of: #"^\d+ (error|warning)s? .*generated\.$"#, options: .regularExpression) != nil {
                keep = true
            }
            if keep { lines.append(line) }
        }
        // 錯誤全都出在系統檔案裡（自己的檔案一個都沒有）：整份照原樣給，免得什麼都看不到
        if failed && !diags.contains(where: { $0.severity == "error" }) {
            return (diags, msg.trimmingCharacters(in: .whitespacesAndNewlines) + windowsHint(msg))
        }
        if hidden > 0 { lines.append(L("（另外有 \(hidden) 個 warning，常常是上面的 error 連帶造成的，修好 error 後通常會一起消失；沒消失的話再按 F9 會顯示）")) }
        return (diags, lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + windowsHint(msg))
    }

    /// 用到 Windows 才有的檔案（Mac 上沒有）時，多一行中文說明（conio.h compat 裡有，不用提示）
    private static func windowsHint(_ msg: String) -> String {
        if msg.contains("'windows.h' file not found") {
            return "\n" + L("→ windows.h 是 Windows 才有的。Sleep(毫秒) 可以改成 this_thread::sleep_for(chrono::milliseconds(毫秒))，要 #include <thread>")
        }
        return ""
    }

    /// Python 的語法錯誤：File "x.py", line 3（縮排錯誤是 (x.py, line 3)）；最後一行是 XxxError: 說明
    static func parsePython(_ msg: String) -> ([CodeDiagnostic], String) {
        func first(_ pattern: String) -> String? {
            guard let r = try? NSRegularExpression(pattern: pattern),
                  let m = r.firstMatch(in: msg, range: NSRange(location: 0, length: (msg as NSString).length)) else { return nil }
            return (msg as NSString).substring(with: m.range(at: 1))
        }
        let ln = Int(first(#"File "[^"]*", line (\d+)"#) ?? first(#", line (\d+)\)"#) ?? "") ?? 0
        let last = msg.components(separatedBy: "\n").last { $0.contains("Error") } ?? msg
        let hint = pyHint(msg)
        let text = msg.trimmingCharacters(in: .whitespacesAndNewlines) + (hint.isEmpty ? "" : "\n→ " + hint)
        guard ln > 0 else { return ([], text) }
        let m = "第 \(ln) 行：" + last.trimmingCharacters(in: .whitespaces) + (hint.isEmpty ? "" : "\n→ " + hint)
        return ([CodeDiagnostic(line: ln, column: 0, severity: "error", message: m)], text)
    }

    /// Python 常見的語法錯誤，用中文說明
    private static func pyHint(_ msg: String) -> String {
        let hints = [
            ("expected an indented block", L("冒號（:）那行的下一行要縮排：在行首按 Tab")),
            ("unexpected indent", L("這一行不該縮排：把行首的空白刪掉，跟上一行對齊")),
            ("unindent does not match", L("這一行的縮排跟上面對不齊：同一層的程式要用一樣多的空白")),
            ("inconsistent use of tabs and spaces", L("Tab 和空白混在一起（常見於別人給的檔案）：統一改成空白")),
            ("expected ':'", L("if／for／while／def／class 那行最後要加冒號（:）")),
            ("unterminated string literal", L("引號只有開頭、沒有結尾：這一行少了一個 \" 或 '")),
            ("EOL while scanning string literal", L("引號只有開頭、沒有結尾：這一行少了一個 \" 或 '")),
            ("unexpected EOF while parsing", L("程式最後少了 ) ] } 或引號的結尾")),
            ("was never closed", L("括號或引號只有開頭、沒有結尾：找那一行少的 ) ] } 或引號")),
            ("invalid syntax", L("常見原因：上一行少了 ) 或 ]，引號沒關，或 if／for／def 那行最後少了冒號（:）")),
        ]
        return hints.first { msg.contains($0.0) }?.1 ?? ""
    }

    // MARK: 執行（F10）

    /// 給終端機跑的整串 shell 指令（/bin/zsh -c 這一串）：
    /// C/C++ 先編譯到 bin/<檔名>，成功就執行；Python 直接 python3。整段用 script 包起來：可以互動（cin 能用），
    /// 畫面同時記進 bin/.codenv-last-run.txt。最後印「—— 結束（代碼 N）——」。
    static func runCommand(file: String) -> String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let dir = (file as NSString).deletingLastPathComponent
        let name = (file as NSString).lastPathComponent
        let base = (name as NSString).deletingPathExtension
        // 執行時：compat/bin 放 PATH 最前面（system("pause")、system("cls")）；除以 0 等錯誤用代碼 86 結束；Python 不等換行就顯示
        let runEnv = "UBSAN_OPTIONS=exitcode=86:abort_on_error=0:print_summary=0 PYTHONUNBUFFERED=1 PATH=\(q(compat.appendingPathComponent("bin").path)):\"$PATH\""
        let body: String
        if isPython(file) {
            body = "\(runEnv) python3 \(q(name))"
        } else {
            let flags = (gppFlags + sanitize).map(q).joined(separator: " ")
            body = "g++ \(flags) \(q(name)) -o \(q("bin/" + base)) && \(runEnv) \(q("./bin/" + base))"
        }
        let inner = "\(body); c=$?; printf '\\n—— 結束（代碼 %d）——\\n' $c; exit $c"
        // -F：每次輸出就寫進紀錄檔，Claude 在程式還在跑時也讀得到
        return "cd \(q(dir)) && mkdir -p bin && exec /usr/bin/script -qF bin/.codenv-last-run.txt /bin/zsh -fc \(q(inner))"
    }
}

/// 程式碼區下面的執行結果：一個小終端機，可以輸入（cin、input() 能用）
final class RunPanel: NSView, LocalProcessTerminalViewDelegate {
    let terminal = LocalProcessTerminalView(frame: .zero)
    var theme: Theme { didSet { applyTheme() } }
    /// 程式結束（自己結束或被停掉）：結束代碼（停掉的、開不起來的是 nil→-1）
    var onFinish: ((Int32) -> Void)?
    /// 上一次還沒停完就按了執行：停完再跑這個
    private var pending: String?
    private(set) var isRunning = false

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
        terminal.processDelegate = self
        terminal.optionAsMetaKey = false
        addSubview(terminal)
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        terminal.frame = NSRect(x: 8, y: 4, width: max(0, bounds.width - 12), height: max(0, bounds.height - 8))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    func applyTheme() {
        let pal = theme.palette(for: effectiveAppearance)
        terminal.font = theme.font
        terminal.lineSpacing = theme.lineSpacing
        terminal.nativeForegroundColor = pal.fg
        terminal.nativeBackgroundColor = pal.bg
        terminal.caretColor = pal.cursor
        terminal.selectedTextBackgroundColor = pal.selection
        terminal.installColors(pal.ansi.map(\.terminalColor))
        wantsLayer = true
        layer?.backgroundColor = pal.bg.cgColor
    }

    /// 執行這個檔案（上一次還在跑就先停掉）
    func run(file: String) {
        let cmd = CodeRunner.runCommand(file: file)
        if isRunning {
            pending = cmd
            stop()
            return
        }
        launch(cmd)
    }

    private func launch(_ cmd: String) {
        terminal.resetToInitialState()
        terminal.feed(text: "\u{1b}[2J\u{1b}[H")
        var env = Workspace.environment()
        env.append("COLORTERM=truecolor")
        isRunning = true
        terminal.startProcess(executable: "/bin/zsh", args: ["-fc", cmd], environment: env, execName: nil, currentDirectory: nil)
        window?.makeFirstResponder(terminal)
    }

    /// 停掉正在跑的程式：先記下整串子孫行程（script 會把程式放進自己開的新 session，殺 process group 殺不到），
    /// 送 SIGTERM；一秒後還活著的全部 SIGKILL（不理 SIGTERM／SIGHUP 的死迴圈也停得掉，不會留成孤兒）
    func stop() {
        guard isRunning else { return }
        let pids = Self.descendants(of: terminal.process.shellPid)
        terminal.terminate()
        for p in pids { kill(p, SIGTERM) }
        Self.killLater(pids)
    }

    /// 一秒後還活著的就 SIGKILL（不靠 self：script 先結束、這格被釋放也照樣收）
    private static func killLater(_ pids: [pid_t]) {
        guard !pids.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            for p in pids where kill(p, 0) == 0 { kill(p, SIGKILL) }
        }
    }

    /// 某個行程底下所有的子孫（深的在前）
    static func descendants(of pid: pid_t) -> [pid_t] {
        guard pid > 0 else { return [] }
        var buf = [pid_t](repeating: 0, count: 256)
        let n = proc_listchildpids(pid, &buf, Int32(buf.count * MemoryLayout<pid_t>.size))
        let kids = n > 0 ? buf.prefix(Int(n)).filter { $0 > 0 } : []
        return kids.flatMap { descendants(of: $0) + [$0] }
    }

    deinit {
        // 對話被刪、這格被釋放：正在跑的程式一起收掉（切分頁只是從畫面拿下來，不會走到這裡）
        guard isRunning else { return }
        let pid = terminal.process.shellPid
        let pids = Self.descendants(of: pid) + (pid > 0 ? [pid] : [])
        for p in pids { kill(p, SIGTERM) }
        Self.killLater(pids)
    }

    // MARK: LocalProcessTerminalViewDelegate
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        isRunning = false
        if let cmd = pending {
            // 被新的一次執行換掉：不算結束，直接跑下一次（SwiftTerm 要在這裡面重新開才接得上）
            pending = nil
            launch(cmd)
            return
        }
        onFinish?(exitCode ?? -1)
    }
}
