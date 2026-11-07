import AppKit

// 右欄（RightPanelView）跟主視窗的掛鉤：協作看板的開關在總指揮模式改成「打開右欄並選看板」。

extension MainWindowController {
    var commanderMode: Bool { Prefs.shared.sidebarMode == "commander" }

    /// 打開協作看板：樹模式開右邊那一欄；總指揮模式打開右欄並選「看板」分頁
    func openCollabBoard() {
        guard commanderMode else { CollabBoardModel.shared.open = true; return }
        showRightPanel(tab: .board)
    }

    /// 左側協作圖示、八宮格「協作」：開／關看板
    func toggleCollabBoard() {
        guard commanderMode else { CollabBoardModel.shared.open.toggle(); return }
        if RightPanelModel.shared.boardShown { setRightPanel(on: false) } else { showRightPanel(tab: .board) }
    }

    func showRightPanel(tab: RightTab) {
        RightPanelModel.shared.tab = tab
        if !PetSlot.enabled { setRightPanel(on: true) }
    }

    /// 跟 F4 同一套滑動（WindowHost 聽這兩個通知）
    private func setRightPanel(on: Bool) {
        NotificationCenter.default.post(name: .rightPanelToggleWillBegin, object: nil)
        PetSlot.enabled = on
        NotificationCenter.default.post(name: .rightPanelToggled, object: nil)
    }
}

// MARK: 聊天室資訊：按 i
extension MainWindowController {
    private static var chatInfoKeyMonitor: Any?

    /// 右欄有焦點（焦點在右欄那個 SwiftUI 視圖裡）、有選取的聊天室、沒在打字時，按 i（不帶修飾鍵）打開「聊天室資訊」
    func installChatInfoKey() {
        guard Self.chatInfoKeyMonitor == nil else { return }
        Self.chatInfoKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.charactersIgnoringModifiers == "i", e.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  let w = self.window, e.window === w || e.windowNumber == w.windowNumber,
                  w.attachedSheet == nil, self.commanderMode else { return e }
            let m = RightPanelModel.shared
            guard m.tab == .windows, m.infoChat == nil, let id = m.selectedChat, self.store.conversation(id) != nil, self.rightPanelHasFocus(w) else { return e }
            ChatInfoCard.shared.cancel()
            m.infoChat = id
            return nil
        }
    }

    /// 焦點是不是在右欄的 SwiftUI 視圖裡（輸入框、網頁、終端機都不是）
    func rightPanelHasFocus(_ w: NSWindow) -> Bool {
        if let t = w.firstResponder as? NSTextView, t.isEditable || t.isFieldEditor { return false }
        guard var v = w.firstResponder as? NSView else { return false }
        while true {
            if String(describing: type(of: v)).contains("RightPanelView") { return true }
            guard let up = v.superview else { return false }
            v = up
        }
    }

    /// 測試用：把焦點交給右欄（等於點了右欄的列之後的狀態；不 activate、不 makeKey）
    func focusRightPanelForTest() {
        guard let w = window, let root = w.contentView else { return }
        func find(_ v: NSView) -> NSView? {
            if String(describing: type(of: v)).contains("RightPanelView") { return v }
            for s in v.subviews { if let f = find(s) { return f } }
            return nil
        }
        if let h = find(root) { w.makeFirstResponder(h) }
    }
}
