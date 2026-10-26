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

    func running(_ id: UUID) -> [RunningItem] { (foreground[id] ?? []) + (background[id] ?? []) }

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
                    // 丟到背景跑的會馬上有結果，之後改由背景清單顯示
                    if input["run_in_background"] as? Bool == true { continue }
                    list.append(RunningItem(id: tid, text: (input["command"] as? String) ?? L("指令"), since: Date(), background: false, kind: "bash"))
                case "Task", "Agent":
                    list.append(RunningItem(id: tid, text: (input["description"] as? String) ?? L("子代理"), since: Date(), background: false, kind: "agent"))
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
                    return RunningItem(id: tid, text: (t["description"] as? String) ?? type, since: old[tid]?.since ?? Date(), background: true,
                                       kind: type == "local_bash" ? "bash" : (type == "local_agent" ? "agent" : type))
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
                if self.git[dir] == nil || self.git[dir]! != info { self.git[dir] = info }
            }
        }
    }

    private static func readGit(_ dir: String) -> GitInfo? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir, "--no-optional-locks", "status", "--porcelain=v2", "--branch"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, let s = String(data: data, encoding: .utf8) else { return nil }
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
                // 使用者 10/24：列這個分頁每一格在跑的，像終端機那樣用樹狀：main（主對話）、shell、agent
                let ids = (store.currentWindow?.root?.leaves ?? []).filter { store.conversation($0) != nil }
                let live = ids.filter { (store.status[$0] ?? .idle) != .idle || !activity.running($0).isEmpty }
                if !live.isEmpty {
                    Text(L("正在跑")).font(.system(size: 12 * s)).padding(.top, 4)
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(live, id: \.self) { tree($0, now: ctx.date) }
                        }
                        .font(.system(size: 11.5 * s, design: .monospaced))
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

    /// 一格：標題（＋分支），底下 ├─ └─ 列 main、shell、agent；指令內容放下一行
    @ViewBuilder private func tree(_ id: UUID, now: Date) -> some View {
        let c = store.conversation(id)
        let st = store.status[id] ?? .idle
        let lines: [(id: String, kind: String, note: String?, text: String?, since: Date?)] =
            (st == .idle ? [] : [("main", "main", st == .waiting ? L("等你回覆") : L("工作中"), nil, store.busySince[id])])
            + activity.running(id).map { it in
                (it.id, it.kind == "bash" ? "shell" : it.kind, it.background ? L("背景") : nil,
                 it.text.replacingOccurrences(of: "\n", with: " "), it.since)
            }
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(c?.title ?? "").fontWeight(.semibold).lineLimit(1).truncationMode(.tail)
                if let dir = c.flatMap({ store.project($0.projectID)?.path }), let g = activity.git[dir] ?? nil {
                    Text("⎇ " + g.branch).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
            }
            ForEach(Array(lines.enumerated()), id: \.element.id) { i, l in
                let last = i == lines.count - 1
                HStack(spacing: 0) {
                    Text((last ? "└─ " : "├─ ") + l.kind).foregroundStyle(.secondary)
                    if let n = l.note { Text(" " + n).foregroundStyle(.tertiary) }
                    Spacer(minLength: 6)
                    if let t = l.since { Text(Self.elapsed(now.timeIntervalSince(t))).monospacedDigit().foregroundStyle(.tertiary) }
                }
                .lineLimit(1)
                if let t = l.text {
                    Text((last ? "   " : "│  ") + t).lineLimit(1).truncationMode(.tail).help(t)
                }
            }
        }
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
