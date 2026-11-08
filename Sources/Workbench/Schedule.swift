import AppKit
import SwiftUI

// 排程喚醒：到時間自動送一則訊息給某段對話（對話右鍵「排程…」）。定的範圍
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
        let sep = L("、")
        let t = times.joined(separator: sep)
        switch frequency {
        case "weekly":
            let names = [L("日"), L("一"), L("二"), L("三"), L("四"), L("五"), L("六")]
            // 壞掉的 schedules.json 或編輯畫面可能帶進 0、負數、8 以上：只留 1...7（原本 names[($0-1)%7] 對 0 越界崩潰、8 顯示成「日」）
            let valid = weekdays.filter { (1...7).contains($0) }.sorted()
            let days = valid.isEmpty ? L("（沒有選日子）") : valid.map { names[$0 - 1] }.joined(separator: sep)
            return L("每週\(days) \(t)")
        case "monthly":
            let days = monthDays.sorted().map { L("\($0) 號") }.joined(separator: sep)
            return L("每月 \(days) \(t)")
        case "interval": return L("每隔 \(intervalMinutes) 分鐘")
        default: return L("每天 \(t)")
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
            if let list = try? dec.decode([WakeSchedule].self, from: d) { items = list; loadedOK = !d.isEmpty }
            else if !d.isEmpty {
                // 讀不懂（壞了或新版格式）：原檔另存一份，並且不再存檔蓋掉它（排程變空的話，下次 save 會把原檔洗掉）
                let f = DateFormatter(); f.dateFormat = "MMdd-HHmmss"
                let bad = Self.file.deletingLastPathComponent().appendingPathComponent("schedules.json.讀不到-\(f.string(from: Date()))")
                if (try? d.write(to: bad)) == nil { protectOriginal = true }
                NSLog("排程：schedules.json 讀不到，已另存 %@", bad.lastPathComponent)
                EventLog.log(L("檔案"), L("schedules.json 無法讀取，已備份為 \(bad.lastPathComponent)"))
            }
        } else if (try? Data(contentsOf: Self.file)) == nil, FileManager.default.fileExists(atPath: Self.file.path) {
            protectOriginal = true      // 檔案在但讀不出來（權限、暫時讀不到）：不能當成沒有排程，不然下次存檔會蓋掉。空檔不算（讀得到、沒東西可保護）
            NSLog("排程：schedules.json 存在但讀不出來，本次不存排程")
            EventLog.log(L("檔案"), L("schedules.json 存在但讀不出來，本次不存排程以保護原檔"))
        }
    }

    /// 上一次存檔失敗：下一次 tick 先重存，存好了才送（沒存好就送，當掉重開會重送）
    private var unsaved = false
    /// deliver 的回傳：聊天室沒開著且選了「等它打開再送」／被擋下（同一段對話在別處進行）。不能用 L()：英文介面會比對不到
    static let waitMark = "等待"
    static let blockedMark = "等待（被擋）"
    /// 啟動時沒讀到 state.json（對話清單不可信）：到期的排程不能動
    var suspended = false
    private var retries: [String: Int] = [:]
    /// schedules.json 讀不懂又沒能另存備份：保護原檔，不存檔
    private var protectOriginal = false

    /// 暫存檔＋改名，權限 0600；每一步都檢查，失敗回 false（記憶體裡的改動留著，unsaved 會讓下一次 tick 重試）
    @discardableResult
    private func save() -> Bool {
        guard !protectOriginal else { return false }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let dir = Self.file.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".schedules.\(getpid()).tmp")
        guard let d = try? enc.encode(items),
              (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil,
              FileManager.default.createFile(atPath: tmp.path, contents: d, attributes: [.posixPermissions: 0o600]),
              rename(tmp.path, Self.file.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            unsaved = true
            let errCode = errno
            NSLog("排程存檔失敗：%@", Self.file.path)
            EventLog.log(L("檔案"), L("schedules.json 存檔失敗（errno \(errCode)）"))
            return false
        }
        unsaved = false
        return true
    }

    func has(_ conversation: UUID) -> Bool { items.contains { $0.conversation == conversation && $0.enabled } }
    func of(_ conversation: UUID) -> [WakeSchedule] { items.filter { $0.conversation == conversation } }

    /// 交接只換接收者：不經 put，不重算時間、不清待送與歷史；存不成就保留原本的指向。
    @discardableResult
    func retarget(from old: UUID, to new: UUID) -> Bool {
        guard old != new, items.contains(where: { $0.conversation == old }) else { return true }
        guard !protectOriginal else { return false }
        let original = items
        for i in items.indices where items[i].conversation == old { items[i].conversation = new }
        if save() { return true }
        items = original
        return false
    }

    /// 新增或改一個排程（下一次時間從現在重算）
    /// saved：存好了；retrying：這次寫檔失敗，排程留在記憶體、每 30 秒重試存檔（關掉 codenv 前沒存成就會不見）；refused：保護原檔中，沒有加進去
    enum PutResult { case saved, retrying, refused }

    @discardableResult
    func put(_ s: WakeSchedule, now: Date = ScheduleStore.now()) -> PutResult {
        guard !protectOriginal else { return .refused }
        var s = s
        s.times = Array(s.times.prefix(WakeSchedule.maxTimes))
        s.nextAt = s.enabled ? s.next(after: now) : nil
        if let i = items.firstIndex(where: { $0.id == s.id }) {
            // 待送和紀錄以現在的為準：編輯表單是開表單時的舊副本，不能把已處理的待送復活
            // 改了時間設定、或改成「沒開就跳過」：舊的待送不再送（只改文字的保留，會送新的字；agy Argon 11/6）
            let o = items[i]
            let timingChanged = o.frequency != s.frequency || o.times != s.times || o.weekdays != s.weekdays || o.monthDays != s.monthDays
                || o.intervalMinutes != s.intervalMinutes || o.until != s.until
            s.runs = o.runs
            s.pendingRun = s.enabled && !timingChanged && s.whenClosed != "skip" ? o.pendingRun : nil
            items[i] = s
        } else { items.append(s) }
        return save() ? .saved : .retrying
    }

    func remove(_ id: UUID) { items.removeAll { $0.id == id }; save() }

    func setEnabled(_ id: UUID, _ on: Bool, now: Date = ScheduleStore.now()) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].enabled = on
        items[i].nextAt = on ? items[i].next(after: now) : nil
        if !on { items[i].pendingRun = nil }
        save()
    }

    /// 每次啟動把 schedules.json 複製一份到 .備份（只做一次；檔案不存在就略過）
    func backupOncePerLaunch() {
        backupOnce()
    }
    /// 這次啟動 schedules.json 有沒有讀懂（而且不是空檔）
    private var loadedOK = false
    private func backupOnce() {
        let fm = FileManager.default
        let src = Self.file
        // 只有這次真的讀懂了才更新備份：壞檔、空檔不能蓋掉原本好的 .備份（agy Argon 11/6）
        guard !protectOriginal, loadedOK, fm.fileExists(atPath: src.path) else { return }
        let dst = src.appendingPathExtension("備份")
        // 先複製到暫存檔再替換：複製失敗時，上一份好的備份還在（原本先刪再複製，複製失敗就一份都沒了）
        let tmp = src.appendingPathExtension("備份-\(ProcessInfo.processInfo.processIdentifier).tmp")
        try? fm.removeItem(at: tmp)
        do {
            try fm.copyItem(at: src, to: tmp)
            if fm.fileExists(atPath: dst.path) { _ = try fm.replaceItemAt(dst, withItemAt: tmp) } else { try fm.moveItem(at: tmp, to: dst) }
        } catch {
            try? fm.removeItem(at: tmp)
            EventLog.log("排程", "更新備份失敗，沿用上一份：\(error.localizedDescription)")
        }
    }

    /// 對話被刪掉時，它的排程一起拿掉
    func removeSchedules(for conversation: UUID) {
        let before = items.count
        items.removeAll { $0.conversation == conversation }
        if items.count != before { save() }
    }

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

    /// 時間＋排程編號：同一個聊天室同一分鐘有兩個排程到期，標記不能一樣，不然當掉重開會把沒送的那則當成已經送過
    static func marker(_ s: WakeSchedule, _ due: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy/M/d HH:mm"      // 要有年份：每月／每週的排程隔年同一天同一時間，標記不能一樣（不然去年那則還在紀錄檔尾端 512 KB 內，這次會被當成已送出）
        return "〔codenv 排程 \(f.string(from: due)) #\(s.id.uuidString.prefix(8).lowercased())〕"
    }

    /// 舊格式（沒有年份）的標記：升版當下紀錄檔裡可能還留著舊格式、剛好當掉沒清 pendingRun 的那一則，防重送要認得，不然重送一次
    static func legacyMarker(_ marker: String) -> String {
        marker.replacingOccurrences(of: #"排程 \d{4}/"#, with: "排程 ", options: .regularExpression)
    }

    static func message(_ s: WakeSchedule, due: Date) -> String {
        marker(s, due) + "這是排程自動送的，不是使用者本人現在說的。\n\n" + s.text
    }

    private func sentToday(_ now: Date) -> Int {
        items.flatMap(\.runs).filter { $0.result == "已送出" && Calendar.current.isDate($0.at, inSameDayAs: now) }.count
    }

    private func record(_ i: Int, due: Date, now: Date, _ result: String) {
        items[i].runs.append(ScheduleRun(at: now, due: due, result: result))
        // 只留最近 30 筆；但今天已送出的要留著（每日上限靠它們計數），先丟別的舊紀錄
        while items[i].runs.count > 30 {
            let drop = items[i].runs.firstIndex { !($0.result == "已送出" && Calendar.current.isDate($0.at, inSameDayAs: now)) } ?? 0
            items[i].runs.remove(at: drop)
        }
    }

    func tick(now: Date = ScheduleStore.now()) {
        // schedules.json 在但讀不出來、不敢存檔：記憶體裡的排程到期也不能送（送了又存不下「已送」，重開後會重送或全消失）
        guard !protectOriginal, !suspended else { return }
        if unsaved { save() }   // 上次沒存成功的，這次先補存（不管這次有沒有排程到期）
        var changed = false
        for i in items.indices where items[i].enabled {
            // 新到期的：先推下一次、記待送、存檔，再處理（當掉也不漏不重送）
            if let n = items[i].nextAt, n <= now {
                // 上一次還沒送出（等聊天室打開、被擋在別處）就到了下一次：舊的那次記跳過、改送最新這次
                // （原本是把新的記跳過、照樣送舊的，送出去的是過時的那班；agy Argon 11/6）
                if let old = items[i].pendingRun {
                    record(i, due: old, now: now, "跳過：還沒送出就到了下一次")
                    retries["\(items[i].id.uuidString)-\(old.timeIntervalSince1970)"] = nil
                }
                items[i].pendingRun = n
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
            if unsaved, !save() { continue }   // 待送的狀態還沒存好：不送，下次 tick 再試（送了又當掉會重送）
            if alreadySent(s.conversation, Self.marker(s, due)) {
                result = nil   // 上次送到一半當掉：其實送出去了
            } else if sentToday(now) >= Self.dailyLimit {
                result = "跳過：超過每日上限（\(Self.dailyLimit) 則）"
            } else {
                result = deliver(s, Self.message(s, due: due), due)
            }
            if result == Self.waitMark { continue }   // 聊天室沒開、選了「等它打開再送」
            var final = result
            let retryKey = "\(s.id.uuidString)-\(due.timeIntervalSince1970)"
            if result == Self.blockedMark {
                // 被擋下（同一段對話在別處進行）：每 30 秒重試一次，最多 10 次（約 5 分鐘）就放棄這次，不然永遠重試
                let n = (retries[retryKey] ?? 0) + 1
                retries[retryKey] = n
                if n <= 10 { continue }
                final = "跳過：這段對話一直在別處進行，這次沒送"
            }
            retries[retryKey] = nil
            record(i, due: due, now: now, final ?? "已送出")
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
            Text(L("排程：\(title)")).font(.headline)
            Text(L("會送給：\(model)。codenv 沒開著就不送；全部排程合計每天最多 \(ScheduleStore.dailyLimit) 則。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let d = Binding($draft) {
                ScheduleForm(s: d)
                HStack {
                    Spacer()
                    Button(L("取消")) { draft = nil }.keyboardShortcut(.cancelAction)
                    Button(L("存")) {
                        // 算不出下一次（時間、日期看不懂，或每週一天都沒勾）：先講清楚，不存（不然 30 秒後會自己變暫停）
                        if let s = draft, s.enabled, s.next(after: ScheduleStore.now()) == nil {
                            let a = NSAlert(); a.alertStyle = .warning
                            a.messageText = L("排程的時間或日期看不懂")
                            a.informativeText = L("時間請寫成 09:00（多個用逗號分開）；每月寫 1、15 這樣的數字；每週至少勾一天；截止日要在之後。")
                            a.runModal()
                            return
                        }
                        if let s = draft, case let r = store.put(s), r != .saved {
                            let a = NSAlert(); a.alertStyle = .warning
                            if r == .refused {
                                a.messageText = L("排程沒有加進去")
                                a.informativeText = L("schedules.json 讀不懂，codenv 為了保護原檔先不改它，所以這個排程沒有加。請確認檔案（或用備份還原）後重開 codenv，再設一次。")
                            } else {
                                a.messageText = L("排程還沒存進檔案")
                                a.informativeText = L("schedules.json 暫時寫不進去（權限、磁碟）。這個排程目前在記憶體裡會照常執行，codenv 會每 30 秒再試著存；在存成功之前關掉 codenv 就會不見。")
                            }
                            a.runModal()
                        }
                        draft = nil
                    }
                        .keyboardShortcut(.defaultAction)
                        .disabled(draft?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                }
            } else {
                let list = store.of(conversation)
                if list.isEmpty { Text(L("還沒有排程")).foregroundStyle(.secondary) }
                ForEach(list) { s in ScheduleRowView(s: s, edit: { draft = s }) }
                HStack {
                    Button { draft = WakeSchedule(conversation: conversation, text: "") } label: { Label(L("新增排程"), systemImage: "plus") }
                    Spacer()
                    Button(L("關閉"), action: close).keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(18).frame(width: 460)
    }
}

/// 一個排程的設定欄位
struct ScheduleForm: View {
    @Binding var s: WakeSchedule
    @State private var timesDraft: String?
    @State private var monthDaysDraft: String?
    var body: some View {
        Form {
            TextField(L("要送的話"), text: $s.text, axis: .vertical).lineLimit(3...6)
            Picker(L("頻率"), selection: $s.frequency) {
                Text(L("每天")).tag("daily"); Text(L("每週")).tag("weekly"); Text(L("每月")).tag("monthly"); Text(L("每隔幾分鐘")).tag("interval")
            }
            if s.frequency == "interval" {
                Stepper(L("每隔 \(s.intervalMinutes) 分鐘"), value: $s.intervalMinutes, in: 5...1440, step: 5)
            } else {
                TextField(L("時間（24 小時制，逗號分開，最多 6 個）"), text: Binding(
                    get: { timesDraft ?? s.times.joined(separator: ", ") },
                    set: { timesDraft = $0; commitTimes() }))      // 邊打邊存（沒按 Enter 就關掉也不會丟）；畫面上顯示打字的原樣，逗號才不會被抹掉
                    .onSubmit { timesDraft = nil }
                if s.frequency == "weekly" {
                    HStack(spacing: 4) {
                        ForEach(1...7, id: \.self) { d in
                            Toggle(L(["日", "一", "二", "三", "四", "五", "六"][d - 1]), isOn: Binding(
                                get: { s.weekdays.contains(d) },
                                set: { on in if on { s.weekdays.append(d) } else { s.weekdays.removeAll { $0 == d } } }))
                            .toggleStyle(.button)
                        }
                    }
                }
                if s.frequency == "monthly" {
                    TextField(L("每月幾號（逗號分開）"), text: Binding(
                        get: { monthDaysDraft ?? s.monthDays.map(String.init).joined(separator: ", ") },
                        set: { monthDaysDraft = $0; commitMonthDays() }))
                        .onSubmit { monthDaysDraft = nil }
                }
            }
            Toggle(L("有截止日"), isOn: Binding(get: { s.until != nil }, set: { s.until = $0 ? (s.until ?? Date().addingTimeInterval(7 * 86400)) : nil }))
            if s.until != nil {
                DatePicker(L("截止"), selection: Binding(get: { s.until ?? Date() }, set: { s.until = $0 }))
            }
            Picker(L("聊天室沒開著時"), selection: $s.whenClosed) {
                Text(L("開起來送")).tag("open"); Text(L("等它打開再送")).tag("wait"); Text(L("跳過")).tag("skip")
            }
        }
        .formStyle(.grouped)
    }

    /// 全形數字、全形冒號換成半形（中文輸入法常打出「09：00」，原本讀不懂、存了 30 秒後自己變暫停；agy Argon 11/6）
    static func halfWidth(_ t: String) -> String {
        String(t.map { c -> Character in
            if c == "：" { return ":" }
            if let u = c.unicodeScalars.first, (0xFF10...0xFF19).contains(u.value) { return Character(UnicodeScalar(u.value - 0xFF10 + 0x30)!) }
            return c
        })
    }

    private func commitTimes() {
        guard let value = timesDraft else { return }
        s.times = Self.halfWidth(value).split(whereSeparator: { ",，、 ".contains($0) }).map { t -> String in
            let t = String(t)
            // 「0900」「900」沒冒號：補成 09:00
            if !t.contains(":"), t.count >= 3, t.count <= 4, t.allSatisfy(\.isNumber) { return String(t.dropLast(2)) + ":" + String(t.suffix(2)) }
            return t
        }.filter { !$0.isEmpty }
    }

    private func commitMonthDays() {
        guard let value = monthDaysDraft else { return }
        // 「15號」「15日」也認得（只取數字）
        s.monthDays = Self.halfWidth(value).split(whereSeparator: { ",，、 ".contains($0) })
            .compactMap { Int($0.filter(\.isNumber)) }.filter { (1...31).contains($0) }
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
                        if let model { Text(L("送給 \(model)")) }
                        Text(s.enabled ? L("下一次 \(s.nextAt.map { Self.fmt($0) } ?? "—")") : L("暫停中"))
                        if s.pendingRun != nil { Text(L("等聊天室打開")).foregroundStyle(.orange) }
                    }.font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer()
                if let edit { Button(L("改"), action: edit).controlSize(.small) }
                Button(role: .destructive) { store.remove(s.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help(L("刪掉這個排程"))
            }
            if !s.runs.isEmpty {
                DisclosureGroup(L("最近 \(s.runs.count) 次"), isExpanded: $showRuns) {
                    ForEach(Array(s.runs.reversed().enumerated()), id: \.offset) { _, r in
                        Text(L("\(Self.fmt(r.due))　\(r.result)")).font(.system(size: 10.5)).foregroundStyle(r.result == "已送出" ? .secondary : Color.orange)
                    }
                }.font(.system(size: 10.5))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
    }

    static func fmt(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = Calendar.current.isDateInToday(d) ? "今天 HH:mm" : "yyyy/M/d HH:mm"
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
                    Text(L("還沒有排程。在側欄的對話上按右鍵 →「排程…」新增。")).foregroundStyle(.secondary)
                }
                ForEach(schedules.items) { s in
                    ScheduleRowView(s: s, model: store.displayModel(s.conversation), conversationTitle: store.conversation(s.conversation)?.title ?? L("（對話已刪除）"))
                }
            } footer: {
                Text(L("codenv 沒開著就不送，重開時錯過好幾次只補一次。全部排程合計每天最多 \(ScheduleStore.dailyLimit) 則，超過的記成「超過每日上限」。送出去的訊息開頭會寫「這是排程自動送的」。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
