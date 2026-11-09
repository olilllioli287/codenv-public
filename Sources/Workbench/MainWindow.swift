import AppKit
import SwiftUI
import Combine

final class MainWindowController: NSWindowController {
    let store: Store
    let workspace: Workspace
    let host: WindowHost
    /// 拉出去的獨立視窗（Window id → 控制器）；關掉就移掉
    var detachedWindows: [UUID: DetachedWindowController] = [:]
    private weak var splitController: NSSplitViewController?
    private var collabSub: AnyCancellable?
    private var bag: Set<AnyCancellable> = []
    var openSettings: () -> Void = {}
    private var keys: PrefixKeys?
    var lidKeeper: LidKeeper?
    var lidTimer: Timer?
    var sprintRunner: SprintRunner?
    lazy var floatingTerminal = FloatingTerminalController(parent: window!, store: store, workspace: workspace)

    init(store: Store, workspace: Workspace) {
        self.store = store
        self.workspace = workspace
        host = WindowHost(store: store, workspace: workspace)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.isRestorable = false
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        // 上緣不能拖視窗（系統會在 App 收到之前就接走，分頁就拖不了）；只有分頁列左邊那塊空白能拖（TabBar 的 DragHandle）
        w.isMovable = false
        let testing = CommandLine.arguments.contains("--state-dir")   // 測試 App 不記視窗大小，免得蓋掉使用者調好的
        w.minSize = NSSize(width: 480, height: 400)   // 寬 480：Rectangle 等的「一半」在 iPad 第二螢幕（1366 寬→683）、筆電的「三分之一」（504）都放得下（版面超出一半）
        super.init(window: w)
        shouldCascadeWindows = false
        // 上次的位置（自己記的原始座標；沒有就讀以前系統記的那份）
        let savedFrame = testing ? nil : (UserDefaults.standard.string(forKey: Self.frameKey) ?? UserDefaults.standard.string(forKey: "NSWindow Frame " + Self.frameName))

        let split = NSSplitViewController()
        let actions = SidebarActions(
            newConversation: { [weak self] in self?.newConversation() },
            addProject: { [weak self] in self?.addProject() },
            openSettings: { [weak self] in self?.openSettings() },
            deleteConversation: { [weak self] id in self?.deleteConversation(id) },
            removeProject: { [weak self] id in self?.removeProject(id) },
            switchMode: { [weak self] id, terminal in self?.switchMode(id, terminal: terminal) },
            compact: { [weak self] id in self?.compact(id) },
            handoff: { [weak self] id in self?.handoff(id) },
            toggleSidebar: { [weak self] in self?.toggleSidebar() },
            newCodeLab: { [weak self] in self?.newCodeLabConversation() },
            newBrowser: { [weak self] in self?.newBrowser() },
            changeFolder: { [weak self] id in self?.changeFolder(id) },
            about: { [weak self] id in self?.showAbout(id) },
            toggleCollab: { [weak self] in self?.toggleCollabBoard() },
            schedule: { [weak self] id in self?.showSchedule(id) },
            toggleSandbox: { [weak self] id in self?.toggleSandbox(id) })
        let side = NSHostingController(rootView: Scaled { SidebarView(store: store, workspace: workspace, actions: actions) })
        // 側欄最上面那條（紅綠燈右邊、跟分頁列一樣高）：按住拖整個視窗、點兩下放大
        // （SwiftUI 的 hosting view 點擊只看自己的內容、不看加進去的子 view，所以放在它外面那層，對齊它的上緣）
        let sideDrag = DragHandle()
        sideDrag.translatesAutoresizingMaskIntoConstraints = false
        DispatchQueue.main.async {
            guard let box = side.view.superview else { return }
            box.addSubview(sideDrag, positioned: .above, relativeTo: side.view)
            NSLayoutConstraint.activate([
            sideDrag.topAnchor.constraint(equalTo: side.view.topAnchor),
            sideDrag.leadingAnchor.constraint(equalTo: side.view.leadingAnchor),
            sideDrag.trailingAnchor.constraint(equalTo: side.view.trailingAnchor),
            sideDrag.heightAnchor.constraint(equalToConstant: WindowHost.barHeight),
            ])
        }
        let sideItem = NSSplitViewItem(sidebarWithViewController: side)
        sideItem.minimumThickness = 250
        sideItem.maximumThickness = 420
        sideItem.canCollapse = true
        let mainItem = NSSplitViewItem(viewController: host)
        split.addSplitViewItem(sideItem)
        split.addSplitViewItem(mainItem)
        // 右邊的協作看板（CollabBoard.swift）：平常收起來，按最左邊的「協作」圖示打開
        let collab = CollabBoardModel.shared
        let board = NSHostingController(rootView: Scaled {
            CollabBoardView(openConversation: { [weak self] id in self?.store.show(id) },
                            pause: { [weak self] p in self?.pauseCollab(p) })
        })
        let boardItem = NSSplitViewItem(inspectorWithViewController: board)
        boardItem.minimumThickness = 280
        boardItem.maximumThickness = 560
        boardItem.canCollapse = true
        // 總指揮模式：看板改嵌在右欄的「看板」分頁（RightPanelView），這一欄一律收著
        if Prefs.shared.sidebarMode == "commander" { collab.open = false }
        boardItem.isCollapsed = !collab.open
        split.addSplitViewItem(boardItem)
        collab.sources = { [weak self] in self?.collabSources() ?? [] }
        // 收件匣的回覆／退回：直接送進開目標的聊天室（跟 codenv-todo send 同一條路；送不出去由 CollabBoardModel 排隊）
        CollabBoardModel.sendToConversation = { [weak self] id, text in
            guard let self, let c = self.store.conversation(id), let pane = self.workspace.pane(for: c) as? ChatPane else { return false }
            self.workspace.woken.insert(id)
            if pane.sendText(QuoteText.neutralize(text)) { return true }
            self.workspace.woken.remove(id)
            return false
        }
        collab.start()
        setUpSchedules()
        // 聊天室被拿出取過名字的 Window、或 Window 改回預設名字／被關：它在 Window 框上的記號清掉（Bundles.swift syncWindowBundles）
        store.$sessions.dropFirst().debounce(for: .seconds(0.3), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.store.syncWindowBundles() }.store(in: &bag)
        // 使用者改聊天室名字：正在跑的 Claude 也改 session 名字（ListAgents、cross-session 的 from-name 才會跟著變）
        installChatInfoKey()
        store.onUserRename = { [weak self] id, title in (self?.workspace.panes[id] as? ChatPane)?.session.syncName(title) }
        // 聊天室改名：非 Claude 聊天室的 md 紀錄檔名跟著改（Transcripts.swift）
        store.$conversations.map { Dictionary($0.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a }) }
            .removeDuplicates().dropFirst().debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { Transcripts.renamed($0) }.store(in: &bag)
        collabSub = collab.$open.dropFirst().removeDuplicates().sink { open in
            DispatchQueue.main.async { boardItem.animator().isCollapsed = !open || Prefs.shared.sidebarMode == "commander" }
        }
        Prefs.shared.$sidebarMode.dropFirst().receive(on: RunLoop.main).sink { mode in
            if mode == "commander", collab.open { collab.open = false }
        }.store(in: &bag)
        if !testing { split.splitView.autosaveName = "AI 工作台側欄" }
        // 沒有記過側欄寬度（第一次開、或測試 App）：側欄預設打開、260 寬
        let hasSaved = !testing && UserDefaults.standard.object(forKey: "NSSplitView Subview Frames AI 工作台側欄") != nil
        if !hasSaved {
            sideItem.isCollapsed = false
            DispatchQueue.main.async { split.splitView.setPosition(260, ofDividerAt: 0) }
        }
        w.contentViewController = split
        splitController = split
        w.setContentSize(NSSize(width: 1280, height: 800))
        // 照上次關掉（⌘ Q）時的位置和大小打開；沒記過、或那個螢幕已經不在（外接螢幕拔掉）才放正中間
        var restored = false
        // 照原座標擺。不用系統的 setFrame(from:)／frameAutosaveName：視窗還沒顯示時系統當它在筆電螢幕上，
        // 會照筆電螢幕重新換算，外接螢幕上的位置每次都被搬到筆電螢幕（10/22 實測）
        let nums = (savedFrame ?? "").split(separator: " ").compactMap { Double($0) }
        if nums.count >= 4, nums[2] >= 300, nums[3] >= 200 {
            w.setFrame(NSRect(x: nums[0], y: nums[1], width: nums[2], height: nums[3]), display: false)
            restored = true
        }
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersection(w.frame).width > 200 && $0.visibleFrame.intersection(w.frame).height > 150 }
        if !(restored && onScreen) {
            if let vf = (NSScreen.main ?? w.screen)?.visibleFrame {
                var f = w.frame
                f.size.width = min(f.width, vf.width)
                f.size.height = min(f.height, vf.height)
                f.origin = NSPoint(x: (vf.midX - f.width / 2).rounded(), y: (vf.midY - f.height / 2).rounded())
                w.setFrame(f, display: false)
            } else {
                w.center()
            }
        }
        TestScreen.fit(w)      // 測試用：--test-screen 指定的螢幕（只在測試實例生效）
        // 擺好了才開始記：拖動、調大小就存原始座標（⌘ Q 時 AppDelegate 再存一次）
        if !testing {
            for n in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                NotificationCenter.default.addObserver(forName: n, object: w, queue: .main) { [weak self] _ in self?.saveFrame() }
            }
        }

        host.onCollabPause = { [weak self] p in self?.pauseCollab(p) }
        host.onNewWindow = { [weak self] in self?.newWindow() }
        RadialMenu.shared.controller = self
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: w, queue: .main) { [weak self] _ in self?.fitWidth() }
        DispatchQueue.main.async { [weak self] in self?.fitWidth() }
        host.onDetach = { [weak self] i, p in self?.detachWindowTab(i, at: p) }
        // 主視窗拿到焦點：「改目前的 Window」回到主視窗那個（獨立視窗拿到焦點時會把 scope 指向它）
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { [weak store] _ in store?.scope = nil }
        // 側欄點的對話在獨立視窗裡：把那個獨立視窗叫到最前面（Store.makeCurrent）
        store.onRaiseWindow = { [weak self] id in self?.detachedWindows[id]?.window?.makeKeyAndOrderFront(nil) }
        host.onEmptyAdd = { [weak self] slot, v in self?.showEmptyMenu(slot: slot, from: v) }
        store.ensureCodeLabGroup()
        host.tabBar.onToggleSidebar = { [weak self] in self?.toggleSidebar() }
        host.onCompact = { [weak self] id in self?.compact(id) }
        // 分頁上的 ×：直接關，跟 ⌘ W 一樣不問（對話都留在側欄）；Ctrl+A & 照 tmux 的習慣還是會問
        host.onCloseWindowRequest = { [weak self] i in self?.store.selectWindow(at: i); self?.store.closeWindow() }
        host.onRenameWindowRequest = { [weak self] i in self?.store.selectWindow(at: i); self?.renameWindow() }
        host.sessionMenu = { [weak self] in self?.treeMenu() ?? NSMenu() }
        host.tabBar.onSessions = { [weak self] v in self?.showSessionPanel(from: v) }
        floatingTerminal.onVisibilityChange = { visible in FloatTermButton.setVisible(visible) }
        floatingTerminal.chatRect = { [weak self] in self?.host.chatScreenRect }
        keys = PrefixKeys(controller: self)
        watchDrafts()
        // 設定檔存不進去：在這個視窗上跳一次說明（sheet，不把 App 叫到前景、不搶別的 App 的焦點）
        store.onSaveProblem = { [weak self] msg in
            // 測試實例不跳（會出現在使用者的螢幕上），只記一行
            if CommandLine.arguments.contains("--state-dir") { EventLog.log("檔案", "（測試）會跳「設定還沒存好」"); return }
            guard let w = self?.window, w.attachedSheet == nil else { return }
            let a = NSAlert(); a.alertStyle = .warning
            a.messageText = L("設定還沒存好")
            a.informativeText = msg
            a.addButton(withTitle: L("好"))
            a.beginSheetModal(for: w)
        }
        // 關掉的格子（不在任何 Window 裡）閒著就收掉 Claude；版面變了、或某段做完了都檢查一次（Workspace.releaseUnplaced）
        // 背景工作、背景模型結束也要再查一次：不然前景做完時被背景擋住的格子，背景結束後沒有事件再來檢查，一直收不掉（Codex 11/6）
        Publishers.MergeMany([store.$sessions.map { _ in () }.eraseToAnyPublisher(),
                              store.$status.map { _ in () }.eraseToAnyPublisher(),
                              store.$backgroundModel.map { _ in () }.eraseToAnyPublisher(),
                              SessionActivity.shared.$scanned.map { _ in () }.eraseToAnyPublisher(),
                              SessionActivity.shared.$background.map { _ in () }.eraseToAnyPublisher()])
            .debounce(for: .seconds(2), scheduler: RunLoop.main)   // 等狀態穩定 2 秒（剛閒下來可能馬上讀排隊的下一則）
            .sink { [weak self] _ in self?.workspace.releaseUnplaced() }.store(in: &bag)
        // 保底：別格事件一直來時防抖會一直延後，每 15 秒一定檢查一次（Codex 11/6）
        Timer.publish(every: 15, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.workspace.releaseUnplaced(); self?.workspace.releaseBackgroundIdle() }.store(in: &bag)
        reconnectPlaced()
        // 瀏覽器格子給 AI 讀的通道（codenv-browser）；名字照側欄
        BrowserServer.shared.titleOf = { [weak self] id in self?.store.conversation(id)?.title }
        BrowserServer.shared.wake = { [weak self] name, conv, done in self?.wake(name: name, caller: conv, done: done) ?? done(["ok": false, "error": "codenv 關閉中"]) }
        BrowserServer.shared.team = { [weak self] conv, name, done in
            guard let self else { return done(["ok": false, "error": "codenv 關閉中"]) }
            done(self.store.teamInfo(conversation: conv, name: name) { [weak self] id in (self?.workspace.panes[id] as? ChatPane)?.session.isRunning == true })
        }
        BrowserServer.shared.renameChat = { [weak self] conv, target, name, done in
            guard let self else { return done(["ok": false, "error": "codenv 關閉中"]) }
            done(self.store.commanderRename(caller: conv, target: target, name: name))
        }
        BrowserServer.shared.newChat = { [weak self] conv, name, dir, project, model, effort, mcp, topic, area, sandboxed, done in
            guard let self else { return done(["ok": false, "error": "codenv 關閉中"]) }
            self.commanderNewChat(caller: conv, name: name, dir: dir, project: project, model: model, effort: effort, mcp: mcp, topic: topic, area: area, sandboxed: sandboxed, done: done)
        }
        BrowserServer.shared.areaCmd = { [weak self] req, done in
            guard let self else { return done(["ok": false, "error": "codenv 關閉中"]) }
            let conv = req["conv"] as? String
            switch req["op"] as? String {
            case "add": done(self.store.commanderAreaAdd(caller: conv, name: (req["name"] as? String) ?? "", parent: req["parent"] as? String))
            case "move": done(self.store.commanderAreaMove(caller: conv, target: (req["target"] as? String) ?? "", area: (req["area"] as? String) ?? ""))
            case "ls": done(self.store.commanderAreaList(conversation: conv, name: req["name"] as? String) { [weak self] id in (self?.workspace.panes[id] as? ChatPane)?.session.isRunning == true })
            default: done(["ok": false, "error": "area 只有 add、move、ls"])
            }
        }
        BrowserServer.shared.setTopicChat = { [weak self] conv, target, topic, done in
            guard let self else { return done(["ok": false, "error": "codenv 關閉中"]) }
            self.commanderSetTopicChat(caller: conv, target: target, topic: topic, done: done)
        }
        BrowserServer.shared.archiveChat = { [weak self] conv, target, done in
            guard let self else { return done(["ok": false, "error": "codenv 關閉中"]) }
            done(self.store.commanderArchive(caller: conv, target: target))
        }
        BrowserServer.shared.newEngineChat = { [weak self] conv, name, engine, dir, project, model, effort, topic, done in
            guard let self else { return done(["ok": false, "error": "codenv 關閉中"]) }
            self.commanderNewEngineChat(caller: conv, name: name, engine: engine, dir: dir, project: project, model: model, effort: effort, topic: topic, done: done)
        }
        BrowserServer.shared.sendChat = { [weak self] conv, target, text, wait, timeout, done in
            guard let self else { return done(["ok": false, "error": "codenv 關閉中"]) }
            self.commanderSendChat(caller: conv, target: target, text: text, wait: wait, timeout: timeout, done: done)
        }
        BrowserServer.shared.lastChat = { [weak self] conv, target, done in
            guard let self else { return done(["ok": false, "error": "codenv 關閉中"]) }
            done(self.commanderLastChat(caller: conv, target: target))
        }
        BrowserServer.shared.setModelChat = { [weak self] conv, target, model, effort, done in
            guard let self else { return done(["ok": false, "error": "codenv 關閉中"]) }
            self.commanderSetModelChat(caller: conv, target: target, model: model, effort: effort, done: done)
        }
        BrowserServer.shared.setMcpChat = { [weak self] conv, target, mode, done in
            guard let self else { return done(["ok": false, "error": "codenv 關閉中"]) }
            done(self.store.commanderSetMcp(caller: conv, target: target, mode: mode))
        }
        BrowserServer.shared.showGoal = { [weak self] goal, activate, done in self?.showGoal(goal, activate: activate, done: done) ?? done(["ok": false, "error": "codenv 關閉中"]) }
        BrowserServer.shared.start()
        setupLidKeeper()
        sprintRunner = SprintRunner(host: self)
        BrowserServer.shared.sprintCmd = { [weak self] req, done in done(self?.sprintRunner?.command(req) ?? ["ok": false, "error": "codenv 關閉中"]) }
        // 右邊欄的記憶體：哪個程序是哪個聊天室
        MemoryMonitor.shared.labeler = { [weak self] in
            guard let self else { return [:] }
            var out: [pid_t: String] = [:]
            for (id, p) in self.workspace.panes {
                let title = self.store.conversation(id)?.title ?? L("聊天室")
                if let c = p as? ChatPane, let pid = c.session.pid { out[pid] = title }
                else if let t = p as? TerminalPane, t.terminal.process.shellPid > 0 { out[t.terminal.process.shellPid] = title + L("（終端機）") }
            }
            return out
        }
        MemoryMonitor.shared.idLabeler = { [weak self] in
            guard let self else { return [:] }
            var out: [pid_t: UUID] = [:]
            for (id, p) in self.workspace.panes {
                if let c = p as? ChatPane, let pid = c.session.pid { out[pid] = id }
                else if let t = p as? TerminalPane, t.terminal.process.shellPid > 0 { out[t.terminal.process.shellPid] = id }
            }
            return out
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: 動作

    let dirPicker = DirPicker()

    /// 新對話：先跳出資料夾選單（跟 iTerm 打 claude 的那個一樣、清單共用 ~/.claude/envs），選了就在那裡開
    @objc func newConversation() {
        guard let window else { return }
        let current = currentProject.flatMap { store.project($0)?.path }
        dirPicker.model.onListChanged = { [weak self] in self?.syncEnvsKeepingRemoved() }
        // 照側欄最上層的組分段（程式碼學習專區另外有「新的練習」，不列）
        dirPicker.model.topGroups = store.topGroups.filter { $0.name != Store.codeLabGroupName }.map { ($0.id, $0.name) }
        dirPicker.model.groupOfPath = { [weak self] path in self?.store.topGroup(ofPath: path) }
        dirPicker.model.setGroup = { [weak self] path, g in
            guard let self else { return }
            let pid = self.store.projects.first(where: { $0.path == path })?.id ?? self.store.addProject(path: path).id
            self.store.setDefaultGroup(pid, to: g)
        }
        dirPicker.toggle(in: window, current: current) { [weak self] path in self?.newConversation(at: path) }
    }

    /// 選單裡「從清單移除」的資料夾：側欄那個專案如果是空的就一起拿掉；有對話的留著（對話還找得到）
    func syncEnvsKeepingRemoved() {
        let envs = Set(ClaudeEnvs.load())
        for p in store.projects where !envs.contains(p.path) && store.conversations(in: p.id).isEmpty {
            store.removeProject(p.id)
        }
        store.syncEnvs()
    }

    /// 新瀏覽器格子：開在目前那格的專案，切開目前那格放右邊（沒有格子就直接擺上去）
    /// url：nil＝掛件用 Gemini、一般格子用空白頁（瀏覽器不該預設開 Gemini）
    func newBrowser(url: String? = nil) {
        guard Prefs.shared.webFeaturesEnabled else { return }
        // ⌘ ⇧ B 是切換：紫框選中聊天室＝開／收它那個框的掛件（Bundles.swift toggleBundle）；選中掛件＝收起那個框的掛件
        if url == nil, let f = store.currentWindow?.focused, let c = store.conversation(f) {
            if let b = c.gadgetOf { store.hideGadgets(of: b); return }
            if Store.isChat(c) { store.toggleBundle(from: c.id); return }
        }
        guard let pid = currentProject ?? store.projects.first?.id ?? Optional(store.addProject(path: NSHomeDirectory()).id) else { return }
        let c = store.createBrowser(in: pid, url: url ?? BrowserPane.home)
        if store.currentWindow?.focused != nil { store.split(vertical: false, with: c.id) } else { store.show(c.id) }   // 放右邊，跟聊天室並排
        store.selected = c.id
    }

    func newConversation(at path: String) {
        let pid = store.projects.first(where: { $0.path == path })?.id ?? store.addProject(path: path).id
        // 先當草稿：只列在「最近項目」，沒聊就自動刪（Drafts.swift）
        let c = store.createConversation(in: pid, draft: true)
        store.show(c.id)
    }

    /// 新對話要開在哪個專案：目前那格的專案，沒有就側欄選的、第一個
    private var currentProject: UUID? {
        if let f = store.currentWindow?.focused, let c = store.conversation(f) { return c.projectID }
        return store.selectedProject ?? store.projects.first?.id
    }

    // MARK: Session／Window／Pane（Ctrl+A 那一套也叫這些）

    /// Ctrl+A | 或 -：切開，新的一格先空著（按裡面的「新增聊天室」再選要開哪裡）
    func split(vertical: Bool) {
        store.split(vertical: vertical, with: store.newEmptySlot())
    }

    /// Ctrl+A c、分頁列的 ＋：新 Window，先空著
    func newWindow() {
        store.newWindow(with: nil)
    }

    func confirmClosePane() {
        guard let f = store.currentWindow?.focused else { return }
        confirm(L("關掉這格？"), L("「\(store.conversation(f)?.title ?? "")」會留在側欄，之後可以再打開。")) { [weak self] in self?.store.closePane() }
    }

    func confirmCloseWindow() {
        guard let w = store.currentWindow else { return }
        confirm(L("關掉整個 Window「\(store.displayName(w))」？"), L("裡面的對話都會留在側欄。")) { [weak self] in self?.store.closeWindow() }
    }

    /// F2：選取整個 Window 時改 Window 名字，不然改目前紫框那格的名字（跟側欄右鍵「重新命名」同一條路：store.rename byUser，會同步 Claude 的 session 名字）。
    /// 跳一個小輸入框（跟 Ctrl+A , 同一種）；answer＝測試用，直接當成輸入框的答案、不跳視窗
    func f2Rename(answer: String? = nil) {
        if store.windowSelected {
            guard let w = store.currentWindow else { return }
            if let answer { store.renameWindow(answer); return }
            ask(L("Window 新名字"), current: w.renamed ? w.name : "") { [weak self] t in self?.store.renameWindow(t) }
            return
        }
        guard let id = store.currentWindow?.focused, let c = store.conversation(id), !c.isGadget else { NSSound.beep(); return }
        if let answer { store.rename(id, to: answer, byUser: true); return }
        ask(L("對話新名字"), current: c.title) { [weak self] t in self?.store.rename(id, to: t, byUser: true) }
    }

    func renameWindow() {
        guard let w = store.currentWindow else { return }
        ask(L("Window 新名字"), current: w.renamed ? w.name : "") { [weak self] t in self?.store.renameWindow(t) }
    }

    func renameSession() {
        ask(L("Session 新名字"), current: store.currentSessionLayout?.name ?? "") { [weak self] t in self?.store.renameSession(t) }
    }

    /// Ctrl+A s／w：列出所有 Session 和 Window 來選（像 tmux 的 choose-tree）
    func showTree() { showSessionPanel(from: nil) }

    // MARK: Session 面板（跟模型選單同一個樣子）

    private var sessionPanel: FloatingPanel?
    private let sessionPanelModel = SessionPanelModel()
    private var sessionPanelKeys: Any?
    private var lastSessionPanelClose = Date.distantPast

    /// 從 Session 按鈕（貼在它下面）或 Ctrl+A s（視窗中間）打開
    func showSessionPanel(from anchor: NSView?) {
        if let p = sessionPanel, p.isVisible { p.close(); return }
        // 點按鈕想關掉：面板在按下時已經自己關了，放開時別又打開
        if anchor != nil, Date().timeIntervalSince(lastSessionPanelClose) < 0.4 { return }
        guard let win = window else { return }
        let m = sessionPanelModel
        m.rows = sessionRows()
        m.canClose = store.areaSessions.count > 1
        m.keyIndex = anchor == nil ? m.rows.firstIndex(where: { $0.checked && !$0.isSession }) : nil
        let done = { [weak self] (f: () -> Void) in self?.sessionPanel?.close(); f() }
        m.onPick = { [weak self] r in done { self?.pick(r) } }
        m.onNew = { [weak self] in done { self?.newSessionAction() } }
        m.onRename = { [weak self] in done { self?.renameSession() } }
        m.onCloseSession = { [weak self] in done { self?.closeSessionAction() } }

        let host = NSHostingView(rootView: SessionPanel(m: m))
        host.sizingOptions = []
        let size = NSHostingView(rootView: SessionPanel(m: m)).fittingSize
        let p = FloatingPanel(content: host)
        var origin: NSPoint
        if let a = anchor, let aw = a.window {
            let r = aw.convertToScreen(a.convert(a.bounds, to: nil))
            origin = NSPoint(x: r.minX, y: r.minY - 6 - size.height)
        } else {
            let f = win.frame
            origin = NSPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2 + 80)
        }
        if let vf = win.screen?.visibleFrame {
            origin.x = min(max(vf.minX + 8, origin.x), vf.maxX - size.width - 8)
            origin.y = max(vf.minY + 8, origin.y)
        }
        p.setFrame(NSRect(origin: origin, size: size), display: true)
        // 鍵盤：↑ ↓ 選、Enter 確定（Esc 由面板自己關）
        sessionPanelKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.sessionPanel?.isVisible == true else { return e }
            let n = m.rows.count
            switch e.keyCode {
            case 125: m.keyIndex = ((m.keyIndex ?? -1) + 1) % max(1, n); return nil
            case 126: m.keyIndex = ((m.keyIndex ?? n) - 1 + n) % max(1, n); return nil
            case 36, 76:
                if let i = m.keyIndex, m.rows.indices.contains(i) { m.onPick?(m.rows[i]) }
                return nil
            default: return e
            }
        }
        p.onClose = { [weak self] in
            guard let self else { return }
            if let k = self.sessionPanelKeys { NSEvent.removeMonitor(k); self.sessionPanelKeys = nil }
            self.sessionPanel = nil
            self.lastSessionPanelClose = Date()
        }
        sessionPanel = p
        win.addChildWindow(p, ordered: .above)
        p.orderFront(nil)
    }

    /// 面板上的每一行：Session 一行、底下它的 Window
    func sessionRows() -> [SessionPanelRow] {
        store.areaSessions.flatMap { s -> [SessionPanelRow] in
            let here = s.id == store.currentSession
            let current = s.current ?? s.windows.first?.id
            return [SessionPanelRow(id: s.id.uuidString, title: "Session \(s.name)", isSession: true, checked: here, session: s.id, window: nil)]
                + s.windows.enumerated().map { i, w in
                    SessionPanelRow(id: w.id.uuidString, title: "[\(i + 1)] \(store.displayName(w))", isSession: false,
                                    checked: here && w.id == current, session: s.id, window: w.id)
                }
        }
    }

    private func pick(_ r: SessionPanelRow) {
        if let w = r.window { return selectWindow(session: r.session, window: w) }
        store.selectSession(r.session)
    }

    /// 選某個 Window：獨立視窗（detached）不是可見的 Window，不能設成 current（不然主視窗跳回第 1 頁、獨立視窗又沒叫出來），改成把它叫到前面
    private func selectWindow(session: UUID, window: UUID) {
        guard let si = store.sessions.firstIndex(where: { $0.id == session }) else { return }
        if store.sessions[si].windows.first(where: { $0.id == window })?.detached == true { store.onRaiseWindow?(window); return }
        store.sessions[si].current = window
        store.selectSession(session)
    }

    func treeMenu() -> NSMenu {
        let m = NSMenu()
        for s in store.areaSessions {
            let head = NSMenuItem(title: "Session \(s.name)", action: #selector(pickSession(_:)), keyEquivalent: "")
            head.target = self
            head.representedObject = s.id
            head.state = s.id == store.currentSession ? .on : .off
            m.addItem(head)
            for (i, w) in s.windows.enumerated() {
                let item = NSMenuItem(title: "    [\(i + 1)] \(store.displayName(w))", action: #selector(pickWindow(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = [s.id, w.id]
                item.state = s.id == store.currentSession && w.id == s.current ? .on : .off
                m.addItem(item)
            }
        }
        m.addItem(.separator())
        let new = NSMenuItem(title: L("新 Session…"), action: #selector(newSessionAction), keyEquivalent: "")
        new.target = self
        m.addItem(new)
        let ren = NSMenuItem(title: L("幫這個 Session 改名…（Ctrl+A $）"), action: #selector(renameSessionAction), keyEquivalent: "")
        ren.target = self
        m.addItem(ren)
        if store.areaSessions.count > 1 {
            let close = NSMenuItem(title: L("關掉這個 Session（對話留在側欄）"), action: #selector(closeSessionAction), keyEquivalent: "")
            close.target = self
            m.addItem(close)
        }
        return m
    }

    @objc private func pickSession(_ i: NSMenuItem) { if let id = i.representedObject as? UUID { store.selectSession(id) } }
    @objc private func pickWindow(_ i: NSMenuItem) {
        guard let ids = i.representedObject as? [UUID], ids.count == 2 else { return }
        selectWindow(session: ids[0], window: ids[1])
    }
    @objc private func newSessionAction() {
        ask(L("新 Session 的名字"), current: "") { [weak self] t in
            guard let self else { return }
            self.store.newSession(named: t)
            if let pid = self.currentProject { let c = self.store.createConversation(in: pid); self.store.show(c.id) }
        }
    }
    @objc private func renameSessionAction() { renameSession() }
    @objc private func closeSessionAction() {
        confirm(L("關掉 Session「\(store.currentSessionLayout?.name ?? "")」？"), L("裡面的對話都會留在側欄。")) { [weak self] in self?.store.closeSession() }
    }

    /// Ctrl+A Ctrl+A：中文指令選單（跟 tmux-kit 的選單一樣的意思）
    func showCommandMenu() {
        guard let v = window?.contentView else { return }
        let m = NSMenu()
        let items: [(String, String, () -> Void)] = [
            (L("往右切開（空的格子）"), "|", { [weak self] in self?.split(vertical: false) }),
            (L("往下切開（空的格子）"), "-", { [weak self] in self?.split(vertical: true) }),
            (L("關掉這格"), "x", { [weak self] in self?.confirmClosePane() }),
            (L("放大／還原這格"), "z", { [weak self] in self?.store.toggleZoom() }),
            (L("新 Window"), "c", { [weak self] in self?.newWindow() }),
            (L("下一個 Window"), "n", { [weak self] in self?.store.selectWindow(offset: 1) }),
            (L("上一個 Window"), "p", { [weak self] in self?.store.selectWindow(offset: -1) }),
            (L("幫 Window 改名"), ",", { [weak self] in self?.renameWindow() }),
            (L("關掉整個 Window"), "&", { [weak self] in self?.confirmCloseWindow() }),
            (L("列出 Session 和 Window"), "s", { [weak self] in self?.showTree() }),
            (L("幫 Session 改名"), "$", { [weak self] in self?.renameSession() }),
            (L("新 Session"), "", { [weak self] in self?.newSessionAction() }),
            (L("開／關右下角的桌寵位置"), "b", { PetSlot.enabled.toggle() }),
            (L("視窗整理（設定）"), "", { [weak self] in self?.openSettings() }),
        ]
        for (t, k, f) in items {
            let item = NSMenuItem(title: k.isEmpty ? t : L("\(t)　　Ctrl+A \(k)"), action: #selector(runBlock(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = BlockBox(f)
            m.addItem(item)
        }
        m.addItem(.separator())
        let hint = m.addItem(withTitle: L("換格 Ctrl+A h j k l　調大小 Ctrl+A Ctrl+h j k l　第幾個 Window Ctrl+A 1～9"), action: nil, keyEquivalent: "")
        hint.isEnabled = false
        m.popUp(positioning: nil, at: NSPoint(x: v.bounds.midX - 160, y: v.bounds.midY + 180), in: v)
    }
    @objc private func runBlock(_ i: NSMenuItem) { (i.representedObject as? BlockBox)?.f() }

    /// Ctrl+A a：把 Ctrl+A 本身交給目前那格（輸入框跳到行首；終端機收到 ^A）
    /// 目前那格是聊天就換到下一個權限模式；不是聊天回 false
    // 從別的 App 切回來（例如在 Chrome 拖完圖片點一下這邊）：不管點在哪，游標直接進目前那格的輸入框。
    // 切回來之後再刻意點輸入框以外，才會離開。
    private var activatedAt = Date.distantPast
    private var activationObservers: [Any] = []
    /// 每日交接（DailyHandoff.swift）
    lazy var dailyHandoff = DailyHandoff(store: store, main: self)

    func setupActivationFocus() {
        activationObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.activatedAt = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self?.focusChatInput() }
        })
        if let m = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] e in
            // 切回來的那一下點擊：等點擊本身處理完（網頁拿走游標、側欄換對話）再放回輸入框
            if let self, e.window === self.window, Date().timeIntervalSince(self.activatedAt) < 0.6 {
                self.activatedAt = .distantPast
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.focusChatInput() }
            }
            return e
        }) { activationObservers.append(m) }
    }

    @discardableResult
    func focusChatInput() -> Bool {
        guard let w = window, w.isKeyWindow, let f = store.currentWindow?.focused, let c = workspace.panes[f] as? ChatPane else { return false }
        if let t = w.firstResponder as? NSTextView, t.isEditable, t !== c.inputBar.textView { return false }   // 正在別的欄位打字（改名、搜尋）
        return c.focusInput()
    }

    /// 輸入框以外按 /（注音的 ㄥ 同一顆鍵）：回到輸入框。正在打字的地方（輸入框、改名、終端機）照常
    func slashFocus() -> Bool {
        guard let w = window else { return false }
        // 沒跳回去的原因記進事件紀錄（紫框在聊天室、沒在打字，按 / 卻沒進去；只記種類，不記內容）
        func no(_ why: String) -> Bool { EventLog.log("焦點", "按 / 沒跳回輸入框：\(why)"); return false }
        guard let f = store.currentWindow?.focused, let c = workspace.panes[f] as? ChatPane else { return false }   // 瀏覽器、終端機格的 / 照常，不記（打字時太多筆）
        let v = w.firstResponder as? NSView
        if inCodeLab(c, v) { return false }   // 程式碼區的編輯器是網頁，/ 要打進程式裡
        // 網頁編輯中只有焦點真的在這格網頁裡才算，免得旗標卡住就一直跳不回來
        if c.webEditing, v?.isDescendant(of: c) == true, !(v === c.inputBar.textView) { return no("聊天網頁裡有欄位在編輯") }
        if let t = v as? NSTextView, t.isEditable {
            if t === c.inputBar.textView { return false }                                   // 就在這格打字，照常
            // 焦點留在別格的輸入框（點了紫框那格的空白處，焦點沒跟過來）：跳到紫框那格，不要把 / 打進看不到的地方
            guard sequence(first: t as NSView, next: { $0.superview }).contains(where: { $0 is ChatInputBar }) else { return no("焦點在其他文字欄位") }
        }
        if let v, sequence(first: v, next: { $0.superview }).contains(where: { $0 is TerminalPane }) { return false }
        return c.focusInput() ? true : no("輸入框鎖住")
    }

    /// 輸入框以外按 Tab：輸入框是空的、有灰字建議，就跳回輸入框並採用建議。規則跟 / 一樣：正在打字的地方、終端機照常
    func tabSuggestion(from eventWindow: NSWindow?) -> Bool {
        guard let w = window, let f = store.currentWindow?.focused, let c = workspace.panes[f] as? ChatPane, !c.webEditing else { return false }
        let tv = c.inputBar.textView
        guard w.firstResponder !== tv, tv.string.isEmpty, tv.isEditable, let s = tv.suggestion, !s.isEmpty else { return false }
        // Tab 很常用：只在按鍵是按在主視窗上（不是設定視窗等別的視窗）、焦點就在這格聊天室裡（對話內容上）、而且不在任何可輸入的地方時才攔。
        // 設定視窗、看板輸入框、程式碼區的編輯器、終端機格、瀏覽器格的網頁表單都照常
        guard eventWindow === w, let v = w.firstResponder as? NSView, v.isDescendant(of: c) else { return false }
        if inCodeLab(c, v) { return false }   // 程式碼區的編輯器是網頁，不是 NSTextView，下一行認不出來
        if let t = v as? NSTextView, t.isEditable { return false }
        if sequence(first: v, next: { $0.superview }).contains(where: { $0 is TerminalPane || $0 is BrowserPane }) { return false }
        guard c.focusInput() else { return false }
        tv.insertText(s, replacementRange: tv.selectedRange())
        return true
    }

    /// 焦點不在聊天輸入框時按 ⌃ Enter／⌃ C：照在輸入框裡按的做。輸入框自己拿到的、正在別的欄位打字、終端機格照常
    func chatCtrlKey(sendNow: Bool) -> Bool {
        guard let w = window, let f = store.currentWindow?.focused, let c = workspace.panes[f] as? ChatPane, !c.webEditing else { return false }
        if w.firstResponder === c.inputBar.textView { return false }
        if inCodeLab(c, w.firstResponder as? NSView) { return false }   // 在程式碼區按 ⌃ C 不能停掉聊天室
        if let t = w.firstResponder as? NSTextView, t.isEditable { return false }
        if let v = w.firstResponder as? NSView, sequence(first: v, next: { $0.superview }).contains(where: { $0 is TerminalPane }) { return false }
        if sendNow { c.inputBar.sendNowFromOutside() } else { return c.inputBar.stopFromInput() }
        return true
    }

    /// ⌃ A 方向鍵／h j k l：有程式碼區的聊天室先在格子裡面移動（聊天↔編輯器↔執行結果），到邊了才切到隔壁格
    func moveFocus(dx: Int, dy: Int) {
        if let f = store.currentWindow?.focused, let c = workspace.panes[f] as? ChatPane, let lab = c.codeLab,
           c.window === window, lab.moveFocus(dx: dx, dy: dy, chat: c) { return }
        store.focus(dx: dx, dy: dy)
    }

    /// 焦點在這格的程式碼區（編輯器、執行畫面）裡：聊天室的快捷鍵都要讓給它
    private func inCodeLab(_ c: ChatPane, _ v: NSView?) -> Bool {
        guard let v, let lab = c.codeLab else { return false }
        return v.isDescendant(of: lab)
    }

    func cycleChatMode() -> Bool {
        guard let f = store.currentWindow?.focused, let c = workspace.panes[f] as? ChatPane else { return false }
        // 程式碼區（編輯器、執行畫面）裡的 ⇧ Tab 是退縮排／倒退焦點，不能被拿去換權限模式
        if inCodeLab(c, window?.firstResponder as? NSView) { return false }
        c.cycleMode()
        return true
    }

    func sendCtrlA() {
        guard let f = store.currentWindow?.focused, let pane = workspace.panes[f] else { return }
        if let t = pane as? TerminalPane { t.terminal.send(txt: "\u{1}") }
        else if let c = pane as? ChatPane { c.inputBar.textView.moveToBeginningOfLine(nil) }
    }

    // MARK: 小對話框（Enter 確定、Esc 取消；輸入法開著也能按）

    func confirm(_ title: String, _ info: String, button: String = L("關掉"), _ ok: @escaping () -> Void) {
        guard let window else { return }
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        a.addButton(withTitle: button)
        a.addButton(withTitle: L("取消"))
        a.beginSheetModal(for: window) { r in if r == .alertFirstButtonReturn { ok() } }
    }

    private func ask(_ title: String, current: String, _ done: @escaping (String) -> Void) {
        guard let window else { return }
        let a = NSAlert()
        a.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = current
        a.accessoryView = field
        a.addButton(withTitle: L("好"))
        a.addButton(withTitle: L("取消"))
        a.window.initialFirstResponder = field
        a.beginSheetModal(for: window) { r in if r == .alertFirstButtonReturn { done(field.stringValue) } }
    }

    @objc func addProjectAction() { addProject() }

    func addProject(then: (() -> Void)? = nil) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.message = L("選一個資料夾當專案（對話會在這個資料夾裡開 Claude Code）")
        p.prompt = L("加入專案")
        p.directoryURL = Edition.projectsRoot
        guard let window else { return }
        p.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = p.url, let self else { return }
            self.store.addProject(path: url.path)
            self.store.addToEnvs(url.path)
            self.store.syncEnvs()
            then?()
        }
    }

    /// 壓縮這段對話（/compact）：先確認，因為很早以前的細節之後只剩摘要
    func compact(_ id: UUID) {
        guard let c = store.conversation(id), c.terminal != true, !c.isBrowser else { return }
        confirm(L("壓縮「\(c.title)」？"), L("Claude 會把前面的內容濃縮成一份摘要，之後每一輪會快很多、也比較省額度。很早以前的細節之後只剩摘要（原本的紀錄檔還在，不會刪）。"), button: L("壓縮")) { [weak self] in
            guard let self, let pane = self.workspace.pane(for: c) as? ChatPane else { return }
            self.store.show(id)
            pane.compact()
        }
    }

    /// 正在寫交接的對話（同一段不要重複按）
    private var handingOff: Set<UUID> = []
    /// 每日交接的背景任務（key＝舊聊天室）：記最後一則失敗原因與是否成功，結束時回報
    struct BackgroundHandoff {
        var completion: ((HandoffOutcome) -> Void)?
        var lastMessage: String?
        var succeeded = false
    }
    private var bgHandoffs: [UUID: BackgroundHandoff] = [:]

    /// 一件交接結束（成功或任何原因沒完成）：解除「正在交接」，背景任務在這裡回報結果
    private func endHandoff(_ id: UUID) {
        handingOff.remove(id)
        guard let job = bgHandoffs.removeValue(forKey: id) else { return }
        job.completion?(job.succeeded ? .success : .failed(job.lastMessage ?? L("交接沒有完成")))
    }

    /// 交接：先存文字，再開新聊天室送出；收到指定訊息的送達確認才換格與封存。
    func handoff(_ id: UUID) {
        guard let c = store.conversation(id), c.terminal != true, !c.isBrowser,
              let dir = store.project(c.projectID)?.path, let pane = workspace.pane(for: c) as? ChatPane else { return }
        if handingOff.contains(id) { pane.notice(L("這段對話正在交接，請等這次完成。")); return }
        if let reason = handoffBlockReason(c, pane: pane) { pane.notice(reason); return }
        guard Store.claudeHasSession(c.claudeSession, path: dir) else {
            pane.notice(L("「\(c.title)」還沒有對話紀錄，先跟 Claude 聊幾句再交接。")); return
        }
        confirm(L("交接「\(c.title)」？"), L("Claude 會讀完這段對話寫一份交接（大約半分鐘到幾分鐘，會用到額度）。交接文字會先存檔，再送到新聊天室；確認送達後，新的沿用這個名字、草稿與原本的位置，舊的改名成「今天日期_原名稱」收進封存。期間有新內容就不切換；沒有送達確認也會保留舊的。"), button: L("交接")) { [weak self] in
            self?.startHandoff(c, directory: dir)
        }
    }

    /// 確認框之後與測試掛鉤都走這裡，開始時重新檢查，不採用開確認框時的舊副本。
    /// background＝每日交接用：不改目前選取、不切 Session／Window、不搶焦點；結果（成功／延後／失敗）從 completion 回報，不跳視窗。
    func startHandoff(_ source: Conversation, directory: String, background: Bool = false, completion: ((HandoffOutcome) -> Void)? = nil) {
        guard let c = store.conversation(source.id), c.terminal != true, !c.isBrowser,
              let pane = workspace.pane(for: c) as? ChatPane else { if background { completion?(.failed(L("找不到這段聊天室"))) }; return }
        if handingOff.contains(c.id) {
            if background { completion?(.deferred(L("這段對話正在交接"))) } else { pane.notice(L("這段對話正在交接，請等這次完成。")) }
            return
        }
        if let reason = handoffBlockReason(c, pane: pane) {
            if background { completion?(.deferred(reason)) } else { pane.notice(reason) }
            return
        }
        guard store.project(c.projectID)?.path == directory,
              let version = try? handoffTranscriptVersions(c, pane: pane, directory: directory) else {
            let why = L("交接沒有開始：讀不到這段對話的紀錄，或工作資料夾已經改變。")
            if background { completion?(.failed(why)) } else { pane.notice(why) }
            return
        }
        if background { bgHandoffs[c.id] = BackgroundHandoff(completion: completion) }
        handingOff.insert(c.id)
        pane.notice(L("正在寫交接…（文字會先存檔，確認送達新聊天室後才換格）"))
        Handoff.write(session: c.claudeSession, directory: directory, model: c.model, effort: c.effort, proposals: { MemoryAdvice.submit($0, from: c.title) }) { [weak self] r in
            guard let self else { return }
            var waitingForDelivery = false
            defer { if !waitingForDelivery { self.endHandoff(c.id) } }
            switch r {
            case .failure(let e):
                self.handoffNotice(c.id, L("交接沒寫成：\(e.message)"))
            case .success(let text):
                let file: URL
                do { file = try Handoff.save(text, conversation: c.id, directory: self.store.directory) }
                catch {
                    self.handoffNotice(c.id, L("交接文字存檔失敗，沒有切換或封存：\(error.localizedDescription)")); return
                }
                if background, Prefs.shared.e4bDailyReviewEnabled {
                    E4BReview.review(handoffFile: file, conversationTitle: c.title)
                }
                // 一定先存檔再檢查：即使舊對話已被刪掉、程序剛開始下一輪，寫好的文字也留得住。
                guard self.handoffSourceUnchanged(c, directory: directory, version: version),
                      let old = self.store.conversation(c.id) else {
                    self.handoffNotice(c.id, self.handoffChangedNotice(file)); return
                }
                guard let oldPane = self.workspace.pane(for: old) as? ChatPane else { return }
                if let reason = self.handoffBlockReason(old, pane: oldPane) {
                    oldPane.notice(reason + L(" 交接文字已存在 \(file.path)，這次沒有切換。")); return
                }
                let projectBefore = self.store.selectedProject
                var n = self.store.createConversation(in: old.projectID)
                if self.bgHandoffs[c.id] != nil { self.store.selectedProject = projectBefore }   // 背景交接不改「新對話開在哪」
                if let i = self.store.conversations.firstIndex(where: { $0.id == n.id }) {
                    self.store.conversations[i].groupID = old.groupID
                    self.store.conversations[i].model = old.model
                    self.store.conversations[i].effort = old.effort
                    self.store.conversations[i].permissionMode = old.permissionMode
                    self.store.conversations[i].sandbox = old.sandbox
                    self.store.conversations[i].order = old.order
                    self.store.conversations[i].lastHandoffAt = ScheduleStore.now()   // 新的繼承交接時間，每日交接不會又把它當待交接
                    n = self.store.conversations[i]
                }
                let base = old.title.replacingOccurrences(of: #"^\d{8}_"#, with: "", options: .regularExpression)
                self.store.rename(n.id, to: base, byUser: true)
                let message = Handoff.firstMessage(from: old.title, text)
                // 先保存新聊天室的編號，再送出；此時舊名字、草稿、掛件框與版面都還沒動。
                guard self.store.saveNow() else {
                    self.preserveFailedHandoff(message, file: file, old: c.id, new: n.id, reason: L("新聊天室還沒存好，交接訊息沒有送出。")); return
                }
                guard let conv = self.store.conversation(n.id), let p = self.workspace.pane(for: conv) as? ChatPane else {
                    // 新聊天室已建好卻開不出格子：一樣要標「交接未送達」、記下舊的交接過，不然每日交接下一輪又開一個同名的
                    self.preserveFailedHandoff(message, file: file, old: c.id, new: n.id, reason: L("新聊天室開不出來，交接訊息沒有送出。")); return
                }
                oldPane.notice(L("交接文字已存在 \(file.path)，正在等新聊天室確認收到第一則訊息…"))
                waitingForDelivery = p.sendText(message, onDelivery: { [weak self] acknowledged in
                    guard let self else { return }
                    defer { self.endHandoff(c.id) }
                    guard acknowledged else {
                        self.preserveFailedHandoff(message, file: file, old: c.id, new: n.id, reason: L("交接訊息尚未確認送達（程序結束、被關閉，或等候超過 60 秒）。重送前請先確認新聊天室是否已收到，避免重複。")); return
                    }
                    self.finishHandoff(c, new: n.id, directory: directory, version: version, file: file)
                })
                if !waitingForDelivery {
                    self.preserveFailedHandoff(message, file: file, old: c.id, new: n.id, reason: L("交接訊息沒有送出去（程序開不起來、寄件匣存檔失敗，或這段對話在別處進行）。"))
                }
            }
        }
    }

    private func handoffNotice(_ id: UUID, _ message: String) {
        bgHandoffs[id]?.lastMessage = message
        if let c = store.conversation(id), let pane = workspace.pane(for: c) as? ChatPane { pane.notice(message) }
        else if bgHandoffs[id] == nil, let selected = store.selected, let pane = workspace.panes[selected] as? ChatPane { pane.notice(message) }
    }

    private func handoffBlockReason(_ c: Conversation, pane: ChatPane) -> String? {
        if pane.session.hasPendingPermission || pane.session.status == .waiting || store.status[c.id] == .waiting {
            return L("交接沒有開始：這格有權限詢問或問題還沒回覆，請先處理。")
        }
        if pane.session.hasUnacknowledgedInput { return L("交接沒有開始：寄件匣還有訊息未確認送達，請先確認或處理。") }
        do {
            if let outbox = pane.session.outboxPersistence,
               !(try outbox.reconcile(transcriptURLs: pane.session.allTranscripts.map(\.url))).isEmpty {
                return L("交接沒有開始：寄件匣還有訊息未確認送達，請先確認或處理。")
            }
        } catch { return L("交接沒有開始：寄件匣讀取或更新失敗，無法確認是否還有未送達訊息。") }
        if pane.session.status == .working || store.status[c.id] == .working || pane.inputBar.busy {
            return L("交接沒有開始：這格正在回答，請等回答結束。")
        }
        let activity = SessionActivity.shared
        if !activity.running(c.id).isEmpty
            || store.backgroundModel[c.id] != nil || pane.isBangRunning || pane.codeLab?.isProgramRunning == true {
            return L("交接沒有開始：這格還有背景工作或程式正在跑，請等它完成或先停下來。")
        }
        return nil
    }

    /// 曾換過模型的同一段對話可能有多份紀錄，任何一份新增、刪除或改寫都要中止切換。
    private func handoffTranscriptVersions(_ c: Conversation, pane: ChatPane, directory: String) throws -> [URL: Handoff.TranscriptVersion] {
        let claude = Store.claudeTranscript(c.claudeSession, path: directory)
        var versions = [claude: try Handoff.TranscriptVersion(claude)]
        for item in pane.session.allTranscripts where item.url != claude && FileManager.default.fileExists(atPath: item.url.path) {
            versions[item.url] = try Handoff.TranscriptVersion(item.url)
        }
        return versions
    }

    private func handoffSourceUnchanged(_ source: Conversation, directory: String, version: [URL: Handoff.TranscriptVersion]) -> Bool {
        guard let old = store.conversation(source.id), old.claudeSession == source.claudeSession, old.projectID == source.projectID,
              store.project(old.projectID)?.path == directory,
              let pane = workspace.pane(for: old) as? ChatPane,
              let current = try? handoffTranscriptVersions(old, pane: pane, directory: directory) else { return false }
        return current == version
    }

    private func handoffChangedNotice(_ file: URL) -> String {
        L("交接期間這段對話又有新內容，交接文字已存在 \(file.path)；要用最新內容請再按一次交接")
    }

    /// 背景交接（每日交接）走到新聊天室已建好的階段後，不管成功或失敗都先記下舊聊天室「交接過了」：
    /// 失敗時舊的不改名、不封存，不記的話每日交接下一輪又把它當待交接，再開一個同名新聊天室（一天最多 2 個、每個花一次額度）。
    /// 成功時舊的會被封存，這個記號沒有影響
    private func markHandoffAttempted(_ id: UUID) {
        guard bgHandoffs[id] != nil, let i = store.conversations.firstIndex(where: { $0.id == id }) else { return }
        store.conversations[i].lastHandoffAt = ScheduleStore.now()
        _ = store.saveNow()
    }

    /// 失敗時保留原本那格與草稿；新聊天室留在側欄，交接第一則放進它的輸入框，不自動重送。
    private func preserveFailedHandoff(_ message: String, file: URL, old: UUID, new: UUID, reason: String) {
        markHandoffAttempted(old)
        var draftSaved = false
        // 新舊同名會讓 codenv-todo wake 等以名字找人的地方撞名：沒完成的新聊天室標出來
        if let o = store.conversation(old), let n = store.conversation(new), n.title == o.title {
            store.rename(new, to: o.title + L("（交接未送達）"), byUser: true)
        }
        if let conv = store.conversation(new), let p = workspace.pane(for: conv) as? ChatPane {
            // onLost 可能已經從寄件匣放回同一則，不再重複附一次。
            if !p.inputBar.textView.string.contains(message) { p.inputBar.setDraft(message) }
            draftSaved = p.flushDraft()
            p.notice(reason + L(" 交接文字已存在 \(file.path)；舊聊天室沒有改名或封存。"))
        }
        let input = draftSaved ? L("交接訊息已放進新聊天室（\(new.uuidString.prefix(8))）的輸入框。") : L("新聊天室的草稿還沒存好，請從交接檔取回內容。")
        handoffNotice(old, reason + " " + input + L(" 交接文字已存在 \(file.path)；舊聊天室沒有改名或封存，原本的草稿也留著。"))
    }

    private func finishHandoff(_ source: Conversation, new: UUID, directory: String, version: [URL: Handoff.TranscriptVersion], file: URL) {
        markHandoffAttempted(source.id)
        // 等送達期間也可能有新內容：最後一次檢查通過後才動舊對話。
        guard handoffSourceUnchanged(source, directory: directory, version: version), let old = store.conversation(source.id) else {
            let message = handoffChangedNotice(file)
            handoffNotice(source.id, message); handoffNotice(new, message); return
        }
        guard let oldPane = workspace.pane(for: old) as? ChatPane, let next = store.conversation(new),
              let newPane = workspace.pane(for: next) as? ChatPane else { return }
        let bg = bgHandoffs[source.id] != nil
        if let reason = handoffBlockReason(old, pane: oldPane) {
            bgHandoffs[old.id]?.lastMessage = reason
            oldPane.notice(reason + L(" 交接文字已存在 \(file.path)，新聊天室已收到交接，但這次沒有切換或封存。")); return
        }
        guard oldPane.moveDraft(to: newPane) else {
            let why = L("新聊天室已收到交接，但草稿搬移未完成（存檔失敗或新輸入框已有內容），舊聊天室沒有改名或封存。交接文字已存在 \(file.path)")
            bgHandoffs[old.id]?.lastMessage = why
            oldPane.notice(why); return
        }
        let bundle = old.bundle ?? store.windowFrames[old.id]?.window
        if let i = store.conversations.firstIndex(where: { $0.id == new }) {
            // 直接接手原位置；reorder 會順便搬框，封存後再叫它會把新聊天室的框清掉。
            store.conversations[i].order = old.order
            store.conversations[i].groupID = old.groupID
            store.conversations[i].projectID = old.projectID
            store.conversations[i].bundle = old.bundle
        }
        guard store.saveNow(), ScheduleStore.shared.retarget(from: old.id, to: new) else {
            newPane.moveDraft(to: oldPane)
            let why = L("新聊天室已收到交接，但聊天室或排程存檔失敗，沒有切換、改名或封存。交接文字已存在 \(file.path)")
            bgHandoffs[old.id]?.lastMessage = why
            oldPane.notice(why); return
        }
        // 具名的已關閉 Window 也先整個找回，再換掉原格，框的編號、掛件、網址與比例都能接續。
        // 背景交接（每日交接）不找回已關閉的 Window、不 show：舊的不在版面上，新的就只留在側欄
        if !bg, store.locate(old.id) == nil { store.reopenClosedWindow(containing: old.id) }
        if bg { _ = store.replacePane(old.id, with: new, activate: false) }
        else if !store.replacePane(old.id, with: new) { store.show(new) }
        // 總指揮換代：Session 的總指揮聊天室指向舊的，就改指新的
        for i in store.sessions.indices where store.sessions[i].chief == old.id { store.sessions[i].chief = new }
        // 一般框直接繼承 bundle；Window 框通常由 windowFrames 現算，必要時補明確記號，保證封存前新成員已在框裡。
        if let bundle, store.conversation(new)?.bundle != bundle, store.windowFrames[new]?.window != bundle { store.setBundle(new, bundle) }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd"
        let base = old.title.replacingOccurrences(of: #"^\d{8}_"#, with: "", options: .regularExpression)
        store.rename(old.id, to: f.string(from: Date()) + "_" + base, byUser: true)
        store.setArchived(old.id, true)
        // 背景交接只在「目前選取的正是舊的」時順延給新的；其他情況不碰目前選取
        if !bg || store.selected == old.id { store.selected = new }
        bgHandoffs[old.id]?.succeeded = true
        let saved = store.saveNow()
        newPane.notice(saved ? L("交接已確認送達，舊聊天室已封存。交接文字存在 \(file.path)")
                            : L("交接已確認送達，但切換後的設定還沒存好，請先不要關閉 codenv。交接文字存在 \(file.path)"))
    }

    func switchMode(_ id: UUID, terminal: Bool) {
        workspace.switchMode(id, terminal: terminal) { [weak self] in self?.host.invalidate(id) }
    }

    /// 刪對話（側欄、清空草稿）：程式碼區有沒存的修改先存（刪的是對話，不是你寫的程式），存不了就不刪（Codex 11/6）
    func deleteConversation(_ id: UUID) {
        guard let c = store.conversation(id) else { return }
        let running = store.status[id].map { $0 != .idle } == true || ClaudeSessions.live()[c.claudeSession] != nil
        let detail = running ? L("\n\n這段對話目前有程序在跑；確認後會關掉它再移除。") : ""
        confirm(L("刪除「\(c.title)」？"), L("聊天室的 Claude 紀錄仍會保留。\(detail)"), button: L("刪除")) { [weak self] in
            self?.saveCodeLabs([id]) { ok in if ok { self?.reallyDeleteConversation(id) } }
        }
    }

    /// 這幾段對話的程式碼區有沒存的修改：一個一個存（可能跳衝突視窗），全部存好才 done(true)
    private func saveCodeLabs(_ ids: [UUID], done: @escaping (Bool) -> Void) {
        guard let id = ids.first else { return done(true) }
        let rest = Array(ids.dropFirst())
        guard let lab = (workspace.panes[id] as? ChatPane)?.codeLab, lab.hasUnsaved else { return saveCodeLabs(rest, done: done) }
        lab.saveForClose(interactive: true) { [weak self] ok in
            guard ok, let self else { return done(false) }
            self.saveCodeLabs(rest, done: done)
        }
    }

    private func reallyDeleteConversation(_ id: UUID) {
        workspace.close(id)
        // 草稿檔：格子沒開也要刪，不然留下孤兒檔；放在關格之後，關格時寫的草稿也一起刪
        DraftPersistence(directory: store.directory, conversationID: id).remove()
        store.removeConversation(id)
    }

    /// 整理視窗的「刪除…」：問過才刪；Claude 的紀錄檔丟垃圾桶（救得回來）。正在跑的、別處開著的不刪
    static let frameName = "AI 工作台主視窗"

    /// 收起／打開左邊的側欄（直接叫分割畫面，不靠回應鏈：視窗不是目前的視窗時也有用）
    @objc func toggleSidebar() { autoCollapsed.remove("side"); splitController?.toggleSidebar(nil) }

    // MARK: 視窗太窄（Rectangle 用 Accessibility 直接設大小，不受拖邊緣的最小寬度限制）
    /// 聊天區至少要這麼寬；左欄＋協作看板＋這個加起來比視窗寬，就先自動收協作看板、再收左欄；視窗變寬了自動回來。
    /// 自動收的才會自動打開：使用者自己（F3、F4、按鈕、拖）收起來的不會被打開
    static let hostMinWidth: CGFloat = 360
    private var autoCollapsed: Set<String> = []
    func fitWidth() {
        guard let split = splitController, let w = window, let total = w.contentView?.bounds.width, split.splitViewItems.count == 3 else { return }
        let side = split.splitViewItems[0], board = split.splitViewItems[2]
        let sideW: CGFloat = side.isCollapsed ? 0 : max(side.minimumThickness, side.viewController.view.frame.width)
        let boardW: CGFloat = board.isCollapsed ? 0 : max(board.minimumThickness, board.viewController.view.frame.width)
        // 太窄：先收協作看板、再收左欄
        if total < sideW + boardW + Self.hostMinWidth {
            if boardW > 0 { board.isCollapsed = true; autoCollapsed.insert("board") }
            if total < sideW + Self.hostMinWidth, sideW > 0 { side.isCollapsed = true; autoCollapsed.insert("side") }
            return
        }
        // 夠寬了：自動收的照原樣回來（先左欄再協作看板），要有 20 點的餘裕，免得邊界上一直開關
        if autoCollapsed.contains("side"), total >= side.minimumThickness + Self.hostMinWidth + 20 + (board.isCollapsed ? 0 : boardW) {
            side.isCollapsed = false; autoCollapsed.remove("side")
        }
        if autoCollapsed.contains("board"), CollabBoardModel.shared.open {
            let s = side.isCollapsed ? 0 : max(side.minimumThickness, side.viewController.view.frame.width)
            if total >= s + board.minimumThickness + Self.hostMinWidth + 20 { board.isCollapsed = false; autoCollapsed.remove("board") }
        } else { autoCollapsed.remove("board") }
    }
    var sidebarCollapsed: Bool { splitController?.splitViewItems.first?.isCollapsed ?? false }

    /// F6：大的關聯圖面板（總指揮模式才有）；左緣貼左欄右邊緣，左欄收起或在程式碼學習專區時貼視窗左邊
    lazy var graphPanel: GraphPanelController = {
        let g = GraphPanelController(window: window!, store: store, workspace: workspace)
        g.sidebarEdge = { [weak self] in
            guard let self, let split = self.splitController, let cv = self.window?.contentView,
                  let item = split.splitViewItems.first, !item.isCollapsed, self.store.area != Store.codeLabArea else { return 0 }
            let v = item.viewController.view
            return v.convert(v.bounds, to: cv).maxX
        }
        return g
    }()
    @objc func toggleGraphPanel() {
        guard Prefs.shared.sidebarMode == "commander" || graphPanel.isOpen else { return }
        graphPanel.toggle()
    }

    /// F4：開關右側欄（用量欄＋桌寵格）。收起來時協作看板開著就一起收；再按一次只打開右側欄，協作看板不跟著開（要自己點）
    @objc func toggleRightPanel() {
        autoCollapsed.remove("board")
        NotificationCenter.default.post(name: .rightPanelToggleWillBegin, object: nil)
        // 右邊有東西開著（用量欄或協作看板）→ 全部收起來；都收著 → 只打開用量欄
        if PetSlot.enabled || CollabBoardModel.shared.open {
            if CollabBoardModel.shared.open { CollabBoardModel.shared.open = false }
            PetSlot.enabled = false
        } else {
            PetSlot.enabled = true
        }
        NotificationCenter.default.post(name: .rightPanelToggled, object: nil)
    }
    static let frameKey = "mainWindowFrame"

    /// 存視窗的原始座標（x y 寬 高，全螢幕座標）
    func saveFrame() {
        guard appDefaults === UserDefaults.standard, let w = window, !w.isMiniaturized else { return }
        let f = w.frame
        UserDefaults.standard.set("\(f.minX) \(f.minY) \(f.width) \(f.height)", forKey: Self.frameKey)
    }

    func deleteConversations(_ ids: [UUID]) {
        let live = ClaudeSessions.live()
        let convs = ids.compactMap { store.conversation($0) }
        // 程式碼區有沒存的修改也先跳過：批次刪除不一個一個跳存檔視窗（Codex 11/6）
        let busy = convs.filter { store.status[$0.id] != nil || live[$0.claudeSession] != nil
            || (workspace.panes[$0.id] as? ChatPane)?.codeLab?.hasUnsaved == true }
        let targets = convs.filter { c in !busy.contains { $0.id == c.id } }
        guard !targets.isEmpty else {
            confirm(L("沒有可以刪的"), L("選的對話都還在跑（工作台或終端機裡），先停下來再刪。"), button: L("好")) {}
            return
        }
        let names = targets.prefix(5).map { L("・\($0.title)") }.joined(separator: "\n") + (targets.count > 5 ? L("\n…還有 \(targets.count - 5) 段") : "")
        let skip = busy.isEmpty ? "" : L("\n\n（\(busy.count) 段正在跑，先跳過）")
        confirm(L("刪除 \(targets.count) 段對話？"), L("\(names)\n\nClaude 的紀錄檔會丟進垃圾桶，需要時可以從垃圾桶救回。\(skip)"), button: L("丟進垃圾桶")) { [weak self] in
            guard let self else { return }
            var failed: [String] = []
            defer {
                if !failed.isEmpty {
                    DispatchQueue.main.async { self.confirm(L("有 \(failed.count) 段沒刪掉"), L("這些對話的紀錄檔丟不進垃圾桶，所以對話留著，沒動：\n") + failed.prefix(5).map { L("・\($0)") }.joined(separator: "\n"), button: L("好")) {} }
                }
            }
            // 確認視窗開著的時候可能又開始跑了（終端機 claude --resume）：按下確認後每段再檢查一次（Codex 11/6）
            let liveNow = ClaudeSessions.live()
            for c in targets {
                if self.store.status[c.id] != nil || liveNow[c.claudeSession] != nil
                    || (self.workspace.panes[c.id] as? ChatPane)?.codeLab?.hasUnsaved == true { failed.append(c.title + L("（剛開始在跑，沒刪）")); continue }
                let path = self.store.project(c.projectID)?.path ?? NSHomeDirectory()
                let file = Store.claudeTranscript(c.claudeSession, path: path)
                let side = file.deletingPathExtension()   // 子代理的紀錄放在同名資料夾
                // 紀錄檔丟垃圾桶失敗（權限、垃圾桶滿了）就不刪這段對話：不然紀錄檔留在磁碟上、codenv 裡卻沒有入口了
                // 主紀錄檔一定要先成功；子代理資料夾（side）丟不進去只是留在磁碟上，不擋刪除（不然會變成主紀錄已經不見、對話入口卻還在）
                if FileManager.default.fileExists(atPath: file.path) {
                    do { try FileManager.default.trashItem(at: file, resultingItemURL: nil) } catch { failed.append(c.title); continue }
                }
                if FileManager.default.fileExists(atPath: side.path) { try? FileManager.default.trashItem(at: side, resultingItemURL: nil) }
                self.reallyDeleteConversation(c.id)
            }
        }
    }

    func removeProject(_ id: UUID) {
        // 從側欄移除（資料夾不刪）：程式碼區有沒存的修改先存，存不了就不移除（Codex 11/6）
        guard let p = store.project(id) else { return }
        let convs = store.conversations(in: id)
        let busy = convs.filter { store.status[$0.id].map { $0 != .idle } == true || ClaudeSessions.live()[$0.claudeSession] != nil }
        let detail = busy.isEmpty ? "" : L("\n\n有 \(busy.count) 段對話正在跑；確認後會關閉它們。")
        confirm(L("移除專案「\(p.name)」？"), L("只從工作台清單移除，不會刪除資料夾。\(detail)"), button: L("移除")) { [weak self] in
            self?.saveCodeLabs(convs.map(\.id)) { ok in if ok { self?.reallyRemoveProject(id) } }
        }
    }

    private func reallyRemoveProject(_ id: UUID) {
        for c in store.conversations(in: id) { workspace.close(c.id) }
        if let p = store.project(id) { store.removeFromEnvs(p.path) }
        store.removeProject(id)
    }
}

private final class BlockBox: NSObject {
    let f: () -> Void
    init(_ f: @escaping () -> Void) { self.f = f }
}

extension MainWindowController {
    /// 協作看板要讀的對話：codenv 裡每段 Claude 對話的紀錄檔（測試 App 讀 --state-dir 裡的 projects）
    func collabSources() -> [(UUID, URL, String)] {
        store.conversations.compactMap { c in
            guard let path = store.project(c.projectID)?.path else { return nil }
            let url = CollabBoardModel.projectsRoot.appendingPathComponent(ConversationMover.slug(path))
                .appendingPathComponent(c.claudeSession.uuidString.lowercased() + ".jsonl")
            return (c.id, url, c.title)
        }
    }

    /// 「兩邊都暫停」：codenv 裡開著的那兩段對話各按一次停止（跟 Esc 一樣，只停這一步，不關程序）；
    /// 沒在 codenv 開著的（別處跑的 claude）不去動它，寫在看板上
    func pauseCollab(_ p: CollabPair) {
        var stopped: [String] = [], skipped: [String] = []
        for id in p.conversations {
            let title = store.conversation(id)?.title ?? "?"
            if let c = workspace.panes[id] as? ChatPane, c.session.isRunning {
                c.session.interrupt()
                stopped.append(title)
            } else {
                skipped.append(title)
            }
        }
        var n = stopped.isEmpty ? "" : L("已停止：\(stopped.joined(separator: "、"))。")
        if !skipped.isEmpty { n += L("沒在 codenv 開著、沒動：\(skipped.joined(separator: "、"))。") }
        CollabBoardModel.shared.notice = n
        CollabBoardModel.shared.dismissed[p.id] = p.count
    }
}

extension MainWindowController {
    /// 排程喚醒（Schedule.swift）：接上「怎麼送」「送過沒」，開始每 30 秒檢查
    func setUpSchedules() {
        let sched = ScheduleStore.shared
        // state.json 沒讀到時對話清單不可信：排程整個暫停，也不再用差集清理（改成對話被明確刪除時才跟著清）
        sched.suspended = store.loadFailed
        sched.backupOncePerLaunch()
        store.onConversationRemoved = { id in ScheduleStore.shared.removeSchedules(for: id) }
        // 測試用：--schedule-fake-send 檔案＝不真的送，把要送的訊息寫進檔案
        let args = CommandLine.arguments
        let fake = args.firstIndex(of: "--schedule-fake-send").flatMap { args.contains("--state-dir") && $0 + 1 < args.count ? args[$0 + 1] : nil }
        sched.deliver = { [weak self] s, message, _ in
            guard let self else { return ScheduleStore.waitMark }
            // 對話明確刪除時排程已跟著清；排程在、對話不在＝state.json 出事，不消耗這次、等設定檔還原
            guard let c = self.store.conversation(s.conversation) else { return ScheduleStore.waitMark }
            if c.terminal == true { return L("失敗：這段對話用終端機打開，排程只能送聊天介面") }
            if c.isBrowser { return L("失敗：這是瀏覽器格子，排程只能送聊天介面") }
            let open = self.workspace.panes[c.id] as? ChatPane
            // 「開著」＝擺在某個 Window 的版面上；格子物件還在不算（有草稿的格子關掉後會留在背景，Codex 11/6）
            let placed = self.store.sessions.contains { $0.windows.contains { $0.root?.leaves.contains(c.id) == true } }
            if !placed {
                if s.whenClosed == "wait" { return ScheduleStore.waitMark }
                if s.whenClosed == "skip" { return L("跳過：聊天室沒開著") }
            }
            guard let p = open ?? self.workspace.pane(for: c) as? ChatPane else { return L("失敗：聊天室開不起來") }
            if let fake {
                let line = "[\(c.title)] opened=\(placed) \(message.replacingOccurrences(of: "\n", with: "⏎"))\n"
                if let h = FileHandle(forWritingAtPath: fake) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
                else { try? line.write(toFile: fake, atomically: true, encoding: .utf8) }
                return nil
            }
            if !p.sendText(message) { return ScheduleStore.blockedMark }   // 正在忙會照常排隊，做完再讀；被擋下（同一段對話在別處進行中）沒送出，不能記成已送出
            return nil
        }
        // 送到一半當掉重開：紀錄檔最後 512 KB 裡已經有這則（開頭帶到期時間）就算送過
        // 送出時「〔codenv」會被 QuoteText.neutralize 改成「〔 codenv」：兩種都找；各家模型的紀錄都查（Codex 11/6：原本只找原樣、只查 Claude，當掉重開會重送）
        sched.alreadySent = { [weak self] id, marker in
            guard let self, let c = self.store.conversation(id), let path = self.store.project(c.projectID)?.path else { return false }
            let urls = [ConversationMover.root.appendingPathComponent(ConversationMover.slug(path)).appendingPathComponent(c.claudeSession.uuidString.lowercased() + ".jsonl"),
                        AgyBridge.transcript(for: c.claudeSession), CodexBridge.transcript(for: c.claudeSession), CopilotBridge.transcript(for: c.claudeSession),
                        LocalBridge.transcript(for: c.claudeSession), AppleBridge.transcript(for: c.claudeSession)]
            // 標記裡的日期有「/」：codenv 自己寫的紀錄（JSONSerialization）會寫成「\/」，Claude Code（Node）不會
            let legacy = ScheduleStore.legacyMarker(marker)      // 升版前送出的舊格式（沒有年份）也算送過
            let forms = [marker, QuoteText.neutralize(marker), legacy, QuoteText.neutralize(legacy)]
            let needles = Set(forms + forms.map { $0.replacingOccurrences(of: "/", with: "\\/") }).map { Data($0.utf8) }
            for url in urls {
                guard let h = try? FileHandle(forReadingFrom: url) else { continue }
                defer { try? h.close() }
                let size = (try? h.seekToEnd()) ?? 0
                try? h.seek(toOffset: size > 524_288 ? size - 524_288 : 0)
                guard let d = try? h.readToEnd() else { continue }
                if needles.contains(where: { d.range(of: $0) != nil }) { return true }
            }
            return false
        }
        sched.start()
    }

    /// 對話右鍵「排程…」
    /// 右鍵「在沙盒裡跑（nono）」：記下來；開著的格子停掉目前的 Claude，下一則訊息用（或不用）沙盒接回同一段
    func toggleSandbox(_ id: UUID) {
        guard let c = store.conversation(id) else { return }
        let on = c.sandbox != true
        if store.status[id] != nil {
            let a = NSAlert()
            a.messageText = L("這段對話還在跑")
            a.informativeText = L("等它停下來（或按停止）再切換沙盒。")
            a.addButton(withTitle: L("好"))
            if let window { a.beginSheetModal(for: window) } else { EventLog.log("沙盒", "\(c.title)：還在跑，沒有切換") }
            return
        }
        store.setSandbox(id, on)
        if let p = workspace.panes[id] as? ChatPane {
            p.session.sandboxed = on
            p.session.terminate()
        }
        EventLog.log("沙盒", "\(c.title)：\(on ? "開" : "關")（下一則訊息生效）")
    }

    func showSchedule(_ id: UUID) {
        guard let c = store.conversation(id), let vc = window?.contentViewController else { return }
        var sheet: NSViewController?
        let host = NSHostingController(rootView: ScheduleSheet(conversation: id, title: c.title, model: store.displayModel(id)) {
            if let sheet { vc.dismiss(sheet) }
        })
        sheet = host
        vc.presentAsSheet(host)
    }
}
