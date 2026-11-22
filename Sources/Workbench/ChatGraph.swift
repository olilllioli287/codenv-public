import AppKit
import Combine
import SwiftUI

// 右欄「視窗」分頁的關聯圖（Obsidian 式）：中心＝總指揮聊天室、中型節點＝區、小節點＝聊天室。
// 全部用 AppKit 自畫（NSView.draw）＋自己的力導向佈局，沒有引進套件。
// 省電：佈局穩定後不再計算；只有「在畫面上、App 在前景、有工作中的聊天室（呼吸）或佈局還在動」才有計時器。

/// 改寫與參考自 agent-orchestrator（Apache-2.0）與 edict（MIT）：
/// 關聯圖上的工作分配資訊（工作名稱、四階段狀態、經過時間、最後工具動作、指派者）。
struct GraphAssignment: Equatable {
    enum Stage: String, Equatable {
        case dispatched // 剛派出去（收到派工、還沒開始輸出，≤60 秒）：橘
        case working    // 工作中：綠色呼吸
        case review     // 做完等總指揮看（工作結束後尚未回覆／驗收）：藍
        case stuck      // 卡住（CommanderStuck 判定）：紅

        var label: String {
            switch self {
            case .dispatched: return "剛派出去"
            case .working: return "工作中"
            case .review: return "待驗收"
            case .stuck: return "卡住"
            }
        }
    }
    var taskTitle: String
    var shortTitle: String
    var stage: Stage
    var elapsedSeconds: Int
    var elapsedText: String
    var lastAction: String
    var assignerName: String
    var assignerID: UUID?
    var activeDispatch: Bool
    var dispatchClosedReason: String?

    static func shorten(_ raw: String, limit: Int = 12) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count > limit else { return s }
        return String(s.prefix(max(1, limit - 1))) + "…"
    }

    static func formatElapsed(_ sec: Int) -> String {
        let s = max(1, sec)
        if s < 60 { return "\(s) 秒" }
        let m = s / 60
        if m < 60 { return "\(m) 分鐘" }
        let h = m / 60, rm = m % 60
        return rm > 0 ? "\(h) 小時 \(rm) 分" : "\(h) 小時"
    }
}

struct GraphNodeInfo {
    enum Kind { case center, area, chat }
    let id: UUID
    let kind: Kind
    var title: String
    var parent: UUID?
    let state: RPState
    let context: Int?
    let placed: Bool
    let hue: CGFloat
    var rawTitle: String = ""
    var isAreaLead: Bool = false
    var areaGroupID: UUID? = nil
    var representedConversationID: UUID? = nil
    var areaLeadID: UUID? = nil
    var areaLeadName: String? = nil
    var assignment: GraphAssignment? = nil
}

struct GraphSnapshot {
    var sessionID: UUID?
    var name: String
    var nodes: [GraphNodeInfo]
    /// 結構（誰連誰）的指紋：沒變就只更新顏色大小，不重跑佈局
    var signature: Int
    var layout: GraphLayoutSettings
}

extension GraphLayoutSettings {
    static func linkLength(parent: GraphNodeInfo.Kind, child: GraphNodeInfo.Kind, settings: GraphLayoutSettings) -> Double {
        switch (parent, child) {
        case (.center, .area): return settings.commanderToArea
        case (.area, .area): return settings.areaToSubarea
        case (.area, .chat), (.center, .chat): return settings.areaToChat
        default: return settings.areaToChat
        }
    }
}

extension RPData {
    static func graph(_ store: Store, workspace: Workspace) -> GraphSnapshot? {
        guard let s = store.currentSessionLayout, s.groups != nil else { return nil }
        let ctx = ContextMonitor.shared.tokens
        let centerID = s.chief ?? s.id
        let nodes = store.areaNodes(s)
        let live = store.conversations(inCommander: s).filter { Store.isChat($0) && !$0.isBrowser && !$0.isGadget && $0.draft != true && !store.isArchived($0) }
        let leadsByArea = Dictionary(uniqueKeysWithValues: nodes.compactMap { area -> (UUID, Conversation)? in
            GraphAssignmentTracker.shared.activeAreaLead(for: area.group, live: live, store: store).map { (area.group.id, $0) }
        })
        var graphAreaIDs: [UUID: UUID] = [:]
        for area in nodes { graphAreaIDs[area.group.id] = leadsByArea[area.group.id]?.id ?? area.group.id }
        let areaLeadIDs = Set(leadsByArea.values.map(\.id))
        var out: [GraphNodeInfo] = []
        let chief = s.chief.flatMap { store.conversation($0) }
        out.append(GraphNodeInfo(id: centerID, kind: .center, title: chief?.title ?? s.name,
                                 parent: nil, state: s.chief.map { graphState($0, store: store, workspace: workspace) } ?? .asleep,
                                 context: s.chief.flatMap { ctx[$0] }, placed: true, hue: 0))
        // 區：第一層的區各一種色相，底下的區沿用
        var hueOf: [UUID: CGFloat] = [:]
        var first = 0
        for n in nodes {
            let h: CGFloat
            if let p = n.parent, let ph = hueOf[p] { h = ph } else { h = (0.08 + CGFloat(first) * 0.137).truncatingRemainder(dividingBy: 1); first += 1 }
            hueOf[n.group.id] = h
            let lead = leadsByArea[n.group.id]
            let label = lead.map { "\(n.group.name)（區長：\($0.title)）" } ?? n.group.name
            out.append(GraphNodeInfo(id: graphAreaIDs[n.group.id] ?? n.group.id, kind: .area, title: label,
                                     parent: n.parent.flatMap { graphAreaIDs[$0] } ?? centerID,
                                     state: lead.map { graphState($0.id, store: store, workspace: workspace) } ?? .idle,
                                     context: lead.flatMap { ctx[$0.id] }, placed: true, hue: h,
                                     rawTitle: lead?.title ?? n.group.name, isAreaLead: lead != nil,
                                     areaGroupID: n.group.id, representedConversationID: lead?.id,
                                     areaLeadID: lead?.id, areaLeadName: lead?.title))
        }
        for c in live where c.id != s.chief && !areaLeadIDs.contains(c.id) {
            let a = store.areaID(of: c, in: nodes)
            out.append(GraphNodeInfo(id: c.id, kind: .chat, title: c.title, parent: a.flatMap { graphAreaIDs[$0] } ?? centerID,
                                     state: graphState(c.id, store: store, workspace: workspace), context: ctx[c.id],
                                     placed: store.locate(c.id) != nil, hue: a.flatMap { hueOf[$0] } ?? 0))
        }
        GraphAssignmentTracker.shared.enrich(&out, session: s, areas: nodes, live: live, centerID: centerID, chief: chief, store: store, workspace: workspace)
        var h = Hasher()
        h.combine(s.id)
        for n in out { h.combine(n.id); h.combine(n.parent) }
        return GraphSnapshot(sessionID: s.id, name: s.name, nodes: out, signature: h.finalize(), layout: s.graphLayout ?? .defaults)
    }
}

/// 改寫與參考自 agent-orchestrator（Apache-2.0）與 edict（MIT）：
/// 整合 Store、collab.json、對話紀錄 JSONL 與 CommanderStuck，提供關聯圖的工作分配、階段顏色與最後工具動作。
final class GraphAssignmentTracker {
    static let shared = GraphAssignmentTracker()

    struct Seed {
        var taskTitle: String?
        var stage: GraphAssignment.Stage?
        var dispatchedAt: Date?
        var lastAction: String?
        var assignerName: String?
        var assignerID: UUID?
    }

    private struct TranscriptScan {
        var mtime: Date
        var size: Int
        var scannedAt: Date
        var dispatchSender: String?
        var dispatchFromLead: Bool = false
        var dispatchSentence: String?
        var dispatchTime: Date?
        var hasOutputAfterDispatch: Bool = false
        var finishedAfterDispatch: Bool = false
        var lastToolAction: String?
    }

    private var seeds: [UUID: Seed] = [:]
    private var transcriptCache: [URL: TranscriptScan] = [:]
    private var cachedGoals: [CollabGoal] = []
    private var cachedCollabURL: URL?
    private var cachedCollabMtime: Date?
    private var cachedGoalsLoaded = false
    private let transcriptRescanInterval: TimeInterval = 1
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    func seed(_ id: UUID, taskTitle: String? = nil, stage: GraphAssignment.Stage? = nil, dispatchedAt: Date? = nil, lastAction: String? = nil, assignerName: String? = nil, assignerID: UUID? = nil) {
        seeds[id] = Seed(taskTitle: taskTitle, stage: stage, dispatchedAt: dispatchedAt, lastAction: lastAction, assignerName: assignerName, assignerID: assignerID)
    }

    func clearSeeds() { seeds.removeAll() }

    /// 判斷這個區是否有有效的區長聊天室（直接隸屬該區、未封存、Claude 模型）。
    func activeAreaLead(for group: ConvGroup, live: [Conversation], store: Store) -> Conversation? {
        guard let lid = group.areaLeadID,
              let c = live.first(where: { $0.id == lid }),
              store.groupOf(c) == group.id,
              !store.isArchived(c),
              c.modelCategory == "claude" else { return nil }
        return c
    }

    func enrich(_ out: inout [GraphNodeInfo], session: SessionLayout, areas: [AreaNode], live: [Conversation], centerID: UUID, chief: Conversation?, store: Store, workspace: Workspace, now: Date = Date()) {
        for i in out.indices {
            if out[i].rawTitle.isEmpty { out[i].rawTitle = out[i].title }
        }
        let goals = loadGoalsIfNeeded()
        let activeTranscripts = Set(live.compactMap { transcriptURL(for: $0, store: store) })
        transcriptCache = transcriptCache.filter { activeTranscripts.contains($0.key) }
        var leadByArea: [UUID: Conversation] = [:]
        var leadIDs = Set<UUID>()
        var graphAreaIDs: [UUID: UUID] = [:]
        for node in out where node.kind == .area {
            graphAreaIDs[node.areaGroupID ?? node.id] = node.id
        }
        for a in areas {
            if let g = store.group(a.group.id) ?? Optional(a.group),
               let lead = activeAreaLead(for: g, live: live, store: store) {
                leadByArea[a.group.id] = lead
                leadIDs.insert(lead.id)
            }
        }
        for i in out.indices {
            switch out[i].kind {
            case .center:
                break
            case .area:
                let areaID = out[i].areaGroupID ?? out[i].id
                if let lead = leadByArea[areaID] {
                    let areaName = store.group(areaID)?.name ?? out[i].title
                    out[i].areaLeadID = lead.id
                    out[i].areaLeadName = lead.title
                    out[i].isAreaLead = true
                    out[i].representedConversationID = lead.id
                    out[i].rawTitle = lead.title
                    out[i].title = "\(areaName)（區長：\(lead.title)）"
                }
            case .chat:
                if leadIDs.contains(out[i].id) {
                    out[i].isAreaLead = true
                }
                guard let c = live.first(where: { $0.id == out[i].id }) else { continue }
                let areaID = store.areaID(of: c, in: areas)
                let areaLead = areaID.flatMap { leadByArea[$0] }
                if let areaID {
                    out[i].parent = graphAreaIDs[areaID] ?? areaID
                } else if let areaLead, areaLead.id != c.id {
                    out[i].parent = areaLead.id
                }
                if let assign = resolveAssignment(for: c, state: out[i].state, session: session, areaLead: areaLead, chief: chief, centerID: centerID, store: store, goals: goals, now: now) {
                    out[i].assignment = assign
                }
            }
        }
    }

    private func loadGoalsIfNeeded() -> [CollabGoal] {
        let url = CollabBoardModel.todoFile
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if !cachedGoalsLoaded || url != cachedCollabURL || mtime != cachedCollabMtime {
            cachedGoalsLoaded = true
            cachedCollabURL = url
            cachedCollabMtime = mtime
            cachedGoals = mtime == nil ? [] : CollabBoardModel.loadTodos().1
        }
        return cachedGoals
    }

    private func transcriptURL(for c: Conversation, store: Store) -> URL? {
        let path = store.workingDirectory(for: c)
        return ContextMonitor.transcript(c, path: path)
    }

    private func scanTranscript(for c: Conversation, store: Store, now: Date) -> TranscriptScan? {
        guard let url = transcriptURL(for: c, store: store) else { return nil }
        guard let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let mtime = vals.contentModificationDate,
              let size = vals.fileSize, size > 0 else {
            transcriptCache.removeValue(forKey: url)
            return nil
        }
        if let cached = transcriptCache[url], cached.mtime == mtime, cached.size == size {
            return cached
        }
        if let cached = transcriptCache[url] {
            let age = now.timeIntervalSince(cached.scannedAt)
            if age >= 0 && age < transcriptRescanInterval { return cached }
        }
        guard let text = ModelCarry.readLines(url, tail: 65536)?.text else { return nil }
        var scan = TranscriptScan(mtime: mtime, size: size, scannedAt: now)
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = obj["type"] as? String,
                  let msg = obj["message"] as? [String: Any] else { continue }
            let ts = (obj["timestamp"] as? String).flatMap { Self.isoFrac.date(from: $0) ?? Self.isoPlain.date(from: $0) }
            if type == "user" {
                let raw = Self.extractUserText(from: msg["content"])
                if let parsed = Self.parseDispatchMessage(raw) {
                    scan.dispatchSender = parsed.sender
                    scan.dispatchFromLead = parsed.fromLead
                    scan.dispatchSentence = parsed.firstSentence
                    scan.dispatchTime = ts ?? mtime
                    scan.hasOutputAfterDispatch = false
                    scan.finishedAfterDispatch = false
                    scan.lastToolAction = nil
                } else if scan.dispatchTime != nil {
                    // 指派者在工作者完成後再次傳訊，代表已看過／接手，不再顯示待驗收。
                    scan.finishedAfterDispatch = false
                }
            } else if type == "assistant" {
                scan.hasOutputAfterDispatch = true
                if let blocks = msg["content"] as? [[String: Any]] {
                    var sawToolUse = false
                    var sawText = false
                    for b in blocks {
                        let btype = b["type"] as? String
                        if btype == "tool_use" {
                            sawToolUse = true
                            scan.finishedAfterDispatch = false
                            let name = (b["name"] as? String) ?? "工具"
                            let input = (b["input"] as? [String: Any]) ?? [:]
                            scan.lastToolAction = Self.formatToolAction(name: name, input: input)
                        } else if btype == "text", let t = b["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            sawText = true
                        }
                    }
                    if sawText && !sawToolUse {
                        scan.finishedAfterDispatch = true
                    }
                } else if let s = msg["content"] as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    scan.finishedAfterDispatch = true
                }
            }
        }
        transcriptCache[url] = scan
        return scan
    }

    private static func extractUserText(from content: Any?) -> String {
        if let s = content as? String { return s }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["type"] as? String == "text" ? ($0["text"] as? String) : nil }.joined(separator: "\n")
        }
        return ""
    }

    static func parseDispatchMessage(_ raw: String) -> (sender: String, fromLead: Bool, firstSentence: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.range(of: "〔來自"),
              let end = trimmed.range(of: "〕", range: start.upperBound..<trimmed.endIndex) else { return nil }
        let header = String(trimmed[start.upperBound..<end.lowerBound])
        let fromWorker = header.contains("施工聊天室")
        guard header.contains("總指揮") || header.contains("區長") || fromWorker else { return nil }
        let fromLead = header.contains("區長")
        var sender = header
        if let q1 = header.lastIndex(of: "「"), let q2 = header.lastIndex(of: "」"), q1 < q2 {
            let name = String(header[header.index(after: q1)..<q2])
            sender = fromWorker ? "施工聊天室「\(name)」" : (fromLead ? "區長「\(name)」" : "總指揮「\(name)」")
        }
        var rest = String(trimmed[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        while rest.hasPrefix("〔"), let rEnd = rest.firstIndex(of: "〕") {
            rest = String(rest[rest.index(after: rEnd)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let firstLine = rest.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        guard !firstLine.isEmpty else { return nil }
        let delimiters = CharacterSet(charactersIn: "。！？；\n")
        let firstClause: String
        if let r = firstLine.rangeOfCharacter(from: delimiters) {
            firstClause = String(firstLine[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            firstClause = firstLine
        }
        guard !firstClause.isEmpty else { return nil }
        return (sender, fromLead, firstClause)
    }

    static func formatToolAction(name: String, input: [String: Any]) -> String {
        let rawPath = (input["file_path"] ?? input["path"] ?? input["notebook_path"] ?? input[" Path"] ?? input["Path"]) as? String
        let baseName = rawPath.map { ($0 as NSString).lastPathComponent }
        switch name {
        case "Edit", "Write", "MultiEdit", "NotebookEdit", "edit_file", "write_file":
            return "改 \(baseName ?? "檔案")"
        case "Read", "read_file":
            return "讀 \(baseName ?? "檔案")"
        case "Bash", "run_command":
            let cmd = ((input["command"] ?? input["CommandLine"]) as? String ?? "")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let safe = KeyScan.redact(cmd, strongOnly: false)
            let short = safe.count > 26 ? String(safe.prefix(25)) + "…" : safe
            return short.isEmpty ? "執行指令" : "執行 \(short)"
        case "Grep", "Glob", "grep_search", "find_by_name":
            let pat = ((input["pattern"] ?? input["Query"] ?? input["Pattern"]) as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let short = pat.count > 22 ? String(pat.prefix(21)) + "…" : pat
            return short.isEmpty ? "搜尋檔案" : "搜尋 \(short)"
        default:
            return "工具：\(name)"
        }
    }

    private func resolveAssignment(for c: Conversation, state: RPState, session: SessionLayout, areaLead: Conversation?, chief: Conversation?, centerID: UUID, store: Store, goals: [CollabGoal], now: Date) -> GraphAssignment? {
        guard c.id != session.chief, !leadIsSelf(c: c, areaLead: areaLead) else { return nil }
        let seed = seeds[c.id]
        // commanderDispatches 同時保存排隊中與已開始的工作；只有 started 才是這一輪目前正在處理的派工。
        let dispatchRecord = c.commanderDispatches?.filter(\.started).max { $0.sequence < $1.sequence }
        let scan = scanTranscript(for: c, store: store, now: now)
        var matchedStep: CollabStep?
        var matchedGoal: CollabGoal?
        let idPrefix = String(c.id.uuidString.prefix(8)).lowercased()
        for g in goals where g.status == "active" {
            for st in g.steps {
                guard let owner = st.owner?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty else { continue }
                let conversationID = c.id.uuidString.lowercased()
                let ownerID = owner.lowercased()
                let matchesOwner = (owner.caseInsensitiveCompare(c.title) == .orderedSame)
                    || (ownerID == conversationID)
                    || (owner.count >= 4 && (idPrefix.hasPrefix(ownerID) || conversationID.hasPrefix(ownerID)))
                guard matchesOwner else { continue }
                if st.state == "doing" || st.state == "進行中" || st.state == "blocked" || st.state == "卡住" || st.state == "review" || st.state == "待驗收" {
                    matchedStep = st; matchedGoal = g; break
                } else if st.state == "done", let cur = g.current, CollabBoardModel.isVerifyStep(cur.text) {
                    matchedStep = st; matchedGoal = g
                }
            }
            if matchedStep != nil && matchedStep?.state != "done" { break }
        }

        // 工作名稱優先序：(1) collab.json 指派給該聊天室且進行中的步驟標題 → (2) 最近一則來自總指揮／區長訊息第一句 → (3) 測試 seed → 不顯示
        let stepTitle = matchedStep?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let msgTitle = scan?.dispatchSentence?.trimmingCharacters(in: .whitespacesAndNewlines)
        let taskTitle = (stepTitle?.isEmpty == false ? stepTitle : nil)
            ?? (msgTitle?.isEmpty == false ? msgTitle : nil)
            ?? seed?.taskTitle
        guard let taskTitle, !taskTitle.isEmpty else { return nil }

        let stuckMins = CommanderStuck.shared.minutes(c.id)
        let stateIsStuck: Bool
        if case .stuck = state { stateIsStuck = true } else { stateIsStuck = false }
        let isStuck = stuckMins != nil || stateIsStuck || matchedStep?.state == "blocked" || matchedStep?.state == "卡住" || seed?.stage == .stuck

        let stepTime = matchedStep?.at.flatMap { Self.isoFrac.date(from: $0) ?? Self.isoPlain.date(from: $0) }
        let startedAt = seed?.dispatchedAt ?? scan?.dispatchTime ?? stepTime
        let elapsedSec: Int
        if let stuckMins, isStuck {
            elapsedSec = max(stuckMins * 60, startedAt.map { Int(max(1, now.timeIntervalSince($0))) } ?? stuckMins * 60)
        } else if let startedAt {
            elapsedSec = max(1, Int(now.timeIntervalSince(startedAt)))
        } else {
            elapsedSec = 30
        }

        // 階段判定
        let stage: GraphAssignment.Stage
        if let seededStage = seed?.stage {
            stage = seededStage
        } else if isStuck {
            stage = .stuck
        } else if state == .working || state == .waiting || isBackground(state) {
            let hasOutput = scan?.hasOutputAfterDispatch ?? (matchedStep != nil && scan?.lastToolAction != nil)
            if !hasOutput && elapsedSec <= 60 {
                stage = .dispatched
            } else {
                stage = .working
            }
        } else {
            // 聊天室已不在 working：只在「做完等總指揮／區長看（等待驗收）」時顯示藍色，一般閒置不顯示
            let waitingReview = (matchedStep?.state == "review" || matchedStep?.state == "待驗收")
                || (matchedStep?.state == "done" && matchedGoal?.current.map { CollabBoardModel.isVerifyStep($0.text) } == true)
                || (scan?.finishedAfterDispatch == true)
            guard waitingReview else { return nil }
            stage = .review
        }

        let lastAction = seed?.lastAction
            ?? scan?.lastToolAction
            ?? (stage == .dispatched ? "剛收到派工，準備開始" : "尚無工具呼叫")

        let assignerID: UUID?
        let assignerName: String
        if let dispatchRecord, let actualAssigner = store.conversation(dispatchRecord.assignerID) {
            assignerID = dispatchRecord.assignerID
            assignerName = actualAssigner.title
        } else if let sID = seed?.assignerID, let sName = seed?.assignerName {
            assignerID = sID
            assignerName = sName
        } else if let areaLead, areaLead.id != c.id, (scan?.dispatchFromLead != false) {
            assignerID = areaLead.id
            assignerName = scan?.dispatchSender ?? "區長「\(areaLead.title)」"
        } else {
            assignerID = centerID
            assignerName = scan?.dispatchSender ?? "總指揮「\(chief?.title ?? session.name)」"
        }

        let dispatchDate = scan?.dispatchTime ?? seed?.dispatchedAt
        let isActiveState: Bool
        switch state {
        case .working, .background, .stuck: isActiveState = true
        // 07-1 的完成通知在 waiting/result/error 都結束這一輪；waiting 不代表派工仍在執行。
        case .waiting, .idle, .asleep: isActiveState = false
        }
        let withinDispatchWindow = dispatchDate.map { age in
            let elapsed = now.timeIntervalSince(age)
            return elapsed >= 0 && elapsed <= 24 * 60 * 60
        } ?? false
        // 07-1 用狀態轉換及 started 派工紀錄判定一輪；關閉條件直接由目前快照推導，
        // 不保留聊天室層級的「已關閉」旗標，以免污染同一聊天室下一輪的新派工。
        let hasStartedDispatch = dispatchRecord != nil || seed != nil
        let activeDispatch = hasStartedDispatch && isActiveState && withinDispatchWindow
        let dispatchClosedReason: String?
        if activeDispatch { dispatchClosedReason = nil }
        else if !withinDispatchWindow { dispatchClosedReason = "超過 24 小時或沒有派工時間" }
        else if !isActiveState { dispatchClosedReason = "被派方本輪已結束" }
        else { dispatchClosedReason = "沒有未結束的派工紀錄" }

        return GraphAssignment(
            taskTitle: taskTitle,
            shortTitle: GraphAssignment.shorten(taskTitle, limit: 12),
            stage: stage,
            elapsedSeconds: elapsedSec,
            elapsedText: GraphAssignment.formatElapsed(elapsedSec),
            lastAction: lastAction,
            assignerName: assignerName,
            assignerID: assignerID,
            activeDispatch: activeDispatch,
            dispatchClosedReason: dispatchClosedReason
        )
    }

    private func leadIsSelf(c: Conversation, areaLead: Conversation?) -> Bool {
        areaLead?.id == c.id
    }

    private func isBackground(_ state: RPState) -> Bool {
        if case .background = state { return true }
        return false
    }
}

final class ChatGraphView: NSView {
    struct Node {
        var info: GraphNodeInfo
        var pos: CGPoint
        var vel = CGPoint.zero
        var pinned = false
        var r: CGFloat
        var lw: CGFloat = 40          // 標籤寬度（畫面點數，約值；置中貼合時把標籤也算進去）
        var id: UUID { info.id }
    }

    // 外面接的
    weak var store: Store?
    weak var workspace: Workspace?
    var onSummon: ((UUID) -> Void)?
    var onInfo: ((UUID) -> Void)?
    var onEscape: (() -> Void)?
    var onLayoutRequested: (() -> Void)?
    /// F6 大畫面版：字和節點大一點
    var big = false { didSet { if big != oldValue { invalidateFullDisplay() } } }
    /// F6 面板本身；右欄那份在 F6 開著時被蓋住，要停下來
    var isOverlay = false
    private(set) static var overlayOpen = false
    /// 測試用：右欄那份
    static weak var rightInstance: ChatGraphView?
    static let overlayChanged = Notification.Name("ChatGraphView.overlayChanged")
    static func setOverlayOpen(_ on: Bool) {
        overlayOpen = on
        NotificationCenter.default.post(name: overlayChanged, object: nil)
    }

    private(set) var nodes: [Node] = []
    private var index: [UUID: Int] = [:]
    private var signature = 0
    private var graphLayout = GraphLayoutSettings.defaults
    private struct Viewport { var scale: CGFloat; var offset: CGPoint; var userMoved: Bool }
    private var activeSessionID: UUID?
    private var viewports: [UUID: Viewport] = [:]
    private var alpha: CGFloat = 0
    private var alphaTarget: CGFloat = 0
    private var alphaMin: CGFloat = 0.001
    private var alphaDecay: CGFloat = 1 - pow(0.001, 1.0 / 220.0)
    var velocityDecay: CGFloat = 0.6
    private var childCounts: [UUID: Int] = [:]
    private var subtreeCounts: [UUID: Int] = [:]
    private var offset = CGPoint.zero          // 世界原點在視圖中心偏移多少（畫面座標）
    private var scale: CGFloat = 1
    private var userMoved = false
    private var fitting = false
    private var fitAfterLayout = false
    private var autoFitPending = false
    private var timer: Timer?
    private var timerInterval: TimeInterval = 0
    private var floatingTerminalDragging = false
    private var hover: UUID?
    private var hoverEdge: UUID?
    private var hoverEdgeFrom: UUID?
    private var lastDrawnEdgeLabels: [UUID: String] = [:]
    private struct DrawnNodeLabel { var frame: CGRect; var text: String; var fullTitle: String }
    private var lastDrawnNodeLabels: [UUID: DrawnNodeLabel] = [:]
    private struct CachedNodeLabel {
        let id: UUID
        let displayTitle: String
        let fullTitle: String
        let origin: CGPoint
        let frame: CGRect
        let attrs: [NSAttributedString.Key: Any]
    }
    private struct CachedEdgeLabel {
        let id: UUID
        let shortTitle: String
        let stage: GraphAssignment.Stage
        let faded: Bool
        let origin: CGPoint
        let pillRect: CGRect
        let attrs: [NSAttributedString.Key: Any]
    }
    private struct LabelLayoutKey: Equatable {
        let generation: Int
        let boundsWidth: CGFloat
        let boundsHeight: CGFloat
        let scale: CGFloat
        let offsetX: CGFloat
        let offsetY: CGFloat
        let big: Bool
        let isDark: Bool
        let themeOverride: String?
        let hover: UUID?
        let hoverEdge: UUID?
        let hoverEdgeFrom: UUID?
        let selectedChat: UUID?
    }
    private var labelLayoutGeneration = 0
    private var cachedLabelLayoutKey: LabelLayoutKey?
    private var cachedNodeLabels: [CachedNodeLabel] = []
    private var cachedEdgeLabels: [CachedEdgeLabel] = []
    private var lastHoverCardRect: CGRect?
    private static let isTestInstance = CommandLine.arguments.contains("--state-dir")
    private var drawCountForTest = 0
    private var lastDirtyRectAreaForTest: Double = 0
    private var suppressDirtyTracking = false
    private var isDumping = false
    /// 僅供 --state-dir 測試掛鉤讀取；非測試實例不計數、不增加執行期成本。
    var diagnosticsForTest: (drawCount: Int, timerRunning: Bool, lastDirtyRectArea: Double) {
        (drawCount: drawCountForTest, timerRunning: timer != nil, lastDirtyRectArea: lastDirtyRectAreaForTest)
    }
    var themeOverride: String? { didSet { if themeOverride != oldValue { invalidateFullDisplay() } } }
    private var bag = Set<AnyCancellable>()
    private var menuActions: [MenuAction] = []

    // 滑鼠
    private var downNode: UUID?
    private var downPoint = CGPoint.zero
    private var dragged = false
    private var lastDrag = CGPoint.zero

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// 視窗不是目前的視窗時，第一下點擊也要直接算（不然第一下只拿來啟用視窗，選取要點第二次）
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }

    override func setNeedsDisplay(_ invalidRect: NSRect) {
        if Self.isTestInstance && !suppressDirtyTracking {
            lastDirtyRectAreaForTest = Double(max(0, invalidRect.width) * max(0, invalidRect.height))
        }
        super.setNeedsDisplay(invalidRect)
    }

    private func invalidateFullDisplay() {
        if Self.isTestInstance {
            lastDirtyRectAreaForTest = Double(max(0, bounds.width) * max(0, bounds.height))
            suppressDirtyTracking = true
            needsDisplay = true
            suppressDirtyTracking = false
        } else {
            needsDisplay = true
        }
    }

    private func invalidateDirtyRects(_ rects: [CGRect]) {
        let valid = rects.filter { !$0.isNull && !$0.isEmpty && $0.width > 0 && $0.height > 0 }
        guard !valid.isEmpty else { return }
        if Self.isTestInstance {
            let maxArea = Double(max(0, bounds.width) * max(0, bounds.height))
            let total = valid.reduce(0.0) { $0 + Double($1.width * $1.height) }
            lastDirtyRectAreaForTest = maxArea > 0 ? min(maxArea, total) : total
            suppressDirtyTracking = true
            for rect in valid { super.setNeedsDisplay(rect) }
            suppressDirtyTracking = false
        } else {
            for rect in valid { super.setNeedsDisplay(rect) }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        RightPanelModel.shared.$selectedChat.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.invalidateFullDisplay() }.store(in: &bag)
        let nc = NotificationCenter.default
        for n in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            nc.publisher(for: n).sink { [weak self] _ in self?.updateTimer() }.store(in: &bag)
        }
        nc.publisher(for: Self.overlayChanged).sink { [weak self] _ in self?.updateTimer() }.store(in: &bag)
        nc.publisher(for: NSWindow.didChangeOcclusionStateNotification).sink { [weak self] _ in self?.updateTimer() }.store(in: &bag)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }

    // MARK: 資料

    private func isAssignmentVisuallyEqual(_ a: GraphAssignment?, _ b: GraphAssignment?, includeElapsed: Bool) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (lhs?, rhs?):
            guard lhs.taskTitle == rhs.taskTitle,
                  lhs.shortTitle == rhs.shortTitle,
                  lhs.stage == rhs.stage,
                  lhs.lastAction == rhs.lastAction,
                  lhs.assignerName == rhs.assignerName,
                  lhs.assignerID == rhs.assignerID,
                  lhs.activeDispatch == rhs.activeDispatch,
                  lhs.dispatchClosedReason == rhs.dispatchClosedReason else { return false }
            return !includeElapsed || lhs.elapsedText == rhs.elapsedText
        default: return false
        }
    }

    private func isNodeVisuallyEqual(_ a: GraphNodeInfo, _ b: GraphNodeInfo, includeElapsed: Bool) -> Bool {
        a.id == b.id
            && a.kind == b.kind
            && a.title == b.title
            && a.parent == b.parent
            && a.state == b.state
            && a.context == b.context
            && a.placed == b.placed
            && a.hue == b.hue
            && a.rawTitle == b.rawTitle
            && a.isAreaLead == b.isAreaLead
            && a.areaGroupID == b.areaGroupID
            && a.representedConversationID == b.representedConversationID
            && a.areaLeadID == b.areaLeadID
            && a.areaLeadName == b.areaLeadName
            && isAssignmentVisuallyEqual(a.assignment, b.assignment, includeElapsed: includeElapsed)
    }

    private func isVisuallyEqual(to nextNodes: [GraphNodeInfo]) -> Bool {
        guard nodes.count == nextNodes.count else { return false }
        for i in nodes.indices {
            let nextInfo = nextNodes[i]
            if !isNodeVisuallyEqual(nodes[i].info, nextInfo, includeElapsed: hover == nextInfo.id) {
                return false
            }
        }
        return true
    }

    func apply(_ snap: GraphSnapshot?) {
        guard let snap else {
            if activeSessionID == nil && nodes.isEmpty && hover == nil && hoverEdge == nil && hoverEdgeFrom == nil && !fitting && alpha == 0 {
                updateTimer()
                return
            }
            rememberViewport()
            activeSessionID = nil
            nodes = []; index = [:]; childCounts = [:]; signature = 0; alpha = 0; alphaTarget = 0; hover = nil; hoverEdge = nil; hoverEdgeFrom = nil; fitting = false
            lastHoverCardRect = nil
            labelLayoutGeneration &+= 1
            invalidateFullDisplay(); updateTimer(); return
        }
        let layoutChanged = graphLayout != snap.layout
        if graphLayout != snap.layout { graphLayout = snap.layout; alpha = max(alpha, 0.25) }
        let sessionChanged = activeSessionID != snap.sessionID
        if !layoutChanged && !sessionChanged && activeSessionID != nil && isVisuallyEqual(to: snap.nodes) {
            // 視覺欄位完全相同：原地同步每秒變動的 elapsed，不重跑佈局、不標記重畫。
            for i in nodes.indices {
                if let nextAssign = snap.nodes[i].assignment, nodes[i].info.assignment != nil {
                    nodes[i].info.assignment?.elapsedSeconds = nextAssign.elapsedSeconds
                    nodes[i].info.assignment?.elapsedText = nextAssign.elapsedText
                }
            }
            // 背景或隱藏視窗不會啟動動畫 timer；快速路徑也要保留原本的補 fit 檢查。
            if !canAnimate, !userMoved, (fitAfterLayout || !viewportFits()) {
                autoFitPending = false
                fit(animated: false)
            }
            updateTimer()
            return
        }
        let savedViewport: Viewport?
        if sessionChanged {
            rememberViewport()
            activeSessionID = snap.sessionID
            savedViewport = snap.sessionID.flatMap { viewports[$0] }
            // 每位總指揮使用自己的世界座標與力導向速度；不可把上一位的模擬狀態接過來。
            nodes = []; index = [:]; signature = 0; alpha = 0; hover = nil; hoverEdge = nil; hoverEdgeFrom = nil; fitting = false
            lastHoverCardRect = nil
            if let savedViewport {
                scale = savedViewport.scale; offset = savedViewport.offset; userMoved = savedViewport.userMoved
                autoFitPending = !savedViewport.userMoved
            } else {
                scale = 1; offset = .zero; userMoved = false
                autoFitPending = true
            }
        } else {
            savedViewport = nil
        }
        let first = nodes.isEmpty
        var old: [UUID: Node] = [:]
        for n in nodes { old[n.id] = n }
        var oldAreas: [UUID: Node] = [:]
        for n in nodes where n.info.kind == .area {
            if let areaID = n.info.areaGroupID { oldAreas[areaID] = n }
        }
        let pos = spawnPositions(for: snap.nodes, existing: old)
        var out: [Node] = []
        for info in snap.nodes {
            let r = Self.radius(info)
            let lw = (info.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: info.kind == .center ? 12 : info.kind == .area ? 11 : 10, weight: info.kind == .chat ? .regular : .semibold)]).width
            if var n = info.areaGroupID.flatMap({ oldAreas[$0] }) ?? old[info.id] {
                if n.info.parent != info.parent { n.vel = .zero }
                n.info = info; n.r = r; n.lw = lw
                out.append(n)
            } else {
                let p = pos[info.id] ?? .zero
                var n = Node(info: info, pos: p, r: r)
                n.lw = lw
                n.pinned = info.kind == .center
                out.append(n)
            }
        }
        nodes = out
        index = Dictionary(uniqueKeysWithValues: out.enumerated().map { ($1.id, $0) })
        if let h = hover, index[h] == nil { hover = nil; hoverEdge = nil; hoverEdgeFrom = nil; lastHoverCardRect = nil }
        if let edgeFrom = hoverEdgeFrom, index[edgeFrom] == nil { hoverEdge = nil; hoverEdgeFrom = nil }
        let changed = snap.signature != signature
        signature = snap.signature
        if first {
            warmup(ticks: 12, initialAlpha: 1)
            if let savedViewport, savedViewport.userMoved {
                userMoved = true
                autoFitPending = false
                rememberViewport()
            } else {
                userMoved = false
                autoFitPending = true
            }
        } else if changed || layoutChanged {
            let targetAlpha: CGFloat = changed ? 0.65 : 0.35
            warmup(ticks: 8, initialAlpha: max(alpha, targetAlpha))
            autoFitPending = !userMoved
        }
        // 背景或隱藏視窗不會啟動動畫 timer；此時不能把首次 fit 留給 tick。
        if !canAnimate, !userMoved, (fitAfterLayout || !viewportFits()) {
            autoFitPending = false
            fit(animated: false)
        }
        labelLayoutGeneration &+= 1
        invalidateFullDisplay()
        updateTimer()
    }

    static func radius(_ i: GraphNodeInfo) -> CGFloat {
        switch i.kind {
        case .center: return 16
        case .area: return 10
        case .chat: return 5 + min(5, CGFloat(i.context ?? 0) / 100_000)     // 上下文愈大節點愈大（500K 以上封頂）
        }
    }

    // MARK: 力導向

    /// 改寫自 obsidian-orrery（MIT License, Copyright (c) 2026 WestTee）：
    /// 區到聊天室的目標距離隨該父節點的子節點數 n 放大（base × max(1, √n / 2)）；
    /// 中心到區的目標距離也隨該區的子節點數放大，避免子節點多時總指揮節點貼近區節點，同時尊重使用者設定的層距離。
    private func spawnLinkLength(parentKind: GraphNodeInfo.Kind, childKind: GraphNodeInfo.Kind, siblingCount: Int, childID: UUID? = nil) -> CGFloat {
        let base = CGFloat(GraphLayoutSettings.linkLength(parent: parentKind, child: childKind, settings: graphLayout))
        if childKind == .chat {
            let n = CGFloat(max(1, siblingCount))
            return base * max(1, sqrt(n) / 2)
        }
        if childKind == .area, let childID {
            let desc = CGFloat(max(childCounts[childID] ?? 0, subtreeCounts[childID] ?? 0))
            if desc > 2 {
                return base * max(1, 1 + (sqrt(desc) - 1.4) * 0.35)
            }
        }
        return base
    }

    /// 改寫自 obsidian-orrery（MIT License, Copyright (c) 2026 WestTee）：
    /// 新節點出生在所屬父節點（區或總指揮）外圍、依現有子節點數排的空角度，距離取該層設定距離；
    /// 父節點也尚無位置時，先遞迴安置父節點再放子節點，非中心節點絕不放在原點。
    private func spawnPositions(for infos: [GraphNodeInfo], existing: [UUID: Node]) -> [UUID: CGPoint] {
        var infoByID: [UUID: GraphNodeInfo] = [:]
        var childrenByParent: [UUID: [UUID]] = [:]
        var centerID: UUID?
        for info in infos {
            infoByID[info.id] = info
            if info.kind == .center { centerID = info.id }
            if let pid = info.parent {
                childrenByParent[pid, default: []].append(info.id)
            }
        }
        childCounts = childrenByParent.mapValues(\.count)
        var memoSubtree: [UUID: Int] = [:]
        func countDescendants(_ id: UUID, seen: inout Set<UUID>) -> Int {
            if let c = memoSubtree[id] { return c }
            guard seen.insert(id).inserted else { return 0 }
            let kids = childrenByParent[id] ?? []
            var total = kids.count
            for k in kids { total += countDescendants(k, seen: &seen) }
            memoSubtree[id] = total
            return total
        }
        for info in infos {
            var seen = Set<UUID>()
            _ = countDescendants(info.id, seen: &seen)
        }
        subtreeCounts = memoSubtree
        var pos: [UUID: CGPoint] = [:]
        for info in infos {
            if let oldNode = existing[info.id] {
                pos[info.id] = oldNode.pos
            } else if info.kind == .center {
                pos[info.id] = .zero
            }
        }
        var placedParentGroups = Set<UUID>()

        func normalizeAngle(_ a: Double) -> Double {
            let twoPi = 2.0 * Double.pi
            var r = a.truncatingRemainder(dividingBy: twoPi)
            if r < 0 { r += twoPi }
            return r
        }

        func nextEmptyAngle(existingAngles: inout [Double], baseAngle: Double, slotIndex: Int, totalNew: Int) -> Double {
            let twoPi = 2.0 * Double.pi
            if existingAngles.isEmpty {
                return normalizeAngle(baseAngle + Double(slotIndex) * (twoPi / Double(max(1, totalNew))))
            }
            let sorted = existingAngles.map(normalizeAngle).sorted()
            if sorted.count == 1 {
                let a = normalizeAngle(sorted[0] + twoPi / 2.0)
                existingAngles.append(a)
                return a
            }
            var bestGap = -1.0
            var bestMid = baseAngle
            for i in 0..<sorted.count {
                let a1 = sorted[i]
                let a2 = (i + 1 < sorted.count) ? sorted[i + 1] : (sorted[0] + twoPi)
                let gap = a2 - a1
                if gap > bestGap {
                    bestGap = gap
                    bestMid = normalizeAngle(a1 + gap * 0.5)
                }
            }
            existingAngles.append(bestMid)
            return bestMid
        }

        func ensurePosition(_ id: UUID, visiting: inout Set<UUID>) -> CGPoint {
            if let p = pos[id] { return p }
            guard let info = infoByID[id], info.kind != .center, !visiting.contains(id) else {
                pos[id] = .zero
                return .zero
            }
            visiting.insert(id)
            let pid = info.parent ?? centerID
            let parentPos: CGPoint
            let parentKind: GraphNodeInfo.Kind
            if let pid, let pInfo = infoByID[pid] {
                parentPos = ensurePosition(pid, visiting: &visiting)
                parentKind = pInfo.kind
            } else {
                parentPos = .zero
                parentKind = .center
            }
            let groupKey = pid ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
            if !placedParentGroups.contains(groupKey) {
                placedParentGroups.insert(groupKey)
                let siblings = pid.flatMap { childrenByParent[$0] } ?? [id]
                var existingAngs: [Double] = []
                for sibID in siblings {
                    if let sibPos = pos[sibID] {
                        let dx = Double(sibPos.x - parentPos.x), dy = Double(sibPos.y - parentPos.y)
                        if hypot(dx, dy) > 0.001 {
                            existingAngs.append(normalizeAngle(atan2(dy, dx)))
                        }
                    }
                }
                let newSiblings = siblings.filter { pos[$0] == nil }
                let baseAngle: Double
                if abs(parentPos.x) > 0.1 || abs(parentPos.y) > 0.1 {
                    baseAngle = normalizeAngle(atan2(Double(parentPos.y), Double(parentPos.x)))
                } else {
                    baseAngle = -Double.pi / 2.0
                }
                let hadExisting = !existingAngs.isEmpty
                for (slotIdx, sibID) in newSiblings.enumerated() {
                    guard let sibInfo = infoByID[sibID] else { continue }
                    if hadExisting && existingAngs.count == 1 && slotIdx == 0 && newSiblings.count > 1 {
                        let a0 = existingAngs[0]
                        for (k, sID) in newSiblings.enumerated() {
                            guard let sInfo = infoByID[sID] else { continue }
                            let a = normalizeAngle(a0 + Double(k + 1) * (2.0 * Double.pi / Double(newSiblings.count + 1)))
                            let d = max(12, spawnLinkLength(parentKind: parentKind, childKind: sInfo.kind, siblingCount: siblings.count, childID: sID))
                            var p = CGPoint(x: parentPos.x + CGFloat(cos(a)) * d, y: parentPos.y + CGFloat(sin(a)) * d)
                            if hypot(p.x, p.y) < 12 { p.x += 24 }
                            pos[sID] = p
                        }
                        break
                    }
                    let angle: Double
                    if !hadExisting {
                        angle = normalizeAngle(baseAngle + Double(slotIdx) * (2.0 * Double.pi / Double(max(1, newSiblings.count))))
                    } else {
                        angle = nextEmptyAngle(existingAngles: &existingAngs, baseAngle: baseAngle, slotIndex: slotIdx, totalNew: newSiblings.count)
                    }
                    let d = max(12, spawnLinkLength(parentKind: parentKind, childKind: sibInfo.kind, siblingCount: siblings.count, childID: sibID))
                    var p = CGPoint(x: parentPos.x + CGFloat(cos(angle)) * d, y: parentPos.y + CGFloat(sin(angle)) * d)
                    if hypot(p.x, p.y) < 12 { p.x += 24 }
                    pos[sibID] = p
                }
            }
            visiting.remove(id)
            return pos[id] ?? CGPoint(x: parentPos.x + 50, y: parentPos.y)
        }

        for info in infos where pos[info.id] == nil {
            var visiting = Set<UUID>()
            _ = ensurePosition(info.id, visiting: &visiting)
        }
        return pos
    }

    private func restLength(_ n: Node, parent p: Node) -> CGFloat {
        spawnLinkLength(parentKind: p.info.kind, childKind: n.info.kind, siblingCount: childCounts[p.id] ?? 1, childID: n.id)
    }

    /// 改寫自 d3-force/src/simulation.js（ISC License, Copyright 2010-2026 Mike Bostock）：
    /// alpha 以 `(alphaTarget - alpha) * alphaDecay` 趨近 alphaTarget。
    private func advanceAlpha() {
        alpha += (alphaTarget - alpha) * alphaDecay
        if abs(alpha - alphaTarget) <= alphaMin { alpha = alphaTarget }
    }

    /// 改寫自 force-graph（MIT License, Copyright (c) 2018 Vasco Asturiano）：
    /// 小量同步暖啟後，讓 RunLoop 的動畫 tick 接手收斂，避免主執行緒同步跑完整輪佈局。
    private func warmup(ticks: Int = 12, initialAlpha: CGFloat = 1) {
        guard !nodes.isEmpty else { alpha = 0; return }
        alpha = max(alpha, initialAlpha)
        alphaTarget = 0
        for _ in 0..<min(16, max(0, ticks)) {
            advanceAlpha()
            step()
            if alpha <= alphaMin { break }
        }
    }

    /// 改寫自 d3-force/src/collide.js（ISC License, Copyright 2010-2026 Mike Bostock）：
    /// 含標籤寬度估算的碰撞半徑，每 tick 迭代 2 次幾何重疊分攤。
    private func collisionRadius(_ n: Node) -> CGFloat {
        let labelHalf = min(n.r + 22, n.lw * 0.28)
        return max(n.r + 6, labelHalf)
    }

    private func collide(iterations: Int = 2) {
        let n = nodes.count
        guard n > 1 else { return }
        let radii = nodes.map { collisionRadius($0) }
        for _ in 0..<iterations {
            for i in 0..<n {
                for j in (i + 1)..<n where j < n {
                    var dx = nodes[j].pos.x - nodes[i].pos.x
                    var dy = nodes[j].pos.y - nodes[i].pos.y
                    var l2 = dx * dx + dy * dy
                    let ri = radii[i], rj = radii[j]
                    let r = ri + rj
                    guard l2 < r * r else { continue }
                    if l2 < 0.0001 {
                        let a = CGFloat(i * 7 + j * 13) * 0.61803398875 * 2 * .pi
                        dx = cos(a) * 0.5
                        dy = sin(a) * 0.5
                        l2 = dx * dx + dy * dy
                    }
                    let l = sqrt(l2)
                    let overlap = (r - l) / l
                    let wi: CGFloat
                    let wj: CGFloat
                    if nodes[i].pinned && nodes[j].pinned {
                        continue
                    } else if nodes[i].pinned {
                        wi = 0; wj = 1
                    } else if nodes[j].pinned {
                        wi = 1; wj = 0
                    } else {
                        let rj2 = rj * rj
                        let w = rj2 / (ri * ri + rj2)
                        wi = w; wj = 1 - w
                    }
                    nodes[i].pos.x -= dx * overlap * wi
                    nodes[i].pos.y -= dy * overlap * wi
                    nodes[j].pos.x += dx * overlap * wj
                    nodes[j].pos.y += dy * overlap * wj
                }
            }
        }
    }

    /// 改寫自 d3-force/src/manyBody.js 與 simulation.js（ISC License, Copyright 2010-2026 Mike Bostock）：
    /// 拿掉 1/d² 在極近距離的爆量（加下限距離）、以平滑衰減取代 400pt 硬截斷，並執行 2 次幾何碰撞迭代。
    private func step() {
        let n = nodes.count
        guard n > 0 else { return }
        var fx = [CGFloat](repeating: 0, count: n), fy = [CGFloat](repeating: 0, count: n)
        for i in 0..<n {
            for j in (i + 1)..<n where j < n {
                var dx = nodes[j].pos.x - nodes[i].pos.x, dy = nodes[j].pos.y - nodes[i].pos.y
                var d2 = dx * dx + dy * dy
                if d2 < 0.01 { dx = CGFloat(i - j) * 0.3 + 0.1; dy = 0.1; d2 = dx * dx + dy * dy }
                let d = sqrt(d2)
                let minSep = max(24, nodes[i].r + nodes[j].r + 8)
                let effD2 = max(d2, minSep * minSep)
                let falloff = 1 / (1 + d2 / 360_000)
                let k = CGFloat(graphLayout.repulsion) / effD2 * (1 + (nodes[i].r + nodes[j].r) / 30) * falloff
                let ux = dx / d, uy = dy / d
                fx[i] -= ux * k; fy[i] -= uy * k
                fx[j] += ux * k; fy[j] += uy * k
            }
        }
        for i in 0..<n {
            guard let p = nodes[i].info.parent, let pi = index[p] else { continue }
            let dx = nodes[pi].pos.x - nodes[i].pos.x, dy = nodes[pi].pos.y - nodes[i].pos.y
            let d = max(0.01, sqrt(dx * dx + dy * dy))
            let f = (d - restLength(nodes[i], parent: nodes[pi])) * 0.09
            let ux = dx / d, uy = dy / d
            fx[i] += ux * f; fy[i] += uy * f
            fx[pi] -= ux * f; fy[pi] -= uy * f
        }
        let decay = max(0.05, min(0.95, velocityDecay))
        for i in 0..<n {
            fx[i] -= nodes[i].pos.x * 0.004; fy[i] -= nodes[i].pos.y * 0.004
            if nodes[i].pinned { nodes[i].vel = .zero; continue }
            var vx = (nodes[i].vel.x + fx[i] * alpha) * decay, vy = (nodes[i].vel.y + fy[i] * alpha) * decay
            let sp = sqrt(vx * vx + vy * vy)
            if sp > 30 { vx *= 30 / sp; vy *= 30 / sp }
            nodes[i].vel = CGPoint(x: vx, y: vy)
            nodes[i].pos.x += vx; nodes[i].pos.y += vy
        }
        collide(iterations: 2)
    }

    // MARK: 計時器（只在需要時跑）

    private func hasBreathingHalo(_ n: Node) -> Bool {
        n.info.state == .working && (n.info.kind != .area || n.info.isAreaLead)
    }

    private func hasActiveDispatchAnimation(_ n: Node) -> Bool {
        guard n.info.state != .waiting,
              let assign = n.info.assignment,
              assign.activeDispatch,
              assign.stage == .working || assign.stage == .dispatched,
              let assignerID = assign.assignerID, assignerID != n.id,
              index[assignerID] != nil else { return false }
        return true
    }

    private var anyWorking: Bool {
        nodes.contains { hasBreathingHalo($0) || hasActiveDispatchAnimation($0) }
    }
    /// aa5770 測試掛鉤：--idle-bench-probe 時強制略過「App 前景／視窗未被遮擋」判斷（只在 --state-dir 測試實例設定）
    static var forceAnimateForTest = false
    var canAnimateForTest: Bool { canAnimate }
    private var canAnimate: Bool {
        guard let w = window, w.isVisible, !isHiddenOrHasHiddenAncestor, Self.forceAnimateForTest || (NSApp.isActive && w.occlusionState.contains(.visible)) else { return false }
        return isOverlay || !Self.overlayOpen
    }
    private var shouldRun: Bool { !floatingTerminalDragging && canAnimate && (alpha > 0.02 || fitting || autoFitPending || anyWorking) }
    private var isBreathingOnly: Bool { alpha <= 0.02 && !fitting && !autoFitPending && anyWorking }
    private var desiredTimerInterval: TimeInterval { isBreathingOnly ? (1.0 / 15.0) : (1.0 / 60.0) }

    func setFloatingTerminalDragging(_ dragging: Bool) {
        guard floatingTerminalDragging != dragging else { return }
        floatingTerminalDragging = dragging
        updateTimer()
    }

    func updateTimer() {
        if shouldRun {
            let desired = desiredTimerInterval
            if timer != nil && timerInterval == desired { return }
            timer?.invalidate()
            let t = Timer(timeInterval: desired, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
            timerInterval = desired
        } else if let t = timer {
            t.invalidate()
            timer = nil
            timerInterval = 0
        }
    }

    private func breathingDirtyRects() -> [CGRect] {
        guard bounds.width > 0, bounds.height > 0 else { return [] }
        guard cachedLabelLayoutKey != nil else { return [bounds] }
        let ns = nodeScale
        var rects: [CGRect] = []
        for n in nodes {
            if hasBreathingHalo(n) {
                let c = toScreen(n.pos)
                let r = max(n.r * scale * ns, n.info.kind == .chat ? 3 : 5)
                let hrMax = r * 2.0 + 4
                let rect = CGRect(x: c.x - hrMax, y: c.y - hrMax, width: hrMax * 2, height: hrMax * 2)
                    .integral.intersection(bounds)
                if !rect.isNull && !rect.isEmpty { rects.append(rect) }
            }
            if n.info.state != .waiting,
               let assign = n.info.assignment,
               assign.activeDispatch,
               assign.stage == .working,
               let assignerID = assign.assignerID, assignerID != n.id,
               let pi = index[assignerID] {
                let a = toScreen(nodes[pi].pos), b = toScreen(n.pos)
                let pad = max(12.0, 10.0 * scale + 4.0)
                let edgeRect = CGRect(
                    x: min(a.x, b.x) - pad,
                    y: min(a.y, b.y) - pad,
                    width: abs(b.x - a.x) + pad * 2,
                    height: abs(b.y - a.y) + pad * 2
                ).integral.intersection(bounds)
                if !edgeRect.isNull && !edgeRect.isEmpty { rects.append(edgeRect) }
                if let pill = cachedEdgeLabels.first(where: { $0.id == n.id }) {
                    let pillRect = pill.pillRect.insetBy(dx: -3, dy: -3).integral.intersection(bounds)
                    if !pillRect.isNull && !pillRect.isEmpty { rects.append(pillRect) }
                }
            }
        }
        if let h = hover, let hi = index[h], nodes[hi].info.assignment?.stage == .working {
            if let cardRect = lastHoverCardRect {
                let clipped = cardRect.insetBy(dx: -3, dy: -3).integral.intersection(bounds)
                if !clipped.isNull && !clipped.isEmpty { rects.append(clipped) }
            } else {
                return [bounds]
            }
        }
        return rects
    }

    private func tick() {
        var fullRedraw = false
        if alpha > 0.02 {
            advanceAlpha()
            step()
            labelLayoutGeneration &+= 1
            fullRedraw = true
            if alpha <= 0.02 {
                alpha = 0
                for i in nodes.indices { nodes[i].vel = .zero }
            }
        }
        // 力導向動畫會在初次 fit 後繼續移動節點；使用者未手動調整時，
        // 每個 tick 都要補 fit 超出畫布的圖，直到動畫穩定為止。
        if !userMoved {
            if fitting {
                let oldScale = scale, oldOffset = offset
                fit(animated: true)
                if scale != oldScale || offset != oldOffset { fullRedraw = true }
            } else if !viewportFits() || (alpha <= 0.02 && autoFitPending) {
                autoFitPending = false
                let oldScale = scale, oldOffset = offset
                fit(animated: true)
                if scale != oldScale || offset != oldOffset { fullRedraw = true }
            }
        }
        if fullRedraw {
            invalidateFullDisplay()
        } else if anyWorking {
            let rects = breathingDirtyRects()
            if !rects.isEmpty {
                invalidateDirtyRects(rects)
            }
        }
        if !shouldRun || timerInterval != desiredTimerInterval { updateTimer() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, !nodes.isEmpty {
            if !userMoved, fitAfterLayout || !viewportFits() { fit(animated: false) }
        }
        updateTimer()
    }
    override func viewDidHide() { super.viewDidHide(); updateTimer() }
    override func viewDidUnhide() {
        super.viewDidUnhide()
        if !nodes.isEmpty {
            if !userMoved, fitAfterLayout || !viewportFits() { fit(animated: false) }
        }
        updateTimer()
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard !nodes.isEmpty else { return }
        if !userMoved, fitAfterLayout || !viewportFits() { fit(animated: false) }
    }

    private func rememberViewport() {
        guard let activeSessionID, !nodes.isEmpty else { return }
        viewports[activeSessionID] = Viewport(scale: scale, offset: offset, userMoved: userMoved)
    }

    /// 依指定縮放算出節點、標籤與上下留白的世界座標外框。
    private func visualWorldBounds(at candidateScale: CGFloat) -> CGRect? {
        guard !nodes.isEmpty, candidateScale > 0 else { return nil }
        var minX = CGFloat.infinity, maxX = -CGFloat.infinity, minY = CGFloat.infinity, maxY = -CGFloat.infinity
        for n in nodes {
            let half = max(n.r, n.lw * nodeScale / (2 * candidateScale))
            minX = min(minX, n.pos.x - half); maxX = max(maxX, n.pos.x + half)
            minY = min(minY, n.pos.y - n.r); maxY = max(maxY, n.pos.y + n.r + 18 / candidateScale)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 節點、標籤與其上下留白在視圖中的完整外框。
    private func visualBoundsInView() -> CGRect? {
        guard let world = visualWorldBounds(at: scale) else { return nil }
        return CGRect(x: bounds.midX + offset.x + world.minX * scale,
                      y: bounds.midY + offset.y + world.minY * scale,
                      width: world.width * scale, height: world.height * scale)
    }

    /// 記住的縮放／平移必須仍把整張圖放在本身畫布內；右欄高度縮小時不沿用失效視角。
    private func viewportFits() -> Bool {
        guard bounds.width > 10, bounds.height > 10, let graph = visualBoundsInView() else { return false }
        let padX: CGFloat = big ? 12 : 8, padY: CGFloat = big ? 12 : 8
        var visible = bounds.insetBy(dx: padX, dy: padY)
        if big { visible.origin.y = max(visible.minY, 40); visible.size.height = max(0, bounds.maxY - padY - visible.minY) }
        return visible.contains(graph)
    }

    /// 原生考卷掛鉤：模擬在該主管手動縮放與平移後切換出去。
    func adjustViewportForTest(scaleFactor: CGFloat, dx: CGFloat, dy: CGFloat) {
        guard CommandLine.arguments.contains("--state-dir"), scaleFactor.isFinite, scaleFactor > 0 else { return }
        scale = min(5, max(0.15, scale * scaleFactor))
        offset.x += dx; offset.y += dy
        userMoved = true; fitting = false; autoFitPending = false
        rememberViewport(); invalidateFullDisplay()
    }

    /// 縮放平移到剛好看到所有節點
    func fit(animated: Bool) {
        guard !nodes.isEmpty, bounds.width > 10, bounds.height > 10 else { fitAfterLayout = true; return }
        let hadFitAfterLayout = fitAfterLayout
        fitAfterLayout = false
        let padX: CGFloat = big ? 60 : 24, padY: CGFloat = big ? 56 : 20
        let top: CGFloat = big ? 40 : 0          // F6 面板上方有標題列
        let cap: CGFloat = big ? 2.4 : 1.6
        let availableWidth = max(1, bounds.width - padX * 2)
        let availableHeight = max(1, bounds.height - padY * 2 - top)
        var low: CGFloat = 0.0001
        var high = cap
        for _ in 0..<40 {
            let candidate = (low + high) / 2
            guard let visual = visualWorldBounds(at: candidate) else { break }
            if visual.width * candidate <= availableWidth && visual.height * candidate <= availableHeight {
                low = candidate
            } else {
                high = candidate
            }
        }
        let s = low
        guard let visual = visualWorldBounds(at: s) else { return }
        let cx = visual.midX, cy = visual.midY
        // F6 不再保留左欄；以完整面板的中心為基準，雙擊空白處重置也走同一個 fit。
        let target = CGPoint(x: -cx * s, y: -cy * s)
        autoFitPending = false
        if animated {
            scale += (s - scale) * 0.18
            offset = CGPoint(x: offset.x + (target.x - offset.x) * 0.18, y: offset.y + (target.y - offset.y) * 0.18)
            fitting = abs(s - scale) > 0.002 || abs(target.x - offset.x) > 0.3 || abs(target.y - offset.y) > 0.3
            rememberViewport()
        } else {
            let changed = hadFitAfterLayout || scale != s || offset != target
            scale = s; offset = target; fitting = false
            rememberViewport()
            // 非動畫 fit 會直接改變 scale/offset；立即整張失效並遞增 labelLayoutGeneration，
            // 避免只剩呼吸光圈局部重畫時其餘區域殘留舊座標。
            if changed {
                labelLayoutGeneration &+= 1
                invalidateFullDisplay()
            }
        }
    }

    /// 佈局穩定前一直貼合；使用者動過視角就不再自動貼合（雙擊空白處重新貼合）
    private func refit() { userMoved = false; autoFitPending = false; fitting = true; updateTimer() }

    // MARK: 座標

    private func toScreen(_ p: CGPoint) -> CGPoint { CGPoint(x: bounds.midX + offset.x + p.x * scale, y: bounds.midY + offset.y + p.y * scale) }
    private func toWorld(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - bounds.midX - offset.x) / scale, y: (p.y - bounds.midY - offset.y) / scale) }

    private var nodeScale: CGFloat { big ? 1.25 : 1 }

    private func hit(_ p: CGPoint) -> Int? {
        for i in nodes.indices.reversed() {
            let s = toScreen(nodes[i].pos)
            let r = max(7, nodes[i].r * scale * nodeScale + 3)
            if (s.x - p.x) * (s.x - p.x) + (s.y - p.y) * (s.y - p.y) <= r * r { return i }
        }
        return nil
    }

    /// 滑鼠是否停在樹狀連線或派工箭頭上（回傳起點、終點 ID）。
    private func hitEdge(_ p: CGPoint) -> (from: UUID, to: UUID)? {
        var best: (from: UUID, to: UUID)?
        var bestDist = CGFloat(6.5)
        for n in nodes {
            var sources: [UUID] = []
            if let assignment = n.info.assignment, assignment.activeDispatch,
               let assigner = assignment.assignerID { sources.append(assigner) }
            if let parent = n.info.parent, !sources.contains(parent) { sources.append(parent) }
            for sourceID in sources where sourceID != n.id {
                guard let pi = index[sourceID] else { continue }
                let a = toScreen(nodes[pi].pos), b = toScreen(n.pos)
                let vx = b.x - a.x, vy = b.y - a.y
                let lenSq = vx * vx + vy * vy
                guard lenSq > 16 else { continue }
                let t = max(0.12, min(0.88, ((p.x - a.x) * vx + (p.y - a.y) * vy) / lenSq))
                let projX = a.x + t * vx, projY = a.y + t * vy
                let d = hypot(p.x - projX, p.y - projY)
                if d <= bestDist {
                    bestDist = d
                    best = (sourceID, n.id)
                }
            }
        }
        return best
    }

    // MARK: 畫

    private var isDarkTheme: Bool {
        if let themeOverride { return themeOverride == "dark" }
        return effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func stageColorName(_ stage: GraphAssignment.Stage) -> String {
        switch stage {
        case .dispatched: return "orange"
        case .working: return "green-breathe"
        case .review: return "blue"
        case .stuck: return "red"
        }
    }

    static func stageColorHex(_ stage: GraphAssignment.Stage, isDark: Bool) -> String {
        switch stage {
        case .dispatched: return isDark ? "#FF9F1C" : "#D96B00"
        case .working:    return isDark ? "#30D158" : "#1B8F3A"
        case .review:     return isDark ? "#4DA3FF" : "#0066CC"
        case .stuck:      return isDark ? "#FF453A" : "#C91F16"
        }
    }

    static func stageColor(_ stage: GraphAssignment.Stage, phase: Double, nodeID: UUID, isDark: Bool, lit: Bool) -> NSColor {
        let base: NSColor
        switch stage {
        case .dispatched:
            base = isDark
                ? NSColor(srgbRed: 1.00, green: 0.62, blue: 0.11, alpha: 1)
                : NSColor(srgbRed: 0.85, green: 0.42, blue: 0.00, alpha: 1)
        case .working:
            base = isDark
                ? NSColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 1)
                : NSColor(srgbRed: 0.11, green: 0.56, blue: 0.23, alpha: 1)
        case .review:
            base = isDark
                ? NSColor(srgbRed: 0.30, green: 0.64, blue: 1.00, alpha: 1)
                : NSColor(srgbRed: 0.00, green: 0.40, blue: 0.80, alpha: 1)
        case .stuck:
            base = isDark
                ? NSColor(srgbRed: 1.00, green: 0.27, blue: 0.23, alpha: 1)
                : NSColor(srgbRed: 0.79, green: 0.12, blue: 0.09, alpha: 1)
        }
        guard lit else { return base.withAlphaComponent(0.28) }
        if stage == .working {
            // 沿用現有綠圈呼吸節奏（phase * 3.2）
            let k = (sin(phase * 3.2 + Double(abs(nodeID.hashValue % 100)) * 0.1) + 1) / 2
            return base.withAlphaComponent(0.58 + 0.38 * CGFloat(k))
        }
        return base.withAlphaComponent(0.92)
    }

    private static func stateColor(_ s: RPState) -> NSColor {
        switch s {
        case .working: return .systemGreen
        case .waiting: return .systemOrange
        case .idle: return NSColor.systemBlue.withAlphaComponent(0.75)
        case .asleep: return NSColor.systemGray.withAlphaComponent(0.5)
        case .background: return NSColor.systemOrange.withAlphaComponent(0.75)
        case .stuck: return NSColor.systemRed
        }
    }

    private func color(_ n: Node) -> NSColor {
        switch n.info.kind {
        case .center: return Store.bundleAccent
        case .area:
            return n.info.isAreaLead ? Self.stateColor(n.info.state) : NSColor(hue: n.info.hue, saturation: 0.45, brightness: 0.85, alpha: 1)
        case .chat: return Self.stateColor(n.info.state)
        }
    }

    private static func stateColorName(_ node: GraphNodeInfo) -> String {
        switch node.kind {
        case .center: return "accent"
        case .area where !node.isAreaLead: return "area-hue"
        case .area, .chat:
            switch node.state {
            case .working: return "green"
            case .waiting, .background: return "orange"
            case .idle: return "blue"
            case .asleep: return "gray"
            case .stuck: return "red"
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let g = NSGraphicsContext.current?.cgContext else { return }
        if Self.isTestInstance && !isDumping { drawCountForTest += 1 }
        g.saveGState()
        defer { g.restoreGState() }
        g.clip(to: bounds)
        let isDark = isDarkTheme
        if themeOverride != nil {
            let bg = isDark
                ? NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1)
                : Theme.lightPanelBackground
            g.setFillColor(bg.cgColor)
            g.fill(bounds)
        }
        let primaryTextColor: NSColor = themeOverride == nil ? .labelColor : (isDark ? NSColor(white: 0.94, alpha: 1) : NSColor(white: 0.10, alpha: 1))
        let secondaryTextColor: NSColor = themeOverride == nil ? Theme.secondaryTextColor : (isDark ? NSColor(white: 0.72, alpha: 1) : NSColor(white: 0.36, alpha: 1))
        if nodes.isEmpty {
            lastDrawnNodeLabels = [:]
            lastDrawnEdgeLabels = [:]
            cachedLabelLayoutKey = nil
            cachedNodeLabels = []
            cachedEdgeLabels = []
            lastHoverCardRect = nil
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: secondaryTextColor]
            NSString(string: L("這一區沒有總指揮")).draw(at: CGPoint(x: 12, y: 10), withAttributes: a)
            return
        }
        let phase = CACurrentMediaTime()
        let sel = RightPanelModel.shared.selectedChat
        // 滑過去的節點：它自己、相連的亮，其他淡一點
        var near = Set<UUID>()
        if let h = hover, let hi = index[h] {
            near.insert(h)
            if let p = nodes[hi].info.parent { near.insert(p) }
            for n in nodes where n.info.parent == h { near.insert(n.id) }
            if let assignment = nodes[hi].info.assignment, assignment.activeDispatch,
               let source = assignment.assignerID { near.insert(source) }
            for n in nodes where n.info.assignment?.activeDispatch == true && n.info.assignment?.assignerID == h { near.insert(n.id) }
        }
        if let source = hoverEdgeFrom { near.insert(source) }
        if let hoverEdge { near.insert(hoverEdge) }
        if let hoverEdge, let hoverIndex = index[hoverEdge], nodes[hoverIndex].info.assignment?.activeDispatch == true,
           let source = nodes[hoverIndex].info.assignment?.assignerID {
            near.insert(source)
        }
        let dim = hover != nil
        let ns = nodeScale
        // 樹狀連線只依節點 parent 畫，保持原本的區域階層。
        for n in nodes {
            guard let p = n.info.parent, let pi = index[p] else { continue }
            let a = toScreen(nodes[pi].pos), b = toScreen(n.pos)
            let lineW = max(0.8, 1.2 * scale)
            let pad = lineW + 2
            let edgeBounds = CGRect(x: min(a.x, b.x) - pad, y: min(a.y, b.y) - pad,
                                    width: abs(b.x - a.x) + pad * 2, height: abs(b.y - a.y) + pad * 2)
            guard edgeBounds.intersects(dirtyRect) else { continue }
            let lit = !dim || (near.contains(n.id) && near.contains(p) && (hover == n.id || hover == p))
            g.setLineWidth(lineW)
            let base = nodes[pi].info.kind == .center ? secondaryTextColor : NSColor(hue: n.info.hue, saturation: 0.5, brightness: 0.85, alpha: 1)
            g.setStrokeColor(base.withAlphaComponent(lit ? 0.45 : 0.12).cgColor)
            g.move(to: a); g.addLine(to: b); g.strokePath()
        }
        // 派工箭頭直接連 assignerID 與聊天室；不參與 parent、座標或佈局簽章。
        for n in nodes {
            guard let assign = n.info.assignment,
                  assign.activeDispatch,
                  let assignerID = assign.assignerID, assignerID != n.id,
                  let pi = index[assignerID] else { continue }
            let a = toScreen(nodes[pi].pos), b = toScreen(n.pos)
            let pad = max(12.0, 10.0 * scale + 4.0)
            let edgeBounds = CGRect(x: min(a.x, b.x) - pad, y: min(a.y, b.y) - pad,
                                    width: abs(b.x - a.x) + pad * 2, height: abs(b.y - a.y) + pad * 2)
            guard edgeBounds.intersects(dirtyRect) else { continue }
            let lit = !dim || (near.contains(n.id) && near.contains(assignerID) && (hover == n.id || hover == assignerID))
            let col = Self.stageColor(assign.stage, phase: phase, nodeID: n.id, isDark: isDark, lit: lit)
            let k = (sin(phase * 3.2 + Double(abs(n.id.hashValue % 100)) * 0.1) + 1) / 2
            let lineW: CGFloat = assign.stage == .working
                ? max(1.6, (1.8 + 0.6 * CGFloat(k)) * scale)
                : max(1.6, 2.0 * scale)
            g.setLineWidth(lineW)
            g.setStrokeColor(col.cgColor)
            g.move(to: a); g.addLine(to: b); g.strokePath()

            let dx = b.x - a.x, dy = b.y - a.y
            let dist = hypot(dx, dy)
            let targetR = max(n.r * scale * ns, n.info.kind == .chat ? 3 : 5) + (n.info.isAreaLead ? 5 : 2)
            if dist > targetR + 12 {
                let ux = dx / dist, uy = dy / dist
                let tip = CGPoint(x: b.x - ux * (targetR + 1.5), y: b.y - uy * (targetR + 1.5))
                let arrowLen = max(6.5, min(10.0, 8.0 * scale))
                let arrowHalfW = arrowLen * 0.56
                let basePt = CGPoint(x: tip.x - ux * arrowLen, y: tip.y - uy * arrowLen)
                let leftPt = CGPoint(x: basePt.x - uy * arrowHalfW, y: basePt.y + ux * arrowHalfW)
                let rightPt = CGPoint(x: basePt.x + uy * arrowHalfW, y: basePt.y - ux * arrowHalfW)
                g.setFillColor(col.cgColor)
                g.beginPath()
                g.move(to: tip)
                g.addLine(to: leftPt)
                g.addLine(to: rightPt)
                g.closePath()
                g.fillPath()
            }
        }
        // 節點
        let showAll = nodes.count <= 45 || scale >= 0.9
        for n in nodes {
            let c = toScreen(n.pos)
            var r = n.r * scale * ns
            r = max(r, n.info.kind == .chat ? 3 : 5)
            let drawR = max(hasBreathingHalo(n) ? r * 2.0 : r, r + (n.info.isAreaLead ? 16 : 5)) + 3
            let nodeBounds = CGRect(x: c.x - drawR, y: c.y - drawR, width: drawR * 2, height: drawR * 2)
            guard nodeBounds.intersects(dirtyRect) else { continue }
            let faded = dim && !near.contains(n.id)
            let col = color(n).withAlphaComponent(faded ? 0.25 : 1)
            if n.info.state == .working && (n.info.kind != .area || n.info.isAreaLead) {
                let k = (sin(phase * 3.2 + Double(abs(n.id.hashValue % 100)) * 0.1) + 1) / 2      // 0…1 呼吸
                g.setFillColor(color(n).withAlphaComponent(0.18 + 0.22 * CGFloat(k)).cgColor)
                let hr = r * (1.5 + 0.5 * CGFloat(k))
                g.fillEllipse(in: CGRect(x: c.x - hr, y: c.y - hr, width: hr * 2, height: hr * 2))
            }
            g.setFillColor(col.cgColor)
            g.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            if !n.info.placed && n.info.kind == .chat {          // 沒擺在版面上的：空心一點
                let holeBg = themeOverride == nil ? NSColor.windowBackgroundColor : (isDark ? NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1) : Theme.lightPanelBackground)
                g.setFillColor(holeBg.withAlphaComponent(0.55).cgColor)
                g.fillEllipse(in: CGRect(x: c.x - r * 0.45, y: c.y - r * 0.45, width: r * 0.9, height: r * 0.9))
            }
            // 區長徽章：雙環 + 小皇冠
            if n.info.isAreaLead {
                let badgeCol = (isDark
                    ? NSColor(srgbRed: 1.00, green: 0.80, blue: 0.20, alpha: 1)
                    : NSColor(srgbRed: 0.82, green: 0.54, blue: 0.00, alpha: 1)).withAlphaComponent(faded ? 0.35 : 0.95)
                g.setStrokeColor(badgeCol.cgColor)
                g.setLineWidth(max(1.3, 1.5 * scale))
                let r1 = r + 2.5
                g.strokeEllipse(in: CGRect(x: c.x - r1, y: c.y - r1, width: r1 * 2, height: r1 * 2))
                g.setLineWidth(max(0.9, 1.0 * scale))
                let r2 = r + 4.8
                g.strokeEllipse(in: CGRect(x: c.x - r2, y: c.y - r2, width: r2 * 2, height: r2 * 2))
                // 節點上方小皇冠（flipped 座標系：y 越小越靠上）
                let cw = max(8.0, min(13.0, r * 1.45))
                let ch = max(5.0, min(8.5, r * 0.95))
                let baseY = c.y - r2 - 1.5
                let topY = baseY - ch
                let midY = baseY - ch * 0.45
                g.setFillColor(badgeCol.cgColor)
                g.beginPath()
                g.move(to: CGPoint(x: c.x - cw * 0.42, y: baseY))
                g.addLine(to: CGPoint(x: c.x - cw * 0.50, y: topY + ch * 0.15))
                g.addLine(to: CGPoint(x: c.x - cw * 0.18, y: midY))
                g.addLine(to: CGPoint(x: c.x, y: topY))
                g.addLine(to: CGPoint(x: c.x + cw * 0.18, y: midY))
                g.addLine(to: CGPoint(x: c.x + cw * 0.50, y: topY + ch * 0.15))
                g.addLine(to: CGPoint(x: c.x + cw * 0.42, y: baseY))
                g.closePath()
                g.fillPath()
            }
            if n.id == sel || (n.info.kind == .center && sel == n.id) {
                g.setStrokeColor(Store.bundleAccent.cgColor); g.setLineWidth(2)
                g.strokeEllipse(in: CGRect(x: c.x - r - 3, y: c.y - r - 3, width: (r + 3) * 2, height: (r + 3) * 2))
            } else if n.id == hover {
                g.setStrokeColor(primaryTextColor.withAlphaComponent(0.6).cgColor); g.setLineWidth(1)
                g.strokeEllipse(in: CGRect(x: c.x - r - 2, y: c.y - r - 2, width: (r + 2) * 2, height: (r + 2) * 2))
            }
        }
        // 標籤與派工線膠囊排版結果快取：只剩呼吸動畫重畫局部 dirtyRect 時沿用已算好的座標與碰撞結果，
        // 避免每個 15 Hz tick 重做 O(N²) 碰撞檢測與大量文字量寬。
        let layoutKey = LabelLayoutKey(
            generation: labelLayoutGeneration,
            boundsWidth: bounds.width,
            boundsHeight: bounds.height,
            scale: scale,
            offsetX: offset.x,
            offsetY: offset.y,
            big: big,
            isDark: isDark,
            themeOverride: themeOverride,
            hover: hover,
            hoverEdge: hoverEdge,
            hoverEdgeFrom: hoverEdgeFrom,
            selectedChat: sel
        )
        if cachedLabelLayoutKey != layoutKey {
            lastDrawnNodeLabels = [:]
            lastDrawnEdgeLabels = [:]
            var nextNodeLabels: [CachedNodeLabel] = []
            var nextEdgeLabels: [CachedEdgeLabel] = []
            // 標籤：依重要程度排隊（中心、區、滑過／選取、區長、工作中、其他），每個試「下、上、右、左」四個位置，
            // 都會跟已畫的標籤或節點重疊就不畫（滑過／選取的一定畫）
            func rank(_ n: Node) -> Int {
                if n.id == hover || n.id == sel { return 0 }
                switch n.info.kind { case .center: return 1; case .area: return 2; case .chat: break }
                if n.info.isAreaLead { return 2 }
                return n.info.state == .working || n.info.state == .waiting || n.info.assignment != nil ? 3 : 4
            }
            var placed: [CGRect] = nodes.map { n in
                let c = toScreen(n.pos), r = max(n.r * scale * ns, n.info.kind == .chat ? 3 : 5) + (n.info.isAreaLead ? 5 : 1)
                return CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            }
            for n in nodes.sorted(by: { rank($0) < rank($1) }) {
                let hot = n.id == hover || n.id == sel
                let faded = dim && !near.contains(n.id)
                guard n.info.kind != .chat || showAll || hot else { continue }
                let size: CGFloat = (n.info.kind == .center ? 12 : n.info.kind == .area ? 11 : 10) * (big ? 1.25 : 1)
                let weight: NSFont.Weight = (n.info.kind == .chat && !n.info.isAreaLead) ? .regular : .semibold
                let col: NSColor = n.info.kind == .chat ? secondaryTextColor : primaryTextColor
                let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: hot ? size + 1 : size, weight: hot ? .semibold : weight),
                                                        .foregroundColor: (hot ? primaryTextColor : col).withAlphaComponent(faded ? 0.3 : 1)]
                let maxLabelWidth = max(1, bounds.width - 8)
                var displayTitle = n.info.title
                var sz = (displayTitle as NSString).size(withAttributes: a)
                if sz.width > maxLabelWidth {
                    var prefix = Array(displayTitle)
                    repeat {
                        if !prefix.isEmpty { prefix.removeLast() }
                        displayTitle = String(prefix) + "…"
                        sz = (displayTitle as NSString).size(withAttributes: a)
                    } while sz.width > maxLabelWidth && !prefix.isEmpty
                }
                let c = toScreen(n.pos)
                let r = max(n.r * scale * ns, n.info.kind == .chat ? 3 : 5) + (n.info.isAreaLead ? 5 : 0)
                let spots = [CGPoint(x: c.x - sz.width / 2, y: c.y + r + 2), CGPoint(x: c.x - sz.width / 2, y: c.y - r - 2 - sz.height),
                             CGPoint(x: c.x + r + 3, y: c.y - sz.height / 2), CGPoint(x: c.x - r - 3 - sz.width, y: c.y - sz.height / 2)]
                var chosen: CGPoint?
                for p in spots {
                    let rect = CGRect(origin: p, size: sz).insetBy(dx: -2, dy: -1)
                    // 自己的節點圓不算（它的圓一定在 placed 裡，標籤本來就貼著它）
                    if !placed.contains(where: { $0.intersects(rect) && !($0.width <= (r + 2) * 2 + 2 && abs($0.midX - c.x) < 0.5 && abs($0.midY - c.y) < 0.5) }) { chosen = p; break }
                }
                if chosen == nil && hot { chosen = spots[0] }
                guard let chosen else { continue }
                let inset: CGFloat = 4
                let maxX = max(inset, bounds.maxX - inset - sz.width)
                let maxY = max(inset, bounds.maxY - inset - sz.height)
                let p = CGPoint(x: min(max(chosen.x, bounds.minX + inset), maxX),
                                y: min(max(chosen.y, bounds.minY + inset), maxY))
                let frame = CGRect(origin: p, size: sz)
                nextNodeLabels.append(CachedNodeLabel(id: n.id, displayTitle: displayTitle, fullTitle: n.info.title, origin: p, frame: frame, attrs: a))
                lastDrawnNodeLabels[n.id] = DrawnNodeLabel(frame: frame, text: displayTitle, fullTitle: n.info.title)
                placed.append(frame.insetBy(dx: -2, dy: -1))
            }

            // 連線中點工作短名標籤（≤12 字，與節點標籤共用 placed 碰撞避讓，放不下就只在滑過時顯示）
            let edgeNodes = nodes.filter { $0.info.assignment?.activeDispatch == true }.sorted { a, b in
                let ha = (a.id == hover || a.id == hoverEdge || a.id == sel) ? 0 : 1
                let hb = (b.id == hover || b.id == hoverEdge || b.id == sel) ? 0 : 1
                return ha < hb
            }
            for n in edgeNodes {
                guard let assign = n.info.assignment,
                      !assign.shortTitle.isEmpty,
                      let p = assign.assignerID, p != n.id, let pi = index[p] else { continue }
                let a = toScreen(nodes[pi].pos), b = toScreen(n.pos)
                let dx = b.x - a.x, dy = b.y - a.y
                let dist = hypot(dx, dy)
                let hot = (hover == n.id || hoverEdge == n.id || sel == n.id)
                guard dist >= 28 || hot else { continue }
                let faded = dim && !near.contains(n.id)
                let fontSize: CGFloat = (big ? 11 : 9.5)
                let textCol = (isDark ? NSColor(white: 0.95, alpha: 1) : NSColor(white: 0.12, alpha: 1)).withAlphaComponent(faded ? 0.35 : 0.95)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                    .foregroundColor: textCol
                ]
                let str = NSString(string: assign.shortTitle)
                let sz = str.size(withAttributes: attrs)
                let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                let nx = dist > 1 ? -dy / dist : 0
                let ny = dist > 1 ? dx / dist : -1
                var candidateCenters = [mid]
                // 區長併入區節點後，多條派工線會共用一個起點；較長的區標籤可能佔住線段中點，
                // 因此往線段兩側多找幾層位置，避免某一階段標籤被整個省略。
                for offset in [sz.height * 0.75 + 4, sz.height + 12, sz.height + 24, sz.height + 36,
                               sz.height + 48, sz.height + 64, sz.height + 80, sz.height + 96] {
                    candidateCenters.append(CGPoint(x: mid.x + nx * offset, y: mid.y + ny * offset))
                    candidateCenters.append(CGPoint(x: mid.x - nx * offset, y: mid.y - ny * offset))
                }
                for t in [0.25, 0.75, 0.15, 0.85, 0.35, 0.65] {
                    let point = CGPoint(x: a.x + dx * t, y: a.y + dy * t)
                    for offset in [sz.height + 8, sz.height + 20, sz.height + 36, sz.height + 52, sz.height + 68] {
                        candidateCenters.append(CGPoint(x: point.x + nx * offset, y: point.y + ny * offset))
                        candidateCenters.append(CGPoint(x: point.x - nx * offset, y: point.y - ny * offset))
                    }
                }
                var chosenOrigin: CGPoint?
                for center in candidateCenters {
                    let origin = CGPoint(x: center.x - sz.width / 2, y: center.y - sz.height / 2)
                    let pillRect = CGRect(origin: origin, size: sz).insetBy(dx: -4, dy: -1.5)
                    if !placed.contains(where: { $0.intersects(pillRect) }) {
                        chosenOrigin = origin
                        break
                    }
                }
                if chosenOrigin == nil && hot {
                    chosenOrigin = CGPoint(x: mid.x - sz.width / 2, y: mid.y - sz.height / 2)
                }
                guard let origin = chosenOrigin else { continue }
                let pillRect = CGRect(origin: origin, size: sz).insetBy(dx: -4, dy: -1.5)
                nextEdgeLabels.append(CachedEdgeLabel(id: n.id, shortTitle: assign.shortTitle, stage: assign.stage, faded: faded, origin: origin, pillRect: pillRect, attrs: attrs))
                placed.append(pillRect)
                lastDrawnEdgeLabels[n.id] = assign.shortTitle
            }
            cachedNodeLabels = nextNodeLabels
            cachedEdgeLabels = nextEdgeLabels
            cachedLabelLayoutKey = layoutKey
        }

        for item in cachedNodeLabels {
            guard item.frame.insetBy(dx: -2, dy: -2).intersects(dirtyRect) else { continue }
            (item.displayTitle as NSString).draw(at: item.origin, withAttributes: item.attrs)
        }
        for item in cachedEdgeLabels {
            guard item.pillRect.insetBy(dx: -2, dy: -2).intersects(dirtyRect) else { continue }
            let stageCol = Self.stageColor(item.stage, phase: phase, nodeID: item.id, isDark: isDark, lit: !item.faded)
            let pillBg = (isDark
                ? NSColor(srgbRed: 0.14, green: 0.15, blue: 0.18, alpha: 0.88)
                : NSColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 0.90)).withAlphaComponent(item.faded ? 0.35 : 0.90)
            let path = CGPath(roundedRect: item.pillRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
            g.setFillColor(pillBg.cgColor)
            g.addPath(path); g.fillPath()
            g.setStrokeColor(stageCol.withAlphaComponent(item.faded ? 0.25 : 0.75).cgColor)
            g.setLineWidth(1.0)
            g.addPath(path); g.strokePath()
            (item.shortTitle as NSString).draw(at: item.origin, withAttributes: item.attrs)
        }

        // 滑過節點或連線時顯示工作分配小卡
        if let h = hover, let hi = index[h], let assign = nodes[hi].info.assignment {
            drawHoverCard(g: g, node: nodes[hi], assign: assign, isDark: isDark, phase: phase)
        } else {
            lastHoverCardRect = nil
        }
    }

    private func drawHoverCard(g: CGContext, node: Node, assign: GraphAssignment, isDark: Bool, phase: Double) {
        let titleFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let rowFont = NSFont.systemFont(ofSize: 10, weight: .regular)
        let labelFont = NSFont.systemFont(ofSize: 10, weight: .medium)
        let textCol = isDark ? NSColor(white: 0.95, alpha: 1) : NSColor(white: 0.10, alpha: 1)
        let subCol = isDark ? NSColor(white: 0.70, alpha: 1) : NSColor(white: 0.38, alpha: 1)
        let stageCol = Self.stageColor(assign.stage, phase: phase, nodeID: node.id, isDark: isDark, lit: true)

        let rows: [(String, String, NSColor)] = [
            (L("工作名稱"), assign.taskTitle, textCol),
            (L("階段"), assign.stage.label, stageCol),
            (L("多久了"), assign.elapsedText, textCol),
            (L("最後動作"), assign.lastAction, textCol),
            (L("誰派的"), assign.assignerName, textCol)
        ]

        let headerStr = NSString(string: node.info.rawTitle)
        let headerAttrs: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: textCol]
        var maxW = max(130, headerStr.size(withAttributes: headerAttrs).width)
        let labelW: CGFloat = 46
        for (_, val, _) in rows {
            let s = NSString(string: val).size(withAttributes: [.font: rowFont])
            maxW = max(maxW, labelW + s.width)
        }
        let cardW = min(max(bounds.width - 16, 150), min(250, maxW + 20))
        let lineH: CGFloat = 14
        let cardH: CGFloat = 22 + CGFloat(rows.count) * lineH + 8

        let anchor: CGPoint
        if hoverEdge == node.id, node.info.assignment?.activeDispatch == true,
           let p = node.info.assignment?.assignerID, p != node.id, let pi = index[p] {
            let a = toScreen(nodes[pi].pos), b = toScreen(node.pos)
            anchor = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        } else {
            anchor = toScreen(node.pos)
        }
        var cx = anchor.x + 12
        var cy = anchor.y + 10
        if cx + cardW > bounds.maxX - 6 { cx = max(bounds.minX + 6, anchor.x - cardW - 12) }
        if cy + cardH > bounds.maxY - 6 { cy = max(bounds.minY + 6, bounds.maxY - cardH - 6) }
        let cardRect = CGRect(x: cx, y: cy, width: cardW, height: cardH)
        lastHoverCardRect = cardRect

        let bg = isDark
            ? NSColor(srgbRed: 0.15, green: 0.16, blue: 0.20, alpha: 0.96)
            : NSColor(srgbRed: 0.99, green: 0.99, blue: 1.00, alpha: 0.96)
        let path = CGPath(roundedRect: cardRect, cornerWidth: 7, cornerHeight: 7, transform: nil)
        g.setFillColor(bg.cgColor)
        g.addPath(path); g.fillPath()
        g.setStrokeColor(stageCol.withAlphaComponent(0.75).cgColor)
        g.setLineWidth(1.2)
        g.addPath(path); g.strokePath()

        headerStr.draw(in: CGRect(x: cx + 9, y: cy + 6, width: cardW - 18, height: 15), withAttributes: headerAttrs)
        var ry = cy + 23
        let pStyle = NSMutableParagraphStyle()
        pStyle.lineBreakMode = .byTruncatingTail
        for (k, v, vCol) in rows {
            NSString(string: k).draw(at: CGPoint(x: cx + 9, y: ry), withAttributes: [.font: labelFont, .foregroundColor: subCol])
            NSString(string: v).draw(
                in: CGRect(x: cx + 9 + labelW, y: ry, width: cardW - 16 - labelW, height: lineH),
                withAttributes: [.font: rowFont, .foregroundColor: vCol, .paragraphStyle: pStyle]
            )
            ry += lineH
        }
    }

    // MARK: 滑鼠

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { updateHover(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { setHover(nil) }

    private func updateHover(_ p: CGPoint) {
        if let hi = hit(p) {
            setHover(nodes[hi].id)
        } else if let edge = hitEdge(p) {
            setHover(edge.to, edgeFrom: edge.from)
        } else {
            setHover(nil)
        }
    }

    private func setHover(_ id: UUID?, edgeFrom: UUID? = nil) {
        let edgeTo = edgeFrom == nil ? nil : id
        guard id != hover || edgeTo != hoverEdge || edgeFrom != hoverEdgeFrom else { return }
        let nodeChanged = id != hover
        if nodeChanged, let old = hover { ChatInfoCard.shared.hoverEnded(old) }
        hover = id
        hoverEdge = edgeTo
        hoverEdgeFrom = edgeFrom
        if nodeChanged, let id, let store, let workspace, store.conversation(id) != nil {
            if let i = index[id], nodes[i].info.assignment != nil {
                ChatInfoCard.shared.cancel() // 關聯圖內已畫工作卡，避免再疊一張置中資訊卡
            } else {
                ChatInfoCard.shared.hoverBegan(id, store: store, workspace: workspace, window: window)
            }
        }
        if id == nil { lastHoverCardRect = nil }
        invalidateFullDisplay()
    }

    private(set) var dbgDowns = 0, dbgHit = ""
    override func mouseDown(with event: NSEvent) {
        dbgDowns += 1
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        downPoint = p; lastDrag = p; dragged = false
        downNode = hit(p).map { nodes[$0].id }
        dbgHit = "\(p) → \(hit(p).map { nodes[$0].info.title } ?? "nil")"
        ChatInfoCard.shared.cancel()
        if let id = downNode, store?.conversation(id) != nil { RightPanelModel.shared.selectedChat = id }
        if event.clickCount == 2 {
            if let id = downNode { if store?.conversation(id) != nil { onSummon?(id) } }
            else { refit() }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !dragged, hypot(p.x - downPoint.x, p.y - downPoint.y) < 3 { return }
        dragged = true
        if let id = downNode, let i = index[id] {
            nodes[i].pos = toWorld(p); nodes[i].pinned = true; nodes[i].vel = .zero
            alpha = max(alpha, 0.3)
            labelLayoutGeneration &+= 1
        } else {
            offset.x += p.x - lastDrag.x; offset.y += p.y - lastDrag.y
            userMoved = true; fitting = false
        }
        lastDrag = p
        invalidateFullDisplay()
        updateTimer()
    }

    override func mouseUp(with event: NSEvent) { downNode = nil; dragged = false; rememberViewport() }

    override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas && !event.modifierFlags.contains(.command) {
            offset.x += event.scrollingDeltaX; offset.y += event.scrollingDeltaY      // 觸控板兩指＝平移
            userMoved = true; fitting = false
            rememberViewport()
            invalidateFullDisplay()
        } else {
            zoom(by: exp(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.06)), at: convert(event.locationInWindow, from: nil))
        }
    }

    override func magnify(with event: NSEvent) { zoom(by: 1 + event.magnification, at: convert(event.locationInWindow, from: nil)) }

    private func zoom(by f: CGFloat, at p: CGPoint) {
        let w = toWorld(p)
        scale = min(5, max(0.15, scale * f))
        // 縮放後讓游標底下的點不動
        offset.x = p.x - bounds.midX - w.x * scale; offset.y = p.y - bounds.midY - w.y * scale
        userMoved = true; fitting = false
        rememberViewport()
        invalidateFullDisplay()
    }

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        if plain, event.charactersIgnoringModifiers?.lowercased() == "i", let id = RightPanelModel.shared.selectedChat, store?.conversation(id) != nil {
            ChatInfoCard.shared.cancel(); onInfo?(id); return
        }
        if event.keyCode == 53, let onEscape { onEscape(); return }
        super.keyDown(with: event)
    }

    // MARK: 右鍵選單（跟列表同一套）

    private final class MenuAction: NSObject {
        let fn: () -> Void
        init(_ fn: @escaping () -> Void) { self.fn = fn }
        @objc func run() { fn() }
    }

    private func item(_ title: String, checked: Bool = false, _ fn: @escaping () -> Void) -> NSMenuItem {
        let a = MenuAction(fn); menuActions.append(a)
        let it = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
        it.target = a; it.state = checked ? .on : .off
        return it
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuActions = []
        let p = convert(event.locationInWindow, from: nil)
        guard let hi = hit(p), let store else {
            let m = NSMenu()
            m.addItem(item(L("版面…")) { [weak self] in self?.onLayoutRequested?() })
            return m
        }
        let n = nodes[hi]
        ChatInfoCard.shared.cancel()
        guard let c = store.conversation(n.id) else { return nil }       // 區節點沒有選單
        RightPanelModel.shared.selectedChat = c.id
        let id = c.id
        let chief = n.info.kind == .center
        let m = NSMenu()
        m.addItem(item(L("叫出來")) { [weak self] in self?.onSummon?(id) })
        m.addItem(item(L("聊天室資訊…")) { [weak self] in self?.onInfo?(id) })
        m.addItem(item(L("重新命名…")) { [weak self] in self?.promptRename(id) })
        if !store.groups.isEmpty {
            if !chief, let s = store.currentSessionLayout {
                let areas = NSMenu()
                let nodes = store.areaNodes(s)
                if let root = store.areaRoot(s) {
                    areas.addItem(item(L("（總指揮本身）"), checked: store.areaID(of: c, in: nodes) == nil) { store.move(id, toGroup: root) })
                }
                for a in nodes {
                    areas.addItem(item(String(repeating: "　", count: a.depth - 1) + a.group.name, checked: store.groupOf(c) == a.group.id) { store.move(id, toGroup: a.group.id) })
                }
                let top = NSMenuItem(title: L("移到區…"), action: nil, keyEquivalent: ""); top.submenu = areas
                m.addItem(top)
            }
            let move = NSMenu()
            for t in store.groupTree() {
                move.addItem(item(String(repeating: "　", count: t.depth) + t.group.name, checked: store.groupOf(c) == t.group.id) { store.move(id, toGroup: t.group.id) })
            }
            let top = NSMenuItem(title: L("移到…"), action: nil, keyEquivalent: ""); top.submenu = move
            m.addItem(top)
            let arch = store.isArchived(c)
            m.addItem(item(arch ? L("取消封存") : L("封存")) { store.setArchived(id, !arch) })
        }
        if Store.isChat(c) {
            let mcp = NSMenu()
            for mode in McpMode.allCases { mcp.addItem(item(mode.label, checked: McpMode.from(c.mcp) == mode) { store.setMcp(id, mode) }) }
            let top = NSMenuItem(title: L("MCP（下次啟動生效）"), action: nil, keyEquivalent: ""); top.submenu = mcp
            m.addItem(top)
        }
        if !chief {
            m.addItem(item(L("讓總指揮改名"), checked: c.commanderMayRename == true) { store.setCommanderMayRename(id, c.commanderMayRename != true) })
        }
        return m
    }

    private func promptRename(_ id: UUID) {
        guard let store, let c = store.conversation(id) else { return }
        let a = NSAlert()
        a.messageText = L("重新命名對話")
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        f.stringValue = c.title
        a.accessoryView = f
        a.addButton(withTitle: L("好")); a.addButton(withTitle: L("取消"))
        a.window.initialFirstResponder = f
        if a.runModal() == .alertFirstButtonReturn { store.rename(id, to: f.stringValue, byUser: true) }
    }

    // MARK: 測試用

    /// 測試：節點（標題）中心的視窗座標（左下原點）
    var hasNodesForTest: Bool { !nodes.isEmpty }

    /// 只供 --state-dir 探針把標籤節點放到畫布最左側，驗證文字框會被完整收進畫布。
    func placeNodeAtScreenPointForTest(title: String, point: CGPoint) {
        guard CommandLine.arguments.contains("--state-dir"),
              let i = nodes.firstIndex(where: { $0.info.title == title || $0.info.rawTitle == title }) else { return }
        nodes[i].pos = toWorld(point)
        nodes[i].pinned = true
        nodes[i].vel = .zero
        userMoved = true
        labelLayoutGeneration &+= 1
        invalidateFullDisplay()
    }

    func windowPoint(title: String) -> CGPoint? {
        guard let n = nodes.first(where: { $0.info.title == title || $0.info.rawTitle == title }) else { return nil }
        return convert(toScreen(n.pos), to: nil)
    }

    /// 測試：模擬滑過節點（透過真實 hit(p) 座標命中）
    func simulateHover(nodeTitle: String) {
        guard let n = nodes.first(where: { $0.info.title == nodeTitle || $0.info.rawTitle == nodeTitle }) else {
            setHover(nil); return
        }
        updateHover(toScreen(n.pos))
    }

    /// 測試：模擬滑過連線中點（透過真實 hitEdge(p) 線段命中）
    func simulateEdgeHover(toTitle: String) {
        guard let n = nodes.first(where: { $0.info.title == toTitle || $0.info.rawTitle == toTitle }),
              let p = (n.info.assignment?.activeDispatch == true ? n.info.assignment?.assignerID : nil) ?? n.info.parent,
              p != n.id, let pi = index[p] else {
            setHover(nil); return
        }
        let a = toScreen(nodes[pi].pos), b = toScreen(n.pos)
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        updateHover(mid)
    }

    /// --dump-graph：節點與位置
    func dump() -> [String: Any] {
        let saved = alpha; let savedNodes = nodes; alpha = 0
        let t0 = CACurrentMediaTime()
        for _ in 0..<20 { step() }
        let stepMs = (CACurrentMediaTime() - t0) / 20 * 1000
        nodes = savedNodes; alpha = saved
        let d0 = CACurrentMediaTime()
        let rep = bitmapImageRepForCachingDisplay(in: bounds)
        if let rep {
            isDumping = true
            cacheDisplay(in: bounds, to: rep)
            isDumping = false
        }
        let drawMs = (CACurrentMediaTime() - d0) * 1000
        var minX = CGFloat.infinity, maxX = -CGFloat.infinity, minY = CGFloat.infinity, maxY = -CGFloat.infinity
        for n in nodes {
            let half = max(n.r, n.lw * nodeScale / max(0.001, scale) / 2)
            minX = min(minX, n.pos.x - half); maxX = max(maxX, n.pos.x + half)
            minY = min(minY, n.pos.y - n.r); maxY = max(maxY, n.pos.y + n.r + 18 / max(0.001, scale))
        }
        let visualCenter = nodes.isEmpty ? CGPoint.zero : toScreen(CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2))
        let vb = visualBoundsInView() ?? .zero
        let isDark = isDarkTheme
        let treeEdges: [[String: Any]] = nodes.compactMap { n in
            guard let p = n.info.parent, let pi = index[p] else { return nil }
            let fromNode = nodes[pi]
            return ["from": fromNode.info.rawTitle, "to": n.info.rawTitle,
                    "fromID": fromNode.info.id.uuidString.lowercased(), "toID": n.info.id.uuidString.lowercased(),
                    "hasArrow": false, "arrowDirection": "", "label": "",
                    "labelDrawn": false, "stage": "idle", "color": "default", "kind": "tree"]
        }
        let assignmentEdges: [[String: Any]] = nodes.compactMap { n in
            guard let assign = n.info.assignment,
                  assign.activeDispatch,
                  let assignerID = assign.assignerID, assignerID != n.id,
                  let fromNode = index[assignerID].map({ nodes[$0] }) else { return nil }
            return [
                "from": fromNode.info.rawTitle,
                "to": n.info.rawTitle,
                "fromID": assignerID.uuidString.lowercased(),
                "toID": n.info.id.uuidString.lowercased(),
                "hasArrow": true,
                "arrowDirection": "\(fromNode.info.rawTitle)->\(n.info.rawTitle)",
                "label": assign.shortTitle,
                "fullTitle": assign.taskTitle,
                "labelDrawn": lastDrawnEdgeLabels[n.id] != nil,
                "stage": assign.stage.rawValue,
                "stageLabel": assign.stage.label,
                "color": Self.stageColorName(assign.stage),
                "strokeHex": Self.stageColorHex(assign.stage, isDark: isDark),
                "elapsed": assign.elapsedText,
                "lastAction": assign.lastAction,
                "assigner": assign.assignerName,
                "active": true,
                "collected": false,
                "kind": "assignment"
            ]
        }
        let assignmentDispatches: [[String: Any]] = nodes.compactMap { n in
            guard let assign = n.info.assignment, let assignerID = assign.assignerID, assignerID != n.id else { return nil }
            return [
                "from": index[assignerID].map { nodes[$0].info.rawTitle } ?? assign.assignerName,
                "to": n.info.rawTitle,
                "fromID": assignerID.uuidString.lowercased(),
                "toID": n.info.id.uuidString.lowercased(),
                "label": assign.shortTitle,
                "active": assign.activeDispatch,
                "collected": !assign.activeDispatch,
                "closedReason": assign.dispatchClosedReason ?? "",
                "kind": "assignment"
            ]
        }
        let edgesOut = treeEdges + assignmentEdges
        var hoverCardOut: [String: Any] = [:]
        if let h = hover, let hi = index[h], let assign = nodes[hi].info.assignment {
            hoverCardOut = [
                "visible": true,
                "target": nodes[hi].info.rawTitle,
                "viaEdge": hoverEdge == h,
                "task": assign.taskTitle,
                "stage": assign.stage.label,
                "stageRaw": assign.stage.rawValue,
                "elapsed": assign.elapsedText,
                "lastAction": assign.lastAction,
                    "assigner": assign.assignerName,
                    "assignerID": assign.assignerID.flatMap { self.index[$0].map { self.nodes[$0].info.rawTitle } } ?? ""
            ]
        }
        let out: [String: Any] = ["sessionID": activeSessionID?.uuidString ?? "",
         "isDark": isDark,
         "bounds": ["x": bounds.minX, "y": bounds.minY, "width": bounds.width, "height": bounds.height],
         "visualBounds": ["x": Double(vb.minX), "y": Double(vb.minY), "width": Double(vb.width), "height": Double(vb.height)],
         "allNodesVisible": viewportFits(), "viewport": ["scale": Double(scale), "x": Double(offset.x), "y": Double(offset.y), "userMoved": userMoved],
         "visualCenter": ["x": Double(visualCenter.x), "y": Double(visualCenter.y)],
         "nodes": nodes.map { n -> [String: Any] in
             let representedID = n.info.representedConversationID ?? (n.info.kind == .chat || n.info.kind == .center ? n.info.id : nil)
             let representative = representedID.flatMap { store?.conversation($0)?.title } ?? ""
             var d: [String: Any] = [
                 "nodeID": n.info.id.uuidString.lowercased(),
                 "title": n.info.title,
                 "label": n.info.title,
                 "rawTitle": n.info.rawTitle,
                 "kind": "\(n.info.kind)",
                 "state": n.info.state.rawValue,
                 "stateColor": Self.stateColorName(n.info),
                 "x": Int(n.pos.x), "y": Int(n.pos.y), "r": Int(n.r),
                 "fx": Double(n.pos.x), "fy": Double(n.pos.y), "lw": Double(n.lw),
                 "cr": Double(collisionRadius(n)),
                 "isAreaLead": n.info.isAreaLead,
                 "areaGroupID": n.info.areaGroupID?.uuidString.lowercased() ?? "",
                 "representedConversationID": representedID?.uuidString.lowercased() ?? "",
                 "representative": representative,
                 "clickTarget": store?.conversation(n.info.id)?.title ?? "",
                 "areaLeadName": n.info.areaLeadName ?? "",
                 "badge": n.info.isAreaLead ? "crown+double-ring" : "",
                 "parent": n.info.parent.flatMap { p in self.index[p].map { self.nodes[$0].info.rawTitle } } ?? ""
             ]
             if let label = lastDrawnNodeLabels[n.info.id] {
                 d["drawnLabel"] = label.text
                 d["labelWasTruncated"] = label.text != label.fullTitle
                 d["labelFrame"] = ["x": Double(label.frame.minX), "y": Double(label.frame.minY),
                                    "width": Double(label.frame.width), "height": Double(label.frame.height)]
                 d["labelFrameInsideCanvas"] = bounds.insetBy(dx: 0.01, dy: 0.01).contains(label.frame)
             } else {
                 d["drawnLabel"] = ""
                 d["labelWasTruncated"] = false
                 d["labelFrame"] = NSNull()
                 d["labelFrameInsideCanvas"] = false
             }
             if let assign = n.info.assignment {
                 d["assignment"] = [
                     "taskTitle": assign.taskTitle,
                     "shortTitle": assign.shortTitle,
                     "stage": assign.stage.rawValue,
                     "stageLabel": assign.stage.label,
                     "elapsed": assign.elapsedText,
                     "lastAction": assign.lastAction,
                    "assigner": assign.assignerName,
                    "activeDispatch": assign.activeDispatch,
                    "dispatchClosedReason": assign.dispatchClosedReason ?? ""
                 ]
             }
             return d
         },
         "edges": edgesOut,
         "dispatches": assignmentDispatches,
         "hoverCard": hoverCardOut,
         "downs": dbgDowns, "lastHit": dbgHit, "stepMs": stepMs, "drawMs": drawMs, "scale": scale, "alpha": alpha, "timerRunning": timer != nil, "anyWorking": anyWorking]
        return out
    }
}

/// 把 ChatGraphView 放進 SwiftUI：每次 store 有變就把最新快照丟進去
struct ChatGraphRepresentable: NSViewRepresentable {
    @ObservedObject var store: Store
    let workspace: Workspace
    var big = false
    var isOverlay = false
    var onSummon: (UUID) -> Void
    var onInfo: (UUID) -> Void
    var onEscape: (() -> Void)?
    var onCreate: ((ChatGraphView) -> Void)?
    var onLayoutRequested: (() -> Void)?

    func makeNSView(context: Context) -> ChatGraphView {
        let v = ChatGraphView(frame: .zero)
        onCreate?(v)
        v.big = big; v.isOverlay = isOverlay
        if !isOverlay { ChatGraphView.rightInstance = v }
        configure(v)
        v.apply(RPData.graph(store, workspace: workspace))
        return v
    }

    func updateNSView(_ v: ChatGraphView, context: Context) {
        configure(v)
        v.apply(RPData.graph(store, workspace: workspace))
    }

    private func configure(_ v: ChatGraphView) {
        v.store = store; v.workspace = workspace
        v.onSummon = onSummon; v.onInfo = onInfo; v.onEscape = onEscape; v.onLayoutRequested = onLayoutRequested
    }

    static func dismantleNSView(_ v: ChatGraphView, coordinator: ()) { v.updateTimer() }
}

struct GraphLayoutControls: View {
    @ObservedObject var store: Store
    let sessionID: UUID?
    private var current: GraphLayoutSettings {
        store.sessions.first(where: { $0.id == sessionID })?.graphLayout ?? .defaults
    }

    private func set(_ keyPath: WritableKeyPath<GraphLayoutSettings, Double>, _ value: Double) {
        guard let sessionID else { return }
        var next = current
        next[keyPath: keyPath] = value
        store.setGraphLayout(next, sessionID: sessionID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("關聯圖版面")).font(.headline)
            setting(L("總指揮 → 第一層區"), value: current.commanderToArea, range: 50...220) { set(\.commanderToArea, $0) }
            setting(L("區 → 子區"), value: current.areaToSubarea, range: 40...180) { set(\.areaToSubarea, $0) }
            setting(L("區 → 聊天室"), value: current.areaToChat, range: 30...150) { set(\.areaToChat, $0) }
            setting(L("節點互相推開"), value: current.repulsion, range: 300...4200, step: 100) { set(\.repulsion, $0) }
            Button(L("恢復預設")) { if let sessionID { store.setGraphLayout(.defaults, sessionID: sessionID) } }
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(14)
        .frame(width: 270)
    }

    private func setting(_ title: String, value: Double, range: ClosedRange<Double>, step: Double = 5, onChange: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack { Text(title); Spacer(); Text("\(Int(value))").monospacedDigit().foregroundStyle(.secondary) }
                .font(.system(size: 11))
            Slider(value: Binding(get: { value }, set: onChange), in: range, step: step)
        }
    }
}
