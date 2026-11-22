import CoreGraphics
import Foundation
import XCTest
@testable import Workbench

final class F12PanelLayoutTests: XCTestCase {

    private var createdSuiteNames: [String] = []

    override func tearDown() {
        for suite in createdSuiteNames {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        createdSuiteNames = []
        super.tearDown()
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        let suite = "com.local.aiworkbench.unit.f12panel.\(UUID().uuidString)"
        createdSuiteNames.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - 1. UsagePanelGeometry.layout（規格 3.A 四組 a～d＋邊界＋clamp＋螢幕 nil 退回）

    func testGeometryLayoutSpecCasesAToD() {
        // (a) 可見 1512×945、uiScale 1.15、父視窗 1512 寬 → 4 欄、panelScale 1.15、panelWidth 1481.2
        let caseA = UsagePanelGeometry.layout(
            parentFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 945),
            uiScale: 1.15,
            panelHeight: 540
        )
        XCTAssertEqual(caseA.columns, 4)
        XCTAssertEqual(caseA.panelScale, 1.15, accuracy: 0.0001)
        XCTAssertEqual(caseA.panelWidth, 1288 * 1.15, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(caseA.originX, 0)
        XCTAssertLessThanOrEqual(caseA.originX + caseA.panelWidth, 1512)

        // (b) 可見 1512×945、uiScale 1.0、父視窗 900 寬 → 4 欄（不再被父視窗寬×0.95 限縮成 2～3 欄）
        let caseB = UsagePanelGeometry.layout(
            parentFrame: CGRect(x: 300, y: 100, width: 900, height: 700),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 945),
            uiScale: 1.0,
            panelHeight: 500
        )
        XCTAssertEqual(caseB.columns, 4)
        XCTAssertEqual(caseB.panelScale, 1.0, accuracy: 0.0001)
        XCTAssertEqual(caseB.panelWidth, 1288, accuracy: 0.01)
        XCTAssertEqual(caseB.originX, 750 - 644, accuracy: 0.01)

        // (c) 螢幕 1280 寬、uiScale 1.15 → (1280-24)/1288 ≈ 0.975 < 1.0 → 3 欄且 panelScale 等於 uiScale
        let caseC = UsagePanelGeometry.layout(
            parentFrame: CGRect(x: 0, y: 0, width: 1280, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1280, height: 775),
            uiScale: 1.15,
            panelHeight: 520
        )
        XCTAssertEqual(caseC.columns, 3)
        XCTAssertEqual(caseC.panelScale, 1.15, accuracy: 0.0001)
        XCTAssertEqual(caseC.panelWidth, UsagePanelGeometry.panelWidth(columns: 3, scale: 1.15), accuracy: 0.01)

        // (d) Dock 置左使可見寬 1432（leftInset=80）、uiScale 1.15 → 可用寬 1408、panelScale = 1408/1288 ≈ 1.0932、4 欄
        let caseD = UsagePanelGeometry.layout(
            parentFrame: CGRect(x: 80, y: 0, width: 1432, height: 945),
            visibleFrame: CGRect(x: 80, y: 0, width: 1432, height: 945),
            uiScale: 1.15,
            panelHeight: 520
        )
        XCTAssertEqual(caseD.columns, 4)
        XCTAssertEqual(caseD.panelScale, 1408.0 / 1288.0, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(caseD.panelScale, 1.0)
        XCTAssertLessThan(caseD.panelScale, 1.15)
        XCTAssertEqual(caseD.panelWidth, 1408, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(caseD.originX, 80)
        XCTAssertLessThanOrEqual(caseD.originX + caseD.panelWidth, 80 + 1432)
    }

    func testGeometryLayoutScaleBoundariesAndColumnReduction() {
        // 剛好可用寬 = 1288（可見寬 1312），uiScale 1.15 → 縮到 panelScale = 1.0 仍可 4 欄
        let exactOne = UsagePanelGeometry.layout(
            parentFrame: CGRect(x: 0, y: 0, width: 1312, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1312, height: 800),
            uiScale: 1.15
        )
        XCTAssertEqual(exactOne.columns, 4)
        XCTAssertEqual(exactOne.panelScale, 1.0, accuracy: 0.0001)
        XCTAssertEqual(exactOne.panelWidth, 1288, accuracy: 0.01)

        // 少 1pt（可見寬 1311 → 可用寬 1287 < 1288）→ 減為 3 欄且 panelScale 維持 1.15
        let belowOne = UsagePanelGeometry.layout(
            parentFrame: CGRect(x: 0, y: 0, width: 1311, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1311, height: 800),
            uiScale: 1.15
        )
        XCTAssertEqual(belowOne.columns, 3)
        XCTAssertEqual(belowOne.panelScale, 1.15, accuracy: 0.0001)

        // 更窄螢幕減至 2 欄與 1 欄
        let twoCol = UsagePanelGeometry.layout(
            parentFrame: CGRect(x: 0, y: 0, width: 900, height: 700),
            visibleFrame: CGRect(x: 0, y: 0, width: 900, height: 700),
            uiScale: 1.15
        )
        XCTAssertEqual(twoCol.columns, 2)
        XCTAssertEqual(twoCol.panelScale, 1.15, accuracy: 0.0001)

        let oneCol = UsagePanelGeometry.layout(
            parentFrame: CGRect(x: 0, y: 0, width: 500, height: 700),
            visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 700),
            uiScale: 1.15
        )
        XCTAssertEqual(oneCol.columns, 1)
        XCTAssertEqual(oneCol.panelScale, 1.15, accuracy: 0.0001)

        // uiScale < 1.0（如 0.85）正常維持 uiScale 不強拉到 1.0
        let smallScale = UsagePanelGeometry.layout(
            parentFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            uiScale: 0.85
        )
        XCTAssertEqual(smallScale.columns, 4)
        XCTAssertEqual(smallScale.panelScale, 0.85, accuracy: 0.0001)
    }

    func testGeometryLayoutHorizontalAndVerticalClampAfterParentMove() {
        let visible = CGRect(x: 80, y: 48, width: 1432, height: 900)
        let panelHeight: CGFloat = 500

        // 父視窗移到左上超出邊界
        let topLeft = UsagePanelGeometry.layout(
            parentFrame: CGRect(x: -400, y: 800, width: 900, height: 600),
            visibleFrame: visible,
            uiScale: 1.0,
            panelHeight: panelHeight
        )
        XCTAssertEqual(topLeft.originX, visible.minX, accuracy: 0.01)
        XCTAssertEqual(topLeft.originY, visible.maxY - panelHeight, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(topLeft.originX, visible.minX)
        XCTAssertLessThanOrEqual(topLeft.originX + topLeft.panelWidth, visible.maxX)
        XCTAssertGreaterThanOrEqual(topLeft.originY, visible.minY)
        XCTAssertLessThanOrEqual(topLeft.originY + panelHeight, visible.maxY)

        // 父視窗移到右下超出邊界
        let bottomRight = UsagePanelGeometry.layout(
            parentFrame: CGRect(x: 1300, y: -300, width: 900, height: 600),
            visibleFrame: visible,
            uiScale: 1.0,
            panelHeight: panelHeight
        )
        XCTAssertEqual(bottomRight.originX, visible.maxX - bottomRight.panelWidth, accuracy: 0.01)
        XCTAssertEqual(bottomRight.originY, visible.minY, accuracy: 0.01)

        // 省略 panelHeight（預設 0）也能正常 3 參數呼叫並垂直 clamp
        let threeArg = UsagePanelGeometry.layout(
            parentFrame: CGRect(x: 1600, y: 1200, width: 800, height: 600),
            visibleFrame: visible,
            uiScale: 1.0
        )
        XCTAssertEqual(threeArg.originX, visible.maxX - threeArg.panelWidth, accuracy: 0.01)
        XCTAssertEqual(threeArg.originY, visible.maxY, accuracy: 0.01)
    }

    func testGeometryScreenNilFallbackOrder() {
        let winScreen = CGRect(x: 1512, y: 0, width: 1366, height: 1000)
        let mainScreen = CGRect(x: 0, y: 25, width: 1512, height: 945)
        let firstScreen = CGRect(x: -1440, y: 0, width: 1440, height: 875)
        let parentFrame = CGRect(x: 100, y: 100, width: 900, height: 600)

        XCTAssertEqual(
            UsagePanelGeometry.resolveVisibleFrame(
                windowScreenFrame: winScreen,
                mainScreenFrame: mainScreen,
                firstScreenFrame: firstScreen,
                parentFrame: parentFrame
            ),
            winScreen
        )
        XCTAssertEqual(
            UsagePanelGeometry.resolveVisibleFrame(
                windowScreenFrame: nil,
                mainScreenFrame: mainScreen,
                firstScreenFrame: firstScreen,
                parentFrame: parentFrame
            ),
            mainScreen
        )
        XCTAssertEqual(
            UsagePanelGeometry.resolveVisibleFrame(
                windowScreenFrame: nil,
                mainScreenFrame: nil,
                firstScreenFrame: firstScreen,
                parentFrame: parentFrame
            ),
            firstScreen
        )
        XCTAssertEqual(
            UsagePanelGeometry.resolveVisibleFrame(
                windowScreenFrame: nil,
                mainScreenFrame: nil,
                firstScreenFrame: nil,
                parentFrame: parentFrame
            ),
            parentFrame
        )
    }

    func testNeedsRemeasureBranchesAndConstrainedWindowWidth() {
        let base = UsagePanelGeometry.Layout(
            columns: 4,
            panelScale: 1.15,
            panelWidth: 1481.2,
            originX: 15.4,
            originY: 120
        )

        // 1. previous == nil → 視為需要重新量測
        XCTAssertTrue(UsagePanelGeometry.needsRemeasure(previous: nil, next: base))

        // 2. 全部相同 → 不需要重新量測
        XCTAssertFalse(UsagePanelGeometry.needsRemeasure(previous: base, next: base))

        // 3. 僅視窗座標（originX／originY）改變 → 不需要重新量測
        let movedOnly = UsagePanelGeometry.Layout(
            columns: 4,
            panelScale: 1.15,
            panelWidth: 1481.2,
            originX: 240,
            originY: 310
        )
        XCTAssertFalse(UsagePanelGeometry.needsRemeasure(previous: base, next: movedOnly))

        // 4. panelWidth 改變：容差（0.5pt）內為 false，超過 0.5pt 為 true
        let widthWithinTol = UsagePanelGeometry.Layout(
            columns: 4,
            panelScale: 1.15,
            panelWidth: base.panelWidth + 0.4,
            originX: base.originX,
            originY: base.originY
        )
        XCTAssertFalse(UsagePanelGeometry.needsRemeasure(previous: base, next: widthWithinTol))

        let exactHalfPointBase = UsagePanelGeometry.Layout(
            columns: 4, panelScale: 1.0, panelWidth: 1288.0, originX: 0, originY: 0
        )
        let exactHalfPointNext = UsagePanelGeometry.Layout(
            columns: 4, panelScale: 1.0, panelWidth: 1288.5, originX: 0, originY: 0
        )
        XCTAssertFalse(UsagePanelGeometry.needsRemeasure(previous: exactHalfPointBase, next: exactHalfPointNext))

        let widthChangedUp = UsagePanelGeometry.Layout(
            columns: 4, panelScale: 1.15, panelWidth: base.panelWidth + 0.6, originX: base.originX, originY: base.originY
        )
        let widthChangedDown = UsagePanelGeometry.Layout(
            columns: 4, panelScale: 1.15, panelWidth: base.panelWidth - 1.0, originX: base.originX, originY: base.originY
        )
        XCTAssertTrue(UsagePanelGeometry.needsRemeasure(previous: base, next: widthChangedUp))
        XCTAssertTrue(UsagePanelGeometry.needsRemeasure(previous: base, next: widthChangedDown))

        // 5. panelScale 改變：容差（0.0001）內為 false，超過 0.0001 為 true
        let scaleWithinTol = UsagePanelGeometry.Layout(
            columns: 4, panelScale: base.panelScale + 0.00005, panelWidth: base.panelWidth, originX: base.originX, originY: base.originY
        )
        XCTAssertFalse(UsagePanelGeometry.needsRemeasure(previous: base, next: scaleWithinTol))

        let scaleChangedUp = UsagePanelGeometry.Layout(
            columns: 4, panelScale: base.panelScale + 0.0002, panelWidth: base.panelWidth, originX: base.originX, originY: base.originY
        )
        let scaleChangedDown = UsagePanelGeometry.Layout(
            columns: 4, panelScale: base.panelScale - 0.0002, panelWidth: base.panelWidth, originX: base.originX, originY: base.originY
        )
        XCTAssertTrue(UsagePanelGeometry.needsRemeasure(previous: base, next: scaleChangedUp))
        XCTAssertTrue(UsagePanelGeometry.needsRemeasure(previous: base, next: scaleChangedDown))

        // 6. 僅 columns 改變 → true
        let columnsChanged = UsagePanelGeometry.Layout(
            columns: 3, panelScale: base.panelScale, panelWidth: base.panelWidth, originX: base.originX, originY: base.originY
        )
        XCTAssertTrue(UsagePanelGeometry.needsRemeasure(previous: base, next: columnsChanged))

        // 7. 系統因實體螢幕較窄限縮實際視窗寬度（如 iPad 虛擬螢幕 ~1092pt 跑 C500 G(a)），
        //    但模擬可見區與 uiScale 算出的幾何不變 → 必須回 false（不誤清 hasMeasuredCurrentLayout）
        let simulatedVisible = CGRect(x: 0, y: 0, width: 1512, height: 945)
        let initialLayout = UsagePanelGeometry.layout(
            parentFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: simulatedVisible,
            uiScale: 1.15,
            panelHeight: 540
        )
        let snapshot = UsageSheet.GeometrySnapshot(
            columns: initialLayout.columns,
            panelScale: initialLayout.panelScale,
            panelWidth: initialLayout.panelWidth,
            originX: initialLayout.originX,
            originY: initialLayout.originY,
            visibleFrame: simulatedVisible
        )
        let constrainedActualWindowWidth: CGFloat = 1092
        XCTAssertGreaterThan(abs(constrainedActualWindowWidth - initialLayout.panelWidth), 0.5)

        let lateNotificationLayout = UsagePanelGeometry.layout(
            parentFrame: CGRect(x: 24, y: 12, width: constrainedActualWindowWidth, height: 768),
            visibleFrame: simulatedVisible,
            uiScale: 1.15,
            panelHeight: 540
        )
        XCTAssertFalse(UsagePanelGeometry.needsRemeasure(previous: snapshot.layout, next: lateNotificationLayout))

        // 真正切換到較窄可見區（1512 → 1432 微縮 4 欄，或 1512 → 1280 減為 3 欄）→ true
        let shrunkLayout = UsagePanelGeometry.layout(
            parentFrame: CGRect(x: 80, y: 0, width: 1432, height: 945),
            visibleFrame: CGRect(x: 80, y: 0, width: 1432, height: 945),
            uiScale: 1.15,
            panelHeight: 540
        )
        XCTAssertTrue(UsagePanelGeometry.needsRemeasure(previous: snapshot.layout, next: shrunkLayout))

        let threeColLayout = UsagePanelGeometry.layout(
            parentFrame: CGRect(x: 0, y: 0, width: 1280, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1280, height: 775),
            uiScale: 1.15,
            panelHeight: 520
        )
        XCTAssertTrue(UsagePanelGeometry.needsRemeasure(previous: snapshot.layout, next: threeColLayout))

        // 8. 非有限數（NaN）安全視為需要重新量測
        let nanWidth = UsagePanelGeometry.Layout(
            columns: 4, panelScale: 1.15, panelWidth: .nan, originX: 0, originY: 0
        )
        let nanScale = UsagePanelGeometry.Layout(
            columns: 4, panelScale: .nan, panelWidth: 1481.2, originX: 0, originY: 0
        )
        XCTAssertTrue(UsagePanelGeometry.needsRemeasure(previous: base, next: nanWidth))
        XCTAssertTrue(UsagePanelGeometry.needsRemeasure(previous: base, next: nanScale))
    }

    // MARK: - 2. UsageMasonryLayout.columnCount 0.5pt 容差

    func testColumnCountHalfPointToleranceAtScale115() {
        let s: CGFloat = 1.15
        let cardW = UsageFullPage.cardWidth * s
        let gap = UsageFullPage.gap * s
        let exactFourColGridWidth = (UsageFullPage.cardWidth * 4 + UsageFullPage.gap * 3) * s

        // 確認浮點誤差確實會讓原始無容差公式 < 4.0（s = 1.15 時約 3.9999999999999996）
        XCTAssertLessThan((exactFourColGridWidth + gap) / (cardW + gap), 4.0)
        // 加 0.5pt 容差後必須穩穩回 4
        XCTAssertEqual(UsageFullPage.columnCount(width: exactFourColGridWidth, cardWidth: cardW, gap: gap), 4)

        // case (d) 的縮放倍率（1408 / 1288）下 4 欄淨寬度也必須回 4
        let sD: CGFloat = 1408.0 / 1288.0
        let cardWD = UsageFullPage.cardWidth * sD
        let gapD = UsageFullPage.gap * sD
        let gridWidthD = (UsageFullPage.cardWidth * 4 + UsageFullPage.gap * 3) * sD
        XCTAssertEqual(UsageFullPage.columnCount(width: gridWidthD, cardWidth: cardWD, gap: gapD), 4)

        // 差 0.4pt 在容差內仍為 4；差 1.0pt 真正不足 4 欄應回 3
        XCTAssertEqual(UsageFullPage.columnCount(width: exactFourColGridWidth - 0.4, cardWidth: cardW, gap: gap), 4)
        XCTAssertEqual(UsageFullPage.columnCount(width: exactFourColGridWidth - 1.0, cardWidth: cardW, gap: gap), 3)

        // 下限 1、上限 4
        XCTAssertEqual(UsageFullPage.columnCount(width: 0, cardWidth: cardW, gap: gap), 1)
        XCTAssertEqual(UsageFullPage.columnCount(width: -50, cardWidth: cardW, gap: gap), 1)
        XCTAssertEqual(UsageFullPage.columnCount(width: 5000, cardWidth: cardW, gap: gap), 4)
    }

    // MARK: - 3. UsageCardOrder 順序讀寫（含損壞與保留隱藏 key）

    func testCardOrderReadRulesAndCorruptDataHandling() {
        let current = ["pool:cc", "pool:gemini", "pool:codex", "extra:DeepSeek", "extra:Qwen"]

        // 已存且存在的照存的順序；新卡排最後維持預設順序；存了但不存在的忽略
        let saved = ["extra:Gone", "extra:Qwen", "pool:codex", "pool:missing", "pool:cc"]
        XCTAssertEqual(
            UsageCardOrder.orderedKeys(currentKeys: current, savedOrder: saved),
            ["extra:Qwen", "pool:codex", "pool:cc", "pool:gemini", "extra:DeepSeek"]
        )

        // 空的已存順序 → 維持預設
        XCTAssertEqual(UsageCardOrder.orderedKeys(currentKeys: current, savedOrder: []), current)

        // 內容不是字串陣列 → 視同沒存
        let defaults = makeIsolatedDefaults()
        defaults.set("not-an-array", forKey: UsageCardOrder.defaultsKey)
        XCTAssertEqual(UsageCardOrder.loadSavedOrder(from: defaults), [])

        defaults.set(12345, forKey: UsageCardOrder.defaultsKey)
        XCTAssertEqual(UsageCardOrder.loadSavedOrder(from: defaults), [])

        defaults.set(["key": "pool:cc"], forKey: UsageCardOrder.defaultsKey)
        XCTAssertEqual(UsageCardOrder.loadSavedOrder(from: defaults), [])

        defaults.set(["pool:cc", 99, "extra:Qwen"] as [Any], forKey: UsageCardOrder.defaultsKey)
        XCTAssertEqual(UsageCardOrder.loadSavedOrder(from: defaults), [])

        // 合法字串陣列（含重複則去重）
        defaults.set(["extra:Qwen", "pool:cc", "extra:Qwen"], forKey: UsageCardOrder.defaultsKey)
        XCTAssertEqual(UsageCardOrder.loadSavedOrder(from: defaults), ["extra:Qwen", "pool:cc"])
    }

    func testCardOrderWritePreservesHiddenKeysAndAppendsNewKeys() {
        // 隱藏卡在中間與尾端：只重排可見卡佔的位置，隱藏卡原位不動
        let saved = ["pool:cc", "extra:Hidden1", "pool:gemini", "pool:codex", "extra:Hidden2"]
        let merged = UsageCardOrder.mergeOrderForSave(
            savedOrder: saved,
            newVisibleOrder: ["pool:codex", "pool:cc", "pool:gemini"]
        )
        XCTAssertEqual(merged, ["pool:codex", "extra:Hidden1", "pool:cc", "pool:gemini", "extra:Hidden2"])

        // 之後隱藏卡回來，順序仍在原本的位置
        let restored = UsageCardOrder.orderedKeys(
            currentKeys: ["pool:cc", "pool:gemini", "pool:codex", "extra:Hidden1", "extra:Hidden2"],
            savedOrder: merged
        )
        XCTAssertEqual(restored, ["pool:codex", "extra:Hidden1", "pool:cc", "pool:gemini", "extra:Hidden2"])

        // 有新卡出現且被拖到最前面：新卡先補最後獲得槽位，再重排全部可見槽位，隱藏卡依然在原索引
        let withNew = UsageCardOrder.mergeOrderForSave(
            savedOrder: ["pool:cc", "extra:Hidden1", "pool:gemini"],
            newVisibleOrder: ["extra:Qwen", "pool:cc", "pool:gemini"]
        )
        XCTAssertEqual(withNew, ["extra:Qwen", "extra:Hidden1", "pool:cc", "pool:gemini"])
    }

    func testCardOrderStorePersistsAcrossReloadsAndResetsWhenCleared() {
        let defaults = makeIsolatedDefaults()
        let store1 = UsageCardOrderStore(defaults: defaults)
        let visible = ["pool:cc", "pool:gemini", "extra:DeepSeek", "extra:Qwen"]

        // 移到自己 → 不動、不存
        XCTAssertFalse(store1.moveCard(from: "pool:cc", to: "pool:cc", visibleKeys: visible))
        XCTAssertNil(defaults.object(forKey: UsageCardOrder.defaultsKey))

        // 把 extra:Qwen 移到 pool:cc 原位
        XCTAssertTrue(store1.moveCard(from: "extra:Qwen", to: "pool:cc", visibleKeys: visible))
        XCTAssertEqual(
            defaults.stringArray(forKey: UsageCardOrder.defaultsKey),
            ["extra:Qwen", "pool:cc", "pool:gemini", "extra:DeepSeek"]
        )

        // 模擬重開 App：新建 store 讀同一個 suite，順序保留
        let store2 = UsageCardOrderStore(defaults: defaults)
        XCTAssertEqual(
            store2.orderedKeys(for: visible),
            ["extra:Qwen", "pool:cc", "pool:gemini", "extra:DeepSeek"]
        )

        // 清掉 usageCardOrder 後 reload 回預設順序
        defaults.removeObject(forKey: UsageCardOrder.defaultsKey)
        store2.reload()
        XCTAssertEqual(store2.orderedKeys(for: visible), visible)
    }

    // MARK: - 4. 落點計算與「拿掉放到目標位置」

    func testMoveCardRemoveAndInsertAtTargetOriginalIndex() {
        let order = ["pool:cc", "pool:gemini", "pool:codex", "extra:Qwen"]

        // [1,2,3,4] 拖 1 到 3 之後 → 2,3,1,4
        XCTAssertEqual(
            UsageCardOrder.move(key: "pool:cc", relativeTo: "pool:codex", after: true, in: order),
            ["pool:gemini", "pool:codex", "pool:cc", "extra:Qwen"]
        )

        // [1,2,3,4] 拖 1 到 3 之前 → 2,1,3,4
        XCTAssertEqual(
            UsageCardOrder.move(key: "pool:cc", relativeTo: "pool:codex", after: false, in: order),
            ["pool:gemini", "pool:cc", "pool:codex", "extra:Qwen"]
        )

        // [1,2,3,4] 拖 3 到 1 之前 → 3,1,2,4
        XCTAssertEqual(
            UsageCardOrder.move(key: "pool:codex", relativeTo: "pool:cc", after: false, in: order),
            ["pool:codex", "pool:cc", "pool:gemini", "extra:Qwen"]
        )

        // [1,2,3,4] 拖 1 到 2 之後（相鄰）→ 2,1,3,4
        XCTAssertEqual(
            UsageCardOrder.move(key: "pool:cc", relativeTo: "pool:gemini", after: true, in: order),
            ["pool:gemini", "pool:cc", "pool:codex", "extra:Qwen"]
        )

        // 拖到自己前後 → 不動
        XCTAssertEqual(UsageCardOrder.move(key: "pool:cc", relativeTo: "pool:cc", after: false, in: order), order)
        XCTAssertEqual(UsageCardOrder.move(key: "pool:cc", relativeTo: "pool:cc", after: true, in: order), order)

        // 不存在的 key → 不動
        XCTAssertEqual(UsageCardOrder.move(key: "extra:Missing", relativeTo: "pool:cc", after: false, in: order), order)

        // 落點 .end → 移到最後
        XCTAssertEqual(
            UsageCardOrder.applyDrop(sourceKey: "pool:gemini", target: .end, in: order),
            ["pool:cc", "pool:codex", "extra:Qwen", "pool:gemini"]
        )
    }

    func testDropTargetHitTestingCardGapEdgeBelowAndOutside() {
        // 2 欄瀑布流：左欄一張高卡（0..400），右欄兩張矮卡（0..150、162..312），另含干擾用的內部 sub-frame
        let frames: [String: CGRect] = [
            "pool:cc": CGRect(x: 0, y: 0, width: 300, height: 400),
            "pool:gemini": CGRect(x: 312, y: 0, width: 300, height: 150),
            "extra:Qwen": CGRect(x: 312, y: 162, width: 300, height: 150),
            "codex:paid": CGRect(x: 0, y: 0, width: 300, height: 100),
            "codex:free-row:1": CGRect(x: 312, y: 10, width: 200, height: 20),
        ]
        let visible = ["pool:cc", "pool:gemini", "extra:Qwen"]
        let gridSize = CGSize(width: 620, height: 400)

        // 1) 在卡內 → 依左半／右半回 .before／.after（不會誤中內部 sub-frame）
        XCTAssertEqual(
            UsageCardOrder.dropTarget(at: CGPoint(x: 100, y: 50), gridSize: gridSize, cardFrames: frames, visibleOrder: visible),
            .before("pool:cc")
        )
        XCTAssertEqual(
            UsageCardOrder.dropTarget(at: CGPoint(x: 150, y: 50), gridSize: gridSize, cardFrames: frames, visibleOrder: visible),
            .after("pool:cc")
        )
        XCTAssertEqual(
            UsageCardOrder.dropTarget(at: CGPoint(x: 400, y: 20), gridSize: gridSize, cardFrames: frames, visibleOrder: visible),
            .before("pool:gemini")
        )
        XCTAssertEqual(
            UsageCardOrder.dropTarget(at: CGPoint(x: 500, y: 200), gridSize: gridSize, cardFrames: frames, visibleOrder: visible),
            .after("extra:Qwen")
        )

        // 2) 在兩欄縫隙（x = 304，離 pool:cc 只有 4pt、在 pool:cc 右側 → .after）
        XCTAssertEqual(
            UsageCardOrder.dropTarget(at: CGPoint(x: 304, y: 50), gridSize: gridSize, cardFrames: frames, visibleOrder: visible),
            .after("pool:cc")
        )
        // 靠右邊縫隙（x = 309，離 pool:gemini 只有 3pt、在 pool:gemini 左側 → .before）
        XCTAssertEqual(
            UsageCardOrder.dropTarget(at: CGPoint(x: 309, y: 50), gridSize: gridSize, cardFrames: frames, visibleOrder: visible),
            .before("pool:gemini")
        )
        // 右欄兩卡垂直縫隙（y = 158，離 extra:Qwen 4pt、x=450 在左半 → .before）
        XCTAssertEqual(
            UsageCardOrder.dropTarget(at: CGPoint(x: 450, y: 158), gridSize: gridSize, cardFrames: frames, visibleOrder: visible),
            .before("extra:Qwen")
        )
        // 格子右緣內空白（x = 618, y = 200）→ 最近卡 extra:Qwen 右側 .after
        XCTAssertEqual(
            UsageCardOrder.dropTarget(at: CGPoint(x: 618, y: 200), gridSize: gridSize, cardFrames: frames, visibleOrder: visible),
            .after("extra:Qwen")
        )

        // 3) 在所有卡下方（y > 400 且在允許區內）→ .end
        XCTAssertEqual(
            UsageCardOrder.dropTarget(at: CGPoint(x: 200, y: 412), gridSize: gridSize, cardFrames: frames, visibleOrder: visible, bottomMargin: 20),
            .end
        )
        // 若 gridSize 本身就比所有卡高（例如 460），在 430 處也是 .end
        XCTAssertEqual(
            UsageCardOrder.dropTarget(at: CGPoint(x: 200, y: 430), gridSize: CGSize(width: 620, height: 460), cardFrames: frames, visibleOrder: visible),
            .end
        )

        // 4) 在格子外（左、右、上、超過下界）→ nil（取消）
        XCTAssertNil(UsageCardOrder.dropTarget(at: CGPoint(x: -5, y: 100), gridSize: gridSize, cardFrames: frames, visibleOrder: visible))
        XCTAssertNil(UsageCardOrder.dropTarget(at: CGPoint(x: 625, y: 100), gridSize: gridSize, cardFrames: frames, visibleOrder: visible))
        XCTAssertNil(UsageCardOrder.dropTarget(at: CGPoint(x: 100, y: -1), gridSize: gridSize, cardFrames: frames, visibleOrder: visible))
        XCTAssertNil(UsageCardOrder.dropTarget(at: CGPoint(x: 100, y: 425), gridSize: gridSize, cardFrames: frames, visibleOrder: visible, bottomMargin: 20))
    }

    // MARK: - 5. 拖曳取消狀態機（Esc／被拖卡消失／格子外放開）

    func testDragStateCancellationPaths() {
        let frames: [String: CGRect] = [
            "pool:cc": CGRect(x: 0, y: 0, width: 300, height: 150),
            "extra:Qwen": CGRect(x: 312, y: 0, width: 300, height: 150),
        ]
        let visible = ["pool:cc", "extra:Qwen"]
        let grid = CGSize(width: 612, height: 150)

        let drag = UsageCardDragState()

        // Esc 取消後，同一手勢後續 onChanged 與 onEnded 都不得再重啟或提交
        drag.updateDrag(key: "pool:cc", startLocation: CGPoint(x: 20, y: 20), location: CGPoint(x: 350, y: 40), gridSize: grid, cardFrames: frames, visibleKeys: visible, bottomMargin: 18)
        XCTAssertTrue(drag.isDragging)
        XCTAssertEqual(drag.dropTarget, .before("extra:Qwen"))

        drag.cancelCurrentDrag()
        XCTAssertFalse(drag.isDragging)
        XCTAssertNil(drag.dropTarget)

        drag.updateDrag(key: "pool:cc", startLocation: CGPoint(x: 20, y: 20), location: CGPoint(x: 360, y: 40), gridSize: grid, cardFrames: frames, visibleKeys: visible, bottomMargin: 18)
        XCTAssertFalse(drag.isDragging)
        XCTAssertNil(drag.finishDrag(key: "pool:cc", location: CGPoint(x: 360, y: 40), gridSize: grid, cardFrames: frames, visibleKeys: visible, bottomMargin: 18))

        // 下一次新手勢（不同起點）可正常拖曳並提交
        drag.updateDrag(key: "pool:cc", startLocation: CGPoint(x: 30, y: 30), location: CGPoint(x: 380, y: 50), gridSize: grid, cardFrames: frames, visibleKeys: visible, bottomMargin: 18)
        XCTAssertEqual(drag.activeKey, "pool:cc")
        let commit = drag.finishDrag(key: "pool:cc", location: CGPoint(x: 380, y: 50), gridSize: grid, cardFrames: frames, visibleKeys: visible, bottomMargin: 18)
        XCTAssertEqual(commit, UsageCardDragState.Commit(sourceKey: "pool:cc", target: .before("extra:Qwen")))

        // 拖曳中卡片因刷新消失 → 自動取消不提交
        drag.updateDrag(key: "extra:Qwen", startLocation: CGPoint(x: 330, y: 20), location: CGPoint(x: 100, y: 40), gridSize: grid, cardFrames: frames, visibleKeys: visible, bottomMargin: 18)
        XCTAssertEqual(drag.activeKey, "extra:Qwen")
        drag.handleVisibleKeysChanged(["pool:cc"])
        XCTAssertFalse(drag.isDragging)
        XCTAssertNil(drag.finishDrag(key: "extra:Qwen", location: CGPoint(x: 100, y: 40), gridSize: grid, cardFrames: frames, visibleKeys: ["pool:cc"], bottomMargin: 18))

        // 放開在格子外 → 取消
        drag.updateDrag(key: "pool:cc", startLocation: CGPoint(x: 25, y: 25), location: CGPoint(x: -40, y: 25), gridSize: grid, cardFrames: frames, visibleKeys: visible, bottomMargin: 18)
        XCTAssertNil(drag.dropTarget)
        XCTAssertNil(drag.finishDrag(key: "pool:cc", location: CGPoint(x: -40, y: 25), gridSize: grid, cardFrames: frames, visibleKeys: visible, bottomMargin: 18))
    }

    // MARK: - 6. 測試旗標解析、隔離、dump 時機守衛與共用移動入口

    func testR2TestFlagsParsingAndIsolation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("f12-r2-flags-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dumpPath = root.appendingPathComponent("dump.json").path

        // 正式實例（無 --state-dir）：全部測試旗標一律忽略
        let formal = UsagePanelDumpConfig.from(arguments: [
            "codenv",
            "--usage-panel-open",
            "--usage-panel-dump", dumpPath,
            "--usage-panel-parent-size", "1512x982",
            "--usage-panel-screen", "1432x945+80",
            "--usage-panel-ui-scale", "1.15",
            "--usage-panel-move", "extra:Qwen:pool:cc",
        ])
        XCTAssertFalse(formal.isTestInstance)
        XCTAssertNil(formal.parentSize)
        XCTAssertNil(formal.screenSpec)
        XCTAssertNil(formal.uiScaleOverride)
        XCTAssertTrue(formal.moves.isEmpty)

        // 測試實例正確解析所有 r2 旗標（含冒號 key 與多組 move）
        let testCfg = UsagePanelDumpConfig.from(arguments: [
            "codenv",
            "--state-dir", root.path,
            "--usage-panel-open",
            "--usage-panel-dump", dumpPath,
            "--usage-panel-parent-size", "900x700",
            "--usage-panel-screen", "1432x945+80",
            "--usage-panel-ui-scale", "1.0",
            "--usage-panel-move", "extra:Qwen:pool:cc,extra:Gemini 免費 API:extra:DeepSeek,pool:codex:pool:gemini",
        ])
        XCTAssertTrue(testCfg.isTestInstance)
        XCTAssertEqual(testCfg.parentSize, CGSize(width: 900, height: 700))
        XCTAssertEqual(testCfg.screenSpec, UsagePanelScreenSpec(width: 1432, height: 945, leftInset: 80))
        XCTAssertEqual(testCfg.screenSpec?.visibleFrame(), CGRect(x: 80, y: 0, width: 1432, height: 945))
        XCTAssertEqual(testCfg.uiScaleOverride, 1.0)
        XCTAssertEqual(testCfg.moves, [
            UsagePanelMoveSpec(sourceKey: "extra:Qwen", targetKey: "pool:cc"),
            UsagePanelMoveSpec(sourceKey: "extra:Gemini 免費 API", targetKey: "extra:DeepSeek"),
            UsagePanelMoveSpec(sourceKey: "pool:codex", targetKey: "pool:gemini"),
        ])

        // 省略 +左缺 時 leftInset = 0
        XCTAssertEqual(
            UsagePanelDumpConfig.parseScreenSpec("1280x800"),
            UsagePanelScreenSpec(width: 1280, height: 800, leftInset: 0)
        )

        // 非法旗標值安全忽略
        XCTAssertNil(UsagePanelDumpConfig.parseSize("0x900"))
        XCTAssertNil(UsagePanelDumpConfig.parseSize("bad"))
        XCTAssertNil(UsagePanelDumpConfig.parseScreenSpec("1432x945+-10"))
        XCTAssertNil(UsagePanelDumpConfig.parseUIScale("0"))
        XCTAssertNil(UsagePanelDumpConfig.parseUIScale("NaN"))
        XCTAssertTrue(UsagePanelDumpConfig.parseMoveSpecs("bad,pool::extra:Qwen,pool:cc:extra:").isEmpty)
    }

    func testDumpReadinessGateRefusesUnmeasuredLayoutAndPendingMoves() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("f12-r2-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dumpPath = root.appendingPathComponent("dump.json").path
        let cfg = UsagePanelDumpConfig.from(arguments: [
            "codenv", "--state-dir", root.path, "--usage-panel-dump", dumpPath
        ])
        let geo = UsageSheet.GeometrySnapshot(
            columns: 4, panelScale: 1.15, panelWidth: 1481.2, originX: 15.4, originY: 100,
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 945)
        )

        // 版面尚未量測（hasMeasuredLayout = false 或 gridSize = .zero）→ 絕不寫 dump
        XCTAssertFalse(UsageSheet.isDumpReady(
            config: cfg, panelVisible: true, extraLoaded: true, extraRefreshInFlight: false,
            geometry: geo, hasMeasuredLayout: false, measuredGridSize: CGSize(width: 1421.4, height: 400),
            pendingMovesCount: 0, pendingMovesCompleted: true
        ))
        XCTAssertFalse(UsageSheet.isDumpReady(
            config: cfg, panelVisible: true, extraLoaded: true, extraRefreshInFlight: false,
            geometry: geo, hasMeasuredLayout: true, measuredGridSize: .zero,
            pendingMovesCount: 0, pendingMovesCompleted: true
        ))
        // geometry 尚未就緒 → 不寫
        XCTAssertFalse(UsageSheet.isDumpReady(
            config: cfg, panelVisible: true, extraLoaded: true, extraRefreshInFlight: false,
            geometry: nil, hasMeasuredLayout: true, measuredGridSize: CGSize(width: 1421.4, height: 400),
            pendingMovesCount: 0, pendingMovesCompleted: true
        ))
        // 尚有待執行的 --usage-panel-move → 不先寫舊順序
        XCTAssertFalse(UsageSheet.isDumpReady(
            config: cfg, panelVisible: true, extraLoaded: true, extraRefreshInFlight: false,
            geometry: geo, hasMeasuredLayout: true, measuredGridSize: CGSize(width: 1421.4, height: 400),
            pendingMovesCount: 1, pendingMovesCompleted: false
        ))
        // 全部就緒 → 允許寫出
        XCTAssertTrue(UsageSheet.isDumpReady(
            config: cfg, panelVisible: true, extraLoaded: true, extraRefreshInFlight: false,
            geometry: geo, hasMeasuredLayout: true, measuredGridSize: CGSize(width: 1421.4, height: 400),
            pendingMovesCount: 1, pendingMovesCompleted: true
        ))
    }

    func testSharedMoveEntryUpdatesDumpPayloadAndSinglePoolModeIgnoresOrder() {
        let defaults = makeIsolatedDefaults()
        let orderStore = UsageCardOrderStore(defaults: defaults)
        let monitor = UsageMonitor.makeForUnitTest()
        monitor.buckets = [UsageBucket(label: "5 小時", used: 20, resets: "明天 10:00")]
        monitor.agyBuckets = [UsageBucket(label: "Gemini 5 小時", used: 10, resets: "明天 11:00")]
        let ds = ExtraKeyPool(name: "DeepSeek", source: "DeepSeek 官方 API", buckets: [], notes: ["餘額 10.00 CNY（儲值 10.00＋贈送 0.00）"])
        let qw = ExtraKeyPool(name: "Qwen", source: "本機帳本", buckets: [], notes: ["已花 1.35／10.00 USD（本機上限，非帳戶餘額）", "3 次呼叫"])
        monitor.setExtraPoolsForTest(remote: [ds], local: [qw])
        monitor.setExtraLoadedAtForTest(Date(timeIntervalSince1970: 1_800_000_000))

        // 呼叫與手勢共用的 UsageSheet.moveCard 入口把 extra:Qwen 移到 pool:cc 位置
        XCTAssertTrue(UsageSheet.moveCard(from: "extra:Qwen", to: "pool:cc", monitor: monitor, orderStore: orderStore))

        let payload = monitor.buildUsagePanelDumpPayload(
            panelFrame: CGRect(x: 15.4, y: 100, width: 1481.2, height: 520),
            screenVisibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 945),
            columns: 4,
            panelScale: 1.15,
            savedOrder: orderStore.savedOrder
        )
        XCTAssertEqual(payload["order"] as? [String], ["extra:Qwen", "pool:cc", "pool:gemini", "extra:DeepSeek"])

        // 單卡模式（onlyPool != nil）不受儲存順序影響，且不出額外卡
        let single = UsageFullPage.orderedItems(for: monitor, onlyPool: .gemini, savedOrder: orderStore.savedOrder)
        XCTAssertEqual(single.map(\.key), ["pool:gemini"])
    }
}
