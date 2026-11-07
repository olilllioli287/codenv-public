import AppKit
import SwiftUI

// ⌥ ＋左鍵：在游標位置叫出八宮格環狀選單。
// 先於任何東西看到事件：KeyStatsApp.sendEvent（NSApplication 層）一開始就問 RadialMenu.intercept，所以聊天格的 WebView、
// 終端機格（原本 ⌥ 點是移動游標）、文字框（⌥ 拖是方塊選取）、瀏覽器格、側欄都一樣先顯示八宮格。只按 ⌥（沒有 ⌘ ⌃ ⇧）才算。
// 操作：按住不放、滑到某一格放開＝執行；點一下放開＝選單留著，再點某一格執行；Esc、點中間、點選單外面＝取消。
// 「這一格」＝⌥ 點下去的位置所在的那一格（不是目前紫框那格）。

enum RadialAction: String, CaseIterable {
    case none, collab, settings, newChat, upload, stop, compact, browser, about, handoff, model, schedule, geminiExport, codeLab, leftSidebar, rightSidebar, google, openGemini, openNotebook

    var title: String {
        switch self {
        case .none: return L("空白")
        case .collab: return L("協作面板開關")
        case .settings: return L("設定")
        case .newChat: return L("在這格旁邊開新聊天室")
        case .upload: return L("上傳檔案")
        case .stop: return L("停止 Claude")
        case .compact: return L("壓縮這段對話")
        case .browser: return L("開瀏覽器格")
        case .about: return L("關於這個聊天室")
        case .handoff: return L("交接")
        case .model: return L("換模型")
        case .schedule: return L("排程")
        case .geminiExport: return L("匯出 Gemini 對話")
        case .codeLab: return L("程式碼練習")
        case .leftSidebar: return L("左側欄（F3）")
        case .rightSidebar: return L("右側欄（F4）")
        case .google: return L("開 Google（子選單）")
        case .openGemini: return L("開 Gemini 瀏覽器格")
        case .openNotebook: return L("開 NotebookLM 瀏覽器格")
        }
    }
    /// 圖示下面的短字
    var short: String {
        switch self {
        case .none: return ""
        case .collab: return L("協作")
        case .settings: return L("設定")
        case .newChat: return L("新聊天")
        case .upload: return L("上傳")
        case .stop: return L("停止")
        case .compact: return L("壓縮")
        case .browser: return L("瀏覽器")
        case .about: return L("關於")
        case .handoff: return L("交接")
        case .model: return L("模型")
        case .schedule: return L("排程")
        case .geminiExport: return L("匯出")
        case .codeLab: return L("練習")
        case .leftSidebar: return L("左欄")
        case .rightSidebar: return L("右欄")
        case .google: return L("開 Google")
        case .openGemini: return "Gemini"
        case .openNotebook: return "NotebookLM"
        }
    }
    var symbol: String {
        switch self {
        case .none: return ""
        case .collab: return "person.2"
        case .settings: return "gearshape"
        case .newChat: return "plus.bubble"
        case .upload: return "paperclip"
        case .stop: return "stop.circle"
        case .compact: return "arrow.down.right.and.arrow.up.left"
        case .browser: return "globe"
        case .about: return "info.circle"
        case .handoff: return "arrowshape.turn.up.right"
        case .model: return "cpu"
        case .schedule: return "clock"
        case .geminiExport: return "square.and.arrow.down"
        case .codeLab: return "chevron.left.forwardslash.chevron.right"
        case .leftSidebar: return "sidebar.left"
        case .rightSidebar: return "sidebar.right"
        case .google: return "square.grid.2x2"
        case .openGemini: return "sparkle"
        case .openNotebook: return "book.closed"
        }
    }

    /// 要不要有「這一格」才有用
    var needsPane: Bool {
        switch self {
        case .upload, .stop, .compact, .about, .handoff, .model, .schedule, .geminiExport, .newChat: return true
        default: return false
        }
    }

    /// 舊自訂八宮格照樣保存在 defaults，只在顯示、設定選項與執行時過濾網頁動作。
    var available: Bool {
        switch self {
        case .browser, .geminiExport, .google, .openGemini, .openNotebook: return Prefs.shared.webFeaturesEnabled
        default: return true
        }
    }

    /// 這一格現在能不能用（灰掉的按了沒反應）
    func enabled(for c: Conversation?) -> Bool {
        guard available else { return false }
        if self == .none { return false }
        if !needsPane { return true }
        guard let c else { return false }
        switch self {
        case .geminiExport: return c.isBrowser
        case .newChat: return true
        case .upload, .stop, .about, .handoff, .model, .schedule: return !c.isBrowser && c.terminal != true
        case .compact:
            // 壓縮是 Claude 的 /compact：不是 Claude 的聊天室（agy、Codex、Copilot、本機）不行
            let m = c.model ?? ""
            return !c.isBrowser && c.terminal != true && !["agy:", "codex:", "copilot:", "local:"].contains { m.hasPrefix($0) }
        default: return true
        }
    }

    func run(_ mc: MainWindowController, on id: UUID?) {
        guard available else { return }
        let store = mc.store
        let pane = id.flatMap { mc.workspace.panes[$0] }
        switch self {
        case .none: break
        case .collab: mc.toggleCollabBoard()
        case .settings: mc.openSettings()
        case .newChat:
            guard let id, let c = store.conversation(id) else { return }
            let n = store.newConversation(in: c.projectID)
            store.editWindow { $0.focused = id }
            store.split(vertical: false, with: n.id)
        case .upload: (pane as? ChatPane)?.inputBar.uploadPressed()
        case .stop:
            if let id { store.show(id) }
            (pane as? ChatPane)?.inputBar.interruptAndRestore()
        case .compact: if let id { mc.compact(id) }
        case .browser: mc.newBrowser()
        case .about: if let id { mc.showAbout(id) }
        case .handoff: if let id { mc.handoff(id) }
        case .model: if let c = pane as? ChatPane { c.inputBar.onModelButton?(c.inputBar.modelButton) }
        case .schedule: if let id { mc.showSchedule(id) }
        case .geminiExport: (pane as? BrowserPane)?.exportChat()
        case .codeLab: mc.newCodeLabConversation()
        case .leftSidebar: mc.toggleSidebar()
        case .rightSidebar: mc.toggleRightPanel()
        case .google: break      // 子選單：由 RadialMenu.finish 處理（換成第二層八宮格），不走這裡
        case .openGemini, .openNotebook:
            // 在 ⌥ 點的那一格右邊切出瀏覽器格；點的位置不在任何格子上就在目前那格右邊
            let kind: GadgetKind = self == .openGemini ? .gemini : .notebooklm
            // 在瀏覽器格（含掛件格）上點：不另外開新格，這一格原地換網站，接續那個網站最後的網址
            if let id, let c = store.conversation(id), c.isBrowser {
                if let u = store.switchBrowserSite(id, to: kind) { (pane as? BrowserPane)?.load(u) }
                if let p = pane as? BrowserPane { p.window?.makeFirstResponder(p.webView) }
                return
            }
            let url = kind.home
            guard let pid = id.flatMap({ store.conversation($0)?.projectID }) ?? store.currentWindow?.focused.flatMap({ store.conversation($0)?.projectID }) ?? store.projects.first?.id else { return }
            let c = store.createBrowser(in: pid, url: url)
            if let id { store.editWindow { $0.focused = id } }
            if store.currentWindow?.focused != nil { store.split(vertical: false, with: c.id) } else { store.show(c.id) }
            store.selected = c.id
        }
    }
}

/// 八格的設定：存在 appDefaults（radialSlots，8 個動作名字）。順序＝從正上方開始順時針：上、右上、右、右下、下、左下、左、左上
enum RadialSlots {
    static let names = [L("上"), L("右上"), L("右"), L("右下"), L("下"), L("左下"), L("左"), L("左上")]
    /// 預設：右＝協作面板、右下＝設定、左＝壓縮、左下＝交接（⌥ 點的那一格）、右上＝開 Google 子選單，其他空白
    static let defaults: [RadialAction] = [.none, .google, .collab, .settings, .none, .handoff, .compact, .none]
    static var current: [RadialAction] {
        get {
            let raw = appDefaults.stringArray(forKey: "radialSlots") ?? []
            guard raw.count == 8 else { return defaults }
            return raw.map { RadialAction(rawValue: $0) ?? .none }
        }
        set { appDefaults.set(newValue.map(\.rawValue), forKey: "radialSlots") }
    }
    static func reset() { appDefaults.removeObject(forKey: "radialSlots") }
    static var visible: [RadialAction] { current.map { $0.available ? $0 : .none } }
    /// 第二層（右上「開 Google」）：這版固定兩格，左＝Gemini、右＝NotebookLM，不能自訂
    static let google: [RadialAction] = [.none, .none, .openNotebook, .none, .none, .none, .openGemini, .none]
}

final class RadialMenu {
    static let shared = RadialMenu()
    weak var controller: MainWindowController?
    private var panel: NSPanel?
    private var view: RadialView?
    private(set) var isOpen = false
    private var origin = NSPoint.zero            // 按下去的位置（螢幕座標）
    private var moved = false
    private var target: UUID?                    // ⌥ 點下去的位置所在的那一格
    private var observers: [NSObjectProtocol] = []
    /// 目前是第幾層（1＝一般八宮格，2＝右上「開 Google」換出來的）；換層動畫進行中 transitioning＝true（期間吃掉滑鼠事件）
    private(set) var level = 1
    private(set) var transitioning = false
    private var generation = 0                    // 關掉或重開之後，舊動畫的收尾不能再動新的選單
    private var idleTimer: Timer?
    private static let idleLimit: TimeInterval = 30   // 選單留著沒人操作超過這麼久就自動收掉
    static let size: CGFloat = 330

    /// 在 NSApplication.sendEvent 最前面問：true＝這個事件吃掉了
    func intercept(_ e: NSEvent) -> Bool {
        if isOpen {
            if e.type != .mouseMoved { resetIdle() }
            if transitioning {
                if e.type == .keyDown, e.keyCode == 53 { close() }
                return e.type != .mouseMoved
            }
            switch e.type {
            case .leftMouseDragged:
                if hypot(NSEvent.mouseLocation.x - origin.x, NSEvent.mouseLocation.y - origin.y) > 6 { moved = true }
                updateHighlight(); return true
            case .mouseMoved, .otherMouseDragged: updateHighlight(); return e.type == .otherMouseDragged
            case .leftMouseUp:
                if moved { finish(execute: true) }      // 拖過去再放開：執行那一格（在中間／空白／灰格就是取消）
                return true                              // 沒拖＝點一下放開：選單留著
            case .leftMouseDown:
                updateHighlight()
                finish(execute: true)                    // 選單留著時再點：點到某一格就執行，點中間或外面取消
                return true
            case .rightMouseDown, .otherMouseDown: close(); return true
            case .keyDown:
                if e.keyCode == 53 { close(); return true }
                // ⌘ 開頭的組合鍵（⌘ Q、⌘ Tab…）：先收掉選單再交給系統，不要被吃掉
                if e.modifierFlags.contains(.command) { close(); return false }
                return true
            default: return false
            }
        }
        guard e.type == .leftMouseDown, e.modifierFlags.intersection([.command, .control, .option, .shift]) == .option else { return false }
        open(at: NSEvent.mouseLocation, event: e)
        return true
    }

    // MARK: 開、關

    func open(at p: NSPoint, event: NSEvent?) {
        close()
        target = event.flatMap { paneAt($0) }
        origin = p
        moved = false
        let s = Self.size
        var f = NSRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
        if let scr = NSScreen.screens.first(where: { $0.frame.contains(p) }) ?? NSScreen.main {
            // 靠近螢幕邊緣往內移（選單要完整在螢幕裡）
            let v = scr.visibleFrame
            f.origin.x = max(v.minX, min(f.origin.x, v.maxX - s))
            f.origin.y = max(v.minY, min(f.origin.y, v.maxY - s))
        }
        let panel = NSPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false
        let conv = target.flatMap { controller?.store.conversation($0) }
        let v = RadialView(frame: NSRect(x: 0, y: 0, width: s, height: s))
        v.slots = RadialSlots.visible
        v.enabled = v.slots.map { $0.enabled(for: conv) }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: s, height: s))
        host.wantsLayer = true
        host.addSubview(v)
        panel.contentView = host
        panel.orderFrontRegardless()
        self.panel = panel; view = v
        level = 1; transitioning = false; generation += 1
        isOpen = true
        updateHighlight()
        // 切到別的 App、選單所在的視窗失去焦點、放著不管：自動收掉，不然選單開著會吃掉所有按鍵
        let nc = NotificationCenter.default
        observers = [nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.close() }]
        observers.append(nc.addObserver(forName: Prefs.webFeaturesChanged, object: nil, queue: .main) { [weak self] _ in self?.close() })
        if let w = event?.window {
            observers.append(nc.addObserver(forName: NSWindow.didResignKeyNotification, object: w, queue: .main) { [weak self] _ in self?.close() })
        }
        resetIdle()
    }

    private func resetIdle() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleLimit, repeats: false) { [weak self] _ in self?.close() }
    }

    func close() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        idleTimer?.invalidate(); idleTimer = nil
        panel?.orderOut(nil)
        panel = nil; view = nil
        isOpen = false
        level = 1; transitioning = false; generation += 1
        target = nil
    }

    /// 現在游標在哪一格（nil＝中間或外面）
    private func updateHighlight() {
        guard let panel, let view else { return }
        let c = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        view.highlight = Self.sector(of: NSEvent.mouseLocation, center: c)
        view.centerHot = hypot(NSEvent.mouseLocation.x - c.x, NSEvent.mouseLocation.y - c.y) < RadialView.inner
    }

    /// 方位 → 第幾格（0＝正上方，順時針）；在中間圓裡回 nil。離太遠也算（拖過去放開比較好選）
    static func sector(of p: NSPoint, center c: NSPoint) -> Int? {
        let dx = p.x - c.x, dy = p.y - c.y
        if hypot(dx, dy) < RadialView.inner { return nil }
        var deg = 90 - atan2(dy, dx) * 180 / .pi          // 0＝上，順時針
        deg = deg.truncatingRemainder(dividingBy: 360); if deg < 0 { deg += 360 }
        return Int(((deg + 22.5).truncatingRemainder(dividingBy: 360)) / 45)
    }

    /// 放開／點下去：照目前亮的那一格決定
    private func finish(execute: Bool) {
        guard let view, let panel else { return close() }
        let c = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let mouse = NSEvent.mouseLocation
        let far = hypot(mouse.x - c.x, mouse.y - c.y) > RadialView.outer + 40    // 點在選單外面很遠：取消
        let idx = far ? nil : view.highlight
        let id = target
        let action = idx.map { view.slots[$0] }
        let ok = idx.map { view.enabled[$0] } ?? false
        if execute, ok, action == .google, level == 1 { openSubmenu(); return }
        close()
        if execute, ok, let action, let mc = controller { action.run(mc, on: id) }
    }

    /// 右上「開 Google」：第一層縮小淡出（約 0.12 秒），同一個位置換成第二層淡入放大。「減少動態效果」只做淡入淡出
    private func openSubmenu() {
        guard Prefs.shared.webFeaturesEnabled, let panel, let old = view, let host = panel.contentView, !transitioning else { return }
        transitioning = true
        generation += 1
        let gen = generation
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let small: CGFloat = reduce ? 1 : 0.8
        let nv = RadialView(frame: old.frame)
        nv.slots = RadialSlots.google
        nv.enabled = nv.slots.map { $0.enabled(for: target.flatMap { controller?.store.conversation($0) }) }
        nv.wantsLayer = true
        host.addSubview(nv)
        for v in [old, nv] { v.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5); v.layer?.position = CGPoint(x: v.frame.midX, y: v.frame.midY) }
        nv.layer?.opacity = 0
        Self.animate(old, from: (1, 1), to: (0, small), duration: 0.12) { [weak self] in
            guard let self, self.generation == gen, self.isOpen else { return }
            old.removeFromSuperview()
            self.view = nv; self.level = 2
            self.origin = NSEvent.mouseLocation; self.moved = false
            self.updateHighlight()
            Self.animate(nv, from: (0, small), to: (1, 1), duration: 0.14) { [weak self] in
                guard let self, self.generation == gen else { return }
                self.transitioning = false
                self.updateHighlight()
            }
        }
    }
    private static func animate(_ v: NSView, from: (alpha: Float, scale: CGFloat), to: (alpha: Float, scale: CGFloat), duration: CFTimeInterval, done: @escaping () -> Void) {
        guard let l = v.layer else { return done() }
        CATransaction.begin()
        CATransaction.setCompletionBlock(done)
        let t = CABasicAnimation(keyPath: "transform")
        t.fromValue = CATransform3DMakeScale(from.scale, from.scale, 1); t.toValue = CATransform3DMakeScale(to.scale, to.scale, 1)
        let o = CABasicAnimation(keyPath: "opacity")
        o.fromValue = from.alpha; o.toValue = to.alpha
        for a in [t, o] { a.duration = duration; a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut) }
        l.transform = CATransform3DMakeScale(to.scale, to.scale, 1); l.opacity = to.alpha
        l.add(t, forKey: "t"); l.add(o, forKey: "o")
        CATransaction.commit()
    }

    private func paneAt(_ e: NSEvent) -> UUID? {
        guard let mc = controller, let w = e.window else { return nil }
        if w === mc.window { return mc.host.conversation(atWindowPoint: e.locationInWindow) }
        return mc.detachedWindows.values.first { $0.window === w }?.host.conversation(atWindowPoint: e.locationInWindow)
    }

    // MARK: 測試用（--radial、--radial-pick）

    func testShow(at p: NSPoint, target id: UUID?) {
        open(at: p, event: nil)
        self.target = id
        let conv = id.flatMap { controller?.store.conversation($0) }
        view?.enabled = (view?.slots ?? []).map { $0.enabled(for: conv) }
    }
    func testPick(_ n: Int) {
        guard let view, view.slots.indices.contains(n), !transitioning else { return }
        let id = target, action = view.slots[n], ok = view.enabled[n]
        if ok, action == .google, level == 1 { openSubmenu(); return }
        close()
        if ok, let mc = controller { action.run(mc, on: id) }
    }
    /// 取樣：第幾層、換層中嗎、每個子視圖的 frame 和（動畫中的）alpha／縮放
    func testState() -> String {
        let subs = (panel?.contentView?.subviews ?? []).map { v -> String in
            let l = v.layer?.presentation() ?? v.layer
            return "[a=\(String(format: "%.2f", l?.opacity ?? -1)) s=\(String(format: "%.2f", l?.transform.m11 ?? -1)) frame=\(Int(v.frame.width))x\(Int(v.frame.height)) slots=\((v as? RadialView)?.slots.map(\.rawValue).joined(separator: ",") ?? "")]"
        }
        return "open=\(isOpen) level=\(level) transitioning=\(transitioning) " + subs.joined(separator: " ")
    }
    func testImage() -> NSImage? {
        guard let v = view, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        let img = NSImage(size: v.bounds.size); img.addRepresentation(rep); return img
    }
}

final class RadialView: NSView {
    static let inner: CGFloat = 38, outer: CGFloat = 148
    var slots: [RadialAction] = []
    var enabled: [Bool] = []
    var highlight: Int? { didSet { if highlight != oldValue { needsDisplay = true } } }
    var centerHot = false { didSet { if centerHot != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { false }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let accent = NSColor.controlAccentColor
        let gap: CGFloat = 1.6
        for i in 0..<8 {
            let mid = 90 - 45 * CGFloat(i)                       // 這格的中心方位（度，數學座標）
            let a0 = mid - 22.5 + gap, a1 = mid + 22.5 - gap
            let path = NSBezierPath()
            path.appendArc(withCenter: c, radius: Self.outer, startAngle: a0, endAngle: a1)
            path.appendArc(withCenter: c, radius: Self.inner + 6, startAngle: a1, endAngle: a0, clockwise: true)
            path.close()
            let action = i < slots.count ? slots[i] : .none
            let on = i < enabled.count && enabled[i]
            let hot = highlight == i
            if hot && on { accent.withAlphaComponent(0.92).setFill() }
            else if action == .none { NSColor(white: 1, alpha: 0.09).setFill() }
            else { NSColor(white: 0.08, alpha: 0.86).setFill() }
            path.fill()
            NSColor(white: 1, alpha: action == .none ? 0.22 : 0.18).setStroke()
            path.lineWidth = 1
            path.stroke()
            guard action != .none else { continue }
            // 圖示＋短字
            let r = (Self.inner + 6 + Self.outer) / 2
            let rad = mid * .pi / 180
            let center = NSPoint(x: c.x + cos(rad) * r, y: c.y + sin(rad) * r)
            let tint = on ? NSColor.white : NSColor(white: 1, alpha: 0.28)
            if let img = NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.title)?.withSymbolConfiguration(.init(pointSize: 22, weight: .regular)) {
                let t = img.tinted(tint)
                t.draw(in: NSRect(x: center.x - t.size.width / 2, y: center.y - t.size.height / 2 + 7, width: t.size.width, height: t.size.height))
            }
            let label = NSAttributedString(string: action.short, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: tint])
            let ls = label.size()
            label.draw(at: NSPoint(x: center.x - ls.width / 2, y: center.y - 24))
        }
        // 中間：取消
        let circle = NSBezierPath(ovalIn: NSRect(x: c.x - Self.inner, y: c.y - Self.inner, width: Self.inner * 2, height: Self.inner * 2))
        NSColor(white: centerHot ? 0.3 : 0.08, alpha: 0.9).setFill()
        circle.fill()
        NSColor(white: 1, alpha: 0.2).setStroke(); circle.stroke()
        let t = NSAttributedString(string: L("取消"), attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor(white: 1, alpha: 0.75)])
        let ts = t.size()
        t.draw(at: NSPoint(x: c.x - ts.width / 2, y: c.y - ts.height / 2))
    }
}

private extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        draw(in: NSRect(origin: .zero, size: size))
        color.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        img.unlockFocus()
        return img
    }
}

// MARK: 設定頁

struct RadialPage: View {
    @ObservedObject private var prefs = Prefs.shared
    @State private var slots = RadialSlots.current
    var body: some View {
        Form {
            Text(L("按住 ⌥ 再按滑鼠左鍵，在游標位置叫出八宮格。按住不放滑到某一格再放開＝執行；點一下放開，選單會留著，再點某一格執行；Esc、點中間或點外面＝取消。「這一格」是 ⌥ 點下去的位置所在的那一格。"))
                .font(.callout).foregroundStyle(.secondary)
            ForEach(0..<8, id: \.self) { i in
                Picker(RadialSlots.names[i], selection: Binding(get: { slots[i].available ? slots[i] : .none }, set: { slots[i] = $0; RadialSlots.current = slots })) {
                    ForEach(RadialAction.allCases.filter { $0 != .openGemini && $0 != .openNotebook && (prefs.webFeaturesEnabled || $0.available) }, id: \.self) { a in
                        if a == .none { Text(a.title).tag(a) } else { Label(a.title, systemImage: a.symbol).tag(a) }
                    }
                }
            }
            Button(L("還原預設")) { RadialSlots.reset(); slots = RadialSlots.current }
        }
        .formStyle(.grouped)
        .padding()
    }
}
