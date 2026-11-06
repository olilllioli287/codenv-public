import Foundation
import Combine

// 新對話草稿：側欄「新對話」（⌘ N）開的對話先當草稿，只列在「最近項目」。
// 送出第一則、或已經有 Claude 的紀錄檔，就變成一般對話；
// 一句都沒聊、又沒擺在任何一格（被換掉、格子關掉）也不是目前選的，就自動刪掉。

private final class DraftWatcher {
    var bag: Set<AnyCancellable> = []
    var work: DispatchWorkItem?
}

extension MainWindowController {
    private static var draftWatcher: DraftWatcher?

    /// 開始監看草稿（init 結尾叫一次）
    func watchDrafts() {
        let w = DraftWatcher()
        Self.draftWatcher = w
        // store 有變動就稍等一秒，合併成一次檢查
        store.objectWillChange.sink { [weak self, weak w] _ in
            guard let w else { return }
            w.work?.cancel()
            let item = DispatchWorkItem { self?.sweepDrafts() }
            w.work = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
        }.store(in: &w.bag)
        // 送出訊息：那段對話就不是草稿了
        NotificationCenter.default.publisher(for: ChatPane.didSend).sink { [weak self] n in
            guard let self, let sid = n.object as? UUID,
                  let i = self.store.conversations.firstIndex(where: { $0.claudeSession == sid && $0.draft == true }) else { return }
            self.store.conversations[i].draft = nil
        }.store(in: &w.bag)
        DispatchQueue.main.async { [weak self] in self?.sweepDrafts() }   // App 一開也清一次
    }

    func sweepDrafts() {
        for c in store.conversations where c.draft == true {
            let path = store.project(c.projectID)?.path ?? NSHomeDirectory()
            // 任何一家的紀錄檔有了，就不是空草稿（agy、Codex、Copilot、本機、Apple 的紀錄不在 Claude 的資料夾）
            let others = [AgyBridge.transcript(for: c.claudeSession), CodexBridge.transcript(for: c.claudeSession), CopilotBridge.transcript(for: c.claudeSession),
                          LocalBridge.transcript(for: c.claudeSession), AppleBridge.transcript(for: c.claudeSession)]
            if Store.claudeHasSession(c.claudeSession, path: path) || others.contains(where: { FileManager.default.fileExists(atPath: $0.path) })
                || FileManager.default.fileExists(atPath: OutboxPersistence(directory: store.directory, conversationID: c.id).fileURL.path)
                || OutboxPersistence(directory: store.directory, conversationID: c.id).hasLeftovers {
                if let i = store.conversations.firstIndex(where: { $0.id == c.id }) { store.conversations[i].draft = nil }
            } else if store.locate(c.id) == nil, store.selected != c.id, store.status[c.id] == nil,
                      (workspace.panes[c.id] as? ChatPane)?.inputBar.hasPendingInput != true,   // 打了字還沒送的草稿不刪
                      // 格子關了、或重開 App 還沒開格子：輸入框看不到，改看磁碟上的草稿檔（DraftPersistence；Astra 11/5：原本會連草稿檔一起刪）
                      !FileManager.default.fileExists(atPath: DraftPersistence(directory: store.directory, conversationID: c.id).fileURL.path),
                      !DraftPersistence(directory: store.directory, conversationID: c.id).hasQuarantined,   // 讀不懂隔離起來的草稿（含新版 .bad-時間）
                      (workspace.panes[c.id] as? ChatPane)?.isBangRunning != true,              // ! 指令還在跑、或已經有指令紀錄的不刪（紀錄放在自己的檔，不算 AI 對話）
                      (workspace.panes[c.id] as? ChatPane)?.codeLab?.hasUnsaved != true,        // 程式碼區有沒存的修改：刪掉會繞過存檔
                      BangStore.load(c.id).isEmpty {
                deleteConversation(c.id)
            }
        }
    }
}
