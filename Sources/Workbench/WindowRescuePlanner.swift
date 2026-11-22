import AppKit
import CoreGraphics
import Foundation

// 點 Dock 視窗救援第一階段（純邏輯狀態機與可注入執行器，不直接綁定真 NSWindow）
// 僅在偵測到異常時依序執行：① Space（暫加 .moveToActiveSpace＋下個 run loop 還原）→ ② 座標搬回主螢幕可見區 → ③ orderOut 再 orderFront。
// 不重建視窗、不做無條件 orderFront；含進行中防重入、60 秒冷卻與每次啟動總次數上限（5 次）。

/// 單次量測到的主視窗救援狀態
struct WindowRescueState: Equatable, Sendable {
    var isKey: Bool
    var isMain: Bool
    var occVisible: Bool
    /// 以 CGWindowListCopyWindowInfo(.optionAll) 查得的 kCGWindowIsOnscreen（true / false / nil）
    var wsOnscreen: Bool?
    var isOnActiveSpace: Bool
    var frame: WindowSnapshotRect
    var frameInUnion: Bool
    /// 主螢幕可見區（供步驟 2 搬回置中與縮放）
    var primaryVisibleFrame: WindowSnapshotRect?

    /// 異常判定：主視窗 key 或 main 為 true，且 WindowServer onscreen（.optionAll）不是 true 或 occlusionState 不含 .visible
    var isAnomalous: Bool {
        (isKey || isMain) && (wsOnscreen != true || !occVisible)
    }

    /// 已救回判定：WindowServer onscreen 為 true 且 occlusionState 含 .visible
    var isRecovered: Bool {
        wsOnscreen == true && occVisible
    }

    var anomalyReason: String {
        let wsBad = wsOnscreen != true
        let occBad = !occVisible
        switch (wsBad, occBad) {
        case (true, true): return "ws_not_onscreen+occ_hidden"
        case (true, false): return "ws_not_onscreen"
        case (false, true): return "occ_hidden"
        case (false, false): return "none"
        }
    }
}

enum WindowRescueStep: Int, CaseIterable, Equatable, Sendable {
    case moveToActiveSpace = 1
    case moveToPrimaryScreen = 2
    case orderOutAndFront = 3

    var actionCode: String {
        switch self {
        case .moveToActiveSpace: return "space"
        case .moveToPrimaryScreen: return "frame"
        case .orderOutAndFront: return "backing"
        }
    }

    var hypothesisLabel: String {
        switch self {
        case .moveToActiveSpace: return "Space"
        case .moveToPrimaryScreen: return "座標"
        case .orderOutAndFront: return "backing"
        }
    }

    var next: WindowRescueStep? {
        WindowRescueStep(rawValue: rawValue + 1)
    }
}

enum WindowRescueSkipReason: Error, Equatable, Sendable {
    case noAnomaly
    case alreadyInProgress
    case cooldown(remaining: TimeInterval)
    case launchLimitReached(count: Int, max: Int)
}

enum WindowRescueStepPlan: Equatable, Sendable {
    case executeMoveToActiveSpace
    case executeMoveToPrimaryScreen(targetFrame: WindowSnapshotRect, visibleFrame: WindowSnapshotRect)
    case executeOrderOutAndFront
    case skip(reason: String)
}

enum WindowRescuePostStepOutcome: Equatable, Sendable {
    case recovered(step: WindowRescueStep)
    case proceedTo(WindowRescueStep)
    case exhausted
}

/// 純狀態機：決定是否啟動救援、每一步該執行或略過、以及步驟後是否已救回
struct WindowRescuePlanner {
    static let defaultCooldownDuration: TimeInterval = 60.0
    static let defaultMaxAttemptsPerLaunch = 5
    static let defaultSettleDelay: TimeInterval = 0.3

    let cooldownDuration: TimeInterval
    let maxAttemptsPerLaunch: Int
    let settleDelay: TimeInterval
    private let clock: @Sendable () -> TimeInterval

    private(set) var isInProgress = false
    private(set) var attemptCount = 0
    private(set) var lastAttemptStartTime: TimeInterval?

    init(
        cooldownDuration: TimeInterval = WindowRescuePlanner.defaultCooldownDuration,
        maxAttemptsPerLaunch: Int = WindowRescuePlanner.defaultMaxAttemptsPerLaunch,
        settleDelay: TimeInterval = WindowRescuePlanner.defaultSettleDelay,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.cooldownDuration = cooldownDuration
        self.maxAttemptsPerLaunch = maxAttemptsPerLaunch
        self.settleDelay = settleDelay
        self.clock = clock
    }

    /// 決定是否開始一輪救援；通過時回傳第幾次救援（1-based）並鎖定進行中狀態
    mutating func beginAttempt(
        initialState: WindowRescueState,
        at explicitNow: TimeInterval? = nil
    ) -> Result<Int, WindowRescueSkipReason> {
        guard initialState.isAnomalous else {
            return .failure(.noAnomaly)
        }
        if isInProgress {
            return .failure(.alreadyInProgress)
        }
        if attemptCount >= maxAttemptsPerLaunch {
            return .failure(.launchLimitReached(count: attemptCount, max: maxAttemptsPerLaunch))
        }
        let now = explicitNow ?? clock()
        let eps: TimeInterval = 1e-9
        if let last = lastAttemptStartTime {
            let elapsed = now - last
            if elapsed + eps < cooldownDuration {
                return .failure(.cooldown(remaining: max(0, cooldownDuration - elapsed)))
            }
        }
        isInProgress = true
        attemptCount += 1
        lastAttemptStartTime = now
        return .success(attemptCount)
    }

    /// 依目前狀態決定第 step 步應執行或略過
    func plan(step: WindowRescueStep, state: WindowRescueState) -> WindowRescueStepPlan {
        switch step {
        case .moveToActiveSpace:
            if state.isOnActiveSpace {
                return .skip(reason: "已在作用中Space")
            }
            return .executeMoveToActiveSpace
        case .moveToPrimaryScreen:
            if state.frameInUnion {
                return .skip(reason: "frame在有效螢幕內")
            }
            guard let visible = state.primaryVisibleFrame, visible.width > 0, visible.height > 0 else {
                return .skip(reason: "無主螢幕可見區")
            }
            let target = Self.centeredFrame(currentFrame: state.frame, inVisibleFrame: visible)
            return .executeMoveToPrimaryScreen(targetFrame: target, visibleFrame: visible)
        case .orderOutAndFront:
            return .executeOrderOutAndFront
        }
    }

    /// 每步等 0.3 秒量測後判定：已救回就停，否則進下一步或結束
    func evaluateAfter(step: WindowRescueStep, measuredState: WindowRescueState) -> WindowRescuePostStepOutcome {
        if measuredState.isRecovered {
            return .recovered(step: step)
        }
        if let nextStep = step.next {
            return .proceedTo(nextStep)
        }
        return .exhausted
    }

    mutating func finishAttempt() {
        isInProgress = false
    }

    mutating func reset() {
        isInProgress = false
        attemptCount = 0
        lastAttemptStartTime = nil
    }

    /// 步驟 2 座標計算：保持原大小置中於主螢幕可見區；任一軸大於可見區則縮至可見區大小
    static func centeredFrame(
        currentFrame: WindowSnapshotRect,
        inVisibleFrame visible: WindowSnapshotRect
    ) -> WindowSnapshotRect {
        let clampedW = max(1, min(max(currentFrame.width, 1), max(visible.width, 1)))
        let clampedH = max(1, min(max(currentFrame.height, 1), max(visible.height, 1)))
        let centeredX = visible.x + Int((Double(visible.width - clampedW) / 2.0).rounded())
        let centeredY = visible.y + Int((Double(visible.height - clampedH) / 2.0).rounded())
        return WindowSnapshotRect(x: centeredX, y: centeredY, width: clampedW, height: clampedH)
    }
}

/// 可注入的救援目標介面（實機包 NSWindow，單元測試與 --window-diag-inject rescue-ok 包假視窗）
@MainActor
protocol WindowRescueTarget: AnyObject {
    var collectionBehaviorRaw: UInt { get set }
    var frame: WindowSnapshotRect { get }
    func makeKeyAndOrderFront()
    func setFrame(_ rect: WindowSnapshotRect)
    func orderOut()
    func orderFront()
    /// 監聽視窗關閉事件（供步驟 1 確保 collectionBehavior 一定會還原）；回傳取消監聽的 closure
    func observeWillClose(_ handler: @escaping @MainActor () -> Void) -> () -> Void
    func measureState() -> WindowRescueState
}

/// 救援紀錄格式化（category 固定為「視窗救援」）
enum WindowRescueFormatter {
    static let category = "視窗救援"
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    static func formatStart(attempt: Int, state: WindowRescueState) -> String {
        let occ = state.occVisible ? "visible" : "hidden"
        return "救援#\(attempt) 開始 | 原因=\(state.anomalyReason) | key=\(state.isKey) main=\(state.isMain) occ=\(occ) wsOnscreen=\(fmtWs(state.wsOnscreen)) onActiveSpace=\(state.isOnActiveSpace) frameInUnion=\(state.frameInUnion) frame=\(state.frame.formatted)"
    }

    static func formatStepSkip(attempt: Int, step: WindowRescueStep, reason: String) -> String {
        "救援#\(attempt) 步驟\(step.rawValue) 略過 | 動作=\(step.actionCode) 原因=\(reason)"
    }

    static func formatStep1Execute(attempt: Int, originalBehaviorRaw: UInt, tempBehaviorRaw: UInt) -> String {
        "救援#\(attempt) 步驟1 執行 | 動作=space origBehavior=\(fmtHex(originalBehaviorRaw)) tempBehavior=\(fmtHex(tempBehaviorRaw))"
    }

    static func formatStep1Restore(attempt: Int, restoredBehaviorRaw: UInt, source: String) -> String {
        "救援#\(attempt) 步驟1 還原 | behavior=\(fmtHex(restoredBehaviorRaw)) 來源=\(source)"
    }

    static func formatStep2Execute(
        attempt: Int,
        from: WindowSnapshotRect,
        to: WindowSnapshotRect,
        visibleFrame: WindowSnapshotRect
    ) -> String {
        "救援#\(attempt) 步驟2 執行 | 動作=frame from=\(from.formatted) to=\(to.formatted) visibleFrame=\(visibleFrame.formatted)"
    }

    static func formatStep3Execute(attempt: Int) -> String {
        "救援#\(attempt) 步驟3 執行 | 動作=backing orderOut+orderFront"
    }

    static func formatStepMeasure(attempt: Int, step: WindowRescueStep, state: WindowRescueState) -> String {
        let resultText = state.isRecovered ? "已救回" : "未救回"
        let occ = state.occVisible ? "visible" : "hidden"
        return "救援#\(attempt) 步驟\(step.rawValue) 量測 | 結果=\(resultText) wsOnscreen=\(fmtWs(state.wsOnscreen)) occ=\(occ) onActiveSpace=\(state.isOnActiveSpace) frameInUnion=\(state.frameInUnion) frame=\(state.frame.formatted)"
    }

    static func formatFinishRecovered(attempt: Int, step: WindowRescueStep) -> String {
        "救援#\(attempt) 結束 | 結論=第 \(step.rawValue) 步救回 假設=\(step.hypothesisLabel)"
    }

    static func formatFinishFailed(attempt: Int) -> String {
        "救援#\(attempt) 結束 | 結論=未救回"
    }

    static func formatAttemptSkip(_ reason: WindowRescueSkipReason) -> String? {
        switch reason {
        case .noAnomaly:
            return nil
        case .alreadyInProgress:
            return "救援略過 | 原因=進行中"
        case .cooldown(let remaining):
            let remText = String(format: "%.1f", locale: posixLocale, remaining)
            return "救援略過 | 原因=冷卻中 剩餘=\(remText)s"
        case .launchLimitReached(let count, let max):
            return "救援略過 | 原因=已達啟動上限 次數=\(count)/\(max)"
        }
    }

    private static func fmtWs(_ v: Bool?) -> String {
        guard let v else { return "none" }
        return v ? "true" : "false"
    }

    private static func fmtHex(_ raw: UInt) -> String {
        String(format: "0x%x", raw)
    }
}

/// 協調器：串接 WindowRescuePlanner 與 WindowRescueTarget，負責 0.3 秒等待、步驟 1 collectionBehavior 必定還原、以及記錄每步結果
@MainActor
final class WindowRescueCoordinator {
    typealias DelayScheduler = (_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void
    typealias NextRunLoopScheduler = (_ work: @escaping @MainActor () -> Void) -> Void
    typealias LogSink = (_ category: String, _ message: String) -> Void

    private(set) var planner: WindowRescuePlanner
    private let scheduleNextRunLoop: NextRunLoopScheduler
    private let scheduleAfterDelay: DelayScheduler
    private let sink: LogSink

    private var activeRunID: UInt64 = 0
    private var activeTarget: WindowRescueTarget?
    private var cancelPendingDelay: (() -> Void)?
    private var flushPendingBehaviorRestore: ((_ source: String) -> Void)?

    init(
        planner: WindowRescuePlanner = WindowRescuePlanner(),
        scheduleNextRunLoop: @escaping NextRunLoopScheduler = { work in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { work() }
            }
        },
        scheduleAfterDelay: @escaping DelayScheduler = { delay, work in
            let item = DispatchWorkItem {
                MainActor.assumeIsolated { work() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return { item.cancel() }
        },
        sink: @escaping LogSink = { EventLog.log($0, $1) }
    ) {
        self.planner = planner
        self.scheduleNextRunLoop = scheduleNextRunLoop
        self.scheduleAfterDelay = scheduleAfterDelay
        self.sink = sink
    }

    /// 點 Dock 入口：正常狀態完全不寫「視窗救援」也不改視窗；異常時依序執行救援並記錄每步結果
    @discardableResult
    func trigger(target: WindowRescueTarget, at explicitNow: TimeInterval? = nil) -> Bool {
        let initialState = target.measureState()
        switch planner.beginAttempt(initialState: initialState, at: explicitNow) {
        case .failure(let reason):
            if let line = WindowRescueFormatter.formatAttemptSkip(reason) {
                sink(WindowRescueFormatter.category, line)
            }
            return false
        case .success(let attempt):
            activeRunID &+= 1
            let runID = activeRunID
            activeTarget = target
            sink(WindowRescueFormatter.category, WindowRescueFormatter.formatStart(attempt: attempt, state: initialState))
            runStep(.moveToActiveSpace, attempt: attempt, runID: runID, target: target, currentState: initialState)
            return true
        }
    }

    /// 取消尚未完成的計時器並立即還原尚未還原的 collectionBehavior（停止監控或測試重置時用）
    func cancelAndReset(resetHistory: Bool = false) {
        activeRunID &+= 1
        cancelPendingDelay?()
        cancelPendingDelay = nil
        flushPendingBehaviorRestore?("cancel")
        flushPendingBehaviorRestore = nil
        activeTarget = nil
        if resetHistory {
            planner.reset()
        } else {
            planner.finishAttempt()
        }
    }

    private func runStep(
        _ step: WindowRescueStep,
        attempt: Int,
        runID: UInt64,
        target: WindowRescueTarget,
        currentState: WindowRescueState
    ) {
        guard runID == activeRunID else { return }

        let plan = planner.plan(step: step, state: currentState)
        switch plan {
        case .skip(let reason):
            sink(WindowRescueFormatter.category, WindowRescueFormatter.formatStepSkip(attempt: attempt, step: step, reason: reason))
            if let next = step.next {
                runStep(next, attempt: attempt, runID: runID, target: target, currentState: currentState)
            } else {
                completeFailed(attempt: attempt, runID: runID)
            }

        case .executeMoveToActiveSpace:
            executeStep1(attempt: attempt, runID: runID, target: target)
            scheduleVerification(after: step, attempt: attempt, runID: runID, target: target)

        case .executeMoveToPrimaryScreen(let targetFrame, let visibleFrame):
            let fromFrame = target.frame
            sink(
                WindowRescueFormatter.category,
                WindowRescueFormatter.formatStep2Execute(
                    attempt: attempt,
                    from: fromFrame,
                    to: targetFrame,
                    visibleFrame: visibleFrame
                )
            )
            target.setFrame(targetFrame)
            scheduleVerification(after: step, attempt: attempt, runID: runID, target: target)

        case .executeOrderOutAndFront:
            sink(WindowRescueFormatter.category, WindowRescueFormatter.formatStep3Execute(attempt: attempt))
            target.orderOut()
            target.orderFront()
            scheduleVerification(after: step, attempt: attempt, runID: runID, target: target)
        }
    }

    private func executeStep1(attempt: Int, runID: UInt64, target: WindowRescueTarget) {
        let originalRaw = target.collectionBehaviorRaw
        let moveBit = NSWindow.CollectionBehavior.moveToActiveSpace.rawValue
        let tempRaw = originalRaw | moveBit

        var restored = false
        var cancelWillClose: (() -> Void)?

        let performRestore: @MainActor (_ source: String) -> Void = { [weak self, weak target] source in
            guard !restored else { return }
            restored = true
            cancelWillClose?()
            cancelWillClose = nil
            if let self {
                self.flushPendingBehaviorRestore = nil
            }
            if let target {
                target.collectionBehaviorRaw = originalRaw
            }
            self?.sink(
                WindowRescueFormatter.category,
                WindowRescueFormatter.formatStep1Restore(attempt: attempt, restoredBehaviorRaw: originalRaw, source: source)
            )
        }

        // 先註冊 willClose 保護與保底 flush，再暫時修改 collectionBehavior，確保無論何種路徑皆會還原
        cancelWillClose = target.observeWillClose {
            performRestore("willClose")
        }
        flushPendingBehaviorRestore = performRestore

        if tempRaw != originalRaw {
            target.collectionBehaviorRaw = tempRaw
        }
        sink(
            WindowRescueFormatter.category,
            WindowRescueFormatter.formatStep1Execute(attempt: attempt, originalBehaviorRaw: originalRaw, tempBehaviorRaw: tempRaw)
        )
        target.makeKeyAndOrderFront()

        scheduleNextRunLoop {
            performRestore("nextRunLoop")
        }
    }

    private func scheduleVerification(
        after step: WindowRescueStep,
        attempt: Int,
        runID: UInt64,
        target: WindowRescueTarget
    ) {
        cancelPendingDelay?()
        cancelPendingDelay = scheduleAfterDelay(planner.settleDelay) { [weak self, weak target] in
            guard let self, runID == self.activeRunID else { return }
            self.cancelPendingDelay = nil
            // 保底：若因任何排程順序導致步驟 1 尚未還原，於量測前先行還原
            self.flushPendingBehaviorRestore?("flush")
            guard let target else {
                self.completeFailed(attempt: attempt, runID: runID)
                return
            }
            let measured = target.measureState()
            self.sink(
                WindowRescueFormatter.category,
                WindowRescueFormatter.formatStepMeasure(attempt: attempt, step: step, state: measured)
            )
            switch self.planner.evaluateAfter(step: step, measuredState: measured) {
            case .recovered(let winningStep):
                self.activeTarget = nil
                self.planner.finishAttempt()
                self.sink(
                    WindowRescueFormatter.category,
                    WindowRescueFormatter.formatFinishRecovered(attempt: attempt, step: winningStep)
                )
            case .proceedTo(let nextStep):
                self.runStep(nextStep, attempt: attempt, runID: runID, target: target, currentState: measured)
            case .exhausted:
                self.completeFailed(attempt: attempt, runID: runID)
            }
        }
    }

    private func completeFailed(attempt: Int, runID: UInt64) {
        guard runID == activeRunID else { return }
        activeTarget = nil
        planner.finishAttempt()
        sink(WindowRescueFormatter.category, WindowRescueFormatter.formatFinishFailed(attempt: attempt))
    }
}

/// 供 `--window-diag-inject rescue-ok=<1|2|3|none>` 測試實例使用的模擬目標（不移動或喚起真實背景測試視窗）
@MainActor
final class SimulatedWindowRescueTarget: WindowRescueTarget {
    var collectionBehaviorRaw: UInt
    private(set) var frame: WindowSnapshotRect
    private var state: WindowRescueState
    private let successOutcome: WindowRescueInjectOutcome
    private var lastExecutedStep: WindowRescueStep?
    private var closeHandlers: [@MainActor () -> Void] = []

    init(
        initialState: WindowRescueState,
        initialBehaviorRaw: UInt,
        successOutcome: WindowRescueInjectOutcome
    ) {
        self.state = initialState
        self.frame = initialState.frame
        self.collectionBehaviorRaw = initialBehaviorRaw
        self.successOutcome = successOutcome
    }

    func makeKeyAndOrderFront() {
        lastExecutedStep = .moveToActiveSpace
        state.isOnActiveSpace = true
        if successOutcome == .step1 {
            state.wsOnscreen = true
            state.occVisible = true
        }
    }

    func setFrame(_ rect: WindowSnapshotRect) {
        lastExecutedStep = .moveToPrimaryScreen
        frame = rect
        state.frame = rect
        state.frameInUnion = true
        if successOutcome == .step2 {
            state.wsOnscreen = true
            state.occVisible = true
        }
    }

    func orderOut() {
        lastExecutedStep = .orderOutAndFront
    }

    func orderFront() {
        lastExecutedStep = .orderOutAndFront
        if successOutcome == .step3 {
            state.wsOnscreen = true
            state.occVisible = true
        }
    }

    func observeWillClose(_ handler: @escaping @MainActor () -> Void) -> () -> Void {
        let index = closeHandlers.count
        closeHandlers.append(handler)
        return { [weak self] in
            guard let self, index < self.closeHandlers.count else { return }
            self.closeHandlers[index] = {}
        }
    }

    func simulateWillClose() {
        let handlers = closeHandlers
        closeHandlers.removeAll()
        for h in handlers { h() }
    }

    func measureState() -> WindowRescueState {
        state
    }
}
