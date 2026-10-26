import Foundation

// 打開 App（包括 ⌘ Q 之後再開）時，把版面裡每一格聊天的 Claude 先開起來，不送訊息。
// 原本要等那格送出第一則才開 claude，沒開的格子別的聊天室就聯絡不到（ListAgents 看不到）。
// claude 用聊天室的名字開（ChatSession.nameProvider → --name），重開後名字不變。

extension MainWindowController {
    func reconnectPlaced() {
        guard Prefs.shared.reconnectOnLaunch else { return }
        var ids: [UUID] = []
        for s in store.sessions { for w in s.windows { for id in w.root?.leaves ?? [] where !ids.contains(id) { ids.append(id) } } }
        let convs = ids.compactMap { store.conversation($0) }.filter { $0.terminal != true && !$0.isBrowser && $0.draft != true && !store.isArchived($0) }
        // 一格隔一秒，不要同時開一堆 claude
        for (i, c) in convs.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 + Double(i)) { [weak self] in
                guard let self, self.store.conversation(c.id) != nil, let p = self.workspace.pane(for: c) as? ChatPane else { return }
                p.warmStart()
            }
        }
    }
}

extension ChatPane {
    /// 先把 claude 開起來（接回原本的對話），不送訊息。沒有紀錄檔的（還沒聊過）、本機模型的不開。
    /// 正在別處跑的（claude 的執行登記查得到）不開；只看「紀錄檔 3 分鐘內被寫過」那條不算：⌘ Q 馬上重開時，寫的人就是剛結束的自己
    func warmStart() {
        guard !session.isRunning, session.forkFrom == nil, session.localEndpoint == nil,
              Store.claudeHasSession(session.claudeSession, path: session.directory) else { return }
        if let l = liveElsewhere(), l.kind != "recent" { return }
        session.start()
        ownSessionStarted()
    }
}
