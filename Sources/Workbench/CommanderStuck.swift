import AppKit
import Combine

/// 總指揮派工的無輸出監督。只有有未完成派工的工作聊天室會進入自動處理。
final class CommanderStuck: ObservableObject {
    enum CommanderEscalationReason: Equatable { case noAreaLead, areaLeadInvalid, areaLeadTimeout }
    enum Escalation { case areaLead, commander(CommanderEscalationReason), none }

    private enum Stage: Equatable {
        case watching
        case nudged
        case stopping
        case waitingForNotice
        case retried
        case notified
    }

    private struct Watch {
        var lastOutput: Date
        var incidentStartedAt: Date
        var stage: Stage = .watching
        var stageStartedAt: Date
        var pauseStartedAt: Date?
        var retryDeadline: Date?
        var assignerID: UUID
        var dispatchMessageID: String
        var dispatchSequence: Int
        var retryText: String?
        var noticeAt: Date?
        var leadOutputAtNotice: Date?
        var escalated = false
        var toolExecutionStartedAt: Date?
        var toolInterruptSkipLogged = false
    }

    private struct StageEvent {
        let stage: String
        let recipient: String
        let text: String
        let at: Date
        let elapsed: TimeInterval
        var childAliveAtNotice: Bool? = nil
    }

    struct AreaLeadInterruptDecision {
        let accepted: Bool
        let reason: String
        let message: String
    }

    static let shared = CommanderStuck()
    @Published private(set) var stuckMinutes: [UUID: Int] = [:]
    private var lastOutput: [UUID: Date] = [:]
    private var lastAction: [UUID: String] = [:]
    private var areaNotifiedAt: [UUID: Date] = [:]
    private var chiefNotified = Set<UUID>()
    /// 只有觀察到該聊天室實際開始一輪後，一般停止結果才會升級給總指揮。
    private var guards = Set<UUID>()
    private var watches: [UUID: Watch] = [:]
    private var dispatchTexts: [UUID: [String: String]] = [:]
    private var autoStopResults = Set<UUID>()
    private var autoStopResultDeadlines: [UUID: Date] = [:]
    private var autoNudgeIDs: [UUID: Set<String>] = [:]
    private var autoRetryIDs: [UUID: Set<String>] = [:]
    private var waitingSince: [UUID: Date] = [:]
    private var waitingReminded = Set<UUID>()
    /// C120 的既有自我探針沿用單一門檻；正式聊天室不使用這條相容路徑。
    private var legacyProbeIDs = Set<UUID>()
    private var stageEvents: [UUID: [StageEvent]] = [:]
    private var toolProbeIDs = Set<UUID>()
    private var toolExecutionEvents: [UUID: [StageEvent]] = [:]
    private weak var store: Store?
    private weak var main: MainWindowController?
    private var timer: Timer?
    private let realClockOrigin = Date()
    private let virtualClockOrigin = Date()
    private let clockScale: Double
    var configuredClockScale: Double { clockScale }
    private init() {
        let args = CommandLine.arguments
        if args.contains("--state-dir"), let i = args.firstIndex(of: "--commander-stuck-scale"), i + 1 < args.count,
           let v = Double(args[i + 1]), v.isFinite, (0.1...600).contains(v) {
            clockScale = v
        } else { clockScale = 1 }
    }

    func start(store: Store, main: MainWindowController) {
        self.store = store
        self.main = main
        guard timer == nil else { return }
        let interval = max(0.02, 1.0 / clockScale)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.tick(now: self.clockNow())
        }
    }

    /// 把派工文字只保存在執行期記憶體，監督重送時使用；不把任務全文另寫入 state.json。
    func registerDispatch(target: UUID, messageID: String, assignerID: UUID, text: String, supervisedRetry: Bool = false) {
        guard !messageID.isEmpty else { return }
        dispatchTexts[target, default: [:]][messageID] = text
        if supervisedRetry { autoRetryIDs[target, default: []].insert(messageID) }
    }

    func output(_ id: UUID, event: [String: Any], hasUnacknowledgedInput: Bool = false) {
        let now = clockNow()
        let type = event["type"] as? String
        let eventID = ((event["uuid"] as? String) ?? "").lowercased()
        if type == "user", var ids = autoNudgeIDs[id], ids.remove(eventID) != nil {
            autoNudgeIDs[id] = ids.isEmpty ? nil : ids
            return
        }
        if type == "user", var ids = autoRetryIDs[id], ids.remove(eventID) != nil {
            autoRetryIDs[id] = ids.isEmpty ? nil : ids
            return
        }

        let isAutomaticStopResult = type == "result" && autoStopResults.contains(id)
        if isAutomaticStopResult {
            // CommanderEngine 會在同一事件回呼接著消耗旗標，避免把自動中斷誤報成派工失敗。
        } else {
            lastOutput[id] = now
            if stuckMinutes[id] != nil { stuckMinutes[id] = nil }
            areaNotifiedAt[id] = nil
            chiefNotified.remove(id)
            watches[id] = nil
        }
        if type == "assistant" || type == "stream_event" || type == "result" {
            lastAssistantOutput[id] = now
        }

        if type == "result" {
            let hadGuard = guards.remove(id) != nil || hasUnacknowledgedInput
            let detail = (event["result"] as? String ?? L("引擎回報執行錯誤"))
                .components(separatedBy: .newlines).joined(separator: " ")
            let manualStop = detail.localizedCaseInsensitiveContains("[Request interrupted by user]")
            let stopped = TerminalTurnTracker.isStopped(event)
            // 有派工紀錄時由 commanderDispatchEvent 統一消耗結果；通知偏好不應讓錯誤走備援通知。
            let hasTrackedDispatch = store?.conversation(id)?.commanderDispatches?.contains(where: \.started) ?? false
            if !isAutomaticStopResult {
                if !hasTrackedDispatch,
                   let store, let session = store.commander(of: id), session.chief != id,
                   let chief = session.chief, let conversation = store.conversation(id) {
                    if stopped {
                        if hadGuard, let notice = TerminalTurnTracker.supervisionNotice(conversation: conversation.title, event: event) {
                            CollabBoardModel.queueNotice(conv: chief, text: notice)
                        }
                    } else if event["is_error"] as? Bool == true, !manualStop {
                        let redacted = Self.redactFailureNotice(detail)
                        let short = redacted.count > 500 ? String(redacted.prefix(500)) + "…" : redacted
                        if let notice = TerminalTurnTracker.supervisionNotice(conversation: conversation.title, event: event, detail: short) {
                            CollabBoardModel.queueNotice(conv: chief, text: notice)
                        }
                    }
                }
                dispatchTexts[id] = nil
            }
        } else if type == "assistant" || type == "stream_event" || type == "control_request"
                    || (type == "user" && event["isReplay"] as? Bool == true) {
            if let store, let session = store.commander(of: id), session.chief != id { guards.insert(id) }
        }
        if let type {
            let subtype = event["subtype"] as? String
            let content = event["content_block"] as? [String: Any]
            let name = content?["name"] as? String
            lastAction[id] = name.map { "工具：\($0)" } ?? subtype.map { "\(type)：\($0)" } ?? type
        }
    }

    private var lastAssistantOutput: [UUID: Date] = [:]
    func minutes(_ id: UUID) -> Int? { stuckMinutes[id] }

    /// 區長只可手動中斷已越過輕推門檻的工作；工具子程序仍在執行時一律不允許。
    func areaLeadInterruptDecision(_ id: UUID) -> AreaLeadInterruptDecision {
        let refusal = "對方還在工作，請用 --steer 或排隊"
        guard store?.status[id] == .working else {
            return AreaLeadInterruptDecision(accepted: false, reason: "not-working", message: refusal)
        }
        guard let watch = watches[id] else {
            return AreaLeadInterruptDecision(accepted: false, reason: "not-stuck", message: refusal)
        }
        guard SessionActivity.shared.running(id).isEmpty else {
            return AreaLeadInterruptDecision(accepted: false, reason: "tool-running", message: refusal)
        }
        switch watch.stage {
        case .watching:
            return AreaLeadInterruptDecision(accepted: false, reason: "not-stuck", message: refusal)
        case .stopping:
            return AreaLeadInterruptDecision(accepted: false, reason: "interrupt-already-requested", message: refusal)
        case .nudged, .waitingForNotice, .retried, .notified:
            return AreaLeadInterruptDecision(accepted: true, reason: "stuck", message: "")
        }
    }

    func tick(now: Date = Date()) {
        guard let store else { return }
        let expiredStopResults = autoStopResultDeadlines.filter { $0.value <= now }.map(\.key)
        for id in expiredStopResults {
            autoStopResultDeadlines[id] = nil
            autoStopResults.remove(id)
        }
        var candidates = Set<UUID>()
        for (id, status) in store.status where status != .idle { candidates.insert(id) }
        candidates.formUnion(watches.keys)
        candidates.formUnion(waitingSince.keys)
        candidates.formUnion(stuckMinutes.keys)
        candidates.formUnion(legacyProbeIDs)
        candidates.formUnion(lastOutput.keys)
        guard !candidates.isEmpty else { return }
        let base = TimeInterval(max(1, Prefs.shared.commanderStuckMinutes) * 60)
        for id in candidates {
            guard let c = store.conversation(id) else {
                clear(id); continue
            }
            guard let session = store.commander(of: c.id), session.chief != c.id else {
                clear(c.id); continue
            }
            let status = store.status[c.id] ?? .idle
            if status == .waiting, hasStartedDispatch(c) {
                updateWaiting(c, session: session, now: now)
                continue
            }
            waitingSince[c.id] = nil
            waitingReminded.remove(c.id)

            // C120 既有探針保留舊的單門檻通知行為；正式監督必須有未完成派工。
            if legacyProbeIDs.contains(c.id) {
                legacyTick(c, session: session, now: now, limit: base)
                continue
            }

            if var watch = watches[c.id], watch.stage == .notified {
                if SessionActivity.shared.running(c.id).isEmpty == false {
                    if watch.pauseStartedAt == nil { watch.pauseStartedAt = now }
                    observeToolExecution(c, session: session, watch: &watch, now: now, base: base)
                } else {
                    shiftAfterPause(&watch, now: now)
                    clearToolExecution(&watch)
                    escalateAreaLeadIfNeeded(c, session: session, watch: &watch, now: now)
                }
                watches[c.id] = watch
                continue
            }
            if var watch = watches[c.id], watch.stage == .waitingForNotice {
                if SessionActivity.shared.running(c.id).isEmpty == false {
                    if watch.pauseStartedAt == nil { watch.pauseStartedAt = now }
                    observeToolExecution(c, session: session, watch: &watch, now: now, base: base)
                    watches[c.id] = watch
                    continue
                }
                shiftAfterPause(&watch, now: now)
                clearToolExecution(&watch)
                if now.timeIntervalSince(watch.lastOutput) >= base * 3 {
                    notifyAssigner(c, session: session, watch: &watch, now: now)
                }
                watches[c.id] = watch
                continue
            }

            if var watch = watches[c.id], watch.stage == .stopping {
                if SessionActivity.shared.running(c.id).isEmpty == false {
                    if watch.pauseStartedAt == nil { watch.pauseStartedAt = now }
                    observeToolExecution(c, session: session, watch: &watch, now: now, base: base)
                    watches[c.id] = watch
                    continue
                }
                shiftAfterPause(&watch, now: now)
                clearToolExecution(&watch)
                if status != .working {
                    retryAfterStop(c, session: session, watch: &watch, now: now)
                } else if let deadline = watch.retryDeadline, now >= deadline {
                    autoStopResultDeadlines[c.id] = nil
                    autoStopResults.remove(c.id)
                    watch.stage = .waitingForNotice
                    watch.stageStartedAt = now
                    logStage(c, text: "卡住處理第 2 階段：15 秒內未確認停止，不重送；滿 15 分鐘後通知派工者。")
                }
                watches[c.id] = watch
                continue
            }
            guard status == .working, let dispatch = startedDispatch(c) else {
                clear(c.id)
                continue
            }
            if watches[c.id]?.assignerID != dispatch.assignerID || watches[c.id]?.dispatchMessageID != dispatch.messageID {
                let payload = dispatchTexts[c.id]?[dispatch.messageID]
                let start = lastOutput[c.id] ?? now
                watches[c.id] = Watch(lastOutput: start, incidentStartedAt: start, stageStartedAt: now,
                                      assignerID: dispatch.assignerID, dispatchMessageID: dispatch.messageID,
                                      dispatchSequence: dispatch.sequence, retryText: payload)
            }
            if SessionActivity.shared.running(c.id).isEmpty == false {
                if var watch = watches[c.id], watch.pauseStartedAt == nil {
                    watch.pauseStartedAt = now
                    watches[c.id] = watch
                }
                if var watch = watches[c.id] {
                    observeToolExecution(c, session: session, watch: &watch, now: now, base: base)
                    watches[c.id] = watch
                }
                continue
            }
            if var watch = watches[c.id], let paused = watch.pauseStartedAt {
                shiftAfterPause(&watch, now: now, startedAt: paused)
                clearToolExecution(&watch)
                watches[c.id] = watch
            }
            guard var watch = watches[c.id] else { continue }
            if watch.stage == .notified {
                escalateAreaLeadIfNeeded(c, session: session, watch: &watch, now: now)
                watches[c.id] = watch
                continue
            }

            let elapsed = max(0, now.timeIntervalSince(watch.lastOutput))
            if elapsed >= base {
                let mins = max(1, Int(elapsed / 60))
                if stuckMinutes[c.id] != mins { stuckMinutes[c.id] = mins }
            }
            switch watch.stage {
            case .watching where elapsed >= base:
                // 輕推目前只送給 Codex／本機；其他引擎的 steer 中斷語意不同或尚未確認。
                if ["codex", "local"].contains(c.modelCategory) {
                    let id = UUID().uuidString.lowercased()
                    autoNudgeIDs[c.id, default: []].insert(id)
                    let text = "還在嗎？請回報進度。"
                    if let pane = main?.workspace.pane(for: c) as? ChatPane {
                        _ = main?.commanderDeliver(pane, text, id, true, nil, nil, "卡住提醒")
                        pane.notice("〔卡住處理 1/3〕已送出不中斷進度提醒。")
                    }
                    record("nudge", recipient: c.title, text: text, id: c.id, at: now, started: watch.incidentStartedAt)
                    logStage(c, text: "卡住處理第 1 階段：已送出不中斷進度提醒（\(Int(base / 60)) 分鐘）。")
                }
                watch.stage = .nudged
                watch.stageStartedAt = now
            case .nudged where elapsed >= base * 2:
                watch.stage = .stopping
                watch.stageStartedAt = now
                watch.retryDeadline = now.addingTimeInterval(15)
                watch.retryText = dispatchTexts[c.id]?[dispatch.messageID] ?? watch.retryText
                if let pane = main?.workspace.pane(for: c) as? ChatPane {
                    autoStopResults.insert(c.id)
                    autoStopResultDeadlines[c.id] = now.addingTimeInterval(15)
                    pane.notice("〔卡住處理 2/3〕已要求停止，最多等 15 秒後重送最後一則派工。")
                    main?.commanderInterrupt(pane)
                }
                logStage(c, text: "卡住處理第 2 階段：已要求停止，等待最多 15 秒後重送。")
                record("interrupt", recipient: c.title, text: "停止目前回合並等待最多 15 秒。", id: c.id, at: now, started: watch.incidentStartedAt)
            case .retried where elapsed >= base:
                notifyAssigner(c, session: session, watch: &watch, now: now)
            default: break
            }
            watches[c.id] = watch
        }
    }

    private func startedDispatch(_ c: Conversation) -> CommanderDispatch? {
        c.commanderDispatches?.filter(\.started).max { $0.sequence < $1.sequence }
    }

    private func hasStartedDispatch(_ c: Conversation) -> Bool { startedDispatch(c) != nil }

    private func shiftAfterPause(_ watch: inout Watch, now: Date, startedAt: Date? = nil) {
        guard let paused = startedAt ?? watch.pauseStartedAt else { return }
        let shift = max(0, now.timeIntervalSince(paused))
        watch.lastOutput = watch.lastOutput.addingTimeInterval(shift)
        watch.incidentStartedAt = watch.incidentStartedAt.addingTimeInterval(shift)
        watch.stageStartedAt = watch.stageStartedAt.addingTimeInterval(shift)
        if let deadline = watch.retryDeadline { watch.retryDeadline = deadline.addingTimeInterval(shift) }
        if let noticeAt = watch.noticeAt { watch.noticeAt = noticeAt.addingTimeInterval(shift) }
        watch.pauseStartedAt = nil
    }

    /// 工具子程序執行期間凍結一般卡住階段，另計它自己的運行時間：跨過中斷門檻只記一次，跨過通知門檻通知派工者。
    private func observeToolExecution(_ c: Conversation, session: SessionLayout, watch: inout Watch,
                                      now: Date, base: TimeInterval) {
        if watch.toolExecutionStartedAt == nil { watch.toolExecutionStartedAt = now }
        guard let started = watch.toolExecutionStartedAt else { return }
        let elapsed = max(0, now.timeIntervalSince(started))
        let canSkipInterrupt: Bool
        switch watch.stage {
        case .watching, .nudged: canSkipInterrupt = true
        case .stopping, .waitingForNotice, .retried, .notified: canSkipInterrupt = false
        }
        if canSkipInterrupt, elapsed >= base * 2, !watch.toolInterruptSkipLogged {
            watch.toolInterruptSkipLogged = true
            let text = "工具子程序仍在執行，已跳過第 2 階段自動中斷。"
            logStage(c, text: text)
            recordToolProbeEvent(StageEvent(stage: "record", recipient: "紀錄",
                                            text: text, at: now, elapsed: elapsed), for: c.id)
        }
        if watch.stage != .notified, elapsed >= base * 3 {
            notifyAssigner(c, session: session, watch: &watch, now: now)
        }
    }

    private func clearToolExecution(_ watch: inout Watch) {
        watch.toolExecutionStartedAt = nil
        watch.toolInterruptSkipLogged = false
    }

    private func retryAfterStop(_ c: Conversation, session: SessionLayout, watch: inout Watch, now: Date) {
        guard let main, let text = dispatchTexts[c.id]?[watch.dispatchMessageID] ?? watch.retryText else {
            watch.stage = .waitingForNotice
            watch.stageStartedAt = now
            logStage(c, text: "卡住處理第 2 階段：找不到派工原文，為避免重送錯誤內容已停止自動重試。")
            watches[c.id] = watch
            return
        }
        watch.stage = .waitingForNotice
        watch.stageStartedAt = now
        watches[c.id] = watch
        logStage(c, text: "卡住處理第 2 階段：已確認停止，正在重送最後一則派工。")
        guard let assigner = store?.conversation(watch.assignerID) else { return }
        main.commanderSendChat(caller: assigner.id.uuidString, target: c.title, text: text,
                               wait: false, timeout: 60, allowClaudeAfterInterrupt: true,
                               supervisedRetry: true) { [weak self] response in
            guard let self, var current = self.watches[c.id] else { return }
            let sent = response["sent"] as? Bool == true
            if sent {
                current.stage = .retried
                current.lastOutput = self.clockNow()
                current.stageStartedAt = current.lastOutput
                current.retryText = text
                if let messageID = response["messageID"] as? String { current.dispatchMessageID = messageID }
                if let record = self.store?.conversation(c.id)?.commanderDispatches?.filter(\.started).max(by: { $0.sequence < $1.sequence }) {
                    current.dispatchMessageID = record.messageID
                    current.dispatchSequence = record.sequence
                }
                self.lastOutput[c.id] = current.lastOutput
                if self.stuckMinutes[c.id] != nil { self.stuckMinutes[c.id] = nil }
                if let pane = self.main?.workspace.pane(for: c) as? ChatPane {
                    pane.notice("〔卡住處理 2/3〕已重送最後一則派工，重新計算無輸出時間。")
                }
                let line = "卡住處理第 2 階段：已重送最後一則派工，重新起算。"
                self.logStage(c, text: line)
                self.record("retry", recipient: c.title, text: "已重送最後一則派工。", id: c.id,
                            at: current.lastOutput, started: current.incidentStartedAt)
            } else {
                current.stage = .waitingForNotice
                current.stageStartedAt = current.lastOutput
                let reason = response["error"] as? String ?? "派工訊息送不出去"
                self.logStage(c, text: "卡住處理第 2 階段：重送失敗（\(reason)），滿 15 分鐘後通知派工者。")
            }
            self.watches[c.id] = current
        }
        _ = session
    }

    private func notifyAssigner(_ c: Conversation, session: SessionLayout, watch: inout Watch, now: Date) {
        guard let store else { return }
        let activeLead = store.activeAreaLead(for: c, in: session)
        let requestedAssigner = store.conversation(watch.assignerID)
        let assignerIsValid = requestedAssigner.map { Store.isChat($0) && !store.isArchived($0) } ?? false
        let recipient: Conversation
        if assignerIsValid, let requestedAssigner,
           requestedAssigner.id == session.chief || activeLead?.id == requestedAssigner.id {
            recipient = requestedAssigner
        } else if let chiefID = session.chief, let chief = store.conversation(chiefID) {
            recipient = chief
        } else { return }
        let toolElapsed = watch.toolExecutionStartedAt.map { max(0, now.timeIntervalSince($0)) }
        let isToolRunning = toolElapsed != nil && !SessionActivity.shared.running(c.id).isEmpty
        let mins = max(0, Int((isToolRunning ? toolElapsed! : now.timeIntervalSince(watch.lastOutput)) / 60))
        let recovery: String
        if isToolRunning {
            recovery = "工具子程序已執行約 \(mins) 分鐘，為保護執行中的指令未自動中斷"
        } else if watch.stage == .retried {
            recovery = "最後一則派工重送後又過了 \(mins) 分鐘仍沒有輸出"
        } else {
            recovery = "已連續約 \(mins) 分鐘沒有輸出，停止與重送未能確認恢復"
        }
        let msg = "〔總指揮監督〕「\(c.title)」\(recovery)。最後動作：\(lastAction[c.id] ?? "尚無輸出事件")。請用 codenv-todo last 檢查並接手。"
        let delivered = main?.sendCommanderSupervisionNotice(to: recipient.id, text: msg) ?? false
        if !delivered { CollabBoardModel.queueNotice(conv: recipient.id, text: msg) }
        if let pane = main?.workspace.pane(for: c) as? ChatPane { pane.notice("〔卡住處理 3/3〕已通知「\(recipient.title)」接手。") }
        logStage(c, text: "卡住處理第 3 階段：已通知派工者「\(recipient.title)」。")
        record("notify", recipient: recipient.id == session.chief ? "總指揮" : "區長", text: msg,
               id: c.id, at: now, started: watch.incidentStartedAt)
        if isToolRunning {
            recordToolProbeEvent(StageEvent(stage: "notify",
                recipient: recipient.id == session.chief ? "總指揮" : "區長", text: msg, at: now,
                elapsed: toolElapsed ?? 0, childAliveAtNotice: true), for: c.id)
        }
        watch.stage = .notified
        watch.noticeAt = now
        watch.leadOutputAtNotice = lastAssistantOutput[recipient.id]
        watch.escalated = recipient.id == session.chief
    }

    private func escalateAreaLeadIfNeeded(_ c: Conversation, session: SessionLayout, watch: inout Watch, now: Date) {
        guard !watch.escalated, let noticeAt = watch.noticeAt, now.timeIntervalSince(noticeAt) >= 300,
              let store, let chiefID = session.chief,
              let lead = store.activeAreaLead(for: c, in: session), lead.id == watch.assignerID else { return }
        let leadHandled = lastAssistantOutput[lead.id].map { $0 > (watch.leadOutputAtNotice ?? .distantPast) } ?? false
        guard !leadHandled, let chief = store.conversation(chiefID) else { watch.escalated = true; return }
        let text = "〔總指揮監督〕區長收到卡住通知 5 分鐘後，「\(c.title)」仍沒有進度，已升級給總指揮。請用 codenv-todo last 檢查並接手。"
        if main?.sendCommanderSupervisionNotice(to: chief.id, text: text) != true {
            CollabBoardModel.queueNotice(conv: chief.id, text: text)
        }
        if let pane = main?.workspace.pane(for: c) as? ChatPane { pane.notice("〔卡住處理〕區長 5 分鐘未回應，已升級通知總指揮。") }
        logStage(c, text: "卡住處理：區長 5 分鐘未處理，已升級通知總指揮。")
        record("escalate", recipient: "總指揮", text: text, id: c.id, at: now, started: watch.incidentStartedAt)
        watch.escalated = true
    }

    private func updateWaiting(_ c: Conversation, session: SessionLayout, now: Date) {
        let start = waitingSince[c.id] ?? now
        waitingSince[c.id] = start
        guard !waitingReminded.contains(c.id), now.timeIntervalSince(start) >= 60 else { return }
        waitingReminded.insert(c.id)
        let text = "「\(c.title)」正在等你回答權限或選擇問題；這格不會被中斷或自動重送。"
        if let pane = main?.workspace.pane(for: c) as? ChatPane { pane.notice(text) }
        if CommandLine.arguments.contains("--state-dir") {
            record("waiting-reminder", recipient: "使用者", text: text, id: c.id, at: now, started: start)
        } else {
            let notice = NSUserNotification()
            notice.title = L("聊天室正在等你回答")
            notice.informativeText = text
            NSUserNotificationCenter.default.deliver(notice)
        }
        Self.petSay("\(c.title) 正在等你回答")
        EventLog.log("總指揮", text)
        _ = session
    }

    private func record(_ stage: String, recipient: String, text: String, id: UUID, at: Date, started: Date) {
        stageEvents[id, default: []].append(StageEvent(stage: stage, recipient: recipient, text: text,
                                                       at: at, elapsed: max(0, at.timeIntervalSince(started))))
    }

    private func logStage(_ c: Conversation, text: String) {
        EventLog.log("總指揮", "「\(c.title)」\(text)")
    }

    private func clear(_ id: UUID) {
        if stuckMinutes[id] != nil { stuckMinutes[id] = nil }
        lastOutput[id] = nil
        lastAction[id] = nil
        areaNotifiedAt[id] = nil
        chiefNotified.remove(id)
        guards.remove(id)
        watches[id] = nil
        waitingSince[id] = nil
        waitingReminded.remove(id)
        legacyProbeIDs.remove(id)
        toolProbeIDs.remove(id)
        toolExecutionEvents[id] = nil
    }

    private func recordToolProbeEvent(_ event: StageEvent, for id: UUID) {
        guard toolProbeIDs.contains(id) else { return }
        toolExecutionEvents[id, default: []].append(event)
        if let count = toolExecutionEvents[id]?.count, count > 20 {
            toolExecutionEvents[id]?.removeFirst(count - 20)
        }
    }

    private func legacyTick(_ c: Conversation, session: SessionLayout, now: Date, limit: TimeInterval) {
        if lastOutput[c.id] == nil { lastOutput[c.id] = now }
        guard let last = lastOutput[c.id], now.timeIntervalSince(last) >= limit else { return }
        let minutes = max(1, Int(now.timeIntervalSince(last) / 60))
        if stuckMinutes[c.id] != minutes { stuckMinutes[c.id] = minutes }
        let areaLead = store?.activeAreaLead(for: c, in: session)?.id
        switch Self.nextEscalation(areaLead: areaLead, subject: c.id, commander: session.chief,
                                   areaNotifiedAt: areaNotifiedAt[c.id], commanderAlreadyNotified: chiefNotified.contains(c.id), now: now) {
        case .areaLead:
            guard let areaLead else { return }
            areaNotifiedAt[c.id] = now
            let msg = "〔區長監督〕「\(c.title)」可能卡住：\(minutes) 分鐘沒有輸出。最後動作：\(lastAction[c.id] ?? "尚無輸出事件")。請先用 codenv-todo last 查狀態，處理後再回報總指揮。"
            CollabBoardModel.queueNotice(conv: areaLead, text: msg)
            Self.petSay("\(c.title) 可能卡住，已通知區長")
        case .commander(let reason):
            guard let chief = session.chief else { return }
            chiefNotified.insert(c.id)
            let msg: String
            switch reason {
            case .areaLeadTimeout:
                msg = "〔總指揮監督〕區長收到通知 10 分鐘後，「\(c.title)」仍可能卡住：\(minutes) 分鐘沒有輸出。最後動作：\(lastAction[c.id] ?? "尚無輸出事件")。請用 codenv-todo last 查狀態，再決定 stop 或重派。"
            case .areaLeadInvalid:
                msg = "〔總指揮監督〕區長已失效（取消指派、搬離、封存或更換模型），「\(c.title)」仍可能卡住：\(minutes) 分鐘沒有輸出。最後動作：\(lastAction[c.id] ?? "尚無輸出事件")。請立即接手或重新指派區長。"
            case .noAreaLead:
                msg = "〔總指揮監督〕「\(c.title)」目前沒有有效區長，可能卡住：\(minutes) 分鐘沒有輸出。最後動作：\(lastAction[c.id] ?? "尚無輸出事件")。請先用 codenv-todo last 查狀態，再決定 stop 或重派。"
            }
            CollabBoardModel.queueNotice(conv: chief, text: msg)
            Self.petSay("\(c.title) 可能卡住，已通知總指揮")
        case .none: break
        }
    }

    /// C120 的舊測試掛鉤；一般程式碼不可用這個 API 啟動監督。
    func seedForTest(_ id: UUID, lastOutput: Date, action: String = "假引擎輸出") {
        self.lastOutput[id] = lastOutput
        lastAction[id] = action
        areaNotifiedAt[id] = nil
        chiefNotified.remove(id)
        if stuckMinutes[id] != nil { stuckMinutes[id] = nil }
        legacyProbeIDs.insert(id)
    }

    /// 黑箱階段探針使用：建立一個已開始的假派工並由一般監督器推進各階段。
    func seedStagesForTest(_ id: UUID, assignerID: UUID, messageID: String, sequence: Int, text: String, now: Date) {
        lastOutput[id] = now
        lastAction[id] = "假引擎沒有輸出"
        if stuckMinutes[id] != nil { stuckMinutes[id] = nil }
        legacyProbeIDs.remove(id)
        toolProbeIDs.insert(id)
        toolExecutionEvents[id] = nil
        registerDispatch(target: id, messageID: messageID, assignerID: assignerID, text: text)
        watches[id] = Watch(lastOutput: now, incidentStartedAt: now, stageStartedAt: now, assignerID: assignerID,
                            dispatchMessageID: messageID, dispatchSequence: sequence, retryText: text)
    }

    func seedStagesForTest(_ id: UUID, assignerID: UUID, messageID: String, sequence: Int, text: String,
                           now: Date, alreadyNudged: Bool) {
        seedStagesForTest(id, assignerID: assignerID, messageID: messageID, sequence: sequence, text: text, now: now)
        guard alreadyNudged, var watch = watches[id] else { return }
        watch.stage = .nudged
        watches[id] = watch
        let mins = max(1, Prefs.shared.commanderStuckMinutes)
        if stuckMinutes[id] != mins { stuckMinutes[id] = mins }
    }

    func stageProbeResult(for id: UUID) -> [[String: Any]] {
        let formatter = ISO8601DateFormatter()
        return (stageEvents[id] ?? []).map { e in
            ["stage": e.stage, "recipient": e.recipient, "text": e.text,
             "timestamp": formatter.string(from: e.at), "elapsedSeconds": e.elapsed] as [String: Any]
        }
    }

    func toolExecutionProbeResult(for id: UUID) -> [[String: Any]] {
        let formatter = ISO8601DateFormatter()
        return (toolExecutionEvents[id] ?? []).map { e in
            var result: [String: Any] = ["stage": e.stage, "recipient": e.recipient, "text": e.text,
                                         "timestamp": formatter.string(from: e.at), "elapsedSeconds": e.elapsed]
            if let childAliveAtNotice = e.childAliveAtNotice { result["childAliveAtNotice"] = childAliveAtNotice }
            return result
        }
    }

    func testClockNow() -> Date { clockNow() }

    /// CommanderEngine consumes this after CommanderStuck has identified the result as its own stop.
    func consumeAutomaticStopResult(_ id: UUID, now: Date? = nil) -> Bool {
        guard autoStopResults.contains(id) else { return false }
        let now = now ?? clockNow()   // 期限用虛擬時鐘設定，這裡也要用同一個時鐘
        if let deadline = autoStopResultDeadlines[id], deadline <= now {
            autoStopResults.remove(id)
            autoStopResultDeadlines[id] = nil
            return false
        }
        autoStopResults.remove(id)
        autoStopResultDeadlines[id] = nil
        return true
    }

    private func clockNow() -> Date {
        guard clockScale != 1 else { return Date() }
        return virtualClockOrigin.addingTimeInterval(Date().timeIntervalSince(realClockOrigin) * clockScale)
    }

    static func nextEscalation(areaLead: UUID?, subject: UUID, commander: UUID?, areaNotifiedAt: Date?, commanderAlreadyNotified: Bool, now: Date) -> Escalation {
        if let areaLead, areaLead != subject, areaLead != commander {
            guard let areaNotifiedAt else { return .areaLead }
            return !commanderAlreadyNotified && now.timeIntervalSince(areaNotifiedAt) >= 600 ? .commander(.areaLeadTimeout) : .none
        }
        guard commander != nil, !commanderAlreadyNotified else { return .none }
        return .commander(areaNotifiedAt == nil ? .noAreaLead : .areaLeadInvalid)
    }

    private static func petSay(_ message: String) {
        var tool = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/pet-say").path
        if CommandLine.arguments.contains("--state-dir") {
            guard let i = CommandLine.arguments.firstIndex(of: "--pet-say"), i + 1 < CommandLine.arguments.count else { return }
            tool = CommandLine.arguments[i + 1]
        }
        guard FileManager.default.isExecutableFile(atPath: tool) else { return }
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = ["-n", message]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    /// 監督通知可能包含截斷的憑證或 Bearer token；通知採保守遮罩，避免短測試憑證與未完整格式外洩。
    private static func redactFailureNotice(_ text: String) -> String {
        var safe = KeyScan.redact(text, strongOnly: true)
        let patterns = [
            #"(?i)(?<![A-Za-z0-9_-])(?:sk-[A-Za-z0-9_-]{6,}|nvapi-[A-Za-z0-9_-]{6,})"#,
            #"(?i)\bBearer\s+[^\s,\"'<>]{6,}"#,
            #"(?<![A-Za-z0-9_+/.-])[A-Za-z0-9_+/.-]{32,}={0,2}"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = safe as NSString
            let matches = regex.matches(in: safe, range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                safe = (safe as NSString).replacingCharacters(in: match.range, with: "〔金鑰已遮蔽〕")
            }
        }
        return safe
    }
}
