import SwiftUI
import Foundation

// 額度衝刺：額度快重置了還有剩，就讓一個聊天室（預設總指揮）規劃「會消耗額度、又真的有用」的工作去做，
// 重置的那一刻 codenv 通知它收尾、總結。狀態存在 sprint.json（測試實例放 --state-dir），使用者回來看右欄的衝刺卡片。
// 流程：idle → running（衝刺中）→ winding（已通知重置、等總結）→ done（有最後一次總結）。

struct SprintNote: Codable, Equatable { var at: Date; var text: String }

struct SprintState: Codable, Equatable {
    var phase = "idle"              // idle／running／winding／done
    var convID: String?             // 衝刺的聊天室
    var convTitle = ""
    var startedAt: Date?
    var watchLabel = ""             // 盯哪一格額度（例如「5 小時」）
    var targetReset: Date?          // 預計重置時間
    var baselineUsed = 0            // 開始時用掉的百分比
    var goal = ""                   // agent 寫的工作目標
    var notes: [SprintNote] = []    // agent 回報的進度
    var windingAt: Date?
    var endedAt: Date?
    var endReason = ""              // reset／manual／timeout
    var summary = ""                // 最後一次總結
    var summaryAuto = false         // 總結是 codenv 從聊天室最後一則回覆抓的（agent 沒自己交）
    var targetKnown = true          // 重置時間是真的查到的（false＝暫以 5 小時後計，查到真的就換掉）
    var windSent = false            // 收尾通知已送出
    var nudges = 0                  // 閒置時提醒繼續的次數
    var lastNudgeAt: Date?
    var checkLastRound: String?     // 最近已檢查的衝刺聊天室回合
    var checkReminderTimes: [Date]? // 衝刺收尾檢查在最近 30 分鐘送出的提醒
    var checkReminderCount: Int?    // 這次衝刺累計提醒次數
    var checkConsecutiveReminders: Int? // 連續提醒後仍未動手的次數
    var checkStuckReason: String?   // 停止提醒後顯示在衝刺卡片上的原因
    var checkNudgeRound: String?    // 正常回覆或模型失敗後，可由閒置 nudge 接手的回合
}

final class SprintStore: ObservableObject {
    static let shared = SprintStore()
    @Published private(set) var state = SprintState()
    /// 右欄按「開始衝刺」／「收尾」由 MainWindowController 接
    var startHandler: (() -> Void)?
    var stopHandler: (() -> Void)?

    static let fileURL: URL = {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--state-dir"), i + 1 < a.count { return URL(fileURLWithPath: a[i + 1]).appendingPathComponent("sprint.json") }
        return Edition.support("sprint.json")
    }()

    private init() {
        if let d = try? Data(contentsOf: Self.fileURL) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            if let s = try? dec.decode(SprintState.self, from: d) { state = s } else if !UnreadableFile.setAside(Self.fileURL, data: d) { protectOriginal = true }
        }
    }

    private var protectOriginal = false      // 讀不懂、又另存不了：原檔是唯一一份，不覆蓋（只在記憶體裡更新）

    func update(_ f: (inout SprintState) -> Void) {
        var s = state
        f(&s)
        guard s != state else { return }
        state = s
        guard !protectOriginal else { return }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(s) { try? d.write(to: Self.fileURL, options: .atomic) }
    }

    var isActive: Bool { state.phase == "running" || state.phase == "winding" }
}

/// 右欄的衝刺卡片
struct SprintCard: View {
    @Environment(\.uiScale) private var s
    @ObservedObject var sprint = SprintStore.shared
    @State private var expanded = false

    private func countdown(_ d: Date) -> String {
        let sec = Int(d.timeIntervalSinceNow)
        if sec <= 0 { return L("已到") }
        let m = sec / 60
        return m >= 60 ? "\(m / 60)h\(String(format: "%02d", m % 60))m" : "\(max(m, 1))m"
    }

    var body: some View {
        let st = sprint.state
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Button(action: { expanded.toggle() }) {
                    HStack(spacing: 4) {
                        Text(L("額度衝刺")).font(.system(size: 13 * s, weight: .semibold)).foregroundStyle(.secondary)
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9 * s, weight: .semibold)).foregroundStyle(.tertiary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                Spacer()
                if sprint.isActive {
                    Button(L("收尾")) { sprint.stopHandler?() }.controlSize(.mini).help(L("現在就通知它收尾、總結"))
                } else {
                    Button(L("開始")) { sprint.startHandler?() }.controlSize(.mini).help(L("讓聊天室規劃並消耗快重置的額度"))
                }
            }
            switch st.phase {
            case "running":
                Text(L("衝刺中（\(st.convTitle)）")).font(.system(size: 12 * s)).foregroundStyle(.green)
                if let t = st.targetReset { Text(L("\(st.watchLabel) 還有 \(countdown(t)) 重置")).font(.system(size: 11 * s)).foregroundStyle(.secondary) }
            case "winding":
                Text(L("已重置，等 \(st.convTitle) 交總結…")).font(.system(size: 12 * s)).foregroundStyle(.orange)
            case "done":
                Text(L("上次衝刺已結束（\(st.endedAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? "")）")).font(.system(size: 11 * s)).foregroundStyle(.secondary)
            default:
                Text(L("還沒有衝刺")).font(.system(size: 11 * s)).foregroundStyle(.tertiary)
            }
            if let reason = st.checkStuckReason {
                Text(L("卡住：") + reason).font(.system(size: 11 * s)).foregroundStyle(.red)
            }
            if !st.goal.isEmpty {
                Text(L("目標：") + st.goal).font(.system(size: 11 * s)).foregroundStyle(.primary).lineLimit(expanded ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
            } else if st.phase == "running" {
                Text(L("目標：（agent 還沒寫）")).font(.system(size: 11 * s)).foregroundStyle(.tertiary)
            }
            if expanded {
                ForEach(Array(st.notes.suffix(8).enumerated()), id: \.offset) { _, n in
                    Text("\(n.at.formatted(date: .omitted, time: .shortened)) \(n.text)").font(.system(size: 11 * s)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !st.summary.isEmpty {
                Text(L("最後總結") + (st.summaryAuto ? L("（自動擷取）") : "") + "：").font(.system(size: 11 * s, weight: .semibold)).foregroundStyle(.secondary)
                Text(st.summary).font(.system(size: 11 * s)).foregroundStyle(.secondary)
                    .lineLimit(expanded ? 40 : 4).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}
