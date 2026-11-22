import AppKit
import XCTest
@testable import Workbench

final class WindowStuckDetectorTests: XCTestCase {

    // MARK: - 條件 A／條件 B／合併觸發

    func testConditionAAloneTriggersAt1_5Seconds() {
        var detector = WindowStuckDetector()
        // 條件 A 成立（active=true, key=true, occ=hidden），條件 B 不成立（wsOnscreen=true）
        let sampleA = WindowStuckSample(isActive: true, isKey: true, isMain: false, occVisible: false, wsOnscreen: true)
        XCTAssertTrue(sampleA.matchesConditionA)
        XCTAssertFalse(sampleA.matchesConditionB)

        let d0 = detector.evaluate(sampleA, at: 10.0)
        XCTAssertFalse(d0.shouldEmit)
        XCTAssertEqual(d0, .pending(remaining: 1.5))

        let dBefore = detector.evaluate(sampleA, at: 11.49)
        XCTAssertFalse(dBefore.shouldEmit)

        let dAt = detector.evaluate(sampleA, at: 11.5)
        XCTAssertTrue(dAt.shouldEmit)
        XCTAssertEqual(dAt, .emit(trigger: .conditionA, sequence: 1))
        XCTAssertEqual(detector.emittedCount, 1)
    }

    func testConditionBAloneWithKeyAndFalseOnscreenTriggersWithoutActive() {
        var detector = WindowStuckDetector()
        // 條件 B 成立（isActive=false, occVisible=true 使 A 不成立；isKey=true 且 wsOnscreen=false 使 B 成立）
        let sampleB = WindowStuckSample(isActive: false, isKey: true, isMain: false, occVisible: true, wsOnscreen: false)
        XCTAssertFalse(sampleB.matchesConditionA)
        XCTAssertTrue(sampleB.matchesConditionB)

        XCTAssertFalse(detector.evaluate(sampleB, at: 100.0).shouldEmit)
        XCTAssertFalse(detector.evaluate(sampleB, at: 101.4).shouldEmit)
        let decision = detector.evaluate(sampleB, at: 101.5)
        XCTAssertEqual(decision, .emit(trigger: .conditionB, sequence: 1))
    }

    func testConditionBAloneWithMainAndMissingOnscreenTriggers() {
        var detector = WindowStuckDetector()
        // 條件 B：isKey=false 但 isMain=true，且 WindowServer 查不到視窗（wsOnscreen=nil）
        let sampleB = WindowStuckSample(isActive: false, isKey: false, isMain: true, occVisible: true, wsOnscreen: nil)
        XCTAssertFalse(sampleB.matchesConditionA)
        XCTAssertTrue(sampleB.matchesConditionB)

        XCTAssertFalse(detector.evaluate(sampleB, at: 5.0).shouldEmit)
        let decision = detector.evaluate(sampleB, at: 6.5)
        XCTAssertEqual(decision, .emit(trigger: .conditionB, sequence: 1))
    }

    func testBothConditionsSimultaneouslyEmitOnlyOnce() {
        var detector = WindowStuckDetector()
        let both = WindowStuckSample(isActive: true, isKey: true, isMain: true, occVisible: false, wsOnscreen: nil)
        XCTAssertTrue(both.matchesConditionA)
        XCTAssertTrue(both.matchesConditionB)

        XCTAssertFalse(detector.evaluate(both, at: 0.0).shouldEmit)
        XCTAssertEqual(detector.evaluate(both, at: 1.5), .emit(trigger: .both, sequence: 1))
        XCTAssertEqual(detector.evaluate(both, at: 3.0), .suppressedSameIncident)
        XCTAssertEqual(detector.evaluate(both, at: 120.0), .suppressedSameIncident)
        XCTAssertEqual(detector.emittedCount, 1)
    }

    // MARK: - 持續時間、解除、取消計時、不重複、冷卻與總上限

    func testConditionShorterThan1_5SecondsDoesNotEmitAndCancelsTimer() {
        var detector = WindowStuckDetector()
        let stuck = WindowStuckSample(isActive: true, isKey: true, isMain: true, occVisible: false, wsOnscreen: true)
        let normal = WindowStuckSample(isActive: true, isKey: true, isMain: true, occVisible: true, wsOnscreen: true)

        XCTAssertFalse(detector.evaluate(stuck, at: 0.0).shouldEmit)
        XCTAssertFalse(detector.evaluate(stuck, at: 1.4).shouldEmit)
        // 中途條件解除：計時應取消
        XCTAssertEqual(detector.evaluate(normal, at: 1.45), .idle)
        XCTAssertNil(detector.stuckSince)
        XCTAssertEqual(detector.emittedCount, 0)

        // 重新進入卡住狀態：必須從 2.0 重算 1.5 秒，不可接續先前 1.4 秒
        XCTAssertEqual(detector.evaluate(stuck, at: 2.0), .pending(remaining: 1.5))
        XCTAssertFalse(detector.evaluate(stuck, at: 3.4).shouldEmit)
        XCTAssertEqual(detector.evaluate(stuck, at: 3.5), .emit(trigger: .conditionA, sequence: 1))
    }

    func testSustainedWithoutClearingNeverEmitsTwiceEvenAfterCooldown() {
        var detector = WindowStuckDetector()
        let stuck = WindowStuckSample(isActive: true, isKey: true, isMain: true, occVisible: false, wsOnscreen: true)

        XCTAssertFalse(detector.evaluate(stuck, at: 0.0).shouldEmit)
        XCTAssertEqual(detector.evaluate(stuck, at: 1.5), .emit(trigger: .conditionA, sequence: 1))
        for t in [2.0, 10.0, 65.0, 200.0, 1000.0] {
            XCTAssertEqual(detector.evaluate(stuck, at: t), .suppressedSameIncident)
        }
        XCTAssertEqual(detector.emittedCount, 1)
    }

    func testCooldown60SecondsBlocksJitterAndAllowsAfterCooldown() {
        var detector = WindowStuckDetector()
        let stuck = WindowStuckSample(isActive: true, isKey: true, isMain: true, occVisible: false, wsOnscreen: true)
        let cleared = WindowStuckSample(isActive: true, isKey: true, isMain: true, occVisible: true, wsOnscreen: true)

        // 第 1 次觸發於 t=1.5
        XCTAssertFalse(detector.evaluate(stuck, at: 0.0).shouldEmit)
        XCTAssertEqual(detector.evaluate(stuck, at: 1.5), .emit(trigger: .conditionA, sequence: 1))

        // 條件解除後，60 秒冷卻內多次抖動（每次都持續 >= 1.5s）皆不寫
        XCTAssertEqual(detector.evaluate(cleared, at: 2.0), .idle)
        XCTAssertFalse(detector.evaluate(stuck, at: 10.0).shouldEmit)
        if case .suppressedCooldown = detector.evaluate(stuck, at: 12.0) {
            // expected
        } else {
            XCTFail("冷卻窗內應回傳 suppressedCooldown")
        }
        XCTAssertEqual(detector.evaluate(cleared, at: 15.0), .idle)
        XCTAssertFalse(detector.evaluate(stuck, at: 58.0).shouldEmit)
        if case .suppressedCooldown = detector.evaluate(stuck, at: 60.0) {
            // 60.0 - 1.5 = 58.5 < 60
        } else {
            XCTFail("58.5 秒仍在冷卻窗內，應回傳 suppressedCooldown")
        }
        XCTAssertEqual(detector.emittedCount, 1)

        // 冷卻解除後（t=62.0 起，t=63.5 距上次 1.5 已過 62 秒 >= 60 秒）應寫第 2 份
        XCTAssertEqual(detector.evaluate(cleared, at: 60.5), .idle)
        XCTAssertFalse(detector.evaluate(stuck, at: 62.0).shouldEmit)
        XCTAssertEqual(detector.evaluate(stuck, at: 63.5), .emit(trigger: .conditionA, sequence: 2))
        XCTAssertEqual(detector.emittedCount, 2)
    }

    func testMaxSnapshotsPerLaunchCap() {
        var detector = WindowStuckDetector(dwellDuration: 1.5, cooldownDuration: 60.0, maxSnapshotsPerLaunch: 3)
        let stuck = WindowStuckSample(isActive: true, isKey: true, isMain: true, occVisible: false, wsOnscreen: true)
        let cleared = WindowStuckSample(isActive: true, isKey: true, isMain: true, occVisible: true, wsOnscreen: true)

        var now: TimeInterval = 0
        for expectedSeq in 1...3 {
            XCTAssertFalse(detector.evaluate(stuck, at: now).shouldEmit)
            XCTAssertEqual(detector.evaluate(stuck, at: now + 1.5), .emit(trigger: .conditionA, sequence: expectedSeq))
            XCTAssertEqual(detector.evaluate(cleared, at: now + 2.0), .idle)
            now += 70.0
        }
        XCTAssertEqual(detector.emittedCount, 3)

        // 第 4 次即使超過冷卻且持續 >= 1.5 秒仍應被每次啟動上限擋下
        XCTAssertEqual(detector.evaluate(stuck, at: now), .suppressedSessionLimit)
        XCTAssertEqual(detector.evaluate(stuck, at: now + 5.0), .suppressedSessionLimit)
        XCTAssertEqual(detector.emittedCount, 3)
    }

    func testNormalAndNonMatchingStatesNeverTrigger() {
        var detector = WindowStuckDetector()
        let cases: [WindowStuckSample] = [
            // 正常前景
            WindowStuckSample(isActive: true, isKey: true, isMain: true, occVisible: true, wsOnscreen: true),
            // isActive=false 且 wsOnscreen=true（條件 A 與 B 皆不成立）
            WindowStuckSample(isActive: false, isKey: true, isMain: true, occVisible: false, wsOnscreen: true),
            // isKey=false 且 isMain=false（即使 active=true, occ=hidden, wsOnscreen=false，兩條件皆不成立）
            WindowStuckSample(isActive: true, isKey: false, isMain: false, occVisible: false, wsOnscreen: false),
            // isKey=false, isMain=true, occ=hidden, wsOnscreen=true（A 要 key，B 要 wsOnscreen!=true）
            WindowStuckSample(isActive: true, isKey: false, isMain: true, occVisible: false, wsOnscreen: true),
            // occVisible=true 且 wsOnscreen=true
            WindowStuckSample(isActive: true, isKey: true, isMain: false, occVisible: true, wsOnscreen: true),
        ]

        for (idx, sample) in cases.enumerated() {
            let base = TimeInterval(idx * 100)
            XCTAssertEqual(detector.evaluate(sample, at: base), .idle, "case \(idx) at t0")
            XCTAssertEqual(detector.evaluate(sample, at: base + 10.0), .idle, "case \(idx) at t+10")
        }
        XCTAssertEqual(detector.emittedCount, 0)
    }

    func testInjectableClockWorks() {
        final class FakeClock: @unchecked Sendable {
            var now: TimeInterval = 50.0
        }
        let clock = FakeClock()
        var detector = WindowStuckDetector(clock: { clock.now })
        let stuck = WindowStuckSample(isActive: true, isKey: true, isMain: true, occVisible: false, wsOnscreen: true)

        XCTAssertFalse(detector.evaluate(stuck).shouldEmit)
        clock.now = 51.49
        XCTAssertFalse(detector.evaluate(stuck).shouldEmit)
        clock.now = 51.50
        XCTAssertEqual(detector.evaluate(stuck), .emit(trigger: .conditionA, sequence: 1))
    }

    // MARK: - 快照組裝、座標換算、上層視窗與全螢幕偵測

    func testConvertCGToAppKitRect() {
        // 主螢幕高 1080；外接螢幕在下方（AppKit y = -526, h = 526 → CG y = 1080）
        let cg = CGRect(x: 1561, y: 1080, width: 1142, height: 526)
        let ns = WindowSnapshotFormatter.convertCGToAppKitRect(cg, primaryScreenHeight: 1080)
        XCTAssertEqual(ns, CGRect(x: 1561, y: -526, width: 1142, height: 526))
    }

    func testFilterAboveWindowsRespectsZOrderOwnPIDOverlapAndMax20() {
        let ourFrame = WindowSnapshotRect(x: 100, y: 100, width: 800, height: 600)
        let ourScreen = WindowSnapshotRect(x: 0, y: 0, width: 1920, height: 1080)
        let ourPID: Int32 = 1000
        let ourWID: UInt32 = 500

        var list: [WindowSnapshotExternalWindow] = []
        // 自己的視窗在上面：應排除
        list.append(WindowSnapshotExternalWindow(windowNumber: 1, ownerPID: ourPID, ownerName: "codenv", layer: 3, bounds: ourFrame, alpha: 1.0, isOnscreen: true))
        // 沒交集的其他 App 視窗：應排除
        list.append(WindowSnapshotExternalWindow(windowNumber: 2, ownerPID: 2001, ownerName: "SideApp", layer: 0, bounds: WindowSnapshotRect(x: 1200, y: 100, width: 300, height: 300), alpha: 1.0, isOnscreen: true))
        // 25 個在我們之上且有交集的其他 App 視窗：最多取 20 筆
        for i in 0..<25 {
            list.append(WindowSnapshotExternalWindow(
                windowNumber: UInt32(100 + i),
                ownerPID: Int32(3000 + i),
                ownerName: "Overlay\(i)",
                layer: 0,
                bounds: WindowSnapshotRect(x: 150, y: 150, width: 400, height: 400),
                alpha: 1.0,
                isOnscreen: true
            ))
        }
        // 我們自己的視窗（分界）
        list.append(WindowSnapshotExternalWindow(windowNumber: ourWID, ownerPID: ourPID, ownerName: "codenv", layer: 0, bounds: ourFrame, alpha: 1.0, isOnscreen: true))
        // 在我們下面的其他 App 視窗：絕不可被列入
        list.append(WindowSnapshotExternalWindow(windowNumber: 999, ownerPID: 4000, ownerName: "BelowApp", layer: 0, bounds: ourFrame, alpha: 1.0, isOnscreen: true))

        let above = WindowSnapshotFormatter.filterAboveWindows(
            allOnscreenFrontToBack: list,
            ourWindowNumber: ourWID,
            ourPID: ourPID,
            ourFrame: ourFrame,
            ourScreenFrame: ourScreen
        )
        XCTAssertEqual(above.count, 20)
        XCTAssertEqual(above.first?.ownerName, "Overlay0")
        XCTAssertEqual(above.last?.ownerName, "Overlay19")
        XCTAssertFalse(above.contains { $0.ownerName == "BelowApp" || $0.ownerName == "codenv" || $0.ownerName == "SideApp" })

        // 若目標視窗位在另一 Space（不在 onscreen 清單內），會列出佔住同區域的上層視窗（不含自己與無交集者）
        let smallList: [WindowSnapshotExternalWindow] = [
            WindowSnapshotExternalWindow(windowNumber: 10, ownerPID: 2002, ownerName: "FullScreenApp", layer: 0, bounds: ourScreen, alpha: 1.0, isOnscreen: true),
            WindowSnapshotExternalWindow(windowNumber: 11, ownerPID: ourPID, ownerName: "codenv", layer: 0, bounds: ourFrame, alpha: 1.0, isOnscreen: true),
            WindowSnapshotExternalWindow(windowNumber: 12, ownerPID: 2003, ownerName: "OtherScreenApp", layer: 0, bounds: WindowSnapshotRect(x: -1000, y: 0, width: 500, height: 500), alpha: 1.0, isOnscreen: true),
        ]
        let whenOffscreen = WindowSnapshotFormatter.filterAboveWindows(
            allOnscreenFrontToBack: smallList,
            ourWindowNumber: 77777, // 不在清單內
            ourPID: ourPID,
            ourFrame: ourFrame,
            ourScreenFrame: ourScreen
        )
        XCTAssertEqual(whenOffscreen.map(\.ownerName), ["FullScreenApp"])
    }

    func testDetectFullscreenLayer0Windows() {
        let screen1 = WindowSnapshotScreen(
            index: 1, kind: "外接", isPrimary: true, isMain: true,
            pixelWidth: 3840, pixelHeight: 2160, scale: 2.0,
            frame: WindowSnapshotRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: WindowSnapshotRect(x: 0, y: 0, width: 1920, height: 1080)
        )
        let windows: [WindowSnapshotExternalWindow] = [
            // 自己的視窗：不計
            WindowSnapshotExternalWindow(windowNumber: 1, ownerPID: 1000, ownerName: "codenv", layer: 0, bounds: screen1.frame, alpha: 1.0, isOnscreen: true),
            // 非 layer 0：不計
            WindowSnapshotExternalWindow(windowNumber: 2, ownerPID: 2000, ownerName: "Window Server", layer: 1000, bounds: screen1.frame, alpha: 1.0, isOnscreen: true),
            // 符合條件的全螢幕 App
            WindowSnapshotExternalWindow(windowNumber: 3, ownerPID: 2001, ownerName: "Safari", layer: 0, bounds: WindowSnapshotRect(x: 0, y: 0, width: 1920, height: 1080), alpha: 1.0, isOnscreen: true),
            // 部分尺寸視窗：不計
            WindowSnapshotExternalWindow(windowNumber: 4, ownerPID: 2002, ownerName: "Finder", layer: 0, bounds: WindowSnapshotRect(x: 100, y: 100, width: 800, height: 600), alpha: 1.0, isOnscreen: true),
        ]
        let matches = WindowSnapshotFormatter.detectFullscreenLayer0Windows(onscreenWindows: windows, screens: [screen1], ourPID: 1000)
        XCTAssertEqual(matches, ["Safari@螢幕1"])
    }

    func testFormatSnapshotLinesContainsRequiredFieldsAndEmitsViaSink() {
        let screens = [
            WindowSnapshotScreen(
                index: 1, kind: "外接", isPrimary: true, isMain: true,
                pixelWidth: 3840, pixelHeight: 2160, scale: 2.0,
                frame: WindowSnapshotRect(x: 0, y: 0, width: 1920, height: 1080),
                visibleFrame: WindowSnapshotRect(x: 0, y: 0, width: 1920, height: 1050)
            ),
            WindowSnapshotScreen(
                index: 2, kind: "內建", isPrimary: false, isMain: false,
                pixelWidth: 2704, pixelHeight: 1756, scale: 2.0,
                frame: WindowSnapshotRect(x: -1352, y: 76, width: 1352, height: 878),
                visibleFrame: WindowSnapshotRect(x: -1352, y: 76, width: 1352, height: 878)
            ),
        ]
        let ownWindows = [
            WindowSnapshotOwnWindow(
                index: 1, isPrimaryMainWindow: true,
                frame: WindowSnapshotRect(x: 100, y: 120, width: 1280, height: 800),
                isOnActiveSpace: false, isVisible: true, occVisible: false,
                isKey: true, isMain: true, isMiniaturized: false,
                screenLabel: "1（外接）", level: 0, wsOnscreen: nil, space: "n/a",
                collectionBehaviorRaw: NSWindow.CollectionBehavior.fullScreenPrimary.rawValue
            ),
        ]
        let env = WindowSnapshotEnvironment(
            screensHaveSeparateSpaces: true,
            presentationOptionsRaw: NSApplication.PresentationOptions.hideMenuBar.rawValue,
            menuBarVisible: false,
            frontmostAppName: "Safari",
            frontmostActivationPolicy: "regular",
            frontmostIsSelf: false
        )
        let above = [
            WindowSnapshotExternalWindow(
                windowNumber: 42, ownerPID: 9999, ownerName: "Safari", layer: 0,
                bounds: WindowSnapshotRect(x: 0, y: 0, width: 1920, height: 1080),
                alpha: 1.0, isOnscreen: true
            ),
        ]
        let data = WindowSnapshotData(
            sequence: 1,
            trigger: .both,
            source: "live",
            sample: WindowStuckSample(isActive: true, isKey: true, isMain: true, occVisible: false, wsOnscreen: nil),
            mainOnActiveSpace: false,
            screens: screens,
            ownWindows: ownWindows,
            environment: env,
            fullscreenLayer0Matches: ["Safari@螢幕1"],
            aboveWindows: above
        )

        var emitted: [(String, String)] = []
        WindowSnapshotFormatter.emitSnapshot(data) { cat, msg in
            emitted.append((cat, msg))
        }

        XCTAssertEqual(emitted.count, 7)
        XCTAssertTrue(emitted.allSatisfy { $0.0 == "視窗快照" })
        // 每行必須小於 EventLog.scrub 的 400 字截斷門檻
        for (_, line) in emitted {
            XCTAssertLessThan(line.count, 380, "快照行過長可能被 EventLog 截斷：\(line)")
        }

        let lines = emitted.map(\.1)
        XCTAssertTrue(lines[0].hasPrefix("快照#1 開始 | 觸發=A+B 來源=live | active=true key=true main=true occ=hidden wsOnscreen=none onActiveSpace=false"))
        XCTAssertTrue(lines[1].contains("快照#1 螢幕#1 | 種類=外接 primary=true main=true") && lines[1].contains("visible=(0,0 1920×1050)"))
        XCTAssertTrue(lines[2].contains("快照#1 螢幕#2 | 種類=內建 primary=false main=false"))
        XCTAssertTrue(lines[3].contains("快照#1 視窗#1 | role=主視窗") && lines[3].contains("onActiveSpace=false") && lines[3].contains("behavior=fullScreenPrimary("))
        XCTAssertTrue(lines[4].contains("快照#1 環境 | separateSpaces=true") && lines[4].contains("menuBarVisible=false") && lines[4].contains("frontApp=Safari") && lines[4].contains("fullscreenLayer0=Safari@螢幕1") && lines[4].contains("fullscreenSuspected=true"))
        XCTAssertTrue(lines[5].contains("快照#1 上層視窗#1 | owner=Safari layer=0 bounds=(0,0 1920×1080) alpha=1.000 onscreen=true"))
        XCTAssertEqual(lines[6], "快照#1 結束 | 行數=7")
    }

    // MARK: - 每筆診斷新欄位、Dock reopen 與 EventLog sink 注入

    func testWindowDiagExtraFieldsAppendedPreservingOrder() {
        let existingPrefix = "事件=遮擋變化 視窗#1 | 螢幕=1（外接） scale=2.0 色域=sRGB | 視窗 alpha=1.000 opaque=true 背景=0.1000,0.1000,0.1000,1.0000 key=true main=true occ=hidden | 內容層 opacity=1.000 opaque=true 背景alpha=無 view_alpha=1.000 | 子層異常=無 | WindowServer alpha=1.000 onscreen=true layer=0 | 異常=無"
        let fullLine = existingPrefix + WindowSnapshotFormatter.formatWindowDiagSpaceSuffix(onActiveSpace: false, space: "n/a")

        XCTAssertTrue(fullLine.hasPrefix(existingPrefix))
        XCTAssertTrue(fullLine.hasSuffix(" | onActiveSpace=false space=n/a"))
        // 不重複加 wsOnscreen=（既有已有 WindowServer ... onscreen=）
        XCTAssertFalse(fullLine.contains("wsOnscreen="))

        XCTAssertEqual(WindowSnapshotFormatter.extractWorkspaceID(from: nil), "n/a")
        XCTAssertEqual(WindowSnapshotFormatter.extractWorkspaceID(from: ["kCGWindowLayer": 0]), "n/a")
        XCTAssertEqual(WindowSnapshotFormatter.extractWorkspaceID(from: ["kCGWindowWorkspace": NSNumber(value: 3)]), "3")
    }

    func testDockReopenFormatAndEventLogTestSink() {
        let withWindow = DockReopenSnapshot(
            hasWindow: true,
            isOnActiveSpace: false,
            occVisible: false,
            isVisible: true,
            isKeyWindow: true,
            isMiniaturized: false,
            isAppActive: true,
            hasVisibleWindows: true
        )
        let line1 = WindowSnapshotFormatter.formatDockReopenLine(withWindow)
        XCTAssertEqual(
            line1,
            "事件=點Dock重開 | appActive=true hasVisibleWindows=true | 主視窗 onActiveSpace=false occ=hidden visible=true key=true miniaturized=false"
        )

        let noWindow = DockReopenSnapshot(
            hasWindow: false,
            isOnActiveSpace: nil,
            occVisible: nil,
            isVisible: nil,
            isKeyWindow: nil,
            isMiniaturized: nil,
            isAppActive: false,
            hasVisibleWindows: false
        )
        let line2 = WindowSnapshotFormatter.formatDockReopenLine(noWindow)
        XCTAssertEqual(line2, "事件=點Dock重開 | appActive=false hasVisibleWindows=false | 主視窗=無")

        // 驗證 EventLog.testSink 攔截寫入，不碰磁碟與 ~/Library/Logs/codenv
        var captured: [(String, String)] = []
        EventLog.testSink = { cat, msg in captured.append((cat, msg)) }
        defer { EventLog.testSink = nil }

        EventLog.log(WindowSnapshotFormatter.diagnosticCategory, line1)
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured[0].0, "視窗診斷")
        XCTAssertEqual(captured[0].1, line1)
    }

    // MARK: - --window-diag-inject 規格解析與合併

    func testWindowDiagInjectSpecParsingAndMerge() {
        let cmd1 = WindowDiagInjectCommand.parse("occ=hidden,space=off,active=1,key=1,main=1,onscreen=0")
        XCTAssertEqual(cmd1?.delaySeconds, 0)
        XCTAssertEqual(cmd1?.clear, false)
        XCTAssertEqual(cmd1?.patch.occVisible, false)
        XCTAssertEqual(cmd1?.patch.isOnActiveSpace, false)
        XCTAssertEqual(cmd1?.patch.isActive, true)
        XCTAssertEqual(cmd1?.patch.isKey, true)
        XCTAssertEqual(cmd1?.patch.isMain, true)
        XCTAssertEqual(cmd1?.patch.wsOnscreen, .some(false))

        let cmdNone = WindowDiagInjectCommand.parse("onscreen=none,key=1")
        XCTAssertEqual(cmdNone?.patch.wsOnscreen, .some(nil))
        XCTAssertEqual(cmdNone?.patch.isKey, true)

        let cmd2 = WindowDiagInjectCommand.parse("3.5:occ=visible")
        XCTAssertEqual(cmd2?.delaySeconds, 3.5)
        XCTAssertEqual(cmd2?.patch.occVisible, true)
        XCTAssertNil(cmd2?.patch.isKey)

        // 合併後只覆寫 occVisible，保留先前設定的欄位
        var state = cmd1!.patch
        state.merge(cmd2!.patch)
        let applied = state.applying(to: WindowStuckSample(isActive: false, isKey: false, isMain: false, occVisible: false, wsOnscreen: true))
        XCTAssertEqual(applied, WindowStuckSample(isActive: true, isKey: true, isMain: true, occVisible: true, wsOnscreen: false))

        let cmdClear = WindowDiagInjectCommand.parse("5:clear")
        XCTAssertEqual(cmdClear?.delaySeconds, 5.0)
        XCTAssertEqual(cmdClear?.clear, true)

        let cmdReopen = WindowDiagInjectCommand.parse("2.0:reopen=1")
        XCTAssertEqual(cmdReopen?.delaySeconds, 2.0)
        XCTAssertEqual(cmdReopen?.triggerReopen, true)

        // 驗證雙層 Optional wsOnscreen 套用邏輯：none 覆寫 live=true 成 nil；未覆寫時保留 live=false
        let liveTrue = WindowStuckSample(isActive: false, isKey: true, isMain: false, occVisible: true, wsOnscreen: true)
        let appliedNone = cmdNone!.patch.applying(to: liveTrue)
        XCTAssertNil(appliedNone.wsOnscreen)
        XCTAssertTrue(appliedNone.matchesConditionB)

        let liveFalse = WindowStuckSample(isActive: false, isKey: true, isMain: false, occVisible: true, wsOnscreen: false)
        let onlyOccPatch = WindowDiagInjectCommand.parse("occ=visible")!.patch
        let appliedKeep = onlyOccPatch.applying(to: liveFalse)
        XCTAssertEqual(appliedKeep.wsOnscreen, false)

        XCTAssertNil(WindowDiagInjectCommand.parse(""))
        XCTAssertNil(WindowDiagInjectCommand.parse("unknown=123"))
    }

    @MainActor
    func testWindowDiagRecordDockReopenWithInjectedSink() {
        var captured: [(String, String)] = []
        WindowDiag.recordDockReopen(window: nil, isAppActive: true, hasVisibleWindows: false) { cat, msg in
            captured.append((cat, msg))
        }
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured[0].0, "視窗診斷")
        XCTAssertEqual(captured[0].1, "事件=點Dock重開 | appActive=true hasVisibleWindows=false | 主視窗=無")
    }
}
