import AppKit

/// 管每個對話的終端機：第一次打開才開，切到別的對話時不關，在背景繼續跑
final class Workspace {
    let store: Store
    var theme: Theme
    private(set) var panes: [UUID: any ConversationPane] = [:]
    /// 跑 Claude 的指令；測試時可以換成別的（main.swift 的 --claude）
    var claudeCommand = "claude"

    init(store: Store, theme: Theme) {
        self.store = store
        self.theme = theme
    }

    func pane(for c: Conversation) -> any ConversationPane {
        if let p = panes[c.id] { return p }
        if c.isBrowser { return browserPane(for: c) }
        if c.terminal != true { return chatPane(for: c) }
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
        p.onURL = { [weak self] u in
            guard let self, let i = self.store.conversations.firstIndex(where: { $0.id == cid }), self.store.conversations[i].browser != u else { return }
            self.store.conversations[i].browser = u
        }
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
        if store.wantsCodeLab(c) { p.attachCodeLab(directory: path, key: cid.uuidString) }
        p.applyModel(c.model)
        p.applyEffort(c.effort)
        p.applyPermissionMode(c.permissionMode)
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
        p.onStatus = { [weak self] s in
            guard let self else { return }
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
    func switchMode(_ id: UUID, terminal: Bool) {
        close(id)
        if let i = store.conversations.firstIndex(where: { $0.id == id }) { store.conversations[i].terminal = terminal ? true : nil }
    }

    func close(_ id: UUID) {
        panes[id]?.terminate()
        panes[id] = nil
        store.liveModel[id] = nil
        store.status[id] = nil   // 格子已經放掉了，它不會再回報「停下來」，燈號要自己清
    }

    /// 按 × 或 ⌘ W 關掉的格子（哪個 Window 都沒擺著了）：閒著的就把 Claude 收掉、釋出記憶體（使用者 10/25）。
    /// 正在做事的留著跑完（做完再呼叫一次就會收）；輸入框還有沒送的字或圖的留著；程式碼區的程式在跑的留著、有沒存的修改先存再收（存不了就留著）；
    /// 終端機模式不動（裡面可能在跑別的）。
    /// 紀錄都在，之後再打開會自動接回（--resume）
    func releaseUnplaced() {
        var placed = Set<UUID>()
        for s in store.sessions { for w in s.windows { placed.formUnion(w.root?.leaves ?? []) } }
        for (id, p) in panes where !placed.contains(id) {
            // 瀏覽器格子關掉就停（不在背景播聲音、吃記憶體）；網址記在對話上，再打開會重新載入
            // 掛件例外：⌘ ⇧ B 收起來只是不顯示，網頁留著，再叫出來不用重新載入、不會閃白（使用者 10/25）
            if p is BrowserPane { if store.conversation(id)?.isGadget != true { close(id) }; continue }
            guard let c = p as? ChatPane, store.status[id] == nil, !c.inputBar.hasPendingInput,
                  c.codeLab?.isProgramRunning != true else { continue }
            guard let lab = c.codeLab, lab.hasUnsaved else { close(id); continue }
            // 程式碼區有沒存的修改：先存（使用者 10/25），存好而且還是關著、閒著才收；存不了就留著
            lab.saveForClose { [weak self, weak c] ok in
                guard ok, let self, let c, (self.panes[id] as AnyObject?) === c, self.store.status[id] == nil,
                      !self.store.sessions.contains(where: { $0.windows.contains { $0.root?.leaves.contains(id) == true } }) else { return }
                self.close(id)
            }
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
        env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["LANG"] = src["LANG"] ?? "zh_TW.UTF-8"
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["AI_WORKBENCH"] = "1"
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
        Transcripts.update(id: id, title: c.title, files: files, done: done)
    }
}
