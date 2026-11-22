import XCTest
import Darwin
@testable import Workbench

/// F12 第 3 輪（規格第 8 節）單元測試：
/// 合計平均與進位、設定檔驗證、容器讀取門檻、節流、寫快取條件、source 相容性、
/// dockerPath 隔離、並行完成時機、與 `--usage-card-dump` 擴充欄位。
/// 全程使用假帳號名（alpha／beta／gamma／delta）與暫存目錄，不碰真實設定或真 docker／agy-swap。
final class AgyContainerTotalTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDir(_ prefix: String = "agy-container-test") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeExecutableScript(in dir: URL, name: String, body: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func bucket(_ label: String, remaining: Int, resetAt: Date? = nil) -> UsageBucket {
        UsageBucket(label: label, used: 100 - remaining, resets: "", resetAt: resetAt)
    }

    private func makeStatus(
        active: String? = "alpha",
        gen: Int = 3,
        switching: Bool = false,
        liveMatches: String? = "alpha",
        recoveryPending: Bool = false,
        accountsError: Bool = false,
        accounts: [AgySwapStatus.Account]
    ) -> AgySwapStatus {
        AgySwapStatus(
            active: active,
            gen: gen,
            switching: switching,
            liveMatches: liveMatches,
            lastSwitch: nil,
            accounts: accounts,
            recoveryPending: recoveryPending,
            accountsError: accountsError
        )
    }

    private func makeAccount(_ name: String, invalid: Bool = false) -> AgySwapStatus.Account {
        AgySwapStatus.Account(name: name, invalid: invalid, exhausted: [:], verifyFailures: 0, verifyFailedAt: nil)
    }

    private func writeContainerMap(_ dict: [String: Any], to stateDir: URL) throws {
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        try data.write(to: stateDir.appendingPathComponent("agy-container-map.json"), options: .atomic)
    }

    private func usageTable(g5: Int, gw: Int, argon: Int, cw: Int? = nil, c5: Int? = nil) -> String {
        var lines = [
            "Gemini Models\tFive Hour Limit\t\(g5)%\t2026-11-28T10:00:00Z",
            "Gemini Models\tWeekly Limit\t\(gw)%\t2026-11-28T12:00:00Z",
            "Gemini 4 Argon\tWeekly Limit\t\(argon)%\t2026-11-28T14:00:00Z",
        ]
        if let cw {
            lines.append("Claude and GPT models\tWeekly Limit\t\(cw)%\t2026-11-28T16:00:00Z")
        }
        if let c5 {
            lines.append("Claude and GPT models\tFive Hour Limit\t\(c5)%\t2026-11-28T18:00:00Z")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - 1. 合計平均與進位（規格 8.2 / 8.6）

    func testRoundedAveragePercentAwayFromZero() {
        XCTAssertEqual(AgyContainerUsage.roundedAveragePercent([32, 33]), 33, "32.5 必須進位到 33")
        XCTAssertEqual(AgyContainerUsage.roundedAveragePercent([33, 34]), 34, "33.5 必須進位到 34")
        XCTAssertEqual(AgyContainerUsage.roundedAveragePercent([65, 0]), 33, "32.5 必須進位到 33")
        XCTAssertEqual(AgyContainerUsage.roundedAveragePercent([67, 0]), 34, "33.5 必須進位到 34")
        XCTAssertEqual(AgyContainerUsage.roundedAveragePercent([0, 1]), 1, "0.5 必須進位到 1")
        XCTAssertEqual(AgyContainerUsage.roundedAveragePercent([100, 0, 0]), 33)
        XCTAssertEqual(AgyContainerUsage.roundedAveragePercent([100, 100, 0]), 67)
        XCTAssertEqual(AgyContainerUsage.roundedAveragePercent([0, 0, 0]), 0)
        XCTAssertEqual(AgyContainerUsage.roundedAveragePercent([100, 100, 100]), 100)
    }

    func testComputeTotalSummaryCoverageOldestZeroClaudeAndDedup() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let tenMinAgo = now.addingTimeInterval(-600)
        let thirtyMinAgo = now.addingTimeInterval(-1800)

        // 1) 3/3 全即時：固定順序、無附註、Claude 0% 照平均、重複標籤去重
        let fullLive = [
            AgySwapAccountDisplay(
                name: "alpha", isActive: true, state: .live, readAt: now, ageText: "剛剛",
                buckets: [
                    bucket("Claude 5 小時", remaining: 100),
                    bucket("Gemini 5 小時", remaining: 90),
                    bucket("Gemini 5 小時", remaining: 10), // 重複標籤：只取第一個 90
                    bucket("Gemini 每週", remaining: 80),
                    bucket("Argon 每週", remaining: 60),
                    bucket("Claude 每週", remaining: 100),
                ],
                source: "mac", containerStatus: .skipped
            ),
            AgySwapAccountDisplay(
                name: "beta", isActive: false, state: .live, readAt: now, ageText: "剛剛",
                buckets: [
                    bucket("Gemini 5 小時", remaining: 60),
                    bucket("Gemini 每週", remaining: 50),
                    bucket("Argon 每週", remaining: 30),
                    bucket("Claude 每週", remaining: 0), // 0% 照平均
                    bucket("Claude 5 小時", remaining: 0),
                ],
                source: "container:agy2", containerStatus: .fresh
            ),
            AgySwapAccountDisplay(
                name: "gamma", isActive: false, state: .live, readAt: now, ageText: "剛剛",
                buckets: [
                    bucket("Gemini 5 小時", remaining: 30),
                    bucket("Gemini 每週", remaining: 20),
                    bucket("Argon 每週", remaining: 0),
                    bucket("Claude 每週", remaining: 0),
                    bucket("Claude 5 小時", remaining: 0),
                ],
                source: "container:agy3", containerStatus: .fresh
            ),
        ]
        let s3 = try XCTUnwrap(AgyContainerUsage.computeTotalSummary(accounts: fullLive))
        XCTAssertEqual(s3.title, "三帳號合計")
        XCTAssertEqual(s3.accountCount, 3)
        XCTAssertEqual(s3.rows.map(\.label), ["Gemini 5 小時", "Gemini 每週", "Argon 每週", "Claude 每週", "Claude 5 小時"])
        XCTAssertEqual(s3.rows.map(\.displayLabel), ["Gemini 5 小時", "Gemini 每週", "Argon 每週", "Claude／GPT 每週", "Claude／GPT 5 小時"])
        XCTAssertEqual(s3.rows.map(\.percent), [60, 50, 30, 33, 33])
        XCTAssertTrue(s3.rows.allSatisfy { $0.covered == 3 && $0.total == 3 && $0.oldestReadAt == nil })
        XCTAssertTrue(s3.rows.allSatisfy { $0.footnoteText(now: now) == nil })

        // 2) 2/3（1 個 never、1 個 cached 30 分鐘前、1 個 live）→ 標 2/3 與最舊時間
        let twoOfThree = [
            AgySwapAccountDisplay(
                name: "alpha", isActive: true, state: .live, readAt: now, ageText: "剛剛",
                buckets: [bucket("Gemini 每週", remaining: 32)], source: "mac"
            ),
            AgySwapAccountDisplay(
                name: "beta", isActive: false, state: .cached, readAt: thirtyMinAgo, ageText: "30 分鐘前",
                buckets: [bucket("Gemini 每週", remaining: 33)], source: "container:agy2"
            ),
            AgySwapAccountDisplay(
                name: "gamma", isActive: false, state: .never, readAt: nil, ageText: "還沒讀過", buckets: []
            ),
        ]
        let s2 = try XCTUnwrap(AgyContainerUsage.computeTotalSummary(accounts: twoOfThree))
        XCTAssertEqual(s2.title, "三帳號合計")
        XCTAssertEqual(s2.rows.count, 1)
        XCTAssertEqual(s2.rows[0].label, "Gemini 每週")
        XCTAssertEqual(s2.rows[0].percent, 33) // (32+33)/2 = 32.5 -> 33
        XCTAssertEqual(s2.rows[0].covered, 2)
        XCTAssertEqual(s2.rows[0].total, 3)
        XCTAssertEqual(s2.rows[0].oldestReadAt, thirtyMinAgo)
        XCTAssertEqual(s2.rows[0].footnoteText(now: now), "2／3 個帳號 · 最舊 30 分鐘前")

        // 3) 1/3（1 個 cached 10 分鐘前、1 個 invalid 即使有 buckets 也排除、1 個 never）
        let oneOfThree = [
            AgySwapAccountDisplay(
                name: "alpha", isActive: true, state: .cached, readAt: tenMinAgo, ageText: "10 分鐘前",
                buckets: [bucket("Argon 每週", remaining: 88)]
            ),
            AgySwapAccountDisplay(
                name: "beta", isActive: false, state: .invalid, readAt: nil, ageText: "登入失效",
                buckets: [bucket("Argon 每週", remaining: 10)] // 應排除
            ),
            AgySwapAccountDisplay(
                name: "gamma", isActive: false, state: .never, readAt: nil, ageText: "還沒讀過", buckets: []
            ),
        ]
        let s1 = try XCTUnwrap(AgyContainerUsage.computeTotalSummary(accounts: oneOfThree))
        XCTAssertEqual(s1.rows.count, 1)
        XCTAssertEqual(s1.rows[0].percent, 88)
        XCTAssertEqual(s1.rows[0].covered, 1)
        XCTAssertEqual(s1.rows[0].total, 3)
        XCTAssertEqual(s1.rows[0].oldestReadAt, tenMinAgo)
        XCTAssertEqual(s1.rows[0].footnoteText(now: now), "1／3 個帳號 · 最舊 10 分鐘前")

        // 4) 0/3 → 不顯示合計區塊（回傳 nil）
        let zeroOfThree = [
            AgySwapAccountDisplay(name: "alpha", isActive: true, state: .never, readAt: nil, ageText: "還沒讀過", buckets: []),
            AgySwapAccountDisplay(name: "beta", isActive: false, state: .invalid, readAt: nil, ageText: "登入失效", buckets: []),
            AgySwapAccountDisplay(name: "gamma", isActive: false, state: .never, readAt: nil, ageText: "還沒讀過", buckets: []),
        ]
        XCTAssertNil(AgyContainerUsage.computeTotalSummary(accounts: zeroOfThree))

        // 5) 2 帳號與 4 帳號標題格式
        let twoAccounts = [
            AgySwapAccountDisplay(name: "alpha", isActive: true, state: .live, readAt: now, ageText: "剛剛", buckets: [bucket("Gemini 5 小時", remaining: 33)]),
            AgySwapAccountDisplay(name: "beta", isActive: false, state: .live, readAt: now, ageText: "剛剛", buckets: [bucket("Gemini 5 小時", remaining: 34)]),
        ]
        let sTwo = try XCTUnwrap(AgyContainerUsage.computeTotalSummary(accounts: twoAccounts))
        XCTAssertEqual(sTwo.title, "2 帳號合計")
        XCTAssertEqual(sTwo.rows[0].percent, 34) // 33.5 -> 34
        XCTAssertNil(sTwo.rows[0].footnoteText(now: now))

        // 6) 多個快取取最舊一筆 read_at
        let twoCached = [
            AgySwapAccountDisplay(name: "alpha", isActive: true, state: .live, readAt: now, ageText: "剛剛", buckets: [bucket("Gemini 每週", remaining: 90)]),
            AgySwapAccountDisplay(name: "beta", isActive: false, state: .cached, readAt: tenMinAgo, ageText: "10 分鐘前", buckets: [bucket("Gemini 每週", remaining: 60)]),
            AgySwapAccountDisplay(name: "gamma", isActive: false, state: .cached, readAt: thirtyMinAgo, ageText: "30 分鐘前", buckets: [bucket("Gemini 每週", remaining: 30)]),
        ]
        let sOldest = try XCTUnwrap(AgyContainerUsage.computeTotalSummary(accounts: twoCached))
        XCTAssertEqual(sOldest.rows[0].oldestReadAt, thirtyMinAgo)
        XCTAssertEqual(sOldest.rows[0].footnoteText(now: now), "最舊 30 分鐘前")
    }

    // MARK: - 2. 設定檔驗證（規格 8.1）

    func testContainerMapValidationAndLoading() throws {
        let dir = try makeTempDir("map-validation")
        defer { try? FileManager.default.removeItem(at: dir) }

        // 不存在 → 停用
        XCTAssertFalse(AgyContainerMap.load(from: dir.appendingPathComponent("missing.json")).isEnabled)
        XCTAssertFalse(AgyContainerMap.load(from: nil).isEnabled)

        // 空字典 → 停用
        XCTAssertFalse(AgyContainerMap.parse(data: Data("{}".utf8)).isEnabled)

        // 非字典（陣列、字串、數字、壞 JSON）→ 停用
        for bad in ["[]", #"["agy2"]"#, #""agy2""#, "123", "{not-json"] {
            XCTAssertFalse(AgyContainerMap.parse(data: Data(bad.utf8)).isEnabled, "非字典應停用：\(bad)")
        }

        // 容器名正則邊界：^[a-z0-9][a-z0-9_-]{0,31}$
        XCTAssertTrue(AgyContainerMap.isValidContainerName("a"))
        XCTAssertTrue(AgyContainerMap.isValidContainerName("agy2"))
        XCTAssertTrue(AgyContainerMap.isValidContainerName("0_worker-1"))
        XCTAssertTrue(AgyContainerMap.isValidContainerName(String(repeating: "a", count: 32)))
        XCTAssertFalse(AgyContainerMap.isValidContainerName(""))
        XCTAssertFalse(AgyContainerMap.isValidContainerName("-agy2"), "不得以 - 開頭")
        XCTAssertFalse(AgyContainerMap.isValidContainerName("--help"), "不得以 - 開頭")
        XCTAssertFalse(AgyContainerMap.isValidContainerName("_agy2"), "不得以 _ 開頭")
        XCTAssertFalse(AgyContainerMap.isValidContainerName("Agy2"), "不得含大寫")
        XCTAssertFalse(AgyContainerMap.isValidContainerName("agy 2"), "不得含空白")
        XCTAssertFalse(AgyContainerMap.isValidContainerName("agy/2"))
        XCTAssertFalse(AgyContainerMap.isValidContainerName(String(repeating: "a", count: 33)))

        // 合法與非法項目混合：忽略非法，保留合法
        let tooLongAccount = String(repeating: "a", count: 33)
        let mixedJSON = """
        {
          "beta": "agy2",
          "gamma_1": "agy-3",
          "": "agy4",
          "\(tooLongAccount)": "agy4",
          "bad name": "agy4",
          "../evil": "agy5",
          "flag_target": "-flag",
          "upper_target": "AGY2",
          "non_string": 42,
          "empty_container": ""
        }
        """
        let parsed = AgyContainerMap.parse(data: Data(mixedJSON.utf8))
        XCTAssertTrue(parsed.isEnabled)
        XCTAssertEqual(parsed.entries, ["beta": "agy2", "gamma_1": "agy-3"])

        // 全部都是非法項目 → 過濾後為空 → 停用
        let allInvalidJSON = #"{"bad name":"agy2","beta":"-bad","gamma":"UPPER"}"#
        XCTAssertFalse(AgyContainerMap.parse(data: Data(allInvalidJSON.utf8)).isEnabled)
    }

    // MARK: - 3. 目標篩選門檻（現用、live_matches、switching、recoveryPending、離線、dockerPath）

    func testEligibleTargetsPreconditions() {
        let map = AgyContainerMap(entries: ["alpha": "agy1", "beta": "agy2", "gamma": "agy3"])
        let threeAccounts = [makeAccount("alpha"), makeAccount("beta"), makeAccount("gamma")]

        // 正常：排除現用 alpha（即使 alpha 在設定檔內），只回傳 beta、gamma
        let normal = makeStatus(active: "alpha", gen: 3, liveMatches: "alpha", accounts: threeAccounts)
        XCTAssertEqual(
            AgyContainerUsage.eligibleTargets(status: normal, containerMap: map, dockerPath: "/fake/docker", canCallAgy: true),
            [AgyContainerTarget(account: "beta", container: "agy2"), AgyContainerTarget(account: "gamma", container: "agy3")]
        )

        // 失效帳號排除
        let withInvalid = makeStatus(active: "alpha", gen: 3, liveMatches: "alpha", accounts: [
            makeAccount("alpha"), makeAccount("beta", invalid: true), makeAccount("gamma"),
        ])
        XCTAssertEqual(
            AgyContainerUsage.eligibleTargets(status: withInvalid, containerMap: map, dockerPath: "/fake/docker", canCallAgy: true),
            [AgyContainerTarget(account: "gamma", container: "agy3")]
        )

        // live_matches 與 active 不一致 → 整輪不讀
        let mismatch = makeStatus(active: "alpha", gen: 3, liveMatches: "beta", accounts: threeAccounts)
        XCTAssertTrue(AgyContainerUsage.eligibleTargets(status: mismatch, containerMap: map, dockerPath: "/fake/docker", canCallAgy: true).isEmpty)

        // active 或 live_matches 未知（nil）→ 整輪不讀
        let unknownActive = makeStatus(active: nil, gen: 3, liveMatches: nil, accounts: threeAccounts)
        XCTAssertTrue(AgyContainerUsage.eligibleTargets(status: unknownActive, containerMap: map, dockerPath: "/fake/docker", canCallAgy: true).isEmpty)
        let unknownLive = makeStatus(active: "alpha", gen: 3, liveMatches: nil, accounts: threeAccounts)
        XCTAssertTrue(AgyContainerUsage.eligibleTargets(status: unknownLive, containerMap: map, dockerPath: "/fake/docker", canCallAgy: true).isEmpty)

        // switching / recoveryPending / 離線 / 無 dockerPath / 停用設定檔 → 整輪不讀
        let switching = makeStatus(active: "alpha", gen: 3, switching: true, liveMatches: "alpha", accounts: threeAccounts)
        XCTAssertTrue(AgyContainerUsage.eligibleTargets(status: switching, containerMap: map, dockerPath: "/fake/docker", canCallAgy: true).isEmpty)

        let recovery = makeStatus(active: "alpha", gen: 3, liveMatches: "alpha", recoveryPending: true, accounts: threeAccounts)
        XCTAssertTrue(AgyContainerUsage.eligibleTargets(status: recovery, containerMap: map, dockerPath: "/fake/docker", canCallAgy: true).isEmpty)

        XCTAssertTrue(AgyContainerUsage.eligibleTargets(status: normal, containerMap: map, dockerPath: "/fake/docker", canCallAgy: false).isEmpty)
        XCTAssertTrue(AgyContainerUsage.eligibleTargets(status: normal, containerMap: map, dockerPath: nil, canCallAgy: true).isEmpty)
        XCTAssertTrue(AgyContainerUsage.eligibleTargets(status: normal, containerMap: .disabled, dockerPath: "/fake/docker", canCallAgy: true).isEmpty)
    }

    // MARK: - 4. 節流器（成功 10 分鐘、失敗 5 分鐘、重開歸零）

    func testAttemptTrackerSuccessAndFailureTTLAndReset() {
        let tracker = AgyContainerAttemptTracker()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        // 初次允許，進行中再呼叫被擋
        XCTAssertTrue(tracker.beginAttemptIfAllowed(container: "agy2", now: t0, successTTL: 600, failureTTL: 300))
        XCTAssertFalse(tracker.beginAttemptIfAllowed(container: "agy2", now: t0, successTTL: 600, failureTTL: 300))
        tracker.recordAttempt(container: "agy2", succeeded: true, at: t0)

        // 成功後 599 秒內節流，600 秒後放行
        XCTAssertFalse(tracker.beginAttemptIfAllowed(container: "agy2", now: t0.addingTimeInterval(599), successTTL: 600, failureTTL: 300))
        XCTAssertTrue(tracker.beginAttemptIfAllowed(container: "agy2", now: t0.addingTimeInterval(600), successTTL: 600, failureTTL: 300))
        tracker.recordAttempt(container: "agy2", succeeded: false, at: t0.addingTimeInterval(600))

        // 失敗後 299 秒內節流，300 秒後放行
        XCTAssertFalse(tracker.beginAttemptIfAllowed(container: "agy2", now: t0.addingTimeInterval(899), successTTL: 600, failureTTL: 300))
        XCTAssertTrue(tracker.beginAttemptIfAllowed(container: "agy2", now: t0.addingTimeInterval(900), successTTL: 600, failureTTL: 300))
        tracker.recordAttempt(container: "agy2", succeeded: true, at: t0.addingTimeInterval(900))

        // 另一個容器互不干擾
        XCTAssertTrue(tracker.beginAttemptIfAllowed(container: "agy3", now: t0.addingTimeInterval(901), successTTL: 600, failureTTL: 300))
        tracker.recordAttempt(container: "agy3", succeeded: true, at: t0.addingTimeInterval(901))

        // 重開（新實例或 reset）後立刻可讀
        let restarted = AgyContainerAttemptTracker()
        XCTAssertTrue(restarted.beginAttemptIfAllowed(container: "agy2", now: t0.addingTimeInterval(901), successTTL: 600, failureTTL: 300))
    }

    // MARK: - 5. 寫快取條件全分支（規格 8.2 / 8.6）

    func testShouldWriteContainerCacheAllBranches() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let buckets = [bucket("Gemini 每週", remaining: 75)]
        let accounts = [makeAccount("alpha"), makeAccount("beta"), makeAccount("gamma")]
        let goodPost = makeStatus(active: "alpha", gen: 5, liveMatches: "alpha", accounts: accounts)
        let olderCache = AgySwapUsageCacheEntry(account: "beta", readAt: now.addingTimeInterval(-60), pools: [AgySwapCachedPool(name: "Gemini 每週", remainingPercent: 50, resetAt: nil)])
        let newerCache = AgySwapUsageCacheEntry(account: "beta", readAt: now.addingTimeInterval(60), pools: [AgySwapCachedPool(name: "Gemini 每週", remainingPercent: 50, resetAt: nil)])

        // 全通過（無舊快取 / 舊快取較舊 / 舊快取同時間）
        XCTAssertTrue(AgyContainerUsage.shouldWriteContainerCache(
            account: "beta", container: "agy2", fetchResult: .available(buckets),
            preGen: 5, postStatus: goodPost, readAt: now, existingCache: nil
        ))
        XCTAssertTrue(AgyContainerUsage.shouldWriteContainerCache(
            account: "beta", container: "agy2", fetchResult: .available(buckets),
            preGen: 5, postStatus: goodPost, readAt: now, existingCache: olderCache
        ))

        // 空解析 / down / unreadable → 不寫
        XCTAssertFalse(AgyContainerUsage.shouldWriteContainerCache(
            account: "beta", container: "agy2", fetchResult: .available([]),
            preGen: 5, postStatus: goodPost, readAt: now, existingCache: nil
        ))
        XCTAssertFalse(AgyContainerUsage.shouldWriteContainerCache(
            account: "beta", container: "agy2", fetchResult: .down,
            preGen: 5, postStatus: goodPost, readAt: now, existingCache: nil
        ))
        XCTAssertFalse(AgyContainerUsage.shouldWriteContainerCache(
            account: "beta", container: "agy2", fetchResult: .unreadable,
            preGen: 5, postStatus: goodPost, readAt: now, existingCache: nil
        ))

        // gen 變了 → 不寫
        let genChanged = makeStatus(active: "alpha", gen: 6, liveMatches: "alpha", accounts: accounts)
        XCTAssertFalse(AgyContainerUsage.shouldWriteContainerCache(
            account: "beta", container: "agy2", fetchResult: .available(buckets),
            preGen: 5, postStatus: genChanged, readAt: now, existingCache: nil
        ))

        // switching / recoveryPending / accountsError / postStatus nil → 不寫
        XCTAssertFalse(AgyContainerUsage.shouldWriteContainerCache(
            account: "beta", container: "agy2", fetchResult: .available(buckets),
            preGen: 5, postStatus: makeStatus(active: "alpha", gen: 5, switching: true, liveMatches: "alpha", accounts: accounts),
            readAt: now, existingCache: nil
        ))
        XCTAssertFalse(AgyContainerUsage.shouldWriteContainerCache(
            account: "beta", container: "agy2", fetchResult: .available(buckets),
            preGen: 5, postStatus: makeStatus(active: "alpha", gen: 5, liveMatches: "alpha", recoveryPending: true, accounts: accounts),
            readAt: now, existingCache: nil
        ))
        XCTAssertFalse(AgyContainerUsage.shouldWriteContainerCache(
            account: "beta", container: "agy2", fetchResult: .available(buckets),
            preGen: 5, postStatus: makeStatus(active: "alpha", gen: 5, liveMatches: "alpha", accountsError: true, accounts: accounts),
            readAt: now, existingCache: nil
        ))
        XCTAssertFalse(AgyContainerUsage.shouldWriteContainerCache(
            account: "beta", container: "agy2", fetchResult: .available(buckets),
            preGen: 5, postStatus: nil, readAt: now, existingCache: nil
        ))

        // 帳號變成現用（active 或 live_matches）→ 不寫
        XCTAssertFalse(AgyContainerUsage.shouldWriteContainerCache(
            account: "beta", container: "agy2", fetchResult: .available(buckets),
            preGen: 5, postStatus: makeStatus(active: "beta", gen: 5, liveMatches: "alpha", accounts: accounts),
            readAt: now, existingCache: nil
        ))
        XCTAssertFalse(AgyContainerUsage.shouldWriteContainerCache(
            account: "beta", container: "agy2", fetchResult: .available(buckets),
            preGen: 5, postStatus: makeStatus(active: "alpha", gen: 5, liveMatches: "beta", accounts: accounts),
            readAt: now, existingCache: nil
        ))

        // 帳號已移除或變成 invalid → 不寫
        XCTAssertFalse(AgyContainerUsage.shouldWriteContainerCache(
            account: "beta", container: "agy2", fetchResult: .available(buckets),
            preGen: 5, postStatus: makeStatus(active: "alpha", gen: 5, liveMatches: "alpha", accounts: [makeAccount("alpha"), makeAccount("gamma")]),
            readAt: now, existingCache: nil
        ))
        XCTAssertFalse(AgyContainerUsage.shouldWriteContainerCache(
            account: "beta", container: "agy2", fetchResult: .available(buckets),
            preGen: 5, postStatus: makeStatus(active: "alpha", gen: 5, liveMatches: "alpha", accounts: [makeAccount("alpha"), makeAccount("beta", invalid: true), makeAccount("gamma")]),
            readAt: now, existingCache: nil
        ))

        // 磁碟快取 read_at 較新 → 不寫
        XCTAssertFalse(AgyContainerUsage.shouldWriteContainerCache(
            account: "beta", container: "agy2", fetchResult: .available(buckets),
            preGen: 5, postStatus: goodPost, readAt: now, existingCache: newerCache
        ))
    }

    // MARK: - 6. source 欄位讀寫相容性（規格 8.2 / 8.6）

    func testCacheSourceFieldCompatibility() throws {
        let stateDir = try makeTempDir("source-compat")
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let readAt = Date(timeIntervalSince1970: 1_800_000_000)

        // 寫入帶 container source
        XCTAssertTrue(AgySwapUsageCache.write(
            account: "beta", readAt: readAt, buckets: [bucket("Gemini 每週", remaining: 64)],
            stateDir: stateDir, source: "container:agy2"
        ))
        let loadedContainer = try XCTUnwrap(AgySwapUsageCache.read(account: "beta", stateDir: stateDir))
        XCTAssertEqual(loadedContainer.source, "container:agy2")

        // 寫入帶 mac source
        XCTAssertTrue(AgySwapUsageCache.write(
            account: "alpha", readAt: readAt, buckets: [bucket("Gemini 每週", remaining: 88)],
            stateDir: stateDir, source: "mac"
        ))
        let loadedMac = try XCTUnwrap(AgySwapUsageCache.read(account: "alpha", stateDir: stateDir))
        XCTAssertEqual(loadedMac.source, "mac")

        // 缺少 source、null、型別錯誤、非法 source、含未知欄位 → 都能正常讀回（source 退為 nil）
        let cases: [(name: String, json: String, expectedSource: String?)] = [
            ("missing", #"{"account":"alpha","read_at":"2026-11-22T00:00:00Z","pools":[{"name":"Gemini 每週","remaining_percent":80,"reset_at":null}]}"#, nil),
            ("null", #"{"account":"alpha","read_at":"2026-11-22T00:00:00Z","source":null,"pools":[{"name":"Gemini 每週","remaining_percent":80,"reset_at":null}]}"#, nil),
            ("int-type", #"{"account":"alpha","read_at":"2026-11-22T00:00:00Z","source":123,"pools":[{"name":"Gemini 每週","remaining_percent":80,"reset_at":null}]}"#, nil),
            ("array-type", #"{"account":"alpha","read_at":"2026-11-22T00:00:00Z","source":["mac"],"pools":[{"name":"Gemini 每週","remaining_percent":80,"reset_at":null}]}"#, nil),
            ("bool-type", #"{"account":"alpha","read_at":"2026-11-22T00:00:00Z","source":true,"pools":[{"name":"Gemini 每週","remaining_percent":80,"reset_at":null}]}"#, nil),
            ("unknown-source", #"{"account":"alpha","read_at":"2026-11-22T00:00:00Z","source":"cloud:foo","pools":[{"name":"Gemini 每週","remaining_percent":80,"reset_at":null}]}"#, nil),
            ("bad-container-source", #"{"account":"alpha","read_at":"2026-11-22T00:00:00Z","source":"container:-flag","pools":[{"name":"Gemini 每週","remaining_percent":80,"reset_at":null}]}"#, nil),
            ("extra-unknown-fields", #"{"account":"alpha","read_at":"2026-11-22T00:00:00Z","source":"container:agy3","future_v9":{"x":1},"note":"ok","pools":[{"name":"Gemini 每週","remaining_percent":80,"reset_at":null}]}"#, "container:agy3"),
        ]
        for tc in cases {
            let entry = try XCTUnwrap(AgySwapUsageCache.parse(data: Data(tc.json.utf8), expectedAccount: "alpha"), "應成功解析：\(tc.name)")
            XCTAssertEqual(entry.source, tc.expectedSource, "案例 \(tc.name)")
            XCTAssertEqual(entry.pools.first?.remainingPercent, 80)
        }
    }

    // MARK: - 7. AgySwapConfig 的 dockerPath／設定檔路徑／--agy-container-ttl 隔離（規格 8.1 / 8.4）

    func testConfigDockerPathContainerMapAndTTLIsolation() throws {
        let root = try makeTempDir("cfg-docker")
        defer { try? FileManager.default.removeItem(at: root) }
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        let supportDir = root.appendingPathComponent("support", isDirectory: true)
        let fakeDocker = try makeExecutableScript(in: root, name: "fake-docker", body: "#!/bin/sh\nexit 0\n")

        // 測試實例未給 CODENV_DOCKER_PATH → dockerPath 必為 nil（絕不退回系統真 docker）
        let testNoDocker = AgySwapConfig.from(
            arguments: ["codenv", "--state-dir", stateDir.path, "--agy-container-ttl", "12,6"],
            environment: [:],
            formalDockerPath: { fakeDocker.path },
            formalSupportDir: supportDir
        )
        XCTAssertTrue(testNoDocker.isTestInstance)
        XCTAssertNil(testNoDocker.dockerPath)
        XCTAssertEqual(testNoDocker.containerMapURL?.path, stateDir.appendingPathComponent("agy-container-map.json").path)
        XCTAssertEqual(testNoDocker.containerSuccessTTL, 12)
        XCTAssertEqual(testNoDocker.containerFailureTTL, 6)

        // 測試實例有給 CODENV_DOCKER_PATH → 採用注入路徑
        let testWithDocker = AgySwapConfig.from(
            arguments: ["codenv", "--state-dir", stateDir.path],
            environment: ["CODENV_DOCKER_PATH": fakeDocker.path],
            formalDockerPath: { nil },
            formalSupportDir: supportDir
        )
        XCTAssertEqual(testWithDocker.dockerPath, fakeDocker.path)
        XCTAssertEqual(testWithDocker.containerSuccessTTL, 600)
        XCTAssertEqual(testWithDocker.containerFailureTTL, 300)

        // 測試實例非法 --agy-container-ttl → 退回預設值
        let badTTL = AgySwapConfig.from(
            arguments: ["codenv", "--state-dir", stateDir.path, "--agy-container-ttl", "abc,-1"],
            environment: [:]
        )
        XCTAssertEqual(badTTL.containerSuccessTTL, 600)
        XCTAssertEqual(badTTL.containerFailureTTL, 300)

        // 測試實例 CODENV_DOCKER_PATH 指向不存在或不可執行檔案 → dockerPath 必為 nil
        let nonExec = root.appendingPathComponent("not-exec")
        try "hello".write(to: nonExec, atomically: true, encoding: .utf8)
        let testBadDocker = AgySwapConfig.from(
            arguments: ["codenv", "--state-dir", stateDir.path],
            environment: ["CODENV_DOCKER_PATH": nonExec.path],
            formalDockerPath: { fakeDocker.path },
            formalSupportDir: supportDir
        )
        XCTAssertNil(testBadDocker.dockerPath)

        // 正式實例忽略 CODENV_DOCKER_PATH 與 --agy-container-ttl，使用 formalDockerPath 與 formalSupportDir
        let otherDocker = try makeExecutableScript(in: root, name: "formal-docker", body: "#!/bin/sh\nexit 0\n")
        let formal = AgySwapConfig.from(
            arguments: ["codenv", "--agy-container-ttl", "1,1"],
            environment: ["CODENV_DOCKER_PATH": fakeDocker.path],
            formalDockerPath: { nil },
            formalSupportDir: supportDir
        )
        XCTAssertFalse(formal.isTestInstance)
        XCTAssertNil(formal.dockerPath)
        XCTAssertEqual(formal.containerMapURL?.path, supportDir.appendingPathComponent("agy-container-map.json").path)
        XCTAssertEqual(formal.containerSuccessTTL, 600)
        XCTAssertEqual(formal.containerFailureTTL, 300)

        let formalWithDocker = AgySwapConfig.from(
            arguments: ["codenv", "--agy-container-ttl", "1,1"],
            environment: ["CODENV_DOCKER_PATH": fakeDocker.path],
            formalDockerPath: { otherDocker.path },
            formalSupportDir: supportDir
        )
        XCTAssertEqual(formalWithDocker.dockerPath, otherDocker.path)
    }

    // MARK: - 8. fetchContainerQuota 逾時（5s / 5s / 10s）與非 agy2 容器泛化

    func testFetchContainerQuotaTimeoutsAndContainerValidation() {
        var recorded: [(args: [String], timeout: TimeInterval)] = []
        let status = UsageMonitor.fetchContainerQuota(
            container: "agy3",
            dockerPath: "/fake/docker",
            fileExists: { $0 == "/tmp/fake-kiri.sock" },
            runner: { _, args, timeout in
                recorded.append((args, timeout))
                if args == ["context", "inspect", "kiri"] {
                    return ExternalCommand.Result(
                        stdout: #"[{"Endpoints":{"docker":{"Host":"unix:///tmp/fake-kiri.sock"}}}]"#,
                        status: 0, timedOut: false
                    )
                }
                if args == ["--context", "kiri", "inspect", "-f", "{{.State.Running}}", "agy3"] {
                    return ExternalCommand.Result(stdout: "true\n", status: 0, timedOut: false)
                }
                if args == ["--context", "kiri", "exec", "agy3", "agy", "-p=/usage"] {
                    return ExternalCommand.Result(stdout: self.usageTable(g5: 80, gw: 70, argon: 90), status: 0, timedOut: false)
                }
                return ExternalCommand.Result(stdout: "", status: 1, timedOut: false)
            }
        )
        guard case .available(let buckets) = status else {
            return XCTFail("應回傳 .available，實際：\(status)")
        }
        XCTAssertEqual(buckets.map(\.remaining), [80, 70, 90])
        XCTAssertEqual(recorded.count, 3)
        XCTAssertEqual(recorded[0].timeout, 5)
        XCTAssertEqual(recorded[1].timeout, 5)
        XCTAssertEqual(recorded[2].timeout, 10, "exec 逾時須為 10 秒")

        // 非法容器名（- 開頭）直接拒絕，0 次 runner 呼叫
        var badCalls = 0
        let rejected = UsageMonitor.fetchContainerQuota(
            container: "-privileged",
            dockerPath: "/fake/docker",
            fileExists: { _ in true },
            runner: { _, _, _ in badCalls += 1; return nil }
        )
        XCTAssertEqual(rejected, .unreadable)
        XCTAssertEqual(badCalls, 0)
    }

    // MARK: - 9. 端對端整合：三帳號並行讀取、先更新 Mac 再完成容器、節流、狀態與 dump 欄位

    func testSwapBranchParallelContainerReadDumpThrottleAndNoLiveMutation() throws {
        let root = try makeTempDir("e2e-parallel")
        defer { try? FileManager.default.removeItem(at: root) }
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        let sockFile = root.appendingPathComponent("kiri.sock")
        let swapLog = root.appendingPathComponent("swap.log")
        let dockerLog = root.appendingPathComponent("docker.log")
        FileManager.default.createFile(atPath: sockFile.path, contents: Data())

        // alpha 為現用（也故意放進設定檔，驗證絕不讀 alpha 的容器）
        try writeContainerMap(["alpha": "agy1", "beta": "agy2", "gamma": "agy3"], to: stateDir)

        let alphaOut = usageTable(g5: 90, gw: 80, argon: 100, cw: 100, c5: 100)
        let betaOut = usageTable(g5: 60, gw: 50, argon: 40, cw: 0, c5: 50)
        let gammaOut = usageTable(g5: 30, gw: 20, argon: 10, cw: 0, c5: 0)

        let fakeSwap = try makeExecutableScript(in: root, name: "fake-agy-swap", body: """
        #!/usr/bin/python3
        import json, sys
        sub = sys.argv[1] if len(sys.argv) > 1 else ""
        with open("\(swapLog.path)", "a", encoding="utf-8") as f:
            f.write(sub + "\\n")
        if sub == "status":
            print(json.dumps({
                "active": "alpha", "gen": 3, "switching": False,
                "live_matches": "alpha", "recovery_pending": False,
                "accounts": [{"name": "alpha"}, {"name": "beta"}, {"name": "gamma"}]
            }))
            sys.exit(0)
        if sub == "run":
            if "--an-file" in sys.argv:
                an = sys.argv[sys.argv.index("--an-file") + 1]
                with open(an, "w", encoding="utf-8") as f:
                    f.write("alpha 3\\n")
            sys.stdout.write(\(String(reflecting: alphaOut)))
            sys.exit(0)
        sys.exit(2)
        """)

        // 假 docker：exec 刻意延遲 0.4s，確保 Mac 先完成並觸發第一次部分更新
        let fakeDocker = try makeExecutableScript(in: root, name: "fake-docker", body: """
        #!/usr/bin/python3
        import json, sys, time
        argv = sys.argv[1:]
        with open("\(dockerLog.path)", "a", encoding="utf-8") as f:
            f.write(json.dumps(argv) + "\\n")
        if argv == ["context", "inspect", "kiri"]:
            print(json.dumps([{"Endpoints": {"docker": {"Host": "unix://\(sockFile.path)"}}}]))
            sys.exit(0)
        if len(argv) == 6 and argv[:5] == ["--context", "kiri", "inspect", "-f", "{{.State.Running}}"]:
            print("true")
            sys.exit(0)
        if len(argv) == 6 and argv[:3] == ["--context", "kiri", "exec"] and argv[4:] == ["agy", "-p=/usage"]:
            time.sleep(0.4)
            c = argv[3]
            if c == "agy2":
                sys.stdout.write(\(String(reflecting: betaOut)))
                sys.exit(0)
            if c == "agy3":
                sys.stdout.write(\(String(reflecting: gammaOut)))
                sys.exit(0)
        sys.exit(1)
        """)

        let dumpFile = stateDir.appendingPathComponent("card-dump.json")
        let config = AgySwapConfig.from(
            arguments: ["codenv", "--state-dir", stateDir.path,
                        "--agy-swap-bin", fakeSwap.path, "--agy-usage-test",
                        "--usage-card-dump", dumpFile.path],
            environment: ["CODENV_DOCKER_PATH": fakeDocker.path]
        )

        var currentTime = Date(timeIntervalSince1970: 1_800_000_000)
        let monitor = UsageMonitor.makeForUnitTest()
        let partialExp = expectation(description: "Mac partial update before containers complete")
        let doneExp = expectation(description: "All Mac + container reads complete")
        var agyLoadingAtPartial: Bool?
        var dumpExistedAtPartial: Bool?

        monitor.runAgyRefreshBranchForTest(
            config: config,
            nowProvider: { currentTime },
            onPartialUpdate: {
                agyLoadingAtPartial = monitor.agyLoading
                dumpExistedAtPartial = FileManager.default.fileExists(atPath: dumpFile.path)
                partialExp.fulfill()
            },
            onComplete: { doneExp.fulfill() }
        )

        wait(for: [partialExp], timeout: 5)
        XCTAssertEqual(agyLoadingAtPartial, true, "Mac 先完成時 agyLoading 必須仍為 true")
        XCTAssertEqual(dumpExistedAtPartial, false, "容器未結束前不得先寫 --usage-card-dump")

        wait(for: [doneExp], timeout: 10)
        XCTAssertFalse(monitor.agyLoading)
        XCTAssertEqual(monitor.lastAgyOutcome, .ok)
        XCTAssertEqual(monitor.lastRoundContainerCalls, 6) // 2 容器 * 3 呼叫

        // 驗證 dump 檔案與結構（規格 8.5）
        let dumpData = try Data(contentsOf: dumpFile)
        let dump = try XCTUnwrap(JSONSerialization.jsonObject(with: dumpData) as? [String: Any])
        XCTAssertEqual(dump["mode"] as? String, "swap")
        XCTAssertEqual(dump["containerCalls"] as? Int, 6)
        let fullPage = try XCTUnwrap(dump["fullPage"] as? [String: Any])
        let accs = try XCTUnwrap(fullPage["accounts"] as? [[String: Any]])
        XCTAssertEqual(accs.map { $0["name"] as? String }, ["alpha", "beta", "gamma"])
        XCTAssertEqual(accs[0]["source"] as? String, "mac")
        XCTAssertEqual(accs[0]["containerStatus"] as? String, "skipped")
        XCTAssertEqual(accs[1]["source"] as? String, "container:agy2")
        XCTAssertEqual(accs[1]["containerStatus"] as? String, "fresh")
        XCTAssertEqual(accs[1]["state"] as? String, "live")
        XCTAssertEqual(accs[2]["source"] as? String, "container:agy3")
        XCTAssertEqual(accs[2]["containerStatus"] as? String, "fresh")
        XCTAssertEqual(accs[2]["state"] as? String, "live")

        let total = try XCTUnwrap(fullPage["total"] as? [String: Any])
        XCTAssertEqual(total["title"] as? String, "三帳號合計")
        XCTAssertEqual(total["accountCount"] as? Int, 3)
        let totalRows = try XCTUnwrap(total["rows"] as? [[String: Any]])
        XCTAssertEqual(totalRows.map { $0["label"] as? String }, ["Gemini 5 小時", "Gemini 每週", "Argon 每週", "Claude 每週", "Claude 5 小時"])
        // (90+60+30)/3=60, (80+50+20)/3=50, (100+40+10)/3=50, (100+0+0)/3=33, (100+50+0)/3=50
        XCTAssertEqual(totalRows.map { $0["percent"] as? Int }, [60, 50, 50, 33, 50])
        XCTAssertTrue(totalRows.allSatisfy { ($0["covered"] as? Int) == 3 && ($0["total"] as? Int) == 3 && ($0["oldestReadAt"] is NSNull) })

        // 驗證假 docker 記錄：絕不讀現用 alpha 的 agy1，且只有 context inspect / inspect / exec
        let dockerLines = try String(contentsOf: dockerLog, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String] }
        XCTAssertEqual(dockerLines.count, 6)
        XCTAssertFalse(dockerLines.contains { $0.contains("agy1") }, "現用帳號 alpha 即使有容器也絕不可讀取")
        XCTAssertTrue(dockerLines.allSatisfy { args in
            args == ["context", "inspect", "kiri"]
                || (args.count == 6 && args[2] == "inspect")
                || (args.count == 6 && args[2] == "exec")
        })

        // 驗證假 agy-swap 只出現 status 與 Mac 的 run，無任何切帳號指令
        let swapCalls = try String(contentsOf: swapLog, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertTrue(swapCalls.allSatisfy { $0 == "status" || $0 == "run" })
        XCTAssertEqual(swapCalls.filter { $0 == "run" }.count, 1)

        // 第二輪（5 分鐘後，仍在 10 分鐘成功節流窗內）→ 0 次 docker 呼叫，beta／gamma 為 throttled 且走磁碟快取
        currentTime = currentTime.addingTimeInterval(5 * 60)
        let round2Exp = expectation(description: "Second round throttled")
        monitor.runAgyRefreshBranchForTest(config: config, nowProvider: { currentTime }) { round2Exp.fulfill() }
        wait(for: [round2Exp], timeout: 10)

        XCTAssertEqual(monitor.lastRoundContainerCalls, 0)
        let dump2 = monitor.buildUsageCardDumpPayload()
        XCTAssertEqual(dump2["containerCalls"] as? Int, 0)
        let accs2 = try XCTUnwrap((dump2["fullPage"] as? [String: Any])?["accounts"] as? [[String: Any]])
        XCTAssertEqual(accs2[1]["containerStatus"] as? String, "throttled")
        XCTAssertEqual(accs2[1]["state"] as? String, "cached")
        XCTAssertEqual(accs2[1]["ageText"] as? String, "5 分鐘前")
        XCTAssertEqual(accs2[2]["containerStatus"] as? String, "throttled")
        XCTAssertEqual(accs2[2]["state"] as? String, "cached")

        // 第三輪（再過 6 分鐘＝距首次 11 分鐘 > 10 分鐘 TTL）→ 再次讀取容器
        currentTime = currentTime.addingTimeInterval(6 * 60)
        let round3Exp = expectation(description: "Third round after TTL")
        monitor.runAgyRefreshBranchForTest(config: config, nowProvider: { currentTime }) { round3Exp.fulfill() }
        wait(for: [round3Exp], timeout: 10)
        XCTAssertEqual(monitor.lastRoundContainerCalls, 6)
        let accs3 = try XCTUnwrap((monitor.buildUsageCardDumpPayload()["fullPage"] as? [String: Any])?["accounts"] as? [[String: Any]])
        XCTAssertEqual(accs3[1]["containerStatus"] as? String, "fresh")
        XCTAssertEqual(accs3[2]["containerStatus"] as? String, "fresh")
    }

    // MARK: - 10. 容器沒開（有／無快取）、失敗節流 5 分鐘、Mac 失敗但容器成功視為 gotData=true

    func testContainerDownWithAndWithoutCacheAndFailureThrottleAndGotData() throws {
        let root = try makeTempDir("container-down-gotdata")
        defer { try? FileManager.default.removeItem(at: root) }
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        let cacheDir = stateDir.appendingPathComponent("agy-swap/state", isDirectory: true)
        try writeContainerMap(["beta": "agy2", "gamma": "agy3"], to: stateDir)

        let baseNow = Date(timeIntervalSince1970: 1_800_000_000)
        let twentyMinAgo = baseNow.addingTimeInterval(-1200)
        // beta 有 20 分鐘前的舊快取，gamma 沒有快取
        XCTAssertTrue(AgySwapUsageCache.write(
            account: "beta", readAt: twentyMinAgo,
            buckets: [bucket("Gemini 每週", remaining: 44)], stateDir: cacheDir, source: "container:agy2"
        ))

        // Mac run 刻意失敗（exit 1），但 gamma 容器成功、beta 容器沒開（down）
        let fakeSwap = try makeExecutableScript(in: root, name: "swap-mac-fail.py", body: #"""
        #!/usr/bin/python3
        import json, sys
        if sys.argv[1] == "status":
            print(json.dumps({
                "active": "alpha", "gen": 3, "switching": False,
                "live_matches": "alpha", "recovery_pending": False,
                "accounts": [{"name": "alpha"}, {"name": "beta"}, {"name": "gamma"}]
            }))
            sys.exit(0)
        sys.exit(1)
        """#)

        let dummyDocker = try makeExecutableScript(in: root, name: "dummy-docker", body: "#!/bin/sh\nexit 0\n")
        let config = AgySwapConfig.from(
            arguments: ["codenv", "--state-dir", stateDir.path, "--agy-swap-bin", fakeSwap.path, "--agy-usage-test"],
            environment: ["CODENV_DOCKER_PATH": dummyDocker.path]
        )

        var currentTime = baseNow
        let monitor = UsageMonitor.makeForUnitTest()
        let oldUpdated = Date(timeIntervalSince1970: 1_700_000_000)
        monitor.updated = oldUpdated
        let cycle = monitor.beginRefreshCycleOnMain()
        let exp1 = expectation(description: "round 1")

        let mockRunner: (String, [String], TimeInterval) -> ExternalCommand.Result? = { _, args, _ in
            if args == ["context", "inspect", "kiri"] {
                return ExternalCommand.Result(stdout: #"[{"Endpoints":{"docker":{"Host":"unix:///fake/kiri.sock"}}}]"#, status: 0, timedOut: false)
            }
            if args.count == 6 && args[2] == "inspect" {
                return ExternalCommand.Result(stdout: args[5] == "agy3" ? "true\n" : "false\n", status: 0, timedOut: false)
            }
            if args.count == 6 && args[2] == "exec" && args[3] == "agy3" {
                return ExternalCommand.Result(stdout: self.usageTable(g5: 80, gw: 76, argon: 90), status: 0, timedOut: false)
            }
            return ExternalCommand.Result(stdout: "", status: 1, timedOut: false)
        }

        monitor.runAgyRefreshBranchForTest(
            config: config,
            nowProvider: { currentTime },
            containerFileExists: { _ in true },
            containerRunner: mockRunner
        ) { exp1.fulfill() }
        monitor.completeMainCycleOnMain(cycle: cycle, gotClaude: false, gotOther: false)
        wait(for: [exp1], timeout: 10)

        // Mac 失敗 → lastAgyOutcome == .failed，但 gamma 容器成功 → gotData == true（更新 updated，非「查不到用量」）
        XCTAssertEqual(monitor.lastAgyOutcome, .failed)
        XCTAssertEqual(monitor.error, "Claude 用量這次查不到")
        XCTAssertGreaterThan(try XCTUnwrap(monitor.updated), oldUpdated)

        let dump = monitor.buildUsageCardDumpPayload()
        let fullPage = try XCTUnwrap(dump["fullPage"] as? [String: Any])
        let accs = try XCTUnwrap(fullPage["accounts"] as? [[String: Any]])
        // alpha: never；beta: down + 舊快取保留（20 分鐘前）；gamma: fresh + live
        XCTAssertEqual(accs[0]["state"] as? String, "never")
        XCTAssertEqual(accs[1]["state"] as? String, "cached")
        XCTAssertEqual(accs[1]["containerStatus"] as? String, "down")
        XCTAssertEqual(accs[1]["ageText"] as? String, "20 分鐘前")
        XCTAssertEqual(accs[2]["state"] as? String, "live")
        XCTAssertEqual(accs[2]["containerStatus"] as? String, "fresh")
        XCTAssertEqual(accs[2]["source"] as? String, "container:agy3")

        // 合計 Gemini 每週：beta(44, cached) + gamma(76, live) = 60%, covered=2, total=3, oldestReadAt=twentyMinAgo
        let total = try XCTUnwrap(fullPage["total"] as? [String: Any])
        let rows = try XCTUnwrap(total["rows"] as? [[String: Any]])
        let gwRow = try XCTUnwrap(rows.first(where: { $0["label"] as? String == "Gemini 每週" }))
        XCTAssertEqual(gwRow["percent"] as? Int, 60)
        XCTAssertEqual(gwRow["covered"] as? Int, 2)
        XCTAssertEqual(gwRow["total"] as? Int, 3)
        XCTAssertEqual(gwRow["oldestReadAt"] as? String, AgySwapUsageCache.formatISO8601UTC(twentyMinAgo))

        // 4 分鐘後（< 5 分鐘失敗 TTL）：beta 與 gamma 都還在節流中 → 0 次 docker 呼叫
        currentTime = baseNow.addingTimeInterval(240)
        let exp2 = expectation(description: "round 2 failure throttle")
        monitor.runAgyRefreshBranchForTest(
            config: config,
            nowProvider: { currentTime },
            containerFileExists: { _ in true },
            containerRunner: mockRunner
        ) { exp2.fulfill() }
        wait(for: [exp2], timeout: 10)
        XCTAssertEqual(monitor.lastRoundContainerCalls, 0)
        let accs2 = try XCTUnwrap((monitor.buildUsageCardDumpPayload()["fullPage"] as? [String: Any])?["accounts"] as? [[String: Any]])
        XCTAssertEqual(accs2[1]["containerStatus"] as? String, "throttled")
        XCTAssertEqual(accs2[2]["containerStatus"] as? String, "throttled")

        // 6 分鐘後（> 5 分鐘失敗 TTL，但 < 10 分鐘成功 TTL）：beta 重試（2 次 docker 呼叫），gamma 仍節流！
        currentTime = baseNow.addingTimeInterval(360)
        let exp3 = expectation(description: "round 3 beta retry only")
        monitor.runAgyRefreshBranchForTest(
            config: config,
            nowProvider: { currentTime },
            containerFileExists: { _ in true },
            containerRunner: mockRunner
        ) { exp3.fulfill() }
        wait(for: [exp3], timeout: 10)
        XCTAssertEqual(monitor.lastRoundContainerCalls, 2) // 僅 beta 跑了 context inspect + inspect
        let accs3 = try XCTUnwrap((monitor.buildUsageCardDumpPayload()["fullPage"] as? [String: Any])?["accounts"] as? [[String: Any]])
        XCTAssertEqual(accs3[1]["containerStatus"] as? String, "down")
        XCTAssertEqual(accs3[2]["containerStatus"] as? String, "throttled")
    }

    // MARK: - 11. 離線／switching／recoveryPending／skipRound／無設定檔／無 dockerPath 不讀且不記錄嘗試

    func testOfflineSwitchingSkipRoundNoMapAndNoDockerPathNeverReadOrRecordAttempts() throws {
        let root = try makeTempDir("no-read-guards")
        defer { try? FileManager.default.removeItem(at: root) }
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        try writeContainerMap(["beta": "agy2"], to: stateDir)

        let dummyDocker = try makeExecutableScript(in: root, name: "dummy-docker", body: "#!/bin/sh\nexit 0\n")
        let normalSwap = try makeExecutableScript(in: root, name: "swap-normal.py", body: #"""
        #!/usr/bin/python3
        import json, sys
        if sys.argv[1] == "status":
            print(json.dumps({
                "active": "alpha", "gen": 3, "switching": False,
                "live_matches": "alpha", "recovery_pending": False,
                "accounts": [{"name": "alpha"}, {"name": "beta"}]
            }))
            sys.exit(0)
        sys.exit(1)
        """#)
        let failSwap = try makeExecutableScript(in: root, name: "swap-fail.sh", body: "#!/bin/sh\nexit 1\n")

        let baseNow = Date(timeIntervalSince1970: 1_800_000_000)
        var dockerCalls = 0
        let runner: (String, [String], TimeInterval) -> ExternalCommand.Result? = { _, args, _ in
            dockerCalls += 1
            if args == ["context", "inspect", "kiri"] {
                return ExternalCommand.Result(stdout: #"[{"Endpoints":{"docker":{"Host":"unix:///fake/kiri.sock"}}}]"#, status: 0, timedOut: false)
            }
            if args.count == 6 && args[2] == "inspect" {
                return ExternalCommand.Result(stdout: "true\n", status: 0, timedOut: false)
            }
            return ExternalCommand.Result(stdout: self.usageTable(g5: 50, gw: 50, argon: 50), status: 0, timedOut: false)
        }

        let monitor = UsageMonitor.makeForUnitTest()

        // 1) 離線（--agy-offline）→ 0 次 docker、不記錄嘗試
        let offlineCfg = AgySwapConfig.from(
            arguments: ["codenv", "--state-dir", stateDir.path, "--agy-swap-bin", normalSwap.path, "--agy-usage-test", "--agy-offline"],
            environment: ["CODENV_DOCKER_PATH": dummyDocker.path]
        )
        let expOffline = expectation(description: "offline")
        monitor.runAgyRefreshBranchForTest(config: offlineCfg, nowProvider: { baseNow }, containerFileExists: { _ in true }, containerRunner: runner) {
            expOffline.fulfill()
        }
        wait(for: [expOffline], timeout: 5)
        XCTAssertEqual(dockerCalls, 0)
        XCTAssertEqual(monitor.lastRoundContainerCalls, 0)

        // 2) .skipRound（status 失敗）→ 0 次 docker、不記錄嘗試
        let skipCfg = AgySwapConfig.from(
            arguments: ["codenv", "--state-dir", stateDir.path, "--agy-swap-bin", failSwap.path, "--agy-usage-test"],
            environment: ["CODENV_DOCKER_PATH": dummyDocker.path]
        )
        let expSkip = expectation(description: "skipRound")
        monitor.runAgyRefreshBranchForTest(config: skipCfg, nowProvider: { baseNow.addingTimeInterval(1) }, containerFileExists: { _ in true }, containerRunner: runner) {
            expSkip.fulfill()
        }
        wait(for: [expSkip], timeout: 5)
        XCTAssertEqual(dockerCalls, 0)

        // 3) 無 dockerPath → 0 次 docker、不記錄嘗試
        let noDockerCfg = AgySwapConfig.from(
            arguments: ["codenv", "--state-dir", stateDir.path, "--agy-swap-bin", normalSwap.path, "--agy-usage-test"],
            environment: [:]
        )
        XCTAssertNil(noDockerCfg.dockerPath)
        let expNoDocker = expectation(description: "no dockerPath")
        monitor.runAgyRefreshBranchForTest(config: noDockerCfg, nowProvider: { baseNow.addingTimeInterval(2) }, containerFileExists: { _ in true }, containerRunner: runner) {
            expNoDocker.fulfill()
        }
        wait(for: [expNoDocker], timeout: 5)
        XCTAssertEqual(dockerCalls, 0)

        // 4) 立刻恢復線上＋給 dockerPath（同一秒內，證明前三次都沒記錄嘗試）→ 立刻讀容器成功！
        let onlineCfg = AgySwapConfig.from(
            arguments: ["codenv", "--state-dir", stateDir.path, "--agy-swap-bin", normalSwap.path, "--agy-usage-test"],
            environment: ["CODENV_DOCKER_PATH": dummyDocker.path]
        )
        let expOnline = expectation(description: "online immediately after offline")
        monitor.runAgyRefreshBranchForTest(config: onlineCfg, nowProvider: { baseNow.addingTimeInterval(3) }, containerFileExists: { _ in true }, containerRunner: runner) {
            expOnline.fulfill()
        }
        wait(for: [expOnline], timeout: 5)
        XCTAssertEqual(dockerCalls, 3)
        let accs = try XCTUnwrap((monitor.buildUsageCardDumpPayload()["fullPage"] as? [String: Any])?["accounts"] as? [[String: Any]])
        XCTAssertEqual(accs[1]["containerStatus"] as? String, "fresh")

        // 5) 設定檔不存在 → containerStatus 全為 null、0 次 docker
        let stateNoMap = root.appendingPathComponent("state-nomap", isDirectory: true)
        let noMapCfg = AgySwapConfig.from(
            arguments: ["codenv", "--state-dir", stateNoMap.path, "--agy-swap-bin", normalSwap.path, "--agy-usage-test"],
            environment: ["CODENV_DOCKER_PATH": dummyDocker.path]
        )
        dockerCalls = 0
        let monitorNoMap = UsageMonitor.makeForUnitTest()
        let expNoMap = expectation(description: "no map file")
        monitorNoMap.runAgyRefreshBranchForTest(config: noMapCfg, nowProvider: { baseNow }, containerFileExists: { _ in true }, containerRunner: runner) {
            expNoMap.fulfill()
        }
        wait(for: [expNoMap], timeout: 5)
        XCTAssertEqual(dockerCalls, 0)
        let noMapDump = monitorNoMap.buildUsageCardDumpPayload()
        XCTAssertEqual(noMapDump["containerCalls"] as? Int, 0)
        let noMapFP = try XCTUnwrap(noMapDump["fullPage"] as? [String: Any])
        XCTAssertTrue(noMapFP["total"] is NSNull)
        let noMapAccs = try XCTUnwrap(noMapFP["accounts"] as? [[String: Any]])
        XCTAssertTrue(noMapAccs.allSatisfy { $0["containerStatus"] is NSNull })
    }

    // MARK: - 12. 寫入前 gen 變動時不覆蓋既有快取（端對端）

    func testContainerWriteAbortedWhenGenChangesBeforeWrite() throws {
        let root = try makeTempDir("gen-change")
        defer { try? FileManager.default.removeItem(at: root) }
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        let cacheDir = stateDir.appendingPathComponent("agy-swap/state", isDirectory: true)
        let cntFile = root.appendingPathComponent("status-cnt")
        try writeContainerMap(["beta": "agy2"], to: stateDir)

        let oldReadAt = Date(timeIntervalSince1970: 1_799_990_000)
        XCTAssertTrue(AgySwapUsageCache.write(
            account: "beta", readAt: oldReadAt,
            buckets: [bucket("Gemini 每週", remaining: 55)], stateDir: cacheDir, source: "container:agy2"
        ))
        let betaFile = try XCTUnwrap(AgySwapUsageCache.cacheFileURL(account: "beta", stateDir: cacheDir))
        let beforeBytes = try Data(contentsOf: betaFile)

        // 第 1 次 status 回 gen=3，後續寫入前 status 回 gen=4
        let genBumpSwap = try makeExecutableScript(in: root, name: "swap-gen-bump.py", body: """
        #!/usr/bin/python3
        import json, os, sys
        if sys.argv[1] == "status":
            p = "\(cntFile.path)"
            n = int(open(p).read()) + 1 if os.path.exists(p) else 1
            open(p, "w").write(str(n))
            print(json.dumps({
                "active": "alpha", "gen": 3 if n == 1 else 4, "switching": False,
                "live_matches": "alpha", "recovery_pending": False,
                "accounts": [{"name": "alpha"}, {"name": "beta"}]
            }))
            sys.exit(0)
        sys.exit(1)
        """)
        let dummyDocker = try makeExecutableScript(in: root, name: "dummy-docker", body: "#!/bin/sh\nexit 0\n")
        let config = AgySwapConfig.from(
            arguments: ["codenv", "--state-dir", stateDir.path, "--agy-swap-bin", genBumpSwap.path, "--agy-usage-test"],
            environment: ["CODENV_DOCKER_PATH": dummyDocker.path]
        )

        let monitor = UsageMonitor.makeForUnitTest()
        let exp = expectation(description: "gen changed before container write")
        monitor.runAgyRefreshBranchForTest(
            config: config,
            containerFileExists: { _ in true },
            containerRunner: { _, args, _ in
                if args == ["context", "inspect", "kiri"] {
                    return ExternalCommand.Result(stdout: #"[{"Endpoints":{"docker":{"Host":"unix:///fake/kiri.sock"}}}]"#, status: 0, timedOut: false)
                }
                if args.count == 6 && args[2] == "inspect" {
                    return ExternalCommand.Result(stdout: "true\n", status: 0, timedOut: false)
                }
                return ExternalCommand.Result(stdout: self.usageTable(g5: 99, gw: 99, argon: 99), status: 0, timedOut: false)
            }
        ) { exp.fulfill() }
        wait(for: [exp], timeout: 10)

        XCTAssertEqual(try Data(contentsOf: betaFile), beforeBytes, "gen 變了絕不可覆蓋既有快取")
        let betaDisp = try XCTUnwrap(monitor.agySwapAccounts.first(where: { $0.name == "beta" }))
        XCTAssertEqual(betaDisp.state, .cached)
        XCTAssertEqual(betaDisp.buckets.first?.remaining, 55)
        XCTAssertEqual(betaDisp.containerStatus, .skipped)
    }

    // MARK: - 13. switching／recoveryPending／live_matches 不一致不讀且不記錄嘗試（端對端）

    func testSwitchingRecoveryPendingAndLiveMatchesMismatchSkipWithoutRecordingAttempts() throws {
        let root = try makeTempDir("status-guards-e2e")
        defer { try? FileManager.default.removeItem(at: root) }
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        let modeFile = root.appendingPathComponent("mode.txt")
        try writeContainerMap(["beta": "agy2"], to: stateDir)

        let swapScript = try makeExecutableScript(in: root, name: "swap-modes.py", body: """
        #!/usr/bin/python3
        import json, sys
        mode = open("\(modeFile.path)").read().strip()
        if sys.argv[1] == "status":
            st = {
                "active": "alpha", "gen": 3, "switching": False,
                "live_matches": "alpha", "recovery_pending": False,
                "accounts": [{"name": "alpha"}, {"name": "beta"}]
            }
            if mode == "switching":
                st["switching"] = True
            elif mode == "recovery":
                st["recovery_pending"] = True
            elif mode == "mismatch":
                st["live_matches"] = "beta"
            elif mode == "unknown":
                st["active"] = None
                st["live_matches"] = None
            print(json.dumps(st))
            sys.exit(0)
        sys.exit(1)
        """)
        let dummyDocker = try makeExecutableScript(in: root, name: "dummy-docker", body: "#!/bin/sh\nexit 0\n")
        let config = AgySwapConfig.from(
            arguments: ["codenv", "--state-dir", stateDir.path, "--agy-swap-bin", swapScript.path, "--agy-usage-test"],
            environment: ["CODENV_DOCKER_PATH": dummyDocker.path]
        )

        var dockerCalls = 0
        let runner: (String, [String], TimeInterval) -> ExternalCommand.Result? = { _, args, _ in
            dockerCalls += 1
            if args == ["context", "inspect", "kiri"] {
                return ExternalCommand.Result(stdout: #"[{"Endpoints":{"docker":{"Host":"unix:///fake/kiri.sock"}}}]"#, status: 0, timedOut: false)
            }
            if args.count == 6 && args[2] == "inspect" {
                return ExternalCommand.Result(stdout: "true\n", status: 0, timedOut: false)
            }
            return ExternalCommand.Result(stdout: self.usageTable(g5: 66, gw: 77, argon: 88), status: 0, timedOut: false)
        }

        let monitor = UsageMonitor.makeForUnitTest()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        for mode in ["switching", "recovery", "mismatch", "unknown"] {
            try mode.write(to: modeFile, atomically: true, encoding: .utf8)
            let exp = expectation(description: "guard mode \(mode)")
            monitor.runAgyRefreshBranchForTest(config: config, nowProvider: { t0 }, containerFileExists: { _ in true }, containerRunner: runner) {
                exp.fulfill()
            }
            wait(for: [exp], timeout: 5)
            XCTAssertEqual(dockerCalls, 0, "mode=\(mode) 不得呼叫 docker")
            let beta = try XCTUnwrap(monitor.agySwapAccounts.first(where: { $0.name == "beta" }))
            XCTAssertEqual(beta.containerStatus, .skipped, "mode=\(mode) 應標 skipped")
        }

        // 同一時間切回 normal：因前四輪都沒記錄嘗試，本輪立刻讀容器成功
        try "normal".write(to: modeFile, atomically: true, encoding: .utf8)
        let expNormal = expectation(description: "normal right after guarded rounds")
        monitor.runAgyRefreshBranchForTest(config: config, nowProvider: { t0 }, containerFileExists: { _ in true }, containerRunner: runner) {
            expNormal.fulfill()
        }
        wait(for: [expNormal], timeout: 5)
        XCTAssertEqual(dockerCalls, 3)
        let betaNormal = try XCTUnwrap(monitor.agySwapAccounts.first(where: { $0.name == "beta" }))
        XCTAssertEqual(betaNormal.containerStatus, .fresh)
        XCTAssertEqual(betaNormal.state, .live)
    }

    // MARK: - 14. 現用帳號切換成有容器的那個（規格 8.6 e）

    func testActiveSwitchedToMappedAccountSkipsItsContainerAndReadsOtherContainer() throws {
        let root = try makeTempDir("active-mapped-switch")
        defer { try? FileManager.default.removeItem(at: root) }
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        let cacheDir = stateDir.appendingPathComponent("agy-swap/state", isDirectory: true)
        // alpha 無容器（只有磁碟舊快取）、beta ↔ agy2（目前現用）、gamma ↔ agy3（非現用）
        try writeContainerMap(["beta": "agy2", "gamma": "agy3"], to: stateDir)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let tenMinAgo = now.addingTimeInterval(-600)
        XCTAssertTrue(AgySwapUsageCache.write(
            account: "alpha", readAt: tenMinAgo,
            buckets: [bucket("Gemini 每週", remaining: 40)], stateDir: cacheDir, source: "mac"
        ))

        let betaOut = usageTable(g5: 90, gw: 80, argon: 100)
        let swapScript = try makeExecutableScript(in: root, name: "swap-beta-active.py", body: """
        #!/usr/bin/python3
        import json, sys
        sub = sys.argv[1] if len(sys.argv) > 1 else ""
        if sub == "status":
            print(json.dumps({
                "active": "beta", "gen": 8, "switching": False,
                "live_matches": "beta", "recovery_pending": False,
                "accounts": [{"name": "alpha"}, {"name": "beta"}, {"name": "gamma"}]
            }))
            sys.exit(0)
        if sub == "run":
            if "--an-file" in sys.argv:
                an = sys.argv[sys.argv.index("--an-file") + 1]
                with open(an, "w", encoding="utf-8") as f:
                    f.write("beta 8\\n")
            sys.stdout.write(\(String(reflecting: betaOut)))
            sys.exit(0)
        sys.exit(2)
        """)
        let dummyDocker = try makeExecutableScript(in: root, name: "dummy-docker", body: "#!/bin/sh\nexit 0\n")
        let config = AgySwapConfig.from(
            arguments: ["codenv", "--state-dir", stateDir.path, "--agy-swap-bin", swapScript.path, "--agy-usage-test"],
            environment: ["CODENV_DOCKER_PATH": dummyDocker.path]
        )

        var seenContainers: [String] = []
        let monitor = UsageMonitor.makeForUnitTest()
        let exp = expectation(description: "beta active skips agy2 and reads agy3")
        monitor.runAgyRefreshBranchForTest(
            config: config,
            nowProvider: { now },
            containerFileExists: { _ in true },
            containerRunner: { _, args, _ in
                if args == ["context", "inspect", "kiri"] {
                    return ExternalCommand.Result(stdout: #"[{"Endpoints":{"docker":{"Host":"unix:///fake/kiri.sock"}}}]"#, status: 0, timedOut: false)
                }
                if args.count == 6 && args[2] == "inspect" {
                    seenContainers.append(args[5])
                    return ExternalCommand.Result(stdout: "true\n", status: 0, timedOut: false)
                }
                if args.count == 6 && args[2] == "exec" {
                    seenContainers.append(args[3])
                    return ExternalCommand.Result(stdout: self.usageTable(g5: 60, gw: 60, argon: 60), status: 0, timedOut: false)
                }
                return ExternalCommand.Result(stdout: "", status: 1, timedOut: false)
            }
        ) { exp.fulfill() }
        wait(for: [exp], timeout: 10)

        XCTAssertFalse(seenContainers.contains("agy2"), "現用帳號 beta 的容器 agy2 絕不可被讀取")
        XCTAssertEqual(Set(seenContainers), Set(["agy3"]))
        XCTAssertEqual(monitor.lastRoundContainerCalls, 3)

        let dump = monitor.buildUsageCardDumpPayload()
        let accs = try XCTUnwrap((dump["fullPage"] as? [String: Any])?["accounts"] as? [[String: Any]])
        // alpha: cached (mac, 10 分鐘前, skipped)
        XCTAssertEqual(accs[0]["name"] as? String, "alpha")
        XCTAssertEqual(accs[0]["state"] as? String, "cached")
        XCTAssertEqual(accs[0]["source"] as? String, "mac")
        XCTAssertEqual(accs[0]["containerStatus"] as? String, "skipped")
        // beta: live (mac, skipped)
        XCTAssertEqual(accs[1]["name"] as? String, "beta")
        XCTAssertEqual(accs[1]["state"] as? String, "live")
        XCTAssertEqual(accs[1]["source"] as? String, "mac")
        XCTAssertEqual(accs[1]["containerStatus"] as? String, "skipped")
        // gamma: live (container:agy3, fresh)
        XCTAssertEqual(accs[2]["name"] as? String, "gamma")
        XCTAssertEqual(accs[2]["state"] as? String, "live")
        XCTAssertEqual(accs[2]["source"] as? String, "container:agy3")
        XCTAssertEqual(accs[2]["containerStatus"] as? String, "fresh")

        // Gemini 每週平均：(40 + 80 + 60) / 3 = 60%，covered=3, total=3, oldestReadAt=tenMinAgo
        let total = try XCTUnwrap((dump["fullPage"] as? [String: Any])?["total"] as? [String: Any])
        let rows = try XCTUnwrap(total["rows"] as? [[String: Any]])
        let gwRow = try XCTUnwrap(rows.first(where: { $0["label"] as? String == "Gemini 每週" }))
        XCTAssertEqual(gwRow["percent"] as? Int, 60)
        XCTAssertEqual(gwRow["covered"] as? Int, 3)
        XCTAssertEqual(gwRow["total"] as? Int, 3)
        XCTAssertEqual(gwRow["oldestReadAt"] as? String, AgySwapUsageCache.formatISO8601UTC(tenMinAgo))
    }

    // MARK: - 15. 自訂 --agy-container-ttl、較新磁碟快取保護、空解析／unreadable 不清舊快取

    func testCustomContainerTTLNewerCacheProtectionAndUnreadablePreservesOldCache() throws {
        let root = try makeTempDir("ttl-newer-unreadable")
        defer { try? FileManager.default.removeItem(at: root) }
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        let cacheDir = stateDir.appendingPathComponent("agy-swap/state", isDirectory: true)
        try writeContainerMap(["beta": "agy2", "gamma": "agy3"], to: stateDir)

        let baseNow = Date(timeIntervalSince1970: 1_800_000_000)
        let newerReadAt = baseNow.addingTimeInterval(120)
        let oldGammaReadAt = baseNow.addingTimeInterval(-300)

        // beta 磁碟已有比本次讀取更新的快取（+120s），gamma 有 5 分鐘前的舊快取
        XCTAssertTrue(AgySwapUsageCache.write(
            account: "beta", readAt: newerReadAt,
            buckets: [bucket("Gemini 每週", remaining: 82)], stateDir: cacheDir, source: "mac"
        ))
        XCTAssertTrue(AgySwapUsageCache.write(
            account: "gamma", readAt: oldGammaReadAt,
            buckets: [bucket("Gemini 每週", remaining: 47)], stateDir: cacheDir, source: "container:agy3"
        ))
        let betaFile = try XCTUnwrap(AgySwapUsageCache.cacheFileURL(account: "beta", stateDir: cacheDir))
        let gammaFile = try XCTUnwrap(AgySwapUsageCache.cacheFileURL(account: "gamma", stateDir: cacheDir))
        let betaBefore = try Data(contentsOf: betaFile)
        let gammaBefore = try Data(contentsOf: gammaFile)

        let swapScript = try makeExecutableScript(in: root, name: "swap.py", body: #"""
        #!/usr/bin/python3
        import json, sys
        if sys.argv[1] == "status":
            print(json.dumps({
                "active": "alpha", "gen": 3, "switching": False,
                "live_matches": "alpha", "recovery_pending": False,
                "accounts": [{"name": "alpha"}, {"name": "beta"}, {"name": "gamma"}]
            }))
            sys.exit(0)
        sys.exit(1)
        """#)
        let dummyDocker = try makeExecutableScript(in: root, name: "dummy-docker", body: "#!/bin/sh\nexit 0\n")
        // 自訂短 TTL：成功 10 秒、失敗 5 秒
        let config = AgySwapConfig.from(
            arguments: ["codenv", "--state-dir", stateDir.path, "--agy-swap-bin", swapScript.path,
                        "--agy-usage-test", "--agy-container-ttl", "10,5"],
            environment: ["CODENV_DOCKER_PATH": dummyDocker.path]
        )

        var gammaMode = "garbage"
        var currentTime = baseNow
        let runner: (String, [String], TimeInterval) -> ExternalCommand.Result? = { _, args, _ in
            if args == ["context", "inspect", "kiri"] {
                return ExternalCommand.Result(stdout: #"[{"Endpoints":{"docker":{"Host":"unix:///fake/kiri.sock"}}}]"#, status: 0, timedOut: false)
            }
            if args.count == 6 && args[2] == "inspect" {
                return ExternalCommand.Result(stdout: "true\n", status: 0, timedOut: false)
            }
            if args.count == 6 && args[2] == "exec" {
                if args[3] == "agy2" {
                    return ExternalCommand.Result(stdout: self.usageTable(g5: 10, gw: 10, argon: 10), status: 0, timedOut: false)
                }
                if args[3] == "agy3" {
                    if gammaMode == "garbage" {
                        return ExternalCommand.Result(stdout: "not a usage table\n", status: 0, timedOut: false)
                    }
                    return ExternalCommand.Result(stdout: self.usageTable(g5: 70, gw: 70, argon: 70), status: 0, timedOut: false)
                }
            }
            return ExternalCommand.Result(stdout: "", status: 1, timedOut: false)
        }

        let monitor = UsageMonitor.makeForUnitTest()

        // 第 1 輪：beta 磁碟快取較新 → 不覆蓋；gamma 吐非 /usage 表（unreadable）→ 不清舊快取
        let exp1 = expectation(description: "round 1")
        monitor.runAgyRefreshBranchForTest(config: config, nowProvider: { currentTime }, containerFileExists: { _ in true }, containerRunner: runner) {
            exp1.fulfill()
        }
        wait(for: [exp1], timeout: 10)
        XCTAssertEqual(try Data(contentsOf: betaFile), betaBefore, "磁碟快取較新時絕不可被較舊讀取覆蓋")
        XCTAssertEqual(try Data(contentsOf: gammaFile), gammaBefore, "unreadable／空解析絕不可清掉舊快取")
        let beta1 = try XCTUnwrap(monitor.agySwapAccounts.first(where: { $0.name == "beta" }))
        let gamma1 = try XCTUnwrap(monitor.agySwapAccounts.first(where: { $0.name == "gamma" }))
        XCTAssertEqual(beta1.state, .cached)
        XCTAssertEqual(beta1.buckets.first?.remaining, 82)
        XCTAssertEqual(beta1.containerStatus, .skipped)
        XCTAssertEqual(gamma1.state, .cached)
        XCTAssertEqual(gamma1.buckets.first?.remaining, 47)
        XCTAssertEqual(gamma1.containerStatus, .unreadable)

        // 第 2 輪（+4 秒 < 失敗 TTL 5 秒）：gamma 與 beta 仍在節流窗內 → 0 次呼叫
        currentTime = baseNow.addingTimeInterval(4)
        gammaMode = "ok"
        let exp2 = expectation(description: "round 2 throttled at 4s")
        monitor.runAgyRefreshBranchForTest(config: config, nowProvider: { currentTime }, containerFileExists: { _ in true }, containerRunner: runner) {
            exp2.fulfill()
        }
        wait(for: [exp2], timeout: 10)
        XCTAssertEqual(monitor.lastRoundContainerCalls, 0)

        // 第 3 輪（+5 秒 >= 失敗 TTL 5 秒）：gamma 放行並成功讀到 70%（寫新快取）；beta 仍受較新快取保護
        currentTime = baseNow.addingTimeInterval(5)
        let exp3 = expectation(description: "round 3 retry at 5s")
        monitor.runAgyRefreshBranchForTest(config: config, nowProvider: { currentTime }, containerFileExists: { _ in true }, containerRunner: runner) {
            exp3.fulfill()
        }
        wait(for: [exp3], timeout: 10)
        XCTAssertEqual(monitor.lastRoundContainerCalls, 6)
        let gamma3 = try XCTUnwrap(monitor.agySwapAccounts.first(where: { $0.name == "gamma" }))
        XCTAssertEqual(gamma3.state, .live)
        XCTAssertEqual(gamma3.containerStatus, .fresh)
        XCTAssertEqual(gamma3.buckets.first(where: { $0.label == "Gemini 每週" })?.remaining, 70)

        // 第 4 輪（+14 秒＝gamma 成功後 9 秒 < 成功 TTL 10 秒）：gamma 仍在成功節流窗內
        currentTime = baseNow.addingTimeInterval(14)
        let exp4 = expectation(description: "round 4 gamma throttled at +9s")
        monitor.runAgyRefreshBranchForTest(config: config, nowProvider: { currentTime }, containerFileExists: { _ in true }, containerRunner: runner) {
            exp4.fulfill()
        }
        wait(for: [exp4], timeout: 10)
        let gamma4 = try XCTUnwrap(monitor.agySwapAccounts.first(where: { $0.name == "gamma" }))
        XCTAssertEqual(gamma4.containerStatus, .throttled)

        // 第 5 輪（+15 秒＝gamma 成功後 10 秒 >= 成功 TTL 10 秒）：gamma 放行再讀
        currentTime = baseNow.addingTimeInterval(15)
        let exp5 = expectation(description: "round 5 gamma allowed at +10s")
        monitor.runAgyRefreshBranchForTest(config: config, nowProvider: { currentTime }, containerFileExists: { _ in true }, containerRunner: runner) {
            exp5.fulfill()
        }
        wait(for: [exp5], timeout: 10)
        let gamma5 = try XCTUnwrap(monitor.agySwapAccounts.first(where: { $0.name == "gamma" }))
        XCTAssertEqual(gamma5.containerStatus, .fresh)
    }
}
