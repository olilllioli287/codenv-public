import SwiftUI
import AppKit

// 左欄最下面固定一塊（首頁、程式碼學習專區、tree／commander 都顯示），總高 ≤ 85 點
// 用量剩餘一家一行（Claude／Codex「5 小時 · 週」、agy「5 小時 · 週 · 阿公 週」，UsageMonitor.glance）＋記憶體兩行；重置倒數在滑過說明裡。資料不受目前 Window 過濾。

struct SidebarFooter: View {
    @Environment(\.uiScale) private var s
    @ObservedObject private var usage = UsageMonitor.shared
    @ObservedObject private var mem = MemoryMonitor.shared
    @ObservedObject private var colab = ColabMonitor.shared
    @State private var memOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 2 * s) {
                // 用量（Claude／Codex／agy）只放在輸入框下面那條（UsageGlanceStrip），左下角不再列

                if colab.balance != nil || !colab.machines.isEmpty {
                    Button(action: { (NSApp.windows.compactMap { $0.windowController as? MainWindowController }.first)?.showRightPanel(tab: .windows) }) {
                        Text(colabSummary).font(.system(size: 11 * s)).minimumScaleFactor(0.75)
                            .foregroundStyle(colab.machines.isEmpty ? Color.secondary : Color.orange)
                            .lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L("Colab 運算單元；點一下到右欄看開著的機器"))
                }

                Button(action: { memOpen.toggle() }) {
                    // 兩行，每行放不下就換短的寫法（不截成「…」、不縮字）
                    VStack(alignment: .leading, spacing: 1 * s) {
                        memLine(memoryCodenv)
                        if let c = memoryClaude { memLine(c) }
                    }
                    .font(.system(size: 11 * s)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("codenv 和它開的程序加起來用的記憶體；點一下看各聊天室"))
                .popover(isPresented: $memOpen, arrowEdge: .trailing) { MemoryDetailList() }
            }
            .padding(.horizontal, 8).padding(.vertical, 4 * s)
        }
        .frame(maxWidth: .infinity)
    }

    private var colabSummary: String {
        var t = "Colab"
        if let b = colab.balance { t += " " + L("\(String(format: "%.1f", b)) 單位") }
        if let r = colab.ratePerHour { t += " · " + String(format: "%.2f", r) + "/hr" }
        if !colab.machines.isEmpty { t += " · " + L("\(colab.machines.count) 台開著") }
        return t
    }

    /// 每行給「長 → 短」兩種寫法
    private var memoryCodenv: [String] {
        let m = MemoryMonitor.format(mem.rows.first?.bytes ?? mem.total)
        return [L("記憶體") + " codenv " + m, "codenv " + m]
    }
    private var memoryClaude: [String]? {
        guard mem.claudeCount > 0 else { return nil }
        let m = MemoryMonitor.format(mem.claudeBytes)
        return [L("Claude \(mem.claudeCount) 個") + " " + m, "Claude ×\(mem.claudeCount) " + m]
    }
    private func memLine(_ options: [String]) -> some View {
        ViewThatFits(in: .horizontal) {
            ForEach(options, id: \.self) { Text($0).lineLimit(1).fixedSize() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func numbers(_ g: UsageGlanceGroup, tight: Bool) -> Text {
        g.parts(compact: true, tight: tight).reduce(Text("")) { t, p in t + Text(p.text).foregroundColor(p.low ? UsageRowView.color(0) : .secondary) }
            .font(.system(size: 10.5 * s)).monospacedDigit()
    }

    /// 不縮小字級：左欄再窄，依序換比較短的寫法——
    /// 名稱＋「66%·39%」→ 名稱＋「66·39%」（只留最後一個 %）→ 小圖示＋「66·39%」；每一段都完整顯示。
    private func usageLine(_ g: UsageGlanceGroup) -> some View {
        ViewThatFits(in: .horizontal) {
            row(Text(g.name).font(.system(size: 11 * s)), numbers(g, tight: false))
            row(Text(g.name).font(.system(size: 11 * s)), numbers(g, tight: true))
            row(Text(Image(systemName: g.symbol)).font(.system(size: 10 * s)), numbers(g, tight: true))
            // 最窄的左欄：名稱一行、數字一行（總共最多 6 行），不縮字、不截斷
            VStack(alignment: .leading, spacing: 0) {
                Text(g.name).font(.system(size: 11 * s)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                numbers(g, tight: true).lineLimit(1).fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 13 * s)
        .help(g.tip)
    }

    private func row(_ left: Text, _ right: Text) -> some View {
        HStack(spacing: 3 * s) {
            left.foregroundStyle(.secondary).lineLimit(1).fixedSize()
            Spacer(minLength: 0)
            right.lineLimit(1).fixedSize()
        }
    }

    /// 「66% · 2h13m」；重置時間字串（今天 22:00／明天 01:00／10/30 01:00）轉成倒數，轉不出來就只留百分比
    static func trailing(_ b: UsageBucket) -> String {
        var t = "\(b.remaining)%"
        if let c = countdown(b.resets) { t += " · " + c }
        return t
    }

    static func countdown(_ s: String, now: Date = Date()) -> String? {
        let cal = Calendar.current
        let parts = s.split(separator: " ")
        guard parts.count == 2 else { return nil }
        let hm = parts[1].split(separator: ":").compactMap { Int($0) }
        guard hm.count == 2 else { return nil }
        var d = cal.startOfDay(for: now)
        let day = String(parts[0])
        if day == "今天" { }
        else if day == "明天" { d = cal.date(byAdding: .day, value: 1, to: d) ?? d }
        else {
            let md = day.split(separator: "/").compactMap { Int($0) }
            guard md.count == 2 else { return nil }
            var c = cal.dateComponents([.year], from: now); c.month = md[0]; c.day = md[1]
            guard var t = cal.date(from: c) else { return nil }
            if t < cal.startOfDay(for: now) { t = cal.date(byAdding: .year, value: 1, to: t) ?? t }
            d = t
        }
        guard let target = cal.date(bySettingHour: hm[0], minute: hm[1], second: 0, of: d) else { return nil }
        let sec = Int(target.timeIntervalSince(now))
        if sec <= 0 { return nil }
        let m = sec / 60
        if m >= 2880 { return "\(m / 1440)d" }
        if m >= 60 { return "\(m / 60)h\(String(format: "%02d", m % 60))m" }
        return "\(max(m, 1))m"
    }
}
