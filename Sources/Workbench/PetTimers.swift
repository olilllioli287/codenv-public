import AppKit
import SwiftUI

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
    }

    private(set) var tasks: [String: Task] = [:]
    private var nextOrder = 0
    static let finishedShow: TimeInterval = 3

    /// 開始一個任務（同一個 id 再開一次＝重新計時）
    mutating func start(id: String, label: String, eta: TimeInterval?, total: Int?, now: Date = Date()) {
        nextOrder += 1
        tasks[id] = Task(label: label, started: now, updated: now, eta: eta, done: total == nil ? nil : 0, total: total,
                         order: tasks[id]?.order ?? nextOrder)
    }

    /// 回報完成幾題。沒開始過的任務直接當作現在開始
    mutating func update(id: String, done: Int, total: Int?, now: Date = Date()) {
        if tasks[id] == nil { nextOrder += 1 }
        var t = tasks[id] ?? Task(label: id, started: now, updated: now, order: nextOrder)
        t.done = done
        if let total { t.total = total }
        t.updated = now
        tasks[id] = t
    }

    mutating func finish(id: String, now: Date = Date()) {
        guard var t = tasks[id] else { return }
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
                if done > 0 { left = elapsed / Double(done) * Double(total - min(done, total)) }
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
            let fit = max(1, Int(geo.size.height / Self.rowH))
            let shown = items.count > fit ? Array(items.prefix(fit - 1)) : items
            let extra = items.count - shown.count
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                if extra > 0 {
                    Text(L("＋\(extra)")).font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(height: Self.rowH, alignment: .leading)
                }
                // 由下往上：最早開始的在最下面
                ForEach(Array(shown.reversed()), id: \.id) { row($0) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
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

/// 放在 PetSlotView 左半；沒任務時整塊不吃滑鼠、不畫
final class PetTimersHost: NSHostingView<PetTimersView> {
    required init(rootView: PetTimersView) { super.init(rootView: rootView) }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { PetTimers.shared.isEmpty ? nil : super.hitTest(point) }
}
