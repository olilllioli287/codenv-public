import AppKit

extension MainWindowController {
    /// 紀錄檔與標記檔：測試實例（--state-dir）放在暫存資料夾，不動 ~/Library/Logs 和正式資料
    static func lidPaths() -> (log: URL, marker: URL) {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--state-dir"), i + 1 < a.count {
            let d = URL(fileURLWithPath: a[i + 1])
            return (d.appendingPathComponent("codenv-lid.log"), d.appendingPathComponent("lid-hold.json"))
        }
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/codenv-lid.log")
        return (logs, Edition.support("lid-hold.json"))
    }

    func setupLidKeeper() {
        let paths = Self.lidPaths()
        // 測試實例（暫存 state-dir 或 --background）絕不連真的小幫手：它們的假 claude 一直「工作中」，會搶走正式 codenv 的 nosleep、
        // 被殺時連線一斷還把 disablesleep 改回 0（實測闔蓋失敗的原因）。只有正式實例才接真硬體
        let args = CommandLine.arguments
        let isTest = args.contains("--state-dir") || args.contains("--background") || args.contains("--lid-sim")
        let sim = isTest ? SimLidEnv() : nil
        let keeper = LidKeeper(env: sim ?? RealLidEnv(), logURL: paths.log, markerURL: paths.marker)
        sim?.onCall = { [weak keeper] s in keeper?.log(s) }
        keeper.enabled = { Prefs.shared.lidKeepWorking }
        keeper.resumeEnabled = { Prefs.shared.lidResumeNotifyEnabled }
        keeper.workingIDs = { [weak self] in
            guard let self else { return [] }
            return self.store.conversations.filter { Store.isChat($0) && self.store.status[$0.id] == .working }.map(\.id)
        }
        keeper.workingCount = { [weak keeper] in keeper?.workingIDs().count ?? 0 }
        keeper.sendStop = { [weak self] id in
            guard let pane = self?.workspace.panes[id] as? ChatPane else { return false }
            return pane.sendText(LidKeeper.stopMessage)
        }
        keeper.sessionIsAvailable = { [weak self] id in
            guard let self, let conversation = self.store.conversation(id), Store.isChat(conversation) else { return false }
            return self.workspace.panes[id] is ChatPane
        }
        keeper.sessionIsArchived = { [weak self] id in
            guard let self, let conversation = self.store.conversation(id) else { return true }
            return self.store.isArchived(conversation)
        }
        keeper.sendResume = { [weak self] id in
            guard let pane = self?.workspace.panes[id] as? ChatPane else { return }
            _ = pane.sendText(LidKeeper.resumeMessage)
        }
        keeper.notify = { [weak self] title, detail in
            // 測試實例不跳視窗，只記一行
            if CommandLine.arguments.contains("--state-dir") { keeper.log("（測試）會提醒：\(title)｜\(detail.replacingOccurrences(of: "\n", with: " "))"); return }
            guard let w = self?.window, w.attachedSheet == nil else { return }
            let a = NSAlert(); a.alertStyle = .warning
            a.messageText = title; a.informativeText = detail
            a.addButton(withTitle: L("好"))
            a.beginSheetModal(for: w)
        }
        keeper.recoverIfNeeded()
        lidKeeper = keeper
        // 預擋中（螢幕開著先擋住睡眠）約 1 秒看一次有沒有闔蓋；平常 3 秒看一次
        var n = 0
        lidTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak keeper] _ in
            guard let keeper else { return }
            n += 1
            if keeper.noSleepOn || keeper.isHolding || keeper.workingCount() > 0 ? n % 3 == 0 : n % 10 == 0 { keeper.tick() }
        }
    }
}
