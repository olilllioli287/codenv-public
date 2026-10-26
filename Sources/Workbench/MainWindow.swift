import AppKit
import SwiftUI
import Combine

final class MainWindowController: NSWindowController {
    let store: Store
    let workspace: Workspace
    let host: WindowHost
    private weak var splitController: NSSplitViewController?
    private var collabSub: AnyCancellable?
    private var bag: Set<AnyCancellable> = []
    var openSettings: () -> Void = {}
    private var keys: PrefixKeys?

    init(store: Store, workspace: Workspace) {
        self.store = store
        self.workspace = workspace
        host = WindowHost(store: store, workspace: workspace)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        // 上緣不能拖視窗（系統會在 App 收到之前就接走，分頁就拖不了）；只有分頁列左邊那塊空白能拖（TabBar 的 DragHandle）
        w.isMovable = false
        let testing = CommandLine.arguments.contains("--state-dir")   // 測試 App 不記視窗大小，免得蓋掉使用者調好的
        w.minSize = NSSize(width: 700, height: 400)
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
            toggleCollab: { CollabBoardModel.shared.open.toggle() },
            schedule: { [weak self] id in self?.showSchedule(id) })
        let side = NSHostingController(rootView: Scaled { SidebarView(store: store, actions: actions) })
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
        boardItem.isCollapsed = !collab.open
        split.addSplitViewItem(boardItem)
        collab.sources = { [weak self] in self?.collabSources() ?? [] }
        collab.start()
        setUpSchedules()
        // 聊天室改名：非 Claude 聊天室的 md 紀錄檔名跟著改（Transcripts.swift）
        store.$conversations.map { Dictionary($0.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a }) }
            .removeDuplicates().dropFirst().debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { Transcripts.renamed($0) }.store(in: &bag)
        collabSub = collab.$open.dropFirst().removeDuplicates().sink { open in
            DispatchQueue.main.async { boardItem.animator().isCollapsed = !open }
        }
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
        // 照上次關掉（⌘ Q）時的位置和大小打開（使用者 10/22 要的）；沒記過、或那個螢幕已經不在（外接螢幕拔掉）才放正中間
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
        // 擺好了才開始記：拖動、調大小就存原始座標（⌘ Q 時 AppDelegate 再存一次）
        if !testing {
            for n in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                NotificationCenter.default.addObserver(forName: n, object: w, queue: .main) { [weak self] _ in self?.saveFrame() }
            }
        }

        host.onNewWindow = { [weak self] in self?.newWindow() }
        host.onEmptyAdd = { [weak self] slot, v in self?.showEmptyMenu(slot: slot, from: v) }
        store.ensureCodeLabGroup()
        host.tabBar.onToggleSidebar = { [weak self] in self?.toggleSidebar() }
        host.onCompact = { [weak self] id in self?.compact(id) }
        // 分頁上的 ×：直接關，跟 ⌘ W 一樣不問（對話都留在側欄，使用者 10/25 要的）；Ctrl+A & 照 tmux 的習慣還是會問
        host.onCloseWindowRequest = { [weak self] i in self?.store.selectWindow(at: i); self?.store.closeWindow() }
        host.onRenameWindowRequest = { [weak self] i in self?.store.selectWindow(at: i); self?.renameWindow() }
        host.sessionMenu = { [weak self] in self?.treeMenu() ?? NSMenu() }
        host.tabBar.onSessions = { [weak self] v in self?.showSessionPanel(from: v) }
        keys = PrefixKeys(controller: self)
        watchDrafts()
        // 關掉的格子（不在任何 Window 裡）閒著就收掉 Claude；版面變了、或某段做完了都檢查一次（Workspace.releaseUnplaced）
        store.$sessions.combineLatest(store.$status).debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.workspace.releaseUnplaced() }.store(in: &bag)
        reconnectPlaced()
        // 瀏覽器格子給 AI 讀的通道（codenv-browser）；名字照側欄
        BrowserServer.shared.titleOf = { [weak self] id in self?.store.conversation(id)?.title }
        BrowserServer.shared.start()
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
    /// url：nil＝掛件用 Gemini、一般格子用空白頁（使用者 10/25：瀏覽器不該預設開 Gemini）
    func newBrowser(url: String? = nil) {
        // ⌘ ⇧ B 是切換（使用者 10/25）：紫框選中聊天室＝開／收它那個框的掛件（Bundles.swift toggleBundle）；選中掛件＝收起那個框的掛件
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
        if let w = r.window, let si = store.sessions.firstIndex(where: { $0.id == r.session }) { store.sessions[si].current = w }
        store.selectSession(r.session)
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
        guard let ids = i.representedObject as? [UUID], let si = store.sessions.firstIndex(where: { $0.id == ids[0] }) else { return }
        store.sessions[si].current = ids[1]
        store.selectSession(ids[0])
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
        guard let w = window, let f = store.currentWindow?.focused, let c = workspace.panes[f] as? ChatPane, !c.webEditing else { return false }
        if let t = w.firstResponder as? NSTextView, t.isEditable { return false }
        if let v = w.firstResponder as? NSView, sequence(first: v, next: { $0.superview }).contains(where: { $0 is TerminalPane }) { return false }
        return c.focusInput()
    }

    /// 輸入框以外按 Tab：輸入框是空的、有灰字建議，就跳回輸入框並採用建議（使用者 10/25）。規則跟 / 一樣：正在打字的地方、終端機照常
    func tabSuggestion(from eventWindow: NSWindow?) -> Bool {
        guard let w = window, let f = store.currentWindow?.focused, let c = workspace.panes[f] as? ChatPane, !c.webEditing else { return false }
        let tv = c.inputBar.textView
        guard w.firstResponder !== tv, tv.string.isEmpty, tv.isEditable, let s = tv.suggestion, !s.isEmpty else { return false }
        // Tab 很常用：只在按鍵是按在主視窗上（不是設定視窗等別的視窗）、焦點就在這格聊天室裡（對話內容上）、而且不在任何可輸入的地方時才攔。
        // 設定視窗、看板輸入框、程式碼區的編輯器、終端機格、瀏覽器格的網頁表單都照常
        guard eventWindow === w, let v = w.firstResponder as? NSView, v.isDescendant(of: c) else { return false }
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
        if let t = w.firstResponder as? NSTextView, t.isEditable { return false }
        if let v = w.firstResponder as? NSView, sequence(first: v, next: { $0.superview }).contains(where: { $0 is TerminalPane }) { return false }
        if sendNow { c.inputBar.sendNowFromOutside() } else { c.inputBar.interruptAndRestore() }
        return true
    }

    func cycleChatMode() -> Bool {
        guard let f = store.currentWindow?.focused, let c = workspace.panes[f] as? ChatPane else { return false }
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

    /// 交接：Claude 讀完這段寫交接 → 同一組開新聊天室、交接當第一則送出 → 原本那格換成新的（舊的留在側欄）
    func handoff(_ id: UUID) {
        guard let c = store.conversation(id), c.terminal != true, !c.isBrowser, !handingOff.contains(id), let dir = store.project(c.projectID)?.path else { return }
        guard Store.claudeHasSession(c.claudeSession, path: dir) else {
            return confirm(L("「\(c.title)」還沒有對話紀錄"), L("先跟 Claude 聊幾句再交接。"), button: L("好")) {}
        }
        confirm(L("交接「\(c.title)」？"), L("Claude 會讀完這段對話寫一份交接（大約半分鐘到幾分鐘，會用到額度），寫好後開一個新聊天室、把交接當第一則訊息送出，新的沿用這個名字、畫面上這一格換成新的。原本的對話改名成「今天日期_原名稱」收進封存（側欄上面的封存按鈕看得到），紀錄不會改。"), button: L("交接")) { [weak self] in
            self?.startHandoff(c, directory: dir)
        }
    }

    func startHandoff(_ c: Conversation, directory: String) {
        handingOff.insert(c.id)
        let oldPane = workspace.panes[c.id] as? ChatPane
        oldPane?.notice(L("正在寫交接…（寫好會開新聊天室，這一格換成新的）"))
        Handoff.write(session: c.claudeSession, directory: directory, model: c.model, effort: c.effort) { [weak self] r in
            guard let self else { return }
            self.handingOff.remove(c.id)
            switch r {
            case .failure(let e):
                if let p = self.workspace.panes[c.id] as? ChatPane { p.notice(L("交接沒寫成：\(e.message)")) }
                else { self.confirm(L("交接沒寫成"), e.message, button: L("好")) {} }
            case .success(let text):
                guard let old = self.store.conversation(c.id) else { return }
                var n = self.store.createConversation(in: old.projectID)
                if let i = self.store.conversations.firstIndex(where: { $0.id == n.id }) {
                    self.store.conversations[i].groupID = old.groupID
                    self.store.conversations[i].model = old.model
                    self.store.conversations[i].effort = old.effort
                    n = self.store.conversations[i]
                }
                // 新的接手原本的名字；舊的改成「交接當天日期_原名稱」（之前交接過的日期換成今天，不疊兩個）
                let f = DateFormatter(); f.dateFormat = "yyyyMMdd"
                let base = old.title.replacingOccurrences(of: #"^\d{8}_"#, with: "", options: .regularExpression)
                self.store.rename(n.id, to: base, byUser: true)
                self.store.rename(old.id, to: f.string(from: Date()) + "_" + base, byUser: true)
                // 舊的收進封存：側欄平常不列（按封存按鈕才看得到），紀錄還在
                self.store.setArchived(old.id, true)
                self.store.reorder(n.id, before: old.id)
                // 原本那格換成新的；舊的沒擺在畫面上就照一般打開
                if !self.store.replacePane(old.id, with: n.id) { self.store.show(n.id) }
                self.store.selected = n.id
                DispatchQueue.main.async {
                    guard let conv = self.store.conversation(n.id), let p = self.workspace.pane(for: conv) as? ChatPane else { return }
                    p.sendText(Handoff.firstMessage(from: old.title, text))
                }
            }
        }
    }

    func switchMode(_ id: UUID, terminal: Bool) {
        workspace.switchMode(id, terminal: terminal)
        host.invalidate(id)
    }

    func deleteConversation(_ id: UUID) {
        workspace.close(id)
        store.removeConversation(id)
    }

    /// 整理視窗的「刪除…」：問過才刪；Claude 的紀錄檔丟垃圾桶（救得回來）。正在跑的、別處開著的不刪
    static let frameName = "AI 工作台主視窗"

    /// 收起／打開左邊的側欄（直接叫分割畫面，不靠回應鏈：視窗不是目前的視窗時也有用）
    @objc func toggleSidebar() { splitController?.toggleSidebar(nil) }
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
        let busy = convs.filter { store.status[$0.id] != nil || live[$0.claudeSession] != nil }
        let targets = convs.filter { c in !busy.contains { $0.id == c.id } }
        guard !targets.isEmpty else {
            confirm(L("沒有可以刪的"), L("選的對話都還在跑（工作台或終端機裡），先停下來再刪。"), button: L("好")) {}
            return
        }
        let names = targets.prefix(5).map { L("・\($0.title)") }.joined(separator: "\n") + (targets.count > 5 ? L("\n…還有 \(targets.count - 5) 段") : "")
        let skip = busy.isEmpty ? "" : L("\n\n（\(busy.count) 段正在跑，先跳過）")
        confirm(L("刪除 \(targets.count) 段對話？"), L("\(names)\n\nClaude 的紀錄檔會丟進垃圾桶，需要時可以從垃圾桶救回。\(skip)"), button: L("丟進垃圾桶")) { [weak self] in
            guard let self else { return }
            for c in targets {
                let path = self.store.project(c.projectID)?.path ?? NSHomeDirectory()
                let file = Store.claudeTranscript(c.claudeSession, path: path)
                let side = file.deletingPathExtension()   // 子代理的紀錄放在同名資料夾
                for u in [file, side] where FileManager.default.fileExists(atPath: u.path) {
                    try? FileManager.default.trashItem(at: u, resultingItemURL: nil)
                }
                self.deleteConversation(c.id)
            }
        }
    }

    func removeProject(_ id: UUID) {
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
        sched.prune(alive: Set(store.conversations.map(\.id)))
        // 測試用：--schedule-fake-send 檔案＝不真的送，把要送的訊息寫進檔案
        let args = CommandLine.arguments
        let fake = args.firstIndex(of: "--schedule-fake-send").flatMap { args.contains("--state-dir") && $0 + 1 < args.count ? args[$0 + 1] : nil }
        sched.deliver = { [weak self] s, message, _ in
            guard let self, let c = self.store.conversation(s.conversation) else { return L("失敗：對話已經刪掉了") }
            if c.terminal == true { return L("失敗：這段對話用終端機打開，排程只能送聊天介面") }
            if c.isBrowser { return L("失敗：這是瀏覽器格子，排程只能送聊天介面") }
            let open = self.workspace.panes[c.id] as? ChatPane
            if open == nil {
                if s.whenClosed == "wait" { return L("等待") }
                if s.whenClosed == "skip" { return L("跳過：聊天室沒開著") }
            }
            guard let p = open ?? self.workspace.pane(for: c) as? ChatPane else { return L("失敗：聊天室開不起來") }
            if let fake {
                let line = "[\(c.title)] opened=\(open != nil) \(message.replacingOccurrences(of: "\n", with: "⏎"))\n"
                if let h = FileHandle(forWritingAtPath: fake) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
                else { try? line.write(toFile: fake, atomically: true, encoding: .utf8) }
                return nil
            }
            p.sendText(message)   // 正在忙會照常排隊，做完再讀
            return nil
        }
        // 送到一半當掉重開：紀錄檔最後 512 KB 裡已經有這則（開頭帶到期時間）就算送過
        sched.alreadySent = { [weak self] id, marker in
            guard let self, let c = self.store.conversation(id), let path = self.store.project(c.projectID)?.path else { return false }
            let url = ConversationMover.root.appendingPathComponent(ConversationMover.slug(path)).appendingPathComponent(c.claudeSession.uuidString.lowercased() + ".jsonl")
            guard let h = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            try? h.seek(toOffset: size > 524_288 ? size - 524_288 : 0)
            guard let d = try? h.readToEnd() else { return false }
            return d.range(of: Data(marker.utf8)) != nil
        }
        sched.start()
    }

    /// 對話右鍵「排程…」
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
