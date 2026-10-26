import SwiftUI
import AppKit

// 「從 Claude Code 匯入對話」視窗：列出 ~/.claude/projects 裡的對話，勾選後加進側欄。
// 正在 iTerm／tmux 裡進行的排在最前面；打開它們時工作台會同步顯示（ChatPane 的 checkLive）。

final class ImportModel: ObservableObject {
    @Published var sessions: [ExternalSession] = []
    @Published var picked: Set<UUID> = []
    @Published var search = ""
    @Published var onlyLive = false
    @Published var includeTemp = false { didSet { reload() } }
    @Published var loading = false

    func reload() {
        loading = true
        let temp = includeTemp
        DispatchQueue.global(qos: .userInitiated).async {
            let list = ClaudeSessions.scan(includeTemp: temp)
            DispatchQueue.main.async {
                // 正在進行的排前面，其餘照最後更新時間
                self.sessions = list.filter { $0.live != nil } + list.filter { $0.live == nil }
                self.loading = false
            }
        }
    }
}

struct ImportView: View {
    @ObservedObject private var prefs = Prefs.shared   // 跟設定頁同一個開關（以前各存一份會不同步）
    @ObservedObject var model: ImportModel
    @ObservedObject var store: Store
    var close: () -> Void

    private var shown: [ExternalSession] {
        model.sessions.filter { s in
            (!model.onlyLive || s.live != nil) &&
            (model.search.isEmpty || s.title.localizedCaseInsensitiveContains(model.search) || s.cwd.localizedCaseInsensitiveContains(model.search))
        }
    }

    private func imported(_ s: ExternalSession) -> Bool { store.conversations.contains { $0.claudeSession == s.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("從 Claude Code 匯入對話")).font(.title2.weight(.semibold))
            Text(L("在 iTerm／tmux 開過的 Claude 對話。匯入後在工作台打開會接著原本的對話；還在那邊進行的，這裡會同步顯示，結束後（或按「在這裡接手」複製一份）就能在這裡繼續。"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField(L("搜尋標題或資料夾"), text: $model.search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Toggle(L("只看正在進行的"), isOn: $model.onlyLive)
                Toggle(L("包含暫存資料夾"), isOn: $model.includeTemp)
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                Button(L("重新整理")) { model.reload() }
            }
            List(shown) { s in
                let done = imported(s)
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(get: { done || model.picked.contains(s.id) },
                                             set: { on in if on { model.picked.insert(s.id) } else { model.picked.remove(s.id) } }))
                        .labelsHidden().disabled(done)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(s.title).lineLimit(1)
                            if let l = s.live {
                                Text(l.tmux.isEmpty ? L("進行中") : L("進行中 · \(l.tmux)"))
                                    .font(.caption.weight(.medium)).foregroundStyle(.white)
                                    .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Color.green.opacity(0.8)))
                            }
                            if done { Text(L("已在工作台")).font(.caption).foregroundStyle(.secondary) }
                        }
                        Text((s.cwd as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(s.modified, style: .relative).font(.caption).foregroundStyle(.secondary)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(s.size), countStyle: .file)).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 2)
            }
            HStack {
                Toggle(L("自動加入正在 tmux／iTerm 裡進行的對話（每 30 秒檢查）"), isOn: $prefs.autoImportLive)
                Spacer()
                Button(L("選取全部進行中的")) {
                    for s in model.sessions where s.live != nil && !imported(s) { model.picked.insert(s.id) }
                }
                Button(L("取消")) { close() }.keyboardShortcut(.cancelAction)
                Button(L("匯入 \(model.picked.count) 段")) {
                    store.importSessions(model.sessions.filter { model.picked.contains($0.id) })
                    model.picked.removeAll()
                    close()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.picked.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 820, height: 600)
        .onAppear { model.reload() }
    }
}

final class ImportWindowController: NSWindowController {
    let model = ImportModel()
    init(store: Store) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = L("匯入對話")
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.contentViewController = NSHostingController(rootView: ImportView(model: model, store: store, close: { [weak w] in w?.close() }))
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }
}

extension ClaudeSessions {
    /// 自動同步：把正在跑、工作台還沒有的對話加進來（只看正在跑的，很快）
    static func importLive(into store: Store) {
        let live = live()
        let missing = live.keys.filter { id in !store.conversations.contains { $0.claudeSession == id } }
        guard !missing.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            let all = scan()
            let list = all.filter { missing.contains($0.id) }
            DispatchQueue.main.async { if !list.isEmpty { store.importSessions(list) } }
        }
    }
}
