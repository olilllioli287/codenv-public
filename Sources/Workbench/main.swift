import AppKit
import SwiftUI
import SwiftTerm
import WebKit

// AI 工作台：自己的 AI 工作環境。左邊照 Codex 的側欄（專案→對話），右邊每個對話一格跑 Claude Code 的終端機。
// 不用 tmux：關掉 App 再開，用 Claude 的 --resume 接回同一段對話。
// 測試用參數：--dump-theme（印出從 iTerm 讀到的字型配色）、--state-dir <資料夾>（資料存到別的地方，不碰平常用的）、
//   --background（開起來不搶焦點）、--send "秒數:文字"（幾秒後把文字送進目前那格，可以給好幾個；\r 代表 Enter）
final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: Store!
    var workspace: Workspace!
    var main: MainWindowController!
    var settings: SettingsWindowController?
    var importer: ImportWindowController?
    var organizer: OrganizerWindowController?
    private var autoImportTimer: Timer?
    let appearance = AppearanceSettings()

    func applicationDidFinishLaunching(_ n: Notification) {
        // 寫給已經結束的 claude 不要整個 App 被 SIGPIPE 殺掉（寫入錯誤在 ChatSession 自己處理）
        signal(SIGPIPE, SIG_IGN)
        let args = CommandLine.arguments
        // 拖進來的暫存圖片，超過一天的清掉
        if let old = try? FileManager.default.contentsOfDirectory(at: TerminalPane.dropFolder, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for f in old where ((try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < Date().addingTimeInterval(-86400) {
                try? FileManager.default.removeItem(at: f)
            }
        }
        if args.contains("--dump-theme") {
            let t = Theme.fromITerm()
            print("字型", t.font.fontName, t.font.pointSize, "粗體", t.boldFont.fontName, "行距", t.lineSpacing)
            print("深色 背景", t.dark.bg, "文字", t.dark.fg)
            print("淺色 背景", t.light.bg, "文字", t.light.fg)
            exit(0)
        }
        if let i = args.firstIndex(of: "--state-dir"), i + 1 < args.count {
            store = Store(directory: URL(fileURLWithPath: args[i + 1], isDirectory: true))
        } else {
            store = Store()
        }
        // 按鍵統計（KeyStats.swift）：讀進舊的統計，之後按鍵才開始記（存在 state 資料夾）
        KeyStats.shared.start(in: store.directory)
        workspace = Workspace(store: store, theme: appearance.theme)
        if let i = args.firstIndex(of: "--claude"), i + 1 < args.count { workspace.claudeCommand = args[i + 1] }
        // --chat-args "參數 參數"：測試時多給 claude 的參數（例如 --permission-mode default，逼它來問權限）
        if let i = args.firstIndex(of: "--chat-args"), i + 1 < args.count {
            ChatSession.extraArgs = args[i + 1].split(separator: " ").map(String.init)
        }
        if let i = args.firstIndex(of: "--chat-log"), i + 1 < args.count {
            FileManager.default.createFile(atPath: args[i + 1], contents: nil)
            ChatSession.log = FileHandle(forWritingAtPath: args[i + 1])
        }
        appearance.onChange = { [weak self] in
            guard let self else { return }
            self.workspace.applyTheme(self.appearance.theme)
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
        main.openSettings = { [weak self] in self?.showSettings() }
        buildMenu()
        Prefs.shared.applyAppearance()
        UpdateCheck.shared.start(directory: store.directory)
        I18n.startDumpIfAsked()
        if args.contains("--state-dir"), let i = args.firstIndex(of: "--feedback-dump"), i + 1 < args.count {
            let log = args.firstIndex(of: "--feedback-log").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            Feedback.dump(to: args[i + 1], logFile: log)
        }
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
        scheduleTestInput(args)
    }

    private func scheduleTestInput(_ args: [String]) {
        // --return "秒數"：幾秒後模擬按一下鍵盤的 Return（走跟真的按鍵一樣的路）
        for (i, a) in args.enumerated() where a == "--return" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? TerminalPane,
                      let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: self.main.window?.windowNumber ?? 0, context: nil,
                                               characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else { return }
                p.terminal.keyDown(with: e)
            }
        }
        // --drop "秒數:路徑"：幾秒後模擬把這個檔案拖進目前那格
        for (i, a) in args.enumerated() where a == "--drop" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let url = URL(fileURLWithPath: String(parts[1]))
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? TerminalPane else { return }
                p.pastePaths([url])
            }
        }
        // --front "秒數:持續秒數"：幾秒後把視窗短暫放到最前面（不搶焦點），給外面的截圖工具拍，時間到退回後面
        for (i, a) in args.enumerated() where a == "--front" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":").compactMap { Double($0) }
            guard parts.count == 2 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + parts[0]) { [weak self] in
                guard let w = self?.main.window else { return }
                w.orderFrontRegardless()
                DispatchQueue.main.asyncAfter(deadline: .now() + parts[1]) { w.orderBack(nil) }
            }
        }
        // --focus-settings "秒數"：打開設定視窗、把 App 叫到前面讓設定變成作用中的視窗（測 ⌘ W 關小視窗；會搶鍵盤焦點）
        for (i, a) in args.enumerated() where a == "--focus-settings" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                self?.showSettings()
                NSApp.activate(ignoringOtherApps: true)
                self?.settings?.window?.makeKeyAndOrderFront(nil)
            }
        }
        // --key-keys "秒數:按鍵 …"：跟 --keys 一樣，但送到當下作用中的視窗（例如設定視窗）
        for (i, a) in args.enumerated() where a == "--key-keys" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let tokens = parts[1].split(separator: " ").map(String.init)
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                guard let w = NSApp.keyWindow else { return }
                for (n, t) in tokens.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(n) * 0.15) { Self.postKey(t, window: w) }
                }
            }
        }
        // --spring "秒數:第幾個分頁（從 0 數）:停幾秒"：像拖著檔案停在那個分頁上，時間到移開（測 1.5 秒切 Window）
        for (i, a) in args.enumerated() where a == "--spring" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":").compactMap { Double($0) }
            guard parts.count == 3 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + parts[0]) { [weak self] in
                self?.main.host.tabBar.springHover(tab: Int(parts[1]))
                DispatchQueue.main.asyncAfter(deadline: .now() + parts[2]) { self?.main.host.tabBar.springHover(tab: nil) }
            }
        }
        // --show "秒數:第幾段對話"：像在側欄點一下那段對話
        for (i, a) in args.enumerated() where a == "--show" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":").compactMap { Double($0) }
            guard parts.count == 2 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + parts[0]) { [weak self] in
                guard let self, Int(parts[1]) < self.store.conversations.count else { return }
                self.store.show(self.store.conversations[Int(parts[1])].id)
            }
        }
        // --new-codelab "秒數"：像按側欄程式碼學習專區的「新的練習」
        for (i, a) in args.enumerated() where a == "--new-codelab" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.main.newCodeLabConversation() }
        }
        // --tab-rects "秒數:檔案"：每個分頁在螢幕上的位置（x y w h，螢幕座標、左下原點）
        for (i, a) in args.enumerated() where a == "--tab-rects" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                let s = self.main.host.tabBar.tabScreenRects().map { "\($0.minX) \($0.minY) \($0.width) \($0.height)" }.joined(separator: "\n")
                try? s.write(toFile: String(parts[1]), atomically: true, encoding: .utf8)
            }
        }
        // --dump-windows "秒數:檔案"：設定視窗開著沒、每個 Session 的 Window 名稱、作用中的是哪個視窗
        for (i, a) in args.enumerated() where a == "--dump-windows" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                let key = NSApp.keyWindow.map { $0 === self.main.window ? "主視窗" : $0 === self.settings?.window ? "設定" : $0.title } ?? "（無）"
                let fr = self.main.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                let s = "settings=\(self.settings?.window?.isVisible == true) key=\(key) active=\(NSApp.isActive) mainKey=\(self.main.window?.isKeyWindow == true) focus=\(fr) pane=\(self.store.currentWindow?.focused.map { String($0.uuidString.suffix(4)) } ?? "nil") windows=\(self.store.sessions.map { $0.windows.map(\.name) })\n"
                try? s.write(toFile: String(parts[1]), atomically: true, encoding: .utf8)
            }
        }
        // --open-settings "秒數:持續秒數"：幾秒後打開設定視窗、短暫放到最前面（不搶焦點）給截圖工具拍，時間到退回後面
        for (i, a) in args.enumerated() where a == "--open-settings" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":").compactMap { Double($0) }
            guard parts.count == 2 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + parts[0]) { [weak self] in
                self?.showSettings()
                guard let w = self?.settings?.window else { return }
                w.orderFrontRegardless()
                DispatchQueue.main.asyncAfter(deadline: .now() + parts[1]) { w.orderBack(nil) }
            }
        }
        // --chat-send "秒數:文字"：幾秒後在聊天框打這些字並送出（\\n 代表換行）
        for (i, a) in args.enumerated() where a == "--chat-send" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let text = String(parts[1]).replacingOccurrences(of: "\\n", with: "\n")
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.inputBar.textView.string = text
                p.inputBar.textView.onSend?()
            }
        }
        // --tab-test "秒數:檔案"：在幾種焦點下呼叫「輸入框外按 Tab」，結果寫進檔案（Tab 只在對話內容上採用建議，其他地方照常）
        for (i, a) in args.enumerated() where a == "--tab-test" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let w = self.main.window,
                      let (id, p) = self.workspace.panes.compactMap({ k, v in (v as? ChatPane).map { (k, $0) } }).first else { return }
                self.store.setFocus(id)
                let tv = p.inputBar.textView
                guard let web = p.subviews.first(where: { $0 is WKWebView }) else { return }
                var out: [String] = []
                func run(_ name: String, focus: NSView?, expect: Bool) {
                    tv.string = ""; tv.suggestion = "測試建議"
                    if let focus { w.makeFirstResponder(focus) }
                    let r = self.main.tabSuggestion(from: w)
                    out.append("\(r == expect ? "OK " : "NG ") \(name)：攔了=\(r) 輸入框=「\(tv.string)」")
                }
                run("焦點在對話內容", focus: web, expect: true)
                run("焦點在輸入框本身（交給輸入框自己）", focus: tv, expect: false)
                // 聊天室裡可輸入的地方（程式碼區編輯器、看板輸入框也是可編輯的 NSTextView）
                let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 50, height: 20)); p.addSubview(editor)
                run("焦點在聊天室裡的可編輯文字區（程式碼區編輯器）", focus: editor, expect: false)
                editor.removeFromSuperview()
                let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 50, height: 20)); w.contentView?.addSubview(field)
                run("焦點在主視窗別的輸入欄（看板輸入框）", focus: field, expect: false)
                field.removeFromSuperview()
                if let b = BrowserPane.all.first { run("焦點在瀏覽器格", focus: b.webView, expect: false) }
                w.makeFirstResponder(web)
                tv.string = "已經有字"; let r1 = self.main.tabSuggestion(from: w); out.append("\(r1 ? "NG" : "OK ") 輸入框已經有字：攔了=\(r1)")
                tv.string = ""; tv.suggestion = nil; let r2 = self.main.tabSuggestion(from: w); out.append("\(r2 ? "NG" : "OK ") 沒有建議：攔了=\(r2)")
                self.showSettings()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.settings?.window?.makeKey()
                    tv.suggestion = "測試建議"; w.makeFirstResponder(web)
                    let r3 = self.main.tabSuggestion(from: self.settings?.window)
                    out.append("\(r3 ? "NG" : "OK ") 在設定視窗按 Tab：攔了=\(r3)")
                    try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
                }
            }
        }
        // --pane-close-test "秒數:檔案"：前三段對話排成三格（比例 0.3／0.6），紫框在中間按 ⌘ W、⌘ ⇧ T，再關到剩一格、關 Window、找回，結果寫進檔案
        for (i, a) in args.enumerated() where a == "--pane-close-test" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let s = self.store, s.conversations.count >= 3 else { return }
                let ids = Array(s.conversations.prefix(3).map(\.id))
                let (a, b, c) = (ids[0], ids[1], ids[2])
                let name = { (id: UUID?) in id.flatMap { x in ids.firstIndex(of: x).map { ["A", "B", "C"][$0] } } ?? "nil" }
                var out: [String] = []
                func ok(_ cond: Bool, _ msg: String) { out.append((cond ? "OK  " : "NG  ") + msg) }
                let orig: PaneNode = .split(vertical: false, ratio: 0.3, a: .leaf(a), b: .split(vertical: false, ratio: 0.6, a: .leaf(b), b: .leaf(c)))
                for id in ids { s.unplace(id) }
                s.editWindow { w in w.root = orig; w.focused = b }
                let windowsBefore = s.sessions.first?.windows.count ?? 0
                let bURL = s.conversation(b)?.browser
                ok(true, "B 是瀏覽器格子=\(bURL != nil)")
                s.closePaneOrWindow()
                let leaves = s.currentWindow?.root?.leaves ?? []
                ok(leaves == [a, c], "⌘ W 後剩 \(leaves.map { name($0) })")
                ok(s.currentWindow?.focused == a || s.currentWindow?.focused == c, "焦點移到 \(name(s.currentWindow?.focused))")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    ok(self.workspace.panes[b] == nil && !BrowserPane.all.contains { $0.conversationID == b }, "關掉的瀏覽器格子已停掉（3 秒後）")
                    ok(s.conversation(b) != nil, "B 還在側欄")
                    ok(s.reopenClosedWindow(), "⌘ ⇧ T 有東西可以找回")
                    ok(s.currentWindow?.root == orig, "B 放回原位、比例一樣")
                    ok(s.currentWindow?.focused == b, "焦點回到 B")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        let bp = BrowserPane.all.first { $0.conversationID == b }
                        ok(bp?.currentURL == bURL, "B 重新打開回到原網址：\(bp?.currentURL ?? "沒有")")
                        // 關到剩一格，再 ⌘ W 關整個 Window，找回
                        s.closePaneOrWindow(); s.closePaneOrWindow()
                        ok((s.currentWindow?.root?.leaves.count ?? 0) == 1, "連按兩次 ⌘ W 剩一格")
                        let lone = s.currentWindow?.root?.leaves.first
                        let wid = s.currentWindow?.id
                        s.closePaneOrWindow()
                        ok(!(s.sessions.first?.windows.contains { $0.id == wid } ?? true), "只剩一格時 ⌘ W 關掉整個 Window（Window 數 \(windowsBefore) → \(s.sessions.first?.windows.count ?? 0)，空的補上一個）")
                        ok(s.reopenClosedWindow(), "⌘ ⇧ T 找回 Window")
                        ok(s.currentWindow?.id == wid && s.currentWindow?.root?.leaves == [lone!], "找回的是同一個 Window、裡面是 \(name(lone))")
                        ok(s.reopenClosedWindow() && s.reopenClosedWindow(), "再按兩次 ⌘ ⇧ T 把前面關的兩格也找回")
                        ok(Set(s.currentWindow?.root?.leaves ?? []) == Set(ids), "三格都回來了：\((s.currentWindow?.root?.leaves ?? []).map { name($0) })")
                        ok(s.currentWindow?.root == orig, "版面跟一開始一樣")
                        try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
                    }
                }
            }
        }
        // --agy-net-test "秒數:檔案"：斷網判斷的各層結果寫進檔案（配 --agy-offline、--agy-check-host 用）
        for (i, a) in args.enumerated() where a == "--agy-net-test" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                DispatchQueue.global().async {
                    var out = ["quickOK=\(AgyNet.quickOK)", "canCall=\(AgyNet.canCall())"]
                    // 假的 agy 紀錄：走到互動登入 → 之後 30 分鐘都不叫
                    let log = AgyNet.newLogFile()
                    try? "I1025 printmode.go:409] Print mode: silent auth failed\nI1025 printmode.go:426] Print mode: triggering interactive OAuth\n".write(to: log, atomically: true, encoding: .utf8)
                    AgyNet.check(log: log)
                    out.append("跳過登入頁之後 quickOK=\(AgyNet.quickOK) canCall=\(AgyNet.canCall()) 紀錄檔刪了=\(!FileManager.default.fileExists(atPath: log.path))")
                    try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
                }
            }
        }
        // --finder-test "秒數:檔案"：點路徑時 Finder 會怎麼顯示（只算結果，不真的開 Finder）
        for (i, a) in args.enumerated() where a == "--finder-test" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                let home = NSHomeDirectory()
                let cases = ["/etc/hosts", "/usr/bin",
                             "/Applications/Google Chrome.app", home + "/Documents/沒有這個/檔案.md", "/no/such/dir/x.txt"]
                let out = cases.map { c -> String in
                    let t = ChatPane.finderTarget(URL(fileURLWithPath: c))
                    return "\(c) → \(t.select ? "選起來" : "打開") \(t.url.path)"
                }
                try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        // --new-browser "秒數"：像按側欄的「瀏覽器」
        for (i, a) in args.enumerated() where a == "--new-browser" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.main.newBrowser() }
        }
        // --browser-test "秒數:動作:參數"：對目前選中的瀏覽器格子做事（紀錄寫進 state-dir/browser-test.log）
        //   zoom:+ 或 zoom:-（同 ⌘ + / ⌘ −）、load:網址或 file://…、drop:檔案路徑（假的 Finder 拖放，不動真滑鼠）、click:x,y（網頁座標，事件直接送給 WKWebView）
        for (i, a) in args.enumerated() where a == "--browser-test" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let b = self.workspace.panes[id] as? BrowserPane else { return }
                let logURL = self.store.directory.appendingPathComponent("browser-test.log")
                let log: (String) -> Void = { line in
                    let d = Data((line + "\n").utf8)
                    if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(d); try? h.close() } else { try? d.write(to: logURL) }
                }
                switch parts[1] {
                case "load": b.load(parts[2])
                case "drop": FakeFileDrag.run(files: [URL(fileURLWithPath: parts[2])], onto: b.webView, log: log)
                case "click":
                    let xy = parts[2].split(separator: ",").compactMap { Double($0) }
                    guard xy.count == 2, let win = b.window else { return }
                    let w = b.webView
                    let pt = w.convert(NSPoint(x: xy[0], y: w.isFlipped ? xy[1] : w.bounds.height - xy[1]), to: nil)
                    for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        guard let e = NSEvent.mouseEvent(with: t, location: pt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
                        if t == .leftMouseDown { w.mouseDown(with: e) } else { w.mouseUp(with: e) }
                    }
                    log("click \(xy) 已送出")
                case "zoom": b.zoom(parts[2] == "-" ? -1 : 1); log("pageZoom \(b.webView.pageZoom)")
                case "sheet":   // 看視窗上有沒有掛著選檔視窗；有就按取消收掉
                    let sh = b.window?.attachedSheet
                    log("sheet：\(sh.map { String(describing: type(of: $0)) } ?? "沒有")")
                    if let sh { b.window?.endSheet(sh, returnCode: .cancel) }
                default: break
                }
            }
        }
        // --input-text "秒數:文字"：幾秒後在聊天框打這些字但不送出（\\n 代表換行；看長文字會不會碰到下面的狀態列）
        for (i, a) in args.enumerated() where a == "--input-text" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let text = String(parts[1]).replacingOccurrences(of: "\\n", with: "\n")
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.inputBar.textView.string = text
                p.inputBar.textView.didChangeText()
            }
        }
        // --input-files "秒數:路徑|路徑…"：幾秒後像把這些檔案拖進聊天框（圖片變縮圖、其他變檔案卡片）
        for (i, a) in args.enumerated() where a == "--input-files" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let urls = parts[1].split(separator: "|").map { URL(fileURLWithPath: String($0)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                let imgs = urls.filter(ChatTextView.isImage), others = urls.filter { !ChatTextView.isImage($0) }
                if !imgs.isEmpty { p.inputBar.attach(urls: imgs, images: []) }
                p.inputBar.insertPaths(others)
            }
        }
        // --input-key "秒數:游標[+選取長度]:keyCode"：幾秒後把游標放到那裡、在 App 裡直接送一個按鍵給輸入框（不經系統，不動真的鍵盤）
        // 例：51＝delete、117＝往後刪、123／124＝← →；位置 -1＝最後面
        for (i, a) in args.enumerated() where a == "--input-key" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":").map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]), let code = UInt16(parts[2]) else { continue }
            let sel = parts[1].split(separator: "+").compactMap { Int($0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane, let w = p.window else { return }
                let tv = p.inputBar.textView
                let n = (tv.string as NSString).length
                let loc = (sel.first ?? -1) < 0 ? n : min(n, sel[0])
                tv.setSelectedRange(NSRange(location: loc, length: min(n - loc, sel.count > 1 ? sel[1] : 0)))
                let ch = code == 51 ? "\u{7f}" : code == 117 ? "\u{f728}" : code == 123 ? "\u{f702}" : code == 124 ? "\u{f703}" : ""
                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                            context: nil, characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code) {
                    tv.keyDown(with: e)
                }
            }
        }
        // --dump-input "秒數:檔案"：把目前聊天室輸入框裡的字寫進檔案（測 ⌃ C 放回）
        for (i, a) in args.enumerated() where a == "--dump-input" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                let fr = p.window?.firstResponder
                let where_ = fr === p.inputBar.textView ? "輸入框" : fr.map { "\(type(of: $0))" } ?? "無"
                try? "busy=\(p.inputBar.busy) focus=\(where_) \(p.inputBar.scrollerState) suggestion=\(p.inputBar.suggestion ?? "（無）") undo=\(p.inputBar.textView.undoManager?.canUndo == true)/\(p.inputBar.textView.undoManager?.canRedo == true) sel=\(p.inputBar.textView.selectedRange().location) text=\(p.inputBar.textView.string)\n".write(toFile: String(parts[1]), atomically: true, encoding: .utf8)
            }
        }
        // --focus-input "秒數"：把 App 叫到前面、焦點放進輸入框（測選單快捷鍵 ⌘ Z、⌘ X 要有作用中的視窗；會搶走鍵盤焦點）
        for (i, a) in args.enumerated() where a == "--focus-input" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                NSApp.activate(ignoringOtherApps: true)
                self.main.window?.makeKeyAndOrderFront(nil)
                self.main.window?.makeFirstResponder(p.inputBar.textView)
            }
        }
        // --blur-input "秒數"：像 Claude 沒在做時按 Esc（離開輸入框），但 Claude 在做時也能用
        for (i, a) in args.enumerated() where a == "--blur-input" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.inputBar.onBlur?()
            }
        }
        // --set-input "秒數:文字"：只把字放進輸入框（不送出、不移焦點）
        for (i, a) in args.enumerated() where a == "--set-input" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.inputBar.textView.string = String(parts[1]).replacingOccurrences(of: "\\n", with: "\n")
                p.inputBar.textView.didChangeText()
            }
        }
        // --chat-send-now "秒數:文字"：像按 ⌃ Enter（Claude 還在做的話馬上插話）
        for (i, a) in args.enumerated() where a == "--chat-send-now" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let text = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.inputBar.textView.string = text
                p.inputBar.textView.onSendNow?()
            }
        }
        // --dump-focus "秒數:檔案"：幾秒後把游標所在的元件和輸入框文字附加到檔案（測 Esc、/）
        for (i, a) in args.enumerated() where a == "--dump-focus" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                let fr = self.main.window?.firstResponder
                let r = fr.map { String(describing: type(of: $0)) } ?? "nil"
                // 游標在哪一格（看第一回應者在哪段對話的格子裡）
                let owner = self.workspace.panes.first { (_, v) in (fr as? NSView).map { $0.isDescendant(of: v) } ?? false }
                let where_ = owner.flatMap { self.store.conversation($0.key)?.title } ?? "-"
                let line = "\(sec)s 游標=\(r) 格=\(where_) 目前格=\(self.store.currentWindow?.focused.flatMap { self.store.conversation($0)?.title } ?? "-") 輸入框=「\(p.inputBar.textView.string)」\n"
                if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile() }
                else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
            }
        }
        // --drag-tab "秒數:第幾個分頁:拖幾個分頁寬"：按住上面的分頁往右（負數往左）拖再放開
        for (i, a) in args.enumerated() where a == "--drag-tab" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":")
            guard parts.count == 3, let sec = Double(parts[0]), let n = Int(parts[1]), let k = Double(parts[2]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let w = self?.main.window, let bar = Self.find(TabBar.self, in: w.contentView), let p = bar.tabCenter(n),
                      let q = bar.tabCenter(n + 1) ?? bar.tabCenter(n - 1) else { return }
                let step = abs(q.x - p.x)
                var pts = [(NSEvent.EventType.leftMouseDown, p)]
                for j in 1...10 { pts.append((.leftMouseDragged, NSPoint(x: p.x + step * k * Double(j) / 10, y: p.y))) }
                pts.append((.leftMouseUp, NSPoint(x: p.x + step * k, y: p.y)))
                for (t, pt) in pts {
                    if let e = NSEvent.mouseEvent(with: t, location: pt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.postEvent(e, atStart: false) }
                }
                Self.flushEvents(w)
            }
        }
        // --drag-tab-slow "秒數:第幾個分頁:拖幾個分頁寬:紀錄檔"：照真人速度慢慢拖（每 30 毫秒一步），一邊把每個分頁畫面上的 x 寫進紀錄檔
        for (i, a) in args.enumerated() where a == "--drag-tab-slow" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 3)
            guard parts.count == 4, let sec = Double(parts[0]), let n = Int(parts[1]), let k = Double(parts[2]) else { continue }
            let log = String(parts[3])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let w = self?.main.window, let bar = Self.find(TabBar.self, in: w.contentView), let p = bar.tabCenter(n),
                      let q = bar.tabCenter(n + 1) ?? bar.tabCenter(n - 1) else { return }
                let step = abs(q.x - p.x)
                var lines: [String] = []
                let t0 = ProcessInfo.processInfo.systemUptime
                func post(_ t: NSEvent.EventType, _ x: CGFloat) {
                    if let e = NSEvent.mouseEvent(with: t, location: NSPoint(x: x, y: p.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.postEvent(e, atStart: false) }
                }
                // 取樣計時器（常用模式：拖曳的事件迴圈裡也會跑）
                let sampler = Timer(timeInterval: 0.01, repeats: true) { _ in
                    let xs = (0..<8).compactMap { bar.tabShownX($0) }.map { String(format: "%.0f", $0) }.joined(separator: " ")
                    lines.append(String(format: "%.3f ", ProcessInfo.processInfo.systemUptime - t0) + xs)
                }
                RunLoop.main.add(sampler, forMode: .common)
                post(.leftMouseDown, p.x)
                let steps = 20
                for j in 1...steps {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03 * Double(j)) {
                        post(.leftMouseDragged, p.x + step * k * Double(j) / Double(steps)); Self.flushEvents(w)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03 * Double(steps + 1)) { post(.leftMouseUp, p.x + step * k); Self.flushEvents(w) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03 * Double(steps + 1) + 0.6) {
                    sampler.invalidate()
                    try? lines.joined(separator: "\n").write(toFile: log, atomically: true, encoding: .utf8)
                }
                Self.flushEvents(w)
            }
        }
        // --pull-tab "秒數:第幾個分頁:left|right|top|bottom"：把那個分頁往下拉進目前畫面第一格的那一半放開
        for (i, a) in args.enumerated() where a == "--pull-tab" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":")
            guard parts.count == 3, let sec = Double(parts[0]), let n = Int(parts[1]) else { continue }
            let edge = String(parts[2])
            // 格子還沒擺好（背景開起來有時要比較久）就每半秒再試，最多 20 次
            var tries = 0
            func attempt() {
                // edge 寫 empty：瞄準空格子的正中間
                let cv = self.main.window?.contentView
                let tv: NSView? = edge == "empty" ? Self.find(EmptyPaneView.self, in: cv) : Self.find(PaneFrame.self, in: cv)
                guard let w = self.main.window, let bar = Self.find(TabBar.self, in: w.contentView), let p = bar.tabCenter(n),
                      let f = tv, f.bounds.width > 50 else {
                    tries += 1; pullDebug("test wait \(tries)")
                    if tries < 20 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: attempt) }
                    return
                }
                let r = f.convert(f.bounds, to: nil)
                let q: NSPoint = ["left": NSPoint(x: r.minX + r.width * 0.15, y: r.midY), "right": NSPoint(x: r.maxX - r.width * 0.15, y: r.midY),
                                  "top": NSPoint(x: r.midX, y: r.maxY - r.height * 0.15), "bottom": NSPoint(x: r.midX, y: r.minY + r.height * 0.15)][edge] ?? NSPoint(x: r.midX, y: r.midY)
                var pts = [(NSEvent.EventType.leftMouseDown, p)]
                for j in 1...12 { let t = Double(j) / 12; pts.append((.leftMouseDragged, NSPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t))) }
                pts.append((.leftMouseUp, q))
                for (t, pt) in pts {
                    if let e = NSEvent.mouseEvent(with: t, location: pt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.postEvent(e, atStart: false) }
                }
                Self.flushEvents(w)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec, execute: attempt)
        }
        // --tear-pane "秒數:第幾格"：按住第 n 格（PaneFrame，從 0 數）的標題拖到分頁列的空白處放開（變成新分頁）
        // --swap-pane "秒數:第幾格:到第幾格:檔名開頭"：拖第幾格（由左到右）的標題到另一格中間，途中拍一張（<開頭>-mid.png），
        // 放開後把各格由左到右的聊天室名字寫進 <開頭>.txt（前後各一行）
        for (i, a) in args.enumerated() where a == "--swap-pane" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 3)
            guard parts.count == 4, let sec = Double(parts[0]), let n = Int(parts[1]), let m = Int(parts[2]) else { continue }
            let base = String(parts[3])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let w = self.main.window else { return }
                func all(_ v: NSView?) -> [PaneFrame] { guard let v else { return [] }; return (v as? PaneFrame).map { [$0] } ?? v.subviews.flatMap { all($0) } }
                func order() -> String {
                    all(w.contentView).sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
                        .map { self.store.conversation($0.conversation)?.title ?? "?" }.joined(separator: " | ")
                }
                let fs = all(w.contentView).sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
                guard fs.indices.contains(n), fs.indices.contains(m) else { try? "格子不夠：\(fs.count)".write(toFile: base + ".txt", atomically: true, encoding: .utf8); return }
                var log = "前：" + order() + "\n"
                let p = fs[n].convert(NSPoint(x: fs[n].bounds.midX, y: fs[n].bounds.height - PaneFrame.headerHeight / 2), to: nil)
                let q = fs[m].convert(NSPoint(x: fs[m].bounds.midX, y: fs[m].bounds.midY), to: nil)
                func post(_ t: NSEvent.EventType, _ pt: NSPoint) {
                    if let e = NSEvent.mouseEvent(with: t, location: pt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.postEvent(e, atStart: false) }
                }
                post(.leftMouseDown, p)
                for j in 1...12 { let t = Double(j) / 12; post(.leftMouseDragged, NSPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t)) }
                Self.flushEvents(w)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    if let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                        v.cacheDisplay(in: v.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: base + "-mid.png"))
                    }
                    post(.leftMouseUp, q)
                    Self.flushEvents(w)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        log += "後：" + order() + "\n"
                        try? log.write(toFile: base + ".txt", atomically: true, encoding: .utf8)
                    }
                }
            }
        }
        for (i, a) in args.enumerated() where a == "--tear-pane" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":")
            guard parts.count == 2, let sec = Double(parts[0]), let n = Int(parts[1]) else { continue }
            var tries = 0
            func attempt() {
                func all(_ v: NSView?) -> [PaneFrame] { guard let v else { return [] }; return (v as? PaneFrame).map { [$0] } ?? v.subviews.flatMap { all($0) } }
                let fs = all(self.main.window?.contentView).sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
                guard let w = self.main.window, let bar = Self.find(TabBar.self, in: w.contentView), fs.indices.contains(n), fs[n].bounds.width > 50 else {
                    tries += 1
                    if tries < 20 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: attempt) }
                    return
                }
                let f = fs[n]
                let p = f.convert(NSPoint(x: f.bounds.midX, y: f.bounds.height - PaneFrame.headerHeight / 2), to: nil)
                let q = bar.emptyPoint()
                var pts = [(NSEvent.EventType.leftMouseDown, p)]
                for j in 1...12 { let t = Double(j) / 12; pts.append((.leftMouseDragged, NSPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t))) }
                pts.append((.leftMouseUp, q))
                for (t, pt) in pts {
                    if let e = NSEvent.mouseEvent(with: t, location: pt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.postEvent(e, atStart: false) }
                }
                Self.flushEvents(w)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec, execute: attempt)
        }
        // --fill-empty "秒數"：目前 Window 第一個空格子按「新增聊天室」選第一個資料夾（跳過選單）
        for (i, a) in args.enumerated() where a == "--fill-empty" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let pid = self.store.projects.first?.id else { return }
                let slot = self.store.currentWindow?.root?.leaves.first { self.store.isEmptySlot($0) }
                self.main.fillEmpty(slot, newIn: pid, group: self.store.groups.first?.id)
            }
        }
        // --codelab "秒數:check|run|context:輸出檔"：目前那格的程式碼區按檢查／執行，或把給 Claude 的那行上下文寫進檔案
        for (i, a) in args.enumerated() where a == "--codelab" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2)
            guard parts.count == 3, let sec = Double(parts[0]) else { continue }
            let act = String(parts[1]), out = String(parts[2])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let f = self.store.currentWindow?.focused, let p = self.workspace.panes[f] as? ChatPane, let lab = p.codeLab else {
                    try? "沒有程式碼區".write(toFile: out, atomically: true, encoding: .utf8); return
                }
                lab.testAction(act) { s in try? s.write(toFile: out, atomically: true, encoding: .utf8) }
            }
        }
        // --handoff "秒數"：目前這段對話直接交接（不問）
        for (i, a) in args.enumerated() where a == "--handoff" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let c = self.store.conversation(id), let dir = self.store.project(c.projectID)?.path else { return }
                self.main.startHandoff(c, directory: dir)
            }
        }
        // --click-pane "秒數:第幾段對話"：在那段對話那格的對話區（上半部）點一下滑鼠
        for (i, a) in args.enumerated() where a == "--click-pane" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":")
            guard parts.count == 2, let sec = Double(parts[0]), let n = Int(parts[1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let w = self.main.window, n < self.store.conversations.count,
                      let v = self.workspace.panes[self.store.conversations[n].id], v.window != nil else { return }
                let pt = v.convert(NSPoint(x: v.bounds.midX, y: v.bounds.height * 0.7), to: nil)
                for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let e = NSEvent.mouseEvent(with: t, location: pt, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.postEvent(e, atStart: false) }
                }
                Self.flushEvents(w)
            }
        }
        // --chat-image "秒數:圖片檔"：幾秒後把圖片加到聊天框的附件（之後用 --chat-send 送出）
        for (i, a) in args.enumerated() where a == "--chat-image" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let url = URL(fileURLWithPath: String(parts[1]))
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.inputBar.textView.onImages?([url], [])
            }
        }
        // --new-in-group "秒數:組名"：像在群組上按右鍵「在這一組開新對話」
        for (i, a) in args.enumerated() where a == "--new-in-group" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let g = self.store.groups.first(where: { $0.name == String(parts[1]) }) else { return }
                self.store.newConversation(inGroup: g.id)
            }
        }
        // --hit-test "秒數:x,y;x,y…"：幾秒後印出主視窗這些點（從左上角算，單位 pt）點下去會落在哪個 view 上
        for (i, a) in args.enumerated() where a == "--hit-test" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let w = self?.main.window, let root = w.contentView?.superview else { return }
                for pt in parts[1].split(separator: ";") {
                    let xy = pt.split(separator: ",").compactMap { Double($0) }
                    guard xy.count == 2 else { continue }
                    let p = NSPoint(x: xy[0], y: root.bounds.height - xy[1])
                    let v = root.hitTest(p)
                    print("hit \(pt) → \(v.map { String(describing: type(of: $0)) } ?? "nil")")
                }
                fflush(stdout)
            }
        }
        // --dump-panes "秒數:檔案"：附加一行「目前開著（有程序物件）的格子」的對話標題，看關掉的格子有沒有被收掉
        for (i, a) in args.enumerated() where a == "--dump-panes" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                let names = self.workspace.panes.keys.compactMap { self.store.conversation($0)?.title }.sorted()
                let line = "t=\(parts[0]) panes=\(names)\n"
                if let h = FileHandle(forWritingAtPath: String(parts[1])) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
                else { try? line.write(toFile: String(parts[1]), atomically: true, encoding: .utf8) }
            }
        }
        // --close-pane "秒數"：關掉目前那格（像按 × 確認之後）
        for (i, a) in args.enumerated() where a == "--close-pane" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.store.closePane() }
        }
        // --carry-dump "紀錄檔:輸出檔"：把一份紀錄檔整理成換模型交接的那段（只讀紀錄檔，全文檔寫到測試的 carry 資料夾）
        for (i, a) in args.enumerated() where a == "--carry-dump" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let note = ModelCarry.note(from: URL(fileURLWithPath: String(parts[0])), session: UUID(), limit: 6000, canRead: true) ?? "nil"
            try? note.write(toFile: String(parts[1]), atomically: true, encoding: .utf8)
        }
        // --collab-dump "秒數:檔案"：協作看板讀到的往來、每一對的來回次數、提醒、待辦（讀 --state-dir 裡的 projects、collab.json）
        for (i, a) in args.enumerated() where a == "--collab-dump" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                CollabBoardModel.shared.refresh {
                    let line = "t=\(parts[0]) open=\(CollabBoardModel.shared.open)\n" + CollabBoardModel.shared.dump()
                    if let h = FileHandle(forWritingAtPath: String(parts[1])) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
                    else { try? line.write(toFile: String(parts[1]), atomically: true, encoding: .utf8) }
                }
            }
        }
        // --collab-act "秒數|動作|參數…"：像在看板上操作（測 codenv 這邊寫 collab.json）。動作：
        //   done 登記編號／approve 目標／step 目標 步驟 狀態／addgoal 標題 完成標準 步驟（\\n 分行）／addstep 目標 內容@負責人／delgoal 目標
        for (i, a) in args.enumerated() where a == "--collab-act" && i + 1 < args.count {
            let p = args[i + 1].components(separatedBy: "|")
            guard p.count >= 3, let sec = Double(p[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                let m = CollabBoardModel.shared
                switch p[1] {
                case "done": m.editTodo(p[2], col: "done")
                case "approve": m.setGoalStatus(p[2], "active")
                case "step" where p.count >= 5: m.setStep(goal: p[2], step: p[3], state: p[4])
                case "addgoal" where p.count >= 5: m.addGoal(title: p[2], done: p[3], steps: p[4].replacingOccurrences(of: "\\n", with: "\n"))
                case "addstep" where p.count >= 4: m.addStep(goal: p[2], line: p[3])
                case "delgoal": m.deleteGoal(p[2])
                case "setowner" where p.count >= 5: m.setOwner(goal: p[2], step: p[3], owner: p[4])   // 改負責人：setowner|目標|步驟|名字
                case "manualprompt" where p.count >= 5:   // 手動步驟的 prompt 寫進檔案：manualprompt|目標|步驟|檔案
                    if let st = m.goals.first(where: { $0.id == p[2] })?.steps.first(where: { $0.id == p[3] }) { try? CollabBoardModel.manualPrompt(st).write(toFile: p[4], atomically: true, encoding: .utf8) }
                case "manualreturn" where p.count >= 5:   // 交回：manualreturn|目標|步驟|回答（\\n 分行）；結果寫進 state-dir/manual-return.txt
                    let ok = m.returnManual(goal: p[2], step: p[3], text: p[4].replacingOccurrences(of: "\\n", with: "\n"))
                    let line = "manualreturn \(p[3]) → \(ok)\n"
                    let f = URL(fileURLWithPath: CollabBoardModel.todoFile.deletingLastPathComponent().path).appendingPathComponent("manual-return.txt")
                    if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() } else { try? line.write(to: f, atomically: true, encoding: .utf8) }
                default: break
                }
            }
        }
        // --rename "秒數:新名字"：把目前選的對話改名（像側欄右鍵重新命名）
        for (i, a) in args.enumerated() where a == "--rename" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected else { return }
                self.store.rename(id, to: String(parts[1]), byUser: true)
            }
        }
        // --schedule-put "秒數|第幾段對話|頻率|時間（逗號）|要送的話|沒開著時|每隔幾分鐘"：新增一個排程（下一次照 --fake-now 的「現在」算）
        for (i, a) in args.enumerated() where a == "--schedule-put" && i + 1 < args.count {
            let p = args[i + 1].components(separatedBy: "|")
            guard p.count >= 6, let sec = Double(p[0]), let n = Int(p[1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, n < self.store.conversations.count else { return }
                var sc = WakeSchedule(conversation: self.store.conversations[n].id, text: p[4])
                sc.frequency = p[2]
                sc.times = p[3].components(separatedBy: ",")
                sc.whenClosed = p[5]
                if p.count > 6, let m = Int(p[6]) { sc.intervalMinutes = m }
                ScheduleStore.shared.put(sc)
            }
        }
        // --schedule-sheet "秒數:第幾段對話"：打開那段對話的「排程…」小視窗（像在側欄右鍵）
        for (i, a) in args.enumerated() where a == "--schedule-sheet" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":").compactMap { Double($0) }
            guard parts.count == 2 else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + parts[0]) { [weak self] in
                guard let self, Int(parts[1]) < self.store.conversations.count else { return }
                self.main.showSchedule(self.store.conversations[Int(parts[1])].id)
            }
        }
        // --schedule-dump "秒數:檔案"：附加每個排程的下一次、待送、最近幾次結果
        for (i, a) in args.enumerated() where a == "--schedule-dump" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                let line = "t=\(parts[0]) now=\(ISO8601DateFormatter.local.string(from: ScheduleStore.now()))\n" + ScheduleStore.shared.dump()
                if let h = FileHandle(forWritingAtPath: String(parts[1])) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
                else { try? line.write(toFile: String(parts[1]), atomically: true, encoding: .utf8) }
            }
        }
        // --collab-open "秒數"：打開協作看板（像按最左邊的協作圖示）
        for (i, a) in args.enumerated() where a == "--collab-open" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { CollabBoardModel.shared.open = true }
        }
        // --area "秒數:home|codelab"：像點側欄最左邊的圖示換區
        for (i, a) in args.enumerated() where a == "--area" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.store.switchArea(String(parts[1])) }
        }
        // --dump-layout "秒數:檔案"：附加一行目前在哪一區、看的是哪個 Session，每個 Session（區）裡各 Window 擺了哪些對話
        for (i, a) in args.enumerated() where a == "--dump-layout" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                let t = { (id: UUID) in self.store.conversation(id)?.title ?? "空" }
                let all = self.store.sessions.map { s in "\(s.name)(\(s.area ?? "home"))=" + s.windows.map { w in "[" + (w.root?.leaves.map(t) ?? []).joined(separator: ",") + "]" }.joined() }
                let line = "t=\(parts[0]) area=\(self.store.area) 看=\(self.store.currentSessionLayout?.name ?? "nil") 選=\(self.store.selected.map(t) ?? "nil") | " + all.joined(separator: " ") + "\n"
                if let h = FileHandle(forWritingAtPath: String(parts[1])) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
                else { try? line.write(toFile: String(parts[1]), atomically: true, encoding: .utf8) }
            }
        }
        // --move-folder "秒數:對話標題:新資料夾"：像在對話上按右鍵「換工作資料夾…」（不問，直接搬）
        for (i, a) in args.enumerated() where a == "--move-folder" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2)
            guard parts.count == 3, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let c = self.store.conversations.first(where: { $0.title == String(parts[1]) }) else { return }
                self.main.moveConversation(c.id, to: String(parts[2]))
            }
        }
        // --chat-js "秒數:JS"：幾秒後在聊天畫面裡跑一段 JS（例如點按鈕），結果附加到 --chat-log
        for (i, a) in args.enumerated() where a == "--chat-js" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let code = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.evaluate(code) { r in ChatSession.log?.write(Data("JS \(code.prefix(60)) => \(r.prefix(300))\n".utf8)) }
            }
        }
        // --chat-model "秒數:模型"：幾秒後像從選單換模型（haiku、fable…；default＝預設）
        for (i, a) in args.enumerated() where a == "--chat-model" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let v = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.applyModel(v)
                p.onModelChange?(v == "default" ? nil : v)
            }
        }
        // --keys "秒數:按鍵 按鍵 …"：幾秒後模擬按鍵（走跟真的按鍵一樣的路），例如 "3:C-a | C-a h"
        for (i, a) in args.enumerated() where a == "--keys" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let tokens = parts[1].split(separator: " ").map(String.init)
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let w = self?.main.window else { return }
                for (n, t) in tokens.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(n) * 0.15) { Self.postKey(t, window: w) }
                }
            }
        }
        // --place "秒數:第幾段對話:left|right|top|bottom|center"：像從側欄把對話拖到目前那格的某一邊
        for (i, a) in args.enumerated() where a == "--place" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":").map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]), let n = Int(parts[1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, n < self.store.conversations.count, let target = self.store.currentWindow?.focused else { return }
                let conv = self.store.conversations[n].id
                let edge: DropOverlay.Edge? = ["left": .left, "right": .right, "top": .top, "bottom": .bottom][parts[2]] ?? nil
                self.store.place(conv, near: target, edge: edge)
            }
        }
        // --chat-effort "秒數:low|medium|high|xhigh|max"：像從選單換思考強度
        for (i, a) in args.enumerated() where a == "--chat-effort" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let v = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.applyEffort(v)
                p.onEffortChange?(v)
            }
        }
        // --import-live "秒數"：像打開「自動加入」那樣，把正在跑的對話抓進來
        for (i, a) in args.enumerated() where a == "--import-live" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                ClaudeSessions.importLive(into: self.store)
            }
        }
        // --open-session "秒數:Claude 對話編號開頭"：打開那段對話
        for (i, a) in args.enumerated() where a == "--open-session" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let prefix = String(parts[1]).uppercased()
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let c = self.store.conversations.first(where: { $0.claudeSession.uuidString.hasPrefix(prefix) }) else { return }
                self.store.open(c.id)
            }
        }
        // --chat-fork "秒數"：像按「在這裡接手（複製一份）」
        for (i, a) in args.enumerated() where a == "--chat-fork" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.session.forkFrom = p.session.claudeSession
            }
        }
        // --chat-drop "秒數:檔案"：像把這個檔案拖進聊天畫面（走拖放收件那段）
        for (i, a) in args.enumerated() where a == "--chat-drop" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let url = URL(fileURLWithPath: String(parts[1])) as NSURL
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                let pb = NSPasteboard(name: NSPasteboard.Name("AIWorkbenchTest-\(UUID().uuidString)"))
                pb.clearContents()
                pb.writeObjects([url])
                _ = p.inputBar.takeDrop(pb)
                pb.releaseGlobally()
            }
        }
        // --model-list "秒數"：面板開著時切到模型清單那頁
        for (i, a) in args.enumerated() where a == "--model-list" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.testShowModelList()
            }
        }
        // --render-panel "秒數:檔案.png"：把思考強度面板直接畫成圖片（不用讓 App 跑到前面）
        // --shot-models "秒數:檔名開頭"：打開目前聊天室的模型面板、換到模型清單，每個分頁拍一張（＋列出內容的 .txt）
        for (i, a) in args.enumerated() where a == "--shot-models" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let base = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.inputBar.modelButton.performClick(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard let m = ModelPanelModel.last else { return }
                    m.showingModels = true; m.onSizeChange?()
                    for (n, t) in m.tabs.enumerated() {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + Double(n) * 0.6) {
                            m.tab = t; m.onSizeChange?()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                let list = m.shownSections.map { $0.map { $0.id + " | " + $0.shownTitle + ($0.via.map { " (\($0))" } ?? "") + ($0.checked ? " ✓" : "") }.joined(separator: "\n") }.joined(separator: "\n---\n")
                                try? "分頁：\(m.tabs.map(\.title))\n\(list)\n".write(toFile: "\(base)-\(t.rawValue).txt", atomically: true, encoding: .utf8)
                                guard let w = NSApp.windows.first(where: { $0 is FloatingPanel && $0.isVisible }), let v = w.contentView,
                                      let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                                v.cacheDisplay(in: v.bounds, to: rep)
                                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(base)-\(t.rawValue).png"))
                            }
                        }
                    }
                }
            }
        }
        // --anim-models "秒數:檔名開頭"：打開模型清單，從 Claude 換到 Gemini 再換回來，動畫途中每 40 毫秒記一次面板位置並拍照（查換頁跳動）
        for (i, a) in args.enumerated() where a == "--anim-models" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let base = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.inputBar.modelButton.performClick(nil)
                var log = ""
                func shot(_ tag: String) {
                    guard let w = NSApp.windows.first(where: { $0 is FloatingPanel && $0.isVisible }), let v = w.contentView else { return }
                    log += "\(tag) frame=\(w.frame)\n"
                    if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                        v.cacheDisplay(in: v.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(base)-\(tag).png"))
                    }
                    try? log.write(toFile: base + ".txt", atomically: true, encoding: .utf8)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard let m = ModelPanelModel.last else { return }
                    m.tab = .claude; m.showingModels = true; m.onSizeChange?()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        shot("a0")
                        withAnimation(.easeInOut(duration: 0.18)) { m.tab = .gemini }
                        m.onSizeChange?()
                        for k in 1...8 { DispatchQueue.main.asyncAfter(deadline: .now() + Double(k) * 0.04) { shot("a\(k)") } }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            shot("b0")
                            withAnimation(.easeInOut(duration: 0.18)) { m.tab = .claude }
                            m.onSizeChange?()
                            for k in 1...8 { DispatchQueue.main.asyncAfter(deadline: .now() + Double(k) * 0.04) { shot("b\(k)") } }
                        }
                    }
                }
            }
        }
        // --usage-page "秒數:檔名開頭"：等用量查完，把右側欄會列的（目前分頁用到的組）寫進 <開頭>.txt、拍整個視窗，
        // 再打開置中的完整用量頁拍一張（<開頭>-page.png）
        for (i, a) in args.enumerated() where a == "--usage-page" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let base = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let w = self.main.window else { return }
                let m = UsageMonitor.shared
                var out = "目前分頁的組：" + self.store.usagePoolsInCurrentWindow.map { $0.pool.rawValue + ($0.argon ? "+argon" : "") }.joined(separator: ", ") + "\n"
                for p in self.store.usagePoolsInCurrentWindow { for r in m.rows(p.pool, argon: p.argon) { out += "  側欄 \(p.pool.rawValue) | \(r.label) | \(r.bucket.remaining)% | \(r.bucket.resets)\n" } }
                for p in UsagePool.allCases { for r in m.rows(p) { out += "  全部 \(p.rawValue) | \(r.label) | \(r.bucket.remaining)%\n" }; if let n = m.note(p) { out += "  附註 \(p.rawValue) | \(n)\n" } }
                try? out.write(toFile: base + ".txt", atomically: true, encoding: .utf8)
                if let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: base + "-window.png"))
                }
                UsageSheet.toggle()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    guard let p = UsageSheet.current, let v = p.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: base + "-page.png"))
                    try? (out + "完整頁大小 \(p.frame.size)，主視窗 \(w.frame.size)，置中差 \(Int(p.frame.midX - w.frame.midX)),\(Int(p.frame.midY - w.frame.midY))\n").write(toFile: base + ".txt", atomically: true, encoding: .utf8)
                }
            }
        }
        // --render-models "秒數:檔名開頭"：用假資料畫模型清單的每個分頁（<開頭>-claude.png、-gemini.png、-local.png）
        for (i, a) in args.enumerated() where a == "--render-models" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let base = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                let m = ModelPanelModel()
                m.modelName = "Opus 5.5"; m.levels = Effort.order; m.defaultEffort = "high"; m.showingModels = true
                let r = { (id: String, t: String, c: Bool) in ModelRow(id: id, title: t, tip: "", checked: c) }
                m.sections = [[r("opus", "Opus 5.5", true), r("claude-opus-5", "Opus 5", false)], [r("sonnet", "Sonnet 5.5", false)],
                              [r("agy:gemini-4-argon-high", "Gemini 4 Argon", false), r("agy:gemini-3.8-flash-high", "Gemini 3.8 Flash", false),
                               r("agy:claude-opus-5-5-high", "Claude Opus 5.5", false), r("agy:claude-sonnet-5-5-high", "Claude Sonnet 5.5", false)],
                              [r("codex:gpt-6-luna", "GPT-6 Luna", false), r("codex:gpt-5.6-terra", "GPT-5.6 Terra", false)],
                              [r("copilot:auto", "Auto", false)],
                              [r("local:x", "LFM2.5", false)]]
                for t in ModelTab.allCases {
                    m.tab = t
                    let list = m.shownSections.map { $0.map { $0.shownTitle + ($0.via.map { " (\($0))" } ?? "") + ($0.checked ? " ✓" : "") }.joined(separator: "\n") }.joined(separator: "\n---\n")
                    try? "分頁：\(m.tabs.map(\.title))\n\(list)\n".write(toFile: "\(base)-\(t.rawValue).txt", atomically: true, encoding: .utf8)
                    let ren = ImageRenderer(content: ModelPanel(m: m).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
                    ren.scale = 2
                    if let img = ren.nsImage, let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: "\(base)-\(t.rawValue).png"))
                    }
                }
            }
        }
        for (i, a) in args.enumerated() where a == "--render-panel" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                let m = ModelPanelModel()
                m.modelName = "Opus 5.5"; m.levels = Effort.order; m.defaultEffort = "high"
                let r = ImageRenderer(content: ModelPanel(m: m).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
                r.scale = 2
                if let img = r.nsImage, let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                }
            }
        }
        // --render-sessions "秒數:檔案.png"：把 Session 面板畫成圖片（不真的打開，不會蓋到畫面上）
        for (i, a) in args.enumerated() where a == "--render-sessions" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                let m = SessionPanelModel()
                m.rows = self.main.sessionRows(); m.canClose = self.store.sessions.count > 1; m.keyIndex = 2
                let v = NSHostingView(rootView: SessionPanel(m: m))
                v.frame = NSRect(origin: .zero, size: v.fittingSize)
                v.layoutSubtreeIfNeeded()
                if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
            }
        }
        // --model-panel "秒數"：按右下角的模型按鈕
        for (i, a) in args.enumerated() where a == "--model-panel" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.inputBar.modelButton.performClick(nil)
            }
        }
        // --toggle-sidebar "秒數"：收起／打開側欄
        for (i, a) in args.enumerated() where a == "--toggle-sidebar" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.main.toggleSidebar() }
        }
        // --suggest "秒數:文字"：目前那格聊天的輸入框顯示這句灰字建議（測建議的畫法）
        for (i, a) in args.enumerated() where a == "--suggest" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let text = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.inputBar.suggestion = text
            }
        }
        // --organizer "秒數"：打開整理對話視窗
        for (i, a) in args.enumerated() where a == "--organizer" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.showOrganizer() }
        }
        // --organizer-dump "秒數:檔案"：整理對話「對話」分頁會列的對話、「資料夾」分頁的對話數
        for (i, a) in args.enumerated() where a == "--organizer-dump" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let st = self?.store as Store? else { return }
                var out = st.organizerConversations.map { "對話：\($0.title)" }
                out += st.projects.map { p in "資料夾：\(p.name) \(st.organizerConversations.filter { $0.projectID == p.id }.count) 段（全部 \(st.conversations.filter { $0.projectID == p.id }.count)）" }
                try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        // --new-conv "秒數"：像按「新對話」（跳出資料夾選單）
        for (i, a) in args.enumerated() where a == "--new-conv" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.main.newConversation() }
        }
        // --new-chat "秒數:標題"：幾秒後開一段真的聊天室（不是草稿，不會被自動刪；放進目前那格）。測版面、掛件、⌘ W 用
        for (i, a) in args.enumerated() where a == "--new-chat" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                let pid = self.store.projects.first?.id ?? self.store.addProject(path: NSHomeDirectory()).id
                var c = self.store.createConversation(in: pid)
                self.store.rename(c.id, to: String(parts[1]), byUser: true)
                c = self.store.conversation(c.id) ?? c
                self.store.show(c.id)
            }
        }
        // --new-conv-at "秒數:資料夾"：幾秒後直接在那個資料夾開新對話（不跳資料夾選單；測聊天室畫面用）
        for (i, a) in args.enumerated() where a == "--new-conv-at" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let dir = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.main.newConversation(at: dir) }
        }
        // --store-op "秒數:動作:第幾段:參數"：shift（參數＝上移負數／下移正數）、archive（1 封存／0 取消）、unread（1 標成做完沒看／0 取消）、before（排到第參數段前面）
        for (i, a) in args.enumerated() where a == "--store-op" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":").map(String.init)
            guard parts.count == 4, let sec = Double(parts[0]), let n = Int(parts[2]), let v = Int(parts[3]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, n < self.store.conversations.count else { return }
                let id = self.store.conversations[n].id
                switch parts[1] {
                case "shift": self.store.shift(id, by: v)
                case "archive": self.store.setArchived(id, v == 1)
                case "before": if v < self.store.conversations.count { self.store.reorder(id, before: self.store.conversations[v].id) }
                case "after": if v < self.store.conversations.count { self.store.reorder(id, after: self.store.conversations[v].id) }
                case "compact": (self.workspace.panes[id] as? ChatPane)?.compact()
                case "unread": if v == 1 { self.store.unread.insert(id) } else { self.store.unread.remove(id) }   // 分頁／側欄的小藍點
                // 掛件框（Bundles.swift）：gemini／notebook＝掛到第 n 段（參數不用）；leave＝離開框；dissolve＝解散第 n 段所在的框；
                // movegroup＝把第 n 段所在的框整個搬到第 v 組；attach＝把第 n 段（瀏覽器）改成掛在第 v 段上；open＝打開第 n 段的第 v 個掛件
                case "show": self.store.show(id)   // 放進紫框那格（測 ⌘ ⇧ B 依選中的格子決定掛不掛）
                case "focus": self.store.editWindow { $0.focused = id }   // 紫框移到第 n 段（它要已經在目前 Window）
                case "newwindow": self.store.newWindow(with: id)   // 開新 Window 放第 n 段
                case "window": self.store.selectWindow(at: v)      // 切到第 v 個 Window
                case "splitwith": self.store.split(vertical: false, with: id)   // 從紫框那格左右切開、放第 n 段
                case "gemini": self.store.addGadget(.gemini, to: id)
                case "notebook": self.store.addGadget(.notebooklm, to: id)
                case "leave": self.store.setBundle(id, nil)
                case "dissolve": if let b = self.store.conversation(id)?.bundle { self.store.dissolveBundle(b) }
                case "movegroup": if let b = self.store.conversation(id)?.bundle, v < self.store.groups.count { self.store.moveBundle(b, toGroup: self.store.groups[v].id) }
                case "attach": if v < self.store.conversations.count { self.store.attachBrowser(id, to: self.store.conversations[v].id) }
                case "open": if let b = self.store.conversation(id)?.bundle, v < self.store.gadgets(of: b).count { self.store.openGadget(self.store.gadgets(of: b)[v].id) }
                // ⌘ W（closew）、⌘ ⇧ T（reopen）、側欄點第 n 段（sidebar）、⌘ ⇧ B（togglebundle）：不按鍵盤，直接呼叫同一個函式
                case "closew": self.store.closePaneOrWindow()
                case "reopen": self.store.reopenClosedWindow()
                case "sidebar": self.store.open(id)
                case "togglebundle": self.store.toggleBundle(from: id)
                default: break
                }
            }
        }
        // --bundle-anim "秒數:動畫秒數"：把側欄所有掛件框停在描邊動畫的第幾秒（負數＝放開，回到正常）；可以給好幾次
        for (i, a) in args.enumerated() where a == "--bundle-anim" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]), let at = Double(parts[1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { BundleAnim.shared.frozen = at < 0 ? nil : at }
        }
        // --drag-divider "秒數:第幾條:比例"：像用滑鼠把目前 Window 的第幾條分隔線（外層先）拖到這個比例（測 ⌘ Q 後比例有沒有記住）
        for (i, a) in args.enumerated() where a == "--drag-divider" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":").map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]), let n = Int(parts[1]), let r = Double(parts[2]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in self?.main.host.testDragDivider(index: n, ratio: CGFloat(r)) }
        }
        // --quit "秒數"：走跟 ⌘ Q 一樣的結束流程（applicationShouldTerminate → applicationWillTerminate 存檔）
        for (i, a) in args.enumerated() where a == "--quit" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { NSApp.terminate(nil) }
        }
        // --dump-tree "秒數:檔案"：每個 Window 的版面樹和每一層的比例
        for (i, a) in args.enumerated() where a == "--dump-tree" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let st = self?.store as Store? else { return }
                func show(_ n: PaneNode) -> String {
                    switch n {
                    case .leaf(let id): return st.conversation(id)?.title ?? "空"
                    case .split(let v, let r, let a, let b): return "[\(v ? "上下" : "左右") \(String(format: "%.3f", r)): \(show(a)) | \(show(b))]"
                    }
                }
                var out = st.sessions.flatMap { s in s.windows.map { w in "\(s.name)/\(w.name)：\(w.root.map(show) ?? "-")（紫框＝\(w.focused.flatMap { st.conversation($0)?.title } ?? "-")）" } }
                // 目前 Window 裡每個掛件圖示是亮還是暗（側欄的 shownGadgets 用同一個算法），和 ⌘ ⇧ T 能找回幾個
                let here = Set((st.currentWindow?.root?.leaves ?? []).filter { !PaneSlide.shared.isLeaving($0) })
                out.append("掛件圖示：" + st.conversations.filter(\.isGadget).map { "\($0.title)＝\(here.contains($0.id) ? "亮" : "暗")" }.joined(separator: "、"))
                out.append("可找回的 Window：\(Store.closed.filter { if case .window = $0 { return true } else { return false } }.count)")
                try? out.joined(separator: "\n").write(toFile: String(parts[1]), atomically: true, encoding: .utf8)
            }
        }
        // --pane-slide "秒數:動畫秒數"：掛件格子滑進／滑出的動畫停在第幾秒（負數＝放開，照常跑完）；可以給好幾次
        for (i, a) in args.enumerated() where a == "--pane-slide" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]), let at = Double(parts[1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { PaneSlide.shared.frozen = at < 0 ? nil : at; PaneSlide.shared.onTick?() }
        }
        // --bundle-dump "秒數:檔案"：每段對話的組、掛件框、掛件和網址（測掛件框）
        for (i, a) in args.enumerated() where a == "--bundle-dump" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                guard let st = self.store as Store? else { return }
                let short = { (u: UUID?) in u.map { String($0.uuidString.prefix(4)) } ?? "-" }
                var out = st.conversations.map { c in
                    "\(c.title)\t組=\(st.group(st.groupOf(c))?.name ?? "-")\t框=\(short(c.bundle))\t掛件of=\(short(c.gadgetOf))\t網址=\(c.browser ?? "-")\t在版面=\(st.locate(c.id) != nil)"
                }
                out.append("格子：\(st.currentWindow?.root?.leaves.count ?? 0)")
                let fr = self.main.window?.firstResponder
                let owner = self.workspace.panes.first { (_, v) in (fr as? NSView).map { $0.isDescendant(of: v) } ?? false }
                out.append("版面：" + (st.currentWindow?.root?.leaves ?? []).map { st.conversation($0)?.title ?? "空" }.joined(separator: "｜"))
                if case .split(_, let r, _, _)? = st.currentWindow?.root { out.append("最外層比例：\(String(format: "%.3f", r))") }
                out.append("紫框：\(st.currentWindow?.focused.flatMap { st.conversation($0)?.title } ?? "-")")
                out.append("焦點：\(fr.map { String(describing: type(of: $0)) } ?? "nil") 在 \(owner.flatMap { st.conversation($0.key)?.title } ?? "-")")
                try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        // --set-default-effort "秒數:強度"：像在模型面板把拉桿拉到這段、按「設為預設」（要先 --model-panel 打開面板）
        for (i, a) in args.enumerated() where a == "--set-default-effort" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let v = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
                guard let m = ModelPanelModel.last, let i = m.levels.firstIndex(of: v) else { return }
                m.index = Double(i)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if let e = m.effort { m.onSetDefault?(e) } }
            }
        }
        // --chat-stop "秒數"：幾秒後按停止
        for (i, a) in args.enumerated() where a == "--chat-stop" && i + 1 < args.count {
            guard let sec = Double(args[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.session.interrupt()
            }
        }
        // --chat-text "秒數:檔案"：幾秒後把聊天畫面上的文字（網頁的 innerText）寫進檔案
        for (i, a) in args.enumerated() where a == "--chat-text" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.evaluate("document.body.innerText") { s in try? s.write(toFile: path, atomically: true, encoding: .utf8) }
            }
        }
        // --snapshot "秒數:檔案.png"：幾秒後把整個視窗內容畫成圖片（視窗被蓋住也拍得到最新畫面）
        for (i, a) in args.enumerated() where a == "--snapshot" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let v = self?.main.window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
        // --settings-snapshot "秒數:頁:檔案"：打開設定視窗（頁＝windows、chat、appearance、pet、keys、local、schedules、data）拍成 PNG。測英文介面有沒有漏翻用
        for (i, a) in args.enumerated() where a == "--settings-snapshot" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count == 3, let sec = Double(parts[0]) else { continue }
            let tab = parts[1]
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                appDefaults.set(tab, forKey: "settingsTab")      // 測試實例的偏好，不是正式的
                self?.showSettings()
                guard let w = self?.settings?.window else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    guard let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: parts[2]))
                }
            }
        }
        // --web-snapshot "秒數:檔案"：目前聊天室的網頁拍成 PNG（背景測試時 screencapture 拍不到網頁內容）
        for (i, a) in args.enumerated() where a == "--web-snapshot" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? ChatPane else { return }
                p.snapshotWeb(to: path)
            }
        }
        // --dump "秒數:檔案"：幾秒後把目前那格的尺寸和畫面文字寫進檔案
        for (i, a) in args.enumerated() where a == "--dump" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let path = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self else { return }
                guard let id = self.store.selected, let p = self.workspace.panes[id] as? TerminalPane else { return }
                var out = "pane \(p.frame) terminal \(p.terminal.frame)\n"
                for v in p.subviews { out += "  \(type(of: v)) \(v.frame) hidden \(v.isHidden) sub \(v.subviews.map { "\(type(of: $0))\($0.frame)\($0.isHidden ? "隱" : "")" })\n" }
                p.terminal.withTerminalPublic { t in
                    out += "cols \(t.cols) rows \(t.rows) yDisp \(t.buffer.yDisp)\n"
                    for r in 0..<t.rows { out += (t.getLine(row: r)?.translateToString(trimRight: true) ?? "") + "\n" }
                }
                try? out.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        for (i, a) in args.enumerated() where a == "--send" && i + 1 < args.count {
            let parts = args[i + 1].split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let sec = Double(parts[0]) else { continue }
            let text = String(parts[1]).replacingOccurrences(of: "\\r", with: "\r")
                .replacingOccurrences(of: "\\e", with: "\u{1b}")
                .replacingOccurrences(of: "^X", with: "\u{18}").replacingOccurrences(of: "^S", with: "\u{13}")
            DispatchQueue.main.asyncAfter(deadline: .now() + sec) { [weak self] in
                guard let self, let id = self.store.selected, let p = self.workspace.panes[id] as? TerminalPane else { return }
                p.terminal.send(txt: text)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    // 還有對話在跑：先問一聲，不要直接把正在工作的 Claude 關掉
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let busy = store.status.keys.compactMap { store.conversation($0)?.title }
        guard !busy.isEmpty, !CommandLine.arguments.contains("--background") else { return .terminateNow }
        let a = NSAlert()
        a.messageText = L("還有 \(busy.count) 段對話在進行")
        a.informativeText = L("\(busy.prefix(5).joined(separator: "、"))\n\n結束的話 Claude 會停在做到一半的地方，下次打開可以接著問。")
        a.addButton(withTitle: L("取消"))
        a.addButton(withTitle: L("結束"))
        return a.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ n: Notification) {
        store.saveNow()
        main.saveFrame()   // ⌘ Q 時的位置，下次照這個開
        for p in workspace.panes.values { p.terminate() }
    }

    /// 測試用：把「C-a」「|」「h」這種寫法變成真的按鍵事件丟進 App
    /// 背景測試時自己送的事件要等「下一個事件」來才會被處理：補一個沒作用的事件把它們推出去
    static func flushEvents(_ w: NSWindow) {
        if let e = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber, context: nil, subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(e, atStart: false) }
    }

    /// 在畫面元件樹裡找第一個某種元件（測試用）
    static func find<T: NSView>(_ t: T.Type, in v: NSView?) -> T? {
        guard let v else { return nil }
        if let x = v as? T { return x }
        for c in v.subviews { if let x = find(t, in: c) { return x } }
        return nil
    }

    static func postKey(_ token: String, window: NSWindow) {
        defer { flushEvents(window) }
        let codes: [Character: UInt16] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
            "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "-": 27,
            "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46]
        let shifted: [Character: Character] = ["|": "\\", "&": "7", "$": "4", "(": "9", ")": "0", "?": "/"]
        var mods: NSEvent.ModifierFlags = []
        var ch = Character(token.last.map(String.init) ?? " ")
        if token.hasPrefix("C-") { mods.insert(.control) }
        if token.hasPrefix("D-") { mods.insert(.command) }   // D-1＝⌘ 1（測 Window 切換）
        if token.contains("S-") { mods.insert(.shift) }      // D-S-z＝⌘ ⇧ Z
        if token == "Esc" {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)
            if let e { NSApp.postEvent(e, atStart: false) }
            return
        }
        // 特殊鍵：Tab、↑、↓（測 / 選單）、Ret＝Enter（測程式碼區的 cin）
        let special: [String: (UInt16, String)] = ["Tab": (48, "\t"), "Down": (125, "\u{F701}"), "Up": (126, "\u{F700}"), "Left": (123, "\u{F702}"), "Right": (124, "\u{F703}"), "BS": (51, "\u{7F}"), "Ret": (36, "\r")]
        // 方向鍵可以加 C-（⌃ ←，測 ⌃ A 之後 ⌃ 沒放開）、D-（⌘ ↑，測輸入框跳到最前）
        let arrowMod = (token.hasPrefix("C-") || token.hasPrefix("D-")) && ["Left", "Right", "Up", "Down"].contains(String(token.dropFirst(2)))
        if let (code, chars) = special[arrowMod ? String(token.dropFirst(2)) : token] {
            var flags: NSEvent.ModifierFlags = code >= 123 && code <= 126 ? [.function, .numericPad] : []
            if arrowMod { flags.insert(token.hasPrefix("C-") ? .control : .command) }
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
            if let e { NSApp.postEvent(e, atStart: false) }
            return
        }
        if token == "C-Ret" {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
            if let e { NSApp.postEvent(e, atStart: false) }
            return
        }
        if token == "D-Ret" {   // ⌘ Enter（測問答卡片「其他」欄送出）
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
            if let e { NSApp.postEvent(e, atStart: false) }
            return
        }
        if token == "M-Up" || token == "M-Down" {   // ⌘ ↑／⌘ ↓
            let up = token == "M-Up", ch = up ? "\u{F700}" : "\u{F701}"
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: up ? 126 : 125)
            if let e { NSApp.postEvent(e, atStart: false) }
            return
        }
        if token == "S-Tab" {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\u{19}", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)
            if let e { NSApp.postEvent(e, atStart: false) }
            return
        }
        var shown = String(ch)
        if mods.contains(.shift), ch.isLetter { shown = shown.uppercased() }   // 真的鍵盤按 ⌘ ⇧ Z 送的是大寫 Z
        if let base = shifted[ch] { mods.insert(.shift); ch = base }
        guard let code = codes[ch] else { return }
        if mods.contains(.control) { shown = String(UnicodeScalar(UInt8(ch.asciiValue! & 0x1f))) }
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: window.windowNumber, context: nil, characters: shown,
                                 charactersIgnoringModifiers: mods.contains(.shift) ? shown : String(ch), isARepeat: false, keyCode: code)
        if let e { NSApp.postEvent(e, atStart: false) }
    }

    /// ⌘ W：關設定、整理對話這類小視窗；在主視窗是關掉目前的 Window（跟 ⌃ W 一樣，對話留在側欄），主視窗本身不關
    @objc func closeSideWindow() {
        guard let w = NSApp.keyWindow else { return NSSound.beep() }
        if w === main.window { store.closePaneOrWindow() } else { w.performClose(nil) }
    }

    /// ⌘ ⇧ T：找回剛關掉的格子或 Window（主視窗裡由 PrefixKeys 先攔；這裡給選單點、或焦點在小視窗時用）
    @objc func newTabWindow() { main.newWindow() }
    @objc func reopenWindow() {
        if !store.reopenClosedWindow() { NSSound.beep() }
    }

    @objc func showSettings() {
        if settings == nil { settings = SettingsWindowController(store: store, appearance: appearance) }
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func checkForUpdates() { UpdateCheck.shared.check(manual: true) }
    @objc func showFeedback() { Feedback.present() }

    @objc func newConversation() { main.newConversation() }
    @objc func newBrowser() { main.newBrowser() }
    @objc func togglePetSlot() { PetSlot.enabled.toggle() }
    @objc func toggleSidebar() { main.toggleSidebar() }
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
        fileMenu.addItem(withTitle: L("新瀏覽器"), action: #selector(newBrowser), keyEquivalent: "B")   // 大寫＝⌘ ⇧ B
        let add = fileMenu.addItem(withTitle: L("新增專案…"), action: #selector(addProject), keyEquivalent: "o")
        add.keyEquivalentModifierMask = [.command, .shift]
        let imp = fileMenu.addItem(withTitle: L("從 Claude Code 匯入對話…"), action: #selector(showImporter), keyEquivalent: "i")
        imp.keyEquivalentModifierMask = [.command, .shift]
        let org = fileMenu.addItem(withTitle: L("整理對話…"), action: #selector(showOrganizer), keyEquivalent: "l")
        org.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: L("關閉這格（只剩一格時關掉這個 Window）"), action: #selector(closeSideWindow), keyEquivalent: "w")
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
        let side = viewMenu.addItem(withTitle: L("收起／打開側欄"), action: #selector(toggleSidebar), keyEquivalent: "s")
        side.keyEquivalentModifierMask = [.command, .control]
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

        if Feedback.available {
            let helpItem = NSMenuItem(); menu.addItem(helpItem)
            let helpMenu = NSMenu(title: L("說明"))
            helpMenu.addItem(withTitle: L("回報問題…"), action: #selector(showFeedback), keyEquivalent: "")
            helpItem.submenu = helpMenu
            NSApp.helpMenu = helpMenu
        }
        NSApp.mainMenu = menu
    }
}

let app = KeyStatsApp.shared   // 按鍵統計：按鍵先經過它（KeyStats.swift）
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
