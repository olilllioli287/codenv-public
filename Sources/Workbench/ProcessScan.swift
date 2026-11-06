import Foundation
import Darwin

// 定期掃 claude 底下有沒有 agy、codex、copilot 在跑（Activity.swift 的「正在跑」用）。
// 為什麼要掃：Bash 裡用 shell 的 `&` 丟到背景的，指令馬上回傳，Claude Code 不把它當背景工作，事件裡看不到。
// 做法：一次 sysctl(KERN_PROC_ALL) 拿全部程序（pid、父程序、名字、啟動時間），只對名字像的再讀 KERN_PROCARGS2（argv、環境變數）。不開 ps、不用 pgrep。
// 怎麼算「在這個 claude 底下」：
//  1. 往上爬父程序，碰到那個 claude 的 pid 就算；
//  2. 父程序已經死掉、被 launchd（1）收養的（`cmd &` 之後 shell 就結束了，最常見），看環境變數 CLAUDE_PID：
//     Claude Code 給它的 Bash 設了 CLAUDE_PID=<claude 的 pid>，程序被收養之後環境變數還在。
// 兩種都對不上（例如自己 setsid／清掉環境變數）就抓不到。

struct ScannedProcess: Equatable {
    let pid: Int32
    let command: String      // argv 接起來（給 externalModel 看是哪個模型）
    let started: Date
}

enum ProcessScan {
    static let names: Set<String> = ["agy", "codex", "copilot"]
    /// 這些是直譯器：名字是 node 之類時，改看 argv[1]（腳本名）
    private static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3"]

    private struct Entry { let pid: Int32; let ppid: Int32; let comm: String; let started: Date }

    private static func allProcesses() -> [Entry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        size += size / 8     // 掃描的空檔可能多出幾個程序
        let count = size / MemoryLayout<kinfo_proc>.stride
        var buf = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        return buf.prefix(size / MemoryLayout<kinfo_proc>.stride).compactMap { k in
            let pid = k.kp_proc.p_pid
            guard pid > 0 else { return nil }
            var comm = k.kp_proc.p_comm
            let name = withUnsafeBytes(of: &comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let t = k.kp_proc.p_starttime
            return Entry(pid: pid, ppid: k.kp_eproc.e_ppid, comm: name, started: Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_usec) / 1_000_000))
        }
    }

    /// 讀一個程序的 argv 和環境變數（別人的程序只有同一個使用者讀得到；讀不到回 nil）
    private static func args(of pid: Int32) -> (argv: [String], env: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = Int(buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var i = 4
        while i < size, buf[i] != 0 { i += 1 }          // 執行檔路徑
        while i < size, buf[i] == 0 { i += 1 }          // 補的 0
        var strings: [String] = []
        var start = i
        while i < size {
            if buf[i] == 0 {
                if i > start { strings.append(String(decoding: buf[start..<i], as: UTF8.self)) } else if strings.count < argc { strings.append("") }
                start = i + 1
            }
            i += 1
        }
        guard argc >= 0, strings.count >= argc else { return nil }
        return (Array(strings.prefix(argc)), Array(strings.dropFirst(argc)))
    }

    /// 這個 pid 現在的啟動時間（沒有這個程序回 nil）。停止前比對用：pid 會被重用，啟動時間對不上就不是原本那個程序
    static func startTime(of pid: Int32) -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var k = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &k, &size, nil, 0) == 0, size > 0, k.kp_proc.p_pid == pid else { return nil }
        let t = k.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_usec) / 1_000_000)
    }

    /// 停掉掃到的外部程序：先確定 pid 還是同一個程序（啟動時間對得上）才送 SIGTERM，3 秒後還是同一個、還活著才送 SIGKILL。
    /// 不用 pkill、不比對指令字串。回傳 false＝程序已經不在、或 pid 已經是別的程序（沒有送任何訊號）
    @discardableResult
    static func stop(pid: Int32, started: Date, grace: TimeInterval = 3, log: ((String) -> Void)? = nil) -> Bool {
        func same() -> Bool { startTime(of: pid).map { abs($0.timeIntervalSince(started)) < 0.01 } ?? false }
        guard pid > 1, same() else {
            log?("不是同一個程序，沒有送訊號")
            EventLog.log("停止程序", "略過 pid \(pid)：程序已結束或並非原本的程序")
            return false
        }
        let r = kill(pid, SIGTERM)
        log?("SIGTERM")
        EventLog.log("停止程序", "送出 SIGTERM 給 pid \(pid)（結果 \(r == 0 ? "ok" : "errno \(errno)")）")
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            guard same() else { return }
            let kr = kill(pid, SIGKILL)
            log?("SIGKILL")
            EventLog.log("停止程序", "送出 SIGKILL 給 pid \(pid)（結果 \(kr == 0 ? "ok" : "errno \(errno)")）")
        }
        return true
    }

    /// 每個 claude pid 底下的 agy／codex／copilot（同一個程序只算給一個 claude）
    static func scan(claudePIDs: Set<Int32>) -> [Int32: [ScannedProcess]] {
        guard !claudePIDs.isEmpty else { return [:] }
        let procs = allProcesses()
        let byPid = Dictionary(procs.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var hits: [(Entry, String, [String], [String])] = []   // (程序, 認出的名字, 名字後面的參數, 環境變數) = []
        for p in procs where p.pid > 1 {
            // 先用名字篩，名字不像的不讀 argv（幾百個程序每幾秒都讀太浪費）
            let mayBe = names.contains(p.comm) || interpreters.contains(p.comm)
            guard mayBe, let a = args(of: p.pid), let first = a.argv.first else { continue }
            var head = (first as NSString).lastPathComponent
            var rest = Array(a.argv.dropFirst())
            if interpreters.contains(head), let i = rest.firstIndex(where: { !$0.hasPrefix("-") }) {
                head = (rest[i] as NSString).lastPathComponent
                rest = Array(rest.dropFirst(i + 1))        // 直譯器本人和它的旗標不算，指令從腳本名開始
            }
            guard names.contains(head) else { continue }
            hits.append((p, head, rest, a.env))
        }
        // 外層的先算：agy 自己再開的同名子程序不重複列
        let hitPIDs = Set(hits.map(\.0.pid))
        var out: [Int32: [ScannedProcess]] = [:]
        for (p, head, rest, env) in hits {
            var owner: Int32?
            var cur = p.ppid, hops = 0, nestedInHit = false
            while cur > 1, hops < 64, let e = byPid[cur] {
                if claudePIDs.contains(cur) { owner = cur; break }
                if hitPIDs.contains(cur) { nestedInHit = true }
                cur = e.ppid; hops += 1
            }
            if owner == nil, let v = env.first(where: { $0.hasPrefix("CLAUDE_PID=") }), let pid = Int32(v.dropFirst("CLAUDE_PID=".count)), claudePIDs.contains(pid) { owner = pid }
            guard let owner, !nestedInHit else { continue }
            out[owner, default: []].append(ScannedProcess(pid: p.pid, command: ([head] + rest).joined(separator: " "), started: p.started))
        }
        return out.mapValues { $0.sorted { $0.started < $1.started } }
    }
}
