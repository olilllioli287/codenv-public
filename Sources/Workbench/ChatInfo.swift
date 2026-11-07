import SwiftUI
import AppKit

// 聊天室資訊：右欄單擊選取（紫框）→ 按 i 或點 ⓘ 開「聊天室資訊」表單（名稱＋說明，像 Discord 頻道設定的名稱與主題）；
// 滑鼠在某一列停 1.5 秒，主視窗正中央浮出資訊卡（名稱、說明、模型、狀態、資料夾、所屬總指揮），離開就收，不搶焦點、不擋輸入。

/// 表單的名稱欄：打開時全文已選取（像 ⌘ A 之後），直接打字就取代
struct SelectAllField: NSViewRepresentable {
    @Binding var text: String
    var size: CGFloat = 13
    var onCommit: () -> Void = {}

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField(string: text)
        f.font = .systemFont(ofSize: size)
        f.delegate = context.coordinator
        f.lineBreakMode = .byTruncatingTail
        f.cell?.isScrollable = true
        DispatchQueue.main.async {
            guard let w = f.window else { return }
            w.makeFirstResponder(f)
            f.currentEditor()?.selectAll(nil)
        }
        return f
    }
    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.currentEditor() == nil, f.stringValue != text { f.stringValue = text }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SelectAllField
        init(_ p: SelectAllField) { parent = p }
        func controlTextDidChange(_ n: Notification) {
            if let f = n.object as? NSTextField { parent.text = f.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.insertNewline(_:)) { parent.onCommit(); return true }
            return false
        }
    }
}

/// 「聊天室資訊」表單
struct ChatInfoForm: View {
    @Environment(\.uiScale) private var s
    @ObservedObject var store: Store
    let id: UUID
    var close: () -> Void
    @State private var name = ""
    @State private var topic = ""
    @State private var loaded = false

    private var remaining: Int { Store.topicLimit - topic.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("聊天室資訊")).font(.system(size: 14 * s, weight: .semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text(L("名稱")).font(.system(size: 10.5 * s, weight: .semibold)).foregroundStyle(.secondary)
                SelectAllField(text: $name, size: 13 * s, onCommit: save)
                    .frame(height: 24 * s)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(L("說明")).font(.system(size: 10.5 * s, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(remaining)").font(.system(size: 10.5 * s)).monospacedDigit()
                        .foregroundStyle(remaining < 50 ? Color.orange : Color.secondary)
                }
                TextEditor(text: $topic)
                    .font(.system(size: 12.5 * s))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(height: 130 * s)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
                    .onChange(of: topic) { _, v in if v.count > Store.topicLimit { topic = String(v.prefix(Store.topicLimit)) } }
                Text(L("這個聊天室負責什麼。聊天室自己的 Claude 會在系統提示看到「你負責：…」，總指揮的名單和滑鼠停留的資訊卡也會顯示。"))
                    .font(.system(size: 10 * s)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(L("取消")) { close() }.keyboardShortcut(.cancelAction)
                Button(L("儲存")) { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 360 * s)
        .onAppear {
            guard !loaded, let c = store.conversation(id) else { return }
            loaded = true
            name = c.title
            topic = c.topic ?? ""
        }
    }

    private func save() {
        guard let c = store.conversation(id) else { return close() }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty, n != c.title { store.rename(id, to: n, byUser: true) }   // 走使用者改名同一條（byUser）
        if Store.cleanTopic(topic) != Store.cleanTopic(c.topic ?? "") { store.setTopic(id, topic, byUser: true) }
        close()
    }
}

/// 資訊卡本體
struct ChatInfoCardView: View {
    let name: String
    let topic: String?
    let rows: [(String, String)]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name).font(.system(size: 16, weight: .semibold)).lineLimit(2)
            if let t = topic, !t.isEmpty {
                Text(t).font(.system(size: 13)).foregroundStyle(.primary.opacity(0.9))
                    .lineLimit(14).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L("（還沒有說明。選取這個聊天室按 i 可以寫）")).font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(r.0).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                        Text(r.1).font(.system(size: 11.5)).lineLimit(2).truncationMode(.middle)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 380, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.18)))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
    }
}

/// 點不到的疊層：滑鼠、鍵盤都穿過去，不擋輸入
private final class PassthroughHost<V: View>: NSHostingView<V> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}

/// 在主視窗正中央浮出／收起資訊卡（加在 contentView 上的子視圖，不是另一個視窗：不搶焦點）
final class ChatInfoCard {
    static let shared = ChatInfoCard()
    private var host: NSView?
    private var pending: DispatchWorkItem?
    private(set) var shownFor: UUID?
    /// 滑鼠停多久才浮出
    static var delay: TimeInterval = 1.5

    /// 滑鼠進入某列：停滿 delay 秒就浮出
    func hoverBegan(_ id: UUID, store: Store, workspace: Workspace, window: NSWindow?) {
        cancel()
        let w = DispatchWorkItem { [weak self, weak window] in
            guard let self, let window else { return }
            self.show(id, store: store, workspace: workspace, in: window)
        }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: w)
    }

    func hoverEnded(_ id: UUID) {
        pending?.cancel(); pending = nil
        if shownFor == id { hide() }
    }

    func cancel() { pending?.cancel(); pending = nil; hide() }

    func show(_ id: UUID, store: Store, workspace: Workspace, in window: NSWindow) {
        guard let c = store.conversation(id), let cv = window.contentView else { return }
        hide()
        let state = RPData.state(id, store: store, workspace: workspace)
        var rows: [(String, String)] = []
        rows.append((L("模型"), c.model ?? Prefs.shared.defaultModel ?? L("預設")))
        rows.append((L("狀態"), state.label))
        if let p = store.project(c.projectID)?.path { rows.append((L("工作資料夾"), (p as NSString).abbreviatingWithTildeInPath)) }
        if let s = store.commander(of: id) { rows.append((L("總指揮"), s.name)) }
        let v = PassthroughHost(rootView: ChatInfoCardView(name: c.title, topic: Store.cleanTopic(c.topic ?? ""), rows: rows))
        let size = v.fittingSize
        v.frame = NSRect(x: (cv.bounds.width - size.width) / 2, y: (cv.bounds.height - size.height) / 2, width: size.width, height: size.height)
        v.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        v.setAccessibilityIdentifier("chatInfoCard")
        cv.addSubview(v, positioned: .above, relativeTo: nil)
        host = v
        shownFor = id
    }

    func hide() { host?.removeFromSuperview(); host = nil; shownFor = nil }
}

/// 抓這個 view 所在的視窗（資訊卡要加在那個視窗的 contentView）
struct WindowGrabber: NSViewRepresentable {
    final class Box { weak var window: NSWindow? }
    let box: Box
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { box.window = v.window }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { if box.window == nil { DispatchQueue.main.async { box.window = v.window } } }
}
