import AppKit

// Ctrl+A 開頭的按鍵，照使用者的 ~/.tmux.conf（prefix 是 Ctrl+A）：
//   |  往右切   -  往下切   h j k l  換格   Ctrl+h/j/k/l  調大小（一秒內可以連按，不用再按 Ctrl+A）
//   x  關這格（Enter 確定）   &  關整個 Window（Enter 確定）   ,  Window 改名   $  Session 改名
//   c  新 Window   n / p  下一個／上一個 Window   1～9  第幾個 Window   z  放大這格
//   s / w  列出 Session 和 Window 來選   ( / )  上一個／下一個 Session
//   b  右下角開／關桌寵的位置
// 不用 Ctrl+A 的：⌘ W 關這格、⌃ ⌘ W 關整個 Window（對話留在側欄）、⌃ T 新 Window（終端機格裡照樣交給終端機）、⌘ 1～9 跳到第幾個 Window
//   a  把 Ctrl+A 本身送出（輸入框跳到行首）   Ctrl+A  中文指令選單   ?  也是選單
// 原生 App 收按鍵早於輸入法，所以唯音開著中文也不用先切英文（tmux 那邊要靠 ~/.codenv-ime）。

final class PrefixKeys {
    weak var controller: MainWindowController?
    private var armed = false
    private var repeatUntil: TimeInterval = 0
    private var monitor: Any?
    private var mouseMonitor: Any?
    private var resignObservers: [NSObjectProtocol] = []
    private let hud = PrefixHUD()

    /// Ctrl+A 按了之後又切去別的 App、別的視窗、或用滑鼠點了別處：取消等待。不然回來打的第一個字會被當成 prefix 的指令（c 開新 Window、x 跳出關閉確認…）
    private func disarm() {
        guard armed else { return }
        armed = false
        hud.hide()
    }

    init(controller: MainWindowController) {
        self.controller = controller
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let c = self.controller else { return e }
            // F5：全 App 開關浮動終端機，終端機裡按也收得起來（不送進 shell）。瀏覽器格有焦點時 F5 仍是重新載入
            if e.keyCode == 96, e.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
               e.window === c.window || c.floatingTerminal.owns(e.window),
               !(e.window === c.window && Self.browserPane(containing: e.window?.firstResponder) != nil) {
                self.disarm()
                if !e.isARepeat { c.floatingTerminal.toggle() }
                return nil
            }
            // 只攔主視窗與它的浮動面板；用實體鍵碼讓中文輸入法也能按 ⌃ `。
            if e.keyCode == 50, e.modifierFlags.intersection([.command, .control, .option, .shift]) == .control,
               e.window === c.window || c.floatingTerminal.owns(e.window) {
                self.disarm()
                if !e.isARepeat { c.floatingTerminal.toggle() }
                return nil
            }
            guard e.window === c.window else {
                // 獨立視窗：沒有側欄，F3／F4 不用管；F5 在它裡面的瀏覽器格要能重新載入
                if e.keyCode == 96, e.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                   c.detachedWindows.values.contains(where: { $0.window === e.window }),
                   let bp = Self.browserPane(containing: e.window?.firstResponder) { bp.reloadPage(); return nil }
                return e
            }
            return self.handle(e) ? nil : e
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] e in
            self?.disarm()
            return e
        }
        let nc = NotificationCenter.default
        resignObservers = [
            nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.disarm() },
            nc.addObserver(forName: NSWindow.didResignKeyNotification, object: controller.window, queue: .main) { [weak self] _ in self?.disarm() },
        ]
    }
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        resignObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// 焦點在瀏覽器格或程式碼區（Monaco 編輯器、執行畫面）裡：Ghostty 那組 ⌘ 快捷鍵讓給它們
    private func inEditorOrWeb(_ e: NSEvent) -> Bool {
        let r = e.window?.firstResponder
        if Self.browserPane(containing: r) != nil { return true }
        // 從焦點往上找：在任何一格的程式碼區裡都算（不只看紫框那格，點了之後紫框可能還沒跟上）
        var v = r as? NSView
        while let cur = v { if cur is CodeLabView { return true }; v = cur.superview }
        return false
    }

    /// 焦點（第一回應者）在哪個瀏覽器格裡面（網頁本身或它的網址框）；不在任何瀏覽器格回 nil
    static func browserPane(containing r: NSResponder?) -> BrowserPane? {
        var v = r as? NSView
        // 網頁裡的輸入框會讓第一回應者是 WKWebView 底下的子視圖：往上找
        while let cur = v { if let b = cur as? BrowserPane { return b }; v = cur.superview }
        return nil
    }

    private func handle(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .control, .option])
        let ch = e.charactersIgnoringModifiers ?? ""
        let isCtrlA = mods == .control && e.keyCode == 0   // keyCode 0＝A 鍵（不管輸入法）

        // 選取整個 Window 的狀態：除了 F2（改 Window 名字）和 ⌘ 數字（再選別的 Window）之外，任何按鍵（打字）都回到單格
        if !armed, controller?.store.windowSelected == true, e.keyCode != 120, !(mods == .command && Self.digit(e.keyCode) != nil) {
            controller?.store.windowSelected = false
        }
        // F3：開關左側欄（同 ⌘ ⌃ S）；F4：開關右側欄（用量欄＋桌寵格）（F5、F6 改成 F3、F4）。聊天格、終端機格、瀏覽器格都有效，所以不排除終端機（監視器先於終端機看到按鍵）
        // F5：只在嵌入的瀏覽器格（焦點在它的網頁或它裡面）重新載入；聊天格、終端機格不處理、不吃掉（照一般按鍵交出去）。F6 沒有功能
        // CodeLab 的 F9／F10 不受影響：這裡只吃 F3、F4、F5，沒有修飾鍵才算
        if !armed, mods.isEmpty, e.keyCode == 99 { controller?.toggleSidebar(); return true }
        if !armed, mods.isEmpty, e.keyCode == 118 { controller?.toggleRightPanel(); return true }
        if !armed, mods.isEmpty, e.keyCode == 96, let bp = Self.browserPane(containing: e.window?.firstResponder) { bp.reloadPage(); return true }
        // F2：改名。選取整個 Window 時改 Window 的名字，不然改紫框那一格；焦點在終端機（含程式碼執行區）照常交給它
        if !armed, e.keyCode == 120, mods.isEmpty, !Self.inTerminal(e.window) { controller?.f2Rename(); return true }
        // 調大小可以連按：剛按過 Ctrl+A Ctrl+h 的一秒內，直接按 Ctrl+h 也算
        if !armed, mods == .control, Date().timeIntervalSince1970 < repeatUntil, let d = Self.resizeDir(e.keyCode) {
            controller?.store.resize(dx: d.0, dy: d.1)
            repeatUntil = Date().timeIntervalSince1970 + 1
            return true
        }
        // ⇧ Tab：聊天格換權限模式（跟 Claude Code 一樣）。在這裡攔，焦點在對話內容上也能換；終端機格照常送給 claude
        if !armed, e.keyCode == 44, mods.isEmpty, !e.modifierFlags.contains(.shift), controller?.slashFocus() == true { return true }
        if !armed, e.keyCode == 48, mods.isEmpty, e.modifierFlags.contains(.shift), controller?.cycleChatMode() == true { return true }
        // Tab：輸入框沒焦點時也能採用灰字建議（跳回輸入框、把建議變成文字）
        if !armed, e.keyCode == 48, mods.isEmpty, !e.modifierFlags.contains(.shift), controller?.tabSuggestion(from: e.window) == true { return true }
        // ⌃ Enter（馬上插話）／⌃ C（停止並放回剛送的字）：焦點在對話內容上、或不在任何輸入欄位時也能用
        if !armed, mods == .control, e.keyCode == 36 || e.keyCode == 76, controller?.chatCtrlKey(sendNow: true) == true { return true }
        if !armed, mods == .control, e.keyCode == 8, controller?.chatCtrlKey(sendNow: false) == true { return true }
        // ⌃ ⌘ W 關掉整個 Window（對話留在側欄；從 ⌃ W 改過來，終端機格裡也能用）
        if !armed, mods == [.command, .control], e.keyCode == 13 {
            controller?.store.closeWindow()
            return true
        }
        // ⌃ T 開新 Window；焦點在終端機時照樣交給它（shell 的 ⌃ T 對調字元）
        if !armed, mods == .control, e.keyCode == 17, !Self.inTerminal(e.window) {
            controller?.newWindow()
            return true
        }
        // ⌘ W 在主視窗：關掉紫框那一格（對話留在側欄），只剩一格才關整個 Window（終端機不用 ⌘ W，照樣攔）；
        // 設定這類小視窗由選單「關閉這格」那項關（main.swift 的 closeSideWindow）
        if !armed, mods == .command, !e.modifierFlags.contains(.shift), e.keyCode == 13, e.window === controller?.window {      // ⌘ ⇧ W 不算（加了 ⇧ 就不關格）
            controller?.store.closePaneOrWindow()
            return true
        }
        // ⌘ T：開新 Window（跟瀏覽器一樣）
        if !armed, mods == .command, !e.modifierFlags.contains(.shift), e.keyCode == 17 {
            controller?.newWindow()
            return true
        }
        // ⌘ ⇧ T：找回剛關掉的格子或 Window（跟瀏覽器一樣，最近關的先回來）；沒有可找回的就嗶一聲
        if !armed, mods == .command, e.modifierFlags.contains(.shift), e.keyCode == 17 {   // mods 不含 ⇧，另外看
            if controller?.store.reopenClosedWindow() != true { NSSound.beep() }
            return true
        }
        // 學 Ghostty 的分割快捷鍵，功能跟 ⌃ A 那組一樣
        // ⌘ D＝左右分（⌃ A |）、⌘ ⇧ D＝上下分（⌃ A -）、⌘ [ ／ ⌘ ]＝上一格／下一格、⌘ ⇧ Enter＝放大／還原這格（⌃ A z）
        // 焦點在程式碼編輯器或網頁裡時 ⌘ D、⌘ [ ]、⌘ ⇧ Enter 讓給它們（編輯器的「選下一個相同字」、縮排，網頁的上一頁／下一頁）
        if !armed, mods == .command, e.window === controller?.window, let c = controller, !inEditorOrWeb(e),
           (e.window?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true {   // 輸入法還在組字：交給輸入法
            let shift = e.modifierFlags.contains(.shift)
            // 按住不放的重複鍵不算（不然按住 ⌘ D 會一直分割、⌘ ⇧ Enter 會一直閃）
            if e.isARepeat, e.keyCode == 2 || e.keyCode == 36 { return true }
            switch e.keyCode {
            case 2: c.split(vertical: shift); return true                 // D
            case 33 where !shift: c.store.focusCycle(-1); return true    // [
            case 30 where !shift: c.store.focusCycle(1); return true     // ]
            case 36 where shift: c.store.toggleZoom(); return true       // Return
            default: break
            }
        }
        // ⌘ 1～9：跳到第幾個 Window（看實體位置，輸入法開著也行）
        if !armed, mods == .command, !e.modifierFlags.contains(.shift), let d = Self.digit(e.keyCode) { controller?.store.toggleWindowSelection(slot: d - 1); return true }   // ＝選取整個 Window，再按同一個＝回原本那格   // ⌘ ⇧ 數字不算（網頁裡的 ⌘ ⇧ 7／8 要留給網頁）
        if !armed {
            guard isCtrlA else { return false }
            armed = true
            hud.show(in: controller?.window)
            return true
        }
        armed = false
        hud.hide()
        if e.keyCode == 53 { return true }   // Esc：取消
        guard let c = controller else { return true }

        if mods == .control {
            if isCtrlA { c.showCommandMenu(); return true }
            // ⌃ 還沒放開就按方向鍵：一樣切 pane（⌃ h／j／k／l 才是調大小）
            if let d = Self.arrowDir(e.keyCode) { c.moveFocus(dx: d.0, dy: d.1); return true }
            if let d = Self.resizeDir(e.keyCode) {
                c.store.resize(dx: d.0, dy: d.1)
                repeatUntil = Date().timeIntervalSince1970 + 1
            }
            return true
        }
        // 用實體按鍵的位置判斷（keyCode），唯音開著中文時 characters 會是注音
        switch e.keyCode {
        case 4: c.moveFocus(dx: -1, dy: 0)          // h
        case 38: c.moveFocus(dx: 0, dy: 1)          // j
        case 40: c.moveFocus(dx: 0, dy: -1)         // k
        case 37: c.moveFocus(dx: 1, dy: 0)          // l
        case 123, 124, 125, 126:                      // ← → ↓ ↑：跟 h／l／j／k 一樣切 pane
            if let d = Self.arrowDir(e.keyCode) { c.moveFocus(dx: d.0, dy: d.1) }
        case 7: c.confirmClosePane()                  // x
        case 8: c.newWindow()                         // c
        case 45: c.store.selectWindow(offset: 1)      // n
        case 35: c.store.selectWindow(offset: -1)     // p
        case 6: c.store.toggleZoom()                  // z
        case 11: PetSlot.enabled.toggle()             // b：桌寵位置（跟 tmux 的 pet-slot 一樣）
        case 1, 13: c.showTree()                      // s、w
        case 0: c.sendCtrlA()                         // a
        case 43: c.renameWindow()                     // ,
        case 27 where !e.modifierFlags.contains(.shift): c.split(vertical: true)   // -
        default:
            // 要按 Shift 的符號：看打出來的字
            switch ch {
            case "|", "\\": c.split(vertical: false)
            case "&": c.confirmCloseWindow()
            case "$": c.renameSession()
            case "(": c.store.selectSession(offset: -1)
            case ")": c.store.selectSession(offset: 1)
            case "?": c.showCommandMenu()
            default:
                if let n = Int(ch), (1...9).contains(n) { c.store.selectWindow(slot: n - 1) }
                else if let d = Self.digit(e.keyCode) { c.store.selectWindow(slot: d - 1) }
            }
        }
        return true
    }

    /// 焦點在終端機（SwiftTerm 的 TerminalView，包含程式碼執行區）上
    static func inTerminal(_ w: NSWindow?) -> Bool {
        guard let r = w?.firstResponder else { return false }
        return String(describing: type(of: r)).contains("TerminalView")
    }

    /// Ctrl+h/j/k/l 的方向
    /// 方向鍵 ← → ↓ ↑ 的方向（跟 h／l／j／k 同一套：dy 正的是往下）
    static func arrowDir(_ keyCode: UInt16) -> (Int, Int)? {
        [123: (-1, 0), 124: (1, 0), 125: (0, 1), 126: (0, -1)][keyCode]
    }

    static func resizeDir(_ keyCode: UInt16) -> (Int, Int)? {
        switch keyCode {
        case 4: return (-1, 0)
        case 38: return (0, 1)
        case 40: return (0, -1)
        case 37: return (1, 0)
        default: return nil
        }
    }

    /// 數字鍵的實體位置（輸入法開著時 characters 可能不是數字）
    static func digit(_ keyCode: UInt16) -> Int? {
        [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9][keyCode]
    }
}

/// 按下 Ctrl+A 後在視窗中間下方顯示一個小提示，像 tmux 的 prefix 狀態
final class PrefixHUD {
    private var panel: NSPanel?
    func show(in window: NSWindow?) {
        guard let window else { return }
        let label = NSTextField(labelWithString: L("Ctrl+A  （| - 切開、h j k l 換格、c 新 Window、x 關、再按 Ctrl+A 看全部）"))
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        let size = label.intrinsicContentSize
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size.width + 28, height: 30), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.ignoresMouseEvents = true
        let bg = NSView(frame: p.contentView!.bounds)
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        bg.layer?.cornerRadius = 8
        label.frame = NSRect(x: 14, y: (30 - size.height) / 2, width: size.width, height: size.height)
        bg.addSubview(label)
        p.contentView = bg
        let f = window.frame
        p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.minY + 90))
        p.orderFront(nil)
        panel?.orderOut(nil)
        panel = p
    }
    func hide() { panel?.orderOut(nil); panel = nil }
}
