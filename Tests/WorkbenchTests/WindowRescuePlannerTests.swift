import AppKit
import XCTest
@testable import Workbench

@MainActor
final class WindowRescuePlannerTests: XCTestCase {

    // MARK: - 測試替身（假視窗與假排程器）

    private final class FakeRescueWindow: WindowRescueTarget {
        var collectionBehaviorRaw: UInt
        var behaviorHistory: [UInt] = []
        var frame: WindowSnapshotRect
        var state: WindowRescueState
        var actions: [String] = []
        var onMakeKeyAndOrderFront: ((FakeRescueWindow) -> Void)?
        var onSetFrame: ((FakeRescueWindow, WindowSnapshotRect) -> Void)?
        var onOrderOut: ((FakeRescueWindow) -> Void)?
        var onOrderFront: ((FakeRescueWindow) -> Void)?
        private var closeHandlers: [@MainActor () -> Void] = []

        init(state: WindowRescueState, initialBehaviorRaw: UInt = NSWindow.CollectionBehavior.fullScreenPrimary.rawValue) {
            self.state = state
            self.frame = state.frame
            self.collectionBehaviorRaw = initialBehaviorRaw
            self.behaviorHistory = [initialBehaviorRaw]
        }

        func makeKeyAndOrderFront() {
            actions.append("makeKeyAndOrderFront(behavior=0x\(String(collectionBehaviorRaw, radix: 16)))")
            behaviorHistory.append(collectionBehaviorRaw)
            onMakeKeyAndOrderFront?(self)
        }

        func setFrame(_ rect: WindowSnapshotRect) {
            frame = rect
            state.frame = rect
            actions.append("setFrame(\(rect.formatted))")
            onSetFrame?(self, rect)
        }

        func orderOut() {
            actions.append("orderOut")
            onOrderOut?(self)
        }

        func orderFront() {
            actions.append("orderFront")
            onOrderFront?(self)
        }

        func observeWillClose(_ handler: @escaping @MainActor () -> Void) -> () -> Void {
            let idx = closeHandlers.count
            closeHandlers.append(handler)
            return { [weak self] in
                guard let self, idx < self.closeHandlers.count else { return }
                self.closeHandlers[idx] = {}
            }
        }

        func fireWillClose() {
            let list = closeHandlers
            closeHandlers.removeAll()
            for h in list { h() }
        }

        func measureState() -> WindowRescueState {
            state
        }
    }

    @MainActor
    private final class ManualScheduler {
        var nextRunLoopQueue: [@MainActor () -> Void] = []
        var delayedQueue: [(delay: TimeInterval, cancelled: Bool, work: @MainActor () -> Void)] = []

        func scheduleNextRunLoop(_ work: @escaping @MainActor () -> Void) {
            nextRunLoopQueue.append(work)
        }

        func scheduleAfterDelay(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void {
            let idx = delayedQueue.count
            delayedQueue.append((delay: delay, cancelled: false, work: work))
            return { [weak self] in
                guard let self, idx < self.delayedQueue.count else { return }
                self.delayedQueue[idx].cancelled = true
            }
        }

        func runNextRunLoopTasks() {
            let batch = nextRunLoopQueue
            nextRunLoopQueue.removeAll()
            for task in batch { task() }
        }

        func runNextDelayedTask() -> TimeInterval? {
            while !delayedQueue.isEmpty {
                let first = delayedQueue.removeFirst()
                if first.cancelled { continue }
                first.work()
                return first.delay
            }
            return nil
        }
    }

    private func makeAnomalousState(
        isKey: Bool = true,
        isMain: Bool = true,
        occVisible: Bool = false,
        wsOnscreen: Bool? = false,
        isOnActiveSpace: Bool = false,
        frame: WindowSnapshotRect = WindowSnapshotRect(x: 4000, y: 200, width: 1200, height: 800),
        frameInUnion: Bool = false,
        primaryVisibleFrame: WindowSnapshotRect? = WindowSnapshotRect(x: 0, y: 40, width: 1920, height: 1010)
    ) -> WindowRescueState {
        WindowRescueState(
            isKey: isKey,
            isMain: isMain,
            occVisible: occVisible,
            wsOnscreen: wsOnscreen,
            isOnActiveSpace: isOnActiveSpace,
            frame: frame,
            frameInUnion: frameInUnion,
            primaryVisibleFrame: primaryVisibleFrame
        )
    }

    // MARK: - 1. 正常狀態不動視窗也不記「視窗救援」

    func testNormalStateDoesNothingAndLogsNothing() {
        let scheduler = ManualScheduler()
        var logs: [(String, String)] = []
        let coordinator = WindowRescueCoordinator(
            scheduleNextRunLoop: scheduler.scheduleNextRunLoop,
            scheduleAfterDelay: scheduler.scheduleAfterDelay,
            sink: { logs.append(($0, $1)) }
        )

        // 正常前景視窗
        let normal = FakeRescueWindow(state: makeAnomalousState(occVisible: true, wsOnscreen: true, isOnActiveSpace: true, frameInUnion: true))
        XCTAssertFalse(coordinator.trigger(target: normal, at: 10.0))
        XCTAssertTrue(normal.actions.isEmpty)
        XCTAssertTrue(logs.isEmpty)
        XCTAssertEqual(coordinator.planner.attemptCount, 0)

        // 背景被其他 App 遮住（isKey=false, isMain=false, occ=hidden）：非異常
        let coveredBackground = FakeRescueWindow(state: makeAnomalousState(isKey: false, isMain: false, occVisible: false, wsOnscreen: false))
        XCTAssertFalse(coordinator.trigger(target: coveredBackground, at: 11.0))
        XCTAssertTrue(coveredBackground.actions.isEmpty)
        XCTAssertTrue(logs.isEmpty)
    }

    // MARK: - 2. 步驟 1（Space）：暫加 .moveToActiveSpace、下個 run loop 還原、0.3s 救回就停

    func testStep1RescuesRestoresCollectionBehaviorOnNextRunLoopAndStops() {
        let scheduler = ManualScheduler()
        var logs: [(String, String)] = []
        let coordinator = WindowRescueCoordinator(
            scheduleNextRunLoop: scheduler.scheduleNextRunLoop,
            scheduleAfterDelay: scheduler.scheduleAfterDelay,
            sink: { logs.append(($0, $1)) }
        )

        let originalBehavior = NSWindow.CollectionBehavior.fullScreenPrimary.rawValue
        let fake = FakeRescueWindow(state: makeAnomalousState(), initialBehaviorRaw: originalBehavior)
        fake.onMakeKeyAndOrderFront = { w in
            // 執行當下 collectionBehavior 必須包含 .moveToActiveSpace
            XCTAssertTrue(NSWindow.CollectionBehavior(rawValue: w.collectionBehaviorRaw).contains(.moveToActiveSpace))
            w.state.isOnActiveSpace = true
            w.state.wsOnscreen = true
            w.state.occVisible = true
        }

        XCTAssertTrue(coordinator.trigger(target: fake, at: 100.0))
        // 還沒跑下一個 run loop 前暫時含 .moveToActiveSpace
        XCTAssertEqual(fake.collectionBehaviorRaw, originalBehavior | NSWindow.CollectionBehavior.moveToActiveSpace.rawValue)

        // 下個 run loop 立即還原為原值
        scheduler.runNextRunLoopTasks()
        XCTAssertEqual(fake.collectionBehaviorRaw, originalBehavior)

        // 等 0.3 秒量測：已救回 → 停止，步驟 2 與 3 不得執行
        let delay = scheduler.runNextDelayedTask()
        XCTAssertEqual(delay, 0.3)
        XCTAssertEqual(fake.actions.count, 1)
        XCTAssertFalse(coordinator.planner.isInProgress)
        XCTAssertNil(scheduler.runNextDelayedTask())

        XCTAssertTrue(logs.allSatisfy { $0.0 == "視窗救援" })
        let msgs = logs.map(\.1)
        XCTAssertTrue(msgs.contains { $0.contains("救援#1 步驟1 執行 | 動作=space") })
        XCTAssertTrue(msgs.contains { $0.contains("救援#1 步驟1 還原 | behavior=0x80 來源=nextRunLoop") })
        XCTAssertTrue(msgs.contains { $0.contains("救援#1 步驟1 量測 | 結果=已救回") })
        XCTAssertTrue(msgs.contains { $0.contains("救援#1 結束 | 結論=第 1 步救回 假設=Space") })
        XCTAssertFalse(msgs.contains { $0.contains("步驟2") || $0.contains("步驟3") })
    }

    // MARK: - 3. 步驟 1 視窗提前關閉（willClose）必定還原且不重複還原

    func testStep1RestoresCollectionBehaviorOnWillCloseBeforeNextRunLoop() {
        let scheduler = ManualScheduler()
        var logs: [(String, String)] = []
        let coordinator = WindowRescueCoordinator(
            scheduleNextRunLoop: scheduler.scheduleNextRunLoop,
            scheduleAfterDelay: scheduler.scheduleAfterDelay,
            sink: { logs.append(($0, $1)) }
        )

        let originalBehavior = NSWindow.CollectionBehavior.managed.rawValue
        let fake = FakeRescueWindow(state: makeAnomalousState(), initialBehaviorRaw: originalBehavior)

        XCTAssertTrue(coordinator.trigger(target: fake, at: 10.0))
        XCTAssertNotEqual(fake.collectionBehaviorRaw, originalBehavior)

        // 視窗在下個 run loop 到來前關閉：必須立刻還原
        fake.fireWillClose()
        XCTAssertEqual(fake.collectionBehaviorRaw, originalBehavior)

        // 後續 run loop 到來時不得重複寫第二筆還原紀錄
        scheduler.runNextRunLoopTasks()
        XCTAssertEqual(fake.collectionBehaviorRaw, originalBehavior)
        let restoreLogs = logs.filter { $0.1.contains("步驟1 還原") }
        XCTAssertEqual(restoreLogs.count, 1)
        XCTAssertTrue(restoreLogs[0].1.contains("來源=willClose"))
    }

    // MARK: - 4. 步驟 1 略過（已在作用中 Space）→ 步驟 2 搬回主螢幕可見區置中／縮放救回並停止

    func testStep1SkippedAndStep2MovesToPrimaryScreenAndStops() {
        let scheduler = ManualScheduler()
        var logs: [(String, String)] = []
        let coordinator = WindowRescueCoordinator(
            scheduleNextRunLoop: scheduler.scheduleNextRunLoop,
            scheduleAfterDelay: scheduler.scheduleAfterDelay,
            sink: { logs.append(($0, $1)) }
        )

        // 視窗比可見區大（2400x1400 > 1920x1010），必須縮到可見區內並置中
        let oversized = WindowSnapshotRect(x: 5000, y: -3000, width: 2400, height: 1400)
        let visible = WindowSnapshotRect(x: 60, y: 40, width: 1860, height: 1010)
        let fake = FakeRescueWindow(
            state: makeAnomalousState(
                isOnActiveSpace: true,
                frame: oversized,
                frameInUnion: false,
                primaryVisibleFrame: visible
            )
        )
        fake.onSetFrame = { w, _ in
            w.state.frameInUnion = true
            w.state.wsOnscreen = true
            w.state.occVisible = true
        }

        XCTAssertTrue(coordinator.trigger(target: fake, at: 50.0))
        // 步驟 1 直接略過、未呼叫 makeKeyAndOrderFront，立即執行步驟 2
        XCTAssertEqual(fake.frame, visible)
        XCTAssertEqual(fake.actions, ["setFrame((60,40 1860×1010))"])

        XCTAssertEqual(scheduler.runNextDelayedTask(), 0.3)
        XCTAssertNil(scheduler.runNextDelayedTask())

        let msgs = logs.map(\.1)
        XCTAssertTrue(msgs.contains { $0.contains("救援#1 步驟1 略過 | 動作=space 原因=已在作用中Space") })
        XCTAssertTrue(msgs.contains { $0.contains("救援#1 步驟2 執行 | 動作=frame from=(5000,-3000 2400×1400) to=(60,40 1860×1010)") })
        XCTAssertTrue(msgs.contains { $0.contains("救援#1 結束 | 結論=第 2 步救回 假設=座標") })
        XCTAssertFalse(msgs.contains { $0.contains("步驟3") })
    }

    func testCenteredFrameKeepsSizeWhenSmallerThanVisibleFrame() {
        let current = WindowSnapshotRect(x: 9000, y: 9000, width: 1000, height: 600)
        let visible = WindowSnapshotRect(x: 100, y: 50, width: 1800, height: 1000)
        let centered = WindowRescuePlanner.centeredFrame(currentFrame: current, inVisibleFrame: visible)
        XCTAssertEqual(centered, WindowSnapshotRect(x: 500, y: 250, width: 1000, height: 600))
    }

    // MARK: - 5. 步驟 1、2 未救回 → 步驟 3 orderOut + orderFront 救回與全失敗（未救回）

    func testStep3OrderOutAndFrontRescuesAfterStep1AndStep2Fail() {
        let scheduler = ManualScheduler()
        var logs: [(String, String)] = []
        let coordinator = WindowRescueCoordinator(
            scheduleNextRunLoop: scheduler.scheduleNextRunLoop,
            scheduleAfterDelay: scheduler.scheduleAfterDelay,
            sink: { logs.append(($0, $1)) }
        )

        let fake = FakeRescueWindow(state: makeAnomalousState(isOnActiveSpace: false, frameInUnion: false))
        fake.onOrderFront = { w in
            w.state.wsOnscreen = true
            w.state.occVisible = true
        }

        XCTAssertTrue(coordinator.trigger(target: fake, at: 10.0))
        scheduler.runNextRunLoopTasks()
        XCTAssertEqual(scheduler.runNextDelayedTask(), 0.3) // 步驟 1 量測：未救回 → 進步驟 2
        XCTAssertEqual(scheduler.runNextDelayedTask(), 0.3) // 步驟 2 量測：未救回 → 進步驟 3
        XCTAssertEqual(scheduler.runNextDelayedTask(), 0.3) // 步驟 3 量測：已救回 → 停
        XCTAssertNil(scheduler.runNextDelayedTask())

        XCTAssertEqual(fake.actions.suffix(2), ["orderOut", "orderFront"])
        let msgs = logs.map(\.1)
        XCTAssertTrue(msgs.contains { $0.contains("救援#1 步驟3 執行 | 動作=backing orderOut+orderFront") })
        XCTAssertTrue(msgs.contains { $0.contains("救援#1 結束 | 結論=第 3 步救回 假設=backing") })
    }

    func testAllThreeStepsFailLogsExhausted() {
        let scheduler = ManualScheduler()
        var logs: [(String, String)] = []
        let coordinator = WindowRescueCoordinator(
            scheduleNextRunLoop: scheduler.scheduleNextRunLoop,
            scheduleAfterDelay: scheduler.scheduleAfterDelay,
            sink: { logs.append(($0, $1)) }
        )

        // 步驟 1、2 略過，步驟 3 執行後仍未救回
        let fake = FakeRescueWindow(state: makeAnomalousState(isOnActiveSpace: true, frameInUnion: true))
        XCTAssertTrue(coordinator.trigger(target: fake, at: 10.0))
        XCTAssertEqual(scheduler.runNextDelayedTask(), 0.3)
        XCTAssertFalse(coordinator.planner.isInProgress)
        XCTAssertTrue(logs.map(\.1).contains { $0.contains("救援#1 結束 | 結論=未救回") })
    }

    // MARK: - 6. 防重入（進行中）、60 秒冷卻與每次啟動 5 次上限

    func testInProgressReentryCooldownAndLaunchLimit() {
        let scheduler = ManualScheduler()
        var logs: [(String, String)] = []
        let planner = WindowRescuePlanner(cooldownDuration: 60.0, maxAttemptsPerLaunch: 5, settleDelay: 0.3)
        let coordinator = WindowRescueCoordinator(
            planner: planner,
            scheduleNextRunLoop: scheduler.scheduleNextRunLoop,
            scheduleAfterDelay: scheduler.scheduleAfterDelay,
            sink: { logs.append(($0, $1)) }
        )

        let fake = FakeRescueWindow(state: makeAnomalousState(isOnActiveSpace: true, frameInUnion: true))

        // 第 1 次啟動於 t=0
        XCTAssertTrue(coordinator.trigger(target: fake, at: 0.0))
        // 尚在等 0.3s 期間再次點 Dock → 略過（進行中）
        XCTAssertFalse(coordinator.trigger(target: fake, at: 0.1))
        XCTAssertTrue(logs.last?.1.contains("原因=進行中") == true)

        // 完成第 1 輪
        _ = scheduler.runNextDelayedTask()
        XCTAssertFalse(coordinator.planner.isInProgress)

        // 60s 冷卻內（t=30.0、t=59.9）→ 略過（冷卻中）
        XCTAssertFalse(coordinator.trigger(target: fake, at: 30.0))
        XCTAssertTrue(logs.last?.1.contains("原因=冷卻中") == true)
        XCTAssertFalse(coordinator.trigger(target: fake, at: 59.9))
        XCTAssertTrue(logs.last?.1.contains("原因=冷卻中") == true)
        XCTAssertEqual(coordinator.planner.attemptCount, 1)

        // t=60.0 起滿冷卻，依序跑完第 2～5 次（間隔 60s）
        for idx in 2...5 {
            let t = TimeInterval((idx - 1) * 60)
            XCTAssertTrue(coordinator.trigger(target: fake, at: t), "attempt \(idx)")
            _ = scheduler.runNextDelayedTask()
            XCTAssertEqual(coordinator.planner.attemptCount, idx)
        }

        // 第 6 次即使超過冷卻（t=500.0）→ 達每次啟動上限 5 次，略過
        XCTAssertFalse(coordinator.trigger(target: fake, at: 500.0))
        XCTAssertTrue(logs.last?.1.contains("原因=已達啟動上限 次數=5/5") == true)
        XCTAssertEqual(coordinator.planner.attemptCount, 5)
    }

    // MARK: - 7. 模擬救援目標（供 --window-diag-inject rescue-ok=<1|2|3|none> 用）

    func testSimulatedTargetHonorsRescueOk2AndStops() {
        let scheduler = ManualScheduler()
        var logs: [(String, String)] = []
        let coordinator = WindowRescueCoordinator(
            scheduleNextRunLoop: scheduler.scheduleNextRunLoop,
            scheduleAfterDelay: scheduler.scheduleAfterDelay,
            sink: { logs.append(($0, $1)) }
        )

        let initial = makeAnomalousState(isOnActiveSpace: false, frameInUnion: false)
        let sim = SimulatedWindowRescueTarget(
            initialState: initial,
            initialBehaviorRaw: NSWindow.CollectionBehavior.fullScreenPrimary.rawValue,
            successOutcome: .step2
        )

        XCTAssertTrue(coordinator.trigger(target: sim, at: 0.0))
        scheduler.runNextRunLoopTasks()
        XCTAssertEqual(sim.collectionBehaviorRaw, NSWindow.CollectionBehavior.fullScreenPrimary.rawValue)
        XCTAssertEqual(scheduler.runNextDelayedTask(), 0.3) // 步驟 1 未救回
        XCTAssertEqual(scheduler.runNextDelayedTask(), 0.3) // 步驟 2 救回
        XCTAssertNil(scheduler.runNextDelayedTask())

        let msgs = logs.map(\.1)
        XCTAssertTrue(msgs.contains { $0.contains("救援#1 步驟1 量測 | 結果=未救回") })
        XCTAssertTrue(msgs.contains { $0.contains("救援#1 步驟2 量測 | 結果=已救回") })
        XCTAssertTrue(msgs.contains { $0.contains("救援#1 結束 | 結論=第 2 步救回 假設=座標") })
        XCTAssertFalse(msgs.contains { $0.contains("步驟3") })
    }

    func testSimulatedTargetHonorsRescueOkNoneAndRunsAllSteps() {
        let scheduler = ManualScheduler()
        var logs: [(String, String)] = []
        let coordinator = WindowRescueCoordinator(
            scheduleNextRunLoop: scheduler.scheduleNextRunLoop,
            scheduleAfterDelay: scheduler.scheduleAfterDelay,
            sink: { logs.append(($0, $1)) }
        )

        let initial = makeAnomalousState(isOnActiveSpace: false, frameInUnion: false)
        let sim = SimulatedWindowRescueTarget(
            initialState: initial,
            initialBehaviorRaw: NSWindow.CollectionBehavior.fullScreenPrimary.rawValue,
            successOutcome: .never
        )

        XCTAssertTrue(coordinator.trigger(target: sim, at: 0.0))
        scheduler.runNextRunLoopTasks()
        XCTAssertEqual(scheduler.runNextDelayedTask(), 0.3) // 步驟 1 未救回
        XCTAssertEqual(scheduler.runNextDelayedTask(), 0.3) // 步驟 2 未救回
        XCTAssertEqual(scheduler.runNextDelayedTask(), 0.3) // 步驟 3 未救回
        XCTAssertNil(scheduler.runNextDelayedTask())

        let msgs = logs.map(\.1)
        XCTAssertTrue(msgs.contains { $0.contains("救援#1 步驟1 還原") })
        XCTAssertTrue(msgs.contains { $0.contains("救援#1 步驟2 執行") })
        XCTAssertTrue(msgs.contains { $0.contains("救援#1 步驟3 執行") })
        XCTAssertTrue(msgs.contains { $0.contains("救援#1 結束 | 結論=未救回") })
    }
}
