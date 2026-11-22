import AppKit
import CoreGraphics
import XCTest
@testable import Workbench

final class WindowDiagFieldsTests: XCTestCase {

    // MARK: - A.1 frameInUnion 判斷（含 L 形多螢幕空區、邊界接觸、activeDisplays 過濾）

    func testFrameInUnionBasicInsideAndOutside() {
        let screens = [
            WindowDiagScreenInfo(displayID: 1, frame: WindowSnapshotRect(x: 0, y: 0, width: 1920, height: 1080)),
            WindowDiagScreenInfo(displayID: 2, frame: WindowSnapshotRect(x: -1352, y: 76, width: 1352, height: 878)),
        ]
        // 完全在螢幕 1 內
        XCTAssertTrue(WindowDiagFieldsFormatter.isFrameInUnion(
            frame: WindowSnapshotRect(x: 100, y: 100, width: 1200, height: 800),
            screens: screens,
            activeDisplayIDs: [1, 2]
        ))
        // 部分跨界重疊螢幕 2
        XCTAssertTrue(WindowDiagFieldsFormatter.isFrameInUnion(
            frame: WindowSnapshotRect(x: -1500, y: 200, width: 300, height: 300),
            screens: screens,
            activeDisplayIDs: [1, 2]
        ))
        // 完全落在所有螢幕之外（斷線虛擬螢幕殘留座標）
        XCTAssertFalse(WindowDiagFieldsFormatter.isFrameInUnion(
            frame: WindowSnapshotRect(x: 3000, y: 0, width: 1280, height: 800),
            screens: screens,
            activeDisplayIDs: [1, 2]
        ))
        // 僅邊界相切（交集寬為 0）：不算在聯集內
        XCTAssertFalse(WindowDiagFieldsFormatter.isFrameInUnion(
            frame: WindowSnapshotRect(x: 1920, y: 0, width: 800, height: 600),
            screens: screens,
            activeDisplayIDs: [1, 2]
        ))
        // 寬或高為 0 的退化視窗：不算在聯集內
        XCTAssertFalse(WindowDiagFieldsFormatter.isFrameInUnion(
            frame: WindowSnapshotRect(x: 100, y: 100, width: 0, height: 600),
            screens: screens,
            activeDisplayIDs: [1, 2]
        ))
    }

    func testFrameInUnionLShapedDeadZoneAndInactiveDisplayFiltering() {
        // L 形排列：螢幕 1 在 (0,0 1920x1080)，螢幕 2 在 (1920,600 1000x480)
        // 空區 (1920,0 1000x600) 落在外接矩形內，但不屬於任何螢幕的真正聯集
        let screens = [
            WindowDiagScreenInfo(displayID: 10, frame: WindowSnapshotRect(x: 0, y: 0, width: 1920, height: 1080)),
            WindowDiagScreenInfo(displayID: 20, frame: WindowSnapshotRect(x: 1920, y: 600, width: 1000, height: 480)),
        ]
        XCTAssertFalse(WindowDiagFieldsFormatter.isFrameInUnion(
            frame: WindowSnapshotRect(x: 2000, y: 50, width: 500, height: 400),
            screens: screens,
            activeDisplayIDs: [10, 20]
        ))

        // 若 display 20 已不在 CGGetActiveDisplayList（斷線虛擬螢幕），落在其上的視窗必須判為 false
        let onDisplay20 = WindowSnapshotRect(x: 2000, y: 700, width: 500, height: 300)
        XCTAssertTrue(WindowDiagFieldsFormatter.isFrameInUnion(frame: onDisplay20, screens: screens, activeDisplayIDs: [10, 20]))
        XCTAssertFalse(WindowDiagFieldsFormatter.isFrameInUnion(frame: onDisplay20, screens: screens, activeDisplayIDs: [10]))

        // activeDisplays 為空（無有效顯示器）一律 false
        XCTAssertFalse(WindowDiagFieldsFormatter.isFrameInUnion(
            frame: WindowSnapshotRect(x: 100, y: 100, width: 800, height: 600),
            screens: screens,
            activeDisplayIDs: []
        ))
    }

    // MARK: - A.1 .optionAll 字典解析與格式化

    func testParseAndFormatCGAllInfo() {
        // 正常視窗：含 bounds、onscreen=true、memoryUsage
        let normalDict: [String: Any] = [
            kCGWindowBounds as String: ["X": 120.0, "Y": 44.0, "Width": 1280.0, "Height": 800.0] as NSDictionary,
            kCGWindowIsOnscreen as String: true,
            kCGWindowMemoryUsage as String: NSNumber(value: 8_388_608),
        ]
        let normal = WindowDiagFieldsFormatter.parseCGAllInfo(from: normalDict)
        XCTAssertEqual(normal?.bounds, WindowSnapshotRect(x: 120, y: 44, width: 1280, height: 800))
        XCTAssertEqual(normal?.isOnscreen, true)
        XCTAssertEqual(normal?.memoryUsage, 8_388_608)
        XCTAssertEqual(
            WindowDiagFieldsFormatter.formatCGAll(normal),
            "bounds(120,44,1280x800),on=true,mem=8388608"
        )

        // backing 釋放且省略 kCGWindowIsOnscreen 鍵（macOS 非 onscreen 視窗常見形態）
        let releasedDict: [String: Any] = [
            kCGWindowBounds as String: ["X": -2000.0, "Y": 0.0, "Width": 1280.0, "Height": 800.0] as NSDictionary,
            kCGWindowMemoryUsage as String: NSNumber(value: 0),
        ]
        let released = WindowDiagFieldsFormatter.parseCGAllInfo(from: releasedDict)
        XCTAssertNil(released?.isOnscreen)
        XCTAssertEqual(released?.memoryUsage, 0)
        XCTAssertEqual(
            WindowDiagFieldsFormatter.formatCGAll(released),
            "bounds(-2000,0,1280x800),on=none,mem=0"
        )

        // 查不到該 windowNumber（nil）
        XCTAssertNil(WindowDiagFieldsFormatter.parseCGAllInfo(from: nil))
        XCTAssertEqual(WindowDiagFieldsFormatter.formatCGAll(nil), "none")
    }

    // MARK: - A.1 追加欄位格式與 wnChanged 偵測

    func testExtendedSuffixContainsAllFieldsAndWnChanged() {
        let screens = [
            WindowDiagScreenInfo(displayID: 1, frame: WindowSnapshotRect(x: 0, y: 0, width: 1920, height: 1080)),
            WindowDiagScreenInfo(displayID: 2, frame: WindowSnapshotRect(x: -1352, y: 76, width: 1352, height: 878)),
        ]
        let cgAll = WindowDiagCGAllInfo(
            bounds: WindowSnapshotRect(x: 100, y: 160, width: 1280, height: 800),
            isOnscreen: false,
            memoryUsage: 0
        )

        // 首筆（previousWindowNumber == nil）：不應含 wnChanged=
        let first = WindowDiagExtendedFields(
            frame: WindowSnapshotRect(x: 100, y: 120, width: 1280, height: 800),
            screenID: 1,
            screens: screens,
            activeDisplays: [1, 2],
            frameInUnion: true,
            isVisible: true,
            isMiniaturized: false,
            appHidden: false,
            collectionBehaviorRaw: 0x80,
            level: 0,
            parentWindowNumber: nil,
            childWindowNumbers: [901, 902],
            windowNumber: 500,
            previousWindowNumber: nil,
            cgAll: cgAll
        )
        let firstSuffix = WindowDiagFieldsFormatter.formatExtendedSuffix(first)
        XCTAssertTrue(firstSuffix.hasPrefix(" | frame=(100,120 1280×800) screenID=1 screens=1@0,0,1920x1080;2@-1352,76,1352x878 activeDisplays=1,2 frameInUnion=true isVisible=true isMiniaturized=false appHidden=false collectionBehavior=0x80 level=0 parent=none children=901,902 wn=500 "))
        XCTAssertFalse(firstSuffix.contains("wnChanged="))
        XCTAssertTrue(firstSuffix.hasSuffix("cgAll=bounds(100,160,1280x800),on=false,mem=0"))

        // 同 windowNumber（500 -> 500）：不加 wnChanged=
        var sameWN = first
        sameWN.previousWindowNumber = 500
        XCTAssertFalse(WindowDiagFieldsFormatter.formatExtendedSuffix(sameWN).contains("wnChanged="))

        // windowNumber 換號（500 -> 777）：同列緊接 wn=777 後加 wnChanged=500->777
        var changedWN = first
        changedWN.previousWindowNumber = 500
        changedWN.windowNumber = 777
        changedWN.parentWindowNumber = 400
        changedWN.childWindowNumbers = []
        changedWN.cgAll = nil
        let changedSuffix = WindowDiagFieldsFormatter.formatExtendedSuffix(changedWN)
        XCTAssertTrue(changedSuffix.contains("parent=400 children=none wn=777 wnChanged=500->777 cgAll=none"))

        // 確認串接在既有行與第 1 輪後綴之後，原本欄位順序完全不變
        let existingPrefix = "事件=遮擋變化 視窗#1 | 螢幕=1（外接） scale=2.0 色域=sRGB | 視窗 alpha=1.000 opaque=true 背景=0.1000,0.1000,0.1000,1.0000 key=true main=true occ=hidden | 內容層 opacity=1.000 opaque=true 背景alpha=無 view_alpha=1.000 | 子層異常=無 | WindowServer alpha=1.000 onscreen=無 layer=0 | 異常=無"
        let fullLine = existingPrefix
            + WindowSnapshotFormatter.formatWindowDiagSpaceSuffix(onActiveSpace: false, space: "n/a")
            + changedSuffix
        XCTAssertTrue(fullLine.hasPrefix(existingPrefix + " | onActiveSpace=false space=n/a | frame="))
        XCTAssertLessThan(fullLine.count, EventLog.maxMessageLength(for: "視窗診斷"))
    }

    // MARK: - A.2 異常快照列出全部 NSApp.windows（最多 40 筆、含 NSPanel、不含標題）

    func testSnapshotOwnWindowsIncludesAllPanelsAndCapsAt40() {
        var own: [WindowSnapshotOwnWindow] = []
        for i in 1...45 {
            own.append(WindowSnapshotOwnWindow(
                index: i,
                isPrimaryMainWindow: i == 1,
                frame: WindowSnapshotRect(x: i * 10, y: 20, width: 300, height: 200),
                isOnActiveSpace: i == 1 ? false : true,
                isVisible: i % 2 == 1,
                occVisible: i % 2 == 1,
                isKey: i == 1,
                isMain: i == 1,
                isMiniaturized: false,
                screenLabel: "1（外接）",
                level: i == 2 ? 3 : 0,
                wsOnscreen: i == 1 ? nil : (i % 2 == 1),
                space: "n/a",
                collectionBehaviorRaw: 0,
                alpha: i == 2 ? 0.85 : 1.0,
                windowNumber: 1000 + i,
                windowClass: i == 2 ? "RadialPanel" : "NSPanel"
            ))
        }
        let data = WindowSnapshotData(
            sequence: 2,
            trigger: .conditionB,
            source: "live",
            sample: WindowStuckSample(isActive: false, isKey: true, isMain: true, occVisible: true, wsOnscreen: nil),
            mainOnActiveSpace: false,
            screens: [],
            ownWindows: own,
            environment: WindowSnapshotEnvironment(
                screensHaveSeparateSpaces: true,
                presentationOptionsRaw: 0,
                menuBarVisible: true,
                frontmostAppName: "codenv",
                frontmostActivationPolicy: "regular",
                frontmostIsSelf: true
            ),
            fullscreenLayer0Matches: [],
            aboveWindows: []
        )

        let lines = WindowSnapshotFormatter.formatLines(data)
        XCTAssertTrue(lines[0].contains("視窗數=40"))
        let windowLines = lines.filter { $0.contains("快照#2 視窗#") }
        XCTAssertEqual(windowLines.count, 40)
        XCTAssertTrue(windowLines[1].contains("alpha=0.850 wn=1002 cls=RadialPanel"))
        XCTAssertTrue(windowLines[1].contains("visible=false") && windowLines[1].contains("level=3"))
        for line in lines {
            XCTAssertLessThan(line.count, 380)
        }
    }

    // MARK: - A.3 呼叫堆疊符號解析（前 6 層、只留符號名）與頻率上限

    func testCallStackSymbolParsingAndTop6Limit() {
        let rawStack = [
            "0   Workbench                           0x0000000104a00010 $s9Workbench10WindowDiagO23recordFocusSourceEventyyFZ + 64",
            "1   Foundation                          0x000000018a123456 -[__NSObserver _doit:] + 348",
            "2   CoreFoundation                      0x0000000189abcdef __CFNOTIFICATIONCENTER_IS_CALLING_OUT_TO_AN_OBSERVER__ + 148",
            "3   AppKit                              0x000000018c112233 -[NSWindow _changeKeyAndMainLimitedOK:] + 980",
            "4   AppKit                              0x000000018c112500 -[NSWindow makeKeyAndOrderFront:] + 120",
            "5   Workbench                           0x0000000104b00100 MainWindowController.showSettings(sender: Any?) + 44",
            "6   AppKit                              0x000000018c220000 -[NSApplication sendAction:to:from:] + 312",
            "7   AppKit                              0x000000018c220100 -[NSApplication run] + 500",
        ]

        let symbols = WindowDiagCallStackFormatter.extractSymbolNames(
            from: rawStack,
            maxFrames: 6,
            skipSubstrings: ["recordFocusSourceEvent"]
        )
        XCTAssertEqual(symbols.count, 6)
        XCTAssertEqual(symbols[0], "-[__NSObserver _doit:]")
        XCTAssertEqual(symbols[1], "__CFNOTIFICATIONCENTER_IS_CALLING_OUT_TO_AN_OBSERVER__")
        XCTAssertEqual(symbols[2], "-[NSWindow _changeKeyAndMainLimitedOK:]")
        XCTAssertEqual(symbols[3], "-[NSWindow makeKeyAndOrderFront:]")
        // 含參數括號的符號只留符號主體、不記參數
        XCTAssertEqual(symbols[4], "MainWindowController.showSettings")
        XCTAssertEqual(symbols[5], "-[NSApplication sendAction:to:from:]")

        let formatted = WindowDiagCallStackFormatter.formatFocusSourceLine(
            kind: .winBecomeKey,
            frontAppName: "codenv",
            frontBundleID: "com.local.aiworkbench",
            windowClass: "NSPanel",
            windowNumber: 456,
            symbols: symbols
        )
        XCTAssertTrue(formatted.hasPrefix("事件=焦點來源 | kind=winBecomeKey frontApp=codenv frontBundle=com.local.aiworkbench | winClass=NSPanel wn=456 | stack="))
        XCTAssertFalse(formatted.contains("0x0000000"))
        XCTAssertFalse(formatted.contains("sender:"))
    }

    func testFocusSourceRateLimiterBlocksBursts() {
        var limiter = WindowDiagRateLimiter(
            minIntervalPerKey: 0.5,
            windowDuration: 60.0,
            maxPerKeyInWindow: 3,
            maxTotalInWindow: 5
        )
        XCTAssertTrue(limiter.allow(key: "appBecomeActive", at: 10.0))
        // 0.5s 內同事件阻擋
        XCTAssertFalse(limiter.allow(key: "appBecomeActive", at: 10.2))
        XCTAssertTrue(limiter.allow(key: "appBecomeActive", at: 10.5))
        XCTAssertTrue(limiter.allow(key: "appBecomeActive", at: 12.0))
        // 單事件達 3 次上限：阻擋
        XCTAssertFalse(limiter.allow(key: "appBecomeActive", at: 15.0))
        // 另一事件仍可通過，直到全域達 5 次上限
        XCTAssertTrue(limiter.allow(key: "winBecomeKey", at: 15.0))
        XCTAssertTrue(limiter.allow(key: "winBecomeKey", at: 16.0))
        XCTAssertFalse(limiter.allow(key: "winResignKey", at: 17.0))
        // 超過 60s 滑動視窗後恢復
        XCTAssertTrue(limiter.allow(key: "appBecomeActive", at: 75.0))
    }

    // MARK: - 第 2 輪 --window-diag-inject 擴充規格與 EventLog 類別長度上限

    func testRound2InjectSpecParsing() {
        let cmd = WindowDiagInjectCommand.parse(
            "1.5:occ=hidden,space=off,key=1,onscreen=0,frameout=1,rescue-ok=2,alpha-node=NSView[0]/TabBar[2]:0.45,alpha-node=NSView[0]/L:CALayer[0]:0.30"
        )
        XCTAssertEqual(cmd?.delaySeconds, 1.5)
        XCTAssertEqual(cmd?.patch.frameOutOfBounds, true)
        XCTAssertEqual(cmd?.patch.isOnActiveSpace, false)
        XCTAssertEqual(cmd?.patch.rescueOutcome, .step2)
        XCTAssertEqual(cmd?.patch.alphaNodes?.count, 2)
        XCTAssertEqual(cmd?.patch.alphaNodes?[0], AlphaScanInjectedNode(path: "NSView[0]/TabBar[2]", opacity: 0.45))
        XCTAssertEqual(cmd?.patch.alphaNodes?[1], AlphaScanInjectedNode(path: "NSView[0]/L:CALayer[0]", opacity: 0.30))

        let cmdNone = WindowDiagInjectCommand.parse("rescue-ok=none,frameout=0")
        XCTAssertEqual(cmdNone?.patch.rescueOutcome, .never)
        XCTAssertEqual(cmdNone?.patch.frameOutOfBounds, false)

        // EventLog 視窗診斷類別放寬上限避免截斷、其他類別維持 400
        XCTAssertEqual(EventLog.maxMessageLength(for: "視窗診斷"), 1600)
        XCTAssertEqual(EventLog.maxMessageLength(for: "視窗診斷!"), 1600)
        XCTAssertEqual(EventLog.maxMessageLength(for: "視窗救援"), 1600)
        XCTAssertEqual(EventLog.maxMessageLength(for: "視窗半透明"), 1600)
        XCTAssertEqual(EventLog.maxMessageLength(for: "一般"), 400)
    }
}
