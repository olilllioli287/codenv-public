import Foundation
import Darwin

/// 右欄聊天室列表共用欄寬（以 1x UI 點數為準，由各 View 乘上 uiScale）。
enum RightPanelLayout {
    static let memoryColumnWidth: CGFloat = 42
    static let contextColumnWidth: CGFloat = 36
    static let toggleButtonsWidth: CGFloat = 42 // 兩顆 20pt 按鈕、2pt 間距
    static let chatColumnTrailingInset: CGFloat = 10
    static let dividerHitHeight: CGFloat = 8
}

// 右欄（RightPanelView.swift）背後的資料來源：跑外部指令、監聽中的連接埠、檔案樹與搜尋、git 狀態、歷史全文搜尋。
// 全部在背景執行、有逾時；畫面只讀這些物件的 @Published 欄位。

/// 取消旗標（背景工作每個段落檢查一次）
final class RPCancel {
    private let lock = NSLock()
    private var flag = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func cancel() { lock.lock(); flag = true; lock.unlock() }
}

enum RPShell {
    struct Result {
        var out: String
        var status: Int32
        var timedOut: Bool
    }

    /// 同步跑一個外部指令（呼叫的人要在背景）。逾時就結束它；輸出超過 maxBytes 也結束（避免 diff 太大）
    static func run(_ exe: String, _ args: [String], cwd: String? = nil, timeout: TimeInterval = 8, maxBytes: Int = 600_000) -> Result {
        let p = GitProcess.wrap(exe, args)      // 自己一個 process group：逾時／輸出太大時整群結束（子程序不會握著管線不放）
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"      // 讀狀態不要去搶 index.lock，免得擋住使用者自己的 git
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "en_US.UTF-8"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return Result(out: "", status: -1, timedOut: false) }
        var timedOut = false
        let kill = GitProcess.arm(p, after: timeout) { timedOut = true }
        var data = Data()
        let h = pipe.fileHandleForReading
        while true {
            let chunk = h.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
            if data.count > maxBytes { GitProcess.terminateGroup(p); break }
        }
        p.waitUntilExit()
        kill.cancel()
        return Result(out: String(decoding: data, as: UTF8.self), status: p.terminationStatus, timedOut: timedOut)
    }

    static func git(_ args: [String], cwd: String, timeout: TimeInterval = 8, maxBytes: Int = 600_000) -> Result {
        // 專案資料夾裡的 .git/config、.gitattributes 可能是被注入的 Claude 寫的：背景自動跑的 git 不執行 fsmonitor、外部 diff、textconv 指定的指令
        run("/usr/bin/git", ["-c", "core.quotepath=false"] + GitProcess.safeOptions + args, cwd: cwd, timeout: timeout, maxBytes: maxBytes)
    }
}

// MARK: 監聽中的連接埠

final class PortsMonitor: ObservableObject {
    static let shared = PortsMonitor()

    struct Entry: Identifiable, Hashable {
        let pid: Int32
        let name: String
        let port: Int
        let address: String
        let ours: Bool          // 屬於 codenv 的子程序樹
        var id: String { "\(pid):\(port):\(address)" }
    }

    @Published private(set) var entries: [Entry] = []
    private var last = Date.distantPast
    private var busy = false

    /// 10 秒內不重查（force 除外）
    func refresh(force: Bool = false) {
        guard !busy, force || Date().timeIntervalSince(last) >= 10 else { return }
        busy = true
        let me = getpid()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let r = RPShell.run("/usr/sbin/lsof", ["+c", "0", "-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"], timeout: 6)
            var ours = Set<pid_t>([me])
            MemoryMonitor.descendants(of: me).forEach { ours.insert($0) }
            let list = Self.parse(r.out, ours: ours)
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.last = Date()
                if self.entries != list { self.entries = list }
            }
        }
    }

    static func parse(_ text: String, ours: Set<pid_t>) -> [Entry] {
        var pid: Int32 = 0
        var name = ""
        var seen = Set<String>()
        var out: [Entry] = []
        for line in text.split(separator: "\n") {
            guard let k = line.first else { continue }
            let v = String(line.dropFirst())
            switch k {
            case "p": pid = Int32(v) ?? 0
            case "c": name = v
            case "n":
                guard let colon = v.lastIndex(of: ":"), let port = Int(v[v.index(after: colon)...]) else { continue }
                let addr = String(v[..<colon])
                let e = Entry(pid: pid, name: name, port: port, address: addr, ours: ours.contains(pid))
                if seen.insert("\(pid):\(port)").inserted { out.append(e) }
            default: break
            }
        }
        return out.sorted { $0.port < $1.port }
    }
}

// MARK: 檔案樹

final class FileTreeModel: ObservableObject {
    struct Node: Identifiable, Hashable {
        let path: String
        let name: String
        let isDir: Bool
        let depth: Int
        var id: String { path }
    }

    static let skipped: Set<String> = [".git", "node_modules", ".build", ".DS_Store"]

    @Published private(set) var rows: [Node] = []
    private(set) var root: String?
    private var expanded = Set<String>()
    private var cache: [String: [(name: String, isDir: Bool)]] = [:]

    func setRoot(_ path: String?) {
        guard path != root else { return }
        root = path
        expanded = []
        cache = [:]
        rebuild()
    }

    func isExpanded(_ n: Node) -> Bool { expanded.contains(n.path) }

    func toggle(_ n: Node) {
        guard n.isDir else { return }
        if expanded.contains(n.path) { expanded.remove(n.path) } else { expanded.insert(n.path) }
        rebuild()
    }

    func reload() {
        cache = [:]
        rebuild()
    }

    private func list(_ dir: String) -> [(name: String, isDir: Bool)] {
        if let c = cache[dir] { return c }
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { !Self.skipped.contains($0) }
        var items: [(name: String, isDir: Bool)] = []
        for n in names {
            var d: ObjCBool = false
            fm.fileExists(atPath: (dir as NSString).appendingPathComponent(n), isDirectory: &d)
            items.append((n, d.boolValue))
        }
        items.sort { a, b in a.isDir != b.isDir ? a.isDir : a.name.localizedStandardCompare(b.name) == .orderedAscending }
        if items.count > 2000 { items = Array(items.prefix(2000)) }
        cache[dir] = items
        return items
    }

    private func rebuild() {
        guard let root else { rows = []; return }
        var out: [Node] = []
        func walk(_ dir: String, _ depth: Int) {
            for it in list(dir) {
                let p = (dir as NSString).appendingPathComponent(it.name)
                out.append(Node(path: p, name: it.name, isDir: it.isDir, depth: depth))
                if it.isDir, expanded.contains(p) { walk(p, depth + 1) }
            }
        }
        walk(root, 0)
        rows = out
    }
}

// MARK: 檔案搜尋（檔名／內容）

final class FileSearchModel: ObservableObject {
    struct Hit: Identifiable, Hashable {
        let path: String
        let rel: String
        let line: Int?
        let text: String?
        var id: String { "\(path):\(line ?? 0):\(text ?? "")" }
    }

    static let limit = 200
    @Published private(set) var hits: [Hit] = []
    @Published private(set) var running = false
    @Published private(set) var note = ""
    private var cancel: RPCancel?
    private var generation = 0

    func clear() {
        cancel?.cancel()
        generation += 1
        hits = []; running = false; note = ""
    }

    func search(_ query: String, content: Bool, root: String?) {
        cancel?.cancel()
        generation += 1
        let gen = generation
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let root, !q.isEmpty else { hits = []; running = false; note = ""; return }
        let flag = RPCancel()
        cancel = flag
        running = true
        note = ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (list, note) = content ? Self.contentSearch(q, root: root, cancel: flag) : Self.nameSearch(q, root: root, cancel: flag)
            DispatchQueue.main.async {
                guard let self, self.generation == gen, !flag.isCancelled else { return }
                self.hits = list; self.running = false; self.note = note
            }
        }
    }

    static func nameSearch(_ q: String, root: String, cancel: RPCancel) -> ([Hit], String) {
        let fm = FileManager.default
        var out: [Hit] = []
        let deadline = Date().addingTimeInterval(6)
        guard let en = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants]) else { return ([], "") }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        var truncated = false
        while let u = en.nextObject() as? URL {
            if cancel.isCancelled { return ([], "") }
            let name = u.lastPathComponent
            if FileTreeModel.skipped.contains(name) { en.skipDescendants(); continue }
            if name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                let p = u.path
                out.append(Hit(path: p, rel: p.hasPrefix(prefix) ? String(p.dropFirst(prefix.count)) : p, line: nil, text: nil))
                if out.count >= limit { truncated = true; break }
            }
            if Date() > deadline { truncated = true; break }
        }
        return (out, truncated ? L("只列前 \(out.count) 筆") : "")
    }

    static func contentSearch(_ q: String, root: String, cancel: RPCancel) -> ([Hit], String) {
        let rg = ["/opt/homebrew/bin/rg", "/usr/local/bin/rg"].first { FileManager.default.isExecutableFile(atPath: $0) }
        let r: RPShell.Result
        if let rg {
            r = RPShell.run(rg, ["--no-heading", "--line-number", "--color", "never", "--smart-case", "--fixed-strings", "--max-count", "3",
                                  "--max-columns", "240", "--max-filesize", "2M", "-g", "!.git", "-g", "!node_modules", "-g", "!.build", "-e", q, "--", "."],
                            cwd: root, timeout: 10, maxBytes: 400_000)
        } else {
            r = RPShell.run("/usr/bin/grep", ["-rIn", "-F", "-i", "--exclude-dir=.git", "--exclude-dir=node_modules", "--exclude-dir=.build", "-m", "3", "--", q, "."],
                            cwd: root, timeout: 10, maxBytes: 400_000)
        }
        var out: [Hit] = []
        for line in r.out.split(separator: "\n") {
            if cancel.isCancelled { return ([], "") }
            // 路徑:行號:內容
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let n = Int(parts[1]) else { continue }
            var rel = String(parts[0])
            if rel.hasPrefix("./") { rel = String(rel.dropFirst(2)) }
            let text = String(parts[2]).trimmingCharacters(in: .whitespaces)
            out.append(Hit(path: (root as NSString).appendingPathComponent(rel), rel: rel, line: n, text: String(text.prefix(160))))
            if out.count >= limit { break }
        }
        var note = ""
        if out.count >= limit || r.timedOut { note = L("只列前 \(out.count) 筆") }
        if rg == nil { note = (note.isEmpty ? "" : note + " · ") + L("沒有 rg，改用 grep") }
        return (out, note)
    }
}

// MARK: git

final class GitPanelModel: ObservableObject {
    enum Kind: String { case staged, unstaged, untracked }
    struct Change: Identifiable, Hashable {
        let kind: Kind
        let code: String       // M、A、D、R、?…
        let path: String
        var id: String { "\(kind.rawValue):\(path)" }
    }
    struct Tree: Identifiable, Hashable {
        let path: String
        let branch: String
        let isCurrent: Bool
        var id: String { path }
    }

    @Published private(set) var isRepo: Bool?          // nil＝還沒查
    @Published private(set) var branch = ""
    @Published private(set) var changes: [Change] = []
    @Published private(set) var worktrees: [Tree] = []
    @Published private(set) var diff = ""
    @Published private(set) var diffNote = ""
    @Published private(set) var loading = false
    @Published var selected: Change?

    private(set) var project: String?
    private var top: String?
    private var generation = 0

    func setProject(_ path: String?) {
        guard path != project else { return }
        project = path
        selected = nil; diff = ""; diffNote = ""
        top = nil; isRepo = nil; changes = []; worktrees = []; branch = ""
        refresh()
    }

    func refresh() {
        generation += 1
        let gen = generation
        guard let path = project else { return }
        loading = true
        let sel = selected
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let topR = RPShell.git(["rev-parse", "--show-toplevel"], cwd: path, timeout: 5)
            let topDir = topR.out.trimmingCharacters(in: .whitespacesAndNewlines)
            guard topR.status == 0, !topDir.isEmpty else {
                DispatchQueue.main.async {
                    guard let self, self.generation == gen else { return }
                    self.isRepo = false; self.loading = false; self.changes = []; self.worktrees = []; self.top = nil
                }
                return
            }
            let st = RPShell.git(["status", "--porcelain=v1", "-b"], cwd: topDir)
            let wt = RPShell.git(["worktree", "list", "--porcelain"], cwd: topDir, timeout: 5)
            if st.timedOut {
                DispatchQueue.main.async {
                    guard let self, self.generation == gen else { return }
                    self.isRepo = true; self.branch = L("git status 逾時"); self.changes = []; self.worktrees = []; self.top = topDir; self.loading = false
                }
                return
            }
            let (branch, changes) = Self.parseStatus(st.out)
            let trees = Self.parseWorktrees(wt.out, current: topDir)
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.top = topDir
                self.isRepo = true
                self.branch = branch
                self.changes = changes
                self.worktrees = trees
                self.loading = false
                if let sel, let again = changes.first(where: { $0.id == sel.id }) { self.selected = again; self.loadDiff(again) }
                else if sel != nil { self.selected = nil; self.diff = ""; self.diffNote = "" }
            }
        }
    }

    func select(_ c: Change) {
        selected = c
        loadDiff(c)
    }

    private func loadDiff(_ c: Change) {
        guard let top else { return }
        let gen = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r: RPShell.Result
            switch c.kind {
            case .staged: r = RPShell.git(["diff", "--cached", "--no-color", "--no-ext-diff", "--no-textconv", "--", c.path], cwd: top, maxBytes: 300_000)
            case .unstaged: r = RPShell.git(["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--", c.path], cwd: top, maxBytes: 300_000)
            case .untracked:
                var d: ObjCBool = false
                if FileManager.default.fileExists(atPath: (top as NSString).appendingPathComponent(c.path), isDirectory: &d), d.boolValue {
                    r = RPShell.Result(out: "", status: 0, timedOut: false)
                } else {
                    r = RPShell.git(["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-index", "--", "/dev/null", c.path], cwd: top, maxBytes: 300_000)
                }
            }
            DispatchQueue.main.async {
                guard let self, self.selected?.id == c.id, self.generation == gen else { return }
                self.diff = r.out
                self.diffNote = r.timedOut ? L("逾時，只顯示一部分") : (r.out.isEmpty ? L("沒有可顯示的差異（新資料夾或二進位檔）") : "")
            }
        }
    }

    static func parseStatus(_ text: String) -> (String, [Change]) {
        var branch = ""
        var out: [Change] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if line.hasPrefix("## ") {
                var b = String(line.dropFirst(3))
                if let r = b.range(of: "...") { b = String(b[..<r.lowerBound]) }
                if b.hasPrefix("No commits yet on ") { b = String(b.dropFirst("No commits yet on ".count)) }
                if let r = b.range(of: " [") { b = String(b[..<r.lowerBound]) }
                branch = b == "HEAD (no branch)" ? L("（沒有在分支上）") : b
                continue
            }
            guard line.count > 3 else { continue }
            let x = line[line.startIndex], y = line[line.index(after: line.startIndex)]
            var path = String(line.dropFirst(3))
            if let r = path.range(of: " -> ") { path = String(path[r.upperBound...]) }
            if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 { path = String(path.dropFirst().dropLast()) }
            if x == "?" && y == "?" { out.append(Change(kind: .untracked, code: "?", path: path)); continue }
            if x != " " { out.append(Change(kind: .staged, code: String(x), path: path)) }
            if y != " " { out.append(Change(kind: .unstaged, code: String(y), path: path)) }
        }
        return (branch, out)
    }

    static func parseWorktrees(_ text: String, current: String) -> [Tree] {
        var out: [Tree] = []
        var path = "", branch = ""
        func flush() {
            if !path.isEmpty { out.append(Tree(path: path, branch: branch.isEmpty ? L("（沒有在分支上）") : branch, isCurrent: path == current)) }
            path = ""; branch = ""
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("worktree ") { path = String(line.dropFirst(9)) }
            else if line.hasPrefix("branch ") { branch = String(line.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "") }
            else if line == "bare" { branch = "(bare)" }
        }
        flush()
        return out
    }
}

// MARK: 歷史全文搜尋

final class HistorySearchModel: ObservableObject {
    struct Hit: Identifiable, Hashable {
        let id = UUID()
        let conversation: UUID
        let title: String
        let role: String        // user／assistant
        let snippet: String
    }
    struct Target {
        let id: UUID
        let title: String
        let url: URL
    }

    static let limit = 200
    static let perChat = 8
    @Published private(set) var hits: [Hit] = []
    @Published private(set) var running = false
    @Published private(set) var scanned = 0
    @Published private(set) var total = 0
    /// 走全文索引（codenv-todo search）時為真：total 是索引裡的聊天室數，不是「已掃幾個」
    @Published private(set) var indexed = false
    /// 正在用全文索引搜尋（第一次要建索引，可能一分鐘左右；在背景跑，不卡畫面）
    @Published private(set) var usingIndex = false
    private var cancel: RPCancel?
    private var generation = 0

    func stop() {
        cancel?.cancel()
        generation += 1
        running = false
        usingIndex = false
    }

    func clear() { stop(); hits = []; scanned = 0; total = 0; indexed = false; usingIndex = false }

    /// convs：這個總指揮底下所有聊天室的 id（索引搜尋用，含非 Claude 的）；targets：索引用不了時退回逐檔掃描（只掃 Claude 的）
    func search(_ query: String, targets: [Target], convs: [UUID] = []) {
        cancel?.cancel()
        generation += 1
        let gen = generation
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        hits = []; scanned = 0; total = targets.count; indexed = false; usingIndex = false
        guard !q.isEmpty else { running = false; return }
        let flag = RPCancel()
        cancel = flag
        running = true
        if !convs.isEmpty, SearchIndexClient.available {
            usingIndex = true
            let titles = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0.title) })
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let r = SearchIndexClient.search(q, convs: convs, limit: Self.limit, cancel: flag)
                DispatchQueue.main.async {
                    guard let self, self.generation == gen, !flag.isCancelled else { return }
                    self.usingIndex = false
                    if let r {
                        self.indexed = true
                        self.total = r.chats
                        self.scanned = r.chats
                        self.hits = r.hits.map { Hit(conversation: $0.conv, title: $0.chat.isEmpty ? (titles[$0.conv] ?? "") : $0.chat, role: $0.role, snippet: $0.snippet) }
                        self.running = false
                    } else {
                        self.scanFiles(q, targets: targets, gen: gen, flag: flag)    // 索引用不了（指令壞了、python 不在）：退回逐檔掃描
                    }
                }
            }
            return
        }
        scanFiles(q, targets: targets, gen: gen, flag: flag)
    }

    private func scanFiles(_ q: String, targets: [Target], gen: Int, flag: RPCancel) {
        total = targets.count
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var all: [Hit] = []
            for (i, t) in targets.enumerated() {
                if flag.isCancelled || all.count >= Self.limit { break }
                all += Self.scan(t, query: q, room: min(Self.perChat, Self.limit - all.count), cancel: flag)
                let done = i + 1
                DispatchQueue.main.async {
                    guard let self, self.generation == gen, !flag.isCancelled else { return }
                    self.scanned = done
                    self.hits = all
                }
            }
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.running = false
                if !flag.isCancelled { self.hits = all }
            }
        }
    }

    /// 掃一個聊天室的紀錄檔（jsonl）：只看 user／assistant 的文字
    static func scan(_ t: Target, query q: String, room: Int, cancel: RPCancel) -> [Hit] {
        guard let data = try? Data(contentsOf: t.url, options: .mappedIfSafe) else { return [] }
        let variants = Set([q, q.lowercased(), q.uppercased()]).map { Data($0.utf8) }
        var out: [Hit] = []
        for raw in data.split(separator: 0x0a) {
            if out.count >= room || cancel.isCancelled { break }
            // 先用位元組粗篩，省掉大部分 JSON 解析
            guard variants.contains(where: { raw.range(of: $0) != nil }) else { continue }
            guard let o = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
                  let type = o["type"] as? String, type == "user" || type == "assistant",
                  (o["isMeta"] as? Bool) != true,
                  let msg = o["message"] as? [String: Any] else { continue }
            let text = Self.plainText(msg["content"])
            guard let r = text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
            out.append(Hit(conversation: t.id, title: t.title, role: type, snippet: Self.snippet(text, around: r)))
        }
        return out
    }

    static func plainText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        guard let arr = content as? [[String: Any]] else { return "" }
        return arr.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
    }

    static func snippet(_ text: String, around r: Range<String.Index>) -> String {
        let lo = text.index(r.lowerBound, offsetBy: -36, limitedBy: text.startIndex) ?? text.startIndex
        let hi = text.index(r.upperBound, offsetBy: 60, limitedBy: text.endIndex) ?? text.endIndex
        var s = String(text[lo..<hi]).replacingOccurrences(of: "\n", with: " ")
        if lo > text.startIndex { s = "…" + s }
        if hi < text.endIndex { s += "…" }
        return s
    }
}
