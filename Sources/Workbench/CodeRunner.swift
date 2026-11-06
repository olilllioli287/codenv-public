import AppKit
import SwiftTerm

// 程式碼學習專區的「檢查（F9）」和「執行（F10）」：照舊版 codenv 的 vimrc 做（舊版 codenv）。
// C++ 用 g++ -std=c++17 -Wall（純 C 用 gcc -std=c11 -Wall），加上 compat（Windows 寫的程式在 Mac 上也能跑：bits/stdc++.h、conio.h、
// system("pause")／system("cls")、輸出不等換行就顯示）；Python 用 python3。
// 執行檔放在程式旁邊的 bin/；每次執行的畫面依檔名記在 bin/.<檔名>.last-run.txt，讓 Claude 讀得到。

struct CodeDiagnostic {
    var line: Int
    var column: Int          // 從 1 開始；0＝整行（Python 只知道第幾行）
    var severity: String     // error | warning
    var message: String      // 開頭是「第 N 行：」
}

enum CodeRunner {
    enum CheckStatus {
        case ok            // 退出碼 0（可能有 warning，在 diags 裡）
        case failed        // 退出碼非 0（語法／編譯錯誤，或找不到編譯工具）
        case unsupported   // 不是 C／C++／Python 檔
    }

    /// compat 資料夾：App 裡的 Resources/compat；直接跑 .build 裡的執行檔時用原始碼旁邊的
    static var compat: URL {
        if let u = Bundle.main.resourceURL?.appendingPathComponent("compat"), FileManager.default.fileExists(atPath: u.appendingPathComponent("include").path) { return u }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/compat")
    }

    static let cppSourceExtensions: Set<String> = ["cpp", "cc", "cxx"]
    static let headerExtensions: Set<String> = ["h", "hpp"]
    static let cppExtensions: Set<String> = ["cpp", "cc", "cxx", "c", "h", "hpp"]
    static func isC(_ file: String) -> Bool { (file as NSString).pathExtension.lowercased() == "c" }
    static func isCppSource(_ file: String) -> Bool { cppSourceExtensions.contains((file as NSString).pathExtension.lowercased()) }
    static func isHeader(_ file: String) -> Bool { headerExtensions.contains((file as NSString).pathExtension.lowercased()) }
    static func isCpp(_ file: String) -> Bool { cppExtensions.contains((file as NSString).pathExtension.lowercased()) }
    static func isPython(_ file: String) -> Bool { (file as NSString).pathExtension.lowercased() == "py" }
    static func isRunnable(_ file: String) -> Bool { isCppSource(file) || isC(file) || isPython(file) }

    /// 執行紀錄檔（依檔名分開記，切到還沒跑過的另一題時 Claude 不會讀到上一題的輸出）
    static func lastRunLog(for file: String) -> String {
        let dir = (file as NSString).deletingLastPathComponent
        let name = (file as NSString).lastPathComponent
        return (dir as NSString).appendingPathComponent("bin/.\(name).last-run.txt")
    }

    /// 純 C 用的即時輸出標頭檔（compat 的 codenv-unbuffered.h 用了 C++ 語法，純 C 改用 constructor 屬性）
    private static var cUnbufferedHeader: String {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("codenv-unbuffered-c.h")
        if !FileManager.default.fileExists(atPath: path) {
            let src = "#include <stdio.h>\n__attribute__((constructor, unused)) static void codenv_unbuffered_c(void) { setvbuf(stdout, NULL, _IONBF, 0); }\n"
            try? src.write(toFile: path, atomically: true, encoding: .utf8)
        }
        return path
    }
    /// g++ 共用的參數：C++17、警告全開、compat 的標頭檔，輸出不等換行就顯示
    private static var gppFlags: [String] {
        ["-std=c++17", "-Wall", "-I", compat.appendingPathComponent("include").path, "-include", "codenv-unbuffered.h"]
    }
    /// gcc（純 C）共用的參數：C11、警告全開，輸出不等換行就顯示
    private static var gccFlags: [String] {
        ["-std=c11", "-Wall", "-I", compat.appendingPathComponent("include").path, "-include", cUnbufferedHeader]
    }
    /// 執行時多加的檢查：整數除以 0、陣列超出範圍（Mac 上不會自己當掉），發生時印出第幾行、代碼 86 結束
    /// -g：沒有除錯資訊的話，空指標寫入這類 SEGV 的 stack 只有位址、沒有「檔名:行」，畫不出紅線（編譯時間幾乎沒差）
    private static let sanitize = ["-g", "-fsanitize=integer-divide-by-zero,bounds", "-fno-sanitize-recover=all"]

    /// CodeLabSetup 偵測到的某個工具所在的資料夾（在 /usr/bin 或沒偵測過就不用加）。只加「這次要用的那個語言」的工具資料夾，
    /// 不把 g++、gcc、python3 的資料夾一起塞進 PATH（可能蓋掉使用者別的工具）
    private static func toolDir(_ path: String?) -> [String] {
        guard let path else { return [] }
        let dir = (path as NSString).deletingLastPathComponent
        return (dir.isEmpty || dir == "/usr/bin") ? [] : [dir]
    }

    /// 這個檔案執行或檢查要用的工具資料夾：Python 檔→python3、C→gcc、C++／標頭檔→g++
    static func toolchainDirs(for file: String) -> [String] {
        guard let tc = CodeLabSetup.cachedToolchain else { return [] }
        if isPython(file) { return toolDir(tc.python3) }
        if isC(file) { return toolDir(tc.gcc) }
        if isCpp(file) { return toolDir(tc.gpp) }
        return []
    }

    /// 用指令名字找（檢查時的 shell 用）：g++、gcc、python3
    private static func toolchainDirs(forTool name: String) -> [String] {
        guard let tc = CodeLabSetup.cachedToolchain else { return [] }
        switch name {
        case "g++": return toolDir(tc.gpp)
        case "gcc": return toolDir(tc.gcc)
        case "python3": return toolDir(tc.python3)
        default: return []
        }
    }

    // MARK: 檢查（F9）

    /// 只檢查、不執行。背景跑，做完回主執行緒：(狀態, 錯誤／警告, 給人看的訊息)
    /// 訊息照舊版整理過：只留自己檔案的部分、「檔名:行:字:」換成「第 N 行：」、有 error 時先藏 warning、最後附中文提示
    static func check(file: String, _ done: @escaping (CheckStatus, [CodeDiagnostic], String) -> Void) {
        let dir = (file as NSString).deletingLastPathComponent
        let name = (file as NSString).lastPathComponent
        DispatchQueue.global(qos: .userInitiated).async {
            var status: CheckStatus = .ok
            var diags: [CodeDiagnostic] = []
            var text: String
            if isPython(file) {
                // .pyc 放暫存資料夾，作業資料夾不會多出 __pycache__
                let (code, out) = shell(["python3", "-m", "py_compile", name], dir: dir, env: ["PYTHONPYCACHEPREFIX": NSTemporaryDirectory()])
                status = code == 0 ? .ok : .failed
                (diags, text) = code == 0 ? ([], "") : parsePython(out)
            } else if isC(file) {
                let (code, out) = shell(["gcc"] + gccFlags + ["-fsyntax-only", name], dir: dir)
                status = code == 0 ? .ok : .failed
                (diags, text) = parseGcc(out, file: name, failed: code != 0)
            } else if isCppSource(file) || isHeader(file) {
                let (code, out) = shell(["g++"] + gppFlags + ["-fsyntax-only", name], dir: dir)
                status = code == 0 ? .ok : .failed
                (diags, text) = parseGcc(out, file: name, failed: code != 0)
            } else {
                status = .unsupported
                text = L("只支援 C／C++ 和 Python 檔")
            }
            DispatchQueue.main.async { done(status, diags, text) }
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
        // 把偵測到的工具所在資料夾加到 PATH 最前面，避免找不到或打到 /usr/bin 替身
        let curPath = env["PATH"] ?? ""
        let tcDirs = toolchainDirs(forTool: args.first ?? "").filter { dir in !curPath.split(separator: ":").contains(Substring(dir)) }
        if !tcDirs.isEmpty {
            let prefix = tcDirs.joined(separator: ":")
            env["PATH"] = curPath.isEmpty ? prefix : "\(prefix):\(curPath)"
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
        let m = L("第 \(ln) 行：") + last.trimmingCharacters(in: .whitespaces) + (hint.isEmpty ? "" : "\n→ " + hint)
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

    /// 常見的執行期崩潰結束代碼翻成白話中文（86＝UBSan、139＝SIGSEGV、134＝SIGABRT）
    /// log：執行紀錄。UBSan 抓到 SEGV（例如 *p = 1 寫進空指標）也是用代碼 86 結束，只看代碼會誤說成「陣列超出範圍或除以 0」，所以要看紀錄內容分辨
    static func describeExit(code: Int32, log: String = "") -> String? {
        switch code {
        case 86 where isSanitizerMemoryFault(log): return L("記憶體存取錯誤（例如指標沒指到有效位置）")
        case 86: return L("執行期錯誤（代碼 86）：陣列超出範圍或除以 0")
        case 139: return L("記憶體存取錯誤（代碼 139）：指標未初始化、陣列越界或遞迴太深")
        case 134: return L("程式異常中止（代碼 134）：abort、assert 失敗或記憶體錯誤")
        default: return nil
        }
    }

    /// 從執行紀錄解析 UBSan（代碼 86）印出的「檔名:行:字: runtime error: …」，轉成紅線標記
    static func parseRuntimeErrors(_ rawLog: String, file: String) -> [CodeDiagnostic] {
        let targetName = (file as NSString).lastPathComponent
        guard !targetName.isEmpty else { return [] }
        let clean = rawLog.replacingOccurrences(of: "\u{1b}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "")
        let escaped = NSRegularExpression.escapedPattern(for: targetName)
        guard let regex = try? NSRegularExpression(pattern: "(?:^|[^A-Za-z0-9_.-])" + escaped + ":(\\d+):(\\d+): runtime error: ?(.*)$") else { return [] }
        var out: [CodeDiagnostic] = []
        for line in clean.components(separatedBy: "\n") {
            let ns = line as NSString
            guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let ln = Int(ns.substring(with: m.range(at: 1))) ?? 0
            let col = Int(ns.substring(with: m.range(at: 2))) ?? 0
            guard ln > 0 else { continue }
            let detail = ns.substring(with: m.range(at: 3))
            var hint = ""
            if detail.contains("division by zero") { hint = L("（除以 0）") }
            else if detail.contains("out of bounds") { hint = L("（陣列索引超出範圍）") }
            let msg = L("第 \(ln) 行：") + "runtime error: " + detail + hint
            out.append(CodeDiagnostic(line: ln, column: col, severity: "error", message: msg))
        }
        return out
    }

    /// 紀錄裡是 sanitizer 抓到的記憶體存取錯誤（「UndefinedBehaviorSanitizer: SEGV on unknown address …」，BUS 也算），
    /// 不是「檔名:行:字: runtime error:」那種：兩者結束代碼都是 86，要靠內容分辨
    static func isSanitizerMemoryFault(_ log: String) -> Bool {
        log.range(of: #"Sanitizer: (SEGV|BUS) on"#, options: .regularExpression) != nil
    }

    /// 記憶體存取錯誤的補充說明：位址落在 0 附近（Hint: address points to the zero page）幾乎都是空指標，講白一點；其他情況不亂猜
    static func memoryFaultHint(_ log: String) -> String {
        log.contains("address points to the zero page") ? L("（指標是空的：NULL／nullptr）") : ""
    }

    /// 記憶體存取錯誤：從 stack（「#0 … in main 檔名:行:字」）找第一個落在自己檔案的那一層，轉成紅線標記。
    /// 編譯沒帶除錯資訊時 stack 只有位址、沒有「檔名:行」，這時回傳空的（只顯示狀態列、不畫紅線）
    static func parseMemoryFault(_ rawLog: String, file: String) -> [CodeDiagnostic] {
        let targetName = (file as NSString).lastPathComponent
        guard !targetName.isEmpty else { return [] }
        let clean = rawLog.replacingOccurrences(of: "\u{1b}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "")
        let escaped = NSRegularExpression.escapedPattern(for: targetName)
        guard let frame = try? NSRegularExpression(pattern: "^\\s*#\\d+ .*?(?:^|[^A-Za-z0-9_.-])" + escaped + ":(\\d+)(?::(\\d+))?"),
              let head = try? NSRegularExpression(pattern: #"Sanitizer: ((?:SEGV|BUS) on [^(]*?)\s*(?:\(|$)"#) else { return [] }
        var detail = "SEGV"
        var seenHead = false
        for line in clean.components(separatedBy: "\n") {
            let ns = line as NSString
            let all = NSRange(location: 0, length: ns.length)
            if !seenHead {
                // 只看報告開頭之後的 stack：程式自己先印出來的東西不算
                guard let h = head.firstMatch(in: line, range: all) else { continue }
                seenHead = true
                detail = ns.substring(with: h.range(at: 1))
                continue
            }
            guard let m = frame.firstMatch(in: line, range: all) else { continue }
            let ln = Int(ns.substring(with: m.range(at: 1))) ?? 0
            guard ln > 0 else { continue }
            let col = m.range(at: 2).location != NSNotFound ? (Int(ns.substring(with: m.range(at: 2))) ?? 0) : 0
            let msg = L("第 \(ln) 行：") + detail + memoryFaultHint(clean)
            return [CodeDiagnostic(line: ln, column: col, severity: "error", message: msg)]
        }
        return []
    }

    // MARK: 執行（F10）

    /// 給終端機跑的整串 shell 指令（/bin/zsh -c 這一串）：
    /// C/C++ 先編譯到 bin/<檔名>，成功就執行；Python 直接 python3。整段用 script 包起來：可以互動（cin 能用），
    /// 畫面同時記進 bin/.<檔名>.last-run.txt。最後印「—— 結束（代碼 N）——」。
    /// 輸入檔的選擇（照檔案記，appDefaults）：沒記＝自動、"typing"＝自己打字、其他＝使用者指定的檔
    static func inputChoiceKey(_ file: String) -> String { "codelab.input." + file }

    /// 程式旁邊自動找的輸入檔：<檔名>.in（例如 hw1.cpp → hw1.in）優先，其次同資料夾的 input.txt
    static func autoInput(for file: String) -> String? {
        let dir = (file as NSString).deletingLastPathComponent
        let base = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
        for n in [base + ".in", "input.txt"] {
            let p = (dir as NSString).appendingPathComponent(n)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue { return p }
        }
        return nil
    }

    /// 這次執行真的要當 stdin 的檔；nil＝自己打字。指定的檔不見了就退回自動找
    static func effectiveInput(for file: String, choice: String?) -> String? {
        switch choice {
        case "typing": return nil
        case .some(let c) where c != "auto" && !c.isEmpty:
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: c, isDirectory: &isDir), !isDir.boolValue { return c }
            return autoInput(for: file)
        default: return autoInput(for: file)
        }
    }

    static func runCommand(file: String, input: String? = nil) -> String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let dir = (file as NSString).deletingLastPathComponent
        let name = (file as NSString).lastPathComponent
        let base = (name as NSString).deletingPathExtension
        let logRel = "bin/.\(name).last-run.txt"
        // 執行時：compat/bin 與偵測到的 toolchain 資料夾放 PATH 最前面（system("pause")、system("cls")、python.org 或 Homebrew 工具）；除以 0 等錯誤用代碼 86 結束；Python 不等換行就顯示
        let pathParts = [compat.appendingPathComponent("bin").path] + toolchainDirs(for: file)
        let pathVal = pathParts.map(q).joined(separator: ":") + ":\"$PATH\""
        // PATH 只在下面 export 設一次（編譯與執行兩個階段都用它），這裡不再重複設
        let runEnv = "UBSAN_OPTIONS=exitcode=86:abort_on_error=0:print_summary=0 PYTHONUNBUFFERED=1"
        // 有輸入檔：程式的 stdin 接那個檔，開跑前先印一行讓人看得出這次用了哪個檔（終端機不會回顯檔案內容）
        let redirect = input.map { " < " + q($0) } ?? ""
        let banner = input.map { "printf '\\033[2m%s\\033[0m\\n' " + q(L("（這次用 \(($0 as NSString).lastPathComponent) 當輸入）")) + " && " } ?? ""
        let body: String
        if isPython(file) {
            body = "\(banner)\(runEnv) python3 \(q(name))\(redirect)"
        } else if isC(file) {
            let flags = (gccFlags + sanitize).map(q).joined(separator: " ")
            body = "gcc \(flags) \(q(name)) -o \(q("bin/" + base)) && \(banner)\(runEnv) \(q("./bin/" + base))\(redirect)"
        } else if isCppSource(file) {
            let flags = (gppFlags + sanitize).map(q).joined(separator: " ")
            body = "g++ \(flags) \(q(name)) -o \(q("bin/" + base)) && \(banner)\(runEnv) \(q("./bin/" + base))\(redirect)"
        } else {
            body = "printf '%s\\n' \(q(L("只支援執行 C、C++ 和 Python 程式檔"))); exit 1"
        }
        // export PATH 確保編譯階段（gcc／g++）與執行階段都使用包含 toolchain 所在目錄的 PATH
        let inner = "export PATH=\(pathVal); \(body); c=$?; printf '\\n—— 結束（代碼 %d）——\\n' $c; exit $c"
        // -F：每次輸出就寫進紀錄檔，Claude 在程式還在跑時也讀得到
        return "cd \(q(dir)) && mkdir -p bin && exec /usr/bin/script -qF \(q(logRel)) /bin/zsh -fc \(q(inner))"
    }
}

/// 程式碼區下面的執行結果：一個小終端機，可以輸入（cin、input() 能用）
final class RunPanel: NSView, LocalProcessTerminalViewDelegate {
    /// 單次執行紀錄檔上限（10 MB）：防止死迴圈狂印灌爆硬碟與拖垮主執行緒
    private static let maxOutputBytes: UInt64 = 10 * 1024 * 1024
    let terminal = LocalProcessTerminalView(frame: .zero)
    var theme: Theme { didSet { applyTheme() } }
    /// 程式結束（自己結束或被停掉）：結束代碼（停掉的、開不起來的是 nil→-1）
    var onFinish: ((Int32) -> Void)?
    /// 這次執行針對的目標檔案路徑
    private(set) var currentFile: String?
    /// 上一次還沒停完就按了執行：停完再跑這個
    private var pending: (cmd: String, logPath: String, file: String)?
    private var outputTimer: Timer?
    private(set) var isRunning = false
    /// 使用者主動按停止或關掉執行視窗（不算執行錯誤）
    private(set) var stoppedByUser = false
    /// 因輸出超過上限自動停掉（不一定是無限迴圈，也可能是正常的大量輸出）
    private(set) var stoppedForOutputLimit = false
    /// 每次 launch 加一：停止後的保底收尾只收當次，不會誤收之後重開的那一次
    private var runGeneration = 0

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
    func run(file: String, input: String? = nil) {
        let cmd = CodeRunner.runCommand(file: file, input: input)
        let logPath = CodeRunner.lastRunLog(for: file)
        if isRunning {
            pending = (cmd, logPath, file)
            terminateCurrent()
            return
        }
        if sessionBusy {
            // 上一次被保底收尾了，但 SwiftTerm 還沒把那個 session 交回來（processTerminated 還沒到）：這時 startProcess 會被拒絕。
            // 先記著、執行鈕維持「跑中」，等 session 交回來（processTerminated 或下面的輪詢）再開
            pending = (cmd, logPath, file)
            isRunning = true
            let gen = runGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.settleAfterStop(generation: gen) }
            return
        }
        launch(cmd, logPath: logPath, file: file)
    }

    /// SwiftTerm 的 session 還沒交回來（行程樹還沒收乾淨，或收完的回呼還在路上）：這段時間 startProcess 會被拒絕
    private var sessionBusy: Bool { terminal.process.running || terminal.process.windingDown }

    private func launch(_ cmd: String, logPath: String, file: String) {
        currentFile = file
        outputTimer?.invalidate()
        outputTimer = nil
        stoppedByUser = false
        stoppedForOutputLimit = false
        try? FileManager.default.removeItem(atPath: logPath)
        terminal.resetToInitialState()
        terminal.feed(text: "\u{1b}[2J\u{1b}[H")
        var env = Workspace.environment()
        env.append("COLORTERM=truecolor")
        runGeneration += 1
        isRunning = true
        terminal.startProcess(executable: "/bin/zsh", args: ["-fc", cmd], environment: env, execName: nil, currentDirectory: nil)
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, self.isRunning else { return }
            if let sz = (try? FileManager.default.attributesOfItem(atPath: logPath)[.size] as? NSNumber)?.uint64Value,
               sz > Self.maxOutputBytes {
                self.stopForOutputLimit()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        outputTimer = timer
        window?.makeFirstResponder(terminal)
    }

    /// 使用者主動停掉正在跑的程式
    func stop() {
        guard isRunning else { return }
        pending = nil
        stoppedByUser = true
        terminateCurrent()
    }

    private func stopForOutputLimit() {
        guard isRunning else { return }
        pending = nil
        stoppedForOutputLimit = true
        terminateCurrent()
    }

    /// 停掉目前行程樹：同時對各子行程所屬的 process group（含 script 開的新 session）與單一子孫送 SIGTERM，
    /// 避免快照與送訊號之間新 fork 的子行程漏網；一秒後還活著的全部 SIGKILL
    private func terminateCurrent() {
        outputTimer?.invalidate()
        outputTimer = nil
        let targets = Self.collectTargets(rootPid: terminal.process.shellPid)
        if let d = Self.testTermDelay {
            // 測試用：行程樹很晚才收乾淨（SwiftTerm 的 session 很晚才交回）。不呼叫 terminal.terminate()（它會馬上送 SIGTERM 給 shell），自己延遲再送
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { Self.sendSignal(SIGTERM, to: targets); Self.killLater(targets) }
        } else {
            terminal.terminate()
            Self.sendSignal(SIGTERM, to: targets)
            Self.killLater(targets)
        }
        // processTerminated 要等行程樹收乾淨才會來；萬一沒來，isRunning 永遠是 true、執行鈕卡在「停止」、排著的下一次執行也不會開。
        // 所以 1.5 秒後（SIGKILL 在 1 秒時已送出）還沒收尾就自己收；processTerminated 先到的話 isRunning 已是 false，這裡什麼都不做。
        // 注意：SwiftTerm 的 session 要等 processTerminated 交回來才能再 startProcess（見 sessionBusy、settleAfterStop）
        let gen = runGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.settleAfterStop(generation: gen) }
    }

    /// 停止後 1.5 秒（或等 session 交回來的輪詢）：只處理當次（generation 對得上、還標著在跑）。
    /// SwiftTerm 已經交回 session、或沒有下一次要跑 → 直接收尾（沒有下一次時舊的 processTerminated 之後才到也無妨：isRunning 已是 false，會被擋掉）。
    /// 舊 session 還沒交回、又有下一次要跑 → 不能現在開（startProcess 會被拒絕、之後遲到的 processTerminated 還會被當成新那次結束），
    /// 等 processTerminated 來了由 processEnded 開，期間每 0.5 秒再看一次
    private func settleAfterStop(generation gen: Int) {
        guard isRunning, runGeneration == gen else { return }
        if pending != nil && sessionBusy {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.settleAfterStop(generation: gen) }
            return
        }
        processEnded(exitCode: nil)
    }

    /// 一次執行的收尾（processTerminated 或停止後的保底都走這裡）：用 isRunning 擋重複，onFinish 每次執行只會呼叫一次
    private func processEnded(exitCode: Int32?) {
        guard isRunning else { return }
        outputTimer?.invalidate()
        outputTimer = nil
        isRunning = false
        if let next = pending {
            // 被新的一次執行換掉：不算結束，直接跑下一次（SwiftTerm 要在舊行程結束後重新開才接得上）
            pending = nil
            launch(next.cmd, logPath: next.logPath, file: next.file)
            return
        }
        onFinish?(exitCode ?? -1)
    }

    private static func collectTargets(rootPid: pid_t) -> (pids: [pid_t], pgids: Set<pid_t>) {
        guard rootPid > 0 else { return ([], []) }
        let all = descendants(of: rootPid) + [rootPid]
        let me = getpid(), myGroup = getpgrp()
        var groups = Set<pid_t>()
        for p in all where p > 1 && p != me {
            let g = getpgid(p)
            if g > 1 && g != myGroup && g != me { groups.insert(g) }
        }
        return (all.filter { $0 > 1 && $0 != me }, groups)
    }

    private static func sendSignal(_ sig: Int32, to targets: (pids: [pid_t], pgids: Set<pid_t>)) {
        let me = getpid(), myGroup = getpgrp()
        for g in targets.pgids where g > 1 && g != myGroup && g != me { kill(-g, sig) }
        for p in targets.pids where p > 1 && p != me { kill(p, sig) }
    }

    /// 測試用：帶 --state-dir 時環境變數 CODENV_TEST_TERM_DELAY（秒）讓停止要等這麼久才真的送 SIGTERM
    private static var testTermDelay: TimeInterval? {
        guard CommandLine.arguments.contains("--state-dir"), let v = ProcessInfo.processInfo.environment["CODENV_TEST_TERM_DELAY"], let d = TimeInterval(v), d > 0 else { return nil }
        return d
    }

    /// 一秒後還活著的就 SIGKILL（不靠 self：script 先結束、這格被釋放也照樣收）
    private static func killLater(_ targets: (pids: [pid_t], pgids: Set<pid_t>)) {
        guard !targets.pids.isEmpty || !targets.pgids.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let me = getpid(), myGroup = getpgrp()
            for g in targets.pgids where g > 1 && g != myGroup && g != me && kill(-g, 0) == 0 { kill(-g, SIGKILL) }
            for p in targets.pids where p > 1 && p != me && kill(p, 0) == 0 { kill(p, SIGKILL) }
        }
    }

    /// 某個行程底下所有的子孫（深的在前）
    static func descendants(of pid: pid_t) -> [pid_t] {
        guard pid > 0 else { return [] }
        var buf = [pid_t](repeating: 0, count: 2048)
        let n = proc_listchildpids(pid, &buf, Int32(buf.count * MemoryLayout<pid_t>.size))
        let kids = n > 0 ? buf.prefix(min(buf.count, Int(n))).filter { $0 > 0 } : []
        return kids.flatMap { descendants(of: $0) + [$0] }
    }

    deinit {
        outputTimer?.invalidate()
        // 對話被刪、這格被釋放：正在跑的程式一起收掉（切分頁只是從畫面拿下來，不會走到這裡）
        guard isRunning else { return }
        let targets = Self.collectTargets(rootPid: terminal.process.shellPid)
        Self.sendSignal(SIGTERM, to: targets)
        Self.killLater(targets)
    }

    // MARK: LocalProcessTerminalViewDelegate
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        processEnded(exitCode: exitCode)
    }
}
