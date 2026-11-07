import AppKit

/// 每日交接的單件結果（MainWindowController.startHandoff 的背景模式回報）
enum HandoffOutcome {
    case success
    case deferred(String)   // 正在回答、權限詢問…：不算失敗，下一輪再試
    case failed(String)
}

/// 每日交接。
/// 每天 Prefs.dailyHandoffHour 點為分界；App 開著時，過了分界就把符合條件的 Claude 聊天室一件一件在背景交接：
/// 未封存、一般聊天室、上次交接後有新對話、上下文夠大。實際交接走 MainWindowController.startHandoff（背景模式：不改選取、不搶焦點）。
final class DailyHandoff {
    private let store: Store
    private weak var main: MainWindowController?
    private let testing = CommandLine.arguments.contains("--state-dir")

    private var timer: Timer?
    private var queue: [UUID] = []
    private var running = false
    private var observers: [Any] = []

    static let contextTokenThreshold = 20_000
    static let transcriptBytesThreshold: UInt64 = 200 * 1024
    static let lowUsagePercent = 15
    /// 新聊天室的紀錄會在「交接完成」之後才收到 Claude 的回覆；這段時間內的新內容不算「交接後又聊過」
    static let graceAfterHandoff: TimeInterval = 600

    init(store: Store, main: MainWindowController) {
        self.store = store
        self.main = main
    }

    // MARK: 啟動與觸發

    /// 啟動：10 分鐘一次，另外在 App 啟動後、睡眠醒來、變成前景時各檢查一次。
    /// 測試實例（有 --state-dir）不自動檢查，避免花到真的額度；要測請用 --daily-handoff-now，或另外加 --daily-handoff-auto。
    func start() {
        let auto = !testing || CommandLine.arguments.contains("--daily-handoff-auto")
        guard auto, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in self?.check("定時") }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self?.check("睡眠醒來") }   // 醒來等網路回來
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.check("回到前景")
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.check("啟動") }   // 等版面、用量先載入
    }

    // MARK: 一天的紀錄（daily-handoff.json）

    private struct DayState: Codable {
        var day: String = ""
        var started = 0                       // 今天已開始的件數（延後的不算）
        var failures: [String: Int] = [:]     // 聊天室 UUID → 今天失敗次數
        var memoryChecked: Bool?              // 今天跑過記憶容量檢查了（舊檔沒有這欄＝nil）
    }

    private var stateURL: URL { store.directory.appendingPathComponent("daily-handoff.json") }

    private func loadState(for boundary: Date) -> DayState {
        let key = Self.dayKey(boundary)
        if let data = try? Data(contentsOf: stateURL), let s = try? JSONDecoder().decode(DayState.self, from: data), s.day == key { return s }
        return DayState(day: key)
    }

    private func saveState(_ s: DayState) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    private static func dayKey(_ boundary: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: boundary)
    }

    /// 最近一次分界：今天分界時間已過就是今天的，還沒到就是昨天的
    func boundary(now: Date) -> Date {
        let cal = Calendar.current
        let hour = min(23, max(0, Prefs.shared.dailyHandoffHour))
        let today = cal.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now
        return today > now ? (cal.date(byAdding: .day, value: -1, to: today) ?? today) : today
    }

    // MARK: 挑對象

    private struct Candidate { let id: UUID; let modified: Date; let isChief: Bool }

    private func isChief(_ id: UUID) -> Bool { store.sessions.contains { $0.chief == id } }

    private func candidates(state: DayState, boundary: Date) -> [Candidate] {
        var out: [Candidate] = []
        for c in store.conversations {
            guard Store.isChat(c), c.modelCategory == "claude", !store.isArchived(c),
                  let path = store.project(c.projectID)?.path, Store.claudeHasSession(c.claudeSession, path: path),
                  (state.failures[c.id.uuidString] ?? 0) < 2 else { continue }
            let url = Store.claudeTranscript(c.claudeSession, path: path)
            guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modified = a[.modificationDate] as? Date, let size = (a[.size] as? NSNumber)?.uint64Value else { continue }
            // 有新對話：交接過的看紀錄是否比上次交接晚（今天已交接過就不再做）；從沒交接過的看分界前 24 小時內有沒有新內容
            if let last = c.lastHandoffAt {
                guard last < boundary, modified > last.addingTimeInterval(Self.graceAfterHandoff) else { continue }
            } else {
                guard modified >= boundary.addingTimeInterval(-24 * 3600) else { continue }
            }
            // 上下文夠大：ContextMonitor 的數字 ≥ 20K token；拿不到數字就看紀錄檔 ≥ 200 KB
            if let tokens = ContextMonitor.shared.tokens[c.id] {
                guard tokens >= Self.contextTokenThreshold else { continue }
            } else {
                ContextMonitor.shared.load(c, path: path)
                guard size >= Self.transcriptBytesThreshold else { continue }
            }
            out.append(Candidate(id: c.id, modified: modified, isChief: isChief(c.id)))
        }
        // 總指揮優先，其次最後活動新到舊
        return out.sorted { $0.isChief != $1.isChief ? $0.isChief : $0.modified > $1.modified }
    }

    /// Claude 的 5 小時或每週剩不到 15% 就暫停（還沒查到用量時不擋）
    private func usageLow() -> String? {
        for b in UsageMonitor.shared.buckets where (b.label == "5 小時" || b.label == "每週") && b.remaining < Self.lowUsagePercent {
            return L("Claude \(b.label)額度只剩 \(b.remaining)%")
        }
        return nil
    }

    // MARK: 排隊與執行

    /// 檢查一輪（force＝測試用 --daily-handoff-now：忽略「功能開關」，其他條件照常）
    func check(_ reason: String, force: Bool = false) {
        guard force || Prefs.shared.dailyHandoffEnabled, !running, main != nil else { return }
        // 測試實例沒有假摘要器就不跑：絕不能呼叫真的 claude
        if testing, Handoff.fakeFile == nil { return }
        let now = ScheduleStore.now()
        let b = boundary(now: now)
        var state = loadState(for: b)
        // 記憶容量檢查（唯讀、不花額度，所以排在用量檢查前）：每天一次，超過上限才在看板開提議，不自動改任何記憶檔
        if state.memoryChecked != true { state.memoryChecked = true; saveState(state); MemoryAdvice.checkCapacity() }
        if let why = usageLow() { log("暫停：\(why)，等下一次檢查", once: true); return }
        let room = max(0, Prefs.shared.dailyHandoffMax - state.started)
        guard room > 0 else { return }
        let list = Array(candidates(state: state, boundary: b).prefix(room))
        guard !list.isEmpty else { return }
        saveState(state)
        queue = list.map(\.id)
        running = true
        EventLog.log("每日交接", "\(reason)檢查：排入 \(queue.count) 件")
        step()
    }

    private var gapSeconds: TimeInterval {
        if testing, let i = CommandLine.arguments.firstIndex(of: "--daily-handoff-gap"), i + 1 < CommandLine.arguments.count,
           let s = Double(CommandLine.arguments[i + 1]) { return s }
        return 20
    }

    private func finishRound() { running = false; queue = [] }

    private func step(after delay: TimeInterval = 0) {
        let go: @Sendable () -> Void = { [weak self] in self?.runNext() }
        if delay > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: go) } else { DispatchQueue.main.async(execute: go) }
    }

    private func runNext() {
        guard let main else { return finishRound() }
        guard !queue.isEmpty else { return finishRound() }
        if let why = usageLow() { log("暫停：\(why)，剩下 \(queue.count) 件等下一次檢查"); return finishRound() }
        let id = queue.removeFirst()
        let b = boundary(now: ScheduleStore.now())
        var state = loadState(for: b)
        guard state.started < Prefs.shared.dailyHandoffMax else { log("今天已到上限 \(Prefs.shared.dailyHandoffMax) 件"); return finishRound() }
        guard let c = store.conversation(id), !store.isArchived(c), let dir = store.project(c.projectID)?.path else { return step() }
        // 正在用的不交接（重開後正在聊的這段被交接掉）：擺在眼前的 Window、或 30 分鐘內有新對話的，留到閒下來
        if let why = inUse(c, dir: dir) { EventLog.log("每日交接", "延後：\(c.title)（\(why)）"); return step() }
        state.started += 1; saveState(state)
        let label = c.title
        EventLog.log("每日交接", "開始：\(label)")
        main.startHandoff(c, directory: dir, background: true) { [weak self] outcome in
            guard let self else { return }
            var s = self.loadState(for: b)
            switch outcome {
            case .success:
                EventLog.log("每日交接", "成功：\(label)")
                self.step(after: self.gapSeconds)
            case .deferred(let why):
                s.started = max(0, s.started - 1)
                EventLog.log("每日交接", "延後：\(label)（\(why)）")
                self.step()
            case .failed(let why):
                s.failures[id.uuidString, default: 0] += 1
                EventLog.log("每日交接", "失敗：\(label)（\(why)）")
                self.step(after: self.gapSeconds)
            }
            self.saveState(s)
        }
    }

    private func inUse(_ c: Conversation, dir: String) -> String? {
        if CommandLine.arguments.contains("--daily-handoff-now") { return nil }   // 測試掛鉤：照舊立刻跑
        if NSApp.isActive || NSApp.windows.contains(where: { $0.isVisible && $0.isKeyWindow }) {
            let visible = (store.currentWindow?.root?.leaves.contains(c.id) ?? false)
                || store.sessions.contains { $0.windows.contains { $0.detached && $0.root?.leaves.contains(c.id) == true } }
            if visible { return L("正擺在畫面上") }
        }
        let url = Store.claudeTranscript(c.claudeSession, path: dir)
        if let m = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
           ScheduleStore.now().timeIntervalSince(m) < 30 * 60 { return L("30 分鐘內還在用") }
        return nil
    }

    private var lastLogged = ""
    private func log(_ message: String, once: Bool = false) {
        if once { guard lastLogged != message else { return }; lastLogged = message }
        EventLog.log("每日交接", message)
    }
}
