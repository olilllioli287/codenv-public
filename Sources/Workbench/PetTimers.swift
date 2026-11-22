import AppKit
import SwiftUI
import Combine

// 計時器：桌寵空位左半的 pet-progress 進度列。訂閱桌寵同一個通知（com.local.desktoppet.progress），
// 規則照 desktop-pet/ProgressModel.swift（下面那段是搬過來的純邏輯）：超時變紅停 99%、完成顯示 3 秒、沒消息太久自動拿掉。


struct TimerItem: Equatable {
    enum State: Equatable { case running, finished, overdue }
    let id: String
    let fraction: Double      // 0～1
    let percent: Int          // 圓圈中間的數字
    let minutesLeft: Int?     // 估得出來才有
    let state: State
}

struct ProgressHistoryEntry: Codable {
    var totalSeconds: TimeInterval
    var secondsPerItem: TimeInterval?
    var samples: Int
    var updatedAt: Date
}

struct PetProgressModel {
    struct Task {
        var label: String
        var started: Date
        var updated: Date
        var eta: TimeInterval?     // 預計總共要幾秒
        var done: Int?
        var total: Int?
        var finishedAt: Date?
        var order = 0              // 開始的先後；同一秒開始的任務也排得穩，圈不會左右跳
        var historyKey: String = ""
        var historicSecondsPerItem: TimeInterval?
        var emaSecondsPerItem: TimeInterval?
        var speedSampleAt: Date?
        var speedSampleDone: Int?
    }

    private(set) var tasks: [String: Task] = [:]
    private var nextOrder = 0
    private(set) var history: [String: ProgressHistoryEntry] = [:]
    private let historyURL: URL
    static let finishedShow: TimeInterval = 3
    static let emaAlpha = 0.3

    init(historyURL: URL? = nil) {
        if let historyURL { self.historyURL = historyURL }
        else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.historyURL = support.appendingPathComponent("com.local.desktoppet", isDirectory: true).appendingPathComponent("progress-history.json")
        }
        if let data = try? Data(contentsOf: self.historyURL), let rows = try? JSONDecoder.progressHistory.decode([String: ProgressHistoryEntry].self, from: data) { history = rows }
    }

    static func historyKey(label: String, id: String) -> String {
        let source = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? id : label
        let stripped = source.replacingOccurrences(of: #"\d+"#, with: "", options: .regularExpression)
        let words = stripped.lowercased().split(whereSeparator: { $0.isWhitespace })
        return words.joined(separator: " ").isEmpty ? id.lowercased() : words.joined(separator: " ")
    }

    private mutating func saveHistory() {
        guard let data = try? JSONEncoder.progressHistory.encode(history) else { return }
        try? FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: historyURL, options: .atomic)
    }

    /// 開始一個任務（同一個 id 再開一次＝重新計時）
    mutating func start(id: String, label: String, eta: TimeInterval?, total: Int?, now: Date = Date()) {
        nextOrder += 1
        let key = Self.historyKey(label: label, id: id)
        let old = history[key]
        let chosenETA = old.map { $0.totalSeconds * 0.7 + (eta ?? $0.totalSeconds) * 0.3 } ?? eta
        tasks[id] = Task(label: label, started: now, updated: now, eta: chosenETA, done: total == nil ? nil : 0, total: total,
                         order: tasks[id]?.order ?? nextOrder, historyKey: key,
                         historicSecondsPerItem: old?.secondsPerItem, emaSecondsPerItem: old?.secondsPerItem)
    }

    /// 回報完成幾題。沒開始過的任務直接當作現在開始
    mutating func update(id: String, done: Int, total: Int?, now: Date = Date()) {
        if tasks[id] == nil { nextOrder += 1 }
        var t = tasks[id] ?? Task(label: id, started: now, updated: now, order: nextOrder)
        let oldDone = t.done ?? 0
        if done > oldDone, oldDone >= 3, let sampleAt = t.speedSampleAt, let sampleDone = t.speedSampleDone, done > sampleDone {
            let sample = max(0, now.timeIntervalSince(sampleAt)) / Double(done - sampleDone)
            if sample.isFinite, sample > 0 { t.emaSecondsPerItem = (t.emaSecondsPerItem ?? sample) * (1 - Self.emaAlpha) + sample * Self.emaAlpha }
        }
        if done >= 3, done > oldDone { t.speedSampleAt = now; t.speedSampleDone = done }
        t.done = done
        if let total { t.total = total }
        t.updated = now
        tasks[id] = t
    }

    mutating func finish(id: String, now: Date = Date()) {
        guard var t = tasks[id] else { return }
        let elapsed = max(0, now.timeIntervalSince(t.started))
        let count = max(t.done ?? 0, t.done == nil ? (t.total ?? 0) : 0)
        let perItem = count > 0 ? elapsed / Double(count) : nil
        let old = history[t.historyKey]
        history[t.historyKey] = ProgressHistoryEntry(totalSeconds: (old?.totalSeconds ?? elapsed) * (1 - Self.emaAlpha) + elapsed * Self.emaAlpha,
            secondsPerItem: perItem.map { (old?.secondsPerItem ?? $0) * (1 - Self.emaAlpha) + $0 * Self.emaAlpha } ?? old?.secondsPerItem,
            samples: (old?.samples ?? 0) + 1, updatedAt: now)
        saveHistory()
        t.finishedAt = now
        t.updated = now
        tasks[id] = t
    }

    mutating func cancel(id: String) { tasks[id] = nil }

    /// 打勾顯示完的、太久沒消息的（回報的程式可能已經掛了）拿掉。回傳有沒有拿掉東西
    @discardableResult
    mutating func prune(now: Date = Date()) -> Bool {
        let before = tasks.count
        tasks = tasks.filter { _, t in
            if let f = t.finishedAt { return now.timeIntervalSince(f) < PetProgressModel.finishedShow }
            let quiet = now.timeIntervalSince(t.updated)
            let limit = max(600, (t.eta ?? 0) * 2)
            return quiet < limit
        }
        return tasks.count != before
    }

    /// 秒 → 分鐘（進位）。先 clamp 再轉 Int：極大的預計時間（1e30）直接轉 Int 會 trap
    static func minutes(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite else { return 0 }
        return Int((min(max(seconds, 0), 7 * 86400 * 10) / 60).rounded(.up))
    }

    func items(now: Date = Date()) -> [TimerItem] {
        tasks.sorted { $0.value.order < $1.value.order }.map { id, t in
            if t.finishedAt != nil {
                return TimerItem(id: id, fraction: 1, percent: 100, minutesLeft: 0, state: .finished)
            }
            let elapsed = max(0, now.timeIntervalSince(t.started))
            var fraction = 0.0
            var left: TimeInterval?
            if let done = t.done, let total = t.total, total > 0 {
                fraction = Double(min(done, total)) / Double(total)
                // 用目前的速度推剩下的時間；剛開始還沒有速度可以參考時，退回用預計時間
                let perItem: TimeInterval?
                if done <= 3 { perItem = t.historicSecondsPerItem ?? (done > 0 ? elapsed / Double(done) : nil) }
                else { perItem = t.emaSecondsPerItem ?? t.historicSecondsPerItem ?? elapsed / Double(done) }
                if let perItem { left = perItem * Double(max(0, total - min(done, total))) }
                else if let eta = t.eta { left = max(0, eta - elapsed) }
            } else if let eta = t.eta, eta > 0 {
                fraction = elapsed / eta
                left = max(0, eta - elapsed)
            }
            // 還沒回報做完之前，最多顯示 99%
            let overdue = t.done == nil && (t.eta.map { elapsed > $0 } ?? false)
            fraction = min(max(fraction, 0), 0.99)
            return TimerItem(id: id, fraction: fraction, percent: Int(fraction * 100),
                            minutesLeft: left.map { Self.minutes($0) },
                            state: overdue ? .overdue : .running)
        }
    }

    /// 只有用時間估的任務需要定時重畫；只看題數的任務，收到回報才重畫
    var needsClock: Bool { tasks.values.contains { $0.finishedAt == nil } }
}


final class PetTimers: ObservableObject {
    static let shared = PetTimers()
    @Published private(set) var tick = 0          // 每次狀態變動或每秒加一，觸發畫面重算
    private(set) var model = PetProgressModel()
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    init() {}

    /// 開始訂閱（沒任務時不開計時器）
    func start() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.local.desktoppet.progress"), object: nil, queue: .main) { [weak self] n in
            self?.handle(n.userInfo ?? [:])
        }
    }

    private func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
    /// Int(Double) 遇到 NaN／無限／超大會崩潰：限在合理範圍內
    private func int(_ d: Double?) -> Int? {
        guard let d, d.isFinite else { return nil }
        return Int(max(-1e9, min(1e9, d)))
    }

    func handle(_ u: [AnyHashable: Any]) {
        guard let cmd = u["cmd"] as? String, let id = u["id"] as? String else { return }
        switch cmd {
        // eta 限在 0～7 天
        case "start": model.start(id: id, label: (u["label"] as? String) ?? id, eta: num(u["eta"]).flatMap { $0.isFinite ? min(max($0, 0), 7 * 86400) : nil }, total: int(num(u["total"])))
        case "update": model.update(id: id, done: int(num(u["done"])) ?? 0, total: int(num(u["total"])))
        case "done": model.finish(id: id)
        case "cancel": model.cancel(id: id)
        default: return
        }
        changed()
    }

    /// 測試用：直接塞一個任務
    func inject(id: String, label: String, eta: TimeInterval?, done: Int? = nil, total: Int? = nil, startedAgo: TimeInterval = 0, finished: Bool = false) {
        let now = Date()
        model.start(id: id, label: label, eta: eta, total: total, now: now.addingTimeInterval(-startedAgo))
        if let done { model.update(id: id, done: done, total: total, now: now) }
        if finished { model.finish(id: id) }
        changed()
    }

    private func changed() {
        model.prune()
        tick &+= 1
        if model.tasks.isEmpty { timer?.invalidate(); timer = nil }
        else if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.model.prune()
                self.tick &+= 1
                if self.model.tasks.isEmpty { self.timer?.invalidate(); self.timer = nil }
            }
        }
    }

    var isEmpty: Bool { model.tasks.isEmpty }
}

struct PetTimersView: View {
    @ObservedObject var timers = PetTimers.shared
    static let rowH: CGFloat = 20

    var body: some View {
        GeometryReader { geo in
            let _ = timers.tick
            let items = timers.model.items()
            let visibleHeight = max(geo.size.height, CGFloat(items.count) * Self.rowH)
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                // 由下往上：最早開始的在最下面
                ForEach(Array(items.reversed()), id: \.id) { row($0) }
            }
            .frame(maxWidth: .infinity, minHeight: visibleHeight, maxHeight: visibleHeight, alignment: .bottomLeading)
        }
        .padding(.leading, 8).padding(.bottom, 4)
    }

    private func row(_ it: TimerItem) -> some View {
        let t = timers.model.tasks[it.id]
        let label = t?.label ?? it.id
        let color: Color = it.state == .finished ? .green : (it.state == .overdue ? .red : .orange)
        var right = ""
        if it.state == .finished { right = "✓" }
        else if let d = t?.done, let tot = t?.total, tot > 0 { right = "\(d)/\(tot)" }
        else if it.state == .overdue { right = L("超時") }
        else if let m = it.minutesLeft { right = L("剩 \(m) 分") }
        return HStack(spacing: 5) {
            ZStack {
                Circle().stroke(color.opacity(0.25), lineWidth: 2)
                Circle().trim(from: 0, to: it.fraction).stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
            }.frame(width: 14, height: 14)
            Text(label).font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 2)
            Text(right).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).fixedSize()
        }
        .frame(height: Self.rowH)
        .help(label)
        .contentShape(Rectangle())
    }
}

private extension JSONDecoder { static var progressHistory: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d } }
private extension JSONEncoder { static var progressHistory: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e } }

/// 放在 PetSlotView 左半；沒任務時整塊不吃滑鼠、不畫
final class PetTimersHost: NSHostingView<PetTimersView> {
    private var timerObservation: AnyCancellable?
    private var minimumHeight: CGFloat = 0
    required init(rootView: PetTimersView) {
        super.init(rootView: rootView)
        timerObservation = PetTimers.shared.$tick.receive(on: RunLoop.main).sink { [weak self] _ in self?.resizeForTasks() }
    }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { PetTimers.shared.isEmpty ? nil : super.hitTest(point) }
    func setMinimumHeight(_ height: CGFloat) { minimumHeight = height; resizeForTasks() }
    private func resizeForTasks() {
        guard let parent = superview else { return }
        let wanted = min(parent.bounds.height, max(minimumHeight, CGFloat(PetTimers.shared.model.tasks.count) * PetTimersView.rowH + 10))
        guard abs(frame.height - wanted) > 0.5 else { return }
        frame.size.height = wanted
    }
}
