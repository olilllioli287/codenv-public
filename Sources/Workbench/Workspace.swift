import AppKit

/// 管每個對話的終端機：第一次打開才開，切到別的對話時不關，在背景繼續跑
final class Workspace {
    let store: Store
    var theme: Theme
    private(set) var panes: [UUID: any ConversationPane] = [:]
    /// 跑 Claude 的指令；測試時可以換成別的（main.swift 的 --claude）
    var claudeCommand = "claude"
    private var webUnloadTimer: Timer?
    private var webFeaturesObserver: NSObjectProtocol?

    init(store: Store, theme: Theme, webUnloadSeconds: TimeInterval = 180) {
        self.store = store
        self.theme = theme
        webFeaturesObserver = NotificationCenter.default.addObserver(forName: Prefs.webFeaturesChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refreshWebFeatures()
        }
        webUnloadTimer = Timer.scheduledTimer(withTimeInterval: max(0.5, min(30, webUnloadSeconds / 2)), repeats: true) { [weak self] _ in
            self?.unloadHiddenWebViews(idleSeconds: webUnloadSeconds)
        }
    }

    deinit {
        webUnloadTimer?.invalidate()
        if let webFeaturesObserver { NotificationCenter.default.removeObserver(webFeaturesObserver) }
    }

    /// 只放掉實體網頁／占位，不經過 close，也不改 Store。掛件即使藏在其他 Session 或背景，也必須停下來。
    private func refreshWebFeatures() {
        let enabled = Prefs.shared.webFeaturesEnabled
        for (id, pane) in panes where enabled ? pane is DisabledWebPane : pane is BrowserPane {
            panes[id] = nil
            pane.removeFromSuperview()
            pane.terminate()
        }
    }

    func unloadHiddenWebViews(idleSeconds: TimeInterval = 180) {
        let now = Date()
        for pane in panes.values {
            guard let c = pane as? ChatPane, c.window == nil, let since = c.hiddenSince,
                  now.timeIntervalSince(since) >= idleSeconds, c.canUnloadWeb else { continue }
            c.unloadWeb()
        }
    }

    func pane(for c: Conversation) -> any ConversationPane {
        // 先檢查總開關，不能取回快取中的舊網頁；舊 state.json 的瀏覽器葉節點只建立原生占位。
        if c.isBrowser {
            let enabled = Prefs.shared.webFeaturesEnabled
            if let p = panes[c.id] {
                if enabled ? p is BrowserPane : p is DisabledWebPane { return p }
                panes[c.id] = nil
                p.removeFromSuperview()
                p.terminate()
            }
            if enabled { return browserPane(for: c) }
            let p = DisabledWebPane(theme: theme)
            panes[c.id] = p
            return p
        }
        if let p = panes[c.id] {
            (p as? ChatPane)?.restoreSavedDraftIfNeeded()
            return p
        }
        if c.terminal != true || c.sandbox == true { return chatPane(for: c) }      // 開了沙盒的聊天室不開終端機版（終端機沒包 nono，等於脫離沙盒）
        let p = TerminalPane(theme: theme)
        let path = store.project(c.projectID)?.path ?? NSHomeDirectory()
        let id = c.claudeSession.uuidString.lowercased()
        // 對話紀錄已經在就接回（--resume），沒有就用這個編號開新的（--session-id）
        let flag = Store.claudeHasSession(c.claudeSession, path: path) ? "--resume \(id)" : "--session-id \(id)"
        // 用登入＋互動的 zsh 跑，PATH、別名跟平常在 iTerm 一樣；Claude 結束後留在 zsh
        p.start(executable: "/bin/zsh", args: ["-l", "-i", "-c", "\(claudeCommand) \(flag); exec zsh -l -i"],
                directory: path, environment: Self.environment() + ["CLAUDE_CODE_AUTO_COMPACT_WINDOW=\(Prefs.shared.cloudCompactTokens)"])   // 終端機模式也照 ⌘ , 的自動壓縮門檻
        p.attachImageShelf(claudeSession: c.claudeSession)
        let cid = c.id
        p.onTitle = { [weak self] title in
            guard let t = Self.cleanTitle(title) else { return }
            self?.store.rename(cid, to: t, byUser: false)
        }
        // 只拿掉自己：切換模式後晚到的結束通知不要把新開的那格也拿掉
        p.onExit = { [weak self, weak p] _ in
            guard let self, let p, (self.panes[cid] as AnyObject?) === p else { return }
            self.panes[cid] = nil
        }
        panes[c.id] = p
        return p
    }

    private func browserPane(for c: Conversation) -> BrowserPane {
        let p = BrowserPane(conversation: c.id, url: c.browser ?? "", theme: theme)
        let cid = c.id
        // 名字跟著網頁標題（自己改過名就不動）；網址記下來，重開 App 打開同一頁
        p.onTitle = { [weak self] t in self?.store.rename(cid, to: String(t.prefix(40)), byUser: false) }
        p.onURL = { [weak self] u in self?.store.noteBrowserURL(cid, u) }
        p.zoomFor = { [weak self] h in self?.store.browserZoom[h].map { CGFloat($0) } }
        p.onZoom = { [weak self] h, z in self?.store.browserZoom[h] = abs(z - 1) < 0.001 ? nil : Double(z) }
        p.applySavedZoom()
        panes[c.id] = p
        return p
    }

    private func chatPane(for c: Conversation) -> ChatPane {
        let path = store.project(c.projectID)?.path ?? NSHomeDirectory()
        let p = ChatPane(session: ChatSession(claudeSession: c.claudeSession, directory: path), theme: theme)
        let cid = c.id
        p.conversationID = cid
        p.session.nameProvider = { [weak self] in self?.store.conversation(cid)?.title }
        p.session.topicProvider = { [weak self] in self?.store.conversation(cid)?.topic }
        p.session.roleProvider = { [weak self] in self?.store.commanderRoleNote(for: cid) }
        p.session.mcpProvider = { [weak self] in McpMode.from(self?.store.conversation(cid)?.mcp) }
        p.session.conversationTag = cid.uuidString.lowercased()
        if store.wantsCodeLab(c) { p.attachCodeLab(directory: path, key: cid.uuidString) }
        p.applyModel(c.model)
        p.applyEffort(c.effort)
        p.applyPermissionMode(c.permissionMode)
        p.session.sandboxed = c.sandbox == true
        p.configureDraftPersistence(directory: store.directory)
        p.onPermissionModeChange = { [weak self] m in
            guard let self, let i = self.store.conversations.firstIndex(where: { $0.id == cid }) else { return }
            self.store.conversations[i].permissionMode = m
        }
        p.session.onForked = { [weak self] new in
            guard let self, let i = self.store.conversations.firstIndex(where: { $0.id == cid }) else { return }
            self.store.conversations[i].claudeSession = new
        }
        p.onEffortChange = { [weak self] e in
            guard let self, let i = self.store.conversations.firstIndex(where: { $0.id == cid }) else { return }
            self.store.conversations[i].effort = e
        }
        p.onModelChange = { [weak self] m in
            guard let self, let i = self.store.conversations.firstIndex(where: { $0.id == cid }) else { return }
            self.store.conversations[i].model = m
            self.store.liveModel[cid] = nil   // 換了模型：等新的那家回報再顯示
        }
        p.onResolvedModel = { [weak self] m in
            guard let self else { return }
            self.store.liveModel[cid] = m
            // 沒選模型（預設）的對話實際跑出來的：記下來，沒在跑的對話也照這個顯示
            let saved = self.store.conversation(cid)?.model
            if (saved == nil || saved == "default"), self.store.conversation(cid)?.terminal != true { appDefaults.set(m, forKey: "lastDefaultModel") }
        }
        p.openSettings = { NSApp.sendAction(#selector(AppDelegate.showSettings), to: nil, from: nil) }
        p.onToolsMenu = { [weak self, weak p] v in
            guard let self, let p else { return }
            self.popUpToolsMenu(for: cid, chat: p, from: v)
        }
        p.onStatus = { [weak self, weak p] s in
            // 只認目前這格：已經關掉或換掉的舊格晚到的回報不能改燈號（agy Argon 11/6）
            guard let self, let p, (self.panes[cid] as AnyObject?) === p else { return }
            let was = self.store.status[cid]
            self.store.status[cid] = s == .idle ? nil : s
            // 做完了而且你沒在看這段：標成未讀
            if s == .idle, was != nil, self.store.selected != cid || NSApp.isActive == false { self.store.unread.insert(cid) }
            // 非 Claude 聊天室回答完一則：更新好讀的 md（Transcripts.swift），Claude 聊天室才讀得到它說了什麼
            if s == .idle, was != nil { self.updateTranscript(cid) }
        }
        p.onCompacted = { [weak self] in self?.updateTranscript(cid) }
        // Claude Code 自己壓縮也會送 status: compacting，那是它自己的模型在做，不算背景：只有本機模型聊天室才記
        p.onBackgroundModel = { [weak self] m in
            guard let self, m == nil || self.store.conversation(cid)?.model?.hasPrefix("local:") == true else { return }
            if self.store.backgroundModel[cid] != m { self.store.backgroundModel[cid] = m }
        }
        p.onWantFocus = { [weak self] in self?.store.setFocus(cid) }
        p.onFirstMessage = { [weak self] text in
            guard let self, self.store.conversation(cid)?.title == "新對話" else { return }
            let first = text.split(separator: "\n").first.map(String.init) ?? ""
            if !first.isEmpty { self.store.rename(cid, to: String(first.prefix(30)), byUser: false) }
        }
        panes[c.id] = p
        return p
    }

    /// 換成終端機／聊天介面打開同一段對話（兩邊共用 Claude 的對話紀錄）
    func switchMode(_ id: UUID, terminal: Bool, done: (() -> Void)? = nil) {
        // 沙盒聊天室不能切成終端機模式（終端機版沒包 nono；先關掉沙盒再切）
        if terminal, store.conversation(id)?.sandbox == true {
            NSSound.beep()
            EventLog.log("沙盒", "\(store.conversation(id)?.title ?? "?")：開著沙盒，不能用終端機打開（先在右鍵關掉沙盒）")
            done?()
            return
        }
        // 程式碼區有沒存的修改：先存，存不了就不換（關掉這一格會把它丟掉）
        if let lab = (panes[id] as? ChatPane)?.codeLab, lab.hasUnsaved {
            lab.saveForClose { [weak self] ok in
                guard let self else { return }
                guard ok else { NSSound.beep(); return }
                self.doSwitchMode(id, terminal: terminal)
                done?()      // 先存檔的情況是存好才真的換：畫面要等換完再重建，不然會重建出舊的聊天格
            }
            return
        }
        doSwitchMode(id, terminal: terminal)
        done?()
    }

    private func doSwitchMode(_ id: UUID, terminal: Bool) {
        close(id)
        if let i = store.conversations.firstIndex(where: { $0.id == id }) { store.conversations[i].terminal = terminal ? true : nil }
    }

    func close(_ id: UUID) {
        // 先拿掉格子、清燈號，再結束：結束過程同步回報的「停下來」不能把被關掉的對話標成未讀（agy Argon 11/6）
        let old = panes.removeValue(forKey: id)
        store.liveModel[id] = nil
        store.backgroundModel[id] = nil
        store.status[id] = nil   // 格子已經放掉了，它不會再回報「停下來」，燈號要自己清
        old?.terminate()
    }

    /// 不在版面上的聊天格能不能收：閒著、沒有沒送的字、沒有 ! 指令和程式在跑，也沒有背景工作（背景 shell、agy／codex、本機背景模型）。
    /// 前景回答完但背景指令還在跑的，收掉會連 Claude 一起結束、背景工作跟著死（agy Argon 11/6）
    private func canRelease(_ id: UUID, _ c: ChatPane, ignoreWoken: Bool = false) -> Bool {
        if !ignoreWoken, woken.contains(id), c.session.isRunning { return false }
        // 背景工作只看可信的：掃描到真的還活著的程序，以及 claude 還活著時它自己回報的背景清單。
        // 不看前景紀錄、也不看已結束程序留下的清單：主動結束（換模型）時不會走 onExit 清理，殘留紀錄會讓格子永遠收不掉（Codex 11/6）
        let act = SessionActivity.shared
        let busyBackground = !(act.scanned[id] ?? []).isEmpty || (c.session.isRunning && !(act.background[id] ?? []).isEmpty)
        return store.status[id] == nil && store.backgroundModel[id] == nil && !busyBackground
            && !c.session.hasUnacknowledgedInput   // 還有送出沒確認的（排隊中）：這輪剛結束、下一則馬上要讀
            && !c.inputBar.hasPendingInput && !c.isBangRunning && c.codeLab?.isProgramRunning != true
    }

    /// 按 × 或 ⌘ W 關掉的格子（哪個 Window 都沒擺著了）：閒著的就把 Claude 收掉、釋出記憶體。
    /// 正在做事的留著跑完（做完再呼叫一次就會收）；輸入框還有沒送的字或圖的留著；程式碼區的程式在跑的留著、有沒存的修改先存再收（存不了就留著）；
    /// 終端機模式不動（裡面可能在跑別的）。
    /// 紀錄都在，之後再打開會自動接回（--resume）
    /// 用 codenv-todo wake 喚醒的、不在版面上的聊天室：releaseUnplaced 不收（不然 claude 馬上又被關掉）。擺進版面之後就照一般規則
    var woken = Set<UUID>()

    func releaseUnplaced() {
        var placed = Set<UUID>()
        for s in store.sessions { for w in s.windows { placed.formUnion(w.root?.leaves ?? []) } }
        woken.subtract(placed)
        for (id, p) in panes where !placed.contains(id) {
            // 喚醒的：claude 還在跑就留著；已經結束了就當一般不在版面上的處理（不要永遠留著）
            if woken.contains(id) { if (p as? ChatPane)?.session.isRunning == true { continue } else { woken.remove(id) } }
            // 瀏覽器格子關掉就停（不在背景播聲音、吃記憶體）；網址記在對話上，再打開會重新載入
            // 掛件例外：⌘ ⇧ B 收起來只是不顯示，網頁留著，再叫出來不用重新載入、不會閃白
            if p is BrowserPane { if store.conversation(id)?.isGadget != true { close(id) }; continue }
            guard let c = p as? ChatPane, canRelease(id, c) else { continue }
            guard let lab = c.codeLab, lab.hasUnsaved else { close(id); continue }
            // 程式碼區有沒存的修改：先存，存好而且還是關著、閒著才收；存不了就留著
            lab.saveForClose(interactive: false) { [weak self, weak c] ok in
                // 存檔是非同步的：回來時重新整套檢查（存檔期間可能被喚醒、打了字、開始跑程式）
                guard ok, let self, let c, (self.panes[id] as AnyObject?) === c, self.canRelease(id, c), c.codeLab?.hasUnsaved != true,
                      !self.store.sessions.contains(where: { $0.windows.contains { $0.root?.leaves.contains(id) == true } }) else { return }
                self.close(id)
            }
        }
    }

    /// 閒置回收（10 個聊天室的 Claude 程序共約 7 GB，其中一半是各自開的 MCP 程序）
    /// 不在畫面上的聊天室，「待命」（沒在工作、沒在等回答）超過 idleReleaseSeconds（15 分鐘）就結束 claude，之後用 --resume 接回。
    /// 兩種算「不在畫面上」：
    ///   1. 總指揮模式下，不在目前 Session、也不在獨立視窗的已擺聊天格（版面節點保留，切回去時 WindowHost 會重建）；
    ///   2. 用 codenv-todo wake／new 喚醒、沒擺進版面的聊天室（releaseUnplaced 為了不馬上關掉它而不收，這裡由閒置計時收）。
    /// 安全檢查跟 releaseUnplaced 同一套 canRelease：工作中、等你回答（status）、背景工作、排隊中的訊息（寄件匣）、輸入框草稿、! 指令、程式碼區程式都不收。
    /// 收掉後 wake／SendMessage／使用者點開時再起。
    var idleReleaseSeconds: TimeInterval = 15 * 60
    private var bgIdleSince: [UUID: Date] = [:]

    func releaseBackgroundIdle(now: Date = Date()) {
        let commander = Prefs.shared.sidebarMode == "commander"
        let cur = store.currentSessionLayout?.id
        var foreground = Set<UUID>(), background = Set<UUID>(), placed = Set<UUID>()
        for s in store.sessions {
            for w in s.windows {
                let leaves = w.root?.leaves ?? []
                placed.formUnion(leaves)
                if w.detached || s.id == cur { foreground.formUnion(leaves) } else { background.formUnion(leaves) }
            }
        }
        background.subtract(foreground)
        var candidates = commander ? background : []
        for id in woken where !placed.contains(id) { candidates.insert(id) }
        bgIdleSince = bgIdleSince.filter { candidates.contains($0.key) && panes[$0.key] != nil }
        for id in candidates {
            guard let c = panes[id] as? ChatPane, canRelease(id, c, ignoreWoken: true), c.codeLab?.hasUnsaved != true else { bgIdleSince[id] = nil; continue }
            let since = bgIdleSince[id] ?? now
            bgIdleSince[id] = since
            guard now.timeIntervalSince(since) >= idleReleaseSeconds else { continue }
            bgIdleSince[id] = nil
            woken.remove(id)
            EventLog.log("記憶體", "不在畫面上的聊天室待命超過 \(Int(idleReleaseSeconds / 60)) 分鐘，收掉程序（之後 --resume 接回）")
            close(id)
        }
    }

    func applyTheme(_ t: Theme) {
        theme = t
        for p in panes.values { p.applyTheme(t) }
    }

    /// 自己組環境變數，不沿用啟動這個 App 的終端機（不然 TMUX、iTerm 的變數會被帶進去）
    static func environment() -> [String] {
        let src = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]
        for k in ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING"] {
            if let v = src[k] { env[k] = v }
        }
        // ~/.local/bin 放最前面（codenv-todo、codenv-browser、agy、pet-say 都裝在這）：跟使用者 ~/.zshrc 的順序一樣（它也是加在最前面）。
        // 登入 shell（zsh -l）的 path_helper 會把系統路徑排到前面，但這些還是留在 PATH 裡
        let home = src["HOME"] ?? NSHomeDirectory()
        env["PATH"] = "\(CLITools.pathEntries(home: home)):/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["LANG"] = src["LANG"] ?? "zh_TW.UTF-8"
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["AI_WORKBENCH"] = "1"
        // 測試實例（--state-dir）：codenv-todo／codenv-browser 預設連到正式看板和正式 codenv，這裡明確指到測試資料夾（正式實例不設，維持原樣）
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--state-dir"), i + 1 < a.count {
            let d = URL(fileURLWithPath: a[i + 1], isDirectory: true)
            env["CODENV_STATE_DIR"] = d.path
            env["CODENV_COLLAB_FILE"] = d.appendingPathComponent("collab.json").path
            env["CODENV_BROWSER_DIR"] = d.appendingPathComponent("browser").path
        }
        return env.map { "\($0.key)=\($0.value)" }
    }

    /// Claude Code 把視窗標題設成目前在做的事，前面常有轉圈的符號；拿掉符號，太像預設值的就不用
    static func cleanTitle(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let f = t.unicodeScalars.first, !(CharacterSet.letters.contains(f) || CharacterSet.decimalDigits.contains(f)) {
            t.removeFirst()
            t = t.trimmingCharacters(in: .whitespaces)
        }
        let lower = t.lowercased()
        if t.isEmpty || lower == "claude" || lower == "claude code" || lower.hasPrefix("zsh") || t.hasPrefix("/") || t.hasPrefix("~") { return nil }
        return String(t.prefix(60))
    }
}

/// 停用網頁時只用 AppKit 畫一行灰字；不持有 WebKit，也不接觸網址或版面資料。
final class DisabledWebPane: NSView, ConversationPane {
    var focusTarget: NSView { self }
    var petReserve: NSSize = .zero
    override var acceptsFirstResponder: Bool { true }

    init(theme: Theme) {
        super.init(frame: .zero)
        wantsLayer = true
        let label = NSTextField(labelWithString: L("網頁外掛功能已關閉（設定可打開）"))
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.cell?.usesSingleLineMode = true
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
        applyTheme(theme)
    }
    required init?(coder: NSCoder) { fatalError() }
    func terminate() {}
    func applyTheme(_ t: Theme) { layer?.backgroundColor = t.palette(for: effectiveAppearance).bg.cgColor }
}

extension Workspace {
    /// 這段對話現在用的不是 Claude：把它用過的非 Claude 紀錄整理成 AI 工作台/transcripts/<聊天室名稱>.md
    func updateTranscript(_ id: UUID, done: ((URL?) -> Void)? = nil) {
        guard let p = panes[id] as? ChatPane, let c = store.conversation(id) else { done?(nil); return }
        let s = p.session
        guard s.agyModel != nil || s.codexModel != nil || s.copilotModel != nil || s.mlxModel != nil || s.appleModel != nil else { done?(nil); return }
        let claude = Store.claudeTranscript(s.claudeSession, path: s.directory)
        let current = s.transcriptURL
        let files = s.allTranscripts.filter { $0.url != claude }
            .map { (url: $0.url, model: $0.url == current ? store.displayModel(id) : Transcripts.family($0.url)) }
        // 用 ! 跑過的指令（Bang.swift）也寫進好讀紀錄
        let extra = p.bangForTranscript.map { Transcripts.Turn(time: $0.at, user: true, text: Bang.readable($0), model: "") }
        Transcripts.update(id: id, title: c.title, files: files, extra: extra, done: done)
    }

    /// ⌘ Q 結束前檢查所有格子有沒有在跑的東西，每項一句白話
    /// 範圍：所有 Session、所有 Window（包含獨立視窗）、沒擺在版面上但程序還活著的聊天室
    func runningSummary() -> [String] {
        var result: [String] = []

        // 收集所有相關對話 ID：維持穩定順序（先依 conversations 清單，再補其餘活著的 pane 與 status）
        var checkedIDs = Set<UUID>()
        var orderedIDs: [UUID] = []

        for c in store.conversations {
            orderedIDs.append(c.id)
            checkedIDs.insert(c.id)
        }
        for id in panes.keys where !checkedIDs.contains(id) {
            orderedIDs.append(id)
            checkedIDs.insert(id)
        }
        for id in store.status.keys where !checkedIDs.contains(id) {
            orderedIDs.append(id)
            checkedIDs.insert(id)
        }
        for id in SessionActivity.shared.activeIDs where !checkedIDs.contains(id) {
            orderedIDs.append(id)
            checkedIDs.insert(id)
        }

        func isExternalModel(_ it: RunningItem) -> Bool {
            if it.id.hasPrefix("proc-") { return true }
            if let tag = it.tag?.lowercased() {
                if tag.contains("agy") || tag.contains("codex") || tag.contains("copilot") || tag.contains("gemini") || tag.contains("本機") {
                    return true
                }
            }
            if SessionActivity.externalModel(in: it.text) != nil { return true }
            return false
        }

        for id in orderedIDs {
            let conv = store.conversation(id)
            let title = conv?.title ?? L("新對話")
            let pane = panes[id]

            // 1. 主對話：Claude 回答中
            if let st = store.status[id], st != .idle {
                result.append(L("\(title)：Claude 回答中"))
            }

            // 2. 背景工作與外部程序（SessionActivity）
            let items = SessionActivity.shared.running(id)
            for it in items {
                if isExternalModel(it) {
                    result.append(L("\(title)：agy／codex 在跑"))
                } else if it.background {
                    result.append(L("\(title)：背景 shell"))
                }
            }

            // 3. 程式碼學習專區：程式執行中
            if let chat = pane as? ChatPane, let lab = chat.codeLab, lab.isProgramRunning {
                let practiceName = conv?.title ?? L("練習")
                result.append(L("\(practiceName)：程式執行中"))
            }

            // 4. ! 指令在跑
            if let chat = pane as? ChatPane, chat.isBangRunning {
                result.append(L("\(title)：! 指令在跑"))
            }

            // 5. 終端機格：有程式在跑
            if let term = pane as? TerminalPane, term.hasRunningProcess {
                result.append(L("終端機：有程式在跑"))
            }
        }

        // 最後輸出前把完全相同的行去重，保留原本順序
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }
}
