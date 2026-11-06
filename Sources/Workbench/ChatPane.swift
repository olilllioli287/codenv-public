import AppKit
import WebKit
import SwiftUI
import Combine

/// 對話內容的網頁元件：檔案、圖片拖進來不要讓網頁吃掉（會被當成「打開這個檔案」），交給輸入框
final class DropWebView: WKWebView {
    var onDrop: ((NSPasteboard) -> Bool)?
    private func wanted(_ pb: NSPasteboard) -> Bool {
        if DropOverlay.conversation(in: pb) != nil { return false }
        return pb.availableType(from: [.fileURL, .png, .tiff, NSPasteboard.PasteboardType("public.jpeg")]) != nil
            || pb.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
    }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { wanted(s.draggingPasteboard) ? .copy : super.draggingEntered(s) }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation { wanted(s.draggingPasteboard) ? .copy : super.draggingUpdated(s) }
    override func prepareForDragOperation(_ s: NSDraggingInfo) -> Bool { wanted(s.draggingPasteboard) ? true : super.prepareForDragOperation(s) }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        ChatTextView.dropLog("對話內容 收=\(wanted(s.draggingPasteboard))", s.draggingPasteboard)
        if wanted(s.draggingPasteboard) { return onDrop?(s.draggingPasteboard) ?? false }
        return super.performDragOperation(s)
    }
}

/// 右邊一格對話要有的東西：聊天或終端機都一樣
protocol ConversationPane: NSView {
    var focusTarget: NSView { get }
    /// 右下角讓給桌寵的空間（只有畫面最右下那一格會有）
    var petReserve: NSSize { get set }
    func terminate()
    func applyTheme(_ t: Theme)
}

extension TerminalPane: ConversationPane {
    var focusTarget: NSView { terminal }
    func applyTheme(_ t: Theme) { theme = t; applyTheme() }
}

/// WKWebView 會強留 message handler，中間隔一層 weak 才不會互相抓住
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: ChatPane?
    init(_ t: ChatPane) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { target?.received(m) }
}

/// 聊天介面的一格：上面是對話內容（網頁畫面 Resources/chat），下面是原生輸入框
final class ChatPane: NSView, ConversationPane, WKNavigationDelegate {
    let session: ChatSession
    private var web: DropWebView?
    var hasWeb: Bool { web != nil }
    var pendingNoticeCount: Int { lastNotices.count }   // 測試用：還沒被看到、記著的提示數
    /// 測試用（--web-probe）：畫面上的文字；網頁不在或還沒好就回說明
    func testWebText(_ done: @escaping (String) -> Void) {
        guard CommandLine.arguments.contains("--state-dir") else { return }
        guard let web else { return done("(沒有網頁)") }
        guard ready else { return done("(網頁還沒好)") }
        web.evaluateJavaScript("document.body.innerText") { r, _ in done(r as? String ?? "(讀不到)") }
    }
    /// 不在任何視窗裡才算隱藏；背景預熱只建立 ChatPane 外殼。
    private(set) var hiddenSince: Date? = Date()
    var webPID: Int {
        guard let web, web.responds(to: NSSelectorFromString("_webProcessIdentifier")) else { return -1 }
        return (web.value(forKey: "_webProcessIdentifier") as? NSNumber)?.intValue ?? -1
    }
    let inputBar = ChatInputBar()
    /// 程式碼學習專區：右邊的程式碼區（CodeLab.swift）；其他組的對話沒有
    private(set) var codeLab: CodeLabView?
    private let codeDivider = CodeLabDivider()
    private var codeShare: CGFloat = CGFloat(appDefaults.object(forKey: "codeLabShare") as? Double ?? 0.55)
    private var theme: Theme
    private var ready = false
    private var unloadingWeb = false
    /// 網頁卸載前記下的閱讀位置（JSON 字串，重建後交給 wb.restoreAnchor）
    private var scrollAnchor: String?
    private var queued: [String] = []
    private var onReadyCallbacks: [() -> Void] = []
    private var pendingControlLines: [String] = []
    private var lastNotices: [String] = []
    /// 對話壓縮完（本機模型的自動壓縮在回答完之後才做完）：md 紀錄要再寫一次，摘要才會進去
    var onCompacted: (() -> Void)?
    /// 背景替這段對話跑的模型（nil＝沒有）：右側欄「使用中」用
    var onBackgroundModel: ((String?) -> Void)?
    var onStatus: ((ChatStatus) -> Void)?
    /// 第一次送出時給標題用
    var onFirstMessage: ((String) -> Void)?
    /// 要求變成目前這格（拖放進來時：之後切回 App 的游標也放在這格）
    var onWantFocus: (() -> Void)?
    /// 這格是哪段對話（給上下文大小用）
    var conversationID: UUID? {
        didSet {
            guard conversationID != oldValue else { return }
            if let old = oldValue { SessionActivity.shared.unregister(old) }
            // 只有 Claude 自己的程序才掃它底下；其他家（agy、codex…）的聊天室不是 claude 程序
            if let id = conversationID { SessionActivity.shared.register(id, pid: { [weak self] in
                guard let s = self?.session, s.agyModel == nil, s.codexModel == nil, s.copilotModel == nil, s.mlxModel == nil, s.appleModel == nil else { return nil }
                return s.pid
            }, stopTask: { [weak self] tid in self?.session.stopTask(tid) }) }
        }
    }
    /// 使用者換了模型（存到對話裡）
    var onModelChange: ((String?) -> Void)?
    /// Claude 回報實際在用的模型（右側欄顯示用）
    var onResolvedModel: ((String) -> Void)?
    var onEffortChange: ((String?) -> Void)?
    var onPermissionModeChange: ((String?) -> Void)?
    var openSettings: (() -> Void)?
    private var resolvedModel = ""
    private var sentAny = false
    private var quotes: [MessageQuote] = []

    private var draftPersistence: DraftPersistence?
    private var checkedOutbox = false
    private var recoveringOutbox = false
    private var recoveredOutboxIDs = Set<String>()
    private var recoveredOutboxDraft: (text: String, quotes: [MessageQuote], files: [String], images: [DraftPersistence.Image])?

    func configureDraftPersistence(directory: URL) {
        guard let id = conversationID else { return }
        let persistence = DraftPersistence(directory: directory, conversationID: id)
        draftPersistence = persistence
        session.outboxPersistence = OutboxPersistence(directory: directory, conversationID: id)
        session.onOutboxError = { [weak self] message in self?.notice(message) }
        inputBar.onDraftChange = { [weak self] in
            DispatchQueue.main.async { self?.persistDraftSoon() }
        }
        inputBar.onPendingInputChange = { [weak self] in self?.persistDraftSoon() }
        restoreSavedDraft()
    }

    func removeSavedDraft() { draftPersistence?.remove() }

    func restoreSavedDraftIfNeeded() {
        restoreSavedDraft()
        restoreOutboxIfNeeded()
    }

    private var toldOutboxWaiting = false
    private func restoreOutboxIfNeeded() {
        guard window != nil, !checkedOutbox, let outbox = session.outboxPersistence else { return }
        checkedOutbox = true
        let inFlight = session.inFlightIDs
        do { try restoreOutbox(try outbox.reconcile(transcriptURLs: session.allTranscripts.map(\.url)).filter { !inFlight.contains($0.id) }, from: outbox) }
        catch { notice(L("寄件匣讀取或更新失敗，已保留原檔，請檢查 outbox 資料夾。")) }
    }

    private func restoreOutbox(_ records: [OutboxPersistence.Record], from outbox: OutboxPersistence) throws {
        guard !records.isEmpty else { return }
        // 不覆蓋既有草稿、不拿焦點，也不把這些紀錄交回發送佇列。
        guard !inputBar.hasPendingInput else {
            // 原文還在寄件匣（不會丟），只是輸入框有字先不放；講清楚怎麼拿回來（agy Opus 11/6 審查）
            if !toldOutboxWaiting { notice(L("上次有訊息不確定有沒有送到；輸入框有字，先沒放回來。清空輸入框後切到別的聊天室再切回來就會放回")) }
            toldOutboxWaiting = true
            checkedOutbox = false // 下次這格回到視窗（切回來）再檢查一次
            return
        }
        notice(records.count == 1 ? L("上次有一則訊息不確定有沒有送到") : L("上次有多則訊息不確定有沒有送到"))
        var texts: [String] = [], images: [DraftPersistence.Image] = []
        for record in records {
            var text = record.text
            let source = try outbox.draftImages(record) // 缺圖就保留原檔、提示，不還原不完整的快照。
            guard source.allSatisfy({ NSImage(data: $0.data) != nil }) else { throw CocoaError(.fileReadCorruptFile) }
            // 程式代送的圖片可能沒有文字標記；restoreImages 不插字，這裡補上才能讓 textChanged 保留附件。
            for image in source where !text.contains(ChatInputBar.imageToken(image.no)) {
                text += (text.isEmpty ? "" : " ") + ChatInputBar.imageToken(image.no)
            }
            if records.count == 1 {
                images = source
            } else {
                var replacements: [Int: Int] = [:]
                for var image in source {
                    let newNo = images.count + 1
                    replacements[image.no] = newNo
                    image.no = newNo
                    images.append(image)
                }
                // 從後往前替換，避免 #1→#2 之後又被 #2→#3 替換一次。
                let ns = text as NSString
                let regex = try NSRegularExpression(pattern: #"\[Image #(\d+)\]"#)
                for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
                    if let no = Int(ns.substring(with: match.range(at: 1))), let newNo = replacements[no],
                       let range = Range(match.range, in: text) { text.replaceSubrange(range, with: ChatInputBar.imageToken(newNo)) }
                }
            }
            texts.append(text)
        }
        recoveringOutbox = true
        defer { recoveringOutbox = false }
        inputBar.textView.string = texts.joined(separator: "\n\n")
        inputBar.textView.undoManager?.removeAllActions()
        inputBar.restoreImages(images)
        inputBar.restoreFilePaths(records.flatMap(\.filePaths))
        var seen = Set<String>()
        setQuotes(records.flatMap(\.quotes).filter { seen.insert($0.qid).inserted }, syncWeb: true)
        inputBar.textView.didChangeText()
        rememberRecoveredOutbox(ids: Set(records.map(\.id)))
    }

    private func rememberRecoveredOutbox(ids: Set<String>) {
        recoveredOutboxIDs.formUnion(ids)
        recoveredOutboxDraft = (inputBar.textView.string, quotes, inputBar.draftFilePaths, inputBar.draftImages)
        flushDraft()
    }

    private var isUneditedOutboxDraft: Bool {
        guard !recoveredOutboxIDs.isEmpty, let original = recoveredOutboxDraft else { return false }
        let images = inputBar.draftImages
        return inputBar.textView.string == original.text && quotes == original.quotes
            && inputBar.draftFilePaths == original.files && images.count == original.images.count
            && zip(images, original.images).allSatisfy { a, b in
                a.data == b.data && a.mediaType == b.mediaType && a.no == b.no && a.edited == b.edited
            }
    }

    /// main.swift 的隔離測試掛鉤；seed 只寫 fixture，絕不呼叫 send 或開啟後端。
    func probeOutbox(_ action: String) throws -> String {
        guard CommandLine.arguments.contains("--state-dir"), let outbox = session.outboxPersistence else { return "" }
        let responder = window?.firstResponder
        let keyWindow = NSApp.keyWindow
        if action == "seed" || action == "seed-delivered" {
            let directory = outbox.fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("probe-attachment.txt")
            try "附件 fixture".write(to: file, atomically: true, encoding: .utf8)
            let id = UUID().uuidString.lowercased()
            let text = "寄件匣復原測試 \(id)\n" + TerminalPane.shellEscape(file.path) + " [Image #7]"
            let transcript = directory.appendingPathComponent("probe-\(id).jsonl")
            let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGOQa/rwH4QZYAwAVgwKPaFOh1UAAAAASUVORK5CYII=")!
            try outbox.append(id: id, text: text, wireText: text, quotes: [MessageQuote(qid: "probe", role: "assistant", text: "寄件匣引用測試")],
                              filePaths: [file.path], images: [(image, "image/png")], transcriptURLs: [transcript],
                              imageDrafts: [DraftPersistence.Image(data: image, mediaType: "image/png", no: 7, edited: true)])
            if action == "seed-delivered" {
                let row: [String: Any] = ["type": "user", "uuid": id, "message": ["role": "user", "content": [["type": "text", "text": text]]]]
                try (JSONSerialization.data(withJSONObject: row) + Data([0x0a])).write(to: transcript, options: .atomic)
            }
        } else if action == "recover" {
            checkedOutbox = false
            restoreOutboxIfNeeded()
        }
        let records = try outbox.read()
        let object: [String: Any] = ["path": outbox.fileURL.path, "input": inputBar.textView.string,
                                     "quotes": quotes.map(\.qid), "filePaths": inputBar.draftFilePaths,
                                     "outboxIDs": records.map(\.id), "imagePaths": records.flatMap(\.images).map(\.path),
                                     "hasUnackedInput": session.hasUnacknowledgedInput,
                                     "imageNos": inputBar.draftImages.map(\.no), "edited": inputBar.draftImages.map(\.edited),
                                     "uneditedRecovery": isUneditedOutboxDraft,
                                     "notices": lastNotices,
                                     "focusUnchanged": responder === window?.firstResponder && keyWindow === NSApp.keyWindow]
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    }

    private func persistDraftSoon() {
        guard !recoveringOutbox, let persistence = draftPersistence else { return }
        // 原樣復原的快照仍由寄件匣保管，避免重開後先還原已送達的舊副本。
        // 使用者修改後就走既有草稿存圖，不建立第二套圖片關聯。
        if isUneditedOutboxDraft { persistence.remove(); return }
        if inputBar.hasPendingInput {
            persistence.schedule(text: inputBar.textView.string, quotes: quotes, filePaths: inputBar.draftFilePaths, images: inputBar.draftImages)
        } else { persistence.remove() }
        releaseRecoveredOutbox()
    }

    /// 放回輸入框的寄件匣訊息，使用者清空了（＝丟掉）或改過了（＝改由草稿保管）：寄件匣那幾筆刪掉。
    /// 不然清空後下次開格子又被塞回來、改過後每次都跳「不確定有沒有送到」（agy Sonnet 11/6）
    private func releaseRecoveredOutbox() {
        guard !recoveredOutboxIDs.isEmpty, !isUneditedOutboxDraft else { return }
        // 先把改過的版本存成草稿，確定寫進去了才刪寄件匣；寫不進去就留著寄件匣（agy Argon 11/6 審查）
        if inputBar.hasPendingInput, !flushDraft() {
            notice(L("草稿存不進去（請檢查磁碟空間），寄件匣的原文先保留")); return
        }
        do {
            try session.outboxPersistence?.remove(ids: recoveredOutboxIDs)
            recoveredOutboxIDs.removeAll()
            recoveredOutboxDraft = nil
        } catch { notice(L("寄件匣更新失敗，已保留原檔；重開時會再對照對話紀錄。")) }
    }

    /// 回傳草稿有沒有存好（沒有草稿設定、或沒東西要存都算 true）
    @discardableResult
    func flushDraft() -> Bool {
        guard let persistence = draftPersistence else { return true }
        if isUneditedOutboxDraft { persistence.remove(); return true }
        if inputBar.hasPendingInput {
            return persistence.write(text: inputBar.textView.string, quotes: quotes, filePaths: inputBar.draftFilePaths, images: inputBar.draftImages)
        }
        persistence.remove(); return true
    }

    private func restoreSavedDraft() {
        guard let persistence = draftPersistence,
              inputBar.textView.string.isEmpty, !inputBar.hasQuotes, !inputBar.hasPendingInput,
              let saved = persistence.read() else { return }
        inputBar.textView.string = saved.text
        inputBar.restoreImages(persistence.readImages(saved))
        inputBar.restoreFilePaths(saved.filePaths)
        inputBar.textView.didChangeText()
        setQuotes(saved.quotes, syncWeb: true)
    }

    private func setQuotes(_ items: [MessageQuote], syncWeb: Bool = false) {
        quotes = items
        inputBar.hasQuotes = !items.isEmpty
        inputBar.onPendingInputChange?()
        if syncWeb, let data = try? JSONEncoder().encode(items), let json = String(data: data, encoding: .utf8) { js("wb.restoreQuotes(\(json))") }
    }
    /// 換模型前那個模型的紀錄檔：新的模型看不到前面的對話，下一則送出時附一行告訴它去哪裡讀
    private var carryFrom: URL?
    private var carryName: String?      // 換之前的模型叫什麼（輸入框右下角顯示的名字，交接時寫給新模型看）

    var focusTarget: NSView { inputBar.textView }
    var petReserve: NSSize = .zero { didSet { if petReserve != oldValue { needsLayout = true } } }
    private var lastPetInset = NSSize.zero

    static var chatFolder: URL {
        if let u = Bundle.main.resourceURL?.appendingPathComponent("chat"), FileManager.default.fileExists(atPath: u.appendingPathComponent("index.html").path) { return u }
        // 直接跑 .build 裡的執行檔時：用原始碼旁邊的
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/chat")
    }

    init(session: ChatSession, theme: Theme) {
        self.session = session
        self.theme = theme
        super.init(frame: .zero)
        addSubview(inputBar)

        inputBar.onSend = { [weak self] text, images, now in self?.send(text: text, images: images, now: now) ?? false }
        inputBar.onModelButton = { [weak self] v in self?.showModelPanel(from: v) }
        inputBar.onToolsButton = { [weak self] v in self?.onToolsMenu?(v) }
        session.onModel = { [weak self] m in self?.resolvedModel = m; self?.refreshModelTitle(); self?.onResolvedModel?(m) }
        session.onModels = { [weak self] _ in self?.refreshModelTitle() }
        session.onCommands = { [weak self] l in self?.inputBar.commands = l }
        inputBar.onCycleMode = { [weak self] in self?.cycleMode() }
        session.onPermissionMode = { [weak self] m in self?.refreshMode(); self?.onPermissionModeChange?(m) }
        session.onPermissionModeError = { [weak self] err in
            guard let self else { return }
            self.refreshMode()
            self.onPermissionModeChange?(self.session.permissionMode)
            self.notice(L("沒辦法換權限模式：\(err)"))
        }
        inputBar.onStop = { [weak self] in
            guard let self else { return }
            ChatTextView.dropLog("按了停止（⌃ C 或停止鍵）\(self.conversationTitleForLog)", nil)
            self.session.interrupt()
        }
        inputBar.onSendQueuedNow = { [weak self] in self?.js("wb.sendQueuedNow()") }
        inputBar.onBang = { [weak self] cmd in self?.runBang(cmd) ?? false }
        inputBar.onStopBang = { [weak self] in self?.stopBang() }
        inputBar.onBangCancel = { [weak self] in self?.dismissBang() }
        // 拖東西進來：工作台跳到最前面、游標進這格的輸入框，放完直接 ⌘ Enter 就能送
        inputBar.onDropped = { [weak self] in
            guard let self, !CommandLine.arguments.contains("--background") else { return }   // 背景測試不要搶走前景
            self.onWantFocus?()
            NSApp.activate()
            self.window?.makeKeyAndOrderFront(nil)
            self.focusInput()
        }
        inputBar.onBlur = { [weak self] in
            guard let self, let web = self.web else { return }
            self.window?.makeFirstResponder(web)
        }
        session.onLine = { [weak self] line, obj in
            guard let self else { return }
            let type = obj["type"] as? String
            self.markOwnActivity(final: type == "result")
            SessionActivity.shared.observe(obj, conversation: self.conversationID, directory: self.session.directory)
            // Gemini（agy）、ChatGPT（codex）、Copilot、本機模型自己不會猜下一句：每輪結束另外猜（NextGuess.swift；Flash 的聊天室用 Flash，其他用 Apple）
            let s = self.session
            if s.agyModel != nil || s.codexModel != nil || s.copilotModel != nil || s.mlxModel != nil || s.appleModel != nil {
                self.nextGuess.saw(obj, flash: s.agyModel?.hasPrefix("gemini-3.8-flash") == true) { [weak self] s in
                    guard let self, self.session.status == .idle, self.inputBar.textView.string.isEmpty else { return }
                    self.inputBar.suggestion = s
                }
            }
            // 回答完 Claude 猜的下一句：放進輸入框當灰字
            if type == "prompt_suggestion" {
                if let s = obj["suggestion"] as? String, self.session.status == .idle { self.inputBar.suggestion = s }
                return
            }
            // Claude 讀進了使用者的訊息（--replay-user-messages 回送的那份）：排隊中的泡泡移到對話裡
            if type == "user", obj["isReplay"] as? Bool == true {
                if let u = obj["uuid"] as? String { self.js("wb.userTaken(\(Self.jsString(u)))") }
                return
            }
            // 這一輪結束：紀錄檔到這裡都是自己寫的，同步顯示之後從這裡接（不然會把自己的訊息再貼一次）
            if type == "result", let url = self.session.transcriptURL,
               let n = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                self.followOffset = UInt64(n); self.followPartial = Data()
            }
            // Claude 收回權限詢問：畫面上那張卡也收掉，不要還能按
            if type == "control_cancel_request", let id = obj["request_id"] as? String {
                self.removePendingControl(id)
                self.js("wb.permissionResolved(\(Self.jsString(id)), \(Self.jsString(L("Claude 收回了這個詢問"))))")
            }
            if type == "control_request", self.web == nil { self.pendingControlLines.append(line) }
            self.js("wb.event(\(line))")
            ContextMonitor.shared.observe(obj, conversation: self.conversationID)
            if obj["type"] as? String == "system", obj["subtype"] as? String == "status" {
                self.onBackgroundModel?(obj["status"] as? String == "compacting" ? L("Claude Haiku・背景整理摘要") : nil)
            }
            if obj["type"] as? String == "system", obj["subtype"] as? String == "compact_boundary",
               let m = obj["compact_metadata"] as? [String: Any] {
                let pre = (m["pre_tokens"] as? NSNumber)?.intValue ?? 0, post = (m["post_tokens"] as? NSNumber)?.intValue ?? 0
                self.notice(L("已壓縮對話：\(ContextMonitor.text(pre)) → \(ContextMonitor.text(post)) token（原本的紀錄檔還在）"))
                self.onCompacted?()
            }
        }
        session.onStatus = { [weak self] s in
            guard let self else { return }
            // 網頁卸載後在背景開始忙（排程、交接、背景工作回報）：先把網頁建回來，串流事件才不會被丟掉（agy Argon 11/6）
            if s != .idle, self.web == nil, self.codeLab?.mode != .noAI { self.ensureWeb() }
            self.inputBar.busy = s != .idle
            self.js("wb.setBusy(\(s != .idle))")
            self.onStatus?(s)
        }
        session.onLost = { [weak self] lost in
            guard let self else { return }
            guard let outbox = self.session.outboxPersistence else { return }
            do {
                let pending = try outbox.reconcile(transcriptURLs: self.session.allTranscripts.map(\.url))
                let uncertain = Set(pending.map(\.id))
                for m in lost {
                    self.js(uncertain.contains(m.uuid) ? "wb.unsend(\(Self.jsString(m.uuid)))" : "wb.userTaken(\(Self.jsString(m.uuid)))")
                }
                let ids = Set(lost.map(\.uuid))
                try self.restoreOutbox(pending.filter { ids.contains($0.id) }, from: outbox)
            } catch {
                for m in lost { self.js("wb.unsend(\(Self.jsString(m.uuid)))") }
                self.notice(L("寄件匣讀取或更新失敗，已保留原檔，請檢查 outbox 資料夾。"))
            }
        }
        // 主動結束也清活動紀錄：不清的話舊程序的背景清單會在同一格開新程序後又被當真，格子永遠收不掉（Codex 11/6）
        session.onTerminated = { [weak self] in
            if let id = self?.conversationID { SessionActivity.shared.clear(id) }
        }
        session.onExit = { [weak self] code, err in
            guard let self else { return }
            self.pendingControlLines.removeAll()
            let who = self.agentName
            self.js("wb.resolveAllPermissions(\(Self.jsString(L("\(who) 已經結束，這個詢問作廢了"))))")
            self.js("wb.flushQueued()")
            if let id = self.conversationID { SessionActivity.shared.clear(id) }   // 程序沒了，還沒回答的詢問也作廢
            guard code != 0 && code != 15 else { return }
            let tail = err.split(separator: "\n").suffix(3).joined(separator: " / ")
            self.notice(L("\(who) 結束了（\(code)）\(tail.isEmpty ? "" : "：" + tail)。再送一則訊息會重新接上。"))
        }
        wantsLayer = true
        applyTheme(theme)
        // 整體文字大小：對話內容用網頁縮放、輸入框換字級
        applyScale()
        scaleSink = UIScale.shared.$factor.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.applyScale() }
        // 設定頁換了程式碼顏色：馬上套用
        prefsSink = Prefs.shared.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { guard let self else { return }; self.applyTheme(self.theme) }
        }
    }

    private var scaleSink: AnyCancellable?
    private var prefsSink: AnyCancellable?
    private func applyScale() {
        web?.pageZoom = UIScale.shared.f
        inputBar.setFontScale(UIScale.shared.f)
        needsLayout = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            hiddenSince = Date()
        } else {
            hiddenSince = nil
            unloadingWeb = false
            if web != nil, ready { lastNotices.removeAll() }   // 隱藏時記著的提示已經在這頁上了，現在看得到＝看過
            restoreOutboxIfNeeded()
            if codeLab?.mode != .noAI { ensureWeb() }
        }
    }

    func ensureWeb() {
        // 背景建回（代送、轉忙）：隱藏時間重新起算，閒下來不會馬上又被卸載（agy Sonnet 11/6）
        if web == nil, window == nil { hiddenSince = Date() }
        guard web == nil else { return }
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // Markdown 裡的本機圖片仍只透過 codenv-img:// 讀取。
        config.setURLSchemeHandler(LocalImageScheme.shared, forURLScheme: LocalImageScheme.scheme)
        config.userContentController.add(WeakHandler(self), name: "wb")
        if I18n.isEnglish { config.userContentController.addUserScript(WKUserScript(source: "window.__LOCALE=\(I18n.tableJSON);", injectionTime: .atDocumentStart, forMainFrameOnly: true)) }
        let w = DropWebView(frame: .zero, configuration: config)
        web = w
        w.navigationDelegate = self
        w.onDrop = { [weak self] pb in self?.inputBar.takeDrop(pb) ?? false }
        w.setValue(false, forKey: "drawsBackground")
        w.pageZoom = UIScale.shared.f
        addSubview(w, positioned: .below, relativeTo: inputBar)
        lastPetInset = .zero
        needsLayout = true
        applyTheme(theme)
        w.loadFileURL(Self.chatFolder.appendingPathComponent("index.html"), allowingReadAccessTo: Self.chatFolder)
    }

    var canUnloadWeb: Bool {
        guard web != nil, ready, !unloadingWeb, onReadyCallbacks.isEmpty else { return false }
        if session.status != .idle || inputBar.busy || session.hasUnacknowledgedInput { return false }
        if inputBar.hasPendingInput || !quotes.isEmpty || webEditing || isBangRunning { return false }
        if carryFrom != nil || !pendingControlLines.isEmpty { return false }
        return true
    }

    func unloadWeb() {
        guard canUnloadWeb, let w = web else { return }
        unloadingWeb = true
        w.evaluateJavaScript("wb.scrollAnchor()") { [weak self, weak w] obj, _ in
            guard let self, let w, self.web === w, self.unloadingWeb else { return }
            self.unloadingWeb = false
            guard self.window == nil, self.canUnloadWeb else { return }
            self.scrollAnchor = Self.scrollAnchorJSON(obj)
            self.finishUnloadWeb(w)
        }
    }

    private func finishUnloadWeb(_ w: DropWebView) {
        // 同步顯示的鎖定由 checkLive 在重建後重新判斷，避免別處結束後留下舊鎖。
        if followTimer != nil { inputBar.setLocked(nil) }
        followTimer?.invalidate()
        followTimer = nil
        followPartial = Data()
        w.configuration.userContentController.removeScriptMessageHandler(forName: "wb")
        w.navigationDelegate = nil
        w.onDrop = nil
        w.stopLoading()
        w.removeFromSuperview()
        web = nil
        ready = false
        queued.removeAll()
        older = nil
        webEditing = false
        lastPetInset = .zero
    }

    private static func scrollAnchorJSON(_ obj: Any?) -> String? {
        guard let dict = obj as? [String: Any],
              JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    override func layout() {
        super.layout()
        // 有桌寵空位：輸入框讓出右邊；對話區高度不變（空位疊在它右下角），只有內容最底下多留一段，最新的字停在桌寵上面
        let r = petReserve
        // 有程式碼區：左邊聊天、右邊程式碼（中間那條可以拖）
        var cw = bounds.width
        // 不用 AI 的版面：程式碼區佔滿整格，聊天先收起來（換回別的版面就回來）
        let noAI = codeLab?.mode == .noAI
        if window != nil, web == nil, !noAI { ensureWeb() }
        web?.isHidden = noAI
        [inputBar, codeDivider].forEach { $0.isHidden = noAI }
        if noAI, let lab = codeLab { lab.frame = bounds; return }
        if let lab = codeLab {
            cw = (bounds.width * (1 - codeShare)).rounded()
            codeDivider.frame = NSRect(x: cw - 3, y: 0, width: 6, height: bounds.height)
            lab.frame = NSRect(x: cw + 3, y: 0, width: max(0, bounds.width - cw - 3), height: bounds.height)
            cw -= 3
        }
        let h = inputBar.fittingHeight(width: cw - (codeLab == nil ? r.width : 0))
        inputBar.frame = NSRect(x: 0, y: 0, width: cw - (codeLab == nil ? r.width : 0), height: h)
        web?.frame = NSRect(x: 0, y: h, width: cw, height: max(0, bounds.height - h))
        let inset = r == .zero ? NSSize.zero : NSSize(width: r.width, height: max(0, r.height - h))
        if inset != lastPetInset {
            lastPetInset = inset
            js("wb.setPetInset(\(Int(inset.width)), \(Int(inset.height)))")
        }
    }

    /// 開右邊的程式碼區（程式放在 directory）
    func attachCodeLab(directory: String, key: String) {
        guard codeLab == nil else { return }
        let lab = CodeLabView(directory: directory, key: key, theme: theme)
        codeLab = lab
        addSubview(codeDivider)
        addSubview(lab)
        lab.onModeChange = { [weak self] in self?.needsLayout = true }
        lab.onAskAI = { [weak self] text in
            guard let self else { return false }
            self.inputBar.setDraft(text)
            return true
        }
        codeDivider.onDrag = { [weak self] x in
            guard let self else { return }
            let local = self.convert(NSPoint(x: x, y: 0), from: nil).x
            self.codeShare = max(0.25, min(0.75, 1 - local / max(1, self.bounds.width)))
            appDefaults.set(Double(self.codeShare), forKey: "codeLabShare")
            self.needsLayout = true
        }
        needsLayout = true
    }

    func applyTheme(_ t: Theme) {
        codeLab?.applyTheme(t)
        theme = t
        let pal = t.palette(for: effectiveAppearance)
        layer?.backgroundColor = pal.bg.cgColor
        inputBar.applyTheme(pal, mono: t.font)
        refreshMode()
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        var obj: [String: Any] = ["fg": pal.fg.hex, "bg": pal.bg.hex, "ansi": pal.ansi.map(\.hex),
                                  "monoFont": t.font.fontName, "monoSize": t.font.pointSize, "dark": dark]
        // 對話文字跟終端機一樣：同一個字型、粗細；大小在預設的介面縮放下剛好等於終端機的點數
        let termText = Prefs.shared.chatFont == "terminal"
        if termText {
            obj["bodyFont"] = t.font.familyName ?? t.font.fontName
            obj["bodyWeight"] = Self.cssWeight(t.font)
            obj["bodySize"] = Double(t.font.pointSize) / UIScale.defaultFactor
        }
        inputBar.textFont = termText ? t.font : nil
        if I18n.isEnglish { js("wb.setLocale(\(I18n.tableJSON))") }     // 英文介面：chat.js 的 L() 用同一份對照表（要在 setTheme 之前，畫面才一開始就是英文）
        if let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) { js("wb.setTheme(\(s))") }
        js(CodeColors.js(palette: pal, dark: dark))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme(theme)
    }

    func terminate() {
        followTimer?.invalidate()
        flushDraft()   // 防抖還沒寫的草稿先落盤（格子要被收掉了，1 秒後的存檔可能等不到；agy Argon 11/6）
        // 跑到一半的 ! 指令：格子一關 ChatPane 就放掉了，結束的回呼（bangEnd 才存檔）永遠不會來，已經收到的輸出會整段消失。先把目前收到的存下來、標成已停止
        if isBangRunning { for i in bangRecords.indices where bangRecords[i].running { bangRecords[i].status = "stopped" }; saveBang() }
        stopBang(); session.terminate()
    }   // 跑到一半的 ! 指令也停掉，不然它的程序群組會留在背景跑到逾時

    // MARK: 模型

    /// 這格實際在跑的是誰（提示文字用）
    var agentName: String {
        session.agyModel != nil ? "Gemini" : session.codexModel != nil ? "ChatGPT" : session.copilotModel != nil ? "Copilot"
            : session.appleModel != nil ? L("Apple 模型")
            : session.mlxModel != nil || session.localEndpoint != nil ? L("本機模型") : "Claude"
    }

    func refreshModelTitle() {
        refreshModelName()
        // 沒自己選過強度就顯示預設的（跟模型面板拉桿停的位置一樣）
        guard session.localEndpoint == nil, let e = session.effort ?? defaultEffortNow else { return }
        // agy 只有低中高三段（換名字尾巴），從 Claude 帶來的 xhigh、max 不算數
        let few = session.agyModel != nil ? AgyBridge.levels : session.copilotModel != nil ? CopilotBridge.levels : session.mlxModel != nil ? LocalBridge.levels(session.mlxModel)
            : session.appleModel != nil ? [] : nil
        if few?.contains(e) ?? true { inputBar.modelTitle += " · " + Effort.name(e) }
    }

    /// 沒選過強度時實際用的那段：各家的預設，Claude 看 settings.json 裡這個模型的 effortLevel
    private var defaultEffortNow: String? {
        if let m = session.agyModel { return AgyBridge.level(m) }
        if session.codexModel != nil { return CodexBridge.defaultLevel }
        if session.copilotModel != nil { return CopilotBridge.defaultLevel }
        if session.appleModel != nil { return nil }
        if session.mlxModel != nil { return LocalBridge.defaultLevel(session.mlxModel) }
        let choice = currentChoice
        return ClaudeSettings.effort(for: choice?.resolved.isEmpty == false ? choice!.resolved : resolvedModel)
    }

    /// 目前選的模型（給思考強度選單看它支援哪幾段）
    private var currentChoice: ModelChoice? {
        let known = ModelChoice.known
        if let m = session.model { return known.first { $0.value == m } }
        if !resolvedModel.isEmpty { return known.first { $0.resolved == resolvedModel } }
        return known.first { $0.value == "default" }
    }

    private func refreshModelName() {
        setModelName()
        // 右邊「正在跑」那區在聊天室名字後面標模型（Activity.swift）：用按鈕上同一個名字
        if let id = conversationID { SessionActivity.shared.setModel(id, inputBar.modelTitle) }
    }

    private func setModelName() {
        if let local = session.localEndpoint { inputBar.modelTitle = local.name; return }
        if let m = session.agyModel { inputBar.modelTitle = AgyBridge.name(m); return }
        if let m = session.codexModel { inputBar.modelTitle = CodexBridge.name(m); return }
        if let m = session.copilotModel { inputBar.modelTitle = CopilotBridge.name(m); return }
        if let m = session.mlxModel { inputBar.modelTitle = LocalBridge.name(m); return }
        if let m = session.appleModel { inputBar.modelTitle = AppleBridge.name(m); return }
        let known = ModelChoice.known
        if let m = session.model, m != "default" {
            inputBar.modelTitle = known.first { $0.value == m }?.name ?? m
            return
        }
        // 沒選模型（預設）：Claude 實際回報的 → 上次預設實際跑出來的（還沒跑起來時）→ 清單上說預設是哪個
        // （清單說預設是 Sonnet，實際卻可能是 Opus，使用者 10/25）
        let d = known.first { $0.value == "default" }
        let live = [resolvedModel, appDefaults.string(forKey: "lastDefaultModel") ?? "", d?.resolved ?? ""].first { !$0.isEmpty } ?? ""
        inputBar.modelTitle = known.first { $0.resolved == live && $0.value != "default" }?.name ?? (live.isEmpty ? (d?.name ?? L("預設模型")) : live)
    }

    private var panel: FloatingPanel?
    private let panelModel = ModelPanelModel()
    private let nextGuess = NextGuess.Tracker()   // 不是 Claude 的聊天室：每輪結束猜下一句
    private var panelHost: NSHostingView<ModelPanel>?
    private var lastPanelClose = Date.distantPast

    /// 右下角按下去：思考強度拉桿＋模型清單（自己畫的浮動面板，右緣對齊輸入框，不會伸進桌寵的格子）
    private func showModelPanel(from v: NSView) {
        if let p = panel, p.isVisible { p.close(); return }
        // 點按鈕想關掉：面板在按下時已經自己關了，放開時別又打開
        if Date().timeIntervalSince(lastPanelClose) < 0.4 { return }
        refreshPanel()
        panelModel.showingModels = false
        panelModel.onEffort = { [weak self] e in
            guard let self else { return }
            self.applyEffort(e)
            self.onEffortChange?(e)
            self.refreshPanel()
        }
        panelModel.onPickModel = { [weak self] value in
            guard let self else { return }
            self.applyModel(value)
            self.onModelChange?(value == "default" ? nil : value)
            self.refreshPanel()
        }
        panelModel.onLocalSettings = { [weak self] in self?.panel?.close(); self?.openSettings?() }
        panelModel.onSetDefault = { [weak self] e in
            guard let self else { return }
            self.panelModel.defaultNote = L("存檔中…")
            self.session.saveDefaultEffort(e) { [weak self] ok in
                guard let self else { return }
                if ok { self.panelModel.defaultEffort = e }
                self.panelModel.defaultNote = ok ? L("已設為預設：") + Effort.name(e) : L("存不進去，再試一次")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.panelModel.defaultNote = nil }
            }
        }
        panelModel.onSizeChange = { [weak self] in DispatchQueue.main.async { self?.placePanel(animated: true) } }
        let host = NSHostingView(rootView: ModelPanel(m: panelModel))
        host.sizingOptions = []          // 不要讓它自己撐大視窗（它會固定上緣往下長）；大小由 placePanel 算
        panelHost = host
        let p = FloatingPanel(content: host)
        p.onClose = { [weak self] in self?.panel = nil; self?.lastPanelClose = Date() }
        panel = p
        placePanel()
        p.closeWhenMouseLeaves()
        window?.addChildWindow(p, ordered: .above)
        p.orderFront(nil)
    }

    func testShowModelList() { panelModel.showingModels = true; placePanel() }

    /// 面板的位置：右緣對齊輸入框右緣、貼在輸入框上面；換頁（大小變了）也照這個重擺
    private func placePanel(animated: Bool = false) {
        guard let p = panel, let host = panelHost, let win = window else { return }
        // 顯示用的那個關掉了自動撐大，量不到大小：另外用一個不顯示的副本量
        let size = NSHostingView(rootView: ModelPanel(m: panelModel)).fittingSize
        _ = host
        let box = win.convertToScreen(inputBar.boxRectInWindow)
        var x = box.maxX - size.width, y = box.maxY + 8
        // 輸入框實際在哪個螢幕就用哪個螢幕的範圍，左右上都不超出去（太靠上就往下擠）
        let mid = NSPoint(x: box.midX, y: box.midY)
        if let vf = (NSScreen.screens.first { $0.frame.contains(mid) } ?? win.screen)?.visibleFrame {
            x = min(max(vf.minX + 8, x), vf.maxX - size.width - 8)
            if y + size.height > vf.maxY - 8 { y = vf.maxY - 8 - size.height }
        }
        let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        // 換頁、換分頁：大小用動畫慢慢變（下緣貼著輸入框不動），裡面的內容跟著每一格重排，不會先跳一下再改大小
        if animated, p.isVisible, p.frame.size != frame.size {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                p.animator().setFrame(frame, display: true)
            }
        } else {
            p.setFrame(frame, display: true)
        }
    }

    private func refreshPanel() {
        refreshModelName()
        panelModel.canSetDefault = false   // 只有 Claude 那段會打開
        panelModel.modelName = inputBar.modelTitle
        panelModel.isLocal = session.localEndpoint != nil
        if let m = session.agyModel {
            // agy：強度在模型名字尾巴，拉桿換的是尾巴（下一則訊息生效）
            panelModel.levels = AgyBridge.level(m) != nil ? AgyBridge.levels : []
            panelModel.effort = session.effort.flatMap { AgyBridge.levels.contains($0) ? $0 : nil }
            panelModel.defaultEffort = AgyBridge.level(m)
            panelModel.sections = modelSections(currentResolved: "")
        } else if session.codexModel != nil {
            panelModel.levels = CodexBridge.levels
            panelModel.effort = session.effort
            panelModel.defaultEffort = CodexBridge.defaultLevel
            panelModel.sections = modelSections(currentResolved: "")
        } else if session.copilotModel != nil {
            // Copilot Auto：拉桿是 Auto 的偏好（省／平衡／聰明），下一則訊息生效
            panelModel.levels = CopilotBridge.levels
            panelModel.effort = session.effort.flatMap { CopilotBridge.levels.contains($0) ? $0 : nil }
            panelModel.defaultEffort = CopilotBridge.defaultLevel
            panelModel.sections = modelSections(currentResolved: "")
        } else if session.appleModel != nil {
            // Apple 模型：沒有強度可調
            panelModel.isLocal = true
            panelModel.levels = []
            panelModel.effort = nil
            panelModel.defaultEffort = nil
            panelModel.sections = modelSections(currentResolved: "")
        } else if session.mlxModel != nil {
            // 本機 MLX：拉桿是要不要先想（低＝直接答、高＝先想再答），下一則訊息生效；不會思考的模型沒有拉桿
            let levels = LocalBridge.levels(session.mlxModel)
            panelModel.isLocal = levels.isEmpty
            panelModel.levels = levels
            panelModel.effort = session.effort.flatMap { levels.contains($0) ? $0 : nil }
            panelModel.defaultEffort = LocalBridge.defaultLevel(session.mlxModel)
            panelModel.sections = modelSections(currentResolved: "")
        } else {
            let choice = currentChoice
            panelModel.levels = Effort.order.filter { (choice?.efforts ?? Effort.order).contains($0) }
            panelModel.effort = session.effort
            let resolved = choice?.resolved.isEmpty == false ? choice!.resolved : resolvedModel
            panelModel.defaultEffort = ClaudeSettings.effort(for: resolved)
            panelModel.canSetDefault = true
            panelModel.sections = modelSections(currentResolved: resolved)
        }
        refreshModelTitle()
    }

    /// 模型清單：同一系列一組（新的在前），系列照 Claude 給的順序；最後一組是本機模型
    private func modelSections(currentResolved: String) -> [[ModelRow]] {
        let known = ModelChoice.known.filter { $0.value != "default" }
        var families: [String] = []
        var byFamily: [String: [ModelChoice]] = [:]
        for c in known {
            let fam = String(c.name.split(separator: " ").first ?? Substring(c.name))
            if byFamily[fam] == nil { families.append(fam) }
            byFamily[fam, default: []].append(c)
        }
        func version(_ c: ModelChoice) -> Double { Double(c.name.split(separator: " ").dropFirst().first ?? "0") ?? 0 }
        var checkedDone = session.localEndpoint != nil || session.agyModel != nil || session.codexModel != nil || session.copilotModel != nil || session.mlxModel != nil || session.appleModel != nil
        // 精簡清單（設定沒勾「列出全部」）：只留 Opus／Sonnet／Haiku 5.5 (cc)、Gemini 3.8 Flash、本機模型全部；這格正在用的照列
        let all = Prefs.shared.allModels
        func keep(_ rows: [ModelRow], _ common: (ModelRow) -> Bool = { _ in false }) -> [ModelRow] {
            all ? rows : rows.filter { $0.checked || common($0) }
        }
        var out: [[ModelRow]] = families.map { fam in
            byFamily[fam]!.sorted { version($0) > version($1) }.map { c in
                let on = !checkedDone && (session.model.map { $0 == c.value } ?? (c.resolved == currentResolved))
                if on { checkedDone = true }
                return ModelRow(id: c.value, title: c.name, tip: c.detail, checked: on)
            }
        }.map { keep($0) { ["opus", "sonnet", "haiku"].contains($0.id) } }.filter { !$0.isEmpty }
        // 本機：自己開 mlx_lm 伺服器的（快取裡有模型才列），再來是設定頁加的 Anthropic 格式伺服器
        let mlx = LocalBridge.available.map { m in
            ModelRow(id: "local:mlx:" + m.id, title: m.name, tip: L("本機 MLX · 約 \(m.gb) GB 記憶體 · 不花額度") + (m.gb >= 15 ? L(" · 跑的時候先關掉其他本機模型") : ""), checked: session.mlxModel == m.id)
        }
        // Apple 內建的模型：系統夠新、Apple Intelligence 開著才列
        let apple = AppleBridge.available
            ? [ModelRow(id: "local:apple:" + AppleBridge.model, title: AppleBridge.name(AppleBridge.model), tip: L("macOS 內建 · 不佔額外記憶體 · 上下文約 8K"), checked: session.appleModel != nil)]
            : []
        let locals = apple + mlx + LocalModel.all.map { l in   // 本機的不花額度，精簡清單也全列
            ModelRow(id: "local:" + l.id.uuidString, title: l.name, tip: "\(l.baseURL) · \(l.model)", checked: session.localEndpoint?.id == l.id)
        }
        if !locals.isEmpty { out.append(locals) }
        // Gemini：有裝 agy（Google 的 Antigravity 命令列工具）才列
        if AgyBridge.enabled, AgyBridge.executable != "agy" {
            let rows = keep(AgyBridge.models.map { m in
                ModelRow(id: "agy:" + m.id, title: m.name, tip: L("經 agy（Antigravity）· 用你的 Google AI 訂閱"), checked: session.agyModel.map(AgyBridge.base) == AgyBridge.base(m.id))
            }) { AgyBridge.base($0.id) == "agy:gemini-3.8-flash" }
            if !rows.isEmpty { out.append(rows) }
        }
        // ChatGPT：有裝 codex（OpenAI 的命令列工具，用 ChatGPT 帳號登入）才列
        if CodexBridge.installed {
            let rows = keep(CodexBridge.models.map { m in
                ModelRow(id: "codex:" + m.id, title: m.name, tip: L("經 Codex · 用你的 ChatGPT 帳號"), checked: session.codexModel == m.id)
            })
            if !rows.isEmpty { out.append(rows) }
        }
        // GitHub Copilot：有裝 copilot（GitHub 的命令列工具，用 GitHub 帳號登入）才列
        if CopilotBridge.installed {
            let rows = keep(CopilotBridge.models.map { m in
                ModelRow(id: "copilot:" + m.id, title: m.name, tip: L("經 Copilot CLI · 用你的 GitHub Copilot 額度"), checked: session.copilotModel == m.id)
            })
            if !rows.isEmpty { out.append(rows) }
        }
        return out
    }

    @objc private func openLocalSettings() { openSettings?() }

    // MARK: 權限模式

    func applyPermissionMode(_ m: String?) {
        session.permissionMode = m
        refreshMode()
    }
    private var currentMode: String { session.permissionMode ?? Prefs.shared.permissionMode ?? "default" }
    private func refreshMode() { inputBar.permissionMode = currentMode }
    /// ⇧ Tab 或按輸入框上的模式按鈕：換到下一個模式
    func cycleMode() {
        let next = PermissionMode.next(after: currentMode)
        session.setPermissionMode(next)
        refreshMode()
        onPermissionModeChange?(next)
    }

    func applyEffort(_ v: String?) {
        session.setEffort(v)
        refreshModelTitle()
    }

    /// 套用對話存的模型；本機和 Claude 之間切換要重開程序（下次送出時用 --resume 接回）
    func applyModel(_ value: String?) {
        let wasLocal = session.localEndpoint != nil
        let before = session.transcriptURL
        let beforeName = inputBar.modelTitle.components(separatedBy: " · ").first
        defer {
            // 換到另一套（紀錄檔不同）而且前面真的聊過：記下來，送下一則時附上
            if let before, before != session.transcriptURL,
               ((try? before.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0 { carryFrom = before; carryName = beforeName }
        }
        if let v = value, v.hasPrefix("codex:") {
            // ChatGPT（codex）：同一個程序裡換模型就好；從別的換過來要重開
            let m = String(v.dropFirst(6))
            if session.codexModel == nil { session.terminate() }
            session.agyModel = nil
            session.copilotModel = nil
            session.mlxModel = nil
            session.appleModel = nil
            session.localEndpoint = nil
            session.model = nil
            session.setCodexModel(m)
        } else if let v = value, v.hasPrefix("copilot:") {
            // GitHub Copilot：模型只能開的時候指定
            let m = String(v.dropFirst(8))
            if session.copilotModel != m { session.terminate() }
            session.agyModel = nil
            session.codexModel = nil
            session.mlxModel = nil
            session.appleModel = nil
            session.copilotModel = m
            session.localEndpoint = nil
            session.model = nil
        } else if let v = value, v.hasPrefix("agy:") {
            // Gemini（agy）：換成另一個程式，模型也只能開的時候指定
            let m = String(v.dropFirst(4))
            if session.agyModel != m || session.codexModel != nil || session.copilotModel != nil || session.mlxModel != nil || session.appleModel != nil { session.terminate() }
            session.codexModel = nil
            session.copilotModel = nil
            session.mlxModel = nil
            session.appleModel = nil
            session.agyModel = m
            session.localEndpoint = nil
            session.model = nil
        } else if value?.hasPrefix("local:apple:") == true {
            // Apple 模型：從別的換過來要重開（不是同一套）
            if session.appleModel == nil { session.terminate() }
            session.agyModel = nil
            session.codexModel = nil
            session.copilotModel = nil
            session.mlxModel = nil
            session.appleModel = AppleBridge.model
            session.localEndpoint = nil
            session.model = nil
        } else if let v = value, v.hasPrefix("local:mlx:") {
            // 本機 MLX：從別的換過來要重開（不是同一套）
            let m = String(v.dropFirst(10))
            if session.mlxModel != m || session.appleModel != nil { session.terminate() }
            session.agyModel = nil
            session.codexModel = nil
            session.copilotModel = nil
            session.mlxModel = m
            session.appleModel = nil
            session.localEndpoint = nil
            session.model = nil
        } else if let v = value, v.hasPrefix("local:"), let l = LocalModel.all.first(where: { "local:" + $0.id.uuidString == v }) {
            if session.localEndpoint?.id != l.id || session.agyModel != nil || session.codexModel != nil || session.copilotModel != nil || session.mlxModel != nil || session.appleModel != nil { session.terminate() }
            session.agyModel = nil
            session.codexModel = nil
            session.copilotModel = nil
            session.mlxModel = nil
            session.appleModel = nil
            session.localEndpoint = l
            session.model = nil
        } else {
            if wasLocal || session.agyModel != nil || session.codexModel != nil || session.copilotModel != nil || session.mlxModel != nil || session.appleModel != nil { session.terminate() }
            session.agyModel = nil
            session.codexModel = nil
            session.copilotModel = nil
            session.mlxModel = nil
            session.appleModel = nil
            session.localEndpoint = nil
            session.setModel(value == "default" ? nil : value)
        }
        refreshModelTitle()
    }

    /// 回傳有沒有真的送出（被「別處進行中」「agy 沒網」擋下就是 false）。restore＝使用者從輸入框送出；失敗時輸入框保持原樣（程式代送為 false）
    private var lastBlockedNotice = Date.distantPast
    @discardableResult
    private func send(text: String, images: [(data: Data, mediaType: String)], now: Bool = false, restore: Bool = true) -> Bool {
        // 不在這裡清 lastNotices：網頁卸載時程式代送會把使用者還沒看到的錯誤提示清掉；放上畫面後才清
        // 送出前再確認一次：這段對話如果正在別處進行，不要兩邊同時寫同一份紀錄
        if !session.isRunning, session.forkFrom == nil, liveElsewhere() != nil {
            // 程式代送（排程每 30 秒重試）不要一直洗版：使用者自己送的每次都講，代送的 5 分鐘內只講一次
            if restore || Date().timeIntervalSince(lastBlockedNotice) > 300 {
                lastBlockedNotice = Date()
                notice(L("這段對話剛好在別處進行中，這則沒有送出（避免兩邊同時寫同一份紀錄）。可以等那邊結束，或按「在這裡接手」複製一份。"))
            }
            checkLive()
            return false
        }
        // Gemini（agy）還沒開、系統說沒網路：不送，字放回輸入框（斷網時開 agy 會一直跳瀏覽器登入頁，AgyNet.swift）
        if session.agyModel != nil, !session.isRunning, !AgyNet.quickOK {
            notice(AgyNet.offlineMessage)
            return false
        }
        // 網頁卸載中被程式代送：先建回網頁，排隊泡泡與之後的串流先排進 queued，loadHistory 後再畫（跟第一次打開同一條路）。
        // 放在「別處進行中」「沒網路」這些會擋下的檢查之後，擋下時不白建（agy Sonnet 11/6）
        if web == nil, codeLab?.mode != .noAI { ensureWeb() }
        let selectedQuotes = restore ? quotes : []
        let bang = takeBangAttachment()
        let dataURLs = images.map { "data:\($0.mediaType);base64,\($0.data.base64EncodedString())" }
        let uuid = UUID().uuidString.lowercased()
        // Claude 還在做：先排在下面，等它真的讀進去（回送）再移進對話
        let queued = session.isRunning && session.status != .idle
        if let d = try? JSONSerialization.data(withJSONObject: ["text": text, "images": dataURLs, "uuid": uuid, "queued": queued, "now": now, "bang": bang?.count ?? 0, "quotes": selectedQuotes.map(\.preview)] as [String: Any]), let s = String(data: d, encoding: .utf8) {
            js("wb.localUser(\(s))")
        }
        if !sentAny { sentAny = true; onFirstMessage?(text) }
        nextGuess.sent(text, uuid: uuid)
        // 程式碼區開著：附一行告訴 Claude 你在看哪個檔案哪一行（畫面上的泡泡只顯示你打的字）
        // 使用者自己打的字裡若有〔codenv 開頭的字樣，先中和：不然重載歷史時會被當成附加區塊的開頭，從那裡截掉
        var full = QuoteText.append(to: QuoteText.neutralize(text), quotes: selectedQuotes)
        if let line = codeLab?.contextLine() { full += "\n\n" + line }
        // 看板上使用者終止了這個聊天室開的目標裡的 agy 步驟：附一行提示在最前面（CollabBoard.swift；畫面上的泡泡還是只顯示你打的字）
        if let id = conversationID, let n = CollabBoardModel.takeNotices(for: id) { full = n + "\n\n" + full }
        if let b = bang { full = b.text + full }      // 前面用 ! 跑的指令結果（只附這一次；畫面上泡泡不顯示，旁邊有小標）
        // 剛換到另一家的模型：附上交接（最近的對話＋精簡全文檔，ModelCarry.swift）。又換回原本那個就不用附。
        // 換到 Apple 模型不附（使用者 10/25：它做不了事，不用交接）
        let carried = carryFrom
        if let from = carryFrom {
            carryFrom = nil
            if from != session.transcriptURL, session.appleModel == nil,
               let note = ModelCarry.note(from: from, session: session.claudeSession, model: carryName, limit: 6000, canRead: true) {
                full += note
            }
        }
        if !session.send(text: full, images: images, uuid: uuid, now: now, displayText: text, quotes: selectedQuotes,
                         filePaths: restore ? inputBar.draftFilePaths : [], imageDrafts: restore ? inputBar.draftImages : []) {
            // 沒送出去（啟動失敗、claude 剛好結束）：! 指令結果和模型交接還沒用掉，放回去，重送時才不會漏
            if let b = bang { for i in b.indices where i < bangRecords.count { bangRecords[i].attached = false }; saveBang(); inputBar.bangCount = bangRecords.filter { !$0.attached && !$0.running }.count }
            carryFrom = carried
            js("wb.unsend(\(Self.jsString(uuid)))")      // 剛畫的泡泡收回來（字放回輸入框，重送才不會有兩個泡泡）
            if restore, let records = try? session.outboxPersistence?.read(), records.contains(where: { $0.id == uuid }) {
                // 管線失敗仍可能寫入了一部分：輸入框保持原樣，由已落盤的快照保管。
                rememberRecoveredOutbox(ids: [uuid])
            }
            return false      // 沒送出去：呼叫端（排程、瀏覽器回報、交接）靠這個知道，不能回成功
        }
        if restore {
            // 新版本先落盤後才取代使用者重送的舊快照；刪除失敗就繼續保留。
            do {
                try session.outboxPersistence?.remove(ids: recoveredOutboxIDs)
                recoveredOutboxIDs.removeAll()
                recoveredOutboxDraft = nil
            } catch { notice(L("寄件匣更新失敗，已保留原檔；重開時會再對照對話紀錄。")) }
            inputBar.clearAttempt()
            setQuotes([])
            js("wb.clearQuotes()")
            draftPersistence?.remove()
        }
        scrollAnchor = nil
        NotificationCenter.default.post(name: ChatPane.didSend, object: session.claudeSession)   // 草稿聊過了，留下來（Drafts.swift）
        return true
    }

    // MARK: ! 指令（Bang.swift、docs/bang-command-spec.md）

    private var bangRun: BangRun?
    /// ! 指令是否正在跑
    var isBangRunning: Bool { bangRun?.isRunning == true }
    private var bangRecords: [BangRecord] = []
    private var bangLoaded = false
    private var bangFloor = Date.distantFuture      // 歷史載到哪（再更舊的卡片等往上捲載入更早的時才補）
    private var bangBuf: [(String, Bool)] = []
    private var bangFlushing = false
    private static let bangISO: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()

    private func loadBang() {
        guard !bangLoaded else { return }
        bangLoaded = true
        bangRecords = BangStore.load(session.claudeSession)
        inputBar.bangCount = bangRecords.filter { !$0.attached && !$0.running }.count
    }
    private func saveBang() { BangStore.save(session.claudeSession, bangRecords) }

    /// 給 chat.js 的一筆（卡片）
    private func bangDict(_ r: BangRecord) -> [String: Any] {
        ["id": r.id, "cmd": r.cmd, "ts": Self.bangISO.string(from: r.at), "status": r.status, "secs": r.secs, "truncated": r.truncated,
         "code": r.code as Any? ?? NSNull(), "segs": r.segs.map { ["e": $0.e, "t": $0.t] }]
    }
    private func bangJSON(_ obj: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: obj)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// inputBar：Enter 執行。回傳 false＝沒執行（上一個還在跑），字留在輸入框
    func runBang(_ cmd: String) -> Bool {
        loadBang()
        if bangRun?.isRunning == true {
            notice(L("上一個指令還在跑"))
            return false
        }
        let rec = BangRecord(id: String(UUID().uuidString.lowercased().prefix(8)), cmd: cmd, cwd: session.directory, at: Date())
        bangRecords.append(rec)
        saveBang()
        scrollAnchor = nil
        js("wb.bangStart(\(bangJSON(bangDict(rec))))")
        let run = BangRun(id: rec.id, cmd: cmd, dir: session.directory)
        run.onChunk = { [weak self] s, e in self?.bangChunk(rec.id, s, e) }
        run.onEnd = { [weak self] code, status, secs in self?.bangEnd(rec.id, code, status, secs) }
        bangRun = run
        inputBar.bangRunning = true
        run.start()
        return true
    }

    private func bangChunk(_ id: String, _ s: String, _ isErr: Bool) {
        guard let i = bangRecords.firstIndex(where: { $0.id == id }) else { return }
        var text = s
        let used = bangRecords[i].segs.reduce(0) { $0 + $1.t.utf8.count }
        if used >= Bang.maxBytes { bangRecords[i].truncated = true; return }
        if used + text.utf8.count > Bang.maxBytes {
            text = String(decoding: Array(text.utf8.prefix(Bang.maxBytes - used)), as: UTF8.self)
            bangRecords[i].truncated = true
        }
        if bangRecords[i].segs.last?.e == isErr { bangRecords[i].segs[bangRecords[i].segs.count - 1].t += text }
        else { bangRecords[i].segs.append(BangSeg(e: isErr, t: text)) }
        bangBuf.append((text, isErr))
        guard !bangFlushing else { return }
        bangFlushing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.bangFlush(id) }
    }
    private func bangFlush(_ id: String) {
        bangFlushing = false
        guard !bangBuf.isEmpty else { return }
        // 連續同一種的併成一次
        var parts: [(String, Bool)] = []
        for (t, e) in bangBuf { if let l = parts.last, l.1 == e { parts[parts.count - 1].0 += t } else { parts.append((t, e)) } }
        bangBuf = []
        for (t, e) in parts { js("wb.bangOut(\(Self.jsString(id)), \(Self.jsString(t)), \(e))") }
    }

    private func bangEnd(_ id: String, _ code: Int?, _ status: String, _ secs: Double) {
        bangFlush(id)
        if let i = bangRecords.firstIndex(where: { $0.id == id }) {
            bangRecords[i].code = code; bangRecords[i].status = status; bangRecords[i].secs = secs
            js("wb.bangEnd(\(bangJSON(bangDict(bangRecords[i]))))")
        }
        bangRun = nil
        inputBar.bangRunning = false
        saveBang()
        inputBar.bangCount = bangRecords.filter { !$0.attached && !$0.running }.count
    }

    func stopBang() { bangRun?.stop() }

    /// 卡片上的「停止」
    private func bangStopFromCard(_ id: String) { if bangRun?.id == id { bangRun?.stop() } }

    /// ✕：這次不附上（這些結果就不再提示、也不會附給模型；卡片還在）
    func dismissBang() {
        loadBang()   // 網頁還沒回報 ready 就按 ✕ 時紀錄還沒載入：先載入再存，不然會拿空陣列蓋掉磁碟上的紀錄
        for i in bangRecords.indices where !bangRecords[i].attached && !bangRecords[i].running { bangRecords[i].attached = true; bangRecords[i].dismissed = true }
        saveBang()
        inputBar.bangCount = 0
    }

    /// 送出一般訊息時：還沒附的結果依序附在最前面（附過就標起來，只附一次）
    private func takeBangAttachment() -> (text: String, count: Int, indices: [Int])? {
        loadBang()
        let idx = bangRecords.indices.filter { !bangRecords[$0].attached && !bangRecords[$0].running }
        guard !idx.isEmpty else { return nil }
        let text = Bang.attachment(idx.map { bangRecords[$0] })
        for i in idx { bangRecords[i].attached = true }
        saveBang()
        inputBar.bangCount = bangRecords.filter { !$0.attached && !$0.running }.count
        return (text, idx.count, idx)
    }

    /// 測試用（--bang-dump）：這個聊天室的指令紀錄
    var bangDump: String {
        loadBang()
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return (try? e.encode(bangRecords)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
    /// 這個聊天室的指令紀錄（好讀紀錄用）
    var bangForTranscript: [BangRecord] { loadBang(); return bangRecords.filter { !$0.running } }

    private static func lineTime(_ s: String) -> Date? {
        guard let r = s.range(of: "\"timestamp\":\"") else { return nil }
        let rest = s[r.upperBound...]
        guard let q = rest.firstIndex(of: "\"") else { return nil }
        return bangISO.date(from: String(rest[..<q]))
    }

    /// 歷史這一頁（舊到新）裡插進時間在範圍內的指令卡片：[lo, hi)。more＝前面還有更舊的頁（這一頁最舊那則之前的卡片留給下一頁）
    private func mergeBang(_ lines: [String], records: [BangRecord], hi: Date, more: Bool) -> (lines: [String], lo: Date) {
        let firstTime = lines.lazy.compactMap { Self.lineTime($0) }.first
        let lo: Date = more ? (firstTime ?? .distantPast) : .distantPast
        let pick = records.filter { $0.at >= lo && $0.at < hi && !$0.running }.sorted { $0.at < $1.at }
        guard !pick.isEmpty else { return (lines, lo) }
        var out: [String] = []
        var j = 0
        for line in lines {
            while j < pick.count, let t = Self.lineTime(line), pick[j].at < t {
                out.append(bangJSON(["type": "wbBang", "rec": bangDict(pick[j])])); j += 1
            }
            out.append(line)
        }
        while j < pick.count { out.append(bangJSON(["type": "wbBang", "rec": bangDict(pick[j])])); j += 1 }
        return (out, lo)
    }

    /// 送出一則訊息（object：Claude 的對話編號）
    static let didSend = Notification.Name("ChatPaneDidSend")

    /// 畫面上一行系統提示（交接進度之類）
    func notice(_ s: String) {
        // 格子看不到（隱藏）或網頁不在：先記著，等使用者真的看到才算數。網頁在背景會被重建又卸載，
        // 「放上網頁」不等於「看過」（Codex 11/6：背景重建時清掉，再卸載後使用者就看不到失敗提示）
        if web == nil || window == nil {
            lastNotices.append(s)
            lastNotices = Array(lastNotices.suffix(3))
        }
        // 網頁好了才直接放；還在載入的不放（ready 時會統一重播記著的，免得同一頁出現兩次）
        if web != nil, ready { js("wb.notice(\(Self.jsString(s)))") }
        else if web != nil, window != nil, !lastNotices.contains(s) { lastNotices.append(s) }
    }

    private func removePendingControl(_ id: String) {
        pendingControlLines.removeAll { line in
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
            return obj["request_id"] as? String == id
        }
    }
    /// 程式幫忙送一則訊息（交接的第一則）
    @discardableResult
    func sendText(_ text: String) -> Bool { send(text: text, images: [], restore: false) }      // 程式代送的：被擋下不要把字塞進使用者的輸入框
    /// 程式幫忙送一則附圖的訊息（瀏覽器格的截圖回報）
    func sendReport(text: String, images: [(data: Data, mediaType: String)]) -> Bool { send(text: text, images: images, restore: false) }
    /// 橘色收納鈕按下去：由 Workspace 給選單（BrowserTools.swift）
    var onToolsMenu: ((NSView) -> Void)?

    // MARK: 網頁

    private static let jsIdentRegex = try? NSRegularExpression(pattern: #"^[A-Za-z_$][A-Za-z0-9_$.]*"#)

    /// 提取 JS 程式碼開頭的識別碼（最多 40 字），只取 wb.xxx 等安全識別碼；取不到就記 eval，避免洩漏內容
    private static func jsIdentifier(from code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = trimmed as NSString
        let checkLen = min(ns.length, 40)
        if let match = jsIdentRegex?.firstMatch(in: trimmed, range: NSRange(location: 0, length: checkLen)),
           match.range.length > 0 {
            return ns.substring(with: match.range)
        }
        return "eval"
    }

    private func js(_ code: String) {
        // 沒有網頁時由下次 loadHistory 從紀錄還原，不能再排隊重畫一次。
        guard let web else { return }
        guard ready else { queued.append(code); return }
        web.evaluateJavaScript(code) { _, err in
            if let err {
                let ns = err as NSError
                let fn = Self.jsIdentifier(from: code)
                NSLog("AI 工作台 JS 錯誤：\(fn)（\(ns.domain) \(ns.code)）")      // 不記程式碼本身：裡面有使用者的訊息、模型的回答
                EventLog.log("聊天畫面", "JS 執行錯誤：\(fn)（\(ns.domain) \(ns.code)）")
            }
        }
    }

    fileprivate func received(_ m: WKScriptMessage) {
        guard let web, m.webView === web else { return }
        guard let o = m.body as? [String: Any], let type = o["type"] as? String else { return }
        switch type {
        case "quotes":
            guard let items = o["items"] as? [[String: Any]] else { return }
            setQuotes(items.compactMap { item in
                guard let qid = item["qid"] as? String, !qid.isEmpty,
                      let role = item["role"] as? String, ["user", "assistant"].contains(role),
                      let text = item["text"] as? String else { return nil }
                return MessageQuote(qid: qid, role: role, text: text)
            })
        case "ready":
            // 先把舊紀錄畫上去，再放行排隊中的東西（不然 wb.history 會把剛送出的訊息、權限卡片清掉）
            loadBang()
            loadHistory { [weak self, weak web] in
                guard let self, let web, self.web === web else { return }
                self.ready = true
                let q = self.queued; self.queued = []
                q.forEach(self.js)
                self.setQuotes(self.quotes, syncWeb: true)
                self.pendingControlLines.forEach { self.js("wb.event(\($0))") }
                self.lastNotices.forEach { self.js("wb.notice(\(Self.jsString($0)))") }
                // 格子在視窗裡才算看過、清掉；背景重建的不清，等切回來（Codex 11/6）。清掉才不會每次重載都再出現（agy Opus 11/6）
                if self.window != nil { self.lastNotices.removeAll() }
                if let anchor = self.scrollAnchor {
                    self.scrollAnchor = nil
                    self.js("wb.restoreAnchor(\(anchor))")
                }
                if self.session.status != .idle { self.js("wb.setBusy(true)") }
                self.checkLive()
                let callbacks = self.onReadyCallbacks
                self.onReadyCallbacks.removeAll()
                callbacks.forEach { $0() }
            }
        case "scrollLog":
            // chat.js：跟到底被關掉／需要補貼的原因（查「沒有貼底」用，寫進 drop.log）
            if let t = o["text"] as? String { ChatTextView.dropLog("捲動 " + t, nil) }
        case "permission", "answer":
            guard let id = o["request_id"] as? String else { return }
            let behavior = type == "answer" ? "allow" : (o["behavior"] as? String ?? "deny")
            // 查「明明沒按卻被拒絕」用：每次回覆權限詢問都記一筆
            ChatTextView.dropLog("權限回覆：\(behavior)（\(type)）\(conversationTitleForLog)", nil)
            session.answerPermission(requestID: id, behavior: behavior, updatedInput: o["updatedInput"],
                                     updatedPermissions: o["updatedPermissions"], message: o["message"] as? String)
            removePendingControl(id)
            window?.makeFirstResponder(inputBar.textView)
        case "open":
            if var p = o["path"] as? String {
                // chat.js 已經拿掉行號；這裡再保險一次（file.swift:42、:42:7、#L42）
                p = p.replacingOccurrences(of: #"(:\d+(:\d+)?|#L\d+(-L?\d+)?)$"#, with: "", options: .regularExpression)
                let ex = (p as NSString).expandingTildeInPath
                let full = ex.hasPrefix("/") ? ex : (session.directory as NSString).appendingPathComponent(ex)
                Self.revealInFinder(URL(fileURLWithPath: full))
            }
        case "pathCheck":
            // chat.js 問「這些路徑在不在」：只有檔名、相對路徑、沒包反引號的路徑，要真的存在才做成連結
            guard let items = o["items"] as? [[String: Any]] else { return }
            let dir = session.directory
            let out: [[String: Any]] = items.compactMap { it in
                guard let key = it["key"] as? String, let p = it["path"] as? String else { return nil }
                let hit = (it["prefix"] as? Bool ?? false) ? Self.existingPrefix(p, in: dir) : (Self.pathExists(p, in: dir) ? p : nil)
                return ["key": key, "hit": hit ?? NSNull()]
            }
            if let d = try? JSONSerialization.data(withJSONObject: out), let s = String(data: d, encoding: .utf8) { js("wb.pathsChecked(\(s))") }
        case "editing":
            webEditing = o["on"] as? Bool ?? false
        case "sendNow":
            if let u = o["uuid"] as? String { session.sendNow(u) }
        case "loadOlder":
            loadOlder()
        case "bangStop":
            if let id = o["id"] as? String { bangStopFromCard(id) }
        case "openURL":
            // 網頁（對話內容）送來的網址：只開網頁和寄信，file:、自訂 scheme 會去開本機檔案或別的 App
            if let s = o["url"] as? String, let u = URL(string: s), ["http", "https", "mailto"].contains(u.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(u) }
        default: break
        }
    }

    /// 一次最多載入幾則（長對話的紀錄檔可能有上百 MB）
    static var historyLimit: Int { Prefs.shared.historyLimit }
    private var followOffset: UInt64 = 0
    private var followTimer: Timer?
    private var followPartial = Data()

    /// 這行是使用者／Claude 的訊息嗎（先用字串粗篩，不用每行都解析）
    private static func isMessage(_ raw: Data.SubSequence) -> Bool {
        guard raw.count > 20, let s = String(data: raw, encoding: .utf8) else { return false }
        return s.contains("\"type\":\"user\"") || s.contains("\"type\":\"assistant\"")
    }

    private static let userKey = Data("\"type\":\"user\"".utf8)
    private static let assistantKey = Data("\"type\":\"assistant\"".utf8)
    private static func isMessageBytes(_ raw: Data.SubSequence) -> Bool {
        raw.count > 20 && (raw.range(of: userKey) != nil || raw.range(of: assistantKey) != nil)
    }

    /// 從紀錄檔尾巴往前讀：第一次讀最後 400 則，往上捲再接著往前讀 300 則（長對話幾百 MB，不整份掃）
    private var older: ChainReader?
    private let olderQueue = DispatchQueue(label: "AI 工作台 載入紀錄")

    private func loadHistory(_ done: @escaping () -> Void) {
        guard let web else { done(); return }
        let reader = ChainReader(session.allTranscripts)
        followOffset = reader.size
        followPartial = Data()
        let bangs = bangRecords
        guard reader.hasMore || !bangs.isEmpty else { done(); return }
        older = reader
        let debug = ProcessInfo.processInfo.environment["AI_WORKBENCH_DEBUG"] != nil
        olderQueue.async { [weak self, weak web] in
            let t0 = Date()
            let taken = reader.take(Self.historyLimit, where: Self.isMessageBytes)
            let more = reader.hasMore
            let merged = self?.mergeBang(taken, records: bangs, hi: .distantFuture, more: more) ?? (lines: taken, lo: Date.distantPast)
            let lines = merged.lines
            let code = lines.isEmpty ? nil : "wb.history([" + lines.joined(separator: ",") + "])"
            let tPick = Date()
            DispatchQueue.main.async {
                guard let self, let web, self.web === web else { return }
                self.bangFloor = merged.lo
                self.followOffset = reader.size
                if let code {
                    self.sentAny = true
                    web.evaluateJavaScript(code) { [weak self] _, err in
                        if let err {
                            let ns = err as NSError
                            NSLog("AI 工作台 載入紀錄失敗：\(err.localizedDescription)")
                            EventLog.log(L("聊天畫面"), L("載入紀錄失敗（\(ns.domain) \(ns.code)）"))
                        }
                        if more { self?.js("wb.moreAbove()") }
                        if debug { FileHandle.standardError.write(Data(String(format: "載入紀錄 %.0f MB：挑訊息 %.2fs、畫面 %.2fs\n", Double(reader.size) / 1e6, tPick.timeIntervalSince(t0), Date().timeIntervalSince(tPick)).utf8)) }
                        done()
                    }
                } else {
                    done()
                }
            }
        }
    }

    /// 畫面捲到頂端附近要更早的
    private func loadOlder() {
        guard let reader = older else { js("wb.noMoreAbove()"); return }
        let bangs = bangRecords, hi = bangFloor
        olderQueue.async { [weak self] in
            let taken = reader.take(300, where: Self.isMessageBytes)
            let more = reader.hasMore
            let merged = self?.mergeBang(taken, records: bangs, hi: hi, more: more) ?? (lines: taken, lo: Date.distantPast)
            let lines = merged.lines
            let code = lines.isEmpty ? "wb.noMoreAbove()" : "wb.historyPrepend([" + lines.joined(separator: ",") + "], \(more))"
            DispatchQueue.main.async {
                guard let self, self.older === reader else { return }
                self.bangFloor = merged.lo
                self.js(code)
            }
        }
    }

    // MARK: 同步顯示：這段對話還開在 iTerm／tmux 裡

    /// 最後一次收到自己（工作台這邊的 Claude）的東西：紀錄檔在這之後被改，才算別人改的
    /// 也存起來：重開 App、關掉再開這格時，自己剛寫的紀錄檔不要被當成別人在用
    private lazy var lastOwnActivity: Date = Self.ownActivity(session.claudeSession)
    private var lastOwnSaved = Date.distantPast
    private func markOwnActivity(final: Bool = false) {
        lastOwnActivity = Date()
        guard final || Date().timeIntervalSince(lastOwnSaved) > 5 else { return }
        lastOwnSaved = Date()
        var all = appDefaults.dictionary(forKey: "ownActivity") as? [String: Double] ?? [:]
        let now = Date().timeIntervalSince1970
        all = all.filter { now - $0.value < 3600 }   // 只留一小時內的
        all[session.claudeSession.uuidString] = now
        appDefaults.set(all, forKey: "ownActivity")
    }
    private static func ownActivity(_ id: UUID) -> Date {
        guard let t = (appDefaults.dictionary(forKey: "ownActivity") as? [String: Double])?[id.uuidString] else { return .distantPast }
        return Date(timeIntervalSince1970: t)
    }

    /// 紀錄裡用的「這是哪一格」
    var conversationTitleForLog: String { conversationID.map { "［\($0.uuidString.prefix(8))］" } ?? "" }

    func liveElsewhere() -> LiveSession? {
        if let l = ClaudeSessions.live()[session.claudeSession], l.pid != session.pid { return l }
        // 登記檔查不到，但紀錄檔最近 3 分鐘被別的程式改過（例如那邊正在重新啟動）：保守一點，也當成還在別處進行
        // 只看「訊息」的時間：claude 結束時會在尾巴補寫幾行記帳資料，那不算有人在用
        if let url = session.transcriptURL,
           let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           Date().timeIntervalSince(m) < 180,
           let last = Self.lastMessageDate(url), Date().timeIntervalSince(last) < 180, last.timeIntervalSince(lastOwnActivity) > 5 {
            return LiveSession(pid: 0, tmux: "", kind: "recent")
        }
        return nil
    }

    /// 紀錄檔最後一則使用者／Claude 訊息的時間（只讀尾巴 512 KB）
    private static func lastMessageDate(_ url: URL) -> Date? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 512_000 ? size - 512_000 : 0)
        guard let tail = try? h.readToEnd() else { return nil }
        let key = Data("\"timestamp\":\"".utf8)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for raw in tail.split(separator: 0x0a).reversed() where isMessageBytes(raw) {
            guard let r = raw.range(of: key) else { continue }
            let rest = raw[r.upperBound...]
            guard let q = rest.firstIndex(of: 0x22), let s = String(data: rest[..<q], encoding: .utf8) else { continue }
            if let d = iso.date(from: s) { return d }
        }
        return nil
    }

    private func checkLive() {
        // 這格自己的 claude 已經在跑（例如打開 App 時自動接回）：紀錄檔剛被寫過是自己寫的，不算在別處
        guard !session.isRunning, let l = liveElsewhere() else { return }
        let whereText = l.kind == "recent" ? L("別處（紀錄檔剛剛還在更新）") : (l.tmux.isEmpty ? L("另一個終端機") : L("tmux（\(l.tmux)）"))
        inputBar.setLocked(L("這段對話正在\(whereText)裡進行，這裡同步顯示。在那邊結束後就能在這裡接著聊；也可以複製一份在這裡繼續（那邊不受影響）。"),
                           button: L("在這裡接手（複製一份）")) { [weak self] in self?.takeOver() }
        followTimer?.invalidate()
        var tick = 0
        followTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.session.isRunning { self.stopFollowing(); return }   // 這格自己接上了
            self.pullNewLines()
            tick += 1
            // 別處停下來（登記檔查不到、紀錄檔 2 分鐘沒動）才解鎖
            if tick % 3 == 0, self.liveElsewhere() == nil, self.quietFor(120) {
                self.stopFollowing()
                self.notice(L("那邊的對話已經結束，可以在這裡接著聊了。"))
            }
        }
    }

    private func quietFor(_ seconds: TimeInterval) -> Bool {
        guard let url = session.transcriptURL,
              let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return true }
        return Date().timeIntervalSince(m) >= seconds
    }

    /// 紀錄檔新長出來的部分接到畫面後面
    private func pullNewLines() {
        guard let url = session.transcriptURL, let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        let end = (try? h.seekToEnd()) ?? 0
        if end < followOffset { followOffset = 0; followPartial = Data() }
        guard end > followOffset else { return }
        try? h.seek(toOffset: followOffset)
        let chunk = followPartial + ((try? h.readToEnd()) ?? Data())
        followOffset = (try? h.offset()) ?? end      // 讀到哪就記到哪（seekToEnd 之後檔案又長了，不能記舊的檔尾，不然下次會再讀一次）
        // 最後一行可能還沒寫完：留到下次
        if let last = chunk.lastIndex(of: 0x0a) {
            followPartial = chunk[(last + 1)...]
            let lines = chunk[..<last].split(separator: 0x0a).compactMap { raw -> String? in
                guard Self.isMessage(raw), (try? JSONSerialization.jsonObject(with: raw)) != nil else { return nil }
                return String(data: raw, encoding: .utf8)
            }
            if !lines.isEmpty { js("wb.historyAppend([" + lines.joined(separator: ",") + "])") }
        } else {
            followPartial = chunk
        }
    }

    /// 網頁裡正在打字（選擇題的「其他」欄位之類）：這時候按 / 不要搶走
    private(set) var webEditing = false

    /// 在這格裡點了輸入框以外（對話內容）：輸入框失效。點在輸入框、縮圖、按鈕、/ 選單上不算
    func clickedInside(_ e: NSEvent) {
        let inBar = inputBar.bounds.contains(inputBar.convert(e.locationInWindow, from: nil))
        let inMenu = !inputBar.slash.isHidden && inputBar.slash.bounds.contains(inputBar.slash.convert(e.locationInWindow, from: nil))
        guard !inBar, !inMenu else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, let web = self.web, let w = self.window, w.firstResponder === self.inputBar.textView else { return }
            w.makeFirstResponder(web)
        }
    }

    /// 游標放進輸入框（鎖住時不動）
    @discardableResult
    func focusInput() -> Bool {
        guard !inputBar.isLocked, let w = window else { return false }
        if w.firstResponder !== inputBar.textView { w.makeFirstResponder(inputBar.textView) }
        return true
    }

    /// 自己的 claude 開起來了：如果先前以為「在別處進行」而鎖住輸入框，解開
    func ownSessionStarted() {
        guard followTimer != nil, session.isRunning else { return }
        stopFollowing()
    }

    private func stopFollowing() {
        followTimer?.invalidate()
        followTimer = nil
        inputBar.setLocked(nil)
        // 解鎖是計時器／自動接回觸發的，不是使用者點的：只有焦點本來就在這格（或沒人拿著）才放回輸入框，
        // 不然使用者正在別格打字，游標會被搶過來（使用者 10/30「打字的地方跳到別的格子」）
        guard let w = window else { return }
        let r = w.firstResponder
        if r == nil || r === w || (r as? NSView)?.isDescendant(of: self) == true { w.makeFirstResponder(inputBar.textView) }
    }

    /// 複製一份在這裡繼續：下一則訊息用 --fork-session 開新的對話編號
    private func takeOver() {
        pullNewLines()
        session.forkFrom = session.claudeSession
        stopFollowing()
        notice(L("已經準備好在這裡接手：送出下一則訊息時會複製一份新的對話，原本那段在那邊照常進行。"))
    }

    /// 對話裡點檔案路徑：一律在 Finder 裡把那個檔案選起來，不用預設 App 打開（使用者 10/25：「不要用 vscode 打開，請直接用 finder 的那個檔案位置」）。
    /// 資料夾直接在 Finder 打開（看裡面有什麼）；檔案不存在就打開最近一層存在的資料夾
    static func revealInFinder(_ url: URL) {
        let t = finderTarget(url)
        if t.select { NSWorkspace.shared.activateFileViewerSelecting([t.url]) } else { NSWorkspace.shared.open(t.url) }
    }
    /// 路徑在不在（去掉 :行號、#L行號；~ 換成家目錄；相對路徑接在工作目錄後面）
    static func pathExists(_ p: String, in dir: String) -> Bool {
        var p = p.replacingOccurrences(of: #"(:\d+(:\d+)?|#L\d+(-L?\d+)?)$"#, with: "", options: .regularExpression)
        if p.hasPrefix("./") { p.removeFirst(2) }
        let ex = (p as NSString).expandingTildeInPath
        guard !ex.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: ex.hasPrefix("/") ? ex : (dir as NSString).appendingPathComponent(ex))
    }
    /// 一般文字裡的路徑候選（後面可能黏著中文或標點）：從尾巴一個字一個字縮，回傳最長的存在前綴。
    /// 剩下的字要是「斷得乾淨」的地方（中文、標點），不然 ~/Desktop/打錯.md 會變成只連到 ~/Desktop
    static func existingPrefix(_ cand: String, in dir: String) -> String? {
        let cand = String(cand.prefix(400))
        var t = cand
        while t.count > 2 {
            let rest = cand.dropFirst(t.count)
            // 剩下的字開頭是英數、_-/，或「. 後面接英數」（~/foo 存在但 ~/foo.md 不存在）都算沒斷乾淨
            let pathy = { (c: Character?) in c.map { $0.isASCII && ($0.isLetter || $0.isNumber || "_-/".contains($0)) } ?? false }
            let clean = rest.isEmpty || (!t.hasSuffix("/") && !pathy(rest.first) && !(rest.first == "." && pathy(rest.dropFirst().first)))
            if clean, pathExists(t, in: dir) { return t }
            t.removeLast()
        }
        return nil
    }
    /// Finder 要怎麼顯示：(要打開或選起來的位置, true＝選起來 / false＝打開資料夾)
    static func finderTarget(_ url: URL) -> (url: URL, select: Bool) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            // .app 這類套件也是資料夾，但要選起來，不要打開（打開 Finder 會直接執行 App）
            return isDir.boolValue && !NSWorkspace.shared.isFilePackage(atPath: url.path) ? (url, false) : (url, true)
        }
        var dir = url.deletingLastPathComponent()
        while dir.path != "/", !fm.fileExists(atPath: dir.path) { dir = dir.deletingLastPathComponent() }
        return (dir, false)
    }

    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // 頁面裡點到外面的連結：交給瀏覽器，不在這格裡打開
        if a.navigationType == .linkActivated, let u = a.request.url {
            if u.isFileURL { Self.revealInFinder(u) } else { NSWorkspace.shared.open(u) }   // 網址用預設瀏覽器
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    /// 右鍵「壓縮這段對話」：送 /compact（Claude 把前面的內容濃縮成摘要；原本的紀錄檔還在）
    func compact() {
        send(text: "/compact", images: [], restore: false)
    }

    /// 測試用：把聊天網頁拍成 PNG（背景視窗 screencapture 拍不到網頁內容，WebKit 自己的快照拍得到）
    func snapshotWeb(to path: String) {
        whenWebReady { [weak self] in
            self?.web?.takeSnapshot(with: nil) { img, _ in
                guard let img, let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
                try? png.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    /// 測試用：在畫面裡跑一段 JS，結果當字串回來
    func evaluate(_ code: String, _ done: @escaping (String) -> Void) {
        whenWebReady { [weak self] in
            self?.web?.evaluateJavaScript(code) { r, e in done(r.map { "\($0)" } ?? L("錯誤：\(e?.localizedDescription ?? "?")")) }
        }
    }

    private func whenWebReady(_ action: @escaping () -> Void) {
        unloadingWeb = false
        ensureWeb()
        if ready { action() } else { onReadyCallbacks.append(action) }
    }

    /// NSFont 的粗細換成 CSS 的 font-weight（更紗黑體 SemiBold → 600）
    static func cssWeight(_ f: NSFont) -> Int {
        let w = (f.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat ?? 0
        switch w {
        case ..<(-0.5): return 200
        case ..<(-0.2): return 300
        case ..<0.1: return 400
        case ..<0.25: return 500
        case ..<0.45: return 600
        case ..<0.6: return 700
        default: return 800
        }
    }

    static func jsString(_ s: String) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: d, as: UTF8.self).dropFirst().dropLast())
    }
}

extension NSColor {
    var hex: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}

/// 從檔案尾巴往前一段一段讀行，可以接著讀（記住讀到哪）
/// 換過模型的對話：各家的紀錄檔接起來往前讀（目前這家在最後面），兩份中間插一則「以下換成 …」的分隔線（wbDivider）
/// 各家紀錄沒有共同的時間，只能整份接：來回換過好幾次的，同一家的幾段會併在一起
final class ChainReader {
    private var parts: [(reader: BackwardReader, name: String)]
    /// 目前這家紀錄檔讀到哪（同步顯示從這裡接著讀）
    let size: UInt64

    init(_ files: [(url: URL, name: String)]) {
        // 目前這家的檔可能還沒有（剛換模型、還沒聊）
        let current = files.first.flatMap { BackwardReader(url: $0.url) }
        parts = (current.map { [($0, files[0].name)] } ?? []) + files.dropFirst().compactMap { f in BackwardReader(url: f.url).map { ($0, f.name) } }
        size = current?.size ?? 0
    }

    var hasMore: Bool { parts.contains { $0.reader.hasMore } }

    /// 往前再拿 n 行，回傳時是舊到新
    func take(_ n: Int, where ok: (Data.SubSequence) -> Bool) -> [String] {
        var out: [String] = []
        while out.count < n, let p = parts.first {
            out = p.reader.take(n - out.count, where: ok) + out
            guard !p.reader.hasMore else { break }
            parts.removeFirst()
            if !parts.isEmpty, let d = try? JSONSerialization.data(withJSONObject: ["type": "wbDivider", "text": "以下換成 \(p.name)"]),
               let s = String(data: d, encoding: .utf8) { out.insert(s, at: 0) }
        }
        return out
    }
}

final class BackwardReader {
    let size: UInt64
    private let handle: FileHandle
    private var pos: UInt64
    private var tail = Data()           // 上一塊開頭那行還沒讀完整的部分
    private var pending: [Data] = []    // 已經切好、還沒交出去的行（新到舊）
    private let chunk: UInt64 = 8 * 1024 * 1024

    init?(url: URL) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        handle = h
        var end = (try? h.seekToEnd()) ?? 0
        // 最後一行可能還在寫（別處正在進行）：只讀到最後一個換行，剩下的交給同步顯示接著讀
        if end > 0 {
            let look = min(end, 4 * 1024 * 1024)
            try? h.seek(toOffset: end - look)
            if let tail = try? h.read(upToCount: Int(look)), let nl = tail.lastIndex(of: 0x0a) {
                end = end - look + UInt64(tail.distance(from: tail.startIndex, to: nl)) + 1
            }
        }
        size = end
        pos = end
    }
    deinit { try? handle.close() }

    var hasMore: Bool { pos > 0 || !tail.isEmpty || !pending.isEmpty }

    /// 往前再拿 n 行符合條件的，回傳時是舊到新
    func take(_ n: Int, where ok: (Data.SubSequence) -> Bool) -> [String] {
        var out: [Data] = []
        while out.count < n {
            if pending.isEmpty {
                if pos == 0 {
                    if !tail.isEmpty { pending = [tail]; tail = Data() } else { break }
                } else {
                    let len = min(chunk, pos)
                    pos -= len
                    try? handle.seek(toOffset: pos)
                    var buf = (try? handle.read(upToCount: Int(len))) ?? Data()
                    buf.append(tail)
                    var start = buf.startIndex
                    if pos > 0, buf.firstIndex(of: 0x0a) == nil { tail = buf; continue }      // 整塊都在同一行裡（超長一行）：整塊留著繼續往前讀，不能當成完整的一行
                    if pos > 0, let nl = buf.firstIndex(of: 0x0a) { tail = Data(buf[buf.startIndex..<nl]); start = buf.index(after: nl) } else { tail = Data() }
                    pending = buf[start...].split(separator: 0x0a).reversed().map { Data($0) }
                    continue
                }
            }
            let line = pending.removeFirst()
            if ok(line[...]) { out.append(line) }
        }
        return out.reversed().compactMap { String(data: $0, encoding: .utf8) }
    }
}
