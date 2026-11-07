import AppKit

/// 查「打字的地方自己跳到別格」用：鍵盤焦點換到另一格、而且前 1 秒內使用者沒點滑鼠也沒按鍵
/// 就記一筆到事件紀錄（哪一格、閒了幾秒、是程式哪裡叫的）。codenv 自己跑到最前面時也記。只記，不改任何行為
final class FocusWatch {
    private let store: Store
    private let workspace: Workspace
    private var lastInput = Date()
    private var observed: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var lastPane: UUID?
    private var monitor: Any?

    init(store: Store, workspace: Workspace) {
        self.store = store
        self.workspace = workspace
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] e in
            self?.lastInput = Date()
            return e
        }
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] n in
            if let w = n.object as? NSWindow { self?.watch(w) }
        }
        nc.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] n in
            if let w = n.object as? NSWindow { self?.observed[ObjectIdentifier(w)] = nil }
        }
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            // 從別的 App 點回來、⌘ Tab、點 Dock：那個按鍵 codenv 收不到（監視器只看得到自己的事件），要問系統全域最近有沒有操作，有就不是自己跑上來的
            guard let self, self.idle > 1, Self.systemIdle > 1 else { return }
            EventLog.log("焦點", "codenv 自己跑到最前面（前 \(String(format: "%.1f", self.idle)) 秒沒有操作 codenv）")
        }
    }

    private var idle: TimeInterval { Date().timeIntervalSince(lastInput) }
    /// 整台電腦距離上次點滑鼠、按鍵（含 ⌘ 這類修飾鍵）幾秒，不管按在哪個 App
    private static var systemIdle: TimeInterval {
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown, .keyDown, .flagsChanged]
        return types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
    }

    private func watch(_ w: NSWindow) {
        let key = ObjectIdentifier(w)
        guard observed[key] == nil else { return }
        observed[key] = w.observe(\.firstResponder, options: [.new]) { [weak self] w, _ in self?.changed(w) }
    }

    private func changed(_ w: NSWindow) {
        guard let v = w.firstResponder as? NSView,
              let (id, _) = workspace.panes.first(where: { v.isDescendant(of: $0.value) }) else { return }
        defer { lastPane = id }
        guard let prev = lastPane, prev != id, idle > 1 else { return }
        // 叫 makeFirstResponder 的那幾層（KVO 是同步通知，堆疊裡就有元兇）；只留 Workbench 自己的函式名，不含路徑
        let frames = Thread.callStackSymbols.dropFirst(2)
            .filter { $0.contains("Workbench") && !$0.contains("FocusWatch") }
            .prefix(4)
            .map { $0.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).prefix(1).joined() }
        EventLog.log("焦點", "沒操作時焦點從 \(desc(prev)) 跳到 \(desc(id))（閒了 \(String(format: "%.1f", idle)) 秒）；來源：\(frames.joined(separator: " ← "))")
    }

    private func desc(_ id: UUID) -> String {
        guard let c = store.conversation(id) else { return "格 \(String(id.uuidString.prefix(8)))" }
        return "對話 \(String(c.claudeSession.uuidString.prefix(8).uppercased()))（\(c.modelCategory)）"
    }
}
