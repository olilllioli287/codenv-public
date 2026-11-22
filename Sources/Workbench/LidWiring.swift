import AppKit

enum LidIndicatorNoticeProbe {
    static var observe: (([LidInterruptionNoticeRoute]) -> Void)?
}

extension MainWindowController {
    /// 紀錄檔與標記檔：測試實例（--state-dir）放在暫存資料夾，不動 ~/Library/Logs 和正式資料
    static func lidPaths() -> (log: URL, marker: URL) {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--state-dir"), i + 1 < a.count {
            let d = URL(fileURLWithPath: a[i + 1])
            return (d.appendingPathComponent("codenv-lid.log"), d.appendingPathComponent("lid-hold.json"))
        }
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/codenv-lid.log")
        return (logs, Edition.support("lid-hold.json"))
    }

    static func lidRescueURL(stateDirectory: URL) -> URL {
        stateDirectory.appendingPathComponent("lid-interrupted-rescue.json")
    }

    func setupLidKeeper() {
        let paths = Self.lidPaths()
        let rescueURL = Self.lidRescueURL(stateDirectory: store.directory)
        // 測試實例（暫存 state-dir 或 --background）絕不連真的小幫手：它們的假 claude 一直「工作中」，會搶走正式 codenv 的 nosleep、
        // 被殺時連線一斷還把 disablesleep 改回 0（實測闔蓋失敗的原因）。只有正式實例才接真硬體
        let args = CommandLine.arguments
        let isTest = args.contains("--state-dir") || args.contains("--background") || args.contains("--lid-sim")
        let sim = isTest ? SimLidEnv() : nil
        let keeper = LidKeeper(env: sim ?? RealLidEnv(), logURL: paths.log, markerURL: paths.marker, rescueURL: rescueURL)
        let noticeDeduplicator = LidNoticeDeduplicator()
        sim?.onCall = { [weak keeper] s in keeper?.log(s) }
        sim?.traceNow = { [weak keeper] in keeper?.now() ?? Date() }
        keeper.enabled = { Prefs.shared.lidInterruptOnClose }
        keeper.interruptOnCloseEnabled = { Prefs.shared.lidInterruptOnClose }
        keeper.externalIdleSleepEnabled = { Prefs.shared.lidExternalIdleSleep }
        keeper.resumeEnabled = { Prefs.shared.lidResumeNotifyEnabled }
        keeper.workingIDs = { [weak self] in
            guard let self else { return [] }
            let activityIDs = SessionActivity.shared.activeIDs
            return self.store.conversations.filter {
                Store.isChat($0) && (self.store.status[$0.id] == .working || activityIDs.contains($0.id))
            }.map(\.id)
        }
        keeper.interruptWork = { [weak self] in
            guard let self else { return [] }
            let activity = SessionActivity.shared
            return self.store.conversations.compactMap { conversation in
                guard Store.isChat(conversation) else { return nil }
                let status = self.store.status[conversation.id] ?? .idle
                let running = activity.running(conversation.id)
                let pane = self.workspace.panes[conversation.id] as? ChatPane
                let bang = pane?.lidInterruptBangDescription
                guard status != .idle || !running.isEmpty || bang != nil else { return nil }
                let category = conversation.modelCategory
                let engine: String
                switch category {
                case "agy": engine = "agy"
                case "codex": engine = "Codex"
                case "copilot": engine = "Copilot"
                case "local", "apple": engine = "本機模型"
                default: engine = "Claude"
                }
                var details = running.map(\.text)
                if let bang { details.append(bang) }
                let foreground = status != .idle || bang != nil || running.contains { !$0.background }
                return LidInterruptWork(id: conversation.id, title: conversation.title, engine: engine,
                                        supportsTermination: ["claude", "codex", "copilot", "agy"].contains(category),
                                        hasBangCommand: bang != nil,
                                        details: details,
                                        foreground: foreground)
            }
        }
        keeper.pendingMessagesForInterrupt = { [weak self] id in
            (self?.workspace.panes[id] as? ChatPane)?.pendingMessagesForLidInterrupt() ?? LidInterruptPendingMessages()
        }
        keeper.terminateForInterrupt = { [weak self] id, pendingIDs in
            guard let self, let pane = self.workspace.panes[id] as? ChatPane,
                  let conversation = self.store.conversation(id) else { return false }
            if ["claude", "codex", "copilot", "agy"].contains(conversation.modelCategory) {
                pane.terminateForLidInterrupt(pendingIDs: pendingIDs)
            } else {
                pane.terminateBangForLidInterrupt()
            }
            return true
        }
        keeper.isDraining = { [weak self] id in
            (self?.workspace.panes[id] as? ChatPane)?.isDrainingForLidInterrupt ?? false
        }
        keeper.forceKillDraining = { [weak self] id in
            (self?.workspace.panes[id] as? ChatPane)?.forceKillDrainingForLidInterrupt() ?? false
        }
        keeper.didForceKillForInterrupt = { [weak self] id in
            (self?.workspace.panes[id] as? ChatPane)?.lidInterruptForceKillOccurred ?? false
        }
        keeper.sendInterruptNotices = { [weak self] records, late in
            self?.sendLidInterruptNotices(records, late: late)
        }
        keeper.sendInterruptResume = { [weak self, weak keeper] records in
            self?.sendLidInterruptResume(records, deduplicator: noticeDeduplicator, notify: { title, detail in
                keeper?.notify(title, detail)
            }) { message in
                keeper?.log(message)
            }
        }
        keeper.workingCount = { [weak keeper] in keeper?.workingIDs().count ?? 0 }
        keeper.workDescriptions = { [weak self] in
            guard let self else { return [] }
            let activity = SessionActivity.shared
            return self.store.conversations.filter { Store.isChat($0) }.flatMap { conversation -> [String] in
                let status = self.store.status[conversation.id] ?? .idle
                let running = activity.running(conversation.id)
                var descriptions: [String] = []
                if status == .working || status == .waiting {
                    let engine: String
                    switch conversation.modelCategory {
                    case "agy": engine = "agy"
                    case "codex": engine = "Codex"
                    case "copilot": engine = "Copilot"
                    case "local", "apple": engine = "本機"
                    default: engine = "Claude"
                    }
                    descriptions.append("\(conversation.title)（\(engine)）\(status == .waiting ? "等待回覆" : "工作中")")
                }
                let backgroundCount = running.filter(\.background).count
                if backgroundCount > 0 {
                    descriptions.append("\(conversation.title) 等背景任務 \(backgroundCount)")
                } else if status != .working, !running.isEmpty {
                    descriptions.append("\(conversation.title) 執行中 \(running.count)")
                }
                return descriptions
            }
        }
        keeper.sendStop = { [weak self] id in
            guard let self, self.shouldSendLidNotice(to: id) else { return false }
            guard self.store.status[id] == .working else { return false }
            guard let pane = self.workspace.panes[id] as? ChatPane else { return false }
            return noticeDeduplicator.send(conversationID: id, text: LidKeeper.stopMessage) {
                pane.sendAutomatedText(LidKeeper.stopMessage, source: "闔蓋")
            }
        }
        keeper.sessionIsAvailable = { [weak self] id in
            guard let self, let conversation = self.store.conversation(id), Store.isChat(conversation) else { return false }
            return self.workspace.panes[id] is ChatPane
        }
        keeper.sessionIsArchived = { [weak self] id in
            guard let self, let conversation = self.store.conversation(id) else { return true }
            return self.store.isArchived(conversation)
        }
        keeper.sendResume = { [weak self] id in
            guard let self, self.shouldSendLidNotice(to: id),
                  let pane = self.workspace.panes[id] as? ChatPane else { return }
            _ = noticeDeduplicator.send(conversationID: id, text: LidKeeper.resumeMessage) {
                pane.sendAutomatedText(LidKeeper.resumeMessage, source: "闔蓋恢復")
            }
        }
        keeper.notify = { [weak self] title, detail in
            // 測試實例不跳視窗，只記一行
            if CommandLine.arguments.contains("--state-dir") { keeper.log("（測試）會提醒：\(title)｜\(detail.replacingOccurrences(of: "\n", with: " "))"); return }
            guard let w = self?.window, w.attachedSheet == nil else { return }
            let a = NSAlert(); a.alertStyle = .warning
            a.messageText = title; a.informativeText = detail
            a.addButton(withTitle: L("好"))
            a.beginSheetModal(for: w)
        }
        keeper.onRescueRetryTick = { [weak self, weak keeper] entries in
            guard let self, let keeper else { return }
            self.deliverRescueEntries(entries, keeper: keeper, forceLate: nil)
        }
        keeper.recoverIfNeeded()
        lidKeeper = keeper
        scheduleStartupRescueDelivery(keeper: keeper)
        // 預擋中（螢幕開著先擋住睡眠）約 1 秒看一次有沒有闔蓋；平常 3 秒看一次
        var n = 0
        lidTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak keeper] _ in
            guard let keeper else { return }
            n += 1
            if keeper.noSleepOn || keeper.isHolding || keeper.isInterrupting || keeper.isAwakeClosed
                || keeper.hasPendingInterruptNotice || keeper.hasPendingRescueRetry || keeper.workingCount() > 0
                || !keeper.interruptWork().isEmpty ? n % 3 == 0 : n % 10 == 0 { keeper.tick() }
        }
    }

    private func scheduleStartupRescueDelivery(keeper: LidKeeper) {
        keeper.canPresentNotify = { [weak self] in
            if CommandLine.arguments.contains("--state-dir") { return true }
            guard let w = self?.window else { return false }
            return w.attachedSheet == nil
        }
        let initialStatus = keeper.pendingRescueStatus()
        guard !initialStatus.entries.isEmpty || initialStatus.readFailed || keeper.hasPendingRescueNotifications else { return }
        if initialStatus.readFailed && initialStatus.entries.isEmpty {
            keeper.log("App 啟動讀取闔蓋中斷救援檔失敗，保留原檔並排程有限次數重試")
            keeper.scheduleStartupReadFailureRetry()
        }
        let expectedPlacedIDs: [UUID] = {
            let commander = Prefs.shared.sidebarMode == "commander"
            let cur = store.currentSessionLayout
            var ids: [UUID] = []
            for s in store.sessions {
                for w in s.windows {
                    if commander, !(w.detached || (s.id == cur?.id && w.id == (s.current ?? s.windows.first { !$0.detached }?.id))) { continue }
                    for id in w.root?.leaves ?? [] where !ids.contains(id) {
                        if let conv = store.conversation(id), Store.isChat(conv), !store.isArchived(conv) {
                            ids.append(id)
                        }
                    }
                }
            }
            return ids
        }()
        let earliest = Date().addingTimeInterval(0.8)
        let deadline = Date().addingTimeInterval(5.0)
        func attempt() {
            let now = Date()
            let windowReady = window != nil
            let needsPanes = !initialStatus.entries.isEmpty || initialStatus.readFailed
            let panesReady = !needsPanes || expectedPlacedIDs.allSatisfy { workspace.panes[$0] is ChatPane }
            if (windowReady && panesReady && now >= earliest) || now >= deadline {
                let currentStatus = keeper.pendingRescueStatus()
                keeper.flushRescueNotifications()
                if currentStatus.readFailed && currentStatus.entries.isEmpty {
                    keeper.log("App 啟動補送時仍無法讀取闔蓋中斷救援檔，保留原檔等待有限次數重試")
                    keeper.scheduleStartupReadFailureRetry()
                    keeper.flushRescueNotifications()
                    return
                }
                guard !currentStatus.entries.isEmpty else {
                    keeper.flushRescueNotifications()
                    return
                }
                keeper.log("App 啟動偵測到未送出的闔蓋中斷記錄（\(currentStatus.entries.count) 筆），執行補送通知")
                deliverRescueEntries(currentStatus.entries, keeper: keeper, forceLate: true)
                keeper.flushRescueNotifications()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak keeper] in
                guard let self, let keeper, self.lidKeeper === keeper else { return }
                attempt()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak keeper] in
            guard let self, let keeper, self.lidKeeper === keeper else { return }
            attempt()
        }
    }

    private func deliverRescueEntries(_ entries: [LidRescueEntry], keeper: LidKeeper, forceLate: Bool?) {
        let eligibleEntries = entries.filter { $0.attempts < LidKeeper.maxRescueStartupAttempts }
        guard !eligibleEntries.isEmpty else { return }
        if forceLate == true, !keeper.prepareStartupRescueDelivery(for: eligibleEntries) {
            return
        }
        let allowCreatePane = !(CommandLine.arguments.contains("--state-dir") && LidIndicatorNoticeProbe.observe != nil)
        if allowCreatePane && forceLate == true {
            for entry in eligibleEntries {
                let id = entry.record.id
                if let conv = store.conversation(id), Store.isChat(conv), !store.isArchived(conv),
                   workspace.panes[id] == nil {
                    _ = workspace.pane(for: conv)
                }
                if let chiefID = store.commander(of: id)?.chief,
                   let chiefConv = store.conversation(chiefID), Store.isChat(chiefConv), !store.isArchived(chiefConv),
                   workspace.panes[chiefID] == nil {
                    _ = workspace.pane(for: chiefConv)
                }
            }
        }
        if let forceLate {
            let records = eligibleEntries.map(\.record).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            sendLidInterruptNotices(records, late: forceLate)
        } else {
            let lateRecords = eligibleEntries.filter(\.late).map(\.record).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            let normalRecords = eligibleEntries.filter { !$0.late }.map(\.record).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            if !normalRecords.isEmpty { sendLidInterruptNotices(normalRecords, late: false) }
            if !lateRecords.isEmpty { sendLidInterruptNotices(lateRecords, late: true) }
        }
    }

    /// 琥珀旗標與開蓋自動繼續共用的候選篩選：存在、未封存、非工作中、有前景活動，且為可終止、已終止並已停止存活的模型程序。
    private func isInterruptedCandidate(_ record: LidInterruption) -> Bool {
        guard record.supportsTermination, record.terminated, !record.stillRunning,
              let conversation = store.conversation(record.id), !store.isArchived(conversation) else { return false }
        return store.status[record.id] != .working && record.foreground
    }

    /// 檢查該聊天室輸入框或磁碟草稿是否有未送出的草稿（見 §11.4）。
    private func hasPendingDraft(for id: UUID) -> Bool {
        if let pane = workspace.panes[id] as? ChatPane {
            return pane.inputBar.hasPendingInput
        }
        let persistence = DraftPersistence(directory: store.directory, conversationID: id)
        return FileManager.default.fileExists(atPath: persistence.fileURL.path) || persistence.hasQuarantined
    }

    @discardableResult
    private func presentPreservedQueueAlert(title: String, detail: String, log: ((String) -> Void)? = nil) -> Bool {
        if CommandLine.arguments.contains("--state-dir") {
            let line = "（測試）會提醒：\(title)｜\(detail.replacingOccurrences(of: "\n", with: " "))"
            if let log { log(line) } else { lidKeeper?.log(line) }
            return true
        }
        guard let w = window, w.attachedSheet == nil else { return false }
        let a = NSAlert(); a.alertStyle = .warning
        a.messageText = title; a.informativeText = detail
        a.addButton(withTitle: L("好"))
        a.beginSheetModal(for: w)
        return true
    }

    func sendLidInterruptResume(_ records: [LidInterruption],
                                deduplicator: LidNoticeDeduplicator = LidNoticeDeduplicator(),
                                notify: ((String, String) -> Void)? = nil,
                                log: ((String) -> Void)? = nil) {
        _ = deduplicator // 繼續訊息恰好一次由 LidKeeper 每輪狀態保證，不用跨輪 5 秒去重視窗。
        guard !records.isEmpty else { return }
        if CommandLine.arguments.contains("--state-dir"), LidIndicatorNoticeProbe.observe != nil {
            lidKeeper?.recordInterruptDelivery(handledIDs: Set(records.map(\.id)),
                                               failedRecords: [],
                                               late: false,
                                               handledRecords: records)
            return
        }
        let now = Date()
        let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        var memberSummaries: [UUID: [LidInterruption]] = [:]
        var standaloneOrChief: [UUID: LidInterruption] = [:]
        var fallbackNoticeRecords: [LidInterruption] = []
        var preservedQueueNotes: [String] = []
        var preservedNoteIDs: [UUID] = []
        var handledIDs = Set<UUID>()
        var failedRecords: [LidInterruption] = []
        let chiefAvailable: (UUID) -> Bool = { [weak self] chiefID in
            guard let self, let conversation = self.store.conversation(chiefID), !self.store.isArchived(conversation) else { return false }
            return self.workspace.panes[chiefID] is ChatPane
        }

        for record in records {
            guard isInterruptedCandidate(record) else {
                // 使用者在 3 秒內已自行發訊轉 working 等情形，仍要保全已移出寄件匣的排隊訊息原文不丟失（§9.8）。
                if let conversation = store.conversation(record.id), !store.isArchived(conversation),
                   record.supportsTermination, record.terminated,
                   (!record.queuedMessages.isEmpty || record.outboxReadFailed) {
                    fallbackNoticeRecords.append(record)
                } else if record.supportsTermination, record.terminated,
                          (!record.queuedMessages.isEmpty || record.outboxReadFailed) {
                    preservedQueueNotes.append(Self.preservedQueueDetail(for: record, reason: "聊天室不可用／已封存"))
                    preservedNoteIDs.append(record.id)
                } else if !record.supportsTermination, record.foreground {
                    // 本機模型等不主動停止的前景工作：開蓋時改走通知路徑補送一則資訊通知，不續送、不標琥珀旗標。
                    fallbackNoticeRecords.append(record)
                } else {
                    handledIDs.insert(record.id)
                }
                continue
            }
            if let chief = store.commander(of: record.id)?.chief, chief != record.id {
                store.markInterrupted(record.id, at: now)
                if chiefAvailable(chief) {
                    memberSummaries[chief, default: []].append(record)
                } else {
                    // Q6：總指揮不可用時成員絕不自行繼續，改走通知路徑並保留排隊原文。
                    fallbackNoticeRecords.append(record)
                }
            } else {
                standaloneOrChief[record.id] = record
            }
        }

        let targetIDs = Set(standaloneOrChief.keys).union(memberSummaries.keys).sorted { $0.uuidString < $1.uuidString }
        var sentRecipients: Set<UUID> = []

        for targetID in targetIDs {
            let selfRec = standaloneOrChief[targetID]
            let members = (memberSummaries[targetID] ?? []).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            let affectedRecords = ([selfRec].compactMap { $0 }) + members
            guard !affectedRecords.isEmpty else { continue }
            guard !sentRecipients.contains(targetID) else { continue }

            guard let targetConv = store.conversation(targetID), !store.isArchived(targetConv),
                  let pane = workspace.panes[targetID] as? ChatPane else {
                fallbackNoticeRecords.append(contentsOf: affectedRecords)
                continue
            }

            // §11.4：只要收件聊天室（包含總指揮彙總對象）輸入框或草稿有內容，略過自動繼續並提示，不覆蓋或打擾輸入框
            if hasPendingDraft(for: targetID) {
                for row in affectedRecords {
                    store.markInterrupted(row.id, at: now)
                }
                let queueRisk = affectedRecords.filter { !$0.queuedMessages.isEmpty || $0.outboxReadFailed }
                pane.notice(queueRisk.isEmpty
                    ? "輸入框尚有草稿，已略過開蓋自動繼續。"
                    : "輸入框尚有草稿，已略過開蓋自動繼續；先前的排隊訊息已附於系統提醒。")
                log?("開蓋自動繼續：聊天室 \(targetConv.title) 有草稿，略過繼續並僅標記琥珀燈")
                for row in affectedRecords {
                    if !row.queuedMessages.isEmpty || row.outboxReadFailed {
                        preservedQueueNotes.append(Self.preservedQueueDetail(for: row, reason: "草稿略過"))
                        preservedNoteIDs.append(row.id)
                    } else {
                        handledIDs.insert(row.id)
                    }
                }
                continue
            }

            let text = members.isEmpty
                ? LidInterruption.continueMessage(for: selfRec!)
                : LidInterruption.commanderContinueMessage(selfRecord: selfRec, members: members)

            let succeeded = pane.sendAutomatedText(text, source: "闔蓋繼續")
            if !succeeded {
                log?("開蓋自動繼續送出失敗（\(targetConv.title)），改走通知路徑")
                fallbackNoticeRecords.append(contentsOf: affectedRecords)
            } else {
                sentRecipients.insert(targetID)
                handledIDs.formUnion(affectedRecords.map(\.id))
            }
        }

        if !preservedQueueNotes.isEmpty {
            let detail = preservedQueueNotes.joined(separator: "\n\n")
            let canPresentAlert = CommandLine.arguments.contains("--state-dir") || (window != nil && window?.attachedSheet == nil)
            if let notify {
                notify("開蓋自動繼續保留的排隊訊息", detail)
                if canPresentAlert {
                    handledIDs.formUnion(preservedNoteIDs)
                } else {
                    failedRecords.append(contentsOf: preservedNoteIDs.compactMap { recordsByID[$0] })
                }
            } else if presentPreservedQueueAlert(title: "開蓋自動繼續保留的排隊訊息", detail: detail, log: log) {
                handledIDs.formUnion(preservedNoteIDs)
            } else {
                failedRecords.append(contentsOf: preservedNoteIDs.compactMap { recordsByID[$0] })
            }
        }
        if !handledIDs.isEmpty || !failedRecords.isEmpty || fallbackNoticeRecords.isEmpty {
            lidKeeper?.recordInterruptDelivery(handledIDs: handledIDs,
                                               failedRecords: failedRecords,
                                               late: false,
                                               handledRecords: handledIDs.compactMap { recordsByID[$0] })
        }
        if !fallbackNoticeRecords.isEmpty {
            if let lidKeeper {
                lidKeeper.sendInterruptNotices(fallbackNoticeRecords, false)
            } else {
                sendLidInterruptNotices(fallbackNoticeRecords, late: false)
            }
        }
    }

    private static func preservedQueueDetail(for row: LidInterruption, reason: String) -> String {
        var lines = ["• \(row.title)（\(row.engine)，\(reason)）"]
        if row.outboxReadFailed { lines.append("  寄件匣讀取失敗，可能有沒送出的訊息。") }
        if !row.queuedMessages.isEmpty {
            lines.append("  沒送出的排隊訊息原文：")
            lines += row.queuedMessages.map { "  \($0.text)" }
        }
        return lines.joined(separator: "\n")
    }

    func sendLidInterruptNotices(_ records: [LidInterruption], late: Bool) {
        guard !records.isEmpty else { return }
        let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let liveRecords = records.filter { id in
            guard let conversation = store.conversation(id.id) else { return false }
            return !store.isArchived(conversation)
        }
        let liveIDs = Set(liveRecords.map(\.id))
        let deadRecords = records.filter { !liveIDs.contains($0.id) }
        var handledIDs = Set<UUID>()
        var failedRecords: [LidInterruption] = []
        var preservedQueueNotes: [String] = []
        var preservedNoteIDs: [UUID] = []

        for row in deadRecords {
            if row.supportsTermination, row.terminated, (!row.queuedMessages.isEmpty || row.outboxReadFailed) {
                preservedQueueNotes.append(Self.preservedQueueDetail(for: row, reason: "聊天室不可用／已封存"))
                preservedNoteIDs.append(row.id)
            } else {
                handledIDs.insert(row.id)
            }
        }

        let now = Date()
        for record in liveRecords where isInterruptedCandidate(record) {
            store.markInterrupted(record.id, at: now)
        }
        let routes = LidInterruptionNoticeRouter.routes(liveRecords,
            commanderFor: { [weak self] id in self?.store.commander(of: id)?.chief },
            recipientAvailable: { [weak self] id in
                guard let self, let conversation = self.store.conversation(id), !self.store.isArchived(conversation) else { return false }
                return self.workspace.panes[id] is ChatPane
            })
        if CommandLine.arguments.contains("--state-dir"), let observe = LidIndicatorNoticeProbe.observe {
            observe(routes)
            lidKeeper?.recordInterruptDelivery(handledIDs: Set(records.map(\.id)),
                                               failedRecords: [],
                                               late: late,
                                               handledRecords: records)
            return // 探針觀測真路由後停止，避免通知觸發模型程序。
        }
        var routedIDs = Set<UUID>()
        for route in routes {
            routedIDs.formUnion(route.rows.map(\.id))
            guard let pane = workspace.panes[route.recipient] as? ChatPane else {
                failedRecords.append(contentsOf: route.rows)
                continue
            }
            let sent = workspace.withoutClearingInterrupted(for: route.recipient) {
                pane.sendAutomatedText(LidInterruption.noticeText(route.rows, late: late), source: "闔蓋中斷")
            }
            if sent {
                handledIDs.formUnion(route.rows.map(\.id))
            } else {
                let recipientTitle = store.conversation(route.recipient)?.title ?? route.recipient.uuidString
                lidKeeper?.log("闔蓋中斷通知送出失敗（\(recipientTitle)），保留記錄待補送")
                for row in route.rows {
                    if isInterruptedCandidate(row) {
                        store.markInterrupted(row.id, at: now)
                    }
                    failedRecords.append(row)
                }
            }
        }
        for row in liveRecords where !routedIDs.contains(row.id) {
            lidKeeper?.log("闔蓋中斷通知找不到可用視窗格（\(row.title)），保留記錄待補送")
            if isInterruptedCandidate(row) {
                store.markInterrupted(row.id, at: now)
            }
            failedRecords.append(row)
        }
        if !preservedQueueNotes.isEmpty {
            let detail = preservedQueueNotes.joined(separator: "\n\n")
            if presentPreservedQueueAlert(title: "闔蓋中斷保留的排隊訊息", detail: detail) {
                handledIDs.formUnion(preservedNoteIDs)
            } else {
                failedRecords.append(contentsOf: preservedNoteIDs.compactMap { recordsByID[$0] })
            }
        }
        lidKeeper?.recordInterruptDelivery(handledIDs: handledIDs,
                                           failedRecords: failedRecords,
                                           late: late,
                                           handledRecords: handledIDs.compactMap { recordsByID[$0] })
    }

    /// 總指揮 team 成員由總指揮持續派工；闔蓋時不打斷，也不在開蓋時插入繼續訊息。
    private func shouldSendLidNotice(to id: UUID) -> Bool {
        let commander = store.commander(of: id)
        return Self.shouldSendLidNotice(isCommanderMember: commander != nil && commander?.chief != id,
                                        isCommanderChief: commander?.chief == id)
    }

    static func shouldSendLidNotice(isCommanderMember: Bool, isCommanderChief: Bool) -> Bool {
        !isCommanderMember || isCommanderChief
    }
}
