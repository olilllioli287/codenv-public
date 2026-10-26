import AppKit
import SwiftUI

// 排程喚醒：到時間自動送一則訊息給某段對話（對話右鍵「排程…」）。使用者 10/25 定的範圍：
// - codenv 沒開就不送（不裝 LaunchAgent、不叫醒 Mac）；重開時錯過好幾次只補一次，下一次從現在算
// - 只能送訊息，不能關 codenv 或聊天室
// - 小視窗和排程頁都寫出會送給哪個模型；全部排程合計每天最多送 10 則，超過就跳過、記「超過每日上限」
// 照 cc-agent 的做法：到期時「先把下一次時間往後推、記下這次待送（pendingRun），存檔，再送」；
// 送到一半當掉，重開看到 pendingRun 時先查紀錄檔有沒有這則（訊息開頭帶到期時間），有就不重送，沒有才補送。

struct ScheduleRun: Codable, Equatable {
    var at: Date          // 實際處理的時間
    var due: Date         // 本來該送的時間
    var result: String    // 已送出／跳過：…／失敗：…
}

struct WakeSchedule: Codable, Identifiable, Equatable {
    var id = UUID()
    var conversation: UUID
    var text: String
    var frequency = "daily"          // daily 每天／weekly 每週／monthly 每月／interval 每隔幾分鐘
    var times: [String] = ["09:00"]  // HH:mm，最多 6 個
    var weekdays: [Int] = [2]        // 1＝週日 … 7＝週六（Calendar 的 weekday）
    var monthDays: [Int] = [1]
    var intervalMinutes = 60
    var until: Date?
    var whenClosed = "open"          // 聊天室沒開著：open 開起來送／wait 等它打開再送／skip 跳過
    var enabled = true
    var createdAt = Date()
    var nextAt: Date?
    var pendingRun: Date?
    var runs: [ScheduleRun] = []

    static let maxTimes = 6

    /// after 之後（不含）的下一次；過了截止日或找不到回傳 nil
    func next(after: Date, cal: Calendar = .current) -> Date? {
        var found: Date?
        if frequency == "interval" {
            found = after.addingTimeInterval(TimeInterval(max(1, intervalMinutes) * 60))
        } else {
            let hm = times.compactMap { t -> (Int, Int)? in
                let p = t.split(separator: ":").compactMap { Int($0) }
                return p.count == 2 && (0..<24).contains(p[0]) && (0..<60).contains(p[1]) ? (p[0], p[1]) : nil
            }.sorted { $0 < $1 }
            guard !hm.isEmpty else { return nil }
            var day = cal.startOfDay(for: after)
            search: for _ in 0..<400 {
                let ok: Bool
                switch frequency {
                case "weekly": ok = weekdays.contains(cal.component(.weekday, from: day))
                case "monthly": ok = monthDays.contains(cal.component(.day, from: day))
                default: ok = true
                }
                if ok {
                    for (h, m) in hm {
                        if let d = cal.date(bySettingHour: h, minute: m, second: 0, of: day), d > after { found = d; break search }
                    }
                }
                guard let n = cal.date(byAdding: .day, value: 1, to: day) else { break }
                day = n
            }
        }
        if let f = found, let u = until, f > u { return nil }
        return found
    }

    /// 給人看的頻率（「每天 09:00、21:00」）
    var summary: String {
        let t = times.joined(separator: "、")
        switch frequency {
        case "weekly":
            let names = ["日", "一", "二", "三", "四", "五", "六"]
            return "每週" + weekdays.sorted().map { names[($0 - 1) % 7] }.joined(separator: "、") + " " + t
        case "monthly": return "每月 " + monthDays.sorted().map { "\($0) 號" }.joined(separator: "、") + " " + t
        case "interval": return "每隔 \(intervalMinutes) 分鐘"
        default: return "每天 " + t
        }
    }
}

final class ScheduleStore: ObservableObject {
    static let shared = ScheduleStore()
    static let dailyLimit = 10

    @Published private(set) var items: [WakeSchedule] = []

    static let file: URL = {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--state-dir"), i + 1 < a.count { return URL(fileURLWithPath: a[i + 1]).appendingPathComponent("schedules.json") }
        return Edition.support("schedules.json")
    }()

    init() {
        if let d = try? Data(contentsOf: Self.file) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            items = (try? dec.decode([WakeSchedule].self, from: d)) ?? []
        }
    }

    /// 暫存檔＋改名，權限 0600
    private func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(items) else { return }
        let dir = Self.file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".schedules.\(getpid()).tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: d, attributes: [.posixPermissions: 0o600])
        _ = rename(tmp.path, Self.file.path)
    }

    func has(_ conversation: UUID) -> Bool { items.contains { $0.conversation == conversation && $0.enabled } }
    func of(_ conversation: UUID) -> [WakeSchedule] { items.filter { $0.conversation == conversation } }

    /// 新增或改一個排程（下一次時間從現在重算）
    func put(_ s: WakeSchedule, now: Date = ScheduleStore.now()) {
        var s = s
        s.times = Array(s.times.prefix(WakeSchedule.maxTimes))
        s.nextAt = s.enabled ? s.next(after: now) : nil
        if let i = items.firstIndex(where: { $0.id == s.id }) { s.runs = items[i].runs; items[i] = s } else { items.append(s) }
        save()
    }

    func remove(_ id: UUID) { items.removeAll { $0.id == id }; save() }

    func setEnabled(_ id: UUID, _ on: Bool, now: Date = ScheduleStore.now()) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].enabled = on
        items[i].nextAt = on ? items[i].next(after: now) : nil
        if !on { items[i].pendingRun = nil }
        save()
    }

    /// 對話刪掉了：它的排程一起拿掉
    func prune(alive: Set<UUID>) {
        let before = items.count
        items.removeAll { !alive.contains($0.conversation) }
        if items.count != before { save() }
    }

    // MARK: 檢查與送出

    /// 測試 App 可以用 --fake-now 指定「現在」（之後照真實時間往前走）
    private static let fakeOffset: TimeInterval = {
        let a = CommandLine.arguments
        guard a.contains("--state-dir"), let i = a.firstIndex(of: "--fake-now"), i + 1 < a.count,
              let d = ISO8601DateFormatter.local.date(from: a[i + 1]) else { return 0 }
        return d.timeIntervalSinceNow
    }()
    static func now() -> Date { Date().addingTimeInterval(fakeOffset) }

    /// 怎麼送（MainWindowController 接上）：回傳 nil＝送出了，否則是沒送的原因（「跳過：…」「失敗：…」「等待」）
    var deliver: (_ s: WakeSchedule, _ message: String, _ due: Date) -> String? = { _, _, _ in "失敗：還沒接好" }
    /// 這段對話的紀錄檔裡有沒有這串字（當掉重開時防重送）
    var alreadySent: (_ conversation: UUID, _ marker: String) -> Bool = { _, _ in false }

    private var timer: Timer?
    func start() {
        guard timer == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.tick() }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.tick() }
        // Mac 醒來：馬上檢查一次（睡著時錯過的只補一次）
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.tick() }
        }
    }

    static func marker(_ due: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "M/d HH:mm"
        return "〔codenv 排程 \(f.string(from: due))〕"
    }

    static func message(_ s: WakeSchedule, due: Date) -> String {
        marker(due) + "這是排程自動送的，不是使用者本人現在說的。\n\n" + s.text
    }

    private func sentToday(_ now: Date) -> Int {
        items.flatMap(\.runs).filter { $0.result == "已送出" && Calendar.current.isDate($0.at, inSameDayAs: now) }.count
    }

    private func record(_ i: Int, due: Date, now: Date, _ result: String) {
        items[i].runs.append(ScheduleRun(at: now, due: due, result: result))
        if items[i].runs.count > 30 { items[i].runs.removeFirst(items[i].runs.count - 30) }
    }

    func tick(now: Date = ScheduleStore.now()) {
        var changed = false
        for i in items.indices where items[i].enabled {
            // 新到期的：先推下一次、記待送、存檔，再處理（當掉也不漏不重送）
            if let n = items[i].nextAt, n <= now {
                if items[i].pendingRun == nil {
                    items[i].pendingRun = n
                } else {
                    record(i, due: n, now: now, "跳過：上一次還在等聊天室打開")
                }
                items[i].nextAt = items[i].next(after: now)   // 錯過好幾次只算一次，下一次從現在算
                changed = true
                save()
            }
            guard let due = items[i].pendingRun else {
                if items[i].nextAt == nil { items[i].enabled = false; changed = true }   // 過了截止日
                continue
            }
            let s = items[i]
            let result: String?
            if alreadySent(s.conversation, Self.marker(due)) {
                result = nil   // 上次送到一半當掉：其實送出去了
            } else if sentToday(now) >= Self.dailyLimit {
                result = "跳過：超過每日上限（\(Self.dailyLimit) 則）"
            } else {
                result = deliver(s, Self.message(s, due: due), due)
            }
            if result == "等待" { continue }   // 聊天室沒開、選了「等它打開再送」
            record(i, due: due, now: now, result ?? "已送出")
            items[i].pendingRun = nil
            if items[i].nextAt == nil { items[i].enabled = false }
            changed = true
        }
        if changed { save(); objectWillChange.send() }
    }

    /// --schedule-dump
    func dump() -> String {
        let f = ISO8601DateFormatter.local
        return items.map { s in
            "\(s.summary) enabled=\(s.enabled) next=\(s.nextAt.map(f.string) ?? "-") pending=\(s.pendingRun.map(f.string) ?? "-")\n"
                + s.runs.map { "  run due=\(f.string(from: $0.due)) \($0.result)\n" }.joined()
        }.joined()
    }
}

extension ISO8601DateFormatter {
    /// 本地時間、不帶時區的「2026-10-25T09:00:00」（測試參數、dump 用）
    static let local: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        f.timeZone = .current
        return f
    }()
}

// MARK: 畫面

/// 對話右鍵「排程…」的小視窗：這段對話的排程清單＋新增／修改
struct ScheduleSheet: View {
    @ObservedObject var store = ScheduleStore.shared
    let conversation: UUID
    let title: String
    let model: String
    var close: () -> Void
    @State private var draft: WakeSchedule?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("排程：\(title)").font(.headline)
            Text("會送給：\(model)。codenv 沒開著就不送；全部排程合計每天最多 \(ScheduleStore.dailyLimit) 則。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let d = Binding($draft) {
                ScheduleForm(s: d)
                HStack {
                    Spacer()
                    Button("取消") { draft = nil }.keyboardShortcut(.cancelAction)
                    Button("存") { if let s = draft { store.put(s) }; draft = nil }
                        .keyboardShortcut(.defaultAction)
                        .disabled(draft?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                }
            } else {
                let list = store.of(conversation)
                if list.isEmpty { Text("還沒有排程").foregroundStyle(.secondary) }
                ForEach(list) { s in ScheduleRowView(s: s, edit: { draft = s }) }
                HStack {
                    Button { draft = WakeSchedule(conversation: conversation, text: "") } label: { Label("新增排程", systemImage: "plus") }
                    Spacer()
                    Button("關閉", action: close).keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(18).frame(width: 460)
    }
}

/// 一個排程的設定欄位
struct ScheduleForm: View {
    @Binding var s: WakeSchedule
    var body: some View {
        Form {
            TextField("要送的話", text: $s.text, axis: .vertical).lineLimit(3...6)
            Picker("頻率", selection: $s.frequency) {
                Text("每天").tag("daily"); Text("每週").tag("weekly"); Text("每月").tag("monthly"); Text("每隔幾分鐘").tag("interval")
            }
            if s.frequency == "interval" {
                Stepper("每隔 \(s.intervalMinutes) 分鐘", value: $s.intervalMinutes, in: 5...1440, step: 5)
            } else {
                TextField("時間（24 小時制，逗號分開，最多 6 個）", text: Binding(
                    get: { s.times.joined(separator: ", ") },
                    set: { s.times = $0.split(whereSeparator: { ",，、 ".contains($0) }).map(String.init).filter { !$0.isEmpty } }))
                if s.frequency == "weekly" {
                    HStack(spacing: 4) {
                        ForEach(1...7, id: \.self) { d in
                            Toggle(["日", "一", "二", "三", "四", "五", "六"][d - 1], isOn: Binding(
                                get: { s.weekdays.contains(d) },
                                set: { on in if on { s.weekdays.append(d) } else { s.weekdays.removeAll { $0 == d } } }))
                            .toggleStyle(.button)
                        }
                    }
                }
                if s.frequency == "monthly" {
                    TextField("每月幾號（逗號分開）", text: Binding(
                        get: { s.monthDays.map(String.init).joined(separator: ", ") },
                        set: { s.monthDays = $0.split(whereSeparator: { ",，、 ".contains($0) }).compactMap { Int($0) }.filter { (1...31).contains($0) } }))
                }
            }
            Toggle("有截止日", isOn: Binding(get: { s.until != nil }, set: { s.until = $0 ? (s.until ?? Date().addingTimeInterval(7 * 86400)) : nil }))
            if s.until != nil {
                DatePicker("截止", selection: Binding(get: { s.until ?? Date() }, set: { s.until = $0 }))
            }
            Picker("聊天室沒開著時", selection: $s.whenClosed) {
                Text("開起來送").tag("open"); Text("等它打開再送").tag("wait"); Text("跳過").tag("skip")
            }
        }
        .formStyle(.grouped)
    }
}

struct ScheduleRowView: View {
    @ObservedObject var store = ScheduleStore.shared
    let s: WakeSchedule
    var model: String? = nil
    var conversationTitle: String? = nil
    var edit: (() -> Void)? = nil
    @State private var showRuns = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle("", isOn: Binding(get: { s.enabled }, set: { store.setEnabled(s.id, $0) })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                VStack(alignment: .leading, spacing: 2) {
                    if let conversationTitle { Text(conversationTitle).font(.system(size: 12, weight: .semibold)) }
                    Text(s.summary).font(.system(size: 12))
                    Text(s.text).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    HStack(spacing: 8) {
                        if let model { Text("送給 \(model)") }
                        Text(s.enabled ? "下一次 " + (s.nextAt.map { Self.fmt($0) } ?? "—") : "暫停中")
                        if s.pendingRun != nil { Text("等聊天室打開").foregroundStyle(.orange) }
                    }.font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer()
                if let edit { Button("改", action: edit).controlSize(.small) }
                Button(role: .destructive) { store.remove(s.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("刪掉這個排程")
            }
            if !s.runs.isEmpty {
                DisclosureGroup("最近 \(s.runs.count) 次", isExpanded: $showRuns) {
                    ForEach(Array(s.runs.reversed().enumerated()), id: \.offset) { _, r in
                        Text("\(Self.fmt(r.due))　\(r.result)").font(.system(size: 10.5)).foregroundStyle(r.result == "已送出" ? .secondary : Color.orange)
                    }
                }.font(.system(size: 10.5))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
    }

    static func fmt(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = Calendar.current.isDateInToday(d) ? "今天 HH:mm" : "M/d HH:mm"
        return f.string(from: d)
    }
}

/// 設定裡的「排程」分頁：全部排程
struct SchedulesPage: View {
    @ObservedObject var store: Store
    @ObservedObject var schedules = ScheduleStore.shared
    var body: some View {
        Form {
            Section {
                if schedules.items.isEmpty {
                    Text("還沒有排程。在側欄的對話上按右鍵 →「排程…」新增。").foregroundStyle(.secondary)
                }
                ForEach(schedules.items) { s in
                    ScheduleRowView(s: s, model: store.displayModel(s.conversation), conversationTitle: store.conversation(s.conversation)?.title ?? "（對話已刪除）")
                }
            } footer: {
                Text("codenv 沒開著就不送，重開時錯過好幾次只補一次。全部排程合計每天最多 \(ScheduleStore.dailyLimit) 則，超過的記成「超過每日上限」。送出去的訊息開頭會寫「這是排程自動送的」。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
