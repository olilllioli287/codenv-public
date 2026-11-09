import AppKit
import SwiftUI
import SwiftTerm
import WebKit

// 必須在 NSApplication 建立視窗前註冊，停用 macOS 自己的視窗還原。
UserDefaults.standard.register(defaults: [
    "ApplePersistenceIgnoreState": true,
    "NSQuitAlwaysKeepsWindows": false
])

// AI 工作台：自己的 AI 工作環境。左邊照 Codex 的側欄（專案→對話），右邊每個對話一格跑 Claude Code 的終端機。
// 不用 tmux：關掉 App 再開，用 Claude 的 --resume 接回同一段對話。
// 測試用參數：--dump-theme（印出從 iTerm 讀到的字型配色）、--state-dir <資料夾>（資料存到別的地方，不碰平常用的）、
//   --background（開起來不搶焦點）、--send "秒數:文字"（幾秒後把文字送進目前那格，可以給好幾個；\r 代表 Enter）
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }

    func application(_ app: NSApplication, shouldRestoreApplicationState coder: NSCoder) -> Bool { false }

    func application(_ app: NSApplication, shouldSaveApplicationState coder: NSCoder) -> Bool { false }

    var store: Store!
    var workspace: Workspace!
    var focusWatch: FocusWatch?
    var main: MainWindowController!
    var settings: SettingsWindowController?
    var importer: ImportWindowController?
    var organizer: OrganizerWindowController?
    private var autoImportTimer: Timer?
    var recoveryProbeLabs: [CodeLabView] = [] // TestHarness 用
    let appearance = AppearanceSettings()

    /// 資料夾鎖的檔案描述子：整個程序活著就一直開著（關了鎖就放掉）
    private static var dataLockFD: Int32 = -1
    static func lockDataDir(_ dir: URL) -> Bool {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // O_CLOEXEC：開 claude 等子程序時不要被繼承，不然子程序活著鎖就放不掉，下次開 codenv 會被自己擋掉（Flash 11/6）
        let fd = open(dir.appendingPathComponent("codenv.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return true }          // 連鎖檔都開不了（權限）：不擋啟動，照舊（Store 自己有保護）
        // 舊的那個可能正在結束（剛按 ⌘ Q 就又打開）：最多等 3 秒
        var got = flock(fd, LOCK_EX | LOCK_NB) == 0
        for _ in 0..<15 where !got { usleep(200_000); got = flock(fd, LOCK_EX | LOCK_NB) == 0 }
        if !got { close(fd); return false }
        dataLockFD = fd
        return true
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        // 寫給已經結束的 claude 不要整個 App 被 SIGPIPE 殺掉（寫入錯誤在 ChatSession 自己處理）
        signal(SIGPIPE, SIG_IGN)
        let args = CommandLine.arguments
        installTestHooksEarly(args)
        EventLog.start()
        // 同一個資料夾只准一個 codenv：兩個各自載入再輪流寫整份 state.json 會互蓋，第二個還會刪掉第一個的 browser socket（Astra 11/5）
        // 鎖在獨立的 codenv.lock（不鎖會被原子替換的 state.json）；程序結束或當掉時系統自動放開。不同 --state-dir 照樣能並行
        // --state-dir 後面沒給資料夾：不能悄悄落回正式資料（後面又把它當測試實例），直接報錯結束
        if let i = args.firstIndex(of: "--state-dir"), i + 1 >= args.count || args[i + 1].hasPrefix("--") {
            FileHandle.standardError.write(Data("codenv：--state-dir 後面要接資料夾\n".utf8))
            exit(2)
        }
        let dataDir = args.firstIndex(of: "--state-dir").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1], isDirectory: true) : nil } ?? Edition.supportDir
        if !Self.lockDataDir(dataDir) {
            EventLog.log(L("啟動"), L("這個資料夾已經有另一個 codenv 在用，這次不開：\(dataDir.path)"))
            FileHandle.standardError.write(Data("codenv：\(dataDir.path) 已經有另一個 codenv 在用\n".utf8))
            if !args.contains("--state-dir") {
                // 使用者自己再點一次 codenv：把開著的那個叫出來就好（不跳視窗、不搶別人的焦點，本來就是使用者要看它）
                let me = ProcessInfo.processInfo.processIdentifier
                NSRunningApplication.runningApplications(withBundleIdentifier: Edition.bundleID).first { $0.processIdentifier != me }?.activate()
            }
            exit(0)
        }
        // 拖進來的暫存圖片，超過一天的清掉。要拿到資料夾的鎖之後才清（沒拿到鎖的第二個實例會馬上結束）；
        // 這個暫存資料夾所有實例共用，測試實例（--state-dir）不碰，不然測試會刪掉正式實例的草稿還指著的檔案
        if !args.contains("--state-dir") { TerminalPane.cleanDropFolder(folder: TerminalPane.dropFolder, stateDir: dataDir) }      // 草稿／寄件匣還指著的不刪
        if let i = args.firstIndex(of: "--state-dir"), i + 1 < args.count {
            store = Store(directory: URL(fileURLWithPath: args[i + 1], isDirectory: true))
        } else {
            store = Store()
        }
        EventLog.log(L("啟動"), L("codenv \(Edition.version.isEmpty ? "dev" : Edition.version)，\(Feedback.systemLine)，螢幕：\(EventLog.screensSummary())"))
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            EventLog.log(L("螢幕"), L("螢幕設定變更：\(EventLog.screensSummary())"))
        }
        // 按鍵統計（KeyStats.swift）：讀進舊的統計，之後按鍵才開始記（存在 state 資料夾）
        KeyStats.shared.start(in: store.directory)
        let webUnloadSeconds = testWebUnloadSeconds(args)
        workspace = Workspace(store: store, theme: appearance.theme, webUnloadSeconds: webUnloadSeconds)
        focusWatch = FocusWatch(store: store, workspace: workspace)   // 查焦點自己跳格（FocusWatch.swift）
        installChatTestHooks(args)
        appearance.onChange = { [weak self] in
            guard let self else { return }
            self.workspace.applyTheme(self.appearance.theme)
            self.main?.floatingTerminal.applyTheme(self.appearance.theme)
        }
        // 側欄的專案跟 iTerm 的 claude 選單清單（~/.claude/envs）同步；切回 App 時再對一次（可能在 iTerm 改過）
        store.syncEnvs()
        store.applyClassification(in: store.directory)
        store.refreshActivity()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.store.syncEnvs()
            self?.store.refreshActivity()
        }
        // 開著不關的時候，滿一週的對話也要自己收進封存
        Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            self?.store.refreshActivity()
            self?.store.objectWillChange.send()
        }
        main = MainWindowController(store: store, workspace: workspace)
        main.setupActivationFocus()
        main.dailyHandoff.start()
        DispatchQueue.main.async { [weak self] in self?.main.restoreDetachedWindows() }   // 上次獨立出去的 Window 照原位置開回來
        main.openSettings = { [weak self] in self?.showSettings() }
        buildMenu()
        Prefs.shared.applyAppearance()
        GeminiSkin.startObservingAppearance()
        UpdateCheck.shared.start(directory: store.directory)
        // 公版 agy 預設開但提醒還沒看過：開 App、回到前景時跳一次（看板執行器沒領步驟、桌寵提醒的時候就是靠這個叫人回來看）
        DispatchQueue.main.async { Prefs.shared.checkAgyNotice() }
        // 設定檔讀不到、這次不存檔：跳一次提示（測試實例只記 log，不跳視窗）
        if let problem = store.startupProblem {
            NSLog("codenv：%@", problem)
            if !CommandLine.arguments.contains("--state-dir") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    let a = NSAlert(); a.alertStyle = .warning
                    a.messageText = self.store.startupTitle ?? L("設定檔讀不到，這次不會存檔")
                    a.informativeText = problem
                    a.addButton(withTitle: L("好"))
                    a.runModal()
                }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in Prefs.shared.checkAgyNotice() }
        I18n.startDumpIfAsked()
        installFeedbackTestHooks(args)
        // 自動加入正在 tmux／iTerm 裡進行的對話（匯入視窗裡的選項）
        autoImportTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, appDefaults.bool(forKey: "autoImportLive") else { return }
            ClaudeSessions.importLive(into: self.store)
        }
        if appDefaults.bool(forKey: "autoImportLive") { ClaudeSessions.importLive(into: store) }
        if args.contains("--background") {
            main.window?.orderBack(nil)
        } else {
            main.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        installTestHooks(args)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    /// ⌘ Q 結束前檢查所有格子有沒有在跑的東西
    func runningSummary() -> [String] {
        workspace.runningSummary() + (main.floatingTerminal.hasRunningProcess ? [L("浮動終端機：有程式在跑")] : [])
    }

    /// ⌘ Q 前存程式碼區時用：存的期間再按 ⌘ Q 不重複存；使用者選了「不存，直接結束」就跳過檢查
    private var quitSaving = false

    // 還有東西在跑：先問一聲，不要直接把正在工作的程式關掉
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 設定檔讀不懂、這次一直沒存：結束前再提醒一次（改動關掉就沒了）。測試實例／背景不問
        if store.isSaveProtected, !CommandLine.arguments.contains("--background"), !CommandLine.arguments.contains("--state-dir") {
            let a = NSAlert(); a.alertStyle = .warning
            a.messageText = L("這次的改動不會存")
            a.informativeText = L("設定檔 state.json 這次讀不懂，為了不蓋掉它，這次執行沒有存檔；現在結束，剛才的改動就沒了。")
            let cancel = a.addButton(withTitle: L("取消"))
            cancel.keyEquivalent = "\u{1b}"
            let quit = a.addButton(withTitle: L("直接結束"))
            quit.keyEquivalent = ""
            if a.runModal() != .alertSecondButtonReturn { return .terminateCancel }
        }
        // 程式碼區改了沒存（沒有自動存檔）：先存好再結束，不然 ⌘ Q 會直接丟掉修改（Astra 11/5 審查抓到）
        let unsaved = workspace.panes.values.compactMap { ($0 as? ChatPane)?.codeLab }.filter { $0.hasUnsaved }
        if !unsaved.isEmpty {
            if quitSaving { return .terminateCancel }   // 上一次 ⌘ Q 還在存：這次不算
            quitSaving = true
            let interactive = !CommandLine.arguments.contains("--background")
            var left = unsaved, allOK = true
            func next() {
                guard let lab = left.first else {
                    quitSaving = false
                    // 都存好了：接著照原本的流程（還有東西在跑照樣會問）；用 terminateLater＋reply，登出／關機時不會被打斷
                    if allOK { NSApp.reply(toApplicationShouldTerminate: busyReply() == .terminateNow); return }
                    guard interactive else { NSApp.reply(toApplicationShouldTerminate: false); return }
                    let a = NSAlert()
                    a.messageText = L("程式碼區有修改沒存成")
                    a.informativeText = L("存檔失敗或被取消，先不結束。要放棄這些修改直接結束嗎？")
                    let cancel = a.addButton(withTitle: L("取消"))
                    cancel.keyEquivalent = "\u{1b}"
                    let force = a.addButton(withTitle: L("不存，直接結束"))
                    force.keyEquivalent = ""
                    force.hasDestructiveAction = true
                    let giveUp = a.runModal() == .alertSecondButtonReturn
                    let quitting = giveUp && busyReply() == .terminateNow
                    if quitting { unsaved.forEach { $0.discardRecoveryForQuit() } }
                    NSApp.reply(toApplicationShouldTerminate: quitting)
                    return
                }
                left.removeFirst()
                lab.saveForClose(interactive: interactive) { ok in
                    if !ok { allOK = false }
                    next()
                }
            }
            next()
            return .terminateLater
        }
        return busyReply()
    }

    /// 有東西在跑就問要不要強制結束（程式碼區的存檔在上面先處理）
    private func busyReply() -> NSApplication.TerminateReply {
        let busy = runningSummary()
        guard !busy.isEmpty, !CommandLine.arguments.contains("--background") else { return .terminateNow }
        let a = NSAlert()
        a.messageText = L("有東西正在跑")
        var lines = Array(busy.prefix(5))
        if busy.count > 5 {
            lines.append(L("還有 \(busy.count - 5) 項"))
        }
        let list = lines.joined(separator: "\n")
        a.informativeText = L("\(list)\n\n結束的話這些都會停掉；Claude 會停在做到一半的地方，下次打開可以接著問。") + "\n\n" + L("再按一次 ⌘ Q 也會強制結束。")

        // 按鈕順序：「取消」（第一顆、預設、Esc）、「強制結束」（hasDestructiveAction = true）
        let cancelBtn = a.addButton(withTitle: L("取消"))
        cancelBtn.keyEquivalent = "\u{1b}"
        let forceBtn = a.addButton(withTitle: L("強制結束"))
        forceBtn.keyEquivalent = ""
        forceBtn.hasDestructiveAction = true

        // 對話框開著時再按 ⌘ Q＝強制結束。剛跳出來 0.6 秒內的不算（連按兩下 ⌘ Q 是常見的手滑），按住不放的重複鍵也不算；
        // ⌘ Q 一律在這裡吃掉，不然會再走一次選單的「結束」
        let shownAt = Date()
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  e.charactersIgnoringModifiers?.lowercased() == "q" else { return e }
            if !e.isARepeat, Date().timeIntervalSince(shownAt) > 0.6 { forceBtn.performClick(nil) }
            return nil
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        return a.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ n: Notification) {
        DetachedWindowController.terminating = true      // 獨立視窗跟著關掉時不要收回主視窗：保持獨立的狀態存檔
        for c in main.detachedWindows.values { c.saveFrameNow() }
        store.saveNow()
        for pane in workspace.panes.values { (pane as? ChatPane)?.flushDraft() }
        main.saveFrame()   // ⌘ Q 時的位置，下次照這個開
        for p in workspace.panes.values { p.terminate() }
        main.lidKeeper?.shutdown()
        main.floatingTerminal.terminate()
        EventLog.log(L("結束"), L("codenv 結束"))
        EventLog.flush()
    }

    /// ⌘ W：關設定、整理對話這類小視窗；在主視窗是關掉目前那格（只剩一格才關 Window，對話留在側欄），主視窗本身不關
    @objc func closeSideWindow() {
        guard let w = NSApp.keyWindow else { return NSSound.beep() }
        if w === main.window { store.closePaneOrWindow() } else { w.performClose(nil) }
    }

    /// ⌃ ⌘ W：關掉目前整個 Window（對話留在側欄）；原本是 ⌃ W
    @objc func closeWholeWindow() { store.closeWindow() }
    @objc func toggleFloatingTerminal() { main.floatingTerminal.toggle() }
    @objc func toggleGraphPanel() { main.toggleGraphPanel() }
    @objc func toggleUsageSheet() { UsageSheet.toggleForShortcut(in: NSApp.keyWindow) }
    @objc func toggleHelpSheet() { HelpSheet.toggle(in: NSApp.keyWindow) }
    @objc func resetFloatingTerminalFrame() { main.floatingTerminal.resetGeometry() }

    /// ⌘ ⇧ T：找回剛關掉的格子或 Window（主視窗裡由 PrefixKeys 先攔；這裡給選單點、或焦點在小視窗時用）
    @objc func newTabWindow() { main.newWindow() }
    @objc func reopenWindow() {
        if !store.reopenClosedWindow() { NSSound.beep() }
    }

    /// 重新建立設定視窗並停在「對話」頁（Prefs.openChatSettings 先把 settingsTab 寫成 chat）
    func showChatSettings() { settings?.close(); settings = nil; showSettings() }

    @objc func showSettings() {
        if settings == nil { settings = SettingsWindowController(store: store, appearance: appearance) }
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func checkForUpdates() { UpdateCheck.shared.check(manual: true) }
    @objc func showEventConsole() { EventConsoleWindowController.shared.present() }
    @objc func showFeedback() { Feedback.present() }

    @objc func newConversation() { main.newConversation() }
    @objc func newBrowser() { main.newBrowser() }
    @objc func togglePetSlot() { PetSlot.enabled.toggle() }
    @objc func toggleSidebar() { main.toggleSidebar() }
    @objc func toggleRightPanel() { main.toggleRightPanel() }
    @objc func zoomIn() { UIScale.shared.bigger() }
    @objc func zoomOut() { UIScale.shared.smaller() }
    @objc func zoomReset() { UIScale.shared.reset() }
    @objc func showImporter() {
        if importer == nil { importer = ImportWindowController(store: store) }
        importer?.model.reload()
        importer?.showWindow(nil)
        importer?.window?.makeKeyAndOrderFront(nil)
    }
    @objc func addProject() { main.addProject() }
    @objc func showOrganizer() {
        if organizer == nil {
            organizer = OrganizerWindowController(store: store,
                open: { [weak self] id in self?.store.open(id); self?.main.window?.makeKeyAndOrderFront(nil) },
                delete: { [weak self] ids in self?.main.deleteConversations(ids) },
                removeFolder: { [weak self] id in self?.main.removeProject(id) })
        }
        organizer?.model.loadSizes(store)
        organizer?.showWindow(nil)
        organizer?.window?.makeKeyAndOrderFront(nil)
    }

    private func buildMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("關於 codenv"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("設定…"), action: #selector(showSettings), keyEquivalent: ",")
        if Edition.updateRepo != nil { appMenu.addItem(withTitle: L("檢查更新…"), action: #selector(checkForUpdates), keyEquivalent: "") }
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("隱藏 codenv"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: L("結束 codenv"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem(); menu.addItem(fileItem)
        let fileMenu = NSMenu(title: L("檔案"))
        fileMenu.addItem(withTitle: L("新對話"), action: #selector(newConversation), keyEquivalent: "n")
        let browser = fileMenu.addItem(withTitle: L("新瀏覽器"), action: #selector(newBrowser), keyEquivalent: "")
        func updateBrowserEntry() {
            let enabled = Prefs.shared.webFeaturesEnabled
            browser.isHidden = !enabled
            browser.keyEquivalent = enabled ? "B" : ""   // 關閉時連 ⌘ ⇧ B 都不註冊。
        }
        updateBrowserEntry()
        NotificationCenter.default.addObserver(forName: Prefs.webFeaturesChanged, object: nil, queue: .main) { _ in updateBrowserEntry() }
        let add = fileMenu.addItem(withTitle: L("新增專案…"), action: #selector(addProject), keyEquivalent: "o")
        add.keyEquivalentModifierMask = [.command, .shift]
        let imp = fileMenu.addItem(withTitle: L("從 Claude Code 匯入對話…"), action: #selector(showImporter), keyEquivalent: "i")
        imp.keyEquivalentModifierMask = [.command, .shift]
        let org = fileMenu.addItem(withTitle: L("整理對話…"), action: #selector(showOrganizer), keyEquivalent: "l")
        org.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: L("關閉這格（只剩一格時關掉這個 Window）"), action: #selector(closeSideWindow), keyEquivalent: "w")
        let cw = fileMenu.addItem(withTitle: L("關掉整個 Window"), action: #selector(closeWholeWindow), keyEquivalent: "w")
        cw.keyEquivalentModifierMask = [.command, .control]
        fileMenu.addItem(withTitle: L("新 Window"), action: #selector(newTabWindow), keyEquivalent: "t")
        fileMenu.addItem(withTitle: L("重新打開剛關掉的格子或 Window"), action: #selector(reopenWindow), keyEquivalent: "T")   // 大寫＝⌘ ⇧ T
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem(); menu.addItem(editItem)
        let editMenu = NSMenu(title: L("編輯"))
        editMenu.addItem(withTitle: L("復原"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: L("重做"), action: Selector(("redo:")), keyEquivalent: "Z")   // 大寫＝要按 ⇧（⌘ ⇧ Z）
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("剪下"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("拷貝"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("貼上"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("全選"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let viewItem = NSMenuItem(); menu.addItem(viewItem)
        let viewMenu = NSMenu(title: L("顯示方式"))
        let floating = viewMenu.addItem(withTitle: L("浮動終端機"), action: #selector(toggleFloatingTerminal), keyEquivalent: "`")
        floating.keyEquivalentModifierMask = [.control]
        viewMenu.addItem(withTitle: L("浮動終端機：回到預設位置"), action: #selector(resetFloatingTerminalFrame), keyEquivalent: "")
        let side = viewMenu.addItem(withTitle: L("收起／打開側欄"), action: #selector(toggleSidebar), keyEquivalent: "s")
        side.keyEquivalentModifierMask = [.command, .control]
        // F3／F4：實際是 PrefixKeys 先攔下來處理（終端機格裡也有效）；列在選單裡讓人看得到
        let f3 = viewMenu.addItem(withTitle: L("收起／打開左側欄（F3）"), action: #selector(toggleSidebar), keyEquivalent: String(UnicodeScalar(NSF3FunctionKey)!))
        f3.keyEquivalentModifierMask = []
        let f4 = viewMenu.addItem(withTitle: L("收起／打開右側欄（F4）"), action: #selector(toggleRightPanel), keyEquivalent: String(UnicodeScalar(NSF4FunctionKey)!))
        f4.keyEquivalentModifierMask = []
        let f6 = viewMenu.addItem(withTitle: L("關聯圖面板（F6）"), action: #selector(toggleGraphPanel), keyEquivalent: String(UnicodeScalar(NSF6FunctionKey)!))
        f6.keyEquivalentModifierMask = []
        let f12 = viewMenu.addItem(withTitle: L("全部的用量（F12）"), action: #selector(toggleUsageSheet), keyEquivalent: String(UnicodeScalar(NSF12FunctionKey)!))
        f12.keyEquivalentModifierMask = []
        viewMenu.addItem(withTitle: L("桌寵位置（Ctrl+A b）"), action: #selector(togglePetSlot), keyEquivalent: "")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: L("放大文字"), action: #selector(zoomIn), keyEquivalent: "=")
        viewMenu.addItem(withTitle: L("縮小文字"), action: #selector(zoomOut), keyEquivalent: "-")
        viewMenu.addItem(withTitle: L("文字實際大小"), action: #selector(zoomReset), keyEquivalent: "0")
        viewItem.submenu = viewMenu

        let winItem = NSMenuItem(); menu.addItem(winItem)
        let winMenu = NSMenu(title: L("視窗"))
        winMenu.addItem(withTitle: L("縮到 Dock"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = winMenu
        NSApp.windowsMenu = winMenu

        let helpItem = NSMenuItem(); menu.addItem(helpItem)
        let helpMenu = NSMenu(title: L("說明"))
        helpMenu.addItem(withTitle: L("事件紀錄…"), action: #selector(showEventConsole), keyEquivalent: "")
        let help = helpMenu.addItem(withTitle: L("codenv 說明（F1）"), action: #selector(toggleHelpSheet), keyEquivalent: String(UnicodeScalar(NSF1FunctionKey)!))
        help.keyEquivalentModifierMask = []
        if Feedback.available {
            helpMenu.addItem(withTitle: L("回報問題…"), action: #selector(showFeedback), keyEquivalent: "")
        }
        helpItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu
        NSApp.mainMenu = menu
    }
}

// --state-dir 一定要接路徑：各處只看「有沒有 --state-dir」就放行測試開關，漏接路徑時資料夾卻會退回正式資料，
// 等於在正式資料上跑測試（agy Argon 11/6 審查）。在這裡一次擋掉，不開
if let i = CommandLine.arguments.firstIndex(of: "--state-dir") {
    let a = CommandLine.arguments
    if i + 1 >= a.count || a[i + 1].isEmpty || a[i + 1].hasPrefix("-") {
        FileHandle.standardError.write(Data("codenv：--state-dir 後面要接資料夾路徑，這次不開\n".utf8))
        exit(2)
    }
}
if CommandLine.arguments.contains("--quote-selftest") { exit(QuoteTextTests.run() ? 0 : 1) }

// 在任何 App／EventLog／偏好設定初始化之前退出，不讀取日常資料，也不開視窗。
if CommandLine.arguments.contains("--outbox-selftest"),
   let index = CommandLine.arguments.firstIndex(of: "--state-dir"), index + 1 < CommandLine.arguments.count {
    exit(OutboxProbe.run(in: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)) ? 0 : 1)
}
if let i = CommandLine.arguments.firstIndex(of: "--archive-selftest"), i + 1 < CommandLine.arguments.count,
   let s = CommandLine.arguments.firstIndex(of: "--state-dir"), s + 1 < CommandLine.arguments.count {
    exit(Store.runArchiveSelfTest(in: URL(fileURLWithPath: CommandLine.arguments[s + 1], isDirectory: true),
                                  out: CommandLine.arguments[i + 1],
                                  waitStop: CommandLine.arguments.contains("--wait-stop")) ? 0 : 1)
}

let app = KeyStatsApp.shared   // 按鍵統計：按鍵先經過它（KeyStats.swift）
let delegate = AppDelegate()
app.delegate = delegate
if CommandLine.arguments.contains("--background") {
    app.setActivationPolicy(.accessory)
} else {
    app.setActivationPolicy(.regular)
}
app.run()
