import Foundation
import SwiftUI

// 每段對話現在的上下文大小（Claude 每回答一次要讀進去的 token 數）：太大會慢、也很吃額度。
// 對話在工作台跑的時候從回覆的 usage 即時更新；沒在跑的從紀錄檔尾巴找最後一則回覆的 usage。

final class ContextMonitor: ObservableObject {
    static let shared = ContextMonitor()
    @Published var tokens: [UUID: Int] = [:]
    private var loading: Set<UUID> = []

    /// Claude 回覆裡的 usage：input＋快取讀＋快取寫＝這一輪的上下文
    func observe(_ o: [String: Any], conversation: UUID?) {
        // 壓縮完：直接用壓縮後的大小
        if let conversation, o["type"] as? String == "system", o["subtype"] as? String == "compact_boundary",
           let post = ((o["compact_metadata"] as? [String: Any])?["post_tokens"] as? NSNumber)?.intValue {
            tokens[conversation] = post
            return
        }
        // 子代理（Task）的回覆也會帶 usage，那是它自己的上下文，不算這段對話的
        guard let conversation, o["type"] as? String == "assistant", o["parent_tool_use_id"] == nil || o["parent_tool_use_id"] is NSNull,
              let u = (o["message"] as? [String: Any])?["usage"] as? [String: Any] else { return }
        let n = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"].reduce(0) { $0 + ((u[$1] as? NSNumber)?.intValue ?? 0) }
        if n > 0, tokens[conversation] != n { tokens[conversation] = n }
    }

    /// 從紀錄檔讀（在背景、只看尾巴 3 MB）
    func load(_ c: Conversation, path: String) {
        guard !loading.contains(c.id) else { return }
        loading.insert(c.id)
        let url = Self.transcript(c, path: path)
        let id = c.id
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var found: Int?
            if let h = try? FileHandle(forReadingFrom: url) {
                let size = (try? h.seekToEnd()) ?? 0
                try? h.seek(toOffset: size > 3_000_000 ? size - 3_000_000 : 0)
                let tail = (try? h.readToEnd()) ?? Data()
                try? h.close()
                let key = Data("\"type\":\"assistant\"".utf8)
                let side = Data("\"isSidechain\":true".utf8)
                for raw in tail.split(separator: 0x0a).reversed() where raw.range(of: key) != nil && raw.range(of: side) == nil {
                    guard let o = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
                          let u = (o["message"] as? [String: Any])?["usage"] as? [String: Any] else { continue }
                    let n = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"].reduce(0) { $0 + ((u[$1] as? NSNumber)?.intValue ?? 0) }
                    if n > 0 { found = n; break }
                }
            }
            DispatchQueue.main.async {
                self?.loading.remove(id)
                if let found, self?.tokens[id] == nil { self?.tokens[id] = found }
            }
        }
    }

    /// 照後端選紀錄檔（跟 ChatSession.transcriptURL 同一套）：不是 Claude 的讀它自己的紀錄，
    /// 不然會讀到換模型前 Claude 的舊數字，或根本沒有
    static func transcript(_ c: Conversation, path: String) -> URL {
        let m = c.model ?? ""
        if m.hasPrefix("agy:") { return AgyBridge.transcript(for: c.claudeSession) }
        if m.hasPrefix("codex:") { return CodexBridge.transcript(for: c.claudeSession) }
        if m.hasPrefix("copilot:") { return CopilotBridge.transcript(for: c.claudeSession) }
        if m.hasPrefix("local:apple:") { return AppleBridge.transcript(for: c.claudeSession) }
        if m.hasPrefix("local:mlx:") { return LocalBridge.transcript(for: c.claudeSession) }
        return Store.claudeTranscript(c.claudeSession, path: path)
    }

    static func text(_ n: Int) -> String { n >= 1000 ? "\(n / 1000)K" : "\(n)" }
    /// 60 萬以上紅（很慢、很吃額度），其他不上色（自動壓縮設在 50 萬，通常不會到）
    static func color(_ n: Int) -> Color { n >= 600_000 ? .red : .secondary }
}

/// 用量欄位裡「目前這個分頁」那一塊：分頁裡每一格的上下文各多少（目前那格粗體）。
/// 只有一格時就是那一段對話。很長的（60 萬以上）那列下面有「壓縮」
struct ContextBlock: View {
    @Environment(\.uiScale) private var s
    @ObservedObject var store: Store
    @ObservedObject var monitor = ContextMonitor.shared
    var compact: (UUID) -> Void

    var body: some View {
        let ids = (store.currentWindow?.root?.leaves ?? []).filter { store.conversation($0).map { !$0.isBrowser } ?? false }   // 瀏覽器沒有上下文
        if !ids.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Divider().padding(.vertical, 4)
                Text(L(ids.count > 1 ? "這個分頁的上下文" : "目前這段對話的上下文")).font(.system(size: 12 * s)).foregroundStyle(.secondary)
                ForEach(ids, id: \.self) { id in row(id, focused: ids.count == 1 || id == store.currentWindow?.focused) }
            }
            .onAppear { ids.forEach(load) }
            .onChange(of: ids) { _, new in new.forEach(load) }
        }
    }

    @ViewBuilder private func row(_ id: UUID, focused: Bool) -> some View {
        let c = store.conversation(id)
        let n = monitor.tokens[id]
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // 用哪家的模型（跟用量那邊同一套圖示）
                let icon = UsagePool.of(model: c?.terminal == true ? nil : c?.model).pool.icon
                if let img = icon.image {
                    Image(nsImage: img).resizable().renderingMode(icon.monochrome ? .template : .original)
                        .aspectRatio(contentMode: .fit).frame(width: 12 * s, height: 12 * s).foregroundStyle(.secondary)
                }
                Text(c?.title ?? "").font(.system(size: 12 * s, weight: focused ? .semibold : .regular)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text(n.map(ContextMonitor.text) ?? "—").font(.system(size: (focused ? 15 : 13) * s, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(n.map(ContextMonitor.color) ?? .secondary)
            }
            .help(c?.title ?? "")
            // 使用者 10/24：這格是哪個模型在跑
            Text(store.displayModel(id))
                .font(.system(size: 10.5 * s)).foregroundStyle(.tertiary).lineLimit(1).padding(.leading, 18 * s)
            if let n, n >= 600_000 {
                HStack(spacing: 6) {
                    Text(L("很長了：每一輪都很慢、很吃額度")).font(.system(size: 11 * s)).foregroundStyle(ContextMonitor.color(n))
                    Button(L("壓縮")) { compact(id) }
                        .controlSize(.small)
                        .help(L("送 /compact：Claude 把前面的內容濃縮成摘要，上下文會變小很多（原本的紀錄檔還在）"))
                }
            }
        }
    }

    private func load(_ id: UUID) {
        guard monitor.tokens[id] == nil, let c = store.conversation(id), let p = store.project(c.projectID) else { return }
        monitor.load(c, path: p.path)
    }
}
