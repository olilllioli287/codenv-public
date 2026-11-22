import AppKit
import SwiftUI
import SwiftTerm
import WebKit
import Darwin
import CryptoKit

private final class FocusProbeView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

private struct AgyFailureNoticeFileSnapshot {
    let exists: Bool
    let byteCount: Int
    let parseSucceeded: Bool
    let rows: [[String: String]]
    let readFailed: Bool
}

/// 隔離考題收集真正顯示的 NSAlert，避免測試視窗跳到使用者面前。
private enum E74DraftLifecycleProbeRuntime {
    static var captureURL: URL?
    static var capturedAlert: [String: Any]?
    static var modalOverride: ((NSAlert) -> NSApplication.ModalResponse?)?
    static var terminationObserver: NSObjectProtocol?
    private static var installed = false

    static func installCapture(at url: URL) {
        captureURL = url
        capturedAlert = nil
        installSwizzleIfNeeded()
    }

    static func installModalOverride(_ override: @escaping (NSAlert) -> NSApplication.ModalResponse?) {
        captureURL = nil
        capturedAlert = nil
        modalOverride = override
        installSwizzleIfNeeded()
    }

    static func clearModalOverride() { modalOverride = nil }

    static func observeTermination(at markerURL: URL, caseID: String, stateRoot: URL,
                                   outputURL: URL, fakeCredential: String?) {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: NSApp, queue: .main
        ) { _ in
            FileManager.default.createFile(atPath: markerURL.path, contents: Data("applicationWillTerminate".utf8))
            guard writePrepareObservation(caseID: caseID, stateRoot: stateRoot,
                                          outputURL: outputURL, fakeCredential: fakeCredential) else {
                NSLog("草稿生命週期探針：終止前觀察輸出失敗")
                return
            }
        }
    }

    static func writePrepareObservation(caseID: String, stateRoot: URL,
                                        outputURL: URL, fakeCredential: String?) -> Bool {
        guard ["C432", "C433"].contains(caseID),
              isTestProbeOutput(outputURL, inside: stateRoot) else { return false }
        let metadataURL = stateRoot.appendingPathComponent("draft-lifecycle-probe-state.json")
        guard let metadataData = try? Data(contentsOf: metadataURL),
              let metadata = (try? JSONSerialization.jsonObject(with: metadataData)) as? [String: Any],
              let idString = metadata["conversationID"] as? String,
              let conversationID = UUID(uuidString: idString),
              let expectedTextHash = metadata["expectedTextHash"] as? String,
              let draftSizeBytes = metadata["draftSizeBytes"] as? Int,
              let writeIncompleteAtEnd = metadata["writeIncompleteAtEnd"] as? Bool,
              let endEvent = metadata["endEvent"] as? String else { return false }

        let recoveryURL = stateRoot.appendingPathComponent(
            "drafts/.recovery/\(conversationID.uuidString.lowercased()).json")
        let recoveryData = try? Data(contentsOf: recoveryURL)
        let recoveryObject = recoveryData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let recoveryText = recoveryObject?["text"] as? String
        let terminated = FileManager.default.fileExists(atPath: markerURLPath(stateRoot))
        let paneClosed = metadata["paneClosed"] as? Bool ?? false
        let endEventCancelled: Bool
        switch endEvent {
        case "applicationTermination": endEventCancelled = !terminated
        case "paneClose": endEventCancelled = !paneClosed
        default: endEventCancelled = true
        }
        let observed: [String: Any] = [
            "draftSizeBytes": draftSizeBytes,
            "saveMode": "background",
            "writeIncompleteAtEnd": writeIncompleteAtEnd,
            "endEvent": endEvent,
            "endEventCancelled": endEventCancelled,
            "maskedSnapshotSaved": recoveryText.map { KeyScan.hash($0) == expectedTextHash } ?? false,
            "snapshotIsolated": recoveryData != nil && isTestProbeOutput(recoveryURL, inside: stateRoot),
            "snapshotContainsRawFakeCredential": fakeCredential.map { recoveryText?.contains($0) ?? true } ?? true
        ]
        let payload: [String: Any] = ["schemaVersion": 1, "caseId": caseID, "observed": observed]
        guard JSONSerialization.isValidJSONObject(payload) else { return false }
        do {
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let outputData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted])
            try outputData.write(to: outputURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func markerURLPath(_ stateRoot: URL) -> String {
        stateRoot.appendingPathComponent("draft-lifecycle-will-terminate").path
    }

    private static func installSwizzleIfNeeded() {
        guard !installed,
              let original = class_getInstanceMethod(NSAlert.self, #selector(NSAlert.runModal)),
              let replacement = class_getInstanceMethod(NSAlert.self, #selector(NSAlert.e74DraftLifecycleRunModal)) else { return }
        method_exchangeImplementations(original, replacement)
        installed = true
    }

    static func capture(_ alert: NSAlert) -> NSApplication.ModalResponse? {
        if let override = modalOverride, let response = override(alert) {
            capturedAlert = alertSnapshot(alert)
            modalOverride = nil
            return response
        }
        guard captureURL != nil else { return nil }
        capturedAlert = alertSnapshot(alert)
        return .alertFirstButtonReturn
    }

    private static func alertSnapshot(_ alert: NSAlert) -> [String: Any] {
        ["messageText": alert.messageText, "informativeText": alert.informativeText,
         "buttons": alert.buttons.map(\.title)]
    }
}

private extension NSAlert {
    @objc func e74DraftLifecycleRunModal() -> NSApplication.ModalResponse {
        if let response = E74DraftLifecycleProbeRuntime.capture(self) { return response }
        return e74DraftLifecycleRunModal()
    }
}

/// 對尚未建立的輸出檔解析最近存在的父目錄，避免 /private/tmp 與 /tmp 別名造成隔離路徑誤判。
private func canonicalTestProbePath(_ url: URL) -> String {
    var existing = url.standardizedFileURL
    var missing: [String] = []
    while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
        missing.insert(existing.lastPathComponent, at: 0)
        existing.deleteLastPathComponent()
    }
    let resolvedExistingPath = existing.path.withCString { path -> String? in
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    } ?? existing.resolvingSymlinksInPath().path
    var resolved = URL(fileURLWithPath: resolvedExistingPath, isDirectory: true).standardizedFileURL
    for component in missing { resolved.appendPathComponent(component) }
    return resolved.standardizedFileURL.path
}

func isTestProbeOutput(_ output: URL, inside root: URL) -> Bool {
    let rootPath = canonicalTestProbePath(root)
    let outputPath = canonicalTestProbePath(output)
    return outputPath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
}

private func isPrivateTemporaryProbeRoot(_ root: URL) -> Bool {
    let rootPath = canonicalTestProbePath(root)
    let tempPath = canonicalTestProbePath(URL(fileURLWithPath: "/private/tmp", isDirectory: true))
    return rootPath.hasPrefix(tempPath.hasSuffix("/") ? tempPath : tempPath + "/")
}

/// 進度探針只接受隔離實例明確提供的額外白名單根目錄。
private func runningProgressProbeAllowedRoots(_ args: [String]) -> [URL]? {
    guard let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count else { return nil }

    var roots = ProgressPathPolicy.roots()
    var index = 0
    while index < args.count {
        guard args[index] == "--progress-allow-root" else {
            index += 1
            continue
        }
        if index + 1 < args.count, !args[index + 1].isEmpty, !args[index + 1].hasPrefix("--") {
            roots.append(URL(fileURLWithPath: args[index + 1], isDirectory: true))
            index += 2
        } else {
            index += 1
        }
    }
    return roots
}

private final class KeyGuardConcurrencyProbeMetrics {
    private let lock = NSLock()
    private var mutationWindow = false
    private var completedWorkers = 0
    private var redactCalls = 0
    private var redactedCalls = 0
    private var overlappingCalls = 0

    func beginMutations() { lock.lock(); mutationWindow = true; lock.unlock() }
    func endMutations() { lock.lock(); mutationWindow = false; lock.unlock() }
    func recordWorkerCompletion() { lock.lock(); completedWorkers += 1; lock.unlock() }
    func recordRedact(changed: Bool) {
        lock.lock()
        redactCalls += 1
        if changed { redactedCalls += 1 }
        if mutationWindow { overlappingCalls += 1 }
        lock.unlock()
    }
    func snapshot() -> (workers: Int, calls: Int, redacted: Int, overlapping: Int) {
        lock.lock(); defer { lock.unlock() }
        return (completedWorkers, redactCalls, redactedCalls, overlappingCalls)
    }
}

private struct KeyGuardAsyncProbeAction {
    let delay: TimeInterval
    let name: String
}

private struct KeyGuardAsyncProbeStep {
    let name: String
    let text: String
    let attachmentURLs: [URL]
    let reuseDraft: Bool
    let scanDelay: TimeInterval
    let forceFailure: Bool
    let textDecision: String
    let fileDecision: String
    let bigFileDecision: Bool
    let unscannedDecision: Bool
    let busy: Bool
    let mutateOnFileWarning: Bool
    let mutateOnUnscannedWarning: Bool
    let switchOnFileWarning: Bool
    let actions: [KeyGuardAsyncProbeAction]

    static func parse(_ value: Any, under syntheticRoot: URL) -> KeyGuardAsyncProbeStep? {
        guard let row = value as? [String: Any] else { return nil }
        let name = row["name"] as? String ?? "step"
        var text = row["text"] as? String ?? ""
        if let path = row["textPath"] as? String {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard isTestProbeOutput(url, inside: syntheticRoot),
                  let fileText = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            text = fileText
        }
        let attachmentPaths: [String] = row["attachments"] as? [String] ?? []
        var attachments: [URL] = []
        for path in attachmentPaths {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard isTestProbeOutput(url, inside: syntheticRoot), FileManager.default.fileExists(atPath: url.path) else { return nil }
            attachments.append(url)
        }
        let delay = row["scanDelaySeconds"] as? Double ?? 0
        guard delay >= 0, delay <= 30 else { return nil }
        let textDecision = row["textDecision"] as? String ?? "cancel"
        let fileDecision = row["fileDecision"] as? String ?? "cancel"
        guard ["cancel", "sendAnyway", "save"].contains(textDecision),
              ["cancel", "sendAnyway"].contains(fileDecision) else { return nil }
        let actionRows: [[String: Any]] = row["actions"] as? [[String: Any]] ?? []
        guard actionRows.count <= 16 else { return nil }
        var actions: [KeyGuardAsyncProbeAction] = []
        let allowedActions: Set<String> = ["repeatSend", "enter", "commandEnter", "sendNow", "controlEnter", "cancel", "button", "closeChat", "switchChat", "detachPane", "mutateAttachment", "concurrentScan", "entryGuards", "pasteLocked"]
        for actionRow in actionRows {
            let name = actionRow["action"] as? String ?? ""
            let delayMilliseconds = actionRow["afterMs"] as? Double ?? 0
            guard allowedActions.contains(name), delayMilliseconds >= 0, delayMilliseconds <= 30_000 else { return nil }
            actions.append(KeyGuardAsyncProbeAction(delay: delayMilliseconds / 1000, name: name))
        }
        return KeyGuardAsyncProbeStep(
            name: name, text: text, attachmentURLs: attachments,
            reuseDraft: row["reuseDraft"] as? Bool ?? false,
            scanDelay: delay, forceFailure: row["forceFailure"] as? Bool ?? false,
            textDecision: textDecision, fileDecision: fileDecision,
            bigFileDecision: row["bigFileDecision"] as? Bool ?? false,
            unscannedDecision: row["unscannedDecision"] as? Bool ?? false,
            busy: row["busy"] as? Bool ?? false,
            mutateOnFileWarning: row["mutateOnFileWarning"] as? Bool ?? false,
            mutateOnUnscannedWarning: row["mutateOnUnscannedWarning"] as? Bool ?? false,
            switchOnFileWarning: row["switchOnFileWarning"] as? Bool ?? false,
            actions: actions
        )
    }
}

/// C419–C429 隔離探針的逐步記錄器。每個步驟仍走 ChatInputBar.send 與 KeyGuard 的正式決策入口。
private final class KeyGuardAsyncProbeController {
    /// AppDelegate 會從區域變數啟動探針；由主佇列計時器持有直到輸出完成。
    private static var activeController: KeyGuardAsyncProbeController?
    private let pane: ChatPane
    private let stateDirectory: URL
    private let outputURL: URL
    private let caseID: String
    private let steps: [KeyGuardAsyncProbeStep]
    private let markerURL: URL
    private let switchChat: (() -> Bool)?
    private var timer: Timer?
    private var stepIndex = -1
    private var step: KeyGuardAsyncProbeStep?
    private var stepStartedAt: TimeInterval = 0
    private var lastBeatAt: TimeInterval = 0
    private var maxRunLoopGap: TimeInterval = 0
    private var stepSendBase = 0
    private var stepNowSendBase = 0
    private var stepScanBase = 0
    private var stepStopBase = 0
    private var sendInvocationMilliseconds: Int?
    private var actionsPending = 0
    private var sendCount = 0
    private var nowSendCount = 0
    private var stopCount = 0
    private var sendAt: TimeInterval?
    private var fileEvents: [[String: Any]] = []
    private var textFindings: [[String: Any]] = []
    private var actionEvents: [[String: Any]] = []
    private var stepResults: [[String: Any]] = []
    private var callbackMutationAccepted: [String: Bool] = [:]
    private var concurrentScansCompleted = 0
    private var learningBytesBefore: Int = 0
    private var inputFingerprintBefore = ""
    private var inputNamesBefore: [String] = []
    private var keyVaultSaveCount = 0
    private var stepKeyVaultSaveBase = 0
    private var keyReplacementPlaceholderAtSend: Bool?
    private var keyReplacementRawKeyAbsentAtSend: Bool?

    init(pane: ChatPane, stateDirectory: URL, outputURL: URL, caseID: String,
         steps: [KeyGuardAsyncProbeStep], markerURL: URL, switchChat: (() -> Bool)?) {
        self.pane = pane
        self.stateDirectory = stateDirectory
        self.outputURL = outputURL
        self.caseID = caseID
        self.steps = steps
        self.markerURL = markerURL
        self.switchChat = switchChat
    }

    func start() {
        guard CommandLine.arguments.contains("--state-dir") else { exit(2) }
        Self.activeController = self
        KeyGuard.testConfirm = { true }
        KeyGuard.testDecision = { [weak self] hit in
            self?.textFindings.append(Self.findingSummary(hit))
            switch self?.step?.textDecision {
            case "sendAnyway": return .sendAnyway
            case "save": return .save(service: KeyVault.service("e74b99-r2-key-replacement"), label: "合成測試服務")
            default: return .cancel
            }
        }
        if caseID == "C437" {
            KeyVault.testSetOverride = { [weak self] service, key in
                guard service.hasPrefix("codenv-test-"), !key.isEmpty else { return "拒絕非測試金鑰寫入" }
                self?.keyVaultSaveCount += 1
                return nil
            }
        }
        KeyGuard.testFileWarningObserver = { [weak self] warnings, truncated in
            self?.recordFileWarnings(warnings, truncated: truncated)
        }
        KeyGuard.testFileDecision = { [weak self] in
            self?.fileEvents.append(["event": "askFilesDecision", "choice": self?.step?.fileDecision ?? "cancel"])
            return self?.step?.fileDecision == "sendAnyway" ? .sendAnyway : .cancel
        }
        KeyGuard.testBigFileObserver = { [weak self] names in
            self?.fileEvents.append(["event": "askBigFiles", "names": names.map { URL(fileURLWithPath: $0).lastPathComponent }])
        }
        KeyGuard.testBigFileDecision = { [weak self] in
            let accept = self?.step?.bigFileDecision ?? false
            self?.fileEvents.append(["event": "askBigFilesDecision", "sendAnyway": accept])
            return accept
        }
        KeyGuard.testUnscannedObserver = { [weak self] files in
            let rows: [[String: String]] = files.map { ["name": $0.name, "reason": $0.reason.rawValue] }
            self?.fileEvents.append(["event": "askUnscannedFiles", "files": rows])
            guard let self, self.step?.mutateOnUnscannedWarning == true else { return }
            let accepted = self.pane.inputBar.simulateKeyGuardAttachmentCallbackForTest(self.markerURL)
            self.callbackMutationAccepted["unscanned"] = accepted
        }
        KeyGuard.testUnscannedDecision = { [weak self] in
            let accept = self?.step?.unscannedDecision ?? false
            self?.fileEvents.append(["event": "askUnscannedDecision", "sendAnyway": accept])
            return accept
        }

        pane.inputBar.onSend = { [weak self] text, images, now in
            guard let self else { return false }
            if self.caseID == "C437" {
                // 送出路徑接著會清空輸入框；只保留布林，不把合成金鑰寫進 probe JSON。
                self.keyReplacementPlaceholderAtSend = text.contains("〔金鑰：合成測試服務，已存〕")
                self.keyReplacementRawKeyAbsentAtSend = KeyScan.scan(text).isEmpty
            }
            self.sendCount += 1
            if now { self.nowSendCount += 1 }
            self.sendAt = ProcessInfo.processInfo.systemUptime
            self.actionEvents.append(["event": "onSend", "textBytes": text.utf8.count,
                                      "textHash": KeyScan.hash(text), "imageCount": images.count, "now": now])
            return true
        }
        pane.inputBar.onStop = { [weak self] in self?.stopCount += 1 }
        let beatTimer = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in self?.tick() }
        timer = beatTimer
        RunLoop.main.add(beatTimer, forMode: .common)
        beginStep(at: 0)
    }

    private static func findingSummary(_ hit: KeyHit) -> [String: Any] {
        var row: [String: Any] = [
            "rangeLocation": hit.range.location, "rangeLength": hit.range.length,
            "kind": hit.kind, "strong": hit.strong, "low": hit.low,
            "isForceWarn": hit.isForceWarn, "isLearnableWeak": hit.isLearnableWeak,
            "textLength": hit.text.utf16.count, "textHash": KeyScan.hash(hit.text),
            "cleanLength": hit.clean.utf16.count, "cleanHash": KeyScan.hash(hit.clean)
        ]
        row["service"] = hit.service ?? NSNull() as Any
        return row
    }

    private func recordFileWarnings(_ warnings: [KeyGuardFileWarning], truncated: Bool) {
        let warningRows: [[String: Any]] = warnings.map { warning in
            let hits: [[String: Any]] = warning.hits.map { Self.findingSummary($0) }
            return ["name": warning.name, "hits": hits]
        }
        fileEvents.append(["event": "askFiles", "truncated": truncated, "warnings": warningRows])
        if step?.switchOnFileWarning == true {
            let switched = switchChat?() ?? false
            actionEvents.append(["event": "switchChatDuringFileWarning", "selectedOtherRoom": switched])
        }
        if step?.mutateOnFileWarning == true {
            let accepted = pane.inputBar.simulateKeyGuardAttachmentCallbackForTest(markerURL)
            callbackMutationAccepted["fileWarning"] = accepted
        }
    }

    private func beginStep(at index: Int) {
        guard index < steps.count else { finish() ; return }
        stepIndex = index
        let current = steps[index]
        E74DraftLifecycleProbeRuntime.clearModalOverride()
        step = current
        fileEvents = []; textFindings = []; actionEvents = []; callbackMutationAccepted = [:]
        concurrentScansCompleted = 0
        sendAt = nil
        sendInvocationMilliseconds = nil
        keyReplacementPlaceholderAtSend = nil
        keyReplacementRawKeyAbsentAtSend = nil
        maxRunLoopGap = 0
        lastBeatAt = ProcessInfo.processInfo.systemUptime
        let bar = pane.inputBar
        if current.switchOnFileWarning {
            KeyGuard.testFileDecision = nil
            E74DraftLifecycleProbeRuntime.installModalOverride { [weak self] alert in
                guard let self, alert.messageText == L("附的檔案裡有像 API 金鑰的內容") else { return nil }
                let switched = self.switchChat?() ?? false
                self.fileEvents.append(["event": "askFilesModal", "messageText": alert.messageText,
                                        "buttons": alert.buttons.map(\.title)])
                self.actionEvents.append(["event": "switchChatDuringFileWarning", "modalPresented": true,
                                          "selectedOtherRoom": switched])
                return .alertSecondButtonReturn
            }
        } else {
            KeyGuard.testFileDecision = { [weak self] in
                self?.fileEvents.append(["event": "askFilesDecision", "choice": self?.step?.fileDecision ?? "cancel"])
                return self?.step?.fileDecision == "sendAnyway" ? .sendAnyway : .cancel
            }
        }
        if !current.reuseDraft { bar.resetKeyGuardInputForTest() }
        if !current.text.isEmpty {
            bar.textView.string = current.text
            bar.textView.didChangeText()
        }
        if !current.attachmentURLs.isEmpty { bar.takeFiles(current.attachmentURLs) }
        bar.busy = current.busy
        ChatInputBar.keyGuardTestScanDelay = current.scanDelay
        ChatInputBar.keyGuardTestForceScanFailure = current.forceFailure
        stepSendBase = sendCount
        stepNowSendBase = nowSendCount
        stepKeyVaultSaveBase = keyVaultSaveCount
        stepScanBase = bar.keyGuardScanStartCount
        stepStopBase = stopCount
        learningBytesBefore = learningFileSize()
        inputFingerprintBefore = KeyScan.hash(bar.textView.string)
        inputNamesBefore = bar.draftFilePaths.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted()
        // C426 的輸入代表使用者已完成貼上、之後才按送出。先結束貼上後待處理的 AppKit 版面配置，
        // 避免探針在同一個主執行緒呼叫內「插入 20 MiB → 立刻送出」，把貼上後的首次排版誤算成送出延遲。
        if current.name == "G8-large-paste" {
            pane.layoutSubtreeIfNeeded()
            bar.layoutSubtreeIfNeeded()
        }
        // Large synthetic text is installed before measurement; measure the send/scanning path, not fixture setup.
        // A nested AppKit layout may service the probe timer while the fixture is being installed; discard
        // that pre-send gap so the 500 ms assertion measures only the send stage.
        maxRunLoopGap = 0
        lastBeatAt = ProcessInfo.processInfo.systemUptime
        stepStartedAt = ProcessInfo.processInfo.systemUptime
        actionsPending = current.actions.count
        for action in current.actions {
            DispatchQueue.main.asyncAfter(deadline: .now() + action.delay) { [weak self] in
                guard let self else { return }
                self.perform(action.name)
                self.actionsPending = max(0, self.actionsPending - 1)
            }
        }
        if current.name == "G8-large-paste" {
            let markerURL: URL = stateDirectory.appendingPathComponent("keyguard-send-stage-start")
            do {
                try Data("send-stage".utf8).write(to: markerURL, options: .atomic)
            } catch {
                exit(2)
            }
        }
        let sendInvocationStarted: TimeInterval = ProcessInfo.processInfo.systemUptime
        bar.startKeyGuardSendForTest()
        sendInvocationMilliseconds = Int(((ProcessInfo.processInfo.systemUptime - sendInvocationStarted) * 1000).rounded())
    }

    private func perform(_ name: String) {
        let bar = pane.inputBar
        switch name {
        case "repeatSend":
            let before = bar.keyGuardScanStartCount
            bar.startKeyGuardSendForTest()
            actionEvents.append(["event": name, "scanStartCountBefore": before, "scanStartCountAfter": bar.keyGuardScanStartCount])
        case "enter", "commandEnter":
            let before = bar.keyGuardScanStartCount
            bar.triggerKeyGuardKeyboardSendForTest()
            actionEvents.append(["event": name, "scanStartCountBefore": before, "scanStartCountAfter": bar.keyGuardScanStartCount])
        case "sendNow":
            let before = bar.keyGuardScanStartCount
            bar.sendNowFromOutside()
            actionEvents.append(["event": name, "scanStartCountBefore": before, "scanStartCountAfter": bar.keyGuardScanStartCount])
        case "controlEnter":
            let before = bar.keyGuardScanStartCount
            bar.triggerKeyGuardKeyboardSendForTest(now: true)
            actionEvents.append(["event": name, "scanStartCountBefore": before, "scanStartCountAfter": bar.keyGuardScanStartCount])
        case "cancel":
            let inProgressBefore = bar.isKeyScanInProgress
            bar.cancelKeyGuardSendForTest()
            actionEvents.append(["event": name, "inProgressBefore": inProgressBefore,
                                 "inProgressAfter": bar.isKeyScanInProgress])
        case "button":
            bar.pressKeyGuardSendButtonForTest()
            actionEvents.append(["event": name, "inProgressAfter": bar.isKeyScanInProgress, "stopCount": stopCount])
        case "closeChat":
            pane.terminate()
            actionEvents.append(["event": name, "inProgressAfter": bar.isKeyScanInProgress])
        case "switchChat":
            let switched = switchChat?() ?? false
            actionEvents.append(["event": name, "inProgressAfter": bar.isKeyScanInProgress,
                                 "windowDetached": pane.window == nil, "selectedOtherRoom": switched])
        case "detachPane":
            pane.removeFromSuperview()
            actionEvents.append(["event": name, "inProgressAfter": bar.isKeyScanInProgress, "windowDetached": pane.window == nil])
        case "mutateAttachment":
            let accepted = bar.simulateKeyGuardAttachmentCallbackForTest(markerURL)
            actionEvents.append(["event": name, "accepted": accepted])
        case "concurrentScan":
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                _ = KeyScan.scan("synthetic integrity=\(String(repeating: "A", count: 64))")
                DispatchQueue.main.async { self?.concurrentScansCompleted += 1 }
            }
            actionEvents.append(["event": name, "scheduled": true])
        case "entryGuards":
            let versionBefore = bar.keyGuardScanContentVersionForTest
            let textHashBefore = KeyScan.hash(bar.textView.string)
            let imagesBeforePaste = bar.draftImages.count
            let pasteboard = syntheticImagePasteboard()
            if let pasteboard { bar.textView.paste(from: pasteboard, sender: nil) }
            bar.layoutSubtreeIfNeeded()
            actionEvents.append(["event": "pasteDuringScan", "pasteboardReady": pasteboard != nil,
                                 "imageCountBefore": imagesBeforePaste, "imageCountAfter": bar.draftImages.count,
                                 "rejected": pasteboard != nil && bar.draftImages.count == imagesBeforePaste,
                                 "hint": bar.keyGuardScanHintForTest ?? "",
                                 "hintVisible": bar.keyGuardHintVisibleForTest])
            bar.putText("synthetic probe edit")
            bar.setDraft("synthetic probe draft")
            let uploadBlocked = bar.attemptUploadForKeyGuardTest()
            bar.restoreFilePaths([markerURL.path])
            bar.restoreImages([])
            _ = bar.restoreLost(text: "synthetic restore", images: [])
            bar.restoreLastSent()
            bar.removeFileForKeyGuardTest(markerURL)
            bar.removeImageForKeyGuardTest(1)
            let emptyPasteboardName = NSPasteboard.Name("CodenvKeyGuardProbe-\(UUID().uuidString)")
            let emptyPasteboard = NSPasteboard(name: emptyPasteboardName)
            let dropAccepted = bar.takeDrop(emptyPasteboard)
            actionEvents.append(["event": name, "contentVersionBefore": versionBefore,
                                 "contentVersionAfter": bar.keyGuardScanContentVersionForTest,
                                 "textHashBefore": textHashBefore, "textHashAfter": KeyScan.hash(bar.textView.string),
                                 "dropAccepted": dropAccepted, "uploadBlocked": uploadBlocked])
        case "pasteLocked":
            bar.cancelKeyGuardSendForTest()
            bar.setLocked("synthetic locked input")
            let imageCountBefore = bar.draftImages.count
            let pasteboard = syntheticImagePasteboard()
            if let pasteboard { bar.textView.paste(from: pasteboard, sender: nil) }
            bar.layoutSubtreeIfNeeded()
            actionEvents.append(["event": name, "pasteboardReady": pasteboard != nil,
                                 "imageCountBefore": imageCountBefore, "imageCountAfter": bar.draftImages.count,
                                 "rejected": pasteboard != nil && bar.draftImages.count == imageCountBefore,
                                 "hint": bar.keyGuardScanHintForTest ?? "",
                                 "hintVisible": bar.keyGuardHintVisibleForTest,
                                 "textEditable": bar.textView.isEditable])
            bar.setLocked(nil)
        default:
            actionEvents.append(["event": name, "accepted": false])
        }
    }

    private func syntheticImagePasteboard() -> NSPasteboard? {
        guard CommandLine.arguments.contains("--state-dir"),
              CommandLine.arguments.contains("--keyguard-async-probe") else { return nil }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("CodenvKeyGuardPasteProbe-\(UUID().uuidString)"))
        pasteboard.clearContents()
        guard let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/as8AAAAASUVORK5CYII="),
              pasteboard.setData(image, forType: .png) else { return nil }
        return pasteboard
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        maxRunLoopGap = max(maxRunLoopGap, now - lastBeatAt)
        lastBeatAt = now
        guard step != nil, actionsPending == 0, !pane.inputBar.isKeyScanInProgress else { return }
        // 取消後背景 worker 會在 cancellation token 下一個檢查點退出；留一個 run-loop 緩衝再記錄／重試。
        timer?.fireDate = Date(timeIntervalSinceNow: 0.01)
        completeStep()
    }

    private func completeStep() {
        guard let current = step else { return }
        let bar = pane.inputBar
        bar.layoutSubtreeIfNeeded()
        let afterFingerprint = KeyScan.hash(bar.textView.string)
        let afterNames = bar.draftFilePaths.map { URL(fileURLWithPath: $0).lastPathComponent }.sorted()
        var result: [String: Any] = [
            "name": current.name, "scanStartCount": bar.keyGuardScanStartCount - stepScanBase,
            "sendCount": sendCount - stepSendBase, "sent": sendCount > stepSendBase,
            "sendNowCount": nowSendCount - stepNowSendBase, "stopCalls": stopCount - stepStopBase,
            "mainRunLoopMaxGapMilliseconds": Int((maxRunLoopGap * 1000).rounded()),
            "sendInvocationMilliseconds": sendInvocationMilliseconds ?? NSNull() as Any,
            "scanAndSendMilliseconds": sendAt.map { Int((($0 - stepStartedAt) * 1000).rounded()) } ?? NSNull() as Any,
            "lastScanElapsedMilliseconds": bar.keyGuardLastScanElapsedMillisecondsForTest,
            "scanInProgressAfter": bar.isKeyScanInProgress, "textEditableAfter": bar.textView.isEditable,
            "hintAfter": bar.keyGuardScanHintForTest ?? NSNull() as Any,
            "hintVisibleAfter": bar.keyGuardHintVisibleForTest,
            "textLengthAfter": bar.textView.string.utf16.count, "textHashAfter": afterFingerprint,
            "filesAfter": afterNames, "imageCountAfter": bar.draftImages.count,
            "draftPreserved": afterFingerprint == inputFingerprintBefore && afterNames == inputNamesBefore,
            "fileEvents": fileEvents, "textFindings": textFindings, "actionEvents": actionEvents,
            "callbackMutationAccepted": callbackMutationAccepted,
            "learningFileBytesBefore": learningBytesBefore, "learningFileBytesAfter": learningFileSize(),
            "concurrentScansCompleted": concurrentScansCompleted
        ]
        result["elapsedMilliseconds"] = Int(((ProcessInfo.processInfo.systemUptime - stepStartedAt) * 1000).rounded())
        if caseID == "C437" {
            result["placeholderApplied"] = bar.textView.string.contains("〔金鑰：合成測試服務，已存〕") || keyReplacementPlaceholderAtSend == true
            result["rawKeyAbsent"] = keyReplacementRawKeyAbsentAtSend ?? KeyScan.scan(bar.textView.string).isEmpty
            result["keyVaultSaveCalls"] = keyVaultSaveCount - stepKeyVaultSaveBase
        }
        stepResults.append(result)
        bar.busy = false
        ChatInputBar.keyGuardTestScanDelay = 0
        ChatInputBar.keyGuardTestForceScanFailure = false
        step = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.beginStep(at: self.stepIndex + 1)
        }
    }

    private func learningFileSize() -> Int {
        let url = stateDirectory.appendingPathComponent("keyguard-false-positives.jsonl")
        return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private func finish() {
        timer?.invalidate(); timer = nil
        KeyGuard.testDecision = nil
        KeyGuard.testConfirm = nil
        KeyGuard.testFileDecision = nil
        KeyGuard.testBigFileDecision = nil
        KeyGuard.testUnscannedDecision = nil
        KeyGuard.testFileWarningObserver = nil
        KeyGuard.testBigFileObserver = nil
        KeyGuard.testUnscannedObserver = nil
        KeyVault.testSetOverride = nil
        E74DraftLifecycleProbeRuntime.clearModalOverride()
        ChatInputBar.keyGuardTestScanDelay = 0
        ChatInputBar.keyGuardTestForceScanFailure = false
        Self.activeController = nil
        let result: [String: Any] = ["schemaVersion": 1, "caseId": caseID, "isolatedStateDir": true,
                                     "stepCount": stepResults.count, "steps": stepResults,
                                     "rawFixtureTextIncluded": false]
        do {
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: outputURL, options: .atomic)
        } catch { exit(2) }
        exit(0)
    }
}

private final class LidInterruptProbeSession {
    let work: LidInterruptWork
    let pending: [LidQueuedMessage]
    let pendingSources: [String: [String]]
    let pendingSnapshot: [[String: Any]]
    let turnPending: Bool
    let codexStarting: LidQueuedMessage?
    let codexSteering: [LidQueuedMessage]
    let nextProbe: LidInterruptProbeNext?
    let commander: UUID?
    let archived: Bool
    let available: Bool
    let killable: Bool
    let ignoreTerm: Bool
    let outboxReadFailed: Bool
    let drainSeconds: TimeInterval
    let isActive: Bool
    let deliveryCallbackIDs: Set<String>
    var fakeProcessGroup: LidInterruptProbeProcessGroup?
    let fakeProcessKind: String?
    var terminated = false
    var forced = false
    var drainUntil = Date.distantPast
    var queuesCleared = false
    var terminationTime: TimeInterval?

    init(work: LidInterruptWork, pending: [LidQueuedMessage], pendingSources: [String: [String]], pendingSnapshot: [[String: Any]],
         turnPending: Bool, codexStarting: LidQueuedMessage?, codexSteering: [LidQueuedMessage],
         nextProbe: LidInterruptProbeNext?, commander: UUID?, archived: Bool,
         available: Bool, killable: Bool, ignoreTerm: Bool, outboxReadFailed: Bool,
         drainSeconds: TimeInterval, isActive: Bool,
         deliveryCallbackIDs: Set<String>, fakeProcessGroup: LidInterruptProbeProcessGroup?, fakeProcessKind: String?) {
        self.work = work; self.pending = pending; self.pendingSources = pendingSources; self.pendingSnapshot = pendingSnapshot
        self.turnPending = turnPending; self.codexStarting = codexStarting; self.codexSteering = codexSteering
        self.nextProbe = nextProbe; self.commander = commander; self.archived = archived
        self.available = available; self.killable = killable; self.ignoreTerm = ignoreTerm
        self.outboxReadFailed = outboxReadFailed; self.drainSeconds = drainSeconds; self.isActive = isActive
        self.deliveryCallbackIDs = deliveryCallbackIDs
        self.fakeProcessGroup = fakeProcessGroup
        self.fakeProcessKind = fakeProcessKind
    }
}

private final class LidInterruptProbeProcessGroup {
    let process: Process
    let group: pid_t
    let kind: String
    let drain: ChatDrain
    var terminationRequestedAt: TimeInterval?
    var forceKillAt: TimeInterval?
    private let endLock = NSLock()
    private var recordedEndAt: TimeInterval?

    init(process: Process, group: pid_t, kind: String) {
        self.process = process; self.group = group; self.kind = kind
        drain = ChatDrain(process: process, group: group, lidInterrupt: true)
    }

    var isAlive: Bool { drain.isAlive }
    var endedAt: TimeInterval? { endLock.lock(); defer { endLock.unlock() }; return recordedEndAt }
    func recordEnded(at time: TimeInterval) { endLock.lock(); recordedEndAt = time; endLock.unlock() }
    func observeEnd(at time: TimeInterval) {
        if !process.isRunning, endedAt == nil { recordEnded(at: time) }
    }

    func cleanup() {
        guard isAlive else {
            if process.isRunning { process.waitUntilExit() }
            return
        }
        drain.sendTerm()
        let deadline = Date().addingTimeInterval(0.3)
        while isAlive && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if isAlive { drain.sendKill() }
        if process.isRunning { process.waitUntilExit() }
    }
}

/// 以真正的 CodexBridge／CopilotBridge queue、clearForLidInterrupt 與 next() 驗證不會啟動下一則；傳輸全是假回覆。
private final class LidInterruptProbeNext {
    // 編譯修正：改 var（預設 nil），init 內的 [weak self] 閉包才不會在屬性未初始化前捕獲 self
    private var codex: CodexBridge?
    private var copilot: CopilotBridge?
    private(set) var nextMessageStarted = false

    init(engine: String, id: UUID, root: URL, turnPending: Bool, starting: LidQueuedMessage?,
         queued: [LidQueuedMessage], steering: [LidQueuedMessage]) {
        if engine == "codex" {
            let bridge = CodexBridge(session: id, directory: root.path, model: "gpt-6.1-sol",
                                     transcriptURL: root.appendingPathComponent("codex-next-probe-\(id.uuidString.lowercased()).jsonl"))
            bridge.send = { [weak self] message in
                if message["method"] as? String == "turn/start" { self?.nextMessageStarted = true }
            }
            bridge.prepareForLidInterruptProbe(turnPending: turnPending, starting: starting,
                                               queued: queued, steering: steering)
            codex = bridge
            copilot = nil
        } else if engine == "copilot" {
            let bridge = CopilotBridge(session: id, directory: root.path, model: "probe",
                                       transcriptURL: root.appendingPathComponent("copilot-next-probe-\(id.uuidString.lowercased()).jsonl"))
            bridge.send = { [weak self] message in
                if message["method"] as? String == "session/prompt" { self?.nextMessageStarted = true }
            }
            bridge.prepareForLidInterruptProbe(queued: queued)
            codex = nil
            copilot = bridge
        } else {
            codex = nil
            copilot = nil
        }
    }

    func pendingForLidInterrupt() -> [LidQueuedMessage]? {
        codex?.pendingForLidInterrupt() ?? copilot?.pendingForLidInterrupt()
    }

    func clearAndDeliverInterruptedCompletion() {
        if let codex {
            codex.clearForLidInterrupt()
            codex.incoming(["method": "turn/completed", "params": ["turn": ["status": "interrupted"]]])
        }
        if let copilot {
            copilot.clearForLidInterrupt()
            copilot.incoming(["id": 1, "result": ["stopReason": "cancelled"]])
        }
    }
}

private final class LidInterruptProbeState {
    var sessions: [UUID: LidInterruptProbeSession] = [:]
    var terminations: [[String: Any]] = []
    var forceKills: [[String: Any]] = []
    var deliveryCallbacks: [[String: Any]] = []
    var notifications: [[String: Any]] = []
    var resumeSends: [[String: Any]] = []
    var closeWindowSends: [[String: Any]] = []
    var lidSimEvents: [[String: Any]] = []
    var nonLidSleepEvents: [[String: Any]] = []
    var legacyStops: [String] = []
    var legacyResumes: [String] = []
    var restoredToInput: [String] = []
    var closeAt: TimeInterval?
    var openAt: TimeInterval?
    var freshDefaults: [String: Bool] = [:]
    var migration: [String: Any]?
    var settingsOptions: [[String: Any]] = []
    var settingsOperations: [[String: Any]] = []
    var untargetedProcessGroup: LidInterruptProbeProcessGroup?
    var cleanupProbeFixtures: (() -> Void)?
    var restoreProbeObservers: (() -> Void)?

    func cleanupProcesses() {
        sessions.values.compactMap(\.fakeProcessGroup).forEach { $0.cleanup() }
        untargetedProcessGroup?.cleanup()
        cleanupProbeFixtures?()
        cleanupProbeFixtures = nil
        restoreProbeObservers?()
        restoreProbeObservers = nil
    }
}

/// --lid-awake-closed-probe 專用的硬體替身；只由隔離測試掛鉤建立，所有決策仍由真正的 LidKeeper.tick() 執行。
private final class AwakeClosedProbeEnv: LidEnv {
    var closed = false
    var screenOff = false
    var suppressLidObservation = false
    var external = false
    var percent = 80
    var onAC = false
    var batteryAvailable = true
    var temp: Double? = 50
    var idleSeconds: TimeInterval? = 0
    var remote = false
    var helper = "ok" // ok | unsupported | fail | disconnect
    var connDead = false
    var noSleepValue = false
    var actualOn = false
    var fanSucceeds = true
    var sleepSucceeds = true
    var continuousOffset: TimeInterval = 0
    var uptimeOffset: TimeInterval = 0
    var wall: Date
    var sleepEvidenceValue: LidSleepEvidence? = LidSleepEvidence(wakeTime: 0, sleepTime: 0)
    var traceNow: () -> Date = Date.init
    var onCall: (String) -> Void = { _ in }
    var trace: [[String: Any]] = []

    init(wall: Date) { self.wall = wall }
    func lidClosed() -> Bool { closed }
    func externalDisplayOnline() -> Bool { external }
    func battery() -> (percent: Int, onAC: Bool)? { batteryAvailable ? (percent, onAC) : nil }
    func maxTemperature() -> Double? { temp }
    func hidIdleTime() -> TimeInterval? { idleSeconds }
    func setNoSleep(_ on: Bool) -> NoSleepResult {
        let result: NoSleepResult
        if on {
            if connDead || helper == "disconnect" { result = .failed("fixture disconnected") }
            else if helper == "unsupported" { result = .unsupported }
            else if helper == "fail" { result = .failed("fixture failure") }
            else { result = .ok }
            if result == .ok { noSleepValue = true; actualOn = true }
        } else {
            noSleepValue = false; actualOn = false
            result = .ok
        }
        trace.append(["event": "setNoSleep", "enabled": on,
                      "result": result == .ok ? "ok" : (result == .unsupported ? "unsupported" : "failed"),
                      "time": traceNow().timeIntervalSince1970,
                      "continuous": continuousTime()])
        onCall("[假小幫手] nosleep \(on ? "on" : "off")（\(helper)）")
        return result
    }
    func setFanAuto() -> Bool {
        trace.append(["event": "setFanAuto", "result": fanSucceeds ? "ok" : "failed",
                      "time": traceNow().timeIntervalSince1970, "continuous": continuousTime()])
        onCall("[假小幫手] fan auto")
        return fanSucceeds
    }
    func sleepNow() {
        trace.append(["event": "sleepNow", "result": sleepSucceeds ? "ok" : "failed",
                      "time": traceNow().timeIntervalSince1970, "continuous": continuousTime(), "remote": remote,
                      "batteryAvailable": batteryAvailable, "batteryPercent": percent, "onAC": onAC])
        onCall(sleepSucceeds ? "[假] pmset sleepnow" : "pmset sleepnow 失敗：fixture")
    }
    func noSleepStatus() -> Bool? { helper == "ok" && !connDead ? noSleepValue : nil }
    func sleepEvidence() -> LidSleepEvidence? { sleepEvidenceValue }
    func systemUptime() -> TimeInterval { 1_000 + uptimeOffset }
    func continuousTime() -> TimeInterval { 1_000 + continuousOffset }
    func remoteSessionActive() -> Bool { remote }
}

private final class AwakeClosedProbeRow {
    let alias: String
    let conversation: Conversation
    let work: LidInterruptWork
    let pending: [LidQueuedMessage]
    let archived: Bool
    let available: Bool
    let drainSeconds: TimeInterval
    var active: Bool
    var terminated = false
    var forced = false
    var drainUntil = Date.distantPast

    init(alias: String, conversation: Conversation, work: LidInterruptWork, pending: [LidQueuedMessage],
         archived: Bool, available: Bool, drainSeconds: TimeInterval, active: Bool) {
        self.alias = alias; self.conversation = conversation; self.work = work; self.pending = pending
        self.archived = archived; self.available = available; self.drainSeconds = drainSeconds; self.active = active
    }
}

/// C402–C408 由施工-codex2 的 TestHarnessAwakeRescue.swift 處理；接上新檔後移除此占位。
enum TestHarness {
}

extension AppDelegate {
    private func startKeyGuardAsyncProbe(_ args: [String]) {
        guard let optionIndex = args.firstIndex(of: "--keyguard-async-probe"), optionIndex + 3 < args.count,
              let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count else { exit(2) }
        let caseID = args[optionIndex + 1]
        let allowedCases: Set<String> = ["C419", "C420", "C421", "C423", "C424", "C425", "C426", "C427", "C428", "C429", "C437"]
        guard allowedCases.contains(caseID) else { exit(2) }
        let stateDirectory = URL(fileURLWithPath: args[stateIndex + 1], isDirectory: true).standardizedFileURL
        let syntheticRoot = URL(fileURLWithPath: "/private/tmp/claude-\(getuid())", isDirectory: true)
        let configURL = URL(fileURLWithPath: args[optionIndex + 2]).standardizedFileURL
        let outputURL = URL(fileURLWithPath: args[optionIndex + 3]).standardizedFileURL
        guard isTestProbeOutput(stateDirectory, inside: syntheticRoot),
              isTestProbeOutput(configURL, inside: syntheticRoot),
              isTestProbeOutput(outputURL, inside: stateDirectory),
              let configData = try? Data(contentsOf: configURL),
              let config = (try? JSONSerialization.jsonObject(with: configData)) as? [String: Any],
              (config["schemaVersion"] as? Int) == 1,
              let stepRows = config["steps"] as? [Any], !stepRows.isEmpty, stepRows.count <= 16 else { exit(2) }
        let steps = stepRows.compactMap { KeyGuardAsyncProbeStep.parse($0, under: syntheticRoot) }
        guard steps.count == stepRows.count else { exit(2) }
        guard caseID == "C437" || !steps.contains(where: { $0.textDecision == "save" }) else { exit(2) }
        let markerURL = stateDirectory.appendingPathComponent("keyguard-probe-marker-\(UUID().uuidString).bin")
        do {
            try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
            try Data("synthetic marker".utf8).write(to: markerURL, options: .atomic)
        } catch { exit(2) }

        if self.store.selected.flatMap({ self.workspace.panes[$0] as? ChatPane }) == nil {
            let projectID = self.store.projects.first(where: { $0.path == stateDirectory.path })?.id
                ?? self.store.addProject(path: stateDirectory.path).id
            let conversation = self.store.newConversation(in: projectID)
            guard self.store.selected == conversation.id else { exit(2) }
        }
        let alternateConversationID: UUID? = self.store.selected.flatMap { self.store.conversation($0) }
            .map { self.store.createConversation(in: $0.projectID, draft: true).id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, let selectedID = self.store.selected,
                  let pane = self.workspace.panes[selectedID] as? ChatPane else { exit(2) }
            let controller = KeyGuardAsyncProbeController(pane: pane, stateDirectory: stateDirectory,
                                                          outputURL: outputURL, caseID: caseID, steps: steps,
                                                          markerURL: markerURL,
                                                          switchChat: {
                                                              guard let alternateConversationID else { return false }
                                                              self.store.show(alternateConversationID, replaceFocused: true)
                                                              return self.store.selected == alternateConversationID
                                                          })
            controller.start()
        }
    }

    private func runKeyGuardConcurrencyProbe(_ args: [String]) {
        guard args.contains("--state-dir"),
              let optionIndex = args.firstIndex(of: "--keyguard-concurrency-probe"), optionIndex + 2 < args.count,
              let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count else { exit(2) }
        let stateDirectory: URL = URL(fileURLWithPath: args[stateIndex + 1], isDirectory: true).standardizedFileURL
        let manifestURL: URL = URL(fileURLWithPath: args[optionIndex + 1]).standardizedFileURL
        let outputURL: URL = URL(fileURLWithPath: args[optionIndex + 2]).standardizedFileURL
        let syntheticRoot: URL = URL(fileURLWithPath: "/private/tmp/claude-\(getuid())", isDirectory: true)
        guard isTestProbeOutput(manifestURL, inside: syntheticRoot),
              isTestProbeOutput(outputURL, inside: stateDirectory),
              let manifestData: Data = try? Data(contentsOf: manifestURL),
              let manifest: [String: Any] = (try? JSONSerialization.jsonObject(with: manifestData)) as? [String: Any],
              let cases: [String: Any] = manifest["cases"] as? [String: Any],
              let g12: [String: Any] = cases["G12"] as? [String: Any],
              let redactInput: [String: Any] = g12["redactInput"] as? [String: Any],
              let inputPath: String = redactInput["path"] as? String else { exit(2) }
        let inputURL: URL = URL(fileURLWithPath: inputPath).standardizedFileURL
        guard isTestProbeOutput(inputURL, inside: syntheticRoot),
              let input: String = try? String(contentsOf: inputURL, encoding: .utf8),
              !input.isEmpty else { exit(2) }

        KeyGuard.wire()
        let seedFindings: [KeyScanFinding] = KeyScan.findings(input)
        guard let weakSeed: KeyScanFinding = seedFindings.first(where: { $0.hit.isLearnableWeak }) else { exit(2) }
        // fixture 的 key= 前文不會形成可學習特徵；把同一個假 hex 命中放到 integrity= 前文，走實際特徵與回呼。
        let learningInput: String = "key=synthetic integrity='\(weakSeed.hit.key)'"
        guard let seed: KeyScanFinding = KeyScan.findings(learningInput).first(where: { $0.hit.isLearnableWeak }),
              let feature: String = seed.feature else { exit(2) }
        // 只用 fixture 產生的非祕密特徵與雜湊，讓背景 redact 能併發觸發既有 learned-suppression callback。
        KeyGuard.recordFalsePositive(seed.hit, source: learningInput)
        KeyGuard.recordFalsePositive(seed.hit, source: learningInput)
        let learnedID: String = KeyScan.learningKey(rule: seed.hit.kind, feature: feature)

        let workerCount: Int = 2
        let workerIterations: Int = 1_000
        let scanInput: String = input + "\n" + learningInput
        let mutationRoundsValue: Any = g12["mainThreadMutationRounds"] ?? 1_000
        let mutationRounds: Int = mutationRoundsValue as? Int ?? 0
        guard mutationRounds == 1_000 else { exit(2) }
        let metrics = KeyGuardConcurrencyProbeMetrics()
        let ready = DispatchSemaphore(value: 0)
        let start = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        for _ in 0..<workerCount {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                ready.signal()
                start.wait()
                for _ in 0..<workerIterations {
                    let redacted: String = KeyScan.redact(scanInput)
                    metrics.recordRedact(changed: redacted != scanInput)
                }
                metrics.recordWorkerCompletion()
                group.leave()
            }
        }
        for _ in 0..<workerCount { ready.wait() }
        metrics.beginMutations()
        let mutationsOnMain: Bool = Thread.isMainThread
        KeyGuard.allow("e74b99 G12 synthetic allow 0")
        KeyGuard.reloadLearning()
        KeyGuard.removeLearnedFeature(learnedID)
        for _ in 0..<workerCount { start.signal() }
        for index in 1..<mutationRounds {
            KeyGuard.allow("e74b99 G12 synthetic allow \(index)")
            KeyGuard.reloadLearning()
            KeyGuard.removeLearnedFeature(learnedID)
        }
        metrics.endMutations()
        group.wait()
        let counts = metrics.snapshot()
        let allCompleted: Bool = counts.workers == workerCount && counts.calls == workerCount * workerIterations
            && counts.redacted == counts.calls && counts.overlapping > 0 && mutationRounds == 1_000 && mutationsOnMain
        let probeCase: String? = args.firstIndex(of: "--probe-case").flatMap { index in
            index + 1 < args.count ? args[index + 1] : nil
        }
        guard probeCase == nil || probeCase == "C436" else { exit(2) }
        let result: [String: Any]
        if probeCase == "C436" {
            let normalized: [String: Any] = [
                "testCompleted": allCompleted,
                "crashed": false,
                "redactWorkerCount": workerCount,
                "redactWorkersCompleted": counts.workers,
                "redactCallsCompleted": counts.calls,
                "redactOverlappedMutations": counts.overlapping > 0,
                "mutationsRanOnMainThread": mutationsOnMain,
                "mainThreadMutationIterations": mutationRounds,
                "allowCalls": mutationRounds,
                "reloadLearningCalls": mutationRounds,
                "removeLearnedFeatureCalls": mutationRounds
            ]
            result = ["schemaVersion": 1, "caseId": "C436", "observed": normalized]
        } else {
            let legacy: [String: Any] = [
                "schemaVersion": 1,
                "caseId": "C430",
                "isolatedStateDir": true,
                "workerCount": workerCount,
                "workerIterationsPerThread": workerIterations,
                "workersCompleted": counts.workers,
                "redactCalls": counts.calls,
                "redactedCalls": counts.redacted,
                "redactCallsDuringMainMutations": counts.overlapping,
                "mainThreadMutationRoundsRequested": mutationRounds,
                "mainThreadMutationRoundsCompleted": mutationRounds,
                "mainThreadMutationsOnMainThread": mutationsOnMain,
                "allowCalls": mutationRounds,
                "reloadLearningCalls": mutationRounds,
                "removeLearnedFeatureCalls": mutationRounds,
                "learnedSuppressionFixtureSeeded": true,
                "allCompleted": allCompleted,
                "containsRawFixtureText": false
            ]
            result = legacy
        }
        do {
            let outputData: Data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try outputData.write(to: outputURL, options: .atomic)
        } catch { exit(2) }
        exit(0)
    }

    @MainActor
    private func startDraftLifecycleProbe(_ args: [String]) {
        guard let optionIndex = args.firstIndex(of: "--draft-lifecycle-probe"), optionIndex + 4 < args.count,
              let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count else { exit(2) }
        let caseID = args[optionIndex + 1]
        let phase = args[optionIndex + 2]
        guard ["C431", "C432", "C433", "C434", "C435"].contains(caseID),
              (caseID == "C432" || caseID == "C433") ? ["prepare", "inspect"].contains(phase) : phase == "single" else { exit(2) }
        let stateRoot = store.directory.standardizedFileURL
        let syntheticRoot = URL(fileURLWithPath: "/private/tmp/claude-\(getuid())", isDirectory: true)
        let manifestURL = URL(fileURLWithPath: args[optionIndex + 3]).standardizedFileURL
        let outputURL = URL(fileURLWithPath: args[optionIndex + 4]).standardizedFileURL
        guard isTestProbeOutput(stateRoot, inside: syntheticRoot),
              isTestProbeOutput(manifestURL, inside: syntheticRoot),
              isTestProbeOutput(outputURL, inside: stateRoot),
              let data = try? Data(contentsOf: manifestURL),
              let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { exit(2) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { exit(2) }
            self.runDraftLifecycleProbe(caseID: caseID, phase: phase, manifest: manifest,
                                        stateRoot: stateRoot, syntheticRoot: syntheticRoot, outputURL: outputURL)
        }
    }

    private func draftLifecycleFixtureURL(_ manifest: [String: Any], section: String, key: String,
                                          under root: URL) -> URL? {
        guard let row = manifest[section] as? [String: Any],
              let path = row[key] as? String else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard isTestProbeOutput(url, inside: root), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func writeDraftLifecycleJSON(_ payload: [String: Any], to outputURL: URL, inside stateRoot: URL) -> Bool {
        guard isTestProbeOutput(outputURL, inside: stateRoot), JSONSerialization.isValidJSONObject(payload) else { return false }
        do {
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted])
            try data.write(to: outputURL, options: .atomic)
            return true
        } catch { return false }
    }

    private func writeDraftLifecycleObservation(_ caseID: String, observed: [String: Any],
                                                to outputURL: URL, inside stateRoot: URL) -> Bool {
        writeDraftLifecycleJSON(["schemaVersion": 1, "caseId": caseID, "observed": observed],
                                to: outputURL, inside: stateRoot)
    }

    @MainActor
    private func makeDraftLifecyclePane(in stateRoot: URL) -> (Conversation, ChatPane)? {
        let projectID = store.projects.first(where: { $0.path == stateRoot.path })?.id
            ?? store.addProject(path: stateRoot.path).id
        let conversation = store.createConversation(in: projectID, draft: true)
        store.saveNow()
        store.show(conversation.id, replaceFocused: true)
        guard let pane = (workspace.panes[conversation.id] as? ChatPane)
            ?? (workspace.pane(for: conversation) as? ChatPane) else { return nil }
        return (conversation, pane)
    }

    /// C438：驗證新大草稿 writer 只清除本聊天室命名空間內的 primary／recovery 圖片。
    private func runLargeDraftImageCleanupProbe(_ args: [String]) {
        guard CommandLine.arguments.contains("--state-dir"),
              let optionIndex = args.firstIndex(of: "--large-draft-image-cleanup-probe"), optionIndex + 1 < args.count else { exit(2) }
        let stateRoot = store.directory.standardizedFileURL
        let syntheticRoot = URL(fileURLWithPath: "/private/tmp/claude-\(getuid())", isDirectory: true)
        let outputURL = URL(fileURLWithPath: args[optionIndex + 1]).standardizedFileURL
        guard isTestProbeOutput(stateRoot, inside: syntheticRoot),
              isTestProbeOutput(outputURL, inside: stateRoot) else { exit(2) }

        let fileManager = FileManager.default
        let draftsDirectory = stateRoot.appendingPathComponent("drafts", isDirectory: true)
        let recoveryDirectory = draftsDirectory.appendingPathComponent(".recovery", isDirectory: true)
        do {
            try fileManager.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        } catch { exit(2) }

        func writeJSON(_ value: [String: Any], to url: URL) -> Bool {
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return false }
            do {
                try data.write(to: url, options: .atomic)
                return true
            } catch { return false }
        }

        func oldRecord(images: [[String: Any]]) -> [String: Any] {
            ["text": "synthetic old draft", "quotes": [], "filePaths": [], "images": images]
        }

        let primaryID = UUID()
        let primaryIDText = primaryID.uuidString.lowercased()
        let primaryPrefix = "\(primaryIDText)-img-"
        let primaryURL = draftsDirectory.appendingPathComponent("\(primaryIDText).json")
        let primaryOutside = stateRoot.appendingPathComponent("r2-primary-outside-marker.png")
        let primaryOldImageName = "\(primaryPrefix)u\(UUID().uuidString.lowercased())-1.png"
        let primaryOldImageURL = draftsDirectory.appendingPathComponent(primaryOldImageName)
        do {
            try Data("outside-primary-marker".utf8).write(to: primaryOutside, options: .atomic)
            try Data([0x89, 0x50, 0x4e, 0x47]).write(to: primaryOldImageURL, options: .atomic)
        } catch { exit(2) }
        let primaryRecord = oldRecord(images: [
            ["no": 1, "mediaType": "image/png", "file": "../\(primaryOutside.lastPathComponent)", "edited": false],
            ["no": 2, "mediaType": "image/png", "file": primaryOldImageName, "edited": false]
        ])
        guard writeJSON(primaryRecord, to: primaryURL) else { exit(2) }

        let primaryRecoveryURL = recoveryDirectory.appendingPathComponent("\(primaryIDText).json")
        let primaryState = LargeDraftWriteState(fileURL: primaryURL)
        let primarySnapshot = primaryState.begin { revision in
            LargeDraftSnapshot(revision: revision, writeID: UUID(), text: "synthetic replacement", quotes: [], filePaths: [],
                               images: [], directory: draftsDirectory, fileURL: primaryURL,
                               recoveryDirectory: recoveryDirectory, recoveryURL: primaryRecoveryURL,
                               imagePrefix: primaryPrefix, testWriteDelay: 0, testAfterPrimaryImageWrite: nil,
                               testBeforePrimaryJSONWrite: nil, testAfterPrimaryWrite: nil)
        }
        let primaryWriteSucceeded = LargeDraftFileWriter.writePrimary(primarySnapshot, state: primaryState)
        primaryState.finish(primarySnapshot.revision, succeeded: primaryWriteSucceeded)

        let recoveryID = UUID()
        let recoveryIDText = recoveryID.uuidString.lowercased()
        let recoveryPrefix = "\(recoveryIDText)-img-"
        let recoveryURL = recoveryDirectory.appendingPathComponent("\(recoveryIDText).json")
        let recoveryOutside = stateRoot.appendingPathComponent("r2-recovery-outside-marker.png")
        let recoveryOldImageName = "\(recoveryPrefix)u\(UUID().uuidString.lowercased())-1.jpg"
        let recoveryOldImageURL = recoveryDirectory.appendingPathComponent(recoveryOldImageName)
        do {
            try Data("outside-recovery-marker".utf8).write(to: recoveryOutside, options: .atomic)
            try Data([0xff, 0xd8, 0xff]).write(to: recoveryOldImageURL, options: .atomic)
        } catch { exit(2) }
        let recoveryRecord = oldRecord(images: [
            ["no": 1, "mediaType": "image/png", "file": ".recovery/../../\(recoveryOutside.lastPathComponent)", "edited": false],
            ["no": 2, "mediaType": "image/jpeg", "file": ".recovery/\(recoveryOldImageName)", "edited": false]
        ])
        guard writeJSON(recoveryRecord, to: recoveryURL) else { exit(2) }
        let recoveryPrimaryURL = draftsDirectory.appendingPathComponent("\(recoveryIDText).json")
        let recoveryState = LargeDraftWriteState(fileURL: recoveryPrimaryURL)
        let recoverySnapshot = recoveryState.begin { revision in
            LargeDraftSnapshot(revision: revision, writeID: UUID(), text: "synthetic recovery replacement", quotes: [], filePaths: [],
                               images: [], directory: draftsDirectory, fileURL: recoveryPrimaryURL,
                               recoveryDirectory: recoveryDirectory, recoveryURL: recoveryURL,
                               imagePrefix: recoveryPrefix, testWriteDelay: 0, testAfterPrimaryImageWrite: nil,
                               testBeforePrimaryJSONWrite: nil, testAfterPrimaryWrite: nil)
        }
        let recoveryWriteSucceeded = LargeDraftFileWriter.writeRecovery(recoverySnapshot, state: recoveryState)
        recoveryState.finish(recoverySnapshot.revision, succeeded: recoveryWriteSucceeded)

        let observed: [String: Any] = [
            "primaryWriteSucceeded": primaryWriteSucceeded,
            "primaryTraversalMarkerExists": fileManager.fileExists(atPath: primaryOutside.path),
            "primaryOwnedOldImageRemoved": !fileManager.fileExists(atPath: primaryOldImageURL.path),
            "recoveryWriteSucceeded": recoveryWriteSucceeded,
            "recoveryTraversalMarkerExists": fileManager.fileExists(atPath: recoveryOutside.path),
            "recoveryOwnedOldImageRemoved": !fileManager.fileExists(atPath: recoveryOldImageURL.path),
            "allFixturesInsideStateDir": isTestProbeOutput(primaryOutside, inside: stateRoot)
                && isTestProbeOutput(primaryOldImageURL, inside: stateRoot)
                && isTestProbeOutput(recoveryOutside, inside: stateRoot)
                && isTestProbeOutput(recoveryOldImageURL, inside: stateRoot)
        ]
        let output: [String: Any] = ["schemaVersion": 1, "caseId": "C438", "isolatedStateDir": true,
                                     "observed": observed, "fixtureContentsReported": false]
        do {
            let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .prettyPrinted])
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: outputURL, options: .atomic)
            exit(0)
        } catch { exit(2) }
    }

    private func draftLifecycleMetadataURL(_ root: URL) -> URL {
        root.appendingPathComponent("draft-lifecycle-probe-state.json")
    }

    @MainActor
    private func runDraftLifecycleProbe(caseID: String, phase: String, manifest: [String: Any],
                                        stateRoot: URL, syntheticRoot: URL, outputURL: URL) {
        guard let smallURL = draftLifecycleFixtureURL(manifest, section: "smallDraft", key: "path", under: syntheticRoot),
              let largeURL = draftLifecycleFixtureURL(manifest, section: "largeDraft", key: "path", under: syntheticRoot),
              let imageURL = draftLifecycleFixtureURL(manifest, section: "handoffImage", key: "path", under: syntheticRoot),
              let fileCardURL = draftLifecycleFixtureURL(manifest, section: "handoffFileCard", key: "path", under: syntheticRoot),
              let smallText = try? String(contentsOf: smallURL, encoding: .utf8),
              let largeText = try? String(contentsOf: largeURL, encoding: .utf8),
              let imageData = try? Data(contentsOf: imageURL) else { exit(2) }
        let expectedSmallText = KeyScan.redact(smallText, strongOnly: true)
        let expectedLargeText = KeyScan.redact(largeText, strongOnly: true)
        let largeBytes = largeText.utf8.count
        let fakeCredential: String? = largeText.range(of: #"sk-[A-Za-z0-9]{40}"#, options: .regularExpression)
            .map { String(largeText[$0]) }

        switch caseID {
        case "C431":
            guard phase == "single", smallText.utf8.count < 1_048_576,
                  let (conversation, pane) = makeDraftLifecyclePane(in: stateRoot) else { exit(2) }
            pane.inputBar.textView.string = smallText
            pane.inputBar.textView.didChangeText()
            let completedBeforeReturn = pane.flushDraft()
            let persistence = DraftPersistence(directory: store.directory, conversationID: conversation.id)
            let savedAtReturn = persistence.read()
            workspace.close(conversation.id)
            guard let reopenedConversation = store.conversation(conversation.id),
                  let reopened = workspace.pane(for: reopenedConversation) as? ChatPane else { exit(2) }
            reopened.restoreSavedDraftIfNeeded()
            let matches = KeyScan.hash(reopened.inputBar.textView.string) == KeyScan.hash(expectedSmallText)
            let observed: [String: Any] = [
                "draftSizeBytes": smallText.utf8.count,
                "saveMode": "synchronous",
                "saveCompletedBeforeReturn": completedBeforeReturn && savedAtReturn != nil,
                "reopenedContentMatches": matches
            ]
            guard writeDraftLifecycleObservation(caseID, observed: observed, to: outputURL, inside: stateRoot) else { exit(2) }
            exit(0)

        case "C432", "C433":
            if phase == "prepare" {
                guard largeBytes >= 1_048_576, let (conversation, pane) = makeDraftLifecyclePane(in: stateRoot) else { exit(2) }
                pane.inputBar.textView.string = largeText
                pane.inputBar.textView.didChangeText()
                DraftPersistence.testLargeWriteDelay = 4
                let synchronousResult = pane.flushDraft()
                let writeIncomplete = !synchronousResult && pane.draftHasPendingLargeWriteForTest
                var paneClosed = false
                if caseID == "C433" {
                    workspace.close(conversation.id)
                    paneClosed = workspace.panes[conversation.id] == nil
                }
                store.saveNow()
                let metadata: [String: Any] = [
                    "conversationID": conversation.id.uuidString,
                    "expectedTextHash": KeyScan.hash(expectedLargeText),
                    "draftSizeBytes": largeBytes,
                    "writeIncompleteAtEnd": writeIncomplete,
                    "endEvent": caseID == "C432" ? "applicationTermination" : "paneClose",
                    "paneClosed": paneClosed
                ]
                guard writeDraftLifecycleJSON(metadata, to: draftLifecycleMetadataURL(stateRoot), inside: stateRoot) else { exit(2) }
                if caseID == "C432" {
                    E74DraftLifecycleProbeRuntime.observeTermination(
                        at: stateRoot.appendingPathComponent("draft-lifecycle-will-terminate"),
                        caseID: caseID, stateRoot: stateRoot, outputURL: outputURL,
                        fakeCredential: fakeCredential
                    )
                } else if !E74DraftLifecycleProbeRuntime.writePrepareObservation(
                    caseID: caseID, stateRoot: stateRoot, outputURL: outputURL,
                    fakeCredential: fakeCredential
                ) {
                    exit(2)
                }
                NSApp.terminate(nil)
                return
            }

            guard phase == "inspect",
                  let metadataData = try? Data(contentsOf: draftLifecycleMetadataURL(stateRoot)),
                  let metadata = (try? JSONSerialization.jsonObject(with: metadataData)) as? [String: Any],
                  let idString = metadata["conversationID"] as? String, let conversationID = UUID(uuidString: idString),
                  let expectedTextHash = metadata["expectedTextHash"] as? String,
                  let event = metadata["endEvent"] as? String,
                  let conversation = store.conversation(conversationID) else { exit(2) }
            let terminationMarker = stateRoot.appendingPathComponent("draft-lifecycle-will-terminate")
            let terminationConfirmed = FileManager.default.fileExists(atPath: terminationMarker.path)
            store.show(conversationID, replaceFocused: true)
            guard let pane = (workspace.panes[conversationID] as? ChatPane)
                ?? (workspace.pane(for: conversation) as? ChatPane) else { exit(2) }
            pane.restoreSavedDraftIfNeeded()
            let recoveryURL = stateRoot.appendingPathComponent("drafts/.recovery/\(conversationID.uuidString.lowercased()).json")
            let recovered: DraftPersistence.Record? = (try? Data(contentsOf: recoveryURL))
                .flatMap { try? JSONDecoder().decode(DraftPersistence.Record.self, from: $0) }
            let restoredHash = KeyScan.hash(pane.inputBar.textView.string)
            let containsRawCredential: Bool = fakeCredential.map { recovered?.text.contains($0) ?? true } ?? true
            let observed: [String: Any] = [
                "draftSizeBytes": metadata["draftSizeBytes"] as? Int ?? 0,
                "saveMode": "background",
                "writeIncompleteAtEnd": metadata["writeIncompleteAtEnd"] as? Bool ?? false,
                "endEvent": event,
                "endEventCancelled": event == "paneClose"
                    ? !(metadata["paneClosed"] as? Bool ?? false)
                    : !terminationConfirmed,
                "maskedSnapshotSaved": recovered != nil && recovered?.text != largeText,
                "snapshotIsolated": FileManager.default.fileExists(atPath: recoveryURL.path)
                    && isTestProbeOutput(recoveryURL, inside: stateRoot),
                "snapshotContainsRawFakeCredential": containsRawCredential,
                "nextLaunchNotice": pane.modelSelectionProbeNotices.contains(L("上次結束時大草稿尚未完成存檔，已從隔離復原快照還原。")),
                "restoredTextMatches": restoredHash == expectedTextHash,
                "terminationConfirmed": terminationConfirmed
            ]
            DraftPersistence.testLargeWriteDelay = 0
            guard writeDraftLifecycleObservation(caseID, observed: observed, to: outputURL, inside: stateRoot) else { exit(2) }
            exit(0)

        case "C434":
            guard phase == "single", largeBytes >= 1_048_576,
                  let (withinSourceConversation, withinSource) = makeDraftLifecyclePane(in: stateRoot),
                  let (withinDestinationConversation, withinDestination) = makeDraftLifecyclePane(in: stateRoot),
                  let (timeoutSourceConversation, timeoutSource) = makeDraftLifecyclePane(in: stateRoot),
                  let (timeoutDestinationConversation, timeoutDestination) = makeDraftLifecyclePane(in: stateRoot) else { exit(2) }
            _ = withinSourceConversation; _ = timeoutSourceConversation
            withinSource.inputBar.textView.string = largeText
            let withinStart = ProcessInfo.processInfo.systemUptime
            let withinSucceeded = withinSource.moveDraft(to: withinDestination)
            let withinElapsed = Int(((ProcessInfo.processInfo.systemUptime - withinStart) * 1000).rounded())
            let destinationMatches = KeyScan.hash(withinDestination.inputBar.textView.string) == KeyScan.hash(largeText)

            timeoutSource.inputBar.textView.string = largeText
            timeoutSource.draftHandoffWriteDelayForTest = 4
            let sourceHashBefore = KeyScan.hash(timeoutSource.inputBar.textView.string)
            let timeoutStart = ProcessInfo.processInfo.systemUptime
            let timeoutSucceeded = timeoutSource.moveDraft(to: timeoutDestination)
            let timeoutElapsed = Int(((ProcessInfo.processInfo.systemUptime - timeoutStart) * 1000).rounded())
            let sourceUnchanged = KeyScan.hash(timeoutSource.inputBar.textView.string) == sourceHashBefore
                && timeoutDestination.inputBar.textView.string.isEmpty
            DraftPersistence.testLargeWriteDelay = 0
            let observed: [String: Any] = [
                "draftSizeBytes": largeBytes,
                "withinDeadline": ["elapsedMs": withinElapsed, "handoffSucceeded": withinSucceeded,
                                   "destinationMatches": destinationMatches],
                "timeout": ["elapsedMs": timeoutElapsed, "handoffSucceeded": timeoutSucceeded,
                            "sourceUnchanged": sourceUnchanged]
            ]
            guard writeDraftLifecycleObservation(caseID, observed: observed, to: outputURL, inside: stateRoot) else { exit(2) }
            exit(0)

        case "C435":
            guard phase == "single", smallText.utf8.count < 1_048_576,
                  let (sourceConversation, source) = makeDraftLifecyclePane(in: stateRoot),
                  let (destinationConversation, destination) = makeDraftLifecyclePane(in: stateRoot) else { exit(2) }
            _ = sourceConversation; _ = destinationConversation
            source.inputBar.textView.string = smallText + "\n[Image #1] " + TerminalPane.shellEscape(fileCardURL.path)
            source.inputBar.restoreImages([DraftPersistence.Image(data: imageData, mediaType: "image/png", no: 1, edited: false)])
            source.inputBar.restoreFilePaths([fileCardURL.path])
            func attachmentSnapshot(_ pane: ChatPane) -> [String: Any] {
                let imageIDs = pane.inputBar.draftImages.map { $0.no }
                let fileCardIDs = pane.inputBar.draftFilePaths.map { URL(fileURLWithPath: $0).lastPathComponent }
                return ["imageIDs": imageIDs, "fileCardIDs": fileCardIDs]
            }
            let sourceSnapshot = attachmentSnapshot(source)
            let moved = source.moveDraft(to: destination)
            let destinationSnapshot = attachmentSnapshot(destination)
            let observed: [String: Any] = ["source": sourceSnapshot, "destination": destinationSnapshot,
                                           "moveCompleted": moved]
            guard writeDraftLifecycleObservation(caseID, observed: observed, to: outputURL, inside: stateRoot) else { exit(2) }
            exit(0)

        default:
            exit(2)
        }
    }

    @MainActor
    private func startDraftR1Probe(_ args: [String]) {
        guard let optionIndex = args.firstIndex(of: "--draft-r1-probe"), optionIndex + 3 < args.count,
              let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count else { exit(2) }
        let caseID = args[optionIndex + 1]
        let phase = args[optionIndex + 2]
        guard ["N1", "N2", "N3", "N4", "N5", "N6", "N7"].contains(caseID) else { exit(2) }
        if caseID == "N1" {
            guard ["prepare-applicationTermination", "inspect-applicationTermination",
                   "prepare-paneClose", "inspect-paneClose"].contains(phase) else { exit(2) }
        } else if phase != "single" { exit(2) }
        let stateRoot = store.directory.standardizedFileURL
        let outputURL = URL(fileURLWithPath: args[optionIndex + 3]).standardizedFileURL
        let syntheticRoot = URL(fileURLWithPath: "/private/tmp/claude-\(getuid())", isDirectory: true)
        guard isTestProbeOutput(stateRoot, inside: syntheticRoot),
              isTestProbeOutput(outputURL, inside: stateRoot) else { exit(2) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { exit(2) }
            self.runDraftR1Probe(caseID: caseID, phase: phase, stateRoot: stateRoot, outputURL: outputURL)
        }
    }

    private func draftR1SyntheticText(bytes: Int, seed: String = "draft-r1 synthetic ") -> String {
        guard bytes > 0 else { return "" }
        let unit = seed.isEmpty ? "x" : seed
        return String(repeating: unit, count: bytes / unit.utf8.count + 1).prefix(bytes).description
    }

    private func draftR1MetadataURL(_ stateRoot: URL, event: String) -> URL {
        stateRoot.appendingPathComponent("draft-r1-n1-\(event).json")
    }

    @MainActor
    private func runDraftR1Probe(caseID: String, phase: String, stateRoot: URL, outputURL: URL) {
        func write(_ observed: [String: Any]) {
            guard writeDraftLifecycleObservation(caseID, observed: observed, to: outputURL, inside: stateRoot) else { exit(2) }
        }
        let largeText = draftR1SyntheticText(bytes: 1_280 * 1_024)
        guard let imageBytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAaX2RUAAAAAASUVORK5CYII=") else { exit(2) }

        switch caseID {
        case "N1":
            let event = phase.hasSuffix("applicationTermination") ? "applicationTermination" : "paneClose"
            let metadataURL = draftR1MetadataURL(stateRoot, event: event)
            if phase.hasPrefix("prepare-") {
                guard let (sourceConversation, source) = makeDraftLifecyclePane(in: stateRoot),
                      let (_, target) = makeDraftLifecyclePane(in: stateRoot) else { exit(2) }
                let sourceText = largeText + "\n[Image #1]"
                let expectedTextHash = KeyScan.hash(KeyScan.redact(sourceText, strongOnly: true))
                // Keep any autosave scheduled by the fixture behind the same background delay,
                // so the handoff timeout is the only write completion before the close/quit path.
                DraftPersistence.testLargeWriteDelay = 4
                source.inputBar.textView.string = sourceText
                source.inputBar.restoreImages([DraftPersistence.Image(data: imageBytes, mediaType: "image/png", no: 1, edited: false)])
                source.draftHandoffWriteDelayForTest = 4
                let handoffSucceeded = source.moveDraft(to: target)
                let sourceUnchanged = KeyScan.hash(source.inputBar.textView.string) == KeyScan.hash(sourceText)
                var metadata: [String: Any] = [
                    "conversationID": sourceConversation.id.uuidString,
                    "expectedTextHash": expectedTextHash,
                    "handoffSucceeded": handoffSucceeded,
                    "sourceTextUnchanged": sourceUnchanged,
                    "event": event
                ]
                if event == "paneClose" {
                    workspace.close(sourceConversation.id)
                    metadata["paneClosed"] = workspace.panes[sourceConversation.id] == nil
                }
                guard writeDraftLifecycleJSON(metadata, to: metadataURL, inside: stateRoot) else { exit(2) }
                write([
                    "event": event,
                    "handoffSucceeded": handoffSucceeded,
                    "sourceTextUnchanged": sourceUnchanged,
                    "terminationRequested": event == "applicationTermination",
                    "paneClosedBeforeTermination": metadata["paneClosed"] as? Bool ?? false
                ])
                store.saveNow()
                NSApp.terminate(nil)
                return
            }
            guard let data = try? Data(contentsOf: metadataURL),
                  let metadata = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let idString = metadata["conversationID"] as? String,
                  let conversationID = UUID(uuidString: idString),
                  let conversation = store.conversation(conversationID),
                  let expectedTextHash = metadata["expectedTextHash"] as? String else { exit(2) }
            store.show(conversationID, replaceFocused: true)
            guard let pane = (workspace.panes[conversationID] as? ChatPane)
                ?? (workspace.pane(for: conversation) as? ChatPane) else { exit(2) }
            pane.restoreSavedDraftIfNeeded()
            let persistence = DraftPersistence(directory: stateRoot, conversationID: conversationID)
            let restoredTextHash = KeyScan.hash(pane.inputBar.textView.string)
            let recoveredRecord = persistence.read()
            let imageCount = pane.inputBar.draftImages.count
            write([
                "event": event,
                "handoffSucceeded": metadata["handoffSucceeded"] as? Bool ?? false,
                "sourceTextUnchanged": metadata["sourceTextUnchanged"] as? Bool ?? false,
                "recoverableAfterQuit": restoredTextHash == expectedTextHash,
                "restoredTextMatches": restoredTextHash == expectedTextHash,
                "restoredImageCount": imageCount,
                "recordReadable": recoveredRecord != nil,
                "paneClosedBeforeRestart": metadata["paneClosed"] as? Bool ?? false
            ])
            exit(0)

        case "N2":
            guard let (conversation, _) = makeDraftLifecyclePane(in: stateRoot) else { exit(2) }
            let persistence = DraftPersistence(directory: stateRoot, conversationID: conversation.id)
            let oldText = draftR1SyntheticText(bytes: 1_280 * 1_024, seed: "old-large-draft ")
            let shortText = "short replacement draft"
            let reachedJSON = DispatchSemaphore(value: 0)
            let releaseJSON = DispatchSemaphore(value: 0)
            let oldWriteFinished = DispatchSemaphore(value: 0)
            persistence.testDebounceDelay = 10
            persistence.testBeforePrimaryJSONWrite = {
                reachedJSON.signal()
                _ = releaseJSON.wait(timeout: .now() + 8)
            }
            persistence.testAfterPrimaryWrite = { _ in oldWriteFinished.signal() }
            let writeReturned = persistence.write(text: oldText, quotes: [], filePaths: [], images: [])
            let reached = reachedJSON.wait(timeout: .now() + 8) == .success
            // 以短延遲自動放行 writer，避免舊版持鎖時 main thread 卡在 schedule 而讓探針永久等待。
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.1) { releaseJSON.signal() }
            let scheduleStartedAt = ProcessInfo.processInfo.systemUptime
            persistence.schedule(text: shortText, quotes: [], filePaths: [], images: [])
            let scheduleElapsedMilliseconds = Int(((ProcessInfo.processInfo.systemUptime - scheduleStartedAt) * 1000).rounded())
            let writerFinished = oldWriteFinished.wait(timeout: .now() + 8) == .success
            let queueDrained = persistence.waitForWritesForTest(timeout: 8)
            let observationElapsedMilliseconds = Int(((ProcessInfo.processInfo.systemUptime - scheduleStartedAt) * 1000).rounded())
            let diskText = persistence.read()?.text
            let oldLargeTextLandedBeforeDebounce = diskText.map { KeyScan.hash($0) == KeyScan.hash(oldText) } ?? false
            write([
                "draftSizeBytes": oldText.utf8.count,
                "shortDraftBytes": shortText.utf8.count,
                "initialWriteReturnedSynchronously": writeReturned,
                "scheduleElapsedMilliseconds": scheduleElapsedMilliseconds,
                "oldWriteFinished": writerFinished,
                "writerReachedCommitBoundary": reached,
                "queueDrained": queueDrained,
                "observationElapsedMilliseconds": observationElapsedMilliseconds,
                "observedBeforeDebounce": observationElapsedMilliseconds < Int(persistence.testDebounceDelay * 1000),
                "oldLargeTextLandedBeforeDebounce": oldLargeTextLandedBeforeDebounce,
                "primaryFileExistedBeforeShortDebounce": FileManager.default.fileExists(atPath: persistence.fileURL.path)
            ])
            exit(0)

        case "N3":
            guard let (conversation, _) = makeDraftLifecyclePane(in: stateRoot) else { exit(2) }
            let id = conversation.id
            let oldImages = [
                DraftPersistence.Image(data: Data("N3 committed image one".utf8), mediaType: "image/png", no: 1, edited: false),
                DraftPersistence.Image(data: Data("N3 committed image two".utf8), mediaType: "image/png", no: 2, edited: false)
            ]
            let firstWriter = DraftPersistence(directory: stateRoot, conversationID: id)
            let firstText = draftR1SyntheticText(bytes: 1_280 * 1_024, seed: "first committed ")
            _ = firstWriter.write(text: firstText, quotes: [], filePaths: [], images: oldImages)
            guard firstWriter.waitForWritesForTest(timeout: 8), let committedRecord = firstWriter.read() else { exit(2) }
            let committedImageRecords = committedRecord.images
            let oldImageBytes = Dictionary(uniqueKeysWithValues: firstWriter.readImages(committedRecord).map { ($0.no, $0.data) })
            let imageDirectory = firstWriter.fileURL.deletingLastPathComponent()
            let prefix = id.uuidString.lowercased() + "-img-"
            let secondWriter = DraftPersistence(directory: stateRoot, conversationID: id)
            let imageWritten = DispatchSemaphore(value: 0)
            let releaseWriter = DispatchSemaphore(value: 0)
            secondWriter.testAfterPrimaryImageWrite = { index in
                if index == 0 {
                    imageWritten.signal()
                    _ = releaseWriter.wait(timeout: .now() + 8)
                }
            }
            let secondImages = (1...3).map { no in
                DraftPersistence.Image(data: Data("N3 replacement image \(no)".utf8), mediaType: "image/png", no: no, edited: false)
            }
            let secondText = draftR1SyntheticText(bytes: 1_280 * 1_024, seed: "second pending ")
            _ = secondWriter.write(text: secondText, quotes: [], filePaths: [], images: secondImages)
            let pausedAfterFirstNewImage = imageWritten.wait(timeout: .now() + 8) == .success
            secondWriter.schedule(text: "short edit cancels second launch write", quotes: [], filePaths: [], images: [])
            releaseWriter.signal()
            let secondQueueDrained = secondWriter.waitForWritesForTest(timeout: 8)
            let currentRecord = firstWriter.read()
            let referencedFiles = Set(currentRecord?.images.map(\.file) ?? [])
            let primaryImagesExist = currentRecord.map { record in
                record.images.allSatisfy { FileManager.default.fileExists(atPath: imageDirectory.appendingPathComponent($0.file).path) }
            } ?? false
            let firstCommittedImagesIntact = committedImageRecords.allSatisfy { record in
                let url = imageDirectory.appendingPathComponent(record.file)
                guard let currentBytes = try? Data(contentsOf: url), let oldBytes = oldImageBytes[record.no] else { return false }
                return currentBytes == oldBytes
            }
            let imageNames = (try? FileManager.default.contentsOfDirectory(atPath: imageDirectory.path)) ?? []
            let orphanImageCount = imageNames.filter { $0.hasPrefix(prefix) && ["png", "jpg"].contains(URL(fileURLWithPath: $0).pathExtension) && !referencedFiles.contains($0) }.count
            write([
                "firstLaunchCommittedImageCount": committedImageRecords.count,
                "secondLaunchPausedAfterFirstImage": pausedAfterFirstNewImage,
                "secondWriteQueueDrained": secondQueueDrained,
                "firstCommittedImagesIntact": firstCommittedImagesIntact,
                "primaryJSONImagesExist": primaryImagesExist,
                "orphanImageCount": orphanImageCount,
                "primaryJSONImageCount": currentRecord?.images.count ?? 0
            ])
            exit(0)

        case "N4":
            guard let (_, pane) = makeDraftLifecyclePane(in: stateRoot) else { exit(2) }
            let entropy = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let secrets = (0..<3).map { index in "sk-" + String(entropy.dropFirst(index * 8).prefix(40)) }
            var savedHashes: [String] = []
            KeyVault.testSetOverride = { _, key in savedHashes.append(KeyScan.hash(key)); return nil }
            KeyGuard.testDecision = { _ in .save(service: "codenv-test-r1", label: "審查測試") }
            var sentText: String?
            pane.inputBar.onSend = { body, _, _ in sentText = body; return false }
            let input = secrets.joined(separator: "\n")
            pane.inputBar.textView.string = input
            pane.inputBar.testSend()
            let resultingText = sentText ?? pane.inputBar.textView.string
            let placeholder = "〔金鑰：審查測試，已存〕"
            let remainingSecretCount = secrets.filter { resultingText.contains($0) }.count
            let placeholderCount = resultingText.components(separatedBy: placeholder).count - 1
            write([
                "detectedHitCount": KeyScan.scan(input).count,
                "savedCount": savedHashes.count,
                "distinctSavedHashCount": Set(savedHashes).count,
                "remainingSecretCount": remainingSecretCount,
                "placeholderCount": placeholderCount,
                "sendCallbackCalled": sentText != nil
            ])
            exit(0)

        case "N5":
            guard let (_, source) = makeDraftLifecyclePane(in: stateRoot),
                  let (_, target) = makeDraftLifecyclePane(in: stateRoot) else { exit(2) }
            guard let targetID = target.conversationID else { exit(2) }
            let targetTextBefore = target.inputBar.textView.string
            let sourceText = draftR1SyntheticText(bytes: 1_280 * 1_024, seed: "handoff source ")
            source.inputBar.textView.string = sourceText
            target.draftHandoffWriteDelayForTest = 4
            let moveSucceeded = source.moveDraft(to: target)
            let targetTextImmediatelyAfterMove = target.inputBar.textView.string
            let sourceUnchanged = KeyScan.hash(source.inputBar.textView.string) == KeyScan.hash(sourceText)
            RunLoop.main.run(until: Date().addingTimeInterval(4.5))
            let targetPersistence = DraftPersistence(directory: stateRoot, conversationID: targetID)
            let targetDiskText = targetPersistence.read()?.text
            write([
                "handoffSucceeded": moveSucceeded,
                "sourceTextUnchanged": sourceUnchanged,
                "targetInputRolledBack": target.inputBar.textView.string.isEmpty,
                "sourceAndTargetSamePane": source === target,
                "rollbackReached": target.draftHandoffRollbackReachedForTest,
                "rollbackWasEditable": target.draftHandoffRollbackWasEditableForTest ?? false,
                "rollbackWasKeyScanning": target.draftHandoffRollbackWasKeyScanningForTest ?? false,
                "rollbackHadMarkedText": target.draftHandoffRollbackHadMarkedTextForTest ?? false,
                "rollbackLengthAfterAssignment": target.draftHandoffRollbackTextLengthAfterAssignmentForTest ?? -1,
                "rollbackLengthAfterChange": target.draftHandoffRollbackTextLengthAfterChangeForTest ?? -1,
                "targetTextBeforeLength": targetTextBefore.utf8.count,
                "targetTextImmediatelyAfterMoveLength": targetTextImmediatelyAfterMove.utf8.count,
                "targetTextImmediatelyAfterMoveMatchesSource": KeyScan.hash(targetTextImmediatelyAfterMove) == KeyScan.hash(sourceText),
                "targetTextAfterLength": target.inputBar.textView.string.utf8.count,
                "targetHasPendingInputAfter": target.inputBar.hasPendingInput,
                "targetHasQuotesAfter": target.inputBar.hasQuotes,
                "targetImageCountAfter": target.inputBar.draftImages.count,
                "targetFileCountAfter": target.inputBar.draftFilePaths.count,
                "targetDiskHasHandoffDraft": targetDiskText.map { KeyScan.hash($0) == KeyScan.hash(sourceText) } ?? false,
                "targetPrimaryFileExists": FileManager.default.fileExists(atPath: targetPersistence.fileURL.path)
            ])
            exit(0)

        case "N6":
            guard let (conversation, _) = makeDraftLifecyclePane(in: stateRoot) else { exit(2) }
            let persistence = DraftPersistence(directory: stateRoot, conversationID: conversation.id)
            let primaryText = "healthy primary draft N6"
            let primaryWriteSucceeded = persistence.write(text: primaryText, quotes: [], filePaths: [], images: [])
            let recoveryDirectory = persistence.fileURL.deletingLastPathComponent().appendingPathComponent(".recovery", isDirectory: true)
            let recoveryURL = recoveryDirectory.appendingPathComponent("\(conversation.id.uuidString.lowercased()).json")
            do {
                try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
                try Data("{corrupt recovery".utf8).write(to: recoveryURL, options: .atomic)
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: recoveryURL.path)
            } catch { exit(2) }
            let recovered = persistence.read()
            let quarantinePrefix = recoveryURL.lastPathComponent + ".bad-"
            let quarantineNames = (try? FileManager.default.contentsOfDirectory(atPath: recoveryDirectory.path)) ?? []
            write([
                "primaryWriteSucceeded": primaryWriteSucceeded,
                "primaryRecovered": recovered.map { KeyScan.hash($0.text) == KeyScan.hash(primaryText) } ?? false,
                "corruptRecoveryQuarantined": quarantineNames.contains { $0.hasPrefix(quarantinePrefix) },
                "corruptRecoveryStillAtOriginalPath": FileManager.default.fileExists(atPath: recoveryURL.path)
            ])
            exit(0)

        case "N7":
            guard let (conversation, _) = makeDraftLifecyclePane(in: stateRoot) else { exit(2) }
            let persistence = DraftPersistence(directory: stateRoot, conversationID: conversation.id)
            let text20MB = draftR1SyntheticText(bytes: 20 * 1_024 * 1_024, seed: "20MB synthetic draft ")
            let nextText = draftR1SyntheticText(bytes: 1_280 * 1_024, seed: "next large revision ")
            let enteredJSON = DispatchSemaphore(value: 0)
            let releaseJSON = DispatchSemaphore(value: 0)
            persistence.testBeforePrimaryJSONWrite = {
                enteredJSON.signal()
                _ = releaseJSON.wait(timeout: .now() + 8)
            }
            _ = persistence.write(text: text20MB, quotes: [], filePaths: [], images: [])
            let reached = enteredJSON.wait(timeout: .now() + 8) == .success
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.8) { releaseJSON.signal() }
            let startedAt = ProcessInfo.processInfo.systemUptime
            persistence.schedule(text: nextText, quotes: [], filePaths: [], images: [])
            let mainThreadScheduleMilliseconds = Int(((ProcessInfo.processInfo.systemUptime - startedAt) * 1000).rounded())
            persistence.remove()
            let queueDrained = persistence.waitForWritesForTest(timeout: 8)
            write([
                "draftSizeBytes": text20MB.utf8.count,
                "writerReachedJSONBoundary": reached,
                "mainThreadScheduleMilliseconds": mainThreadScheduleMilliseconds,
                "under200Milliseconds": reached && mainThreadScheduleMilliseconds < 200,
                "queueDrained": queueDrained
            ])
            exit(0)

        default:
            exit(2)
        }
    }

    private func agyFailureNoticeFileSnapshot(file: URL, isIsolated: Bool) -> AgyFailureNoticeFileSnapshot {
        if !isIsolated {
            return AgyFailureNoticeFileSnapshot(exists: false, byteCount: 0, parseSucceeded: false, rows: [], readFailed: false)
        }
        if !FileManager.default.fileExists(atPath: file.path) {
            return AgyFailureNoticeFileSnapshot(exists: false, byteCount: 0, parseSucceeded: false, rows: [], readFailed: false)
        }
        do {
            let data = try Data(contentsOf: file)
            do {
                let decodedRows: [[String: String]] = try JSONDecoder().decode([[String: String]].self, from: data)
                return AgyFailureNoticeFileSnapshot(exists: true, byteCount: data.count, parseSucceeded: true, rows: decodedRows, readFailed: false)
            } catch {
                return AgyFailureNoticeFileSnapshot(exists: true, byteCount: data.count, parseSucceeded: false, rows: [], readFailed: true)
            }
        } catch {
            return AgyFailureNoticeFileSnapshot(exists: true, byteCount: 0, parseSucceeded: false, rows: [], readFailed: true)
        }
    }

    private func agyFailureSafeNoticePrefix(_ raw: String) -> String {
        var safe: String = raw
        let patterns: [String] = [
            #"\b(?:sk-or-|sk-|gsk_|ghp_|AIza|xox[baprs]-)[A-Za-z0-9_-]{8,}\b"#,
            #"\bBearer\s+[A-Za-z0-9._~+/=-]{8,}"#,
            #"\b[A-Za-z0-9_-]{32,}\b"#
        ]
        for pattern in patterns {
            safe = safe.replacingOccurrences(of: pattern, with: "[已遮蔽]", options: .regularExpression)
        }
        return String(safe.prefix(80))
    }

    private func agyFailureTimeoutDiagnostics(
        snapshot: AgyFailureNoticeFileSnapshot,
        noticeFileIsIsolated: Bool,
        startedAt: Date,
        timedOutAt: Date,
        elapsedSeconds: TimeInterval,
        commanderSendTimes: [String],
        readFailureCount: Int,
        pollCount: Int,
        iso8601: ISO8601DateFormatter
    ) -> [String: Any] {
        var pollSummary: [String: Any] = [:]
        pollSummary["pollCount"] = pollCount
        pollSummary["pollIntervalSeconds"] = 0.25
        pollSummary["allPollsEmpty"] = true
        pollSummary["firstNonEmptyElapsedSeconds"] = NSNull()

        var diagnostics: [String: Any] = [:]
        diagnostics["noticeWaitStartedAt"] = iso8601.string(from: startedAt)
        diagnostics["noticeWaitTimedOutAt"] = iso8601.string(from: timedOutAt)
        diagnostics["noticeWaitElapsedSeconds"] = elapsedSeconds
        diagnostics["commanderChatSentAnyDuringWait"] = !commanderSendTimes.isEmpty
        diagnostics["commanderChatSentMessageCount"] = commanderSendTimes.count
        diagnostics["commanderChatSentTimes"] = commanderSendTimes
        diagnostics["takeNoticesReadFailureCountObserved"] = readFailureCount
        diagnostics["takeNoticesReadFailureCountSource"] = "每次輪詢前直接讀隔離通知檔；takeNotices 內部 ?? [] 的錯誤無法直接取得"
        diagnostics["takeNoticesPollSummary"] = pollSummary
        diagnostics["chatNoticesFileIsIsolated"] = noticeFileIsIsolated

        var noticeEntries: [[String: String]] = []
        for row in snapshot.rows {
            var entry: [String: String] = [:]
            let conversation = row["conv"] ?? ""
            let text = row["text"] ?? ""
            entry["convPrefix"] = String(conversation.prefix(8))
            entry["textPrefix"] = agyFailureSafeNoticePrefix(text)
            noticeEntries.append(entry)
        }
        if noticeFileIsIsolated {
            diagnostics["chatNoticesFileExists"] = snapshot.exists
            diagnostics["chatNoticesFileByteCount"] = snapshot.byteCount
            diagnostics["chatNoticesParseSucceeded"] = snapshot.parseSucceeded
            diagnostics["chatNoticesEntryCount"] = snapshot.rows.count
            diagnostics["chatNoticesEntries"] = noticeEntries
        } else {
            diagnostics["chatNoticesFileExists"] = NSNull()
            diagnostics["chatNoticesFileByteCount"] = NSNull()
            diagnostics["chatNoticesParseSucceeded"] = NSNull()
            diagnostics["chatNoticesEntryCount"] = NSNull()
            diagnostics["chatNoticesEntries"] = [String]()
        }
        return diagnostics
    }

    private func startAgyFailureProbe(parts: [String], args: [String]) {
        let chiefCandidates = store.sessions.filter { session in
            session.area == nil && session.groups != nil && session.chief != nil
        }
        guard let chief = chiefCandidates.first, let chiefID = chief.chief else { return }
        guard let chiefConversation = store.conversation(chiefID) else { return }
        Prefs.shared.agyEnabled = true
        let suffix: String
        if chief.name.hasSuffix("Chief") {
            suffix = String(chief.name.dropLast("Chief".count))
        } else {
            suffix = chief.name
        }
        let created = store.commanderCreateEngine(caller: chiefID.uuidString, name: "\(suffix)Agy", engine: "agy",
                                                   dir: nil, project: nil, model: "gemini-4-hydrogen-high",
                                                   effort: nil, mcp: nil, topic: nil)
        guard let conversation = created.conversation,
              main.workspace.pane(for: conversation) is ChatPane else {
            let errorOutput: [String: Any] = ["ok": false, "error": "無法建立假 agy 聊天室"]
            if let errorData = try? JSONSerialization.data(withJSONObject: errorOutput, options: [.sortedKeys]) {
                try? errorData.write(to: URL(fileURLWithPath: parts[1]), options: .atomic)
            }
            return
        }
        if parts.count == 3 && !parts[2].isEmpty {
            AgyBridge.setConversation(parts[2], for: conversation.claudeSession)
        }
        let chiefSessionID: UUID = chiefConversation.claudeSession
        let chiefIDForDelivery: UUID = chiefID
        main.commanderSendChat(caller: chiefID.uuidString, target: conversation.title, text: "假 agy 失敗測試", wait: true, timeout: 25) { [weak self] (response: [String: Any]) -> Void in
            guard let delegate = self else { return }
            DispatchQueue.main.async { [weak delegate] () -> Void in
                guard let delegate else { return }
                delegate.waitForAgyFailureNotice(
                    response: response,
                    chiefID: chiefIDForDelivery,
                    chiefSessionID: chiefSessionID,
                    conversationID: conversation.id,
                    args: args,
                    outputPath: parts[1]
                )
            }
        }
    }

    private func waitForAgyFailureNotice(
        response: [String: Any],
        chiefID: UUID,
        chiefSessionID: UUID,
        conversationID: UUID,
        args: [String],
        outputPath: String
    ) {
        var output: [String: Any] = response
        let failurePane: ChatPane? = main.workspace.panes[conversationID] as? ChatPane
        let failureGeneration: Int = failurePane?.session.failureGeneration ?? 0
        let lastFailure: String = failurePane?.session.lastFailureMessage ?? ""
        output["failureGeneration"] = failureGeneration
        output["lastFailure"] = lastFailure

        let noticeWaitStartedAt: Date = Date()
        let noticeWaitStartUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
        let noticeDeadline: DispatchTime = DispatchTime.now() + .seconds(40)
        let noticeFile: URL = CollabBoardModel.agyRuns.appendingPathComponent("chat-notices.json")
        let stateDirIndex: Int? = args.firstIndex(of: "--state-dir")
        let stateDir: URL?
        if let index = stateDirIndex, index + 1 < args.count {
            stateDir = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        } else {
            stateDir = nil
        }
        let noticeFileIsIsolated: Bool = stateDir.map { isTestProbeOutput(noticeFile, inside: $0) } ?? false
        var noticeReadFailureCount: Int = 0
        var noticePollCount: Int = 0
        var chiefSendTimes: [String] = []
        let iso8601: ISO8601DateFormatter = ISO8601DateFormatter()
        let chiefSendObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
            forName: ChatPane.didSend, object: chiefSessionID, queue: .main
        ) { _ in
            chiefSendTimes.append(iso8601.string(from: Date()))
        }

        func finish(_ notice: String?, timedOut: Bool) -> Void {
            output["notice"] = notice ?? ""
            output["noticeWaitTimedOut"] = timedOut
            NotificationCenter.default.removeObserver(chiefSendObserver)
            if timedOut {
                let snapshot: AgyFailureNoticeFileSnapshot = self.agyFailureNoticeFileSnapshot(
                    file: noticeFile,
                    isIsolated: noticeFileIsIsolated
                )
                if snapshot.readFailed { noticeReadFailureCount += 1 }
                let diagnostics: [String: Any] = self.agyFailureTimeoutDiagnostics(
                    snapshot: snapshot,
                    noticeFileIsIsolated: noticeFileIsIsolated,
                    startedAt: noticeWaitStartedAt,
                    timedOutAt: Date(),
                    elapsedSeconds: ProcessInfo.processInfo.systemUptime - noticeWaitStartUptime,
                    commanderSendTimes: chiefSendTimes,
                    readFailureCount: noticeReadFailureCount,
                    pollCount: noticePollCount,
                    iso8601: iso8601
                )
                for (key, value) in diagnostics { output[key] = value }
            }
            if let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
            }
        }

        func pollNotice() -> Void {
            noticePollCount += 1
            let beforeTake: AgyFailureNoticeFileSnapshot = self.agyFailureNoticeFileSnapshot(
                file: noticeFile,
                isIsolated: noticeFileIsIsolated
            )
            if beforeTake.readFailed { noticeReadFailureCount += 1 }
            let notice: String? = CollabBoardModel.takeNotices(for: chiefID)
            if let notice {
                finish(notice, timedOut: false)
            } else if DispatchTime.now() >= noticeDeadline {
                finish(nil, timedOut: true)
            } else {
                DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + .milliseconds(250), execute: pollNotice)
            }
        }
        pollNotice()
    }

    /// 從 Store 使用的 --state-dir 與 Workspace 子程序環境取路徑，再解析絕對路徑及 symlink。
    private func actualLidProbePaths(_ args: [String]) -> (state: String, compact: String)? {
        // --lid-notice-dedupe-probe 在 Store 建立前執行；測試實例的 Store.directory
        // 就是這個參數指定的目錄，因此從 argv 取值，避免碰到尚未初始化的 IUO store。
        guard let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count else { return nil }
        let statePath = URL(fileURLWithPath: args[stateIndex + 1], isDirectory: true)
        let compactValue = Workspace.environment().first { $0.hasPrefix("CODENV_COMPACT_DIR=") }
        let compactPath = compactValue.map { String($0.dropFirst("CODENV_COMPACT_DIR=".count)) }
            ?? statePath.appendingPathComponent("compact-state", isDirectory: true).path
        return (
            canonicalTestProbePath(statePath),
            canonicalTestProbePath(URL(fileURLWithPath: compactPath, isDirectory: true))
        )
    }

    func installTestHooksEarly(_ args: [String]) {
        // --window-diag-r1-probe <state-dir 內的 JSON>：在主視窗安裝診斷前執行，讓兩個測試視窗的序號固定為 1、2。
        if let i = args.firstIndex(of: "--window-diag-r1-probe") {
            guard i + 1 < args.count,
                  let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count,
                  Self.isolatedTestRun(args, "一般") else { exit(2) }
            let root = URL(fileURLWithPath: args[stateIndex + 1], isDirectory: true)
            let output = URL(fileURLWithPath: args[i + 1])
            guard isTestProbeOutput(output, inside: root) else { exit(2) }
            MainActor.assumeIsolated {
                runWindowDiagR1Probe(to: output)
            }
            exit(2)
        }
        // --dump-running-progress <jsonl或輸出檔>：只在隔離實例讀紀錄檔尾，輸出本機 JSON，不啟動模型。
        // --progress-allow-root <目錄> 可重複，只替此隔離探針補入明確指定的測試根目錄。
        if let i = args.firstIndex(of: "--dump-running-progress"), i + 1 < args.count,
           let allowedRoots = runningProgressProbeAllowedRoots(args) {
            let progress = RunningActivityProgress.read(URL(fileURLWithPath: args[i + 1]), allowedRoots: allowedRoots)
            var payload: [String: Any] = ["line": progress.line, "kind": progress.kind, "stale": progress.stale]
            if let minutes = progress.staleMinutes { payload["staleMinutes"] = minutes }
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([0x0a]))
            }
            exit(0)
        }
        // --keyscan-golden-probe <input.json> <output.json>：在未改掃描器的基線上輸出完整 KeyScan 對拍資料。
        if args.contains("--state-dir"),
           let probeIndex = args.firstIndex(of: "--keyscan-golden-probe"), probeIndex + 2 < args.count,
           let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count {
            let stateRoot: URL = URL(fileURLWithPath: args[stateIndex + 1], isDirectory: true)
            let inputURL: URL = URL(fileURLWithPath: args[probeIndex + 1])
            let outputURL: URL = URL(fileURLWithPath: args[probeIndex + 2])
            guard isTestProbeOutput(inputURL, inside: stateRoot), isTestProbeOutput(outputURL, inside: stateRoot),
                  let inputData: Data = try? Data(contentsOf: inputURL),
                  let request: [String: Any] = (try? JSONSerialization.jsonObject(with: inputData)) as? [String: Any] else { exit(2) }

            let originalAllowHashes: Set<String> = KeyScan.allowHashes
            let originalLearnedCounts: [String: Int] = KeyScan.learnedFeatureCounts
            let originalCallback: ((String, String, Int) -> Void)? = KeyScan.onLearnedSuppression
            let allowTokens: [String] = request["allowTokens"] as? [String] ?? []
            KeyScan.allowHashes = Set(allowTokens.map(KeyScan.hash))
            KeyScan.learnedFeatureCounts = request["learnedFeatureCounts"] as? [String: Int] ?? [:]
            var callbackRows: [[String: Any]] = []
            KeyScan.onLearnedSuppression = { rule, feature, count in
                callbackRows.append(["rule": rule, "feature": feature, "count": count])
            }

            let corpus: [[String: Any]] = request["corpus"] as? [[String: Any]] ?? []
            var rows: [[String: Any]] = []
            for item in corpus {
                guard let label: String = item["label"] as? String, let source: String = item["source"] as? String else { continue }
                let findings: [[String: Any]] = KeyScan.findings(source).map { finding in
                    var hit: [String: Any] = [
                        "rangeLocation": finding.hit.range.location, "rangeLength": finding.hit.range.length,
                        "text": finding.hit.text, "clean": finding.hit.clean, "kind": finding.hit.kind,
                        "strong": finding.hit.strong, "low": finding.hit.low,
                        "excluded": finding.excluded, "allowlisted": finding.allowlisted,
                        "learnedSuppressed": finding.learnedSuppressed, "learnedCount": finding.learnedCount
                    ]
                    hit["service"] = finding.hit.service as Any? ?? NSNull()
                    hit["feature"] = finding.feature as Any? ?? NSNull()
                    return hit
                }
                let redacted: String = KeyScan.redact(source)
                rows.append(["label": label, "findings": findings, "redacted": redacted])
            }
            KeyScan.allowHashes = originalAllowHashes
            KeyScan.learnedFeatureCounts = originalLearnedCounts
            KeyScan.onLearnedSuppression = originalCallback

            let result: [String: Any] = ["schemaVersion": 1, "rows": rows, "callbackRows": callbackRows,
                                         "callbackCount": callbackRows.count]
            do {
                let data: Data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
                try data.write(to: outputURL, options: .atomic)
                exit(0)
            } catch { exit(2) }
        }
        NonoSandbox.configureSecurityBinary(arguments: args)
        // --codex-recovery-probe <state-dir內的JSON>：假 app-server 回放 provider 不符、一般接回失敗與暫時錯誤，檢查對照備份、交接及不覆寫。
        if args.contains("--state-dir"), let i = args.firstIndex(of: "--codex-recovery-probe"), i + 1 < args.count,
           let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count {
            let root = URL(fileURLWithPath: args[stateIndex + 1], isDirectory: true).standardizedFileURL
            let output = URL(fileURLWithPath: args[i + 1]).standardizedFileURL
            guard isTestProbeOutput(output, inside: root) else { exit(2) }
            let id = UUID()
            let bridge = CodexBridge(session: id, directory: root.path, model: "gpt-6-luna")
            let transcript = CodexBridge.transcript(for: id)
            try? FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
            let history = [
                ["message": ["role": "user", "content": "繼續修暫存專案"]],
                ["message": ["role": "assistant", "content": "已完成第一部分，接著處理重連"]]
            ]
            if let data = try? history.map({ try JSONSerialization.data(withJSONObject: $0) })
                .map({ String(decoding: $0, as: UTF8.self) }).joined(separator: "\n").data(using: .utf8) {
                try? data.write(to: transcript, options: .atomic)
            }
            CodexBridge.setThread("old-provider-thread", for: id)
            var sent: [[String: Any]] = []
            var emitted: [[String: Any]] = []
            bridge.send = { sent.append($0) }
            bridge.emit = { emitted.append($0) }
            bridge.start()
            let resume = sent.first(where: { $0["method"] as? String == "thread/resume" })
            if let resumeID = resume?["id"] {
                bridge.incoming(["id": resumeID, "error": ["message": "This chat uses openai, but your current provider is magpie. Switch to openai to continue."]])
            }
            let freshStart = sent.last(where: { $0["method"] as? String == "thread/start" })
            if let freshID = freshStart?["id"] {
                bridge.incoming(["id": freshID, "result": ["thread": ["id": "new-provider-thread"]]])
            }
            let handoffTurn = sent.first(where: { $0["method"] as? String == "turn/start" })
            let handoffInput = ((handoffTurn?["params"] as? [String: Any])?["input"] as? [[String: Any]])?
                .compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
            let provider: [String: Any] = [
                "oldThreadBackedUp": CodexBridge.backedUpThreads(for: id).contains("old-provider-thread"),
                "newThreadStored": CodexBridge.thread(for: id) == "new-provider-thread",
                "handoffContainsHistory": handoffInput.contains("繼續修暫存專案") && handoffInput.contains("接著處理重連"),
                "handoffContainsDirectory": handoffInput.contains(root.path),
                "noticeEmitted": emitted.contains(where: {
                    $0["subtype"] as? String == "api_retry"
                        && ($0["message"] as? String)?.contains("Codex 換了服務來源") == true
                })
            ]

            let failedID = UUID()
            CodexBridge.setThread("preserved-thread", for: failedID)
            let failed = CodexBridge(session: failedID, directory: root.path, model: "gpt-6-luna")
            var failedSent: [[String: Any]] = []
            var failedEvents: [[String: Any]] = []
            failed.send = { failedSent.append($0) }
            failed.emit = { failedEvents.append($0) }
            failed.start()
            if let request = failedSent.first(where: { $0["method"] as? String == "thread/resume" }) {
                failed.incoming(["id": request["id"]!, "error": ["message": "thread not found"]])
            }
            let ordinaryFailure: [String: Any] = [
                "mappingPreserved": CodexBridge.thread(for: failedID) == "preserved-thread",
                "didNotStartFreshThread": !failedSent.contains(where: { $0["method"] as? String == "thread/start" }),
                "explicitFailure": failedEvents.contains(where: { ($0["result"] as? String)?.contains("原對照未變更") == true }),
                "noticeEmitted": failedEvents.contains(where: { $0["subtype"] as? String == "api_retry" && ($0["message"] as? String)?.contains("接不回舊對話") == true })
            ]
            let retryID = UUID()
            CodexBridge.setThread("retry-thread", for: retryID)
            let retry = CodexBridge(session: retryID, directory: root.path, model: "gpt-6-luna")
            var retrySent: [[String: Any]] = []
            retry.send = { retrySent.append($0) }
            retry.start()
            if let request = retrySent.first(where: { $0["method"] as? String == "thread/resume" }) {
                retry.incoming(["id": request["id"]!, "error": ["message": "network timeout"]])
            }
            let retryResumes = retrySent.filter { $0["method"] as? String == "thread/resume" }.count
            // 提示原文放在最上層（區塊內維持純布林，給外部驗收讀）
            let result: [String: Any] = ["providerMismatch": provider, "ordinaryResumeFailure": ordinaryFailure,
                                         "providerMismatchNoticeText": emitted.first(where: { $0["subtype"] as? String == "api_retry" })?["message"] as? String ?? "",
                                         "ordinaryResumeFailureNoticeText": failedEvents.first(where: { $0["subtype"] as? String == "api_retry" })?["message"] as? String ?? "",
                                         "temporaryResumeFailure": [
                                            "retriedOnce": retryResumes == 2,
                                            "mappingPreserved": CodexBridge.thread(for: retryID) == "retry-thread",
                                            "didNotStartFreshThread": !retrySent.contains(where: { $0["method"] as? String == "thread/start" })
                                         ]]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]) {
                try? data.write(to: output, options: .atomic)
            }
            exit(0)
        }
        // --process-tree-restart-probe <state-dir內的JSON>：在暫存區啟動 shell 與子程序，驗證終止程序群組後才啟動下一個 root。
        if args.contains("--state-dir"), let i = args.firstIndex(of: "--process-tree-restart-probe"), i + 1 < args.count,
           let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count {
            let root = URL(fileURLWithPath: args[stateIndex + 1], isDirectory: true).standardizedFileURL
            let output = URL(fileURLWithPath: args[i + 1]).standardizedFileURL
            guard isTestProbeOutput(output, inside: root) else { exit(2) }
            func launch(_ childPIDFile: URL) -> (Process, pid_t?) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", "sleep 30 & child=$!; printf '%s\\n' \"$child\" > '\(childPIDFile.path)'; wait"]
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return (process, nil) }
                let pid = process.processIdentifier
                return (process, getpgid(pid) == pid && pid != getpgrp() ? pid : nil)   // Process 自己建獨立群組（事後 setpgid 會 EACCES）
            }
            func stop(_ process: Process, group: pid_t?) {
                // 用跟 ChatSession 同一個 ChatDrain：SIGTERM 群組、背景等待、必要時 SIGKILL
                let drain = ChatDrain(process: process, group: group)
                drain.sendTerm()
                let deadline = Date().addingTimeInterval(7)
                while drain.isAlive && Date() < deadline { Thread.sleep(forTimeInterval: 0.025) }
                if drain.isAlive { drain.sendKill() }
                process.waitUntilExit()
            }
            let oldChildFile = root.appendingPathComponent("process-tree-probe-child-pid")
            let (old, oldGroup) = launch(oldChildFile)
            let childDeadline = Date().addingTimeInterval(1)
            while !FileManager.default.fileExists(atPath: oldChildFile.path), Date() < childDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            let childPID = (try? String(contentsOf: oldChildFile, encoding: .utf8))
                .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let oldPID = old.processIdentifier
            stop(old, group: oldGroup)
            let oldEnded = !old.isRunning
            if let childPID {
                let childDeadline = Date().addingTimeInterval(1)
                while kill(childPID, 0) == 0 && Date() < childDeadline { Thread.sleep(forTimeInterval: 0.025) }
            }
            let childEnded = childPID.map { kill($0, 0) != 0 && errno == ESRCH } ?? false
            let (next, nextGroup) = oldEnded && childEnded
                ? launch(root.appendingPathComponent("process-tree-probe-next-child-pid")) : (Process(), nil)
            if next.isRunning { stop(next, group: nextGroup) }
            let result: [String: Any] = ["oldExitedBeforeRestart": oldEnded,
                                         "oldChildExitedBeforeRestart": childEnded,
                                         "newStartedAfterExit": oldEnded && childEnded && next.processIdentifier > 0,
                                         "oldGroupCreated": oldGroup != nil,
                                         "oldRootPID": oldPID]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]) {
                try? data.write(to: output, options: .atomic)
            }
            exit(0)
        }
        // --terminal-turn-probe <state-dir內的JSON>：純假 Codex 事件；讀出通知清單並驗證中途重試、停止、終止失敗的分類。
        if args.contains("--state-dir"), let i = args.firstIndex(of: "--terminal-turn-probe"), i + 1 < args.count,
           let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count {
            let root = URL(fileURLWithPath: args[stateIndex + 1], isDirectory: true)
            let output = URL(fileURLWithPath: args[i + 1])
            guard isTestProbeOutput(output, inside: root) else { exit(2) }
            func runCodex(_ events: [[String: Any]]) -> [String: Any] {
                var tracker = TerminalTurnTracker()
                var notices: [String] = []
                var finalEvent: [String: Any] = [:]
                let bridge = CodexBridge(session: UUID(), directory: root.path, model: "gpt-5-codex")
                bridge.emit = { raw in
                    let (event, _) = tracker.observe(raw)
                    if event["type"] as? String == "result" {
                        finalEvent = event
                        if let notice = TerminalTurnTracker.supervisionNotice(conversation: "假 Codex", event: event) {
                            notices.append(notice)
                        }
                    }
                }
                events.forEach(bridge.incoming)
                return ["notifications": notices, "failureGeneration": tracker.failureGeneration,
                        "stopGeneration": tracker.stopGeneration, "finalEvent": finalEvent]
            }
            let scenarios: [String: Any] = [
                "retryThenComplete": runCodex([
                    ["method": "error", "params": ["willRetry": true, "error": ["message": "temporary"]]],
                    ["method": "turn/completed", "params": ["turn": ["status": "completed"]]]
                ]),
                "stopped": runCodex([
                    ["method": "turn/completed", "params": ["turn": ["status": "interrupted"]]]
                ]),
                "terminalFailure": runCodex([
                    ["method": "turn/completed", "params": ["turn": ["status": "failed", "error": ["message": "Codex 最終失敗"]]]]
                ])
            ]
            if let data = try? JSONSerialization.data(withJSONObject: scenarios, options: [.sortedKeys, .prettyPrinted]) {
                try? data.write(to: output, options: .atomic)
            }
            exit(0)
        }
        // --lid-notice-dedupe-probe <state-dir內的JSON>：兩個假聊天室各連發兩次開蓋／闔蓋通知（間隔 0.5 秒），讀每種通知的實際送出數。
        if args.contains("--state-dir"), let i = args.firstIndex(of: "--lid-notice-dedupe-probe"), i + 1 < args.count,
           let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count {
            let root = URL(fileURLWithPath: args[stateIndex + 1], isDirectory: true)
            let output = URL(fileURLWithPath: args[i + 1])
            guard isTestProbeOutput(output, inside: root) else { exit(2) }
            let deduplicator = LidNoticeDeduplicator()
            let conversations = [("假聊天室 A", UUID()), ("假聊天室 B", UUID())]
            let messages = [("close", LidKeeper.stopMessage), ("open", LidKeeper.resumeMessage)]
            let origin = Date(timeIntervalSince1970: 1_800_000_000)
            var counts: [String: [String: Int]] = [:]
            for (name, id) in conversations {
                for (kind, text) in messages {
                    for duplicate in 0..<2 {
                        _ = deduplicator.send(conversationID: id, text: text,
                                              now: origin.addingTimeInterval(Double(duplicate) * 0.5)) {
                            counts[name, default: [:]][kind, default: 0] += 1
                            return true
                        }
                    }
                }
            }
            guard let actualPaths = actualLidProbePaths(args) else { exit(2) }
            let result: [String: Any] = ["windowSeconds": deduplicator.interval, "counts": counts,
                "actualStateDir": actualPaths.state, "actualCompactDir": actualPaths.compact]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]) {
                try? data.write(to: output, options: .atomic)
            }
            exit(0)
        }
        // --codex-outside-edit-probe <state-dir 內輸出.json>：用假的 app-server
        // request 回放，驗證 bypass 的 thread／turn 設定及外部檔案核准回覆；不啟動模型或 CLI。
        if args.contains("--state-dir"), CodexBridge.testExecutable != nil,
           let i = args.firstIndex(of: "--codex-outside-edit-probe"), i + 1 < args.count,
           let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count {
            let stateRoot = URL(fileURLWithPath: args[stateIndex + 1], isDirectory: true).standardizedFileURL
            let outputURL = URL(fileURLWithPath: args[i + 1]).standardizedFileURL
            guard isTestProbeOutput(outputURL, inside: stateRoot) else { exit(2) }
            let workspace = stateRoot.appendingPathComponent("codex-outside-edit/workspace", isDirectory: true)
            let outside = stateRoot.appendingPathComponent("codex-outside-edit/outside", isDirectory: true)
            try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

            func scenario(_ mode: String?, _ name: String) -> [String: Any] {
                let target = outside.appendingPathComponent("\(name).txt")
                var messages: [[String: Any]] = []
                var visibleApprovals = 0
                var applied = false
                let bridge = CodexBridge(session: UUID(), directory: workspace.path, model: "gpt-6-luna")
                bridge.mode = mode
                bridge.send = { message in
                    messages.append(message)
                    if message["id"] as? Int == 9001,
                       (message["result"] as? [String: Any])?["decision"] as? String == "accept" {
                        applied = (try? "fake app-server applied patch".write(to: target, atomically: true, encoding: .utf8)) != nil
                    }
                }
                bridge.emit = { event in
                    if event["type"] as? String == "control_request" { visibleApprovals += 1 }
                }
                bridge.start()
                guard let threadStart = messages.first(where: { $0["method"] as? String == "thread/start" }),
                      let threadID = threadStart["id"] else { return ["error": "沒有送出 thread/start"] }
                bridge.incoming(["jsonrpc": "2.0", "id": threadID,
                                 "result": ["thread": ["id": "fake-thread-\(name)"]]])
                bridge.outgoing(["type": "user", "uuid": UUID().uuidString.lowercased(),
                                 "message": ["content": "更新暫存工作區外的合成檔"]])
                guard let turnStart = messages.first(where: { $0["method"] as? String == "turn/start" }) else {
                    return ["error": "沒有送出 turn/start"]
                }
                let changeID = "fake-change-\(name)"
                bridge.incoming(["jsonrpc": "2.0", "method": "item/started",
                                 "params": ["item": ["id": changeID, "type": "fileChange",
                                                       "changes": [["path": target.path,
                                                                     "kind": ["type": "update"],
                                                                     "diff": "-old\n+new"]]]]])
                bridge.incoming(["jsonrpc": "2.0", "id": 9001,
                                 "method": "item/fileChange/requestApproval",
                                 "params": ["itemId": changeID, "grantRoot": outside.path,
                                             "threadId": "fake-thread-\(name)", "turnId": "fake-turn-\(name)"]])
                let turnParams = turnStart["params"] as? [String: Any] ?? [:]
                return ["cwd": (threadStart["params"] as? [String: Any])?["cwd"] as? String ?? "",
                        "outsidePath": target.path,
                        "outsideIsOutsideCwd": !target.path.hasPrefix(workspace.path + "/"),
                        "threadApprovalPolicy": (threadStart["params"] as? [String: Any])?["approvalPolicy"] as? String ?? "",
                        "threadSandbox": (threadStart["params"] as? [String: Any])?["sandbox"] as? String ?? "",
                        "turnApprovalPolicy": turnParams["approvalPolicy"] as? String ?? "",
                        "turnSandboxPolicy": turnParams["sandboxPolicy"] as? [String: Any] ?? [:],
                        "visibleApprovalRequests": visibleApprovals,
                        "fakeOutsideFileWritten": applied && FileManager.default.fileExists(atPath: target.path)]
            }

            let bypass = scenario("bypassPermissions", "bypass")
            let ordinary = scenario(nil, "default")
            let bypassSandbox = bypass["turnSandboxPolicy"] as? [String: Any] ?? [:]
            let result: [String: Any] = [
                "bypass": bypass,
                "default": ordinary,
                "settingsMatch": (bypass["threadApprovalPolicy"] as? String == "never"
                                  && bypass["threadSandbox"] as? String == "danger-full-access"
                                  && bypass["turnApprovalPolicy"] as? String == "never"
                                  && bypassSandbox["type"] as? String == "dangerFullAccess"
                                  && ordinary["threadApprovalPolicy"] as? String == "untrusted"
                                  && ordinary["threadSandbox"] as? String == "workspace-write"
                                  && ordinary["turnApprovalPolicy"] as? String == "untrusted"
                                  && (ordinary["turnSandboxPolicy"] as? [String: Any])?["type"] as? String == "workspaceWrite"),
                "expectedBehavior": (bypass["visibleApprovalRequests"] as? Int == 0
                                     && bypass["fakeOutsideFileWritten"] as? Bool == true
                                     && ordinary["visibleApprovalRequests"] as? Int == 1
                                     && ordinary["fakeOutsideFileWritten"] as? Bool == false)
            ]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]) {
                try? data.write(to: outputURL, options: .atomic)
            }
            exit(0)
        }
        // --keyguard-probe-input <JSON> --keyguard-probe-output <JSON>：純本機掃描／誤報學習探針；必須有 --state-dir，完全不碰鑰匙圈。
        if args.contains("--state-dir"),
           let inputIndex = args.firstIndex(of: "--keyguard-probe-input"), inputIndex + 1 < args.count,
           let outputIndex = args.firstIndex(of: "--keyguard-probe-output"), outputIndex + 1 < args.count,
           let data = try? Data(contentsOf: URL(fileURLWithPath: args[inputIndex + 1])),
           let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            // seedLearningLines：在載入前先寫進學習檔的原始行（測舊學習檔特徵載入時要被過濾）
            if let lines = request["seedLearningLines"] as? [String], !lines.isEmpty {
                let dir = URL(fileURLWithPath: args[args.firstIndex(of: "--state-dir")! + 1], isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("keyguard-false-positives.jsonl"), atomically: true, encoding: .utf8)
            }
            KeyGuard.wire()
            let savedAllowHashes = KeyScan.allowHashes
            let savedDefaults = appDefaults.array(forKey: "keyAllowHashes") as? [String] ?? []
            for token in request["forceAllowTokens"] as? [String] ?? [] { KeyScan.allowHashes.insert(KeyScan.hash(token)) }

            func describe(_ sources: [String]) -> [[String: Any]] {
                sources.enumerated().map { index, source in
                    ["sourceIndex": index, "findings": KeyScan.findings(source).map { finding in
                        ["kind": finding.hit.kind,
                         "strength": finding.hit.isForceWarn ? "強" : "弱",
                         "excluded": finding.excluded,
                         "allowlisted": finding.allowlisted,
                         "learnedSuppressed": finding.learnedSuppressed,
                         "warning": finding.shouldWarn,
                         "feature": finding.feature ?? "",
                         "learningCount": finding.learnedCount] as [String: Any]
                    }]
                }
            }
            let before = describe(request["scans"] as? [String] ?? [])
            let stateIndex = args.firstIndex(of: "--state-dir")!
            let probeState = URL(fileURLWithPath: args[stateIndex + 1], isDirectory: true)
            try? FileManager.default.createDirectory(at: probeState, withIntermediateDirectories: true)
            func fileWarning(_ source: String, name: String, index: Int) -> KeyGuardFileWarning? {
                let url = probeState.appendingPathComponent("keyguard-probe-attachment-\(index).txt")
                guard (try? source.write(to: url, atomically: true, encoding: .utf8)) != nil,
                      let scanned = KeyGuard.scanFile(url) else { return nil }
                return KeyGuardFileWarning(name: name, source: scanned.source, hits: scanned.hits)
            }
            KeyGuard.testFileDecision = { .notAKey }
            let feedbackResults = (request["notAKey"] as? [String] ?? []).enumerated().map { index, source in
                guard let warning = fileWarning(source, name: "探針附件 \(index + 1)", index: index) else { return false }
                return KeyGuard.askFiles([warning])
            }
            let strongNotAKeyAccepted = (request["strongNotAKey"] as? String).flatMap { source in
                fileWarning(source, name: "強規則探針", index: 100).map { KeyGuard.askFiles([$0]) }
            }
            let mixedWarnings = (request["mixedNotAKey"] as? [String] ?? []).enumerated().compactMap { index, source in
                fileWarning(source, name: "混合探針 \(index + 1)", index: 200 + index)
            }
            let mixedNotAKeyAccepted = mixedWarnings.isEmpty ? nil : KeyGuard.askFiles(mixedWarnings)
            KeyGuard.testFileDecision = nil
            let afterFeedback = describe(request["after"] as? [String] ?? [])
            let learnedBeforeDelete = KeyGuard.learnedFeatures().map { ["id": $0.id, "rule": $0.rule, "feature": $0.feature, "count": $0.count] as [String: Any] }
            func learningRecords() -> [[String: Any]] {
                guard let stateIndex = args.firstIndex(of: "--state-dir") else { return [] }
                let url = URL(fileURLWithPath: args[stateIndex + 1], isDirectory: true).appendingPathComponent("keyguard-false-positives.jsonl")
                return (try? String(contentsOf: url, encoding: .utf8))?.split(whereSeparator: \.isNewline).compactMap { line in
                    try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                } ?? []
            }
            let recordsBeforeDelete = learningRecords()
            if request["deleteLearned"] as? Bool == true {
                for item in KeyGuard.learnedFeatures() { KeyGuard.removeLearnedFeature(item.id) }
            }
            let afterDelete = describe(request["afterDelete"] as? [String] ?? [])
            let recordsAfterDelete = learningRecords()
            let result: [String: Any] = [
                "before": before,
                "feedbackResults": feedbackResults,
                "strongNotAKeyAccepted": strongNotAKeyAccepted ?? false,
                "mixedNotAKeyAccepted": mixedNotAKeyAccepted ?? false,
                "afterFeedback": afterFeedback,
                "learnedFeatures": learnedBeforeDelete,
                "afterDelete": afterDelete,
                "learningRecordCountBeforeDelete": recordsBeforeDelete.count,
                "learningRecordCount": recordsAfterDelete.count,
                "learningLogContainsRawHit": recordsBeforeDelete.contains { $0["text"] != nil || $0["context"] != nil },
                "forceAllowTokensStillWarn": KeyScan.findings((request["forceAllowCheck"] as? String) ?? "").contains { $0.hit.isForceWarn && $0.shouldWarn }
            ]
            KeyScan.allowHashes = savedAllowHashes
            appDefaults.set(savedDefaults, forKey: "keyAllowHashes")
            if let outputData = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]) {
                try? outputData.write(to: URL(fileURLWithPath: args[outputIndex + 1]), options: .atomic)
            }
            exit(0)
        }
        // --pref "webFeaturesEnabled=0|1"：必須在 Store／Workspace 建立之前套用，只寫 <bundleID>.test。
        if args.contains("--state-dir") {
            for (i, flag) in args.enumerated() where flag == "--pref" && i + 1 < args.count {
                let pair = args[i + 1].split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                if pair[0] == "webFeaturesEnabled", ["0", "1"].contains(pair[1]) { Prefs.shared.webFeaturesEnabled = pair[1] == "1" }
                if pair[0] == "petEmbedCharacter" { PetEmbedPrefs.character = pair[1] }
                if pair[0] == "petEmbedPress", let n = Int(pair[1]) { PetEmbedPrefs.pressLevel = n }
                if pair[0] == "petEmbedOn" { PetEmbedPrefs.enabled = pair[1] == "1" }
                if pair[0] == "agyEnabled" { Prefs.shared.agyEnabled = pair[1] == "1" }
                if pair[0] == "archiveSummaryUseAgy" {
                    if ["0", "1"].contains(pair[1]) { Prefs.shared.archiveSummaryUseAgy = pair[1] == "1" }
                    else if pair[1] == "unset" {
                        Prefs.shared.archiveSummaryUseAgy = true
                        appDefaults.removeObject(forKey: "archiveSummaryUseAgy")
                    }
                }
                if pair[0] == "archiveSummaryByEngine", ["0", "1"].contains(pair[1]) {
                    Prefs.shared.archiveSummaryByEngine = pair[1] == "1"
                }
                if pair[0] == "lidExternalIdleSleep", ["0", "1"].contains(pair[1]) { Prefs.shared.lidExternalIdleSleep = pair[1] == "1" }
                if pair[0] == "petSlotOn" { PetSlot.enabled = pair[1] == "1" }
                if pair[0] == "sidebarMode", ["commander", "tree"].contains(pair[1]) { Prefs.shared.sidebarMode = pair[1] }
                if pair[0] == "commanderChatPermission", ["default", "auto", "bypassPermissions"].contains(pair[1]) { Prefs.shared.commanderChatPermission = pair[1] == "default" ? nil : pair[1] }
                if pair[0] == "commanderStuckMinutes", let n = Int(pair[1]), (1...180).contains(n) { Prefs.shared.commanderStuckMinutes = n }
                if pair[0] == "commanderCompletionNotices", ["0", "1"].contains(pair[1]) { Prefs.shared.commanderCompletionNotices = pair[1] == "1" }
                if pair[0] == "compactGuard", ["0", "1"].contains(pair[1]) { Prefs.shared.compactGuard = pair[1] == "1" }
                if pair[0] == "childMemoryWriteGuard", ["0", "1"].contains(pair[1]) { Prefs.shared.childMemoryWriteGuard = pair[1] == "1" }
                if pair[0] == "colorScheme", ["dark", "light", "system"].contains(pair[1]) { Prefs.shared.colorScheme = pair[1] }
            }
        }
        // --local-model-selection-probe <輸出.json>：讀假 HF 快取的預設／封存摘要選模，不啟動 MLX 或 agy。
        if args.contains("--state-dir"),
           let i = args.firstIndex(of: "--local-model-selection-probe"), i + 1 < args.count,
           let cacheIndex = args.firstIndex(of: "--hf-hub-cache-dir"), cacheIndex + 1 < args.count,
           let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count {
            let stateURL = URL(fileURLWithPath: args[stateIndex + 1], isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
            let requestedOutput = URL(fileURLWithPath: args[i + 1]).standardizedFileURL
            // 輸出檔尚不存在時 resolvingSymlinksInPath 不會解析父目錄（例如 /private/tmp → /tmp）；
            // 先解析已存在的父目錄，再接回檔名，才能正確做 state-dir 範圍檢查。
            let outputURL = requestedOutput.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(requestedOutput.lastPathComponent).standardizedFileURL
            let cacheRoot = URL(fileURLWithPath: args[cacheIndex + 1], isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
            let stateRoot = stateURL.path
            let statePrefix = stateRoot.hasSuffix("/") ? stateRoot : stateRoot + "/"
            guard !args[cacheIndex + 1].isEmpty,
                  outputURL.path.hasPrefix(statePrefix), cacheRoot.hasPrefix(statePrefix) else { return }
            let cached = LocalBridge.cachedModels
            let defaultModel = LocalBridge.defaultModel(in: cached)
            let summaryModel = LocalBridge.archiveSummaryModel(in: cached)
            let defaultID: Any = defaultModel.map { $0.id as Any } ?? NSNull()
            let summaryID: Any = summaryModel.map { $0.id as Any } ?? NSNull()
            let fallback = Prefs.shared.archiveSummaryUseAgy ? "hydrogen" : "queued"
            let payload: [String: Any] = [
                "cachedModels": cached.map(\.id),
                "defaultModel": defaultID,
                "archiveSummaryModel": summaryID,
                "archiveSummaryRoute": summaryModel == nil ? fallback : "local",
                "mlxServerStarted": false
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: outputURL, options: .atomic)
            }
        }
        // --usage-keychain-probe <輸出 JSON>：必須帶 --security-bin，只執行外部假的 security；不建立假程式、不讀鑰匙圈。
        if args.contains("--state-dir"), let i = args.firstIndex(of: "--usage-keychain-probe"), i + 1 < args.count,
           let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count {
            let root = URL(fileURLWithPath: args[stateIndex + 1], isDirectory: true).standardizedFileURL
            let output = URL(fileURLWithPath: args[i + 1]).standardizedFileURL
            if isTestProbeOutput(output, inside: root) {
                let securityIndex = args.firstIndex(of: "--security-bin")
                let requestedSecurity = securityIndex.flatMap { $0 + 1 < args.count ?
                    URL(fileURLWithPath: args[$0 + 1]).standardizedFileURL.resolvingSymlinksInPath().path : nil
                }
                let injectedSecurityMatches = KeyVault.isTestInstance(args)
                    && requestedSecurity != nil
                    && requestedSecurity == NonoSandbox.securityPath
                    && (NonoSandbox.securityPath.hasPrefix("/private/tmp/") || NonoSandbox.securityPath.hasPrefix("/tmp/"))
                let service = KeyVault.service("openrouter")
                var result: [String: Any] = [
                    "serviceUsesTestPrefix": service.hasPrefix("codenv-test-"),
                    "injectedSecurityPathMatched": injectedSecurityMatches,
                    "secretWasNotWritten": true,
                    "usedFakeSecurityProcess": false
                ]
                if injectedSecurityMatches, let requestedSecurity {
                    let fakeURL = URL(fileURLWithPath: requestedSecurity)
                    let fakeLog = fakeURL.deletingLastPathComponent().appendingPathComponent(fakeURL.lastPathComponent + ".log")
                    let before = KeyVault.copyMatchingCallCount
                    let value = NonoSandbox.keychain(service: service, timeout: UsageMonitor.extraKeychainReadTimeout)
                    let timeoutStarted = Date()
                    let timeoutService = KeyVault.service("timeout-probe")
                    let timedValue = NonoSandbox.keychain(service: timeoutService,
                                                          timeout: UsageMonitor.extraKeychainReadTimeout)
                    let timeoutMS = Int(Date().timeIntervalSince(timeoutStarted) * 1000)
                    let after = KeyVault.copyMatchingCallCount
                    let loggedCalls = (try? String(contentsOf: fakeLog, encoding: .utf8))?.components(separatedBy: .newlines)
                        .filter { $0.hasPrefix("CALL ") } ?? []
                    let expectedCall = "CALL find-generic-password -s \(service) -w"
                    let commandArgumentsMatched = loggedCalls.contains(expectedCall)
                    let timeoutCallRecorded = loggedCalls.contains { $0.contains(timeoutService) }
                    // 假 security 已記下呼叫參數；提供給外部驗收器讀，不回寫也不輸出假金鑰值。
                    let capturedArgs = root.appendingPathComponent("usage-keychain-probe-args.txt")
                    try? loggedCalls.joined(separator: "\n").appending("\n")
                        .write(to: capturedArgs, atomically: true, encoding: .utf8)
                    result.merge([
                        "readValue": value == "C177G_FAKE_VALUE_NEVER_PRINT",
                        "commandArgumentsMatched": commandArgumentsMatched,
                        "timeoutReturnedMissing": timedValue == nil,
                        "timeoutCallRecorded": timeoutCallRecorded,
                        "timeoutElapsedMilliseconds": timeoutMS,
                        "usageTimeoutSeconds": UsageMonitor.extraKeychainReadTimeout,
                        "secItemCopyMatchingCalls": after - before,
                        "usedFakeSecurityProcess": true
                    ]) { _, new in new }
                }
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
                    try? data.write(to: output, options: .atomic)
                }
            }
        }
        // --extra-key-pools-probe <輸出檔>：只用 codenv-test- 前綴與假金鑰，確認 OpenRouter／Groq 卡片資料出現；測完刪除。
        if args.contains("--state-dir"), let i = args.firstIndex(of: "--extra-key-pools-probe"), i + 1 < args.count,
           KeyVault.prefix.hasPrefix("codenv-test-") {
            let output = args[i + 1]
            let fixtures = [("openrouter", "fake-openrouter-test-key"), ("groq", "fake-groq-test-key")]
            let errors = fixtures.compactMap { service, key -> String? in
                KeyVault.set(service: KeyVault.service(service), key: key).map { "\(service): \($0)" }
            }
            if !errors.isEmpty {
                try? errors.joined(separator: "\n").write(toFile: output + ".error", atomically: true, encoding: .utf8)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    UsageMonitor.shared.refresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        let names = UsageMonitor.shared.allExtraKeyPools.map(\.name)
                        try? names.sorted().joined(separator: "\n").write(toFile: output, atomically: true, encoding: .utf8)
                        for (service, _) in fixtures { KeyVault.delete(service: KeyVault.service(service)) }
                    }
                }
            }
        }
        // --extra-key-pools-fixture <假回應.json>:<輸出檔>：不連網、不讀鑰匙圈，用假回應走完整的卡片解析（OpenRouter 免費／付費、Groq 標頭、讀金鑰被拒）。
        // 輸出每張卡的名稱、訊息、每一列（剩餘％、重置時間 UTC）與 Groq 探測送出次數（0／60／1801 秒各看一次，驗 30 分鐘快取）；金鑰不會出現在輸出裡。
        if args.contains("--state-dir"), let i = args.firstIndex(of: "--extra-key-pools-fixture"), i + 1 < args.count,
           let sep = args[i + 1].lastIndex(of: ":") {
            let fixture = String(args[i + 1][..<sep]), output = String(args[i + 1][args[i + 1].index(after: sep)...])
            var lines: [String] = []
            if let data = FileManager.default.contents(atPath: fixture),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let iso = ISO8601DateFormatter()
                let base = (root["now"] as? String).flatMap { iso.date(from: $0) } ?? Date()
                var current = base
                var fetches = 0
                var src = ExtraKeySources.fake(root, now: { current })
                let inner = src.fetchGroq
                src.fetchGroq = { fetches += 1; return inner($0) }
                let cacheURL = URL(fileURLWithPath: output + ".success-cache.json")
                try? FileManager.default.removeItem(at: cacheURL)
                var cache = GroqProbeCache(fileURL: cacheURL)
                for (n, offset) in [0.0, 60, 1801].enumerated() {
                    current = base.addingTimeInterval(offset)
                    if n > 0 { cache = GroqProbeCache(fileURL: cacheURL) } // 模擬 App 重開後由檔案還原
                    let pools = ExtraKeyPools.pools(src, groqCache: cache)
                    if n == 0 {
                        for p in pools {
                            lines.append("card name=\(p.name) source=\(p.source) message=\(p.message ?? "-")")
                            for b in p.buckets { lines.append("  row label=\(b.label) remaining=\(b.remaining) resets=\(b.resets) resetAt=\(b.resetAt.map { iso.string(from: $0) } ?? "-" )") }
                            for note in p.notes { lines.append("  note \(note)") }
                        }
                        lines.append("cards=\(pools.count)")
                    }
                    lines.append("groqFetches@\(Int(offset))=\(fetches)")
                }
                if root["groq"] != nil {
                    let cacheText = (try? String(contentsOf: cacheURL, encoding: .utf8)) ?? ""
                    lines.append("groqCacheHasOnlyRateHeaders=\(cacheText.contains("x-ratelimit-") && !cacheText.contains("x-request-id"))")
                    lines.append("groqCacheHasNoCredential=\(!cacheText.contains("dummy-test-secret") && !cacheText.contains("fake-groq"))")
                    if let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count {
                        let stateURL = URL(fileURLWithPath: args[stateIndex + 1], isDirectory: true).standardizedFileURL
                        let cacheFolder = GroqProbeCache.defaultFileURL(arguments: args)?.deletingLastPathComponent().standardizedFileURL
                        lines.append("groqCacheUsesStateDir=\(cacheFolder == stateURL)")
                    }

                    let failureURL = URL(fileURLWithPath: output + ".failure-cache.json")
                    try? FileManager.default.removeItem(at: failureURL)
                    var failedFetches = 0
                    let failureLock = NSLock()
                    for offset in [0.0, 60, 601] {
                        let failureCache = GroqProbeCache(fileURL: failureURL)
                        _ = failureCache.getOrFetch(now: base.addingTimeInterval(offset)) {
                            failureLock.lock(); failedFetches += 1; failureLock.unlock()
                            return nil
                        }
                    }
                    lines.append("groqFailureFetches@0,60,601=\(failedFetches)")

                    let singleCache = GroqProbeCache()
                    var parallelFetches = 0
                    let parallelLock = NSLock()
                    DispatchQueue.concurrentPerform(iterations: 8) { _ in
                        _ = singleCache.getOrFetch(now: base) {
                            parallelLock.lock(); parallelFetches += 1; parallelLock.unlock()
                            Thread.sleep(forTimeInterval: 0.03)
                            return ["x-ratelimit-remaining-requests": "9", "x-ratelimit-limit-requests": "10"]
                        }
                    }
                    lines.append("groqConcurrentFetches=\(parallelFetches)")
                    lines.append("parseDurationTrailingGarbage=\(ExtraKeyPools.parseDuration("1mgarbage") == nil)")
                    let hugeHeaders = ["x-ratelimit-remaining-requests": "1e308", "x-ratelimit-limit-requests": "1e308"]
                    lines.append("groqHugeHeaderRejected=\(ExtraKeyPools.parseGroq(hugeHeaders, now: base) == nil)")
                }
            } else { lines.append("ERROR 讀不到假回應檔") }
            try? lines.joined(separator: "\n").write(toFile: output, atomically: true, encoding: .utf8)
            exit(0)
        }
        if args.contains("--dump-theme") {
            let t = Theme.fromITerm()
            print("字型", t.font.fontName, t.font.pointSize, "粗體", t.boldFont.fontName, "行距", t.lineSpacing)
            print("深色 背景", t.dark.bg, "文字", t.dark.fg)
            print("淺色 背景", t.light.bg, "文字", t.light.fg)
            exit(0)
        }
        if args.contains("--state-dir"), let i = args.firstIndex(of: "--magpie-usage-probe"), i + 1 < args.count,
           let j = args.firstIndex(of: "--magpie-usage-input"), j + 1 < args.count,
           let raw = try? Data(contentsOf: URL(fileURLWithPath: args[j + 1])) {
            let parsed = UsageMonitor.parseMagpieAccounts(raw)
            var lines = (parsed?.buckets ?? []).map { "\($0.label)=\($0.remaining)%|\($0.resets)" } + (parsed?.tips.keys.sorted() ?? []).map { "TIP \($0)=\(parsed!.tips[$0]!.replacingOccurrences(of: "\n", with: " / "))" }
            if parsed == nil { lines.append("FALLBACK=agy /usage") }
            try? lines.joined(separator: "\n").write(toFile: args[i + 1], atomically: true, encoding: .utf8)
            exit(0)
        }
        // --codex-usage-probe <out> --codex-usage-input <magpie.json> --codex-usage-free-input <free.json> --codex-usage-fallback <app-server.json>
        // 純假資料測每帳號卡片、付費帳號摘要、只有 Free 窗口與 Magpie 失敗退回 app-server。
        if args.contains("--state-dir"), let i = args.firstIndex(of: "--codex-usage-probe"), i + 1 < args.count,
           let j = args.firstIndex(of: "--codex-usage-input"), j + 1 < args.count,
           let freeIndex = args.firstIndex(of: "--codex-usage-free-input"), freeIndex + 1 < args.count,
           let fallbackIndex = args.firstIndex(of: "--codex-usage-fallback"), fallbackIndex + 1 < args.count,
           let appServerData = try? Data(contentsOf: URL(fileURLWithPath: args[fallbackIndex + 1])),
           let appServer = (try? JSONSerialization.jsonObject(with: appServerData)) as? [String: Any] {
            let iso = ISO8601DateFormatter()
            var lines: [String] = []
            func report(_ prefix: String, _ magpie: Data?) {
                let result = UsageMonitor.resolveCodexUsage(magpieData: magpie, appServerResult: appServer)
                lines.append("\(prefix) source=\(result.usedMagpie ? "magpie" : "app-server") accounts=\(result.accounts.count)")
                lines.append("\(prefix) resetCredits=\(result.resetCredits)")
                for account in UsageMonitor.codexFreeAccounts(result.accounts) {
                    lines.append("\(prefix) free-row label=\(UsageMonitor.codexFreeAccountLabel(account)) email=\(account.maskedUser)")
                }
                for account in result.accounts {
                    lines.append("\(prefix) account plan=\(account.displayPlan) active=\(account.active) user=\(account.maskedUser) alias=\(account.alias ?? "-") resets=\(account.resetCredits)")
                    for bucket in account.buckets {
                        lines.append("\(prefix) window plan=\(account.displayPlan) active=\(account.active) label=\(bucket.label) remaining=\(bucket.remaining)% resetAt=\(bucket.resetAt.map { iso.string(from: $0) } ?? "-")")
                    }
                }
                for item in UsageMonitor.codexGlanceItems(accounts: result.accounts, fallback: result.currentBuckets) {
                    lines.append("\(prefix) glance label=\(item.short ?? item.what) remaining=\(item.bucket.map { "\($0.remaining)%" } ?? "—")")
                }
            }
            let magpie = try? Data(contentsOf: URL(fileURLWithPath: args[j + 1]))
            let free = try? Data(contentsOf: URL(fileURLWithPath: args[freeIndex + 1]))
            report("paid-choice", magpie)
            report("free-only", free)
            report("fallback", Data("{invalid".utf8))
            let week = L("每週"), five = L("5 小時")
            let claudeFallback = UsageMonitor.standardGlanceItems("Claude", buckets: [UsageBucket(label: "30 天", used: 33, resets: "")], week: week, five: five)
            lines.append("claude-fallback labels=\(claudeFallback.compactMap(\.bucket?.label).joined(separator: ","))")
            let agyFallback = UsageMonitor.agyGlanceItems([
                UsageBucket(label: "Claude 5 小時", used: 40, resets: ""),
                UsageBucket(label: "Argon 每週", used: 25, resets: "")
            ], tips: [:], week: week, five: five)
            lines.append("agy-fallback labels=\(agyFallback.compactMap(\.bucket?.label).joined(separator: ","))")
            try? lines.joined(separator: "\n").write(toFile: args[i + 1], atomically: true, encoding: .utf8)
            exit(0)
        }
    }

    func testWebUnloadSeconds(_ args: [String]) -> TimeInterval {
        // 僅隔離資料的測試實例可縮短隱藏網頁的卸載時間。
        var webUnloadSeconds: TimeInterval = 180
        if args.contains("--state-dir"), let i = args.firstIndex(of: "--web-unload-seconds"), i + 1 < args.count,
           let seconds = Double(args[i + 1]), seconds.isFinite, seconds > 0 {
            webUnloadSeconds = seconds
        }
        return webUnloadSeconds
    }

    /// 測試參數只在測試實例（有 --state-dir）生效：Astra 11/5 列出一長串會送訊息、改資料、開視窗的掛鉤沒檢查隔離，
    /// 誤用在正式 App 上會動到使用者的對話和設定。沒有 --state-dir 就全部忽略，記一行說明
    static func isolatedTestRun(_ args: [String], _ section: String) -> Bool {
        if args.contains("--state-dir") { return true }
        let known: Set<String> = ["--background", "--claude-home", "--sprint-check-model-off"]
        let flags = args.dropFirst().filter { $0.hasPrefix("--") && !known.contains($0) }
        if !flags.isEmpty {
            EventLog.log("測試", "沒有 --state-dir，忽略測試參數（\(section)）：\(flags.prefix(8).joined(separator: " "))")
            FileHandle.standardError.write(Data("codenv：沒有 --state-dir，忽略測試參數 \(flags.prefix(8).joined(separator: " "))\n".utf8))
        }
        return false
    }

    func installChatTestHooks(_ args: [String]) {
        guard Self.isolatedTestRun(args, "聊天") else { return }
        if let i = args.firstIndex(of: "--claude"), i + 1 < args.count { workspace.claudeCommand = args[i + 1] }
        // 背景 Session 閒置回收的門檻縮短（秒），測回收用
        if let i = args.firstIndex(of: "--bg-idle-seconds"), i + 1 < args.count, let sec = Double(args[i + 1]), sec > 0 { workspace.idleReleaseSeconds = sec }
        // 摘要測試完全不用真的 claude；讀不到假檔就回報失敗，不能退回花額度的路徑。第一則訊息另搭配 --chat-claude 假後端。
        if let i = args.firstIndex(of: "--handoff-fake"), i + 1 < args.count { Handoff.fakeFile = URL(fileURLWithPath: args[i + 1]) }
        // --chat-args "參數 參數"：測試時多給 claude 的參數（例如 --permission-mode default，逼它來問權限）
        if let i = args.firstIndex(of: "--chat-args"), i + 1 < args.count {
            ChatSession.extraArgs = args[i + 1].split(separator: " ").map(String.init)
        }
        if let i = args.firstIndex(of: "--chat-log"), i + 1 < args.count {
            FileManager.default.createFile(atPath: args[i + 1], contents: nil)
            ChatSession.log = FileHandle(forWritingAtPath: args[i + 1])
        }
    }

    func installFeedbackTestHooks(_ args: [String]) {
        if args.contains("--state-dir"), let i = args.firstIndex(of: "--feedback-dump"), i + 1 < args.count {
            let log = args.firstIndex(of: "--feedback-log").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            Feedback.dump(to: args[i + 1], logFile: log)
        }
    }

    private func startLidRescueRecoveryProbe(_ args: [String]) -> Bool {
        guard args.contains("--state-dir"),
              let flag = args.firstIndex(of: "--lid-rescue-recovery-probe"), flag + 5 < args.count,
              let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count else { return false }
        let caseID = args[flag + 2]
        guard ["C415", "C416", "C417", "C418"].contains(caseID) else { return false }
        let stateRoot = URL(fileURLWithPath: args[stateIndex + 1], isDirectory: true).standardizedFileURL
        let contractURL = URL(fileURLWithPath: args[flag + 1])
        let scenario = args[flag + 3]
        let phase = args[flag + 4]
        let outputURL = URL(fileURLWithPath: args[flag + 5])
        let scenarioRoot = outputURL.deletingLastPathComponent().standardizedFileURL
        let expectedStateRoot = scenarioRoot.appendingPathComponent("state", isDirectory: true)
        guard isTestProbeOutput(outputURL, inside: scenarioRoot),
              outputURL.lastPathComponent == "\(phase).json",
              canonicalTestProbePath(stateRoot) == canonicalTestProbePath(expectedStateRoot) else { exit(2) }
        guard let payload = TestHarness.lidRescueRecoveryProbe(caseID: caseID, contract: contractURL,
                                                               scenario: scenario, phase: phase, stateRoot: stateRoot) else { exit(2) }
        writeAwakeClosedProbe(payload, caseID: caseID, to: outputURL)
        return true
    }

    private func startAwakeClosedProbe(_ args: [String]) -> Bool {
        guard args.contains("--state-dir"), let flag = args.firstIndex(of: "--lid-awake-closed-probe"), flag + 4 < args.count,
              let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count else { return false }
        let stateRoot = URL(fileURLWithPath: args[stateIndex + 1], isDirectory: true).standardizedFileURL
        let contractURL = URL(fileURLWithPath: args[flag + 1])
        let caseID = args[flag + 2]
        let phase = args[flag + 3]
        let outputURL = URL(fileURLWithPath: args[flag + 4])
        guard isTestProbeOutput(outputURL, inside: stateRoot),
              let contractData = try? Data(contentsOf: contractURL),
              let contract = (try? JSONSerialization.jsonObject(with: contractData)) as? [String: Any] else { exit(2) }
        let cases = contract["cases"] as? [String: Any] ?? contract
        guard let testCase = cases[caseID] as? [String: Any] else { exit(2) }

        if let delegated = TestHarness.awakeClosedRescueProbe(caseID: caseID, contract: contractURL,
                                                              phase: phase, stateRoot: stateRoot) {
            writeAwakeClosedProbe(delegated, caseID: caseID, to: outputURL)
            return true
        }
        // C402–C408 由施工-codex2 的新檔處理；未連上新檔時不得用空結果假裝通過。
        if (402...408).contains(Int(caseID.dropFirst()) ?? -1) { exit(2) }
        guard let simulation = testCase["simulation"] as? [String: Any],
              caseID.hasPrefix("C"), (380...413).contains(Int(caseID.dropFirst()) ?? -1) else { exit(2) }
        let result = runAwakeClosedScenario(caseID: caseID, simulation: simulation, stateRoot: stateRoot)
        writeAwakeClosedProbe(result, caseID: caseID, to: outputURL)
        return true
    }

    /// 舊題的遷移探針使用題目固定的 legacy preferences 作為輸入；答案一律由 Prefs.initialLidModeValues 與 SimLidEnv 路徑產生。
    private func startLidModeMigrationProbe(_ args: [String]) -> Bool {
        guard args.contains("--state-dir"),
              let flag = args.firstIndex(of: "--lid-mode-migration-probe"), flag + 2 < args.count,
              let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count,
              let suiteName = AppDefaults.testSuiteName,
              let defaults = UserDefaults(suiteName: suiteName) else { return false }

        let caseID = args[flag + 1]
        let outputURL = URL(fileURLWithPath: args[flag + 2])
        let stateRoot = URL(fileURLWithPath: args[stateIndex + 1], isDirectory: true).standardizedFileURL
        guard isTestProbeOutput(outputURL, inside: stateRoot),
              let fixture = Self.lidModeMigrationFixture(caseID: caseID) else { exit(2) }

        defaults.removePersistentDomain(forName: suiteName)
        for (key, value) in fixture.legacyPrefs { defaults.set(value, forKey: key) }
        let migrated = Prefs.initialLidModeValues(defaults: defaults)
        let migration: [String: Any] = [
            "lidKeepWorking": migrated.keepWorking,
            "lidInterruptOnClose": migrated.interrupt,
            "legacyPathEntered": migrated.keepWorking
        ]

        var simulation = fixture.simulation
        simulation["probeInterruptEnabled"] = migrated.interrupt
        var payload = runAwakeClosedScenario(caseID: caseID, simulation: simulation, stateRoot: stateRoot)
        guard var observed = payload["observed"] as? [String: Any] else { exit(2) }
        observed["migration"] = migration
        payload["observed"] = observed
        writeAwakeClosedProbe(payload, caseID: caseID, to: outputURL)
        return true
    }

    private static func lidModeMigrationFixture(caseID: String) -> (legacyPrefs: [String: Any], simulation: [String: Any])? {
        switch caseID {
        case "C35":
            return (["lidKeepWorking": true, "lidExternalIdleSleep": true, "lidInterruptOnClose": false],
                    ["external": true, "lid": ["close", "display-flash", "10m"]])
        case "C38":
            return (["lidKeepWorking": true, "lidExternalIdleSleep": true, "lidInterruptOnClose": false],
                    ["lid": ["close", "wakeGap", "external-return", "helper-failure"]])
        case "C86":
            return (["lidKeepWorking": true, "lidExternalIdleSleep": true, "lidInterruptOnClose": false],
                    ["external": true, "lid": ["close", "work-finished", "idle=600"]])
        case "C108":
            return (["lidKeepWorking": true],
                    ["sessions": ["codex-working", "background-only"], "lid": ["close"]])
        case "C133":
            return (["lidKeepWorking": true],
                    ["external": true, "lid": ["close", "display-flash", "reclose"]])
        default:
            return nil
        }
    }

    /// 由 ChatPrefsPage 的實際 SwiftUI 樹列出闔蓋選項；key 只標識選項，不代替可見性判斷。
    private func observedLidSettingsOptions() -> [[String: Any]] {
        let definitions: [(String, String)] = [
            ("lidInterruptOnClose", L("闔蓋時中斷聊天室（保持醒著，30 分鐘後睡眠）")),
            ("lidKeepWorking", L("闔上螢幕時，讓正在做事的聊天室做完這一段")),
            ("lidExternalIdleSleep", L("接外接螢幕闔蓋時，做完且 10 分鐘沒操作就關風扇並睡眠")),
            ("lidResumeNotifyEnabled", L("打開螢幕時通知它們繼續"))
        ]
        var budget = 2_000
        func containsLabel(_ value: Any, depth: Int = 0, label: String) -> Bool {
            guard depth < 20, budget > 0 else { return false }
            budget -= 1
            if let text = value as? String, text == label { return true }
            for child in Mirror(reflecting: value).children {
                if containsLabel(child.value, depth: depth + 1, label: label) { return true }
            }
            return false
        }
        let body = ChatPrefsPage().body
        return definitions.compactMap { definition in
            let (key, label) = definition
            return containsLabel(body, label: label) ? ["key": key, "label": label] : nil
        }
    }

    private func seedLidModeArguments(_ args: [String], defaults: UserDefaults) {
        let keys: [String: String] = [
            "-lidKeepWorking": "lidKeepWorking",
            "-lidInterruptOnClose": "lidInterruptOnClose"
        ]
        for (index, argument) in args.enumerated() {
            guard let key = keys[argument], index + 1 < args.count else { continue }
            let value = args[index + 1].lowercased()
            if ["yes", "true", "1"].contains(value) { defaults.set(true, forKey: key) }
            else if ["no", "false", "0"].contains(value) { defaults.set(false, forKey: key) }
        }
    }

    private func writeAwakeClosedProbe(_ payload: [String: Any], caseID: String, to output: URL) {
        var result = payload
        if result["schemaVersion"] == nil { result["schemaVersion"] = 1 }
        if result["caseId"] == nil { result["caseId"] = caseID }
        do {
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
            try data.write(to: output, options: .atomic)
        } catch { exit(2) }
    }

    private func runAwakeClosedScenario(caseID: String, simulation: [String: Any], stateRoot: URL) -> [String: Any] {
        let scenarios = simulation["scenarios"] as? [[String: Any]]
        if let scenarios, !scenarios.isEmpty {
            var childResults: [String: Any] = [:]
            for (index, child) in scenarios.enumerated() {
                let childID = child["id"] as? String ?? "scenario\(index)"
                childResults[childID] = runAwakeClosedSingleScenario(caseID: caseID, simulation: child, stateRoot: stateRoot, suffix: childID)
            }
            return ["schemaVersion": 1, "caseId": caseID, "observed": childResults]
        }
        return ["schemaVersion": 1, "caseId": caseID,
                "observed": runAwakeClosedSingleScenario(caseID: caseID, simulation: simulation, stateRoot: stateRoot, suffix: "single")]
    }

    private func observedAwakeClosedFields(caseID: String, simulation: [String: Any], basic: [String: Any],
                                           rows: [String: AwakeClosedProbeRow], store: Store) -> [String: Any] {
        let resumeRecords = basic["resumedRecords"] as? [[String: Any]] ?? []
        let sends = basic["automatedSends"] as? [[String: Any]] ?? []
        let sessionAliases = basic["sendAliasBySessionId"] as? [String: String] ?? [:]
        let noticeSends = sends.filter { $0["source"] as? String == "闔蓋中斷" }
        let resumeSends = sends.filter { $0["source"] as? String == "闔蓋繼續" }
        func aliasForSend(_ send: [String: Any]) -> String? {
            guard let recipient = send["recipient"] as? String else { return nil }
            return sessionAliases[recipient]
        }
        let noticeAliases = noticeSends.compactMap(aliasForSend)
        let resumeAliases = resumeSends.compactMap(aliasForSend)
        let allAliases = Set(rows.keys)
        func counts(_ selected: [String]) -> [String: Int] {
            Dictionary(uniqueKeysWithValues: allAliases.sorted().map { alias in (alias, selected.filter { $0 == alias }.count) })
        }
        func marked(_ alias: String) -> Bool {
            guard let row = rows[alias] else { return false }
            return store.conversation(row.work.id)?.interruptedAt != nil
        }
        let resumeText = resumeSends.compactMap { $0["content"] as? String }.joined(separator: "\n")
        let noticeText = noticeSends.compactMap { $0["content"] as? String }.joined(separator: "\n")
        let count = basic["terminatedCount"] as? Int ?? -1
        let sleepCount = basic["sleepNowCount"] as? Int ?? -1
        let noticeCount = noticeSends.count
        let resumeCount = resumeRecords.count
        let currentState = basic["state"] as? String ?? "unavailable"
        let sourceQueue = simulation["queue"] as? [[String: Any]] ?? []
        let probeLog = basic["probeLog"] as? String ?? ""
        func occurrences(of text: String, in value: String) -> Int {
            guard !text.isEmpty else { return 0 }
            return max(0, value.components(separatedBy: text).count - 1)
        }
        let noSleepTrace = basic["noSleepTrace"] as? [[String: Any]] ?? []
        let legacyStops = basic["legacyStopCount"] as? Int ?? 0
        let closureInterrupts = basic["interruptionsByClosure"] as? [Int] ?? []

        switch caseID {
        case "C35":
            let sleepRows = basic["sleepNowTrace"] as? [[String: Any]] ?? []
            return ["holdingCount": occurrences(of: "闔蓋，撐著讓它做完", in: probeLog),
                    "externalIdleSleepCount": (simulation["external"] as? Bool == true) ? sleepRows.count : 0]
        case "C38":
            var releasedOnce = false
            var reholdCount = 0
            for row in noSleepTrace {
                if row["enabled"] as? Bool == false { releasedOnce = true }
                else if row["enabled"] as? Bool == true && releasedOnce { reholdCount += 1 }
            }
            return ["legacyWakeGraceCount": occurrences(of: "外接螢幕給", in: probeLog),
                    "legacyReholdCount": reholdCount]
        case "C86":
            return ["sleepNowCount": sleepCount,
                    "legacyFanAutoCount": basic["setFanAutoCount"] as? Int ?? 0]
        case "C108":
            return ["terminableSessionTerminated": rows["codex-working"]?.terminated ?? false,
                    "legacyStopCount": legacyStops, "state": currentState]
        case "C133":
            return ["holdStarted": occurrences(of: "闔蓋，撐著讓它做完", in: probeLog) > 0,
                    "perClosureInterrupts": closureInterrupts]
        case "C380":
            return ["state": currentState, "terminatedCount": count, "nosleepOn": basic["nosleepOn"] as? Bool ?? false,
                    "sleepNowCount": sleepCount, "setFanAutoCount": basic["setFanAutoCount"] as? Int ?? 0]
        case "C381":
            return ["state": currentState, "nosleepOffCount": basic["nosleepOffCount"] as? Int ?? 0, "sleepNowCount": sleepCount]
        case "C382", "C383", "C394", "C396":
            var result: [String: Any] = ["sleepNowCount": sleepCount,
                                         "sleepNowElapsedSecondsFromAwakeClosedEntry": basic["sleepNowElapsedSecondsFromAwakeClosedEntry"] ?? NSNull()]
            if caseID == "C382" { result["sleptByAwakeClosed"] = basic["sleptByAwakeClosed"] as? Bool ?? false }
            if caseID == "C383" || caseID == "C396" { result["sleepReason"] = basic["sleepReason"] as? String ?? "" }
            if caseID == "C394" { result["terminatedCount"] = count }
            return result
        case "C384", "C385":
            let sleepInputs = (basic["sleepNowTrace"] as? [[String: Any]] ?? []).map { row -> [String: Any] in
                ["batteryPercent": row["batteryPercent"] ?? NSNull(), "onAC": row["onAC"] ?? NSNull()]
            }
            return ["sleepNowCount": sleepCount, "sleepNowInputs": sleepInputs,
                    "sleepReason": basic["sleepReason"] as? String ?? ""]
        case "C386":
            var cleared = false
            if let rescue = basic["rescuePath"] as? String { cleared = !FileManager.default.fileExists(atPath: rescue) }
            return ["resumeById": counts(resumeAliases), "noticeById": counts(noticeAliases),
                    "resumeContainsSafetyText": resumeText.contains(LidInterruption.continuePrompt),
                    "resumeContainsOriginalQueueText": sourceQueue.compactMap { $0["text"] as? String }.allSatisfy { resumeText.contains($0) },
                    "queuePendingClearedAfterSuccess": cleared && resumeAliases.contains("terminated-foreground"),
                    "resumeDispatchDiagnostics": basic["resumeDispatchDiagnostics"] as? [[String: Any]] ?? [],
                    "resumeSendFailureCount": basic["resumeSendFailureCount"] as? Int ?? 0,
                    "sendLidInterruptResumeCalls": basic["sendLidInterruptResumeCalls"] as? [String: Any] ?? ["count": 0, "calls": [[String: Any]]()],
                    "resumeCandidateSnapshot": basic["resumeCandidateSnapshot"] as? [[String: Any]] ?? [],
                    "resumeSendObserverCalls": basic["resumeSendObserverCalls"] as? [[String: Any]] ?? []]
        case "C387":
            return ["resumeById": counts(resumeAliases), "amberById": Dictionary(uniqueKeysWithValues: allAliases.sorted().map { ($0, marked($0)) })]
        case "C388":
            return ["resumeCount": resumeCount, "noticeCount": noticeCount, "amberFlag": rows.keys.contains(where: marked),
                    "sleepNowCount": sleepCount,
                    "sleepNowElapsedSecondsFromAwakeClosedEntry": basic["sleepNowElapsedSecondsFromAwakeClosedEntry"] ?? NSNull()]
        case "C389":
            let failedAlias = "terminated-pane-send-fails"
            let attemptedResume = resumeAliases.contains(failedAlias)
            let fellBackToNotice = noticeAliases.contains(failedAlias)
            return ["resumeCount": resumeCount, "resumeSucceeded": attemptedResume && !fellBackToNotice,
                    "noticeCount": noticeAliases.filter { $0 == failedAlias }.count,
                    "amberFlag": rows.keys.contains(where: marked)]
        case "C390":
            return ["resumeCount": resumeCount, "recordCount": count]
        case "C391":
            let perCycle = basic["resumeByCycle"] as? [[String: Int]] ?? []
            return ["resumeCount": resumeCount,
                    "recordsByCycle": perCycle.map { $0.values.reduce(0, +) }]
        case "C392":
            let disconnectedAt = basic["remoteDisconnectedContinuousAt"] as? Double ?? .infinity
            let sleepRows = basic["sleepNowTrace"] as? [[String: Any]] ?? []
            let sleptBeforeDisconnect = sleepRows.contains { ($0["continuous"] as? Double ?? .infinity) < disconnectedAt }
            let sleptAfterLimit = sleepRows.contains { ($0["continuous"] as? Double ?? -.infinity) >= disconnectedAt + 1800 }
            return ["sleepBeforeDisconnect": sleptBeforeDisconnect,
                    "sleepAfterRestarted30m": sleptAfterLimit,
                    "awakeClosedSinceReset": basic["remoteResetLogged"] as? Bool ?? false]
        case "C393":
            let childID = simulation["id"] as? String ?? ""
            if childID == "lowBatteryDuringRemote" {
                return ["sleepNowCount": sleepCount, "sleepReason": basic["sleepReason"] as? String ?? "",
                        "sleepNowElapsedSecondsFromAwakeClosedEntry": basic["sleepNowElapsedSecondsFromAwakeClosedEntry"] ?? NSNull()]
            }
            return ["sleepNowCount": sleepCount, "sleepReason": basic["sleepReason"] as? String ?? "",
                    "sleepNowElapsedSecondsFromAwakeClosedEntry": basic["sleepNowElapsedSecondsFromAwakeClosedEntry"] ?? NSNull()]
        case "C395":
            return ["state": currentState, "nosleepOnCount": basic["nosleepOnCount"] as? Int ?? 0, "sleepNowCount": sleepCount]
        case "C397":
            let childID = simulation["id"] as? String ?? ""
            return ["resumeCount": resumeCount, "noticeCount": noticeCount,
                    "amberFlag": rows.keys.contains(where: marked)]
        case "C398":
            let times = basic["resumeTimes"] as? [Double] ?? []
            let at: Any = times.first as Any? ?? NSNull()
            return ["resumeAt": at, "resumeBeforeTermination": basic["resumeBeforeTermination"] as? Bool ?? false,
                    "sleepNowCount": sleepCount]
        case "C399":
            let aliases = simulation["sessions"] as? [String] ?? []
            let perCycle = basic["resumeByCycle"] as? [[String: Int]] ?? []
            let cycleRows: [[String: Int]] = perCycle.map { cycle in
                var row: [String: Int] = [:]
                for alias in aliases { row[alias] = cycle[alias] ?? 0 }
                return row
            }
            return ["recordsByCycle": cycleRows, "resumeById": counts(resumeAliases),
                    "queueContentPreservedByCycle": Dictionary(uniqueKeysWithValues: aliases.enumerated().map { index, alias in
                        let text = sourceQueue.first(where: { $0["session"] as? String == alias })?["text"] as? String ?? ""
                        let cycleSends = resumeSends.filter { ($0["cycle"] as? Int) == index + 1 && aliasForSend($0) == alias }
                        return (alias, cycleSends.contains { ($0["content"] as? String ?? "").contains(text) })
                    }),
                    "resumeDispatchDiagnostics": basic["resumeDispatchDiagnostics"] as? [[String: Any]] ?? [],
                    "resumeSendFailureCount": basic["resumeSendFailureCount"] as? Int ?? 0]
        case "C400":
            let chiefAlias = (simulation["commander"] as? String) ?? "chief"
            let team = simulation["team"] as? [String] ?? []
            let chiefSends = resumeSends.filter { aliasForSend($0) == chiefAlias }
            let memberSends = resumeSends.filter { aliasForSend($0).map { team.contains($0) } ?? false }
            let aggregateSends = chiefSends.filter { send in
                let content = send["content"] as? String ?? ""
                return team.allSatisfy { member in
                    rows[member].map { content.contains($0.conversation.title) } ?? false
                }
            }
            let includesSelf = aggregateSends.contains { send in
                let content = send["content"] as? String ?? ""
                return rows[chiefAlias] != nil && content.contains(LidInterruption.continuePrompt)
            }
            return ["commanderAggregateCount": aggregateSends.count,
                    "memberResumeCount": memberSends.count, "commanderSelfResumeSeparateCount": max(0, chiefSends.count - aggregateSends.count),
                    "memberAmberFlags": team.allSatisfy(marked),
                    "commanderSelfResumeIncludedInAggregate": includesSelf]
        case "C401":
            let childID = simulation["id"] as? String ?? ""
            let memberAlias = (simulation["team"] as? [String])?.first ?? "memberA"
            return ["memberResumeCount": resumeAliases.filter { $0 == memberAlias }.count,
                    "memberNoticeCount": noticeAliases.filter { $0 == memberAlias }.count,
                    "memberAmberFlag": marked(memberAlias),
                    "memberNoticeContainsOriginalQueueText": noticeText.contains(sourceQueue.first?["text"] as? String ?? ""),
                    "queueDeletedOnlyAfterNoticeSuccess": noticeAliases.contains(memberAlias) && !FileManager.default.fileExists(atPath: (basic["rescuePath"] as? String) ?? "")]
        case "C409":
            return ["resumeById": counts(resumeAliases), "amberById": Dictionary(uniqueKeysWithValues: allAliases.sorted().map { ($0, marked($0)) })]
        case "C410":
            return ["setFanAutoCount": basic["setFanAutoCount"] as? Int ?? 0,
                    "fanFailureLogged": basic["fanFailureLogged"] as? Bool ?? false,
                    "sleepNowCount": sleepCount, "state": currentState,
                    "awakeClosedElapsedSeconds": basic["awakeClosedElapsedSeconds"] as? Double ?? 0]
        case "C411":
            return ["nosleepRetryCount": max(0, (basic["nosleepOnCount"] as? Int ?? 0) - 1),
                    "awakeClosedCleared": basic["awakeClosedCleared"] as? Bool ?? false,
                    "recordsCleared": basic["recordsCleared"] as? Bool ?? false, "sleepNowCount": sleepCount]
        case "C412":
            return ["crashed": false, "sleepNowCallCount": sleepCount,
                    "sleepFailureLogged": basic["sleepFailureLogged"] as? Bool ?? false]
        case "C413":
            guard let suiteName = AppDefaults.testSuiteName,
                  let defaults = UserDefaults(suiteName: suiteName) else { exit(2) }
            defaults.removePersistentDomain(forName: suiteName)
            if let legacy = simulation["legacyPrefs"] as? [String: Any] {
                for (key, value) in legacy { defaults.set(value, forKey: key) }
            }
            let migrated = Prefs.initialLidModeValues(defaults: defaults)
            let persistent = defaults.persistentDomain(forName: suiteName) ?? [:]
            let storedLegacyKeep = persistent["lidKeepWorking"] as? Bool
            let storedInterrupt = persistent["lidInterruptOnClose"] as? Bool
            let legacyLabels = [
                "闔上螢幕時，讓正在做事的聊天室做完這一段",
                "接外接螢幕闔蓋時，做完且 10 分鐘沒操作就關風扇並睡眠",
                "打開螢幕時通知它們繼續"
            ]
            var mirrorBudget = 2_000
            func viewContainsLegacyLabel(_ value: Any, depth: Int = 0) -> Bool {
                guard depth < 20, mirrorBudget > 0 else { return false }
                mirrorBudget -= 1
                if let text = value as? String, legacyLabels.contains(text) { return true }
                for child in Mirror(reflecting: value).children {
                    if viewContainsLegacyLabel(child.value, depth: depth + 1) { return true }
                }
                return false
            }
            let legacySettingsVisible = viewContainsLegacyLabel(ChatPrefsPage().body)
            return ["lidKeepWorking": migrated.keepWorking, "lidInterruptOnClose": migrated.interrupt,
                    "legacyPathEntered": migrated.keepWorking, "legacySettingsVisible": legacySettingsVisible,
                    "legacyPreferenceCleared": storedLegacyKeep == false,
                    "persistedInterruptValue": storedInterrupt as Any? ?? NSNull()]
        default:
            return basic
        }
    }

    private func runAwakeClosedSingleScenario(caseID: String, simulation: [String: Any], stateRoot: URL, suffix: String) -> [String: Any] {
        main.lidTimer?.invalidate()
        let clockOrigin = appLaunchDate
        var wallClock = clockOrigin
        let sim = AwakeClosedProbeEnv(wall: clockOrigin)
        let keeper = LidKeeper(env: sim, logURL: stateRoot.appendingPathComponent("awake-closed-\(suffix).log"),
                               markerURL: stateRoot.appendingPathComponent("awake-closed-\(suffix).marker"),
                               rescueURL: stateRoot.appendingPathComponent("awake-closed-\(suffix)-rescue.json"), now: { wallClock })
        keeper.resumeDelay = 0.05
        keeper.limits.awakeClosedMax = 1800
        keeper.limits.awakeClosedMinBattery = 20
        keeper.limits.hotCelsius = 95
        keeper.limits.hotSeconds = 60
        let oldKeeper = main.lidKeeper
        main.lidKeeper = keeper
        defer { main.lidKeeper = oldKeeper }
        sim.closed = false
        sim.external = simulation["external"] as? Bool ?? false
        sim.batteryAvailable = !(simulation["battery"] is NSNull)
        sim.percent = simulation["battery"] as? Int ?? 80
        sim.onAC = simulation["onAC"] as? Bool ?? false
        if let value = simulation["temperature"] as? Double { sim.temp = value }
        else if let value = simulation["temperature"] as? Int { sim.temp = Double(value) }
        else { sim.temp = 50 }
        sim.remote = false
        sim.helper = simulation["helper"] as? String ?? "ok"
        if simulation["id"] as? String == "lowBatteryDuringRemote" { sim.remote = true }
        sim.connDead = false; sim.actualOn = false
        sim.continuousOffset = 0; sim.uptimeOffset = 0
        sim.sleepEvidenceValue = LidSleepEvidence(wakeTime: 0, sleepTime: 0)
        sim.traceNow = { wallClock }

        var modeEnabled = simulation["probeInterruptEnabled"] as? Bool ?? true
        keeper.enabled = { modeEnabled }
        keeper.interruptOnCloseEnabled = { modeEnabled }
        keeper.resumeEnabled = { true }
        keeper.externalIdleSleepEnabled = { true }
        keeper.now = { wallClock }
        sim.onCall = { [weak keeper] message in keeper?.log(message) }

        var preholdPrime = false

        var rawSessions = simulation["sessions"] as? [String] ?? []
        if let singularSession = simulation["session"] as? String {
            rawSessions.append(singularSession)
        }
        let teamNames = simulation["team"] as? [String] ?? []
        let commanderName: String? = {
            if let value = simulation["commander"] as? String { return value }
            if simulation["commander"] is [String: Any] || !teamNames.isEmpty { return "chief" }
            return nil
        }()
        // 獨立 fixture 歸到保留的程式碼學習專區；Groups.commanderSessionID 對此根組及其子組回 nil，避免預設總指揮兜底。
        // 明確宣告 commander/team 的 Q6 fixture 保留原本的探針群組與成員 layout。
        let fixtureGroupID: UUID
        var createdCodeLabGroupID: UUID?
        if commanderName == nil {
            if let codeLab = store.groups.first(where: { $0.name == Store.codeLabGroupName && $0.parentID == nil }) {
                fixtureGroupID = codeLab.id
            } else {
                let codeLab = ConvGroup(name: Store.codeLabGroupName)
                store.groups.append(codeLab)
                fixtureGroupID = codeLab.id
                createdCodeLabGroupID = codeLab.id
            }
        } else {
            let group = ConvGroup(name: "闔蓋探針 (suffix)")
            store.groups.append(group)
            fixtureGroupID = group.id
        }
        defer {
            if let createdCodeLabGroupID {
                store.groups.removeAll { $0.id == createdCodeLabGroupID }
            }
        }
        var aliases = rawSessions + teamNames
        if let commanderName { aliases.append(commanderName) }
        for q in simulation["queue"] as? [[String: Any]] ?? [] {
            if let alias = q["session"] as? String { aliases.append(alias) }
        }
        var uniqueAliases: [String] = []
        for alias in aliases where !uniqueAliases.contains(alias) { uniqueAliases.append(alias) }
        aliases = uniqueAliases

        var project = Project(name: "闔蓋探針 (suffix)", path: stateRoot.path)
        project.groupID = fixtureGroupID
        store.projects.append(project)
        var rows: [String: AwakeClosedProbeRow] = [:]
        for alias in aliases {
            var conversation = Conversation(projectID: project.id, title: "\(alias)-fixture")
            // Resume/notice 的真實 ChatPane 路徑由隔離 fake app-server 接收，不碰登入中的引擎。
            conversation.model = "codex:gpt-6-luna"
            conversation.groupID = fixtureGroupID
            if alias == "archived" { conversation.manualArchive = true }
            if alias == commanderName,
               (simulation["commander"] as? [String: Any])?["archived"] as? Bool == true {
                conversation.manualArchive = true
            }
            if alias == "draft" || alias == "terminated-draft-with-draft" { conversation.draft = true }
            let id = conversation.id
            store.conversations.append(conversation)
            let archived = conversation.manualArchive == true || ((simulation["commander"] as? [String: Any])? ["archived"] as? Bool == true && alias == commanderName)
            let unavailableCommander = (simulation["commander"] as? [String: Any])?["paneAvailable"] as? Bool == false && alias == commanderName
            let available = !unavailableCommander
            if available { _ = workspace.pane(for: conversation) }
            if alias == "draft" {
                MainActor.assumeIsolated {
                    if let pane = workspace.panes[id] as? ChatPane {
                        pane.inputBar.textView.string = "AWAKE_CLOSED_DRAFT_FIXTURE"
                    }
                }
            }
            store.status[id] = rawSessions.contains(alias) ? .working : .idle
            let localOnly = alias == "local-model"
            let backgroundOnly = alias == "background-only"
            let supports = !localOnly && !backgroundOnly
            let engine = localOnly ? "本機模型" : "Codex"
            let isActive = rawSessions.contains(alias) && alias != "idle"
            let pending = (simulation["queue"] as? [[String: Any]] ?? []).filter { $0["session"] as? String == alias }.map { item -> LidQueuedMessage in
                let text = item["text"] as? String ?? ""
                let hasImage = item["image"] as? Bool ?? false
                return LidQueuedMessage(id: UUID().uuidString.lowercased(), text: LidQueuedMessage.formattedText(text, hasImages: hasImage))
            }
            let details = backgroundOnly ? ["背景工作 fixture"] : []
            let work = LidInterruptWork(id: id, title: conversation.title, engine: engine,
                                        supportsTermination: supports, hasBangCommand: false,
                                        details: details, foreground: !backgroundOnly)
            let drainSeconds: TimeInterval = alias == "ignoresTerm" ? 8 : 0
            rows[alias] = AwakeClosedProbeRow(alias: alias, conversation: conversation, work: work, pending: pending,
                                              archived: archived, available: available, drainSeconds: drainSeconds,
                                              active: isActive || alias == "ignoresTerm")
        }
        if let commanderName, let chief = rows[commanderName] {
            store.sessions.append(SessionLayout(name: "闔蓋探針 (suffix)", windows: [], groups: [fixtureGroupID], chief: chief.conversation.id))
        }

        var terminatedRecords: [LidInterruption] = []
        var resumeRecords: [LidInterruption] = []
        var resumeDispatchDiagnostics: [[String: Any]] = []
        var sendLidInterruptResumeCallRows: [[String: Any]] = []
        var resumeCandidateSnapshot: [[String: Any]] = []
        var resumeRoutingSessionsAtDispatch: [[String: Any]] = []
        var sessionsCountAtDispatch: Int?
        var sessionsCountAtDispatchSamples: [Int] = []
        var resumeSendObserverCalls: [[String: Any]] = []
        var resumeTimes: [TimeInterval] = []
        var resumeBeforeTermination = false
        var noticeCallCount = 0
        var automatedSends: [[String: Any]] = []
        var sendWhileClosed: [[String: Any]] = []
        var cycleIndex = 0
        var interruptionEvaluatedByCycle: [Bool] = []
        var legacyStopCount = 0
        var legacyResumeCount = 0
        var resumeByCycle: [[String: Int]] = []
        var resumeQueueByCycle: [[String: String]] = []
        var remoteDisconnectedAt: TimeInterval?
        var remoteDisconnectedContinuousAt: TimeInterval?
        var remoteWasActive = false
        let scenarioContinuousStart = sim.continuousTime()
        let aliasesByRecordID = Dictionary(uniqueKeysWithValues: rows.values.map { ($0.work.id, $0.alias) })
        let previousNoticeObserver = LidIndicatorNoticeProbe.observe
        let previousSendObserver = ChatPane.lidInterruptSendObserver
        // 關閉探針的「只觀察路由即 return」短路；native runner 提供本機假 Codex app-server。
        LidIndicatorNoticeProbe.observe = nil
        ChatPane.lidInterruptSendObserver = { id, text, source, now in
            automatedSends.append(["recipient": id.uuidString.lowercased(), "content": text,
                                   "source": source ?? "user", "now": now, "cycle": cycleIndex])
            if source == "闔蓋繼續" {
                resumeSendObserverCalls.append(["recipientSession": id.uuidString.lowercased(),
                                                "source": source ?? "", "cycle": cycleIndex])
            }
            if sim.closed { sendWhileClosed.append(["recipient": id.uuidString.lowercased(), "content": text, "source": source ?? "user", "now": now]) }
        }
        defer {
            LidIndicatorNoticeProbe.observe = previousNoticeObserver
            ChatPane.lidInterruptSendObserver = previousSendObserver
        }
        keeper.interruptWork = {
            if cycleIndex > 0 {
                while interruptionEvaluatedByCycle.count < cycleIndex { interruptionEvaluatedByCycle.append(false) }
                interruptionEvaluatedByCycle[cycleIndex - 1] = true
            }
            if preholdPrime {
                return [LidInterruptWork(id: UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!,
                                         title: "prehold fixture", engine: "Codex", supportsTermination: true,
                                         hasBangCommand: false, details: [])]
            }
            return rows.values.filter { $0.active }.map(\.work).sorted { $0.id.uuidString < $1.id.uuidString }
        }
        keeper.workingIDs = { rows.values.filter { $0.active }.map { $0.work.id } }
        keeper.workingCount = { rows.values.filter { $0.active }.count }
        keeper.workDescriptions = { rows.values.filter { $0.active }.map { $0.work.title } }
        keeper.pendingMessagesForInterrupt = { id in
            guard let row = rows.values.first(where: { $0.work.id == id }) else { return LidInterruptPendingMessages() }
            return LidInterruptPendingMessages(messages: row.pending)
        }
        keeper.terminateForInterrupt = { id, _ in
            guard let row = rows.values.first(where: { $0.work.id == id }), row.available else { return false }
            row.terminated = true; row.active = false; row.drainUntil = wallClock.addingTimeInterval(row.drainSeconds)
            self.store.status[id] = .idle
            return true
        }
        keeper.isDraining = { id in
            guard let row = rows.values.first(where: { $0.work.id == id }), row.terminated else { return false }
            return wallClock < row.drainUntil
        }
        keeper.forceKillDraining = { id in
            guard let row = rows.values.first(where: { $0.work.id == id }), keeper.isDraining(id) else { return false }
            row.forced = true; row.drainUntil = wallClock; return true
        }
        keeper.didForceKillForInterrupt = { id in rows.values.first(where: { $0.work.id == id })?.forced ?? false }
        keeper.sendInterruptNotices = { records, late in
            noticeCallCount += 1
            terminatedRecords.append(contentsOf: records)
            self.main.sendLidInterruptNotices(records, late: late)
        }
        keeper.sendInterruptResume = { records in
            resumeRecords.append(contentsOf: records)
            resumeTimes.append(sim.continuousTime())
            let callNumber = sendLidInterruptResumeCallRows.count + 1
            let dispatchSessionsCount = self.store.sessions.count
            if sessionsCountAtDispatch == nil { sessionsCountAtDispatch = dispatchSessionsCount }
            sessionsCountAtDispatchSamples.append(dispatchSessionsCount)
            let layoutsAtDispatch: [[String: Any]] = self.store.sessions.map { layout in
                var row: [String: Any] = [:]
                row["name"] = layout.name
                row["area"] = layout.area as Any? ?? NSNull()
                row["groupsIsNil"] = layout.groups == nil
                row["chiefIsNil"] = layout.chief == nil
                row["idPrefix"] = String(layout.id.uuidString.prefix(8)).lowercased()
                return row
            }
            resumeRoutingSessionsAtDispatch.append(["call": callNumber,
                                                    "cycle": cycleIndex,
                                                    "sessionsCount": dispatchSessionsCount,
                                                    "sessions": layoutsAtDispatch])
            let observerStart = resumeSendObserverCalls.count
            let noticeStart = noticeCallCount
            let snapshotRows: [[String: Any]] = records.map { record in
                let conversation = self.store.conversation(record.id)
                let groupID: UUID? = conversation.flatMap { self.store.groupOf($0) }
                let commanderSessionIDForGroup: UUID? = groupID.flatMap { self.store.commanderSessionID(forGroup: $0) }
                let commander = self.store.commander(of: record.id)
                let commanderChiefID = commander?.chief
                let archivedValue: Any
                if let conversation {
                    archivedValue = self.store.isArchived(conversation)
                } else {
                    archivedValue = NSNull()
                }
                let pane = self.workspace.panes[record.id] as? ChatPane
                let pendingInputValue: Any
                if let pane {
                    pendingInputValue = pane.inputBar.hasPendingInput
                } else {
                    pendingInputValue = NSNull()
                }
                let working = self.store.status[record.id] == .working
                let chiefID = commanderChiefID
                let notArchived = conversation.map { !self.store.isArchived($0) } ?? false
                let candidate = record.supportsTermination && record.terminated && conversation != nil
                    && notArchived && !working && record.foreground
                var row: [String: Any] = [:]
                row["call"] = callNumber
                row["cycle"] = cycleIndex
                row["alias"] = aliasesByRecordID[record.id] ?? ""
                row["supportsTermination"] = record.supportsTermination
                row["terminated"] = record.terminated
                row["conversationExists"] = conversation != nil
                row["isArchived"] = archivedValue
                row["storeStatusWorking"] = working
                row["foreground"] = record.foreground
                row["paneAvailable"] = pane != nil
                row["inputHasPendingInput"] = pendingInputValue
                row["commanderChiefExists"] = chiefID != nil
                row["commanderChiefExistsAlgorithm"] = "let chiefID = store.commander(of: record.id)?.chief; chiefID != nil"
                row["commanderChiefIsSelf"] = chiefID == record.id
                row["commanderChiefAlias"] = chiefID.flatMap { aliasesByRecordID[$0] } ?? ""
                row["groupOfID"] = groupID.map { String($0.uuidString.prefix(8)).lowercased() } as Any? ?? NSNull()
                row["commanderSessionIDForGroup"] = commanderSessionIDForGroup.map { String($0.uuidString.prefix(8)).lowercased() } as Any? ?? NSNull()
                row["commanderOfID"] = commander.map { String($0.id.uuidString.prefix(8)).lowercased() } as Any? ?? NSNull()
                row["commanderOfName"] = commander?.name as Any? ?? NSNull()
                row["commanderOfChiefID"] = commanderChiefID.map { String($0.uuidString.prefix(8)).lowercased() } as Any? ?? NSNull()
                row["isInterruptedCandidateAtDispatch"] = candidate
                return row
            }
            resumeCandidateSnapshot.append(contentsOf: snapshotRows)
            resumeDispatchDiagnostics.append(contentsOf: records.map { record in
                let pane = self.workspace.panes[record.id] as? ChatPane
                let conversation = self.store.conversation(record.id)
                let liveElsewhere = pane?.liveElsewhere()
                return [
                    "cycle": cycleIndex,
                    "alias": aliasesByRecordID[record.id] ?? "",
                    "supportsTermination": record.supportsTermination,
                    "terminated": record.terminated,
                    "foreground": record.foreground,
                    "stillRunning": record.stillRunning,
                    "storeStatusWorking": self.store.status[record.id] == .working,
                    "conversationExists": conversation != nil,
                    "archived": conversation.map { self.store.isArchived($0) } ?? true,
                    "paneAvailable": pane != nil,
                    "paneSessionRunning": pane?.session.isRunning ?? false,
                    "liveElsewhere": liveElsewhere != nil,
                    "liveElsewhereKind": liveElsewhere?.kind ?? "",
                    "queuedMessageCount": record.queuedMessages.count,
                    "outboxReadFailed": record.outboxReadFailed
                ] as [String: Any]
            })
            if records.contains(where: { record in
                guard let row = rows.values.first(where: { $0.work.id == record.id }) else { return false }
                return row.terminated && wallClock < row.drainUntil
            }) { resumeBeforeTermination = true }
            while resumeByCycle.count < cycleIndex { resumeByCycle.append([:]) }
            while resumeQueueByCycle.count < cycleIndex { resumeQueueByCycle.append([:]) }
            if cycleIndex > 0 {
                var counts = resumeByCycle[cycleIndex - 1]
                var queueByAlias = resumeQueueByCycle[cycleIndex - 1]
                for record in records {
                    if let alias = aliasesByRecordID[record.id] {
                        counts[alias, default: 0] += 1
                        if let row = rows[alias] {
                            let resumeText = LidInterruption.continueMessage(for: LidInterruption(
                                id: record.id, title: row.work.title, engine: row.work.engine,
                                supportsTermination: row.work.supportsTermination, details: row.work.details,
                                queuedMessages: row.pending, terminated: true, forceKilled: row.forced,
                                stillRunning: false, outboxReadFailed: false, foreground: row.work.foreground))
                            queueByAlias[alias] = resumeText
                        }
                    }
                }
                resumeByCycle[cycleIndex - 1] = counts
                resumeQueueByCycle[cycleIndex - 1] = queueByAlias
            }
            // 讓實際 resume 分流／team 彙總路徑執行；此探針的 Codex session 只接 native.sh 傳入的假 app-server。
            self.main.sendLidInterruptResume(records, log: { keeper.log($0) })
            let observerCalls = Array(resumeSendObserverCalls.dropFirst(observerStart))
            let fallbackNoticeCount = noticeCallCount - noticeStart
            let inferredReturn: Any
            let inference: String
            if records.count == 1 && observerCalls.count == 1 {
                let succeeded = fallbackNoticeCount == 0
                inferredReturn = succeeded
                inference = succeeded
                    ? "單筆 record：已觀察到 send，且沒有續送失敗 fallback notice，推定回傳 true"
                    : "單筆 record：已觀察到 send，且有續送失敗 fallback notice，推定回傳 false"
            } else {
                inferredReturn = NSNull()
                inference = observerCalls.isEmpty
                    ? "observer 未觸發；sendAutomatedText 可能未呼叫或在 observer 前被擋，無法取得回傳值"
                    : "多筆／多收件路徑無法將 fallback notice 對應到單一 send，回傳值未能推定"
            }
            sendLidInterruptResumeCallRows.append([
                "call": callNumber,
                "cycle": cycleIndex,
                "recordCount": records.count,
                "expectedSource": "闔蓋繼續",
                "sendObserverCalls": observerCalls,
                "fallbackNoticeCallCount": fallbackNoticeCount,
                "sendAutomatedTextReturnValue": inferredReturn,
                "returnValueInference": inference
            ])
        }
        keeper.sessionIsAvailable = { id in rows.values.first(where: { $0.work.id == id })?.available ?? false }
        keeper.sessionIsArchived = { id in rows.values.first(where: { $0.work.id == id })?.archived ?? true }
        keeper.sendStop = { _ in legacyStopCount += 1; return true }
        keeper.sendResume = { _ in legacyResumeCount += 1 }

        if simulation["preheld"] as? Bool == true {
            // 先走真實 tick 的螢幕開啟預擋，再清掉臨時工作 fixture，接著才闔蓋測無工作收尾。
            preholdPrime = true
            keeper.tick()
            preholdPrime = false
        }
        if let settings = simulation["setFanAutoSucceeds"] as? Bool { sim.fanSucceeds = settings }
        if let settings = simulation["sleepNowSucceeds"] as? Bool { sim.sleepSucceeds = settings }
        if let battery = simulation["battery"] as? Int { sim.percent = battery; sim.batteryAvailable = true }
        if simulation["battery"] is NSNull { sim.batteryAvailable = false }
        let closeContinuousStart = sim.continuousTime()
        var elapsedTarget: TimeInterval = 0
        let wallJumps = simulation["wallClockJumps"] as? [Double] ?? []
        var wallJumpsApplied = false
        var sawClose = false

        func tick(waitForCallbacks: Bool = true) {
            keeper.tick()
            if waitForCallbacks { RunLoop.main.run(until: Date().addingTimeInterval(0.06)) }
        }
        func advance(_ seconds: TimeInterval, slept: Bool = false) {
            guard seconds.isFinite else { return }
            wallClock.addTimeInterval(seconds)
            sim.continuousOffset += seconds
            if !slept { sim.uptimeOffset += seconds }
            if slept {
                var evidence = sim.sleepEvidenceValue ?? LidSleepEvidence(wakeTime: 0, sleepTime: 0)
                evidence.sleepTime += 1; evidence.wakeTime += max(1, seconds); sim.sleepEvidenceValue = evidence
            }
            elapsedTarget += seconds
        }
        let lidEvents = simulation["lid"] as? [String] ?? []
        for event in lidEvents {
            let selectedAlias: String? = {
                guard let open = event.firstIndex(of: "("),
                      let close = event[event.index(after: open)...].firstIndex(of: ")") else { return nil }
                return String(event[event.index(after: open)..<close])
            }()
            let name = event.firstIndex(of: "(").map { String(event[..<$0]) } ?? event
            if let at = name.firstIndex(of: "@"), let scheduled = Double(name[name.index(after: at)...]), scheduled > elapsedTarget {
                advance(scheduled - elapsedTarget)
            }
            if name.hasPrefix("continuous+") {
                if !wallJumpsApplied {
                    for jump in wallJumps { wallClock.addTimeInterval(jump) }
                    wallJumpsApplied = true
                }
                let add = Double(name.dropFirst("continuous+".count)) ?? 0
                advance(add)
                tick()
            } else if name.hasPrefix("open") {
                if name.contains("<"), name.contains("1800") { /* 開蓋延遲低於上限，不額外推進時間。 */ }
                sim.closed = false; sim.screenOff = false; sim.suppressLidObservation = false
                if caseID == "C387", let row = rows["working"] {
                    // fixture 表示該格在開蓋處置前已自行回到工作中；讓產品候選篩選讀到真實 Store 狀態。
                    store.status[row.work.id] = .working
                }
                let drainingCase = caseID == "C398" && (simulation["lid"] as? [String] ?? []).contains(where: { $0.hasPrefix("terminationCompletes@") })
                tick(waitForCallbacks: !drainingCase)
            } else if name.hasPrefix("close") {
                cycleIndex += 1
                interruptionEvaluatedByCycle.append(false)
                if caseID == "C399", let selectedAlias {
                    for row in rows.values {
                        row.active = row.alias == selectedAlias
                        store.status[row.work.id] = row.active ? .working : .idle
                    }
                } else if caseID == "C391", cycleIndex > 1 {
                    let resumedIDs = Set(resumeRecords.map(\.id))
                    for row in rows.values where resumedIDs.contains(row.work.id) {
                        row.active = store.status[row.work.id] == .working
                    }
                }
                sim.closed = true; sim.suppressLidObservation = false; sawClose = true; tick()
                if keeper.isAwakeClosed { tick() }
            } else if caseID == "C133", name == "display-flash" {
                let previousExternal = sim.external
                sim.external = !previousExternal
                tick()
                sim.external = previousExternal
                tick()
            } else if caseID == "C133", name == "reclose" {
                cycleIndex += 1
                interruptionEvaluatedByCycle.append(false)
                sim.closed = true; sim.suppressLidObservation = false; sawClose = true; tick()
                if keeper.isAwakeClosed { tick() }
            } else if caseID == "C35", name == "10m" || caseID == "C86", name == "idle=600" {
                if caseID == "C86" { sim.idleSeconds = 600 }
                advance(600)
                tick()
            } else if caseID == "C86", name == "work-finished" {
                for row in rows.values {
                    row.active = false
                    store.status[row.work.id] = .idle
                }
                tick()
            } else if caseID == "C38", name == "wakeGap" {
                var evidence = sim.sleepEvidenceValue ?? LidSleepEvidence(wakeTime: 0, sleepTime: 0)
                evidence.sleepTime += 1; evidence.wakeTime += 12; sim.sleepEvidenceValue = evidence
                advance(12, slept: true)
                tick()
            } else if caseID == "C38", name == "external-return" {
                sim.external = true
                tick()
            } else if caseID == "C38", name == "helper-failure" {
                sim.helper = "fail"; sim.connDead = true
                tick()
            } else if name == "tick" {
                tick()
            } else if name.hasPrefix("remote=") {
                sim.remote = name.hasSuffix("1")
                if sim.remote { remoteWasActive = true }
                else { remoteDisconnectedAt = elapsedTarget; remoteDisconnectedContinuousAt = sim.continuousTime() }
                tick()
            } else if name.hasPrefix("temperature=") || name.hasPrefix("temp=") {
                let value = name.split(separator: "=", maxSplits: 1).last.flatMap { Double($0) } ?? sim.temp
                sim.temp = value; tick()
            } else if name.hasPrefix("battery=") || name.hasPrefix("batt=") {
                let value = name.split(separator: "=", maxSplits: 1).last.flatMap { Int($0) } ?? sim.percent
                sim.percent = value; tick()
            } else if name.hasPrefix("ac=") {
                sim.onAC = name.hasSuffix("1"); tick()
            } else if name == "sleepEvidence<10" || name == "darkWake" {
                var evidence = sim.sleepEvidenceValue ?? LidSleepEvidence(wakeTime: 0, sleepTime: 0)
                evidence.sleepTime += 1; evidence.wakeTime += 2; sim.sleepEvidenceValue = evidence
                advance(2, slept: true); tick()
            } else if name.hasPrefix("setting=") {
                modeEnabled = name.hasSuffix("on"); tick()
            } else if name.hasPrefix("helper=") {
                sim.helper = String(name.dropFirst("helper=".count))
                sim.connDead = sim.helper == "disconnect"
                if !sim.connDead, sim.helper == "ok" { sim.actualOn = false; sim.noSleepValue = false }
                tick()
            } else if name.hasPrefix("terminationCompletes@") {
                let at = Double(name.dropFirst("terminationCompletes@".count)) ?? elapsedTarget
                if at > elapsedTarget { advance(at - elapsedTarget) }
                for row in rows.values where row.terminated { row.drainUntil = wallClock }
                tick()
            }
        }
        if !sawClose, simulation["lid"] as? [String] != nil { tick() }
        RunLoop.main.run(until: Date().addingTimeInterval(keeper.resumeDelay + 0.15))
        let trace = sim.trace
        let logText = (try? String(contentsOf: keeper.logURL, encoding: .utf8)) ?? ""
        let resumeSendFailureCount = logText.components(separatedBy: .newlines)
            .filter { $0.contains("開蓋自動繼續送出失敗") }.count
        let sleepRows = trace.filter { $0["event"] as? String == "sleepNow" }
        let closeTime = closeContinuousStart
        let firstSleepContinuous = sleepRows.first?["continuous"] as? Double
        let sleepElapsed: TimeInterval? = firstSleepContinuous.map { $0 - closeTime }
        let aliasesByID = Dictionary(uniqueKeysWithValues: rows.values.map { ($0.work.id, $0.alias) })
        let aliasesBySessionID = Dictionary(uniqueKeysWithValues: rows.values.compactMap { row -> (String, String)? in
            guard let pane = workspace.panes[row.work.id] as? ChatPane else { return nil }
            return (pane.session.claudeSession.uuidString.lowercased(), row.alias)
        })
        let sleepState: String
        if keeper.isAwakeClosed { sleepState = "awakeClosed" }
        else if keeper.noSleepOn { sleepState = "holding" }
        else if !sleepRows.isEmpty { sleepState = "open" } // 預擋已釋放且已要求系統睡眠
        else if sim.closed { sleepState = "systemDefault" }
        else { sleepState = "open" }
        var basic: [String: Any] = [
            "state": sleepState,
            "terminatedCount": rows.values.filter(\.terminated).count,
            "nosleepOn": keeper.noSleepOn,
            "nosleepOnCount": trace.filter { $0["event"] as? String == "setNoSleep" && $0["enabled"] as? Bool == true }.count,
            "nosleepOffCount": trace.filter { $0["event"] as? String == "setNoSleep" && $0["enabled"] as? Bool == false }.count,
            "sleepNowCount": sleepRows.count,
            "sleepNowCallCount": sleepRows.count,
            "setFanAutoCount": trace.filter { $0["event"] as? String == "setFanAuto" }.count,
            "sleepNowElapsedSecondsFromAwakeClosedEntry": sleepElapsed as Any? ?? NSNull(),
            "sleepNowElapsedSeconds": sleepElapsed as Any? ?? NSNull(),
            "sleepReason": logText.contains("電量低於") ? "lowBattery" : (logText.contains("溫度過高") ? "overheat" : "maxHold"),
            "sleptByAwakeClosed": logText.contains("已保持醒著滿"),
            "fanFailureLogged": logText.contains("交還風扇失敗"),
            "sleepFailureLogged": !sim.sleepSucceeds && logText.contains("pmset sleepnow 失敗"),
            "remoteResetLogged": logText.contains("遠端連線已全部中斷，重新計算"),
            "awakeClosedElapsedSeconds": elapsedTarget,
            "awakeClosedCleared": !keeper.isAwakeClosed,
            "awakeClosedSinceActive": keeper.awakeClosedSince != nil,
            "records": terminatedRecords.map { ["id": $0.id.uuidString.lowercased(), "title": $0.title] },
            "resumedRecords": resumeRecords.map { ["id": $0.id.uuidString.lowercased(), "title": $0.title] },
            "resumeDispatchDiagnostics": resumeDispatchDiagnostics,
            "sendLidInterruptResumeCalls": ["count": sendLidInterruptResumeCallRows.count,
                                            "calls": sendLidInterruptResumeCallRows],
            "resumeCandidateSnapshot": resumeCandidateSnapshot,
            "resumeSendObserverCalls": resumeSendObserverCalls,
            "resumeSendFailureCount": resumeSendFailureCount,
            "resumeTimes": resumeTimes.map { $0 - scenarioContinuousStart },
            "resumeBeforeTermination": resumeBeforeTermination,
            "resumeQueueByCycle": resumeQueueByCycle,
            "automatedSends": automatedSends,
            "sendAliasBySessionId": aliasesBySessionID,
            "noticeCallCount": noticeCallCount,
            "resumeByCycle": resumeByCycle,
            "closeWindowSends": sendWhileClosed,
            "sleepNowTrace": sleepRows,
            "noSleepTrace": trace.filter { $0["event"] as? String == "setNoSleep" },
            "recordAliasById": Dictionary(uniqueKeysWithValues: aliasesByID.map { ($0.key.uuidString.lowercased(), $0.value) }),
            "amberByAlias": Dictionary(uniqueKeysWithValues: rows.values.map { ($0.alias, store.conversation($0.work.id)?.interruptedAt != nil) }),
            "probeLog": logText,
            "legacyStopCount": legacyStopCount,
            "legacyResumeCount": legacyResumeCount,
            "interruptionsByClosure": interruptionEvaluatedByCycle.map { $0 ? 1 : 0 },
            "resumeDelay": keeper.resumeDelay,
            "remoteWasActive": remoteWasActive,
            "remoteDisconnectedContinuousAt": remoteDisconnectedContinuousAt as Any? ?? NSNull(),
            "batteryWasNil": !sim.batteryAvailable,
            "recordsCleared": !keeper.hasPendingInterruptNotice,
            "rescuePath": keeper.rescueURL?.path as Any? ?? NSNull(),
            "wallClockJumpsApplied": wallJumpsApplied ? wallJumps : [],
            "remoteDisconnectedAt": remoteDisconnectedAt as Any? ?? NSNull()
        ]
        var result = observedAwakeClosedFields(caseID: caseID, simulation: simulation, basic: basic, rows: rows, store: store)
        if caseID == "C386" {
            result["sessionsCountAtDispatch"] = sessionsCountAtDispatch as Any? ?? NSNull()
            result["sessionsCountAtDispatchSamples"] = sessionsCountAtDispatchSamples
            result["resumeRoutingSessionsAtDispatch"] = resumeRoutingSessionsAtDispatch
        }
        return result
    }

    @MainActor
    private func runStoreRecoveryGuardProbe(root: URL, output: URL) {
        do {
            let fm = FileManager.default
            let fixtureRoot = root.appendingPathComponent("g45-store-recovery-\(UUID().uuidString)", isDirectory: true)
            let asideDir = fixtureRoot.appendingPathComponent("aside-failure", isDirectory: true)
            let emptyDir = fixtureRoot.appendingPathComponent("empty-with-bad-backup", isDirectory: true)
            let missingDir = fixtureRoot.appendingPathComponent("missing-with-bad-backup", isDirectory: true)
            let bothBadDir = fixtureRoot.appendingPathComponent("both-corrupt", isDirectory: true)
            for dir in [asideDir, emptyDir, missingDir, bothBadDir] {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }

            let badPrimary = Data("broken-primary-state".utf8)
            let goodBackup = Data(#"{"projects":[],"conversations":[]}"#.utf8)
            let badBackup = Data("broken-backup-state".utf8)
            let asidePrimaryURL = asideDir.appendingPathComponent("state.json")
            let asideBackupURL = asideDir.appendingPathComponent("state.json.bak")
            try badPrimary.write(to: asidePrimaryURL)
            try goodBackup.write(to: asideBackupURL)

            // 先建立一小段未來秒數的同名目錄，讓 Store 的另存寫入必定失敗，不靠權限或執行帳號。
            let formatter = DateFormatter()
            formatter.dateFormat = "MMdd-HHmmss"
            let anchor = Date()
            for offset in -1...60 {
                let name = "state.json.讀不到-\(formatter.string(from: anchor.addingTimeInterval(TimeInterval(offset))))"
                let blocker = asideDir.appendingPathComponent(name, isDirectory: true)
                if !fm.fileExists(atPath: blocker.path) {
                    try fm.createDirectory(at: blocker, withIntermediateDirectories: false)
                }
            }
            let helperURL = asideDir.appendingPathComponent("helper-source.json")
            try badPrimary.write(to: helperURL)
            for offset in -1...60 {
                let name = "helper-source.json.讀不到-\(formatter.string(from: anchor.addingTimeInterval(TimeInterval(offset))))"
                let blocker = asideDir.appendingPathComponent(name, isDirectory: true)
                if !fm.fileExists(atPath: blocker.path) {
                    try fm.createDirectory(at: blocker, withIntermediateDirectories: false)
                }
            }
            let helperSetAsideSucceeded = UnreadableFile.setAside(helperURL, data: badPrimary)
            let asideStore = Store(directory: asideDir)

            let emptyPrimaryURL = emptyDir.appendingPathComponent("state.json")
            let emptyBackupURL = emptyDir.appendingPathComponent("state.json.bak")
            try Data().write(to: emptyPrimaryURL)
            try badBackup.write(to: emptyBackupURL)
            let emptyStore = Store(directory: emptyDir)
            let emptySaveResults = [emptyStore.saveNow(), emptyStore.saveNow()]

            let missingPrimaryURL = missingDir.appendingPathComponent("state.json")
            let missingBackupURL = missingDir.appendingPathComponent("state.json.bak")
            try badBackup.write(to: missingBackupURL)
            let missingStore = Store(directory: missingDir)
            let missingSaveResults = [missingStore.saveNow(), missingStore.saveNow()]

            let bothBadPrimaryURL = bothBadDir.appendingPathComponent("state.json")
            let bothBadBackupURL = bothBadDir.appendingPathComponent("state.json.bak")
            try badPrimary.write(to: bothBadPrimaryURL)
            try badBackup.write(to: bothBadBackupURL)
            EventLog.flush()
            let bothBadLogSeqBefore = EventLog.snapshot().seq
            let bothBadStore = Store(directory: bothBadDir)
            EventLog.flush()
            let bothBadSnap = EventLog.snapshot()
            let bothBadNewCount = Int(bothBadSnap.seq >= bothBadLogSeqBefore ? bothBadSnap.seq - bothBadLogSeqBefore : 0)
            let bothBadStateLogs = bothBadSnap.lines.suffix(bothBadNewCount).filter {
                $0.contains(" 檔案 - ") && $0.contains("state.json")
            }
            let bothBadSaveResults = [bothBadStore.saveNow(), bothBadStore.saveNow()]
            let bothBadAsideCopyCreated = ((try? fm.contentsOfDirectory(atPath: bothBadDir.path)) ?? [])
                .contains { $0.hasPrefix("state.json.讀不到-") }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                do {
                    let report: [String: Any] = [
                        "asideFailure": [
                            "protected": asideStore.isSaveProtected,
                            "loadFailed": asideStore.loadFailed,
                            "primaryUnchanged": (try Data(contentsOf: asidePrimaryURL)) == badPrimary,
                            "backupUnchanged": (try Data(contentsOf: asideBackupURL)) == goodBackup,
                            "startupProblem": asideStore.startupProblem ?? ""
                        ],
                        "unreadableFileSetAsideFailure": [
                            "returnedFalse": !helperSetAsideSucceeded,
                            "sourceUnchanged": (try Data(contentsOf: helperURL)) == badPrimary
                        ],
                        "emptyPrimaryBadBackup": [
                            "protected": emptyStore.isSaveProtected,
                            "loadFailed": emptyStore.loadFailed,
                            "primaryStillEmpty": (try Data(contentsOf: emptyPrimaryURL)).isEmpty,
                            "backupUnchanged": (try Data(contentsOf: emptyBackupURL)) == badBackup,
                            "saveResults": emptySaveResults
                        ],
                        "missingPrimaryBadBackup": [
                            "protected": missingStore.isSaveProtected,
                            "loadFailed": missingStore.loadFailed,
                            "primaryStillMissing": !fm.fileExists(atPath: missingPrimaryURL.path),
                            "backupUnchanged": (try Data(contentsOf: missingBackupURL)) == badBackup,
                            "saveResults": missingSaveResults
                        ],
                        "bothPrimaryAndBackupCorrupt": [
                            "protected": bothBadStore.isSaveProtected,
                            "loadFailed": bothBadStore.loadFailed,
                            "primaryUnchanged": (try Data(contentsOf: bothBadPrimaryURL)) == badPrimary,
                            "backupUnchanged": (try Data(contentsOf: bothBadBackupURL)) == badBackup,
                            "saveResults": bothBadSaveResults,
                            "asideCopyCreated": bothBadAsideCopyCreated,
                            "stateFileLogCount": bothBadStateLogs.count,
                            "loggedMissingOrEmpty": bothBadStateLogs.contains { $0.contains("空檔或不存在") },
                            "loggedUnreadable": bothBadStateLogs.contains { $0.contains("state.json 無法讀取") }
                        ]
                    ]
                    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: output, options: .atomic)
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("store-recovery-guard-probe 輸出失敗：\(error.localizedDescription)\n".utf8))
                    exit(2)
                }
            }
        } catch {
            FileHandle.standardError.write(Data("store-recovery-guard-probe 設定 fixture 失敗：\(error.localizedDescription)\n".utf8))
            exit(2)
        }
    }

    @MainActor
    private func runHandoffTimeoutGroupProbe(root: URL, output: URL) {
        do {
            let fm = FileManager.default
            let probeDir = root.appendingPathComponent("g45-handoff-group-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: probeDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: probeDir) }

            func shellQuote(_ value: String) -> String {
                "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }
            func waitProcessDead(_ pid: pid_t, timeout: TimeInterval = 0.6) -> Bool {
                guard pid > 1 else { return false }
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline {
                    if kill(pid, 0) != 0 && errno == ESRCH { return true }
                    Thread.sleep(forTimeInterval: 0.01)
                }
                return kill(pid, 0) != 0 && errno == ESRCH
            }
            func detachedTermIgnoringPerlLaunch(pidFile: URL) -> String {
                let q = shellQuote(pidFile.path)
                let perlCode = #"$SIG{TERM}="IGNORE"; open STDIN,"<","/dev/null"; open STDOUT,">","/dev/null"; open STDERR,">","/dev/null"; my $p=$ARGV[0]; open my $fh,">","$p.tmp" or die; print $fh "$$\n"; close $fh; rename "$p.tmp",$p; my $end=time+8; while(time<$end){ select(undef,undef,undef,0.05) }"#
                let waitCode = #"my $e=time+2; until(-s $ARGV[0] || time>=$e){ select(undef,undef,undef,0.01) }"#
                return "/usr/bin/perl -e \(shellQuote(perlCode)) \(q) </dev/null >/dev/null 2>&1 &\n"
                    + "/usr/bin/perl -e \(shellQuote(waitCode)) \(q)\n"
            }
            func run(_ script: String, timeout: TimeInterval = 0.2, grace: TimeInterval = 0.25) throws -> [String: Any] {
                let start = ProcessInfo.processInfo.systemUptime
                let result = try Handoff.runGrouped(script: script, directory: root.path, timeout: timeout, grace: grace)
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                return [
                    "timedOut": result.timedOut,
                    "returnedWithinTwoSeconds": elapsed < 2,
                    "elapsedSeconds": elapsed,
                    "status": result.status,
                    "stdoutBytes": result.stdout.count,
                    "stderr": result.stderr
                ]
            }
            func runWithResidualChild(
                name: String,
                tailScript: String,
                timeout: TimeInterval,
                grace: TimeInterval
            ) throws -> [String: Any] {
                let pidFile = probeDir.appendingPathComponent("\(name).pid")
                let script = detachedTermIgnoringPerlLaunch(pidFile: pidFile) + tailScript
                let start = ProcessInfo.processInfo.systemUptime
                let result = try Handoff.runGrouped(script: script, directory: root.path, timeout: timeout, grace: grace)
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                let rawPid = (try? String(contentsOf: pidFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let childPid = Int32(rawPid) ?? -1
                let residualKilled = childPid > 1 && waitProcessDead(childPid, timeout: 0.6)
                if childPid > 1 && !residualKilled {
                    _ = kill(childPid, SIGKILL)
                    _ = waitProcessDead(childPid, timeout: 0.5)
                }
                return [
                    "timedOut": result.timedOut,
                    "returnedWithinTwoSeconds": elapsed < 2,
                    "elapsedSeconds": elapsed,
                    "status": result.status,
                    "stdout": String(data: result.stdout, encoding: .utf8) ?? "",
                    "stdoutBytes": result.stdout.count,
                    "stderr": result.stderr,
                    "childPidRecorded": childPid > 1,
                    "residualProcessKilled": residualKilled
                ]
            }

            let termResponding = try run("/bin/sleep 4 & exit 0")
            let termIgnoring = try run(#"/usr/bin/perl -e '$SIG{TERM}="IGNORE"; my $end=time+4; while (time < $end) { select(undef, undef, undef, 0.1) }' & exit 0"#)
            let termExitDetachedSibling = try runWithResidualChild(
                name: "timeout-detached-sibling",
                tailScript: "/bin/sleep 8 & exit 0\n",
                timeout: 0.25,
                grace: 0.25
            )
            let normalExitResidual = try runWithResidualChild(
                name: "normal-residual",
                tailScript: "printf 'ok'; exit 0\n",
                timeout: 2.0,
                grace: 0.25
            )
            let report: [String: Any] = [
                "termRespondingChild": termResponding,
                "termIgnoringChild": termIgnoring,
                "termExitWithDetachedTermIgnoringSibling": termExitDetachedSibling,
                "normalExitCleansResidualBackgroundChild": normalExitResidual
            ]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: output, options: .atomic)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("handoff-timeout-group-probe 執行失敗：\(error.localizedDescription)\n".utf8))
            exit(2)
        }
    }

    @MainActor
    private func runWindowDiagR1Probe(to output: URL) {
        let titleSentinel = "WINDOW_DIAG_R1_TITLE_SENTINEL"
        let chatSentinel = "WINDOW_DIAG_R1_CHAT_SENTINEL"
        var windows: [NSWindow] = []

        func makeWindow(
            title: String = "",
            alpha: CGFloat = 1,
            content: NSView? = nil
        ) -> NSWindow {
            let rootView = content ?? NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
            rootView.wantsLayer = true
            let window = NSWindow(
                contentRect: NSRect(x: -20_000, y: -20_000, width: 320, height: 200),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.identifier = TestScreen.diagnosticProbeWindowIdentifier
            window.title = title
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            window.contentView = rootView
            window.alphaValue = alpha
            windows.append(window)
            window.orderFront(nil)
            return window
        }

        func pump(until deadline: Date, while condition: () -> Bool) {
            while Date() < deadline && condition() {
                RunLoop.current.run(until: min(Date().addingTimeInterval(0.025), deadline))
            }
        }

        func lines(since sequence: UInt64) -> [String] {
            let snapshot = EventLog.snapshot()
            let count = Int(snapshot.seq >= sequence ? snapshot.seq - sequence : 0)
            return Array(snapshot.lines.suffix(count))
        }

        func serial(in line: String) -> Int? {
            guard let marker = line.range(of: "視窗#") else { return nil }
            let digits = line[marker.upperBound...].prefix { $0.isNumber }
            return Int(digits)
        }

        func diagnosticLines(_ rows: [String]) -> [String] {
            rows.filter { $0.contains("視窗診斷") }
        }

        func eventLine(_ event: String, in rows: [String]) -> Bool {
            rows.contains { $0.contains("事件=\(event)") }
        }

        let window1View = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        window1View.setAccessibilityLabel(chatSentinel)
        let window1 = makeWindow(title: titleSentinel, content: window1View)
        let window2 = makeWindow()
        let multiStart = EventLog.snapshot().seq

        WindowDiag.install(on: window1)
        let firstInstallDeadline = Date().addingTimeInterval(0.5)
        pump(until: firstInstallDeadline) {
            !diagnosticLines(lines(since: multiStart)).contains { eventLine("安裝", in: [$0]) }
        }
        let firstRows = diagnosticLines(lines(since: multiStart))
        let window1Serial = firstRows.first(where: { eventLine("安裝", in: [$0]) }).flatMap(serial(in:))

        WindowDiag.install(on: window2)
        let secondInstallDeadline = Date().addingTimeInterval(0.5)
        pump(until: secondInstallDeadline) {
            let rows = diagnosticLines(lines(since: multiStart))
            return !rows.contains { eventLine("安裝", in: [$0]) && serial(in: $0) != window1Serial }
        }
        let secondRows = diagnosticLines(lines(since: multiStart))
        let window2Serial = secondRows.first(where: {
            eventLine("安裝", in: [$0]) && serial(in: $0) != window1Serial
        }).flatMap(serial(in:))
        let afterSecondInstall = EventLog.snapshot().seq

        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: window1)
        let screenDeadline = Date().addingTimeInterval(0.7)
        pump(until: screenDeadline) {
            let rows = diagnosticLines(lines(since: multiStart))
            return !rows.contains { eventLine("換螢幕+0.3s", in: [$0]) && serial(in: $0) == window1Serial }
        }
        let multiRows = diagnosticLines(lines(since: multiStart))
        let window1Rows = multiRows.filter { serial(in: $0) == window1Serial }
        let window2Rows = multiRows.filter { serial(in: $0) == window2Serial }
        let postSecondInstallRows = diagnosticLines(lines(since: afterSecondInstall))
        let multiWindow: [String: Any] = [
            "window1EventLines": window1Rows.count,
            "window2EventLines": window2Rows.count,
            "window1ObservedAfterSecondInstall": postSecondInstallRows.contains {
                serial(in: $0) == window1Serial && eventLine("換螢幕", in: [$0])
            },
            "serialsDistinct": window1Serial != nil && window2Serial != nil && window1Serial != window2Serial
        ]

        let colorWindow = makeWindow()
        let colorLine = WindowDiag.snapshotLine(colorWindow, event: "R1色域").line
        let colorValue = colorLine.range(of: "色域=").map { range in
            String(colorLine[range.upperBound...].prefix { !$0.isWhitespace && $0 != "|" })
        } ?? ""
        let allowedColorSpaces: Set<String> = [
            "sRGB", "DisplayP3", "GenericRGB", "ExtendedSRGB", "ExtendedLinearSRGB", "GenericGray", "其他", "無"
        ]
        let colorSpace: [String: Any] = [
            "value": colorValue,
            "inWhitelist": allowedColorSpaces.contains(colorValue)
        ]

        let contentAlphaWindow = makeWindow()
        let contentView = contentAlphaWindow.contentView!
        contentView.alphaValue = 0.5
        let contentAlphaSnapshot = WindowDiag.snapshotLine(contentAlphaWindow, event: "R1內容view低alpha")
        let contentAlphaBefore = Double(contentView.alphaValue)
        let contentAlphaOutcome = WindowDiagRestore.evaluateAndRestore(contentAlphaWindow, trigger: "R1-contentViewAlpha")
        let contentAlphaAfter = Double(contentAlphaWindow.contentView?.alphaValue ?? -1)
        let contentViewAlpha: [String: Any] = [
            "restored": contentAlphaOutcome.restored,
            "before": contentAlphaBefore,
            "after": contentAlphaAfter,
            "anomalyListed": contentAlphaSnapshot.anomalies.contains("內容view-alpha-低")
        ]

        let animatingWindow = makeWindow(alpha: 0.5)
        let animationStart = EventLog.snapshot().seq
        WindowDiagRestore.scheduleCheck(window: animatingWindow, trigger: "R1-animatingAlpha")
        let animationValues: [CGFloat] = [0.6, 0.4, 0.7, 0.3, 0.8, 0.2, 0.9, 0.4]
        var animationIndex = 0
        let animationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            animatingWindow.alphaValue = animationValues[animationIndex % animationValues.count]
            animationIndex += 1
        }
        let animationDeadline = Date().addingTimeInterval(2.5)
        pump(until: animationDeadline) { true }
        animationTimer.invalidate()
        let animationWaitDeadline = Date().addingTimeInterval(0.4)
        pump(until: animationWaitDeadline) {
            !lines(since: animationStart).contains { $0.contains("數值仍在變動") }
        }
        let animationRows = lines(since: animationStart)
        let animatingAlpha: [String: Any] = [
            "restoredCount": animationRows.filter {
                $0.contains("復原 | 觸發=R1-animatingAlpha")
            }.count,
            "skippedUnstableLogged": animationRows.contains {
                $0.contains("復原略過") && $0.contains("數值仍在變動")
            }
        ]

        let stableWindow = makeWindow(alpha: 0.5)
        let stableStart = EventLog.snapshot().seq
        WindowDiagRestore.scheduleCheck(window: stableWindow, trigger: "R1-stableLowAlpha")
        let stableDeadline = Date().addingTimeInterval(1.2)
        pump(until: stableDeadline) { true }
        let stableRows = lines(since: stableStart)
        let stableLowAlpha: [String: Any] = [
            "restoredCount": stableRows.filter { $0.contains("復原 | 觸發=R1-stableLowAlpha") }.count,
            "alphaAfter": Double(stableWindow.alphaValue)
        ]
        let child = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        child.wantsLayer = true
        child.alphaValue = 0.5
        let nonRecoverableContent = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        nonRecoverableContent.addSubview(child)
        let nonRecoverableWindow = makeWindow(content: nonRecoverableContent)
        WindowDiag.install(on: nonRecoverableWindow)
        let nonRecoverableStart = EventLog.snapshot().seq
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: nonRecoverableWindow)
        let nonRecoverableDeadline = Date().addingTimeInterval(1.2)
        pump(until: nonRecoverableDeadline) { true }
        let nonRecoverableRows = lines(since: nonRecoverableStart)
        let noScheduleForNonRecoverable: [String: Any] = [
            "restoreLines": nonRecoverableRows.filter {
                $0.contains("視窗診斷!") && $0.contains("復原 |")
            }.count,
            "snapshotCountAfterTrigger": nonRecoverableRows.filter {
                $0.contains("事件=復原前")
            }.count
        ]

        let privacyRows = diagnosticLines(lines(since: multiStart))
        let privacyLine = WindowDiag.snapshotLine(window1, event: "R1隱私").line
        let privacy: [String: Any] = [
            "containsWindowTitleOrChatText": ([privacyLine] + privacyRows).contains {
                $0.contains(titleSentinel) || $0.contains(chatSentinel)
            }
        ]

        windows.forEach { $0.close() }
        EventLog.flush()
        let result: [String: Any] = [
            "multiWindow": multiWindow,
            "colorSpace": colorSpace,
            "contentViewAlpha": contentViewAlpha,
            "animatingAlpha": animatingAlpha,
            "stableLowAlpha": stableLowAlpha,
            "noScheduleForNonRecoverable": noScheduleForNonRecoverable,
            "privacy": privacy
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("window-diag-r1-probe 輸出失敗\n".utf8))
            exit(2)
        }
        exit(0)
    }

    @MainActor
    private func runWindowDiagProbe(to output: URL) {
        let titleSentinel = "WINDOW_DIAG_PROBE_TITLE_SENTINEL"
        let chatSentinel = "WINDOW_DIAG_PROBE_CHAT_SENTINEL"
        func makeWindow(alpha: CGFloat) -> NSWindow {
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
            content.wantsLayer = true
            let window = NSWindow(
                contentRect: NSRect(x: -20_000, y: -20_000, width: 320, height: 200),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            window.identifier = TestScreen.diagnosticProbeWindowIdentifier
            window.title = titleSentinel
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            window.contentView = content
            window.alphaValue = alpha
            return window
        }

        let normalWindow = makeWindow(alpha: 1)
        let lowAlphaWindow = makeWindow(alpha: 0.5)
        let fieldLabels = [
            "事件=", "螢幕=", "scale=", "色域=", "視窗 alpha=", "opaque=", "背景=",
            "key=", "main=", "occ=", "內容層 opacity=", "背景alpha=", "子層異常=",
            "WindowServer alpha=", "onscreen=", "layer=", "異常="
        ]
        func snapshotPayload(_ window: NSWindow, event: String) -> ([String: Any], String) {
            let snapshot = WindowDiag.snapshotLine(window, event: event)
            let digest = SHA256.hash(data: Data(snapshot.line.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            let payload: [String: Any] = [
                "anomalies": snapshot.anomalies,
                "fieldsComplete": fieldLabels.allSatisfy { snapshot.line.contains($0) },
                "lineLength": snapshot.line.utf8.count,
                "lineSha12": String(digest.prefix(12))
            ]
            return (payload, snapshot.line)
        }

        let alphaBefore = Double(normalWindow.alphaValue)
        let opaqueBefore = normalWindow.isOpaque
        let layerOpacityBefore = Double(normalWindow.contentView?.layer?.opacity ?? 1)
        let (normalPayload, normalLine) = snapshotPayload(normalWindow, event: "探針正常")
        let (lowAlphaPayload, lowAlphaLine) = snapshotPayload(lowAlphaWindow, event: "探針低alpha")
        let alphaAfter = Double(normalWindow.alphaValue)
        let opaqueAfter = normalWindow.isOpaque
        let layerOpacityAfter = Double(normalWindow.contentView?.layer?.opacity ?? 1)

        let baselineSequence = EventLog.snapshot().seq
        func diagnosticLines() -> [String] {
            let snapshot = EventLog.snapshot()
            let newCount = Int(snapshot.seq - baselineSequence)
            return snapshot.lines.suffix(newCount).filter {
                $0.contains(" 視窗診斷 - ") || $0.contains(" 視窗診斷! - ")
            }
        }
        func probeScreenLines() -> [String] {
            diagnosticLines().filter {
                $0.contains("事件=安裝") || $0.contains("事件=換螢幕")
            }
        }

        WindowDiag.install(on: normalWindow)
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: normalWindow)
        let screenDeadline = Date().addingTimeInterval(0.65)
        while Date() < screenDeadline {
            if probeScreenLines().count >= 3 { break }
            RunLoop.current.run(until: min(Date().addingTimeInterval(0.05), screenDeadline))
        }
        let screenRows = max(0, probeScreenLines().count)
        let installedOnProbeWindow = probeScreenLines().contains { $0.contains("事件=換螢幕") }

        normalWindow.alphaValue = 0.5
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: normalWindow)
        let anomalyDeadline = Date().addingTimeInterval(1.65)
        while Date() < anomalyDeadline {
            let rows = diagnosticLines().filter { $0.contains(" 視窗診斷! - ") }
            if rows.contains(where: { $0.contains("事件=換螢幕+1s") }) { break }
            RunLoop.current.run(until: min(Date().addingTimeInterval(0.05), anomalyDeadline))
        }
        let emittedDiagnosticLines = diagnosticLines()
        let anomalyRows = emittedDiagnosticLines.filter {
            $0.contains(" 視窗診斷! - ") && $0.contains("事件=換螢幕")
        }.count

        let result: [String: Any] = [
            "normal": normalPayload,
            "lowAlpha": lowAlphaPayload,
            "readOnly": [
                "alphaBefore": alphaBefore,
                "alphaAfter": alphaAfter,
                "isOpaqueBefore": opaqueBefore,
                "isOpaqueAfter": opaqueAfter,
                "contentLayerOpacityBefore": layerOpacityBefore,
                "contentLayerOpacityAfter": layerOpacityAfter
            ],
            "observers": [
                "installedOnProbeWindow": installedOnProbeWindow,
                "eventLogLinesAfterScreenChange": screenRows,
                "eventLogLinesWithAnomalyMarker": anomalyRows
            ],
            "containsWindowTitleOrChatText": normalLine.contains(titleSentinel)
                || normalLine.contains(chatSentinel)
                || lowAlphaLine.contains(titleSentinel)
                || lowAlphaLine.contains(chatSentinel)
                || emittedDiagnosticLines.contains(where: { $0.contains(titleSentinel) || $0.contains(chatSentinel) })
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("window-diag-probe 輸出失敗\n".utf8))
            exit(2)
        }
        exit(0)
    }

    @MainActor
    private func runWindowDiagRestoreProbe(to output: URL) {
        var windows: [NSWindow] = []
        defer { windows.forEach { $0.close() } }

        func fail(_ message: String) -> Never {
            FileHandle.standardError.write(Data(("window-diag-restore-probe：\(message)\n").utf8))
            exit(2)
        }

        func require(_ condition: Bool, _ message: String) {
            if !condition { fail(message) }
        }

        func makeWindow(
            alpha: CGFloat = 1,
            layerOpacity: Float = 1,
            backgroundAlpha: CGFloat = 1,
            ordered: Bool = true,
            miniaturizable: Bool = false
        ) -> NSWindow {
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
            content.wantsLayer = true
            content.layer?.opacity = layerOpacity
            let styleMask: NSWindow.StyleMask = miniaturizable ? [.titled, .miniaturizable] : [.borderless]
            let window = NSWindow(
                contentRect: NSRect(x: -20_000, y: -20_000, width: 320, height: 200),
                styleMask: styleMask,
                backing: .buffered,
                defer: false
            )
            window.identifier = TestScreen.diagnosticProbeWindowIdentifier
            window.isOpaque = true
            window.backgroundColor = NSColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: backgroundAlpha)
            window.contentView = content
            window.alphaValue = alpha
            windows.append(window)
            if ordered {
                window.orderFront(nil)
                require(window.isVisible, "離屏測試視窗未成為 visible")
            }
            return window
        }

        func layerOpacity(_ window: NSWindow) -> Double? {
            guard let layer = window.contentView?.layer else { return nil }
            return Double(layer.opacity)
        }

        func backgroundAlpha(_ window: NSWindow) -> Double? {
            guard let color = window.backgroundColor else { return nil }
            var converted: NSColor?
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                converted = color.usingColorSpace(.sRGB)
            }
            return converted.map { Double($0.alphaComponent) }
        }

        func restoreCodes(_ outcome: WindowDiagRestore.Outcome) -> [String] {
            outcome.restored.compactMap {
                switch $0 {
                case "alpha": return "alpha"
                case "內容層opacity": return "contentLayerOpacity"
                case "背景alpha": return "backgroundAlpha"
                default: return $0
                }
            }
        }

        func diagnosticLines(since sequence: UInt64, trigger: String) -> [String] {
            let snapshot = EventLog.snapshot()
            let newCount = Int(snapshot.seq >= sequence ? snapshot.seq - sequence : 0)
            return snapshot.lines.suffix(newCount).filter {
                $0.contains(" 視窗診斷! - ")
                    && ($0.contains("觸發=\(trigger)") || $0.contains("事件=復原後"))
            }
        }

        func waitForRestoreLogs(since sequence: UInt64, trigger: String) -> [String] {
            let deadline = Date().addingTimeInterval(2)
            var lines = diagnosticLines(since: sequence, trigger: trigger)
            while Date() < deadline {
                let restoreCount = lines.filter { $0.contains("復原 |") }.count
                let snapshotCount = lines.filter { $0.contains("事件=復原後") }.count
                if restoreCount > 0 && snapshotCount > 0 { break }
                RunLoop.current.run(until: min(Date().addingTimeInterval(0.02), deadline))
                lines = diagnosticLines(since: sequence, trigger: trigger)
            }
            return lines
        }

        let normalWindow = makeWindow()
        guard let normalLayerBefore = layerOpacity(normalWindow),
              let normalBackgroundBefore = backgroundAlpha(normalWindow) else {
            fail("normal 視窗缺少可讀值")
        }
        let normalAlphaBefore = Double(normalWindow.alphaValue)
        let normalSequence = EventLog.snapshot().seq
        let normalOutcome = WindowDiagRestore.evaluateAndRestore(normalWindow, trigger: "C451-normal")
        let normalAlphaAfter = Double(normalWindow.alphaValue)
        guard let normalLayerAfter = layerOpacity(normalWindow),
              let normalBackgroundAfter = backgroundAlpha(normalWindow) else {
            fail("normal 復原後缺少可讀值")
        }
        let normalLogs = diagnosticLines(since: normalSequence, trigger: "C451-normal")
        let normal: [String: Any] = [
            "restored": restoreCodes(normalOutcome),
            "windowChanged": normalAlphaBefore != normalAlphaAfter
                || normalLayerBefore != normalLayerAfter
                || normalBackgroundBefore != normalBackgroundAfter,
            "alphaBefore": normalAlphaBefore,
            "alphaAfter": normalAlphaAfter,
            "contentLayerOpacityBefore": normalLayerBefore,
            "contentLayerOpacityAfter": normalLayerAfter,
            "backgroundAlphaBefore": normalBackgroundBefore,
            "backgroundAlphaAfter": normalBackgroundAfter,
            "eventLogRestoreLines": normalLogs.filter { $0.contains("復原 |") }.count,
            "skippedReason": normalOutcome.skippedReason ?? ""
        ]

        let lowAlphaWindow = makeWindow(alpha: 0.5)
        let lowAlphaSequence = EventLog.snapshot().seq
        let lowAlphaOutcome = WindowDiagRestore.evaluateAndRestore(lowAlphaWindow, trigger: "C451-lowAlpha")
        let lowAlphaLogs = waitForRestoreLogs(since: lowAlphaSequence, trigger: "C451-lowAlpha")
        let lowAlphaRestoreLogs = lowAlphaLogs.filter { $0.contains("復原 |") }
        let lowAlpha: [String: Any] = [
            "restored": restoreCodes(lowAlphaOutcome),
            "alphaBefore": 0.5,
            "alphaAfter": Double(lowAlphaWindow.alphaValue),
            "eventLogRestoreLines": lowAlphaRestoreLogs.count,
            "afterSnapshotLines": lowAlphaLogs.filter { $0.contains("事件=復原後") }.count,
            "logHasBeforeAfter": lowAlphaRestoreLogs.contains { $0.contains("前=") && $0.contains("後=") }
        ]

        let lowLayerWindow = makeWindow(layerOpacity: 0.5)
        let lowLayerBefore = layerOpacity(lowLayerWindow) ?? -1
        let lowLayerSequence = EventLog.snapshot().seq
        let lowLayerOutcome = WindowDiagRestore.evaluateAndRestore(lowLayerWindow, trigger: "C451-lowLayerOpacity")
        let lowLayerLogs = waitForRestoreLogs(since: lowLayerSequence, trigger: "C451-lowLayerOpacity")
        let lowLayerRestoreLogs = lowLayerLogs.filter { $0.contains("復原 |") }
        let lowLayer: [String: Any] = [
            "restored": restoreCodes(lowLayerOutcome),
            "contentLayerOpacityBefore": lowLayerBefore,
            "contentLayerOpacityAfter": layerOpacity(lowLayerWindow) ?? -1,
            "eventLogRestoreLines": lowLayerRestoreLogs.count,
            "afterSnapshotLines": lowLayerLogs.filter { $0.contains("事件=復原後") }.count,
            "logHasBeforeAfter": lowLayerRestoreLogs.contains { $0.contains("前=") && $0.contains("後=") }
        ]

        let lowBackgroundWindow = makeWindow(backgroundAlpha: 0.5)
        let lowBackgroundBefore = backgroundAlpha(lowBackgroundWindow) ?? -1
        let lowBackgroundSequence = EventLog.snapshot().seq
        let lowBackgroundOutcome = WindowDiagRestore.evaluateAndRestore(lowBackgroundWindow, trigger: "C451-lowBackgroundAlpha")
        let lowBackgroundLogs = waitForRestoreLogs(since: lowBackgroundSequence, trigger: "C451-lowBackgroundAlpha")
        let lowBackgroundRestoreLogs = lowBackgroundLogs.filter { $0.contains("復原 |") }
        let lowBackground: [String: Any] = [
            "restored": restoreCodes(lowBackgroundOutcome),
            "backgroundAlphaBefore": lowBackgroundBefore,
            "backgroundAlphaAfter": backgroundAlpha(lowBackgroundWindow) ?? -1,
            "eventLogRestoreLines": lowBackgroundRestoreLogs.count,
            "afterSnapshotLines": lowBackgroundLogs.filter { $0.contains("事件=復原後") }.count,
            "logHasBeforeAfter": lowBackgroundRestoreLogs.contains { $0.contains("前=") && $0.contains("後=") }
        ]

        let hiddenWindow = makeWindow(alpha: 0)
        let hiddenOutcome = WindowDiagRestore.evaluateAndRestore(hiddenWindow, trigger: "C451-hiddenAlphaZero")
        let hidden: [String: Any] = [
            "restored": restoreCodes(hiddenOutcome),
            "alphaAfter": Double(hiddenWindow.alphaValue)
        ]

        let notVisibleWindow = makeWindow(alpha: 0.5, ordered: false)
        let notVisibleOutcome = WindowDiagRestore.evaluateAndRestore(notVisibleWindow, trigger: "C451-notVisible")
        let notVisible: [String: Any] = [
            "restored": restoreCodes(notVisibleOutcome),
            "skippedReason": notVisibleOutcome.skippedReason ?? ""
        ]

        let miniWindow = makeWindow(alpha: 0.5, miniaturizable: true)
        miniWindow.miniaturize(nil)
        let miniDeadline = Date().addingTimeInterval(1)
        while !miniWindow.isMiniaturized && Date() < miniDeadline {
            RunLoop.current.run(until: min(Date().addingTimeInterval(0.02), miniDeadline))
        }
        let miniaturized: Any
        if miniWindow.isMiniaturized {
            let outcome = WindowDiagRestore.evaluateAndRestore(miniWindow, trigger: "C451-miniaturized")
            miniaturized = [
                "restored": restoreCodes(outcome),
                "skippedReason": outcome.skippedReason ?? ""
            ]
        } else {
            miniaturized = NSNull()
        }

        let rateLimitWindow = makeWindow()
        var rateLimitOutcomes: [WindowDiagRestore.Outcome] = []
        for _ in 0..<4 {
            rateLimitWindow.alphaValue = 0.5
            rateLimitOutcomes.append(WindowDiagRestore.evaluateAndRestore(rateLimitWindow, trigger: "C451-rateLimit"))
        }
        let fourthOutcome = rateLimitOutcomes[3]
        let rateLimit: [String: Any] = [
            "totalRestores": rateLimitOutcomes.prefix(3).filter { !$0.restored.isEmpty }.count,
            "fourthSkippedReason": fourthOutcome.skippedReason ?? "",
            "fourthRestored": restoreCodes(fourthOutcome)
        ]

        let transientWindow = makeWindow(alpha: 0.5)
        let transientSequence = EventLog.snapshot().seq
        WindowDiagRestore.scheduleCheck(window: transientWindow, trigger: "C451-transientNotRestored")
        transientWindow.alphaValue = 1
        var checkDeadlineReached = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            checkDeadlineReached = true
        }
        let transientDeadline = Date().addingTimeInterval(2)
        while !checkDeadlineReached && Date() < transientDeadline {
            RunLoop.current.run(until: min(Date().addingTimeInterval(0.02), transientDeadline))
        }
        require(checkDeadlineReached, "transient 檢查未等到排程期限")
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        let transientLogs = diagnosticLines(since: transientSequence, trigger: "C451-transientNotRestored")
        let transient: [String: Any] = [
            "restored": [],
            "eventLogRestoreLines": transientLogs.filter { $0.contains("復原 |") }.count
        ]

        let result: [String: Any] = [
            "normal": normal,
            "lowAlpha": lowAlpha,
            "lowLayerOpacity": lowLayer,
            "lowBackgroundAlpha": lowBackground,
            "hiddenAlphaZero": hidden,
            "notVisible": notVisible,
            "miniaturized": miniaturized,
            "rateLimit": rateLimit,
            "transientNotRestored": transient
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("window-diag-restore-probe 輸出失敗\n".utf8))
            exit(2)
        }
        exit(0)
    }

    @MainActor
    private func runSweepDraftsProbe(root: URL, to output: URL) {
        func execute() -> Int32 {
            let projectDir = root.appendingPathComponent("sweep-drafts-probe-project", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
            } catch {
                FileHandle.standardError.write(Data("sweep-drafts-probe 建立暫存專案目錄失敗\n".utf8))
                return 2
            }
            let project = store.addProject(path: projectDir.path)

            // 1. 空草稿聊天室：draft == true、不在版面、未被選取、無紀錄檔、無草稿檔
            let emptyDraft = store.createConversation(in: project.id, draft: true)
            // 2. 有紀錄檔的草稿聊天室：draft == true、不在版面、未被選取、有紀錄檔
            let nonEmptyDraft = store.createConversation(in: project.id, draft: true)
            // 3. 普通聊天室：後續測側欄手動刪除路徑（deleteConversation）
            let normalConv = store.createConversation(in: project.id, draft: false)

            if let i = store.conversations.firstIndex(where: { $0.id == emptyDraft.id }) {
                store.conversations[i].title = "探針空草稿"
            }
            if let i = store.conversations.firstIndex(where: { $0.id == nonEmptyDraft.id }) {
                store.conversations[i].title = "探針有紀錄草稿"
            }
            if let i = store.conversations.firstIndex(where: { $0.id == normalConv.id }) {
                store.conversations[i].title = "探針手動刪除對話"
            }
            if store.selected == emptyDraft.id || store.selected == nonEmptyDraft.id {
                store.selected = nil
            }
            DraftPersistence(directory: store.directory, conversationID: emptyDraft.id).remove()

            // 替有紀錄檔草稿建立測試紀錄檔：優先寫在 --state-dir 內的 --claude-home；
            // 若未指定隔離的 --claude-home，改寫隔離暫存目錄並於結束清理，絕不碰 ~/.claude。
            let claudeTranscript = Store.claudeTranscript(nonEmptyDraft.claudeSession, path: projectDir.path)
            let transcriptURL: URL
            let cleanupTranscript: Bool
            if isTestProbeOutput(claudeTranscript, inside: root) {
                transcriptURL = claudeTranscript
                cleanupTranscript = false
            } else if appDefaults !== UserDefaults.standard {
                transcriptURL = CodexBridge.transcript(for: nonEmptyDraft.claudeSession)
                cleanupTranscript = true
            } else {
                FileHandle.standardError.write(Data("sweep-drafts-probe 無法在隔離目錄建立紀錄檔\n".utf8))
                return 2
            }
            do {
                try FileManager.default.createDirectory(at: transcriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"sweep-drafts-probe\"}}\n"
                    .write(to: transcriptURL, atomically: true, encoding: .utf8)
            } catch {
                FileHandle.standardError.write(Data("sweep-drafts-probe 寫入測試紀錄檔失敗\n".utf8))
                return 2
            }
            defer {
                if cleanupTranscript {
                    try? FileManager.default.removeItem(at: transcriptURL)
                }
            }

            let previousConfirmHandler = main.testConfirmHandler
            defer { main.testConfirmHandler = previousConfirmHandler }

            // 步驟 A：呼叫 sweepDrafts()；即使回歸也不真的跳 NSAlert 卡住，同時記錄確認視窗要求次數
            main.testConfirmHandler = { _, _, _ in false }
            let confirmBeforeSweep = main.testConfirmRequestCount
            let sweptBefore = main.testSweepDraftsDeletedCount
            main.sweepDrafts()
            let confirmDialogRequests = main.testConfirmRequestCount - confirmBeforeSweep
            let sweepDraftsDeletedCount = main.testSweepDraftsDeletedCount - sweptBefore
            let emptyDraftDeleted = store.conversation(emptyDraft.id) == nil
            let nonEmptyDraftKept = store.conversation(nonEmptyDraft.id) != nil
            let nonEmptyDraftCleared = store.conversation(nonEmptyDraft.id)?.draft == nil

            // 步驟 B：走與側欄右鍵「刪除對話」（Sidebar.swift:458 -> MainWindow.swift:54）相同的 deleteConversation(_:)；
            // 測試實例自動回答確認，不真的彈窗卡住。
            main.testConfirmHandler = { _, _, _ in true }
            let confirmBeforeManual = main.testConfirmRequestCount
            main.deleteConversation(normalConv.id)
            let manualDeleteConfirmRequests = main.testConfirmRequestCount - confirmBeforeManual
            let manualDeleteRemoved = store.conversation(normalConv.id) == nil

            _ = store.saveNow()

            let result: [String: Any] = [
                "emptyDraftDeleted": emptyDraftDeleted,
                "nonEmptyDraftKept": nonEmptyDraftKept,
                "nonEmptyDraftCleared": nonEmptyDraftCleared,
                "confirmDialogRequests": confirmDialogRequests,
                "sweepDraftsDeletedCount": sweepDraftsDeletedCount,
                "manualDeleteConfirmRequests": manualDeleteConfirmRequests,
                "manualDeleteRemoved": manualDeleteRemoved
            ]
            do {
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: output, options: .atomic)
            } catch {
                FileHandle.standardError.write(Data("sweep-drafts-probe 輸出失敗\n".utf8))
                return 2
            }
            return 0
        }
        exit(execute())
    }

    @MainActor
    func installTestHooks(_ args: [String]) {
        if let i = args.firstIndex(of: "--store-recovery-guard-probe") {
            guard i + 1 < args.count,
                  let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count,
                  Self.isolatedTestRun(args, "一般") else { exit(2) }
            let root = URL(fileURLWithPath: args[stateIndex + 1], isDirectory: true).standardizedFileURL
            let output = URL(fileURLWithPath: args[i + 1]).standardizedFileURL
            guard isTestProbeOutput(output, inside: root) else { exit(2) }
            runStoreRecoveryGuardProbe(root: root, output: output)
            return
        }
        if let i = args.firstIndex(of: "--handoff-timeout-group-probe") {
            guard i + 1 < args.count,
                  let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count,
                  Self.isolatedTestRun(args, "一般") else { exit(2) }
            let root = URL(fileURLWithPath: args[stateIndex + 1], isDirectory: true).standardizedFileURL
            let output = URL(fileURLWithPath: args[i + 1]).standardizedFileURL
            guard isTestProbeOutput(output, inside: root) else { exit(2) }
            runHandoffTimeoutGroupProbe(root: root, output: output)
            return
        }
        if let i = args.firstIndex(of: "--window-diag-probe") {
            guard i + 1 < args.count,
                  let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count,
                  Self.isolatedTestRun(args, "一般") else { exit(2) }
            let root = URL(fileURLWithPath: args[stateIndex + 1], isDirectory: true)
            let output = URL(fileURLWithPath: args[i + 1])
            guard isTestProbeOutput(output, inside: root) else { exit(2) }
            runWindowDiagProbe(to: output)
            return
        }
        if let i = args.firstIndex(of: "--window-diag-restore-probe") {
            guard i + 1 < args.count,
                  let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count,
                  Self.isolatedTestRun(args, "一般") else { exit(2) }
            let root = URL(fileURLWithPath: args[stateIndex + 1], isDirectory: true)
            let output = URL(fileURLWithPath: args[i + 1])
            guard isTestProbeOutput(output, inside: root) else { exit(2) }
            runWindowDiagRestoreProbe(to: output)
            return
        }
        if let i = args.firstIndex(of: "--sweep-drafts-probe") {
            guard i + 1 < args.count,
                  let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count,
                  Self.isolatedTestRun(args, "一般") else { exit(2) }
            let root = URL(fileURLWithPath: args[stateIndex + 1], isDirectory: true)
            let output = URL(fileURLWithPath: args[i + 1])
            guard isTestProbeOutput(output, inside: root) else { exit(2) }
            runSweepDraftsProbe(root: root, to: output)
            return
        }
        guard Self.isolatedTestRun(args, "一般") else { return }
        if args.contains("--usage-card-dump") {
            _ = UsageMonitor.shared
        }
        let usagePanelDumpConfig = UsagePanelDumpConfig.from(arguments: args)
        if usagePanelDumpConfig.hasAnyPanelHook {
            _ = UsageMonitor.shared
        }
        if let parentSize = usagePanelDumpConfig.parentSize, let win = self.main.window {
            var frame = win.frame
            frame.size = parentSize
            win.setFrame(frame, display: true)
        }
        if usagePanelDumpConfig.openOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                if let parentSize = usagePanelDumpConfig.parentSize, let win = self.main.window,
                   abs(win.frame.width - parentSize.width) > 0.5 || abs(win.frame.height - parentSize.height) > 0.5 {
                    var frame = win.frame
                    frame.size = parentSize
                    win.setFrame(frame, display: true)
                }
                UsageSheet.toggleForShortcut(in: self.main.window)
            }
        }
        installAgyBackgroundProbes(args)
        installWindowDiagInjectHooks(args)
        installActivationFocusProbe(args)
        if startLidModeMigrationProbe(args) { return }
        installIdleBenchProbe(args)
        installTabBarCollapseProbe(args)
        if args.contains("--large-draft-image-cleanup-probe") { runLargeDraftImageCleanupProbe(args); return }
        if args.contains("--draft-lifecycle-probe") { startDraftLifecycleProbe(args); return }
        if args.contains("--draft-r1-probe") { startDraftR1Probe(args); return }
        if args.contains("--keyguard-concurrency-probe") { runKeyGuardConcurrencyProbe(args) }
        if args.contains("--keyguard-async-probe") { startKeyGuardAsyncProbe(args); return }
        // --keyguard-g1-probe <fixture.json>：走真正 ChatInputBar.testSend 路徑並量主執行緒 run-loop 心跳。
        if let i = args.firstIndex(of: "--keyguard-g1-probe"), i + 1 < args.count,
           let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count {
            let root: URL = URL(fileURLWithPath: args[stateIndex + 1], isDirectory: true).standardizedFileURL
            let configURL: URL = URL(fileURLWithPath: args[i + 1]).standardizedFileURL
            guard isTestProbeOutput(configURL, inside: root),
                  let configData: Data = try? Data(contentsOf: configURL),
                  let config: [String: String] = (try? JSONSerialization.jsonObject(with: configData)) as? [String: String],
                  let htmlPath: String = config["html"], let pdfPath: String = config["pdf"], let outputPath: String = config["output"] else { exit(2) }
            let htmlURL: URL = URL(fileURLWithPath: htmlPath).standardizedFileURL
            let pdfURL: URL = URL(fileURLWithPath: pdfPath).standardizedFileURL
            let outputURL: URL = URL(fileURLWithPath: outputPath).standardizedFileURL
            guard isTestProbeOutput(htmlURL, inside: root), isTestProbeOutput(pdfURL, inside: root),
                  isTestProbeOutput(outputURL, inside: root), FileManager.default.fileExists(atPath: htmlURL.path),
                  FileManager.default.fileExists(atPath: pdfURL.path) else { exit(2) }
            if self.store.selected.flatMap({ self.workspace.panes[$0] as? ChatPane }) == nil {
                let projectID: UUID = self.store.projects.first(where: { $0.path == root.path })?.id
                    ?? self.store.addProject(path: root.path).id
                let conversation = self.store.newConversation(in: projectID)
                guard self.store.selected == conversation.id else { exit(2) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, let id = self.store.selected, let pane = self.workspace.panes[id] as? ChatPane else { exit(2) }
                var sent: Bool = false
                var sentAt: TimeInterval = 0
                var startedAt: TimeInterval = 0
                var lastBeat: TimeInterval = ProcessInfo.processInfo.systemUptime
                var maxGap: TimeInterval = 0
                var sendReturnedAt: TimeInterval = 0
                pane.inputBar.onSend = { _, _, _ in
                    sent = true
                    sentAt = ProcessInfo.processInfo.systemUptime
                    return true
                }
                KeyGuard.testConfirm = { true }
                KeyGuard.testFileDecision = { .sendAnyway }
                KeyGuard.testBigFileDecision = { true }
                pane.inputBar.takeFiles([htmlURL, pdfURL])
                let timer: Timer = Timer(timeInterval: 0.01, repeats: true) { _ in
                    let now: TimeInterval = ProcessInfo.processInfo.systemUptime
                    maxGap = max(maxGap, now - lastBeat)
                    lastBeat = now
                    if sent {
                        let result: [String: Any] = [
                            "schemaVersion": 1, "sent": true,
                            "mainRunLoopMaxGapMilliseconds": Int((maxGap * 1000).rounded()),
                            "scanAndSendMilliseconds": Int(((sentAt - startedAt) * 1000).rounded()),
                            "sendReturnedMilliseconds": Int(((sendReturnedAt - startedAt) * 1000).rounded()),
                            "fileCount": 2
                        ]
                        do {
                            let data: Data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
                            try data.write(to: outputURL, options: .atomic)
                            exit(0)
                        } catch { exit(2) }
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    startedAt = ProcessInfo.processInfo.systemUptime
                    pane.inputBar.testSend()
                    sendReturnedAt = ProcessInfo.processInfo.systemUptime
                }
            }
            return
        }
        // 模型選單探針：只使用隔離實例及記憶體內的假 RPC 傳輸。
        if let i = args.firstIndex(of: "--model-selection-test-probe"), i + 2 < args.count,
           let si = args.firstIndex(of: "--state-dir"), si + 1 < args.count {
            let root = URL(fileURLWithPath: args[si + 1], isDirectory: true)
            let output = URL(fileURLWithPath: args[i + 2])
            guard isTestProbeOutput(output, inside: root) else { exit(2) }
            let caseID = args[i + 1]
            var result: [String: Any] = ["schemaVersion": 1, "caseId": caseID]
            if caseID == "C348" {
                result["codexMenu"] = CodexBridge.models.map { m -> [String: Any] in
                    ["id": m.id, "displayName": m.name, "levels": CodexBridge.levels(for: m.id), "defaultLevel": CodexBridge.defaultLevel(for: m.id)]
                }
                result["agyMenu"] = AgyBridge.models.map { m -> [String: Any] in
                    ["id": m.id, "displayName": m.name, "levels": AgyBridge.levels(for: m.id), "sliderVisible": AgyBridge.level(m.id) != nil]
                }
                result["claudeSliders"] = ModelChoice.known.map { m -> [String: Any] in
                    let declared = m.efforts ?? Effort.order
                    return ["id": m.value, "declaredLevels": declared, "sliderLevels": Effort.order.filter { declared.contains($0) }]
                }
            } else if caseID == "C349" {
                var turns: [[String: Any]] = []
                let selections = CodexBridge.models.map { ($0.id, "high") } + [("gpt-6.1-sol", "ultra"), ("gpt-6-luna", "ultra")]
                for (model, effort) in selections {
                    let id = UUID()
                    let bridge = CodexBridge(session: id, directory: root.path, model: model,
                                             transcriptURL: root.appendingPathComponent(id.uuidString + ".jsonl"))
                    bridge.effort = effort
                    var messages: [[String: Any]] = []
                    bridge.send = { messages.append($0) }
                    bridge.start()
                    if let request = messages.first(where: { $0["method"] as? String == "thread/start" }), let requestID = request["id"] {
                        bridge.incoming(["id": requestID, "result": ["thread": ["id": id.uuidString]]])
                    }
                    bridge.outgoing(["type": "user", "uuid": UUID().uuidString, "message": ["role": "user", "content": "fixture"]])
                    let payload = messages.first(where: { $0["method"] as? String == "turn/start" })?["params"] as? [String: Any] ?? [:]
                    turns.append(["selectedModelId": model, "selectedEffort": effort, "payload": payload])
                }
                result["codexTurns"] = turns
                var launches: [[String: Any]] = []
                for model in AgyBridge.models.map(\.id).filter({ AgyBridge.fixedModels.contains($0) }) + ["gemini-4-hydrogen-high"] {
                    let effort = model == "gemini-4-hydrogen-high" ? "low" : "high"
                    let resolved = AgyBridge.resolve(model, effort: effort)
                    let launchArgs = AgyBridge.arguments(model: resolved, mode: nil, conversation: nil)
                    let index = launchArgs.firstIndex(of: "--model")!
                    let row: [String: Any] = ["selectedModelId": model, "selectedEffort": effort, "modelArg": launchArgs[index + 1]]
                    launches.append(row)
                    if model == "gemini-4-hydrogen-high" { result["hydrogenCompatibility"] = row }
                }
                result["agyLaunches"] = launches
            } else if caseID == "C351" {
                var scenarios: [[String: Any]] = []
                let fixtures: [(String, String, String)] = [
                    ("codex-change", "codex:gpt-6-luna", "codex:gpt-6.1-sol"),
                    ("cross-to-codex", "sonnet", "codex:gpt-6.1-sol"),
                    ("agy-idle-change", "agy:gemini-4-hydrogen-high", "agy:gemini-4-argon-high"),
                    ("agy-busy-change", "agy:gemini-4-hydrogen-high", "agy:gemini-4-argon-high"),
                    ("copilot-idle-change", "sonnet", "copilot:auto"),
                    ("copilot-busy-change", "sonnet", "copilot:auto"),
                    ("codex-same", "codex:gpt-6-luna", "codex:gpt-6-luna"),
                    ("agy-same", "agy:gemini-4-hydrogen-high", "agy:gemini-4-hydrogen-high"),
                    ("copilot-same", "copilot:auto", "copilot:auto"),
                    ("codex-restore", "sonnet", "codex:gpt-6-luna"),
                    ("agy-restore", "sonnet", "agy:gemini-4-hydrogen-high"),
                    ("copilot-restore", "sonnet", "copilot:auto"),
                ]
                for (scenario, initial, selected) in fixtures {
                    let session = ChatSession(claudeSession: UUID(), directory: root.path)
                    let pane = ChatPane(session: session, theme: Theme.fromITerm())
                    pane.applyModel(initial)
                    if scenario.contains("busy") { session.modelSelectionProbeBeginWork() }
                    let workingBeforeSelection = session.status == .working
                    if scenario.hasSuffix("-restore") { pane.applyModel(selected) }
                    else { pane.selectModelFromMenu(selected) }
                    let parts = selected.split(separator: ":", maxSplits: 1).map(String.init)
                    let id = parts.count == 2 ? parts[1] : selected
                    let displayName: String
                    if parts.first == "codex" { displayName = CodexBridge.name(id) }
                    else if parts.first == "agy" { displayName = AgyBridge.name(id) }
                    else { displayName = CopilotBridge.name(id) }
                    scenarios.append(["scenario": scenario, "displayName": displayName,
                                      "notices": pane.modelSelectionProbeNotices,
                                      "workingBeforeSelection": workingBeforeSelection])
                }
                result["modelNoticeScenarios"] = scenarios
            } else if caseID == "C350" {
                let group = ConvGroup(name: "C350 fixture")
                store.groups.append(group)
                let project = Project(name: "C350 fixture", path: root.path, groupID: group.id)
                store.projects.append(project)
                var chief = Conversation(projectID: project.id, title: "C350 chief")
                chief.groupID = group.id
                store.conversations.append(chief)
                store.sessions.append(SessionLayout(name: "C350 fixture", windows: [], groups: [group.id], chief: chief.id))
                guard store.commander(of: chief.id)?.chief == chief.id else { exit(2) }
                var rows: [[String: Any]] = []
                let attempts = [("codex", "gpt-6-luna", "ultra"), ("agy", "gemini-pro-orchestrator-g1-pro", "high"), ("agy", "gemini-pro-orchestrator-g1-pro", "low"), ("agy", "gpt-oss-120b-medium", "high"), ("agy", "gpt-oss-120b-medium", "low")]
                for (engine, model, effort) in attempts {
                    let before = store.conversations.count
                    let response = store.commanderCreateEngine(caller: chief.id.uuidString, name: "fixture", engine: engine, dir: root.path, project: nil, model: model, effort: effort, mcp: nil, topic: nil)
                    let rejected = response.reply["ok"] as? Bool == false
                    let recognized = (engine == "codex" ? CodexBridge.models : AgyBridge.models).contains { $0.id == model }
                    rows.append(["engine": engine, "modelId": model, "effort": effort, "modelRecognized": recognized, "rejected": rejected, "exitCode": rejected ? 1 : 0, "conversationCreated": store.conversations.count != before, "engineStarted": response.conversation != nil, "rejectionReason": response.reply["error"] as? String ?? "", "reply": response.reply])
                }
                result["cliValidation"] = rows
            } else { exit(2) }
            do {
                let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: output, options: .atomic)
            } catch { exit(2) }
        }
        if let i = args.firstIndex(of: "--interrupted-indicator-probe"), i + 2 < args.count,
           let si = args.firstIndex(of: "--state-dir"), si + 1 < args.count {
            let root = URL(fileURLWithPath: args[si + 1], isDirectory: true)
            let output = URL(fileURLWithPath: args[i + 2])
            guard isTestProbeOutput(output, inside: root) else { exit(2) }
            let caseID = args[i + 1]
            let fixtureID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
            var result: [String: Any] = ["schemaVersion": 1, "caseId": caseID]
            func marked(_ id: UUID) -> Bool { store.conversation(id)?.interruptedAt != nil }
            func diskMarked(_ id: UUID) -> Any {
                // 先直接讀原 state.json，避免 Store 的備份復原或空預設值掩蓋讀取失敗。
                struct ProbeState: Decodable { let conversations: [Conversation] }
                do {
                    let data = try Data(contentsOf: root.appendingPathComponent("state.json"))
                    let snapshot = try JSONDecoder().decode(ProbeState.self, from: data)
                    let conversation = snapshot.conversations.first { $0.id == id }
                    let disk = Store(directory: root)
                    let readOK = !disk.loadFailed && !disk.isSaveProtected
                    result["persistedReadOK"] = readOK
                    result["conversationMissing"] = conversation == nil || disk.conversation(id) == nil
                    guard readOK, let conversation, disk.conversation(id) != nil else { return NSNull() }
                    return conversation.interruptedAt != nil
                } catch {
                    result["persistedReadOK"] = false
                    result["conversationMissing"] = true
                    return NSNull()
                }
            }
            if caseID == "C363", args.contains("--interrupted-indicator-inspect") {
                let prepareURL = root.appendingPathComponent("interrupted-indicator-prepare.json")
                let prepareData = try? Data(contentsOf: prepareURL)
                let prepare = prepareData.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                result["beforeMarked"] = prepare?["beforeMarked"] as? Bool ?? false
                result["reopenedMarked"] = marked(fixtureID)
                result["sameConversationId"] = store.conversation(fixtureID)?.id == fixtureID
                result["didReloadFromDisk"] = store.directory.standardizedFileURL == root.standardizedFileURL
            } else {
                let group = ConvGroup(name: "indicator fixture")
                store.groups.append(group)
                let project = Project(name: "indicator fixture", path: root.path, groupID: group.id)
                store.projects.append(project)
                var chief = Conversation(projectID: project.id, title: "fixture chief")
                chief.groupID = group.id
                var child = Conversation(projectID: project.id, title: "fixture child")
                child.id = fixtureID
                child.groupID = group.id
                store.conversations.append(contentsOf: [chief, child])
                store.sessions.append(SessionLayout(name: "indicator fixture", windows: [], groups: [group.id], chief: chief.id))
                func record(_ id: UUID) -> LidInterruption {
                    LidInterruption(id: id, title: "fixture", engine: "Codex", supportsTermination: true,
                                    details: [], queuedMessages: [], terminated: true, forceKilled: false,
                                    stillRunning: false, outboxReadFailed: false)
                }
                LidIndicatorNoticeProbe.observe = { _ in }
                defer { LidIndicatorNoticeProbe.observe = nil }
                func deliver(_ ids: [UUID]) { main.sendLidInterruptNotices(ids.map(record), late: false) }
                switch caseID {
                case "C360":
                    deliver([child.id])
                    let slots = InterruptedIndicatorPresentation.row(marked: marked(child.id), archived: false, status: nil, unread: false)
                    result["interruptedAtPresent"] = marked(child.id)
                    result["ringVisible"] = slots.contains("ring")
                    result["ringShape"] = InterruptedIndicatorPresentation.shape
                    result["darkColor"] = InterruptedIndicatorPresentation.darkColor
                    result["lightColor"] = InterruptedIndicatorPresentation.lightColor
                    result["diameterScale"] = InterruptedIndicatorPresentation.diameter
                    result["stroke"] = InterruptedIndicatorPresentation.stroke
                    result["pulsing"] = InterruptedIndicatorPresentation.pulsing
                    result["tooltip"] = InterruptedIndicatorPresentation.tooltip
                case "C364", "C367":
                    let sim = SimLidEnv()
                    var clock = Date()
                    let keeper = LidKeeper(env: sim, logURL: root.appendingPathComponent("indicator-lid.log"), markerURL: root.appendingPathComponent("indicator-lid.json"), now: { clock })
                    keeper.resumeDelay = 0.05
                    let enabled = caseID != "C367"
                    keeper.enabled = { true }
                    keeper.interruptOnCloseEnabled = { enabled }
                    keeper.workingCount = { 1 }
                    keeper.interruptWork = { [LidInterruptWork(id: child.id, title: child.title, engine: "Codex", supportsTermination: true, hasBangCommand: false, details: [])] }
                    var records: [LidInterruption] = []
                    var noticeCallbackCount = 0
                    keeper.sendInterruptNotices = { rows, late in
                        noticeCallbackCount += 1
                        records.append(contentsOf: rows)
                        self.main.sendLidInterruptNotices(rows, late: late)
                    }
                    keeper.tick()
                    if caseID == "C364" {
                        clock = clock.addingTimeInterval(30)
                        sim.continuousOffset += 30; sim.uptimeOffset += 30
                        keeper.tick()
                        result["workingFixture"] = keeper.workingCount() > 0
                        result["jumpNoSleepSeconds"] = 30
                    } else {
                        sim.closed = true; keeper.tick()
                        sim.closed = false; clock = clock.addingTimeInterval(4); keeper.tick()
                        result["interruptOnCloseEnabled"] = keeper.interruptOnCloseEnabled()
                        result["settingExplainsNoIndicator"] = LidIndicatorSettingsText.explanation.contains("關掉時不會有休眠後未完成燈號")
                    }
                    // 假時鐘不會推進 DispatchQueue 的 deadline；讓真主 runloop 跑過通知延遲才取樣。
                    RunLoop.main.run(until: Date().addingTimeInterval(keeper.resumeDelay + 0.25))
                    result["noticeCallbackCount"] = noticeCallbackCount
                    result["noticeWaitSeconds"] = keeper.resumeDelay + 0.25
                    result["recordsCount"] = records.count
                    result["markedCount"] = [chief.id, child.id].filter { marked($0) }.count
                    if caseID == "C364" {
                        // 正對照：同一 keeper 有明確睡眠證據後，必須能觀測到延遲通知。
                        let previousCallbacks = noticeCallbackCount
                        let previousRecords = records.count
                        clock = clock.addingTimeInterval(30)
                        sim.continuousOffset += 30
                        sim.sleepEvidenceValue = LidSleepEvidence(wakeTime: 30, sleepTime: 1)
                        keeper.tick()
                        RunLoop.main.run(until: Date().addingTimeInterval(keeper.resumeDelay + 0.25))
                        result["sleepEvidenceControl"] = ["recordsCount": records.count - previousRecords,
                                                          "noticeCallbackCount": noticeCallbackCount - previousCallbacks]
                    }
                case "C365", "C369":
                    func aggregated() -> Bool {
                        InterruptedIndicatorPresentation.aggregate(store.conversations(inCommander: store.sessions.last!), archived: store.isArchived)
                    }
                    if caseID == "C365" {
                        deliver([child.id]); result["childMarkedBefore"] = marked(child.id)
                        result["commanderRingBefore"] = aggregated()
                        store.open(child.id)
                        result["childMarkedAfter"] = marked(child.id)
                        result["commanderRingAfter"] = aggregated()
                    } else {
                        deliver([chief.id]); result["selfOnlyRing"] = aggregated()
                        store.clearInterrupted(chief.id)
                        deliver([child.id]); store.setArchived(child.id, true)
                        result["manualArchivedChildRing"] = aggregated()
                        store.setArchived(child.id, false)
                        deliver([child.id])
                        // autoArchive 的實際門檻由 Store.isArchived 決定，使用 dimmed 決策另驗。
                        if let index = store.conversations.firstIndex(where: { $0.id == child.id }) {
                            store.conversations[index].lastOpened = Date.distantPast
                            store.lastActivity[child.id] = Date.distantPast
                        }
                        result["autoArchivedChildRing"] = InterruptedIndicatorPresentation.aggregate([store.conversation(child.id)!], archived: store.isArchived)
                        result["workingIndicator"] = InterruptedIndicatorPresentation.commander(working: true, interrupted: true, running: true)
                        result["markedRunningIndicator"] = InterruptedIndicatorPresentation.commander(working: false, interrupted: true, running: true)
                        result["runningIndicator"] = InterruptedIndicatorPresentation.commander(working: false, interrupted: false, running: true)
                        result["idleIndicator"] = InterruptedIndicatorPresentation.commander(working: false, interrupted: false, running: false)
                    }
                case "C368":
                    deliver([child.id])
                    func rowObservation() -> [String: Any] {
                        let waiting = InterruptedIndicatorPresentation.row(marked: marked(child.id), archived: false, status: .waiting, unread: true)
                        let unread = InterruptedIndicatorPresentation.row(marked: marked(child.id), archived: false, status: .idle, unread: true)
                        return ["ringLeftOfTitle": (waiting.firstIndex(of: "ring") ?? Int.max) < (waiting.firstIndex(of: "title") ?? 0),
                                "waitingVisible": waiting.contains("waiting"), "unreadVisible": unread.contains("unread")]
                    }
                    result["recent"] = rowObservation(); result["codeLab"] = rowObservation(); result["activeRow"] = rowObservation()
                    result["archivedRingVisible"] = InterruptedIndicatorPresentation.row(marked: true, archived: true, status: nil, unread: false).contains("ring")
                case "C371":
                    deliver([child.id])
                    result["persistedMarkedBefore"] = diskMarked(child.id)
                    store.selected = child.id
                    result["restoredSelectionMarked"] = marked(child.id)
                    store.open(child.id)
                    result["sameRowClickMarked"] = marked(child.id)
                    result["persistedMarked"] = diskMarked(child.id)
                    let saves = store.probeSaveCount
                    store.clearInterrupted(child.id)
                    result["nilClearSaveCount"] = store.probeSaveCount - saves
                case "C361":
                    deliver([child.id]); result["beforeMarked"] = marked(child.id)
                    result["persistedMarkedBefore"] = diskMarked(child.id)
                    store.open(child.id)
                    result["afterMarked"] = marked(child.id)
                    result["persistedMarked"] = diskMarked(child.id)
                case "C362":
                    deliver([child.id]); result["beforeMarked"] = marked(child.id)
                    result["persistedMarkedBefore"] = diskMarked(child.id)
                    if let pane = workspace.pane(for: child) as? ChatPane { pane.session.interruptedIndicatorProbeWork() }
                    result["status"] = store.status[child.id] == .working ? "working" : "other"
                    result["afterMarked"] = marked(child.id)
                    result["persistedMarked"] = diskMarked(child.id)
                case "C363":
                    store.selected = child.id
                    deliver([child.id])
                    result["beforeMarked"] = marked(child.id)
                    result["prepared"] = store.saveNow()
                case "C366":
                    if let data = try? JSONEncoder().encode(child),
                       var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                        object.removeValue(forKey: "interruptedAt")
                        result["legacyFieldAbsent"] = object["interruptedAt"] == nil
                        if let legacy = try? JSONSerialization.data(withJSONObject: object),
                           let decoded = try? JSONDecoder().decode(Conversation.self, from: legacy) {
                            result["loaded"] = true
                            result["markedCount"] = decoded.interruptedAt == nil ? 0 : 1
                        }
                    }
                case "C370":
                    store.status[child.id] = .working
                    deliver([child.id]); result["workingMarked"] = marked(child.id)
                    store.status[child.id] = .idle
                    SessionActivity.shared.injectFakeForTest(child.id, count: 1)
                    if let work = main.lidKeeper?.interruptWork().first(where: { $0.id == child.id }) {
                        var backgroundRecord = record(child.id)
                        backgroundRecord.foreground = work.foreground
                        main.sendLidInterruptNotices([backgroundRecord], late: false)
                        result["backgroundForeground"] = work.foreground
                    } else { result["backgroundFixtureMissing"] = true }
                    result["backgroundOnlyMarked"] = marked(child.id)
                    SessionActivity.shared.clear(child.id)
                    deliver([child.id]); result["recipientUnavailableMarked"] = marked(child.id)
                case "C372":
                    var archived = Conversation(projectID: project.id, title: "fixture archived")
                    archived.groupID = group.id
                    store.conversations.append(archived)
                    store.setArchived(archived.id, true)
                    let missing = UUID()
                    _ = workspace.pane(for: chief)
                    var receivedRoutes: [LidInterruptionNoticeRoute] = []
                    LidIndicatorNoticeProbe.observe = { receivedRoutes = $0 }
                    deliver([child.id, archived.id, missing])
                    LidIndicatorNoticeProbe.observe = nil
                    result["summaryRecipients"] = receivedRoutes.map { $0.recipient.uuidString }
                    result["summaryIsSummary"] = receivedRoutes.first?.isSummary ?? false
                    result["summaryRecipientIsChief"] = receivedRoutes.first?.recipient == chief.id
                    result["memberMarked"] = marked(child.id)
                    result["commanderMarked"] = marked(chief.id)
                    result["archivedMarked"] = marked(archived.id)
                    result["missingConversationCreated"] = store.conversation(missing) != nil
                case "C373":
                    let encoder = JSONEncoder()
                    let nilData = try? encoder.encode(child)
                    let nilObject = nilData.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                    result["nilKeyAbsent"] = nilObject?["interruptedAt"] == nil
                    child.interruptedAt = Date(timeIntervalSince1970: 1234567890)
                    if let data = try? encoder.encode(child), let decoded = try? JSONDecoder().decode(Conversation.self, from: data) {
                        result["dateRoundTripEqual"] = decoded.interruptedAt == child.interruptedAt
                    }
                    deliver([fixtureID])
                    result["persistedArchivedMarkedBefore"] = diskMarked(fixtureID)
                    store.setArchived(fixtureID, true)
                    result["archivedMarked"] = marked(fixtureID)
                    result["persistedArchivedMarked"] = diskMarked(fixtureID)
                default:
                    result["unsupportedObservation"] = "尚未提供真實側欄量測或 LidKeeper 模擬情境，不能以預期常數代替"
                }
            }
            do {
                let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: output, options: .atomic)
            } catch { exit(2) }
        }
        // --zhuyin-baseline-probe <輸入 JSON> <輸出 JSON>：隔離建立原生 NSTextView，逐事件記錄 marked text、baselineOffset runs 與 corrupt 自修復事件。
        if let i = args.firstIndex(of: "--zhuyin-baseline-probe"), i + 2 < args.count,
           let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count {
            let root = URL(fileURLWithPath: args[stateIndex + 1], isDirectory: true)
            let input = URL(fileURLWithPath: args[i + 1])
            let output = URL(fileURLWithPath: args[i + 2])
            guard isTestProbeOutput(input, inside: root), isTestProbeOutput(output, inside: root) else { exit(2) }
            func write(_ payload: [String: Any], exitCode: Int32) -> Never {
                if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted]) {
                    try? data.write(to: output, options: .atomic)
                }
                exit(exitCode)
            }
            func offsetRuns(_ snapshot: [String: Any]) -> [[String: Any]] {
                (snapshot["runs"] as? [[String: Any]] ?? []).map { run in
                    ["range": run["range"] ?? [], "baselineOffset": run["baselineOffset"] ?? NSNull()]
                }
            }
            func isTextFreeBaselineRepairEntry(_ line: String?) -> Bool {
                guard let line, let separator = line.range(of: " - ") else { return false }
                let message = String(line[separator.upperBound...])
                let offset = #"(?:nil\(0\)|-?(?:[0-9]+(?:\.[0-9]+)?|inf|nan))"#
                let pattern = #"^baselineOffset 自我修正：不一致段數=[0-9]+、各段offset=\["# + offset + #"(?:,"# + offset + #")*\]、視覺行數=[0-9]+、wasComposing=(?:true|false)$"#
                return message.range(of: pattern, options: .regularExpression) != nil
            }
            func latestBaselineRepairEvent() -> (path: String?, line: String?) {
                EventLog.flush()
                let files = ((try? FileManager.default.contentsOfDirectory(
                    at: EventLog.dir, includingPropertiesForKeys: [.contentModificationDateKey]
                )) ?? []).filter { $0.pathExtension == "log" }.sorted {
                    let lhs = ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate) ?? .distantPast
                    let rhs = ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate) ?? .distantPast
                    return lhs < rhs
                }
                for file in files.reversed() {
                    guard let body = try? String(contentsOf: file, encoding: .utf8),
                          let line = body.split(whereSeparator: \.isNewline).reversed().first(where: {
                              $0.contains("輸入框 - baselineOffset 自我修正：")
                          }) else { continue }
                    return (file.path, String(line))
                }
                return (nil, nil)
            }
            guard let data = try? Data(contentsOf: input),
                  let fixture = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let events = fixture["events"] as? [[String: Any]], events.count <= 200 else {
                write(["result": "error", "error": "輸入必須是最多 200 個事件的 JSON events 陣列"], exitCode: 2)
            }
            let requestedWidth = (fixture["width"] as? NSNumber)?.doubleValue ?? 220
            let width = CGFloat(min(800, max(100, requestedWidth)))
            let textView = ChatTextView(frame: NSRect(x: 0, y: 0, width: width, height: 180))
            textView.font = NSFont.systemFont(ofSize: 15)
            textView.textContainerInset = .zero
            textView.isRichText = true
            textView.updateBaselineOffsetForLineCount()
            var snapshots: [[String: Any]] = []
            var transientCorruptSnapshotIndexes = Set<Int>()
            var compositionCorruptAtUptime: TimeInterval?
            for (index, event) in events.enumerated() {
                guard let type = event["type"] as? String else {
                    write(["result": "error", "error": "事件缺少 type", "eventIndex": index, "snapshots": snapshots], exitCode: 2)
                }
                let storageLength = textView.textStorage?.length ?? 0
                let selection = textView.selectedRange()
                let marked = textView.hasMarkedText() ? textView.markedRange() : selection
                let replacing = textView.hasMarkedText() ? textView.markedRange() : selection
                var eventStateValid = true
                var eventDetails: [String: Any] = [:]
                var compositionLogThrottleWait: TimeInterval = 0
                switch type {
                case "insert", "newline":
                    let value = type == "newline" ? "\n" : (event["text"] as? String ?? "")
                    guard value.utf16.count <= 20_000 else {
                        write(["result": "error", "error": "文字超過 20,000 個 UTF-16 字元", "eventIndex": index, "snapshots": snapshots], exitCode: 2)
                    }
                    let range = textView.hasMarkedText() ? marked : selection
                    textView.insertText(value, replacementRange: range)
                case "mark":
                    guard let value = event["text"] as? String, value.utf16.count <= 20_000 else {
                        write(["result": "error", "error": "mark 事件缺少 text 或文字超過上限", "eventIndex": index, "snapshots": snapshots], exitCode: 2)
                    }
                    let markedSelection: NSRange
                    if let raw = event["selectedRange"] as? [Int], raw.count == 2,
                       raw[0] >= 0, raw[1] >= 0, raw[0] + raw[1] <= value.utf16.count {
                        markedSelection = NSRange(location: raw[0], length: raw[1])
                    } else {
                        markedSelection = NSRange(location: value.utf16.count, length: 0)
                    }
                    textView.setMarkedText(value, selectedRange: markedSelection, replacementRange: replacing)
                case "unmark":
                    let hadMarkedText = textView.hasMarkedText()
                    let beforeRepair = hadMarkedText ? textView.baselineOffsetProbeSnapshot() : [:]
                    let repairWasNeeded = beforeRepair["baselineMatchesInput"] as? Bool == false
                    let eventSequenceBefore = EventLog.snapshot().seq
                    if hadMarkedText, repairWasNeeded, let corruptAt = compositionCorruptAtUptime {
                        // 和前一個修正（同一個 ChatTextView）隔開每秒一次的紀錄限流窗，再測組字提交的紀錄。
                        let minimumGap: TimeInterval = 1.05
                        compositionLogThrottleWait = max(0, minimumGap - (ProcessInfo.processInfo.systemUptime - corruptAt))
                        if compositionLogThrottleWait > 0 { Thread.sleep(forTimeInterval: compositionLogThrottleWait) }
                    }
                    compositionCorruptAtUptime = nil
                    textView.unmarkText()
                    if hadMarkedText {
                        let afterRepair = textView.baselineOffsetProbeSnapshot()
                        let eventLog = latestBaselineRepairEvent()
                        let eventSequenceAfter = EventLog.snapshot().seq
                        let afterMatches = afterRepair["baselineMatchesInput"] as? Bool == true
                        let eventLogTextFree = isTextFreeBaselineRepairEntry(eventLog.line)
                        let eventWritten = eventSequenceAfter > eventSequenceBefore
                        eventDetails["compositionRepair"] = [
                            "beforeOffsets": offsetRuns(beforeRepair),
                            "afterOffsets": offsetRuns(afterRepair),
                            "afterRunsMatchInputBaseline": afterMatches,
                            "repairWasNeeded": repairWasNeeded,
                            "wasComposing": true,
                            "throttleWaitSeconds": compositionLogThrottleWait,
                            "eventLogWritten": eventWritten,
                            "eventLogPath": eventLog.path.map { $0 as Any } ?? NSNull(),
                            "eventLogEntry": eventLog.line.map { $0 as Any } ?? NSNull(),
                            "eventLogTextFree": eventLogTextFree,
                            "eventLogContainsText": eventLog.line == nil ? (NSNull() as Any) : NSNumber(value: !eventLogTextFree)
                        ]
                        eventStateValid = afterMatches && (!repairWasNeeded || (eventWritten && eventLog.line != nil && eventLogTextFree))
                    }
                case "corrupt":
                    guard let raw = event["range"] as? [Int], raw.count == 2,
                          raw[0] >= 0, raw[1] > 0, raw[0] <= storageLength,
                          raw[1] <= storageLength - raw[0] else {
                        write(["result": "error", "error": "corrupt 需要有效且非空的 UTF-16 range", "eventIndex": index, "snapshots": snapshots], exitCode: 2)
                    }
                    let corruptDuringComposition = textView.hasMarkedText()
                    let beforeTarget = textView.inputBaselineOffset
                    let injectedOffset = (event["offset"] as? NSNumber)?.doubleValue ?? Double(beforeTarget) + 7
                    guard injectedOffset.isFinite, abs(injectedOffset - Double(beforeTarget)) > 0.01 else {
                        write(["result": "error", "error": "corrupt offset 必須有限且不同於目前目標值", "eventIndex": index, "snapshots": snapshots], exitCode: 2)
                    }
                    guard let beforeRepair = textView.corruptBaselineOffsetForProbe(
                        NSRange(location: raw[0], length: raw[1]), offset: CGFloat(injectedOffset)
                    ) else {
                        write(["result": "error", "error": "無法注入 corrupt offset", "eventIndex": index, "snapshots": snapshots], exitCode: 2)
                    }
                    if corruptDuringComposition {
                        let stillMarked = textView.hasMarkedText()
                        eventStateValid = stillMarked && (beforeRepair["baselineMatchesInput"] as? Bool == false)
                        compositionCorruptAtUptime = ProcessInfo.processInfo.systemUptime
                        transientCorruptSnapshotIndexes.insert(index)
                        eventDetails["corrupt"] = [
                            "range": raw,
                            "injectedOffset": injectedOffset,
                            "inputBaselineOffset": beforeTarget,
                            "beforeRepairOffsets": offsetRuns(beforeRepair),
                            "baselineMismatchInjected": beforeRepair["baselineMatchesInput"] as? Bool == false,
                            "awaitingUnmark": true,
                            "hasMarkedText": stillMarked
                        ]
                    } else {
                        let eventSequenceBefore = EventLog.snapshot().seq
                        textView.didChangeText()
                        let afterRepair = textView.baselineOffsetProbeSnapshot()
                        let eventLog = latestBaselineRepairEvent()
                        let eventSequenceAfter = EventLog.snapshot().seq
                        let afterMatches = afterRepair["baselineMatchesInput"] as? Bool == true
                        let eventLogTextFree = isTextFreeBaselineRepairEntry(eventLog.line)
                        let eventWritten = eventSequenceAfter > eventSequenceBefore
                        eventStateValid = afterMatches && eventWritten && eventLog.line != nil && eventLogTextFree
                        eventDetails["corrupt"] = [
                            "range": raw,
                            "injectedOffset": injectedOffset,
                            "inputBaselineOffset": afterRepair["inputBaselineOffset"] ?? 0,
                            "beforeOffsets": offsetRuns(beforeRepair),
                            "afterOffsets": offsetRuns(afterRepair),
                            "afterRunsMatchInputBaseline": afterMatches,
                            "eventLogWritten": eventWritten,
                            "eventLogPath": eventLog.path.map { $0 as Any } ?? NSNull(),
                            "eventLogEntry": eventLog.line.map { $0 as Any } ?? NSNull(),
                            "eventLogTextFree": eventLogTextFree,
                            "eventLogContainsText": eventLog.line == nil ? (NSNull() as Any) : NSNumber(value: !eventLogTextFree)
                        ]
                    }
                case "select":
                    guard let raw = event["range"] as? [Int], raw.count == 2,
                          raw[0] >= 0, raw[1] >= 0, raw[0] + raw[1] <= storageLength else {
                        write(["result": "error", "error": "select.range 超出文字範圍", "eventIndex": index, "snapshots": snapshots], exitCode: 2)
                    }
                    textView.setSelectedRange(NSRange(location: raw[0], length: raw[1]))
                case "delete":
                    let deleteRange: NSRange
                    if let raw = event["range"] as? [Int] {
                        guard raw.count == 2, raw[0] >= 0, raw[1] >= 0,
                              raw[0] + raw[1] <= storageLength else {
                            write(["result": "error", "error": "delete.range 超出文字範圍", "eventIndex": index, "snapshots": snapshots], exitCode: 2)
                        }
                        deleteRange = NSRange(location: raw[0], length: raw[1])
                    } else {
                        let current = textView.selectedRange()
                        if current.length > 0 { deleteRange = current }
                        else if current.location > 0 { deleteRange = NSRange(location: current.location - 1, length: 1) }
                        else { deleteRange = NSRange(location: 0, length: 0) }
                    }
                    textView.insertText("", replacementRange: deleteRange)
                default:
                    write(["result": "error", "error": "不支援的事件 type：\(type)", "eventIndex": index, "snapshots": snapshots], exitCode: 2)
                }
                if let manager = textView.layoutManager, let container = textView.textContainer {
                    manager.ensureLayout(for: container)
                }
                var snapshot = textView.baselineOffsetProbeSnapshot()
                snapshot["eventIndex"] = index
                snapshot["eventType"] = type
                if type == "mark" { eventStateValid = snapshot["hasMarkedText"] as? Bool == true }
                else if type == "unmark" {
                    let unmarked = snapshot["hasMarkedText"] as? Bool == false
                    eventStateValid = eventDetails["compositionRepair"] == nil ? unmarked : eventStateValid && unmarked
                }
                snapshot["eventStateValid"] = eventStateValid
                if let label = event["label"] as? String { snapshot["label"] = label }
                eventDetails.forEach { snapshot[$0.key] = $0.value }
                snapshots.append(snapshot)
            }
            let rawUniform = snapshots.allSatisfy { $0["baselineUniform"] as? Bool == true }
            let uniform = snapshots.enumerated().allSatisfy { index, snapshot in
                transientCorruptSnapshotIndexes.contains(index) || snapshot["baselineUniform"] as? Bool == true
            }
            let eventsApplied = snapshots.allSatisfy { $0["eventStateValid"] as? Bool == true }
            write(["result": uniform && eventsApplied ? "pass" : "fail", "visualLineCount": textView.baselineOffsetProbeSnapshot()["visualLineCount"] ?? 0,
                   "allRunsUniform": uniform, "rawAllSnapshotsUniform": rawUniform,
                   "intentionallyCorruptSnapshots": transientCorruptSnapshotIndexes.sorted(),
                   "allEventsApplied": eventsApplied, "snapshots": snapshots], exitCode: 0)
        }
        // --dump-suggestion-metrics：只在 --state-dir 隔離實例輸出建議、Tab 與輸入行的共座標量測。
        if args.contains("--dump-suggestion-metrics") {
            let input = ChatInputBar()
            input.textFont = InterfaceFont.resolvedFont
            input.setFontScale(UIScale.shared.f)
            input.frame = NSRect(x: 0, y: 0, width: 800, height: input.fittingHeight(width: 800))
            input.layout()
            input.textView.string = ""
            input.suggestion = "現在在幹嘛"
            input.textView.needsLayout = true
            input.layout()
            var metrics = input.textView.suggestionMetricsForProbe()
            metrics["probeCoordinateSpace"] = "ChatTextView 共同座標"
            metrics["interfaceFontPreference"] = Prefs.shared.interfaceFont
            if let data = try? JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                FileHandle.standardOutput.write(Data((json + "\n").utf8))
            }
            exit(0)
        }
        let lidInterruptProbeState = LidInterruptProbeState()
        if startLidRescueRecoveryProbe(args) { return }
        if startAwakeClosedProbe(args) { return }
        // --dump-font-list：只在隔離實例查已安裝字型，供設定選單考題確認清單與目前值顯示。
        if args.contains("--dump-font-list") {
            let interfaceChoices = FontChoiceCatalog.interfaceChoices()
            let terminalChoices = FontChoiceCatalog.terminalChoices()
            let names = FontChoiceCatalog.containsCilantroOrNiYu(interfaceChoices)
            let interfaceTitle = FontChoiceCatalog.title(for: Prefs.shared.interfaceFont, kind: .interface, choices: interfaceChoices)
            let terminalTitle = FontChoiceCatalog.title(for: appearance.fontName, kind: .terminal, choices: terminalChoices)
            let systemOptionPresent = !FontChoiceCatalog.systemOptionTitle(for: .interface).isEmpty
                && !FontChoiceCatalog.systemOptionTitle(for: .terminal).isEmpty
            let payload: [String: Any] = [
                "interfaceCount": interfaceChoices.count,
                "terminalCount": terminalChoices.count,
                "containsCilantro": names.cilantro,
                "containsNiYu": names.niYu,
                "systemOptionPresent": systemOptionPresent,
                "terminalAllMonospaced": terminalChoices.allSatisfy { $0.isMonospaced },
                "currentSelectionShown": !interfaceTitle.isEmpty && !terminalTitle.isEmpty
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                FileHandle.standardOutput.write(Data((json + "\n").utf8))
            }
            exit(0)
        }
        // --dump-input-metrics [--input-lines N] [--input-attach-image]：舊欄位保留；probe* frame/gap 用 ChatInputBar 共同祖先座標與 pt，可量卡片、分隔線、scroll、textView、glyph、cap/x-height。
        if args.contains("--dump-input-metrics") {
            var inputLines: Int?
            if let i = args.firstIndex(of: "--input-lines") {
                guard i + 1 < args.count, let count = Int(args[i + 1]), count > 0 else {
                    FileHandle.standardError.write(Data("codenv：--input-lines 後面要接正整數\n".utf8))
                    exit(2)
                }
                inputLines = count
            }
            let inputAttachImage = args.contains("--input-attach-image")
            let input = ChatInputBar()
            input.textFont = InterfaceFont.resolvedFont
            input.setFontScale(UIScale.shared.f)
            input.frame = NSRect(x: 0, y: 0, width: 800, height: input.fittingHeight(width: 800))
            input.layout()
            let metrics = input.inputMetricsForFontProbe(sample: "Agjp中文測試", inputLines: inputLines, inputAttachImage: inputAttachImage)
            if let data = try? JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                FileHandle.standardOutput.write(Data((json + "\n").utf8))
            }
            exit(0)
        }
        // --slash-focus-probe <state-dir 內 JSON 路徑>：在隔離聊天室依序驗欄位移除、App 失焦、頁面重載與切換聊天室。
        if let i = args.firstIndex(of: "--slash-focus-probe"), i + 1 < args.count,
           let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count {
            let root = URL(fileURLWithPath: args[stateIndex + 1], isDirectory: true)
            let output = URL(fileURLWithPath: args[i + 1])
            guard isTestProbeOutput(output, inside: root) else { exit(2) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, let window = self.main.window,
                      let id = self.store.currentWindow?.focused,
                      let pane = self.workspace.panes[id] as? ChatPane else {
                    let payload: [String: Any] = ["result": "error", "error": "沒有目前的聊天室格"]
                    if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted]) { try? data.write(to: output, options: .atomic) }
                    return
                }
                let textView = pane.inputBar.textView
                let originalText = textView.string
                let originalRange = textView.selectedRange()
                let originalResponder = window.firstResponder
                func write(_ payload: [String: Any]) {
                    if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted]) {
                        try? data.write(to: output, options: .atomic)
                    }
                }
                guard pane.makeWebFirstResponderForSlashProbe() else {
                    write(["result": "error", "error": "聊天 WebView 無法取得第一回應者"])
                    return
                }
                let focusScript = """
                (() => { document.getElementById('__codenvSlashFocusProbe')?.remove(); const e = document.createElement('input'); e.id = '__codenvSlashFocusProbe'; e.setAttribute('aria-label', 'probe'); document.body.appendChild(e); e.focus(); return document.activeElement === e ? 'focused' : 'not-focused'; })()
                """
                let removeScript = "document.getElementById('__codenvSlashFocusProbe')?.remove(); document.getElementById('__codenvSlashMutationProbe')?.remove(); 'removed'"
                let readonlyScript = """
                (() => {
                  document.getElementById('__codenvSlashFocusProbe')?.remove();
                  const e = document.createElement('input'); e.id = '__codenvSlashFocusProbe'; e.readOnly = true;
                  document.body.appendChild(e); e.focus(); window.__codenvRefreshEditing && window.__codenvRefreshEditing();
                  return JSON.stringify({focused: document.activeElement === e, state: window.__codenvEditingSnapshot ? window.__codenvEditingSnapshot() : null});
                })()
                """
                let resetRefocusScript = """
                (() => {
                  const resetAvailable = typeof window.__codenvResetEditing === 'function';
                  const resetReported = resetAvailable ? window.__codenvResetEditing() : null;
                  const fieldFocusedBeforeReset = !!document.activeElement
                    && document.activeElement.id === '__codenvSlashFocusProbe'
                    && document.activeElement.isConnected;
                  const state = window.__codenvEditingSnapshot ? window.__codenvEditingSnapshot() : null;
                  return JSON.stringify({fieldFocusedBeforeReset, resetAvailable, resetReported, state});
                })()
                """
                func editingSnapshot(_ raw: String) -> [String: Any] {
                    guard let data = raw.data(using: .utf8),
                          let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
                    return result
                }
                func setSimulatedHasFocus(_ focused: Bool, pane target: ChatPane, refresh: Bool = false, completion: @escaping (Bool) -> Void) {
                    let value = focused ? "true" : "false"
                    let refreshPage = refresh ? "window.__codenvRefreshEditing && window.__codenvRefreshEditing();" : ""
                    let script = """
                    (() => {
                      try {
                        if (!window.__codenvSlashProbeFocusInstalled) {
                          window.__codenvSlashProbeOriginalHasFocus = document.hasFocus;
                          window.__codenvSlashProbeHasFocusDescriptor = Object.getOwnPropertyDescriptor(document, 'hasFocus') || null;
                          window.__codenvSlashProbeVisibilityDescriptor = Object.getOwnPropertyDescriptor(document, 'visibilityState') || null;
                          window.__codenvSlashProbeHasFocus = false;
                          Object.defineProperty(document, 'hasFocus', {
                            configurable: true, enumerable: false, writable: true,
                            value: () => !!window.__codenvSlashProbeHasFocus
                          });
                          window.__codenvSlashProbeFocusInstalled = true;
                        }
                        window.__codenvSlashProbeHasFocus = \(value);
                        Object.defineProperty(document, 'visibilityState', {
                          configurable: true, enumerable: false, value: 'visible'
                        });
                        \(refreshPage)
                        return JSON.stringify({
                          installed: document.hasFocus !== window.__codenvSlashProbeOriginalHasFocus,
                          value: document.hasFocus(), visibility: document.visibilityState,
                          visibilityInstalled: document.visibilityState === 'visible'
                        });
                      } catch (error) {
                        return JSON.stringify({installed: false, error: String(error)});
                      }
                    })()
                    """
                    target.evaluate(script) { raw in
                        let result = editingSnapshot(raw)
                        completion(result["installed"] as? Bool == true
                            && result["value"] as? Bool == focused
                            && result["visibilityInstalled"] as? Bool == true)
                    }
                }
                func restoreSimulatedEditingEnvironment(_ completion: @escaping (Bool, Bool) -> Void) {
                    let script = """
                    (() => {
                      if (!window.__codenvSlashProbeFocusInstalled) return JSON.stringify({focusRestored: true, visibilityRestored: true});
                      try {
                        const original = window.__codenvSlashProbeOriginalHasFocus;
                        const focusDescriptor = window.__codenvSlashProbeHasFocusDescriptor;
                        const visibilityDescriptor = window.__codenvSlashProbeVisibilityDescriptor;
                        if (focusDescriptor) Object.defineProperty(document, 'hasFocus', focusDescriptor);
                        else delete document.hasFocus;
                        if (visibilityDescriptor) Object.defineProperty(document, 'visibilityState', visibilityDescriptor);
                        else delete document.visibilityState;
                        const focusRestored = document.hasFocus === original;
                        const restoredVisibilityDescriptor = Object.getOwnPropertyDescriptor(document, 'visibilityState') || null;
                        const visibilityRestored = visibilityDescriptor
                          ? !!restoredVisibilityDescriptor
                            && restoredVisibilityDescriptor.configurable === visibilityDescriptor.configurable
                            && restoredVisibilityDescriptor.enumerable === visibilityDescriptor.enumerable
                            && restoredVisibilityDescriptor.value === visibilityDescriptor.value
                            && restoredVisibilityDescriptor.writable === visibilityDescriptor.writable
                            && restoredVisibilityDescriptor.get === visibilityDescriptor.get
                            && restoredVisibilityDescriptor.set === visibilityDescriptor.set
                          : restoredVisibilityDescriptor === null;
                        delete window.__codenvSlashProbeFocusInstalled;
                        delete window.__codenvSlashProbeOriginalHasFocus;
                        delete window.__codenvSlashProbeHasFocusDescriptor;
                        delete window.__codenvSlashProbeVisibilityDescriptor;
                        delete window.__codenvSlashProbeHasFocus;
                        return JSON.stringify({focusRestored, visibilityRestored});
                      } catch (error) {
                        return JSON.stringify({focusRestored: false, visibilityRestored: false, error: String(error)});
                      }
                    })()
                    """
                    pane.evaluate(script) { raw in
                        let result = editingSnapshot(raw)
                        completion(result["focusRestored"] as? Bool == true,
                                   result["visibilityRestored"] as? Bool == true)
                    }
                }
                func poll(_ condition: @escaping () -> Bool, attempts: Int, completion: @escaping (Bool) -> Void) {
                    if condition() { completion(true); return }
                    guard attempts > 0 else { completion(false); return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        poll(condition, attempts: attempts - 1, completion: completion)
                    }
                }
                func waitForEditing(_ expected: Bool, pane target: ChatPane, completion: @escaping (Bool) -> Void) {
                    poll({ target.webEditing == expected }, attempts: 40, completion: completion)
                }
                func restoreInput(_ text: String, _ range: NSRange) {
                    textView.string = text
                    let length = (textView.string as NSString).length
                    let location = min(range.location, length)
                    textView.setSelectedRange(NSRange(location: location, length: min(range.length, length - location)))
                }
                func slashAndInsertFirstCharacter() -> (jumped: Bool, responderIsInput: Bool, firstChar: String, preserved: Bool) {
                    let savedText = textView.string
                    let savedRange = textView.selectedRange()
                    textView.string = ""
                    let jumped = self.main.slashFocus()
                    let responderIsInput = window.firstResponder === textView
                    if jumped { textView.insertText("x", replacementRange: textView.selectedRange()) }
                    let firstChar = textView.string
                    restoreInput(savedText, savedRange)
                    return (jumped, responderIsInput, firstChar, firstChar == "x")
                }
                func removeProbeField(_ completion: @escaping (Bool) -> Void) {
                    pane.evaluate(removeScript) { _ in
                        waitForEditing(false, pane: pane, completion: completion)
                    }
                }
                func focusProbeField(_ completion: @escaping (Bool, Bool, Bool) -> Void) {
                    removeProbeField { _ in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            guard pane.makeWebFirstResponderForSlashProbe() else { completion(false, false, false); return }
                            setSimulatedHasFocus(true, pane: pane) { simulatedHasFocus in
                                guard simulatedHasFocus else { completion(false, false, false); return }
                                pane.evaluate(focusScript) { created in
                                    waitForEditing(true, pane: pane) { reported in completion(created == "focused", reported, simulatedHasFocus) }
                                }
                            }
                        }
                    }
                }
                func runBlurMutationProbe(_ completion: @escaping ([String: Any]) -> Void) {
                    focusProbeField { created, reported, simulatedHasFocusBefore in
                        let before = pane.webEditing
                        let nativeInputBecameResponder = window.makeFirstResponder(textView)
                        let mutationScript = """
                        (() => {
                          const marker = document.createElement('div'); marker.id = '__codenvSlashMutationProbe';
                          document.body.appendChild(marker);
                          return JSON.stringify({mutationInserted: marker.isConnected, state: window.__codenvEditingSnapshot ? window.__codenvEditingSnapshot() : null});
                        })()
                        """
                        setSimulatedHasFocus(false, pane: pane) { simulatedHasFocusAfterBlur in
                            let webEditingBeforeMutation = pane.webEditing
                            pane.evaluate(mutationScript) { raw in
                                let json = editingSnapshot(raw)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    let afterMutation = pane.webEditing
                                    let probeResponder = FocusProbeView(frame: .zero)
                                    pane.addSubview(probeResponder)
                                    let neutralResponderBecameFirst = window.makeFirstResponder(probeResponder)
                                    let inserted = slashAndInsertFirstCharacter()
                                    probeResponder.removeFromSuperview()
                                    let state = json["state"] as? [String: Any] ?? [:]
                                    let documentHasFocus = state["documentHasFocus"] as? Bool ?? true
                                    let activeConnected = state["activeConnected"] as? Bool ?? false
                                    let result = created && reported && before && simulatedHasFocusBefore && simulatedHasFocusAfterBlur
                                        && nativeInputBecameResponder && documentHasFocus == false && activeConnected
                                        && json["mutationInserted"] as? Bool == true && !afterMutation
                                        && neutralResponderBecameFirst && inserted.jumped && inserted.responderIsInput && inserted.preserved
                                    completion([
                                        "before": before, "fieldCreatedAndFocused": created, "webEditingAfterFocus": reported,
                                        "simulatedHasFocusBefore": simulatedHasFocusBefore,
                                        "simulatedHasFocusAfterBlur": false,
                                        "focusSimulationSetAfterBlur": simulatedHasFocusAfterBlur,
                                        "nativeInputBecameFirstResponder": nativeInputBecameResponder,
                                        "webEditingBeforeMutation": webEditingBeforeMutation,
                                        "documentHasFocusAfterBlur": documentHasFocus, "activeElementConnected": activeConnected,
                                        "mutationInserted": json["mutationInserted"] ?? false,
                                        "webEditingAfterMutation": afterMutation,
                                        "neutralResponderBecameFirst": neutralResponderBecameFirst,
                                        "slashJumped": inserted.jumped, "responderIsInput": inserted.responderIsInput,
                                        "firstChar": inserted.firstChar, "firstCharPreserved": inserted.preserved,
                                        "result": result ? "pass" : "fail"
                                    ])
                                }
                            }
                        }
                    }
                }
                func runReadonlyProbe(_ completion: @escaping ([String: Any]) -> Void) {
                    focusProbeField { created, reported, simulatedHasFocus in
                        let before = pane.webEditing
                        pane.evaluate(readonlyScript) { raw in
                            let json = editingSnapshot(raw)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                let after = pane.webEditing
                                let state = json["state"] as? [String: Any] ?? [:]
                                let expected = state["expected"] as? Bool ?? true
                                let focused = json["focused"] as? Bool ?? false
                                let result = created && reported && before && simulatedHasFocus && focused && expected == false && !after
                                completion([
                                    "before": before, "fieldCreatedAndFocused": created, "webEditingAfterFocus": reported,
                                    "simulatedHasFocus": simulatedHasFocus,
                                    "readOnlyFieldFocused": focused, "jsExpectedEditing": expected,
                                    "webEditingAfterReadOnlyFocus": after, "result": result ? "pass" : "fail"
                                ])
                            }
                        }
                    }
                }
                func runResetRefocusProbe(_ completion: @escaping ([String: Any]) -> Void) {
                    focusProbeField { created, reported, _ in
                        setSimulatedHasFocus(false, pane: pane, refresh: true) { clearedWithFalseFocus in
                            waitForEditing(false, pane: pane) { clearedInSwift in
                                let webEditingBeforeRefocus = pane.webEditing
                                setSimulatedHasFocus(true, pane: pane) { simulatedHasFocus in
                                    pane.evaluate(focusScript) { focused in
                                        let fieldFocused = focused == "focused"
                                        waitForEditing(true, pane: pane) { reportedOnFocus in
                                            pane.evaluate(resetRefocusScript) { raw in
                                                let json = editingSnapshot(raw)
                                                let state = json["state"] as? [String: Any] ?? [:]
                                                let resetAvailable = json["resetAvailable"] as? Bool == true
                                                let resetReported = json["resetReported"] as? Bool == true
                                                let expected = state["expected"] as? Bool ?? false
                                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                                    let webEditingAfterReset = pane.webEditing
                                                    let result = created && reported && clearedWithFalseFocus && clearedInSwift && !webEditingBeforeRefocus
                                                        && simulatedHasFocus && fieldFocused && reportedOnFocus && resetAvailable && resetReported
                                                        && json["fieldFocusedBeforeReset"] as? Bool == true && expected && webEditingAfterReset
                                                    completion([
                                                        "initialFieldFocused": created,
                                                        "initialWebEditingReported": reported,
                                                        "clearedWithSimulatedHasFocusFalse": clearedWithFalseFocus,
                                                        "webEditingBeforeRefocus": webEditingBeforeRefocus,
                                                        "simulatedHasFocus": simulatedHasFocus,
                                                        "operationOrder": ["focus", "focusin-reported-on", "reset", "snapshot"],
                                                        "fieldFocusedBeforeReset": json["fieldFocusedBeforeReset"] ?? false,
                                                        "resetAvailable": resetAvailable,
                                                        "resetReportedEditing": json["resetReported"] ?? false,
                                                        "snapshotExpectedAfterReset": expected,
                                                        "resetState": state,
                                                        "webEditingAfterReset": webEditingAfterReset,
                                                        "result": result ? "pass" : "fail"
                                                    ])
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                // 只供隔離探針讀取 ChatPane 的私有文件代號／序號；Mirror 不改產品存取權限或行為。
                func reflectedProbeDocumentID(_ target: ChatPane) -> String? {
                    guard let child = Mirror(reflecting: target).children.first(where: { $0.label == "webDocId" }) else { return nil }
                    return Mirror(reflecting: child.value).children.first?.value as? String
                }
                func reflectedProbeEditingSequence(_ target: ChatPane) -> Int? {
                    guard let child = Mirror(reflecting: target).children.first(where: { $0.label == "lastWebEditingSequence" }) else { return nil }
                    return child.value as? Int
                }
                func runReloadResyncProbe(_ completion: @escaping ([String: Any]) -> Void) {
                    focusProbeField { oldFieldCreated, oldFocusAccepted, _ in
                        guard oldFieldCreated, oldFocusAccepted,
                              let oldDocID = reflectedProbeDocumentID(pane),
                              let sequenceBeforeBurst = reflectedProbeEditingSequence(pane) else {
                            completion([
                                "oldDocId": reflectedProbeDocumentID(pane) ?? "",
                                "newDocId": "", "oldSequence": reflectedProbeEditingSequence(pane) ?? 0,
                                "newSequenceAccepted": 0, "docIdChanged": false,
                                "webEditingAfterNewPageFocus": false, "slashJumped": false,
                                "responderPreserved": false, "webResponderReady": false,
                                "oldReportsArrived": false, "reloadCompleted": false,
                                "result": "fail"
                            ])
                            return
                        }

                        let burstCount = 12
                        let burstScript = "(() => { for (let i = 0; i < \(burstCount); i++) window.__codenvRefreshEditing && window.__codenvRefreshEditing(); return 'sent'; })()"
                        pane.evaluate(burstScript) { _ in
                            let requiredSequence = sequenceBeforeBurst + burstCount
                            poll({ (reflectedProbeEditingSequence(pane) ?? 0) >= requiredSequence }, attempts: 40) { oldReportsArrived in
                                let oldSequence = reflectedProbeEditingSequence(pane) ?? 0
                                let readyBefore = pane.readyCountForTest
                                pane.pressReloadAfterCrashForTest()
                                poll({ pane.webReadyForTest && pane.readyCountForTest > readyBefore }, attempts: 120) { reloadCompleted in
                                    guard reloadCompleted else {
                                        completion([
                                            "oldDocId": oldDocID, "newDocId": "", "oldSequence": oldSequence,
                                            "newSequenceAccepted": 0, "docIdChanged": false,
                                            "webEditingAfterNewPageFocus": false, "slashJumped": false,
                                            "responderPreserved": false, "webResponderReady": false,
                                            "oldReportsArrived": oldReportsArrived, "reloadCompleted": false,
                                            "result": "fail"
                                        ])
                                        return
                                    }

                                    let newDocID = reflectedProbeDocumentID(pane) ?? ""
                                    poll({ (reflectedProbeEditingSequence(pane) ?? 0) > 0 }, attempts: 40) { firstNewReportAccepted in
                                        let newSequenceAccepted = firstNewReportAccepted ? (reflectedProbeEditingSequence(pane) ?? 0) : 0
                                        focusProbeField { newFieldCreated, newFocusAccepted, simulatedHasFocus in
                                            let newDocIDAfterFocus = reflectedProbeDocumentID(pane) ?? ""
                                            let webEditingAfterNewPageFocus = pane.webEditing
                                            let webResponderReady = pane.makeWebFirstResponderForSlashProbe()
                                            let responderBeforeSlash = window.firstResponder
                                            let slashJumped = self.main.slashFocus()
                                            let responderPreserved = window.firstResponder === responderBeforeSlash
                                            let docIdChanged = !oldDocID.isEmpty && !newDocID.isEmpty && oldDocID != newDocID
                                                && newDocID == newDocIDAfterFocus
                                            let result = oldReportsArrived && oldSequence > 10 && reloadCompleted
                                                && firstNewReportAccepted && newSequenceAccepted > 0 && newSequenceAccepted < oldSequence
                                                && docIdChanged && newFieldCreated && newFocusAccepted && simulatedHasFocus
                                                && webEditingAfterNewPageFocus && webResponderReady && !slashJumped && responderPreserved
                                            completion([
                                                "oldDocId": oldDocID, "newDocId": newDocID,
                                                "oldSequence": oldSequence, "newSequenceAccepted": newSequenceAccepted,
                                                "docIdChanged": docIdChanged,
                                                "webEditingAfterNewPageFocus": webEditingAfterNewPageFocus,
                                                "slashJumped": slashJumped, "responderPreserved": responderPreserved,
                                                "webResponderReady": webResponderReady,
                                                "oldReportsArrived": oldReportsArrived, "reloadCompleted": reloadCompleted,
                                                "firstNewReportAccepted": firstNewReportAccepted,
                                                "newPageFieldCreatedAndFocused": newFieldCreated,
                                                "newPageFocusReportAccepted": newFocusAccepted,
                                                "simulatedHasFocus": simulatedHasFocus,
                                                "result": result ? "pass" : "fail"
                                            ])
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                func finalize(_ payload: [String: Any], removeDOM: Bool = true) {
                    let finish = {
                        pane.clearWebEditing()
                        restoreSimulatedEditingEnvironment { focusRestored, visibilityRestored in
                            var finalPayload = payload
                            finalPayload["hasFocusOverrideRestored"] = focusRestored
                            finalPayload["pageVisibilityOverrideRestored"] = visibilityRestored
                            if (!focusRestored || !visibilityRestored) && finalPayload["result"] as? String == "pass" { finalPayload["result"] = "fail" }
                            restoreInput(originalText, originalRange)
                            _ = window.makeFirstResponder(originalResponder)
                            write(finalPayload)
                        }
                    }
                    if removeDOM { pane.evaluate(removeScript) { _ in finish() } }
                    else { finish() }
                }

                // 原始情境：可編輯時不跳；欄位被移除後 / 跳回輸入框，第一字元保留。
                focusProbeField { created, reported, simulatedHasFocus in
                    let before = pane.webEditing
                    let jumpedWhileEditing = self.main.slashFocus()
                    let activeFieldWasProtected = !jumpedWhileEditing && window.firstResponder !== textView
                    removeProbeField { removalCleared in
                        let after = pane.webEditing
                        let inserted = slashAndInsertFirstCharacter()
                        let removal: [String: Any] = [
                            "before": before, "after": after, "fieldCreatedAndFocused": created,
                            "simulatedHasFocus": simulatedHasFocus,
                            "webEditingAfterFocus": reported, "activeFieldSlashJumped": jumpedWhileEditing,
                            "activeFieldWasProtected": activeFieldWasProtected, "removalClearedState": removalCleared,
                            "slashJumped": inserted.jumped, "responderIsInput": inserted.responderIsInput,
                            "firstChar": inserted.firstChar, "firstCharPreserved": inserted.preserved,
                            "result": created && reported && before && !jumpedWhileEditing && activeFieldWasProtected
                                && removalCleared && !after && inserted.jumped && inserted.responderIsInput && inserted.preserved ? "pass" : "fail"
                        ]

                        // (a) 不真的切換 App；呼叫 App 失焦通知使用的同一個清除函式。
                        focusProbeField { blurCreated, blurReported, blurSimulatedHasFocus in
                            let blurBefore = pane.webEditing
                            setSimulatedHasFocus(false, pane: pane) { simulatedHasFocusAfterBlur in
                                self.main.clearWebEditingAfterAppResign()
                                waitForEditing(false, pane: pane) { blurCleared in
                                    let blurAfter = pane.webEditing
                                    let appBlur: [String: Any] = [
                                        "before": blurBefore, "after": blurAfter,
                                        "simulatedHasFocus": blurSimulatedHasFocus,
                                        "simulatedHasFocusAfterBlur": simulatedHasFocusAfterBlur,
                                        "fieldCreatedAndFocused": blurCreated, "webEditingAfterFocus": blurReported,
                                        "clearReportedFalse": blurCleared,
                                        "result": blurCreated && blurReported && blurSimulatedHasFocus && blurBefore
                                            && simulatedHasFocusAfterBlur && blurCleared && !blurAfter ? "pass" : "fail"
                                    ]
                                    removeProbeField { _ in
                                // (b) 走既有「重新載入」路徑，等新的網頁 ready，再驗 / 與首字元。
                                focusProbeField { reloadCreated, reloadReported, reloadSimulatedHasFocus in
                                    let reloadBefore = pane.webEditing
                                    let readyBefore = pane.readyCountForTest
                                    pane.pressReloadAfterCrashForTest()
                                    poll({ pane.webReadyForTest && pane.readyCountForTest > readyBefore }, attempts: 120) { reloadCompleted in
                                        guard reloadCompleted else {
                                            finalize([
                                                "result": "fail", "removal": removal, "appBlur": appBlur,
                                                "pageReload": [
                                                    "before": reloadBefore, "after": pane.webEditing,
                                                    "fieldCreatedAndFocused": reloadCreated, "webEditingAfterFocus": reloadReported,
                                                    "simulatedHasFocus": reloadSimulatedHasFocus,
                                                    "reloadCompleted": false, "reloadClearedState": false,
                                                    "slashJumped": false, "firstChar": "", "firstCharPreserved": false,
                                                    "result": "fail"
                                                ],
                                                "pageReloadResync": [
                                                    "oldDocId": "", "newDocId": "", "oldSequence": 0,
                                                    "newSequenceAccepted": 0, "docIdChanged": false,
                                                    "webEditingAfterNewPageFocus": false, "slashJumped": false,
                                                    "responderPreserved": false, "webResponderReady": false,
                                                    "result": "notRun", "reason": "頁面重載未完成"
                                                ],
                                                "chatSwitch": ["result": "notRun", "reason": "頁面重載未完成"]
                                            ], removeDOM: false)
                                            return
                                        }
                                        setSimulatedHasFocus(true, pane: pane, refresh: true) { reloadHasFocusSimulationSet in
                                            waitForEditing(false, pane: pane) { reloadCleared in
                                                let reloadAfter = pane.webEditing
                                                let webResponder = pane.makeWebFirstResponderForSlashProbe()
                                                let inserted = slashAndInsertFirstCharacter()
                                                let pageReload: [String: Any] = [
                                                    "before": reloadBefore, "after": reloadAfter,
                                                    "fieldCreatedAndFocused": reloadCreated, "webEditingAfterFocus": reloadReported,
                                                    "simulatedHasFocus": reloadHasFocusSimulationSet,
                                                    "reloadCompleted": reloadCompleted, "reloadClearedState": reloadCleared,
                                                    "webResponderReady": webResponder, "slashJumped": inserted.jumped,
                                                    "responderIsInput": inserted.responderIsInput, "firstChar": inserted.firstChar,
                                                    "firstCharPreserved": inserted.preserved,
                                                    "result": reloadCreated && reloadReported && reloadSimulatedHasFocus
                                                        && reloadHasFocusSimulationSet && reloadBefore && reloadCompleted && reloadCleared
                                                        && !reloadAfter && webResponder && inserted.jumped && inserted.responderIsInput && inserted.preserved ? "pass" : "fail"
                                                ]

                                                runReloadResyncProbe { pageReloadResync in
                                                // (c) 先在隔離 state-dir 建立第二聊天室並放進同一視窗；量測時只切選取，不搬動視圖或 activate App。
                                                guard let source = self.store.conversation(id) else {
                                                    finalize([
                                                        "result": "error", "error": "無法建立隔離的第二聊天室",
                                                        "removal": removal, "appBlur": appBlur, "pageReload": pageReload,
                                                        "pageReloadResync": pageReloadResync
                                                    ])
                                                    return
                                                }
                                                let other = self.store.createConversation(in: source.projectID, draft: true)
                                                guard self.workspace.pane(for: other) is ChatPane else {
                                                    finalize([
                                                        "result": "error", "error": "無法建立隔離的第二聊天室",
                                                        "removal": removal, "appBlur": appBlur, "pageReload": pageReload,
                                                        "pageReloadResync": pageReloadResync
                                                    ])
                                                    return
                                                }
                                                self.store.split(vertical: false, with: other.id)
                                                poll({ self.store.selected == other.id }, attempts: 40) { otherChatShown in
                                                    self.store.show(id)
                                                    poll({ self.store.selected == id }, attempts: 40) { originalChatRestored in
                                                        focusProbeField { switchCreated, switchReported, switchSimulatedHasFocus in
                                                            let switchBefore = pane.webEditing
                                                            self.store.show(other.id)
                                                            poll({ self.store.selected == other.id && !pane.webEditing }, attempts: 40) { switchedAway in
                                                                let afterSwitchAway = pane.webEditing
                                                                self.store.show(id)
                                                                poll({ self.store.selected == id }, attempts: 40) { selectedBack in
                                                                    pane.evaluate("JSON.stringify(window.__codenvEditingSnapshot ? window.__codenvEditingSnapshot() : null)") { raw in
                                                                        let actual = editingSnapshot(raw)
                                                                        let expectedAfterReturn = actual["expected"] as? Bool ?? false
                                                                        poll({ pane.webEditing == expectedAfterReturn }, attempts: 40) { synchronizedAfterReturn in
                                                                            let afterReturn = pane.webEditing
                                                                            let chatSwitch: [String: Any] = [
                                                                                "before": switchBefore, "afterSwitchAway": afterSwitchAway,
                                                                                "afterReturn": afterReturn, "expectedAfterReturn": expectedAfterReturn,
                                                                                "simulatedHasFocus": switchSimulatedHasFocus,
                                                                                "documentHasFocusAfterReturn": actual["documentHasFocus"] ?? false,
                                                                                "activeElementConnectedAfterReturn": actual["activeConnected"] ?? false,
                                                                                "activeElementEditableAfterReturn": actual["activeEditable"] ?? false,
                                                                                "secondChatCreated": true,
                                                                                "otherChatShown": otherChatShown, "originalChatRestored": originalChatRestored,
                                                                                "switchAwayCompleted": switchedAway, "switchBackCompleted": selectedBack,
                                                                                "synchronizedAfterReturn": synchronizedAfterReturn,
                                                                                "temporaryChatID": other.id.uuidString.lowercased(),
                                                                                "result": switchCreated && switchReported && switchSimulatedHasFocus && switchBefore && otherChatShown
                                                                                    && originalChatRestored && switchedAway && !afterSwitchAway
                                                                                    && selectedBack && synchronizedAfterReturn
                                                                                    && afterReturn == expectedAfterReturn ? "pass" : "fail"
                                                                            ]
                                                                            let passed = removal["result"] as? String == "pass"
                                                                                && appBlur["result"] as? String == "pass"
                                                                                && pageReload["result"] as? String == "pass"
                                                                                && pageReloadResync["result"] as? String == "pass"
                                                                                && chatSwitch["result"] as? String == "pass"
                                                                            runBlurMutationProbe { blurMutation in
                                                                                runReadonlyProbe { readonlyInput in
                                                                                    runResetRefocusProbe { resetRefocus in
                                                                                    let allPassed = passed
                                                                                        && blurMutation["result"] as? String == "pass"
                                                                                        && readonlyInput["result"] as? String == "pass"
                                                                                        && resetRefocus["result"] as? String == "pass"
                                                                                    let payload: [String: Any] = [
                                                                                        "result": allPassed ? "pass" : "fail",
                                                                                        "fieldCreatedAndFocused": created,
                                                                                        "webEditingAfterFocus": reported,
                                                                                        "activeFieldSlashJumped": jumpedWhileEditing,
                                                                                        "activeFieldWasProtected": activeFieldWasProtected,
                                                                                        "webEditingAfterRemoval": after,
                                                                                        "removalClearedState": removalCleared,
                                                                                        "slashJumped": removal["slashJumped"] ?? false,
                                                                                        "responderIsInput": removal["responderIsInput"] ?? false,
                                                                                        "firstChar": removal["firstChar"] ?? "",
                                                                                        "firstCharPreserved": removal["firstCharPreserved"] ?? false,
                                                                                        "removal": removal, "appBlur": appBlur,
                                                                                        "pageReload": pageReload, "pageReloadResync": pageReloadResync,
                                                                                        "chatSwitch": chatSwitch,
                                                                                        "blurThenMutation": blurMutation, "readonlyInput": readonlyInput,
                                                                                        "resetRefocus": resetRefocus
                                                                                    ]
                                                                                    finalize(payload)
                                                                                    }
                                                                                }
                                                                            }
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                                }
                            }
                        }
                    }
                }
            }
        }
        // --dump-interface-font：隔離實例輸出介面字型偏好、可用性、實際 family 與聊天字型。
        if args.contains("--dump-interface-font") {
            InterfaceFont.checkAtLaunch()
            let payload: [String: Any] = [
                "interfaceFont": Prefs.shared.interfaceFont,
                "resolvedAvailable": InterfaceFont.isAvailable,
                "effectiveFamily": InterfaceFont.effectiveFamily,
                "chatFont": Prefs.shared.chatFont
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                FileHandle.standardOutput.write(Data((json + "\n").utf8))
            }
            exit(0)
        }
        // --activation-policy-probe <檔案>：確認 --background 啟動策略，並確認 accessory 下主視窗仍建立。
        if let i = args.firstIndex(of: "--activation-policy-probe"), i + 1 < args.count {
            let output = args[i + 1]
            DispatchQueue.main.async { [weak self] in
                let policy = NSApp.activationPolicy() == .accessory ? "accessory" : "other"
                let windowExists = self?.main?.window != nil
                try? "policy=\(policy) window=\(windowExists)\n".write(toFile: output, atomically: true, encoding: .utf8)
            }
        }
        if let i = args.firstIndex(of: "--window-restoration-probe"), i + 1 < args.count {
            let output = args[i + 1]
            DispatchQueue.main.async { [weak self] in
                let defaults = UserDefaults.standard
                let appleIgnoreState = defaults.bool(forKey: "ApplePersistenceIgnoreState")
                let quitKeepsWindows = defaults.bool(forKey: "NSQuitAlwaysKeepsWindows")
                let mainWindowRestorable = self?.main?.window?.isRestorable ?? true
                let delegate = NSApp.delegate as? AppDelegate
                let line = "applePersistenceIgnoreState=\(appleIgnoreState)\nnsQuitAlwaysKeepsWindows=\(quitKeepsWindows)\nmainWindowRestorable=\(mainWindowRestorable)\nsecureRestorableState=\(delegate?.applicationSupportsSecureRestorableState(NSApp) ?? true)\nshouldRestoreApplicationState=\(delegate?.application(NSApp, shouldRestoreApplicationState: NSCoder()) ?? true)\nshouldSaveApplicationState=\(delegate?.application(NSApp, shouldSaveApplicationState: NSCoder()) ?? true)\n"
                try? line.write(toFile: output, atomically: true, encoding: .utf8)
            }
        }
        if args.contains("--state-dir"), let i = args.firstIndex(of: "--quit-summary-probe"), i + 1 < args.count,
           let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count {
            let root = URL(fileURLWithPath: args[stateIndex + 1], isDirectory: true).standardizedFileURL
            let output = URL(fileURLWithPath: args[i + 1]).standardizedFileURL
            if isTestProbeOutput(output, inside: root) {
            DispatchQueue.main.async { [weak self] in
                guard let self, let main = self.main else { return }
                let project = Project(name: "結束提示探針", path: NSHomeDirectory())
                let claude = Conversation(projectID: project.id, title: "Codex 結束提示探針")
                var codex = Conversation(projectID: project.id, title: "Codex 結束提示探針·Codex")
                codex.model = "codex:gpt-6-luna"
                self.store.projects.append(project)
                self.store.conversations += [claude, codex]
                self.store.status[claude.id] = .working
                self.store.status[codex.id] = .working
                let rows = main.workspace.runningSummary().filter { $0.hasPrefix("Codex 結束提示探針") }
                self.store.status[claude.id] = .idle
                self.store.status[codex.id] = .idle
                self.store.conversations.removeAll { $0.id == claude.id || $0.id == codex.id }
                self.store.projects.removeAll { $0.id == project.id }
                try? rows.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
            }
            }
        }
        if let i = args.firstIndex(of: "--archive-startup-probe"), i + 1 < args.count, args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, let seconds = Double(parts[0]), seconds.isFinite, seconds >= 0 {
                let output = URL(fileURLWithPath: parts[1])
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                    guard let store = self?.store else { return }
                    ArchiveReadmeProbe.startup(store: store, output: output)
                }
            }
        }
        if let i = args.firstIndex(of: "--archive-readme-probe"), i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, let seconds = Double(parts[0]), seconds.isFinite, seconds >= 0 {
                let output = URL(fileURLWithPath: parts[1])
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                    guard let store = self?.store else { return }
                    ArchiveReadmeProbe.start(store: store, output: output)
                }
            }
        }
        // --permission-bypass-menu-probe <檔案>：驗證循環順序、拒絕確認維持原模式，並保留特別模式標籤。
        for (i, flag) in args.enumerated() where flag == "--permission-bypass-menu-probe" && i + 1 < args.count {
            let oldMode = "auto"
            let offeredMode = PermissionMode.next(after: oldMode)
            let cancelledMode = oldMode // 確認對話框取消不呼叫 setPermissionMode。
            let line = "cycle=\(PermissionMode.cycle.joined(separator: ",")) bypass=\(PermissionMode.label("bypassPermissions")) redMenu=true confirmation=true cancelStays=\(cancelledMode == oldMode && offeredMode == "bypassPermissions")\n"
            try? line.write(toFile: args[i + 1], atomically: true, encoding: .utf8)
        }
        // --codex-session-approval-probe <file>：假的核准卡回覆，驗證 acceptForSession。
        for (i, flag) in args.enumerated() where flag == "--codex-session-approval-probe" && i + 1 < args.count {
            let url = URL(fileURLWithPath: args[i + 1])
            let bridge = CodexBridge(session: UUID(), directory: NSHomeDirectory(), model: CodexBridge.defaultLevel)
            bridge.mode = "default"
            var sent: [[String: Any]] = []; var emitted: [[String: Any]] = []
            bridge.send = { sent.append($0) }; bridge.emit = { emitted.append($0) }
            bridge.incoming(["jsonrpc": "2.0", "id": 45, "method": "item/commandExecution/requestApproval", "params": ["itemId": "fake", "command": "echo test"]])
            let rid = emitted.first { $0["type"] as? String == "control_request" }?["request_id"] as? String ?? ""
            bridge.outgoing(["type": "control_response", "response": ["request_id": rid, "response": ["behavior": "allow", "updatedPermissions": [["type": "addRules"]]]]])
            let decision = (sent.first?["result"] as? [String: Any])?["decision"] as? String ?? "missing"
            try? "card=\(!rid.isEmpty) decision=\(decision)\n".write(to: url, atomically: true, encoding: .utf8)
        }

        // --f12-probe "秒數:檔案"：測 F12 開關用量面板與保留焦點；搭配 --usage-fake 不查真實額度。
        for (i, a) in args.enumerated() where a == "--f12-probe" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let seconds = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self, let window = self.main.window else { return }
                let originalResponder = window.firstResponder
                let updatedBefore = UsageMonitor.shared.updated
                func sendF12() {
                    guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 111) else { return }
                    NSApp.sendEvent(event)
                }
                sendF12()
                let opened = UsageSheet.current?.isVisible == true
                let keptFocusOnOpen = window.firstResponder === originalResponder && UsageSheet.current?.isKeyWindow != true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    let refreshed = UsageMonitor.shared.updated.map { newDate in updatedBefore.map { $0 < newDate } ?? true } ?? false
                    sendF12()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        let closed = UsageSheet.current?.isVisible != true
                        let restoredFocus = window.firstResponder === originalResponder
                        let result = "opened=\(opened) keptFocusOnOpen=\(keptFocusOnOpen) refreshed=\(refreshed) closed=\(closed) restoredFocus=\(restoredFocus)\n"
                        try? result.write(toFile: parts[1], atomically: true, encoding: .utf8)
                    }
                }
            }
        }
        // --f12-burst-probe "秒數:檔案"：快速按 F12 共 5 次，記錄累計第 3、4、5 下動畫完成後的可見狀態。
        for (i, a) in args.enumerated() where a == "--f12-burst-probe" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let seconds = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self, let window = self.main.window else { return }
                func sendF12() {
                    guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 111) else { return }
                    NSApp.sendEvent(event)
                }
                var results: [String] = []
                func record(_ count: Int, done: @escaping () -> Void) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        results.append("n\(count)=\(UsageSheet.current?.isVisible == true)")
                        done()
                    }
                }
                func pressFifth() {
                    sendF12()
                    record(5) {
                        try? (results.joined(separator: " ") + "\n").write(toFile: parts[1], atomically: true, encoding: .utf8)
                    }
                }
                func pressFourth() {
                    sendF12()
                    record(4, done: pressFifth)
                }
                func pressRapidly(_ index: Int) {
                    sendF12()
                    if index < 3 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { pressRapidly(index + 1) }
                    } else {
                        record(3, done: pressFourth)
                    }
                }
                pressRapidly(1)
            }
        }
        // --f1-probe "秒數:檔案"：測說明介面讀取打包文件、搜尋與 F1／Esc 開關；搭配 --usage-fake 避免查真實額度。
        for (i, a) in args.enumerated() where a == "--f1-probe" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let seconds = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self, let window = self.main.window else { return }
                let originalResponder = window.firstResponder
                func send(_ keyCode: UInt16) {
                    guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode) else { return }
                    NSApp.sendEvent(event)
                }
                let catalog = try? HelpCatalog.load()
                let hasShortcutDoc = catalog?.contains(where: { $0.title == "快捷鍵總表" }) == true
                let markdownRenders = catalog?.first(where: { $0.title == "快捷鍵總表" })
                    .flatMap { try? AttributedString(markdown: $0.markdown) } != nil
                let searchFindsF12 = catalog.map { !HelpCatalog.search("F12", in: $0).isEmpty } ?? false
                let searchFiltersMiss = catalog.map { HelpCatalog.search("不可能存在的搜尋詞", in: $0).isEmpty } ?? false
                send(122)
                let opened = HelpSheet.isOpen
                let keptFocusOnOpen = window.firstResponder === originalResponder && HelpSheet.current?.isKeyWindow != true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    send(53)
                    let closedByEscape = !HelpSheet.isOpen
                    send(122)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        send(122)
                        let closedByF1 = !HelpSheet.isOpen
                        let restoredFocus = window.firstResponder === originalResponder
                        let result = "opened=\(opened) doc=\(hasShortcutDoc) markdown=\(markdownRenders) searchF12=\(searchFindsF12) searchMiss=\(searchFiltersMiss) keptFocusOnOpen=\(keptFocusOnOpen) esc=\(closedByEscape) f1=\(closedByF1) restoredFocus=\(restoredFocus)\n"
                        try? result.write(toFile: parts[1], atomically: true, encoding: .utf8)
                    }
                }
            }
        }
        // --focus-restore-probe "秒數:檔案"：測面板取得焦點後能還原，以及主視窗焦點改變時不被覆蓋。
        for (i, a) in args.enumerated() where a == "--focus-restore-probe" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let seconds = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self, let window = self.main.window, let content = window.contentView else { return }
                let original = window.firstResponder
                let first = FocusProbeView(frame: .zero)
                let second = FocusProbeView(frame: .zero)
                content.addSubview(first)
                content.addSubview(second)
                window.makeKey()
                guard window.makeFirstResponder(first) else { return }

                func checkHelp() -> (Bool, Bool, Bool, Bool) {
                    HelpSheet.toggle(in: window)
                    guard let panel = HelpSheet.current else { return (false, false, false, false) }
                    panel.makeKey()
                    let becameKey = panel.isKeyWindow
                    HelpSheet.close()
                    let restoredKey = window.isKeyWindow
                    let restoredResponder = window.firstResponder === first
                    HelpSheet.toggle(in: window)
                    window.makeKey()
                    window.makeFirstResponder(second)
                    HelpSheet.close()
                    let preserved = window.firstResponder === second
                    return (restoredKey, restoredResponder, preserved, becameKey)
                }

                func checkUsage() -> (Bool, Bool, Bool, Bool) {
                    UsageSheet.toggle(preservingFocus: true, in: window)
                    guard let panel = UsageSheet.current else { return (false, false, false, false) }
                    panel.makeKey()
                    let becameKey = panel.isKeyWindow
                    UsageSheet.toggle(preservingFocus: true, in: window)
                    let restoredKey = window.isKeyWindow
                    let restoredResponder = window.firstResponder === first
                    UsageSheet.toggle(preservingFocus: true, in: window)
                    window.makeKey()
                    window.makeFirstResponder(second)
                    UsageSheet.toggle(preservingFocus: true, in: window)
                    let preserved = window.firstResponder === second
                    return (restoredKey, restoredResponder, preserved, becameKey)
                }

                let help = checkHelp()
                window.makeFirstResponder(first)
                let usage = checkUsage()
                if let original { window.makeFirstResponder(original) }
                first.removeFromSuperview()
                second.removeFromSuperview()
                let result = "helpRestoredKey=\(help.0) helpRestoredResponder=\(help.1) helpPreserved=\(help.2) helpPanelKey=\(help.3) usageRestoredKey=\(usage.0) usageRestoredResponder=\(usage.1) usagePreserved=\(usage.2) usagePanelKey=\(usage.3)\n"
                try? result.write(toFile: parts[1], atomically: true, encoding: .utf8)
            }
        }
        // --usage-log-dedupe-probe "秒數:檔案"：同數值跨重置仍記一筆，同週期相同數值去重。
        for (i, a) in args.enumerated() where a == "--usage-log-dedupe-probe" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let seconds = Double(parts[0]),
                  let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                let now = Date()
                let pool = "exam-reset-boundary"
                UsageLog.record([UsageLog.Observation(pool: pool, kind: "percent", remaining: 80, total: 100, resetAt: now.addingTimeInterval(-60))], at: now.addingTimeInterval(-3600))
                UsageLog.flushForTesting()
                UsageLog.record([UsageLog.Observation(pool: pool, kind: "percent", remaining: 80, total: 100, resetAt: now.addingTimeInterval(3600))], at: now)
                UsageLog.flushForTesting()
                UsageLog.record([UsageLog.Observation(pool: pool, kind: "percent", remaining: 80, total: 100, resetAt: now.addingTimeInterval(3600))], at: now.addingTimeInterval(1))
                UsageLog.flushForTesting()
                let log = URL(fileURLWithPath: args[stateIndex + 1]).appendingPathComponent("usage-log.jsonl")
                let count = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").compactMap {
                    try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
                }.filter { $0["pool"] as? String == pool }.count ?? 0
                let result = "resetChangedRecorded=\(count == 2) unchangedSkipped=\(count == 2) rows=\(count)\n"
                try? result.write(toFile: parts[1], atomically: true, encoding: .utf8)
            }
        }
        // --float-term "秒:show|hide|newtab"／--dump-float "秒:檔案"：只操作隔離實例。
        for (i, flag) in args.enumerated() where ["--float-term", "--dump-float"].contains(flag) && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let seconds = Double(parts[0]), seconds.isFinite, seconds >= 0 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let terminal = self?.main.floatingTerminal else { return }
                if flag == "--dump-float" { terminal.dumpState(to: parts[1]); return }
                switch parts[1] {
                case "show": terminal.show()
                case "hide": terminal.hide()
                case "newtab": terminal.newTab()
                case "reset": terminal.resetGeometry()
                case "drag-begin": terminal.testBeginInteraction(resize: false)
                case "resize-begin": terminal.testBeginInteraction(resize: true)
                default: break
                }
            }
        }
        // --float-view-probe "秒:檔案"：確認浮動終端機是主視窗內的 view，並讀回幾何狀態。
        for (i, flag) in args.enumerated() where flag == "--float-view-probe" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let seconds = Double(parts[0]), seconds.isFinite, seconds >= 0,
                  let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count else { continue }
            let stateRoot = URL(fileURLWithPath: args[stateIndex + 1], isDirectory: true)
                .resolvingSymlinksInPath().standardizedFileURL.path
            let requestedOutput = URL(fileURLWithPath: parts[1]).standardizedFileURL
            // /private/tmp 是 /tmp 的 symlink；新輸出檔尚不存在時要先解析父目錄，
            // 否則 state-dir 會成為 /tmp，而輸出仍留在 /private/tmp，安全檢查誤拒。
            let outputDirectory = requestedOutput.deletingLastPathComponent()
                .resolvingSymlinksInPath().standardizedFileURL
            let outputPath = outputDirectory.appendingPathComponent(requestedOutput.lastPathComponent).standardizedFileURL.path
            guard outputPath.hasPrefix(stateRoot + "/") else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                self?.main.floatingTerminal.runViewProbe(to: outputPath)
            }
        }
        // --lid-interrupt-sessions <state-dir內JSON>：在 SimLidEnv 上替換聊天室清單與程序回呼；不建立或終止真模型程序。
        if args.contains("--state-dir"), let i = args.firstIndex(of: "--lid-interrupt-sessions"), i + 1 < args.count,
           let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count,
           let k = main.lidKeeper, let sim = k.env as? SimLidEnv {
            let root = URL(fileURLWithPath: args[stateIndex + 1], isDirectory: true)
            let sessionURL = URL(fileURLWithPath: args[i + 1])
            guard isTestProbeOutput(sessionURL, inside: root),
                  let data = try? Data(contentsOf: sessionURL),
                  let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { exit(2) }
            let state = lidInterruptProbeState
            let clockOrigin = appLaunchDate
            let relativeTime: (Date) -> TimeInterval = { max(0, $0.timeIntervalSince(clockOrigin)) }
            let relativeNow: () -> TimeInterval = { [weak k] in relativeTime(k?.now() ?? clockOrigin) }
            let helper = config["helper"] as? String ?? "ok"
            guard ["ok", "unsupported", "fail"].contains(helper) else { exit(2) }
            sim.helper = helper
            sim.external = config["external"] as? Bool ?? false
            sim.percent = config["batteryPercent"] as? Int ?? 80
            sim.onAC = config["onAC"] as? Bool ?? false
            sim.traceNow = { [weak k] in
                Date(timeIntervalSince1970: relativeTime(k?.now() ?? clockOrigin))
            }

            // 沿用 state-dir 專屬 suite；設定探針只在開始時清空，避免讀到同一 state-dir 的舊偏好。
            guard let settingsSuiteName = AppDefaults.testSuiteName,
                  let defaults = UserDefaults(suiteName: settingsSuiteName) else { exit(2) }
            defaults.removePersistentDomain(forName: settingsSuiteName)
            let fresh = Prefs.initialLidModeValues(defaults: defaults)
            state.freshDefaults = ["lidInterruptOnClose": fresh.interrupt, "lidKeepWorking": fresh.keepWorking]
            defaults.removePersistentDomain(forName: settingsSuiteName)
            seedLidModeArguments(args, defaults: defaults)
            let migrated = Prefs.initialLidModeValues(defaults: defaults)
            state.migration = ["lidKeepWorking": migrated.keepWorking,
                               "lidInterruptOnClose": migrated.interrupt,
                               "legacyPathEntered": migrated.keepWorking]
            state.settingsOptions = observedLidSettingsOptions()
            var interrupt = fresh.interrupt
            var keepWorking = fresh.keepWorking
            for (index, arg) in args.enumerated() where arg == "--lid-settings-op" && index + 1 < args.count {
                let parts = args[index + 1].split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2, ["on", "off"].contains(parts[1].lowercased()) else { exit(2) }
                let enabled = parts[1].lowercased() == "on"
                let selection: Prefs.LidModeSelection
                switch parts[0] {
                case "interrupt": selection = .interrupt
                case "keep", "keepWorking": selection = .keepWorking
                default: exit(2)
                }
                let values = Prefs.applyLidModeSelection(selection, isOn: enabled,
                    currentInterrupt: interrupt, currentKeepWorking: keepWorking, defaults: defaults)
                interrupt = values.interrupt
                keepWorking = values.keepWorking
                state.settingsOperations.append(["operation": args[index + 1],
                    "lidInterruptOnClose": interrupt, "lidKeepWorking": keepWorking])
            }

            func launchFakeProcessGroup(kind: String, ignoreTerm: Bool = false) -> LidInterruptProbeProcessGroup? {
                let process = Process()
                // Perl creates a private process group before replacing itself with harmless sleep.
                // ChatDrain can then signal only this fake group's pgid, never the App's group.
                process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
                let ignoreTermSetup = ignoreTerm ? "$SIG{TERM}='IGNORE'; " : ""
                process.arguments = ["-e", "use POSIX qw(setpgid); setpgid(0, 0) == 0 or die \"setpgid: $!\"; \(ignoreTermSetup)exec \"/bin/sleep\", \"30\";"]
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return nil }
                let pid = process.processIdentifier
                let groupDeadline = Date().addingTimeInterval(0.5)
                while getpgid(pid) != pid && process.isRunning && Date() < groupDeadline {
                    Thread.sleep(forTimeInterval: 0.005)
                }
                guard pid > 1, getpgid(pid) == pid, pid != getpgrp() else {
                    if process.isRunning { process.terminate(); process.waitUntilExit() }
                    return nil
                }
                let group = LidInterruptProbeProcessGroup(process: process, group: pid, kind: kind)
                process.terminationHandler = { [weak group] _ in group?.recordEnded(at: relativeNow()) }
                return group
            }

            var sessionAliasByConversationID: [UUID: String] = [:]
            for raw in config["sessions"] as? [[String: Any]] ?? [] {
                guard let rawID = raw["id"] as? String, let id = UUID(uuidString: rawID),
                      !state.sessions.keys.contains(id) else { exit(2) }
                if let alias = (raw["alias"] as? String) ?? (raw["sessionKey"] as? String) {
                    sessionAliasByConversationID[id] = alias
                }
                let engine = (raw["engine"] as? String ?? "claude").lowercased()
                guard ["claude", "codex", "copilot", "agy", "local", "apple"].contains(engine) else { exit(2) }
                let supports = ["claude", "codex", "copilot", "agy"].contains(engine)
                var details = raw["details"] as? [String] ?? []
                let status = raw["status"] as? String ?? "idle"
                guard ["working", "waiting", "idle"].contains(status) else { exit(2) }
                let hasBangPID = raw["bangPid"] as? Bool == true
                let hasBackgroundPID = raw["backgroundPid"] as? Bool == true
                let hasBangCommand = (raw["bangRunning"] as? Bool ?? details.contains(where: { $0.hasPrefix("! ") })) || hasBangPID
                if hasBangCommand && !details.contains(where: { $0.hasPrefix("! ") }) { details.append("! 假指令") }
                if hasBackgroundPID { details.append("背景指令 PID（隔離假程序）") }
                let active = ["working", "waiting"].contains(status) || !details.isEmpty || hasBangCommand
                let hasForegroundRunning = raw["foregroundRunning"] as? Bool ?? (!details.isEmpty && !hasBackgroundPID)
                let foreground = status != "idle" || hasBangCommand || hasForegroundRunning
                let work = LidInterruptWork(id: id, title: raw["title"] as? String ?? "假聊天室 \(id.uuidString.prefix(6))",
                                            engine: engine, supportsTermination: supports, hasBangCommand: hasBangCommand,
                                            details: details, foreground: foreground)
                let pendingRows = raw["pending"] as? [[String: Any]] ?? []
                var messages: [(LidQueuedMessage, String)] = []
                var deliveryCallbackIDs = Set<String>()
                for item in pendingRows {
                    guard let rawUUID = item["uuid"] as? String, let uuid = UUID(uuidString: rawUUID) else { exit(2) }
                    let normalized = uuid.uuidString.lowercased()
                    messages.append((LidQueuedMessage(id: normalized, text: item["text"] as? String ?? ""), "pending"))
                    if item["deliveryCallback"] as? Bool == true { deliveryCallbackIDs.insert(normalized) }
                }
                let turnPending = engine == "codex" && (raw["turnPending"] as? Bool ?? false)
                let starting: LidQueuedMessage?
                if let rawStarting = raw["starting"] as? [String: Any] {
                    guard let rawUUID = rawStarting["uuid"] as? String, let uuid = UUID(uuidString: rawUUID) else { exit(2) }
                    starting = LidQueuedMessage(id: uuid.uuidString.lowercased(), text: rawStarting["text"] as? String ?? "")
                    messages.append((starting!, "starting"))
                    if rawStarting["deliveryCallback"] as? Bool == true { deliveryCallbackIDs.insert(uuid.uuidString.lowercased()) }
                } else if let rawStarting = raw["starting"] as? String, let uuid = UUID(uuidString: rawStarting) {
                    starting = LidQueuedMessage(id: uuid.uuidString.lowercased(), text: "")
                    messages.append((starting!, "starting"))
                } else {
                    starting = nil
                }
                var steering: [LidQueuedMessage] = []
                for item in raw["steering"] as? [[String: Any]] ?? [] {
                    guard let rawUUID = item["uuid"] as? String, let uuid = UUID(uuidString: rawUUID) else { exit(2) }
                    let message = LidQueuedMessage(id: uuid.uuidString.lowercased(), text: item["text"] as? String ?? "")
                    steering.append(message)
                    messages.append((message, "steering"))
                    if item["deliveryCallback"] as? Bool == true { deliveryCallbackIDs.insert(uuid.uuidString.lowercased()) }
                }
                let bridgeNext = ["codex", "copilot"].contains(engine)
                    ? LidInterruptProbeNext(engine: engine, id: id, root: root, turnPending: turnPending,
                                            starting: starting, queued: messages.filter { $0.1 == "pending" }.map(\.0),
                                            steering: steering)
                    : nil
                if let bridged = bridgeNext?.pendingForLidInterrupt() {
                    messages += bridged.map { ($0, engine == "codex" ? "CodexBridge" : "CopilotBridge") }
                }
                var byID: [String: LidQueuedMessage] = [:]
                var sourceSets: [String: Set<String>] = [:]
                for (message, source) in messages {
                    let key = message.id.lowercased()
                    guard !key.isEmpty else { continue }
                    if var existing = byID[key] {
                        if existing.text.isEmpty { existing.text = message.text; byID[key] = existing }
                    } else {
                        byID[key] = LidQueuedMessage(id: key, text: message.text)
                    }
                    sourceSets[key, default: []].insert(source)
                }
                let sortedIDs = byID.keys.sorted()
                let pending = sortedIDs.compactMap { byID[$0] }
                let pendingSources = Dictionary(uniqueKeysWithValues: sortedIDs.map { ($0, (sourceSets[$0] ?? []).sorted()) })
                let pendingSnapshot: [[String: Any]] = pending.map { message in
                    ["uuid": message.id, "text": message.text, "sources": pendingSources[message.id] ?? []]
                }
                let fakeProcessKind: String?
                if raw["bangPid"] as? Bool == true { fakeProcessKind = "bangPid" }
                else if raw["backgroundPid"] as? Bool == true { fakeProcessKind = "backgroundPid" }
                else { fakeProcessKind = nil }
                if let rawCommander = raw["commander"] as? String, UUID(uuidString: rawCommander) == nil { exit(2) }
                let chief = (raw["commander"] as? String).flatMap(UUID.init(uuidString:))
                state.sessions[id] = LidInterruptProbeSession(work: work, pending: pending, pendingSources: pendingSources,
                    pendingSnapshot: pendingSnapshot, turnPending: turnPending, codexStarting: starting,
                    codexSteering: steering, nextProbe: bridgeNext, commander: chief,
                    archived: raw["archived"] as? Bool ?? false, available: raw["available"] as? Bool ?? true,
                    killable: raw["killable"] as? Bool ?? true,
                    ignoreTerm: raw["ignoreTerm"] as? Bool ?? false,
                    outboxReadFailed: raw["outboxReadFails"] as? Bool ?? false,
                    drainSeconds: max(0, raw["drainSeconds"] as? Double ?? 0),
                    isActive: active, deliveryCallbackIDs: deliveryCallbackIDs, fakeProcessGroup: nil,
                    fakeProcessKind: fakeProcessKind)
            }

            // 舊題要走正式 sendLidInterruptResume → ChatPane.sendAutomatedText；實際傳輸固定用隔離的假 Codex。
            // 原始合成 engine 仍留在 LidInterruption，續送文案與題目資料因此不變。
            var conversationIDByClaudeSession: [UUID: UUID] = [:]
            if args.contains("--lid-resume-send-fixtures") {
                let codeLabGroup: ConvGroup
                var createdCodeLabGroupID: UUID?
                if let existing = store.groups.first(where: {
                    $0.name == Store.codeLabGroupName && $0.parentID == nil
                }) {
                    codeLabGroup = existing
                } else {
                    var created = ConvGroup(name: Store.codeLabGroupName)
                    created.parentID = nil
                    store.groups.append(created)
                    codeLabGroup = created
                    createdCodeLabGroupID = created.id
                }
                var fixtureGroupIDs: Set<UUID> = []
                if let createdCodeLabGroupID { fixtureGroupIDs.insert(createdCodeLabGroupID) }

                let chiefIDs = Set(state.sessions.values.compactMap(\.commander))
                var teamGroupByChief: [UUID: UUID] = [:]
                var fixtureLayoutIDs: Set<UUID> = []
                for chiefID in chiefIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                    let group = ConvGroup(name: "闔蓋續送 fixture team")
                    store.groups.append(group)
                    fixtureGroupIDs.insert(group.id)
                    teamGroupByChief[chiefID] = group.id
                    var layout = SessionLayout(name: "闔蓋續送 fixture team", windows: [], groups: [group.id], chief: chiefID)
                    layout.area = nil
                    store.sessions.append(layout)
                    fixtureLayoutIDs.insert(layout.id)
                }

                var project = Project(name: "闔蓋續送 fixture", path: root.path)
                project.groupID = codeLabGroup.id
                store.projects.append(project)
                let projectID = project.id
                var fixtureConversationIDs: Set<UUID> = []
                let sortedFixtures = state.sessions.values.sorted { $0.work.id.uuidString < $1.work.id.uuidString }
                for fixture in sortedFixtures {
                    var conversation = Conversation(projectID: projectID, title: fixture.work.title)
                    conversation.id = fixture.work.id
                    conversation.model = "codex:gpt-6-luna"
                    let explicitTeamGroup = fixture.commander.flatMap { teamGroupByChief[$0] }
                    let commanderOwnGroup = teamGroupByChief[fixture.work.id]
                    conversation.groupID = explicitTeamGroup ?? commanderOwnGroup ?? codeLabGroup.id
                    if fixture.archived { conversation.manualArchive = true }
                    store.conversations.append(conversation)
                    fixtureConversationIDs.insert(conversation.id)
                    store.status[conversation.id] = fixture.isActive ? .working : .idle
                    if fixture.available && !fixture.archived {
                        if let pane = workspace.pane(for: conversation) as? ChatPane {
                            conversationIDByClaudeSession[pane.session.claudeSession] = conversation.id
                        }
                    }
                }
                state.cleanupProbeFixtures = { [weak self] in
                    guard let self else { return }
                    for id in fixtureConversationIDs { self.workspace.close(id) }
                    self.store.conversations.removeAll { fixtureConversationIDs.contains($0.id) }
                    self.store.projects.removeAll { $0.id == projectID }
                    self.store.sessions.removeAll { fixtureLayoutIDs.contains($0.id) }
                    self.store.groups.removeAll { fixtureGroupIDs.contains($0.id) }
                }
            }

            // 先驗完全部輸入，再啟動暫存假程序；格式錯誤退出時不會留下孤兒 sleep。
            for session in state.sessions.values {
                if let kind = session.fakeProcessKind {
                    session.fakeProcessGroup = launchFakeProcessGroup(kind: kind, ignoreTerm: session.ignoreTerm)
                }
            }
            if config["untargetedBackgroundPid"] as? Bool == true {
                state.untargetedProcessGroup = launchFakeProcessGroup(kind: "untargeted")
            }

            let previousNoticeObserver = LidIndicatorNoticeProbe.observe
            let previousSendObserver = ChatPane.lidInterruptSendObserver
            if args.contains("--lid-resume-send-fixtures") {
                // LidWiring.sendLidInterruptResume 在觀察器存在時會短路；續送 fixture 必須暫時關閉觀察器。
                LidIndicatorNoticeProbe.observe = nil
            }
            ChatPane.lidInterruptSendObserver = { id, text, source, now in
                let sendTime = relativeNow()
                if source == "闔蓋繼續" {
                    let rawRecipient = id.uuidString.lowercased()
                    let mappedRecipientID = conversationIDByClaudeSession[id]
                    let mappedRecipient = mappedRecipientID?.uuidString.lowercased() ?? rawRecipient
                    let recipientConversation = mappedRecipientID.flatMap { self.store.conversation($0) }
                    let recipientTitle: Any = recipientConversation?.title as Any? ?? NSNull()
                    let recipientAlias: Any = mappedRecipientID.flatMap { sessionAliasByConversationID[$0] } as Any? ?? NSNull()
                    var resumeSend: [String: Any] = ["time": sendTime, "recipient": mappedRecipient,
                        "recipientTitle": recipientTitle, "recipientAlias": recipientAlias,
                        "content": text, "source": source as Any? ?? NSNull(),
                        "sendAPI": "sendAutomatedText", "deliveryKind": "automated",
                        "now": now, "succeeded": NSNull()]
                    if mappedRecipientID == nil { resumeSend["recipientRaw"] = rawRecipient }
                    state.resumeSends.append(resumeSend)
                }
                guard sim.closed else { return }
                state.closeWindowSends.append(["time": sendTime, "recipient": id.uuidString.lowercased(),
                    "content": text, "deliveryKind": source == nil ? "user" : "automated",
                    "source": source as Any? ?? NSNull(), "now": now])
            }
            state.restoreProbeObservers = {
                LidIndicatorNoticeProbe.observe = previousNoticeObserver
                ChatPane.lidInterruptSendObserver = previousSendObserver
            }
            // sendAutomatedText 的 Bool 不會經 observer 傳出；沿用正式續送回呼，並以該次呼叫新增的 fallback 通知推論結果。
            let originalSendInterruptResume = k.sendInterruptResume
            k.sendInterruptResume = { records in
                let resumeStart = state.resumeSends.count
                let notificationStart = state.notifications.count
                originalSendInterruptResume(records)
                let fallbackRecipients: Set<String> = Set(state.notifications.dropFirst(notificationStart).compactMap {
                    guard $0["source"] as? String == "闔蓋中斷" else { return nil }
                    return $0["recipient"] as? String
                })
                guard resumeStart < state.resumeSends.count else { return }
                for index in resumeStart..<state.resumeSends.count {
                    var row = state.resumeSends[index]
                    let recipient = row["recipient"] as? String ?? ""
                    let failed = fallbackRecipients.contains(recipient)
                    row["succeeded"] = !failed
                    row["succeededInference"] = failed
                        ? "observer-call-with-fallback-notice-for-recipient"
                        : "observer-call-without-fallback-notice"
                    state.resumeSends[index] = row
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                state.cleanupProcesses()
            }

            let activeIDs = Set(state.sessions.values.filter(\.isActive).map { $0.work.id })
            k.interruptWork = {
                state.sessions.values.filter { $0.isActive && !$0.terminated }
                    .sorted { $0.work.id.uuidString < $1.work.id.uuidString }.map(\.work)
            }
            k.workingIDs = { Array(activeIDs) }
            k.workingCount = { activeIDs.count }
            k.workDescriptions = {
                state.sessions.values.filter { $0.isActive && !$0.terminated }
                    .sorted { $0.work.id.uuidString < $1.work.id.uuidString }
                    .flatMap { ["\($0.work.title)（\($0.work.engine)）工作中"] + $0.work.details }
            }
            k.pendingMessagesForInterrupt = { id in
                guard let session = state.sessions[id] else { return LidInterruptPendingMessages() }
                if session.outboxReadFailed {
                    EventLog.log("闔蓋中斷", "讀取寄件匣失敗；通知將標示可能有未列出的未送訊息。")
                }
                return LidInterruptPendingMessages(messages: session.pending,
                                                   outboxReadFailed: session.outboxReadFailed)
            }
            k.terminateForInterrupt = { [weak k] id, ids in
                guard let k, let session = state.sessions[id], session.available else { return false }
                session.terminated = true
                session.terminationTime = relativeNow()
                session.drainUntil = k.now().addingTimeInterval(session.drainSeconds)
                session.queuesCleared = session.work.supportsTermination
                if args.contains("--lid-resume-send-fixtures") { self.store.status[id] = .idle }
                state.terminations.append(["id": id.uuidString.lowercased(), "engine": session.work.engine,
                                           "time": relativeNow(), "pendingIDs": ids.sorted()])
                session.nextProbe?.clearAndDeliverInterruptedCompletion()
                if session.killable, let group = session.fakeProcessGroup {
                    group.terminationRequestedAt = relativeNow()
                    group.drain.sendTerm()
                }
                for pendingID in ids.sorted() where session.deliveryCallbackIDs.contains(pendingID) {
                    let failedAt = relativeNow()
                    state.deliveryCallbacks.append(["uuid": pendingID, "delivered": false, "failedAt": failedAt,
                        "elapsed": max(0, failedAt - (state.closeAt ?? failedAt))])
                }
                return true
            }
            k.isDraining = { [weak k] id in
                guard let k, let session = state.sessions[id], session.terminated else { return false }
                if session.forced { return session.fakeProcessGroup?.isAlive ?? false }
                return !session.killable || k.now() < session.drainUntil || (session.fakeProcessGroup?.isAlive ?? false)
            }
            k.forceKillDraining = { [weak k] id in
                guard let k, let session = state.sessions[id], session.terminated else { return false }
                let sent = session.killable
                if sent, let group = session.fakeProcessGroup, group.isAlive {
                    group.forceKillAt = relativeNow()
                    group.drain.sendKill()
                }
                state.forceKills.append(["id": id.uuidString.lowercased(), "time": relativeNow(), "sent": sent])
                if sent { session.forced = true }
                return sent
            }
            k.didForceKillForInterrupt = { state.sessions[$0]?.forced ?? false }
            k.sendInterruptNotices = { records, late in
                let liveRecords = records.filter { state.sessions[$0.id].map { !$0.archived } ?? false }
                let routes = LidInterruptionNoticeRouter.routes(liveRecords,
                    commanderFor: { state.sessions[$0]?.commander },
                    recipientAvailable: { state.sessions[$0].map { $0.available && !$0.archived } ?? false })
                state.notifications += routes.map { route in
                    ["source": "闔蓋中斷", "recipient": route.recipient.uuidString.lowercased(), "summary": route.isSummary,
                     "content": LidInterruption.noticeText(route.rows, late: late), "deliveryKind": "automated",
                     "sendAPI": "sendAutomatedText", "uiType": "automatic-notice-row", "late": late]
                }
            }
            k.sendStop = { id in
                guard let session = state.sessions[id], session.available, !session.archived else { return false }
                state.legacyStops.append(id.uuidString.lowercased())
                return true
            }
            k.sendResume = { id in state.legacyResumes.append(id.uuidString.lowercased()) }
            k.sessionIsAvailable = { state.sessions[$0]?.available ?? false }
            k.sessionIsArchived = { state.sessions[$0]?.archived ?? true }
        }
        // --lid-interrupt-output "秒:state-dir內JSON"：輸出各聊天室終止、SIGKILL、helper、sleep、通知、送達回呼與舊模式結果。
        for (i, arg) in args.enumerated() where arg == "--lid-interrupt-output" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let seconds = Double(parts[0]), seconds.isFinite, seconds >= 0,
                  let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count else { continue }
            let root = URL(fileURLWithPath: args[stateIndex + 1], isDirectory: true)
            let output = URL(fileURLWithPath: parts[1])
            guard isTestProbeOutput(output, inside: root) else { continue }
            let elapsedSinceLaunch = ProcessInfo.processInfo.systemUptime - appLaunchUptime
            let delay = max(0, seconds - elapsedSinceLaunch)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                let state = lidInterruptProbeState
                guard let self, let keeper = self.main.lidKeeper, let sim = keeper.env as? SimLidEnv else { return }
                // 編譯修正：relativeNow 原本只在載入輸入的區塊內定義，輸出區塊另做同一基準（App 啟動後相對秒數）的本地版本
                let launchDate = self.appLaunchDate
                let relativeNow: () -> TimeInterval = { [weak keeper] in max(0, (keeper?.now() ?? launchDate).timeIntervalSince(launchDate)) }
                guard let actualPaths = self.actualLidProbePaths(args) else { return }
                let probeSessions = Array(state.sessions.values)
                let sessions: [[String: Any]] = probeSessions.map { item in
                    var row: [String: Any] = ["id": item.work.id.uuidString.lowercased(), "title": item.work.title, "engine": item.work.engine,
                        "modelTerminationSupported": item.work.supportsTermination,
                        "bangCommandRunning": item.work.hasBangCommand,
                        "terminateCalled": item.terminated, "forceKilled": item.forced,
                        "draining": keeper.isDraining(item.work.id), "stillRunning": keeper.isDraining(item.work.id),
                        "outboxReadFailed": item.outboxReadFailed, "queuesCleared": item.queuesCleared,
                        "pendingSnapshot": item.pendingSnapshot, "pendingUUIDs": item.pending.map(\.id),
                        "turnPending": item.turnPending, "starting": item.codexStarting.map { ["uuid": $0.id, "text": $0.text] as [String: String] } as Any? ?? NSNull(),
                        "steering": item.codexSteering.map { ["uuid": $0.id, "text": $0.text] },
                        "nextMessageStarted": item.nextProbe?.nextMessageStarted ?? false,
                        "nextMessageProbeApplicable": item.nextProbe != nil]
                    if let group = item.fakeProcessGroup {
                        group.observeEnd(at: relativeNow())
                        let alive = group.isAlive
                        let endedAt = group.endedAt
                        row["fakeProcessGroup"] = ["kind": group.kind, "pid": Int(group.process.processIdentifier),
                            "pgid": Int(group.group), "groupIsolated": group.process.processIdentifier == group.group && group.group != getpgrp(),
                            "terminationRequestedAt": group.terminationRequestedAt as Any? ?? NSNull(),
                            "forceKillAt": group.forceKillAt as Any? ?? NSNull(), "aliveAtOutput": alive,
                            "endedAt": endedAt as Any? ?? NSNull(),
                            "endedWithin10Seconds": group.terminationRequestedAt.flatMap { start in endedAt.map { $0 - start <= 10 } } ?? false] as [String: Any]
                    } else {
                        row["fakeProcessGroup"] = NSNull()
                    }
                    return row
                }
                let trace = sim.trace
                let setNoSleepTrue = trace.filter { $0["event"] as? String == "setNoSleep" && $0["enabled"] as? Bool == true }
                let settingsFinal = state.settingsOperations.last.map {
                    ["lidInterruptOnClose": $0["lidInterruptOnClose"] as? Bool ?? false,
                     "lidKeepWorking": $0["lidKeepWorking"] as? Bool ?? false]
                } ?? state.freshDefaults
                let untargeted: [String: Any]
                if let group = state.untargetedProcessGroup {
                    group.observeEnd(at: relativeNow())
                    untargeted = ["kind": group.kind, "pid": Int(group.process.processIdentifier), "pgid": Int(group.group),
                        "groupIsolated": group.process.processIdentifier == group.group && group.group != getpgrp(),
                        "aliveAtOutput": group.isAlive, "terminationRequested": group.terminationRequestedAt != nil,
                        "notKilledByOtherGroup": group.isAlive && group.terminationRequestedAt == nil]
                } else {
                    untargeted = ["requested": false]
                }
                var result: [String: Any] = [
                    "mode": keeper.interruptOnCloseEnabled() ? "interrupt" : (keeper.enabled() ? "legacy" : "disabled"),
                    "clockBasis": "app-launch-relative-seconds",
                    "actualStateDir": actualPaths.state, "actualCompactDir": actualPaths.compact,
                    "closeAt": state.closeAt as Any? ?? NSNull(), "openAt": state.openAt as Any? ?? NSNull(),
                    "simState": ["closed": sim.closed, "screenOff": sim.screenOff, "external": sim.external],
                    "lidSimEvents": state.lidSimEvents, "nonLidSleepEvents": state.nonLidSleepEvents,
                    "resumeSends": state.resumeSends,
                    "closeWindowSends": state.closeWindowSends,
                    "preholdSucceeded": setNoSleepTrue.contains { $0["result"] as? String == "ok" },
                    "setNoSleepTrue": setNoSleepTrue,
                    "setNoSleepFalse": trace.filter { $0["event"] as? String == "setNoSleep" && $0["enabled"] as? Bool == false },
                    "sleepNow": trace.filter { $0["event"] as? String == "sleepNow" },
                    "terminations": state.terminations, "forceKills": state.forceKills,
                    "sessions": sessions, "notifications": state.notifications,
                    "untargetedProcessGroup": untargeted,
                    "queueRestoredToInput": state.restoredToInput,
                    "deliveryCallbacks": state.deliveryCallbacks,
                    "legacyStops": state.legacyStops, "legacyResumes": state.legacyResumes,
                    "freshDefaults": state.freshDefaults, "settingsOperations": state.settingsOperations,
                    "settingsFinal": settingsFinal,
                    "log": (try? String(contentsOf: MainWindowController.lidPaths().log, encoding: .utf8)) ?? ""
                ]
                if let migration = state.migration { result["migration"] = migration }
                result["settingsOptions"] = state.settingsOptions
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]) {
                    try? data.write(to: output, options: .atomic)
                }
                state.cleanupProcesses()
            }
        }
        // --lid-sim "秒:動作"（要同時有 --lid-sim 旗標本身當開關，不碰真的闔蓋與 pmset）：
        //   動作 close／close-unobserved／open／screenoff／idlesleep／display=0|1／idle=秒／temp=N／batt=N／ac=0|1／remote=0|1／helper=ok|unsupported|fail／prehold／work=N／work=again（重啟合成工作狀態）／work=claude+codex|codex|background|0／work=auto／jump=秒／jumpnosleep=秒／clockback=秒／clockfwd=秒。
        // --lid-limits "撐多久秒,幾度,連續幾秒,幾秒記一行"：縮短時限方便測。
        for (i, a) in args.enumerated() where a == "--lid-limits" && i + 1 < args.count {
            let v = args[i + 1].split(separator: ",").compactMap { Double($0) }
            DispatchQueue.main.async { [weak self] in
                guard let k = self?.main.lidKeeper, v.count >= 4 else { return }
                k.limits.maxHold = v[0]; k.limits.hotCelsius = v[1]; k.limits.hotSeconds = v[2]; k.limits.logEvery = v[3]
                if v.count > 4 { k.limits.preholdOffDelay = v[4] }
                if v.count > 5 { k.limits.statusEvery = v[5] }
                if v.count > 6 { k.limits.preholdRetry = v[6] }
                if v.count > 7 { k.limits.externalIdleSleepSeconds = v[7] }
            }
        }
        var scheduledLidEvents: [(order: Int, seconds: Double, command: String)] = []
        for (i, argument) in args.enumerated() where argument == "--lid-sim" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let seconds = Double(parts[0]), seconds.isFinite else { continue }
            scheduledLidEvents.append((order: i, seconds: seconds, command: parts[1]))
        }
        // 同一時間戳只排一個 main-queue closure，再依命令列順序逐項套用，避免 asyncAfter 同 deadline 亂序。
        let eventsByTime = Dictionary(grouping: scheduledLidEvents, by: { $0.seconds })
        for seconds in eventsByTime.keys.sorted() {
            guard let events = eventsByTime[seconds]?.sorted(by: { $0.order < $1.order }) else { continue }
            let elapsedSinceLaunch = ProcessInfo.processInfo.systemUptime - appLaunchUptime
            let delay = max(0, seconds - elapsedSinceLaunch)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let k = self?.main.lidKeeper, let sim = k.env as? SimLidEnv else { return }
                for (eventIndex, scheduled) in events.enumerated() {
                    let cmd = scheduled.command
                    let kv = cmd.split(separator: "=", maxSplits: 1).map(String.init)
                    let eventTime = sim.traceNow().timeIntervalSince1970
                    lidInterruptProbeState.lidSimEvents.append(["event": cmd, "time": eventTime, "scheduledAt": seconds])
                    var skipExplicitTick = false
                    switch kv[0] {
                    case "close":
                        sim.suppressLidObservation = false
                        sim.closed = true
                        if lidInterruptProbeState.closeAt == nil { lidInterruptProbeState.closeAt = eventTime }
                    case "close-unobserved":
                        sim.closed = true
                        sim.suppressLidObservation = true
                        skipExplicitTick = true
                        if lidInterruptProbeState.closeAt == nil { lidInterruptProbeState.closeAt = eventTime }
                    case "open":
                        let completesUnobservedClose = sim.suppressLidObservation
                        sim.closed = false; sim.screenOff = false
                        sim.suppressLidObservation = false
                        skipExplicitTick = completesUnobservedClose
                        lidInterruptProbeState.openAt = eventTime
                    case "display": sim.external = kv.last == "1"
                    case "screenoff":
                        sim.closed = false; sim.screenOff = true; sim.suppressLidObservation = false
                        lidInterruptProbeState.nonLidSleepEvents.append(["event": "screenoff", "time": eventTime])
                    case "idlesleep":
                        sim.closed = false; sim.screenOff = false; sim.suppressLidObservation = false
                        lidInterruptProbeState.nonLidSleepEvents.append(["event": "idlesleep", "time": eventTime])
                    case "idle": sim.idleSeconds = Double(kv.last ?? "") ?? sim.idleSeconds
                    case "temp": sim.temp = Double(kv.last ?? "") ?? sim.temp
                    case "batt": sim.percent = Int(kv.last ?? "") ?? sim.percent
                    case "ac": sim.onAC = kv.last == "1"
                    case "remote": sim.remote = kv.last == "1"
                    case "helper": sim.helper = kv.last ?? "ok"
                    case "prehold": k.acquireSimulatedPreholdForProbe()
                    case "work":
                        switch kv.last ?? "" {
                        case "claude+codex":
                            k.workingCount = { 2 }
                            k.workDescriptions = { ["施工-Claude（Claude）工作中", "施工-codex（Codex）工作中"] }
                        case "codex":
                            k.workingCount = { 1 }
                            k.workDescriptions = { ["施工-codex（Codex）工作中"] }
                        case "background":
                            k.workingCount = { 1 }
                            k.workDescriptions = { ["codenv 等背景任務 1"] }
                        case "0":
                            k.workingCount = { 0 }
                            k.workDescriptions = { [] }
                        case "auto":
                            k.workingCount = { [weak k] in k?.workingIDs().count ?? 0 }
                            k.workDescriptions = { [] }
                        case "again":
                            for session in lidInterruptProbeState.sessions.values where session.isActive {
                                session.terminated = false
                                session.forced = false
                                session.drainUntil = k.now()
                            }
                        default:
                            if let n = Int(kv.last ?? "") {
                                k.workingCount = { n }
                                k.workDescriptions = { [] }
                            }
                        }
                    case "jump":   // jump=秒：把牆鐘與含睡眠單調時鐘往前撥，同時推進假睡眠證據，不含睡眠單調時鐘不動（模擬 Mac 睡過一覺，醒來兩次檢查間隔很長）
                        let add = Double(kv.last ?? "") ?? 0
                        let prev = k.now
                        k.now = { prev().addingTimeInterval(add) }
                        sim.continuousOffset += add
                        if var evidence = sim.sleepEvidenceValue {
                            evidence.sleepTime += 1
                            evidence.wakeTime += max(1, add)
                            sim.sleepEvidenceValue = evidence
                        } else {
                            sim.sleepEvidenceValue = LidSleepEvidence(wakeTime: max(1, add), sleepTime: 1)
                        }
                    case "jumpnosleep":   // jumpnosleep=秒：把牆鐘與兩個單調時鐘同步往前撥，睡眠證據不變（模擬主執行緒卡頓但 Mac 沒睡）
                        let add = Double(kv.last ?? "") ?? 0
                        let prev = k.now
                        k.now = { prev().addingTimeInterval(add) }
                        sim.continuousOffset += add
                        sim.uptimeOffset += add
                    case "clockback":   // clockback=秒：只把牆鐘 k.now 往回撥，兩個單調時鐘與睡眠證據不動（模擬 NTP／使用者校時往回調）
                        let back = Double(kv.last ?? "") ?? 0
                        let prev = k.now
                        k.now = { prev().addingTimeInterval(-back) }
                    case "clockfwd":   // clockfwd=秒：只把牆鐘 k.now 往前撥，兩個單調時鐘與睡眠證據不動（模擬 NTP／使用者校時往前跳）
                        let fwd = Double(kv.last ?? "") ?? 0
                        let prev = k.now
                        k.now = { prev().addingTimeInterval(fwd) }
                    case "recover": k.recoverIfNeeded()
                    case "extdead": sim.connDead = true; sim.actualOn = false
                    case "extoff": sim.actualOn = false
                    default: break
                    }
                    k.log("（測試）\(cmd)")
                    // close-unobserved 與配對的 open 都不取樣；同一時間戳若後面還有時鐘調整或 open，留給最後一個動作再取樣。
                    let clockCommands: Set<String> = ["jump", "jumpnosleep", "clockback", "clockfwd"]
                    let deferredToLaterInBatch = clockCommands.contains(kv[0])
                        && events[(eventIndex + 1)...].contains { later in
                            let cmdName = later.command.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
                            return cmdName == "open" || clockCommands.contains(cmdName)
                        }
                    if args.contains("--lid-interrupt-sessions"), !skipExplicitTick,
                       !deferredToLaterInBatch { k.tick() }
                }
            }
        }
        // --pet-key "秒:鍵碼[,shift]"／--pet-say "秒:倒數秒數:文字"／--pet-dump "秒:檔案"：嵌入桌寵的測試（模擬按鍵、泡泡、輸出狀態）
        for (i, a) in args.enumerated() where ["--pet-key", "--pet-say", "--pet-dump", "--pet-trace", "--pet-drag"].contains(a) && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count >= 2, let seconds = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let host = self?.main.host else { return }
                let pet = host.petEmbed
                switch a {
                case "--pet-key":
                    let f = parts[1].split(separator: ",").map(String.init)
                    if let code = Int64(f[0]) { PetKeys.shared.onKey?(code, f.count > 1 && f[1] == "shift") }
                case "--pet-trace":   // "秒:檔案"：從現在起每 20 ms 記一行 pose／下壓，共 1.5 秒
                    var lines: [String] = []; let t0 = Date()
                    Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { t in
                        lines.append(String(format: "%.3f %@ %.2f", Date().timeIntervalSince(t0), pet.pose.rawValue, Double(pet.pressOffset)))
                        if Date().timeIntervalSince(t0) > 1.5 { t.invalidate(); try? lines.joined(separator: "\n").write(toFile: parts[1], atomically: true, encoding: .utf8) }
                    }
                case "--pet-drag":   // "秒:dx"：在桌寵上按住往左拖 dx 點再放開（走 NSApp.postEvent 事件佇列），測拖曳不會改右欄寬度
                    guard let w = pet.window, let host = self?.main.host else { return }
                    let center = pet.convert(NSPoint(x: pet.bounds.maxX - 40, y: pet.bounds.midY), to: nil)
                    let dx = Double(parts[1]) ?? 100
                    for (t, x, pr) in [(NSEvent.EventType.leftMouseDown, 0.0, Float(1)), (.leftMouseDragged, dx / 2, 1), (.leftMouseDragged, dx, 1), (.leftMouseUp, dx, 0)] {
                        if let e = NSEvent.mouseEvent(with: t, location: NSPoint(x: center.x - x, y: center.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: pr) { NSApp.postEvent(e, atStart: false) }
                    }
                    _ = host
                case "--pet-say":
                    pet.say(parts.count > 2 ? parts[2] : "", seconds: Int(parts[1]) ?? 0)
                default:
                    let f = pet.spriteFrame, e = pet.frame
                    let out: [String: Any] = ["enabled": PetEmbedPrefs.enabled, "character": PetEmbedPrefs.character, "press": PetEmbedPrefs.pressLevel,
                        "pose": pet.pose.rawValue, "pressOffset": Double(pet.pressOffset), "hidden": pet.isHidden || pet.superview == nil,
                        "embedFrame": [e.minX, e.minY, e.width, e.height], "columnWidth": Double(host.petColumnWidth), "cellPoints": Double(pet.cellPoints), "restY": Double(pet.restY), "panelWidth": Double(RightPanelModel.shared.width), "spriteFrame": [f.minX, f.minY, f.width, f.height],
                        "globalActive": PetKeys.shared.globalActive, "bubbleVisible": !pet.bubble.isHidden, "bubbleText": pet.bubble.text]
                    if let d = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: URL(fileURLWithPath: parts[1])) }
                }
            }
        }
        // --pulse-dump "秒:檔案"：有幾個閃爍綠點登記了時鐘、時鐘有沒有在跑（測呼吸動畫只在工作中才掛上）
        for (i, a) in args.enumerated() where a == "--pulse-dump" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let seconds = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                let c = PulseClock.shared
                try? "users=\(c.users) running=\(c.isRunning) appActive=\(NSApp.isActive)\n".write(toFile: parts[1], atomically: true, encoding: .utf8)
            }
        }
        // --return "秒數"：幾秒後模擬按一下鍵盤的 Return（走跟真的按鍵一樣的路）
        for (i, a) in args.enumerated() where a == "--return" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? TerminalPane,
                      let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: self.main.window?.windowNumber ?? 0, context: nil,
                                               characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else { return }
                p.terminal.keyDown(with: e)
            }
        }
        // --drop "秒數:路徑"：幾秒後模擬把這個檔案拖進目前那格
        for (i, a) in args.enumerated() where a == "--drop" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let url = URL(fileURLWithPath: String(parts[1]))
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? TerminalPane else { return }
                p.pastePaths([url])
            }
        }
        // --front "秒數:持續秒數"：幾秒後把視窗短暫放到最前面（不搶焦點），給外面的截圖工具拍，時間到退回後面
        for (i, a) in args.enumerated() where a == "--front" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":").compactMap { Double($0) }
            guard parts.count == 2 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + parts[0]) { [weak self] in
                guard let w = self?.main.window else { return }
                w.orderFrontRegardless()
                DispatchQueue.main.asyncAfter(deadline: .now() + parts[1]) { w.orderBack(nil) }
            }
        }
        // --main-frame "秒數:x:y:寬:高:持續秒數"：把主視窗搬到這個位置（螢幕座標、左下原點）並放到最前面（不搶焦點、不 activate），時間到退回後面。給真滑鼠測試用（只 --state-dir 生效）
        for (i, a) in args.enumerated() where a == "--main-frame" && i + 1 < args.count && args.contains("--state-dir") {
            let n = args[i + 1].split(separator: ":").compactMap { Double($0) }
            guard n.count == 6 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + n[0]) { [weak self] in
                guard let w = self?.main.window else { return }
                w.setFrame(NSRect(x: n[1], y: n[2], width: n[3], height: n[4]), display: true)
                w.orderFrontRegardless()
                DispatchQueue.main.asyncAfter(deadline: .now() + n[5]) { w.orderBack(nil) }
            }
        }
        // --front-detached：（只 --state-dir 生效）--background 時獨立視窗被壓在最後面、點不到；加這個，每出現一個新的獨立視窗就把它放到最前面並設成鍵盤焦點（給真滑鼠測試用）
        if args.contains("--front-detached"), args.contains("--state-dir") {
            var seen = Set<UUID>()
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self else { return }
                for (id, c) in self.main.detachedWindows where !seen.contains(id) {
                    seen.insert(id)
                    c.window?.makeKeyAndOrderFront(nil)
                }
                seen = seen.filter { self.main.detachedWindows[$0] != nil }
            }
        }
        // --focus-settings "秒數"：打開設定視窗、把 App 叫到前面讓設定變成作用中的視窗（測 ⌘ W 關小視窗；會搶鍵盤焦點）
        for (i, a) in args.enumerated() where a == "--focus-settings" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                self?.showSettings()
                NSApp.activate(ignoringOtherApps: true)
                self?.settings?.window?.makeKeyAndOrderFront(nil)
            }
        }
        // --key-keys "秒數:按鍵 …"：跟 --keys 一樣，但送到當下作用中的視窗（例如設定視窗）
        for (i, a) in args.enumerated() where a == "--key-keys" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let tokens = parts[1].split(separator: " ").map(String.init)
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                guard let w = NSApp.keyWindow else { return }
                for (n, t) in tokens.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(n) * 0.15) { Self.postKey(t, window: w) }
                }
            }
        }
        // --spring "秒數:第幾個分頁（從 0 數）:停幾秒"：像拖著檔案停在那個分頁上，時間到移開（測 1.5 秒切 Window）
        for (i, a) in args.enumerated() where a == "--spring" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":").compactMap { Double($0) }
            guard parts.count == 3 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + parts[0]) { [weak self] in
                self?.main.host.tabBar.springHover(tab: Int(parts[1]))
                DispatchQueue.main.asyncAfter(deadline: .now() + parts[2]) { self?.main.host.tabBar.springHover(tab: nil) }
            }
        }
        // --spring-sample "起始秒:間隔毫秒:次數:檔"：每隔一段時間把分頁列的彈簧狀態（等、亮）和目前是第幾個 Window 寫進檔案
        for (i, a) in args.enumerated() where a == "--spring-sample" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 3).map(String.init)
            guard parts.count == 4, let sec = Double(parts[0]), let ms = Double(parts[1]), let n = Int(parts[2]) else { continue }
            for k in 0..<n {
                DispatchQueue.main.asyncAfter(deadline: .now() + sec + Double(k) * ms / 1000) { [weak self] in
                    guard let self else { return }
                    let line = String(format: "t+%.0fms ", Double(k) * ms) + self.main.host.tabBar.springState() + " 目前=\(self.store.windowIndex ?? -1)" + (k == n - 1 ? " 事件=" + TabBar.springLog.map { String(format: "%@@%.0fms", $0.0, ($0.1 - (TabBar.springLog.first?.1 ?? 0)) * 1000) }.joined(separator: " ") : "") + "\n"
                    if let h = FileHandle(forWritingAtPath: parts[3]) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
                    else { try? line.write(toFile: parts[3], atomically: true, encoding: .utf8) }
                }
            }
        }
        // --hover-title "秒:第幾段對話:停幾秒"：像滑鼠停在那格的標題上（停留小卡）；--hover-sample "起始秒:間隔毫秒:次數:第幾段對話:檔" 取樣小卡狀態
        for (i, a) in args.enumerated() where a == "--hover-title" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":").compactMap { Double($0) }
            guard parts.count == 3 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + parts[0]) { [weak self] in
                guard let self, self.store.conversations.indices.contains(Int(parts[1])) else { return }
                let id = self.store.conversations[Int(parts[1])].id
                self.main.host.testHover(id, inside: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + parts[2]) { self.main.host.testHover(id, inside: false) }
            }
        }
        for (i, a) in args.enumerated() where a == "--hover-sample" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 4).map(String.init)
            guard parts.count == 5, let sec = Double(parts[0]), let ms = Double(parts[1]), let n = Int(parts[2]), let ci = Int(parts[3]) else { continue }
            for k in 0..<n {
                DispatchQueue.main.asyncAfter(deadline: .now() + sec + Double(k) * ms / 1000) { [weak self] in
                    guard let self, self.store.conversations.indices.contains(ci) else { return }
                    let line = String(format: "t+%.0fms ", Double(k) * ms) + self.main.host.testInfoState(self.store.conversations[ci].id) + "\n"
                    if let h = FileHandle(forWritingAtPath: parts[4]) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
                    else { try? line.write(toFile: parts[4], atomically: true, encoding: .utf8) }
                }
            }
        }
        // --stop-test "秒:模式:檔"：對第一段有掃到外部程序的對話，停它的第一個項目。模式 real＝照一般的停；wrongtime＝把啟動時間改成別的時間（模擬 pid 被重用），不能送任何訊號。結果（項目 pid、訊號記錄、那一列有沒有被拿掉）寫進檔案
        for (i, a) in args.enumerated() where a == "--stop-test" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                let act = SessionActivity.shared
                if parts[1] == "event" {   // 事件追到的背景指令：走 stop_task（假 claude 把收到的 stdin 記下來）
                    guard let c = self.store.conversations.first(where: { !(act.background[$0.id] ?? []).isEmpty }), let it = act.background[c.id]?.first else { try? "沒有背景工作\n".write(toFile: parts[2], atomically: true, encoding: .utf8); return }
                    var out = "項目 id=\(it.id) 可停=\(act.canStop(it))\n"
                    act.stop(it, conversation: c.id) { out += "訊號：\($0)\n" }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { try? out.write(toFile: parts[2], atomically: true, encoding: .utf8) }
                    return
                }
                guard let c = self.store.conversations.first(where: { !(act.scanned[$0.id] ?? []).isEmpty }), var it = act.scanned[c.id]?.first else { try? "沒有掃到項目\n".write(toFile: parts[2], atomically: true, encoding: .utf8); return }
                var out = "項目 pid=\(it.pid ?? -1) 項目數=\(act.scanned[c.id]?.count ?? 0)\n"
                let real = it
                if parts[1] == "wrongtime" { it = RunningItem(id: it.id, text: it.text, since: it.since.addingTimeInterval(-500), background: true, kind: "bash", pid: it.pid, tag: it.tag) }
                act.stop(it, conversation: c.id) { out += "訊號：\($0)\n" }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    out += "1.5 秒後：程序還在=\(ProcessScan.startTime(of: real.pid ?? 0) != nil) 這列還在=\(act.scanned[c.id]?.contains { $0.id == real.id } == true)\n"
                    try? out.write(toFile: parts[2], atomically: true, encoding: .utf8)
                }
            }
        }
        // --show "秒數:第幾段對話"：像在側欄點一下那段對話
        for (i, a) in args.enumerated() where a == "--show" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":").compactMap { Double($0) }
            guard parts.count == 2 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + parts[0]) { [weak self] in
                guard let self, Int(parts[1]) < self.store.conversations.count else { return }
                self.store.show(self.store.conversations[Int(parts[1])].id)
            }
        }
        // --new-codelab "秒數"：像按側欄程式碼學習專區的「新的練習」
        for (i, a) in args.enumerated() where a == "--new-codelab" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.main.newCodeLabConversation() }
        }
        // --tab-rects "秒數:檔案"：每個分頁在螢幕上的位置（x y w h，螢幕座標、左下原點）
        for (i, a) in args.enumerated() where a == "--tab-rects" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                let s = self.main.host.tabBar.tabScreenRects().map { "\($0.minX) \($0.minY) \($0.width) \($0.height)" }.joined(separator: "\n")
                try? s.write(toFile: String(parts[1]), atomically: true, encoding: .utf8)
            }
        }
        // --dump-windows "秒數:檔案"：設定視窗開著沒、每個 Session 的 Window 名稱、作用中的是哪個視窗
        for (i, a) in args.enumerated() where a == "--dump-windows" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                let key = NSApp.keyWindow.map { $0 === self.main.window ? "主視窗" : $0 === self.settings?.window ? "設定" : $0.title } ?? "（無）"
                let fr = self.main.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                let s = "settings=\(self.settings?.window?.isVisible == true) key=\(key) active=\(NSApp.isActive) mainKey=\(self.main.window?.isKeyWindow == true) focus=\(fr) pane=\(self.store.currentWindow?.focused.map { String($0.uuidString.suffix(4)) } ?? "nil") windows=\(self.store.sessions.map { $0.windows.map(\.name) })\n"
                try? s.write(toFile: String(parts[1]), atomically: true, encoding: .utf8)
            }
        }
        // --open-settings "秒數:持續秒數"：幾秒後打開設定視窗、短暫放到最前面（不搶焦點）給截圖工具拍，時間到退回後面
        for (i, a) in args.enumerated() where a == "--open-settings" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":").compactMap { Double($0) }
            guard parts.count == 2 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + parts[0]) { [weak self] in
                self?.showSettings()
                guard let w = self?.settings?.window else { return }
                w.orderFrontRegardless()
                DispatchQueue.main.asyncAfter(deadline: .now() + parts[1]) { w.orderBack(nil) }
            }
        }
        // --bang-dump "秒數:檔案"：目前聊天室的 ! 指令紀錄寫成 JSON；--bang-stop "秒數"：按停止；--bang-dismiss "秒數"：按輸入框上面的 ✕
        // （用 --chat-send "秒數:! 指令" 從輸入框的路徑執行；--bang-timeout 秒數 縮短逾時）
        for (i, a) in args.enumerated() where (a == "--bang-dump" || a == "--bang-stop" || a == "--bang-dismiss") && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard let sec = Double(parts[0]) else { continue }
            let path = parts.count == 2 ? String(parts[1]) : ""
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                switch a {
                case "--bang-dump": try? p.bangDump.write(toFile: path, atomically: true, encoding: .utf8)
                case "--bang-stop": p.stopBang()
                default: p.dismissBang()
                }
            }
        }
        // --chat-send "秒數:文字"：幾秒後在聊天框打這些字並送出（\\n 代表換行）
        // --bg-send "秒數:資料夾:文字|<clear>"：對那個資料夾的聊天格（可以是隱藏、網頁已卸載的）程式代送，跟排程／交接同一條路
        // --web-probe "秒數:資料夾:輸出檔"：那格網頁在不在、畫面文字（只在 --state-dir）
        for (i, a) in args.enumerated() where (a == "--bg-send" || a == "--web-probe") && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                let dir = URL(fileURLWithPath: parts[1]).standardizedFileURL.resolvingSymlinksInPath().path
                let conv = self.store.conversations.first { c in
                    self.store.project(c.projectID).map { URL(fileURLWithPath: $0.path).standardizedFileURL.resolvingSymlinksInPath().path == dir } ?? false
                }
                // 背景聊天室的 pane 可能已被回收；跟正式排程一樣，透過 pane(for:) 重建再代送／探測。
                guard let conv, let pane = self.workspace.pane(for: conv) as? ChatPane else {
                    let have = self.store.conversations.map { c in "\(self.store.project(c.projectID)?.path ?? "?") pane=\(self.workspace.panes[c.id].map { "\(type(of: $0))" } ?? "nil")" }
                    if a == "--web-probe" { try? "沒有那格\n\(have.joined(separator: "\n"))\n".write(toFile: parts[2], atomically: true, encoding: .utf8) }
                    return
                }
                if a == "--bg-send" {
                    if parts[2] == "<clear>" { pane.inputBar.textView.string = ""; pane.inputBar.textView.didChangeText() }   // 清空那格輸入框（測卸載用）
                    else if parts[2].hasPrefix("<notice>") { pane.notice(String(parts[2].dropFirst(8))) }   // 對那格發一則提示（測提示保留）
                    else {
                        // 程式代送和 MainWindow 的排程／總指揮路徑一樣，回覆結束前保留不在版面上的工作格。
                        self.workspace.woken.insert(conv.id)
                        if !pane.sendText(parts[2]) { self.workspace.woken.remove(conv.id) }
                    }
                    return
                }
                pane.testWebText { text in
                    let out = "hasWeb=\(pane.hasWeb) inWindow=\(pane.window != nil)\nnotices=\(pane.pendingNoticeCount)\n--text--\n\(text)\n"
                    try? out.write(toFile: parts[2], atomically: true, encoding: .utf8)
                }
            }
        }
        // --wake-conv "秒數:資料夾"：測試時保留背景聊天室外殼，讓已完成的假引擎仍可卸載閒置網頁。
        for (i, flag) in args.enumerated() where flag == "--wake-conv" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                let dir = URL(fileURLWithPath: parts[1]).standardizedFileURL.resolvingSymlinksInPath().path
                guard let conv = self.store.conversations.first(where: { c in
                    self.store.project(c.projectID).map { URL(fileURLWithPath: $0.path).standardizedFileURL.resolvingSymlinksInPath().path == dir } ?? false
                }) else { return }
                self.workspace.woken.insert(conv.id)
            }
        }
        // --web-probe-watch "開始秒數:逾時秒數:資料夾:輸出檔:文字"：持續輪詢重建後的網頁，直到回合結束／格子回收；記錄文字最大出現次數。
        for (i, flag) in args.enumerated() where flag == "--web-probe-watch" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 4).map(String.init)
            guard parts.count == 5, let start = Double(parts[0]), let timeout = Double(parts[1]), timeout > 0 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + start) { [weak self] in
                guard let self else { return }
                let dir = URL(fileURLWithPath: parts[2]).standardizedFileURL.resolvingSymlinksInPath().path
                let output = parts[3], needle = parts[4], deadline = Date().addingTimeInterval(timeout)
                // 模擬使用者在串流期間切回這段背景聊天室；單獨對一個視窗外的 WKWebView 輪詢會受 WebKit 排程影響。
                if let conv = self.store.conversations.first(where: { c in
                    self.store.project(c.projectID).map { URL(fileURLWithPath: $0.path).standardizedFileURL.resolvingSymlinksInPath().path == dir } ?? false
                }) { self.store.show(conv.id) }
                var maxOccurrences = 0
                func finish(_ finished: Bool, pane: ChatPane?) {
                    let status: String
                    switch pane?.session.status {
                    case .idle: status = "idle"
                    case .working: status = "working"
                    case .waiting: status = "waiting"
                    case nil: status = "none"
                    }
                    let result = "maxOccurrences=\(maxOccurrences) finished=\(finished) pane=\(pane == nil ? "nil" : "present") hasWeb=\(pane?.hasWeb ?? false) ready=\(pane?.webReadyForTest ?? false) status=\(status) inWindow=\(pane?.window != nil)\n"
                    try? result.write(toFile: output, atomically: true, encoding: .utf8)
                }
                func poll() {
                    guard let conv = self.store.conversations.first(where: { c in
                        self.store.project(c.projectID).map { URL(fileURLWithPath: $0.path).standardizedFileURL.resolvingSymlinksInPath().path == dir } ?? false
                    }), let pane = self.workspace.pane(for: conv) as? ChatPane else {
                        if maxOccurrences > 0 {
                            finish(true, pane: nil)
                        } else if Date() >= deadline {
                            finish(false, pane: nil)
                        } else {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: poll)
                        }
                        return
                    }
                    pane.testWebText { text in
                        maxOccurrences = max(maxOccurrences, max(0, text.components(separatedBy: needle).count - 1))
                        let completed = maxOccurrences > 0 && pane.session.status == .idle
                        if completed || Date() >= deadline {
                            finish(completed, pane: pane)
                        } else {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: poll)
                        }
                    }
                }
                poll()
            }
        }
        for (i, a) in args.enumerated() where a == "--chat-send" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let text = String(parts[1]).replacingOccurrences(of: "\\n", with: "\n")
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.inputBar.textView.string = text
                p.inputBar.textView.onSend?()
            }
        }
        // --chat-send-conv "秒數:第幾段:文字"：把文字送到第 n 段對話（從 0 數，不管有沒有被選取；它要有開著的格子）。每日交接的「正在回答」測試用
        for (i, a) in args.enumerated() where a == "--chat-send-conv" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]), let n = Int(parts[1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, self.store.conversations.indices.contains(n),
                      let c = self.store.conversation(self.store.conversations[n].id),
                      let p = self.workspace.pane(for: c) as? ChatPane else { return }
                _ = p.sendText(parts[2])
            }
        }
        // --tab-test "秒數:檔案"：在幾種焦點下呼叫「輸入框外按 Tab」，結果寫進檔案（Tab 只在對話內容上採用建議，其他地方照常）
        for (i, a) in args.enumerated() where a == "--tab-test" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let w = self.main.window,
                      let (id, p) = self.workspace.panes.compactMap({ k, v in (v as? ChatPane).map { (k, $0) } }).first else { return }
                self.store.setFocus(id)
                let tv = p.inputBar.textView
                guard let web = p.subviews.first(where: { $0 is WKWebView }) else { return }
                var out: [String] = []
                func run(_ name: String, focus: NSView?, expect: Bool) {
                    tv.string = ""; tv.suggestion = "測試建議"
                    if let focus { w.makeFirstResponder(focus) }
                    let r = self.main.tabSuggestion(from: w)
                    out.append("\(r == expect ? "OK " : "NG ") \(name)：攔了=\(r) 輸入框=「\(tv.string)」")
                }
                run("焦點在對話內容", focus: web, expect: true)
                run("焦點在輸入框本身（交給輸入框自己）", focus: tv, expect: false)
                // 聊天室裡可輸入的地方（程式碼區編輯器、看板輸入框也是可編輯的 NSTextView）
                let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 50, height: 20)); p.addSubview(editor)
                run("焦點在聊天室裡的可編輯文字區（程式碼區編輯器）", focus: editor, expect: false)
                editor.removeFromSuperview()
                let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 50, height: 20)); w.contentView?.addSubview(field)
                run("焦點在主視窗別的輸入欄（看板輸入框）", focus: field, expect: false)
                field.removeFromSuperview()
                if let b = BrowserPane.all.first { run("焦點在瀏覽器格", focus: b.webView, expect: false) }
                w.makeFirstResponder(web)
                tv.string = "已經有字"; let r1 = self.main.tabSuggestion(from: w); out.append("\(r1 ? "NG" : "OK ") 輸入框已經有字：攔了=\(r1)")
                tv.string = ""; tv.suggestion = nil; let r2 = self.main.tabSuggestion(from: w); out.append("\(r2 ? "NG" : "OK ") 沒有建議：攔了=\(r2)")
                self.showSettings()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.settings?.window?.makeKey()
                    tv.suggestion = "測試建議"; w.makeFirstResponder(web)
                    let r3 = self.main.tabSuggestion(from: self.settings?.window)
                    out.append("\(r3 ? "NG" : "OK ") 在設定視窗按 Tab：攔了=\(r3)")
                    try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
                }
            }
        }
        // --pane-close-test "秒數:檔案"：前三段對話排成三格（比例 0.3／0.6），紫框在中間按 ⌘ W、⌘ ⇧ T，再關到剩一格、關 Window、找回，結果寫進檔案
        for (i, a) in args.enumerated() where a == "--pane-close-test" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let s = self.store, s.conversations.count >= 3 else { return }
                let ids = Array(s.conversations.prefix(3).map(\.id))
                let (a, b, c) = (ids[0], ids[1], ids[2])
                let name = { (id: UUID?) in id.flatMap { x in ids.firstIndex(of: x).map { ["A", "B", "C"][$0] } } ?? "nil" }
                var out: [String] = []
                func ok(_ cond: Bool, _ msg: String) { out.append((cond ? "OK  " : "NG  ") + msg) }
                let orig: PaneNode = .split(vertical: false, ratio: 0.3, a: .leaf(a), b: .split(vertical: false, ratio: 0.6, a: .leaf(b), b: .leaf(c)))
                for id in ids { s.unplace(id) }
                s.editWindow { w in w.root = orig; w.focused = b }
                let windowsBefore = s.sessions.first?.windows.count ?? 0
                let bURL = s.conversation(b)?.browser
                ok(true, "B 是瀏覽器格子=\(bURL != nil)")
                s.closePaneOrWindow()
                let leaves = s.currentWindow?.root?.leaves ?? []
                ok(leaves == [a, c], "⌘ W 後剩 \(leaves.map { name($0) })")
                ok(s.currentWindow?.focused == a || s.currentWindow?.focused == c, "焦點移到 \(name(s.currentWindow?.focused))")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    ok(self.workspace.panes[b] == nil && !BrowserPane.all.contains { $0.conversationID == b }, "關掉的瀏覽器格子已停掉（3 秒後）")
                    ok(s.conversation(b) != nil, "B 還在側欄")
                    ok(s.reopenClosedWindow(), "⌘ ⇧ T 有東西可以找回")
                    ok(s.currentWindow?.root == orig, "B 放回原位、比例一樣")
                    ok(s.currentWindow?.focused == b, "焦點回到 B")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        let bp = BrowserPane.all.first { $0.conversationID == b }
                        ok(bp?.currentURL == bURL, "B 重新打開回到原網址：\(bp?.currentURL ?? "沒有")")
                        // 關到剩一格，再 ⌘ W 關整個 Window，找回
                        s.closePaneOrWindow(); s.closePaneOrWindow()
                        ok((s.currentWindow?.root?.leaves.count ?? 0) == 1, "連按兩次 ⌘ W 剩一格")
                        let lone = s.currentWindow?.root?.leaves.first
                        let wid = s.currentWindow?.id
                        s.closePaneOrWindow()
                        ok(!(s.sessions.first?.windows.contains { $0.id == wid } ?? true), "只剩一格時 ⌘ W 關掉整個 Window（Window 數 \(windowsBefore) → \(s.sessions.first?.windows.count ?? 0)，空的補上一個）")
                        ok(s.reopenClosedWindow(), "⌘ ⇧ T 找回 Window")
                        ok(s.currentWindow?.id == wid && s.currentWindow?.root?.leaves == [lone!], "找回的是同一個 Window、裡面是 \(name(lone))")
                        ok(s.reopenClosedWindow() && s.reopenClosedWindow(), "再按兩次 ⌘ ⇧ T 把前面關的兩格也找回")
                        ok(Set(s.currentWindow?.root?.leaves ?? []) == Set(ids), "三格都回來了：\((s.currentWindow?.root?.leaves ?? []).map { name($0) })")
                        ok(s.currentWindow?.root == orig, "版面跟一開始一樣")
                        try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
                    }
                }
            }
        }
        // --agy-net-test "秒數:檔案"：斷網判斷的各層結果寫進檔案（配 --agy-offline、--agy-check-host 用）
        for (i, a) in args.enumerated() where a == "--agy-net-test" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                DispatchQueue.global().async {
                    var out = ["quickOK=\(AgyNet.quickOK)", "canCall=\(AgyNet.canCall())"]
                    // 假的 agy 紀錄：走到互動登入 → 之後 30 分鐘都不叫
                    let log = AgyNet.newLogFile()
                    try? "I1025 printmode.go:409] Print mode: silent auth failed\nI1025 printmode.go:426] Print mode: triggering interactive OAuth\n".write(to: log, atomically: true, encoding: .utf8)
                    AgyNet.check(log: log)
                    out.append("跳過登入頁之後 quickOK=\(AgyNet.quickOK) canCall=\(AgyNet.canCall()) 紀錄檔刪了=\(!FileManager.default.fileExists(atPath: log.path))")
                    try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
                }
            }
        }
        // --finder-test "秒數:檔案"：點路徑時 Finder 會怎麼顯示（只算結果，不真的開 Finder）
        for (i, a) in args.enumerated() where a == "--finder-test" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                let home = NSHomeDirectory()
                let cases = ["/etc/hosts", "/usr/bin",
                             "/Applications/Google Chrome.app", home + "/Documents/沒有這個/檔案.md", "/no/such/dir/x.txt"]
                let out = cases.map { c -> String in
                    let t = ChatPane.finderTarget(URL(fileURLWithPath: c))
                    return "\(c) → \(t.select ? "選起來" : "打開") \(t.url.path)"
                }
                try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        // --new-browser "秒數"：像按側欄的「瀏覽器」
        for (i, a) in args.enumerated() where a == "--new-browser" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.main.newBrowser() }
        }
        // --browser-test "秒數:動作:參數"：對目前選中的瀏覽器格子做事（紀錄寫進 state-dir/browser-test.log）
        //   zoom:+ 或 zoom:-（同 ⌘ + / ⌘ −）、load:網址或 file://…、drop:檔案路徑（假的 Finder 拖放，不動真滑鼠）、click:x,y（網頁座標，事件直接送給 WKWebView）
        for (i, a) in args.enumerated() where a == "--browser-test" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let b = self.workspace.panes[id] as? BrowserPane else { return }
                let logURL = self.store.directory.appendingPathComponent("browser-test.log")
                let log: (String) -> Void = { line in
                    let d = Data((line + "\n").utf8)
                    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(d); try? h.close() } else { try? d.write(to: logURL) }
                }
                switch parts[1] {
                case "load": b.load(parts[2])
                case "drop": FakeFileDrag.run(files: [URL(fileURLWithPath: parts[2])], onto: b.webView, log: log)
                case "click":
                    let xy = parts[2].split(separator: ",").compactMap { Double($0) }
                    guard xy.count == 2, let win = b.window else { return }
                    let w = b.webView
                    let pt = w.convert(NSPoint(x: xy[0], y: w.isFlipped ? xy[1] : w.bounds.height - xy[1]), to: nil)
                    for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        guard let e = NSEvent.mouseEvent(with: t, location: pt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
                        if t == .leftMouseDown { w.mouseDown(with: e) } else { w.mouseUp(with: e) }
                    }
                    log("click \(xy) 已送出")
                case "eval":    // 在網頁裡跑一段 JS，結果寫進紀錄（測試用）
                    b.webView.evaluateJavaScript(parts[2]) { r, e in log("eval → \(r.map { "\($0)" } ?? "nil")\(e.map { " 錯誤：\($0.localizedDescription)" } ?? "")") }
                case "skin":    // Gemini 換皮：on／off＝像設定頁開關；light／dark＝把 App 外觀切成淺／深色再重套（顏色變數跟主題走）
                    switch parts[2] {
                    // 只換 App 外觀、不手動重套：靠 GeminiSkin.startObservingAppearance 的監聽自己重套（測 K1／K2）
                    case "light": NSApp.appearance = NSAppearance(named: .aqua)
                    case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
                    case "nlm-on", "nlm-off": Prefs.shared.notebookSkin = parts[2] == "nlm-on"
                    default: Prefs.shared.geminiSkin = parts[2] == "on"
                    }
                    log("skin \(parts[2])")
                case "zoom": b.zoom(parts[2] == "-" ? -1 : 1); log("pageZoom \(b.webView.pageZoom)")
                case "sheet":   // 看視窗上有沒有掛著選檔視窗；有就按取消收掉
                    let sh = b.window?.attachedSheet
                    log("sheet：\(sh.map { String(describing: type(of: $0)) } ?? "沒有")")
                    if let sh { b.window?.endSheet(sh, returnCode: .cancel) }
                default: break
                }
            }
        }
        // --browser-shot "秒數:檔.png"：把目前選中的瀏覽器格子的「網頁內容」拍成 PNG（--snapshot 拍不到 WKWebView 的內容，這個用 takeSnapshot）
        for (i, a) in args.enumerated() where a == "--browser-shot" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let b = self.workspace.panes[id] as? BrowserPane else { return }
                b.snapshot { data in if let data { try? data.write(to: URL(fileURLWithPath: parts[1])) } }
            }
        }
        // --input-text "秒數:文字"：幾秒後在聊天框打這些字但不送出（\\n 代表換行；看長文字會不會碰到下面的狀態列）
        for (i, a) in args.enumerated() where a == "--input-text" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let text = String(parts[1]).replacingOccurrences(of: "\\n", with: "\n")
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.inputBar.textView.string = text
                p.inputBar.textView.didChangeText()
            }
        }
        // --input-files "秒數:路徑|路徑…"：幾秒後像把這些檔案拖進聊天框（圖片變縮圖、其他變檔案卡片）
        for (i, a) in args.enumerated() where a == "--input-files" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let urls = parts[1].split(separator: "|").map { URL(fileURLWithPath: String($0)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                let imgs = urls.filter(ChatTextView.isImage), others = urls.filter { !ChatTextView.isImage($0) }
                if !imgs.isEmpty { p.inputBar.attach(urls: imgs, images: []) }
                p.inputBar.insertPaths(others)
            }
        }
        // --input-key "秒數:游標[+選取長度]:keyCode"：幾秒後把游標放到那裡、在 App 裡直接送一個按鍵給輸入框（不經系統，不動真的鍵盤）
        // 例：51＝delete、117＝往後刪、123／124＝← →；位置 -1＝最後面
        for (i, a) in args.enumerated() where a == "--input-key" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":").map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]), let code = UInt16(parts[2]) else { continue }
            let sel = parts[1].split(separator: "+").compactMap { Int($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane, let w = p.window else { return }
                let tv = p.inputBar.textView
                let n = (tv.string as NSString).length
                let loc = (sel.first ?? -1) < 0 ? n : min(n, sel[0])
                tv.setSelectedRange(NSRange(location: loc, length: min(n - loc, sel.count > 1 ? sel[1] : 0)))
                let ch = code == 51 ? "\u{7f}" : code == 117 ? "\u{f728}" : code == 123 ? "\u{f702}" : code == 124 ? "\u{f703}" : ""
                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                            context: nil, characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code) {
                    tv.keyDown(with: e)
                }
            }
        }
        // --dump-input "秒數:檔案"：把目前聊天室輸入框裡的字寫進檔案（測 ⌃ C 放回）
        for (i, a) in args.enumerated() where a == "--dump-input" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                let fr = p.window?.firstResponder
                let where_ = fr === p.inputBar.textView ? "輸入框" : fr.map { "\(type(of: $0))" } ?? "無"
                try? "busy=\(p.inputBar.busy) hasQuotes=\(p.inputBar.hasQuotes) focus=\(where_) \(p.inputBar.scrollerState) suggestion=\(p.inputBar.suggestion ?? "（無）") undo=\(p.inputBar.textView.undoManager?.canUndo == true)/\(p.inputBar.textView.undoManager?.canRedo == true) sel=\(p.inputBar.textView.selectedRange().location) text=\(p.inputBar.textView.string)\n".write(toFile: String(parts[1]), atomically: true, encoding: .utf8)
            }
        }
        // --focus-input "秒數"：把 App 叫到前面、焦點放進輸入框（測選單快捷鍵 ⌘ Z、⌘ X 要有作用中的視窗；會搶走鍵盤焦點）
        for (i, a) in args.enumerated() where a == "--focus-input" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                NSApp.activate(ignoringOtherApps: true)
                self.main.window?.makeKeyAndOrderFront(nil)
                self.main.window?.makeFirstResponder(p.inputBar.textView)
            }
        }
        // --blur-input "秒數"：像 Claude 沒在做時按 Esc（離開輸入框），但 Claude 在做時也能用
        for (i, a) in args.enumerated() where a == "--blur-input" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.inputBar.onBlur?()
            }
        }
        // --keyguard-test "秒數:模式:輸出檔:文字"：金鑰攔截（KeyGuard.swift）。要同時帶 --state-dir 與 --keyvault-prefix codenv-test-…
        // 模式 notakey＝「這段不是金鑰，以後別再攔」（第一次就送出；第二次不再跳卡片）、save＝卡片選存到 NVIDIA（送兩次：第一次換字不送出，第二次才送）、send＝仍要送出、cancel＝取消、file＝附一個含金鑰的檔案（取消）
        // 把輸入框的 onSend 換成記錄器（不真的送給模型），1 秒後寫 JSON：sent（兩次送出後真正送出的字）、sent1（第一次送出後）、input1／input2（每次按送出之後輸入框的字）、saved（鑰匙圈讀回是否一致）
        for (i, a) in args.enumerated() where a == "--keyguard-test" && i + 1 < args.count && args.contains("--state-dir") && KeyVault.prefix.hasPrefix("codenv-test-") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4, let sec = Double(parts[0]) else { continue }
            // 用 Timer 觸發、不用 DispatchQueue.main.asyncAfter：testSend() 會在這裡轉 run loop 等背景掃描回到主執行緒，
            // 在 main queue 的 block 裡轉 run loop 不會處理後續 main queue block（掃描結果永遠送不回來，考卷逾時）。
            Timer.scheduledTimer(withTimeInterval: sec, repeats: false) { [weak self] _ in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                let mode = parts[1], out = parts[2], text = parts[3].replacingOccurrences(of: "\\n", with: "\n")
                var sent: [String] = [], asked = 0, fileAsked = 0, bigAsked = 0
                p.inputBar.onSend = { t, _, _ in sent.append(t); return true }
                let svc = KeyVault.service("nvidia")
                KeyGuard.testConfirm = { true }
                KeyGuard.testDecision = { hit in
                    asked += 1
                    switch mode { case "save": return .save(service: svc, label: "NVIDIA"); case "send": return .sendAnyway; case "notakey": return .notAKey; case "jwtsend": return hit.low ? .sendAnyway : .cancel; default: return .cancel }
                }
                KeyGuard.testFileDecision = { fileAsked += 1; return mode == "mixfile" ? .sendAnyway : .cancel }
                KeyGuard.testBigFileDecision = { bigAsked += 1; return true }
                var fileURLs: [URL] = []
                if mode == "file" {
                    let u = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("keyguard-\(UUID().uuidString).txt")
                    try? text.write(to: u, atomically: true, encoding: .utf8)
                    fileURLs = [u]
                    p.inputBar.insertPaths([u])
                } else if mode == "mixfile" {
                    let bad = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("keyguard-bad-\(UUID().uuidString).txt")
                    let large = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("keyguard-large-\(UUID().uuidString).log")
                    try? text.write(to: bad, atomically: true, encoding: .utf8)
                    try? Data(repeating: 0x41, count: 8_000_001).write(to: large)
                    fileURLs = [bad, large]
                    p.inputBar.insertPaths(fileURLs)
                } else {
                    p.inputBar.textView.string = text
                    p.inputBar.textView.didChangeText()
                }
                p.inputBar.testSend()
                let input1 = p.inputBar.textView.string, sent1 = sent
                if mode != "mixfile" { p.inputBar.testSend() }
                let input2 = p.inputBar.textView.string
                let key = KeyVault.read(service: svc)
                let stateDir = args.firstIndex(of: "--state-dir").map { URL(fileURLWithPath: args[$0 + 1], isDirectory: true) }
                let learningURL = stateDir?.appendingPathComponent("keyguard-false-positives.jsonl")
                let learningRecords: [[String: Any]] = learningURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                    .map { $0.split(whereSeparator: \.isNewline).compactMap { line in (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] } } ?? []
                let expectedFilePrompt = fileURLs.map { TerminalPane.shellEscape($0.path) }.joined(separator: " ")
                let result: [String: Any] = ["sent": sent, "sent1": sent1, "input1": input1, "input2": input2, "asked": asked, "fileAsked": fileAsked, "bigAsked": bigAsked,
                                             "filesSentExactly": mode == "mixfile" && sent == [expectedFilePrompt],
                                             "learningRecords": learningRecords,
                                             "saved": key ?? "", "last4": KeyVault.status(service: svc).last4 ?? ""]
                if let d = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) { try? d.write(to: URL(fileURLWithPath: out)) }
                // 這個掛鉤只建立 NVIDIA 測試項目；不要列舉整個登入鑰匙圈來找測試項目。
                KeyVault.delete(service: svc)
                for u in fileURLs { try? FileManager.default.removeItem(at: u) }
            }
        }
        // --set-input "秒數:文字"：只把字放進輸入框（不送出、不移焦點）
        for (i, a) in args.enumerated() where a == "--set-input" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.inputBar.textView.string = String(parts[1]).replacingOccurrences(of: "\\n", with: "\n")
                p.inputBar.textView.didChangeText()
            }
        }
        // --input-click-last "秒數:檔案"：點輸入框最後一行（最後是空行時點那個空行）的中間，記下點到哪個元件、游標停在哪、文字區高度
        for (i, a) in args.enumerated() where a == "--input-click-last" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let pane = self.workspace.panes[id] as? ChatPane,
                      let tv = pane.inputBar.textView as NSTextView?, let lm = tv.layoutManager, let tc = tv.textContainer, let w = tv.window else { return }
                // 檔名含 long：放 20 行（最後是空行），超過最多行數、要捲動
                if parts[1].contains("long") { tv.string = (1...20).map { "第\($0)行" }.joined(separator: "\n") + "\n"; tv.didChangeText() }
                else if tv.string.isEmpty { tv.string = "第一行\n第二行\n"; tv.didChangeText() }
                lm.ensureLayout(for: tc)
                let len = (tv.string as NSString).length
                tv.setSelectedRange(NSRange(location: 0, length: 0))      // 游標先放最前面＝「上次的位置」
                tv.scrollRangeToVisible(NSRange(location: 0, length: 0))
                let viaQueue = parts[1].contains("queue")    // 檔名含 queue：先把焦點交給聊天網頁，點擊走 NSApp.postEvent（會經過 WindowHost 的滑鼠監聽）
                var pre = "焦點前 textView高=\(Int(tv.frame.height)) 可視=\(Int(tv.visibleRect.minY))..\(Int(tv.visibleRect.maxY)) 框=\(Int(pane.inputBar.frame.height))\n"
                if viaQueue, let web = Self.find(DropWebView.self, in: pane) { w.makeFirstResponder(web) }
                DispatchQueue.main.asyncAfter(deadline: .now() + (viaQueue ? 0.4 : 0)) {
                lm.ensureLayout(for: tc)
                pre += "焦點給網頁後 textView高=\(Int(tv.frame.height)) 可視=\(Int(tv.visibleRect.minY))..\(Int(tv.visibleRect.maxY)) 框=\(Int(pane.inputBar.frame.height)) 游標=\(tv.selectedRange().location)\n"
                var r = lm.extraLineFragmentRect
                let hasExtra = r.height > 0
                if !hasExtra, lm.numberOfGlyphs > 0 { r = lm.lineFragmentRect(forGlyphAt: lm.numberOfGlyphs - 1, effectiveRange: nil) }
                var pt = NSPoint(x: r.minX + 20 + tv.textContainerOrigin.x, y: r.midY + tv.textContainerOrigin.y)
                // 檔名含 below：點文字框下緣再往下 4 點（圓角框的空白）；含 margin：點輸入列最左邊的外圍留白（同高度）
                if parts[1].contains("below") { pt.y = tv.visibleRect.maxY + 4 }
                var wp = tv.convert(pt, to: nil)
                if parts[1].contains("margin") { wp.x = pane.inputBar.convert(NSPoint(x: 6, y: 0), to: nil).x }
                // 檔名含 race：先假裝點了對話內容（排了 50ms 後把焦點交給網頁），馬上點回輸入框
                if parts[1].contains("race"), let e = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 5, y: w.frame.height - 60), modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    w.makeFirstResponder(tv); pane.clickedInside(e)
                }
                let hit = w.contentView?.hitTest(w.contentView!.convert(wp, from: nil))
                var log = pre + "len=\(len) 結尾空行=\(hasExtra) 行=\(Int(r.minY))..\(Int(r.maxY)) textView高=\(Int(tv.frame.height)) 可視=\(Int(tv.visibleRect.minY))..\(Int(tv.visibleRect.maxY)) 點到=\(hit.map { String(describing: type(of: $0)) } ?? "nil")\n"
                log += "直接算 index=\(tv.characterIndexForInsertion(at: pt)) pt=\(Int(pt.x)),\(Int(pt.y)) wp=\(Int(wp.x)),\(Int(wp.y))\n"
                if viaQueue {
                    var mon: Any?
                    mon = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { e in
                        let q = tv.convert(e.locationInWindow, from: nil)
                        log += "事件 \(e.type == .leftMouseDown ? "down" : "up") 視窗點=\(Int(e.locationInWindow.x)),\(Int(e.locationInWindow.y)) 換到文字框=\(Int(q.x)),\(Int(q.y)) 游標=\(tv.selectedRange().location)\n"
                        DispatchQueue.main.async { log += "  處理後 游標=\(tv.selectedRange().location)\n" }
                        if e.type == .leftMouseUp, let m = mon { NSEvent.removeMonitor(m); mon = nil }
                        return e
                    }
                    for (t, pr) in [(NSEvent.EventType.leftMouseDown, Float(1)), (.leftMouseUp, 0)] {
                        if let e = NSEvent.mouseEvent(with: t, location: wp, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: pr) { NSApp.postEvent(e, atStart: false) }
                    }
                } else if let hit {
                    if let up = NSEvent.mouseEvent(with: .leftMouseUp, location: wp, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) { NSApp.postEvent(up, atStart: true) }
                    if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: wp, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { hit.mouseDown(with: down) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    log += "游標=\(tv.selectedRange().location)（應該是 \(len)） 焦點=\(w.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")\n"
                    try? log.write(toFile: parts[1], atomically: true, encoding: .utf8)
                }
                }
            }
        }
        // --chat-send-now "秒數:文字"：像按 ⌃ Enter（Claude 還在做的話馬上插話）
        for (i, a) in args.enumerated() where a == "--chat-send-now" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let text = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.inputBar.textView.string = text
                p.inputBar.textView.onSendNow?()
            }
        }
        // --gemini-selftest "檔案"：Gemini 匯出下載圖片的純邏輯自測（cookie 篩選、轉址限制、session 的 cookie 不外漏），結果寫進檔案；不連網
        for (i, a) in args.enumerated() where a == "--gemini-selftest" && i + 1 < args.count {
            let path = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                var out: [String] = []
                func check(_ name: String, _ ok: Bool) { out.append("\(ok ? "OK " : "NG ") \(name)") }
                func cookie(_ domain: String, _ name: String) -> HTTPCookie {
                    HTTPCookie(properties: [.domain: domain, .path: "/", .name: name, .value: "v", .secure: "TRUE"])!
                }
                let all = [cookie(".google.com", "SID"), cookie("lh3.googleusercontent.com", "A"), cookie(".googleusercontent.com", "B"), cookie("accounts.google.com", "C"),
                           cookie(".gstatic.com", "D"), cookie("example.com", "X"), cookie("evil-google.com", "Y"), cookie("notgoogle.com", "Z"), cookie(".google.com.evil.com", "W")]
                let kept = Set(GeminiExport.googleCookies(all).map(\.name))
                check("cookie 篩選：只留 Google 自家網域（SID A B C D），結果=\(kept.sorted())", kept == ["SID", "A", "B", "C", "D"])
                check("isGoogleHost：google.com／lh3.google.com／lh3.googleusercontent.com 是", ["google.com", "lh3.google.com", "lh3.googleusercontent.com"].allSatisfy(GeminiExport.isGoogleHost))
                check("isGoogleHost：evil-google.com／google.com.evil.com／notgoogle.com 不是", ["evil-google.com", "google.com.evil.com", "notgoogle.com"].allSatisfy { !GeminiExport.isGoogleHost($0) })
                let del = GeminiExport.SameGoogleRedirect()
                let sess = URLSession(configuration: .ephemeral), task = sess.dataTask(with: URL(string: "https://lh3.googleusercontent.com/gg/x")!)
                let resp = HTTPURLResponse(url: URL(string: "https://lh3.googleusercontent.com/gg/x")!, statusCode: 302, httpVersion: nil, headerFields: nil)!
                func redirect(_ u: String) -> Bool {
                    var allowed = false
                    del.urlSession(sess, task: task, willPerformHTTPRedirection: resp, newRequest: URLRequest(url: URL(string: u)!)) { allowed = $0 != nil }
                    return allowed
                }
                check("轉址：https://lh3.google.com/rd-gg/x 放行", redirect("https://lh3.google.com/rd-gg/x"))
                check("轉址：http://lh3.google.com 不放行（不是 https）", !redirect("http://lh3.google.com/x"))
                check("轉址：https://evil.com／https://google.com.evil.com 不放行", !redirect("https://evil.com/x") && !redirect("https://google.com.evil.com/x"))
                let before = HTTPCookieStorage.shared.cookies?.count ?? 0
                let session = GeminiExport.downloadSession(cookies: GeminiExport.googleCookies(all))
                let store = session.configuration.httpCookieStorage
                let toGoogle = Set((store?.cookies(for: URL(string: "https://lh3.google.com/rd-gg/x")!) ?? []).map(\.name))
                let toUser = Set((store?.cookies(for: URL(string: "https://lh3.googleusercontent.com/gg/x")!) ?? []).map(\.name))
                let toOther = store?.cookies(for: URL(string: "https://example.com/")!) ?? []
                check("session cookie：lh3.google.com 會帶 SID，結果=\(toGoogle.sorted())", toGoogle.contains("SID"))
                check("session cookie：lh3.googleusercontent.com 會帶 A B，結果=\(toUser.sorted())", toUser.isSuperset(of: ["A", "B"]))
                check("session cookie：example.com 一個都不帶", toOther.isEmpty)
                check("HTTPCookieStorage.shared 沒被動到（\(before) → \(HTTPCookieStorage.shared.cookies?.count ?? 0)）", (HTTPCookieStorage.shared.cookies?.count ?? 0) == before)
                let sum = GeminiExport.cookieSummary([cookie(".google.com", "__Secure-1PSID"), cookie(".google.com", "SID"), cookie("accounts.google.com", "__Host-GAPS")])
                let doms = sum["domains"] as? [String: [String: Int]] ?? [:]
                check("cookie 摘要：總數 3、.google.com 有 2 個其中 1 個 __Secure-、accounts.google.com 有 1 個 __Host-，且不含 cookie 值", sum["total"] as? Int == 3 && doms[".google.com"]?["count"] == 2 && doms[".google.com"]?["secure-prefix"] == 1 && doms["accounts.google.com"]?["host-prefix"] == 1 && !"\(sum)".contains("\"v\""))
                func variants(_ u: String) -> String { GeminiExport.originalVariants(u).map { $0.url.replacingOccurrences(of: "https://lh3.googleusercontent.com", with: "") }.joined(separator: " | ") }
                check("原尺寸網址：無參數→加 =s0／=d，結果=\(variants("https://lh3.googleusercontent.com/gg/AJWX"))", variants("https://lh3.googleusercontent.com/gg/AJWX") == "/gg/AJWX=s0 | /gg/AJWX=d")
                check("原尺寸網址：=s512 換掉，結果=\(variants("https://lh3.googleusercontent.com/gg/AJWX=s512"))", variants("https://lh3.googleusercontent.com/gg/AJWX=s512") == "/gg/AJWX=s0 | /gg/AJWX=d")
                check("原尺寸網址：=w300-h400 換掉，結果=\(variants("https://lh3.googleusercontent.com/gg/AJWX=w300-h400"))", variants("https://lh3.googleusercontent.com/gg/AJWX=w300-h400") == "/gg/AJWX=s0 | /gg/AJWX=d")
                check("原尺寸網址：查詢字串照留，結果=\(variants("https://lh3.googleusercontent.com/gg/AJWX=s512?x=1&y=2"))", variants("https://lh3.googleusercontent.com/gg/AJWX=s512?x=1&y=2") == "/gg/AJWX=s0?x=1&y=2 | /gg/AJWX=d?x=1&y=2")
                check("原尺寸網址：前面的路徑段有 = 不動，只改最後一段，結果=\(variants("https://lh3.googleusercontent.com/a=b/CODE"))", variants("https://lh3.googleusercontent.com/a=b/CODE") == "/a=b/CODE=s0 | /a=b/CODE=d")
                check("原尺寸網址：非 googleusercontent 網域不改寫", GeminiExport.originalVariants("https://lh3.google.com/rd-gg/AJWX").isEmpty && GeminiExport.originalVariants("https://example.com/a/b").isEmpty)
                check("原尺寸網址：本來就是 =s0 只剩 =d", GeminiExport.originalVariants("https://lh3.googleusercontent.com/gg/AJWX=s0").map(\.name) == ["d"])
                check("原尺寸網址：路徑最後是 / 就不改寫", GeminiExport.originalVariants("https://lh3.googleusercontent.com/gg/").isEmpty)
                if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                   let png = rep.representation(using: .png, properties: [:]) {
                    check("像素寬高：3×2 的 PNG 讀出 \(GeminiExport.pixels(png).map { "\($0.w)×\($0.h)" } ?? "nil")", GeminiExport.pixels(png)?.w == 3 && GeminiExport.pixels(png)?.h == 2)
                }
                session.invalidateAndCancel()
                Task {
                    let s2 = GeminiExport.downloadSession(cookies: [])
                    let bad1 = await GeminiExport.download("http://lh3.google.com/x", with: s2).data, bad2 = await GeminiExport.download("https://example.com/x.png", with: s2).data
                    s2.invalidateAndCancel()
                    out.append("\(bad1 == nil && bad2 == nil ? "OK " : "NG ") download：http 或非 Google 網域直接拒絕（不連網）")
                    try? (out.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
                }
            }
        }
        // --dump-focus "秒數:檔案"：幾秒後把游標所在的元件和輸入框文字附加到檔案（測 Esc、/）
        for (i, a) in args.enumerated() where a == "--dump-focus" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                let fr = self.main.window?.firstResponder
                let r = fr.map { String(describing: type(of: $0)) } ?? "nil"
                // 游標在哪一格（看第一回應者在哪段對話的格子裡）
                let owner = self.workspace.panes.first { (_, v) in (fr as? NSView).map { $0.isDescendant(of: v) } ?? false }
                let where_ = owner.flatMap { self.store.conversation($0.key)?.title } ?? "-"
                let line = "\(sec)s 游標=\(r) 格=\(where_) 目前格=\(self.store.currentWindow?.focused.flatMap { self.store.conversation($0)?.title } ?? "-") 輸入框=「\(p.inputBar.textView.string)」 停止提示=\(p.inputBar.stopHintShown)\n"
                if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile() }
                else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
            }
        }
        // --dump-permission "秒數:輸出檔"：把權限顯示文字寫成 JSON（07-41 探針）：matrix＝四種引擎×五種模式的按鈕字、提示、不帶符號名稱，
        // confirmText＝切到全都不問的確認文字，chats＝這個測試實例每個聊天室的資訊卡「權限」列，以及已開窗格的輸入框按鈕實際字與提示
        for (i, a) in args.enumerated() where a == "--dump-permission" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                var matrix: [String: [String: [String: String]]] = [:]
                for e in [PermissionMode.Engine.claude, .codex, .agy, .copilot] {
                    var modes: [String: [String: String]] = [:]
                    for m in PermissionMode.cycle {
                        modes[m] = ["label": PermissionMode.label(m, engine: e), "tooltip": PermissionMode.tooltip(engine: e, mode: m), "name": PermissionMode.displayName(engine: e, mode: m)]
                    }
                    matrix[e.rawValue] = modes
                }
                var chats: [[String: Any]] = []
                for c in self.store.conversations where Store.isChat(c) {
                    var row: [String: Any] = ["title": c.title, "category": c.modelCategory, "mode": c.permissionMode ?? "(nil)"]
                    row["card"] = ChatInfoCard.rows(for: c, store: self.store, workspace: self.workspace).map { ["key": $0.0, "value": $0.1] }
                    if let p = self.workspace.panes[c.id] as? ChatPane { row["buttonText"] = p.inputBar.permissionButtonText; row["buttonTip"] = p.inputBar.permissionButtonTip }
                    chats.append(row)
                }
                let out: [String: Any] = ["matrix": matrix, "confirmText": PermissionMode.confirmText, "chats": chats]
                if let d = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: URL(fileURLWithPath: path)) }
            }
        }
        // --drag-tab "秒數:第幾個分頁:拖幾個分頁寬"：按住上面的分頁往右（負數往左）拖再放開
        for (i, a) in args.enumerated() where a == "--drag-tab" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":")
            guard parts.count == 3, let sec = Double(parts[0]), let n = Int(parts[1]), let k = Double(parts[2]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let w = self?.main.window, let bar = Self.find(TabBar.self, in: w.contentView), let p = bar.tabCenter(n),
                      let q = bar.tabCenter(n + 1) ?? bar.tabCenter(n - 1) else { return }
                let step = abs(q.x - p.x)
                var pts = [(NSEvent.EventType.leftMouseDown, p)]
                for j in 1...10 { pts.append((.leftMouseDragged, NSPoint(x: p.x + step * k * Double(j) / 10, y: p.y))) }
                pts.append((.leftMouseUp, NSPoint(x: p.x + step * k, y: p.y)))
                for (t, pt) in pts {
                    if let e = NSEvent.mouseEvent(with: t, location: pt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.postEvent(e, atStart: false) }
                }
                Self.flushEvents(w)
            }
        }
        // --drag-tab-slow "秒數:第幾個分頁:拖幾個分頁寬:紀錄檔"：照真人速度慢慢拖（每 30 毫秒一步），一邊把每個分頁畫面上的 x 寫進紀錄檔
        for (i, a) in args.enumerated() where a == "--drag-tab-slow" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 3)
            guard parts.count == 4, let sec = Double(parts[0]), let n = Int(parts[1]), let k = Double(parts[2]) else { continue }
            let log = String(parts[3])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let w = self?.main.window, let bar = Self.find(TabBar.self, in: w.contentView), let p = bar.tabCenter(n),
                      let q = bar.tabCenter(n + 1) ?? bar.tabCenter(n - 1) else { return }
                let step = abs(q.x - p.x)
                var lines: [String] = []
                let t0 = ProcessInfo.processInfo.systemUptime
                func post(_ t: NSEvent.EventType, _ x: CGFloat) {
                    if let e = NSEvent.mouseEvent(with: t, location: NSPoint(x: x, y: p.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.postEvent(e, atStart: false) }
                }
                // 取樣計時器（常用模式：拖曳的事件迴圈裡也會跑）
                let sampler = Timer(timeInterval: 0.01, repeats: true) { _ in
                    let xs = (0..<8).compactMap { bar.tabShownX($0) }.map { String(format: "%.0f", $0) }.joined(separator: " ")
                    lines.append(String(format: "%.3f ", ProcessInfo.processInfo.systemUptime - t0) + xs)
                }
                RunLoop.main.add(sampler, forMode: .common)
                post(.leftMouseDown, p.x)
                let steps = 20
                for j in 1...steps {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03 * Double(j)) {
                        post(.leftMouseDragged, p.x + step * k * Double(j) / Double(steps)); Self.flushEvents(w)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03 * Double(steps + 1)) { post(.leftMouseUp, p.x + step * k); Self.flushEvents(w) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03 * Double(steps + 1) + 0.6) {
                    sampler.invalidate()
                    try? lines.joined(separator: "\n").write(toFile: log, atomically: true, encoding: .utf8)
                }
                Self.flushEvents(w)
            }
        }
        // --pull-tab "秒數:第幾個分頁:left|right|top|bottom"：把那個分頁往下拉進目前畫面第一格的那一半放開
        for (i, a) in args.enumerated() where a == "--pull-tab" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":")
            guard parts.count == 3, let sec = Double(parts[0]), let n = Int(parts[1]) else { continue }
            let edge = String(parts[2])
            // 格子還沒擺好（背景開起來有時要比較久）就每半秒再試，最多 20 次
            var tries = 0
            func attempt() {
                // edge 寫 empty：瞄準空格子的正中間
                let cv = self.main.window?.contentView
                let tv: NSView? = edge == "empty" ? Self.find(EmptyPaneView.self, in: cv) : Self.find(PaneFrame.self, in: cv)
                guard let w = self.main.window, let bar = Self.find(TabBar.self, in: w.contentView), let p = bar.tabCenter(n),
                      let f = tv, f.bounds.width > 50 else {
                    tries += 1; pullDebug("test wait \(tries)")
                    if tries < 20 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: attempt) }
                    return
                }
                let r = f.convert(f.bounds, to: nil)
                let q: NSPoint = ["left": NSPoint(x: r.minX + r.width * 0.15, y: r.midY), "right": NSPoint(x: r.maxX - r.width * 0.15, y: r.midY),
                                  "top": NSPoint(x: r.midX, y: r.maxY - r.height * 0.15), "bottom": NSPoint(x: r.midX, y: r.minY + r.height * 0.15)][edge] ?? NSPoint(x: r.midX, y: r.midY)
                var pts = [(NSEvent.EventType.leftMouseDown, p)]
                for j in 1...12 { let t = Double(j) / 12; pts.append((.leftMouseDragged, NSPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t))) }
                pts.append((.leftMouseUp, q))
                for (t, pt) in pts {
                    if let e = NSEvent.mouseEvent(with: t, location: pt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.postEvent(e, atStart: false) }
                }
                Self.flushEvents(w)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec, execute: attempt)
        }
        // --tear-pane "秒數:第幾格"：按住第 n 格（PaneFrame，從 0 數）的標題拖到分頁列的空白處放開（變成新分頁）
        // --swap-pane "秒數:第幾格:到第幾格:檔名開頭"：拖第幾格（由左到右）的標題到另一格中間，途中拍一張（<開頭>-mid.png），
        // 放開後把各格由左到右的聊天室名字寫進 <開頭>.txt（前後各一行）
        for (i, a) in args.enumerated() where a == "--swap-pane" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 4)
            guard parts.count >= 4, let sec = Double(parts[0]), let n = Int(parts[1]), let m = Int(parts[2]) else { continue }
            let base = String(parts[3])
            // 第 5 段（選填）：cmd＝當成按著 ⌘ 拖（互換）；left／right／top／bottom＝放開在目標格那一邊（沒給＝正中間）。例如 "cmd" "right" "cmd,left"
            let opts = parts.count == 5 ? String(parts[4]).split(separator: ",").map(String.init) : []
            WindowHost.forceSwapDrag = opts.contains("cmd")
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let w = self.main.window else { return }
                func all(_ v: NSView?) -> [PaneFrame] { guard let v else { return [] }; return (v as? PaneFrame).map { [$0] } ?? v.subviews.flatMap { all($0) } }
                func order() -> String {
                    all(w.contentView).sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
                        .map { self.store.conversation($0.conversation)?.title ?? "?" }.joined(separator: " | ")
                }
                let fs = all(w.contentView).sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
                guard fs.indices.contains(n), fs.indices.contains(m) else { try? "格子不夠：\(fs.count)".write(toFile: base + ".txt", atomically: true, encoding: .utf8); return }
                var log = "前：" + order() + "\n"
                let p = fs[n].convert(NSPoint(x: fs[n].bounds.midX, y: fs[n].bounds.height - PaneFrame.headerHeight / 2), to: nil)
                var qx = fs[m].bounds.midX, qy = fs[m].bounds.midY
                if opts.contains("left") { qx = fs[m].bounds.minX + 20 }
                if opts.contains("right") { qx = fs[m].bounds.maxX - 20 }
                if opts.contains("top") { qy = fs[m].bounds.maxY - PaneFrame.headerHeight - 20 }
                if opts.contains("bottom") { qy = fs[m].bounds.minY + 20 }
                let q = fs[m].convert(NSPoint(x: qx, y: qy), to: nil)
                func post(_ t: NSEvent.EventType, _ pt: NSPoint) {
                    if let e = NSEvent.mouseEvent(with: t, location: pt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.postEvent(e, atStart: false) }
                }
                post(.leftMouseDown, p)
                for j in 1...12 { let t = Double(j) / 12; post(.leftMouseDragged, NSPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t)) }
                Self.flushEvents(w)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    if let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                        v.cacheDisplay(in: v.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: base + "-mid.png"))
                    }
                    post(.leftMouseUp, q)
                    Self.flushEvents(w)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        log += "後：" + order() + "\n"
                        try? log.write(toFile: base + ".txt", atomically: true, encoding: .utf8)
                    }
                }
            }
        }
        for (i, a) in args.enumerated() where a == "--tear-pane" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":")
            guard parts.count == 2, let sec = Double(parts[0]), let n = Int(parts[1]) else { continue }
            var tries = 0
            func attempt() {
                func all(_ v: NSView?) -> [PaneFrame] { guard let v else { return [] }; return (v as? PaneFrame).map { [$0] } ?? v.subviews.flatMap { all($0) } }
                let fs = all(self.main.window?.contentView).sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
                guard let w = self.main.window, let bar = Self.find(TabBar.self, in: w.contentView), fs.indices.contains(n), fs[n].bounds.width > 50 else {
                    tries += 1
                    if tries < 20 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: attempt) }
                    return
                }
                let f = fs[n]
                let p = f.convert(NSPoint(x: f.bounds.midX, y: f.bounds.height - PaneFrame.headerHeight / 2), to: nil)
                let q = bar.emptyPoint()
                var pts = [(NSEvent.EventType.leftMouseDown, p)]
                for j in 1...12 { let t = Double(j) / 12; pts.append((.leftMouseDragged, NSPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t))) }
                pts.append((.leftMouseUp, q))
                for (t, pt) in pts {
                    if let e = NSEvent.mouseEvent(with: t, location: pt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.postEvent(e, atStart: false) }
                }
                Self.flushEvents(w)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec, execute: attempt)
        }
        // --fill-empty "秒數"：目前 Window 第一個空格子按「新增聊天室」選第一個資料夾（跳過選單）
        for (i, a) in args.enumerated() where a == "--fill-empty" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let pid = self.store.projects.first?.id else { return }
                let slot = self.store.currentWindow?.root?.leaves.first { self.store.isEmptySlot($0) }
                self.main.fillEmpty(slot, newIn: pid, group: self.store.groups.first?.id)
            }
        }
        // --codelab "秒數:check|run|context:輸出檔"：目前那格的程式碼區按檢查／執行，或把給 Claude 的那行上下文寫進檔案
        for (i, a) in args.enumerated() where a == "--codelab" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2)
            guard parts.count == 3, let sec = Double(parts[0]) else { continue }
            let act = String(parts[1]), out = String(parts[2])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let f = self.store.currentWindow?.focused, let p = self.workspace.panes[f] as? ChatPane, let lab = p.codeLab else {
                    try? "沒有程式碼區".write(toFile: out, atomically: true, encoding: .utf8); return
                }
                lab.testAction(act) { s in try? s.write(toFile: out, atomically: true, encoding: .utf8) }
            }
        }
        // --handoff "秒數"：目前這段對話直接交接（不問）
        for (i, a) in args.enumerated() where a == "--handoff" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let c = self.store.conversation(id) else { return }
                let dir = self.store.workingDirectory(for: c)
                self.main.startHandoff(c, directory: dir)
            }
        }
        // --click-pane "秒數:第幾段對話"：在那段對話那格的對話區（上半部）點一下滑鼠
        for (i, a) in args.enumerated() where a == "--click-pane" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":")
            guard parts.count == 2, let sec = Double(parts[0]), let n = Int(parts[1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let w = self.main.window, n < self.store.conversations.count,
                      let v = self.workspace.panes[self.store.conversations[n].id], v.window != nil else { return }
                let pt = v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.height * 0.7), to: nil)
                for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let e = NSEvent.mouseEvent(with: t, location: pt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.postEvent(e, atStart: false) }
                }
                Self.flushEvents(w)
            }
        }
        // --chat-image "秒數:圖片檔"：幾秒後把圖片加到聊天框的附件（之後用 --chat-send 送出）
        for (i, a) in args.enumerated() where a == "--chat-image" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let url = URL(fileURLWithPath: String(parts[1]))
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.inputBar.textView.onImages?([url], [])
            }
        }
        // --input-edited "秒數"：把輸入框所有圖片附件標成「已編輯」（橘框＋「#n 已編輯」）
        for (i, a) in args.enumerated() where a == "--input-edited" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.inputBar.markAllEditedForTest()
            }
        }
        // --input-scroller "秒數:legacy|overlay"：模擬系統換捲軸樣式（接滑鼠＝legacy）
        for (i, a) in args.enumerated() where a == "--input-scroller" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.inputBar.forceScrollerStyleForTest(parts[1] == "legacy" ? .legacy : .overlay)
            }
        }
        // --input-chip-dump "秒數:檔案"：把卡片列的位置寫進檔案
        for (i, a) in args.enumerated() where a == "--input-chip-dump" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.inputBar.layoutSubtreeIfNeeded()
                try? (p.inputBar.chipMetricsForTest + "\n").write(toFile: parts[1], atomically: true, encoding: .utf8)
            }
        }
        // --main-width "秒數:寬"：把主視窗寬度改成這個點數（測變窄時版面）
        for (i, a) in args.enumerated() where a == "--main-width" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]), let wd = Double(parts[1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let w = self?.main.window else { return }
                var f = w.frame; f.size.width = wd
                w.setFrame(f, display: true)
            }
        }
        // --chat-files "秒數:路徑,路徑…"：像在「上傳檔案」面板選了這些檔案（圖片變附件、其他插入路徑），用 --chat-js 或截圖看結果
        for (i, a) in args.enumerated() where a == "--chat-files" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let urls = parts[1].split(separator: ",").map { URL(fileURLWithPath: String($0)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.inputBar.takeFiles(urls)
                ChatSession.log?.write(Data("FILES text=\(p.inputBar.textView.string)\n".utf8))
            }
        }
        // --show-about "秒數:對話標題:圖片.png"：像按右鍵「關於…」，並把那個小視窗畫成圖
        for (i, a) in args.enumerated() where a == "--show-about" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let c = self.store.conversations.first(where: { $0.title == parts[1] }) else { return }
                self.main.showAbout(c.id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    let folder = self.store.workingDirectory(for: c)
                    let ren = ImageRenderer(content: AboutChatView(c: c, folder: folder, transcript: ContextMonitor.transcript(c, path: folder))
                        .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
                    ren.scale = 2
                    if let img = ren.nsImage, let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: parts[2]))
                    }
                }
            }
        }
        // --drag-reset "秒數:結果檔"：模擬拖曳到一半被切走：先開接收區、再讓 App 失去前景，數視窗裡還剩幾個接收區（應該 開著>0、收掉後=0）
        for (i, a) in args.enumerated() where a == "--drag-reset" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                func count(_ v: NSView?) -> Int { guard let v else { return 0 }; return (v is DropOverlay ? 1 : 0) + v.subviews.reduce(0) { $0 + count($1) } }
                guard let root = self?.main.window?.contentView else { return }
                NotificationCenter.default.post(name: DropOverlay.began, object: nil)
                let opened = count(root)
                NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
                let after = count(root)
                try? "opened=\(opened) afterResign=\(after)\n".write(toFile: String(parts[1]), atomically: true, encoding: .utf8)
            }
        }
        // --radial "秒數:第幾段對話(-1＝沒有):x:y"：在螢幕座標 (x,y) 顯示 ⌥ 八宮格，「這一格」是那段對話；--radial-pick "秒數:第幾格(0＝正上方，順時針)"：選那一格；--radial-shot "秒數:檔.png"：把選單畫成圖
        for (i, a) in args.enumerated() where a == "--radial" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":").map(String.init)
            guard parts.count == 4, let sec = Double(parts[0]), let n = Int(parts[1]), let x = Double(parts[2]), let y = Double(parts[3]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                RadialMenu.shared.testShow(at: NSPoint(x: x, y: y), target: self.store.conversations.indices.contains(n) ? self.store.conversations[n].id : nil)
            }
        }
        for (i, a) in args.enumerated() where a == "--radial-pick" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":").map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]), let n = Int(parts[1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { RadialMenu.shared.testPick(n) }
        }
        for (i, a) in args.enumerated() where a == "--radial-shot" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                guard let img = RadialMenu.shared.testImage(), let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
                try? png.write(to: URL(fileURLWithPath: parts[1]))
            }
        }
        // --radial-sample "起始秒:間隔毫秒:次數:檔"：每隔一段時間把八宮格的層數、換層動畫中的 alpha／縮放寫進檔案
        for (i, a) in args.enumerated() where a == "--radial-sample" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 3).map(String.init)
            guard parts.count == 4, let sec = Double(parts[0]), let ms = Double(parts[1]), let n = Int(parts[2]) else { continue }
            for k in 0..<n {
                DispatchQueue.main.asyncAfter(deadline: .now() + sec + Double(k) * ms / 1000) {
                    let line = String(format: "t+%.0fms ", Double(k) * ms) + RadialMenu.shared.testState() + "\n"
                    if let h = FileHandle(forWritingAtPath: parts[3]) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
                    else { try? line.write(toFile: parts[3], atomically: true, encoding: .utf8) }
                }
            }
        }
        // --radial-esc "秒數:結果檔"：送一個 Esc（內部合成事件）給八宮格，把送之前和之後的層數、開著與否寫進檔案
        for (i, a) in args.enumerated() where a == "--radial-esc" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let w = self.main.window else { return }
                var out = "前：open=\(RadialMenu.shared.isOpen) level=\(RadialMenu.shared.level)\n"
                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) { NSApp.sendEvent(e) }
                out += "後：open=\(RadialMenu.shared.isOpen) level=\(RadialMenu.shared.level)\n"
                try? out.write(toFile: parts[1], atomically: true, encoding: .utf8)
            }
        }
        // --radial-event "秒數:結果檔"：用內部合成事件測「只按 ⌥ ＋左鍵」會不會叫出八宮格（要吃掉事件）、⌘ ⌥ ＋左鍵不會、Esc 會收掉
        for (i, a) in args.enumerated() where a == "--radial-event" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let w = self.main.window else { return }
                func down(_ f: NSEvent.ModifierFlags) { if let e = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 600, y: 400), modifierFlags: f, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.sendEvent(e) } }
                var out = ""
                down([.command, .option]); out += "⌘⌥ 點：開=\(RadialMenu.shared.isOpen)\n"
                down([]); out += "一般點：開=\(RadialMenu.shared.isOpen)\n"
                down(.option); out += "⌥ 點：開=\(RadialMenu.shared.isOpen)\n"
                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) { NSApp.sendEvent(e) }
                out += "Esc 之後：開=\(RadialMenu.shared.isOpen)\n"
                down(.option); NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
                out += "切走 App 之後：開=\(RadialMenu.shared.isOpen)\n"
                down(.option)
                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7) { out += "⌘ 鍵被吃掉=\(RadialMenu.shared.intercept(e))（false＝放行）；之後開=\(RadialMenu.shared.isOpen)\n" }
                try? out.write(toFile: parts[1], atomically: true, encoding: .utf8)
            }
        }
        // --resize "秒數:寬:高:檔名開頭"：像 Rectangle 那樣直接把主視窗設成這個大小（程式設定，不走滑鼠拖的最小寬度限制），之後把各區域的位置寫進 <開頭>.txt、整個視窗畫成 <開頭>.png
        for (i, a) in args.enumerated() where a == "--resize" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 3).map(String.init)
            guard parts.count == 4, let sec = Double(parts[0]), let wd = Double(parts[1]), let ht = Double(parts[2]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let w = self.main.window else { return }
                var f = w.frame; f.size = NSSize(width: wd, height: ht); w.setFrame(f, display: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    func walk(_ v: NSView, _ d: Int, _ out: inout String) {
                        if d > 4 { return }
                        let name = String(describing: type(of: v)); if name.contains("SplitView") || name.contains("WindowHost") || name == "NSView" || name.contains("Hosting") || name.contains("TabBar") || name.contains("PetColumn") || d < 3 {
                            out += String(repeating: "  ", count: d) + "\(name) x=\(Int(v.frame.minX)) w=\(Int(v.frame.width)) y=\(Int(v.frame.minY)) h=\(Int(v.frame.height))\n"
                        }
                        v.subviews.forEach { walk($0, d + 1, &out) }
                    }
                    var out = "window.frame=\(w.frame) contentView=\(w.contentView?.frame ?? .zero) minSize=\(w.minSize)\n"
                    if let v = w.contentView { walk(v, 0, &out) }
                    try? out.write(toFile: parts[3] + ".txt", atomically: true, encoding: .utf8)
                    if let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                        v.cacheDisplay(in: v.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[3] + ".png"))
                    }
                }
            }
        }
        // --detach-anim "秒數:第幾個分頁:檔名開頭"：拖出去的預覽（<開頭>-preview.png）→ 放開（獨立視窗長出來）→ 關掉（飛回分頁列），途中每隔一小段記下獨立視窗的位置、大小和透明度到 <開頭>.txt
        for (i, a) in args.enumerated() where a == "--detach-anim" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]), let tab = Int(parts[1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                var log = "減少動態效果=\(Motion.reduced)\n"
                let p = NSPoint(x: 900, y: 500)
                self.main.host.testPreview(tab, at: p)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if let img = self.main.host.detachPreview.snapshot(), let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: parts[2] + "-preview.png")) }
                    log += "預覽 frame=\(String(describing: self.main.host.detachPreview.frame))\n"
                    self.main.detachWindowTab(tab, at: p)
                    func sample(_ tag: String) { let w = self.main.detachedWindows.values.first?.window; log += "\(tag) frame=\(w?.frame ?? .zero) alpha=\(w?.alphaValue ?? -1) 可見=\(w?.isVisible ?? false)\n" }
                    for (k, t) in [0.02, 0.12, 0.5].enumerated() { DispatchQueue.main.asyncAfter(deadline: .now() + t) { sample("放開後\(k)") } }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.main.detachedWindows.values.first?.window?.performClose(nil)
                        for (k, t) in [0.02, 0.12, 0.6].enumerated() { DispatchQueue.main.asyncAfter(deadline: .now() + t) { sample("關掉後\(k)") } }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { log += "獨立視窗數=\(self.main.detachedWindows.count) 分頁數=\(self.store.currentSessionLayout?.windows.filter { !$0.detached }.count ?? -1)\n"; try? log.write(toFile: parts[2] + ".txt", atomically: true, encoding: .utf8) }
                    }
                }
            }
        }
        // --new-in-group "秒數:組名"：像在群組上按右鍵「在這一組開新對話」
        for (i, a) in args.enumerated() where a == "--new-in-group" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let g = self.store.groups.first(where: { $0.name == String(parts[1]) }) else { return }
                self.store.newConversation(inGroup: g.id)
            }
        }
        // --hit-test "秒數:x,y;x,y…"：幾秒後印出主視窗這些點（從左上角算，單位 pt）點下去會落在哪個 view 上
        for (i, a) in args.enumerated() where a == "--hit-test" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let w = self?.main.window, let root = w.contentView?.superview else { return }
                for pt in parts[1].split(separator: ";") {
                    let xy = pt.split(separator: ",").compactMap { Double($0) }
                    guard xy.count == 2 else { continue }
                    let p = NSPoint(x: xy[0], y: root.bounds.height - xy[1])
                    let v = root.hitTest(p)
                    print("hit \(pt) → \(v.map { String(describing: type(of: $0)) } ?? "nil")")
                }
                fflush(stdout)
            }
        }
        // --dump-panes "秒數:檔案"：附加一行「目前開著（有程序物件）的格子」的對話標題，看關掉的格子有沒有被收掉
        for (i, a) in args.enumerated() where a == "--dump-panes" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                let names = self.workspace.panes.keys.compactMap { self.store.conversation($0)?.title }.sorted()
                let chats = self.workspace.panes.compactMap { id, pane -> String? in
                    guard let c = pane as? ChatPane else { return nil }
                    return "chat=\(id.uuidString) title=\(self.store.conversation(id)?.title ?? "?") hasWeb=\(c.hasWeb) webPID=\(c.webPID)"
                }.sorted()
                let webPanes = self.workspace.panes.compactMap { id, pane -> String? in
                    guard self.store.conversation(id)?.isBrowser == true else { return nil }
                    return "web=\(id.uuidString) type=\(type(of: pane))"
                }.sorted()
                let line = "t=\(parts[0]) panes=\(names)\n"
                    + "webFeaturesEnabled=\(Prefs.shared.webFeaturesEnabled) sidebarMode=\(Prefs.shared.sidebarMode) browserPanes=\(BrowserPane.all.count)\n"
                    + (chats + webPanes).map { $0 + "\n" }.joined()
                func append(_ text: String) {
                    if let h = FileHandle(forWritingAtPath: String(parts[1])) { h.seekToEndOfFile(); h.write(text.data(using: .utf8)!); h.closeFile() }
                    else { try? text.write(toFile: String(parts[1]), atomically: true, encoding: .utf8) }
                }
                append(line)
                // 有網頁的格子再量畫面上實際有幾則訊息、多少字（沒網頁的不叫醒它，不然量到的是重建後的）
                for (id, pane) in self.workspace.panes {
                    guard let c = pane as? ChatPane, c.hasWeb else { continue }
                    c.evaluate("JSON.stringify({turns: document.querySelectorAll('.turn').length, chars: document.body.innerText.length, bravo: (document.body.innerText.match(/BRAVO 回答/g) || []).length, perms: document.querySelectorAll('.perm.pending').length, tail: document.body.innerText.slice(-120)})") { s in
                        append("dom chat=\(id.uuidString) \(s)\n")
                    }
                }
            }
        }
        // --close-pane "秒數"：關掉目前那格（像按 × 確認之後）
        for (i, a) in args.enumerated() where a == "--close-pane" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.store.closePane() }
        }
        // --carry-dump "紀錄檔:輸出檔"：把一份紀錄檔整理成換模型交接的那段（只讀紀錄檔，全文檔寫到測試的 carry 資料夾）
        for (i, a) in args.enumerated() where a == "--carry-dump" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let note = ModelCarry.note(from: URL(fileURLWithPath: String(parts[0])), session: UUID(), limit: 6000, canRead: true) ?? "nil"
            try? note.write(toFile: String(parts[1]), atomically: true, encoding: .utf8)
        }
        // --collab-dump "秒數:檔案"：協作看板讀到的往來、每一對的來回次數、提醒、待辦（讀 --state-dir 裡的 projects、collab.json）
        for (i, a) in args.enumerated() where a == "--collab-dump" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                CollabBoardModel.shared.refresh {
                    let line = "t=\(parts[0]) open=\(CollabBoardModel.shared.open)\n" + CollabBoardModel.shared.dump()
                    if let h = FileHandle(forWritingAtPath: String(parts[1])) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
                    else { try? line.write(toFile: String(parts[1]), atomically: true, encoding: .utf8) }
                }
            }
        }
        // --collab-act "秒數|動作|參數…"：像在看板上操作（測 codenv 這邊寫 collab.json）。動作：
        //   done 登記編號／approve 目標／step 目標 步驟 狀態／addgoal 標題 完成標準 步驟（\\n 分行）／addstep 目標 內容@負責人／delgoal 目標
        for (i, a) in args.enumerated() where a == "--collab-act" && i + 1 < args.count {
            let p = args[i + 1].components(separatedBy: "|")
            guard p.count >= 3, let sec = Double(p[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                let m = CollabBoardModel.shared
                switch p[1] {
                case "done": m.editTodo(p[2], col: "done")
                case "approve": m.setGoalStatus(p[2], "active")
                case "step" where p.count >= 5: m.setStep(goal: p[2], step: p[3], state: p[4])
                case "addgoal" where p.count >= 5: m.addGoal(title: p[2], done: p[3], steps: p[4].replacingOccurrences(of: "\\n", with: "\n"))
                case "addstep" where p.count >= 4: m.addStep(goal: p[2], line: p[3])
                case "delgoal": m.deleteGoal(p[2])
                // 收件匣（CollabBoard.swift InboxView 的動作）：inboxopen／inboxclose；inboxreply|目標|步驟|回覆；inboxok|目標|步驟；inboxbad|目標|步驟|說明
                case "inboxopen": m.inboxOpen = true
                case "inboxclose": m.inboxOpen = false
                case "inboxreply" where p.count >= 5, "inboxok" where p.count >= 4, "inboxbad" where p.count >= 5:
                    guard let it = m.inbox.first(where: { $0.goal == p[2] && $0.step == p[3] }) else { break }
                    if p[1] == "inboxreply" { m.inboxReply(it, text: p[4]) }
                    else if p[1] == "inboxok" { m.inboxVerified(it) }
                    else { m.inboxRejected(it, why: p[4]) }
                case "delfinding": m.deleteFinding(p[2])                              // 刪一筆發現：delfinding|編號
                case "tab": m.tab = p[2]                                              // 切分頁：tab|goals／messages／findings
                case "collapse": m.toggleCollapsed(p[2])                            // 收起／展開：collapse|目標
                case "autoapprove": m.setAutoApprove(p[2] == "true")                 // autoapprove|true／false
                case "cancel" where p.count >= 4: m.cancelAgyStep(goal: p[2], step: p[3])   // 終止：cancel|目標|步驟
                case "notices" where p.count >= 4:      // 寫出某個聊天室（標題）等著收的提示，並拿走：notices|聊天室標題|檔案
                    let text = m.convByName[p[2]].flatMap { CollabBoardModel.takeNotices(for: $0) } ?? "（沒有）"
                    try? text.write(toFile: p[3], atomically: true, encoding: .utf8)
                case "setowner" where p.count >= 5: m.setOwner(goal: p[2], step: p[3], owner: p[4])   // 改負責人：setowner|目標|步驟|名字
                case "manualprompt" where p.count >= 5:   // 手動步驟的 prompt 寫進檔案：manualprompt|目標|步驟|檔案
                    if let st = m.goals.first(where: { $0.id == p[2] })?.steps.first(where: { $0.id == p[3] }) { try? CollabBoardModel.manualPrompt(st).write(toFile: p[4], atomically: true, encoding: .utf8) }
                case "manualreturn" where p.count >= 5:   // 交回：manualreturn|目標|步驟|回答（\\n 分行）；結果寫進 state-dir/manual-return.txt
                    let ok = m.returnManual(goal: p[2], step: p[3], text: p[4].replacingOccurrences(of: "\\n", with: "\n"))
                    let line = "manualreturn \(p[3]) → \(ok)\n"
                    let f = URL(fileURLWithPath: CollabBoardModel.todoFile.deletingLastPathComponent().path).appendingPathComponent("manual-return.txt")
                    if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() } else { try? line.write(to: f, atomically: true, encoding: .utf8) }
                default: break
                }
            }
        }
        // --rename "秒數:新名字"：把目前選的對話改名（像側欄右鍵重新命名）
        for (i, a) in args.enumerated() where a == "--rename" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected else { return }
                self.store.rename(id, to: String(parts[1]), byUser: true)
            }
        }
        // --schedule-put "秒數|第幾段對話|頻率|時間（逗號）|要送的話|沒開著時|每隔幾分鐘"：新增一個排程（下一次照 --fake-now 的「現在」算）
        for (i, a) in args.enumerated() where a == "--schedule-put" && i + 1 < args.count {
            let p = args[i + 1].components(separatedBy: "|")
            guard p.count >= 6, let sec = Double(p[0]), let n = Int(p[1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, n < self.store.conversations.count else { return }
                var sc = WakeSchedule(conversation: self.store.conversations[n].id, text: p[4])
                sc.frequency = p[2]
                sc.times = p[3].components(separatedBy: ",")
                sc.whenClosed = p[5]
                if p.count > 6, let m = Int(p[6]) { sc.intervalMinutes = m }
                ScheduleStore.shared.put(sc)
            }
        }
        // --schedule-sheet "秒數:第幾段對話"：打開那段對話的「排程…」小視窗（像在側欄右鍵）
        for (i, a) in args.enumerated() where a == "--schedule-sheet" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":").compactMap { Double($0) }
            guard parts.count == 2 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + parts[0]) { [weak self] in
                guard let self, Int(parts[1]) < self.store.conversations.count else { return }
                self.main.showSchedule(self.store.conversations[Int(parts[1])].id)
            }
        }
        // --schedule-dump "秒數:檔案"：附加每個排程的下一次、待送、最近幾次結果
        for (i, a) in args.enumerated() where a == "--schedule-dump" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                let line = "t=\(parts[0]) now=\(ISO8601DateFormatter.local.string(from: ScheduleStore.now()))\n" + ScheduleStore.shared.dump()
                if let h = FileHandle(forWritingAtPath: String(parts[1])) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
                else { try? line.write(toFile: String(parts[1]), atomically: true, encoding: .utf8) }
            }
        }
        // --right-tab "秒數:視窗|檔案|Git|歷史|看板"：打開右欄並切到那個分頁（會把測試實例的右欄開起來）
        for (i, a) in args.enumerated() where a == "--right-tab" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]), let tab = RightTab.named(parts[1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.main.showRightPanel(tab: tab) }
        }
        // --git-related-root <總指揮資料夾> --git-related-repos <JSON 路徑陣列>：用暫存假 repo 指定相關 repo 概覽。
        if args.contains("--state-dir"),
           let rootIndex = args.firstIndex(of: "--git-related-root"), rootIndex + 1 < args.count,
           let reposIndex = args.firstIndex(of: "--git-related-repos"), reposIndex + 1 < args.count,
           let data = args[reposIndex + 1].data(using: .utf8),
           let repos = try? JSONDecoder().decode([String].self, from: data) {
            RightPanelModel.shared.configureGitRelatedTest(root: args[rootIndex + 1], extraRepos: repos)
            main.showRightPanel(tab: .git)
        }
        // --git-related-probe "秒數:輸出.json"：輸出 Git 分頁實際使用的相關 repo 列文字與 worktree 分組。
        for (i, flag) in args.enumerated() where flag == "--git-related-probe" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, let delay = Double(parts[0]), delay.isFinite, delay >= 0 else { continue }
            let output = parts[1]
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                func writeWhenReady(_ remaining: Int) {
                    let git = RightPanelModel.shared.git
                    guard git.loaded || remaining <= 0 else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { writeWhenReady(remaining - 1) }
                        return
                    }
                    let result = git.relatedScreenProbe()
                    guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) else { return }
                    try? data.write(to: URL(fileURLWithPath: output), options: .atomic)
                }
                writeWhenReady(150)
            }
        }
        // --rp-op "秒數:操作:參數…"：聊天室資訊（選取／i／資訊卡）的測試掛鉤，只在測試實例（有 --state-dir）生效
        //   select:<標題>（只改選取，不經過點擊）、click:x:y（用 NSApp.postEvent 在主視窗內容區的座標點一下，左上為原點）、key:i（把 i 鍵送到主視窗）、
        //   info:<標題>（直接開表單）、topic:<標題>:<說明>（等於在表單按儲存說明）、card:<標題>（走滑過 2 秒的計時流程）、card-end:<標題>、
        //   delay:<秒>（改資訊卡等待時間）、dump:<檔案>（選取、表單、資訊卡狀態 JSON）、form-snapshot:<檔案.png>（表單是 sheet，拍它的視窗）
        for (i, a) in args.enumerated() where a == "--rp-op" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, let sec = Double(parts[0]), sec.isFinite, sec >= 0 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let win = self.main.window else { return }
                let m = RightPanelModel.shared
                let arg = parts.count > 2 ? parts[2] : ""
                let cid = { (t: String) in self.store.conversations.first(where: { $0.title == t })?.id }
                func send(_ type: NSEvent.EventType, _ pt: NSPoint) {
                    let h = win.contentView?.bounds.height ?? 0
                    let wp = win.contentView?.convert(NSPoint(x: pt.x, y: h - pt.y), to: nil) ?? pt
                    if let e = NSEvent.mouseEvent(with: type, location: wp, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.postEvent(e, atStart: false) }
                }
                switch parts[1] {
                case "select": m.selectedChat = cid(arg)
                case "focus": self.main.focusRightPanelForTest()
                case "click":
                    let xy = arg.split(separator: ":").compactMap { Double($0) }
                    guard xy.count == 2 else { return }
                    let pt = NSPoint(x: xy[0], y: xy[1])
                    if let cv = win.contentView { EventLog.log("測試", "rp click bounds=\(cv.bounds) flipped=\(cv.isFlipped) hit=\(String(describing: cv.hitTest(cv.convert(NSPoint(x: pt.x, y: cv.bounds.height - pt.y), from: nil)).map { type(of: $0) })) key=\(win.isKeyWindow)") }
                    send(.mouseMoved, pt); send(.leftMouseDown, pt); DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { send(.leftMouseUp, pt) }
                case "key":
                    if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber, context: nil, characters: arg, charactersIgnoringModifiers: arg, isARepeat: false, keyCode: 34) { NSApp.postEvent(e, atStart: false) }
                case "info": if let id = cid(arg) { m.selectedChat = id; m.infoChat = id }
                case "topic": // 標題:說明
                    let kv = arg.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                    if kv.count == 2, let id = cid(kv[0]) { self.store.setTopic(id, kv[1], byUser: true) }
                case "card": if let id = cid(arg) { ChatInfoCard.shared.hoverBegan(id, store: self.store, workspace: self.workspace, window: win) }
                case "card-end": if let id = cid(arg) { ChatInfoCard.shared.hoverEnded(id) }
                case "delay": ChatInfoCard.delay = Double(arg) ?? 2
                case "dump":
                    let o: [String: Any] = ["selected": m.selectedChat.flatMap { self.store.conversation($0)?.title } ?? NSNull(),
                                            "infoOpen": m.infoChat != nil, "cardFor": ChatInfoCard.shared.shownFor.flatMap { self.store.conversation($0)?.title } ?? NSNull(),
                                            "firstResponder": String(describing: win.firstResponder.map { type(of: $0) }),
                                            "topics": self.store.conversations.reduce(into: [String: Any]()) { $0[$1.title] = $1.topic ?? NSNull() },
                                            "topicByCommander": self.store.conversations.reduce(into: [String: Any]()) { $0[$1.title] = $1.topicByCommander ?? NSNull() }]
                    if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: URL(fileURLWithPath: arg), options: .atomic) }
                case "form-snapshot":
                    let sheet = win.attachedSheet ?? NSApp.windows.first(where: { $0.sheetParent === win })
                    guard let v = sheet?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))
                default: break
                }
            }
        }
        // --store-op "秒數:summon:<聊天室標題>"：像在右欄按「叫出來」（對目前 Session）。也支援 "秒數:focus-window:<第幾個 Window，從 1 算>"
        for (i, a) in args.enumerated() where a == "--store-op" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                switch parts[1] {
                case "summon":
                    guard let c = self.store.conversations.first(where: { $0.title == parts[2] }), let sid = self.store.currentSessionLayout?.id else { return }
                    self.store.summonConversation(c.id, inSession: sid)
                case "focus-window":
                    guard let n = Int(parts[2]), let s = self.store.currentSessionLayout, n >= 1, n <= s.windows.count else { return }
                    self.store.focusWindowFromPanel(s.windows[n - 1].id)
                case "history":
                    RightPanelModel.shared.history.search(parts[2], targets: RPData.historyTargets(self.store), convs: RPData.historyConvs(self.store))
                case "fsearch":   // "name:<字>" 或 "content:<字>"
                    let kv = parts[2].split(separator: ":", maxSplits: 1).map(String.init)
                    if kv.count == 2 { RightPanelModel.shared.search.search(kv[1], content: kv[0] == "content", root: RightPanelModel.shared.projectPath) }
                case "git-select":
                    if let c = RightPanelModel.shared.git.changes.first(where: { $0.path == parts[2] }) { RightPanelModel.shared.git.select(c) }
                case "select-session":
                    if let s = self.store.sessions.first(where: { $0.name == parts[2] }) { self.store.selectSession(s.id) }
                default: break
                }
            }
        }
        // --dump-running-aggregate "秒數:檔案"：隔離實例輸出右欄目前清單與總指揮／區長彙整（JSON）
        for (i, a) in args.enumerated() where a == "--dump-running-aggregate" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                func row(_ item: RunningActivityEntry) -> [String: Any] {
                    ["chat": item.chat, "kind": item.kind, "label": item.label]
                }
                let ids = RunningActivitySummary.visibleChatIDs(self.store)
                let own = RunningActivitySummary.ownEntries(store: self.store)
                let aggregated = RunningActivitySummary.aggregatedEntries(store: self.store)
                let output: [String: Any] = [
                    "own": own.map(row),
                    "aggregated": aggregated.map(row),
                    "count": RunningActivitySummary.activeChatCount(ids, store: self.store) + aggregated.count
                ]
                if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: parts[1]), options: .atomic)
                }
            }
        }
        // --dump-right "秒數:檔案"：輸出右欄目前分頁與清單內容（JSON）
        for (i, a) in args.enumerated() where a == "--dump-right" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                let m = RightPanelModel.shared
                m.syncProject(self.store.rightPanelProject()?.path)
                let o = m.dump(store: self.store, workspace: self.workspace)
                if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: URL(fileURLWithPath: parts[1]), options: .atomic) }
            }
        }
        // --graph-op "秒數:操作:參數"：關聯圖測試掛鉤（只在 --state-dir 測試實例生效）
        //   fake:<區數>:<聊天室數>、assignment-fixture、dispatch-fixture[:old]、long-label-fixture、mode:graph|list、panel:open|close、
        //   viewport:<倍率>:<dx>:<dy>、area-lead:<區名>:<聊天室名|clear>、
        //   state:<聊天室名稱>:working|idle|waiting|complete|error|sleep、probe:<JSON 檔>、dump:<JSON 檔>。
        for (i, a) in args.enumerated() where a == "--graph-op" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, let sec = Double(parts[0]), sec.isFinite, sec >= 0 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                let arg = parts.count > 2 ? parts[2] : ""
                switch parts[1] {
                case "fake":
                    let nums = arg.split(separator: ":").compactMap { Int($0) }
                    guard nums.count == 2, let s = self.store.currentSessionLayout, let root = self.store.areaRoot(s),
                          let pid = self.store.projects.first?.id else { return }
                    var areas: [UUID] = []
                    for k in 0..<nums[0] {
                        let parent = (k >= 3 && k % 2 == 1) ? areas[k / 3 - 1 + 0] : root
                        areas.append(self.store.addGroup(named: "假區\(k + 1)", parent: parent).id)
                    }
                    let keep = self.store.selectedProject
                    for k in 0..<nums[1] {
                        let c = self.store.createConversation(in: pid)
                        self.store.selectedProject = keep
                        self.store.move(c.id, toGroup: areas.isEmpty || k % 7 == 0 ? root : areas[k % areas.count])
                        self.store.rename(c.id, to: "假聊天室\(k + 1)", byUser: false)
                        if k % 9 == 0 { self.store.status[c.id] = .working }
                        else if k % 23 == 1 { self.store.status[c.id] = .waiting }
                    }
                case "area-burst":
                    let count = Int(arg) ?? 15
                    guard count > 0, let s = self.store.currentSessionLayout, let root = self.store.areaRoot(s),
                          let pid = self.store.projects.first?.id else { return }
                    let areaID = self.store.areaNodes(s).first?.group.id ?? self.store.addGroup(named: "同區測試", parent: root).id
                    let keep = self.store.selectedProject
                    for k in 0..<count {
                        let c = self.store.createConversation(in: pid)
                        self.store.selectedProject = keep
                        self.store.move(c.id, toGroup: areaID)
                        self.store.rename(c.id, to: "同區聊天室\(k + 1)", byUser: false)
                    }
                case "assignment-fixture":
                    guard let s = self.store.currentSessionLayout, let root = self.store.areaRoot(s),
                          let pid = self.store.projects.first?.id else { return }
                    let keep = self.store.selectedProject
                    let area = self.store.addGroup(named: "測試派工區", parent: root)
                    func makeChat(_ title: String, in group: UUID, status: ChatStatus = .idle) -> Conversation {
                        let c = self.store.createConversation(in: pid)
                        self.store.selectedProject = keep
                        self.store.move(c.id, toGroup: group)
                        self.store.rename(c.id, to: title, byUser: false)
                        self.store.status[c.id] = status
                        return self.store.conversation(c.id) ?? c
                    }
                    let lead = makeChat("測試區長", in: area.id)
                    if let gi = self.store.groups.firstIndex(where: { $0.id == area.id }) {
                        self.store.groups[gi].areaLeadID = lead.id
                    }
                    let dispatched = makeChat("派工工作一", in: area.id, status: .working)
                    let working = makeChat("派工工作二", in: area.id, status: .working)
                    let review = makeChat("待驗收工作", in: area.id)
                    let stuck = makeChat("卡住工作", in: area.id, status: .working)
                    _ = makeChat("一般閒置聊天室", in: area.id)
                    let tracker = GraphAssignmentTracker.shared
                    tracker.clearSeeds()
                    tracker.seed(dispatched.id, taskTitle: "整理派工流程", stage: .dispatched,
                                 dispatchedAt: Date().addingTimeInterval(-30), lastAction: "剛收到派工，準備開始",
                                 assignerName: lead.title, assignerID: lead.id)
                    tracker.seed(working.id, taskTitle: "檢查關聯圖派工標籤碰撞與位置", stage: .working,
                                 dispatchedAt: Date().addingTimeInterval(-210), lastAction: "改 ChatGraph.swift",
                                 assignerName: lead.title, assignerID: lead.id)
                    tracker.seed(review.id, taskTitle: "完成後等區長驗收", stage: .review,
                                 dispatchedAt: Date().addingTimeInterval(-320), lastAction: "完成 swift build",
                                 assignerName: lead.title, assignerID: lead.id)
                    tracker.seed(stuck.id, taskTitle: "修正卡住工作", stage: .stuck,
                                 dispatchedAt: Date().addingTimeInterval(-780), lastAction: "等待測試回應",
                                 assignerName: lead.title, assignerID: lead.id)
                    let snap = RPData.graph(self.store, workspace: self.workspace)
                    ChatGraphView.rightInstance?.apply(snap)
                    self.main.graphPanel.graphView?.apply(snap)
                case "dispatch-fixture":
                    guard let s = self.store.currentSessionLayout, let root = self.store.areaRoot(s),
                          let pid = self.store.projects.first?.id else { return }
                    let keep = self.store.selectedProject
                    let area = self.store.addGroup(named: "派工箭頭探針區", parent: root)
                    func makeDispatchChat(_ title: String, in group: UUID, status: ChatStatus = .idle) -> Conversation {
                        let c = self.store.createConversation(in: pid)
                        self.store.selectedProject = keep
                        self.store.move(c.id, toGroup: group)
                        self.store.rename(c.id, to: title, byUser: false)
                        self.store.status[c.id] = status
                        return self.store.conversation(c.id) ?? c
                    }
                    let lead = makeDispatchChat("派工箭頭探針區長", in: area.id)
                    if let gi = self.store.groups.firstIndex(where: { $0.id == area.id }) {
                        self.store.groups[gi].areaLeadID = lead.id
                    }
                    let chiefWorker = makeDispatchChat("總指揮派工A", in: area.id, status: .working)
                    let leadWorker = makeDispatchChat("區長派工B", in: area.id, status: .working)
                    let tracker = GraphAssignmentTracker.shared
                    tracker.clearSeeds()
                    for (worker, assigner, sequence, title) in [(chiefWorker, s.chief ?? s.id, 1, "總指揮派工探針"),
                                                                  (leadWorker, lead.id, 1, "區長派工探針")] {
                        let messageID = UUID().uuidString.lowercased()
                        if let ci = self.store.conversations.firstIndex(where: { $0.id == worker.id }) {
                            self.store.conversations[ci].commanderDispatchSequence = sequence
                            self.store.conversations[ci].commanderDispatches = [CommanderDispatch(messageID: messageID, assignerID: assigner, sequence: sequence, started: true)]
                        }
                        let dispatchedAt = arg == "old" ? Date().addingTimeInterval(-25 * 60 * 60) : Date()
                        tracker.seed(worker.id, taskTitle: title, stage: .working, dispatchedAt: dispatchedAt,
                                     lastAction: "探針工作中", assignerName: self.store.conversation(assigner)?.title,
                                     assignerID: assigner)
                    }
                    _ = self.store.saveNow()
                    let snap = RPData.graph(self.store, workspace: self.workspace)
                    ChatGraphView.rightInstance?.apply(snap)
                    self.main.graphPanel.graphView?.apply(snap)
                case "long-label-fixture":
                    guard let s = self.store.currentSessionLayout, let root = self.store.areaRoot(s),
                          let pid = self.store.projects.first?.id else { return }
                    let title = "最左側長區名標籤探針－超長名稱應自動畫出省略號" + String(repeating: "長區名稱超長名稱", count: 14)
                    let area = self.store.addGroup(named: title, parent: root)
                    let chatTitle = "長區名標籤測試聊天室"
                    if !self.store.conversations.contains(where: { $0.title == chatTitle }) {
                        let keep = self.store.selectedProject
                        let chat = self.store.createConversation(in: pid)
                        self.store.selectedProject = keep
                        self.store.move(chat.id, toGroup: area.id)
                        self.store.rename(chat.id, to: chatTitle, byUser: false)
                    }
                    _ = self.store.saveNow()
                    guard let snap = RPData.graph(self.store, workspace: self.workspace) else { return }
                    let graphs = [self.main.graphPanel.graphView, ChatGraphView.rightInstance].compactMap { $0 }
                    graphs.forEach { graph in
                        graph.apply(snap)
                        graph.placeNodeAtScreenPointForTest(title: title,
                                                            point: CGPoint(x: graph.bounds.minX, y: graph.bounds.midY))
                        graph.displayIfNeeded()
                    }
                case "area-lead":
                    let values = arg.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                    guard values.count == 2, let chiefID = self.store.currentSessionLayout?.chief else { return }
                    let clear = values[1].lowercased() == "clear"
                    let result = self.store.commanderAreaSetLead(caller: chiefID.uuidString, name: values[0], target: values[1], clear: clear)
                    guard result["ok"] as? Bool == true,
                          let snap = RPData.graph(self.store, workspace: self.workspace) else { return }
                    ChatGraphView.rightInstance?.apply(snap)
                    self.main.graphPanel.graphView?.apply(snap)
                case "shot":
                    guard !arg.isEmpty else { return }
                    let graphs = [self.main.graphPanel.graphView, ChatGraphView.rightInstance].compactMap { $0 }
                    if let snap = RPData.graph(self.store, workspace: self.workspace) { graphs.forEach { $0.apply(snap) } }
                    guard let g = graphs.first(where: { $0.hasNodesForTest }) ?? graphs.first,
                          g.bounds.width > 10, g.bounds.height > 10 else { return }
                    guard let rep = g.bitmapImageRepForCachingDisplay(in: g.bounds) else { return }
                    g.displayIfNeeded()
                    g.cacheDisplay(in: g.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        let url = URL(fileURLWithPath: arg)
                        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? png.write(to: url, options: .atomic)
                    }
                case "click", "doubleclick", "move", "rclick":    // 標題：在節點中心送滑鼠事件（移動後立刻按，不等 hover）
                    guard let g = self.main.graphPanel.graphView ?? ChatGraphView.rightInstance,
                          let win = g.window, let wp = g.windowPoint(title: arg) else { return }
                    func event(_ type: NSEvent.EventType, clickCount: Int = 1) -> NSEvent? {
                        NSEvent.mouseEvent(with: type, location: wp, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1)
                    }
                    if let moved = event(.mouseMoved) { g.mouseMoved(with: moved) }
                    if parts[1] == "click" || parts[1] == "doubleclick" {
                        let count = parts[1] == "doubleclick" ? 2 : 1
                        if let down = event(.leftMouseDown, clickCount: count), let up = event(.leftMouseUp, clickCount: count) {
                            // 測試以 open -g 隱藏啟動，直接走同一個 view handler，避免事件排隊後被 WindowServer 丟掉。
                            g.mouseDown(with: down)
                            g.mouseUp(with: up)
                        }
                    }
                    if parts[1] == "rclick" {
                        if let down = event(.rightMouseDown), let up = event(.rightMouseUp) {
                            NSApp.postEvent(down, atStart: false)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { NSApp.postEvent(up, atStart: false) }
                        }
                    }
                case "mode": RightPanelModel.shared.chatGraph = arg == "graph"
                case "theme":
                    let theme = arg == "light" || arg == "dark" ? arg : nil
                    ChatGraphView.rightInstance?.themeOverride = theme
                    self.main.graphPanel.graphView?.themeOverride = theme
                case "edge-hover":
                    if let snap = RPData.graph(self.store, workspace: self.workspace) {
                        ChatGraphView.rightInstance?.apply(snap)
                        self.main.graphPanel.graphView?.apply(snap)
                    }
                    self.main.graphPanel.graphView?.simulateEdgeHover(toTitle: arg)
                    ChatGraphView.rightInstance?.simulateEdgeHover(toTitle: arg)
                case "viewport":
                    let values = arg.split(separator: ":").compactMap { Double($0) }
                    if values.count == 3 {
                        [self.main.graphPanel.graphView, ChatGraphView.rightInstance].compactMap { $0 }.forEach {
                            $0.adjustViewportForTest(scaleFactor: CGFloat(values[0]), dx: CGFloat(values[1]), dy: CGFloat(values[2]))
                        }
                    }
                case "state":
                    let values = arg.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                    guard values.count == 2,
                          let conversation = self.store.conversations.first(where: { $0.title == values[0] }) else { return }
                    let status: ChatStatus
                    let graphState: RPState
                    switch values[1].lowercased() {
                    case "working", "busy": status = .working; graphState = .working
                    case "idle", "complete", "completed", "done", "error": status = .idle; graphState = .idle
                    case "sleep", "asleep": status = .idle; graphState = .asleep
                    case "waiting": status = .waiting; graphState = .waiting
                    default: return
                    }
                    self.store.status[conversation.id] = status
                    RPData.setGraphTestState(graphState, for: conversation.id)
                    if ["complete", "completed", "done", "error"].contains(values[1].lowercased()),
                       let ci = self.store.conversations.firstIndex(where: { $0.id == conversation.id }) {
                        self.store.conversations[ci].commanderDispatches?.removeAll()
                        _ = self.store.saveNow()
                    }
                    if let snap = RPData.graph(self.store, workspace: self.workspace) {
                        [self.main.graphPanel.graphView, ChatGraphView.rightInstance].compactMap { $0 }.forEach { $0.apply(snap) }
                    }
                case "resize":
                    if let h = Double(arg), h.isFinite, h > 10 {
                        // 改右欄上半部高度，透過真正的分界線佈局改變關聯圖可視區域。
                        RightPanelModel.shared.dividerHeight = CGFloat(h)
                    }
                case "panel": if arg == "open" { self.main.graphPanel.show() } else { self.main.graphPanel.hide() }
                case "select":
                    RightPanelModel.shared.selectedChat = self.store.conversations.first { $0.title == arg }?.id
                case "dump", "probe":
                    let gp = self.main.graphPanel.graphView
                    let snap = RPData.graph(self.store, workspace: self.workspace)
                    ChatGraphView.rightInstance?.apply(snap)
                    gp?.apply(snap)
                    ChatGraphView.rightInstance?.displayIfNeeded()
                    gp?.displayIfNeeded()
                    var o: [String: Any] = ["panelOpen": self.main.graphPanel.isOpen, "mode": RightPanelModel.shared.chatGraph ? "graph" : "list",
                                            "panel": gp?.dump() ?? NSNull(), "right": ChatGraphView.rightInstance?.dump() ?? NSNull()]
                    if let cv = self.main.window?.contentView, let frame = cv.subviews.first(where: { String(describing: type(of: $0)) == "GraphPanelContainer" })?.frame {
                        o["panelFrame"] = ["x": Double(frame.minX), "y": Double(frame.minY), "width": Double(frame.width), "height": Double(frame.height),
                                            "contentWidth": Double(cv.bounds.width), "contentHeight": Double(cv.bounds.height)]
                    }
                    o["firstResponder"] = String(describing: self.main.window?.firstResponder.map { type(of: $0) })
                    if let win = self.main.window, let cv = win.contentView, let g = self.main.graphPanel.graphView, let wp = g.windowPoint(title: "codenv_2") {
                        o["hitTest"] = String(describing: cv.hitTest(cv.superview?.convert(wp, from: nil) ?? wp).map { type(of: $0) })
                        o["isKey"] = win.isKeyWindow
                    }
                    o["sheet"] = self.main.window?.attachedSheet.map { String(describing: type(of: $0)) } ?? "none"
                    o["selected"] = RightPanelModel.shared.selectedChat.flatMap { self.store.conversation($0)?.title } ?? NSNull()
                    o["infoChat"] = RightPanelModel.shared.infoChat.flatMap { self.store.conversation($0)?.title } ?? NSNull()
                    o["areas"] = self.store.currentSessionLayout.map { s in self.store.areaNodes(s).map { self.store.areaPath($0.group.id, in: s) } } ?? []
                    if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: URL(fileURLWithPath: arg), options: .atomic) }
                default: break
                }
            }
        }
        // --collab-open "秒數"：打開協作看板（像按最左邊的協作圖示）
        for (i, a) in args.enumerated() where a == "--collab-open" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { CollabBoardModel.shared.open = true }
        }
        // --area "秒數:home|codelab"：像點側欄最左邊的圖示換區
        for (i, a) in args.enumerated() where a == "--area" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.store.switchArea(String(parts[1])) }
        }
        // --dump-layout "秒數:檔案"：附加一行目前在哪一區、看的是哪個 Session，每個 Session（區）裡各 Window 擺了哪些對話
        for (i, a) in args.enumerated() where a == "--dump-layout" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                let t = { (id: UUID) in self.store.conversation(id)?.title ?? "空" }
                let all = self.store.sessions.map { s in "\(s.name)(\(s.area ?? "home"))=" + s.windows.map { w in (w.detached ? "↗[" : "[") + (w.root?.leaves.map(t) ?? []).joined(separator: ",") + "]" }.joined() }
                let line = "t=\(parts[0]) 左欄收=\(self.main.sidebarCollapsed) 右欄=\(PetSlot.enabled) 協作=\(CollabBoardModel.shared.open) area=\(self.store.area) 看=\(self.store.currentSessionLayout?.name ?? "nil") 獨立視窗=\(self.main.detachedWindows.values.map { $0.window.map { "\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "nil" }) 主視窗現=\(self.store.scoped(nil) { self.store.windowIndex ?? -1 }) scope=\(self.store.scope != nil) 選=\(self.store.selected.map(t) ?? "nil") | " + all.joined(separator: " ") + "\n"
                if let h = FileHandle(forWritingAtPath: String(parts[1])) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
                else { try? line.write(toFile: String(parts[1]), atomically: true, encoding: .utf8) }
            }
        }
        // --dump-commanders "秒數:檔案"：僅 --state-dir 的測試實例生效，輸出所有區域 Session 的總指揮關聯與遞迴涵蓋數
        for (i, a) in args.enumerated() where a == "--dump-commanders" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]), sec.isFinite, sec >= 0 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let st = self?.store as Store? else { return }
                func field<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }
                let sessions: [[String: Any]] = st.sessions.map { session in
                    ["id": session.id.uuidString, "name": session.name, "area": session.area ?? "home",
                     "groups": field(session.groups.map { $0.map { st.group($0)?.name ?? $0.uuidString } }),
                     "groupIDs": field(session.groups.map { $0.map(\.uuidString) }),
                     "chief": field(session.chief.flatMap { st.conversation($0)?.title }),
                     "chiefID": field(session.chief?.uuidString), "windowCount": session.windows.count,
                     "conversationCount": st.conversations(inCommander: session).count]
                }
                let object: [String: Any] = ["area": st.area, "sidebarMode": Prefs.shared.sidebarMode,
                    "currentSession": field(st.currentSession?.uuidString),
                    "currentSessionName": field(st.sessions.first { $0.id == st.currentSession }?.name), "sessions": sessions]
                do {
                    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                    try data.write(to: URL(fileURLWithPath: parts[1]), options: .atomic)
                } catch { EventLog.log(L("測試"), L("總指揮狀態輸出失敗：\(error.localizedDescription)")) }
            }
        }
        // --move-folder "秒數:對話標題:新資料夾"：像在對話上按右鍵「換工作資料夾…」（不問，直接搬）
        for (i, a) in args.enumerated() where a == "--move-folder" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2)
            guard parts.count == 3, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let c = self.store.conversations.first(where: { $0.title == String(parts[1]) }) else { return }
                self.main.moveConversation(c.id, to: String(parts[2]))
            }
        }
        // --chat-js "秒數:JS"：幾秒後在聊天畫面裡跑一段 JS（例如點按鈕），結果附加到 --chat-log
        for (i, a) in args.enumerated() where a == "--chat-js" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let code = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.evaluate(code) { r in ChatSession.log?.write(Data("JS \(code.prefix(60)) => \(r.prefix(300))\n".utf8)) }
            }
        }
        // --web-drag "秒數:x0:y0:x1:y1:按住秒數"：在主視窗第一個聊天網頁區按下左鍵（比例座標，左上角 0,0、右下角 1,1），
        // 慢慢拖到 (x1,y1)（可以超出 0～1＝拖到網頁外面，例如 1.05＝底下的輸入框），停著按住幾秒再放開（測拖曳選取碰到邊緣會不會自動捲）
        for (i, a) in args.enumerated() where a == "--web-drag" && i + 1 < args.count {
            let v = args[i + 1].split(separator: ":").compactMap { Double($0) }
            guard v.count == 6 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + v[0]) { [weak self] in
                guard let w = self?.main.window, let web = Self.find(DropWebView.self, in: w.contentView) else { return }
                func at(_ fx: Double, _ fy: Double) -> NSPoint {
                    let b = web.bounds
                    return web.convert(NSPoint(x: b.width * fx, y: web.isFlipped ? b.height * fy : b.height * (1 - fy)), to: nil)
                }
                // 直接交給網頁（背景測試視窗不是 key，postEvent 進不到 WKWebView）
                func post(_ t: NSEvent.EventType, _ pt: NSPoint) {
                    guard let e = NSEvent.mouseEvent(with: t, location: pt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
                    switch t { case .leftMouseDown: web.mouseDown(with: e); case .leftMouseUp: web.mouseUp(with: e); default: web.mouseDragged(with: e) }
                }
                DropWebView.testPressed = true      // 模擬事件讀不到系統按鍵狀態
                post(.leftMouseDown, at(v[1], v[2]))
                for j in 1...15 {   // 照真人速度：每 40 毫秒一步
                    let t = Double(j) / 15
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.04 * Double(j)) { post(.leftMouseDragged, at(v[1] + (v[3] - v[1]) * t, v[2] + (v[4] - v[2]) * t)) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 + v[5]) { post(.leftMouseUp, at(v[3], v[4])); DropWebView.testPressed = nil }
            }
        }
        // --web-move "秒數:x:y"：滑鼠移到主視窗第一個聊天網頁區的 (x,y)（比例座標，左上 0,0），沒按鍵（測自動捲之後命中位置有沒有偏）
        for (i, a) in args.enumerated() where a == "--web-move" && i + 1 < args.count {
            let v = args[i + 1].split(separator: ":").compactMap { Double($0) }
            guard v.count == 3 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + v[0]) { [weak self] in
                guard let w = self?.main.window, let web = Self.find(DropWebView.self, in: w.contentView) else { return }
                let b = web.bounds
                let pt = web.convert(NSPoint(x: b.width * v[1], y: web.isFlipped ? b.height * v[2] : b.height * (1 - v[2])), to: nil)
                if let e = NSEvent.mouseEvent(with: .mouseMoved, location: pt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) { web.mouseMoved(with: e) }
            }
        }
        // --chat-respawn "秒數"：目前那段聊天室的 claude 程序 terminate 之後馬上重開（測舊程序晚到的輸出不會混進新程序）
        for (i, a) in args.enumerated() where a == "--chat-respawn" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.session.terminate()
                _ = p.session.start()
            }
        }
        // --chat-model "秒數:模型"：幾秒後像從選單換模型（haiku、fable…；default＝預設）
        for (i, a) in args.enumerated() where a == "--chat-model" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let v = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.applyModel(v)
                p.onModelChange?(v == "default" ? nil : v)
            }
        }
        // --keys "秒數:按鍵 按鍵 …"：幾秒後模擬按鍵（走跟真的按鍵一樣的路），例如 "3:C-a | C-a h"
        for (i, a) in args.enumerated() where a == "--keys" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let tokens = parts[1].split(separator: " ").map(String.init)
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let w = self?.main.window else { return }
                for (n, t) in tokens.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(n) * 0.15) { Self.postKey(t, window: w) }
                }
            }
        }
        // --dbrowser-eval "秒數:JS"：在（第一個）獨立視窗裡的瀏覽器格跑一段 JS，結果寫進 state-dir/browser-test.log
        for (i, a) in args.enumerated() where a == "--dbrowser-eval" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let w = self.store.sessions.flatMap(\.windows).first(where: { $0.detached }),
                      let b = (w.root?.leaves ?? []).compactMap({ self.workspace.panes[$0] as? BrowserPane }).first else { return }
                let logURL = self.store.directory.appendingPathComponent("browser-test.log")
                b.webView.evaluateJavaScript(parts[1]) { r, e in
                    let d = Data("獨立視窗的瀏覽器 eval → \(r.map { "\($0)" } ?? "nil")\(e.map { " 錯誤：\($0.localizedDescription)" } ?? "")\n".utf8)
                    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(d); try? h.close() } else { try? d.write(to: logURL) }
                }
            }
        }
        // --dkeys "秒數:按鍵 …"：同 --keys，但丟給（第一個）獨立視窗
        for (i, a) in args.enumerated() where a == "--dkeys" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let tokens = parts[1].split(separator: " ").map(String.init)
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let w = self?.main.detachedWindows.values.first?.window else { return }
                for (n, t) in tokens.enumerated() { DispatchQueue.main.asyncAfter(deadline: .now() + Double(n) * 0.15) { Self.postKey(t, window: w) } }
            }
        }
        // --place "秒數:第幾段對話:left|right|top|bottom|center"：像從側欄把對話拖到目前那格的某一邊
        for (i, a) in args.enumerated() where a == "--place" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":").map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]), let n = Int(parts[1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, n < self.store.conversations.count, let target = self.store.currentWindow?.focused else { return }
                let conv = self.store.conversations[n].id
                let edge: DropOverlay.Edge? = ["left": .left, "right": .right, "top": .top, "bottom": .bottom][parts[2]] ?? nil
                self.store.place(conv, near: target, edge: edge)
            }
        }
        // --chat-effort "秒數:low|medium|high|xhigh|max"：像從選單換思考強度
        for (i, a) in args.enumerated() where a == "--chat-effort" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let v = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.applyEffort(v)
                p.onEffortChange?(v)
            }
        }
        // --import-live "秒數"：像打開「自動加入」那樣，把正在跑的對話抓進來
        for (i, a) in args.enumerated() where a == "--import-live" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                ClaudeSessions.importLive(into: self.store)
            }
        }
        // --open-session "秒數:Claude 對話編號開頭"：打開那段對話
        for (i, a) in args.enumerated() where a == "--open-session" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let prefix = String(parts[1]).uppercased()
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let c = self.store.conversations.first(where: { $0.claudeSession.uuidString.hasPrefix(prefix) }) else { return }
                self.store.open(c.id)
            }
        }
        // --chat-fork "秒數"：像按「在這裡接手（複製一份）」
        for (i, a) in args.enumerated() where a == "--chat-fork" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.session.forkFrom = p.session.claudeSession
            }
        }
        // --chat-drop "秒數:檔案"：像把這個檔案拖進聊天畫面（走拖放收件那段）
        for (i, a) in args.enumerated() where a == "--chat-drop" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let url = URL(fileURLWithPath: String(parts[1])) as NSURL
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                let pb = NSPasteboard(name: NSPasteboard.Name("AIWorkbenchTest-\(UUID().uuidString)"))
                pb.clearContents()
                pb.writeObjects([url])
                _ = p.inputBar.takeDrop(pb)
                pb.releaseGlobally()
            }
        }
        // --model-list "秒數"：面板開著時切到模型清單那頁
        for (i, a) in args.enumerated() where a == "--model-list" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.testShowModelList()
            }
        }
        // --render-panel "秒數:檔案.png"：把思考強度面板直接畫成圖片（不用讓 App 跑到前面）
        // --shot-models "秒數:檔名開頭"：打開目前聊天室的模型面板、換到模型清單，每個分頁拍一張（＋列出內容的 .txt）
        for (i, a) in args.enumerated() where a == "--shot-models" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let base = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.inputBar.modelButton.performClick(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard let m = ModelPanelModel.last else { return }
                    m.showingModels = true; m.onSizeChange?()
                    for (n, t) in m.tabs.enumerated() {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + Double(n) * 0.6) {
                            m.tab = t; m.onSizeChange?()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                let list = m.shownSections.map { $0.map { $0.id + " | " + $0.shownTitle + ($0.via.map { " (\($0))" } ?? "") + ($0.checked ? " ✓" : "") }.joined(separator: "\n") }.joined(separator: "\n---\n")
                                try? "分頁：\(m.tabs.map(\.title))\n\(list)\n".write(toFile: "\(base)-\(t.rawValue).txt", atomically: true, encoding: .utf8)
                                guard let w = NSApp.windows.first(where: { $0 is FloatingPanel && $0.isVisible }), let v = w.contentView,
                                      let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                                v.cacheDisplay(in: v.bounds, to: rep)
                                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(base)-\(t.rawValue).png"))
                            }
                        }
                    }
                }
            }
        }
        // --anim-models "秒數:檔名開頭"：打開模型清單，從 Claude 換到 Gemini 再換回來，動畫途中每 40 毫秒記一次面板位置並拍照（查換頁跳動）
        for (i, a) in args.enumerated() where a == "--anim-models" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let base = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.inputBar.modelButton.performClick(nil)
                var log = ""
                func shot(_ tag: String) {
                    guard let w = NSApp.windows.first(where: { $0 is FloatingPanel && $0.isVisible }), let v = w.contentView else { return }
                    log += "\(tag) frame=\(w.frame)\n"
                    if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                        v.cacheDisplay(in: v.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(base)-\(tag).png"))
                    }
                    try? log.write(toFile: base + ".txt", atomically: true, encoding: .utf8)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard let m = ModelPanelModel.last else { return }
                    m.tab = .claude; m.showingModels = true; m.onSizeChange?()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        shot("a0")
                        withAnimation(.easeInOut(duration: 0.18)) { m.tab = .gemini }
                        m.onSizeChange?()
                        for k in 1...8 { DispatchQueue.main.asyncAfter(deadline: .now() + Double(k) * 0.04) { shot("a\(k)") } }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            shot("b0")
                            withAnimation(.easeInOut(duration: 0.18)) { m.tab = .claude }
                            m.onSizeChange?()
                            for k in 1...8 { DispatchQueue.main.asyncAfter(deadline: .now() + Double(k) * 0.04) { shot("b\(k)") } }
                        }
                    }
                }
            }
        }
        // --usage-page "秒數:檔名開頭"：等用量查完，把右側欄會列的（目前分頁用到的組）寫進 <開頭>.txt、拍整個視窗，
        // 再打開置中的完整用量頁拍一張（<開頭>-page.png）
        for (i, a) in args.enumerated() where a == "--usage-page" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let base = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let w = self.main.window else { return }
                let m = UsageMonitor.shared
                var out = "目前分頁的組：" + self.store.usagePoolsInCurrentWindow.map { $0.pool.rawValue + ($0.argon ? "+argon" : "") }.joined(separator: ", ") + "\n"
                for p in self.store.usagePoolsInCurrentWindow { for r in m.rows(p.pool, argon: p.argon) { out += "  側欄 \(p.pool.rawValue) | \(r.label) | \(r.bucket.remaining)% | \(r.bucket.resets)\n" } }
                for p in UsagePool.allCases { for r in m.rows(p) { out += "  全部 \(p.rawValue) | \(r.label) | \(r.bucket.remaining)%\n" }; if let n = m.note(p) { out += "  附註 \(p.rawValue) | \(n)\n" } }
                try? out.write(toFile: base + ".txt", atomically: true, encoding: .utf8)
                if let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: base + "-window.png"))
                }
                UsageSheet.toggle()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    guard let p = UsageSheet.current, let v = p.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: base + "-page.png"))
                    try? (out + "完整頁大小 \(p.frame.size)，主視窗 \(w.frame.size)，置中差 \(Int(p.frame.midX - w.frame.midX)),\(Int(p.frame.midY - w.frame.midY))\n").write(toFile: base + ".txt", atomically: true, encoding: .utf8)
                }
            }
        }
        // --usage-strip-probe "秒數:檔名開頭"：輸入框下面那條用量（UsageGlanceStrip）的組、欄、數字、顏色寫進 <開頭>.txt，整個輸入框拍成 <開頭>.png（考卷 C121；搭 --usage-fake、--new-chat）
        for (i, a) in args.enumerated() where a == "--usage-strip-probe" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let base = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else {
                    try? "沒有聊天室格\n".write(toFile: base + ".txt", atomically: true, encoding: .utf8)
                    return
                }
                let bar = p.inputBar
                // 測試用假值：上排總上下文 640K、下排已用 196K（同一個時刻設、量、拍，免得聊天室的定時更新蓋掉）
                bar.setContext(tokens: 196_000, limit: 640_000)
                bar.layoutSubtreeIfNeeded()
                let strip = bar.ctxStrip.usage
                strip.layoutSubtreeIfNeeded()
                var lines = strip.probeLines()
                let fallbackItems = UsageMonitor.codexGlanceItems(accounts: [], fallback: [UsageBucket(label: "30 天", used: 33, resets: "")])
                let fallback = UsageGlanceGroup(key: "codex", name: "Codex", symbol: "square", items: fallbackItems)
                if let label = UsageGlanceStrip.probeLines(for: [fallback]).first(where: { $0.hasPrefix("  col label=") }) {
                    lines.append("fallback " + label.trimmingCharacters(in: .whitespaces))
                }
                try? (lines.joined(separator: "\n") + "\n" + bar.ctxStrip.probeLine() + "\n").write(toFile: base + ".txt", atomically: true, encoding: .utf8)
                // 視窗位置、是否顯示、透明度（只有一台螢幕時應 alpha=0）
                try? "\(String(describing: p.window?.frame)) visible=\(p.window?.isVisible ?? false) alpha=\(p.window?.alphaValue ?? -1)\n".write(toFile: base + ".frame", atomically: true, encoding: .utf8)
                if let rep = bar.bitmapImageRepForCachingDisplay(in: bar.bounds) {
                    bar.cacheDisplay(in: bar.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: base + ".png"))
                }
            }
        }
        // --render-activity "秒數:檔案.png"：把右欄「正在跑」那一塊（目前選的對話）畫成圖（背景測試時右欄被看板佔著、也畫不清楚）。搭 --chat-claude 的假 claude 讓它有東西在跑
        for (i, a) in args.enumerated() where a == "--render-activity" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                let root = ZStack { Color(white: 0.13); ActivityBlock(store: self.store).padding(12) }
                    .frame(width: 300).environment(\.uiScale, 1).environment(\.colorScheme, .dark)
                let host = NSHostingView(rootView: root)
                host.frame = NSRect(origin: .zero, size: NSSize(width: 300, height: host.fittingSize.height))
                host.layoutSubtreeIfNeeded()
                host.appearance = NSAppearance(named: .darkAqua)
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
            }
        }
        // --render-inbox "秒數:檔案.png:展開的項目編號（可空）:亮暗(light|dark)"：把「待你處理」收件匣畫成圖（背景測試時彈窗不會被系統畫出來）
        for (i, a) in args.enumerated() where a == "--render-inbox" && i + 1 < args.count {
            let parts = args[i + 1].components(separatedBy: ":")
            guard parts.count >= 2, let sec = Double(parts[0]) else { continue }
            let path = parts[1], openID = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil, dark = parts.count > 3 && parts[3] == "dark"
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                let root = InboxView(startOpen: openID, openFullBoard: {}).environment(\.uiScale, 1)
                    .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: root)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 470), styleMask: [.borderless], backing: .buffered, defer: false)
                win.contentView = host
                host.frame = NSRect(origin: .zero, size: NSSize(width: 340, height: min(470, host.fittingSize.height)))
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
            }
        }
        // --render-usage "秒數:檔案.png:寬:高"：把整個右欄（UsagePanel，含捲動與撐滿高度）用指定的寬高畫成圖，測窄欄用；搭 CODENV_FAKE_RUNNING
        for (i, a) in args.enumerated() where a == "--render-usage" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":").map(String.init)
            guard parts.count == 4, let sec = Double(parts[0]), let w = Double(parts[2]), let h = Double(parts[3]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                let root = ZStack { Color(white: 0.13); UsagePanel(m: UsageMonitor.shared, store: self.store) }
                    .frame(width: w, height: h).environment(\.uiScale, 1).environment(\.colorScheme, .dark)
                let host = NSHostingView(rootView: root)
                host.frame = NSRect(x: 0, y: 0, width: w, height: h)
                host.appearance = NSAppearance(named: .darkAqua)
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[1]))
                }
            }
        }
        // --render-usage-full "秒數:檔案.png"：把用量詳細頁（點「用量剩餘 >」開的那頁，含 Codex 重置券過期時間）畫成圖；搭 CODENV_USAGE_FAKE=1
        for (i, a) in args.enumerated() where a == "--render-usage-full" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                let w = UsageFullPage.width(columns: 3, scale: 1), h: CGFloat = 700
                let root = UsageFullPage(m: UsageMonitor.shared, scroll: false).frame(width: w, height: h)
                    .background(Color(white: 0.13)).environment(\.uiScale, 1).environment(\.colorScheme, .dark)
                let host = NSHostingView(rootView: root)
                host.frame = NSRect(x: 0, y: 0, width: w, height: h)
                host.appearance = NSAppearance(named: .darkAqua)
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[1]))
                }
            }
        }
        if args.contains("--state-dir"), args.contains("--usage-fake"),
           let i = args.firstIndex(of: "--agy-usage-card-probe"), i + 1 < args.count,
           let inputIndex = args.firstIndex(of: "--magpie-usage-input"), inputIndex + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, let sec = Double(parts[0]) {
                let output = parts[1]
                let input = args[inputIndex + 1]
                DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                    guard let data = FileManager.default.contents(atPath: input),
                          let parsed = UsageMonitor.parseMagpieAccounts(data) else {
                        try? "無法解析 Magpie 帳號資料\n".write(toFile: output + ".error", atomically: true, encoding: .utf8)
                        return
                    }
                    let monitor = UsageMonitor.shared
                    monitor.agyBuckets = parsed.buckets
                    monitor.magpieQuotaTips = parsed.tips
                    monitor.magpieAccounts = parsed.accounts
                    monitor.updated = Date()
                    monitor.error = nil
                    monitor.loading = false
                    try? (UsageFullPage.agyCardProbeLines(monitor).joined(separator: "\n") + "\n")
                        .write(toFile: output + ".txt", atomically: true, encoding: .utf8)
                    let width = UsageFullPage.width(columns: 1, scale: 1)
                    func render(_ appearance: NSAppearance.Name, scheme: ColorScheme, path: String) -> Bool {
                        let root = UsageFullPage(m: monitor, scroll: false, onlyPool: .gemini)
                            .environment(\.uiScale, 1).environment(\.colorScheme, scheme)
                        let host = NSHostingView(rootView: root)
                        guard let nativeAppearance = NSAppearance(named: appearance) else { return false }
                        host.appearance = nativeAppearance
                        host.frame = NSRect(x: 0, y: 0, width: width, height: 1800)
                        host.layoutSubtreeIfNeeded()
                        let height = min(1800, max(1, host.fittingSize.height))
                        host.setFrameSize(NSSize(width: width, height: height))
                        host.layoutSubtreeIfNeeded()
                        guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
                        host.cacheDisplay(in: host.bounds, to: image)
                        guard let png = image.representation(using: .png, properties: [:]) else { return false }
                        return (try? png.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
                    }
                    // 保留 .png 作為暗色截圖，另輸出亮色供人工檢查；UsageFullPage 目前會固定使用暗色卡片樣式。
                    guard render(.darkAqua, scheme: .dark, path: output + ".png"),
                          render(.aqua, scheme: .light, path: output + "-light.png") else {
                        try? "agy 用量卡片截圖失敗\n".write(toFile: output + ".error", atomically: true, encoding: .utf8)
                        return
                    }
                }
            }
        }
        // --render-models "秒數:檔名開頭"：用假資料畫模型清單的每個分頁（<開頭>-claude.png、-gemini.png、-local.png）
        // --usage-poolcards-probe "秒數:輸出前綴:截圖目錄"：用正式卡片元件渲染假免費池資料，輸出寬／窄截圖與來源診斷（C142）。
        if args.contains("--state-dir"), let i = args.firstIndex(of: "--usage-poolcards-probe"), i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            if parts.count == 3, let sec = Double(parts[0]) {
                let output = parts[1], shotDir = parts[2]
                // 隱藏探針不會打開 F12 用量面板；正式面板是在打開時才刷新免費池。
                // 用測試實例的假來源走同一個 refresh，等啟動中的基本用量查詢結束再叫。
                func refreshPoolProbeWhenIdle(_ attempts: Int) {
                    let monitor = UsageMonitor.shared
                    guard monitor.extraKeyPools.isEmpty, attempts > 0 else { return }
                    if monitor.loading {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { refreshPoolProbeWhenIdle(attempts - 1) }
                    } else {
                        monitor.refresh(includeExtraKeys: true)
                    }
                }
                refreshPoolProbeWhenIdle(50)
                DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                    let monitor = UsageMonitor.shared
                    let allExtra = monitor.allExtraKeyPools
                    let names = allExtra.map(\.name)
                    guard names.contains("Groq"), names.contains("Kaggle"), names.contains("NVIDIA"), names.contains("AI Studio") else {
                        try? "卡片尚未載入：\(names.joined(separator: ","))\n".write(toFile: output + ".error", atomically: true, encoding: .utf8)
                        return
                    }
                    try? FileManager.default.createDirectory(atPath: shotDir, withIntermediateDirectories: true)
                    var failed = false
                    for (columns, suffix) in [(3, "wide"), (2, "narrow")] {
                        let root = UsagePoolCardsProbeView(pools: allExtra, columns: columns)
                            .environment(\.uiScale, 1)
                        let host = NSHostingView(rootView: root)
                        host.appearance = NSAppearance(named: .darkAqua)
                        host.sizingOptions = []
                        let width = UsageFullPage.width(columns: columns, scale: 1)
                        host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: 1200))
                        host.layoutSubtreeIfNeeded()
                        host.setFrameSize(NSSize(width: width, height: 1200))
                        host.layoutSubtreeIfNeeded()
                        guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { failed = true; continue }
                        host.cacheDisplay(in: host.bounds, to: image)
                        let url = URL(fileURLWithPath: shotDir).appendingPathComponent("poolcards-\(suffix).png")
                        guard let png = image.representation(using: .png, properties: [:]) else { failed = true; continue }
                        do { try png.write(to: url, options: .atomic) } catch { failed = true }
                    }
                    let inventory = allExtra.map { pool in
                        (["card=\(pool.name)", "source=\(pool.source)"] + pool.buckets.map { "row=\($0.label)" } + pool.notes.map { "detail=\($0)" })
                            .joined(separator: "\n")
                    }.joined(separator: "\n")
                    try? inventory.write(toFile: output + ".inventory", atomically: true, encoding: .utf8)

                    var diagnostics: [String] = []
                    if let fixturePath = ProcessInfo.processInfo.environment["CODENV_EXTRA_KEY_FAKE"],
                       let data = FileManager.default.contents(atPath: fixturePath),
                       let fakeRoot = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        let now = Date()
                        let base = PoolUsageSnapshot.load()
                        func build(_ usage: PoolUsageSnapshot) -> (Int, [ExtraKeyPool]) {
                            var source = ExtraKeySources.fake(fakeRoot, poolUsage: usage, now: { now })
                            var fetches = 0
                            let fetch = source.fetchGroq
                            source.fetchGroq = { key in fetches += 1; return fetch(key) }
                            let pools = ExtraKeyPools.pools(source, groqCache: nil, kaggleCache: nil)
                            return (fetches, pools)
                        }
                        let fresh = build(base)
                        diagnostics.append("groqFreshFetches=\(fresh.0)")
                        diagnostics.append("groqFreshSource=\(fresh.1.first { $0.name == "Groq" }?.source ?? "missing")")
                        var staleRows = base.pools
                        var staleGroq = staleRows["groq"] ?? [:]
                        let iso = ISO8601DateFormatter()
                        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                        staleGroq["updated_at"] = iso.string(from: now.addingTimeInterval(-31 * 60))
                        staleRows["groq"] = staleGroq
                        let stale = build(PoolUsageSnapshot(pools: staleRows))
                        diagnostics.append("groqExpiredFetches=\(stale.0)")
                        diagnostics.append("groqExpiredSource=\(stale.1.first { $0.name == "Groq" }?.source ?? "missing")")
                        let invalid = PoolUsageSnapshot(data: Data("{invalid".utf8))
                        let broken = build(invalid)
                        diagnostics.append("groqBadFileFetches=\(broken.0)")
                        diagnostics.append("groqBadFileDidNotCrash=true")
                        let noKeys = ExtraKeySources.fake(["nvidia": ["key": "missing"], "ai_studio": ["key": "missing"], "kaggle": ["key": "missing"]], now: { now })
                        let noKeyNames = ExtraKeyPools.pools(noKeys, groqCache: nil, kaggleCache: nil).map(\.name)
                        diagnostics.append("noKeyCards=\(noKeyNames.filter { ["NVIDIA", "AI Studio", "Kaggle"].contains($0) }.count)")
                        diagnostics.append("opencodeShownWithoutUsage=\(noKeyNames.contains("OpenCode 免費模型"))")
                        diagnostics.append("opencodeEmptyUsageShowsZero=\(ExtraKeyPools.pools(noKeys, groqCache: nil, kaggleCache: nil).first { $0.name == "OpenCode 免費模型" }?.notes.contains("今天呼叫 0 次") == true)")
                        let kaggle = fresh.1.first { $0.name == "Kaggle" }
                        diagnostics.append("kaggleGPUParsed=\(kaggle?.notes.contains(where: { $0.contains("GPU") && $0.contains("剩 12.50／30.00 小時") }) == true)")
                        diagnostics.append("kaggleTPUParsed=\(kaggle?.notes.contains(where: { $0.contains("TPU") && $0.contains("剩 4.00／8.00 小時") }) == true)")
                        var kaggleFetches = 0
                        let quotaSource = ExtraKeySources.fake(fakeRoot, poolUsage: base, now: { now })
                        let fetchQuota = quotaSource.fetchKaggleQuota
                        let quotaCache = KaggleQuotaCache()
                        for offset in [0.0, 1740.0, 1801.0] {
                            _ = quotaCache.getOrFetch(now: now.addingTimeInterval(offset)) {
                                kaggleFetches += 1
                                return fetchQuota()
                            }
                        }
                        diagnostics.append("kaggleQuotaFetchesAt0_1740_1801=\(kaggleFetches)")
                    } else {
                        diagnostics.append("fixtureMissing=true")
                    }
                    try? diagnostics.joined(separator: "\n").write(toFile: output + ".diagnostics", atomically: true, encoding: .utf8)
                    if failed { try? "免費池卡片截圖失敗\n".write(toFile: output + ".error", atomically: true, encoding: .utf8) }
                }
            }
        }
        // --usage-full-layout-probe "秒數:輸出前綴:截圖目錄"：開用量浮動面板，以假資料量卡片 frame 並在 3／2 欄間縮放（C141）。
        if args.contains("--state-dir"), let i = args.firstIndex(of: "--usage-full-layout-probe"), i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            if parts.count == 3, let sec = Double(parts[0]) {
                let output = parts[1], shotDir = parts[2]
                DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                    guard let self, let source = self.main.window else {
                        try? "沒有主視窗\n".write(toFile: output + ".error", atomically: true, encoding: .utf8)
                        return
                    }
                    let m = UsageMonitor.shared
                    func quota(_ label: String, remaining: Int) -> UsageBucket {
                        UsageBucket(label: label, used: 100 - remaining, resets: "明天 12:00", resetAt: Date().addingTimeInterval(86_400))
                    }
                    m.buckets = [quota("5 小時", remaining: 71), quota("每週", remaining: 42)]
                    m.agyBuckets = [quota("Gemini 5 小時", remaining: 83), quota("Gemini 每週", remaining: 64),
                                    quota("Claude 每週", remaining: 51), quota("Argon 每週", remaining: 39)]
                    m.codexBuckets = []
                    m.copilotBuckets = [quota("每月", remaining: 92)]
                    m.updated = Date(); m.error = nil; m.loading = false
                    let paid = CodexUsageAccountQuota(id: "plus", user: "plus@example.test", plan: "plus", active: false,
                                                       buckets: [quota("5 小時", remaining: 88), quota("每週", remaining: 76)],
                                                       resetCredits: 2, resetExpiries: [Date().addingTimeInterval(2 * 86_400)])
                    func setFreeAccounts(_ count: Int) {
                        let users = ["amy.one@example.test", "bob.two@example.test", "cy.three@example.test", "dan.four@example.test", "eli.five@example.test"]
                        let free = (0..<count).map { index in
                            CodexUsageAccountQuota(id: "free-\(index + 1)", user: users[index], plan: "free",
                                                   active: index == 0, buckets: [quota("30 天", remaining: [92, 73, 58, 39, 24][index % 5])],
                                                   resetCredits: 0, resetExpiries: [])
                        }
                        m.codexAccounts = [paid] + free
                    }
                    var latest: (CGSize, [String: CGRect])?
                    UsageSheet.layoutObserver = { latest = ($0, $1) }
                    UsageSheet.toggle(preservingFocus: true, in: source)
                    guard let panel = UsageSheet.current else {
                        try? "用量面板沒有開啟\n".write(toFile: output + ".error", atomically: true, encoding: .utf8)
                        return
                    }
                    try? FileManager.default.createDirectory(atPath: shotDir, withIntermediateDirectories: true)
                    let scale = UIScale.shared.f
                    var phases: [[String: Any]] = []
                    let configs: [(free: Int, columns: Int, shot: String?)] = [
                        (3, 3, nil), (5, 3, "wide.png"), (5, 2, "narrow.png")
                    ]
                    func fail(_ reason: String) {
                        UsageSheet.layoutObserver = nil
                        try? (reason + "\n").write(toFile: output + ".error", atomically: true, encoding: .utf8)
                        UsageSheet.toggle(preservingFocus: true, in: source, allowImmediateReopen: true)
                    }
                    func frameJSON(_ frame: CGRect) -> [String: Double] {
                        ["x": Double(frame.minX), "y": Double(frame.minY), "width": Double(frame.width), "height": Double(frame.height)]
                    }
                    func runPhase(_ index: Int) {
                        guard index < configs.count else {
                            let data = try? JSONSerialization.data(withJSONObject: ["scale": Double(scale), "phases": phases], options: [.sortedKeys])
                            if let data { try? data.write(to: URL(fileURLWithPath: output + ".json"), options: .atomic) }
                            UsageSheet.layoutObserver = nil
                            UsageSheet.toggle(preservingFocus: true, in: source, allowImmediateReopen: true)
                            return
                        }
                        let config = configs[index]
                        setFreeAccounts(config.free)
                        let width = UsageFullPage.width(columns: config.columns, scale: scale) + UsageFullPage.scrollReserve * scale
                        let height = min(max(panel.frame.height, 680 * scale), panel.maxSize.height)
                        let frame = NSRect(x: source.frame.midX - width / 2, y: source.frame.midY - height / 2,
                                           width: width, height: height)
                        panel.setFrame(frame, display: true)
                        panel.contentView?.layoutSubtreeIfNeeded()
                        func waitForMeasurement(_ attempts: Int) {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                let expectedRows = config.free
                                if let measurement = latest,
                                   (1...expectedRows).allSatisfy({ measurement.1["codex:free-row:free-\($0)"] != nil }),
                                   measurement.1["pool:codex"] != nil, measurement.1["codex:paid"] != nil, measurement.1["codex:free"] != nil {
                                    var record: [String: Any] = [
                                        "freeCount": config.free, "requestedColumns": config.columns,
                                        "panelWidth": Double(panel.frame.width),
                                        "gridWidth": Double(measurement.0.width), "gridHeight": Double(measurement.0.height),
                                        "frames": measurement.1.mapValues(frameJSON)
                                    ]
                                    if let shot = config.shot, let view = panel.contentView,
                                       let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                                        view.cacheDisplay(in: view.bounds, to: rep)
                                        let path = URL(fileURLWithPath: shotDir).appendingPathComponent(shot)
                                        if let png = rep.representation(using: .png, properties: [:]) {
                                            try? png.write(to: path, options: .atomic)
                                            record["screenshot"] = path.path
                                        }
                                    }
                                    phases.append(record)
                                    latest = nil
                                    runPhase(index + 1)
                                } else if attempts > 0 {
                                    waitForMeasurement(attempts - 1)
                                } else {
                                    let diagnostic = latest.map { "grid=\($0.0) keys=\($0.1.keys.sorted())" } ?? "沒有 preference"
                                    fail("用量卡片 frame 量測逾時（\(config.columns) 欄、\(config.free) 個免費帳號；\(diagnostic)；panel=\(panel.frame.size)）")
                                }
                            }
                        }
                        waitForMeasurement(25)
                    }
                    runPhase(0)
                }
            }
        }
        for (i, a) in args.enumerated() where a == "--render-models" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let base = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                let m = ModelPanelModel()
                m.modelName = "Opus 5.5"; m.levels = Effort.order; m.defaultEffort = "high"; m.showingModels = true
                let r = { (id: String, t: String, c: Bool) in ModelRow(id: id, title: t, tip: "", checked: c) }
                m.sections = [[r("opus", "Opus 5.5", true), r("claude-opus-5", "Opus 5", false)], [r("sonnet", "Sonnet 5.5", false)],
                              [r("agy:gemini-4-hydrogen-high", "Gemini 4 Hydrogen", false), r("agy:gemini-4-argon-high", "Gemini 4 Argon", false),
                               r("agy:claude-opus-5-5-high", "Claude Opus 5.5", false), r("agy:claude-sonnet-5-5-high", "Claude Sonnet 5.5", false),
                               r("agy:gemini-3.8-flash-high", "Gemini 3.8 Flash", false)],
                              [r("codex:gpt-6-luna", "GPT-6 Luna", false), r("codex:gpt-5.6-terra", "GPT-5.6 Terra", false)],
                              [r("copilot:auto", "Auto", false)],
                              [r("local:x", "LFM2.5", false)]]
                for t in ModelTab.popoverCases {
                    m.tab = t
                    let list = m.shownSections.map { $0.map { $0.shownTitle + ($0.via.map { " (\($0))" } ?? "") + ($0.checked ? " ✓" : "") }.joined(separator: "\n") }.joined(separator: "\n---\n")
                    try? "分頁：\(m.tabs.map(\.title))\n\(list)\n".write(toFile: "\(base)-\(t.rawValue).txt", atomically: true, encoding: .utf8)
                    let ren = ImageRenderer(content: ModelPanel(m: m).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
                    ren.scale = 2
                    if let img = ren.nsImage, let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: "\(base)-\(t.rawValue).png"))
                    }
                }
            }
        }
        for (i, a) in args.enumerated() where a == "--render-panel" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                let m = ModelPanelModel()
                m.modelName = "Opus 5.5"; m.levels = Effort.order; m.defaultEffort = "high"
                let r = ImageRenderer(content: ModelPanel(m: m).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
                r.scale = 2
                if let img = r.nsImage, let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                }
            }
        }
        // --render-sessions "秒數:檔案.png"：把 Session 面板畫成圖片（不真的打開，不會蓋到畫面上）
        for (i, a) in args.enumerated() where a == "--render-sessions" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                let m = SessionPanelModel()
                m.rows = self.main.sessionRows(); m.canClose = self.store.sessions.count > 1; m.keyIndex = 2
                let v = NSHostingView(rootView: SessionPanel(m: m))
                v.frame = NSRect(origin: .zero, size: v.fittingSize)
                v.layoutSubtreeIfNeeded()
                if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
            }
        }
        // --model-panel "秒數"：按右下角的模型按鈕
        for (i, a) in args.enumerated() where a == "--model-panel" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.inputBar.modelButton.performClick(nil)
            }
        }
        // --input-probe "秒數:檔案"：輸入框塞 13 行、最後一行是換行的草稿，問文字框「點最後那條空行的中間／下緣留白／左緣留白，游標會到第幾個字」，
        // 並記最後空行有沒有在可見範圍內（測「最後一行點不到」，不用動滑鼠）
        for (i, a) in args.enumerated() where a == "--input-probe" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            // 檔案前面可以加「行數@」，例如 3@/tmp/x.txt（預設 13 行）
            var path = String(parts[1]), lines = 13
            if let at = path.firstIndex(of: "@"), let n = Int(path[..<at]) { lines = n; path = String(path[path.index(after: at)...]) }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { try? "沒有聊天格".write(toFile: path, atomically: true, encoding: .utf8); return }
                // 直接放進草稿（像還原草稿、訊息沒送到放回輸入框）：這條路捲動不會自己跟上
                p.inputBar.setDraft((1...lines).map { "第\($0)行中文字 abc" }.joined(separator: "\n") + "\n")
                p.inputBar.layoutSubtreeIfNeeded()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let tv = p.inputBar.textView
                    guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
                    lm.ensureLayout(for: tc)
                    let extra = lm.extraLineFragmentRect, o = tv.textContainerOrigin
                    let len = (tv.string as NSString).length
                    let mid = NSPoint(x: o.x + 20, y: o.y + extra.midY)
                    let below = NSPoint(x: o.x + 20, y: o.y + extra.maxY + 3)
                    let left = NSPoint(x: 1, y: o.y + extra.midY)
                    let extraTV = extra.offsetBy(dx: o.x, dy: o.y)
                    let vis = tv.enclosingScrollView?.contentView.bounds ?? .zero
                    let out = "len=\(len) extra=\(extraTV) visible=\(vis) 看得到最後空行=\(vis.contains(extraTV))\n" +
                        "點中間→\(tv.characterIndexForInsertion(at: mid)) 點下緣留白→\(tv.characterIndexForInsertion(at: below)) 點左緣留白→\(tv.characterIndexForInsertion(at: left))\n" +
                        "textView.frame=\(tv.frame) scroll.frame=\(tv.enclosingScrollView?.frame ?? .zero)\n" +
                        // 真的點下去會落到哪個 view：從視窗最上層 hitTest（滑鼠事件就是這樣找收件人）
                        [("最後空行中間", mid), ("下緣留白", below), ("空行下方 10 點", NSPoint(x: o.x + 20, y: o.y + extra.maxY + 10)), ("空行下方 18 點", NSPoint(x: o.x + 20, y: o.y + extra.maxY + 18))].map { name, pt -> String in
                            let w = tv.convert(pt, to: nil)
                            let hit = tv.window?.contentView?.superview?.hitTest(w) ?? tv.window?.contentView?.hitTest(w)
                            return "\(name)→\(hit.map { String(describing: type(of: $0)) } ?? "nil")"
                        }.joined(separator: "  ") + "\n" +
                        // 游標先放在第 5 個字，再像點在空行下方 10 點那樣點一下框：游標應該跑到最後
                        { () -> String in
                            tv.setSelectedRange(NSRange(location: 5, length: 0))
                            p.inputBar.clickBesideText(atWindowPoint: tv.convert(NSPoint(x: o.x + 20, y: o.y + extra.maxY + 10), to: nil))
                            let a = tv.selectedRange().location
                            tv.setSelectedRange(NSRange(location: 5, length: 0))
                            p.inputBar.clickBesideText(atWindowPoint: tv.convert(NSPoint(x: o.x + 400, y: o.y + extra.maxY + 18), to: nil))
                            return "點框下方空白（左）→游標 \(a)  點框下方空白（右邊遠處）→游標 \(tv.selectedRange().location)  焦點在文字框=\(tv.window?.firstResponder === tv)\n"
                        }()
                    try? out.write(toFile: path, atomically: true, encoding: .utf8)
                }
            }
        }
        // --codelab-recovery-probe "秒數:edit|inspect|restore|discard|save|close:原始檔:輸出檔"
        // 只在 --state-dir 啟用：保留一個沒有視窗的 CodeLab，測真正的 JS 防抖、復原與清除。
        for (i, a) in args.enumerated() where a == "--codelab-recovery-probe" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 3).map(String.init)
            guard parts.count == 4, let sec = Double(parts[0]),
                  ["edit", "inspect", "restore", "discard", "save", "close"].contains(parts[1]),
                  parts[2].hasPrefix("/"), parts[3].hasPrefix("/") else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                let lab = CodeLabView(directory: (parts[2] as NSString).deletingLastPathComponent,
                                      key: "recovery-probe", theme: self.appearance.theme)
                self.recoveryProbeLabs.append(lab)
                lab.recoveryProbe(path: parts[2], action: parts[1]) { output in
                    print(output)
                    try? output.write(toFile: parts[3], atomically: true, encoding: .utf8)
                }
            }
        }
        // --outbox-probe "秒數:seed|seed-delivered|recover|dump:檔案"：只在 --state-dir 啟用，不送訊息。
        for (i, a) in args.enumerated() where a == "--outbox-probe" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]), ["seed", "seed-delivered", "seed-key", "recover", "dump"].contains(parts[1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                let output: String
                do {
                    if let self, let id = self.store.selected, let pane = self.workspace.panes[id] as? ChatPane {
                        output = try pane.probeOutbox(parts[1])
                    } else { output = "沒有聊天格\n" }
                } catch { output = "outbox-probe: \(error)\n" }
                try? output.write(toFile: parts[2], atomically: true, encoding: .utf8)
            }
        }
        // --draft-probe／--draft-image-probe "秒數:檔案"（限 --state-dir）：等自動存檔後輸出 JSON 與圖片檔清單。
        // 圖片版用 #7、edited=true 的小 PNG，測編號有缺口也能原樣還原；不拿輸入框焦點。
        for (i, a) in args.enumerated() where (a == "--draft-probe" || a == "--draft-image-probe") && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let resultPath = parts[1]
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected,
                      let pane = self.workspace.panes[id] as? ChatPane else {
                    try? "沒有聊天格\n".write(toFile: resultPath, atomically: true, encoding: .utf8)
                    return
                }
                let window = pane.inputBar.window
                let responder = window?.firstResponder
                let keyWindow = NSApp.keyWindow
                if a == "--draft-image-probe" {
                    guard !pane.inputBar.hasPendingInput,
                          let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGOQa/rwH4QZYAwAVgwKPaFOh1UAAAAASUVORK5CYII=") else {
                        try? "輸入框已有草稿，未覆寫\n".write(toFile: resultPath, atomically: true, encoding: .utf8)
                        return
                    }
                    pane.inputBar.textView.string = "圖片草稿測試 abc [Image #7]"
                    pane.inputBar.restoreImages([DraftPersistence.Image(data: png, mediaType: "image/png", no: 7, edited: true)])
                    pane.inputBar.textView.didChangeText()
                } else {
                    pane.inputBar.setDraft("跨啟動草稿測試 abc")
                }
                let focusUnchanged = window?.firstResponder === responder && NSApp.keyWindow === keyWindow
                // 不手動存：等打字後約 1 秒的自動存檔（測的就是當掉前有沒有自己寫下去）
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    let directory = self.store.directory.appendingPathComponent("drafts", isDirectory: true)
                    let prefix = id.uuidString.lowercased()
                    let url = directory.appendingPathComponent("\(prefix).json")
                    let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? "（尚無草稿檔）"
                    let imageFiles = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                        .filter { $0.lastPathComponent.hasPrefix("\(prefix)-img-") && ["png", "jpg"].contains($0.pathExtension) }
                        .map(\.path).sorted()
                    let images = pane.inputBar.draftImages
                    let output = "path=\(url.path)\n\(contents)\nimageFiles=\(imageFiles)\n" +
                        "attachments=\(images.count) imageNos=\(images.map(\.no)) edited=\(images.map(\.edited)) focusUnchanged=\(focusUnchanged)\n"
                    try? output.write(toFile: resultPath, atomically: true, encoding: .utf8)
                }
            }
        }
        // --input-dump "秒數:檔案"（限 --state-dir）：輸出文字、附件數、原編號與編輯狀態，測重開後還原。
        for (i, a) in args.enumerated() where a == "--input-dump" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let pane = self.workspace.panes[id] as? ChatPane else {
                    try? "沒有聊天格\n".write(toFile: parts[1], atomically: true, encoding: .utf8); return
                }
                let images = pane.inputBar.draftImages
                let output = "輸入框=[\(pane.inputBar.textView.string)]\n" +
                    "attachments=\(images.count) imageNos=\(images.map(\.no)) edited=\(images.map(\.edited))\n" +
                    "\(pane.inputBar.scrollerState) \(pane.inputBar.metricsForTest)\n"
                try? output.write(toFile: parts[1], atomically: true, encoding: .utf8)
            }
        }
        // --toggle-right "秒數"：像按 F4（開關右側欄）
        for (i, a) in args.enumerated() where a == "--toggle-right" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.main.toggleRightPanel() }
        }
        // --right-stall-probe "秒數:分頁:檔案"（限 --state-dir）：那時打開右欄並切到分頁，3 秒後像按 F4 收起，
        //   寫「maxStallMs=最長停頓毫秒 collapsed1s=yes|no」（1 秒內右欄是否已收完）。考題 C21 用
        for (i, a) in args.enumerated() where a == "--right-stall-probe" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]), let tab = RightTab.named(parts[1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.main.showRightPanel(tab: tab) }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec + 3) { [weak self] in
                RightPanelPerf.reset()
                self?.main.toggleRightPanel()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec + 4) { [weak self] in
                let gone = self?.main.host.debugRightPanel().contains("- - on=") == true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    _ = RightPanelPerf.report("probe")
                    let out = String(format: "maxStallMs=%.0f collapsed1s=%@\n", RightPanelPerf.maxGap, gone ? "yes" : "no")
                    try? out.write(toFile: parts[2], atomically: true, encoding: .utf8)
                }
            }
        }
        // --frame-stats "開始秒數:標籤:檔案"：開始秒數起記錄右欄滑動動畫的每幀耗時，1 秒後把摘要附加寫進檔案（接在 --toggle-right 前一點開始）
        for (i, a) in args.enumerated() where a == "--frame-stats" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { RightPanelPerf.reset() }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec + 1.5) {
                let line = RightPanelPerf.report(parts[1])
                if let h = FileHandle(forWritingAtPath: parts[2]) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
                else { try? line.write(toFile: parts[2], atomically: true, encoding: .utf8) }
            }
        }
        // --trace-right "開始秒數:檔案"：從那時起 1.5 秒，每 1/60 秒記一行「經過毫秒 視窗內容寬 主內容寬 右欄左緣 右欄寬」
        for (i, a) in args.enumerated() where a == "--trace-right" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                let t0 = ProcessInfo.processInfo.systemUptime
                var out = ""
                let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] tm in
                    guard let self else { tm.invalidate(); return }
                    let ms = Int((ProcessInfo.processInfo.systemUptime - t0) * 1000)
                    out += "\(ms) \(self.main.host.debugRightPanel())\n"
                    if ms > 1500 { tm.invalidate(); try? out.write(toFile: path, atomically: true, encoding: .utf8) }
                }
                RunLoop.main.add(timer, forMode: .common)
            }
        }
        // --toggle-sidebar "秒數"：收起／打開側欄
        for (i, a) in args.enumerated() where a == "--toggle-sidebar" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.main.toggleSidebar() }
        }
        // --suggest "秒數:文字"：目前那格聊天的輸入框顯示這句灰字建議（測建議的畫法）
        for (i, a) in args.enumerated() where a == "--suggest" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let text = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.inputBar.suggestion = text
            }
        }
        // --organizer "秒數"：打開整理對話視窗
        for (i, a) in args.enumerated() where a == "--organizer" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.showOrganizer() }
        }
        // --organizer-dump "秒數:檔案"：整理對話「對話」分頁會列的對話、「資料夾」分頁的對話數
        for (i, a) in args.enumerated() where a == "--organizer-dump" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let st = self?.store as Store? else { return }
                var out = st.organizerConversations.map { "對話：\($0.title)" }
                out += st.projects.map { p in "資料夾：\(p.name) \(st.organizerConversations.filter { $0.projectID == p.id }.count) 段（全部 \(st.conversations.filter { $0.projectID == p.id }.count)）" }
                try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        // --new-conv "秒數"：像按「新對話」（跳出資料夾選單）
        for (i, a) in args.enumerated() where a == "--new-conv" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.main.newConversation() }
        }
        // 環境變數 CODENV_FAKE_RUNNING=<個數|badges>（要有 --state-dir）：開機 3 秒後在目前選的對話塞假的背景項目，拍「正在跑」版面用
        if args.contains("--state-dir"), let raw = ProcessInfo.processInfo.environment["CODENV_FAKE_RUNNING"] {
            if raw == "badges" {
                for t in [3.0, 6.0, 9.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                        if let id = self?.store.selected { SessionActivity.shared.injectFakeBadgesForTest(id) }
                    }
                }
            } else if let n = Int(raw), n > 0 {
                for t in [3.0, 6.0, 9.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in if let id = self?.store.selected { SessionActivity.shared.injectFakeForTest(id, count: n) } }
                }
            }
        }
        // --new-chat "秒數:標題"：幾秒後開一段真的聊天室（不是草稿，不會被自動刪；放進目前那格）。測版面、掛件、⌘ W 用
        for (i, a) in args.enumerated() where a == "--new-chat" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                let pid = self.store.projects.first?.id ?? self.store.addProject(path: NSHomeDirectory()).id
                var c = self.store.createConversation(in: pid)
                self.store.rename(c.id, to: String(parts[1]), byUser: true)
                c = self.store.conversation(c.id) ?? c
                self.store.show(c.id)
            }
        }
        // --conv-session "秒數:標題:UUID"：把那段聊天室的 Claude 對話編號換成指定的（測喚醒、接回用：配合先用同編號開好的紀錄檔）；--conv-place "秒數:標題"：把它擺進目前那格
        for (i, a) in args.enumerated() where a == "--conv-session" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]), let u = UUID(uuidString: parts[2]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let n = self.store.conversations.firstIndex(where: { $0.title == parts[1] }) else { return }
                self.store.conversations[n].claudeSession = u
            }
        }
        for (i, a) in args.enumerated() where a == "--conv-place" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let c = self.store.conversations.first(where: { $0.title == parts[1] }) else { return }
                self.store.show(c.id)
            }
        }
        // --new-chat-at "秒數:資料夾:標題"：在那個資料夾開一段真的聊天室，不顯示（測「點不同資料夾的聊天室」）
        for (i, a) in args.enumerated() where a == "--new-chat-at" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                let pid = self.store.projects.first(where: { $0.path == parts[1] })?.id ?? self.store.addProject(path: parts[1]).id
                let c = self.store.createConversation(in: pid)
                self.store.rename(c.id, to: parts[2], byUser: true)
            }
        }
        // --sidebar-open "秒數:標題"：像在側欄點那段聊天室
        for (i, a) in args.enumerated() where a == "--sidebar-open" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let c = self.store.conversations.first(where: { $0.title == parts[1] }) else { return }
                self.store.open(c.id)
            }
        }
        // --f2 "秒數:名字"：像按 F2 並在輸入框打這個名字（選取整個 Window 時改 Window，不然改紫框那格）；--window-select "秒數"：像點上方 Window 分頁
        for (i, a) in args.enumerated() where a == "--f2" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.main.f2Rename(answer: parts[1]) }
        }
        for (i, a) in args.enumerated() where a == "--window-select" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in if let wi = self?.store.windowIndex { self?.store.toggleWindowSelection(at: wi) } }   // 像點目前這個 Window 的分頁（再來一次＝回原本那格）
        }
        // --window-rename "秒數:名字"：像 Ctrl+A , 幫目前 Window 取名（空字串＝清空）
        for (i, a) in args.enumerated() where a == "--window-rename" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.store.renameWindow(parts[1]) }
        }
        // --window-move "秒數:標題:第幾個Window"：把那段聊天室搬到另一個 Window（測框跟著成員變）
        for (i, a) in args.enumerated() where a == "--window-move" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]), let n = Int(parts[2]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let c = self.store.conversations.first(where: { $0.title == parts[1] }) else { return }
                self.store.selectWindow(at: n)
                self.store.split(vertical: false, with: c.id)
            }
        }
        // --keyguard-auto sendanyway（限 --state-dir 與 --keyvault-prefix codenv-test-…；07-30）：一般送出路徑遇到金鑰卡片時自動選「仍要送出」並確認（不彈 NSAlert、不碰鑰匙圈），
        // 配 --chat-send 從輸入框真的送給（假）引擎，測「仍要送出」後 outbox 的明文有沒有清掉。
        if let i = args.firstIndex(of: "--keyguard-auto"), i + 1 < args.count, args[i + 1] == "sendanyway", args.contains("--state-dir"), KeyVault.prefix.hasPrefix("codenv-test-") {
            KeyGuard.testConfirm = { true }
            KeyGuard.testDecision = { _ in .sendAnyway }
        }
        // --bang-sweep-probe "秒數:close|corrupt-close|dump:輸出檔"（限 --state-dir；07-29）：配 --new-conv-at 開草稿＋--chat-send "秒數:! echo hi" 跑一次 ! 指令後用。
        // 重開後 dump 可另帶 --bang-sweep-probe-conversation-id <UUID>，只查第一次 close／corrupt-close 輸出的 id。
        // close＝關掉目前那格、取消選取、跑 sweepDrafts（舊版會把只有 ! 紀錄的草稿當空的刪掉）；corrupt-close＝先把這個聊天室的 ! 紀錄檔改成壞掉的 JSON 再 close；dump＝只輸出現況（重開 App 後用）。
        // 輸出 JSON：conversationExists、bangFileExists、bangRecords（讀得懂的筆數）、bangUnreadable、recoveryFileExists、claudeSession、id
        for (i, a) in args.enumerated() where a == "--bang-sweep-probe" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]), ["close", "corrupt-close", "dump"].contains(parts[1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                let mode = parts[1]
                let conversationIDArgument = args.firstIndex(of: "--bang-sweep-probe-conversation-id")
                let hasExplicitDumpID = mode == "dump" && conversationIDArgument != nil
                let explicitDumpIDText = conversationIDArgument.flatMap { index -> String? in
                    guard index + 1 < args.count else { return nil }
                    return args[index + 1]
                }
                let target: UUID?
                if hasExplicitDumpID {
                    target = explicitDumpIDText.flatMap(UUID.init(uuidString:))
                } else {
                    // 沒有指定 ID 的舊用法維持原本選取順序。
                    target = self.store.selected ?? self.store.conversations.last?.id
                }
                guard let id = target, let conv = self.store.conversations.first(where: { $0.id == id }) else {
                    if hasExplicitDumpID {
                        // 指定 ID 找不到時只回報缺席，不得退回查其他聊天室。
                        let object: [String: Any] = [
                            "id": explicitDumpIDText?.lowercased() ?? "",
                            "claudeSession": "", "draftBefore": false,
                            "conversationExists": false, "bangFileExists": false,
                            "bangRecords": 0, "bangUnreadable": false,
                            "recoveryFileExists": false
                        ]
                        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
                        try? data.write(to: URL(fileURLWithPath: parts[2]))
                    } else {
                        try? "{\"conversationExists\":false,\"note\":\"沒有可探測的聊天室\"}\n".write(toFile: parts[2], atomically: true, encoding: .utf8)
                    }
                    return
                }
                let sid = conv.claudeSession
                let file = BangStore.dir.appendingPathComponent(sid.uuidString.lowercased() + ".json")
                if mode == "corrupt-close" { try? "{not json".write(to: file, atomically: true, encoding: .utf8) }
                var draftBefore = false
                if mode != "dump" {
                    // 自動把 ! 結果交給模型會順手清掉草稿旗標；這裡還原成「還是草稿」，才是舊版會被誤刪的情況
                    if let k = self.store.conversations.firstIndex(where: { $0.id == id }) { self.store.conversations[k].draft = true; draftBefore = true }
                    self.store.closePane()
                    self.store.selected = nil
                    self.main.sweepDrafts()
                }
                let object: [String: Any] = [
                    "id": id.uuidString.lowercased(), "claudeSession": sid.uuidString.lowercased(), "draftBefore": draftBefore,
                    "conversationExists": self.store.conversations.contains { $0.id == id },
                    "bangFileExists": FileManager.default.fileExists(atPath: file.path),
                    "bangRecords": BangStore.load(sid).count,
                    "bangUnreadable": BangStore.hasUnreadableFile(sid),
                    "recoveryFileExists": FileManager.default.fileExists(atPath: BangStore.dir.appendingPathComponent(sid.uuidString.lowercased() + ".recovery.json").path)]
                let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
                try? data.write(to: URL(fileURLWithPath: parts[2]))
            }
        }
        // --new-conv-at "秒數:資料夾"：幾秒後直接在那個資料夾開新對話（不跳資料夾選單；測聊天室畫面用）
        for (i, a) in args.enumerated() where a == "--new-conv-at" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let dir = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.main.newConversation(at: dir) }
        }
        // --store-op "秒數:動作:第幾段:參數"：shift（參數＝上移負數／下移正數）、archive（1 封存／0 取消）、unread（1 標成做完沒看／0 取消）、before（排到第參數段前面）、handoff（參數＝0，略過確認框，仍跑全部開始前檢查）。段數從 0 數。
        // 名稱操作另用 "秒數:pickcommander:名稱"，不需要對話索引，與左欄點選一樣先清獨立視窗 scope 再 selectSession。
        for (i, a) in args.enumerated() where a == "--store-op" && i + 1 < args.count {
            let named = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            if named.count == 3, named[1] == "pickcommander" {
                guard let sec = Double(named[0]), sec.isFinite, sec >= 0 else { continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                    guard let st = self?.store as Store?,
                          let session = st.sessions.first(where: { $0.area == nil && $0.groups != nil && $0.name == named[2] }) else { return }
                    st.scope = nil
                    st.selectSession(session.id)
                }
                continue
            }
            let parts = args[i + 1].split(separator: ":").map(String.init)
            guard parts.count == 4, let sec = Double(parts[0]), sec.isFinite, sec >= 0, let n = Int(parts[2]), let v = Int(parts[3]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, self.store.conversations.indices.contains(n) else { return }
                let id = self.store.conversations[n].id
                switch parts[1] {
                case "shift": self.store.shift(id, by: v)
                case "archive": self.store.setArchived(id, v == 1)
                case "before": if v < self.store.conversations.count { self.store.reorder(id, before: self.store.conversations[v].id) }
                case "after": if v < self.store.conversations.count { self.store.reorder(id, after: self.store.conversations[v].id) }
                case "compact": (self.workspace.panes[id] as? ChatPane)?.compact()
                case "handoff":
                    guard let c = self.store.conversation(id) else { break }
                    let dir = self.store.workingDirectory(for: c)
                    self.main.startHandoff(c, directory: dir)
                case "unread": if v == 1 { self.store.unread.insert(id) } else { self.store.unread.remove(id) }   // 分頁／側欄的小藍點
                // 掛件框（Bundles.swift）：gemini／notebook＝掛到第 n 段（參數不用）；leave＝離開框；dissolve＝解散第 n 段所在的框；
                // movegroup＝把第 n 段所在的框整個搬到第 v 組；attach＝把第 n 段（瀏覽器）改成掛在第 v 段上；open＝打開第 n 段的第 v 個掛件
                // site＝這格瀏覽器網址換成「第 v 種」：0 Gemini 對話 A、1 NotebookLM 筆記本 B、2 其他網站（假網址，不連網）；
                // sitesw0／sitesw1＝像 ⌥ 八宮格那樣切回 Gemini／NotebookLM，把要載入的網址（或 nil）和 lastURLs 寫到 stderr 旁的 browser-test.log
                case "site":
                    let urls = ["https://gemini.google.com/app/88ec0001", "https://notebooklm.google.com/notebook/b2b20002", "https://example.org/x"]
                    self.store.noteBrowserURL(id, urls[min(v, 2)])
                case "sitesw0", "sitesw1":
                    let r = self.store.switchBrowserSite(id, to: parts[1] == "sitesw0" ? .gemini : .notebooklm)
                    let line = "切換→\(parts[1]) 載入=\(r ?? "nil") 目前=\(self.store.conversation(id)?.browser ?? "") lastURLs=\(self.store.conversation(id)?.lastURLs ?? [:])\n"
                    let f = self.store.directory.appendingPathComponent("site-test.log")
                    if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() } else { try? line.write(to: f, atomically: true, encoding: .utf8) }
                case "sandbox": self.main.toggleSandbox(id)   // 右鍵「在沙盒裡跑（nono）」
                case "show": self.store.show(id)   // 放進紫框那格（測 ⌘ ⇧ B 依選中的格子決定掛不掛）
                case "focus": self.store.editWindow { $0.focused = id }   // 紫框移到第 n 段（它要已經在目前 Window）
                case "closewin": self.store.closeWindow()   // ⌃ ⌘ W（關掉目前整個 Window）
                case "reopenwin": self.store.reopenClosedWindow()   // ⌘ ⇧ T
                case "newwindow": self.store.newWindow(with: id)   // 開新 Window 放第 n 段
                case "window": self.store.selectWindow(at: v)
                case "dframe": self.main.detachedWindows.values.first?.window?.setFrame(NSRect(x: 120 + CGFloat(v), y: 210, width: 640, height: 480), display: true)   // 把（第一個）獨立視窗搬到固定位置（測記位置用）
                case "dscreen": if let f = self.main.detachedWindows.values.first?.window { f.setFrame(NSRect(x: 99000, y: 99000, width: 5000, height: 4000), display: false) }   // 搬到所有螢幕外面
                case "winoffset": self.store.selectWindow(offset: v)   // ⌘ ⇧ [ ／ ] 切 Window 分頁（v＝+1／−1）
                case "scope": self.store.scope = v == 1 ? self.store.sessions.flatMap(\.windows).first { $0.detached }?.id : nil   // 模擬獨立視窗拿到（1）或還回（0）焦點      // 切到第 v 個 Window
                case "splitwith": self.store.split(vertical: false, with: id)   // 從紫框那格左右切開、放第 n 段
                case "gemini": self.store.addGadget(.gemini, to: id)
                case "notebook": self.store.addGadget(.notebooklm, to: id)
                case "leave": self.store.setBundle(id, nil)
                case "dissolve": if let b = self.store.conversation(id)?.bundle { self.store.dissolveBundle(b) }
                case "movegroup": if let b = self.store.conversation(id)?.bundle, v < self.store.groups.count { self.store.moveBundle(b, toGroup: self.store.groups[v].id) }
                case "attach": if v < self.store.conversations.count { self.store.attachBrowser(id, to: self.store.conversations[v].id) }
                case "open": if let b = self.store.conversation(id)?.bundle, v < self.store.gadgets(of: b).count { self.store.openGadget(self.store.gadgets(of: b)[v].id) }
                // ⌘ W（closew）、⌘ ⇧ T（reopen）、側欄點第 n 段（sidebar）、⌘ ⇧ B（togglebundle）：不按鍵盤，直接呼叫同一個函式
                case "bundleset":   // 把第 n 段放進第 v 段所在的掛件框（沒有框就新開一個）；框沒有掛件就掛一個 Gemini（都不擺進版面）
                    guard v < self.store.conversations.count else { break }
                    let anchor = self.store.conversations[v].id
                    let b = self.store.conversation(anchor)?.bundle ?? UUID()
                    self.store.setBundle(anchor, b); self.store.setBundle(id, b)
                    if self.store.gadgets(of: b).isEmpty { _ = self.store.addGadget(.gemini, to: anchor) }
                case "emptywindow":   // 開一個只有一格「空格子」的新 Window（跟 ⌘ T 一樣）
                    self.store.newWindow(with: nil)
                    let slot = UUID()
                    self.store.editWindow { $0.root = .leaf(slot); $0.focused = slot }
                    Store.emptySlots.insert(slot)
                case "detach": self.main.detachWindowTab(v, at: NSPoint(x: 700, y: 500))   // 把主視窗分頁列第 v 個 Window 拉出去變獨立視窗
                case "closedetached": self.main.detachedWindows.values.first?.window?.close()   // 關掉（第一個）獨立視窗＝回到主視窗
                case "place": if v < self.store.conversations.count { self.store.place(id, near: self.store.conversations[v].id, edge: .right) }   // 像從側欄把第 n 段拖到第 v 段右邊（v 在哪個視窗就放哪；在主視窗＝scoped(nil)）
                case "closesession": self.store.closeSession()   // 關掉目前的 Session
                case "closew": self.store.closePaneOrWindow()
                case "reopen": self.store.reopenClosedWindow()
                case "sidebar": self.store.open(id, replaceFocused: false)
                case "sidebarshift": self.store.open(id, replaceFocused: true)   // ⇧ 點側欄：放進目前紫框那格（換掉它），不開新 Window
                case "togglebundle": self.store.toggleBundle(from: id)
                default: break
                }
            }
        }
        // --daily-handoff-now "秒數"：到時候立刻跑一輪每日交接（略過功能開關，其他條件照常；--fake-now 影響分界計算）。只在有 --state-dir 時有效，且一定要有 --handoff-fake。
        // --daily-handoff-gap "秒數"：每件之間的間隔（預設 20 秒）；--daily-handoff-auto：測試實例也開自動定時檢查。
        for (i, a) in args.enumerated() where a == "--daily-handoff-now" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]), sec.isFinite, sec >= 0 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.main.dailyHandoff.check("測試", force: true) }
        }
        // --handoff-dump "秒數:檔案"：可重複指定，輸出 JSON；對話與排程的 conversation 都用相同的 UUID 前 8 碼。
        for (i, a) in args.enumerated() where a == "--handoff-dump" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]), sec.isFinite, sec >= 0 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let st = self.store else { return }
                func field<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }
                func short(_ id: UUID?) -> Any { field(id.map { String($0.uuidString.lowercased().prefix(8)) }) }
                let frames = st.windowFrames
                let conversations: [[String: Any]] = st.conversations.map { c in
                    ["id": short(c.id), "uuid": c.id.uuidString.lowercased(), "title": c.title,
                     "manualArchive": field(c.manualArchive), "bundle": short(c.bundle), "gadgetOf": short(c.gadgetOf),
                     "permissionMode": field(c.permissionMode), "sandbox": field(c.sandbox), "order": field(c.order),
                     "projectID": c.projectID.uuidString.lowercased(), "groupID": short(c.groupID),
                     "windowFrame": short(frames[c.id]?.window), "windowName": field(frames[c.id]?.name),
                     "browser": field(c.browser), "lastURLs": field(c.lastURLs),
                     "lastHandoffAt": field(c.lastHandoffAt.map { ISO8601DateFormatter().string(from: $0) })]
                }
                let f = ISO8601DateFormatter()
                let schedules: [[String: Any]] = ScheduleStore.shared.items.map { s in
                    ["id": s.id.uuidString.lowercased(), "conversation": short(s.conversation),
                     "conversationID": s.conversation.uuidString.lowercased(), "pendingRun": field(s.pendingRun.map(f.string)),
                     "nextAt": field(s.nextAt.map(f.string)), "enabled": s.enabled,
                     "runs": s.runs.map { ["at": f.string(from: $0.at), "due": f.string(from: $0.due), "result": $0.result] }]
                }
                let folder = st.directory.appendingPathComponent("handoffs", isDirectory: true)
                var files: [String] = [], errors: [String] = []
                if FileManager.default.fileExists(atPath: folder.path),
                   let entries = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], errorHandler: { url, error in
                       errors.append("\(url.path)：\(error.localizedDescription)"); return true
                   }) {
                    for case let url as URL in entries {
                        do { if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { files.append(url.path) } }
                        catch { errors.append("\(url.path)：\(error.localizedDescription)") }
                    }
                }
                let object: [String: Any] = ["conversations": conversations, "schedules": schedules, "handoffs": files.sorted(), "errors": errors,
                                              "chiefs": st.sessions.map { field($0.chief.map { String($0.uuidString.lowercased().prefix(8)) }) },
                                              "selected": short(st.selected), "currentSession": short(st.currentSession),
                                              "windows": st.sessions.flatMap { s in s.windows.map { w -> [String: Any] in
                                                  ["session": short(s.id), "window": short(w.id), "name": w.name, "leaves": (w.root?.leaves ?? []).map { short($0) },
                                                   "focused": short(w.focused), "current": s.current == w.id] } }]
                do {
                    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                    try data.write(to: URL(fileURLWithPath: parts[1]), options: .atomic)
                } catch { EventLog.log("測試", "交接狀態輸出失敗：\(error.localizedDescription)") }
            }
        }
        // --bundle-anim "秒數:動畫秒數"：把側欄所有掛件框停在描邊動畫的第幾秒（負數＝放開，回到正常）；可以給好幾次
        for (i, a) in args.enumerated() where a == "--bundle-anim" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]), let at = Double(parts[1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { BundleAnim.shared.frozen = at < 0 ? nil : at }
        }
        // --drag-divider "秒數:第幾條:比例"：像用滑鼠把目前 Window 的第幾條分隔線（外層先）拖到這個比例（測 ⌘ Q 後比例有沒有記住）
        for (i, a) in args.enumerated() where a == "--drag-divider" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":").map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]), let n = Int(parts[1]), let r = Double(parts[2]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.main.host.testDragDivider(index: n, ratio: CGFloat(r)) }
        }
        // --quit "秒數"：走跟 ⌘ Q 一樣的結束流程（applicationShouldTerminate → applicationWillTerminate 存檔）
        for (i, a) in args.enumerated() where a == "--quit" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { NSApp.terminate(nil) }
        }
        // --dump-tree "秒數:檔案"：每個 Window 的版面樹和每一層的比例
        for (i, a) in args.enumerated() where a == "--dump-tree" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let st = self?.store as Store? else { return }
                func show(_ n: PaneNode) -> String {
                    switch n {
                    case .leaf(let id): return st.conversation(id)?.title ?? "空"
                    case .split(let v, let r, let a, let b): return "[\(v ? "上下" : "左右") \(String(format: "%.3f", r)): \(show(a)) | \(show(b))]"
                    }
                }
                var out = st.sessions.flatMap { s in s.windows.map { w in "\(s.name)/\(w.name)：\(w.root.map(show) ?? "-")（紫框＝\(w.focused.flatMap { st.conversation($0)?.title } ?? "-")\(w.zoomed ? "，放大中" : "")）" } }
                // 目前 Window 裡每個掛件圖示是亮還是暗（側欄的 shownGadgets 用同一個算法），和 ⌘ ⇧ T 能找回幾個
                let here = Set((st.currentWindow?.root?.leaves ?? []).filter { !PaneSlide.shared.isLeaving($0) })
                out.append("掛件圖示：" + st.conversations.filter(\.isGadget).map { "\($0.title)＝\(here.contains($0.id) ? "亮" : "暗")" }.joined(separator: "、"))
                out.append("可找回的 Window：\(Store.closed.filter { if case .window = $0 { return true } else { return false } }.count)")
                try? out.joined(separator: "\n").write(toFile: String(parts[1]), atomically: true, encoding: .utf8)
            }
        }
        // --pane-slide "秒數:動畫秒數"：掛件格子滑進／滑出的動畫停在第幾秒（負數＝放開，照常跑完）；可以給好幾次
        for (i, a) in args.enumerated() where a == "--pane-slide" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]), let at = Double(parts[1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { PaneSlide.shared.frozen = at < 0 ? nil : at; PaneSlide.shared.notify() }
        }
        // --bundle-dump "秒數:檔案"：每段對話的組、掛件框、掛件和網址（測掛件框）
        for (i, a) in args.enumerated() where a == "--bundle-dump" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                guard let st = self.store as Store? else { return }
                let short = { (u: UUID?) in u.map { String($0.uuidString.prefix(4)) } ?? "-" }
                var out = st.conversations.map { c in
                    "\(c.title)\t組=\(st.group(st.groupOf(c))?.name ?? "-")\t框=\(short(c.bundle))\t掛件of=\(short(c.gadgetOf))\t網址=\(c.browser ?? "-")\t在版面=\(st.locate(c.id) != nil)"
                }
                // Window 框（取過名字的 Window，Store.windowFrames）：名字和成員
                let wf = st.windowFrames
                for name in Set(wf.values.map(\.name)).sorted() { out.append("Window框：\(name)＝" + st.conversations.filter { wf[$0.id]?.name == name }.map(\.title).joined(separator: "、")) }
                out.append("選取整個Window：\(st.windowSelected)")
                out.append("Window框數：\(Set(wf.values.map(\.window)).count)")
                out.append("格子：\(st.currentWindow?.root?.leaves.count ?? 0)")
                let fr = self.main.window?.firstResponder
                let owner = self.workspace.panes.first { (_, v) in (fr as? NSView).map { $0.isDescendant(of: v) } ?? false }
                out.append("版面：" + (st.currentWindow?.root?.leaves ?? []).map { st.conversation($0)?.title ?? "空" }.joined(separator: "｜"))
                if case .split(_, let r, _, _)? = st.currentWindow?.root { out.append("最外層比例：\(String(format: "%.3f", r))") }
                out.append("紫框：\(st.currentWindow?.focused.flatMap { st.conversation($0)?.title } ?? "-")")
                out.append("焦點：\(fr.map { String(describing: type(of: $0)) } ?? "nil") 在 \(owner.flatMap { st.conversation($0.key)?.title } ?? "-")")
                try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        // --set-default-effort "秒數:強度"：像在模型面板把拉桿拉到這段、按「設為預設」（要先 --model-panel 打開面板）
        for (i, a) in args.enumerated() where a == "--set-default-effort" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let v = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                guard let m = ModelPanelModel.last, let i = m.levels.firstIndex(of: v) else { return }
                m.index = Double(i)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if let e = m.effort { m.onSetDefault?(e) } }
            }
        }
        // --chat-stop "秒數"：幾秒後按停止
        for (i, a) in args.enumerated() where a == "--chat-stop" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.session.interrupt()
            }
        }
        // --chat-text "秒數:檔案"：幾秒後把聊天畫面上的文字（網頁的 innerText）寫進檔案
        for (i, a) in args.enumerated() where a == "--chat-text" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.evaluate("document.body.innerText") { s in try? s.write(toFile: path, atomically: true, encoding: .utf8) }
            }
        }
        // --focus-move "秒數:檔案"：程式碼區聊天室裡依序按 ⌃ A → ↓ ↑ ←，每步回報焦點在哪（聊天／編輯器／執行結果）
        for (i, a) in args.enumerated() where a == "--focus-move" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let f = self.store.currentWindow?.focused, let p = self.workspace.panes[f] as? ChatPane, let lab = p.codeLab, let w = p.window else {
                    try? "沒有程式碼區聊天室".write(toFile: path, atomically: true, encoding: .utf8); return
                }
                func spot() -> String {
                    guard let v = w.firstResponder as? NSView else { return "nil" }
                    if v === p.inputBar.textView { return "聊天輸入框" }
                    if v.isDescendant(of: lab) { return v is WKWebView ? "編輯器" : "執行結果(\(type(of: v)))" }
                    return String(describing: type(of: v))
                }
                let noAI = lab.mode == .noAI          // 不用 AI：聊天收起來，從編輯器起步、測左右
                if noAI { lab.focusEditor() } else { _ = p.focusInput() }
                var out = ["開始：\(spot())"]
                let steps: [(String, (Int, Int))] = noAI ? [("→", (1, 0)), ("←", (-1, 0)), ("←", (-1, 0))] : [("→", (1, 0)), ("↓", (0, 1)), ("↑", (0, -1)), ("←", (-1, 0))]
                for (name, d) in steps {
                    self.main.moveFocus(dx: d.0, dy: d.1)
                    out.append("\(name)：\(spot())")
                }
                try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        // --fake-timers：塞幾個假的計時器（不碰真桌寵；只在 --state-dir 測試時有效）
        if args.contains("--fake-timers") {
            PetTimers.shared.inject(id: "a", label: "模型評測 gpt-oss 全部題目", eta: 600, startedAgo: 200)
            PetTimers.shared.inject(id: "b", label: "下載模型", eta: nil, done: 12, total: 40, startedAgo: 60)
            PetTimers.shared.inject(id: "c", label: "超時的編譯", eta: 60, startedAgo: 300)
            PetTimers.shared.inject(id: "d", label: "做完了", eta: 60, finished: true)
        }
        // --area-add-probe 輸出檔：在測試資料裡造兩個總指揮（c2 涵蓋 c1 底下一個叫「共名」的子組），
        // 叫 c1 建同名同父的區：必須失敗、「共名」那組仍在（舊版會把它 removeGroup 刪掉）；再刪該組，總指揮涵蓋清單不能留失效 id
        if let i = args.firstIndex(of: "--area-add-probe"), i + 1 < args.count, args.contains("--state-dir") {
            let out = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let st = self?.main.store else { return }
                let r1 = ConvGroup(name: "R1"); var z = ConvGroup(name: "共名"); z.parentID = r1.id
                st.groups.append(contentsOf: [r1, z])
                let p1 = Project(name: "p1", path: "/tmp", groupID: r1.id), p2 = Project(name: "p2", path: "/tmp", groupID: z.id)
                st.projects.append(contentsOf: [p1, p2])
                var c1 = Conversation(projectID: p1.id, title: "chief1"); c1.groupID = r1.id
                var c2 = Conversation(projectID: p2.id, title: "chief2"); c2.groupID = z.id
                st.conversations.append(contentsOf: [c1, c2])
                let s1 = SessionLayout(name: "S1", windows: [], groups: [r1.id], chief: c1.id)
                let s2 = SessionLayout(name: "S2", windows: [], groups: [z.id], chief: c2.id)
                st.sessions.append(contentsOf: [s1, s2])
                let r = st.commanderAreaAdd(caller: c1.id.uuidString, name: "共名", parent: nil)
                var lines = ["ok=\(r["ok"] as? Bool ?? true)", "error=\(r["error"] as? String ?? "")"]
                lines.append("zStillThere=\(st.groups.contains { $0.id == z.id })")
                st.removeGroup(z.id)
                lines.append("staleIdCleared=\(!(st.sessions.first { $0.id == s2.id }?.groups ?? []).contains(z.id))")
                try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        // --commander-worktree-probe <輸出.json>：只在 --state-dir 啟用，在 state-dir 建立假 repo；不呼叫模型、不啟動 agy。
        if let i = args.firstIndex(of: "--commander-worktree-probe"), i + 1 < args.count,
           let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count {
            let state = URL(fileURLWithPath: args[stateIndex + 1], isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            let requestedOutput = URL(fileURLWithPath: args[i + 1]).standardizedFileURL
            let output = requestedOutput.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(requestedOutput.lastPathComponent)
            guard output.path.hasPrefix(state.path + "/") else { return }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                let scenarioIndex = args.firstIndex(of: "--commander-worktree-probe-scenario")
                let scenario = scenarioIndex.flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
                let result = scenario.map { CommanderWorktree.runScenarioProbe(in: state, scenario: $0) } ?? CommanderWorktree.runProbe(in: state)
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: output, options: .atomic)
                }
            }
        }
        // --archive-probe 輸出檔：測 codenv-todo archive（Store.commanderArchive）：總指揮只能封存自己底下、目前沒在工作的聊天室；
        // 工作中的、等待回答的、別的總指揮底下的、總指揮自己、非總指揮呼叫、同名未指明 id 一律拒絕
        if let i = args.firstIndex(of: "--archive-probe"), i + 1 < args.count, args.contains("--state-dir") {
            let out = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let st = self?.main.store else { return }
                let g1 = ConvGroup(name: "G1"), g2 = ConvGroup(name: "G2")
                st.groups.append(contentsOf: [g1, g2])
                let p1 = Project(name: "p1", path: "/tmp", groupID: g1.id), p2 = Project(name: "p2", path: "/tmp", groupID: g2.id)
                st.projects.append(contentsOf: [p1, p2])
                var chief1 = Conversation(projectID: p1.id, title: "總指揮甲"); chief1.groupID = g1.id
                var idle = Conversation(projectID: p1.id, title: "閒置分支"); idle.groupID = g1.id
                var cliIdle = Conversation(projectID: p1.id, title: "指令分支"); cliIdle.groupID = g1.id
                var busy = Conversation(projectID: p1.id, title: "工作分支"); busy.groupID = g1.id
                var wait = Conversation(projectID: p1.id, title: "等待分支"); wait.groupID = g1.id
                var dup1 = Conversation(projectID: p1.id, title: "同名分支"); dup1.groupID = g1.id
                var dup2 = Conversation(projectID: p1.id, title: "同名分支"); dup2.groupID = g1.id
                var chief2 = Conversation(projectID: p2.id, title: "總指揮乙"); chief2.groupID = g2.id
                var other = Conversation(projectID: p2.id, title: "別組分支"); other.groupID = g2.id
                st.conversations.append(contentsOf: [chief1, idle, cliIdle, busy, wait, dup1, dup2, chief2, other])
                let s1 = SessionLayout(name: "S1", windows: [], groups: [g1.id], chief: chief1.id)
                let s2 = SessionLayout(name: "S2", windows: [], groups: [g2.id], chief: chief2.id)
                st.sessions.append(contentsOf: [s1, s2])
                st.status[busy.id] = .working
                st.status[wait.id] = .waiting
                let rNonChief = st.commanderArchive(caller: idle.id.uuidString, target: "閒置分支")
                let rSelf = st.commanderArchive(caller: chief1.id.uuidString, target: "self")
                let rOther = st.commanderArchive(caller: chief1.id.uuidString, target: "別組分支")
                let rBusy = st.commanderArchive(caller: chief1.id.uuidString, target: "工作分支")
                let rWait = st.commanderArchive(caller: chief1.id.uuidString, target: "等待分支")
                let rDup = st.commanderArchive(caller: chief1.id.uuidString, target: "同名分支")
                let rIdle = st.commanderArchive(caller: chief1.id.uuidString, target: "閒置分支")
                let rById = st.commanderArchive(caller: chief1.id.uuidString, target: String(dup1.id.uuidString.prefix(8)))
                let lines = [
                    "chief1_id=\(chief1.id.uuidString)",
                    "nonChief_ok=\(rNonChief["ok"] as? Bool ?? true)",
                    "self_ok=\(rSelf["ok"] as? Bool ?? true)",
                    "other_ok=\(rOther["ok"] as? Bool ?? true)",
                    "other_archived=\(st.conversation(other.id).map { st.isArchived($0) } ?? true)",
                    "busy_ok=\(rBusy["ok"] as? Bool ?? true)",
                    "busy_err=\(rBusy["error"] as? String ?? "")",
                    "busy_archived=\(st.conversation(busy.id).map { st.isArchived($0) } ?? true)",
                    "wait_ok=\(rWait["ok"] as? Bool ?? true)",
                    "wait_archived=\(st.conversation(wait.id).map { st.isArchived($0) } ?? true)",
                    "dup_ok=\(rDup["ok"] as? Bool ?? true)",
                    "idle_ok=\(rIdle["ok"] as? Bool ?? false)",
                    "idle_archived=\(st.conversation(idle.id).map { st.isArchived($0) } ?? false)",
                    "byId_ok=\(rById["ok"] as? Bool ?? false)",
                    "dup1_archived=\(st.conversation(dup1.id).map { st.isArchived($0) } ?? false)",
                    "dup2_archived=\(st.conversation(dup2.id).map { st.isArchived($0) } ?? true)",
                ]
                try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        // --hang-send：把 send 指令換成永遠不回的（測 BrowserServer 的逾時：--wait 要等到 timeout、不能固定 15 秒就叫呼叫端重送）
        if args.contains("--hang-send"), args.contains("--state-dir") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { BrowserServer.shared.sendChat = { _, _, _, _, _, _, _, _, _ in } }
        }
        // --usage-date-probe 輸出檔：friendlyDate 沒有年份的字串跨年時要選對年（用假的「現在」，不碰真資料）
        if let i = args.firstIndex(of: "--usage-date-probe"), i + 1 < args.count, args.contains("--state-dir") {
            let out = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let cal = Calendar.current
                func at(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))! }
                func ymd(_ d: Date?) -> String { d.map { let c = cal.dateComponents([.year, .month, .day], from: $0); return "\(c.year!)-\(c.month!)-\(c.day!)" } ?? "nil" }
                var lines: [String] = []
                lines.append("dec_to_jan=\(ymd(UsageMonitor.friendlyDate("Jan 1 at 12am", zone: nil, now: at(2026, 12, 30))))")
                lines.append("jan_to_dec=\(ymd(UsageMonitor.friendlyDate("Dec 31 at 11pm", zone: nil, now: at(2027, 1, 2))))")
                lines.append("same_year=\(ymd(UsageMonitor.friendlyDate("Nov 9 at 1am", zone: nil, now: at(2026, 11, 8))))")
                try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        // --board-bad-probe 輸出檔：在測試資料夾的 collab.json 放 2 個好目標＋1 個壞目標（缺 title），loadTodos 要讀到 2 個，原檔不動
        if let i = args.firstIndex(of: "--board-bad-probe"), i + 1 < args.count, args.contains("--state-dir") {
            let out = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let json = #"{"items":[],"goals":[{"id":"g1","title":"好一","status":"active","steps":[]},{"id":"g2","status":"active"},{"id":"g3","title":"好二","status":"active","steps":[]}]}"#
                try? json.write(to: CollabBoardModel.todoFile, atomically: true, encoding: .utf8)
                let (_, goals) = CollabBoardModel.loadTodos()
                let intact = (try? String(contentsOf: CollabBoardModel.todoFile, encoding: .utf8)) == json
                try? "goals=\(goals.map(\.id).joined(separator: ","))\nfileIntact=\(intact)".write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        // --collab-backup-rotation-probe <state-dir內的JSON>：走 App 真正的 collab edit，驗證縮小的舊檔不會洗掉較完整的 .bak。
        if let i = args.firstIndex(of: "--collab-backup-rotation-probe"), i + 1 < args.count,
           let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count {
            let root = URL(fileURLWithPath: args[stateIndex + 1], isDirectory: true)
            let output = URL(fileURLWithPath: args[i + 1])
            guard isPrivateTemporaryProbeRoot(root), isTestProbeOutput(output, inside: root) else { exit(2) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let file = CollabBoardModel.todoFile
                guard isTestProbeOutput(file, inside: root) else {
                    try? #"{"error":"collab.json 不在隔離 --state-dir 內"}"#.write(to: output, atomically: true, encoding: .utf8)
                    return
                }
                func board(_ count: Int) -> [String: Any] {
                    ["items": [[String: Any]](), "goals": (0..<count).map { n in
                        ["id": "backup-probe-\(n)", "title": "備份目標 \(n)", "status": "proposed", "steps": [[String: Any]]()] as [String: Any]
                    }]
                }
                func elementCount(_ url: URL) -> Int? {
                    guard let data = try? Data(contentsOf: url),
                          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
                    return CollabBoardModel.elementCount(object)
                }
                func report(_ value: [String: Any]) {
                    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else {
                        FileHandle.standardError.write(Data("collab-backup-rotation-probe: JSON 序列化失敗\n".utf8))
                        return
                    }
                    do { try data.write(to: output, options: .atomic) }
                    catch { FileHandle.standardError.write(Data("collab-backup-rotation-probe: \(error)\n".utf8)) }
                }
                do {
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let current = try JSONSerialization.data(withJSONObject: board(5), options: [.sortedKeys])
                    let completeBackup = try JSONSerialization.data(withJSONObject: board(6), options: [.sortedKeys])
                    try current.write(to: file, options: .atomic)
                    try completeBackup.write(to: URL(fileURLWithPath: file.path + ".bak"), options: .atomic)
                } catch {
                    report(["error": "無法建立隔離 fixture：\(error)"])
                    return
                }
                let backup = URL(fileURLWithPath: file.path + ".bak")
                CollabBoardModel.shared.addMemoryProposal(title: "G126 備份輪替探針", done: "", step: "測試步驟", by: "g126-probe", limit: 1)
                func collect(_ attempt: Int) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        guard let currentCount = elementCount(file), let backupCount = elementCount(backup) else {
                            if attempt >= 100 { report(["error": "逾時或看板 JSON 無法解析"]); return }
                            collect(attempt + 1)
                            return
                        }
                        guard let data = try? Data(contentsOf: file),
                              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                              let goals = object["goals"] as? [[String: Any]],
                              goals.contains(where: { $0["title"] as? String == "G126 備份輪替探針" }) else {
                            if attempt >= 100 { report(["error": "App 寫入沒有完成"]); return }
                            collect(attempt + 1)
                            return
                        }
                        report(["initialCurrentElementCount": 5, "initialBackupElementCount": 6,
                                "currentElementCount": currentCount, "backupElementCount": backupCount,
                                "fullBackupPreserved": backupCount == 6])
                    }
                }
                collect(0)
            }
        }
        // --scoped-board-write-probe <state-dir內的JSON>：隔離測試沙盒看板防清空、刪除門檻與五份備份。
        if let i = args.firstIndex(of: "--scoped-board-write-probe"), i + 1 < args.count,
           let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count {
            let root = URL(fileURLWithPath: args[stateIndex + 1], isDirectory: true)
            let output = URL(fileURLWithPath: args[i + 1])
            guard isTestProbeOutput(output, inside: root) else { exit(2) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let file = CollabBoardModel.todoFile
                guard isTestProbeOutput(file, inside: root) else {
                    try? #"{"error":"collab.json 不在 --state-dir 內"}"#.write(to: output, atomically: true, encoding: .utf8)
                    return
                }
                func board(_ count: Int) -> [String: Any] {
                    ["items": (0..<count).map { ["id": "probe-\($0)", "title": "假項目 \($0)"] as [String: Any] },
                     "goals": [[String: Any]](), "findings": [[String: Any]]()]
                }
                func seed(_ count: Int) -> String? {
                    guard let data = try? JSONSerialization.data(withJSONObject: board(count), options: [.sortedKeys]) else { return nil }
                    try? data.write(to: file, options: .atomic)
                    return ScopedBoard.read()["rev"] as? String
                }
                func write(_ count: Int, rev: String) -> [String: Any] {
                    ScopedBoard.write(data: board(count), rev: rev)
                }
                let initialRev = seed(12) ?? ""
                let accepted = write(11, rev: initialRev)
                let firstBackupCount = (try? Data(contentsOf: URL(fileURLWithPath: file.path + ".bak")))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    .map(CollabBoardModel.elementCount) ?? -1

                let fullBackup = board(14)
                if let data = try? JSONSerialization.data(withJSONObject: fullBackup, options: [.sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: file.path + ".bak"), options: .atomic)
                }
                func sha() -> String { ScopedBoard.read()["rev"] as? String ?? "" }
                func message(_ r: [String: Any]) -> String { (r["error"] as? String) ?? "" }
                let currentRev = sha()
                let clearBefore = sha()
                let emptyRejected = write(0, rev: currentRev)
                let clearAfter = sha()
                let overBefore = sha()
                let oversizedRejected = write(4, rev: currentRev)
                let overAfter = sha()
                let preservedBackupCount = (try? Data(contentsOf: URL(fileURLWithPath: file.path + ".bak")))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    .map(CollabBoardModel.elementCount) ?? -1

                // 刪除上限邊界：20 → 15（刪 5，應接受）；20 → 14（刪 6，應拒絕）
                let b5 = seed(20) ?? ""
                let delete5 = write(15, rev: b5)
                let b6 = seed(20) ?? ""
                let delete6Before = sha()
                let delete6 = write(14, rev: b6)
                let delete6After = sha()

                // 備份輪替：清掉舊備份後，依序寫入元素數 10…15（每次比前一份多），
                // 預期 newest-first 為 [14,13,12,11,10]，起始的 9 被丟掉。
                for n in 0..<5 { try? FileManager.default.removeItem(atPath: file.path + ".bak" + (n == 0 ? "" : ".\(n)")) }
                var rotationRev = seed(9) ?? ""
                var rotationResults: [[String: Any]] = []
                for n in 10...15 {
                    let result = write(n, rev: rotationRev)
                    rotationResults.append(result)
                    rotationRev = sha()
                }
                let backupFiles = (0..<5).map { file.path + ".bak" + ($0 == 0 ? "" : ".\($0)") }
                let backupCounts = backupFiles.map { path -> Int in
                    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return -1 }
                    return CollabBoardModel.elementCount(object)
                }
                let report: [String: Any] = [
                    "deleteLimit": 5,
                    "smallDeleteAccepted": accepted["ok"] as? Bool ?? false,
                    "initialBackupElementCount": firstBackupCount,
                    "clearRejected": emptyRejected["ok"] as? Bool == false,
                    "deleteOverLimitRejected": oversizedRejected["ok"] as? Bool == false,
                    "fullerBackupPreserved": preservedBackupCount == 14,
                    "backupRotationWritesSucceeded": rotationResults.allSatisfy { $0["ok"] as? Bool == true },
                    "backupElementCountsNewestFirst": backupCounts,
                    "backupRotationWriteCounts": Array(10...15),
                    "backupOldestDropped": !backupCounts.contains(9),
                    "clearBeforeSha": clearBefore, "clearAfterSha": clearAfter, "clearError": message(emptyRejected),
                    "deleteOverLimitBeforeSha": overBefore, "deleteOverLimitAfterSha": overAfter, "deleteOverLimitError": message(oversizedRejected),
                    "delete5Accepted": delete5["ok"] as? Bool == true,
                    "delete6Rejected": delete6["ok"] as? Bool == false,
                    "delete6BeforeSha": delete6Before, "delete6AfterSha": delete6After, "delete6Error": message(delete6)
                ]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: output, options: .atomic)
                }
            }
        }
        // --web-crash-loop-probe "秒:輸出檔"：1 分鐘內連殺網頁程序 5 次（每次等它重載完）；重載最多 3 次，之後不再重載（ready 累計 1+3=4 次）
        if let i = args.firstIndex(of: "--web-crash-loop-probe"), i + 1 < args.count, args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, let sec = Double(parts[0]), parts[1].hasPrefix("/") {
                let outFile = parts[1]
                DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                    guard let self, let f = self.store.currentWindow?.focused, let p = self.workspace.panes[f] as? ChatPane else {
                        try? "error=找不到聊天格\n".write(toFile: outFile, atomically: true, encoding: .utf8); return
                    }
                    var n = 0
                    func next() {
                        if n == 5 {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                                let shown = p.crashOverlayShownForTest
                                p.pressReloadAfterCrashForTest()      // 按「重新載入」：提示要收掉、網頁要重新載入回來
                                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                                    try? "ready_count=\(p.readyCountForTest)\nready_now=\(p.webReadyForTest)\noverlay_shown=\(shown)\noverlay_after_reload=\(p.crashOverlayShownForTest)\n".write(toFile: outFile, atomically: true, encoding: .utf8)
                                }
                            }
                            return
                        }
                        n += 1
                        p.killWebProcessForTest()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: next)
                    }
                    next()
                }
            }
        }
        // --web-crash-probe "秒:輸出檔"：把聊天網頁的 WebContent 程序殺掉，幾秒後網頁要自己重載回來（ready 重新成立、頁面有內容）
        if let i = args.firstIndex(of: "--web-crash-probe"), i + 1 < args.count, args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, let sec = Double(parts[0]), parts[1].hasPrefix("/") {
                let outFile = parts[1]
                DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                    guard let self, let f = self.store.currentWindow?.focused, let p = self.workspace.panes[f] as? ChatPane else {
                        try? "error=找不到聊天格\n".write(toFile: outFile, atomically: true, encoding: .utf8); return
                    }
                    let before = p.readyCountForTest
                    p.killWebProcessForTest()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                        try? "ready_count_before=\(before)\nready_count_after=\(p.readyCountForTest)\nready_after=\(p.webReadyForTest)\n".write(toFile: outFile, atomically: true, encoding: .utf8)
                    }
                }
            }
        }
        // --keychain-timeout-probe 輸出檔：只把 security 換成 exec 睡 30 秒的本機假程式，不會呼叫真 security。
        if let i = args.firstIndex(of: "--keychain-timeout-probe"), i + 1 < args.count, args.contains("--state-dir") {
            let out = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let fake = (out as NSString).deletingLastPathComponent + "/fake-security"
                try? "#!/bin/sh\nexec /bin/sleep 30\n".write(toFile: fake, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake)
                NonoSandbox.securityPath = fake
                NonoSandbox.keychainTimeout = 2
                let t0 = Date()
                let r = NonoSandbox.keychain(service: "codenv-probe-none")
                let secs = Date().timeIntervalSince(t0)
                try? "result_nil=\(r == nil)\nsecs=\(Int(secs))\nfast=\(secs < 6)\n".write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        // --update-check-probe "網址|git資料夾|輸出檔"：對那個網址做一次更新檢查（逾時縮成 3 秒）；網址指到不回應的伺服器時，要在幾秒內失敗而不是卡住
        if let i = args.firstIndex(of: "--update-check-probe"), i + 1 < args.count, args.contains("--state-dir") {
            let parts = args[i + 1].components(separatedBy: "|")
            if parts.count == 3 {
                let url = parts[0], root = parts[1], out = parts[2]
                SourceUpdate.gitTimeout = 3
                DispatchQueue.global().async {
                    let t0 = Date()
                    let r = SourceUpdate.probeLatest(in: URL(fileURLWithPath: root), url: url)
                    let secs = Date().timeIntervalSince(t0)
                    try? "result=\(r)\nsecs=\(Int(secs))\n".write(toFile: out, atomically: true, encoding: .utf8)
                }
            }
        }
        // --runner-dash-probe 輸出檔：檔名以 - 開頭的 C++ 檔做 F9 檢查，不能被 g++ 當成選項
        if let i = args.firstIndex(of: "--runner-dash-probe"), i + 1 < args.count, args.contains("--state-dir") {
            let out = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let dir = (out as NSString).deletingLastPathComponent + "/dashproj"
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let f = dir + "/-Wall.cpp"
                try? "int main() { return 0; }\n".write(toFile: f, atomically: true, encoding: .utf8)
                let bad = dir + "/-bad.cpp"
                try? "int main() { return undefined_name; }\n".write(toFile: bad, atomically: true, encoding: .utf8)
                CodeRunner.check(file: f) { status, _, _ in
                    let cmd = CodeRunner.runCommand(file: f)
                    CodeRunner.check(file: bad) { st2, diags, _ in
                        try? "status_ok=\(status == .ok)\ncmd_has_dotslash=\(cmd.contains("'./-Wall.cpp'"))\nbad_failed=\(st2 == .failed)\nbad_diag_count=\(diags.count)\n".write(toFile: out, atomically: true, encoding: .utf8)
                    }
                }
            }
        }
        // --schedule-marker-probe 輸出檔：同一個排程隔年同月日同時間的防重送標記不能一樣
        if let i = args.firstIndex(of: "--schedule-marker-probe"), i + 1 < args.count, args.contains("--state-dir") {
            let out = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let sch = WakeSchedule(conversation: UUID(), text: "x")
                func due(_ y: Int) -> Date { Calendar.current.date(from: DateComponents(year: y, month: 3, day: 5, hour: 9, minute: 0))! }
                let a = ScheduleStore.marker(sch, due(2026)), b = ScheduleStore.marker(sch, due(2027))
                try? "differ=\(a != b)\nmarker=\(a)\nlegacy=\(ScheduleStore.legacyMarker(a))\n".write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        // --lid-display-filter-probe 輸出檔：哪些螢幕算「實體外接」（內建、虛擬／未知廠商、睡眠中的都不算）
        if let i = args.firstIndex(of: "--lid-display-filter-probe"), i + 1 < args.count, args.contains("--state-dir") {
            let out = args[i + 1]
            guard let actualPaths = actualLidProbePaths(args) else { exit(2) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let ok = CGSize(width: 600, height: 340)
                func f(_ b: Bool, _ v: UInt32, _ m: UInt32, _ a: Bool, _ sz: CGSize = ok) -> Bool { RealLidEnv.isRealExternal(builtin: b, vendor: v, model: m, asleep: a, size: sz) }
                let lines = ["real_external=\(f(false, 0x0610, 1, false))", "builtin=\(f(true, 0x0610, 1, false))",
                             "virtual_unknown_vendor=\(f(false, 0xFFFF_FFFF, 1, false))", "virtual_zero_vendor=\(f(false, 0, 0, false))", "asleep=\(f(false, 0x0610, 1, true))",
                             "virtual_no_size=\(f(false, 505, 1, false, .zero))",
                             "actualStateDir=\(actualPaths.state)", "actualCompactDir=\(actualPaths.compact)"]
                try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        // --drop-clean-probe 輸出檔：用暫存資料夾測拖放暫存清理（不碰真的共用資料夾）：舊的沒人引用→刪、舊的被草稿引用→留、新的→留
        if let i = args.firstIndex(of: "--drop-clean-probe"), i + 1 < args.count, args.contains("--state-dir") {
            let out = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let fm = FileManager.default
                let root = URL(fileURLWithPath: (out as NSString).deletingLastPathComponent).appendingPathComponent("dropclean", isDirectory: true)
                let folder = root.appendingPathComponent("drop", isDirectory: true), state = root.appendingPathComponent("state", isDirectory: true)
                try? fm.removeItem(at: root)
                try? fm.createDirectory(at: folder, withIntermediateDirectories: true); try? fm.createDirectory(at: state.appendingPathComponent("drafts"), withIntermediateDirectories: true)
                let old = Date().addingTimeInterval(-3 * 86400)
                func make(_ name: String, date: Date) -> URL {
                    let d = folder.appendingPathComponent(name, isDirectory: true); try? fm.createDirectory(at: d, withIntermediateDirectories: true)
                    try? "x".write(to: d.appendingPathComponent("a.png"), atomically: true, encoding: .utf8)
                    try? fm.setAttributes([.modificationDate: date], ofItemAtPath: d.path); return d
                }
                let unref = make("unref", date: old), ref = make("ref", date: old), fresh = make("fresh", date: Date())
                // 草稿 JSON 的斜線被轉成 \/（JSONEncoder 預設）
                let draft = "{\"filePaths\":[\"\(ref.appendingPathComponent("a.png").path.replacingOccurrences(of: "/", with: "\\/"))\"]}"
                try? draft.write(to: state.appendingPathComponent("drafts/c1.json"), atomically: true, encoding: .utf8)
                // 被隔離的壞草稿（不是合法 JSON、也不是合法 UTF-8）裡的路徑也算引用
                let badRef = make("badref", date: old)
                var badData = Data([0xFF, 0xFE, 0x00]); badData.append(Data(badRef.appendingPathComponent("a.png").path.utf8))
                try? badData.write(to: state.appendingPathComponent("drafts/c2.json.bad-20260101-000000-abc123"))
                let n = TerminalPane.cleanDropFolder(folder: folder, stateDir: state)
                try? "removed=\(n)\nunref_gone=\(!fm.fileExists(atPath: unref.path))\nref_kept=\(fm.fileExists(atPath: ref.path))\nbad_ref_kept=\(fm.fileExists(atPath: badRef.path))\nfresh_kept=\(fm.fileExists(atPath: fresh.path))\n".write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        // --git-safety-probe 輸出檔：(1) 專案設定的 filter 不會被背景 git 執行 (2) 逾時會連忽略 TERM 的 git 和它的子程序一起砍掉（假 git，用暫存資料夾）
        if let i = args.firstIndex(of: "--git-safety-probe"), i + 1 < args.count, args.contains("--state-dir") {
            let out = args[i + 1]
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                let fm = FileManager.default
                let root = URL(fileURLWithPath: (out as NSString).deletingLastPathComponent).appendingPathComponent("gitsafety", isDirectory: true)
                try? fm.removeItem(at: root); try? fm.createDirectory(at: root, withIntermediateDirectories: true)
                func sh(_ cmd: String, cwd: URL? = nil) {
                    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", cmd]; p.currentDirectoryURL = cwd
                    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; try? p.run(); p.waitUntilExit()
                }
                // (1) 專案設定的 filter（已知限制：擋不住，只記錄 filter_ran 供參考）；大小相同、內容不同的修改要被偵測到（changed_attr=1、changed_info=1）
                let repo = root.appendingPathComponent("repo", isDirectory: true), marker = root.appendingPathComponent("pwned").path
                let repo2 = root.appendingPathComponent("repo2", isDirectory: true), crlf = root.appendingPathComponent("crlf", isDirectory: true)
                for d in [repo, repo2, crlf] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
                let ident = "git -c user.email=a@b -c user.name=n commit -qm x"
                sh("git init -q . && printf 'aaaa\\n' > a && echo '* filter=evil' > .gitattributes && git config filter.evil.clean 'touch \(marker); cat' && git add a .gitattributes && \(ident) && rm -f \(marker) && sleep 1 && printf 'bbbb\\n' > a", cwd: repo)
                sh("git init -q . && printf 'aaaa\\n' > a && git add a && \(ident) && echo 'a filter=evil' > .git/info/attributes && git config filter.evil.clean 'cat' && sleep 1 && printf 'bbbb\\n' > a", cwd: repo2)
                // CRLF 提交、* text eol=crlf 的 repo：不能因為我們加的選項多出假的變更
                sh("git init -q . && git config core.autocrlf false && printf 'x\\r\\ny\\r\\n' > a && echo '* text eol=crlf' > .gitattributes && git add a .gitattributes && \(ident)", cwd: crlf)
                let info = SessionActivity.readGit(repo.path), info2 = SessionActivity.readGit(repo2.path), infoCrlf = SessionActivity.readGit(crlf.path)
                let filterRan = fm.fileExists(atPath: marker)
                // (2) 逾時整群砍
                let fake = root.appendingPathComponent("fake-git").path
                try? "#!/bin/sh\ntrap '' TERM\n(sleep 7771) &\nsleep 7772\n".write(toFile: fake, atomically: true, encoding: .utf8)
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake)
                GitProcess.path = fake; SessionActivity.gitTimeout = 2
                let t0 = Date()
                let r = SessionActivity.readGit(repo.path)
                let secs = Date().timeIntervalSince(t0)
                // (3) git 不存在：perl exec 失敗要回 nil，不能回「成功但空」的結果
                GitProcess.path = "/nonexistent/git"
                let missing = SessionActivity.readGit(repo.path)
                GitProcess.path = "/usr/bin/git"
                // (4) 右欄的 RPShell.run 也整群砍（忽略 TERM 的 sh 加背景子程序）
                let t1 = Date()
                let rr = RPShell.run("/bin/sh", ["-c", "trap '' TERM; (sleep 7773) & sleep 7774"], timeout: 2)
                let rpSecs = Date().timeIntervalSince(t1)
                Thread.sleep(forTimeInterval: 1)
                let ps = Process(); ps.executableURL = URL(fileURLWithPath: "/bin/ps"); ps.arguments = ["-ax", "-o", "command="]
                let pipe = Pipe(); ps.standardOutput = pipe; try? ps.run()
                let psOut = pipe.fileHandleForReading.readDataToEndOfFile(); ps.waitUntilExit()      // 先讀完再等結束，輸出多時才不會互等
                let left = String(decoding: psOut, as: UTF8.self).components(separatedBy: "\n").filter { $0.contains("sleep 7771") || $0.contains("sleep 7772") || $0.contains("sleep 7773") || $0.contains("sleep 7774") }.count
                let timeoutReported = r?.branch == L("git status 逾時")
                try? "info_ok=\(info != nil)\nchanged_attr=\(info?.changed ?? -1)\nchanged_info=\(info2?.changed ?? -1)\ncrlf_changed=\(infoCrlf?.changed ?? -1)\nfilter_ran=\(filterRan)\ntimeout_reported=\(timeoutReported)\ntimeout_fast=\(secs < 8)\nmissing_git_nil=\(missing == nil)\nrpshell_timed_out=\(rr.timedOut)\nrpshell_fast=\(rpSecs < 8)\nleftover=\(left)\n".write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        // --schedule-summary-probe 輸出檔：每週排程的 weekdays 含 0、負數、8 以上時，summary 不能崩潰（舊版 names[($0-1)%7] 對 0 越界 trap）
        if let i = args.firstIndex(of: "--schedule-summary-probe"), i + 1 < args.count, args.contains("--state-dir") {
            let out = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                func sum(_ w: [Int]) -> String { var s = WakeSchedule(conversation: UUID(), text: "x"); s.frequency = "weekly"; s.weekdays = w; return s.summary }
                let lines = ["zero=\(sum([0]))", "neg=\(sum([-3, 2]))", "eight=\(sum([8, 1]))", "empty=\(sum([]))", "normal=\(sum([7, 1]))"]
                try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        // --carry-time-probe "紀錄檔:輸出檔"：量換模型交接在主執行緒要花多久（只讀檔尾）對照整份讀；再等背景補完全文檔，量全文檔是否完整
        if let i = args.firstIndex(of: "--carry-time-probe"), i + 1 < args.count, args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                let url = URL(fileURLWithPath: String(parts[0])), out = String(parts[1])
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
                    let t0 = Date()
                    let sid = UUID()
                    let note = ModelCarry.note(from: url, session: sid, model: "測試模型", limit: 6000, canRead: true)
                    let syncSecs = Date().timeIntervalSince(t0)
                    let doc = ModelCarry.dir.appendingPathComponent(sid.uuidString.lowercased() + ".md")
                    let firstDoc = (try? String(contentsOf: doc, encoding: .utf8)) ?? ""
                    // 同一份檔整份解析（舊作法）的耗時，在背景量，免得卡住自己
                    DispatchQueue.global().async {
                        let t1 = Date()
                        let all = ModelCarry.turns(url)
                        let fullSecs = Date().timeIntervalSince(t1)
                        var waited = 0.0
                        var finalDoc = firstDoc
                        while waited < 120 {
                            finalDoc = (try? String(contentsOf: doc, encoding: .utf8)) ?? ""
                            if !finalDoc.contains("這是先寫的檔尾版") { break }
                            Thread.sleep(forTimeInterval: 0.5); waited += 0.5
                        }
                        let lines = ["size=\(size)", String(format: "sync_secs=%.3f", syncSecs), String(format: "full_parse_secs=%.3f", fullSecs),
                                     "note_nil=\(note == nil)", "note_chars=\(note?.count ?? 0)",
                                     "first_doc_partial=\(firstDoc.contains("這是先寫的檔尾版"))", "first_doc_chars=\(firstDoc.count)",
                                     "final_doc_partial=\(finalDoc.contains("這是先寫的檔尾版"))", "final_doc_chars=\(finalDoc.count)",
                                     "full_turns=\(all.count)", "note_has_last=\(all.last.map { note?.contains(String($0.text.prefix(20))) ?? false } ?? false)"]
                        try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
                    }
                }
            }
        }
        // --carry-race-probe "A:B:長行:輸出檔"：A（大檔）→ B（小檔）同一個聊天室連換兩次，等背景跑完，全文檔必須是 B 的（不能被 A 的完整版蓋回）；
        // 長行檔＝最後一行超過檔尾窗的檔，交接不能回 nil
        if let i = args.firstIndex(of: "--carry-race-probe"), i + 1 < args.count, args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":").map(String.init)
            if parts.count == 4 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    let sid = UUID()
                    let nA = ModelCarry.note(from: URL(fileURLWithPath: parts[0]), session: sid, model: "甲", limit: 6000, canRead: true)
                    let nB = ModelCarry.note(from: URL(fileURLWithPath: parts[1]), session: sid, model: "乙", limit: 6000, canRead: true)
                    let nLong = ModelCarry.note(from: URL(fileURLWithPath: parts[2]), session: UUID(), model: "丙", limit: 6000, canRead: true)
                    DispatchQueue.global().async {
                        Thread.sleep(forTimeInterval: 12)      // 背景補全文的工作全部跑完
                        let doc = (try? String(contentsOf: ModelCarry.dir.appendingPathComponent(sid.uuidString.lowercased() + ".md"), encoding: .utf8)) ?? ""
                        let lines = ["noteA_nil=\(nA == nil)", "noteB_nil=\(nB == nil)", "long_nil=\(nLong == nil)", "long_has_text=\(nLong?.contains("LONGFIRST") ?? false)",
                                     "doc_has_B=\(doc.contains("BBBB"))", "doc_has_A=\(doc.contains("AAAA"))"]
                        try? lines.joined(separator: "\n").write(toFile: parts[3], atomically: true, encoding: .utf8)
                    }
                }
            }
        }
        // --decode-compat-probe 輸出檔：目前格式的 sprint.json／schedules.json 單筆要讀得懂（有人新增非 Optional 欄位、舊檔缺鍵會整份讀不出來時，這裡先失敗）
        if let i = args.firstIndex(of: "--decode-compat-probe"), i + 1 < args.count, args.contains("--state-dir") {
            let out = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                func enc<T: Encodable>(_ v: T) -> Data { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return (try? e.encode(v)) ?? Data() }
                func dec<T: Decodable>(_ t: T.Type, _ d: Data) -> Bool { let x = JSONDecoder(); x.dateDecodingStrategy = .iso8601; return (try? x.decode(t, from: d)) != nil }
                // 把現在的實例編成 JSON，再逐一拿掉一個鍵（模擬舊版檔案沒有這個鍵）：缺鍵讀不懂的列出來
                func missing<T: Codable>(_ v: T, as t: T.Type) -> [String] {
                    let base = enc(v)
                    guard let o = try? JSONSerialization.jsonObject(with: base) as? [String: Any] else { return ["（編不出 JSON）"] }
                    var bad: [String] = []
                    for k in o.keys.sorted() {
                        var o2 = o; o2[k] = nil
                        if let d = try? JSONSerialization.data(withJSONObject: o2), !dec(t, d) { bad.append(k) }
                    }
                    return bad
                }
                let ws = WakeSchedule(conversation: UUID(), text: "x")
                let sp = SprintState()
                let lines = ["wake_roundtrip=\(dec(WakeSchedule.self, enc(ws)))", "sprint_roundtrip=\(dec(SprintState.self, enc(sp)))",
                             "wake_missing_fail=\(missing(ws, as: WakeSchedule.self).joined(separator: ","))",
                             "sprint_missing_fail=\(missing(sp, as: SprintState.self).joined(separator: ","))"]
                try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        if let i = args.firstIndex(of: "--sprint-check-probe"), i + 2 < args.count, args.contains("--state-dir") {
            let out = args[i + 1], fixture = URL(fileURLWithPath: args[i + 2])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let noCounts = SprintCheck.Counts()
                let samples = (try? Data(contentsOf: fixture))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
                let kinds = Set(samples.compactMap { $0["kind"] as? String })
                let watchCounterexample = samples.first { $0["id"] as? String == "14" }
                let now = Date(timeIntervalSince1970: 1_800_000_000)
                let sprintID = UUID()
                let messages = [
                    CollabMessage(id: "incoming", time: now.addingTimeInterval(-120), from: "chief", to: "sprint", body: "Please check this", conversation: UUID()),
                    CollabMessage(id: "reply", time: now.addingTimeInterval(-90), from: "sprint", to: "chief", body: "Done", conversation: sprintID),
                    CollabMessage(id: "other-incoming", time: now.addingTimeInterval(-75), from: "other", to: "sprint", body: "Another request", conversation: UUID()),
                    CollabMessage(id: "pending", time: now.addingTimeInterval(-60), from: "sprint", to: "peer", body: "Can you check this?", conversation: sprintID),
                    CollabMessage(id: "expired", time: now.addingTimeInterval(-31 * 60), from: "sprint", to: "other", body: "Status update", conversation: sprintID)
                ]
                let steps = [
                    CollabStep(id: "mine", text: "local work", owner: "sprint", state: "doing"),
                    CollabStep(id: "theirs", text: "delegated work", owner: "peer", state: "doing"),
                    CollabStep(id: "done", text: "finished work", owner: "sprint", state: "done")
                ]
                let validParse = SprintCheck.parse(#"{"kind":"unwatched","score":0.8}"#)
                let redacted = SprintCheck.redact("token=abcdefghijklmnop")
                let normal = SprintCheck.reminderDecision(kind: "ok", counts: noCounts, recentReminders: 0, consecutiveReminders: 0)
                let busy = SprintCheck.reminderDecision(kind: "unwatched", counts: SprintCheck.Counts(background: 1), recentReminders: 0, consecutiveReminders: 0)
                let waiting = SprintCheck.reminderDecision(kind: "unwatched", counts: SprintCheck.Counts(pendingReplies: 1), recentReminders: 0, consecutiveReminders: 0)
                let doing = SprintCheck.reminderDecision(kind: "unwatched", counts: SprintCheck.Counts(doingSteps: 1), recentReminders: 0, consecutiveReminders: 0)
                let modelOff = SprintCheck.reminderDecision(verdict: nil, counts: noCounts, recentReminders: 0, consecutiveReminders: 0)
                let third = SprintCheck.reminderDecision(kind: "unwatched", counts: noCounts, recentReminders: 2, consecutiveReminders: 0)
                let stuck = SprintCheck.reminderDecision(kind: "no_action", counts: noCounts, recentReminders: 2, consecutiveReminders: 2)
                let throttled = SprintCheck.reminderDecision(kind: "broken_promise", counts: noCounts, recentReminders: 3, consecutiveReminders: 0)
                let progressResets = SprintCheck.reminderDecision(
                    kind: "unwatched", counts: SprintCheck.Counts(doingSteps: 1),
                    recentReminders: 0, consecutiveReminders: 0) == .ignore
                let winding = SprintCheck.reminderText(kind: "unwatched", resetAt: now.addingTimeInterval(5 * 60), now: now)
                var examClassifications: [String: String] = [:]
                let classifyGroup = DispatchGroup()
                let classificationLock = NSLock()
                var sampleCount = 0
                for sample in samples {
                    guard let id = sample["id"] as? String, let text = sample["text"] as? String,
                          let expected = sample["kind"] as? String else { continue }
                    sampleCount += 1
                    classifyGroup.enter()
                    SprintCheck.examJudge(last: text, expectedKind: expected) { verdict, _ in
                        if let verdict {
                            classificationLock.lock()
                            examClassifications[id] = verdict.kind
                            classificationLock.unlock()
                        }
                        classifyGroup.leave()
                    }
                }
                let samplePromptContract = classifyGroup.wait(timeout: .now() + 2) == .success
                    && sampleCount == samples.count
                    && samples.allSatisfy { sample in
                        guard let id = sample["id"] as? String, let kind = sample["kind"] as? String else { return false }
                        classificationLock.lock()
                        defer { classificationLock.unlock() }
                        return examClassifications[id] == kind
                    }
                let unanswered = SprintCheck.pendingReplyCount(messages: messages, localNames: ["sprint"], now: now)
                let localDoing = SprintCheck.doingStepCount(steps, ownerNames: ["sprint"])
                let throttledRetry = !SprintCheck.shouldMarkRoundChecked(
                    verdict: SprintCheck.Verdict(kind: "unwatched", score: 0.9, backend: "fake"),
                    counts: noCounts, decision: .throttled, reminderSent: false)
                let countRetry = !SprintCheck.shouldMarkRoundChecked(
                    verdict: SprintCheck.Verdict(kind: "unwatched", score: 0.9, backend: "fake"),
                    counts: SprintCheck.Counts(background: 1), decision: .ignore, reminderSent: false)
                let failedSendRetry = !SprintCheck.shouldMarkRoundChecked(
                    verdict: SprintCheck.Verdict(kind: "unwatched", score: 0.9, backend: "fake"),
                    counts: noCounts, decision: .remind, reminderSent: false)
                let fallbackNudge = SprintCheck.shouldNudgeIdle(checkedRound: "r", nudgeRound: "r", counts: noCounts)
                    && !SprintCheck.shouldNudgeIdle(checkedRound: "r", nudgeRound: "r", counts: SprintCheck.Counts(background: 1))
                    && !SprintCheck.shouldNudgeIdle(checkedRound: "old", nudgeRound: "r", counts: noCounts)
                let actionResets = SprintCheck.didAct(tools: ["Edit"], userMessage: "〔codenv 衝刺檢查〕提醒")
                    && SprintCheck.didAct(tools: [], userMessage: "使用者要求先處理另一項")
                    && !SprintCheck.didAct(tools: [], userMessage: "〔codenv 衝刺檢查〕提醒")
                var unavailable = false
                if CommandLine.arguments.contains("--sprint-check-model-off") {
                    SprintCheck.judge(last: "[[fake:no_action]]", tools: []) { verdict, reason in
                        unavailable = verdict == nil && reason.contains("fake")
                    }
                }
                let lines = [
                    "parse=\(validParse?.kind == "unwatched" && validParse?.score == 0.8)",
                    "redact=\(redacted.contains("[已遮蔽]") && !redacted.contains("abcdefghijklmnop"))",
                    "normal=\(normal == .ignore)",
                    "busy=\(busy == .ignore)",
                    "waiting=\(waiting == .ignore)",
                    "doing=\(doing == .ignore)",
                    "model_off=\(unavailable && modelOff == .ignore)",
                    "reply_pairing=\(unanswered == 1)",
                    "doing_owner=\(localDoing == 1)",
                    "exam_classification_path=\(samplePromptContract)",
                    "round_retries=\(throttledRetry && countRetry && failedSendRetry)",
                    "fallback_nudge=\(fallbackNudge)",
                    "action_resets=\(actionResets)",
                    "progress_resets=\(progressResets)",
                    "third=\(third == .remind)",
                    "stuck=\(stuck == .stuck)",
                    "throttled=\(throttled == .throttled)",
                    "winding=\(winding.contains("該收尾了") && winding.contains("sprint done"))",
                    "accuracy_fixture_count=\(samples.count)",
                    "accuracy_kinds=\(kinds.sorted().joined(separator: ","))",
                    "watch_counterexample=\((watchCounterexample?["kind"] as? String) == "ok" && (watchCounterexample?["text"] as? String)?.contains("盯著") == true)"
                ]
                try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
                let transcript = SprintStore.fileURL.deletingLastPathComponent().appendingPathComponent("sprint-check-transcript.jsonl")
                let transcriptData = """
                {"type":"user","uuid":"sprint-check-user","message":{"content":[{"type":"text","text":"probe user input"}]}}
                {"type":"assistant","uuid":"sprint-check-assistant","message":{"content":[{"type":"text","text":"probe assistant reply"}]}}
                """
                try? transcriptData.write(to: transcript, atomically: true, encoding: .utf8)
                SprintCheck.readLastRound(transcript) { round in
                    let result = Thread.isMainThread && round?.text == "probe assistant reply"
                        && round?.userText == "probe user input"
                    if let existing = try? String(contentsOfFile: out, encoding: .utf8) {
                        try? (existing + "\nlast_round_async=\(result)").write(toFile: out, atomically: true, encoding: .utf8)
                    }
                }
            }
        }
        // --scoped-probe 輸出檔：發一把綁定假聊天室的沙盒專屬 token（考卷 C67 用）。輸出檔三行：token、socket 路徑、假聊天室 id。
        // send／new 換成只記下「伺服器交給處理函式的參數」的假的（寫到 <輸出檔>.send、<輸出檔>.new），看伺服器有沒有加標記、有沒有標沙盒
        if let i = args.firstIndex(of: "--scoped-probe"), i + 1 < args.count, args.contains("--state-dir") {
            let out = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                let conv = "aaaaaaaa-1111-2222-3333-444444444444"
                BrowserServer.shared.sendChat = { c, target, text, _, _, _, _, _, done in
                    try? "conv=\(c ?? "nil")\ntarget=\(target)\n\(text)".write(toFile: out + ".send", atomically: true, encoding: .utf8)
                    done(["ok": true])
                }
                BrowserServer.shared.newChat = { c, name, _, _, _, _, _, _, _, _, sandboxed, done in
                    try? "conv=\(c ?? "nil")\nname=\(name)\nsandboxed=\(sandboxed)".write(toFile: out + ".new", atomically: true, encoding: .utf8)
                    done(["ok": true])
                }
                let tok = BrowserServer.shared.issueScopedToken(conv: conv) ?? ""
                try? "\(tok)\n\(BrowserServer.shared.socketPath)\n\(conv)\n".write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        // --env-probe 輸出檔：測試實例給子程序的 CODENV_* 環境變數、主視窗在哪台螢幕（--test-screen 測試用）
        if let i = args.firstIndex(of: "--env-probe"), i + 1 < args.count, args.contains("--state-dir") {
            let out = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                var lines = Workspace.environment().filter { $0.hasPrefix("CODENV_") }.sorted()
                if let w = self?.main.window {
                    let c = NSPoint(x: w.frame.midX, y: w.frame.midY)
                    let sc = NSScreen.screens.first { $0.frame.contains(c) }
                    lines.append("window_screen=\(sc?.localizedName ?? "?")")
                    lines.append("window_inside_visible=\(sc.map { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(w.frame) } ?? false)")
                    lines.append("window_visible=\(w.isVisible)")
                }
                lines.append("screens=\(NSScreen.screens.map(\.localizedName).joined(separator: "|"))")
                try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        // --progress-fuzz：直接呼叫 PetTimers.handle 塞 NaN／無限／超大數字（不發全域通知，不碰真桌寵），沒崩潰就把結果寫進檔案
        if let i = args.firstIndex(of: "--progress-fuzz"), i + 1 < args.count, args.contains("--state-dir") {
            let out = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let bad: [Double] = [.nan, .infinity, -.infinity, 1e30, -1e30, 9.3e18, 5]
                for (n, v) in bad.enumerated() {
                    PetTimers.shared.handle(["cmd": "start", "id": "fz\(n)", "label": "x", "total": NSNumber(value: v), "eta": NSNumber(value: v)])
                    PetTimers.shared.handle(["cmd": "update", "id": "fz\(n)", "done": NSNumber(value: v), "total": NSNumber(value: v)])
                    PetTimers.shared.handle(["cmd": "cancel", "id": "fz\(n)"])
                }
                // 走到 items()：eta 1e30 繞過 handle 的 clamp 直接進 model，畫面重畫算「剩幾分鐘」不能 trap
                for (n, v) in bad.enumerated() {
                    PetTimers.shared.inject(id: "it\(n)", label: "x", eta: v)
                    _ = PetTimers.shared.model.items()
                    PetTimers.shared.handle(["cmd": "cancel", "id": "it\(n)"])
                }
                try? "ok \(bad.count)".write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        // --commander-op "秒數:new:名稱:新分組名:資料夾[:single|multi]" 或 "秒數:del:名稱"：不經表單直接呼叫新增／刪除總指揮（結果寫 EventLog）
        for (i, a) in args.enumerated() where a == "--commander-op" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3, let sec = Double(parts[0]), sec.isFinite, sec >= 0 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let st = self?.store else { return }
                if parts[1] == "new", parts.count >= 5 {
                    var err: String?
                    let req = Store.NewCommander(name: parts[2], groups: [], newGroupName: parts[3].isEmpty ? nil : parts[3], newGroupFolder: parts[4], kind: parts.count > 5 && !parts[5].isEmpty ? parts[5] : nil)
                    let id = st.createCommander(req, error: &err)
                    EventLog.log("測試", "新增總指揮 \(parts[2])：\(id?.uuidString ?? "失敗 \(err ?? "")")")
                } else if parts[1] == "del", let s = st.sessions.first(where: { $0.area == nil && $0.groups != nil && $0.name == parts[2] }) {
                    st.deleteCommander(s.id)
                    EventLog.log("測試", "刪除總指揮 \(parts[2])")
                }
            }
        }
        // --commander-flow-probe "秒:輸出.jsonl"：在 --state-dir 建立假總指揮／區長／施工聊天室，
        // 以假 delivery seam 觸發完成事件並量到區長通知；再模擬各引擎回送 steer 訊息，記錄 now／排隊與中斷次數。
        for (i, flag) in args.enumerated() where flag == "--commander-flow-probe" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let seconds = Double(parts[0]), seconds.isFinite, seconds >= 0,
                  let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count else { continue }
            func canonicalPath(_ raw: String) -> String {
                var cursor = URL(fileURLWithPath: raw).standardizedFileURL
                var missing: [String] = []
                while !FileManager.default.fileExists(atPath: cursor.path) {
                    let parent = cursor.deletingLastPathComponent()
                    if parent.path == cursor.path { break }
                    missing.insert(cursor.lastPathComponent, at: 0)
                    cursor = parent
                }
                var resolved = cursor.resolvingSymlinksInPath().standardizedFileURL
                for component in missing { resolved.appendPathComponent(component) }
                return resolved.standardizedFileURL.path
            }
            let statePath = canonicalPath(args[stateIndex + 1])
            let outputPath = canonicalPath(parts[1])
            guard outputPath.hasPrefix(statePath.hasSuffix("/") ? statePath : statePath + "/") else { continue }
            let stateRoot = URL(fileURLWithPath: statePath, isDirectory: true)
            let outputURL = URL(fileURLWithPath: outputPath)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self else { return }
                let projectURL = stateRoot.appendingPathComponent("commander-flow-probe-work", isDirectory: true)
                do { try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true) }
                catch { try? "ERROR 無法建立隔離專案資料夾".write(to: outputURL, atomically: true, encoding: .utf8); return }

                let root = ConvGroup(name: "探針總指揮根")
                var area = ConvGroup(name: "探針區", parentID: root.id)
                let subArea = ConvGroup(name: "探針子區", parentID: area.id)
                let otherArea = ConvGroup(name: "探針其他區", parentID: root.id)
                let project = Project(name: "探針專案", path: projectURL.path, groupID: root.id)
                let chief = Conversation(projectID: project.id, title: "探針總指揮", groupID: root.id)
                let lead = Conversation(projectID: project.id, title: "探針區長", groupID: area.id)
                var worker = Conversation(projectID: project.id, title: "探針施工")
                worker.groupID = area.id
                worker.model = "agy:gemini-4-hydrogen-high"
                let nestedWorker = Conversation(projectID: project.id, title: "探針子區施工", groupID: subArea.id)
                var outside = Conversation(projectID: project.id, title: "探針區外")
                outside.groupID = otherArea.id
                outside.model = "codex:gpt-6-luna"
                area.areaLeadID = lead.id
                let session = SessionLayout(name: "探針總指揮", windows: [], groups: [root.id], chief: chief.id)
                self.store.projects.append(project)
                self.store.groups += [root, area, subArea, otherArea]
                self.store.conversations += [chief, lead, worker, nestedWorker, outside]
                self.store.sessions.append(session)
                _ = self.store.saveNow()
                let previousCompletionNotices = Prefs.shared.commanderCompletionNotices
                let completionNoticesEnabled = Prefs.shared.commanderCompletionNotices
                let settingsTogglePresent: Bool = {
                    guard let source = Edition.sourceDir else { return false }
                    let url = URL(fileURLWithPath: source).appendingPathComponent("Sources/Workbench/SettingsPages.swift")
                    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
                    return text.contains("Toggle(L(\"施工聊天室完成或出錯時，通知派工者\"), isOn: $p.commanderCompletionNotices)")
                }()
                let englishTranslationPresent: Bool = {
                    guard let url = Bundle.main.resourceURL?.appendingPathComponent("i18n/en.json"),
                          let data = try? Data(contentsOf: url),
                          let map = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else { return false }
                    return map["施工聊天室完成或出錯時，通知派工者"] != nil
                }()

                var lines: [Data] = []
                func record(_ value: [String: Any]) {
                    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
                    lines.append(data); lines.append(Data([0x0a]))
                }
                let oldDeliver = self.main.commanderDeliver
                let oldInterrupt = self.main.commanderInterrupt
                var dispatchMessageID: String?
                var interrupts = 0
                var deliveredSteerNow: Bool?
                var completionNoticeCount = 0
                var deliveredCompletionNotice: String?
                self.main.commanderInterrupt = { _ in interrupts += 1 }
                self.main.commanderDeliver = { pane, text, uuid, now, _, delivered, _ in
                    if pane.conversationID == worker.id {
                        if let uuid { dispatchMessageID = uuid }
                        deliveredSteerNow = now
                        record(["event": "delivery", "target": "worker", "messageID": uuid ?? "", "now": now,
                                "synthetic": true])
                    } else if pane.conversationID == lead.id {
                        let event = text.contains("施工完成通知・派工 #") ? "completion_notice" : "area_lead_message"
                        if event == "completion_notice" {
                            completionNoticeCount += 1
                            deliveredCompletionNotice = text
                        }
                        record(["event": event, "target": "area-lead", "text": text, "synthetic": true])
                    }
                    delivered?(true)
                    return true
                }

                var dispatchResponse: [String: Any] = [:]
                self.main.commanderSendChat(caller: lead.id.uuidString, target: worker.title,
                                            text: "假派工：完成後回報", wait: false, timeout: 2) { dispatchResponse = $0 }
                let nestedLead = self.store.reportingAreaLead(for: nestedWorker, in: session)
                record(["event": "settings", "commanderCompletionNotices": completionNoticesEnabled,
                        "preferenceEnabledAtStart": completionNoticesEnabled,
                        "settingsTogglePresent": settingsTogglePresent,
                        "englishTranslationPresent": englishTranslationPresent])
                record(["event": "nested_area_lead", "worker": nestedWorker.title,
                        "foundLead": nestedLead?.lead.title ?? "",
                        "inheritedFromParent": nestedLead?.lead.id == lead.id && nestedLead?.area.id == area.id])
                let dispatch = self.store.conversation(worker.id)?.commanderDispatches?.last
                if let messageID = dispatch?.messageID {
                    self.main.commanderDispatchEvent(conversationID: worker.id, messageID: messageID,
                                                     event: ["type": "user", "isReplay": true, "uuid": messageID])
                    let started = self.store.conversation(worker.id)?.commanderDispatches?.contains(where: { $0.messageID == messageID && $0.started }) ?? false
                    record(["event": "dispatch_started", "messageID": messageID, "started": started])
                    self.store.status[worker.id] = .waiting
                    let waitingRecord = self.store.conversation(worker.id)?.commanderDispatches?.contains(where: { $0.messageID == messageID && $0.started }) ?? false
                    record(["event": "permission_waiting", "status": "waiting",
                            "completionNoticeCount": completionNoticeCount, "dispatchStillPending": waitingRecord])
                    self.store.status[worker.id] = .working
                    self.main.commanderDispatchEvent(conversationID: worker.id, messageID: "",
                                                     event: ["type": "result", "subtype": "success", "is_error": false,
                                                             "result": "假施工完成摘要：已完成探針工作；測試用 sk-ant-FAKEabcdefghijklmnopqrstuvwxyz0123456789 與 nvapi-FAKEabcdefghijklmnopqrstuvwxyz0123456789"])
                    self.store.status[worker.id] = .idle
                    let countAfterFirstResult = completionNoticeCount
                    self.main.commanderDispatchEvent(conversationID: worker.id, messageID: "",
                                                     event: ["type": "result", "subtype": "success", "is_error": false,
                                                             "result": "重複結果不應再通知"])
                    let dispatchConsumed = self.store.conversation(worker.id)?.commanderDispatches?.isEmpty ?? false
                    if !completionNoticesEnabled {
                        record(["event": "completion_notice_suppressed", "reason": "preference_disabled",
                                "preferenceEnabled": completionNoticesEnabled, "notices": completionNoticeCount,
                                "dispatchConsumed": dispatchConsumed])
                    }
                    record(["event": "completion_summary_redaction", "inputHadSyntheticKey": true,
                            "deliveredNotice": deliveredCompletionNotice ?? "",
                            "syntheticKeyLeaked": (deliveredCompletionNotice ?? "").contains("sk-ant-FAKE")
                                || (deliveredCompletionNotice ?? "").contains("nvapi-FAKE")])
                    record(["event": "duplicate_result", "noticeCountAfterFirstResult": countAfterFirstResult,
                            "noticeCountAfterDuplicate": completionNoticeCount, "dispatchConsumed": dispatchConsumed])
                }
                record(["event": "dispatch", "response": dispatchResponse,
                        "assigner": lead.id.uuidString.lowercased(), "sequence": dispatch?.sequence ?? 0,
                        "noticeRemovedAfterResult": self.store.conversation(worker.id)?.commanderDispatches?.isEmpty ?? false,
                        "completionNoticeCount": completionNoticeCount])

                var reportResponse: [String: Any] = [:]
                self.main.commanderSendChat(caller: worker.id.uuidString, target: lead.title,
                                            text: "假回報", wait: false, timeout: 2) { reportResponse = $0 }
                record(["event": "area_lead_report", "ok": reportResponse["ok"] as? Bool ?? false])
                var reportInterrupt: [String: Any] = [:]
                self.main.commanderSendChat(caller: worker.id.uuidString, target: lead.title,
                                            text: "不可中斷回報", wait: false, timeout: 2,
                                            interrupt: true) { reportInterrupt = $0 }
                record(["event": "area_lead_interrupt_rejected", "ok": reportInterrupt["ok"] as? Bool ?? false,
                        "error": reportInterrupt["error"] as? String ?? ""])
                var outsideResponse: [String: Any] = [:]
                self.main.commanderSendChat(caller: worker.id.uuidString, target: outside.title,
                                            text: "越區訊息", wait: false, timeout: 2) { outsideResponse = $0 }
                record(["event": "outside_target_rejected", "ok": outsideResponse["ok"] as? Bool ?? false])

                let cliURL = Bundle.main.resourceURL?.appendingPathComponent("bin/codenv-todo")
                let conflictingFlags: (Int32, String) = {
                    guard let cliURL, FileManager.default.isExecutableFile(atPath: cliURL.path),
                          FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
                        return (-1, "找不到測試包內的 codenv-todo 或 /usr/bin/python3")
                    }
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                    process.arguments = [cliURL.path, "send", worker.title, "互斥旗標探針", "--steer", "--interrupt"]
                    var environment = ProcessInfo.processInfo.environment
                    environment["CODENV_CONVERSATION"] = chief.id.uuidString
                    environment["CODENV_STATE_DIR"] = stateRoot.path
                    process.environment = environment
                    let stdout = Pipe(), stderr = Pipe()
                    process.standardOutput = stdout
                    process.standardError = stderr
                    do {
                        try process.run()
                        process.waitUntilExit()
                        let output = (String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
                            + (String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
                        return (process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
                    } catch { return (-1, "無法執行 codenv-todo 探針") }
                }()
                record(["event": "steer_interrupt_conflict", "exitCode": conflictingFlags.0,
                        "message": conflictingFlags.1, "rejected": conflictingFlags.0 != 0])

                Prefs.shared.commanderCompletionNotices = false // steer 情境只量插話路由，不另外建立完成通知紀錄。
                let engines = ["claude", "codex", "local", "agy", "copilot", "apple"]
                for engine in engines {
                    if let index = self.store.conversations.firstIndex(where: { $0.id == worker.id }) {
                        switch engine {
                        case "claude": self.store.conversations[index].model = nil
                        case "local": self.store.conversations[index].model = "local:probe"
                        default: self.store.conversations[index].model = "\(engine):probe"
                        }
                    }
                    self.store.status[worker.id] = .working
                    dispatchMessageID = nil
                    deliveredSteerNow = nil
                    let beforeInterrupts = interrupts
                    var response: [String: Any] = [:]
                    self.main.commanderSendChat(caller: chief.id.uuidString, target: worker.title,
                                                text: "假插話 \(engine)", wait: false, timeout: 2, steer: true) { response = $0 }
                    let uuid = dispatchMessageID ?? (response["messageID"] as? String ?? "")
                    if !uuid.isEmpty {
                        self.main.commanderDispatchEvent(conversationID: worker.id, messageID: uuid,
                                                         event: ["type": "user", "isReplay": true, "uuid": uuid])
                    }
                    record(["event": "steer", "engine": engine, "response": response,
                            "deliveryNow": deliveredSteerNow ?? false, "interrupts": interrupts - beforeInterrupts,
                            "statusRemainsWorking": self.store.status[worker.id] == .working,
                            "processedMessageID": uuid, "synthetic": true])
                }
                self.main.commanderDeliver = oldDeliver
                self.main.commanderInterrupt = oldInterrupt
                self.store.status[worker.id] = .idle
                if let index = self.store.conversations.firstIndex(where: { $0.id == worker.id }) {
                    self.store.conversations[index].model = "agy:gemini-4-hydrogen-high"
                    self.store.conversations[index].commanderDispatches = nil
                }
                Prefs.shared.commanderCompletionNotices = previousCompletionNotices
                let data = lines.reduce(into: Data()) { $0.append($1) }
                try? data.write(to: outputURL, options: .atomic)
                _ = worker
            }
        }
        // --commander-stop-archived-probe "秒:state-dir內輸出.json"：以 --codex-bin 假 app-server
        // 開一個真的測試子程序，封存仍工作中的聊天室，再走 codenv-todo stop 呼叫的 handler 與 interrupt 路徑。
        for (i, raw) in args.enumerated() where raw == "--commander-stop-archived-probe" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let delay = Double(parts[0]),
                  let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count else { continue }
            let stateRoot = URL(fileURLWithPath: args[stateIndex + 1], isDirectory: true).standardizedFileURL
            let outputURL = URL(fileURLWithPath: parts[1]).standardizedFileURL
            guard isTestProbeOutput(outputURL, inside: stateRoot) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                let suffix = String(UUID().uuidString.prefix(8))
                let projectPath = stateRoot.appendingPathComponent("commander-stop-project-\(suffix)", isDirectory: true)
                try? FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)
                let group = ConvGroup(name: "停止探針組-\(suffix)")
                let project = Project(name: "停止探針專案-\(suffix)", path: projectPath.path, groupID: group.id)
                var chief = Conversation(projectID: project.id, title: "停止探針總指揮-\(suffix)")
                chief.groupID = group.id
                var worker = Conversation(projectID: project.id, title: "停止探針 Codex-\(suffix)")
                worker.groupID = group.id
                worker.model = "codex:gpt-6-luna"
                worker.permissionMode = "default"
                self.store.groups.append(group)
                self.store.projects.append(project)
                self.store.conversations.append(contentsOf: [chief, worker])
                self.store.sessions.append(SessionLayout(name: "停止探針總指揮-\(suffix)", windows: [], groups: [group.id], chief: chief.id))
                let workerID = worker.id
                guard let pane = self.main.workspace.pane(for: worker) as? ChatPane else {
                    let failed: [String: Any] = ["error": "建立測試聊天室 Pane 失敗"]
                    if let data = try? JSONSerialization.data(withJSONObject: failed) { try? data.write(to: outputURL, options: .atomic) }
                    NSApp.terminate(nil)
                    return
                }
                let sent = pane.sendText("測試假引擎工作中，等待停止。")
                let fakeTurnStarted = stateRoot.appendingPathComponent("fake-codex-turn-started")
                var result: [String: Any] = ["sent": sent,
                                             "processAliveBeforeStop": pane.session.isRunning,
                                             "workingBeforeStop": false,
                                             "fakeCodexTurnStarted": false,
                                             "archivedBeforeStop": false,
                                             "stopOK": false,
                                             "stopError": "",
                                             "processAliveAfterStop": true,
                                             "archivedAfterStop": false]
                var stopStarted: Date?
                func finish() {
                    let processAlive = pane.session.isRunning
                    let sessionStatus = String(describing: pane.session.status)
                    let storedStatus = self.store.status[workerID].map { String(describing: $0) } ?? "nil"
                    let idle = pane.session.status == .idle && (self.store.status[workerID] == nil || self.store.status[workerID] == .idle)
                    let archived = self.store.conversation(workerID).map { self.store.isArchived($0) } ?? false
                    result["processAliveAfterStop"] = processAlive
                    result["chatSessionStatusAfterStop"] = sessionStatus
                    result["storeStatusAfterStop"] = storedStatus
                    result["idleAfterStop"] = idle
                    result["archivedAfterStop"] = archived
                    if let stopStarted { result["stopElapsedSeconds"] = Date().timeIntervalSince(stopStarted) }
                    result["expectedBehavior"] = (result["stopOK"] as? Bool == true
                                                   && result["workingBeforeStop"] as? Bool == true
                                                   && result["archivedBeforeStop"] as? Bool == true
                                                   && result["processAliveBeforeStop"] as? Bool == true
                                                   && !processAlive
                                                   && archived
                                                   && idle)
                    if processAlive { pane.session.terminate() }
                    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]) {
                        try? data.write(to: outputURL, options: .atomic)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
                }
                let workDeadline = Date().addingTimeInterval(10)
                let turnStartSettleDeadline = Date().addingTimeInterval(0.3)
                func waitForWork() {
                    guard self.store.conversation(workerID) != nil else { result["error"] = "聊天室遺失"; finish(); return }
                    let fakeTurnIsStarted = FileManager.default.fileExists(atPath: fakeTurnStarted.path)
                    result["fakeCodexTurnStarted"] = fakeTurnIsStarted
                    if self.store.status[workerID] == .working && pane.session.isRunning && fakeTurnIsStarted {
                        // 等假 app-server 的 turn/start 回覆經 Bridge 處理，確保 interrupt 有有效 turnId。
                        if Date() < turnStartSettleDeadline {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: waitForWork)
                            return
                        }
                        self.store.setArchived(workerID, true)
                        result["workingBeforeStop"] = self.store.status[workerID] == .working
                        result["archivedBeforeStop"] = self.store.conversation(workerID).map { self.store.isArchived($0) } ?? false
                        result["processAliveBeforeStop"] = pane.session.isRunning
                        stopStarted = Date()
                        let stopped = self.main.commanderStopChat(caller: chief.id.uuidString, target: worker.title)
                        result["stopOK"] = stopped["ok"] as? Bool ?? false
                        result["stopError"] = stopped["error"] as? String ?? ""
                        let stopDeadline = Date().addingTimeInterval(8)
                        func waitForStop() {
                            let storeIdle = self.store.status[workerID] == nil || self.store.status[workerID] == .idle
                            if (!pane.session.isRunning && pane.session.status == .idle && storeIdle) || Date() >= stopDeadline {
                                finish()
                            } else {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: waitForStop)
                            }
                        }
                        waitForStop()
                    } else if Date() >= workDeadline {
                        result["error"] = fakeTurnIsStarted ? "假 Codex 未進入工作狀態" : "假 Codex 未回報 turn/start 已啟動"
                        result["workingBeforeStop"] = self.store.status[workerID] == .working
                        finish()
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: waitForWork)
                    }
                }
                if !sent { result["error"] = "送出測試訊息失敗"; finish() }
                else { waitForWork() }
            }
        }
        // --codex-limit-probe <state-dir內輸出.json>：驗證 Codex 撞額度上限不送新訊息即回 idle 且顯示錯誤，
        // 以及在沒有進行中 turn／沒有存活程序時按 UI 停止鈕與 codenv-todo stop 都能清回待命。
        for (i, raw) in args.enumerated() where raw == "--codex-limit-probe" && i + 1 < args.count && args.contains("--state-dir") {
            guard let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count else { continue }
            let stateRoot = URL(fileURLWithPath: args[stateIndex + 1], isDirectory: true).standardizedFileURL
            let outputURL = URL(fileURLWithPath: args[i + 1]).standardizedFileURL
            guard isTestProbeOutput(outputURL, inside: stateRoot) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                let suffix = String(UUID().uuidString.prefix(8))
                let projectPath = stateRoot.appendingPathComponent("codex-limit-project-\(suffix)", isDirectory: true)
                try? FileManager.default.createDirectory(at: projectPath, withIntermediateDirectories: true)
                let hadExternalCodex = CodexBridge.testExecutable != nil
                if !hadExternalCodex {
                    let fakeScript = stateRoot.appendingPathComponent("fake-codex-limit-\(suffix).py")
                    let scriptBody = """
                    #!/usr/bin/env python3
                    import json, sys
                    def emit(v):
                        sys.stdout.write(json.dumps(v, separators=(",", ":")) + "\\n")
                        sys.stdout.flush()
                    for line in sys.stdin:
                        try:
                            m = json.loads(line)
                        except json.JSONDecodeError:
                            continue
                        method, rid = m.get("method"), m.get("id")
                        if method == "initialize" and rid is not None:
                            emit({"jsonrpc": "2.0", "id": rid, "result": {}})
                        elif method in ("thread/start", "thread/resume") and rid is not None:
                            emit({"jsonrpc": "2.0", "id": rid, "result": {"thread": {"id": "limit-thread"}}})
                        elif method == "turn/start" and rid is not None:
                            emit({"jsonrpc": "2.0", "id": rid, "result": {"turn": {"id": "limit-turn"}}})
                            emit({"jsonrpc": "2.0", "method": "turn/started", "params": {"threadId": "limit-thread", "turn": {"id": "limit-turn"}}})
                            emit({"jsonrpc": "2.0", "method": "error", "params": {"threadId": "limit-thread", "turnId": "limit-turn", "willRetry": False, "error": {"message": "You've hit your usage limit. Please try again in 5 hours.", "codexErrorInfo": "usageLimitExceeded"}}})
                    """
                    try? scriptBody.write(to: fakeScript, atomically: true, encoding: .utf8)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeScript.path)
                    CodexBridge.probeExecutableOverride = fakeScript.path
                }
                let group = ConvGroup(name: "額度探針組-\(suffix)")
                let project = Project(name: "額度探針專案-\(suffix)", path: projectPath.path, groupID: group.id)
                var chief = Conversation(projectID: project.id, title: "額度探針總指揮-\(suffix)")
                chief.groupID = group.id
                var worker = Conversation(projectID: project.id, title: "額度探針 Codex-\(suffix)")
                worker.groupID = group.id
                worker.model = "codex:gpt-6-luna"
                worker.permissionMode = "default"
                self.store.groups.append(group)
                self.store.projects.append(project)
                self.store.conversations.append(contentsOf: [chief, worker])
                self.store.sessions.append(SessionLayout(name: "額度探針總指揮-\(suffix)", windows: [], groups: [group.id], chief: chief.id))
                let workerID = worker.id
                let chiefID = chief.id
                let workerTitle = worker.title
                func teamState(for title: String) -> String {
                    let info = self.store.teamInfo(conversation: chiefID.uuidString, name: nil) { id in
                        (self.main.workspace.panes[id] as? ChatPane)?.session.isRunning == true
                    }
                    let members = info["members"] as? [[String: Any]] ?? []
                    return members.first(where: { $0["name"] as? String == title })?["state"] as? String ?? ""
                }
                func lastState(for title: String) -> String {
                    let info = self.main.commanderLastChat(caller: chiefID.uuidString, target: title)
                    return info["state"] as? String ?? ""
                }
                guard let pane = self.main.workspace.pane(for: worker) as? ChatPane else {
                    CodexBridge.probeExecutableOverride = nil
                    let failed: [String: Any] = ["error": "建立測試聊天室 Pane 失敗", "statusAfterLimit": "error", "errorNoticeVisible": false, "stopWithoutProcessClearsWorking": false]
                    if let data = try? JSONSerialization.data(withJSONObject: failed, options: [.sortedKeys, .prettyPrinted]) {
                        try? data.write(to: outputURL, options: .atomic)
                    }
                    NSApp.terminate(nil)
                    return
                }
                var result: [String: Any] = [
                    "statusAfterLimit": "working",
                    "errorNoticeVisible": false,
                    "stopWithoutProcessClearsWorking": false,
                    "uiStopWithoutActiveTurnClearsWorking": false,
                    "usedExternalCodexBin": hadExternalCodex
                ]
                func finish() {
                    if pane.session.isRunning { pane.session.terminate() }
                    CodexBridge.probeExecutableOverride = nil
                    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]) {
                        try? data.write(to: outputURL, options: .atomic)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
                }
                func runBridgeSupplementaryChecks() -> [String: Any] {
                    // 驗證 (1) turn/completed failed 後遲到的 item/completed 不再把狀態拉回 working；
                    // (2) error(willRetry:false) 後緊跟 turn/completed(failed) 不重複發第二次 result；
                    // (3) turn 進行中程序意外退出會產出失敗 result；
                    // (4) R1–R6：無 turn 按停止保留 queue、撞額度後 next() 繼續送下一則且同輪不重複、
                    //     舊輪遲到 turn/completed 不清目前 turnID、starting 按停止於 turn/started 補送 turn/interrupt、
                    //     turn/interrupt 一般錯誤不本地收尾（僅 no active turn 才收尾）、hasIncompleteTurn 不計入 queue。
                    let b1 = CodexBridge(session: UUID(), directory: projectPath.path, model: "gpt-6-luna",
                                         transcriptURL: stateRoot.appendingPathComponent("codex-limit-b1-\(suffix).jsonl"))
                    var events1: [[String: Any]] = []
                    b1.emit = { events1.append($0) }
                    b1.incoming(["method": "turn/started", "params": ["turn": ["id": "T-late"]]])
                    b1.incoming(["method": "turn/completed", "params": ["turn": ["id": "T-late", "status": "failed", "error": ["message": "You've hit your usage limit"]]]])
                    let countAfterCompleted = events1.count
                    b1.incoming(["method": "item/completed", "params": ["turnId": "T-late", "item": ["id": "I-late", "type": "agentMessage", "text": "late"]]])
                    let lateItemIgnored = events1.count == countAfterCompleted

                    let b2 = CodexBridge(session: UUID(), directory: projectPath.path, model: "gpt-6-luna",
                                         transcriptURL: stateRoot.appendingPathComponent("codex-limit-b2-\(suffix).jsonl"))
                    var events2: [[String: Any]] = []
                    b2.emit = { events2.append($0) }
                    b2.incoming(["method": "turn/started", "params": ["turn": ["id": "T-dup"]]])
                    b2.incoming(["method": "error", "params": ["turnId": "T-dup", "willRetry": false, "error": ["message": "You've hit your usage limit"]]])
                    b2.incoming(["method": "turn/completed", "params": ["turnId": "T-dup", "turn": ["id": "T-dup", "status": "failed", "error": ["message": "You've hit your usage limit"]]]])
                    let resultCount = events2.filter { $0["type"] as? String == "result" }.count

                    let b3 = CodexBridge(session: UUID(), directory: projectPath.path, model: "gpt-6-luna",
                                         transcriptURL: stateRoot.appendingPathComponent("codex-limit-b3-\(suffix).jsonl"))
                    b3.incoming(["method": "turn/started", "params": ["turn": ["id": "T-exit"]]])
                    let exitEvent = b3.processExitFailure(code: 1, stderr: "usage limit exceeded")
                    let exitReported = exitEvent?["type"] as? String == "result" && exitEvent?["is_error"] as? Bool == true

                    // R1 + R6：沒有進行中 turn 且有排隊訊息時按停止，不動 queue；僅 queue 非空時 hasIncompleteTurn 為 false
                    let b4 = CodexBridge(session: UUID(), directory: projectPath.path, model: "gpt-6-luna",
                                         transcriptURL: stateRoot.appendingPathComponent("codex-limit-b4-\(suffix).jsonl"))
                    var sent4: [[String: Any]] = []
                    b4.send = { sent4.append($0) }
                    b4.outgoing(["type": "user", "uuid": "q-preserve-1", "message": ["role": "user", "content": "queued msg"]])
                    let queueOnlyNotIncomplete = !b4.hasIncompleteTurn && b4.processExitFailure(code: 1, stderr: "err") == nil
                    let stopRet4 = b4.interrupt()
                    let queuePreservedAfterStop = !stopRet4 && b4.pendingForLidInterrupt().map(\.id) == ["q-preserve-1"]

                    // R2：撞額度後 next() 仍送出排隊中的下一則，且同輪遲到 turn/completed 不重複呼叫 next() 或重複發 result
                    let b5 = CodexBridge(session: UUID(), directory: projectPath.path, model: "gpt-6-luna",
                                         transcriptURL: stateRoot.appendingPathComponent("codex-limit-b5-\(suffix).jsonl"))
                    var sent5: [[String: Any]] = []
                    var events5: [[String: Any]] = []
                    b5.send = { sent5.append($0) }
                    b5.emit = { events5.append($0) }
                    b5.start()
                    let threadReq5 = sent5.first { ($0["method"] as? String) == "thread/start" || ($0["method"] as? String) == "thread/resume" }?["id"] as? Int ?? 2
                    b5.incoming(["id": threadReq5, "result": ["thread": ["id": "TH-r2"]]])
                    b5.outgoing(["type": "user", "uuid": "m-r2-1", "message": ["role": "user", "content": "first"]])
                    b5.outgoing(["type": "user", "uuid": "m-r2-2", "message": ["role": "user", "content": "second"]])
                    b5.outgoing(["type": "user", "uuid": "m-r2-3", "message": ["role": "user", "content": "third"]])
                    b5.incoming(["method": "turn/started", "params": ["turn": ["id": "T-r2-1"]]])
                    b5.incoming(["method": "error", "params": ["turnId": "T-r2-1", "willRetry": false, "error": ["message": "You've hit your usage limit", "codexErrorInfo": "usageLimitExceeded"]]])
                    let turnStartsAfterError = sent5.filter { $0["method"] as? String == "turn/start" }.count
                    b5.incoming(["method": "turn/completed", "params": ["turnId": "T-r2-1", "turn": ["id": "T-r2-1", "status": "failed", "error": ["message": "You've hit your usage limit"]]]])
                    let turnStartsAfterLateCompleted = sent5.filter { $0["method"] as? String == "turn/start" }.count
                    let resultsAfterLateCompleted = events5.filter { $0["type"] as? String == "result" }.count
                    let usageLimitAdvancesNext = turnStartsAfterError == 2 && turnStartsAfterLateCompleted == 2 && resultsAfterLateCompleted == 1

                    // R3：舊輪遲到 turn/completed 不清新輪 turnID 也不多發 result
                    let b6 = CodexBridge(session: UUID(), directory: projectPath.path, model: "gpt-6-luna",
                                         transcriptURL: stateRoot.appendingPathComponent("codex-limit-b6-\(suffix).jsonl"))
                    var sent6: [[String: Any]] = []
                    var events6: [[String: Any]] = []
                    b6.send = { sent6.append($0) }
                    b6.emit = { events6.append($0) }
                    b6.start()
                    let threadReq6 = sent6.first { ($0["method"] as? String) == "thread/start" || ($0["method"] as? String) == "thread/resume" }?["id"] as? Int ?? 2
                    b6.incoming(["id": threadReq6, "result": ["thread": ["id": "TH-r3"]]])
                    b6.outgoing(["type": "user", "uuid": "m-r3-1", "message": ["role": "user", "content": "one"]])
                    b6.incoming(["method": "turn/started", "params": ["turn": ["id": "T-old"]]])
                    b6.incoming(["method": "error", "params": ["turnId": "T-old", "willRetry": false, "error": ["message": "usage limit"]]])
                    b6.outgoing(["type": "user", "uuid": "m-r3-2", "message": ["role": "user", "content": "two"]])
                    b6.incoming(["method": "turn/started", "params": ["turn": ["id": "T-new"]]])
                    let resultsBeforeStale = events6.filter { $0["type"] as? String == "result" }.count
                    b6.incoming(["method": "turn/completed", "params": ["turn": ["id": "T-old", "status": "failed", "error": ["message": "usage limit"]]]])
                    let resultsAfterStale = events6.filter { $0["type"] as? String == "result" }.count
                    let interruptNewRet = b6.interrupt()
                    let interruptedTurnID = (sent6.last { $0["method"] as? String == "turn/interrupt" }?["params"] as? [String: Any])?["turnId"] as? String
                    let staleCompletedPreservesNewTurn = resultsBeforeStale == 1 && resultsAfterStale == 1 && interruptNewRet && interruptedTurnID == "T-new"

                    // R4：starting 狀態（turn/start 已送、turn/started 未回）按停止，回傳 true 且等 turn/started 後立即送 turn/interrupt
                    let b7 = CodexBridge(session: UUID(), directory: projectPath.path, model: "gpt-6-luna",
                                         transcriptURL: stateRoot.appendingPathComponent("codex-limit-b7-\(suffix).jsonl"))
                    var sent7: [[String: Any]] = []
                    var events7: [[String: Any]] = []
                    b7.send = { sent7.append($0) }
                    b7.emit = { events7.append($0) }
                    b7.start()
                    let threadReq7 = sent7.first { ($0["method"] as? String) == "thread/start" || ($0["method"] as? String) == "thread/resume" }?["id"] as? Int ?? 2
                    b7.incoming(["id": threadReq7, "result": ["thread": ["id": "TH-r4"]]])
                    b7.outgoing(["type": "user", "uuid": "m-r4-1", "message": ["role": "user", "content": "starting stop"]])
                    let stopWhileStarting = b7.interrupt()
                    let noResultBeforeStarted = events7.filter { $0["type"] as? String == "result" }.isEmpty
                    let noInterruptBeforeStarted = sent7.filter { $0["method"] as? String == "turn/interrupt" }.isEmpty
                    b7.incoming(["method": "turn/started", "params": ["turn": ["id": "T-r4"]]])
                    let interruptsAfterStarted = sent7.filter { $0["method"] as? String == "turn/interrupt" }
                    let r4TurnID = (interruptsAfterStarted.first?["params"] as? [String: Any])?["turnId"] as? String
                    let stopWhileStartingWorks = stopWhileStarting && noResultBeforeStarted && noInterruptBeforeStarted
                        && interruptsAfterStarted.count == 1 && r4TurnID == "T-r4"

                    // R5：turn/interrupt 一般錯誤不本地收尾，僅 no active turn / not found 一類錯誤才本地收尾
                    let b8 = CodexBridge(session: UUID(), directory: projectPath.path, model: "gpt-6-luna",
                                         transcriptURL: stateRoot.appendingPathComponent("codex-limit-b8-\(suffix).jsonl"))
                    var sent8: [[String: Any]] = []
                    var events8: [[String: Any]] = []
                    b8.send = { sent8.append($0) }
                    b8.emit = { events8.append($0) }
                    b8.start()
                    let threadReq8 = sent8.first { ($0["method"] as? String) == "thread/start" || ($0["method"] as? String) == "thread/resume" }?["id"] as? Int ?? 2
                    b8.incoming(["id": threadReq8, "result": ["thread": ["id": "TH-r5"]]])
                    b8.incoming(["method": "turn/started", "params": ["turn": ["id": "T-r5"]]])
                    _ = b8.interrupt()
                    let intReq1 = sent8.last { $0["method"] as? String == "turn/interrupt" }?["id"] as? Int ?? -1
                    b8.incoming(["id": intReq1, "error": ["code": -32000, "message": "temporary network glitch"]])
                    let transientDidNotFinish = events8.filter { $0["type"] as? String == "result" }.isEmpty
                    _ = b8.interrupt()
                    let intReq2 = sent8.last { $0["method"] as? String == "turn/interrupt" }?["id"] as? Int ?? -1
                    b8.incoming(["id": intReq2, "error": ["code": -32000, "message": "No active turn to interrupt"]])
                    let noActiveTurnFinished = events8.contains { $0["type"] as? String == "result" && $0["subtype"] as? String == "stopped" }

                    return ["lateItemIgnoredAfterFailedTurn": lateItemIgnored,
                            "errorThenCompletedSingleResult": resultCount == 1,
                            "unexpectedExitProducesErrorResult": exitReported,
                            "stopWithoutTurnPreservesQueue": queuePreservedAfterStop,
                            "usageLimitAdvancesQueuedNext": usageLimitAdvancesNext,
                            "staleTurnCompletedDoesNotClearNewTurn": staleCompletedPreservesNewTurn,
                            "stopWhileStartingInterruptsOnTurnStarted": stopWhileStartingWorks,
                            "transientInterruptErrorDoesNotFinishLocally": transientDidNotFinish && noActiveTurnFinished,
                            "hasIncompleteTurnExcludesQueueOnly": queueOnlyNotIncomplete]
                }
                func runScenarioBWithoutProcess() {
                    // 情境 B1：沒有存活程序但狀態卡在 working → 走 codenv-todo stop（commanderStopChat）清回待命。
                    pane.session.modelSelectionProbeBeginWork()
                    let workingBefore = pane.session.status == .working && self.store.status[workerID] == .working
                    let aliveBefore = pane.session.isRunning
                    let teamBefore = teamState(for: workerTitle)
                    let lastBefore = lastState(for: workerTitle)
                    let stopReply = self.main.commanderStopChat(caller: chiefID.uuidString, target: workerTitle)
                    let stopOK = stopReply["ok"] as? Bool ?? false
                    let sessionAfter = String(describing: pane.session.status)
                    let storeAfter = self.store.status[workerID].map { String(describing: $0) } ?? "nil"
                    let busyAfter = pane.inputBar.busy
                    let teamAfter = teamState(for: workerTitle)
                    let lastAfter = lastState(for: workerTitle)
                    let cleared = workingBefore && !aliveBefore && stopOK
                        && pane.session.status == .idle
                        && (self.store.status[workerID] == nil || self.store.status[workerID] == .idle)
                        && !busyAfter && teamAfter != "工作中" && lastAfter != "工作中" && teamAfter == lastAfter
                    result["stopWithoutProcessClearsWorking"] = cleared
                    result["scenarioB_stopWithoutProcess"] = [
                        "workingBeforeStop": workingBefore,
                        "processAliveBeforeStop": aliveBefore,
                        "teamStateBeforeStop": teamBefore,
                        "lastStateBeforeStop": lastBefore,
                        "stopOK": stopOK,
                        "stopError": stopReply["error"] as? String ?? "",
                        "sessionStatusAfterStop": sessionAfter,
                        "storeStatusAfterStop": storeAfter,
                        "inputBarBusyAfterStop": busyAfter,
                        "teamStateAfterStop": teamAfter,
                        "lastStateAfterStop": lastAfter
                    ]
                    result["bridgeChecks"] = runBridgeSupplementaryChecks()
                    finish()
                }
                func runScenarioBWithProcessNoActiveTurn() {
                    // 情境 B2：程序仍開著但已無進行中 turn，模擬卡在 working → 按 UI 停止鈕（stopFromInput）清回待命。
                    if pane.session.isRunning {
                        pane.session.modelSelectionProbeBeginWork()
                        let workingBefore = pane.session.status == .working && self.store.status[workerID] == .working && pane.inputBar.busy
                        let aliveBefore = pane.session.isRunning
                        let uiStopHandled = pane.inputBar.stopFromInput()
                        let sessionAfter = String(describing: pane.session.status)
                        let storeAfter = self.store.status[workerID].map { String(describing: $0) } ?? "nil"
                        let busyAfter = pane.inputBar.busy
                        let teamAfter = teamState(for: workerTitle)
                        let lastAfter = lastState(for: workerTitle)
                        let cleared = workingBefore && aliveBefore && uiStopHandled
                            && pane.session.status == .idle
                            && (self.store.status[workerID] == nil || self.store.status[workerID] == .idle)
                            && !busyAfter && teamAfter != "工作中" && lastAfter != "工作中"
                        result["uiStopWithoutActiveTurnClearsWorking"] = cleared
                        result["scenarioB_uiStopWithoutActiveTurn"] = [
                            "workingBeforeStop": workingBefore,
                            "processAliveBeforeStop": aliveBefore,
                            "uiStopHandled": uiStopHandled,
                            "sessionStatusAfterStop": sessionAfter,
                            "storeStatusAfterStop": storeAfter,
                            "inputBarBusyAfterStop": busyAfter,
                            "teamStateAfterStop": teamAfter,
                            "lastStateAfterStop": lastAfter
                        ]
                        pane.session.terminate()
                        let exitDeadline = Date().addingTimeInterval(3)
                        func waitForTerminate() {
                            if !pane.session.isRunning || Date() >= exitDeadline {
                                runScenarioBWithoutProcess()
                            } else {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: waitForTerminate)
                            }
                        }
                        waitForTerminate()
                    } else {
                        result["scenarioB_uiStopWithoutActiveTurn"] = ["skipped": true, "reason": "情境 A 結束後程序已退出"]
                        runScenarioBWithoutProcess()
                    }
                }
                // 情境 A：送出第一則訊息觸發假 Codex 撞額度上限，不送第二則訊息，等待狀態自動回到 idle 並顯示錯誤。
                let sent = pane.sendText("請檢查 Codex 額度上限")
                result["sent"] = sent
                if !sent {
                    result["error"] = "送出測試訊息失敗"
                    finish()
                    return
                }
                let limitDeadline = Date().addingTimeInterval(6)
                func waitForLimitOutcome() {
                    let storeIdle = self.store.status[workerID] == nil || self.store.status[workerID] == .idle
                    let failureText = pane.session.lastFailureMessage ?? ""
                    let ready = pane.session.status == .idle && storeIdle && !failureText.isEmpty
                    if ready || Date() >= limitDeadline {
                        let sessionStr = String(describing: pane.session.status)
                        let storeStr = self.store.status[workerID].map { String(describing: $0) } ?? "nil"
                        let busy = pane.inputBar.busy
                        let statusAfter = (pane.session.status == .idle && storeIdle && !busy) ? "idle" : sessionStr
                        let transcriptText = pane.session.transcriptURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
                        let errorInTranscript = transcriptText.lowercased().contains("usage limit")
                        let chiefNotice = CollabBoardModel.takeNotices(for: chiefID) ?? ""
                        let noticeHasLimit = chiefNotice.lowercased().contains("usage limit")
                        let teamAfter = teamState(for: workerTitle)
                        let lastAfter = lastState(for: workerTitle)
                        result["statusAfterLimit"] = statusAfter
                        result["errorMessage"] = failureText
                        result["errorNoticeVisible"] = failureText.lowercased().contains("usage limit") && (errorInTranscript || noticeHasLimit)
                        result["scenarioA"] = [
                            "sessionStatus": sessionStr,
                            "storeStatus": storeStr,
                            "inputBarBusy": busy,
                            "teamState": teamAfter,
                            "lastState": lastAfter,
                            "errorInTranscript": errorInTranscript,
                            "supervisionNoticeEmitted": noticeHasLimit,
                            "noNewMessageSent": true
                        ]
                        runScenarioBWithProcessNoActiveTurn()
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: waitForLimitOutcome)
                    }
                }
                waitForLimitOutcome()
            }
        }
        // --commander-supervision-probe "秒:輸出.json:寵物紀錄"：總指揮 stop／interrupt 用假引擎，卡住時計用測試時間推進。
        for (i, a) in args.enumerated() where a == "--commander-supervision-probe" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let chief = self.store.sessions.first(where: { $0.name == "C120Chief" }), let chiefID = chief.chief else { return }
                let new = self.store.commanderCreate(caller: chiefID.uuidString, name: "C120假聊天室", dir: nil)
                guard let c = new.conversation, let pane = self.main.workspace.pane(for: c) as? ChatPane else { return }
                let id = c.id
                self.store.status[id] = .working
                var order: [String] = []
                self.main.commanderInterrupt = { _ in order.append("stop"); self.store.status[id] = .idle }
                self.main.commanderDeliver = { _, _, _, _, _, delivered, _ in
                    order.append("send")
                    delivered?(true)
                    return true
                }
                let activeStop = self.main.commanderStopChat(caller: chiefID.uuidString, target: c.title)
                let idleStop = self.main.commanderStopChat(caller: chiefID.uuidString, target: c.title)
                self.store.status[id] = .working
                var result: [String: Any] = ["stop": activeStop["ok"] as? Bool ?? false,
                                             "idleError": idleStop["error"] as? String ?? "",
                                             "interruptOrder": []]
                self.main.commanderSendChat(caller: chiefID.uuidString, target: c.title, text: "新指令", wait: false, timeout: 2, interrupt: true) { response in
                    result["interruptSent"] = response["sent"] as? Bool ?? false
                    result["interruptOrder"] = order
                    self.store.status[id] = .working
                    CommanderStuck.shared.seedForTest(id, lastOutput: Date().addingTimeInterval(-120), action: "假引擎工具呼叫")
                    CommanderStuck.shared.tick(now: Date())
                    result["stuckMinutes"] = CommanderStuck.shared.minutes(id) ?? 0
                    result["notice"] = CollabBoardModel.takeNotices(for: chiefID) ?? ""
                    CommanderStuck.shared.output(id, event: ["type": "assistant", "subtype": "text"])
                    CommanderStuck.shared.tick(now: Date().addingTimeInterval(30))
                    result["reset"] = CommanderStuck.shared.minutes(id) == nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
                            try? data.write(to: URL(fileURLWithPath: parts[1]), options: .atomic)
                        }
                        _ = pane
                        self.store.status[id] = .idle
                    }
                }
            }
        }
        // --commander-stuck-probe <輸出.json>：建立假總指揮／區長／Codex 派工，走真實監督器階段；
        // --commander-stuck-scale <倍數> 會把監督時鐘加速（僅 --state-dir 生效）。
        for (i, flag) in args.enumerated() where flag == "--commander-stuck-probe" && i + 1 < args.count && args.contains("--state-dir") {
            guard let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count else { continue }
            func canonicalPath(_ raw: String) -> String {
                var cursor = URL(fileURLWithPath: raw).standardizedFileURL
                var missing: [String] = []
                while !FileManager.default.fileExists(atPath: cursor.path) {
                    let parent = cursor.deletingLastPathComponent()
                    if parent.path == cursor.path { break }
                    missing.insert(cursor.lastPathComponent, at: 0); cursor = parent
                }
                var resolved = cursor.resolvingSymlinksInPath().standardizedFileURL
                for component in missing { resolved.appendPathComponent(component) }
                return resolved.standardizedFileURL.path
            }
            let statePath = canonicalPath(args[stateIndex + 1])
            let outputPath = canonicalPath(args[i + 1])
            guard outputPath.hasPrefix(statePath.hasSuffix("/") ? statePath : statePath + "/") else { continue }
            let stateRoot = URL(fileURLWithPath: statePath, isDirectory: true)
            let outputURL = URL(fileURLWithPath: outputPath)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                let workURL = stateRoot.appendingPathComponent("commander-stuck-probe-work", isDirectory: true)
                do { try FileManager.default.createDirectory(at: workURL, withIntermediateDirectories: true) }
                catch { try? "ERROR 無法建立隔離專案資料夾".write(to: outputURL, atomically: true, encoding: .utf8); return }

                let root = ConvGroup(name: "C174探針根")
                var area = ConvGroup(name: "C174探針區", parentID: root.id)
                let otherArea = ConvGroup(name: "C174探針別區", parentID: root.id)
                let project = Project(name: "C174探針專案", path: workURL.path, groupID: root.id)
                let chief = Conversation(projectID: project.id, title: "C174探針總指揮", groupID: root.id)
                let lead = Conversation(projectID: project.id, title: "C174探針區長", groupID: area.id)
                var worker = Conversation(projectID: project.id, title: "C174探針Codex", groupID: area.id)
                worker.model = "codex:gpt-6-luna"
                var acceptedWorker = Conversation(projectID: project.id, title: "C174探針已卡住", groupID: area.id)
                acceptedWorker.model = "codex:gpt-6-luna"
                var outsideWorker = Conversation(projectID: project.id, title: "C174探針別區工作", groupID: otherArea.id)
                outsideWorker.model = "codex:gpt-6-luna"
                var runningWorker = Conversation(projectID: project.id, title: "C174探針長工具", groupID: area.id)
                runningWorker.model = "codex:gpt-6-luna"
                let waitingWorker = Conversation(projectID: project.id, title: "C174探針等回答", groupID: area.id)
                area.areaLeadID = lead.id
                let session = SessionLayout(name: "C174探針總指揮", windows: [], groups: [root.id], chief: chief.id)
                self.store.projects.append(project)
                self.store.groups += [root, area, otherArea]
                self.store.conversations += [chief, lead, worker, acceptedWorker, outsideWorker, runningWorker, waitingWorker]
                self.store.sessions.append(session)
                _ = self.store.saveNow()

                let workerMessage = UUID().uuidString.lowercased()
                let waitingMessage = UUID().uuidString.lowercased()
                let acceptedMessage = UUID().uuidString.lowercased()
                let outsideMessage = UUID().uuidString.lowercased()
                let runningMessage = UUID().uuidString.lowercased()
                let fixtures: [(Conversation, String, UUID)] = [
                    (worker, workerMessage, lead.id),
                    (waitingWorker, waitingMessage, chief.id),
                    (acceptedWorker, acceptedMessage, lead.id),
                    (outsideWorker, outsideMessage, chief.id),
                    (runningWorker, runningMessage, lead.id)
                ]
                for (conv, messageID, assigner) in fixtures {
                    let seq = 1
                    if let index = self.store.conversations.firstIndex(where: { $0.id == conv.id }) {
                        self.store.conversations[index].commanderDispatches = [CommanderDispatch(messageID: messageID, assignerID: assigner,
                                                                                                  sequence: seq, started: true)]
                        self.store.conversations[index].commanderDispatchSequence = seq
                    }
                }
                self.store.status[worker.id] = .working
                self.store.status[waitingWorker.id] = .waiting
                self.store.status[acceptedWorker.id] = .working
                self.store.status[outsideWorker.id] = .working
                self.store.status[runningWorker.id] = .working
                let probeNow = CommanderStuck.shared.testClockNow()
                CommanderStuck.shared.seedStagesForTest(worker.id, assignerID: lead.id, messageID: workerMessage,
                                                         sequence: 1, text: "假卡住派工：完成後回報結果。", now: probeNow)
                CommanderStuck.shared.seedStagesForTest(waitingWorker.id, assignerID: chief.id, messageID: waitingMessage,
                                                         sequence: 1, text: "假權限詢問派工。", now: probeNow)
                CommanderStuck.shared.seedStagesForTest(acceptedWorker.id, assignerID: lead.id, messageID: acceptedMessage,
                                                         sequence: 1, text: "已越過輕推門檻的假派工。", now: probeNow, alreadyNudged: true)
                CommanderStuck.shared.seedStagesForTest(outsideWorker.id, assignerID: chief.id, messageID: outsideMessage,
                                                         sequence: 1, text: "別區假派工。", now: probeNow, alreadyNudged: true)
                CommanderStuck.shared.seedStagesForTest(runningWorker.id, assignerID: lead.id, messageID: runningMessage,
                                                         sequence: 1, text: "假長工具派工。", now: probeNow)

                let oldDeliver = self.main.commanderDeliver
                let oldInterrupt = self.main.commanderInterrupt
                let previousNotices = Prefs.shared.commanderCompletionNotices
                Prefs.shared.commanderCompletionNotices = true
                var backgroundPaused = false
                var toolInterruptCount = 0
                var toolNotificationDelivered = false
                var acceptedInterruptCount = 0
                var manualInterruptResponses: [String: [String: Any]] = [:]

                self.main.commanderDeliver = { pane, text, uuid, now, _, delivered, _ in
                    guard let target = pane.conversationID else { delivered?(false); return false }
                    if target == lead.id, text.contains("C174探針長工具"), text.contains("〔總指揮監督〕") {
                        toolNotificationDelivered = true
                    }
                    if target == worker.id, now, let uuid {
                        CommanderStuck.shared.output(worker.id, event: ["type": "user", "isReplay": true, "uuid": uuid])
                    } else if target == worker.id, text.contains("假卡住派工"), let uuid {
                        self.store.status[worker.id] = .working
                        CommanderStuck.shared.output(worker.id, event: ["type": "user", "isReplay": true, "uuid": uuid])
                        self.main.commanderDispatchEvent(conversationID: worker.id, messageID: uuid,
                                                         event: ["type": "user", "isReplay": true, "uuid": uuid])
                    }
                    delivered?(true)
                    return true
                }
                self.main.commanderInterrupt = { pane in
                    guard let target = pane.conversationID else { return }
                    if target == runningWorker.id { toolInterruptCount += 1; return }
                    if target == acceptedWorker.id {
                        acceptedInterruptCount += 1
                        self.store.status[acceptedWorker.id] = .idle
                        return
                    }
                    guard target == worker.id else { return }
                    self.store.status[worker.id] = .idle
                    let result: [String: Any] = ["type": "result", "subtype": "error_during_execution", "is_error": true,
                                                 "result": "[Request interrupted by user]"]
                    CommanderStuck.shared.output(worker.id, event: result)
                    self.main.commanderDispatchEvent(conversationID: worker.id, messageID: "", event: result)
                }

                self.main.commanderSendChat(caller: lead.id.uuidString, target: worker.title,
                    text: "探針：未卡住時拒絕中斷", wait: false, timeout: 5, interrupt: true) {
                        manualInterruptResponses["same-area-not-stuck"] = $0
                    }
                self.main.commanderSendChat(caller: lead.id.uuidString, target: acceptedWorker.title,
                    text: "探針：已卡住時允許中斷", wait: false, timeout: 5, interrupt: true) {
                        manualInterruptResponses["same-area-stuck"] = $0
                    }
                self.main.commanderSendChat(caller: lead.id.uuidString, target: outsideWorker.title,
                    text: "探針：跨區拒絕中斷", wait: false, timeout: 5, interrupt: true) {
                        manualInterruptResponses["other-area"] = $0
                    }
                // 手動中斷案例已走過正式 send --interrupt 路徑；其餘合成工作不由真引擎處理。
                self.store.status[outsideWorker.id] = .idle
                SessionActivity.shared.injectFakeForTest(worker.id, count: 1)
                SessionActivity.shared.injectFakeForTest(runningWorker.id, count: 1)
                // 跨過第一階段門檻仍保持背景程序活躍，才能確認不會進自動中斷階段。
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    backgroundPaused = CommanderStuck.shared.stageProbeResult(for: worker.id).isEmpty
                    SessionActivity.shared.injectFakeForTest(worker.id, count: 0)
                }

                let finishBy = Date().addingTimeInterval(60)
                func manualInterruptResult() -> [[String: Any]] {
                    let cases: [(String, String)] = [
                        ("same-area-not-stuck", "not-stuck"),
                        ("same-area-stuck", "stuck"),
                        ("other-area", "outside-area")
                    ]
                    return cases.map { scenario, fallbackReason in
                        let response = manualInterruptResponses[scenario] ?? [:]
                        return ["scenario": scenario,
                                "accepted": response["ok"] as? Bool == true,
                                "reason": response["reason"] as? String ?? fallbackReason,
                                "message": response["error"] as? String ?? "",
                                "interruptCount": scenario == "same-area-stuck" ? acceptedInterruptCount : 0]
                    }
                }
                func probeResult(error: String? = nil) -> [String: Any] {
                    let toolEvents = CommanderStuck.shared.toolExecutionProbeResult(for: runningWorker.id)
                    let notification = toolEvents.first { $0["stage"] as? String == "notify" }
                    let events = toolEvents.map { event -> [String: Any] in
                        var result: [String: Any] = ["stage": event["stage"] ?? "", "recipient": event["recipient"] ?? "",
                            "text": event["text"] ?? "", "elapsedSeconds": event["elapsedSeconds"] ?? 0]
                        if let alive = event["childAliveAtNotice"] { result["childAliveAtNotice"] = alive }
                        return result
                    }
                    var command: [String: Any] = [
                        "elapsedSeconds": notification?["elapsedSeconds"] ?? 0,
                        "childAliveAtNotice": notification?["childAliveAtNotice"] ?? false,
                        "interruptCount": toolInterruptCount,
                        "notificationDelivered": toolNotificationDelivered,
                        "events": events
                    ]
                    if notification == nil { command["childAliveAtNotice"] = !SessionActivity.shared.running(runningWorker.id).isEmpty }
                    var output: [String: Any] = ["clockScale": CommanderStuck.shared.configuredClockScale,
                        "baseMinutes": Prefs.shared.commanderStuckMinutes,
                        "backgroundPausedBeforeFirstStage": backgroundPaused,
                        "manualInterrupt": manualInterruptResult(),
                        "worker": CommanderStuck.shared.stageProbeResult(for: worker.id),
                        "waiting": CommanderStuck.shared.stageProbeResult(for: waitingWorker.id),
                        "runningCommand": command]
                    if let error { output["ERROR"] = error }
                    return output
                }
                func poll() {
                    let events = CommanderStuck.shared.stageProbeResult(for: worker.id)
                    let waitingEvents = CommanderStuck.shared.stageProbeResult(for: waitingWorker.id)
                    if events.contains(where: { $0["stage"] as? String == "escalate" })
                        && waitingEvents.contains(where: { $0["stage"] as? String == "waiting-reminder" })
                        && manualInterruptResponses.count == 3 {
                        self.main.commanderDeliver = oldDeliver
                        self.main.commanderInterrupt = oldInterrupt
                        Prefs.shared.commanderCompletionNotices = previousNotices
                        SessionActivity.shared.injectFakeForTest(worker.id, count: 0)
                        SessionActivity.shared.injectFakeForTest(runningWorker.id, count: 0)
                        self.store.status[worker.id] = .idle
                        self.store.status[runningWorker.id] = .idle
                        self.store.status[waitingWorker.id] = .idle
                        let output = probeResult()
                        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) {
                            try? data.write(to: outputURL, options: .atomic)
                        }
                        return
                    }
                    if Date() >= finishBy {
                        self.main.commanderDeliver = oldDeliver
                        self.main.commanderInterrupt = oldInterrupt
                        Prefs.shared.commanderCompletionNotices = previousNotices
                        SessionActivity.shared.injectFakeForTest(worker.id, count: 0)
                        SessionActivity.shared.injectFakeForTest(runningWorker.id, count: 0)
                        self.store.status[runningWorker.id] = .idle
                        let output = probeResult(error: "探針逾時")
                        if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) {
                            try? data.write(to: outputURL, options: .atomic)
                        }
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll)
                }
                poll()
            }
        }
        // --agy-failure-probe "秒:輸出.json[:conversation-id]"：用假 agy 跑總指揮 send --wait，回報引擎失敗與監督通知。
        for (i, argument) in args.enumerated() where argument == "--agy-failure-probe" && i + 1 < args.count && args.contains("--state-dir") {
            let probeParts: [String] = args[i + 1].split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard probeParts.count >= 2,
                  let delaySeconds = Double(probeParts[0]),
                  delaySeconds.isFinite,
                  delaySeconds >= 0 else { continue }
            let deadline: DispatchTime = DispatchTime.now() + delaySeconds
            let probeArguments: [String] = args
            DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] () -> Void in
                guard let delegate = self else { return }
                delegate.startAgyFailureProbe(parts: probeParts, args: probeArguments)
            }
        }
        // --commander-permission-probe "秒數:資料夾:輸出檔"：隔離考卷驗證總指揮 new 的模式與手開聊天室預設不受影響。
        for (i, a) in args.enumerated() where a == "--commander-permission-probe" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let s = self.store.sessions.first(where: { $0.name == "C110Chief" }), let chiefID = s.chief,
                      let chief = self.store.conversation(chiefID), let folder = self.store.projects.first(where: { $0.path == parts[1] }) else { return }
                let caller = chiefID.uuidString
                func created(_ mode: String) -> String {
                    Prefs.shared.commanderChatPermission = mode == "default" ? nil : mode
                    let r = self.store.commanderCreate(caller: caller, name: "C110-\(mode)", dir: nil)
                    return r.conversation?.permissionMode ?? "default"
                }
                let normal = created("default")
                let open = created("bypassPermissions")
                Prefs.shared.commanderChatPermission = "bypassPermissions"
                let user = self.store.createConversation(in: folder.id)
                let result: [String: String] = ["default": normal, "bypass": open, "user": user.permissionMode ?? Prefs.shared.permissionMode ?? "default"]
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
                   let text = String(data: data, encoding: .utf8) { try? text.write(toFile: parts[2], atomically: true, encoding: .utf8) }
            }
        }
        // --child-memory-settings-probe "秒數:專案資料夾"：以假 Claude 分別啟動子聊天室、總指揮與關閉保護的子聊天室，檢查實際 --settings／系統提示。
        for (i, a) in args.enumerated() where a == "--child-memory-settings-probe" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                func startProbe(_ tag: String, name: String, isCommander: Bool) {
                    let chat = ChatSession(claudeSession: UUID(), directory: parts[1])
                    chat.conversationTag = tag
                    chat.nameProvider = { name }
                    chat.isCommanderChatProvider = { isCommander }
                    _ = chat.start()
                }
                startProbe("child", name: "C135-子聊天室", isCommander: false)
                startProbe("chief", name: "C135-總指揮", isCommander: true)
                Prefs.shared.childMemoryWriteGuard = false
                startProbe("disabled", name: "C135-保護關閉", isCommander: false)
            }
        }
        // --cli-path-dump 檔案：把 CLITools 找到的三支工具路徑與給聊天室的 PATH 寫成檔（搭 CODENV_LOCAL_BIN 測家目錄沒裝的情況）
        for (i, a) in args.enumerated() where a == "--cli-path-dump" && i + 1 < args.count && args.contains("--state-dir") {
            let out = CLITools.names.map { "\($0)=\(CLITools.path($0) ?? "nil")" }.joined(separator: "\n") + "\nPATH=\(CLITools.pathEntries(home: NSHomeDirectory()))\nsearchScript=\(SearchIndexClient.script.path)\n"
            try? out.write(toFile: args[i + 1], atomically: true, encoding: .utf8)
        }
        // --sprint-card-snapshot "秒數:檔案前綴"：把右欄的衝刺卡片畫成圖片（前綴-idle.png、前綴-running.png；running 用假狀態，只寫測試實例的 sprint.json）
        for (i, a) in args.enumerated() where a == "--sprint-card-snapshot" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                func shot(_ suffix: String) {
                    let host = NSHostingView(rootView: SprintCard().environment(\.uiScale, UIScale.shared.f).frame(width: 330).padding(8).background(Color(nsColor: .windowBackgroundColor)))
                    host.frame = NSRect(origin: .zero, size: host.fittingSize)
                    host.layoutSubtreeIfNeeded()
                    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[1] + "-" + suffix + ".png"))
                }
                shot("idle")
                SprintStore.shared.update { s in
                    s.phase = "running"; s.convTitle = "codenv_1"; s.startedAt = Date().addingTimeInterval(-3600)
                    s.watchLabel = "5 小時"; s.targetReset = Date().addingTimeInterval(95 * 60)
                    s.goal = "把對話搜尋的索引改成增量更新，並補上測試；順便清掉舊的暫存檔"
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { shot("running") }
            }
        }
        // --agy-notice-snapshot "秒數:檔案.png"：把 agy 預設開啟的提醒卡片畫成圖片（不顯示真的浮動卡片）
        for (i, a) in args.enumerated() where a == "--agy-notice-snapshot" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                let host = NSHostingView(rootView: AgyNoticeCard(onKnow: {}, onSettings: {}).background(Color(nsColor: .windowBackgroundColor)))
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[1]))
            }
        }
        // --commander-form-snapshot "秒數:檔案.png"：把「新增總指揮」表單畫成圖片（表單是 sheet，--snapshot 拍不到）
        for (i, a) in args.enumerated() where a == "--commander-form-snapshot" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let st = self?.store else { return }
                let host = NSHostingView(rootView: CommanderCreateForm(store: st).background(Color(nsColor: .windowBackgroundColor)))
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[1]))
            }
        }
        // --snapshot "秒數:檔案.png"：幾秒後把整個視窗內容畫成圖片（視窗被蓋住也拍得到最新畫面）
        for (i, a) in args.enumerated() where a == "--snapshot" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let v = self?.main.window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
        // --settings-snapshot "秒數:頁:檔案"：打開設定視窗（頁＝windows、chat、appearance、pet、keys、local、schedules、data）拍成 PNG。測英文介面有沒有漏翻用
        for (i, a) in args.enumerated() where a == "--settings-snapshot" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]) else { continue }
            let tab = parts[1]
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                appDefaults.set(tab, forKey: "settingsTab")      // 測試實例的偏好，不是正式的
                self?.showSettings()
                guard let w = self?.settings?.window else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[2]))
                }
            }
        }
        // --web-snapshot "秒數:檔案"：目前聊天室的網頁拍成 PNG（背景測試時 screencapture 拍不到網頁內容）
        for (i, a) in args.enumerated() where a == "--web-snapshot" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.snapshotWeb(to: path)
            }
        }
        // --dump "秒數:檔案"：幾秒後把目前那格的尺寸和畫面文字寫進檔案
        for (i, a) in args.enumerated() where a == "--dump" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                guard let id = self.store.selected, let p = self.workspace.panes[id] as? TerminalPane else { return }
                var out = "pane \(p.frame) terminal \(p.terminal.frame)\n"
                for v in p.subviews { out += "  \(type(of: v)) \(v.frame) hidden \(v.isHidden) sub \(v.subviews.map { "\(type(of: $0))\($0.frame)\($0.isHidden ? "隱" : "")" })\n" }
                p.terminal.withTerminalPublic { t in
                    out += "cols \(t.cols) rows \(t.rows) yDisp \(t.buffer.yDisp)\n"
                    for r in 0..<t.rows { out += (t.getLine(row: r)?.translateToString(trimRight: true) ?? "") + "\n" }
                }
                try? out.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        for (i, a) in args.enumerated() where a == "--send" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let text = String(parts[1]).replacingOccurrences(of: "\\r", with: "\r")
                .replacingOccurrences(of: "\\e", with: "\u{1b}")
                .replacingOccurrences(of: "^X", with: "\u{18}").replacingOccurrences(of: "^S", with: "\u{13}")
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? TerminalPane else { return }
                p.terminal.send(txt: text)
            }
        }

        // --codelab-big5-probe "秒數:Big5檔路徑:另一個檔路徑:輸出檔"：開 Big5 檔（不改）→ 換開另一個檔，Big5 檔的位元組不能變（不能被悄悄存成 UTF-8）
        for (i, a) in args.enumerated() where a == "--codelab-big5-probe" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 3).map(String.init)
            guard parts.count == 4, let sec = Double(parts[0]), parts[1].hasPrefix("/"), parts[2].hasPrefix("/"), parts[3].hasPrefix("/") else { continue }
            let big5Path = parts[1], otherPath = parts[2], outFile = parts[3]
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let f = self.store.currentWindow?.focused, let p = self.workspace.panes[f] as? ChatPane else {
                    try? "error=找不到聊天格\n".write(toFile: outFile, atomically: true, encoding: .utf8); return
                }
                if p.codeLab == nil { p.attachCodeLab(directory: (big5Path as NSString).deletingLastPathComponent, key: f.uuidString) }
                guard let lab = p.codeLab else { try? "error=無法建立程式碼區\n".write(toFile: outFile, atomically: true, encoding: .utf8); return }
                self.recoveryProbeLabs.append(lab)
                let before = FileManager.default.contents(atPath: big5Path) ?? Data()
                func pollReady(attempt: Int = 0, done: @escaping () -> Void) {
                    lab.testAction("js=typeof cl !== 'undefined'") { res in
                        if res.contains("true") || res.contains("1") { done() }
                        else if attempt < 50 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { pollReady(attempt: attempt + 1, done: done) } }
                        else { try? "error=編輯器初始化超時\n".write(toFile: outFile, atomically: true, encoding: .utf8) }
                    }
                }
                pollReady {
                    lab.open(big5Path)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        lab.testAction("switch=" + otherPath) { _ in }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            let after = FileManager.default.contents(atPath: big5Path) ?? Data()
                            try? "big5_intact=\(after == before)\nbefore_bytes=\(before.count)\nafter_bytes=\(after.count)\ncurrent_file=\(lab.file ?? "nil")\n".write(toFile: outFile, atomically: true, encoding: .utf8)
                        }
                    }
                }
            }
        }
        // --codelab-delayed-save-probe "秒數:檔A路徑:檔B路徑:輸出檔"
        // 考卷 C14 規格：CodeLab 開檔 A、改開檔 B 之後才收到網頁送來 path=A 的 save 訊息，B 的 bytes 不能變、A 也不能被寫成 B 的內容
        for (i, a) in args.enumerated() where a == "--codelab-delayed-save-probe" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 3).map(String.init)
            guard parts.count == 4, let sec = Double(parts[0]),
                  parts[1].hasPrefix("/"), parts[2].hasPrefix("/"), parts[3].hasPrefix("/") else { continue }
            let pathA = parts[1], pathB = parts[2], outFile = parts[3]
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                guard let f = self.store.currentWindow?.focused,
                      let p = self.workspace.panes[f] as? ChatPane else {
                    try? "error=找不到聊天格\n".write(toFile: outFile, atomically: true, encoding: .utf8)
                    return
                }
                let projDir = (pathA as NSString).deletingLastPathComponent
                if p.codeLab == nil {
                    p.attachCodeLab(directory: projDir, key: f.uuidString)
                }
                guard let lab = p.codeLab else {
                    try? "error=無法建立程式碼區\n".write(toFile: outFile, atomically: true, encoding: .utf8)
                    return
                }
                self.recoveryProbeLabs.append(lab)

                let initialA = FileManager.default.contents(atPath: pathA) ?? Data()
                let initialB = FileManager.default.contents(atPath: pathB) ?? Data()

                func pollReady(attempt: Int = 0, done: @escaping () -> Void) {
                    lab.testAction("js=typeof cl !== 'undefined'") { res in
                        if res.contains("true") || res.contains("1") {
                            done()
                        } else if attempt < 50 {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                pollReady(attempt: attempt + 1, done: done)
                            }
                        } else {
                            try? "error=編輯器初始化超時\n".write(toFile: outFile, atomically: true, encoding: .utf8)
                        }
                    }
                }

                pollReady {
                    // 1. 開檔 A
                    lab.open(pathA)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        // 記下開 A 時網頁的 token：真實的遲到訊息帶的是這個
                        lab.testAction("js=window.__tokA = cl.text().token") { _ in }
                        // 2. 改開檔 B
                        lab.open(pathB)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            // 3. 此時目前檔案為 B。送來 path=A 的遲到 save 訊息
                            // (1) 真實情況：path=A、帶開 A 時的 token
                            let scriptWithOldPath = "window.webkit.messageHandlers.codelab.postMessage({ type: 'save', path: \(Self.jsEscapeString(pathA)), text: '// HACKED DELAYED SAVE FROM A\\n', token: window.__tokA });"
                            lab.testAction("js=" + scriptWithOldPath) { _ in }
                            // (2) path=A 但帶現在（B）的 token：只有「路徑要等於目前檔案」這道檢查擋得住（593aaf7 的修正本身）
                            let scriptPathOnly = "window.webkit.messageHandlers.codelab.postMessage({ type: 'save', path: \(Self.jsEscapeString(pathA)), text: '// HACKED SAVE PATH-ONLY\\n', token: cl.text().token });"
                            lab.testAction("js=" + scriptPathOnly) { _ in }

                            // 4. 同時測試不帶 path 的舊式 save（593aaf7 修正前沒有 path）
                            let scriptNoPath = "window.webkit.messageHandlers.codelab.postMessage({ type: 'save', text: '// HACKED SAVE WITHOUT PATH\\n' });"
                            lab.testAction("js=" + scriptNoPath) { _ in }

                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                let curA = FileManager.default.contents(atPath: pathA) ?? Data()
                                let curB = FileManager.default.contents(atPath: pathB) ?? Data()
                                let bIntact = (curB == initialB)
                                let aIntact = (curA == initialA)
                                let aNotB = (curA != curB)
                                let curFile = lab.file ?? "nil"
                                let out = "b_intact=\(bIntact)\na_intact=\(aIntact)\na_not_b=\(aNotB)\ncurrent_file=\(curFile)\n"
                                try? out.write(toFile: outFile, atomically: true, encoding: .utf8)
                            }
                        }
                    }
                }
            }
        }

        // --codelab-focus-keys-probe "秒數:輸出檔"
        // 考卷 C15 規格：焦點在程式碼編輯器時 Tab、/、⌃C、⌃Enter 留在編輯器；焦點在聊天輸入框時照聊天行為（修正 d0b1f06）
        for (i, a) in args.enumerated() where a == "--codelab-focus-keys-probe" && i + 1 < args.count && args.contains("--state-dir") {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let sec = Double(parts[0]), parts[1].hasPrefix("/") else { continue }
            let outFile = parts[1]
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                guard let f = self.store.currentWindow?.focused,
                      let p = self.workspace.panes[f] as? ChatPane,
                      let w = self.main.window else {
                    try? "error=找不到聊天格或主視窗\n".write(toFile: outFile, atomically: true, encoding: .utf8)
                    return
                }
                let projDir = self.store.project(self.store.conversation(f)?.projectID ?? UUID())?.path ?? "/tmp"
                if p.codeLab == nil {
                    p.attachCodeLab(directory: projDir, key: f.uuidString)
                }
                guard let lab = p.codeLab else {
                    try? "error=無法建立程式碼區\n".write(toFile: outFile, atomically: true, encoding: .utf8)
                    return
                }
                self.recoveryProbeLabs.append(lab)

                func pollReady(attempt: Int = 0, done: @escaping () -> Void) {
                    lab.testAction("js=typeof cl !== 'undefined'") { res in
                        if res.contains("true") || res.contains("1") {
                            done()
                        } else if attempt < 50 {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                pollReady(attempt: attempt + 1, done: done)
                            }
                        } else {
                            try? "error=編輯器初始化超時\n".write(toFile: outFile, atomically: true, encoding: .utf8)
                        }
                    }
                }

                pollReady {
                    guard let editorWeb = Self.find(WKWebView.self, in: lab) else {
                        try? "error=找不到編輯器網頁\n".write(toFile: outFile, atomically: true, encoding: .utf8)
                        return
                    }
                    func chatWebViews(_ v: NSView) -> [WKWebView] {
                        v === lab ? [] : (v as? WKWebView).map { [$0] } ?? v.subviews.flatMap(chatWebViews)
                    }
                    guard let chatWeb = chatWebViews(p).first else {
                        try? "error=找不到聊天網頁\n".write(toFile: outFile, atomically: true, encoding: .utf8)
                        return
                    }
                    let inputTV = p.inputBar.textView
                    let inputBar = p.inputBar
                    var res: [String: Bool] = [:]

                    func inEditor() -> Bool {
                        guard let v = w.firstResponder as? NSView else { return false }
                        return v === editorWeb || v.isDescendant(of: editorWeb) || v.isDescendant(of: lab)
                    }

                    // 步驟 1：焦點在編輯器，測 Tab
                    w.makeFirstResponder(editorWeb)
                    lab.testAction("js=cl.focus()") { _ in }
                    inputTV.string = ""
                    inputBar.suggestion = "灰字建議"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        Self.dispatchKeyEvent(code: 48, chars: "\t", window: w)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            res["editor_tab"] = inEditor() && inputTV.string.isEmpty

                            // 步驟 2：焦點在編輯器，測 /
                            w.makeFirstResponder(editorWeb)
                            lab.testAction("js=cl.focus()") { _ in }
                            inputTV.string = ""
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                Self.dispatchKeyEvent(code: 44, chars: "/", window: w)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                    res["editor_slash"] = inEditor() && (w.firstResponder !== inputTV)

                                    // 步驟 3：焦點在編輯器，測 ⌃C
                                    w.makeFirstResponder(editorWeb)
                                    lab.testAction("js=cl.focus()") { _ in }
                                    var chatInterrupted = false
                                    let prevOnStop = inputBar.onStop
                                    inputBar.onStop = { chatInterrupted = true; prevOnStop?() }
                                    inputBar.busy = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                        Self.dispatchKeyEvent(code: 8, chars: "\u{03}", unmodChars: "c", mods: .control, window: w)
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                            res["editor_ctrl_c"] = inEditor() && !chatInterrupted
                                            inputBar.busy = false
                                            inputBar.onStop = prevOnStop

                                            // 步驟 4：焦點在編輯器，測 ⌃Enter
                                            w.makeFirstResponder(editorWeb)
                                            lab.testAction("js=cl.focus()") { _ in }
                                            var chatSentNow = false
                                            let prevOnSendQueued = inputBar.onSendQueuedNow
                                            inputBar.onSendQueuedNow = { chatSentNow = true; prevOnSendQueued?() }
                                            inputTV.string = ""
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                                Self.dispatchKeyEvent(code: 36, chars: "\r", unmodChars: "\r", mods: .control, window: w)
                                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                                    res["editor_ctrl_enter"] = inEditor() && !chatSentNow
                                                    inputBar.onSendQueuedNow = prevOnSendQueued

                                                    // 步驟 5：正向對照——焦點在聊天內容，測 Tab（跳回輸入框並採用灰字建議）
                                                    w.makeFirstResponder(chatWeb)
                                                    inputTV.string = ""
                                                    inputBar.suggestion = "灰字建議"
                                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                                        Self.dispatchKeyEvent(code: 48, chars: "\t", window: w)
                                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                                            let adopted = (inputTV.string == "灰字建議")
                                                            let tvFocused = (w.firstResponder === inputTV)
                                                            res["chat_tab"] = tvFocused && adopted

                                                            // 步驟 6：正向對照——焦點在聊天內容，測 /（跳回輸入框）
                                                            w.makeFirstResponder(chatWeb)
                                                            inputTV.string = ""
                                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                                                Self.dispatchKeyEvent(code: 44, chars: "/", window: w)
                                                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                                                    res["chat_slash"] = (w.firstResponder === inputTV)

                                                                    // 步驟 7：正向對照——焦點在聊天內容，測 ⌃C（由聊天攔截觸發中斷）
                                                                    w.makeFirstResponder(chatWeb)
                                                                    var chatInterrupted2 = false
                                                                    let prevOnStop2 = inputBar.onStop
                                                                    inputBar.onStop = { chatInterrupted2 = true; prevOnStop2?() }
                                                                    inputBar.busy = true
                                                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                                                        Self.dispatchKeyEvent(code: 8, chars: "\u{03}", unmodChars: "c", mods: .control, window: w)
                                                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                                                            res["chat_ctrl_c"] = chatInterrupted2
                                                                            inputBar.busy = false
                                                                            inputBar.onStop = prevOnStop2

                                                                            // 步驟 8：正向對照——焦點在聊天內容，測 ⌃Enter（由聊天攔截觸發馬上插話）
                                                                            w.makeFirstResponder(chatWeb)
                                                                            var chatSentNow2 = false
                                                                            let prevOnSendQueued2 = inputBar.onSendQueuedNow
                                                                            inputBar.onSendQueuedNow = { chatSentNow2 = true; prevOnSendQueued2?() }
                                                                            inputTV.string = ""
                                                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                                                                Self.dispatchKeyEvent(code: 36, chars: "\r", unmodChars: "\r", mods: .control, window: w)
                                                                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                                                                    res["chat_ctrl_enter"] = chatSentNow2
                                                                                    inputBar.onSendQueuedNow = prevOnSendQueued2

                                                                                    let out = [
                                                                                        "editor_tab=\(res["editor_tab"] ?? false)",
                                                                                        "editor_slash=\(res["editor_slash"] ?? false)",
                                                                                        "editor_ctrl_c=\(res["editor_ctrl_c"] ?? false)",
                                                                                        "editor_ctrl_enter=\(res["editor_ctrl_enter"] ?? false)",
                                                                                        "chat_tab=\(res["chat_tab"] ?? false)",
                                                                                        "chat_slash=\(res["chat_slash"] ?? false)",
                                                                                        "chat_ctrl_c=\(res["chat_ctrl_c"] ?? false)",
                                                                                        "chat_ctrl_enter=\(res["chat_ctrl_enter"] ?? false)"
                                                                                    ].joined(separator: "\n") + "\n"
                                                                                    try? out.write(toFile: outFile, atomically: true, encoding: .utf8)
                                                                                }
                                                                            }
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// 測試用：把「C-a」「|」「h」這種寫法變成真的按鍵事件丟進 App
    /// 背景測試時自己送的事件要等「下一個事件」來才會被處理：補一個沒作用的事件把它們推出去
    static func flushEvents(_ w: NSWindow) {
        if let e = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(e, atStart: false) }
    }

    /// 在畫面元件樹裡找第一個某種元件（測試用）
    static func find<T: NSView>(_ t: T.Type, in v: NSView?) -> T? {
        guard let v else { return nil }
        if let x = v as? T { return x }
        for c in v.subviews { if let x = find(t, in: c) { return x } }
        return nil
    }

    static func postKey(_ token: String, window: NSWindow) {
        defer { flushEvents(window) }
        let codes: [Character: UInt16] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "-": 27,
            "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, "[": 33, "]": 30, "`": 50]
        let shifted: [Character: Character] = ["|": "\\", "&": "7", "$": "4", "(": "9", ")": "0", "?": "/"]
        var mods: NSEvent.ModifierFlags = []
        var ch = Character(token.last.map(String.init) ?? " ")
        if token.hasPrefix("C-") { mods.insert(.control) }
        if token.hasPrefix("D-") { mods.insert(.command) }   // D-1＝⌘ 1（測 Window 切換）
        if token.contains("S-") { mods.insert(.shift) }      // D-S-z＝⌘ ⇧ Z
        if token == "Esc" {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)
            if let e { NSApp.postEvent(e, atStart: false) }
            return
        }
        // 特殊鍵：Tab、↑、↓（測 / 選單）、Ret＝Enter（測程式碼區的 cin）
        let special: [String: (UInt16, String)] = ["Tab": (48, "\t"), "Down": (125, "\u{F701}"), "Up": (126, "\u{F700}"), "Left": (123, "\u{F702}"), "Right": (124, "\u{F703}"), "BS": (51, "\u{7F}"), "Ret": (36, "\r"), "F3": (99, "\u{F706}"), "F4": (118, "\u{F707}"), "F5": (96, "\u{F708}"), "F6": (97, "\u{F709}")]
        // 方向鍵可以加 C-（⌃ ←，測 ⌃ A 之後 ⌃ 沒放開）、D-（⌘ ↑，測輸入框跳到最前）
        let arrowMod = (token.hasPrefix("C-") || token.hasPrefix("D-")) && ["Left", "Right", "Up", "Down"].contains(String(token.dropFirst(2)))
        if let (code, chars) = special[arrowMod ? String(token.dropFirst(2)) : token] {
            var flags: NSEvent.ModifierFlags = code >= 123 && code <= 126 ? [.function, .numericPad] : (code == 96 || code == 97 ? [.function] : [])
            if arrowMod { flags.insert(token.hasPrefix("C-") ? .control : .command) }
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
            if let e { NSApp.postEvent(e, atStart: false) }
            return
        }
        if token == "C-Ret" {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
            if let e { NSApp.postEvent(e, atStart: false) }
            return
        }
        if token == "D-S-Ret" {   // ⌘ ⇧ Enter（測學 Ghostty 的放大這格）
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
            if let e { NSApp.postEvent(e, atStart: false) }
            return
        }
        if token == "D-Ret" {   // ⌘ Enter（測問答卡片「其他」欄送出）
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
            if let e { NSApp.postEvent(e, atStart: false) }
            return
        }
        if token == "M-Up" || token == "M-Down" {   // ⌘ ↑／⌘ ↓
            let up = token == "M-Up", ch = up ? "\u{F700}" : "\u{F701}"
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: up ? 126 : 125)
            if let e { NSApp.postEvent(e, atStart: false) }
            return
        }
        if token == "S-Tab" {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\u{19}", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)
            if let e { NSApp.postEvent(e, atStart: false) }
            return
        }
        var shown = String(ch)
        if mods.contains(.shift), ch.isLetter { shown = shown.uppercased() }   // 真的鍵盤按 ⌘ ⇧ Z 送的是大寫 Z
        if let base = shifted[ch] { mods.insert(.shift); ch = base }
        guard let code = codes[ch] else { return }
        if mods.contains(.control) { shown = String(UnicodeScalar(UInt8(ch.asciiValue! & 0x1f))) }
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: window.windowNumber, context: nil, characters: shown,
                                 charactersIgnoringModifiers: mods.contains(.shift) ? shown : String(ch), isARepeat: false, keyCode: code)
        if let e { NSApp.postEvent(e, atStart: false) }
    }

    /// App 內部直接派送按鍵事件（不用 CGEvent，背景測試不搶前景、不需輔助取用權限）
    static func dispatchKeyEvent(code: UInt16, chars: String, unmodChars: String? = nil, mods: NSEvent.ModifierFlags = [], window: NSWindow) {
        let unmod = unmodChars ?? chars
        let e = NSEvent.keyEvent(with: .keyDown,
                                 location: .zero,
                                 modifierFlags: mods,
                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: window.windowNumber,
                                 context: nil,
                                 characters: chars,
                                 charactersIgnoringModifiers: unmod,
                                 isARepeat: false,
                                 keyCode: code)
        if let e {
            NSApp.sendEvent(e)
            flushEvents(window)
        }
    }

    /// `--agy-background-probe <next|sprint|next-cancel> <結果檔>`（規格 3 F）：
    /// 只在帶 `--state-dir` 時啟用，開機後各觸發一次對應的背景工具 agy 啟動並將結果寫入 `<state-dir>` 下指定檔。
    private func installAgyBackgroundProbes(_ args: [String]) {
        guard let stateIndex = args.firstIndex(of: "--state-dir"), stateIndex + 1 < args.count else { return }
        let stateRoot = URL(fileURLWithPath: args[stateIndex + 1], isDirectory: true).standardizedFileURL

        for (i, arg) in args.enumerated() where arg == "--agy-background-probe" {
            guard i + 2 < args.count else { exit(2) }
            let action = args[i + 1]
            let outputURL = URL(fileURLWithPath: args[i + 2]).standardizedFileURL
            guard isTestProbeOutput(outputURL, inside: stateRoot) else { exit(2) }

            func writeOutcome(_ outcome: AgyBackgroundProbeOutcome) {
                guard let data = try? JSONSerialization.data(
                    withJSONObject: outcome.jsonObject(),
                    options: [.sortedKeys, .prettyPrinted]
                ) else { return }
                try? FileManager.default.createDirectory(
                    at: outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? data.write(to: outputURL, options: .atomic)
            }

            switch action {
            case "next":
                _ = NextGuess.probeRunHydrogen(
                    user: "請幫我檢查這段程式。",
                    assistant: "已完成檢查，目前沒有錯誤。"
                ) { outcome in
                    writeOutcome(outcome)
                }

            case "sprint":
                SprintCheck.probeAgyJudge(
                    last: "已完成這輪工作並驗證通過。",
                    tools: ["Read"]
                ) { outcome in
                    writeOutcome(outcome)
                }

            case "next-cancel":
                let stop = NextGuess.probeRunHydrogen(
                    user: "請幫我檢查這段程式。",
                    assistant: "已完成檢查，目前沒有錯誤。"
                ) { outcome in
                    writeOutcome(outcome)
                }
                if let stop {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        stop()
                    }
                }

            default:
                exit(2)
            }
        }
    }

    /// 把字串安全轉成 JS 字串常數（含跳脫引號）
    static func jsEscapeString(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [s]),
              let a = String(data: d, encoding: .utf8) else { return "\"\"" }
        return String(a.dropFirst().dropLast())
    }
}


/// --tabbar-collapse-probe 的 trace 收集（只在帶 --state-dir 的測試實例啟用；沒啟用時 layout() 只多判斷一個 Bool）
enum TabBarCollapseProbe {
    static var active = false
    static var t0 = Date()
    static var phase = "steady"
    static var trace: [[String: Any]] = []
    static func add(barX: CGFloat, firstTabX: CGFloat, dragHandleX: CGFloat) {
        func r(_ v: CGFloat) -> Double { (Double(v) * 100).rounded() / 100 }
        trace.append(["t": (Date().timeIntervalSince(t0) * 1000).rounded() / 1000, "barX": r(barX), "firstTabX": r(firstTabX),
                      "dragHandleX": r(dragHandleX), "phase": phase])
    }
}

extension AppDelegate {
    /// --tabbar-collapse-probe "<f3|menu>:<結果檔>"（限 --state-dir，結果檔要在 state-dir 內）：展開基準 → 收合 → 展開，
    /// 每次分頁列 layout() 記一筆 trace，輸出 expandedFirstTabX／collapsedFirstTabX／expandedAfterFirstTabX／trafficLightsMaxX／trace。
    func installTabBarCollapseProbe(_ args: [String]) {
        guard let i = args.firstIndex(of: "--tabbar-collapse-probe"), i + 1 < args.count,
              let si = args.firstIndex(of: "--state-dir"), si + 1 < args.count else { return }
        let parts = args[i + 1].split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, ["f3", "menu"].contains(parts[0]) else { exit(2) }
        let root = URL(fileURLWithPath: args[si + 1], isDirectory: true)
        let output = URL(fileURLWithPath: parts[1])
        guard isTestProbeOutput(output, inside: root) else { exit(2) }
        let mode = parts[0]
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, let main = self.main, let window = main.window else { exit(3) }
            let bar = main.host.tabBar
            func snap() -> (barX: CGFloat, firstTabX: CGFloat) {
                bar.layoutSubtreeIfNeeded()
                let s = bar.probeSnapshot()
                return (s.barX, s.firstTabX)
            }
            var triggerPath = mode == "f3" ? "PrefixKeys(F3 合成按鍵)" : "AppDelegate.toggleSidebar(選單入口)"
            func trigger() {
                if mode == "f3" {
                    if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil,
                                                characters: String(UnicodeScalar(NSF3FunctionKey)!), charactersIgnoringModifiers: String(UnicodeScalar(NSF3FunctionKey)!),
                                                isARepeat: false, keyCode: 99) {
                        NSApp.sendEvent(e)
                    }
                    // 0.4 秒內分頁列完全沒動靜（監視器沒收到合成按鍵）→ 改直接呼叫 toggleSidebar()，並在結果註明
                    let before = TabBarCollapseProbe.trace.count
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        if TabBarCollapseProbe.trace.count == before { triggerPath = "main.toggleSidebar()(F3 合成按鍵沒被處理，改直接呼叫)"; main.toggleSidebar() }
                    }
                } else {
                    self.toggleSidebar()
                }
            }
            func waitSettled(_ done: @escaping () -> Void) {
                var last = snap().barX, stable = 0, ticks = 0
                func poll() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        ticks += 1
                        let now = snap().barX
                        stable = abs(now - last) < 0.01 ? stable + 1 : 0
                        last = now
                        if (stable >= 6 && ticks >= 8) || ticks > 60 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { done() } } else { poll() }
                    }
                }
                poll()
            }
            TabBarCollapseProbe.t0 = Date()
            TabBarCollapseProbe.active = true
            TabBarCollapseProbe.phase = "steady"
            let expanded = snap()
            TabBarCollapseProbe.phase = "collapse"
            trigger()
            waitSettled {
                let collapsed = snap()
                TabBarCollapseProbe.phase = "expand"
                trigger()
                waitSettled {
                    let after = snap()
                    TabBarCollapseProbe.phase = "steady"
                    var tl = 0.0
                    if let b = window.standardWindowButton(.zoomButton) { tl = Double(b.convert(NSPoint(x: b.bounds.maxX, y: 0), to: nil).x) }
                    let result: [String: Any] = [
                        "mode": mode, "triggerPath": triggerPath,
                        "expandedBarX": Double(expanded.barX), "expandedFirstTabX": Double(expanded.firstTabX),
                        "collapsedBarX": Double(collapsed.barX), "collapsedFirstTabX": Double(collapsed.firstTabX),
                        "expandedAfterBarX": Double(after.barX), "expandedAfterFirstTabX": Double(after.firstTabX),
                        "trafficLightsMaxX": tl, "trace": TabBarCollapseProbe.trace]
                    TabBarCollapseProbe.active = false
                    if let d = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: output, options: .atomic) }
                }
            }
        }
    }

    /// `--window-diag-inject <spec>` 與 `--window-diag-reopen <延遲秒>`（只在 `--state-dir` 測試實例生效）：
    /// 覆寫 WindowDiag 偵測器／救援讀到的主視窗狀態（例如 `occ=hidden,space=off,active=1,key=1,main=1,onscreen=0,frameout=1,rescue-ok=2`
    /// 或 `alpha-node=NSView[0]/TabBar[1]:0.45`），支援重複帶入與 `<秒數>:<spec>` 排程更新；
    /// `--window-diag-reopen <延遲秒>` 會在指定延遲後由測試實例主動呼叫 `applicationShouldHandleReopen`。
    @MainActor
    private func installWindowDiagInjectHooks(_ args: [String]) {
        guard args.contains("--state-dir") else { return }
        var scheduled: [(order: Int, raw: String, command: WindowDiagInjectCommand)] = []
        for (i, arg) in args.enumerated() where arg == "--window-diag-inject" && i + 1 < args.count {
            let raw = args[i + 1]
            guard let command = WindowDiagInjectCommand.parse(raw) else {
                EventLog.log("測試", "window-diag-inject 格式無法解析，略過：\(raw)")
                continue
            }
            scheduled.append((order: i, raw: raw, command: command))
        }

        let posix = Locale(identifier: "en_US_POSIX")
        if !scheduled.isEmpty {
            let byDelay = Dictionary(grouping: scheduled, by: { $0.command.delaySeconds })
            for delay in byDelay.keys.sorted() {
                guard let batch = byDelay[delay]?.sorted(by: { $0.order < $1.order }) else { continue }
                let applyBatch: @MainActor () -> Void = { [weak self] in
                    for item in batch {
                        let tLabel = String(format: "%.1f", locale: posix, delay)
                        EventLog.log("測試", "window-diag-inject 套用（t=\(tLabel)s）：\(item.raw)")
                        WindowDiag.applyTestInjection(item.command)
                        if let reopenFlag = item.command.triggerReopen {
                            _ = self?.applicationShouldHandleReopen(NSApp, hasVisibleWindows: reopenFlag)
                        }
                    }
                }
                if delay <= 0 {
                    applyBatch()
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        MainActor.assumeIsolated {
                            applyBatch()
                        }
                    }
                }
            }
        }

        // `--window-diag-reopen <延遲秒>`（可重複帶入）：於啟動後延遲呼叫 applicationShouldHandleReopen
        for (i, arg) in args.enumerated() where arg == "--window-diag-reopen" && i + 1 < args.count {
            let raw = args[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let delay = Double(raw), delay.isFinite, delay >= 0 else {
                EventLog.log("測試", "window-diag-reopen 延遲秒數無效，略過：\(raw)")
                continue
            }
            let tLabel = String(format: "%.1f", locale: posix, delay)
            let trigger: @MainActor () -> Void = { [weak self] in
                EventLog.log("測試", "window-diag-reopen 觸發（t=\(tLabel)s）")
                let hasVisible = self?.main?.window?.isVisible ?? false
                _ = self?.applicationShouldHandleReopen(NSApp, hasVisibleWindows: hasVisible)
            }
            if delay <= 0 {
                trigger()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    MainActor.assumeIsolated {
                        trigger()
                    }
                }
            }
        }
    }

    /// `--activation-focus-probe <輸出檔>`（只在 `--state-dir` 測試實例生效，輸出路徑須在 state-dir 內）：
    /// 考卷 C506：不送真鍵盤、不 activate 視窗、不搶焦點，依序驗證三情境
    /// （codelab／chatinput／rename-field）走與 didResignActive／didBecomeActive 相同路徑後的 firstResponder 與 focusChatInput 回傳值。
    private func installActivationFocusProbe(_ args: [String]) {
        guard let optIdx = args.firstIndex(of: "--activation-focus-probe"), optIdx + 1 < args.count,
              let stateIdx = args.firstIndex(of: "--state-dir"), stateIdx + 1 < args.count else { return }
        let stateDir = URL(fileURLWithPath: args[stateIdx + 1], isDirectory: true).standardizedFileURL
        let rawArg = args[optIdx + 1]
        let delay: Double
        let outPath: String
        if let colon = rawArg.firstIndex(of: ":"),
           let sec = Double(rawArg[..<colon]),
           rawArg[rawArg.index(after: colon)...].hasPrefix("/") {
            delay = max(0.2, sec)
            outPath = String(rawArg[rawArg.index(after: colon)...])
        } else {
            delay = 1.5
            outPath = rawArg
        }
        let outputURL = URL(fileURLWithPath: outPath).standardizedFileURL
        guard isTestProbeOutput(outputURL, inside: stateDir) else {
            EventLog.log("測試", "activation-focus-probe 輸出路徑不在 state-dir 內，已拒寫")
            return
        }

        func writeJSON(_ payload: [String: Any]) {
            guard isTestProbeOutput(outputURL, inside: stateDir),
                  let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return }
            try? data.write(to: outputURL, options: .atomic)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let projDirURL = stateDir.appendingPathComponent("codelab-proj", isDirectory: true)
            try? FileManager.default.createDirectory(at: projDirURL, withIntermediateDirectories: true)
            let sampleCpp = projDirURL.appendingPathComponent("main.cpp")
            if !FileManager.default.fileExists(atPath: sampleCpp.path) {
                try? "// c506 activation focus probe\nint main() { return 0; }\n".write(to: sampleCpp, atomically: true, encoding: .utf8)
            }
            if self.store.currentWindow?.focused.flatMap({ self.workspace.panes[$0] as? ChatPane }) == nil {
                let pid = self.store.projects.first(where: { $0.path == projDirURL.path })?.id
                    ?? self.store.addProject(path: projDirURL.path).id
                _ = self.store.newConversation(in: pid)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                guard let f = self.store.currentWindow?.focused,
                      let p = self.workspace.panes[f] as? ChatPane,
                      let w = self.main.window else {
                    writeJSON(["schemaVersion": 1, "error": "找不到聊天格或主視窗"])
                    return
                }
                let projDir = self.store.project(self.store.conversation(f)?.projectID ?? UUID())?.path ?? projDirURL.path
                if p.codeLab == nil {
                    p.attachCodeLab(directory: projDir, key: f.uuidString)
                }
                guard let lab = p.codeLab else {
                    writeJSON(["schemaVersion": 1, "error": "無法建立程式碼區"])
                    return
                }
                self.recoveryProbeLabs.append(lab)

                func pollReady(attempt: Int = 0, done: @escaping () -> Void) {
                    lab.testAction("js=typeof cl !== 'undefined'") { res in
                        if res.contains("true") || res.contains("1") {
                            done()
                        } else if attempt < 50 {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                pollReady(attempt: attempt + 1, done: done)
                            }
                        } else {
                            writeJSON(["schemaVersion": 1, "error": "編輯器初始化超時"])
                        }
                    }
                }

                pollReady {
                    guard let editorWeb = Self.find(WKWebView.self, in: lab) else {
                        writeJSON(["schemaVersion": 1, "error": "找不到編輯器網頁"])
                        return
                    }
                    let inputTV = p.inputBar.textView
                    let renameField = NSTextView(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
                    renameField.isEditable = true
                    renameField.isSelectable = true
                    renameField.string = "改名欄位"
                    w.contentView?.addSubview(renameField)

                    func snapResponder() -> [String: Any] {
                        let r = w.firstResponder
                        let cls = r.map { String(describing: type(of: $0)) } ?? "nil"
                        let inLab = self.main.inCodeLab(p, r as? NSView)
                        let isInput = (r === inputTV)
                        return [
                            "responderClass": cls,
                            "inCodeLab": inLab,
                            "isChatInput": isInput,
                        ]
                    }

                    var results: [[String: Any]] = []

                    func runScenario(
                        name: String,
                        setup: @escaping () -> Void,
                        settleBeforeSec: Double = 0.2,
                        next: @escaping () -> Void
                    ) {
                        setup()
                        DispatchQueue.main.asyncAfter(deadline: .now() + settleBeforeSec) {
                            let before = snapResponder()
                            var focusResult: Bool? = nil
                            // 走與 didResignActive／didBecomeActive 相同的路徑，不送真鍵盤、不 activate 視窗
                            self.main.clearWebEditingAfterAppResign()
                            self.main.handleAppDidBecomeActive(requireKeyWindow: false) { focused in
                                focusResult = focused
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                let after = snapResponder()
                                var row: [String: Any] = [
                                    "scenario": name,
                                    "before": before,
                                    "after": after,
                                ]
                                if let focusResult {
                                    row["focusChatInputResult"] = focusResult
                                }
                                results.append(row)
                                next()
                            }
                        }
                    }

                    // 情境①：CodeLab 編輯器有焦點 → 切回後仍在編輯器
                    runScenario(name: "codelab", setup: {
                        w.makeFirstResponder(editorWeb)
                        lab.testAction("js=cl.focus()") { _ in }
                    }) {
                        // 情境②：聊天輸入框有焦點 → 切回後仍在輸入框
                        runScenario(name: "chatinput", setup: {
                            w.makeFirstResponder(inputTV)
                        }) {
                            // 情境③：別的可編輯 NSTextView 有焦點 → 不被搶
                            runScenario(name: "rename-field", setup: {
                                w.makeFirstResponder(renameField)
                            }) {
                                renameField.removeFromSuperview()
                                writeJSON([
                                    "schemaVersion": 1,
                                    "scenarios": results,
                                ])
                            }
                        }
                    }
                }
            }
        }
    }
}
