import AppKit

// 輸入框底排橘色收納鈕的選單：作用在「同一個 Window 裡的瀏覽器格」。
//   請 Claude 比對瀏覽器那格：把一句話放進這個輸入框（只放、不送出）
//   截圖回報給 codenv_1（私人版）／回報問題…（公版）：私人版把那一格的截圖加主機名稱和時間當成一則附圖訊息送到「codenv_1」聊天室
//     （找不到就放進目前輸入框）；公版產生回報檔（Feedback.swift）
//   匯出 Gemini 對話：沿用 BrowserPane.exportChat
// 同一個 Window 有好幾個瀏覽器格就讓使用者選（子選單）；一個都沒有就整排反灰。

extension Workspace {
    /// 這段聊天室所在的 Window 裡的瀏覽器格（沒有畫面的不算）
    func browserPanes(inWindowOf cid: UUID) -> [(id: UUID, pane: BrowserPane)] {
        guard Prefs.shared.webFeaturesEnabled, let (si, wi) = store.locate(cid) else { return [] }
        let leaves = store.sessions[si].windows[wi].root?.leaves ?? []
        return leaves.compactMap { id in
            guard let c = store.conversation(id), c.isBrowser, let p = panes[id] as? BrowserPane else { return nil }
            return (id, p)
        }
    }

    private func label(_ id: UUID, _ p: BrowserPane) -> String {
        let name = store.conversation(id)?.title ?? ""
        let host = p.webView.url?.host ?? ""
        if name.isEmpty && host.isEmpty { return L("瀏覽器格") }
        return host.isEmpty ? name : name.isEmpty ? host : "\(name) · \(host)"
    }

    /// 選單（測試也用它看每一項的文字與反灰狀態）
    func toolsMenu(for cid: UUID, chat: ChatPane) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard Prefs.shared.webFeaturesEnabled else { return menu }
        let targets = browserPanes(inWindowOf: cid)
        if targets.isEmpty {
            let h = NSMenuItem(title: L("這個 Window 沒有瀏覽器格"), action: nil, keyEquivalent: "")
            h.isEnabled = false
            menu.addItem(h)
        }
        let reportTitle = Edition.isPublic ? L("回報問題…") : L("截圖回報給 codenv_1")
        let showReport = !Edition.isPublic || Feedback.available
        let entries: [(title: String, show: Bool, enabled: (BrowserPane) -> Bool, run: (UUID, BrowserPane) -> Void)] = [
            (L("請 Claude 比對瀏覽器那格"), true, { _ in true }, { [weak self, weak chat] id, p in if let chat { self?.askCompare(id: id, pane: p, chat: chat) } }),
            (reportTitle, showReport, { _ in true }, { [weak self, weak chat] id, p in if let chat { self?.report(id: id, pane: p, chat: chat) } }),
            (L("匯出 Gemini 對話"), true, { GeminiExport.isConversation($0.webView.url) }, { _, p in p.exportChat() }),
        ]
        for e in entries where e.show {
            let item = NSMenuItem(title: e.title, action: nil, keyEquivalent: "")
            let usable = targets.filter { e.enabled($0.pane) }
            item.isEnabled = !usable.isEmpty
            if targets.count > 1 {
                // 好幾個瀏覽器格：子選單讓使用者選（不能用的反灰）
                let sub = NSMenu(); sub.autoenablesItems = false
                for t in targets {
                    let si = NSMenuItem(title: label(t.id, t.pane), action: #selector(ToolsMenuTarget.fire(_:)), keyEquivalent: "")
                    let tgt = ToolsMenuTarget { if Prefs.shared.webFeaturesEnabled { e.run(t.id, t.pane) } }
                    si.target = tgt; si.representedObject = tgt
                    si.isEnabled = e.enabled(t.pane)
                    sub.addItem(si)
                }
                item.submenu = sub
            } else if let t = targets.first {
                item.action = #selector(ToolsMenuTarget.fire(_:))
                let tgt = ToolsMenuTarget { if Prefs.shared.webFeaturesEnabled { e.run(t.id, t.pane) } }
                item.target = tgt; item.representedObject = tgt
            }
            menu.addItem(item)
        }
        return menu
    }

    func popUpToolsMenu(for cid: UUID, chat: ChatPane, from view: NSView) {
        guard Prefs.shared.webFeaturesEnabled else { return }
        let menu = toolsMenu(for: cid, chat: chat)
        // 在鈕的上方展開（鈕在視窗最下面）
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    // MARK: 比對

    /// 只把這句話放進這個輸入框、不送出
    func askCompare(id: UUID, pane: BrowserPane, chat: ChatPane) {
        guard Prefs.shared.webFeaturesEnabled else { return }
        let name = store.conversation(id)?.title ?? ""
        let host = pane.webView.url?.host ?? ""
        let title = pane.currentTitle
        chat.inputBar.putText(L("看一下瀏覽器那格（\(name)，\(host)），\(title) 的回答講得對不對，跟你自己的看法比對"))
        chat.window?.makeFirstResponder(chat.inputBar.textView)
    }

    // MARK: 回報

    func report(id: UUID, pane: BrowserPane, chat: ChatPane) {
        guard Prefs.shared.webFeaturesEnabled else { return }
        if Edition.isPublic {
            Feedback.present(browser: pane, browserName: store.conversation(id)?.title, over: chat.window)
            return
        }
        pane.snapshot { [weak self, weak chat] data in
            guard let self, let chat else { return }
            let host = pane.webView.url?.host ?? ""
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let name = self.store.conversation(id)?.title ?? ""
            let text = L("瀏覽器格回報（\(name)，\(host)，\(f.string(from: Date()))）：這一格現在的畫面如附圖，請看一下。")
            self.deliverReport(text: text, png: data, chat: chat)
        }
    }

    /// 私人版：送到「codenv_1」聊天室；找不到、就是這一格自己、或被擋下（對話在別處進行、agy 沒網）就放進目前輸入框
    func deliverReport(text: String, png: Data?, chat: ChatPane) {
        let candidates = store.conversations.filter { $0.title == "codenv_1" && !$0.isGadget && !$0.isBrowser && $0.terminal != true }
        // 有好幾個叫 codenv_1：優先用已經開著的那個
        let target = candidates.first { panes[$0.id] is ChatPane } ?? candidates.first
        let fallback: (String) -> Void = { why in
            // 輸入框裡選著草稿文字的話，attach 會把選取的字換成截圖標記：先把游標放到最後面，截圖和回報文字一律接在後面
            let tv = chat.inputBar.textView
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            if let png, let img = NSImage(data: png) { chat.inputBar.attach(urls: [], images: [img]) }
            chat.inputBar.putText(text)
            chat.window?.makeFirstResponder(chat.inputBar.textView)
            Toast.show(why, over: chat.window)
            ToolsTestLog.note("\(why)：\(text)（附圖 \(png?.count ?? 0) bytes）")
        }
        guard let t = target else { return fallback(L("找不到 codenv_1 聊天室，已放進這個輸入框")) }
        guard let p = panes[t.id] as? ChatPane else { return fallback(L("codenv_1 聊天室還沒開啟，已放進這個輸入框")) }
        if p === chat { return fallback(L("這裡就是 codenv_1，已放進這個輸入框")) }
        if p.sendReport(text: text, images: png.map { [(data: $0, mediaType: "image/png")] } ?? []) {
            Toast.show(L("已送到 codenv_1"), over: chat.window)
            ToolsTestLog.note("回報已送到 codenv_1 聊天室：\(text)（附圖 \(png?.count ?? 0) bytes）")
        } else {
            fallback(L("codenv_1 聊天室現在送不出去，已放進這個輸入框"))
        }
    }
}

/// NSMenuItem 的動作包成一個物件（菜單項目的 target 不會被持有，所以也放進 representedObject）
final class ToolsMenuTarget: NSObject {
    private let action: () -> Void
    init(_ a: @escaping () -> Void) { action = a }
    @objc func fire(_ sender: Any?) { action() }
}

/// 測試用：帶 --state-dir 並設 CODENV_TOOLS_TEST_LOG 時，把動作記進那個檔案
enum ToolsTestLog {
    static func note(_ s: String) {
        guard CommandLine.arguments.contains("--state-dir"), let path = ProcessInfo.processInfo.environment["CODENV_TOOLS_TEST_LOG"] else { return }
        let line = s + "\n"
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() } else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
    }
}
