import SwiftUI
import AppKit

// 側欄對話右鍵「關於…」：這段聊天室的位置和其他資訊（原本放在每一格最下面的路徑列，現在路徑列固定隱藏）。
// 工作資料夾、紀錄檔可以在 Finder 顯示或拷貝；session ID 可以拷貝。

struct AboutChatView: View {
    let c: Conversation
    let folder: String
    let transcript: URL
    @ObservedObject var context = ContextMonitor.shared

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
    private var created: String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return f.string(from: c.createdAt)
    }
    private var contextText: String {
        guard let n = context.tokens[c.id] else { return L("（還沒有紀錄）") }
        return "\(ContextMonitor.text(n)) tokens（\(n)）"
    }
    private var modelText: String { c.model.map { $0.isEmpty ? L("預設") : $0 } ?? L("預設") }

    @ViewBuilder private func row(_ label: String, _ value: String, buttons: [(String, () -> Void)] = []) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).font(.system(size: 12.5, design: .monospaced)).lineLimit(3).truncationMode(.middle)
            if !buttons.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(buttons.enumerated()), id: \.offset) { _, b in Button(b.0, action: b.1).controlSize(.small) }
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(c.title).font(.headline).lineLimit(2)
            row(L("工作資料夾"), folder, buttons: [(L("在 Finder 顯示"), { reveal(folder) }), (L("拷貝路徑"), { copy(folder) })])
            row(L("模型"), modelText)
            row(L("Session ID"), c.claudeSession.uuidString.lowercased(), buttons: [(L("拷貝"), { copy(c.claudeSession.uuidString.lowercased()) })])
            row(L("紀錄檔"), transcript.path, buttons: [(L("在 Finder 顯示"), { reveal(transcript.path) }), (L("拷貝路徑"), { copy(transcript.path) })])
            row(L("建立時間"), created)
            row(L("上下文大小"), contextText)
        }
        .padding(18)
        .frame(width: 460, alignment: .leading)
    }
}

extension MainWindowController {
    /// 「關於…」小視窗（同一段對話只開一個）
    func showAbout(_ id: UUID) {
        guard let c = store.conversation(id), !c.isBrowser else { return }
        if let w = Self.aboutWindows[id] { w.makeKeyAndOrderFront(nil); return }
        let folder = store.project(c.projectID)?.path ?? NSHomeDirectory()
        ContextMonitor.shared.load(c, path: folder)
        let host = NSHostingController(rootView: AboutChatView(c: c, folder: folder, transcript: ContextMonitor.transcript(c, path: folder)))
        let w = NSPanel(contentViewController: host)
        w.title = L("關於這個聊天室")
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.hidesOnDeactivate = false
        w.center()
        // 視窗關掉時把自己的觀察者也移掉（token 要存下來，不然每開一次「關於…」就多留一個）
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            Self.aboutWindows[id] = nil
            if let token { NotificationCenter.default.removeObserver(token) }
        }
        Self.aboutWindows[id] = w
        w.makeKeyAndOrderFront(nil)
    }
    private static var aboutWindows: [UUID: NSWindow] = [:]
}
