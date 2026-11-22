import AppKit

/// 測試用：--test-screen <螢幕名稱子字串>（例：ipad）。只在測試實例（有 --state-dir 或 --background）生效，
/// 主視窗和分離視窗都擺進那台螢幕的 visibleFrame（太大就照比例縮）。找不到那台螢幕就照舊。不 activate、不 makeKey。
enum TestScreen {
    static let diagnosticProbeWindowIdentifier = NSUserInterfaceItemIdentifier("codenv.test.diag-probe")

    private static func isDiagnosticProbeWindow(_ window: NSWindow) -> Bool {
        window.identifier == diagnosticProbeWindowIdentifier
    }

    static var screen: NSScreen? {
        let a = CommandLine.arguments
        guard a.contains("--state-dir") || a.contains("--background"),
              let i = a.firstIndex(of: "--test-screen"), i + 1 < a.count else { return nil }
        let key = normalized(a[i + 1])
        guard !key.isEmpty else { return nil }
        return NSScreen.screens.first { normalized($0.localizedName).contains(key) }
    }

    /// Screen names vary by punctuation and Unicode dash style across macOS/display drivers.
    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    /// --test-hidden：測試實例找不到指定的螢幕（例如只有內建螢幕、沒接 iPad）時，主視窗不排到螢幕上，不擋住使用者正在用的螢幕（考卷 C121）
    static var hiddenRequested: Bool {
        let a = CommandLine.arguments
        return a.contains("--test-hidden") && (a.contains("--state-dir") || a.contains("--background"))
    }

    /// 找不到指定螢幕時：透明、滑鼠穿透，再推到畫面外。不能 orderOut：主視窗一收起來，app 會在 0.2 秒內結束（實測，事件紀錄「結束」）。
    /// AppKit 不讓視窗整個移出螢幕（實測 (-20000, -20000) 會被拉成 (-1240, -772)，留 40×28 點），所以只能靠透明：看不到、點不到。截圖用 cacheDisplay，不受透明度影響。
    static func concealIfNoScreen(_ w: NSWindow) {
        guard !isDiagnosticProbeWindow(w), screen == nil, hiddenRequested else { return }
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        w.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    }

    // MARK: 顯示前就在測試螢幕上（考卷 C140）

    /// 測試實例指定螢幕時，或要求無螢幕就隱藏時才會裝（正式版不帶這些旗標，不走這裡）。
    /// 主視窗、分離視窗之外的視窗（設定、說明、用量、NSAlert、各種面板、浮動終端機…）位置都是各自算的（例如 center() 會落在主螢幕），
    /// 所以攔下 NSWindow 所有「顯示」的入口：顯示之前若視窗和別的螢幕有重疊，先搬進測試螢幕再顯示。
    /// 另外每 50 毫秒掃一次所有可見視窗當保險（攔不到的路徑、顯示後才被改位置的）。
    private static var guardInstalled = false
    private static var sweeper: Timer?

    static func installGuard() {
        guard !guardInstalled, screen != nil || hiddenRequested else { return }
        guardInstalled = true
        for (orig, new) in [("orderWindow:relativeTo:", "tsw_orderWindow:relativeTo:"), ("orderFront:", "tsw_orderFront:"),
                            ("orderFrontRegardless", "tsw_orderFrontRegardless"), ("orderBack:", "tsw_orderBack:"),
                            ("makeKeyAndOrderFront:", "tsw_makeKeyAndOrderFront:"), ("setIsVisible:", "tsw_setIsVisible:")] {
            swizzle(NSWindow.self, orig, new)
        }
        swizzle(NSApplication.self, "runModalForWindow:", "tsw_runModalForWindow:")
        swizzle(NSAlert.self, "runModal", "tsw_runModal")
        let t = Timer(timeInterval: 0.05, repeats: true) { _ in
            for w in NSApp.windows where w.isVisible { pull(w) }
        }
        RunLoop.main.add(t, forMode: .common)      // .common 包含跳出對話框（modal）和拖曳時的 run loop
        sweeper = t
    }

    private static func swizzle(_ cls: AnyClass, _ original: String, _ replacement: String) {
        guard let a = class_getInstanceMethod(cls, Selector(original)), let b = class_getInstanceMethod(cls, Selector(replacement)) else { return }
        method_exchangeImplementations(a, b)
    }

    /// 指定螢幕不存在且要求隱藏時，顯示前先隱藏；否則與測試螢幕外的螢幕重疊就先搬進測試螢幕。
    /// 子視窗與 sheet 跟著父視窗，不另搬動。
    static func pull(_ w: NSWindow) {
        guard !isDiagnosticProbeWindow(w) else { return }
        guard w.parent == nil, w.sheetParent == nil else { return }
        guard let test = screen else { concealIfNoScreen(w); return }
        let f = w.frame
        guard f.width > 1, f.height > 1 else { return }
        guard NSScreen.screens.contains(where: { $0.frame != test.frame && $0.frame.intersects(f) }) else { return }
        fit(w)
    }

    static func fit(_ w: NSWindow) {
        guard let s = screen else { return }
        let vf = s.visibleFrame
        var f = w.frame
        guard f.width > 0, f.height > 0 else { return }
        let k = min(1, vf.width / f.width, vf.height / f.height)
        f.size = NSSize(width: (f.width * k).rounded(.down), height: (f.height * k).rounded(.down))
        f.origin = NSPoint(x: (vf.midX - f.width / 2).rounded(), y: (vf.midY - f.height / 2).rounded())
        w.setFrame(f, display: false)
    }
}

/// TestScreen.installGuard 換進去的版本（方法名稱靠 method_exchangeImplementations 互換：呼叫 tsw_ 開頭的就是原本的實作）。
extension NSWindow {
    @objc(tsw_orderWindow:relativeTo:) func tsw_order(_ place: NSWindow.OrderingMode, relativeTo other: Int) {
        if place != .out { TestScreen.pull(self) }
        tsw_order(place, relativeTo: other)
    }
    @objc(tsw_orderFront:) func tsw_orderFront(_ sender: Any?) { TestScreen.pull(self); tsw_orderFront(sender) }
    @objc(tsw_orderFrontRegardless) func tsw_orderFrontRegardless() { TestScreen.pull(self); tsw_orderFrontRegardless() }
    @objc(tsw_orderBack:) func tsw_orderBack(_ sender: Any?) { TestScreen.pull(self); tsw_orderBack(sender) }
    @objc(tsw_makeKeyAndOrderFront:) func tsw_makeKeyAndOrderFront(_ sender: Any?) { TestScreen.pull(self); tsw_makeKeyAndOrderFront(sender) }
    @objc(tsw_setIsVisible:) func tsw_setIsVisible(_ flag: Bool) { if flag { TestScreen.pull(self) }; tsw_setIsVisible(flag) }
}

extension NSApplication {
    @objc(tsw_runModalForWindow:) func tsw_runModal(for window: NSWindow) -> NSApplication.ModalResponse {
        TestScreen.pull(window)
        return tsw_runModal(for: window)
    }
}

extension NSAlert {
    /// NSAlert 的視窗在 runModal 裡才排版、置中（落在主螢幕）：先取 window 讓它排好，搬走，再跑。
    @objc(tsw_runModal) func tsw_runModal() -> NSApplication.ModalResponse {
        TestScreen.pull(window)
        return tsw_runModal()
    }
}
