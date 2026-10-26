import AppKit
import Darwin
import SwiftUI

// 右邊欄最上面的「記憶體」：codenv 自己＋它開出來的每個 Claude（或之後的其他模型、終端機）＋聊天畫面的網頁程序，加起來是多少。
// macOS 是一個程序一個程序算的，活動監視器不會把子程序加到 codenv 身上，所以自己數。
// 數字用 phys_footprint（跟活動監視器「記憶體」那一欄同一種算法）。

final class MemoryMonitor: ObservableObject {
    static let shared = MemoryMonitor()

    struct Row: Identifiable {
        let id: String
        let label: String
        let bytes: UInt64
        let count: Int          // 這一列包含幾個程序
    }

    @Published private(set) var total: UInt64 = 0
    @Published private(set) var rows: [Row] = []
    @Published private(set) var claudeCount = 0

    /// 程序 id → 名字（聊天室標題）。MainWindowController 設定
    var labeler: () -> [pid_t: String] = { [:] }
    private var timer: Timer?

    private init() {
        DispatchQueue.main.async { self.refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        let me = getpid()
        let labels = labeler()
        var out: [Row] = []
        let mine = Self.footprint(me)
        out.append(Row(id: "self", label: "codenv 本身", bytes: mine, count: 1))
        var claude = 0
        var childSet = Set<pid_t>([me])
        for c in Self.children(of: me) {
            let tree = [c] + Self.descendants(of: c)
            tree.forEach { childSet.insert($0) }
            let bytes = tree.reduce(UInt64(0)) { $0 + Self.footprint($1) }
            let name = Self.name(c)
            if name.lowercased().contains("claude") { claude += 1 }
            out.append(Row(id: "p\(c)", label: labels[c] ?? name, bytes: bytes, count: tree.count))
        }
        // 聊天畫面、程式碼區的網頁程序：系統代開的（不是子程序），但「負責的程序」是 codenv
        // 只算 WebKit 的（從 codenv 裡跑的測試實例等等，系統也會記在 codenv 身上，那些不算）
        let web = Self.responsible(to: me).filter { !childSet.contains($0) && Self.name($0).hasPrefix("com.apple.WebKit") }
        if !web.isEmpty {
            out.append(Row(id: "web", label: "畫面（網頁程序）", bytes: web.reduce(UInt64(0)) { $0 + Self.footprint($1) }, count: web.count))
        }
        let head = out.first!
        let rest = out.dropFirst().sorted { $0.bytes > $1.bytes }
        rows = [head] + rest
        total = out.reduce(0) { $0 + $1.bytes }
        claudeCount = claude
    }

    // MARK: 查程序

    static func footprint(_ pid: pid_t) -> UInt64 {
        var info = rusage_info_v2()
        let r = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return r == 0 ? info.ri_phys_footprint : 0
    }

    static func children(of pid: pid_t) -> [pid_t] {
        guard pid > 0 else { return [] }
        var buf = [pid_t](repeating: 0, count: 512)
        let n = proc_listchildpids(pid, &buf, Int32(buf.count * MemoryLayout<pid_t>.size))
        return n > 0 ? buf.prefix(Int(n)).filter { $0 > 0 } : []
    }

    static func descendants(of pid: pid_t) -> [pid_t] {
        children(of: pid).flatMap { [$0] + descendants(of: $0) }
    }

    static func name(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : "程序 \(pid)"
    }

    /// 系統記錄「由誰負責」的程序（WebKit 的網頁程序會記在開它的 App 身上）。查不到這個函式就回空的
    private typealias RespFn = @convention(c) (pid_t) -> pid_t
    private static let respFn: RespFn? = {
        guard let h = dlopen(nil, RTLD_NOW), let s = dlsym(h, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(s, to: RespFn.self)
    }()
    static func responsible(to me: pid_t) -> [pid_t] {
        guard let f = respFn else { return [] }
        var buf = [pid_t](repeating: 0, count: 4096)
        let n = proc_listallpids(&buf, Int32(buf.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return [] }
        return buf.prefix(Int(n)).filter { $0 > 0 && $0 != me && f($0) == me }
    }

    static func format(_ b: UInt64) -> String {
        let mb = Double(b) / 1_048_576
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }
}

/// 右邊欄最上面：總數；點一下展開每個聊天室各多少
struct MemoryBlock: View {
    @Environment(\.uiScale) private var s
    @ObservedObject var m = MemoryMonitor.shared
    @State private var open = ProcessInfo.processInfo.environment["WB_MEMORY_OPEN"] != nil   // 測試用：一開就展開

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: { open.toggle(); if open { m.refresh() } }) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("記憶體").font(.system(size: 13 * s, weight: .semibold)).foregroundStyle(.secondary)
                        Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9 * s, weight: .semibold)).foregroundStyle(.tertiary)
                        Spacer()
                        Text(MemoryMonitor.format(m.total)).font(.system(size: 15 * s, weight: .semibold)).monospacedDigit()
                    }
                    Text(summary).font(.system(size: 11 * s)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("codenv 和它開的程序加起來用的記憶體（跟活動監視器的「記憶體」同一種算法）；點一下看各聊天室")
            if open {
                ForEach(m.rows) { r in
                    HStack(alignment: .firstTextBaseline) {
                        Text(r.label).font(.system(size: 12 * s)).lineLimit(1).truncationMode(.tail)
                        if r.count > 1 { Text("×\(r.count)").font(.system(size: 10 * s)).foregroundStyle(.tertiary) }
                        Spacer()
                        Text(MemoryMonitor.format(r.bytes)).font(.system(size: 12 * s)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            Divider().padding(.top, 2)
        }
    }

    private var summary: String {
        let others = max(0, m.rows.count - 1 - (m.rows.contains { $0.id == "web" } ? 1 : 0))
        var parts = ["codenv"]
        if m.claudeCount > 0 { parts.append("\(m.claudeCount) 個 Claude") }
        if others > m.claudeCount { parts.append("\(others - m.claudeCount) 個其他程序") }
        if m.rows.contains(where: { $0.id == "web" }) { parts.append("畫面") }
        return parts.joined(separator: "＋")
    }
}
