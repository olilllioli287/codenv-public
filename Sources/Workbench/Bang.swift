import Foundation

// 聊天室 ! 指令（docs/bang-command-spec.md）：輸入框打「! 指令」不送給模型，由 codenv 直接用 zsh 跑，結果畫成卡片，
// 下一則一般訊息前面附上 <bash-input>／<bash-stdout>／<bash-stderr>（Claude Code 的格式）。
// 只有使用者在輸入框打字或貼上能觸發：沒有任何指令、排程、codenv-browser 或 API 通到這裡。

/// 一段輸出（e＝stderr）：連續同一種的併在一起
struct BangSeg: Codable, Equatable { var e: Bool; var t: String }

struct BangRecord: Codable, Identifiable, Equatable {
    var id: String
    var cmd: String
    var cwd: String
    var at: Date
    var segs: [BangSeg] = []
    var code: Int?              // 結束碼；沒結束或被停掉＝nil
    var secs: Double = 0
    var status = "running"      // running／done／stopped／timeout／interrupted（執行到一半 codenv 被關掉）
    var truncated = false       // 超過 1 MB 的後面截掉了
    var attached = false        // 已經附給模型（或使用者按 ✕ 取消了）
    var dismissed = false       // 按 ✕ 取消附上

    var running: Bool { status == "running" }
    var stdout: String { segs.filter { !$0.e }.map(\.t).joined() }
    var stderr: String { segs.filter { $0.e }.map(\.t).joined() }
}

enum BangStore {
    /// 一個聊天室的指令紀錄放 bang/<聊天室編號>.json（測試 App 放 --state-dir 裡）；跟 Claude 的 jsonl 分開
    static let dir: URL = {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--state-dir"), i + 1 < a.count { return URL(fileURLWithPath: a[i + 1]).appendingPathComponent("bang") }
        return Edition.support("bang")
    }()
    private static func url(_ chat: UUID) -> URL { dir.appendingPathComponent(chat.uuidString.lowercased() + ".json") }
    private static var coder: (JSONEncoder, JSONDecoder) {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (e, d)
    }
    /// 檔案在、但讀不了或解不開（格式壞了、欄位對不上）的聊天室：save 不能拿空的紀錄蓋掉它
    private static var unreadable = Set<UUID>()
    static func load(_ chat: UUID) -> [BangRecord] {
        guard FileManager.default.fileExists(atPath: url(chat).path) else { unreadable.remove(chat); return [] }
        guard let data = try? Data(contentsOf: url(chat)), var all = try? coder.1.decode([BangRecord].self, from: data) else {
            unreadable.insert(chat)
            return []
        }
        unreadable.remove(chat)
        // 上次執行到一半 codenv 就被關了：標成中斷（卡片不要一直轉圈）
        for i in all.indices where all[i].running { all[i].status = "interrupted" }
        return all
    }
    static func save(_ chat: UUID, _ records: [BangRecord]) {
        let destination: URL = unreadable.contains(chat)
            ? dir.appendingPathComponent(chat.uuidString.lowercased() + ".recovery.json") : url(chat)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 留最近 200 筆，檔案不會一直長
        if let d = try? coder.0.encode(Array(records.suffix(200))) { try? d.write(to: destination, options: .atomic) }
    }
}

enum Bang {
    static let maxBytes = 1_000_000             // 一個指令最多存 1 MB 輸出
    static let attachLimit = 30_000             // 附給模型：stdout、stderr 各最多這麼多字，超過留頭尾

    /// 逾時（秒）：預設 10 分鐘；測試 App 可以用 --bang-timeout 縮短
    static var timeout: Double {
        let a = CommandLine.arguments
        if a.contains("--state-dir"), let i = a.firstIndex(of: "--bang-timeout"), i + 1 < a.count, let s = Double(a[i + 1]) { return s }
        return 600
    }

    /// 是不是 ! 指令：去掉前面的空白後以 ! 或全形 ！ 開頭、後面有東西。回傳指令本身
    static func command(in text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let f = t.first, f == "!" || f == "！" else { return nil }
        let c = t.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        return c.isEmpty ? nil : c
    }
    static func isBangMode(_ text: String) -> Bool {
        guard let f = text.drop(while: { $0.isWhitespace }).first else { return false }
        return f == "!" || f == "！"
    }

    /// 太長的留頭尾、中間註明省略
    static func clip(_ s: String, _ limit: Int = attachLimit) -> String {
        guard s.count > limit else { return s }
        let head = s.prefix(limit / 2), tail = s.suffix(limit / 2)
        return head + "\n…（中間省略 \(s.count - limit) 字）…\n" + tail
    }

    /// 附在下一則訊息前面的文字（Claude Code 的格式）。連續好幾個就依序全部附上
    static func attachment(_ records: [BangRecord]) -> String {
        records.map { r in
            var s = "<bash-input>\(r.cmd)</bash-input>\n<bash-stdout>\(clip(r.stdout))</bash-stdout>\n<bash-stderr>\(clip(r.stderr))</bash-stderr>"
            if r.status == "stopped" || r.status == "timeout" || r.status == "interrupted" { s += "\n（這個指令\(r.status == "timeout" ? "逾時被停掉" : r.status == "stopped" ? "被使用者停掉" : "執行到一半 codenv 被關掉")，輸出可能不完整）" }
            return s
        }.joined(separator: "\n") + "\n\n"
    }

    /// 給好讀紀錄（transcripts）：指令和輸出的前一小段
    static func readable(_ r: BangRecord) -> String {
        let out = (r.stdout + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return "`! \(r.cmd)`（結束碼 \(r.code.map(String.init) ?? "—")）" + (out.isEmpty ? "" : "\n\n```\n\(out.prefix(2000))\(out.count > 2000 ? "\n…" : "")\n```")
    }
}

/// 跑一個指令：zsh -lc、工作資料夾、自己的程序群組（setsid），輸出即時送出。
/// 讀管線全部在自己的序列佇列 q：非阻塞讀（DispatchSource），收尾也在 q 上做，最後才丟一個 main.async 去 finish——
/// 所以輸出一定先於結束送到畫面，而且背景子程序一直握著管線（`sleep 100 &`）也不會卡住主執行緒：收尾最多等一小段、讀不到就結束
final class BangRun {
    let id: String
    let cmd: String
    let dir: String
    /// 都在主執行緒呼叫
    var onChunk: ((String, Bool) -> Void)?
    var onEnd: ((_ code: Int?, _ status: String, _ secs: Double) -> Void)?

    private var proc: Process?
    private var started = Date()
    private var ended = false
    private var status = "done"
    private let q = DispatchQueue(label: "codenv.bang.read")
    // 以下只在 q 上碰
    private var leftover: [Bool: Data] = [false: Data(), true: Data()]
    private var pipes: [(fd: Int32, isErr: Bool, source: DispatchSourceRead)] = []
    private var keep: [Pipe] = []

    init(id: String, cmd: String, dir: String) { self.id = id; self.cmd = cmd; self.dir = dir }

    var isRunning: Bool { proc != nil && !ended }

    func start() {
        let p = Process()
        // Foundation 的 Process 沒有 setsid：包一層 perl 先成為新的 session／程序群組領頭，再換成 zsh（pid 不變，之後 killpg(pid) 只停這一群）
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", "use POSIX (); POSIX::setsid(); exec {$ARGV[0]} @ARGV or die \"exec: $!\"", "/bin/zsh", "-lc", cmd]
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        var env: [String: String] = [:]
        for kv in Workspace.environment() { if let i = kv.firstIndex(of: "=") { env[String(kv[..<i])] = String(kv[kv.index(after: i)...]) } }
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice      // 要互動輸入的指令（sudo 要密碼、git 問帳密）會直接失敗
        keep = [out, err]
        for (pipe, isErr) in [(out, false), (err, true)] {
            let fd = pipe.fileHandleForReading.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: q)
            src.setEventHandler { [weak self] in self?.readAvailable(fd, isErr) }
            pipes.append((fd, isErr, src))
        }
        // 全部放進 pipes 再開始聽：q 上的處理一開始就會走訪 pipes
        for pp in pipes { pp.source.resume() }
        p.terminationHandler = { [weak self] _ in
            // 讓還在路上的輸出多讀一下，再收尾（背景程序可能還握著管線，不等到它關）
            guard let self else { return }
            self.q.asyncAfter(deadline: .now() + 0.3) { self.wrapUp() }
        }
        started = Date()
        do { try p.run() } catch {
            DispatchQueue.main.async { [weak self] in
                self?.onChunk?("開不了 zsh：\(error.localizedDescription)\n", true)
                self?.status = "done"
                self?.ended = true
                self?.onEnd?(nil, "done", 0)
            }
            return
        }
        proc = p
        DispatchQueue.main.asyncAfter(deadline: .now() + Bang.timeout) { [weak self] in
            guard let self, self.isRunning else { return }
            self.status = "timeout"
            self.terminate()
        }
    }

    /// 在 q 上：把管線裡現有的都讀完（非阻塞，沒資料或 EOF 就停）。回傳是不是遇到 EOF
    @discardableResult
    private func readAvailable(_ fd: Int32, _ isErr: Bool) -> Bool {
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = read(fd, &buf, buf.count)
            if n > 0 { received(Data(buf[0..<n]), isErr); continue }
            if n == 0 {     // EOF：不用再聽了
                pipes.first { $0.fd == fd }?.source.cancel()
                return true
            }
            return false    // EAGAIN（沒資料了）或其他錯誤
        }
    }

    /// 在 q 上：收尾。每條管線再非阻塞讀一次，然後把還沒完整的位元組也送出，最後在主執行緒 finish（排在所有 onChunk 後面）
    private func wrapUp() {
        for pp in pipes { readAvailable(pp.fd, pp.isErr); pp.source.cancel() }
        // 指令結束時還留著收不完整的位元組（輸出本身就斷在字中間）：照現有的解碼送出，不要吞掉
        for isErr in [false, true] {
            let d = leftover[isErr] ?? Data()
            leftover[isErr] = Data()
            if !d.isEmpty { emit(String(decoding: d, as: UTF8.self), isErr) }
        }
        DispatchQueue.main.async { [weak self] in self?.finish() }
    }

    private func emit(_ s: String, _ isErr: Bool) {
        DispatchQueue.main.async { [weak self] in self?.onChunk?(s, isErr) }
    }

    /// 在 q 上
    private func received(_ data: Data, _ isErr: Bool) {
        var buf = leftover[isErr] ?? Data()
        buf.append(data)
        // 結尾可能切在一個字的中間（包含只收到第一個位元組）：從最後 4 個位元組裡找開頭位元組，字還沒收完就留到下一塊再解
        var cut = buf.count
        var i = cut - 1
        while i >= max(0, cut - 4) {
            let b = buf[i]
            if b & 0xC0 != 0x80 {       // 不是接續位元組：這就是最後一個字的開頭
                let need = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1
                if cut - i < need { cut = i }
                break
            }
            i -= 1
        }
        let head = buf.prefix(cut)
        leftover[isErr] = Data(buf.suffix(buf.count - cut))
        let s = String(decoding: head, as: UTF8.self)
        if !s.isEmpty { emit(s, isErr) }
    }

    /// 停止：先 SIGTERM（整個程序群組），3 秒後還在就 SIGKILL
    func stop() {
        guard isRunning else { return }
        status = "stopped"
        terminate()
    }

    private func terminate() {
        guard let p = proc, p.isRunning else { return }
        let pid = p.processIdentifier
        guard pid > 1 else { return }       // killpg(0) 會殺到 codenv 自己的群組
        killpg(pid, SIGTERM)
        // codenv 正在結束（⌘ Q 選「強制結束」）：等不到 3 秒後那次 SIGKILL，就地等最多 1 秒，還在就直接 SIGKILL，不留孤兒
        if DetachedWindowController.terminating {
            for _ in 0..<20 where killpg(pid, 0) == 0 { usleep(50_000) }
            if killpg(pid, 0) == 0 || errno == EPERM { killpg(pid, SIGKILL) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if killpg(pid, 0) == 0 || errno == EPERM { killpg(pid, SIGKILL) }
        }
    }

    private func finish() {
        guard !ended else { return }
        ended = true
        // 被訊號停掉（SIGTERM／SIGKILL）沒有結束碼
        let code: Int? = proc?.terminationReason == .exit ? Int(proc?.terminationStatus ?? 0) : nil
        onEnd?(code, status, Date().timeIntervalSince(started))
    }
}
