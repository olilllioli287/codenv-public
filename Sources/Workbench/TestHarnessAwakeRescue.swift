import AppKit
import Darwin
import Foundation

private struct AwakeClosedRescueInput {
    let text: String
    let image: Bool
    let outboxReadFails: Bool
    let draft: String?
}

private struct AwakeClosedRescueFixture {
    let target: Conversation
    let chief: Conversation
    let targetPane: ChatPane?
    let chiefPane: ChatPane?
    let temporaryCodeLabGroupID: UUID?
}

private struct C418MessageFixture {
    let logicalID: String
    let text: String
    let imageMarker: String?
    var outboxID: String { logicalID.lowercased() }
}

private struct C418SendEvent {
    let sessionID: UUID
    let text: String
    let source: String
}

private struct C418TimelineEvent {
    let atSeconds: TimeInterval
    let name: String
    let chatID: String?
}

private struct C418CloseSnapshot {
    let chatUUID: UUID?
    let outboxMessageIDs: [String]
    let rescueMessageIDs: [String]
    let rescueEntryCount: Int
    let resumeCandidateSnapshot: [String: Any]
}

private struct C418DeliveryLedger: Codable {
    var targetConversationID: String? = nil
    var m1DeliveryCount = 0
    var m2DeliveryCount = 0
    var resumeCount = 0
}

private enum AwakeClosedRescueProbeSupport {
    static let caseIDs: Set<String> = Set((402...408).map { "C\($0)" })
    static let imageMarkerToken = "（含圖片附件）"
    private static let temporaryCodeLabGroupMarker = ".awake-closed-rescue-code-lab-group-id"

    private static func temporaryCodeLabGroupMarkerURL(root: URL) -> URL {
        root.appendingPathComponent(temporaryCodeLabGroupMarker)
    }

    static func cleanupTemporaryCodeLabGroup(id: UUID?, root: URL, store: Store) {
        guard let id else { return }
        store.groups.removeAll { $0.id == id }
        guard store.saveNow() else {
            EventLog.log("闔蓋救援掛鉤", "清理暫存程式碼學習群組時存檔失敗")
            return
        }
        let marker = temporaryCodeLabGroupMarkerURL(root: root)
        if FileManager.default.fileExists(atPath: marker.path) {
            do { try FileManager.default.removeItem(at: marker) }
            catch { EventLog.log("闔蓋救援掛鉤", "移除暫存群組標記失敗：\(error.localizedDescription)") }
        }
    }

    static func cleanupTemporaryCodeLabGroupFromMarker(root: URL, store: Store) {
        let marker = temporaryCodeLabGroupMarkerURL(root: root)
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        do {
            let raw = try String(contentsOf: marker, encoding: .utf8)
            guard let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                EventLog.log("闔蓋救援掛鉤", "暫存群組標記格式錯誤，保留群組以免刪錯")
                return
            }
            cleanupTemporaryCodeLabGroup(id: id, root: root, store: store)
        } catch {
            EventLog.log("闔蓋救援掛鉤", "讀取暫存群組標記失敗：\(error.localizedDescription)")
        }
    }

    static func envelope(_ caseID: String, _ observed: [String: Any]) -> [String: Any] {
        ["schemaVersion": 1, "caseId": caseID, "observed": observed]
    }

    static func failure(_ caseID: String, _ reason: String) -> [String: Any] {
        envelope(caseID, ["probeError": reason])
    }

    static func input(contract: URL, caseID: String) throws -> AwakeClosedRescueInput {
        let data = try Data(contentsOf: contract)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let item = root[caseID] as? [String: Any],
              let simulation = item["simulation"] as? [String: Any],
              let queue = simulation["queue"] as? [[String: Any]],
              let first = queue.first,
              let text = first["text"] as? String, !text.isEmpty else {
            throw ProbeError.invalidContract
        }
        return AwakeClosedRescueInput(text: text,
            image: first["image"] as? Bool ?? false,
            outboxReadFails: simulation["outboxReadFails"] as? Bool ?? false,
            draft: simulation["draft"] as? String)
    }

    static func makeFixture(delegate: AppDelegate, root: URL, caseID: String,
                            team: Bool, createPanes: Bool,
                            model: String = "codex:gpt-6-luna") throws -> AwakeClosedRescueFixture {
        let store = delegate.store!
        let teamGroup = team ? ConvGroup(name: "awake rescue fixture") : nil
        var temporaryCodeLabGroupID: UUID?
        let fixtureGroup: ConvGroup
        if let teamGroup {
            fixtureGroup = teamGroup
        } else if let existing = store.groups.first(where: {
            $0.name == Store.codeLabGroupName && $0.parentID == nil
        }) {
            fixtureGroup = existing
        } else {
            var created = ConvGroup(name: Store.codeLabGroupName)
            created.parentID = nil
            store.groups.append(created)
            fixtureGroup = created
            temporaryCodeLabGroupID = created.id
            do {
                try Data(created.id.uuidString.utf8).write(to: temporaryCodeLabGroupMarkerURL(root: root), options: .atomic)
            } catch {
                store.groups.removeAll { $0.id == created.id }
                throw ProbeError.stateWriteFailed
            }
        }
        var fixtureReturned = false
        defer {
            if !fixtureReturned, let temporaryCodeLabGroupID {
                cleanupTemporaryCodeLabGroup(id: temporaryCodeLabGroupID, root: root, store: store)
            }
        }
        var project = Project(name: "awake rescue fixture", path: root.path)
        project.groupID = fixtureGroup.id

        var target = Conversation(projectID: project.id, title: "\(caseID) member")
        // 預設用 Codex 假 app-server；需要實際接受訊息的 C415 改用 runner 已注入的假 agy。
        target.model = model
        var chief = target
        if team {
            chief = Conversation(projectID: project.id, title: "\(caseID) chief")
            chief.model = model
        } else {
            target.title = "\(caseID) rescue chat"
            chief = target
        }

        store.projects.append(project)
        if let teamGroup { store.groups.append(teamGroup) }
        store.conversations.append(chief)
        if team { store.conversations.append(target) }

        var window = WindowLayout(name: "1")
        if team {
            window.root = .split(vertical: false, ratio: 0.5, a: .leaf(chief.id), b: .leaf(target.id))
        } else {
            window.root = .leaf(target.id)
        }
        window.focused = chief.id
        let layout = SessionLayout(name: "awake rescue fixture", windows: [window], current: window.id,
                                   groups: teamGroup.map { [$0.id] }, chief: team ? chief.id : nil,
                                   commanderKind: team ? "single" : nil)
        store.sessions.append(layout)
        store.currentSession = layout.id
        store.selectedProject = project.id
        store.selected = chief.id
        guard store.saveNow() else { throw ProbeError.stateWriteFailed }

        var targetPane: ChatPane?
        var chiefPane: ChatPane?
        if createPanes {
            targetPane = delegate.workspace.pane(for: target) as? ChatPane
            guard targetPane != nil else { throw ProbeError.fixturePaneUnavailable }
            _ = chatSession(root: root, conversation: target, pane: targetPane)
            if team {
                chiefPane = delegate.workspace.pane(for: chief) as? ChatPane
                guard chiefPane != nil else { throw ProbeError.fixturePaneUnavailable }
                _ = chatSession(root: root, conversation: chief, pane: chiefPane)
            } else {
                chiefPane = targetPane
            }
        }
        fixtureReturned = true
        return AwakeClosedRescueFixture(target: target, chief: chief, targetPane: targetPane, chiefPane: chiefPane,
                                        temporaryCodeLabGroupID: temporaryCodeLabGroupID)
    }

    static func seedOutbox(root: URL, conversation: Conversation, text: String, image: Bool) throws -> String {
        let id = UUID().uuidString.lowercased()
        var images: [(data: Data, mediaType: String)] = []
        if image {
            guard let pixel = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/g9sAAAAASUVORK5CYII=") else {
                throw ProbeError.fixtureImageInvalid
            }
            images.append((data: pixel, mediaType: "image/png"))
        }
        try OutboxPersistence(directory: root, conversationID: conversation.claudeSession)
            .append(id: id, text: text, wireText: text, quotes: [], filePaths: [], images: images, transcriptURLs: [])
        return id
    }

    static func chatSession(root: URL, conversation: Conversation, pane: ChatPane?) -> ChatSession {
        let session = pane?.session ?? ChatSession(claudeSession: conversation.claudeSession, directory: root.path)
        // 合成 pane 可能已在 fixture 寫入 store 前建立；測試訊息必須綁到本次 --state-dir。
        session.outboxPersistence = OutboxPersistence(directory: root, conversationID: conversation.claudeSession)
        return session
    }

    private static func draftSnapshot(_ pane: ChatPane?) -> [String: Any] {
        guard let pane else {
            return ["paneExists": false, "hasPendingInput": NSNull(), "inputTextLength": NSNull(),
                    "inputTextNonEmpty": NSNull(), "draftFilePathsCount": NSNull(),
                    "draftFilePathsNonEmpty": NSNull(), "draftImagesCount": NSNull(),
                    "draftImagesNonEmpty": NSNull()]
        }
        let text = pane.inputBar.textView.string
        let filePathCount = pane.inputBar.draftFilePaths.count
        let imageCount = pane.inputBar.draftImages.count
        return ["paneExists": true, "hasPendingInput": pane.inputBar.hasPendingInput,
                "inputTextLength": text.utf16.count, "inputTextNonEmpty": !text.isEmpty,
                "draftFilePathsCount": filePathCount, "draftFilePathsNonEmpty": filePathCount > 0,
                "draftImagesCount": imageCount, "draftImagesNonEmpty": imageCount > 0]
    }

    static func dispatchSnapshots(records: [LidInterruption], store: Store, workspace: Workspace,
                                  root: URL) -> [[String: Any]] {
        records.map { record in
            let conversation = store.conversation(record.id)
            let pane = workspace.panes[record.id] as? ChatPane
            let status = store.status[record.id]
            let isInterruptedCandidate = record.supportsTermination && record.terminated
                && conversation.map { !store.isArchived($0) } == true
                && status != .working && record.foreground
            let commander = store.commander(of: record.id)
            let chiefID = commander?.chief
            let chiefConversation = chiefID.flatMap { store.conversation($0) }
            let chiefPane = chiefID.flatMap { workspace.panes[$0] as? ChatPane }
            let chiefAvailable = chiefConversation.map { !store.isArchived($0) } == true && chiefPane != nil
            let routesToChief = isInterruptedCandidate && chiefID.map { $0 != record.id } == true && chiefAvailable
            let recipientID = routesToChief ? (chiefID ?? record.id) : record.id
            let recipientPane = workspace.panes[recipientID] as? ChatPane
            let paneSnapshot = draftSnapshot(pane)
            let recipientPaneSnapshot = draftSnapshot(recipientPane)

            let outbox = conversation.map {
                OutboxPersistence(directory: root, conversationID: $0.claudeSession)
            }
            var outboxReadSucceeded: Bool?
            var outboxMessageCount: Int?
            var outboxTextMessageCount: Int?
            var outboxImageCount: Int?
            if let outbox {
                do {
                    let messages = try outbox.read()
                    outboxReadSucceeded = true
                    outboxMessageCount = messages.count
                    outboxTextMessageCount = messages.filter { !$0.text.isEmpty }.count
                    outboxImageCount = messages.reduce(0) { $0 + $1.images.count }
                } catch {
                    outboxReadSucceeded = false
                }
            }
            let queuedImageMarkers = record.queuedMessages.filter { $0.text.contains(imageMarkerToken) }.count
            var snapshot: [String: Any] = [
                "recordID": record.id.uuidString,
                "supportsTermination": record.supportsTermination,
                "terminated": record.terminated,
                "foreground": record.foreground,
                "conversationExists": conversation != nil,
                "isArchived": conversation.map { store.isArchived($0) } as Any? ?? NSNull(),
                "storeStatus": status.map { String(describing: $0) } as Any? ?? NSNull(),
                "storeStatusWorking": status.map { $0 == .working } as Any? ?? NSNull(),
                "commanderID": commander?.id.uuidString as Any? ?? NSNull(),
                "chiefID": chiefID?.uuidString as Any? ?? NSNull(),
                "chiefConversationExists": chiefConversation != nil,
                "chiefIsSelf": chiefID.map { $0 == record.id } as Any? ?? NSNull(),
                "routerCandidate": isInterruptedCandidate,
                "pane": paneSnapshot,
                "routerRecipientID": recipientID.uuidString,
                "routerRecipientPane": recipientPaneSnapshot,
                "queuedMessagesCount": record.queuedMessages.count,
                "queuedMessagesWithTextCount": record.queuedMessages.filter { !$0.text.isEmpty }.count,
                "queuedMessagesImageMarkerCount": queuedImageMarkers,
                "outboxReadFailed": record.outboxReadFailed,
                "outboxPath": outbox?.fileURL.path as Any? ?? NSNull(),
                "outboxFileExists": outbox.map { FileManager.default.fileExists(atPath: $0.fileURL.path) } as Any? ?? NSNull(),
                "outboxReadSucceeded": outboxReadSucceeded as Any? ?? NSNull(),
                "outboxMessageCount": outboxMessageCount as Any? ?? NSNull(),
                "outboxTextMessageCount": outboxTextMessageCount as Any? ?? NSNull(),
                "outboxImageAttachmentCount": outboxImageCount as Any? ?? NSNull(),
                "messagePlacement": [
                    "outboxTextMessageCount": outboxTextMessageCount as Any? ?? NSNull(),
                    "queuedMessagesWithTextCount": record.queuedMessages.filter { !$0.text.isEmpty }.count,
                    "inputBarTextLength": paneSnapshot["inputTextLength"] ?? NSNull(),
                    "inputBarTextNonEmpty": paneSnapshot["inputTextNonEmpty"] ?? NSNull()
                ] as [String: Any],
                "imagePlacement": [
                    "outboxAttachmentCount": outboxImageCount as Any? ?? NSNull(),
                    "queuedMessagesContainsImageMarker": queuedImageMarkers > 0,
                    "inputBarDraftImageCount": paneSnapshot["draftImagesCount"] ?? NSNull()
                ] as [String: Any]
            ]
            snapshot["chiefPaneExists"] = chiefPane != nil
            snapshot["routeUsesChiefSummary"] = routesToChief
            return snapshot
        }
    }

    static func recordFromOutbox(root: URL, conversation: Conversation, pane: ChatPane?, queueID: String) throws -> LidInterruption {
        let session = chatSession(root: root, conversation: conversation, pane: pane)
        let pending = session.pendingMessagesForLidInterrupt()
        guard pending.messages.contains(where: { $0.id == queueID }) else { throw ProbeError.queueNotRead }
        return LidInterruption(id: conversation.id, title: conversation.title, engine: conversation.modelCategory,
                               supportsTermination: true, details: [], queuedMessages: pending.messages,
                               terminated: true, forceKilled: false, stillRunning: false,
                               outboxReadFailed: pending.outboxReadFailed, foreground: true)
    }

    static func persistence(root: URL) -> LidInterruptRescuePersistence {
        LidInterruptRescuePersistence(fileURL: MainWindowController.lidRescueURL(stateDirectory: root))
    }

    static func entries(_ persistence: LidInterruptRescuePersistence) throws -> [LidRescueEntry] {
        switch persistence.loadResult() {
        case .empty: return []
        case .loaded(let entries): return entries
        case .readFailed: throw ProbeError.rescueReadFailed
        }
    }

    static func outboxIDs(root: URL, conversation: Conversation) throws -> Set<String> {
        Set(try OutboxPersistence(directory: root, conversationID: conversation.claudeSession).read().map(\.id))
    }

    static func originalQueueStillStored(root: URL, conversation: Conversation, queueID: String,
                                         persistence: LidInterruptRescuePersistence) throws -> Bool {
        if try outboxIDs(root: root, conversation: conversation).contains(queueID) { return true }
        return try entries(persistence).contains { entry in
            entry.record.id == conversation.id && entry.record.queuedMessages.contains { $0.id == queueID }
        }
    }

    static func triggerClose(keeper: LidKeeper, sim: SimLidEnv) throws -> [LidRescueEntry] {
        sim.closed = true
        keeper.tick()
        guard let rescueURL = keeper.rescueURL else { throw ProbeError.closeDidNotPersistRescue }
        let saved = try entries(persistence(root: rescueURL.deletingLastPathComponent()))
        guard !saved.isEmpty, keeper.isAwakeClosed else { throw ProbeError.closeDidNotPersistRescue }
        return saved
    }

    static func observedText(_ text: String, contains value: String) -> Bool {
        !value.isEmpty && text.contains(value)
    }

    static func imageMarker(in text: String) -> String {
        guard let range = text.range(of: imageMarkerToken) else { return "" }
        return String(text[range])
    }

    static func outboxWarning(in text: String) -> String {
        guard let line = text.components(separatedBy: .newlines).first(where: { $0.contains("寄件匣讀取失敗") }) else {
            return ""
        }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix("。") ? String(trimmed.dropLast()) : trimmed
    }

    enum ProbeError: LocalizedError {
        case invalidContract, stateWriteFailed, fixturePaneUnavailable, fixtureImageInvalid
        case queueNotRead, rescueReadFailed, closeDidNotPersistRescue, noIsolatedApp, noKeeper, noSimulatedLid
        case unsupportedPhase(String)

        var errorDescription: String? {
            switch self {
            case .invalidContract: return "規格 fixture 缺欄位或格式錯誤"
            case .stateWriteFailed: return "無法將合成聊天室寫入隔離 state-dir"
            case .fixturePaneUnavailable: return "無法建立合成 ChatPane"
            case .fixtureImageInvalid: return "合成圖片 fixture 無法解碼"
            case .queueNotRead: return "產品寄件匣路徑未讀回合成排隊訊息"
            case .rescueReadFailed: return "讀取隔離 rescue JSON 失敗"
            case .closeDidNotPersistRescue: return "產品闔蓋流程沒有寫出 rescue 記錄"
            case .noIsolatedApp: return "探針只能在 --state-dir App 實例執行"
            case .noKeeper: return "MainWindowController 尚未建立 LidKeeper"
            case .noSimulatedLid: return "隔離探針未使用 SimLidEnv"
            case .unsupportedPhase(let phase): return "不支援的 phase：\(phase)"
            }
        }
    }
}

extension TestHarness {
    static func awakeClosedRescueProbe(caseID: String, contract: URL, phase: String, stateRoot: URL) -> [String: Any]? {
        guard AwakeClosedRescueProbeSupport.caseIDs.contains(caseID) else { return nil }
        do {
            guard Thread.isMainThread,
                  CommandLine.arguments.contains("--state-dir"),
                  let stateIndex = CommandLine.arguments.firstIndex(of: "--state-dir"), stateIndex + 1 < CommandLine.arguments.count,
                  let delegate = NSApp.delegate as? AppDelegate,
                  delegate.store != nil, delegate.main?.lidKeeper != nil else {
                throw AwakeClosedRescueProbeSupport.ProbeError.noIsolatedApp
            }
            let requestedRoot = stateRoot.standardizedFileURL.resolvingSymlinksInPath()
            let appRoot = delegate.store.directory.standardizedFileURL.resolvingSymlinksInPath()
            let argumentRoot = URL(fileURLWithPath: CommandLine.arguments[stateIndex + 1], isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath()
            guard requestedRoot == appRoot, requestedRoot == argumentRoot else {
                throw AwakeClosedRescueProbeSupport.ProbeError.noIsolatedApp
            }
            let input = try AwakeClosedRescueProbeSupport.input(contract: contract, caseID: caseID)
            if caseID == "C407" {
                guard phase == "prepare" || phase == "resume" else {
                    throw AwakeClosedRescueProbeSupport.ProbeError.unsupportedPhase(phase)
                }
                return try runC407(delegate: delegate, root: requestedRoot, input: input, phase: phase)
            }
            guard phase == "single" else { throw AwakeClosedRescueProbeSupport.ProbeError.unsupportedPhase(phase) }
            return try runSingle(delegate: delegate, root: requestedRoot, caseID: caseID, input: input)
        } catch {
            return AwakeClosedRescueProbeSupport.failure(caseID, error.localizedDescription)
        }
    }

    private static func runSingle(delegate: AppDelegate, root: URL, caseID: String,
                                  input: AwakeClosedRescueInput) throws -> [String: Any] {
        guard let keeper = delegate.main.lidKeeper else { throw AwakeClosedRescueProbeSupport.ProbeError.noKeeper }
        let persistence = AwakeClosedRescueProbeSupport.persistence(root: root)
        let isTeam = caseID == "C406"
        let needsPane = caseID != "C404"
        let fixture = try AwakeClosedRescueProbeSupport.makeFixture(delegate: delegate, root: root,
            caseID: caseID, team: isTeam, createPanes: needsPane)
        defer {
            AwakeClosedRescueProbeSupport.cleanupTemporaryCodeLabGroup(id: fixture.temporaryCodeLabGroupID,
                root: root, store: delegate.store!)
        }
        let queueConversation = AwakeClosedRescueProbeSupport.chatSession(root: root,
            conversation: fixture.target, pane: fixture.targetPane)
        let queueID = try AwakeClosedRescueProbeSupport.seedOutbox(root: root, conversation: fixture.target,
            text: input.text, image: input.image)
        // 重新讀寄件匣取得實際 LidQueuedMessage；records 不是從 contract.expected 還原。
        let snapshot = queueConversation.pendingMessagesForLidInterrupt()
        guard snapshot.messages.contains(where: { $0.id == queueID }) else {
            throw AwakeClosedRescueProbeSupport.ProbeError.queueNotRead
        }

        let oldEnabled = keeper.enabled
        let oldInterruptEnabled = keeper.interruptOnCloseEnabled
        let oldPendingMessages = keeper.pendingMessagesForInterrupt
        var modeEnabled = true
        keeper.enabled = { modeEnabled }
        keeper.interruptOnCloseEnabled = { modeEnabled }
        defer {
            keeper.enabled = oldEnabled
            keeper.interruptOnCloseEnabled = oldInterruptEnabled
            keeper.pendingMessagesForInterrupt = oldPendingMessages
        }

        if caseID == "C402", input.outboxReadFails {
            keeper.pendingMessagesForInterrupt = { id in
                let actual = oldPendingMessages(id)
                return LidInterruptPendingMessages(messages: actual.messages, outboxReadFailed: true)
            }
        }

        var sent: [(UUID, String, String?)] = []
        let previousSendObserver = ChatPane.lidInterruptSendObserver
        ChatPane.lidInterruptSendObserver = { id, text, source, _ in sent.append((id, text, source)) }
        defer { ChatPane.lidInterruptSendObserver = previousSendObserver }

        var row: LidInterruption
        if caseID == "C402" || caseID == "C406" || caseID == "C408" {
            guard let sim = keeper.env as? SimLidEnv else { throw AwakeClosedRescueProbeSupport.ProbeError.noSimulatedLid }
            delegate.store.status[fixture.target.id] = .working
            _ = try AwakeClosedRescueProbeSupport.triggerClose(keeper: keeper, sim: sim)
            if caseID == "C402" || caseID == "C406" {
                // 模擬 terminateForInterrupt 完成後的同步 idle 回報：ChatSession.swift:1022 設 .idle
                // → ChatSession.swift:207 呼叫 onStatus → ChatPane.swift:528–534 → Workspace.swift onStatus 將 nil 寫回 store。
                // 此 fixture 先手動種成 working；明確移除字典項目等同產品的 idle(nil)，與 C386 的掛鉤模擬相同。
                delegate.store.status[fixture.target.id] = nil
            }
            guard let entry = try AwakeClosedRescueProbeSupport.entries(persistence)
                .first(where: { $0.record.id == fixture.target.id }) else {
                throw AwakeClosedRescueProbeSupport.ProbeError.closeDidNotPersistRescue
            }
            row = entry.record
        } else {
            row = try AwakeClosedRescueProbeSupport.recordFromOutbox(root: root, conversation: fixture.target,
                pane: fixture.targetPane, queueID: queueID)
            guard persistence.upsert([row], late: false) else { throw AwakeClosedRescueProbeSupport.ProbeError.stateWriteFailed }
            if caseID == "C405" { delegate.store.status[fixture.target.id] = .working }
        }

        if caseID == "C408" {
            modeEnabled = false
            keeper.tick()
            guard let sim = keeper.env as? SimLidEnv else { throw AwakeClosedRescueProbeSupport.ProbeError.noSimulatedLid }
            let rescueEntries = try AwakeClosedRescueProbeSupport.entries(persistence)
            let retained = rescueEntries.contains { entry in
                entry.record.id == fixture.target.id && entry.record.queuedMessages.contains { $0.id == queueID }
            }
            let sleepCount = sim.trace.filter { $0["event"] as? String == "sleepNow" }.count
            return AwakeClosedRescueProbeSupport.envelope(caseID, [
                "awakeClosedCleared": !keeper.isAwakeClosed,
                "recordsCleared": !keeper.hasPendingInterruptNotice,
                "nosleepReleased": sim.noSleepStatus() == false && !sim.actualOn,
                "sleepNowCount": sleepCount,
                "queueStillInOutboxOrRescue": try AwakeClosedRescueProbeSupport.originalQueueStillStored(
                    root: root, conversation: fixture.target, queueID: queueID, persistence: persistence) || retained
            ])
        }

        if caseID == "C402" && input.outboxReadFails {
            row.outboxReadFailed = true
            guard persistence.upsert([row], late: false) else { throw AwakeClosedRescueProbeSupport.ProbeError.stateWriteFailed }
        }
        if caseID == "C403", let draft = input.draft, let pane = fixture.targetPane {
            pane.inputBar.textView.string = draft
        }

        guard AgyBridge.canLaunchInCurrentInstance else {
            throw AwakeClosedRescueProbeSupport.ProbeError.noIsolatedApp
        }
        var resumeDispatchCalls: [[String: Any]] = []
        let capturesResumeDispatch = caseID == "C402" || caseID == "C406"
        let previousResumeDispatch = keeper.sendInterruptResume
        if capturesResumeDispatch {
            keeper.sendInterruptResume = { records in
                resumeDispatchCalls.append([
                    "recordCount": records.count,
                    "records": AwakeClosedRescueProbeSupport.dispatchSnapshots(
                        records: records, store: delegate.store!, workspace: delegate.workspace, root: root)
                ])
                previousResumeDispatch(records)
            }
        }
        defer {
            if capturesResumeDispatch { keeper.sendInterruptResume = previousResumeDispatch }
        }
        if caseID == "C402" || caseID == "C406" {
            guard let sim = keeper.env as? SimLidEnv else {
                throw AwakeClosedRescueProbeSupport.ProbeError.noSimulatedLid
            }
            // 走真正的開蓋狀態轉換，讓 LidKeeper 自己排程續送；只直接呼叫
            // sendInterruptResume 會繞過 !lidShut && wasLidShut 這段產品路徑。
            sim.closed = false
            sim.screenOff = false
            sim.suppressLidObservation = false
            keeper.tick()
            let observedConversations: Set<UUID> = [fixture.target.claudeSession, fixture.chief.claudeSession]
            pollMainRunLoop(timeout: 15) {
                sent.contains {
                    observedConversations.contains($0.0)
                        && ($0.2 == "闔蓋繼續" || $0.2 == "闔蓋中斷")
                }
            }
        } else {
            // C403–C405 是獨立建立 rescue row 的路由情境，keeper 沒有本輪
            // interruptRecords；保留直接送入實際續送 router 的既有測試方式。
            keeper.sendInterruptResume([row])
        }
        let capturedResume = sent.filter { $0.2 == "闔蓋繼續" }.map { $0.1 }.joined(separator: "\n")
        let queueIDs = try AwakeClosedRescueProbeSupport.outboxIDs(root: root, conversation: fixture.target)
        let rescueEntries = try AwakeClosedRescueProbeSupport.entries(persistence)
        let rescueRow = rescueEntries.first { $0.record.id == fixture.target.id }
        let stillQueued = queueIDs.contains(queueID) || (rescueRow?.record.queuedMessages.contains { $0.id == queueID } ?? false)
        var dispatchDiagnostics: [String: Any] = [:]
        if capturesResumeDispatch {
            let observerEvents: [[String: Any]] = sent.map { event in
                var value: [String: Any] = ["conversationID": event.0.uuidString]
                value["source"] = event.2 as Any? ?? NSNull()
                return value
            }
            let resumeSourceCount = sent.filter { $0.2 == "闔蓋繼續" }.count
            let fallbackNoticeCount = sent.filter { $0.2 == "闔蓋中斷" }.count
            let draftSkipNoticeText = "輸入框尚有草稿，已略過開蓋自動繼續"
            let draftSkipNoticeBuffered = [fixture.targetPane, fixture.chiefPane].compactMap { $0 }
                .contains { pane in pane.modelSelectionProbeNotices.contains { $0.contains(draftSkipNoticeText) } }
            let sendOutcomeInference: String
            if resumeSourceCount == 0 {
                sendOutcomeInference = "沒有觀察到 source=闔蓋繼續 的 observer 呼叫；sendAutomatedText 結果無法推論"
            } else if fallbackNoticeCount > 0 {
                sendOutcomeInference = "觀察到闔蓋繼續呼叫及闔蓋中斷 fallback；observer 在實際 send 前觸發，無法單獨判定回傳值"
            } else {
                sendOutcomeInference = "觀察到闔蓋繼續呼叫且未觀察到闔蓋中斷 fallback；observer 在實際 send 前觸發，不能證明回傳 true"
            }
            dispatchDiagnostics = [
                "sendInterruptResumeDispatchCount": resumeDispatchCalls.count,
                "sendInterruptResumeDispatches": resumeDispatchCalls,
                "lidInterruptSendObserverCount": sent.count,
                "lidInterruptSendObserverEvents": observerEvents,
                "resumeObserverCount": resumeSourceCount,
                "fallbackNoticeObserverCount": fallbackNoticeCount,
                "fallbackNoticeObserved": fallbackNoticeCount > 0,
                "draftSkipNoticeInNativeBuffer": draftSkipNoticeBuffered,
                "draftSkipNoticeVisibleInWebObservable": false,
                "draftSkipNoticeObservability": "只能檢查 ChatPane 的待顯示 notice 緩衝；notice 若直接送到已 ready 的 WebKit 畫面，掛鉤無法讀回是否顯示",
                "sendAutomatedTextReturnObservable": false,
                "sendAutomatedTextReturnValue": NSNull(),
                "sendAutomatedTextOutcomeInference": sendOutcomeInference
            ]
        }

        switch caseID {
        case "C402":
            let resumeAttempted = sent.contains { $0.0 == fixture.target.claudeSession && $0.2 == "闔蓋繼續" }
            let fallbackNoticeAttempted = sent.contains { $0.0 == fixture.target.claudeSession && $0.2 == "闔蓋中斷" }
            let outboxWarning = AwakeClosedRescueProbeSupport.outboxWarning(in: capturedResume)
            var observed: [String: Any] = [
                "messageContainsOriginal": AwakeClosedRescueProbeSupport.observedText(capturedResume, contains: input.text),
                "imageMarker": AwakeClosedRescueProbeSupport.imageMarker(in: capturedResume),
                "outboxReadFailed": !outboxWarning.isEmpty,
                "resumeWarning": outboxWarning,
                "queueContentPreservedInResumeText": AwakeClosedRescueProbeSupport.observedText(capturedResume, contains: input.text),
                "queuePendingClearedAfterSuccess": resumeAttempted && !fallbackNoticeAttempted
                    && !queueIDs.contains(queueID) && rescueRow == nil
            ]
            observed.merge(dispatchDiagnostics) { _, diagnostic in diagnostic }
            return AwakeClosedRescueProbeSupport.envelope(caseID, observed)
        case "C403":
            return AwakeClosedRescueProbeSupport.envelope(caseID, [
                "resumeCount": sent.filter { $0.2 == "闔蓋繼續" }.count,
                "amberFlag": delegate.store.conversation(fixture.target.id)?.interruptedAt != nil,
                "queueStillInOutboxOrRescue": stillQueued
            ])
        case "C404":
            return AwakeClosedRescueProbeSupport.envelope(caseID, [
                "rescueRecordPresent": rescueRow != nil,
                "queueDeleted": !queueIDs.contains(queueID),
                "queueStillInRescue": rescueRow?.record.queuedMessages.contains { $0.id == queueID && $0.text.contains(input.text) } ?? false
            ])
        case "C405":
            return AwakeClosedRescueProbeSupport.envelope(caseID, [
                "resumeCount": sent.filter { $0.2 == "闔蓋繼續" }.count,
                "queueStillInOutbox": queueIDs.contains(queueID)
            ])
        case "C406":
            let aggregate = sent.filter { $0.0 == fixture.chief.claudeSession && $0.2 == "闔蓋繼續" }
                .map { $0.1 }.joined(separator: "\n")
            let resumeAttempted = sent.contains { $0.0 == fixture.chief.claudeSession && $0.2 == "闔蓋繼續" }
            let fallbackNoticeAttempted = sent.contains { $0.0 == fixture.target.claudeSession && $0.2 == "闔蓋中斷" }
            var observed: [String: Any] = [
                "aggregateContainsOriginal": AwakeClosedRescueProbeSupport.observedText(aggregate, contains: input.text),
                "imageMarker": AwakeClosedRescueProbeSupport.imageMarker(in: aggregate),
                "queuePreserved": AwakeClosedRescueProbeSupport.observedText(aggregate, contains: input.text),
                "queuePendingClearedAfterSuccess": resumeAttempted && !fallbackNoticeAttempted
                    && !queueIDs.contains(queueID) && rescueRow == nil
            ]
            observed.merge(dispatchDiagnostics) { _, diagnostic in diagnostic }
            return AwakeClosedRescueProbeSupport.envelope(caseID, observed)
        default:
            throw AwakeClosedRescueProbeSupport.ProbeError.invalidContract
        }
    }

    private static func pollMainRunLoop(timeout: TimeInterval, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        var observed = condition()
        while !observed, Date() < deadline {
            RunLoop.main.run(until: min(Date().addingTimeInterval(0.05), deadline))
            observed = condition()
        }
        if observed {
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
    }

    private static func runC407(delegate: AppDelegate, root: URL, input: AwakeClosedRescueInput,
                                phase: String) throws -> [String: Any] {
        guard let keeper = delegate.main.lidKeeper else { throw AwakeClosedRescueProbeSupport.ProbeError.noKeeper }
        let persistence = AwakeClosedRescueProbeSupport.persistence(root: root)
        var preparedForRestart = false
        defer {
            if !preparedForRestart {
                AwakeClosedRescueProbeSupport.cleanupTemporaryCodeLabGroupFromMarker(root: root, store: delegate.store!)
            }
        }
        if phase == "prepare" {
            let fixture = try AwakeClosedRescueProbeSupport.makeFixture(delegate: delegate, root: root,
                caseID: "C407", team: false, createPanes: true)
            guard let pane = fixture.targetPane else { throw AwakeClosedRescueProbeSupport.ProbeError.fixturePaneUnavailable }
            let queueID = try AwakeClosedRescueProbeSupport.seedOutbox(root: root, conversation: fixture.target,
                text: input.text, image: input.image)
            guard pane.pendingMessagesForLidInterrupt().messages.contains(where: { $0.id == queueID }),
                  let sim = keeper.env as? SimLidEnv else { throw AwakeClosedRescueProbeSupport.ProbeError.queueNotRead }
            var prepareSends: [(UUID, String, String?)] = []
            let previousSendObserver = ChatPane.lidInterruptSendObserver
            ChatPane.lidInterruptSendObserver = { id, text, source, _ in prepareSends.append((id, text, source)) }
            defer { ChatPane.lidInterruptSendObserver = previousSendObserver }
            keeper.enabled = { true }
            keeper.interruptOnCloseEnabled = { true }
            delegate.store.status[fixture.target.id] = .working
            _ = try AwakeClosedRescueProbeSupport.triggerClose(keeper: keeper, sim: sim)
            guard delegate.store.saveNow() else { throw AwakeClosedRescueProbeSupport.ProbeError.stateWriteFailed }
            let entries = try AwakeClosedRescueProbeSupport.entries(persistence)
            let row = entries.first { $0.record.id == fixture.target.id }
            let outboxStillHasOriginal = try AwakeClosedRescueProbeSupport.outboxIDs(root: root, conversation: fixture.target).contains(queueID)
            let prepared = AwakeClosedRescueProbeSupport.envelope("C407", [
                "rescueWritten": row != nil,
                "resumeCount": prepareSends.filter { $0.2 == "闔蓋繼續" }.count,
                "noticeCount": prepareSends.filter { $0.2 == "闔蓋中斷" }.count,
                "noticeContainsOriginalQueueText": prepareSends.contains { $0.2 == "闔蓋中斷" && $0.1.contains(input.text) },
                "outboxQueueRemovedAfterRescuePersist": !outboxStillHasOriginal
                    && row?.record.queuedMessages.contains { $0.id == queueID } == true
            ])
            // 呼叫端同步寫出 prepare.json 後，此排程結束第一個 App 程序；不讓記憶體中斷記錄代替跨程序恢復。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { Darwin.exit(0) }
            preparedForRestart = true
            return prepared
        }

        let beforeEntries = try AwakeClosedRescueProbeSupport.entries(persistence)
        let rescueFileExistedAtResumeStart = FileManager.default.fileExists(atPath: persistence.fileURL.path)
        for entry in beforeEntries {
            if let conversation = delegate.store.conversation(entry.record.id),
               !delegate.store.isArchived(conversation), delegate.workspace.panes[conversation.id] == nil {
                _ = delegate.workspace.pane(for: conversation)
            }
            if let chiefID = delegate.store.commander(of: entry.record.id)?.chief,
               let chief = delegate.store.conversation(chiefID), !delegate.store.isArchived(chief),
               delegate.workspace.panes[chiefID] == nil {
                _ = delegate.workspace.pane(for: chief)
            }
        }
        var routeCount = 0
        var noticeTexts: [String] = []
        var resumeCount = 0
        let priorRouteObserver = LidIndicatorNoticeProbe.observe
        let priorSendObserver = ChatPane.lidInterruptSendObserver
        defer {
            LidIndicatorNoticeProbe.observe = priorRouteObserver
            ChatPane.lidInterruptSendObserver = priorSendObserver
        }
        LidIndicatorNoticeProbe.observe = { routes in
            routeCount += routes.count
            noticeTexts += routes.map { LidInterruption.noticeText($0.rows, late: true) }
        }
        ChatPane.lidInterruptSendObserver = { _, _, source, _ in
            if source == "闔蓋繼續" { resumeCount += 1 }
        }
        pollMainRunLoop(timeout: 15) {
            routeCount > 0 || resumeCount > 0
        }
        let afterEntries = try AwakeClosedRescueProbeSupport.entries(persistence)
        let queueIDs = Set(beforeEntries.flatMap { $0.record.queuedMessages.map(\.id) })
        let outboxGone = try beforeEntries.allSatisfy { entry in
            guard let conversation = delegate.store.conversation(entry.record.id) else { return false }
            return try AwakeClosedRescueProbeSupport.outboxIDs(root: root, conversation: conversation).isDisjoint(with: queueIDs)
        }
        let noticeContainsOriginal = noticeTexts.contains { $0.contains(input.text) }
        let deliveredAndRemoved = rescueFileExistedAtResumeStart && routeCount > 0 && afterEntries.isEmpty && outboxGone
        return AwakeClosedRescueProbeSupport.envelope("C407", [
            "rescueSurvivesRestart": rescueFileExistedAtResumeStart && !beforeEntries.isEmpty,
            "resumeCount": resumeCount,
            "noticeCount": routeCount,
            "noticeContainsOriginalQueueText": noticeContainsOriginal,
            "queueDeletedOnlyAfterNoticeSuccess": deliveredAndRemoved
        ])
    }
}

private enum LidRescueRecoveryProbeSupport {
    enum ProbeError: LocalizedError {
        case invalidContract, missingKeeper, missingSimulationFile, missingRecord, fixtureUnavailable
        case persistenceWriteFailed, unexpectedPhase, faultInjectionFailed(String), ledgerInvalid

        var errorDescription: String? {
            switch self {
            case .invalidContract: return "救援復原 fixture 缺欄位或格式錯誤"
            case .missingKeeper: return "MainWindowController 尚未建立 LidKeeper"
            case .missingSimulationFile: return "預期的救援 JSON 檔不存在"
            case .missingRecord: return "救援檔中找不到合成記錄"
            case .fixtureUnavailable: return "無法建立救援復原合成聊天室或 pane"
            case .persistenceWriteFailed: return "無法透過產品救援 persistence 寫入 fixture"
            case .unexpectedPhase: return "不支援的 scenario／phase"
            case .faultInjectionFailed(let detail): return "隔離故障注入失敗：\(detail)"
            case .ledgerInvalid: return "讀取或更新隔離 probe ledger 失敗"
            }
        }
    }

    struct Ledger: Codable {
        var messageSendCount = 0
        var keeperNotifyCalls = 0
        var autoSendCount = 0
    }

    static func contractScenario(contract: URL, caseID: String, scenario: String, phase: String) throws -> [String: Any] {
        let data = try Data(contentsOf: contract)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let item = root[caseID] as? [String: Any],
              let simulation = item["simulation"] as? [String: Any],
              let scenarios = simulation["scenarios"] as? [String: Any],
              let fixture = scenarios[scenario] as? [String: Any],
              let phases = fixture["phases"] as? [String], phases.contains(phase) else {
            throw ProbeError.invalidContract
        }
        return fixture
    }

    static func rescueURL(root: URL) -> URL { MainWindowController.lidRescueURL(stateDirectory: root) }

    static func makeEntry(delegate: AppDelegate, root: URL, caseID: String,
                          persistence: LidInterruptRescuePersistence,
                          model: String = "codex:gpt-6-luna") throws -> LidRescueEntry {
        let fixture = try AwakeClosedRescueProbeSupport.makeFixture(delegate: delegate, root: root,
            caseID: "\(caseID)-recovery", team: false, createPanes: true, model: model)
        defer {
            AwakeClosedRescueProbeSupport.cleanupTemporaryCodeLabGroup(id: fixture.temporaryCodeLabGroupID,
                root: root, store: delegate.store!)
        }
        guard let pane = fixture.targetPane else { throw ProbeError.fixtureUnavailable }
        delegate.store.status[fixture.target.id] = .idle
        let record = LidInterruption(id: fixture.target.id, title: fixture.target.title,
            engine: fixture.target.modelCategory, supportsTermination: true, details: [], queuedMessages: [],
            terminated: true, forceKilled: false, stillRunning: false, outboxReadFailed: false, foreground: true)
        guard persistence.upsert([record], late: true),
              let entry = try AwakeClosedRescueProbeSupport.entries(persistence).first(where: { $0.record.id == fixture.target.id }),
              let installedPane = delegate.workspace.panes[fixture.target.id] as? ChatPane,
              installedPane === pane else { throw ProbeError.persistenceWriteFailed }
        return entry
    }

    static func ensurePanes(delegate: AppDelegate, entries: [LidRescueEntry]) throws {
        for entry in entries {
            guard let conversation = delegate.store.conversation(entry.record.id) else { throw ProbeError.missingRecord }
            if delegate.workspace.panes[conversation.id] == nil,
               delegate.workspace.pane(for: conversation) as? ChatPane == nil {
                throw ProbeError.fixtureUnavailable
            }
        }
    }

    static func setImmutable(_ url: URL, _ enabled: Bool) throws {
        let flags = enabled ? UInt32(UF_IMMUTABLE) : 0
        let result = url.path.withCString { chflags($0, flags) }
        guard result == 0 else { throw ProbeError.faultInjectionFailed("chflags \(url.lastPathComponent): errno \(errno)") }
    }

    static func badFiles(root: URL) -> [URL] {
        badFiles(for: rescueURL(root: root), in: root)
    }

    static func badFiles(for rescueURL: URL, in root: URL) -> [URL] {
        let prefix = rescueURL.lastPathComponent + ".bad-"
        return ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func mode(_ url: URL?) -> String {
        guard let url,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let value = attributes[.posixPermissions] as? NSNumber else { return "" }
        return String(format: "%04o", value.intValue & 0o7777)
    }

    static func occurrences(of needle: String, in text: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return text.components(separatedBy: needle).count - 1
    }

    static func ledgerURL(stateRoot: URL) -> URL {
        stateRoot.deletingLastPathComponent().appendingPathComponent(".lid-rescue-recovery-ledger.json")
    }

    static func updateLedger(stateRoot: URL, messageSends: Int = 0,
                             notifyCalls: Int = 0, autoSends: Int = 0) throws -> Ledger {
        let url = ledgerURL(stateRoot: stateRoot)
        var value = Ledger()
        if FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url), let old = try? JSONDecoder().decode(Ledger.self, from: data) else {
                throw ProbeError.ledgerInvalid
            }
            value = old
        }
        value.messageSendCount += messageSends
        value.keeperNotifyCalls += notifyCalls
        value.autoSendCount += autoSends
        guard let data = try? JSONEncoder().encode(value) else { throw ProbeError.ledgerInvalid }
        do { try data.write(to: url, options: .atomic) }
        catch { throw ProbeError.ledgerInvalid }
        return value
    }

    static func c418LedgerURL(stateRoot: URL) -> URL {
        stateRoot.deletingLastPathComponent().appendingPathComponent(".lid-rescue-c418-ledger.json")
    }

    static func loadC418Ledger(stateRoot: URL) throws -> C418DeliveryLedger {
        let url = c418LedgerURL(stateRoot: stateRoot)
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(C418DeliveryLedger.self, from: data)
        } catch {
            throw ProbeError.ledgerInvalid
        }
    }

    static func saveC418Ledger(_ ledger: C418DeliveryLedger, stateRoot: URL) throws {
        do {
            let data = try JSONEncoder().encode(ledger)
            try data.write(to: c418LedgerURL(stateRoot: stateRoot), options: .atomic)
        } catch {
            throw ProbeError.ledgerInvalid
        }
    }

    static func envelope(_ caseID: String, _ scenario: String, _ phase: String,
                         observed: [String: Any]) -> [String: Any] {
        ["schemaVersion": 1, "caseId": caseID, "scenario": scenario, "phase": phase, "observed": observed]
    }

    static func failure(_ caseID: String, _ scenario: String, _ phase: String, _ error: Error) -> [String: Any] {
        envelope(caseID, scenario, phase, observed: ["probeError": error.localizedDescription])
    }
}

extension TestHarness {
    static func lidRescueRecoveryProbe(caseID: String, contract: URL, scenario: String,
                                       phase: String, stateRoot: URL) -> [String: Any]? {
        guard ["C415", "C416", "C417", "C418"].contains(caseID) else { return nil }
        do {
            guard Thread.isMainThread,
                  CommandLine.arguments.contains("--state-dir"),
                  let stateIndex = CommandLine.arguments.firstIndex(of: "--state-dir"), stateIndex + 1 < CommandLine.arguments.count,
                  let delegate = NSApp.delegate as? AppDelegate,
                  delegate.store != nil, delegate.main?.lidKeeper != nil else {
                throw LidRescueRecoveryProbeSupport.ProbeError.missingKeeper
            }
            let root = stateRoot.standardizedFileURL.resolvingSymlinksInPath()
            let appRoot = delegate.store.directory.standardizedFileURL.resolvingSymlinksInPath()
            let argumentRoot = URL(fileURLWithPath: CommandLine.arguments[stateIndex + 1], isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath()
            guard root == appRoot, root == argumentRoot else {
                throw LidRescueRecoveryProbeSupport.ProbeError.missingKeeper
            }
            let scenarioFixture = try LidRescueRecoveryProbeSupport.contractScenario(contract: contract, caseID: caseID,
                scenario: scenario, phase: phase)
            guard let keeper = delegate.main.lidKeeper else { throw LidRescueRecoveryProbeSupport.ProbeError.missingKeeper }
            let persistence = AwakeClosedRescueProbeSupport.persistence(root: root)
            if caseID == "C415" {
                return try runC415Recovery(delegate: delegate, keeper: keeper, root: root,
                    persistence: persistence, scenario: scenario, phase: phase)
            }
            if caseID == "C417" {
                return try runC417Recovery(delegate: delegate, keeper: keeper, root: root,
                    persistence: persistence, scenario: scenario, phase: phase, fixture: scenarioFixture)
            }
            if caseID == "C418" {
                return try runC418Recovery(delegate: delegate, keeper: keeper, root: root,
                    persistence: persistence, scenario: scenario, phase: phase, fixture: scenarioFixture)
            }
            return try runC416Recovery(delegate: delegate, keeper: keeper, root: root,
                persistence: persistence, scenario: scenario, phase: phase, fixture: scenarioFixture)
        } catch {
            return LidRescueRecoveryProbeSupport.failure(caseID, scenario, phase, error)
        }
    }

    private static func runC415Recovery(delegate: AppDelegate, keeper: LidKeeper, root: URL,
                                        persistence: LidInterruptRescuePersistence,
                                        scenario: String, phase: String) throws -> [String: Any] {
        let rescueURL = LidRescueRecoveryProbeSupport.rescueURL(root: root)
        let firstPhase = scenario == "deleteFailure" ? "attempt1" : "writeFailure1"
        if !FileManager.default.fileExists(atPath: rescueURL.path) {
            guard phase == firstPhase else { throw LidRescueRecoveryProbeSupport.ProbeError.missingSimulationFile }
            _ = try LidRescueRecoveryProbeSupport.makeEntry(delegate: delegate, root: root,
                caseID: "C415", persistence: persistence, model: "agy:gemini-4-hydrogen-high")
        }
        var entries = try AwakeClosedRescueProbeSupport.entries(persistence)
        try LidRescueRecoveryProbeSupport.ensurePanes(delegate: delegate, entries: entries)
        guard let entry = entries.first else { throw LidRescueRecoveryProbeSupport.ProbeError.missingRecord }

        let oldNotify = keeper.notify
        var notifyCalls = 0
        keeper.notify = { title, detail in notifyCalls += 1; oldNotify(title, detail) }
        defer { keeper.notify = oldNotify }

        var sendAttemptCount = 0
        let oldSendObserver = ChatPane.lidInterruptSendObserver
        defer { ChatPane.lidInterruptSendObserver = oldSendObserver }
        var injectionError: String?
        var immutableInjected = false
        defer {
            if immutableInjected, FileManager.default.fileExists(atPath: rescueURL.path) {
                _ = rescueURL.path.withCString { chflags($0, 0) }
            }
        }

        if scenario == "deleteFailure", phase.hasPrefix("attempt"), phase != "attempt4", phase != "attempt5" {
            let eligible = keeper.prepareStartupRescueDelivery(for: [entry])
            entries = try AwakeClosedRescueProbeSupport.entries(persistence)
            let attemptsBeforeSend = entries.first(where: { $0.record.id == entry.record.id })?.attempts ?? -1
            guard let targetConversation = delegate.store.conversation(entry.record.id) else {
                throw LidRescueRecoveryProbeSupport.ProbeError.missingRecord
            }
            let targetSessionID = targetConversation.claudeSession
            let beforeLog = (try? String(contentsOf: keeper.logURL, encoding: .utf8)) ?? ""
            ChatPane.lidInterruptSendObserver = { id, _, source, _ in
                guard id == targetSessionID, source == "闔蓋中斷" else { return }
                sendAttemptCount += 1
                if FileManager.default.fileExists(atPath: rescueURL.path) {
                    let result = rescueURL.path.withCString { chflags($0, UInt32(UF_IMMUTABLE)) }
                    if result == 0 { immutableInjected = true }
                    else { injectionError = "chflags 救援檔失敗：errno \(errno)" }
                } else {
                    injectionError = "送達前 rescue 檔已不存在"
                }
            }
            if eligible {
                guard let latest = entries.first(where: { $0.record.id == entry.record.id }) else {
                    throw LidRescueRecoveryProbeSupport.ProbeError.missingRecord
                }
                delegate.main.sendLidInterruptNotices([latest.record], late: true)
            }
            if immutableInjected {
                try LidRescueRecoveryProbeSupport.setImmutable(rescueURL, false)
                immutableInjected = false
            }
            if let injectionError { throw LidRescueRecoveryProbeSupport.ProbeError.faultInjectionFailed(injectionError) }
            let afterLog = (try? String(contentsOf: keeper.logURL, encoding: .utf8)) ?? ""
            let deliveryMarker = "闔蓋中斷通知已送達，但移除救援檔項目失敗"
            let deliveryMarkerCount = LidRescueRecoveryProbeSupport.occurrences(of: deliveryMarker, in: afterLog)
                - LidRescueRecoveryProbeSupport.occurrences(of: deliveryMarker, in: beforeLog)
            let successfulSendCount = deliveryMarkerCount > 0 ? sendAttemptCount : 0
            let ledger = try LidRescueRecoveryProbeSupport.updateLedger(stateRoot: root,
                messageSends: successfulSendCount, notifyCalls: notifyCalls)
            let deleted = !FileManager.default.fileExists(atPath: rescueURL.path)
            return LidRescueRecoveryProbeSupport.envelope("C415", scenario, phase, observed: [
                "attemptCountPersistedBeforeSend": attemptsBeforeSend,
                "messageSendCountThisLaunch": successfulSendCount,
                "rescueDeleteSucceeded": deleted,
                "keeperNotifyCallsThisLaunch": notifyCalls,
                "cumulative": ["messageSendCount": ledger.messageSendCount,
                               "keeperNotifyCalls": ledger.keeperNotifyCalls,
                               "rescueFileExists": FileManager.default.fileExists(atPath: rescueURL.path)]
            ])
        }

        if scenario == "deleteFailure" {
            _ = keeper.pendingRescueStatus()
            keeper.flushRescueNotifications()
            let attempts = try AwakeClosedRescueProbeSupport.entries(persistence)
                .first(where: { $0.record.id == entry.record.id })?.attempts ?? -1
            let ledger = try LidRescueRecoveryProbeSupport.updateLedger(stateRoot: root, notifyCalls: notifyCalls)
            var observed: [String: Any] = [
                "attemptCountPersistedBeforeSend": attempts,
                "messageSendCountThisLaunch": 0,
                "keeperNotifyCallsThisLaunch": notifyCalls,
                "cumulativeKeeperNotifyCalls": ledger.keeperNotifyCalls
            ]
            if phase == "attempt5" {
                observed["cumulative"] = ["messageSendCount": ledger.messageSendCount,
                                          "keeperNotifyCalls": ledger.keeperNotifyCalls,
                                          "rescueFileExists": FileManager.default.fileExists(atPath: rescueURL.path)]
            }
            return LidRescueRecoveryProbeSupport.envelope("C415", scenario, phase, observed: observed)
        }

        var attemptWriteSucceeded = false
        if phase == "writeFailure1" {
            try LidRescueRecoveryProbeSupport.setImmutable(rescueURL, true)
            attemptWriteSucceeded = keeper.prepareStartupRescueDelivery(for: [entry])
            try LidRescueRecoveryProbeSupport.setImmutable(rescueURL, false)
            keeper.flushRescueNotifications()
        } else {
            attemptWriteSucceeded = keeper.prepareStartupRescueDelivery(for: [entry])
            keeper.flushRescueNotifications()
        }
        let ledger = try LidRescueRecoveryProbeSupport.updateLedger(stateRoot: root, notifyCalls: notifyCalls)
        var observed: [String: Any] = [
            "attemptCountWriteSucceeded": attemptWriteSucceeded,
            "messageSendCountThisLaunch": 0,
            "keeperNotifyCallsThisLaunch": notifyCalls
        ]
        if phase == "writeFailure2" {
            observed["cumulativeKeeperNotifyCalls"] = ledger.keeperNotifyCalls
            observed["cumulative"] = ["messageSendCount": ledger.messageSendCount,
                                      "keeperNotifyCalls": ledger.keeperNotifyCalls,
                                      "rescueFileExists": FileManager.default.fileExists(atPath: rescueURL.path)]
        }
        return LidRescueRecoveryProbeSupport.envelope("C415", scenario, phase, observed: observed)
    }

    private static func runC416Recovery(delegate: AppDelegate, keeper: LidKeeper, root: URL,
                                        persistence: LidInterruptRescuePersistence,
                                        scenario: String, phase: String,
                                        fixture: [String: Any]) throws -> [String: Any] {
        let isFailure = scenario == "quarantineFailure"
        let rescueURL: URL
        if isFailure {
            guard let originalFilename = fixture["originalFilename"] as? String, !originalFilename.isEmpty else {
                throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
            }
            // C416 的契約使用自己的來源檔名；以相同產品 LidKeeper 邏輯對該隔離檔執行損壞復原。
            rescueURL = root.appendingPathComponent(originalFilename)
        } else {
            rescueURL = LidRescueRecoveryProbeSupport.rescueURL(root: root)
        }
        guard fixture["rescueJSON"] as? String == "invalid-json",
              (fixture["quarantineSucceeds"] as? Bool) == !isFailure else {
            throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
        }
        let probeKeeper = LidKeeper(env: SimLidEnv(), logURL: keeper.logURL,
            markerURL: root.appendingPathComponent("c416-marker.json"), rescueURL: rescueURL)
        probeKeeper.canPresentNotify = { true }
        if phase == "scan1" {
            guard !FileManager.default.fileExists(atPath: rescueURL.path) else {
                throw LidRescueRecoveryProbeSupport.ProbeError.missingSimulationFile
            }
            try Data("not-json".utf8).write(to: rescueURL, options: .atomic)
        } else if !FileManager.default.fileExists(atPath: rescueURL.path), isFailure {
            throw LidRescueRecoveryProbeSupport.ProbeError.missingSimulationFile
        }

        var quarantineFailureMode: String?
        var restoreDirectoryMode: Int?
        var clearImmutableOnExit = false
        defer {
            if let permissions = restoreDirectoryMode {
                _ = chmod(root.path, mode_t(permissions))
            }
            if clearImmutableOnExit, FileManager.default.fileExists(atPath: rescueURL.path) {
                let _ = rescueURL.path.withCString { chflags($0, 0) }
            }
        }
        if isFailure {
            guard let originalFilename = fixture["originalFilename"] as? String,
                  rescueURL.lastPathComponent == originalFilename,
                  let repeatCount = fixture["repeatCorruptLoadCountPerLaunch"] as? Int,
                  repeatCount == 2,
                  let phaseActions = fixture["phaseActions"] as? [String: Any],
                  let phaseAction = phaseActions[phase] as? [String: Any],
                  let mode = phaseAction["quarantineFailureMode"] as? String else {
                throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
            }
            quarantineFailureMode = mode
            switch mode {
            case "move-failed":
                try LidRescueRecoveryProbeSupport.setImmutable(rescueURL, true)
            case "directory-unwritable":
                try LidRescueRecoveryProbeSupport.setImmutable(rescueURL, false)
                clearImmutableOnExit = true
                let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
                guard let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue else {
                    throw LidRescueRecoveryProbeSupport.ProbeError.faultInjectionFailed("無法讀取 state-dir 權限")
                }
                let restricted = permissions & ~0o222
                guard chmod(root.path, mode_t(restricted)) == 0 else {
                    throw LidRescueRecoveryProbeSupport.ProbeError.faultInjectionFailed("無法讓 state-dir 變成唯讀")
                }
                restoreDirectoryMode = permissions
                guard let actual = Int(LidRescueRecoveryProbeSupport.mode(root), radix: 8),
                      actual & 0o222 == 0 else {
                    throw LidRescueRecoveryProbeSupport.ProbeError.faultInjectionFailed("無法讓 state-dir 變成唯讀")
                }
            default:
                throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
            }
        }
        let oldNotify = probeKeeper.notify
        var notifyCalls = 0
        probeKeeper.notify = { title, detail in notifyCalls += 1; oldNotify(title, detail) }
        defer { probeKeeper.notify = oldNotify }

        var autoSendCount = 0
        let priorSendObserver = ChatPane.lidInterruptSendObserver
        ChatPane.lidInterruptSendObserver = { _, _, source, _ in
            if source == "闔蓋中斷" { autoSendCount += 1 }
        }
        defer { ChatPane.lidInterruptSendObserver = priorSendObserver }

        let quarantineFailureText = "闔蓋中斷救援檔損壞且隔離失敗"
        let logBefore: String
        if FileManager.default.fileExists(atPath: keeper.logURL.path) {
            logBefore = try String(contentsOf: keeper.logURL, encoding: .utf8)
        } else {
            logBefore = ""
        }
        let badFilesBefore = LidRescueRecoveryProbeSupport.badFiles(for: rescueURL, in: root)
        let loadCount = isFailure ? (fixture["repeatCorruptLoadCountPerLaunch"] as? Int ?? 0) : 1
        if loadCount <= 0 { throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract }
        for _ in 0..<loadCount {
            _ = probeKeeper.pendingRescueStatus()
            probeKeeper.flushRescueNotifications(closed: false)
        }

        let badFiles = LidRescueRecoveryProbeSupport.badFiles(for: rescueURL, in: root)
        let rescueExists = FileManager.default.fileExists(atPath: rescueURL.path)
        let quarantineSucceeded = !rescueExists && !badFiles.isEmpty
        let logText = try String(contentsOf: probeKeeper.logURL, encoding: .utf8)
        let quarantineAttemptCount = LidRescueRecoveryProbeSupport.occurrences(of: quarantineFailureText, in: logText)
            - LidRescueRecoveryProbeSupport.occurrences(of: quarantineFailureText, in: logBefore)
        guard quarantineAttemptCount >= 0 else {
            throw LidRescueRecoveryProbeSupport.ProbeError.faultInjectionFailed("救援隔離失敗日誌計數倒退")
        }
        var observed: [String: Any] = [
            "crashed": false,
            "autoSendCount": autoSendCount,
            "keeperNotifyCallsThisLaunch": notifyCalls
        ]
        if isFailure {
            guard let mode = quarantineFailureMode else {
                throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
            }
            observed["quarantineSucceeded"] = rescueExists == false && badFiles.count > badFilesBefore.count
            observed["quarantineFailureMode"] = mode
            observed["quarantineAttemptCountThisLaunch"] = quarantineAttemptCount
            observed["quarantineOriginalFilenames"] = Array(repeating: rescueURL.lastPathComponent, count: quarantineAttemptCount)
            observed["quarantineFailureLogged"] = quarantineAttemptCount > 0
            observed["rescueFileExists"] = rescueExists
        } else {
            observed["quarantineSucceeded"] = quarantineSucceeded
            observed["badFileExists"] = !badFiles.isEmpty
            observed["badFileMode"] = LidRescueRecoveryProbeSupport.mode(badFiles.first)
        }
        let successLedger: LidRescueRecoveryProbeSupport.Ledger?
        if !isFailure {
            successLedger = try LidRescueRecoveryProbeSupport.updateLedger(stateRoot: root,
                notifyCalls: notifyCalls, autoSends: autoSendCount)
        } else {
            successLedger = nil
        }
        if !isFailure, phase == "scan2", let ledger = successLedger {
            observed["badFileExists"] = !badFiles.isEmpty
            observed["rescueFileExists"] = rescueExists
            observed["cumulativeKeeperNotifyCalls"] = ledger.keeperNotifyCalls
            observed["cumulative"] = ["autoSendCount": ledger.autoSendCount,
                                      "keeperNotifyCalls": ledger.keeperNotifyCalls,
                                      "badFileMode": LidRescueRecoveryProbeSupport.mode(badFiles.first)]
        }
        if isFailure, phase == "scan2", FileManager.default.fileExists(atPath: rescueURL.path) {
            try LidRescueRecoveryProbeSupport.setImmutable(rescueURL, false)
            clearImmutableOnExit = false
        }
        if !isFailure, phase == "scan2" {
            guard let dedupeFixture = fixture["sameRecordReminderDedupe"] as? [String: Any] else {
                throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
            }
            let dedupePersistence = LidInterruptRescuePersistence(
                fileURL: root.appendingPathComponent("c416-repeat-reminder-rescue.json"))
            let dedupeResult = try runC416SameRecordReminderDedupe(delegate: delegate, keeper: probeKeeper,
                root: root, persistence: dedupePersistence, fixture: dedupeFixture)
            guard let dedupeObserved = dedupeResult["observed"] as? [String: Any] else {
                throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
            }
            observed["sameRecordReminderDedupe"] = dedupeObserved
        }
        return LidRescueRecoveryProbeSupport.envelope("C416", scenario, phase, observed: observed)
    }

    private static func runC416SameRecordReminderDedupe(delegate: AppDelegate, keeper: LidKeeper,
                                                        root: URL, persistence: LidInterruptRescuePersistence,
                                                        fixture: [String: Any]) throws -> [String: Any] {
        guard let phases = fixture["phases"] as? [String], phases == ["repeatReminder"],
              fixture["firstAttemptCountWriteSucceeds"] as? Bool == false,
              let attemptsAfterFirstReminder = fixture["advanceAttemptsAfterFirstReminder"] as? Int,
              attemptsAfterFirstReminder == LidKeeper.maxRescueStartupAttempts else {
            throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
        }
        let rescueURL = persistence.fileURL
        guard !FileManager.default.fileExists(atPath: rescueURL.path) else {
            throw LidRescueRecoveryProbeSupport.ProbeError.missingSimulationFile
        }
        let entry = try LidRescueRecoveryProbeSupport.makeEntry(delegate: delegate, root: root,
            caseID: "C416-sameRecordReminderDedupe", persistence: persistence)
        guard entry.attempts == 0, !entry.isReminded else {
            throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
        }

        let probeKeeper = LidKeeper(env: SimLidEnv(), logURL: keeper.logURL,
            markerURL: root.appendingPathComponent("c416-repeat-reminder.marker"), rescueURL: rescueURL)
        probeKeeper.canPresentNotify = { true }
        let oldNotify = probeKeeper.notify
        var notifyCalls = 0
        probeKeeper.notify = { title, detail in
            notifyCalls += 1
            oldNotify(title, detail)
        }
        defer { probeKeeper.notify = oldNotify }

        try LidRescueRecoveryProbeSupport.setImmutable(rescueURL, true)
        var rescueImmutable = true
        defer {
            if rescueImmutable, FileManager.default.fileExists(atPath: rescueURL.path) {
                _ = rescueURL.path.withCString { chflags($0, 0) }
            }
        }
        let firstAttemptWriteSucceeded = probeKeeper.prepareStartupRescueDelivery(for: [entry])
        guard !firstAttemptWriteSucceeded else {
            throw LidRescueRecoveryProbeSupport.ProbeError.faultInjectionFailed("唯讀 rescue 檔仍允許寫入嘗試次數")
        }
        probeKeeper.flushRescueNotifications(closed: false)
        let firstReminderCount = notifyCalls
        guard firstReminderCount == 1 else {
            throw LidRescueRecoveryProbeSupport.ProbeError.faultInjectionFailed("第一次寫入失敗提醒沒有恰好送出一次")
        }

        try LidRescueRecoveryProbeSupport.setImmutable(rescueURL, false)
        rescueImmutable = false
        let afterFirstReminder = try AwakeClosedRescueProbeSupport.entries(persistence)
        guard let savedAfterFirstReminder = afterFirstReminder.first(where: { $0.record.id == entry.record.id }),
              savedAfterFirstReminder.attempts == 0, !savedAfterFirstReminder.isReminded else {
            throw LidRescueRecoveryProbeSupport.ProbeError.faultInjectionFailed("第一次提醒後 persistent reminded 狀態未保持 false")
        }

        // 透過正式 persistence 推進同一記錄的嘗試次數，保持同程序記憶體提醒狀態不變。
        for _ in 0..<attemptsAfterFirstReminder {
            guard persistence.incrementAttempts(for: [entry.record.id]) else {
                throw LidRescueRecoveryProbeSupport.ProbeError.persistenceWriteFailed
            }
        }
        let beforeRepeat = try AwakeClosedRescueProbeSupport.entries(persistence)
        guard let exhausted = beforeRepeat.first(where: { $0.record.id == entry.record.id }),
              exhausted.attempts == attemptsAfterFirstReminder, !exhausted.isReminded else {
            throw LidRescueRecoveryProbeSupport.ProbeError.faultInjectionFailed("第二次提醒前救援記錄未達 exhausted fixture")
        }

        let exhaustedMarker = "已嘗試送達達上限"
        let logBeforeRepeat = try String(contentsOf: keeper.logURL, encoding: .utf8)
        _ = probeKeeper.pendingRescueStatus()
        let logAfterRepeatScan = try String(contentsOf: keeper.logURL, encoding: .utf8)
        let exhaustedPathLogCount = LidRescueRecoveryProbeSupport.occurrences(of: exhaustedMarker, in: logAfterRepeatScan)
            - LidRescueRecoveryProbeSupport.occurrences(of: exhaustedMarker, in: logBeforeRepeat)
        guard exhaustedPathLogCount >= 0 else {
            throw LidRescueRecoveryProbeSupport.ProbeError.faultInjectionFailed("第二次提醒路徑日誌計數倒退")
        }
        probeKeeper.flushRescueNotifications(closed: false)

        return LidRescueRecoveryProbeSupport.envelope("C416", "sameRecordReminderDedupe", "repeatReminder", observed: [
            "firstAttemptWriteSucceeded": firstAttemptWriteSucceeded,
            "firstReminderCount": firstReminderCount,
            "remindedPersistedAfterFirstReminder": savedAfterFirstReminder.isReminded,
            "attemptsBeforeRepeatPath": exhausted.attempts,
            "exhaustedPathLogCount": exhaustedPathLogCount,
            "secondPathAdditionalNotifyCalls": notifyCalls - firstReminderCount,
            "keeperNotifyCallsThisLaunch": notifyCalls
        ])
    }

    private static func runC417Recovery(delegate: AppDelegate, keeper: LidKeeper, root: URL,
                                        persistence: LidInterruptRescuePersistence,
                                        scenario: String, phase: String,
                                        fixture: [String: Any]) throws -> [String: Any] {
        switch scenario {
        case "newMessageReset":
            return try runC417NewMessageReset(delegate: delegate, keeper: keeper, root: root,
                persistence: persistence, phase: phase, fixture: fixture)
        case "inProcessReminderDedupe":
            guard phase == "notifyDedupe" else { throw LidRescueRecoveryProbeSupport.ProbeError.unexpectedPhase }
            return try runC417ReminderDedupe(delegate: delegate, keeper: keeper, root: root,
                persistence: persistence, fixture: fixture)
        case "emptyIDUpsertNoReset":
            guard phase == "emptyIDUpsert" else { throw LidRescueRecoveryProbeSupport.ProbeError.unexpectedPhase }
            return try runC417EmptyIDUpsert(delegate: delegate, keeper: keeper, root: root,
                persistence: persistence, fixture: fixture)
        case "sameSourceCorruptionDedupe":
            guard phase == "corruptTwice" else { throw LidRescueRecoveryProbeSupport.ProbeError.unexpectedPhase }
            return try runC417SameSourceCorruption(root: root, fixture: fixture)
        default:
            throw LidRescueRecoveryProbeSupport.ProbeError.unexpectedPhase
        }
    }

    private static func runC417NewMessageReset(delegate: AppDelegate, keeper: LidKeeper, root: URL,
                                                persistence: LidInterruptRescuePersistence,
                                                phase: String, fixture: [String: Any]) throws -> [String: Any] {
        guard let initial = fixture["initialRecord"] as? [String: Any],
              let logicalRecordID = initial["recordID"] as? String,
              let logicalChatID = initial["chatID"] as? String,
              let oldIDs = initial["queuedMessageIDs"] as? [String], oldIDs.count == 1,
              let oldAttempts = initial["attempts"] as? Int, oldAttempts == 3,
              let oldReminded = initial["reminded"] as? Bool, oldReminded,
              let cycleID = fixture["newCycleID"] as? String, !cycleID.isEmpty,
              let action = (fixture["phaseActions"] as? [String: Any])?[phase] as? [String: Any] else {
            throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
        }
        let actionMessageID: String?
        if phase == "duplicateUpsert" || phase == "newMessageUpsert" {
            guard action["operation"] as? String == "upsertQueuedMessage",
                  action["chatID"] as? String == logicalChatID,
                  action["cycleID"] as? String == cycleID,
                  let messageID = action["messageID"] as? String else {
                throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
            }
            actionMessageID = messageID
        } else {
            actionMessageID = nil
        }
        if phase == "duplicateUpsert" {
            guard actionMessageID == oldIDs[0] else { throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract }
        }
        if phase == "newMessageUpsert" {
            guard let actionMessageID, !actionMessageID.isEmpty, !oldIDs.contains(actionMessageID) else {
                throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
            }
        }
        let rescueURL = LidRescueRecoveryProbeSupport.rescueURL(root: root)
        if !FileManager.default.fileExists(atPath: rescueURL.path) {
            guard phase == "duplicateUpsert" else { throw LidRescueRecoveryProbeSupport.ProbeError.missingSimulationFile }
            let created = try LidRescueRecoveryProbeSupport.makeEntry(delegate: delegate, root: root,
                caseID: "C417-newMessageReset", persistence: persistence)
            var seed = created.record
            seed.queuedMessages = oldIDs.map { LidQueuedMessage(id: $0, text: "fixture \($0)") }
            guard persistence.upsert([seed], late: true) else { throw LidRescueRecoveryProbeSupport.ProbeError.persistenceWriteFailed }
            for _ in 0..<oldAttempts {
                guard persistence.incrementAttempts(for: [seed.id]) else {
                    throw LidRescueRecoveryProbeSupport.ProbeError.persistenceWriteFailed
                }
            }
            guard persistence.markReminded(for: [seed.id]) else {
                throw LidRescueRecoveryProbeSupport.ProbeError.persistenceWriteFailed
            }
        }
        var entries = try AwakeClosedRescueProbeSupport.entries(persistence)
        try LidRescueRecoveryProbeSupport.ensurePanes(delegate: delegate, entries: entries)
        guard let oldEntry = entries.first, entries.filter({ $0.record.id == oldEntry.record.id }).count == 1 else {
            throw LidRescueRecoveryProbeSupport.ProbeError.missingRecord
        }

        if phase == "duplicateUpsert" || phase == "newMessageUpsert" {
            guard let conversation = delegate.store.conversation(oldEntry.record.id) else {
                throw LidRescueRecoveryProbeSupport.ProbeError.missingRecord
            }
            let oldNotify = keeper.notify
            var notifyCalls = 0
            keeper.notify = { title, detail in notifyCalls += 1; oldNotify(title, detail) }
            let oldObserver = ChatPane.lidInterruptSendObserver
            var sendCalls = 0
            ChatPane.lidInterruptSendObserver = { id, _, source, _ in
                if id == conversation.claudeSession && source == "闔蓋中斷" { sendCalls += 1 }
            }
            defer { keeper.notify = oldNotify; ChatPane.lidInterruptSendObserver = oldObserver }
            var incoming = oldEntry.record
            let beforeIDs = Set(incoming.queuedMessages.map { $0.id.lowercased() }.filter { !$0.isEmpty })
            guard let actionMessageID else { throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract }
            if !incoming.queuedMessages.contains(where: { $0.id.lowercased() == actionMessageID.lowercased() }) {
                incoming.queuedMessages.append(LidQueuedMessage(id: actionMessageID, text: "fixture \(actionMessageID)"))
            }
            guard persistence.upsert([incoming], late: true) else {
                throw LidRescueRecoveryProbeSupport.ProbeError.persistenceWriteFailed
            }
            entries = try AwakeClosedRescueProbeSupport.entries(persistence)
            guard let after = entries.first(where: { $0.record.id == oldEntry.record.id }) else {
                throw LidRescueRecoveryProbeSupport.ProbeError.missingRecord
            }
            let afterIDs = Set(after.record.queuedMessages.map { $0.id.lowercased() }.filter { !$0.isEmpty })
            let countForChat = entries.filter { $0.record.id == oldEntry.record.id }.count
            let added = !afterIDs.subtracting(beforeIDs).isEmpty
            return LidRescueRecoveryProbeSupport.envelope("C417", "newMessageReset", phase, observed: [
                "recordID": logicalRecordID,
                "chatID": logicalChatID,
                "queuedMessageIDs": after.record.queuedMessages.map(\.id),
                "attempts": after.attempts,
                "reminded": after.isReminded,
                "recordCountForChat": countForChat,
                "newNonEmptyMessageIDAdded": added,
                "messageSendCountThisLaunch": sendCalls,
                "keeperNotifyCallsThisLaunch": notifyCalls
            ])
        }

        guard ["retry1", "retry2", "retry3", "retry4", "retry5"].contains(phase) else {
            throw LidRescueRecoveryProbeSupport.ProbeError.unexpectedPhase
        }
        if phase.hasPrefix("retry"),
           (action["operation"] as? String != "recoveryLaunch"
            || action["messageSendSucceeds"] as? Bool != false
            || action["rescueDeleteSucceeds"] as? Bool != false) {
            throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
        }
        var notifyCalls = 0
        let oldNotify = keeper.notify
        keeper.notify = { title, detail in notifyCalls += 1; oldNotify(title, detail) }
        defer { keeper.notify = oldNotify }
        var sendAttemptCount = 0
        var deliveryFailure = false
        if phase == "retry1" || phase == "retry2" || phase == "retry3" {
            let status = keeper.pendingRescueStatus()
            guard let pending = status.entries.first(where: { $0.record.id == oldEntry.record.id }),
                  keeper.prepareStartupRescueDelivery(for: [pending]) else {
                throw LidRescueRecoveryProbeSupport.ProbeError.persistenceWriteFailed
            }
            entries = try AwakeClosedRescueProbeSupport.entries(persistence)
            guard let afterIncrement = entries.first(where: { $0.record.id == oldEntry.record.id }),
                  let conversation = delegate.store.conversation(oldEntry.record.id),
                  let pane = delegate.workspace.panes[oldEntry.record.id] as? ChatPane else {
                throw LidRescueRecoveryProbeSupport.ProbeError.fixtureUnavailable
            }
            let outbox = AwakeClosedRescueProbeSupport.chatSession(root: root, conversation: conversation, pane: pane).outboxPersistence
                ?? OutboxPersistence(directory: root, conversationID: conversation.claudeSession)
            if !FileManager.default.fileExists(atPath: outbox.fileURL.path) {
                _ = try AwakeClosedRescueProbeSupport.seedOutbox(root: root, conversation: conversation,
                    text: "C417 isolated outbox fixture", image: false)
            }
            let beforeLog = (try? String(contentsOf: keeper.logURL, encoding: .utf8)) ?? ""
            let oldObserver = ChatPane.lidInterruptSendObserver
            ChatPane.lidInterruptSendObserver = { id, _, source, _ in
                if id == conversation.claudeSession && source == "闔蓋中斷" { sendAttemptCount += 1 }
            }
            defer { ChatPane.lidInterruptSendObserver = oldObserver }
            try LidRescueRecoveryProbeSupport.setImmutable(outbox.fileURL, true)
            var outboxImmutable = true
            defer {
                if outboxImmutable, FileManager.default.fileExists(atPath: outbox.fileURL.path) {
                    _ = outbox.fileURL.path.withCString { chflags($0, 0) }
                }
            }
            delegate.main.sendLidInterruptNotices([afterIncrement.record], late: true)
            try LidRescueRecoveryProbeSupport.setImmutable(outbox.fileURL, false)
            outboxImmutable = false
            let afterLog = (try? String(contentsOf: keeper.logURL, encoding: .utf8)) ?? ""
            deliveryFailure = LidRescueRecoveryProbeSupport.occurrences(of: "闔蓋中斷通知送出失敗", in: afterLog)
                > LidRescueRecoveryProbeSupport.occurrences(of: "闔蓋中斷通知送出失敗", in: beforeLog)
            guard sendAttemptCount == 1, deliveryFailure else {
                throw LidRescueRecoveryProbeSupport.ProbeError.faultInjectionFailed("闔蓋通知未經寄件匣故障路徑明確失敗")
            }
        } else {
            _ = keeper.pendingRescueStatus()
            keeper.flushRescueNotifications(closed: false)
        }
        entries = try AwakeClosedRescueProbeSupport.entries(persistence)
        guard let after = entries.first(where: { $0.record.id == oldEntry.record.id }) else {
            throw LidRescueRecoveryProbeSupport.ProbeError.missingRecord
        }
        let ledger = try LidRescueRecoveryProbeSupport.updateLedger(stateRoot: root,
            messageSends: sendAttemptCount, notifyCalls: notifyCalls)
        var observed: [String: Any] = [
            "attemptCountPersistedBeforeSend": after.attempts,
            "keeperNotifyCallsThisLaunch": notifyCalls,
            "remindedAfterLaunch": after.isReminded
        ]
        if phase == "retry1" || phase == "retry2" || phase == "retry3" {
            observed["newMessageSendCountThisLaunch"] = sendAttemptCount
            observed["newMessageSendSucceeded"] = !deliveryFailure
        } else {
            observed["newMessageSendCountThisLaunch"] = 0
        }
        if phase == "retry5" {
            observed["cumulativeKeeperNotifyCalls"] = ledger.keeperNotifyCalls
            observed["cumulative"] = [
                "newMessageSendCount": ledger.messageSendCount,
                "keeperNotifyCalls": ledger.keeperNotifyCalls,
                "attempts": after.attempts,
                "reminded": after.isReminded,
                "recordCountForChat": entries.filter { $0.record.id == oldEntry.record.id }.count
            ]
        }
        return LidRescueRecoveryProbeSupport.envelope("C417", "newMessageReset", phase, observed: observed)
    }

    private static func runC417EmptyIDUpsert(delegate: AppDelegate, keeper: LidKeeper, root: URL,
                                              persistence: LidInterruptRescuePersistence,
                                              fixture: [String: Any]) throws -> [String: Any] {
        guard let initial = fixture["initialRecord"] as? [String: Any],
              let logicalRecordID = initial["recordID"] as? String,
              let logicalChatID = initial["chatID"] as? String,
              let initialQueueIDs = initial["queuedMessageIDs"] as? [String], initialQueueIDs == [""],
              let phases = fixture["phases"] as? [String], phases.contains("emptyIDUpsert"),
              let action = (fixture["phaseActions"] as? [String: Any])?["emptyIDUpsert"] as? [String: Any],
              action["operation"] as? String == "upsertQueuedMessage",
              action["chatID"] as? String == logicalChatID,
              let messageID = action["messageID"] as? String, messageID.isEmpty,
              let attempts = initial["attempts"] as? Int, attempts == 3,
              (initial["reminded"] as? Bool) == true else {
            throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
        }
        if !FileManager.default.fileExists(atPath: LidRescueRecoveryProbeSupport.rescueURL(root: root).path) {
            let created = try LidRescueRecoveryProbeSupport.makeEntry(delegate: delegate, root: root,
                caseID: "C417-emptyIDUpsertNoReset", persistence: persistence)
            var seed = created.record
            seed.queuedMessages = initialQueueIDs.map { LidQueuedMessage(id: $0, text: "empty-id-old") }
            guard persistence.upsert([seed], late: true) else { throw LidRescueRecoveryProbeSupport.ProbeError.persistenceWriteFailed }
            for _ in 0..<attempts {
                guard persistence.incrementAttempts(for: [seed.id]) else { throw LidRescueRecoveryProbeSupport.ProbeError.persistenceWriteFailed }
            }
            guard persistence.markReminded(for: [seed.id]) else { throw LidRescueRecoveryProbeSupport.ProbeError.persistenceWriteFailed }
        }
        let before = try AwakeClosedRescueProbeSupport.entries(persistence)
        guard let oldEntry = before.first else { throw LidRescueRecoveryProbeSupport.ProbeError.missingRecord }
        guard let conversation = delegate.store.conversation(oldEntry.record.id) else {
            throw LidRescueRecoveryProbeSupport.ProbeError.missingRecord
        }
        let oldNotify = keeper.notify
        var notifyCalls = 0
        keeper.notify = { title, detail in notifyCalls += 1; oldNotify(title, detail) }
        let oldObserver = ChatPane.lidInterruptSendObserver
        var sendCalls = 0
        ChatPane.lidInterruptSendObserver = { id, _, source, _ in
            if id == conversation.claudeSession && source == "闔蓋中斷" { sendCalls += 1 }
        }
        defer { keeper.notify = oldNotify; ChatPane.lidInterruptSendObserver = oldObserver }
        let beforeNonEmptyIDs = Set(oldEntry.record.queuedMessages.map { $0.id.lowercased() }.filter { !$0.isEmpty })
        var incoming = oldEntry.record
        // 模擬一輪新事件只提供新增項目；Persistence 再與既有項目合併。
        incoming.queuedMessages = [LidQueuedMessage(id: "", text: "empty-id-new")]
        guard persistence.upsert([incoming], late: true) else { throw LidRescueRecoveryProbeSupport.ProbeError.persistenceWriteFailed }
        let after = try AwakeClosedRescueProbeSupport.entries(persistence)
        guard let updated = after.first(where: { $0.record.id == oldEntry.record.id }) else {
            throw LidRescueRecoveryProbeSupport.ProbeError.missingRecord
        }
        let afterNonEmptyIDs = Set(updated.record.queuedMessages.map { $0.id.lowercased() }.filter { !$0.isEmpty })
        return LidRescueRecoveryProbeSupport.envelope("C417", "emptyIDUpsertNoReset", "emptyIDUpsert", observed: [
            "recordID": logicalRecordID,
            "chatID": logicalChatID,
            "queuedMessageIDs": updated.record.queuedMessages.map(\.id),
            "attempts": updated.attempts,
            "reminded": updated.isReminded,
            "recordCountForChat": after.filter { $0.record.id == oldEntry.record.id }.count,
            "newNonEmptyMessageIDAdded": !afterNonEmptyIDs.subtracting(beforeNonEmptyIDs).isEmpty,
            "messageSendCountThisLaunch": sendCalls,
            "keeperNotifyCallsThisLaunch": notifyCalls
        ])
    }

    private static func runC417ReminderDedupe(delegate: AppDelegate, keeper: LidKeeper, root: URL,
                                               persistence: LidInterruptRescuePersistence,
                                               fixture: [String: Any]) throws -> [String: Any] {
        guard let events = fixture["events"] as? [[String: Any]] else {
            throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
        }
        let eventPairs = events.compactMap { event -> (String, String)? in
            guard let recordID = event["recordID"] as? String,
                  let reason = event["reason"] as? String else { return nil }
            return (recordID, reason)
        }
        guard eventPairs.count == events.count, eventPairs.count == 5,
              eventPairs[0].0 == eventPairs[1].0, eventPairs[0].1 == eventPairs[1].1,
              eventPairs[0].0 == "rescue-record-a", eventPairs[0].1 == "attempts-exhausted",
              eventPairs[2].0 == "rescue-record-b", eventPairs[2].1 == "attempts-exhausted",
              eventPairs[3].0 == eventPairs[4].0, eventPairs[3].0 == eventPairs[0].0,
              eventPairs[3].1 == eventPairs[4].1, eventPairs[3].1 == "attempt-counter-write-failed" else {
            throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
        }
        let a = try LidRescueRecoveryProbeSupport.makeEntry(delegate: delegate, root: root,
            caseID: "C417-reminder-a", persistence: persistence)
        let b = try LidRescueRecoveryProbeSupport.makeEntry(delegate: delegate, root: root,
            caseID: "C417-reminder-b", persistence: persistence)
        for _ in 0..<3 {
            guard persistence.incrementAttempts(for: [a.record.id]) else { throw LidRescueRecoveryProbeSupport.ProbeError.persistenceWriteFailed }
        }

        var notifyCalls = 0
        var notifiedPairs: [[String: String]] = []
        var notifyContext: (String, String)?
        let oldNotify = keeper.notify
        let oldCanNotify = keeper.canPresentNotify
        keeper.canPresentNotify = { true }
        keeper.notify = { title, detail in
            notifyCalls += 1
            if let pair = notifyContext { notifiedPairs.append(["recordID": pair.0, "reason": pair.1]) }
            oldNotify(title, detail)
        }
        defer { keeper.notify = oldNotify; keeper.canPresentNotify = oldCanNotify }

        _ = keeper.pendingRescueStatus()
        _ = keeper.pendingRescueStatus()
        notifyContext = eventPairs[0]
        keeper.flushRescueNotifications(closed: false)
        notifyContext = nil
        var currentEntries = try AwakeClosedRescueProbeSupport.entries(persistence)
        guard currentEntries.first(where: { $0.record.id == a.record.id })?.isReminded == true,
              currentEntries.first(where: { $0.record.id == b.record.id })?.isReminded == false else {
            throw LidRescueRecoveryProbeSupport.ProbeError.persistenceWriteFailed
        }

        for _ in 0..<3 {
            guard persistence.incrementAttempts(for: [b.record.id]) else { throw LidRescueRecoveryProbeSupport.ProbeError.persistenceWriteFailed }
        }
        _ = keeper.pendingRescueStatus()
        notifyContext = eventPairs[2]
        keeper.flushRescueNotifications(closed: false)
        notifyContext = nil
        currentEntries = try AwakeClosedRescueProbeSupport.entries(persistence)
        guard currentEntries.first(where: { $0.record.id == b.record.id })?.isReminded == true else {
            throw LidRescueRecoveryProbeSupport.ProbeError.persistenceWriteFailed
        }

        var aWithNewCycle = a.record
        aWithNewCycle.queuedMessages.append(LidQueuedMessage(id: "c417-new-cycle-message", text: "new lid cycle message"))
        keeper.recordInterruptDelivery(handledIDs: [], failedRecords: [aWithNewCycle], late: true)
        let afterReset = try AwakeClosedRescueProbeSupport.entries(persistence)
        guard let resetEntry = afterReset.first(where: { $0.record.id == a.record.id }),
              resetEntry.attempts == 0, !resetEntry.isReminded else {
            throw LidRescueRecoveryProbeSupport.ProbeError.persistenceWriteFailed
        }
        try LidRescueRecoveryProbeSupport.setImmutable(persistence.fileURL, true)
        var rescueImmutable = true
        defer {
            if rescueImmutable, FileManager.default.fileExists(atPath: persistence.fileURL.path) {
                _ = persistence.fileURL.path.withCString { chflags($0, 0) }
            }
        }
        _ = keeper.prepareStartupRescueDelivery(for: [resetEntry])
        _ = keeper.prepareStartupRescueDelivery(for: [resetEntry])
        try LidRescueRecoveryProbeSupport.setImmutable(persistence.fileURL, false)
        rescueImmutable = false
        notifyContext = eventPairs[3]
        keeper.flushRescueNotifications(closed: false)
        notifyContext = nil
        currentEntries = try AwakeClosedRescueProbeSupport.entries(persistence)
        guard currentEntries.first(where: { $0.record.id == a.record.id })?.isReminded == true else {
            throw LidRescueRecoveryProbeSupport.ProbeError.persistenceWriteFailed
        }
        let ledger = try LidRescueRecoveryProbeSupport.updateLedger(stateRoot: root, notifyCalls: notifyCalls)
        return LidRescueRecoveryProbeSupport.envelope("C417", "inProcessReminderDedupe", "notifyDedupe", observed: [
            "keeperNotifyCallsThisLaunch": notifyCalls,
            "duplicateReminderEventsSuppressed": max(0, eventPairs.count - notifyCalls),
            "notifiedRecordReasonPairs": notifiedPairs,
            "cumulativeKeeperNotifyCalls": ledger.keeperNotifyCalls
        ])
    }

    private static func runC417SameSourceCorruption(root: URL, fixture: [String: Any]) throws -> [String: Any] {
        guard let originalFilename = fixture["originalFilename"] as? String,
              let reason = fixture["reason"] as? String,
              let corruptions = fixture["corruptions"] as? [[String: Any]], corruptions.count == 2,
              corruptions[0]["operation"] as? String == "writeInvalidAndReadOriginal",
              corruptions[1]["operation"] as? String == "rewriteSameOriginalInvalidAndRead" else {
            throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
        }
        let rescueURL = root.appendingPathComponent(originalFilename)
        let isolatedKeeper = LidKeeper(env: SimLidEnv(),
            logURL: root.appendingPathComponent("c417-corruption.log"),
            markerURL: root.appendingPathComponent("c417-corruption.marker"), rescueURL: rescueURL)
        isolatedKeeper.canPresentNotify = { true }
        var notifyCalls = 0
        var notifiedPairs: [[String: String]] = []
        isolatedKeeper.notify = { title, detail in
            notifyCalls += 1
            notifiedPairs.append(["sourceFilename": rescueURL.lastPathComponent, "reason": reason])
            _ = (title, detail)
        }
        for attempt in 1...corruptions.count {
            guard !FileManager.default.fileExists(atPath: rescueURL.path) else {
                throw LidRescueRecoveryProbeSupport.ProbeError.missingSimulationFile
            }
            try Data("not-json-\(attempt)".utf8).write(to: rescueURL, options: .atomic)
            _ = isolatedKeeper.pendingRescueStatus()
            isolatedKeeper.flushRescueNotifications(closed: false)
        }
        let quarantined = LidRescueRecoveryProbeSupport.badFiles(for: rescueURL, in: root)
        let names = quarantined.map { $0.lastPathComponent.components(separatedBy: ".bad-").first ?? $0.lastPathComponent }
        let ledger = try LidRescueRecoveryProbeSupport.updateLedger(stateRoot: root, notifyCalls: notifyCalls)
        return LidRescueRecoveryProbeSupport.envelope("C417", "sameSourceCorruptionDedupe", "corruptTwice", observed: [
            "corruptOriginalFilename": rescueURL.lastPathComponent,
            "quarantineCountThisLaunch": quarantined.count,
            "quarantineOriginalFilenames": names,
            "quarantinePathsDistinct": Set(quarantined.map(\.path)).count == quarantined.count,
            "keeperNotifyCallsThisLaunch": notifyCalls,
            "duplicateReminderEventsSuppressed": max(0, corruptions.count - notifyCalls),
            "notifiedSourceReasonPairs": notifiedPairs,
            "cumulativeKeeperNotifyCalls": ledger.keeperNotifyCalls
        ])
    }

    private static func runC418Recovery(delegate: AppDelegate, keeper: LidKeeper, root: URL,
                                        persistence: LidInterruptRescuePersistence,
                                        scenario: String, phase: String,
                                        fixture: [String: Any]) throws -> [String: Any] {
        let initialPhase: String
        let initialOperation: String
        let restartOperation: String
        let isBounce: Bool
        switch scenario {
        case "bouncePreservesM1":
            initialPhase = "bounceAndResume"
            initialOperation = "simulateCloseOpenRecloseAndResume"
            restartOperation = "relaunchSameStateDirAndRecoverRescue"
            isBounce = true
        case "bouncePreservesM1AndM2":
            initialPhase = "bounceAndResume"
            initialOperation = "simulateCloseOpenRecloseAndResume"
            restartOperation = "relaunchSameStateDirAndRecoverRescue"
            isBounce = true
        case "normalSingleCycleCleanup":
            initialPhase = "singleCycleDelivery"
            initialOperation = "simulateSingleCloseOpenAndResume"
            restartOperation = "relaunchSameStateDirAndCheckNoResend"
            isBounce = false
        default:
            throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
        }
        guard let phases = fixture["phases"] as? [String],
              phases == [initialPhase, "restartAfterDelivery"],
              let phaseActions = fixture["phaseActions"] as? [String: Any],
              let initialAction = phaseActions[initialPhase] as? [String: Any],
              let action = phaseActions[phase] as? [String: Any],
              initialAction["operation"] as? String == initialOperation,
              action["selectedChatID"] as? String == "chat-C418",
              initialAction["selectedChatID"] as? String == "chat-C418",
              (isBounce
                ? (initialAction["messageSendSucceeds"] == nil
                    || (initialAction["messageSendSucceeds"] as? Bool) == true)
                : (initialAction["messageSendSucceeds"] as? Bool) == true),
              (phase == initialPhase || action["operation"] as? String == restartOperation) else {
            throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
        }
        if isBounce && initialAction["sameStateDirAcrossPhases"] as? Bool != true {
            throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
        }

        let initialMessages = try c418Messages(initialAction["initialOutbox"])
        let addedMessage: C418MessageFixture?
        if let rawAdded = initialAction["addAfterSecondClose"] {
            guard let dictionary = rawAdded as? [String: Any] else {
                throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
            }
            addedMessage = try c418Message(dictionary)
        } else {
            addedMessage = nil
        }
        guard Set((initialMessages + (addedMessage.map { [$0] } ?? [])).map(\.logicalID)).count
                == initialMessages.count + (addedMessage == nil ? 0 : 1),
              Set((initialMessages + (addedMessage.map { [$0] } ?? [])).map(\.text)).count
                == initialMessages.count + (addedMessage == nil ? 0 : 1) else {
            throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
        }
        let allMessages = initialMessages + (addedMessage.map { [$0] } ?? [])
        let targetFixture = try c418Fixture(delegate: delegate, root: root)
        let target = targetFixture.target
        let outbox = OutboxPersistence(directory: root, conversationID: target.claudeSession)
        let isRestart = phase == "restartAfterDelivery"
        var ledger: C418DeliveryLedger
        if isRestart {
            ledger = try LidRescueRecoveryProbeSupport.loadC418Ledger(stateRoot: root)
            guard ledger.targetConversationID == target.id.uuidString.lowercased() else {
                throw LidRescueRecoveryProbeSupport.ProbeError.fixtureUnavailable
            }
        } else {
            guard phase == initialPhase,
                  try outbox.read().isEmpty,
                  try AwakeClosedRescueProbeSupport.entries(persistence).allSatisfy({ $0.record.id != target.id }) else {
                throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
            }
            ledger = C418DeliveryLedger(targetConversationID: target.id.uuidString.lowercased())
            try LidRescueRecoveryProbeSupport.saveC418Ledger(ledger, stateRoot: root)
        }

        let previousEnabled = keeper.enabled
        let previousInterruptEnabled = keeper.interruptOnCloseEnabled
        keeper.enabled = { true }
        keeper.interruptOnCloseEnabled = { true }
        defer {
            keeper.enabled = previousEnabled
            keeper.interruptOnCloseEnabled = previousInterruptEnabled
        }

        let previousNoticeObserver = LidIndicatorNoticeProbe.observe
        LidIndicatorNoticeProbe.observe = nil
        defer { LidIndicatorNoticeProbe.observe = previousNoticeObserver }

        var sendEvents: [C418SendEvent] = []
        var pendingSendIndices: [UUID: [Int]] = [:]
        var successfulSendIndices = Set<Int>()
        var openDiagnostics: [[String: Any]] = []
        var resumeDispatchCount = 0
        var resumeCandidateSnapshots: [[String: Any]] = []
        let previousResumeDispatch = keeper.sendInterruptResume
        keeper.sendInterruptResume = { records in
            resumeDispatchCount += 1
            resumeCandidateSnapshots.append(contentsOf: c418DispatchSnapshots(
                records: records, delegate: delegate, root: root))
            previousResumeDispatch(records)
        }
        defer { keeper.sendInterruptResume = previousResumeDispatch }
        let previousSendObserver = ChatPane.lidInterruptSendObserver
        ChatPane.lidInterruptSendObserver = { sessionID, text, source, _ in
            guard let source else { return }
            let index = sendEvents.count
            sendEvents.append(C418SendEvent(sessionID: sessionID, text: text, source: source))
            pendingSendIndices[sessionID, default: []].append(index)
        }
        let didSendObserver = NotificationCenter.default.addObserver(
            forName: ChatPane.didSend, object: nil, queue: .main
        ) { notification in
            guard let sessionID = notification.object as? UUID,
                  var indices = pendingSendIndices[sessionID], !indices.isEmpty else { return }
            let index = indices.removeFirst()
            pendingSendIndices[sessionID] = indices
            successfulSendIndices.insert(index)
        }
        defer {
            NotificationCenter.default.removeObserver(didSendObserver)
            ChatPane.lidInterruptSendObserver = previousSendObserver
        }

        if isRestart {
            // 啟動補送通知最晚可等 LidWiring 的 5 秒期限；觀察器已在首次主迴圈前安裝。
            RunLoop.main.run(until: Date().addingTimeInterval(max(keeper.resumeDelay + 0.15, 5.5)))
            try c418RecordSends(events: sendEvents, successfulIndices: successfulSendIndices,
                                messages: allMessages, ledger: &ledger, stateRoot: root)
            let rescueEntries = try c418Entries(for: target, persistence: persistence)
            let outboxIDs = try c418OutboxIDs(root: root, conversation: target, messages: allMessages)
            let selectedChatID = c418SelectedChatID(store: delegate.store!, target: target)
            let observed: [String: Any] = [
                "selectedChatID": selectedChatID,
                "rescueEntryPresentForChat": !rescueEntries.isEmpty,
                "resumeCountThisLaunch": sendEvents.filter { $0.source == "闔蓋繼續" }.count,
                "noticeSendCountThisLaunch": sendEvents.filter { $0.source == "闔蓋中斷" }.count,
                "resumeDispatchCount": resumeDispatchCount,
                "resumeCandidateSnapshot": resumeCandidateSnapshots,
                "automatedSendAttempts": c418SendDiagnostics(events: sendEvents,
                    successfulIndices: successfulSendIndices, messages: allMessages, target: target),
                "sentResumeTexts": c418SentResumeTexts(events: sendEvents,
                    successfulIndices: successfulSendIndices, messages: allMessages,
                    target: target, store: delegate.store!),
                "outboxMessageIDs": outboxIDs,
                "rescueEntryCountForChat": rescueEntries.count,
                "cumulative": c418Cumulative(ledger: ledger, rescueEntryCount: rescueEntries.count)
            ]
            AwakeClosedRescueProbeSupport.cleanupTemporaryCodeLabGroupFromMarker(root: root, store: delegate.store!)
            return LidRescueRecoveryProbeSupport.envelope("C418", scenario, phase, observed: observed)
        }

        let initialOutboxIDs = initialMessages.map(\.logicalID).sorted()
        guard let sim = keeper.env as? SimLidEnv else {
            throw LidRescueRecoveryProbeSupport.ProbeError.fixtureUnavailable
        }
        let timeline = try c418Timeline(initialAction)
        let waitKey = isBounce ? "waitForContinuationAfterSecondOpen" : "waitForContinuationAfterOpen"
        guard initialAction[waitKey] as? Bool == true else {
            throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
        }
        if !isBounce && timeline.contains(where: { $0.name == "newWork" }) {
            throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
        }
        if isBounce && initialAction["newWorkDuringBounce"] as? Bool != true {
            throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
        }

        sim.closed = false
        sim.screenOff = false
        sim.suppressLidObservation = false
        keeper.tick()
        let start = Date()
        var closeCount = 0
        var firstOpenAt: TimeInterval?
        var secondCloseAt: TimeInterval?
        var firstClose: C418CloseSnapshot?
        var secondClose: C418CloseSnapshot?
        var newWorkInjected = false
        var newWorkWasActiveAtSecondClose = false
        var m2AddedAfterSecondClose = false
        var m2QueuedAfterSecondClose = false

        for event in timeline {
            let deadline = start.addingTimeInterval(event.atSeconds)
            if deadline > Date() { RunLoop.main.run(until: deadline) }
            switch event.name {
            case "close":
                if closeCount == 0 {
                    // 跟 C402 一樣，排隊訊息在 close 同步前寫入；若先寫再等時間線，App 會把 outbox 還原成輸入框草稿。
                    guard let pane = targetFixture.targetPane,
                          !pane.inputBar.hasPendingInput,
                          try outbox.read().isEmpty else {
                        throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
                    }
                    for message in initialMessages {
                        try c418Append(message, root: root, conversation: target)
                    }
                    guard try c418OutboxIDs(root: root, conversation: target, messages: allMessages) == initialOutboxIDs,
                          !pane.inputBar.hasPendingInput else {
                        throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
                    }
                    delegate.store.status[target.id] = .working
                } else {
                    guard isBounce, newWorkInjected,
                          delegate.store.status[target.id] == .working else {
                        throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
                    }
                    newWorkWasActiveAtSecondClose = true
                    secondCloseAt = event.atSeconds
                }
                _ = try AwakeClosedRescueProbeSupport.triggerClose(keeper: keeper, sim: sim)
                // 終止流程會同步回報 idle；此探針的 synthetic working 狀態同樣在 close 後復位。
                let statusAfterTerminateBeforeHookReset = delegate.store.status[target.id].map { String(describing: $0) }
                delegate.store.status[target.id] = nil
                let snapshot = try c418CloseSnapshot(root: root, conversation: target,
                    persistence: persistence, messages: allMessages, delegate: delegate, keeper: keeper,
                    statusAfterTerminateBeforeHookReset: statusAfterTerminateBeforeHookReset)
                closeCount += 1
                if closeCount == 1 {
                    firstClose = snapshot
                } else if closeCount == 2 {
                    secondClose = snapshot
                }
            case "open":
                if closeCount == 2, let addedMessage {
                    // M2 仍在第二次 close 之後加入，但要等開蓋事件的主迴圈等待結束，避免 outbox 被恢復成草稿。
                    guard let pane = targetFixture.targetPane, !pane.inputBar.hasPendingInput else {
                        throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
                    }
                    let beforeAdd = try c418OutboxIDs(root: root, conversation: target, messages: allMessages)
                    guard beforeAdd.isEmpty else {
                        throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
                    }
                    try c418Append(addedMessage, root: root, conversation: target)
                    let afterAdd = try c418OutboxIDs(root: root, conversation: target, messages: allMessages)
                    m2AddedAfterSecondClose = !beforeAdd.contains(addedMessage.logicalID)
                        && afterAdd.contains(addedMessage.logicalID)
                    m2QueuedAfterSecondClose = afterAdd.contains(addedMessage.logicalID)
                    guard m2AddedAfterSecondClose, m2QueuedAfterSecondClose,
                          !pane.inputBar.hasPendingInput else {
                        throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
                    }
                }
                let statusBeforeOpen = delegate.store.status[target.id]
                let paneBeforeOpen = delegate.workspace.panes[target.id] as? ChatPane
                var openDiagnostic: [String: Any] = [
                    "eventAtSeconds": event.atSeconds,
                    "storeStatusBeforeIdleReset": statusBeforeOpen.map { String(describing: $0) } as Any? ?? NSNull(),
                    "storeStatusWasWorkingBeforeIdleReset": statusBeforeOpen == .working,
                    "paneRegistered": paneBeforeOpen != nil,
                    "hasPendingDraftBeforeOpen": paneBeforeOpen?.inputBar.hasPendingInput as Any? ?? NSNull(),
                    "resumeDelaySeconds": keeper.resumeDelay,
                    "noticeProbeWasNil": LidIndicatorNoticeProbe.observe == nil
                ]
                // terminateForInterrupt 代表模型已停；緊貼開蓋 tick 再設 idle，避免非同步 status 回報留下 working。
                delegate.store.status[target.id] = nil
                sim.closed = false
                sim.screenOff = false
                sim.suppressLidObservation = false
                keeper.tick()
                openDiagnostic["storeStatusAtOpenTick"] = delegate.store.status[target.id].map { String(describing: $0) } as Any? ?? NSNull()
                openDiagnostic["awakeClosedAfterOpenTick"] = keeper.isAwakeClosed
                openDiagnostic["hasPendingInterruptAfterOpenTick"] = keeper.hasPendingInterruptNotice
                openDiagnostics.append(openDiagnostic)
                if firstOpenAt == nil, closeCount == 1 { firstOpenAt = event.atSeconds }
            case "newWork":
                guard isBounce, event.chatID == "chat-C418" else {
                    throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
                }
                delegate.store.status[target.id] = .working
                keeper.tick()
                newWorkInjected = delegate.store.status[target.id] == .working
            default:
                throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
            }
        }
        guard closeCount == (isBounce ? 2 : 1), let firstClose,
              (!isBounce || (secondClose != nil && firstOpenAt != nil && secondCloseAt != nil
                              && newWorkWasActiveAtSecondClose)) else {
            throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
        }
        guard let lastEvent = timeline.last else {
            throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
        }
        RunLoop.main.run(until: start.addingTimeInterval(lastEvent.atSeconds + keeper.resumeDelay + 0.15))

        let ledgerBefore = ledger
        try c418RecordSends(events: sendEvents, successfulIndices: successfulSendIndices,
                            messages: allMessages, ledger: &ledger, stateRoot: root)
        let afterRescueEntries = try c418Entries(for: target, persistence: persistence)
        let outboxAfterDelivery = try c418OutboxIDs(root: root, conversation: target, messages: allMessages)
        let selectedChatID = c418SelectedChatID(store: delegate.store!, target: target)
        let sentResumeTexts = c418SentResumeTexts(events: sendEvents,
            successfulIndices: successfulSendIndices, messages: allMessages,
            target: target, store: delegate.store!)
        let m1DeliveredThisLaunch = ledger.m1DeliveryCount - ledgerBefore.m1DeliveryCount
        let m2DeliveredThisLaunch = ledger.m2DeliveryCount - ledgerBefore.m2DeliveryCount

        var observed: [String: Any]
        if isBounce, let secondClose {
            let firstIDs = firstClose.rescueMessageIDs
            let secondIDs = secondClose.rescueMessageIDs
            var bounceObserved: [String: Any] = [
                "selectedChatID": selectedChatID,
                "sameChatIDAcrossBounce": firstClose.chatUUID != nil
                    && firstClose.chatUUID == secondClose.chatUUID,
                "newWorkDuringBounce": newWorkWasActiveAtSecondClose,
                "openToSecondCloseSeconds": secondCloseAt! - firstOpenAt!,
                "firstCloseOutboxMessageIDs": firstClose.outboxMessageIDs,
                "firstCloseRescueMessageIDs": firstIDs,
                "secondCloseOutboxMessageIDs": secondClose.outboxMessageIDs,
                "secondCloseRescueMessageIDs": secondIDs,
                "sentResumeTexts": sentResumeTexts,
                "resumeCountThisLaunch": sendEvents.filter { $0.source == "闔蓋繼續" }.count,
                "noticeSendCountThisLaunch": sendEvents.filter { $0.source == "闔蓋中斷" }.count,
                "resumeDispatchCount": resumeDispatchCount,
                "resumeCandidateSnapshot": resumeCandidateSnapshots,
                "automatedSendAttempts": c418SendDiagnostics(events: sendEvents,
                    successfulIndices: successfulSendIndices, messages: allMessages, target: target),
                "firstCloseResumeCandidateSnapshot": firstClose.resumeCandidateSnapshot,
                "secondCloseResumeCandidateSnapshot": secondClose.resumeCandidateSnapshot,
                "openDiagnostics": openDiagnostics,
                "m1DeliveryCount": m1DeliveredThisLaunch,
                "m2DeliveryCount": m2DeliveredThisLaunch,
                "rescueEntryPresentAfterDelivery": !afterRescueEntries.isEmpty,
                "outboxMessageIDsAfterDelivery": outboxAfterDelivery,
                "firstCloseRescueEntryCountForChat": firstClose.rescueEntryCount,
                "secondCloseRescueEntryCountForChat": secondClose.rescueEntryCount,
                "rescueEntryCountForChatAfterDelivery": afterRescueEntries.count,
                "m1RecoverableAtSecondClose": secondClose.outboxMessageIDs.contains("M1")
                    || secondIDs.contains("M1"),
                "initialOutboxMessageIDs": initialOutboxIDs,
                "firstCloseChatID": c418ChatAlias(firstClose.chatUUID, target: target),
                "secondCloseChatID": c418ChatAlias(secondClose.chatUUID, target: target)
            ]
            if addedMessage != nil {
                bounceObserved["m2AddedAfterSecondClose"] = m2AddedAfterSecondClose
                bounceObserved["m2QueuedAfterSecondClose"] = m2QueuedAfterSecondClose
            }
            observed = bounceObserved
        } else {
            observed = [
                "selectedChatID": selectedChatID,
                "resumeCountThisLaunch": sendEvents.filter { $0.source == "闔蓋繼續" }.count,
                "noticeSendCountThisLaunch": sendEvents.filter { $0.source == "闔蓋中斷" }.count,
                "resumeDispatchCount": resumeDispatchCount,
                "resumeCandidateSnapshot": resumeCandidateSnapshots,
                "automatedSendAttempts": c418SendDiagnostics(events: sendEvents,
                    successfulIndices: successfulSendIndices, messages: allMessages, target: target),
                "firstCloseResumeCandidateSnapshot": firstClose.resumeCandidateSnapshot,
                "openDiagnostics": openDiagnostics,
                "sentResumeTexts": sentResumeTexts,
                "m1DeliveryCount": m1DeliveredThisLaunch,
                "m2DeliveryCount": m2DeliveredThisLaunch,
                "rescueEntryPresentAfterDelivery": !afterRescueEntries.isEmpty,
                "outboxMessageIDsAfterDelivery": outboxAfterDelivery,
                "rescueEntryCountForChatAfterDelivery": afterRescueEntries.count,
                "initialOutboxMessageIDs": initialOutboxIDs
            ]
        }
        return LidRescueRecoveryProbeSupport.envelope("C418", scenario, phase, observed: observed)
    }

    private static func c418Fixture(delegate: AppDelegate, root: URL) throws -> AwakeClosedRescueFixture {
        guard CommandLine.arguments.contains("--state-dir"), AgyBridge.canLaunchInCurrentInstance else {
            throw AwakeClosedRescueProbeSupport.ProbeError.noIsolatedApp
        }
        // C418 用 runner 提供的 --agy-bin；明確開啟只屬於這個 state-dir 的 agy 偏好，避免 ChatSession.start 因總開關關閉而拒送。
        Prefs.shared.agyEnabled = true
        let store = delegate.store!
        let rootPath = URL(fileURLWithPath: root.path, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
        let matches = store.conversations.filter { conversation in
            guard conversation.title == "C418 rescue chat",
                  let project = store.project(conversation.projectID) else { return false }
            return URL(fileURLWithPath: project.path, isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath().path == rootPath
        }
        guard matches.count <= 1 else { throw LidRescueRecoveryProbeSupport.ProbeError.fixtureUnavailable }
        var fixture: AwakeClosedRescueFixture
        if let target = matches.first {
            guard Store.isChat(target), !store.isArchived(target) else {
                throw LidRescueRecoveryProbeSupport.ProbeError.fixtureUnavailable
            }
            fixture = AwakeClosedRescueFixture(target: target, chief: target,
                targetPane: nil, chiefPane: nil, temporaryCodeLabGroupID: nil)
        } else {
            fixture = try AwakeClosedRescueProbeSupport.makeFixture(delegate: delegate, root: root,
                caseID: "C418", team: false, createPanes: true, model: "agy:gemini-4-hydrogen-high")
        }
        guard let codeLab = store.groups.first(where: {
            $0.name == Store.codeLabGroupName && $0.parentID == nil
        }), let conversationIndex = store.conversations.firstIndex(where: { $0.id == fixture.target.id }) else {
            throw LidRescueRecoveryProbeSupport.ProbeError.fixtureUnavailable
        }
        var target = store.conversations[conversationIndex]
        target.groupID = codeLab.id
        target.model = "agy:gemini-4-hydrogen-high"
        store.conversations[conversationIndex] = target
        guard let (sessionIndex, _) = store.locate(fixture.target.id),
              store.sessions.indices.contains(sessionIndex) else {
            throw LidRescueRecoveryProbeSupport.ProbeError.fixtureUnavailable
        }
        store.currentSession = store.sessions[sessionIndex].id
        store.selectedProject = target.projectID
        store.selected = target.id
        guard store.saveNow() else { throw LidRescueRecoveryProbeSupport.ProbeError.persistenceWriteFailed }
        guard let pane = (fixture.targetPane ?? (delegate.workspace.pane(for: target) as? ChatPane)) else {
            throw LidRescueRecoveryProbeSupport.ProbeError.fixtureUnavailable
        }
        pane.applyModel(target.model)
        _ = AwakeClosedRescueProbeSupport.chatSession(root: root, conversation: target, pane: pane)
        fixture = AwakeClosedRescueFixture(target: target, chief: target,
            targetPane: pane, chiefPane: pane, temporaryCodeLabGroupID: fixture.temporaryCodeLabGroupID)
        return fixture
    }

    private static func c418Messages(_ raw: Any?) throws -> [C418MessageFixture] {
        guard let rows = raw as? [[String: Any]], !rows.isEmpty else {
            throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
        }
        let result = try rows.map(c418Message)
        guard Set(result.map(\.logicalID)).count == result.count,
              Set(result.map(\.text)).count == result.count else {
            throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
        }
        return result
    }

    private static func c418Message(_ row: [String: Any]) throws -> C418MessageFixture {
        guard let logicalID = row["messageID"] as? String, !logicalID.isEmpty,
              let text = row["text"] as? String, !text.isEmpty else {
            throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
        }
        let imageMarker: String?
        if let rawMarker = row["imageMarker"], !(rawMarker is NSNull) {
            guard let marker = rawMarker as? String, !marker.isEmpty else {
                throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
            }
            imageMarker = marker
        } else {
            imageMarker = nil
        }
        return C418MessageFixture(logicalID: logicalID, text: text, imageMarker: imageMarker)
    }

    private static func c418Timeline(_ action: [String: Any]) throws -> [C418TimelineEvent] {
        guard let rows = action["lidTimeline"] as? [[String: Any]], !rows.isEmpty else {
            throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
        }
        var result: [C418TimelineEvent] = []
        for row in rows {
            guard let number = row["atSeconds"] as? NSNumber,
                  number.doubleValue.isFinite, number.doubleValue >= 0,
                  let name = row["event"] as? String,
                  ["close", "open", "newWork"].contains(name) else {
                throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
            }
            if name == "newWork", row["chatID"] as? String == nil {
                throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
            }
            if let previous = result.last, number.doubleValue <= previous.atSeconds {
                throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
            }
            result.append(C418TimelineEvent(atSeconds: number.doubleValue, name: name,
                chatID: row["chatID"] as? String))
        }
        return result
    }

    private static func c418Append(_ message: C418MessageFixture, root: URL,
                                   conversation: Conversation) throws {
        var images: [(data: Data, mediaType: String)] = []
        if message.imageMarker != nil {
            guard let pixel = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/g9sAAAAASUVORK5CYII=") else {
                throw LidRescueRecoveryProbeSupport.ProbeError.invalidContract
            }
            images.append((data: pixel, mediaType: "image/png"))
        }
        try OutboxPersistence(directory: root, conversationID: conversation.claudeSession)
            .append(id: message.outboxID, text: message.text, wireText: message.text,
                    quotes: [], filePaths: [], images: images, transcriptURLs: [])
    }

    private static func c418LogicalIDs(_ ids: [String], messages: [C418MessageFixture]) -> [String] {
        ids.map { rawID in
            messages.first(where: { $0.outboxID == rawID.lowercased() })?.logicalID ?? rawID
        }.sorted()
    }

    private static func c418OutboxIDs(root: URL, conversation: Conversation,
                                       messages: [C418MessageFixture]) throws -> [String] {
        let persistence = OutboxPersistence(directory: root, conversationID: conversation.claudeSession)
        return c418LogicalIDs(try persistence.read().map(\.id), messages: messages)
    }

    private static func c418Entries(for conversation: Conversation,
                                    persistence: LidInterruptRescuePersistence) throws -> [LidRescueEntry] {
        try AwakeClosedRescueProbeSupport.entries(persistence).filter { $0.record.id == conversation.id }
    }

    private static func c418CloseSnapshot(root: URL, conversation: Conversation,
                                          persistence: LidInterruptRescuePersistence,
                                          messages: [C418MessageFixture], delegate: AppDelegate,
                                          keeper: LidKeeper,
                                          statusAfterTerminateBeforeHookReset: String?) throws -> C418CloseSnapshot {
        let entries = try c418Entries(for: conversation, persistence: persistence)
        let messageIDs = entries.flatMap { $0.record.queuedMessages.map { $0.id.lowercased() } }
        let store = delegate.store!
        let pane = delegate.workspace.panes[conversation.id] as? ChatPane
        let groupID = store.groupOf(conversation)
        let group = groupID.flatMap { store.group($0) }
        let dispatchSnapshot = AwakeClosedRescueProbeSupport.dispatchSnapshots(
            records: entries.map(\.record), store: store, workspace: delegate.workspace, root: root
        ).first ?? ["recordFound": false]
        var candidateSnapshot = dispatchSnapshot
        candidateSnapshot["recordFound"] = !entries.isEmpty
        candidateSnapshot["storeStatusAfterTerminateBeforeHookReset"] = statusAfterTerminateBeforeHookReset as Any? ?? NSNull()
        candidateSnapshot["storeStatusAtCandidateCheck"] = store.status[conversation.id].map { String(describing: $0) } as Any? ?? NSNull()
        candidateSnapshot["topLevelCodeLabGroup"] = group.map {
            $0.name == Store.codeLabGroupName && $0.parentID == nil
        } ?? false
        candidateSnapshot["groupID"] = groupID?.uuidString as Any? ?? NSNull()
        candidateSnapshot["groupName"] = group?.name as Any? ?? NSNull()
        candidateSnapshot["groupParentID"] = group?.parentID?.uuidString as Any? ?? NSNull()
        candidateSnapshot["conversationModelCategory"] = conversation.modelCategory
        candidateSnapshot["paneRegistered"] = pane != nil
        candidateSnapshot["paneHasPendingDraft"] = pane?.inputBar.hasPendingInput as Any? ?? NSNull()
        candidateSnapshot["paneModelCategory"] = pane?.session.modelCategory as Any? ?? NSNull()
        candidateSnapshot["paneAgyModel"] = pane?.session.agyModel as Any? ?? NSNull()
        candidateSnapshot["commanderID"] = store.commander(of: conversation.id)?.id.uuidString as Any? ?? NSNull()
        candidateSnapshot["commanderChiefID"] = store.commander(of: conversation.id)?.chief?.uuidString as Any? ?? NSNull()
        candidateSnapshot["noticeProbeWasNil"] = LidIndicatorNoticeProbe.observe == nil
        candidateSnapshot["agyEnabled"] = AgyBridge.enabled
        candidateSnapshot["agyLaunchAllowed"] = AgyBridge.canLaunchInCurrentInstance
        candidateSnapshot["resumeDelaySeconds"] = keeper.resumeDelay
        return C418CloseSnapshot(chatUUID: entries.first?.record.id,
            outboxMessageIDs: try c418OutboxIDs(root: root, conversation: conversation, messages: messages),
            rescueMessageIDs: c418LogicalIDs(messageIDs, messages: messages),
            rescueEntryCount: entries.count, resumeCandidateSnapshot: candidateSnapshot)
    }

    private static func c418SelectedChatID(store: Store, target: Conversation) -> Any {
        guard let selected = store.selected else { return NSNull() }
        if selected == target.id { return "chat-C418" }
        return store.conversation(selected)?.title ?? selected.uuidString.lowercased()
    }

    private static func c418DispatchSnapshots(records: [LidInterruption], delegate: AppDelegate,
                                               root: URL) -> [[String: Any]] {
        let store = delegate.store!
        let base = AwakeClosedRescueProbeSupport.dispatchSnapshots(
            records: records, store: store, workspace: delegate.workspace, root: root)
        return zip(records, base).map { pair in
            let record = pair.0
            var snapshot = pair.1
            let conversation = store.conversation(record.id)
            let pane = delegate.workspace.panes[record.id] as? ChatPane
            let groupID = conversation.flatMap { store.groupOf($0) }
            let group = groupID.flatMap { store.group($0) }
            snapshot["stillRunningAtDispatch"] = record.stillRunning
            snapshot["isInterruptedCandidateAtDispatch"] = record.supportsTermination
                && record.terminated && !record.stillRunning
                && conversation.map { !store.isArchived($0) } == true
                && store.status[record.id] != .working && record.foreground
            snapshot["groupID"] = groupID?.uuidString as Any? ?? NSNull()
            snapshot["groupName"] = group?.name as Any? ?? NSNull()
            snapshot["groupParentID"] = group?.parentID?.uuidString as Any? ?? NSNull()
            snapshot["topLevelCodeLabGroup"] = group.map {
                $0.name == Store.codeLabGroupName && $0.parentID == nil
            } ?? false
            snapshot["conversationModelCategory"] = conversation?.modelCategory as Any? ?? NSNull()
            snapshot["paneRegistered"] = pane != nil
            snapshot["paneHasPendingDraft"] = pane?.inputBar.hasPendingInput as Any? ?? NSNull()
            snapshot["paneModelCategory"] = pane?.session.modelCategory as Any? ?? NSNull()
            snapshot["paneAgyModel"] = pane?.session.agyModel as Any? ?? NSNull()
            snapshot["agyEnabled"] = AgyBridge.enabled
            snapshot["agyLaunchAllowed"] = AgyBridge.canLaunchInCurrentInstance
            snapshot["commanderID"] = store.commander(of: record.id)?.id.uuidString as Any? ?? NSNull()
            snapshot["commanderChiefID"] = store.commander(of: record.id)?.chief?.uuidString as Any? ?? NSNull()
            return snapshot
        }
    }

    private static func c418ChatAlias(_ id: UUID?, target: Conversation) -> Any {
        guard let id else { return NSNull() }
        return id == target.id ? "chat-C418" : id.uuidString.lowercased()
    }

    private static func c418SentResumeTexts(events: [C418SendEvent], successfulIndices: Set<Int>,
                                            messages: [C418MessageFixture], target: Conversation,
                                            store: Store) -> [[String: Any]] {
        events.enumerated().compactMap { index, event in
            guard event.source == "闔蓋繼續", successfulIndices.contains(index) else { return nil }
            let matched = messages.filter { event.text.contains($0.text) }
            var markers: [String: Any] = [:]
            for message in matched {
                if let marker = message.imageMarker {
                    markers[message.logicalID] = event.text.contains(marker) ? marker : ""
                } else {
                    markers[message.logicalID] = NSNull()
                }
            }
            let recipient: String
            if event.sessionID == target.claudeSession {
                recipient = "chat-C418"
            } else {
                recipient = store.conversations.first(where: { $0.claudeSession == event.sessionID })?.title
                    ?? event.sessionID.uuidString.lowercased()
            }
            return ["recipientChatID": recipient,
                    "messageIDs": matched.map(\.logicalID),
                    "texts": matched.map(\.text),
                    "imageMarkersByMessageID": markers]
        }
    }

    private static func c418MessageIDs(in text: String, messages: [C418MessageFixture]) -> [String] {
        messages.filter {
            text.contains($0.logicalID) || text.contains($0.outboxID) || text.contains($0.text)
        }.map(\.logicalID)
    }

    private static func c418SendDiagnostics(events: [C418SendEvent], successfulIndices: Set<Int>,
                                            messages: [C418MessageFixture], target: Conversation) -> [[String: Any]] {
        events.enumerated().map { index, event in
            let recipient = event.sessionID == target.claudeSession
                ? "chat-C418"
                : event.sessionID.uuidString.lowercased()
            return ["source": event.source,
                    "recipientChatID": recipient,
                    "text": event.text,
                    "messageIDs": c418MessageIDs(in: event.text, messages: messages),
                    "didSend": successfulIndices.contains(index)]
        }
    }

    private static func c418RecordSends(events: [C418SendEvent], successfulIndices: Set<Int>,
                                        messages: [C418MessageFixture], ledger: inout C418DeliveryLedger,
                                        stateRoot: URL) throws {
        ledger.resumeCount += events.filter { $0.source == "闔蓋繼續" }.count
        for (index, event) in events.enumerated()
            where successfulIndices.contains(index) {
            for messageID in c418MessageIDs(in: event.text, messages: messages) {
                if messageID == "M1" { ledger.m1DeliveryCount += 1 }
                if messageID == "M2" { ledger.m2DeliveryCount += 1 }
            }
        }
        try LidRescueRecoveryProbeSupport.saveC418Ledger(ledger, stateRoot: stateRoot)
    }

    private static func c418Cumulative(ledger: C418DeliveryLedger, rescueEntryCount: Int) -> [String: Any] {
        [
            "m1DeliveryCount": ledger.m1DeliveryCount,
            "m2DeliveryCount": ledger.m2DeliveryCount,
            "resumeCount": ledger.resumeCount,
            "rescueEntryCountForChat": rescueEntryCount
        ]
    }
}
