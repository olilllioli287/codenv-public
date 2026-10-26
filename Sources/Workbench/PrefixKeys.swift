import AppKit

// Ctrl+A 開頭的按鍵，照使用者的 ~/.tmux.conf（prefix 是 Ctrl+A）：
//   |  往右切   -  往下切   h j k l  換格   Ctrl+h/j/k/l  調大小（一秒內可以連按，不用再按 Ctrl+A）
//   x  關這格（Enter 確定）   &  關整個 Window（Enter 確定）   ,  Window 改名   $  Session 改名
//   c  新 Window   n / p  下一個／上一個 Window   1～9  第幾個 Window   z  放大這格
//   s / w  列出 Session 和 Window 來選   ( / )  上一個／下一個 Session
//   b  右下角開／關桌寵的位置
// 不用 Ctrl+A 的：⌃ W 關 Window（對話留在側欄）、⌃ T 新 Window（終端機格裡照樣交給終端機）、⌘ 1～9 跳到第幾個 Window
//   a  把 Ctrl+A 本身送出（輸入框跳到行首）   Ctrl+A  中文指令選單   ?  也是選單
// 原生 App 收按鍵早於輸入法，所以唯音開著中文也不用先切英文（tmux 那邊要靠 ~/.codenv-ime）。

final class PrefixKeys {
    weak var controller: MainWindowController?
    private var armed = false
    private var repeatUntil: TimeInterval = 0
    private var monitor: Any?
    private let hud = PrefixHUD()

    init(controller: MainWindowController) {
        self.controller = controller
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let c = self.controller, e.window === c.window else { return e }
            return self.handle(e) ? nil : e
        }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    private func handle(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .control, .option])
        let ch = e.charactersIgnoringModifiers ?? ""
        let isCtrlA = mods == .control && e.keyCode == 0   // keyCode 0＝A 鍵（不管輸入法）

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
        // ⌃ W 關掉這個 Window（對話留在側欄）、⌃ T 開新 Window；焦點在終端機時照樣交給它（shell 的 ⌃ W 刪字、⌃ T 對調字元）
        if !armed, mods == .control, e.keyCode == 13 || e.keyCode == 17, !Self.inTerminal(e.window) {
            if e.keyCode == 13 { controller?.store.closeWindow() } else { controller?.newWindow() }
            return true
        }
        // ⌘ W 在主視窗：關掉紫框那一格（對話留在側欄），只剩一格才關整個 Window（終端機不用 ⌘ W，照樣攔）；
        // 設定這類小視窗由選單「關閉這格」那項關（main.swift 的 closeSideWindow）
        if !armed, mods == .command, e.keyCode == 13, e.window === controller?.window {
            controller?.store.closePaneOrWindow()
            return true
        }
        // ⌘ T：開新 Window（跟瀏覽器一樣；使用者 10/24 要的）
        if !armed, mods == .command, !e.modifierFlags.contains(.shift), e.keyCode == 17 {
            controller?.newWindow()
            return true
        }
        // ⌘ ⇧ T：找回剛關掉的格子或 Window（跟瀏覽器一樣，最近關的先回來）；沒有可找回的就嗶一聲
        if !armed, mods == .command, e.modifierFlags.contains(.shift), e.keyCode == 17 {   // mods 不含 ⇧，另外看
            if controller?.store.reopenClosedWindow() != true { NSSound.beep() }
            return true
        }
        // ⌘ 1～9：跳到第幾個 Window（看實體位置，輸入法開著也行）
        if !armed, mods == .command, let d = Self.digit(e.keyCode) { controller?.store.selectWindow(at: d - 1); return true }
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
            if let d = Self.arrowDir(e.keyCode) { c.store.focus(dx: d.0, dy: d.1); return true }
            if let d = Self.resizeDir(e.keyCode) {
                c.store.resize(dx: d.0, dy: d.1)
                repeatUntil = Date().timeIntervalSince1970 + 1
            }
            return true
        }
        // 用實體按鍵的位置判斷（keyCode），唯音開著中文時 characters 會是注音
        switch e.keyCode {
        case 4: c.store.focus(dx: -1, dy: 0)          // h
        case 38: c.store.focus(dx: 0, dy: 1)          // j
        case 40: c.store.focus(dx: 0, dy: -1)         // k
        case 37: c.store.focus(dx: 1, dy: 0)          // l
        case 123, 124, 125, 126:                      // ← → ↓ ↑：跟 h／l／j／k 一樣切 pane
            if let d = Self.arrowDir(e.keyCode) { c.store.focus(dx: d.0, dy: d.1) }
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
                if let n = Int(ch), (1...9).contains(n) { c.store.selectWindow(at: n - 1) }
                else if let d = Self.digit(e.keyCode) { c.store.selectWindow(at: d - 1) }
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
        let label = NSTextField(labelWithString: "Ctrl+A  （| - 切開、h j k l 換格、c 新 Window、x 關、再按 Ctrl+A 看全部）")
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
