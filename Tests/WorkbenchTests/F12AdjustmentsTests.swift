import Foundation
import AppKit
import XCTest
@testable import Workbench

final class F12AdjustmentsTests: XCTestCase {
    private func makeIsolatedDefaults() -> UserDefaults {
        let suite = "com.local.aiworkbench.test.f12adj.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    // MARK: - 1. 拖曳前／後插入與 --usage-panel-move 掛鉤

    func testDragBeforeAfterAndSingleColumnHitTest() {
        let order = ["pool:cc", "pool:gemini", "pool:codex", "extra:Qwen"]

        // 契約指定四組核心順序與自我不動
        XCTAssertEqual(UsageCardOrder.applyDrop(sourceKey: "pool:cc", target: .after("pool:codex"), in: order),
                       ["pool:gemini", "pool:codex", "pool:cc", "extra:Qwen"])
        XCTAssertEqual(UsageCardOrder.applyDrop(sourceKey: "pool:cc", target: .before("pool:codex"), in: order),
                       ["pool:gemini", "pool:cc", "pool:codex", "extra:Qwen"])
        XCTAssertEqual(UsageCardOrder.applyDrop(sourceKey: "pool:codex", target: .before("pool:cc"), in: order),
                       ["pool:codex", "pool:cc", "pool:gemini", "extra:Qwen"])
        XCTAssertEqual(UsageCardOrder.applyDrop(sourceKey: "pool:cc", target: .after("pool:gemini"), in: order),
                       ["pool:gemini", "pool:cc", "pool:codex", "extra:Qwen"])
        XCTAssertEqual(UsageCardOrder.applyDrop(sourceKey: "pool:cc", target: .before("pool:cc"), in: order), order)
        XCTAssertEqual(UsageCardOrder.applyDrop(sourceKey: "pool:cc", target: .after("pool:cc"), in: order), order)

        // 單欄時以上半／下半決定 before／after
        let singleFrames: [String: CGRect] = [
            "pool:cc": CGRect(x: 0, y: 0, width: 300, height: 120),
            "pool:gemini": CGRect(x: 0, y: 132, width: 300, height: 120),
        ]
        let grid = CGSize(width: 300, height: 252)
        let visible = ["pool:cc", "pool:gemini"]
        XCTAssertEqual(
            UsageCardOrder.dropTarget(at: CGPoint(x: 150, y: 30), gridSize: grid, cardFrames: singleFrames, visibleOrder: visible),
            .before("pool:cc")
        )
        XCTAssertEqual(
            UsageCardOrder.dropTarget(at: CGPoint(x: 150, y: 90), gridSize: grid, cardFrames: singleFrames, visibleOrder: visible),
            .after("pool:cc")
        )
    }

    func testParseMoveSpecsBeforeAfterEndAndSharedMovePersistence() {
        let specs = UsagePanelDumpConfig.parseMoveSpecs(
            "pool:cc:after:pool:codex,extra:Qwen:before:pool:gemini,pool:gemini:end,pool:codex:pool:cc"
        )
        XCTAssertEqual(specs, [
            UsagePanelMoveSpec(sourceKey: "pool:cc", targetKey: "pool:codex", after: true),
            UsagePanelMoveSpec(sourceKey: "extra:Qwen", targetKey: "pool:gemini", after: false),
            UsagePanelMoveSpec(sourceKey: "pool:gemini", targetKey: "", after: true),
            UsagePanelMoveSpec(sourceKey: "pool:codex", targetKey: "pool:cc", after: false),
        ])
        XCTAssertEqual(specs[0].dropTarget, .after("pool:codex"))
        XCTAssertEqual(specs[1].dropTarget, .before("pool:gemini"))
        XCTAssertEqual(specs[2].dropTarget, .end)
        XCTAssertEqual(specs[3].dropTarget, .before("pool:cc"))

        // 經共用 moveCard 寫入並重開（新 store）應保留順序
        let defaults = makeIsolatedDefaults()
        let store1 = UsageCardOrderStore(defaults: defaults)
        let monitor = UsageMonitor.makeForUnitTest()
        monitor.buckets = [UsageBucket(label: "5 小時", used: 20, resets: "明天 01:30")]
        monitor.agyBuckets = [UsageBucket(label: "Gemini 5 小時", used: 10, resets: "明天 02:00")]
        monitor.codexBuckets = [UsageBucket(label: "5 小時", used: 30, resets: "明天 03:00")]
        let qw = ExtraKeyPool(name: "Qwen", source: "本機帳本", buckets: [], notes: ["已花 1.93／10.00 USD（本機上限，非帳戶餘額）"])
        monitor.setExtraPoolsForTest(remote: [], local: [qw])

        XCTAssertTrue(UsageSheet.moveCard(sourceKey: "pool:cc", target: .after("pool:codex"), monitor: monitor, orderStore: store1))
        let store2 = UsageCardOrderStore(defaults: defaults)
        XCTAssertEqual(
            store2.orderedKeys(for: ["pool:cc", "pool:gemini", "pool:codex", "extra:Qwen"]),
            ["pool:gemini", "pool:codex", "pool:cc", "extra:Qwen"]
        )
    }

    // MARK: - 2. 紫色語意分段與 dump purpleFields

    func testPurpleColorDynamicHexAndNoteStyling() {
        let lightHex = UsageHighlightColor.hexString(for: .aqua)
        let darkHex = UsageHighlightColor.hexString(for: .darkAqua)
        XCTAssertEqual(lightHex, "#6D28D9")
        XCTAssertEqual(darkHex, "#C4B5FD")
        XCTAssertNotEqual(lightHex, darkHex)

        // DeepSeek：餘額紫、括號說明灰
        XCTAssertEqual(
            UsageNoteStyling.segments(for: "餘額 9.53 USD（儲值 9.53＋贈送 0.00）"),
            [
                StyledNoteSegment(text: "餘額 9.53 USD", purpleField: .balance),
                StyledNoteSegment(text: "（儲值 9.53＋贈送 0.00）", purpleField: nil),
            ]
        )
        // Qwen：已花上限紫、括號說明灰
        XCTAssertEqual(
            UsageNoteStyling.segments(for: "已花 1.93／10.00 USD（本機上限，非帳戶餘額）"),
            [
                StyledNoteSegment(text: "已花 1.93／10.00 USD", purpleField: .spentLimit),
                StyledNoteSegment(text: "（本機上限，非帳戶餘額）", purpleField: nil),
            ]
        )
        // Kaggle：剩餘額度紫＋下次重置紫
        XCTAssertEqual(
            UsageNoteStyling.segments(for: "每週 GPU 剩 30.00／30.00 小時，下次重置 11/28 08:00"),
            [
                StyledNoteSegment(text: "每週 GPU 剩 30.00／30.00 小時", purpleField: .remainingQuota),
                StyledNoteSegment(text: "，", purpleField: nil),
                StyledNoteSegment(text: "下次重置 11/28 08:00", purpleField: .resetTime),
            ]
        )
        // Copilot：剩餘次數紫（含「次額度」與「次」兩種格式）
        XCTAssertEqual(
            UsageNoteStyling.segments(for: "剩 132／200 次額度"),
            [StyledNoteSegment(text: "剩 132／200 次額度", purpleField: .remainingQuota)]
        )
        XCTAssertEqual(
            UsageNoteStyling.segments(for: "剩 194／200 次"),
            [StyledNoteSegment(text: "剩 194／200 次", purpleField: .remainingQuota)]
        )
        // AttributedString 實際保留分段文字
        let dsAttr = UsageNoteStyling.attributedText(for: "餘額 9.53 USD（儲值 9.53＋贈送 0.00）")
        XCTAssertEqual(String(dsAttr.characters), "餘額 9.53 USD（儲值 9.53＋贈送 0.00）")
        XCTAssertEqual(dsAttr.runs.count, 2)
        // 說明灰字不得被標紫
        for gray in ["今天呼叫 5 次", "本機計數", "官方即時", "來源：Mac", "1／3 個帳號", "尚無本機呼叫紀錄"] {
            let segs = UsageNoteStyling.segments(for: gray)
            XCTAssertTrue(segs.allSatisfy { $0.purpleField == nil }, "灰字不應變紫：\(gray)")
        }

        // dump 的 purpleFields 只含語意欄位，不含純灰字卡
        let monitor = UsageMonitor.makeForUnitTest()
        monitor.buckets = [UsageBucket(label: "5 小時", used: 10, resets: "明天 01:30")]
        monitor.copilotNote = "剩 132／200 次額度"
        monitor.copilotBuckets = [UsageBucket(label: "每月額度", used: 34, resets: "12/1 08:00")]
        let ds = ExtraKeyPool(name: "DeepSeek", source: "DeepSeek 官方 API", buckets: [], notes: ["餘額 9.53 USD（儲值 9.53＋贈送 0.00）"])
        let qw = ExtraKeyPool(name: "Qwen", source: "本機帳本", buckets: [], notes: ["已花 1.93／10.00 USD（本機上限，非帳戶餘額）"])
        let nv = ExtraKeyPool(name: "NVIDIA", source: "本機計數", buckets: [], notes: ["今天呼叫 5 次"])
        monitor.setExtraPoolsForTest(remote: [ds, nv], local: [qw])

        let defaults = makeIsolatedDefaults()
        let payload = monitor.buildUsagePanelDumpPayload(
            panelFrame: CGRect(x: 0, y: 0, width: 900, height: 500),
            screenVisibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 945),
            columns: 3,
            panelScale: 1.0,
            defaults: defaults
        )
        let purpleFields = payload["purpleFields"] as? [[String: Any]] ?? []
        let pairs = purpleFields.compactMap { entry -> String? in
            guard let k = entry["cardKey"] as? String, let f = entry["field"] as? String else { return nil }
            XCTAssertEqual(entry["lightHex"] as? String, lightHex)
            XCTAssertEqual(entry["darkHex"] as? String, darkHex)
            return "\(k)|\(f)"
        }
        XCTAssertTrue(pairs.contains("pool:cc|resetTime"))
        XCTAssertTrue(pairs.contains("pool:copilot|resetTime"))
        XCTAssertTrue(pairs.contains("pool:copilot|remainingQuota"))
        XCTAssertTrue(pairs.contains("extra:DeepSeek|balance"))
        XCTAssertTrue(pairs.contains("extra:Qwen|spentLimit"))
        XCTAssertFalse(pairs.contains(where: { $0.hasPrefix("extra:NVIDIA|") }))
    }

    // MARK: - 3. agy 帳號可收合＋無數字不顯示＋合計維持 N／3

    func testAgyAccountCollapseAndHideEmptyAccounts() {
        let defaults = makeIsolatedDefaults()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let accounts: [AgySwapAccountDisplay] = [
            AgySwapAccountDisplay(
                name: "alpha",
                isActive: true,
                state: .live,
                readAt: now,
                ageText: "剛剛",
                buckets: [
                    UsageBucket(label: "Gemini 5 小時", used: 20, resets: "明天 01:00"),
                    UsageBucket(label: "Gemini 每週", used: 10, resets: "11/28 08:00"),
                ],
                source: "mac",
                containerStatus: .skipped
            ),
            AgySwapAccountDisplay(
                name: "beta",
                isActive: false,
                state: .never,
                readAt: nil,
                ageText: "還沒讀過",
                buckets: [],
                source: nil,
                containerStatus: .down
            ),
            AgySwapAccountDisplay(
                name: "gamma",
                isActive: false,
                state: .cached,
                readAt: now.addingTimeInterval(-300),
                ageText: "5 分鐘前",
                buckets: [],
                source: "container:test-agy3",
                containerStatus: .down
            ),
        ]

        // 無數字帳號不顯示
        XCTAssertEqual(AgyAccountSectionPresentation.displayedAccounts(accounts).map(\.name), ["alpha"])

        // 預設收合
        XCTAssertTrue(AgyAccountSectionPresentation.isCollapsed(accountKey: "alpha", defaults: defaults))
        var sections = AgyAccountSectionPresentation.dumpSections(accounts: accounts, defaults: defaults)
        XCTAssertEqual(sections.count, 3)
        XCTAssertEqual(sections[0]["displayed"] as? Bool, true)
        XCTAssertEqual(sections[0]["collapsed"] as? Bool, true)
        XCTAssertEqual(sections[0]["visibleBucketLabels"] as? [String], [])
        XCTAssertEqual(sections[1]["displayed"] as? Bool, false)
        XCTAssertEqual(sections[2]["displayed"] as? Bool, false)

        // 展開並持久化
        AgyAccountSectionPresentation.setCollapsed(false, accountKey: "alpha", defaults: defaults)
        XCTAssertFalse(AgyAccountSectionPresentation.isCollapsed(accountKey: "alpha", defaults: defaults))
        sections = AgyAccountSectionPresentation.dumpSections(accounts: accounts, defaults: defaults)
        XCTAssertEqual(sections[0]["collapsed"] as? Bool, false)
        XCTAssertEqual(sections[0]["visibleBucketLabels"] as? [String], ["Gemini 5 小時", "Gemini 每週"])

        // 合計維持 3 帳號（1／3 個帳號）
        let summary = AgyContainerUsage.computeTotalSummary(accounts: accounts)
        XCTAssertEqual(summary?.accountCount, 3)
        XCTAssertEqual(summary?.title, "三帳號合計")
        XCTAssertEqual(summary?.rows.first?.covered, 1)
        XCTAssertEqual(summary?.rows.first?.total, 3)
        XCTAssertEqual(summary?.rows.first?.footnoteText(now: now), "1／3 個帳號")

        // dump 不得把「還沒讀過」當可見帳號文字
        let monitor = UsageMonitor.makeForUnitTest()
        monitor.agySwapMode = true
        monitor.agySwapAccounts = accounts
        let panelDump = monitor.buildUsagePanelDumpPayload(
            panelFrame: nil, screenVisibleFrame: nil, columns: 2, panelScale: 1.0, defaults: defaults
        )
        let cards = panelDump["cards"] as? [[String: Any]] ?? []
        let agyCard = cards.first { ($0["key"] as? String) == "pool:gemini" }
        let lines = agyCard?["lines"] as? [String] ?? []
        XCTAssertFalse(lines.contains("還沒讀過"))
        XCTAssertFalse(lines.contains("beta"))
        let totalDump = panelDump["agyTotalSummary"] as? [String: Any]
        XCTAssertEqual(totalDump?["accountCount"] as? Int, 3)

        // 收合狀態：dump 的 cards.lines 應只出現單列摘要，且不出現 resetTime 在 purpleFields
        AgyAccountSectionPresentation.setCollapsed(true, accountKey: "alpha", defaults: defaults)
        let collapsedDump = monitor.buildUsagePanelDumpPayload(
            panelFrame: nil, screenVisibleFrame: nil, columns: 2, panelScale: 1.0, defaults: defaults
        )
        let collapsedCards = collapsedDump["cards"] as? [[String: Any]] ?? []
        let collapsedAgyLines = collapsedCards.first { ($0["key"] as? String) == "pool:gemini" }?["lines"] as? [String] ?? []
        XCTAssertTrue(collapsedAgyLines.contains("alpha 使用中 5 小時 80% 每週 90%"))
        XCTAssertFalse(collapsedAgyLines.contains("明天 01:00 重置"))
        let collapsedPurple = collapsedDump["purpleFields"] as? [[String: Any]] ?? []
        XCTAssertFalse(collapsedPurple.contains { ($0["cardKey"] as? String) == "pool:gemini" })

        // 無數字帳號補上數字後自動顯示（且維持預設收起），合計變為 2／3 個帳號
        var updatedAccounts = accounts
        updatedAccounts[1] = AgySwapAccountDisplay(
            name: "beta",
            isActive: false,
            state: .cached,
            readAt: now,
            ageText: "剛剛",
            buckets: [UsageBucket(label: "Gemini 5 小時", used: 30, resets: "明天 03:00")],
            source: "container:test-agy2",
            containerStatus: nil
        )
        XCTAssertEqual(AgyAccountSectionPresentation.displayedAccounts(updatedAccounts).map(\.name), ["alpha", "beta"])
        XCTAssertTrue(AgyAccountSectionPresentation.isCollapsed(accountKey: "beta", defaults: defaults))
        let updatedSummary = AgyContainerUsage.computeTotalSummary(accounts: updatedAccounts)
        XCTAssertEqual(updatedSummary?.accountCount, 3)
        XCTAssertEqual(updatedSummary?.rows.first?.covered, 2)
        XCTAssertEqual(updatedSummary?.rows.first?.total, 3)
        XCTAssertEqual(updatedSummary?.rows.first?.footnoteText(now: now), "2／3 個帳號 · 最舊 剛剛")
    }
}
