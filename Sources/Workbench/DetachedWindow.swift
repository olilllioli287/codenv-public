import AppKit
import Combine

// 把 Window 分頁拉到主視窗外面放開 → 開一個獨立的 macOS 視窗，裡面只有那個 Window 的聊天格（沒有側欄、沒有用量欄、沒有分頁列）。
// 做法：Window 還留在 Session 裡（只是 detached＝true，排在 windows 最後面，主視窗的分頁列不畫它），所以對話一直算「有擺在版面上」，不會被當成沒擺的收掉。
// 獨立視窗拿到焦點時 store.scope 指向它，切格、拖曳、關格這些「改目前的 Window」的操作就落在它身上。
// 關掉獨立視窗：Window 回到主視窗分頁列的最後面、變成目前的 Window，對話都還在。
// 重開 App：獨立視窗照上次的位置和大小還原（WindowLayout.detachedFrame／detachedScreen，搬動、調大小時 0.5 秒 debounce 後存）。
// 原本的螢幕不在了就放到主螢幕，大小夾在可見範圍內；整個跑到所有螢幕外面的也拉回來。

final class DetachedWindowController: NSWindowController, NSWindowDelegate {
    let store: Store
    let windowID: UUID
    let host: WindowHost
    var onClosed: ((UUID) -> Void)?
    /// 關掉飛回去的目標（螢幕座標，分頁列上新分頁的位置）與到了之後的動作（讓那個分頁亮一下）
    var flyBackTarget: (() -> NSPoint?)?
    var arrived: (() -> Void)?
    private var closing = false
    /// ⌘ Q 結束中：獨立視窗跟著關掉時不要把 Window 收回主視窗（要保持獨立的狀態存檔）
    static var terminating = false
    private var saveTimer: Timer?
    private var bag: Set<AnyCancellable> = []

    init(store: Store, workspace: Workspace, windowID: UUID, at screenPoint: NSPoint, restoreFrame: NSRect? = nil) {
        self.store = store
        self.windowID = windowID
        host = WindowHost(store: store, workspace: workspace, boundWindow: windowID)
        let w = NSWindow(contentRect: NSRect(x: screenPoint.x - 450, y: screenPoint.y - 320, width: 900, height: 640),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.minSize = NSSize(width: 360, height: 260)
        w.isReleasedWhenClosed = false
        super.init(window: w)
        shouldCascadeWindows = false
        w.contentViewController = host
        w.setFrame(NSRect(x: screenPoint.x - 450, y: screenPoint.y - 320, width: 900, height: 640), display: false)   // 指定 contentViewController 會把視窗縮成它的大小：再設回來
        w.delegate = self
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) }) ?? NSScreen.main {
            // 放開的位置不要讓視窗整個跑到螢幕外
            var f = w.frame
            f.origin.x = max(screen.visibleFrame.minX, min(f.origin.x, screen.visibleFrame.maxX - f.width))
            f.origin.y = max(screen.visibleFrame.minY, min(f.origin.y, screen.visibleFrame.maxY - f.height))
            w.setFrame(f, display: false)
        }
        if let r = restoreFrame { w.setFrame(r, display: false) }
        TestScreen.fit(w)
        updateTitle()
        store.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateTitle() }.store(in: &bag)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func updateTitle() {
        let t = store.sessions.flatMap(\.windows).first { $0.id == windowID }
        // 這個 Window 被刪掉了（例如最後一格用 ⌘ W 關掉）：獨立視窗跟著關
        if t == nil { closing = true; DispatchQueue.main.async { [weak self] in self?.window?.close() }; return }
        let name = t.map { w in w.renamed ? w.name : (w.focused.flatMap { store.conversation($0)?.title } ?? w.name) } ?? ""
        if window?.title != name { window?.title = name }
    }

    // MARK: 記位置

    /// 存下來的位置轉回螢幕上的 frame：找原本那個螢幕（名字對得上）；不在了就用主螢幕；大小夾在可見範圍內、整個窗拉回可見範圍
    static func resolveFrame(_ f: [Double], screenName: String?, screenOrigin: [Double]? = nil) -> NSRect? {
        guard f.count == 4 else { return nil }
        // 先找名字和原點都對得上的（兩台同型號螢幕名字一樣），再只比名字，最後才用主螢幕
        let named = NSScreen.screens.filter { $0.localizedName == screenName }
        let exact = screenOrigin.flatMap { o in o.count == 2 ? named.first { abs(Double($0.frame.minX) - o[0]) < 1 && abs(Double($0.frame.minY) - o[1]) < 1 } : nil }
        let screen = exact ?? named.first ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return nil }
        let vf = screen.visibleFrame
        let w = min(max(360, f[2]), vf.width), h = min(max(260, f[3]), vf.height)
        let x = max(vf.minX, min(screen.frame.minX + f[0], vf.maxX - w))
        let y = max(vf.minY, min(screen.frame.minY + f[1], vf.maxY - h))
        return NSRect(x: x, y: y, width: w, height: h)
    }
    private func scheduleFrameSave() {
        guard !closing else { return }
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in self?.saveFrameNow() }
    }
    /// 立刻存（結束 App 前也呼叫一次，免得最後一下搬動還在等 debounce）
    func saveFrameNow() {
        saveTimer?.invalidate(); saveTimer = nil
        guard !closing, let w = window, w.isVisible else { return }
        store.setDetachedFrame(windowID, frame: w.frame, screen: w.screen)
    }
    func windowDidMove(_ n: Notification) { scheduleFrameSave() }
    func windowDidResize(_ n: Notification) { scheduleFrameSave() }

    func windowDidBecomeKey(_ n: Notification) { store.scope = windowID }
    func windowDidResignKey(_ n: Notification) { if store.scope == windowID { store.scope = nil } }

    /// 按關閉：先縮小飛回主視窗分頁列、淡出，到了才真的關（關掉時 Window 才回到分頁列）。減少動態效果時只淡出
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closing { return true }
        closing = true
        let finish = { [weak self] in
            guard let self, let w = self.window else { return }
            w.orderOut(nil)
            w.close()
            self.arrived?()
        }
        if Motion.reduced || window?.isVisible != true {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; sender.animator().alphaValue = 0 }, completionHandler: finish)
            return false
        }
        var target = sender.frame
        if let p = flyBackTarget?() { target = NSRect(x: p.x - 40, y: p.y - 12, width: 80, height: 24) }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            sender.animator().setFrame(target, display: true)
            sender.animator().alphaValue = 0
        }, completionHandler: finish)
        return false
    }

    /// 事件紀錄專用的識別字串：記對話 UUID 前 8 碼與模型類別（不記標題自由文字）
    var logConversationDesc: String {
        let w = store.sessions.flatMap(\.windows).first { $0.id == windowID }
        if let cid = w?.focused, let c = store.conversation(cid) {
            return "對話 \(String(c.claudeSession.uuidString.prefix(8).uppercased()))（\(c.modelCategory)）"
        }
        return "視窗 \(String(windowID.uuidString.prefix(8).uppercased()))"
    }

    func windowWillClose(_ n: Notification) {
        saveTimer?.invalidate(); saveTimer = nil
        if store.scope == windowID { store.scope = nil }
        host.resetTransientDragState()
        if !Self.terminating {
            store.attachWindow(windowID)       // 回到主視窗的分頁列，對話不會消失（結束 App 時不收：保持獨立的狀態存檔）
            EventLog.log("獨立視窗", "收回 \(logConversationDesc)")
        }
        onClosed?(windowID)
    }

    /// from：預覽小視窗的位置和大小（螢幕座標）；獨立視窗從那裡長大、淡入到最後的位置（約 0.25 秒）。減少動態效果時只淡入
    func show(from: NSRect? = nil) {
        guard let w = window else { return }
        // 背景測試（--background）：跟主視窗一樣放到最後面，不要跳到使用者正在用的視窗上面
        if CommandLine.arguments.contains("--background") { w.orderBack(nil); return }
        let final = w.frame
        w.alphaValue = 0
        if let from, !Motion.reduced { w.setFrame(from, display: false) }
        w.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            if from != nil, !Motion.reduced { w.animator().setFrame(final, display: true) }
            w.animator().alphaValue = 1
        }
    }
}

extension MainWindowController {
    /// 分頁（主視窗分頁列上的第 index 個）拉到視窗外面：開獨立視窗
    func detachWindowTab(_ index: Int, at screenPoint: NSPoint) {
        guard let si = store.sessionIndex else { return }
        let visible = store.sessions[si].windows.filter { !$0.detached }
        guard visible.indices.contains(index) else { return }
        let id = visible[index].id
        guard store.detachWindow(id) else { NSSound.beep(); return }   // 主視窗至少要留一個 Window
        let c = DetachedWindowController(store: store, workspace: workspace, windowID: id, at: screenPoint)
        configureDetached(c, id: id)
        detachedWindows[id] = c
        c.show(from: host.detachPreview.consume())
        EventLog.log("獨立視窗", "拉出 \(c.logConversationDesc)（\(EventLog.windowSummary(c.window))）")
        Toast.show(L("已拉出成獨立視窗，關掉它就會回到這裡"), over: window)
        // 剛拉出去的位置也記下來（不用等使用者再動它）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak c] in c?.saveFrameNow() }
    }

    /// 重開 App：把存檔裡 detached 的 Window 開成獨立視窗，放回上次的位置（沒記到位置的放在主視窗附近）
    func restoreDetachedWindows() {
        for s in store.sessions {
            for w in s.windows where w.detached && detachedWindows[w.id] == nil {
                let rect = w.detachedFrame.flatMap { DetachedWindowController.resolveFrame($0, screenName: w.detachedScreen, screenOrigin: w.detachedScreenOrigin) }
                let p = NSPoint(x: self.window?.frame.midX ?? 600, y: self.window?.frame.midY ?? 400)
                let c = DetachedWindowController(store: store, workspace: workspace, windowID: w.id, at: p, restoreFrame: rect)
                configureDetached(c, id: w.id)
                detachedWindows[w.id] = c
                c.window?.orderFront(nil)
                EventLog.log("獨立視窗", "還原 \(c.logConversationDesc)（\(EventLog.windowSummary(c.window))）")
            }
        }
    }

    private func configureDetached(_ c: DetachedWindowController, id: UUID) {
        guard let (si, _) = store.windowPosition(id) else { return }
        c.onClosed = { [weak self] id in self?.detachedWindows[id] = nil }
        c.flyBackTarget = { [weak self] in self?.host.tabBar.plusScreenCenter() }
        // 記住它原本在哪個 Session：關閉動畫 0.25 秒期間使用者可能切了 Session 或把這個 Window 刪了，到了之後用「當下的」Session 去閃會閃錯
        let sid = store.sessions[si].id
        c.arrived = { [weak self] in
            guard let self, let si = self.store.sessions.firstIndex(where: { $0.id == sid }), self.store.currentSession == sid,
                  let vi = self.store.sessions[si].windows.filter({ !$0.detached }).firstIndex(where: { $0.id == id }) else { return }   // Window 已經不在了就不閃
            self.host.tabBar.flashTab(vi)
        }
    }
}
