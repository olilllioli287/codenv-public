import Foundation
import SwiftUI

// 右邊用量欄位「目前這段對話」底下：git 分支、這個分頁每一格正在跑的東西（主對話、前景的 Bash、背景的 shell 和子代理）。
// 指令從 claude 的事件追：tool_use 開始、tool_result 結束；背景的看 background_tasks_changed（每次給完整清單）。
// 分支自己跑 git status（切換對話、每輪做完、Claude 做了 commit／push、每 15 秒）。

struct RunningItem: Identifiable, Equatable {
    let id: String
    let text: String
    let since: Date
    let background: Bool
    let kind: String          // bash、agent、其他
    var pid: Int32? = nil     // 掃程序掃到的才有：停止時用 pid＋啟動時間（since）確認是同一個程序
    var tag: String? = nil    // 用的模型（子代理：指定的或「同上」；指令：看得出叫了外部模型才有，例如 Gemini 3.8 Flash、Codex gpt-6-luna、Copilot、本機）
}

struct GitInfo: Equatable {
    var branch: String
    var ahead = 0
    var behind = 0
    var changed = 0
    var upstream = false
}

final class SessionActivity: ObservableObject {
    static let shared = SessionActivity()
    @Published private(set) var foreground: [UUID: [RunningItem]] = [:]
    @Published private(set) var background: [UUID: [RunningItem]] = [:]
    /// 資料夾 → git 狀態（nil：不是 git 資料夾）
    @Published private(set) var git: [String: GitInfo?] = [:]
    private var gitLoading: Set<String> = []
    /// 聊天室現在用的模型名字（ChatPane 換模型時更新；跟輸入框右下角的按鈕同一個名字）
    @Published private(set) var modelNames: [UUID: String] = [:]
    func setModel(_ id: UUID, _ name: String) { if modelNames[id] != name { modelNames[id] = name } }
    /// 丟到背景跑的 Bash：事件只給描述，指令本身只有 tool_use 看得到；先記下「描述 → 指令」，背景清單出現時拿來判斷有沒有叫外部模型
    private var backgroundCommands: [UUID: [String: String]] = [:]
    /// 子代理：描述 → 它的模型標籤（子代理丟到背景之後，背景清單只剩描述，標籤靠這個找回來）
    private var agentTags: [UUID: [String: String]] = [:]

    /// 背景清單的描述 → 當初的指令：先找同名描述；沒寫描述的指令，背景清單給的是指令開頭（可能截斷、只有第一行），比開頭
    static func lookupCommand(_ desc: String, in m: [String: String]) -> String? {
        if let c = m[desc] { return c }
        // 換行、連續空白一律當一個空格比（背景清單可能把多行指令攤成一行）
        func flat(_ s: String) -> String { s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
        let head = flat(desc.trimmingCharacters(in: CharacterSet(charactersIn: "…").union(.whitespacesAndNewlines)))
        guard head.count >= 8 else { return nil }
        return m.values.first { flat($0).hasPrefix(head) }
    }

    /// 從指令文字看得出它叫了哪個外部模型（看不出來就 nil）
    static func externalModel(in command: String) -> String? {
        func value(after flags: [String], in text: String) -> String? {
            for f in flags {
                if let r = text.range(of: #"(?:^|\s)\#(NSRegularExpression.escapedPattern(for: f))(?:\s+|=)(\S+)"#, options: .regularExpression) {
                    let hit = String(text[r]).trimmingCharacters(in: .whitespaces)
                    let v = hit.dropFirst(f.count).drop { $0 == " " || $0 == "=" }
                    return String(v).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                }
            }
            return nil
        }
        // 一段一段看（; && || | 換行分開）：只認「這一段的第一個詞」真的是 agy／codex／copilot；grep agy、which codex 這種只是提到名字的不算
        let normalized = command.replacingOccurrences(of: "&&", with: ";").replacingOccurrences(of: "||", with: ";")
        // 單一個 & 也是分隔（`agy … & agy … &` 同時開好幾個）：事件那一列只取第一段，其他的交給程序掃描
        for seg in normalized.split(whereSeparator: { ";|\n&".contains($0) }) {
            let c = String(seg)
            var tokens = c.split(whereSeparator: { " \t".contains($0) }).map(String.init)
            // 跳過 VAR=值、sudo、time、nohup、exec、env 這些前綴
            while let t = tokens.first, (t.contains("=") && !t.hasPrefix("-") && !t.hasPrefix("/")) || ["sudo", "time", "nohup", "exec", "env", "command"].contains(t) { tokens.removeFirst() }
            guard let head = tokens.first.map({ ($0 as NSString).lastPathComponent }) else { continue }
            switch head {
            case "agy":
                if let m = value(after: ["--model", "-m"], in: c) {
                    // 思考強度在名字尾巴（-low／-medium／-high）：加「・低」「・中」「・高」
                    let lv = AgyBridge.level(m).map { ["low": "・低", "medium": "・中", "high": "・高"][$0] ?? "" } ?? ""
                    return AgyBridge.name(m) + lv
                }
                return "agy"
            case "codex":
                if let m = value(after: ["--model", "-m"], in: c) { return "Codex " + m }
                return "Codex"
            case "copilot": return "Copilot"
            case "python", "python3", "mlx_lm", "mlx_vlm":
                if c.contains("mlx_vlm") || c.contains("mlx_lm") { return L("本機") }
            default: break
            }
        }
        return nil
    }

    /// 子代理指定的模型（Agent 工具的 model：haiku／sonnet／opus 或完整名字）：用跟模型面板同一套名字；沒指定就是「同上」
    static func subagentModel(_ raw: Any?) -> String {
        guard let m = (raw as? String)?.trimmingCharacters(in: .whitespaces).lowercased(), !m.isEmpty, m != "inherit" else { return L("同上") }
        if let hit = ModelChoice.known.first(where: { $0.value.lowercased() == m || $0.resolved.lowercased() == m }) { return hit.name }
        let alias = ["haiku": "Haiku 5.5", "sonnet": "Sonnet 5.5", "opus": "Opus 5.5"]
        return alias[m] ?? m
    }

    /// 測試用（--state-dir 才會被呼叫）：塞假的背景項目，拍「正在跑」版面用。第 1 個背景 shell、第 2 個外部 agy，其餘是 shell
    func injectFakeForTest(_ id: UUID, count: Int) {
        var list: [RunningItem] = []
        for n in 0..<count {
            if n == 1 { list.append(RunningItem(id: "fake\(n)", text: "agy -p Argon fixes second round", since: Date().addingTimeInterval(-200), background: true, kind: "bash", pid: 1, tag: "Gemini 4 Argon・高")) }
            else { list.append(RunningItem(id: "fake\(n)", text: "sleep 600 # \(n)", since: Date().addingTimeInterval(-Double(30 + n * 20)), background: true, kind: "bash")) }
        }
        background[id] = list
    }

    func running(_ id: UUID) -> [RunningItem] {
        let fg = foreground[id] ?? []
        // 子代理還在前景跑的時候，背景清單可能也列了同一個（描述相同）：只列一次
        let fgAgents = Set(fg.filter { $0.kind == "agent" }.map(\.text))
        let events = fg + (background[id] ?? []).filter { !($0.kind == "agent" && fgAgents.contains($0.text)) }
        return events + extraScanned(id, besides: events)
    }

    /// 目前有任何執行項目（前景、背景、掃描到）的對話 id
    var activeIDs: Set<UUID> {
        var s = Set<UUID>()
        for (id, list) in foreground where !list.isEmpty { s.insert(id) }
        for (id, list) in background where !list.isEmpty { s.insert(id) }
        for (id, list) in scanned where !list.isEmpty { s.insert(id) }
        return s
    }

    // MARK: 掃程序（ProcessScan.swift）：Bash 用 `&` 丟出去的 agy／codex／copilot，事件追不到，靠掃 claude 底下的程序補上
    /// 掃到的項目（背景）
    @Published private(set) var scanned: [UUID: [RunningItem]] = [:]
    /// 每格 claude 的 pid（ChatPane 登記；沒有就不掃）
    private var pidProviders: [UUID: () -> Int32?] = [:]
    private var scanTimer: Timer?
    private let scanQueue = DispatchQueue(label: "scan-processes", qos: .utility)
    private var scanning = false

    private var stopHandlers: [UUID: (String) -> Void] = [:]
    func register(_ id: UUID, pid: @escaping () -> Int32?, stopTask: ((String) -> Void)? = nil) {
        pidProviders[id] = pid
        stopHandlers[id] = stopTask
        if scanTimer == nil {
            let t = Timer(timeInterval: Self.scanInterval, repeats: true) { [weak self] _ in self?.scanNow() }
            RunLoop.main.add(t, forMode: .common)
            scanTimer = t
        }
    }
    func unregister(_ id: UUID) {
        pidProviders[id] = nil
        stopHandlers[id] = nil
        if scanned[id] != nil { scanned[id] = nil }
        if pidProviders.isEmpty { scanTimer?.invalidate(); scanTimer = nil }
    }
    static let scanInterval: TimeInterval = 4

    /// 掃一次：沒有任何 claude 在跑就不讀程序表
    func scanNow() {
        guard !scanning else { return }
        var owners: [Int32: UUID] = [:]
        for (id, f) in pidProviders { if let p = f() { owners[p] = id } }
        guard !owners.isEmpty else {
            if !scanned.isEmpty { scanned = [:] }
            return
        }
        scanning = true
        let pids = Set(owners.keys)
        scanQueue.async { [weak self] in
            let found = ProcessScan.scan(claudePIDs: pids)
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning = false
                var next: [UUID: [RunningItem]] = [:]
                for (pid, id) in owners where self.pidProviders[id] != nil {   // 掃描途中被取消登記的不寫回
                    let old = Dictionary((self.scanned[id] ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                    next[id] = (found[pid] ?? []).map { p in
                        let key = "proc-\(p.pid)-\(Int(p.started.timeIntervalSince1970 * 1_000_000))"
                        return old[key] ?? RunningItem(id: key, text: p.command, since: p.started, background: true, kind: "bash", pid: p.pid,
                                                      tag: Self.externalModel(in: p.command) ?? (p.command.split(separator: " ").first.map { ($0 as NSString).lastPathComponent }))
                    }
                }
                if next != self.scanned { self.scanned = next }
            }
        }
    }

    // MARK: 停止一個項目（右欄「正在跑」每列右邊的 ✕）
    /// 正在停的項目（那一列變灰，過一下就移除）
    @Published private(set) var stopping: Set<String> = []

    /// 這一列能不能停：掃到的外部程序（有 pid）、事件追到的背景指令（stop_task）。主對話用 ⌃ C、子代理和前景指令不給
    func canStop(_ it: RunningItem) -> Bool {
        if it.pid != nil { return true }
        return it.background && it.kind == "bash"
    }
    /// 停掉。掃到的：核對 pid＋啟動時間再送 SIGTERM（3 秒後還活著 SIGKILL）；事件追到的背景指令：叫 Claude Code 自己的 stop_task。log 是測試用
    func stop(_ it: RunningItem, conversation id: UUID, log: ((String) -> Void)? = nil) {
        guard canStop(it), !stopping.contains(it.id) else { return }
        if let pid = it.pid {
            guard ProcessScan.stop(pid: pid, started: it.since, log: log) else {
                // 已經不在了（或 pid 被重用）：沒送任何訊號，直接把這一列拿掉
                EventLog.log("正在跑", "停止 pid \(pid)：程序已不在，直接移除項目")
                scanned[id] = (scanned[id] ?? []).filter { $0.id != it.id }
                return
            }
            EventLog.log("正在跑", "已要求停止外部程序（pid \(pid)）")
        } else if let h = stopHandlers[id] {
            h(it.id); log?("stop_task \(it.id)")
            EventLog.log("正在跑", "已送出 stop_task（項目 \(String(it.id.prefix(16)))）")
        } else {
            EventLog.log("正在跑", "無法停止項目 \(String(it.id.prefix(16)))：對話未連線")
            return
        }
        stopping.insert(it.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            self.stopping.remove(it.id)
            if self.scanned[id]?.contains(where: { $0.id == it.id }) == true { self.scanned[id] = self.scanned[id]!.filter { $0.id != it.id } }
            if self.background[id]?.contains(where: { $0.id == it.id }) == true { self.background[id] = self.background[id]!.filter { $0.id != it.id } }
        }
    }

    /// 掃到的裡面，扣掉事件已經追到的（同一個模型標籤的事件項目有幾個，就少列幾個；留下最晚啟動的）
    private func extraScanned(_ id: UUID, besides events: [RunningItem]) -> [RunningItem] {
        var tracked: [String: Int] = [:]
        for e in events where e.kind == "bash" { if let t = e.tag { tracked[t, default: 0] += 1 } }
        var result: [RunningItem] = []
        // 舊的先扣：事件追到的多半是比較早啟動的那幾個
        for it in (scanned[id] ?? []).sorted(by: { $0.since < $1.since }) {
            if let t = it.tag, let n = tracked[t], n > 0 { tracked[t] = n - 1; continue }
            result.append(it)
        }
        return result
    }

    func observe(_ o: [String: Any], conversation id: UUID?, directory: String?) {
        guard let id else { return }
        switch o["type"] as? String {
        case "assistant":
            let blocks = ((o["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
            var list = foreground[id] ?? []
            for b in blocks where b["type"] as? String == "tool_use" {
                guard let tid = b["id"] as? String, !list.contains(where: { $0.id == tid }) else { continue }
                let input = b["input"] as? [String: Any] ?? [:]
                let name = b["name"] as? String ?? ""
                switch name {
                case "Bash":
                    let command = (input["command"] as? String) ?? ""
                    // 丟到背景跑的會馬上有結果，之後改由背景清單顯示（背景清單只有描述，先記下指令）
                    if input["run_in_background"] as? Bool == true {
                        if !command.isEmpty {
                            var m = backgroundCommands[id] ?? [:]
                            if m.count > 100 { m.removeAll() }
                            // 沒寫描述的：背景清單拿指令開頭當描述，先用整段指令當 key，查的時候比開頭（Self.lookupCommand）
                            m[(input["description"] as? String) ?? command] = command
                            backgroundCommands[id] = m
                        }
                        continue
                    }
                    list.append(RunningItem(id: tid, text: command.isEmpty ? L("指令") : command, since: Date(), background: false, kind: "bash", tag: Self.externalModel(in: command)))
                case "Task", "Agent":
                    let desc = (input["description"] as? String) ?? L("子代理")
                    let tag = Self.subagentModel(input["model"])
                    var m = agentTags[id] ?? [:]
                    if m.count > 100 { m.removeAll() }
                    m[desc] = tag
                    agentTags[id] = m
                    list.append(RunningItem(id: tid, text: desc, since: Date(), background: false, kind: "agent", tag: tag))
                default: break
                }
            }
            if list != (foreground[id] ?? []) { foreground[id] = list }
        case "user":
            let blocks = ((o["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
            let done = Set(blocks.compactMap { $0["type"] as? String == "tool_result" ? $0["tool_use_id"] as? String : nil })
            if !done.isEmpty, let list = foreground[id], list.contains(where: { done.contains($0.id) }) {
                foreground[id] = list.filter { !done.contains($0.id) }
            }
        case "result":
            if foreground[id]?.isEmpty == false { foreground[id] = [] }
            if let directory { refreshGit(directory) }
        case "system":
            switch o["subtype"] as? String {
            case "background_tasks_changed":
                let old = Dictionary((background[id] ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                let tasks = (o["tasks"] as? [[String: Any]]) ?? []
                background[id] = tasks.compactMap { t in
                    guard let tid = t["task_id"] as? String, t["ambient"] as? Bool != true else { return nil }
                    let type = t["task_type"] as? String ?? ""
                    let desc = (t["description"] as? String) ?? type
                    // 背景指令：用事件給的指令（有的話），不然用先前記下的「描述 → 指令」，最後才用描述本身
                    let command = (t["command"] as? String) ?? Self.lookupCommand(desc, in: backgroundCommands[id] ?? [:]) ?? desc
                    return RunningItem(id: tid, text: desc, since: old[tid]?.since ?? Date(), background: true,
                                       kind: type == "local_bash" ? "bash" : (type == "local_agent" ? "agent" : type),
                                       tag: type == "local_bash" ? Self.externalModel(in: command) : (type == "local_agent" ? old[tid]?.tag ?? agentTags[id]?[desc] ?? L("同上") : nil))
                }
            case "vcs_state_changed":
                if let directory { refreshGit(directory) }
            default: break
            }
        default: break
        }
    }

    /// claude 結束了：它的指令也都沒了
    func clear(_ id: UUID) {
        if foreground[id]?.isEmpty == false { foreground[id] = [] }
        if background[id]?.isEmpty == false { background[id] = [] }
        if scanned[id]?.isEmpty == false { scanned[id] = [] }
    }

    /// git status 跑一次（背景），拿分支、跟遠端差幾個、改過幾個檔案
    func refreshGit(_ dir: String) {
        guard !gitLoading.contains(dir) else { return }
        gitLoading.insert(dir)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let info = Self.readGit(dir)
            DispatchQueue.main.async {
                guard let self else { return }
                self.gitLoading.remove(dir)
                if self.git[dir] == nil || self.git[dir]! != info { self.git.updateValue(info, forKey: dir) }
            }
        }
    }

    static var gitTimeout: TimeInterval = 15
    static func readGit(_ dir: String) -> GitInfo? {
        // 不執行專案設定檔指定的指令（fsmonitor、filter、textconv）；逾時整群砍掉
        let p = GitProcess.makeProcess(["-C", dir] + GitProcess.safeOptions + ["--no-optional-locks", "status", "--porcelain=v2", "--branch"])
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // 卡住（iCloud 未下載的資料夾、斷線的網路磁碟）最多等 15 秒；不然 gitLoading 一直擋著、這個資料夾的分支永遠不更新
        let watchdog = GitProcess.arm(p, after: gitTimeout)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()
        guard p.terminationStatus == 0, let s = String(data: data, encoding: .utf8), s.contains("# branch.") else { return nil }      // 沒有 branch 標頭＝git 根本沒跑起來
        var g = GitInfo(branch: "")
        for line in s.split(separator: "\n") {
            if line.hasPrefix("# branch.head ") { g.branch = String(line.dropFirst(14)) }
            else if line.hasPrefix("# branch.oid ") && g.branch.isEmpty { g.branch = String(line.dropFirst(13).prefix(7)) }
            else if line.hasPrefix("# branch.upstream ") { g.upstream = true }
            else if line.hasPrefix("# branch.ab ") {
                let parts = line.dropFirst(12).split(separator: " ")
                if parts.count == 2 { g.ahead = Int(parts[0].dropFirst()) ?? 0; g.behind = Int(parts[1].dropFirst()) ?? 0 }
            } else if !line.hasPrefix("#") { g.changed += 1 }
        }
        if g.branch == "(detached)" { g.branch = L("（沒有在分支上）") }
        return g
    }
}

/// 用量欄位裡，上下文下面那幾行
struct ActivityBlock: View {
    @Environment(\.uiScale) private var s
    @ObservedObject var store: Store
    @ObservedObject var activity = SessionActivity.shared
    private let tick = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        if let id = store.selected, let c = store.conversation(id), let dir = store.project(c.projectID)?.path {
            VStack(alignment: .leading, spacing: 6) {
                // 資料夾改放在每一格最下面的路徑列（PathBar），這裡不再列
                if let g = activity.git[dir] ?? nil {
                    row(L("分支")) {
                        HStack(spacing: 6) {
                            Text(g.branch).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                            if g.ahead > 0 { Text("↑\(g.ahead)").foregroundStyle(.secondary).help(L("有 \(g.ahead) 個 commit 還沒推上去")) }
                            if g.behind > 0 { Text("↓\(g.behind)").foregroundStyle(.secondary).help(L("遠端多了 \(g.behind) 個 commit")) }
                        }
                    }
                    if g.changed > 0 {
                        Text(L("\(g.changed) 個檔案改過還沒 commit")).font(.system(size: 11 * s)).foregroundStyle(.tertiary)
                    }
                }
                // 列這個分頁每一格在跑的，像終端機那樣用樹狀：main（主對話）、shell、agent
                let ids = (store.currentWindow?.root?.leaves ?? []).filter { store.conversation($0) != nil }
                let live = ids.filter { (store.status[$0] ?? .idle) != .idle || !activity.running($0).isEmpty }
                if !live.isEmpty {
                    Text(L("正在跑")).font(.system(size: 12 * s)).padding(.top, 4)
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(live, id: \.self) { tree($0, now: ctx.date) }
                        }
                        .font(.system(size: 10.5 * s, design: .monospaced))   // 整塊縮 1 點
                    }
                }
            }
            .font(.system(size: 12 * s))
            .padding(.top, 6)
            .onAppear { paneDirs.forEach(activity.refreshGit) }
            .onChange(of: id) { _, _ in activity.refreshGit(dir) }
            .onChange(of: paneDirs) { _, new in new.forEach(activity.refreshGit) }
            .onReceive(tick) { _ in if NSApp.isActive { paneDirs.forEach(activity.refreshGit) } }
        }
    }

    /// 這個分頁每一格的資料夾（每格的分支都要查）
    private var paneDirs: [String] {
        let ids = store.currentWindow?.root?.leaves ?? []
        var seen = Set<String>()
        return ids.compactMap { store.conversation($0).flatMap { store.project($0.projectID)?.path } }.filter { seen.insert($0).inserted }
    }

    /// 一格：標題（聊天室名字、用的模型、分支），底下 ├─ └─ 列 main、shell、agent。
    /// 每個項目最多三行（類型不要截成 sh…）：第一行類型或名字（main、shell、子代理的描述）
    /// 第二行小字：狀態 · 時間，右邊是用的模型（欄位太窄時先保留模型，狀態和時間可以被截）；第三行指令內容（滑鼠停上去看全文）
    @ViewBuilder private func tree(_ id: UUID, now: Date) -> some View {
        let c = store.conversation(id)
        let st = store.status[id] ?? .idle
        let items: [(id: String, name: String, status: String, tag: String?, text: String?, since: Date?, item: RunningItem?)] =
            (st == .idle ? [] : [("main", "main", st == .waiting ? L("等你回覆") : L("工作中"), nil, nil, store.busySince[id], nil)])
            + activity.running(id).map { it in
                let oneLine = it.text.replacingOccurrences(of: "\n", with: " ")
                // 子代理：描述就是名字（第一行）；指令：第一行 shell，內容放第三行
                return (it.id, it.kind == "agent" ? oneLine : (it.kind == "bash" ? "shell" : it.kind),
                        it.background ? L("背景") : L("執行中"), it.tag, it.kind == "agent" ? nil : oneLine, it.since, it)
            }
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(c?.title ?? "").fontWeight(.semibold).lineLimit(1).truncationMode(.tail)
                if let m = activity.modelNames[id], !m.isEmpty {
                    Text(m).font(.system(size: 9.5 * s)).foregroundStyle(.tertiary).lineLimit(1).fixedSize().layoutPriority(2)
                }
                if let dir = c.flatMap({ store.project($0.projectID)?.path }), let g = activity.git[dir] ?? nil {
                    Text("⎇ " + g.branch).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { i, l in
                let last = i == items.count - 1
                let pad = last ? "   " : "│  "
                // 點一下這一列＝跳到跑它的那一格（在獨立視窗裡的把那個視窗叫到前面）；右邊的 ✕ 停掉它（掃到的外部程序、背景指令才有）
                VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .center, spacing: 4) {
                    // 點跳格只套在左邊的文字區（名字、狀態、指令），不套在整列外層：✕ 按鈕不是它的子視圖，點 ✕ 不會同時跳格
                    Text((last ? "└─ " : "├─ ") + l.name).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).help(l.name).layoutPriority(1)   // 不讓右邊的空白先把它擠成 she…
                        .contentShape(Rectangle()).onTapGesture { store.show(id) }
                    // 高度固定 14：外層 ScrollView 撐高時，Color.clear 會把多出來的高度吃掉、列與列之間被撐開
                    Color.clear.frame(minWidth: 0, maxWidth: .infinity).frame(height: 14).contentShape(Rectangle()).onTapGesture { store.show(id) }
                    if let it = l.item, activity.canStop(it) {
                        Button { confirmStop(it, conversation: id) } label: { Image(systemName: "xmark.circle").font(.system(size: 11 * s)) }
                            .buttonStyle(.plain).foregroundStyle(.tertiary).help(L("停止這個工作"))
                    }
                }
                HStack(spacing: 0) {       // 間距 0：沒有圖示的列，「背景」才跟下一行的指令對齊
                    // 模型圖示接在樹狀線後面，欄位窄時只留圖示
                    Text(pad).fixedSize()
                    if let t = l.tag { ModelBadgeView(tag: t, scale: s, colored: true).padding(.trailing, 4 * s).layoutPriority(1) }
                    Text([l.status, l.since.map { Self.elapsed(now.timeIntervalSince($0)) }].compactMap { $0 }.joined(separator: " · "))
                        .lineLimit(1).truncationMode(.tail).layoutPriority(3)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 9.5 * s, design: .monospaced)).foregroundStyle(.tertiary).monospacedDigit()
                .contentShape(Rectangle()).onTapGesture { store.show(id) }
                if let t = l.text {
                    Text(pad + t).font(.system(size: 9.5 * s, design: .monospaced)).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.tail).help(t)
                        .contentShape(Rectangle()).onTapGesture { store.show(id) }
                }
                }
                .opacity(l.item.map { activity.stopping.contains($0.id) } == true ? 0.35 : 1)
            }
        }
    }

    /// 停之前先問：「停止 <簡稱>？」
    private func confirmStop(_ it: RunningItem, conversation id: UUID) {
        let short = it.tag.map { ModelBadge.info($0).text }.flatMap { $0.isEmpty ? nil : $0 } ?? it.tag ?? ((it.text as NSString).lastPathComponent.split(separator: " ").first.map(String.init) ?? "shell")
        let a = NSAlert()
        a.messageText = L("停止 \(short)？")
        a.informativeText = it.text.replacingOccurrences(of: "\n", with: " ").prefix(160) + ""
        a.addButton(withTitle: L("停止"))
        a.addButton(withTitle: L("取消"))
        if a.runModal() == .alertFirstButtonReturn { activity.stop(it, conversation: id) }
    }

    private func row<V: View>(_ label: String, @ViewBuilder _ v: () -> V) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer(minLength: 8)
            v()
        }
    }

    /// 終端機的寫法：12s、1m 57s、1h 2m
    static func elapsed(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }
}


/// 「正在跑」的模型標籤：廠商圖示（跟上下文欄、用量欄同一套 ModelTab 圖示）＋簡稱，文字裡不寫廠商名字
/// Gemini 4 Argon → Argon、Gemini 3.8 Flash・高 → 3.8 Flash・高、Codex gpt-6-luna → Luna 6、Claude Opus 5.5（agy 跑的 Claude）→ Claude 圖示＋Opus 5.5、
/// Copilot → 只有圖示。認不出來的照原字串（去掉廠商前綴），沒有圖示
enum ModelBadge {
    static func info(_ tag: String) -> (tab: ModelTab?, text: String) {
        let t = tag.trimmingCharacters(in: .whitespaces)
        let lower = t.lowercased()
        func rest(_ p: String) -> String { String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespaces) }
        if lower.hasPrefix("codex") { let r = rest("codex"); return (.chatgpt, r.isEmpty ? "" : gptShort(r)) }
        if lower.hasPrefix("copilot") { return (.copilot, rest("copilot")) }
        if t == L("本機") { return (.local, t) }
        if lower.hasPrefix("gemini") {
            // 只有一個整數版本號又接著名字（4 Argon）：版本號省略；3.8 Flash 這種小數版本保留
            return (.gemini, rest("gemini").replacingOccurrences(of: #"^\d+\s+(?=\D)"#, with: "", options: .regularExpression))
        }
        if lower.hasPrefix("claude") { return (.claude, rest("claude")) }
        if ["opus", "sonnet", "haiku", "fable"].contains(where: { lower.hasPrefix($0) }) { return (.claude, t) }
        if lower.hasPrefix("gpt") { return (.chatgpt, gptShort(t)) }
        if lower == "agy" { return (.gemini, "agy") }
        return (nil, t)
    }
    /// gpt-6-luna／GPT-6 Luna → Luna 6：名字在前、版本號在後
    private static func gptShort(_ raw: String) -> String {
        var t = raw.lowercased()
        if t.hasPrefix("gpt") { t = String(t.dropFirst(3)) }
        let tokens = t.split(whereSeparator: { "- ".contains($0) }).map(String.init)
        guard !tokens.isEmpty else { return raw }
        let words = tokens.filter { $0.contains { $0.isLetter } }.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        let nums = tokens.filter { !$0.contains { $0.isLetter } }
        return (words + nums).joined(separator: " ")
    }
}

struct ModelBadgeView: View {
    let tag: String
    var scale: CGFloat = 1
    var colored = false       // 單色圖示（OpenAI、Copilot、本機）也上品牌色，不跟著文字變灰
    var body: some View {
        let i = ModelBadge.info(tag)
        Group {
            if colored {
                // 放得下才顯示模型名，不留半個字；放不下只留圖示
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 3 * scale) { icon(i.tab); if !i.text.isEmpty { Text(i.text).lineLimit(1).fixedSize() } }
                    icon(i.tab)
                }
            } else {
                HStack(spacing: 3 * scale) {
                    icon(i.tab)
                    if !i.text.isEmpty { Text(i.text).lineLimit(1).truncationMode(.tail) }    // 欄位窄時文字可以縮（狀態與時間優先）
                }
            }
        }
        .help(tag)
    }
    @ViewBuilder private func icon(_ tab: ModelTab?) -> some View {
        if let tab, let img = tab.image {
            Image(nsImage: img).resizable().renderingMode(tab.monochrome ? .template : .original)
                .aspectRatio(contentMode: .fit).frame(width: 11 * scale, height: 11 * scale)
                .foregroundColor(colored ? Self.brand(tab) : nil)
        }
    }
    private static func brand(_ t: ModelTab) -> Color? {
        switch t {
        case .chatgpt: return Color(red: 0.06, green: 0.64, blue: 0.50)
        case .copilot: return Color(red: 0.51, green: 0.40, blue: 0.93)
        case .local: return .orange
        default: return nil       // Claude、Gemini 的圖本來就有顏色
        }
    }
}
