import XCTest
import Darwin
@testable import Workbench

final class AgySwapUsageTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDir(_ prefix: String = "agyswap-test") throws -> URL {
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

    private func sampleBuckets(fivePct: Int = 94, weekPct: Int = 98, argonPct: Int = 100) -> [UsageBucket] {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        return [
            UsageBucket(label: "Gemini 5 小時", used: 100 - fivePct, resets: "12:00", resetAt: base.addingTimeInterval(3600)),
            UsageBucket(label: "Gemini 每週", used: 100 - weekPct, resets: "11/28 00:00", resetAt: base.addingTimeInterval(86400 * 6)),
            UsageBucket(label: "Argon 每週", used: 100 - argonPct, resets: "11/28 00:00", resetAt: base.addingTimeInterval(86400 * 6)),
        ]
    }

    private func sampleStatus(
        active: String? = "oli",
        gen: Int = 5,
        switching: Bool = false,
        liveMatches: String? = "oli",
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

    private func makeAccount(_ name: String, invalid: Bool = false, verifyFailures: Int = 0) -> AgySwapStatus.Account {
        AgySwapStatus.Account(
            name: name,
            invalid: invalid,
            exhausted: [:],
            verifyFailures: verifyFailures,
            verifyFailedAt: verifyFailures > 0 ? "2026-11-22T01:00:00Z" : nil
        )
    }

    private func isProcessAlive(_ pid: pid_t) -> Bool {
        errno = 0
        return Darwin.kill(pid, 0) == 0 || errno != ESRCH
    }

    // MARK: - 1. 測試旗標與門檻（2×2 交叉組合、逾時縮短、路徑隔離）

    func testConfigFlagMatrixAndIsolation() throws {
        let root = try makeTempDir("config")
        defer { try? FileManager.default.removeItem(at: root) }
        let fakeSwap = try makeExecutableScript(in: root, name: "fake-agy-swap", body: "#!/bin/sh\nexit 0\n")
        let fakeAgy = try makeExecutableScript(in: root, name: "fake-agy", body: "#!/bin/sh\nexit 0\n")
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        let insideDump = stateDir.appendingPathComponent("card.json").path
        let outsideDump = root.appendingPathComponent("escape.json").path
        let fakeHome = root.appendingPathComponent("home", isDirectory: true)

        // 1) 正式模式（無 --state-dir）：忽略所有測試旗標，使用 formalSwapPath 與 ~/.local/state/agy-swap
        let formal = AgySwapConfig.from(
            arguments: ["codenv", "--agy-swap-bin", fakeSwap.path, "--agy-usage-test",
                        "--agy-swap-status-timeout", "3", "--agy-swap-run-timeout", "4",
                        "--agy-swap-kill-grace", "1", "--usage-card-dump", insideDump],
            formalSwapPath: { fakeSwap.path },
            homeDir: fakeHome
        )
        XCTAssertFalse(formal.isTestInstance)
        XCTAssertTrue(formal.usageSwapEnabled)
        XCTAssertTrue(formal.backgroundSwapEnabled)
        XCTAssertEqual(formal.statusTimeout, 25)
        XCTAssertEqual(formal.usageRunTimeout, 75)
        XCTAssertEqual(formal.nextGuessTimeout, 45)
        XCTAssertEqual(formal.sprintCheckTimeout, 120)
        XCTAssertEqual(formal.killGrace, 10)
        XCTAssertNil(formal.usageCardDumpURL)
        XCTAssertEqual(formal.cacheStateDir.path, fakeHome.appendingPathComponent(".local/state/agy-swap").path)

        // 2) 測試實例：兩者都沒給（絕不退回正式 agy-swap）
        let testNeither = AgySwapConfig.from(
            arguments: ["codenv", "--state-dir", stateDir.path, "--agy-bin", fakeAgy.path],
            formalSwapPath: { fakeSwap.path },
            homeDir: fakeHome
        )
        XCTAssertTrue(testNeither.isTestInstance)
        XCTAssertNil(testNeither.agySwapBin)
        XCTAssertFalse(testNeither.usageSwapEnabled)
        XCTAssertFalse(testNeither.backgroundSwapEnabled)

        // 3) 測試實例：只給 --agy-usage-test，沒給 --agy-swap-bin
        let testOnlyUsage = AgySwapConfig.from(
            arguments: ["codenv", "--state-dir", stateDir.path, "--agy-usage-test"],
            formalSwapPath: { fakeSwap.path },
            homeDir: fakeHome
        )
        XCTAssertNil(testOnlyUsage.agySwapBin)
        XCTAssertFalse(testOnlyUsage.usageSwapEnabled)
        XCTAssertFalse(testOnlyUsage.backgroundSwapEnabled)

        // 4) 測試實例：只給 --agy-swap-bin，沒給 --agy-usage-test（背景工具啟用、額度查詢不啟用）
        let testOnlyBin = AgySwapConfig.from(
            arguments: ["codenv", "--state-dir", stateDir.path, "--agy-swap-bin", fakeSwap.path],
            formalSwapPath: { nil },
            homeDir: fakeHome
        )
        XCTAssertEqual(testOnlyBin.agySwapBin, fakeSwap.path)
        XCTAssertFalse(testOnlyBin.usageSwapEnabled)
        XCTAssertTrue(testOnlyBin.backgroundSwapEnabled)

        // 5) 測試實例：兩者都給 + 縮短逾時 + dump 路徑在 state-dir 內
        let testBoth = AgySwapConfig.from(
            arguments: ["codenv", "--state-dir", stateDir.path,
                        "--agy-swap-bin", fakeSwap.path, "--agy-bin", fakeAgy.path, "--agy-usage-test",
                        "--agy-swap-status-timeout", "3.5", "--agy-swap-run-timeout", "5",
                        "--agy-swap-kill-grace", "1.5", "--usage-card-dump", insideDump],
            formalSwapPath: { nil },
            homeDir: fakeHome
        )
        XCTAssertTrue(testBoth.usageSwapEnabled)
        XCTAssertTrue(testBoth.backgroundSwapEnabled)
        XCTAssertEqual(testBoth.statusTimeout, 3.5)
        XCTAssertEqual(testBoth.usageRunTimeout, 5)
        XCTAssertEqual(testBoth.nextGuessTimeout, 5)
        XCTAssertEqual(testBoth.sprintCheckTimeout, 5)
        XCTAssertEqual(testBoth.killGrace, 1.5)
        XCTAssertEqual(testBoth.usageCardDumpURL?.path, URL(fileURLWithPath: insideDump).standardizedFileURL.path)
        XCTAssertEqual(testBoth.testDir?.path, stateDir.appendingPathComponent("agy-swap").path)
        XCTAssertEqual(testBoth.cacheStateDir.path, stateDir.appendingPathComponent("agy-swap/state").path)

        // 6) dump 路徑超出 state-dir → 拒絕
        let testOutsideDump = AgySwapConfig.from(
            arguments: ["codenv", "--state-dir", stateDir.path, "--usage-card-dump", outsideDump],
            formalSwapPath: { nil },
            homeDir: fakeHome
        )
        XCTAssertNil(testOutsideDump.usageCardDumpURL)
    }

    // MARK: - 2. 模式判定與連續 3 輪失敗降級

    func testModeTrackerDecisionsAndThreeFailureDegrade() {
        let tracker = AgySwapModeTracker()

        // 無執行檔 → legacy
        XCTAssertEqual(tracker.evaluate(hasBinary: false, statusResult: nil), .legacy(nil))

        // 0 帳號 / 1 帳號 → legacy
        let zero = sampleStatus(active: nil, liveMatches: nil, accounts: [])
        XCTAssertEqual(tracker.evaluate(hasBinary: true, statusResult: .success(zero)), .legacy(zero))

        let one = sampleStatus(accounts: [makeAccount("oli")])
        XCTAssertEqual(tracker.evaluate(hasBinary: true, statusResult: .success(one)), .legacy(one))

        // ≥2 帳號 → swap
        let two = sampleStatus(accounts: [makeAccount("oli"), makeAccount("pettan")])
        XCTAssertEqual(tracker.evaluate(hasBinary: true, statusResult: .success(two)), .swap(two))

        // 第 1 次失敗（逾時）→ skipRound，不降級
        let fail1 = tracker.evaluate(hasBinary: true, statusResult: .failed(reason: "timeout"))
        XCTAssertEqual(fail1, .skipRound(reason: "timeout", consecutiveFailures: 1))

        // 第 2 次失敗（accounts_error=true）→ skipRound，不當 0 帳號
        let accErr = sampleStatus(active: nil, liveMatches: nil, accountsError: true, accounts: [])
        let fail2 = tracker.evaluate(hasBinary: true, statusResult: .success(accErr))
        XCTAssertEqual(fail2, .skipRound(reason: "status 回報 accounts_error", consecutiveFailures: 2))

        // 第 3 次連續失敗 → 降級回非換帳號模式
        let fail3 = tracker.evaluate(hasBinary: true, statusResult: .failed(reason: "exit 1"))
        XCTAssertEqual(fail3, .degradedLegacy(reason: "exit 1", consecutiveFailures: 3))

        // 第 4 次恢復正常 → 計數歸零、回到 swap
        XCTAssertEqual(tracker.evaluate(hasBinary: true, statusResult: .success(two)), .swap(two))
        XCTAssertEqual(tracker.consecutiveStatusFailures, 0)

        // 中途恢復後再失敗 1 次 → 從 1 開始算
        let failAfterRecover = tracker.evaluate(hasBinary: true, statusResult: .failed(reason: "err"))
        XCTAssertEqual(failAfterRecover, .skipRound(reason: "err", consecutiveFailures: 1))
    }

    func testStatusJSONParsing() throws {
        let raw = #"""
        {
          "active": "oli",
          "gen": 7,
          "switching": false,
          "live_matches": "oli",
          "last_switch": "2026-11-22T01:00:00Z",
          "recovery_pending": true,
          "accounts": [
            {"name": "oli", "invalid": false, "exhausted": {}, "verify_failures": 0},
            {"name": "pettan", "invalid": false, "exhausted": {"gemini": "2026-11-22T06:00:00Z"}, "verify_failures": 1, "verify_failed_at": "2026-11-22T02:00:00Z"},
            {"name": "tester-c", "invalid": true, "verify_failures": 2}
          ]
        }
        """#
        let status = try XCTUnwrap(AgySwapStatus.parse(raw))
        XCTAssertEqual(status.active, "oli")
        XCTAssertEqual(status.gen, 7)
        XCTAssertFalse(status.switching)
        XCTAssertTrue(status.recoveryPending)
        XCTAssertFalse(status.accountsError)
        XCTAssertEqual(status.accounts.count, 3)
        XCTAssertEqual(status.accounts[1].verifyFailures, 1)
        XCTAssertFalse(status.accounts[1].invalid)
        XCTAssertTrue(status.accounts[2].invalid)

        // accounts_error=true 即使缺 accounts / gen 仍可解析並標為 accountsError
        let errStatus = try XCTUnwrap(AgySwapStatus.parse(#"{"accounts_error":true}"#))
        XCTAssertTrue(errStatus.accountsError)

        // 非法 JSON → nil
        XCTAssertNil(AgySwapStatus.parse("not json"))
        XCTAssertNil(AgySwapStatus.parse(#"{"active":"oli"}"#))
    }

    // MARK: - 3. 寫快取條件全分支（14 項條件）

    func testShouldWriteCacheAllBranches() {
        let okExec = AgySwapExecResult(exitCode: 0, stdout: "ok", stderr: "", weTerminated: false, timedOut: false, launched: true, argv: [])
        let buckets = sampleBuckets()
        let an = AgySwapAnFileInfo(account: "oli", gen: 5)
        let accounts = [makeAccount("oli"), makeAccount("pettan")]
        let goodPost = sampleStatus(active: "oli", gen: 5, switching: false, liveMatches: "oli", recoveryPending: false, accountsError: false, accounts: accounts)

        // 全通過
        XCTAssertEqual(
            AgySwapUsageCache.shouldWriteCache(execResult: okExec, parsedBuckets: buckets, anInfo: an, postStatus: goodPost),
            "oli"
        )

        // launched == false
        let notLaunched = AgySwapExecResult(exitCode: 0, stdout: "", stderr: "", weTerminated: false, timedOut: false, launched: false, argv: [])
        XCTAssertNil(AgySwapUsageCache.shouldWriteCache(execResult: notLaunched, parsedBuckets: buckets, anInfo: an, postStatus: goodPost))

        // weTerminated == true
        let termExec = AgySwapExecResult(exitCode: 0, stdout: "", stderr: "", weTerminated: true, timedOut: true, launched: true, argv: [])
        XCTAssertNil(AgySwapUsageCache.shouldWriteCache(execResult: termExec, parsedBuckets: buckets, anInfo: an, postStatus: goodPost))

        // outputTruncated == true（fix2 第 1 項）
        let truncatedExec = AgySwapExecResult(exitCode: 0, stdout: "ok", stderr: "", weTerminated: false, timedOut: false, launched: true, argv: [], outputTruncated: true)
        XCTAssertNil(AgySwapUsageCache.shouldWriteCache(execResult: truncatedExec, parsedBuckets: buckets, anInfo: an, postStatus: goodPost))

        // exitCode != 0
        let nonZero = AgySwapExecResult(exitCode: 1, stdout: "ok", stderr: "", weTerminated: false, timedOut: false, launched: true, argv: [])
        XCTAssertNil(AgySwapUsageCache.shouldWriteCache(execResult: nonZero, parsedBuckets: buckets, anInfo: an, postStatus: goodPost))

        // parsedBuckets 為空
        XCTAssertNil(AgySwapUsageCache.shouldWriteCache(execResult: okExec, parsedBuckets: [], anInfo: an, postStatus: goodPost))

        // anInfo == nil
        XCTAssertNil(AgySwapUsageCache.shouldWriteCache(execResult: okExec, parsedBuckets: buckets, anInfo: nil, postStatus: goodPost))

        // unknown 帳號
        let unknownAn = AgySwapAnFileInfo(account: "unknown", gen: 5)
        let unknownPost = sampleStatus(active: "unknown", gen: 5, liveMatches: "unknown", accounts: [makeAccount("unknown"), makeAccount("oli")])
        XCTAssertNil(AgySwapUsageCache.shouldWriteCache(execResult: okExec, parsedBuckets: buckets, anInfo: unknownAn, postStatus: unknownPost))

        // 帳號名非法（路徑穿越、超過 32 字）
        let badNameAn = AgySwapAnFileInfo(account: "../evil", gen: 5)
        let badNamePost = sampleStatus(active: "../evil", gen: 5, liveMatches: "../evil", accounts: [makeAccount("../evil"), makeAccount("oli")])
        XCTAssertNil(AgySwapUsageCache.shouldWriteCache(execResult: okExec, parsedBuckets: buckets, anInfo: badNameAn, postStatus: badNamePost))

        let tooLongName = String(repeating: "a", count: 33)
        let longAn = AgySwapAnFileInfo(account: tooLongName, gen: 5)
        let longPost = sampleStatus(active: tooLongName, gen: 5, liveMatches: tooLongName, accounts: [makeAccount(tooLongName), makeAccount("oli")])
        XCTAssertNil(AgySwapUsageCache.shouldWriteCache(execResult: okExec, parsedBuckets: buckets, anInfo: longAn, postStatus: longPost))

        // postStatus == nil
        XCTAssertNil(AgySwapUsageCache.shouldWriteCache(execResult: okExec, parsedBuckets: buckets, anInfo: an, postStatus: nil))

        // accounts_error == true
        let errPost = sampleStatus(gen: 5, liveMatches: "oli", accountsError: true, accounts: accounts)
        XCTAssertNil(AgySwapUsageCache.shouldWriteCache(execResult: okExec, parsedBuckets: buckets, anInfo: an, postStatus: errPost))

        // switching == true
        let switchPost = sampleStatus(gen: 5, switching: true, liveMatches: "oli", accounts: accounts)
        XCTAssertNil(AgySwapUsageCache.shouldWriteCache(execResult: okExec, parsedBuckets: buckets, anInfo: an, postStatus: switchPost))

        // recovery_pending == true
        let recPost = sampleStatus(gen: 5, liveMatches: "oli", recoveryPending: true, accounts: accounts)
        XCTAssertNil(AgySwapUsageCache.shouldWriteCache(execResult: okExec, parsedBuckets: buckets, anInfo: an, postStatus: recPost))

        // gen 不符
        let genMismatchPost = sampleStatus(gen: 6, liveMatches: "oli", accounts: accounts)
        XCTAssertNil(AgySwapUsageCache.shouldWriteCache(execResult: okExec, parsedBuckets: buckets, anInfo: an, postStatus: genMismatchPost))

        // live_matches != A
        let liveMismatchPost = sampleStatus(active: "oli", gen: 5, liveMatches: "pettan", accounts: accounts)
        XCTAssertNil(AgySwapUsageCache.shouldWriteCache(execResult: okExec, parsedBuckets: buckets, anInfo: an, postStatus: liveMismatchPost))

        // A 不在 accounts 清單內
        let missingInAccounts = sampleStatus(active: "oli", gen: 5, liveMatches: "oli", accounts: [makeAccount("pettan"), makeAccount("tester-c")])
        XCTAssertNil(AgySwapUsageCache.shouldWriteCache(execResult: okExec, parsedBuckets: buckets, anInfo: an, postStatus: missingInAccounts))
    }

    // MARK: - 4. 快取 JSON 讀寫、0600 權限、損毀處理、an-file

    func testCacheWriteReadPermissionsAndCorruption() throws {
        let stateDir = try makeTempDir("cache")
        defer { try? FileManager.default.removeItem(at: stateDir) }

        let readAt = Date(timeIntervalSince1970: 1_800_000_000)
        let buckets = [
            UsageBucket(label: "Gemini 5 小時", used: 12, resets: "今天 22:00", resetAt: Date(timeIntervalSince1970: 1_800_010_000)),
            UsageBucket(label: "Argon 每週", used: 0, resets: "", resetAt: nil),
        ]
        XCTAssertTrue(AgySwapUsageCache.write(account: "oli", readAt: readAt, buckets: buckets, stateDir: stateDir))

        let fileURL = try XCTUnwrap(AgySwapUsageCache.cacheFileURL(account: "oli", stateDir: stateDir))
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(perms, 0o600)

        // 確認目錄沒有殘留 .tmp 檔
        let files = try FileManager.default.contentsOfDirectory(atPath: stateDir.path)
        XCTAssertEqual(files, ["usage-oli.json"])

        // 確認 JSON 格式：存 ISO8601 UTC 或 null，不存已格式化的「今天 22:00」
        let rawText = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(rawText.contains("今天"))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(rawText.utf8)) as? [String: Any])
        XCTAssertEqual(obj["account"] as? String, "oli")
        XCTAssertEqual(obj["read_at"] as? String, AgySwapUsageCache.formatISO8601UTC(readAt))
        let pools = try XCTUnwrap(obj["pools"] as? [[String: Any]])
        XCTAssertEqual(pools.count, 2)
        XCTAssertEqual(pools[0]["name"] as? String, "Gemini 5 小時")
        XCTAssertEqual(pools[0]["remaining_percent"] as? Int, 88)
        XCTAssertNotNil(pools[0]["reset_at"] as? String)
        XCTAssertTrue(pools[1]["reset_at"] is NSNull)

        // 讀回還原
        let loaded = try XCTUnwrap(AgySwapUsageCache.read(account: "oli", stateDir: stateDir))
        XCTAssertEqual(loaded.account, "oli")
        XCTAssertEqual(loaded.readAt, readAt)
        XCTAssertEqual(loaded.toUsageBuckets().map(\.remaining), [88, 100])
        XCTAssertEqual(loaded.toUsageBuckets()[0].resetAt, Date(timeIntervalSince1970: 1_800_010_000))
        XCTAssertNil(loaded.toUsageBuckets()[1].resetAt)

        // 損毀資料全回 nil（當「還沒讀過」）
        let corruptPayloads = [
            "not json",
            #"{"account":"pettan","read_at":"2026-11-22T00:00:00Z","pools":[{"name":"Gemini 5 小時","remaining_percent":90,"reset_at":null}]}"#, // account 與預期不符
            #"{"account":"oli","read_at":"not-a-date","pools":[{"name":"Gemini 5 小時","remaining_percent":90,"reset_at":null}]}"#,
            #"{"account":"oli","read_at":"2026-11-22T00:00:00Z","pools":[]}"#,
            #"{"account":"oli","read_at":"2026-11-22T00:00:00Z","pools":[{"name":"Gemini 5 小時","remaining_percent":101,"reset_at":null}]}"#,
            #"{"account":"oli","read_at":"2026-11-22T00:00:00Z","pools":[{"name":"Gemini 5 小時","remaining_percent":true,"reset_at":null}]}"#,
            #"{"account":"oli","read_at":"2026-11-22T00:00:00Z","pools":[{"name":"Gemini 5 小時","remaining_percent":50,"reset_at":"今天 22:00"}]}"#,
        ]
        for payload in corruptPayloads {
            XCTAssertNil(AgySwapUsageCache.parse(data: Data(payload.utf8), expectedAccount: "oli"), "應判為損毀：\(payload)")
        }
    }

    func testAnFileCreationPermissionsAndParsing() throws {
        let dir = try makeTempDir("anfile")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try XCTUnwrap(AgySwapUsageCache.createAnFile(in: dir))
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        XCTAssertEqual(AgySwapUsageCache.parseAnFile(content: "oli 12\n"), AgySwapAnFileInfo(account: "oli", gen: 12))
        XCTAssertEqual(AgySwapUsageCache.parseAnFile(content: "  pettan   0 \n"), AgySwapAnFileInfo(account: "pettan", gen: 0))
        XCTAssertNil(AgySwapUsageCache.parseAnFile(content: ""))
        XCTAssertNil(AgySwapUsageCache.parseAnFile(content: "oli"))
        XCTAssertNil(AgySwapUsageCache.parseAnFile(content: "oli notanumber"))
        XCTAssertNil(AgySwapUsageCache.parseAnFile(content: "oli 1 extra"))
    }

    // MARK: - 5. 結束碼判讀（143／137 與 weTerminated）

    func testExitCodeClassification() {
        func res(_ code: Int32, weTerminated: Bool, launched: Bool = true) -> AgySwapExecResult {
            AgySwapExecResult(exitCode: code, stdout: "", stderr: "", weTerminated: weTerminated, timedOut: false, launched: launched, argv: [])
        }
        XCTAssertEqual(AgySwapClient.classifyExit(res(0, weTerminated: false)), .ok)
        XCTAssertEqual(AgySwapClient.classifyExit(res(143, weTerminated: true)), .stoppedByUs)
        XCTAssertEqual(AgySwapClient.classifyExit(res(137, weTerminated: true)), .stoppedByUs)
        // 外部殺掉／OOM（!weTerminated）必須視為失敗，絕不當成「被我們停掉」
        XCTAssertEqual(AgySwapClient.classifyExit(res(143, weTerminated: false)), .failed(exitCode: 143))
        XCTAssertEqual(AgySwapClient.classifyExit(res(137, weTerminated: false)), .failed(exitCode: 137))
        // 子程序自己以非 0 離開
        XCTAssertEqual(AgySwapClient.classifyExit(res(1, weTerminated: false)), .failed(exitCode: 1))
        XCTAssertEqual(AgySwapClient.classifyExit(res(2, weTerminated: true)), .failed(exitCode: 2))
        XCTAssertEqual(AgySwapClient.classifyExit(res(0, weTerminated: false, launched: false)), .failed(exitCode: -1))
    }

    // MARK: - 6. posix_spawn 隔離群組、最小 env、只對 run 送 TERM 與寬限後群組 SIGKILL

    func testSpawnMinimalEnvironmentAndSeparateProcessGroup() throws {
        let dir = try makeTempDir("spawn-env")
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = try makeExecutableScript(in: dir, name: "inspect.py", body: #"""
        #!/usr/bin/python3
        import os
        print(f"PID={os.getpid()}")
        print(f"PGID={os.getpgrp()}")
        for k in sorted(os.environ):
            print(f"{k}={os.environ[k]}")
        """#)
        let env = AgySwapClient.minimalEnvironment(
            base: ["HOME": "/tmp/fakehome", "LANG": "zh_TW.UTF-8", "PATH": "/usr/bin:/bin", "SECRET_TOKEN": "should-not-leak"],
            homeDir: "/tmp/fallback"
        )
        XCTAssertEqual(Set(env.keys), Set(["HOME", "PATH", "LANG"]))
        XCTAssertNil(env["SECRET_TOKEN"])

        let handle = try XCTUnwrap(AgySwapProcessHandle.spawn(
            executable: script.path,
            arguments: [],
            workingDirectory: dir,
            environment: env,
            timeout: 5,
            killGrace: 1
        ))
        let result = handle.wait()
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.weTerminated)
        XCTAssertFalse(result.stdout.contains("SECRET_TOKEN"))
        XCTAssertTrue(result.stdout.contains("HOME=/tmp/fakehome"))
        XCTAssertTrue(result.stdout.contains("LANG=zh_TW.UTF-8"))

        let lines = Dictionary(uniqueKeysWithValues: result.stdout.split(separator: "\n").compactMap { line -> (String, String)? in
            guard let eq = line.firstIndex(of: "=") else { return nil }
            return (String(line[..<eq]), String(line[line.index(after: eq)...]))
        })
        let childPID = try XCTUnwrap(lines["PID"].flatMap(Int32.init))
        let childPGID = try XCTUnwrap(lines["PGID"].flatMap(Int32.init))
        XCTAssertEqual(childPID, childPGID, "子程序必須自成新行程群組（pgid == pid）")
        XCTAssertNotEqual(childPGID, Darwin.getpgrp(), "子程序群組不可等於 codenv 自己的群組")
    }

    func testTerminateSendsTermOnlyToRunThenSigkillsGroupAfterGrace() throws {
        let dir = try makeTempDir("spawn-kill")
        defer { try? FileManager.default.removeItem(at: dir) }
        let childPIDFile = dir.appendingPathComponent("grandchild.pid")
        let termLogFile = dir.appendingPathComponent("term.log")

        // 模擬忽略 SIGTERM 的 run + 同樣記錄 SIGTERM 的孫程序（用 Python 確保 SIGTERM handler 立即觸發）：
        // 1. run 收到 SIGTERM 立即記錄 run_term 但不退出；
        // 2. 孫程序不應該在 TERM 階段被送 TERM；
        // 3. killGrace (0.5s) 後 codenv 對 -pgid 送 SIGKILL，run 與孫程序都應立即消失。
        let grandchildScript = try makeExecutableScript(in: dir, name: "grandchild.py", body: """
        #!/usr/bin/python3
        import signal, time
        def on_term(signum, frame):
            with open("\(termLogFile.path)", "a", encoding="utf-8") as f:
                f.write("grandchild_term\\n")
                f.flush()
        signal.signal(signal.SIGTERM, on_term)
        while True:
            time.sleep(0.5)
        """)

        let script = try makeExecutableScript(in: dir, name: "stubborn-run.py", body: """
        #!/usr/bin/python3
        import os, signal, subprocess, time
        def on_term(signum, frame):
            with open("\(termLogFile.path)", "a", encoding="utf-8") as f:
                f.write("run_term\\n")
                f.flush()
        signal.signal(signal.SIGTERM, on_term)
        child = subprocess.Popen(["\(grandchildScript.path)"])
        tmp_pid = "\(childPIDFile.path).tmp"
        with open(tmp_pid, "w", encoding="utf-8") as f:
            f.write(str(child.pid) + "\\n")
            f.flush()
        os.replace(tmp_pid, "\(childPIDFile.path)")
        while True:
            time.sleep(0.5)
        """)

        let handle = try XCTUnwrap(AgySwapProcessHandle.spawn(
            executable: script.path,
            arguments: [],
            workingDirectory: dir,
            environment: AgySwapClient.minimalEnvironment(),
            timeout: 10,
            killGrace: 0.5
        ))

        // 等孫程序啟動並原子寫出完整 PID 檔
        let waitReady = Date().addingTimeInterval(3)
        var parsedGrandchildPID: Int32?
        while parsedGrandchildPID == nil && Date() < waitReady {
            if let text = try? String(contentsOf: childPIDFile, encoding: .utf8),
               let val = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                parsedGrandchildPID = val
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let grandchildPID = pid_t(try XCTUnwrap(parsedGrandchildPID))
        defer {
            if isProcessAlive(grandchildPID) { _ = Darwin.kill(grandchildPID, SIGKILL) }
        }
        // 稍等孫程序完成 signal handler 註冊
        Thread.sleep(forTimeInterval: 0.15)

        handle.terminate()
        let result = handle.wait()

        XCTAssertTrue(result.weTerminated)
        XCTAssertEqual(result.exitCode, 137)
        XCTAssertEqual(AgySwapClient.classifyExit(result), .stoppedByUs)

        // 確認只對 run 送了 TERM，沒對孫程序送 TERM
        let termLog = (try? String(contentsOf: termLogFile, encoding: .utf8)) ?? ""
        XCTAssertTrue(termLog.contains("run_term"))
        XCTAssertFalse(termLog.contains("grandchild_term"), "不應在 TERM 階段對群組送 SIGTERM")

        // 確認孫程序已被群組 SIGKILL 清理乾淨
        let deadline = Date().addingTimeInterval(2)
        while isProcessAlive(grandchildPID) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertFalse(isProcessAlive(grandchildPID), "killGrace 後孫程序應已被群組 SIGKILL 清乾淨")
    }

    func testExternalKillMarksWeTerminatedFalseAndClassifiesFailed() throws {
        let dir = try makeTempDir("ext-kill")
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = try makeExecutableScript(in: dir, name: "wait.sh", body: "#!/bin/sh\n/bin/sleep 30\n")
        let handle = try XCTUnwrap(AgySwapProcessHandle.spawn(
            executable: script.path,
            arguments: [],
            workingDirectory: dir,
            environment: AgySwapClient.minimalEnvironment(),
            timeout: 10,
            killGrace: 1
        ))
        let pid = handle.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
            _ = Darwin.kill(pid, SIGTERM)
        }
        let result = handle.wait()
        XCTAssertFalse(result.weTerminated)
        XCTAssertEqual(result.exitCode, 143)
        XCTAssertEqual(AgySwapClient.classifyExit(result), .failed(exitCode: 143))
    }

    func testClientRunCleansUpAnFileOnSuccessAndTimeout() throws {
        let dir = try makeTempDir("anfile-cleanup")
        defer { try? FileManager.default.removeItem(at: dir) }
        let recordedAnPathFile = dir.appendingPathComponent("an-path.txt")
        let fakeSwap = try makeExecutableScript(in: dir, name: "fake-swap.sh", body: """
        #!/bin/sh
        AN_FILE=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--an-file" ]; then
            AN_FILE="$2"
            shift 2
            continue
          fi
          shift
        done
        printf '%s' "$AN_FILE" > "\(recordedAnPathFile.path)"
        if [ -n "$AN_FILE" ]; then
          printf 'oli 9\\n' > "$AN_FILE"
        fi
        printf 'ok\\n'
        """)
        let config = AgySwapConfig.from(
            arguments: ["codenv", "--state-dir", dir.path, "--agy-swap-bin", fakeSwap.path, "--agy-usage-test"]
        )
        let call = AgySwapClient.run(config: config, agyArguments: ["-p=/usage"], workingDirectory: dir, timeout: 5)
        XCTAssertEqual(call.exec.exitCode, 0)
        XCTAssertEqual(call.anInfo, AgySwapAnFileInfo(account: "oli", gen: 9))
        let anPath = try String(contentsOf: recordedAnPathFile, encoding: .utf8)
        XCTAssertFalse(anPath.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: anPath), "run 成功結束後應刪除 an-file")

        // 逾時路徑：run 睡覺逾時被收掉後，an-file 一樣要刪乾淨
        let timeoutAnPathFile = dir.appendingPathComponent("an-path-timeout.txt")
        let slowSwap = try makeExecutableScript(in: dir, name: "slow-swap.sh", body: """
        #!/bin/sh
        AN_FILE=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--an-file" ]; then
            AN_FILE="$2"
            shift 2
            continue
          fi
          shift
        done
        printf '%s' "$AN_FILE" > "\(timeoutAnPathFile.path)"
        /bin/sleep 30
        """)
        let slowConfig = AgySwapConfig.from(
            arguments: ["codenv", "--state-dir", dir.path, "--agy-swap-bin", slowSwap.path, "--agy-usage-test",
                        "--agy-swap-kill-grace", "0.3"]
        )
        let slowCall = AgySwapClient.run(config: slowConfig, agyArguments: ["-p=/usage"], workingDirectory: dir, timeout: 1.0)
        XCTAssertTrue(slowCall.exec.weTerminated)
        XCTAssertTrue(slowCall.exec.timedOut)
        let timeoutAnPath = try String(contentsOf: timeoutAnPathFile, encoding: .utf8)
        XCTAssertFalse(timeoutAnPath.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: timeoutAnPath), "run 逾時後也應刪除 an-file")
    }

    // MARK: - 7. 顯示資料組裝（0／1／2／3／5 帳號、invalid、verify_failures=1、無快取、read_at vs mtime、切換防張冠李戴）

    func testFormatAgeTextBoundaries() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(AgySwapUsageCache.formatAgeText(readAt: now.addingTimeInterval(30), now: now), "剛剛")
        XCTAssertEqual(AgySwapUsageCache.formatAgeText(readAt: now, now: now), "剛剛")
        XCTAssertEqual(AgySwapUsageCache.formatAgeText(readAt: now.addingTimeInterval(-59), now: now), "剛剛")
        XCTAssertEqual(AgySwapUsageCache.formatAgeText(readAt: now.addingTimeInterval(-60), now: now), "1 分鐘前")
        XCTAssertEqual(AgySwapUsageCache.formatAgeText(readAt: now.addingTimeInterval(-180), now: now), "3 分鐘前")
        XCTAssertEqual(AgySwapUsageCache.formatAgeText(readAt: now.addingTimeInterval(-3600), now: now), "60 分鐘前")
        XCTAssertEqual(AgySwapUsageCache.formatAgeText(readAt: now.addingTimeInterval(-3601), now: now), "1 小時前")
        XCTAssertEqual(AgySwapUsageCache.formatAgeText(readAt: now.addingTimeInterval(-7200), now: now), "2 小時前")
    }

    func testBuildDisplayAccountsMultipleAccountsStatesAndReadAtOverMtime() throws {
        let stateDir = try makeTempDir("display")
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        // 5 個帳號（刻意不按順序，驗證會依帳號名排序）：
        // - alpha: cached（JSON read_at 是 3 分鐘前，但檔案 mtime 刻意設成 10 小時前 → 必須用 read_at 顯示「3 分鐘前」）
        // - beta: invalid=true 且磁碟有舊快取 → 只顯示「登入失效」，buckets 必為空
        // - gamma: verify_failures=1 且 invalid=false，有快取 → 不標失效，照常顯示快取
        // - oli: 現用且即時讀到 → state=live，isActive=true
        // - zeta: 無快取（損毀檔） → state=never，ageText=「還沒讀過」，buckets 必為空
        XCTAssertTrue(AgySwapUsageCache.write(account: "alpha", readAt: now.addingTimeInterval(-180), buckets: sampleBuckets(fivePct: 70), stateDir: stateDir))
        let alphaFile = try XCTUnwrap(AgySwapUsageCache.cacheFileURL(account: "alpha", stateDir: stateDir))
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-36_000)], ofItemAtPath: alphaFile.path)

        XCTAssertTrue(AgySwapUsageCache.write(account: "beta", readAt: now.addingTimeInterval(-120), buckets: sampleBuckets(fivePct: 80), stateDir: stateDir))
        XCTAssertTrue(AgySwapUsageCache.write(account: "gamma", readAt: now.addingTimeInterval(-7200), buckets: sampleBuckets(fivePct: 55), stateDir: stateDir))
        let zetaFile = try XCTUnwrap(AgySwapUsageCache.cacheFileURL(account: "zeta", stateDir: stateDir))
        try "corrupt-json".write(to: zetaFile, atomically: true, encoding: .utf8)

        let status = sampleStatus(
            active: "oli",
            gen: 10,
            liveMatches: "oli",
            accounts: [
                makeAccount("zeta"),
                makeAccount("oli"),
                makeAccount("beta", invalid: true, verifyFailures: 2),
                makeAccount("gamma", invalid: false, verifyFailures: 1),
                makeAccount("alpha"),
            ]
        )

        let displays = AgySwapUsageCache.buildDisplayAccounts(
            status: status,
            liveAccount: "oli",
            liveBuckets: sampleBuckets(fivePct: 95),
            liveReadAt: now,
            cacheLoader: { AgySwapUsageCache.read(account: $0, stateDir: stateDir) },
            now: now
        )

        XCTAssertEqual(displays.map(\.name), ["alpha", "beta", "gamma", "oli", "zeta"])

        // alpha: 用 JSON read_at（3 分鐘前），不是 mtime（10 小時前）
        XCTAssertEqual(displays[0].state, .cached)
        XCTAssertEqual(displays[0].ageText, "3 分鐘前")
        XCTAssertEqual(displays[0].buckets.first?.remaining, 70)
        XCTAssertFalse(displays[0].isActive)

        // beta: invalid=true → 即使有舊快取也不混舊百分比
        XCTAssertEqual(displays[1].state, .invalid)
        XCTAssertEqual(displays[1].ageText, "登入失效")
        XCTAssertTrue(displays[1].buckets.isEmpty)
        XCTAssertNil(displays[1].readAt)

        // gamma: verify_failures=1 不標失效
        XCTAssertEqual(displays[2].state, .cached)
        XCTAssertEqual(displays[2].ageText, "2 小時前")
        XCTAssertEqual(displays[2].buckets.first?.remaining, 55)

        // oli: 現用即時
        XCTAssertEqual(displays[3].state, .live)
        XCTAssertTrue(displays[3].isActive)
        XCTAssertEqual(displays[3].ageText, "剛剛")
        XCTAssertEqual(displays[3].buckets.first?.remaining, 95)

        // zeta: 損毀快取 → 還沒讀過
        XCTAssertEqual(displays[4].state, .never)
        XCTAssertEqual(displays[4].ageText, "還沒讀過")
        XCTAssertTrue(displays[4].buckets.isEmpty)
    }

    func testSwitchToNewActiveWithoutLiveOrCacheDoesNotShowPreviousAccountNumbers() throws {
        let stateDir = try makeTempDir("switch-clean")
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        // 只有舊帳號 oli 有快取；剛切換到 pettan，本輪沒有即時資料（liveAccount = nil）
        XCTAssertTrue(AgySwapUsageCache.write(account: "oli", readAt: now.addingTimeInterval(-300), buckets: sampleBuckets(fivePct: 88), stateDir: stateDir))

        let status = sampleStatus(
            active: "pettan",
            gen: 11,
            switching: false,
            liveMatches: "pettan",
            accounts: [makeAccount("oli"), makeAccount("pettan")]
        )

        let displays = AgySwapUsageCache.buildDisplayAccounts(
            status: status,
            liveAccount: nil,
            liveBuckets: nil,
            liveReadAt: nil,
            cacheLoader: { AgySwapUsageCache.read(account: $0, stateDir: stateDir) },
            now: now
        )

        XCTAssertEqual(displays.map(\.name), ["oli", "pettan"])
        // oli 顯示自己的舊快取
        XCTAssertEqual(displays[0].state, .cached)
        XCTAssertFalse(displays[0].isActive)
        XCTAssertEqual(displays[0].buckets.first?.remaining, 88)
        // 新現用 pettan 沒有快取也沒有即時資料 → 必須是 never + 空 buckets，絕不張冠李戴成 88%
        XCTAssertEqual(displays[1].state, .never)
        XCTAssertTrue(displays[1].isActive)
        XCTAssertEqual(displays[1].ageText, "還沒讀過")
        XCTAssertTrue(displays[1].buckets.isEmpty)
    }

    func testBuildDisplayAccountsZeroOneTwoThreeCounts() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let zero = AgySwapUsageCache.buildDisplayAccounts(
            status: sampleStatus(active: nil, liveMatches: nil, accounts: []),
            liveAccount: nil, liveBuckets: nil, liveReadAt: nil, cacheLoader: { _ in nil }, now: now
        )
        XCTAssertEqual(zero.count, 0)

        let one = AgySwapUsageCache.buildDisplayAccounts(
            status: sampleStatus(active: "oli", liveMatches: "oli", accounts: [makeAccount("oli")]),
            liveAccount: "oli", liveBuckets: sampleBuckets(), liveReadAt: now, cacheLoader: { _ in nil }, now: now
        )
        XCTAssertEqual(one.count, 1)
        XCTAssertTrue(one[0].isActive)

        let three = AgySwapUsageCache.buildDisplayAccounts(
            status: sampleStatus(active: "pettan", liveMatches: "pettan", accounts: [makeAccount("tester-c"), makeAccount("oli"), makeAccount("pettan")]),
            liveAccount: "pettan", liveBuckets: sampleBuckets(), liveReadAt: now, cacheLoader: { _ in nil }, now: now
        )
        XCTAssertEqual(three.map(\.name), ["oli", "pettan", "tester-c"])
        XCTAssertEqual(three.filter(\.isActive).map(\.name), ["pettan"])
    }

    func testUsageCardDumpPayloadSchemaPanelGlanceAndAgy2Visibility() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let monitor = UsageMonitor.makeForUnitTest()
        monitor.buckets = [UsageBucket(label: "5 小時", used: 30, resets: "12:00", resetAt: now.addingTimeInterval(3600))]
        monitor.codexBuckets = [UsageBucket(label: "5 小時", used: 10, resets: "12:00", resetAt: now.addingTimeInterval(3600))]
        monitor.updated = now
        monitor.error = nil
        monitor.loading = false
        monitor.agyLoading = false

        // 1) Swap 模式（3 帳號）：agy2Visible 必為 false，fullPage.accounts 含 3 帳號，panelText/glanceText 只顯示現用＋「另有 2 個帳號」
        monitor.agySwapMode = true
        monitor.agy2Status = .down // 即使曾設過值，swap 模式 dump 仍須回報 agy2Visible=false
        monitor.lastAgyOutcome = .ok
        monitor.agyActiveAccount = "oli"
        monitor.agyBuckets = sampleBuckets(fivePct: 92, weekPct: 84, argonPct: 100)
        monitor.agySwapAccounts = [
            AgySwapAccountDisplay(name: "oli", isActive: true, state: .live, readAt: now, ageText: "剛剛", buckets: monitor.agyBuckets),
            AgySwapAccountDisplay(name: "pettan", isActive: false, state: .cached, readAt: now.addingTimeInterval(-300), ageText: "5 分鐘前", buckets: sampleBuckets(fivePct: 40, weekPct: 50, argonPct: 60)),
            AgySwapAccountDisplay(name: "tester-c", isActive: false, state: .invalid, readAt: nil, ageText: "登入失效", buckets: []),
        ]

        let swapPayload = monitor.buildUsageCardDumpPayload()
        XCTAssertEqual(swapPayload["mode"] as? String, "swap")
        XCTAssertTrue(swapPayload["error"] is NSNull)
        XCTAssertEqual(swapPayload["updatedAt"] as? String, AgySwapUsageCache.formatISO8601UTC(now))
        XCTAssertEqual(swapPayload["mainLoading"] as? Bool, false)
        XCTAssertEqual(swapPayload["agyLoading"] as? Bool, false)
        XCTAssertEqual(swapPayload["otherSourcesShown"] as? [String], ["claude", "codex"])
        XCTAssertEqual(swapPayload["agy2Visible"] as? Bool, false)
        XCTAssertEqual(swapPayload["lastAgyOutcome"] as? String, "ok")

        let fullPage = try XCTUnwrap(swapPayload["fullPage"] as? [String: Any])
        let accounts = try XCTUnwrap(fullPage["accounts"] as? [[String: Any]])
        XCTAssertEqual(accounts.count, 3)
        XCTAssertEqual(accounts.map { $0["name"] as? String }, ["oli", "pettan", "tester-c"])
        XCTAssertEqual(accounts[0]["state"] as? String, "live")
        XCTAssertEqual(accounts[1]["ageText"] as? String, "5 分鐘前")
        XCTAssertEqual(accounts[2]["state"] as? String, "invalid")
        XCTAssertEqual((accounts[2]["rows"] as? [[String: Any]])?.count, 0)

        let panelText = try XCTUnwrap(swapPayload["panelText"] as? String)
        XCTAssertTrue(panelText.contains("oli"))
        XCTAssertTrue(panelText.contains("92%"))
        XCTAssertTrue(panelText.contains("另有 2 個帳號"))
        XCTAssertFalse(panelText.contains("pettan"))
        XCTAssertFalse(panelText.contains("40%"))

        let glanceText = try XCTUnwrap(swapPayload["glanceText"] as? String)
        XCTAssertTrue(glanceText.contains("oli"))
        XCTAssertTrue(glanceText.contains("92%"))
        XCTAssertTrue(glanceText.contains("另有 2 個帳號"))
        XCTAssertFalse(glanceText.contains("pettan"))

        // 2) Legacy 模式：accounts 只有一個（現用），agy2Visible 照 agy2Status
        monitor.agySwapMode = false
        monitor.agySwapAccounts = []
        monitor.agy2Status = .down
        let legacyPayload = monitor.buildUsageCardDumpPayload()
        XCTAssertEqual(legacyPayload["mode"] as? String, "legacy")
        XCTAssertEqual(legacyPayload["agy2Visible"] as? Bool, true)
        let legacyAccounts = try XCTUnwrap((legacyPayload["fullPage"] as? [String: Any])?["accounts"] as? [[String: Any]])
        XCTAssertEqual(legacyAccounts.count, 1)
    }

    // MARK: - 修正單 fix1 對應單元測試（第 1～11 項）

    /// fix1 第 1 項：子程序輸出上限 1 MiB（stdout／stderr 各自上限、排空不卡死不超時）＋ fetchStatus 截斷視為失敗。
    func testSubprocessOutputTruncatedAtOneMiBWithoutDeadlockOrTimeout() throws {
        let dir = try makeTempDir("output-cap")
        defer { try? FileManager.default.removeItem(at: dir) }

        let noisyScript = try makeExecutableScript(in: dir, name: "noisy.py", body: #"""
        #!/usr/bin/python3
        import sys
        chunk_out = "A" * 65536
        chunk_err = "E" * 65536
        for _ in range(80):  # 80 * 64 KiB = 5 MiB each
            sys.stdout.write(chunk_out)
            sys.stderr.write(chunk_err)
        sys.stdout.flush()
        sys.stderr.flush()
        """#)

        let t0 = Date()
        let handle = try XCTUnwrap(AgySwapProcessHandle.spawn(
            executable: noisyScript.path,
            arguments: [],
            workingDirectory: dir,
            environment: AgySwapClient.minimalEnvironment(),
            timeout: 10,
            killGrace: 1
        ))
        let result = handle.wait()
        let elapsed = Date().timeIntervalSince(t0)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertFalse(result.weTerminated)
        XCTAssertTrue(result.outputTruncated)
        XCTAssertLessThanOrEqual(result.stdout.utf8.count, AgySwapProcessHandle.maxStreamBytes)
        XCTAssertLessThanOrEqual(result.stderr.utf8.count, AgySwapProcessHandle.maxStreamBytes)
        XCTAssertEqual(result.stdout.utf8.count, AgySwapProcessHandle.maxStreamBytes)
        XCTAssertEqual(result.stderr.utf8.count, AgySwapProcessHandle.maxStreamBytes)
        XCTAssertLessThan(elapsed, 8.0, "排空 5 MiB 管線不應卡死或超時")

        // fetchStatus 輸出超過 1 MiB 被截斷 → 視為 status 失敗
        let hugeStatus = try makeExecutableScript(in: dir, name: "huge-status.py", body: #"""
        #!/usr/bin/python3
        import sys
        pad = " " * (2 * 1024 * 1024)
        sys.stdout.write('{"active":"oli","gen":1,"switching":false,"live_matches":"oli","accounts":[{"name":"oli"},{"name":"pettan"}]}' + pad)
        sys.stdout.flush()
        """#)
        let cfg = AgySwapConfig.from(
            arguments: ["codenv", "--state-dir", dir.path, "--agy-swap-bin", hugeStatus.path, "--agy-usage-test"]
        )
        let statusRes = AgySwapClient.fetchStatus(config: cfg)
        guard case .failed(let reason) = statusRes else {
            return XCTFail("截斷的 status JSON 必須視為失敗，實際：\(statusRes)")
        }
        XCTAssertTrue(reason.contains("截斷"))
    }

    /// fix1 第 2 項（情境 A）：子程序已結束但同群組孫程序還活著 → 不標 weTerminated／timedOut，孫程序被群組清理且不單獨對 pid 送 SIGTERM／SIGKILL。
    func testChildExitedWithAliveGrandchildDoesNotMarkWeTerminatedAndCleansGroup() throws {
        let dir = try makeTempDir("exited-grandchild")
        defer { try? FileManager.default.removeItem(at: dir) }
        let grandchildPIDFile = dir.appendingPathComponent("gc.pid")

        let script = try makeExecutableScript(in: dir, name: "spawn-orphan.py", body: """
        #!/usr/bin/python3
        import os, subprocess, sys
        # 孫程序繼承 stdout（讓父程序在 wait 階段仍停留於 drain）且屬於同一行程群組
        p = subprocess.Popen(["/bin/sleep", "30"])
        tmp_pid = "\(grandchildPIDFile.path).tmp"
        with open(tmp_pid, "w", encoding="utf-8") as f:
            f.write(str(p.pid) + "\\n")
            f.flush()
        os.replace(tmp_pid, "\(grandchildPIDFile.path)")
        sys.stdout.write("child-done\\n")
        sys.stdout.flush()
        sys.exit(0)
        """)

        let recLock = NSLock()
        var recordedKills: [(pid_t, Int32)] = []
        let ops = AgySwapProcessHandle.SignalOps(
            kill: { target, sig in
                recLock.lock()
                recordedKills.append((target, sig))
                recLock.unlock()
                return Darwin.kill(target, sig)
            },
            killpg: { pgrp, sig in Darwin.killpg(pgrp, sig) }
        )

        let handle = try XCTUnwrap(AgySwapProcessHandle.spawn(
            executable: script.path,
            arguments: [],
            workingDirectory: dir,
            environment: AgySwapClient.minimalEnvironment(),
            timeout: 10,
            killGrace: 0.5,
            signalOps: ops
        ))
        let childPID = handle.processIdentifier

        // 等子程序原子寫出孫程序 PID 且主子程序本身已結束並收屍
        let readyDeadline = Date().addingTimeInterval(3)
        var parsedGrandchildPID: Int32?
        while (parsedGrandchildPID == nil || !handle.hasExitedForTest) && Date() < readyDeadline {
            if parsedGrandchildPID == nil,
               let text = try? String(contentsOf: grandchildPIDFile, encoding: .utf8),
               let val = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                parsedGrandchildPID = val
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(handle.hasExitedForTest, "主子程序應已結束並收屍")
        let grandchildPID = pid_t(try XCTUnwrap(parsedGrandchildPID))
        defer {
            if isProcessAlive(grandchildPID) { _ = Darwin.kill(grandchildPID, SIGKILL) }
        }
        XCTAssertTrue(isProcessAlive(grandchildPID), "呼叫終止前孫程序應仍活著")

        // 主子程序已結束後才呼叫 terminate（或逾時觸發）→ 不應標 weTerminated，但應清理殘留群組
        handle.terminate()
        let result = handle.wait()

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.weTerminated, "子程序已自行結束時絕不可標為 weTerminated")
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(AgySwapClient.classifyExit(result), .ok)

        let deathDeadline = Date().addingTimeInterval(2)
        while isProcessAlive(grandchildPID) && Date() < deathDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertFalse(isProcessAlive(grandchildPID), "殘留孫程序應已被群組 SIGKILL 清乾淨")

        recLock.lock()
        let kills = recordedKills
        recLock.unlock()
        XCTAssertTrue(kills.contains(where: { $0.0 == -childPID && $0.1 == SIGKILL }), "應對 -pgid 送 SIGKILL，實際：\(kills)")
        XCTAssertFalse(kills.contains(where: { $0.0 == childPID && $0.1 == SIGTERM }), "已結束的 pid 不可再送 SIGTERM，實際：\(kills)")
        XCTAssertFalse(kills.contains(where: { $0.0 == childPID && $0.1 == SIGKILL }), "絕不可單獨對 pid 送 SIGKILL，實際：\(kills)")
    }

    /// fix1 第 2 項（情境 B）：已收屍後逾時／強殺計時器觸發 → 不送任何訊號；且任何情況下都不單獨對 pid 送 SIGKILL。
    func testLateTimeoutAfterReapSendsZeroSignalsAndNeverSingleSigkillsPid() throws {
        let dir = try makeTempDir("reaped-no-signal")
        defer { try? FileManager.default.removeItem(at: dir) }

        let fastScript = try makeExecutableScript(in: dir, name: "fast.sh", body: "#!/bin/sh\nexit 0\n")
        let recLock = NSLock()
        var killsAfterReap: [(pid_t, Int32)] = []
        var killpgsAfterReap: [(pid_t, Int32)] = []
        var recording = false
        let ops = AgySwapProcessHandle.SignalOps(
            kill: { target, sig in
                recLock.lock()
                if recording { killsAfterReap.append((target, sig)) }
                recLock.unlock()
                return Darwin.kill(target, sig)
            },
            killpg: { pgrp, sig in
                recLock.lock()
                if recording { killpgsAfterReap.append((pgrp, sig)) }
                recLock.unlock()
                return Darwin.killpg(pgrp, sig)
            }
        )

        let handle = try XCTUnwrap(AgySwapProcessHandle.spawn(
            executable: fastScript.path,
            arguments: [],
            workingDirectory: dir,
            environment: AgySwapClient.minimalEnvironment(),
            timeout: 10,
            killGrace: 1,
            signalOps: ops
        ))
        let res = handle.wait()
        XCTAssertEqual(res.exitCode, 0)
        XCTAssertTrue(handle.hasExitedForTest)

        recLock.lock()
        recording = true
        recLock.unlock()

        handle.triggerTimeoutForTest()
        handle.triggerForceKillForTest()

        recLock.lock()
        let lateKills = killsAfterReap
        let lateKillpgs = killpgsAfterReap
        recLock.unlock()
        XCTAssertTrue(lateKills.isEmpty, "已收屍後不應呼叫任何 kill，實際：\(lateKills)")
        XCTAssertTrue(lateKillpgs.isEmpty, "已收屍且群組已確認清空後不應再呼叫 killpg，實際：\(lateKillpgs)")

        // 另驗證忽略 SIGTERM 的子程序：寬限後只對 -pid 送 SIGKILL，絕不單獨 kill(pid, SIGKILL)
        let ready2File = dir.appendingPathComponent("ignore-ready.flag")
        let ignoreScript = try makeExecutableScript(in: dir, name: "ignore-term.py", body: """
        #!/usr/bin/python3
        import signal, time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        with open("\(ready2File.path)", "w", encoding="utf-8") as f:
            f.write("ready\\n")
            f.flush()
        time.sleep(30)
        """)
        var stubbornKills: [(pid_t, Int32)] = []
        let ops2 = AgySwapProcessHandle.SignalOps(
            kill: { target, sig in
                recLock.lock()
                stubbornKills.append((target, sig))
                recLock.unlock()
                return Darwin.kill(target, sig)
            },
            killpg: { pgrp, sig in Darwin.killpg(pgrp, sig) }
        )
        let handle2 = try XCTUnwrap(AgySwapProcessHandle.spawn(
            executable: ignoreScript.path,
            arguments: [],
            workingDirectory: dir,
            environment: AgySwapClient.minimalEnvironment(),
            timeout: 10,
            killGrace: 0.3,
            signalOps: ops2
        ))
        let pid2 = handle2.processIdentifier
        let ready2Deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: ready2File.path) && Date() < ready2Deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready2File.path), "ignore-term.py 應先完成 SIG_IGN 註冊")
        handle2.terminate()
        let res2 = handle2.wait()
        XCTAssertTrue(res2.weTerminated)
        XCTAssertEqual(res2.exitCode, 137)
        recLock.lock()
        let gotKills2 = stubbornKills
        recLock.unlock()
        XCTAssertTrue(gotKills2.contains(where: { $0.0 == pid2 && $0.1 == SIGTERM }))
        XCTAssertTrue(gotKills2.contains(where: { $0.0 == -pid2 && $0.1 == SIGKILL }))
        XCTAssertFalse(gotKills2.contains(where: { $0.0 == pid2 && $0.1 == SIGKILL }), "總規格 4.2：絕不單獨對 pid 送 SIGKILL，實際：\(gotKills2)")
    }

    /// fix1 第 3 項：背景工具（NextGuess、SprintCheck）遇 status.switching == true 略過本次，不呼叫 `run`。
    func testBackgroundToolsSkipWhenStatusSwitching() throws {
        let dir = try makeTempDir("bg-switching")
        defer { try? FileManager.default.removeItem(at: dir) }
        let callsLog = dir.appendingPathComponent("calls.log")

        let fakeSwap = try makeExecutableScript(in: dir, name: "fake-agy-swap", body: """
        #!/usr/bin/python3
        import json, sys
        sub = sys.argv[1] if len(sys.argv) > 1 else ""
        with open("\(callsLog.path)", "a", encoding="utf-8") as f:
            f.write(sub + "\\n")
        if sub == "status":
            print(json.dumps({
                "active": "alpha",
                "gen": 3,
                "switching": True,
                "live_matches": "alpha",
                "recovery_pending": False,
                "accounts": [{"name": "alpha"}, {"name": "bravo"}]
            }))
            sys.exit(0)
        sys.exit(0)
        """)

        let config = AgySwapConfig.from(
            arguments: ["codenv", "--state-dir", dir.path, "--agy-swap-bin", fakeSwap.path]
        )

        // 1) NextGuess
        let nextExp = expectation(description: "NextGuess switching skipped")
        var nextOutcome: AgyBackgroundProbeOutcome?
        var nextSuggestionCalled = false
        _ = NextGuess.probeRunHydrogen(
            user: "hello",
            assistant: "world",
            swapConfig: config,
            tracker: AgySwapModeTracker(),
            ignoreAgyEnabledPref: true,
            onFinish: { outcome in
                nextOutcome = outcome
                nextExp.fulfill()
            },
            done: { _ in nextSuggestionCalled = true }
        )
        wait(for: [nextExp], timeout: 5)
        XCTAssertEqual(nextOutcome?.launched, false)
        XCTAssertEqual(nextOutcome?.mode, "swap")
        XCTAssertFalse(nextSuggestionCalled)

        // 2) SprintCheck
        let sprintProbeExp = expectation(description: "SprintCheck probe switching skipped")
        let sprintDoneExp = expectation(description: "SprintCheck done switching skipped")
        var sprintOutcome: AgyBackgroundProbeOutcome?
        var sprintVerdict: SprintCheck.Verdict?
        var sprintReason = ""
        SprintCheck.probeAgyJudge(
            last: "已完成",
            tools: ["Read"],
            swapConfig: config,
            tracker: AgySwapModeTracker(),
            ignoreAgyEnabledPref: true,
            onFinish: { outcome in
                sprintOutcome = outcome
                sprintProbeExp.fulfill()
            },
            done: { verdict, reason in
                sprintVerdict = verdict
                sprintReason = reason
                sprintDoneExp.fulfill()
            }
        )
        wait(for: [sprintProbeExp, sprintDoneExp], timeout: 5)
        XCTAssertEqual(sprintOutcome?.launched, false)
        XCTAssertEqual(sprintOutcome?.mode, "swap")
        XCTAssertNil(sprintVerdict)
        XCTAssertTrue(sprintReason.contains("略過"))

        let calls = try String(contentsOf: callsLog, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(calls.filter { $0 == "status" }.count, 2)
        XCTAssertEqual(calls.filter { $0 == "run" }.count, 0, "switching=true 時 run 呼叫數必為 0，實際：\(calls)")
    }

    /// fix1 第 4 項：NextGuess legacy 路徑 stop closure 在啟動前呼叫不啟動、啟動後呼叫正確 terminate。
    func testNextGuessLegacyStopBeforeAndAfterLaunch() throws {
        let dir = try makeTempDir("next-legacy-stop")
        defer { try? FileManager.default.removeItem(at: dir) }
        let launchCountFile = dir.appendingPathComponent("launches.log")
        let readyFile = dir.appendingPathComponent("ready.flag")

        let fakeAgy = try makeExecutableScript(in: dir, name: "fake-agy.py", body: """
        #!/usr/bin/python3
        import time
        with open("\(launchCountFile.path)", "a", encoding="utf-8") as f:
            f.write("launched\\n")
        with open("\(readyFile.path)", "w", encoding="utf-8") as f:
            f.write("ok\\n")
        time.sleep(30)
        """)

        let legacyConfig = AgySwapConfig.from(
            arguments: ["codenv", "--state-dir", dir.path]
        )

        // 1) stop 在啟動前呼叫 → 不可啟動子程序
        let enteredHookSem = DispatchSemaphore(value: 0)
        let releaseHookSem = DispatchSemaphore(value: 0)
        let beforeExp = expectation(description: "legacy stop before launch")
        var beforeOutcome: AgyBackgroundProbeOutcome?
        let stopBefore = NextGuess.probeRunHydrogen(
            user: "hi",
            assistant: "there",
            swapConfig: legacyConfig,
            tracker: AgySwapModeTracker(),
            ignoreAgyEnabledPref: true,
            legacyExecutableOverride: fakeAgy.path,
            legacyOnlineOverride: true,
            beforeLegacyLaunchHook: {
                enteredHookSem.signal()
                _ = releaseHookSem.wait(timeout: .now() + 5)
            },
            onFinish: { outcome in
                beforeOutcome = outcome
                beforeExp.fulfill()
            }
        )
        XCTAssertEqual(enteredHookSem.wait(timeout: .now() + 3), .success)
        stopBefore?()
        releaseHookSem.signal()
        wait(for: [beforeExp], timeout: 5)
        XCTAssertEqual(beforeOutcome?.launched, false)
        XCTAssertEqual(beforeOutcome?.stoppedByUs, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: launchCountFile.path), "啟動前 stop 不可真的啟動子程序")

        // 2) stop 在啟動後呼叫 → 正確 terminate 並快速結束
        let afterExp = expectation(description: "legacy stop after launch")
        var afterOutcome: AgyBackgroundProbeOutcome?
        let t0 = Date()
        let stopAfter = NextGuess.probeRunHydrogen(
            user: "hi",
            assistant: "there",
            swapConfig: legacyConfig,
            tracker: AgySwapModeTracker(),
            ignoreAgyEnabledPref: true,
            legacyExecutableOverride: fakeAgy.path,
            legacyOnlineOverride: true,
            onFinish: { outcome in
                afterOutcome = outcome
                afterExp.fulfill()
            }
        )
        let waitReady = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: readyFile.path) && Date() < waitReady {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: readyFile.path))
        stopAfter?()
        wait(for: [afterExp], timeout: 5)
        XCTAssertEqual(afterOutcome?.launched, true)
        XCTAssertEqual(afterOutcome?.stoppedByUs, true)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 4.0)
    }

    /// fix1 第 5 項：舊 agy 分支還在跑時第二輪主流程完成且全無資料 → 舊 agy 分支回來仍用本輪狀態調和出「查不到用量」。
    func testLateAgyBranchReconcilesCurrentRoundErrorAndUpdated() {
        let monitor = UsageMonitor.makeForUnitTest()

        // 第 1 輪開始（開啟 agy 分支，agyLoading = true），第 1 輪主流程拿回 Claude
        let cycle1 = monitor.beginRefreshCycleOnMain(markAgyLoadingIfIdle: true)
        XCTAssertTrue(monitor.agyLoading)
        monitor.completeMainCycleOnMain(cycle: cycle1, gotClaude: true, gotOther: false)
        XCTAssertNil(monitor.error)

        // agy 還在跑時開第 2 輪刷新，第 2 輪主流程完成且全無資料
        let cycle2 = monitor.beginRefreshCycleOnMain(markAgyLoadingIfIdle: true)
        XCTAssertNotEqual(cycle1, cycle2)
        XCTAssertTrue(monitor.agyLoading)
        monitor.completeMainCycleOnMain(cycle: cycle2, gotClaude: false, gotOther: false)
        // agy 尚未回來前先不誤報
        XCTAssertNil(monitor.error)

        // 第 1 輪的 agy 分支終於結束且沒拿到資料 → 必須調和目前輪，得出「查不到用量」
        monitor.finishAgyRefreshBranchOnMain(gotData: false)
        XCTAssertFalse(monitor.agyLoading)
        XCTAssertEqual(monitor.error, "查不到用量")

        // 另一支路：舊 agy 分支回來有資料 → 調和成「Claude 用量這次查不到」並更新 updated
        let monitor2 = UsageMonitor.makeForUnitTest()
        _ = monitor2.beginRefreshCycleOnMain(markAgyLoadingIfIdle: true)
        let cycleB = monitor2.beginRefreshCycleOnMain(markAgyLoadingIfIdle: true)
        monitor2.completeMainCycleOnMain(cycle: cycleB, gotClaude: false, gotOther: false)
        XCTAssertNil(monitor2.updated)
        monitor2.finishAgyRefreshBranchOnMain(gotData: true)
        XCTAssertEqual(monitor2.error, "Claude 用量這次查不到")
        XCTAssertNotNil(monitor2.updated)
    }

    /// fix1 第 6 項：skipRound 不把舊快取當本輪有資料 → status 失敗＋其他來源全無資料時 error=="查不到用量" 且 updated 不變。
    func testSkipRoundDoesNotCountOldCacheAsGotDataAndKeepsUpdatedUnchanged() throws {
        let dir = try makeTempDir("skip-round-error")
        defer { try? FileManager.default.removeItem(at: dir) }
        let stateDir = dir.appendingPathComponent("state", isDirectory: true)
        let cacheDir = stateDir.appendingPathComponent("agy-swap/state", isDirectory: true)
        let oldCacheTime = Date().addingTimeInterval(-1800)
        XCTAssertTrue(AgySwapUsageCache.write(account: "alpha", readAt: oldCacheTime, buckets: sampleBuckets(fivePct: 55, weekPct: 54, argonPct: 53), stateDir: cacheDir))

        let failingSwap = try makeExecutableScript(in: dir, name: "fail-swap.sh", body: "#!/bin/sh\nexit 1\n")
        let config = AgySwapConfig.from(
            arguments: ["codenv", "--state-dir", stateDir.path, "--agy-swap-bin", failingSwap.path, "--agy-usage-test"]
        )

        let monitor = UsageMonitor.makeForUnitTest()
        let oldUpdated = Date(timeIntervalSince1970: 1_700_000_000)
        monitor.updated = oldUpdated
        monitor.agySwapMode = true
        monitor.agySwapAccounts = [
            AgySwapAccountDisplay(name: "alpha", isActive: true, state: .cached, readAt: oldCacheTime, ageText: "30 分鐘前", buckets: sampleBuckets(fivePct: 55, weekPct: 54, argonPct: 53)),
            AgySwapAccountDisplay(name: "bravo", isActive: false, state: .never, readAt: nil, ageText: "還沒讀過", buckets: []),
        ]

        let cycle = monitor.beginRefreshCycleOnMain()
        let exp = expectation(description: "skipRound finished")
        monitor.runAgyRefreshBranchForTest(config: config) {
            exp.fulfill()
        }
        monitor.completeMainCycleOnMain(cycle: cycle, gotClaude: false, gotOther: false)
        wait(for: [exp], timeout: 5)

        XCTAssertEqual(monitor.lastAgyOutcome, .skipped)
        XCTAssertEqual(monitor.error, "查不到用量", "skipRound 不可把舊快取算成本輪讀到資料而報成「Claude 用量這次查不到」")
        XCTAssertEqual(monitor.updated, oldUpdated, "skipRound 不可刷新 updated")
    }

    /// fix1 第 7 項：快取寫入失敗不標 ok、不設 live（顯示改用磁碟舊快取）；write 回 0 視為失敗不空轉。
    func testCacheWriteFailureMarksFailedKeepsDiskCacheAndZeroByteWriteFails() throws {
        // 1) Darwin.write 回 0 時立刻視為失敗，不可無限迴圈空轉
        var calls = 0
        let ok = AgySwapUsageCache.writeAllBytes(Data("payload".utf8)) { _, _ in
            calls += 1
            return 0
        }
        XCTAssertFalse(ok)
        XCTAssertEqual(calls, 1)

        // 2) 真實 agy 分支：快取目錄唯讀導致寫入失敗 → outcome=.failed、顯示仍為磁碟舊快取（55/54/53、state=cached）
        let dir = try makeTempDir("cache-write-fail")
        defer {
            let cacheDir = dir.appendingPathComponent("state/agy-swap/state", isDirectory: true)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cacheDir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let stateDir = dir.appendingPathComponent("state", isDirectory: true)
        let cacheDir = stateDir.appendingPathComponent("agy-swap/state", isDirectory: true)
        let oldReadAt = Date().addingTimeInterval(-1800)
        let oldBuckets = [
            UsageBucket(label: "Gemini 5 小時", used: 45, resets: "", resetAt: Date().addingTimeInterval(3600)),
            UsageBucket(label: "Gemini 每週", used: 46, resets: "", resetAt: Date().addingTimeInterval(7200)),
            UsageBucket(label: "Argon 每週", used: 47, resets: "", resetAt: Date().addingTimeInterval(10800)),
        ]
        XCTAssertTrue(AgySwapUsageCache.write(account: "alpha", readAt: oldReadAt, buckets: oldBuckets, stateDir: cacheDir))
        // 把快取目錄設為唯讀（0o500）：可讀舊檔，但無法新建 .tmp 檔 → AgySwapUsageCache.write 回 false
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: cacheDir.path)

        let fakeSwap = try makeExecutableScript(in: dir, name: "ok-swap.py", body: #"""
        #!/usr/bin/python3
        import json, sys
        sub = sys.argv[1] if len(sys.argv) > 1 else ""
        if sub == "status":
            print(json.dumps({
                "active": "alpha",
                "gen": 3,
                "switching": False,
                "live_matches": "alpha",
                "recovery_pending": False,
                "accounts": [{"name": "alpha"}, {"name": "bravo"}]
            }))
            sys.exit(0)
        if sub == "run":
            if "--an-file" in sys.argv:
                an = sys.argv[sys.argv.index("--an-file") + 1]
                with open(an, "w", encoding="utf-8") as f:
                    f.write("alpha 3\n")
            print("Gemini Models\tFive Hour Limit\t71%\t2026-11-23T00:00:00Z")
            print("Gemini Models\tWeekly Limit\t72%\t2026-11-29T00:00:00Z")
            sys.exit(0)
        """#)
        let config = AgySwapConfig.from(
            arguments: ["codenv", "--state-dir", stateDir.path, "--agy-swap-bin", fakeSwap.path, "--agy-usage-test"]
        )

        let monitor = UsageMonitor.makeForUnitTest()
        let exp = expectation(description: "cache write fail handled")
        monitor.runAgyRefreshBranchForTest(config: config) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)

        XCTAssertEqual(monitor.lastAgyOutcome, .failed, "寫快取失敗時 outcome 不可為 .ok")
        let alpha = try XCTUnwrap(monitor.agySwapAccounts.first(where: { $0.name == "alpha" }))
        XCTAssertEqual(alpha.state, .cached, "寫快取失敗時不可標 live，應改顯示磁碟舊快取")
        XCTAssertEqual(alpha.buckets.map(\.remaining).sorted(), [53, 54, 55])
    }

    /// fix1 第 8 項：UsagePanel／UsageGlanceGroup 實際渲染使用的函式輸出與 dump 的 panelText／glanceText 逐字相等。
    func testDumpPanelAndGlanceTextMatchRenderedFunctionsExactly() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let monitor = UsageMonitor.makeForUnitTest()
        monitor.updated = now

        func assertSync(_ context: String) throws {
            let dump = monitor.buildUsageCardDumpPayload()
            let renderedPanel = monitor.agyPanelPresentation().summaryText
            let renderedGlanceGroup = try XCTUnwrap(monitor.glance.first(where: { $0.key == "agy" }), "缺少 agy glance：\(context)")
            XCTAssertEqual(renderedPanel, dump["panelText"] as? String, "panelText 必須與 UsagePanel 渲染文字逐字相等（\(context)）")
            XCTAssertEqual(renderedGlanceGroup.summaryText, dump["glanceText"] as? String, "glanceText 必須與 UsageGlanceGroup 渲染文字逐字相等（\(context)）")
        }

        // 1) swap live
        monitor.agySwapMode = true
        monitor.agyBuckets = sampleBuckets(fivePct: 91, weekPct: 82, argonPct: 73)
        monitor.agySwapAccounts = [
            AgySwapAccountDisplay(name: "alpha", isActive: true, state: .live, readAt: now, ageText: "剛剛", buckets: monitor.agyBuckets),
            AgySwapAccountDisplay(name: "bravo", isActive: false, state: .cached, readAt: now.addingTimeInterval(-600), ageText: "10 分鐘前", buckets: sampleBuckets(fivePct: 11, weekPct: 12, argonPct: 13)),
        ]
        try assertSync("swap-live")
        XCTAssertEqual(monitor.agyPanelPresentation().accountName, "alpha")
        XCTAssertEqual(monitor.agyPanelPresentation().othersText, "另有 1 個帳號")

        // 2) swap cached
        monitor.agySwapAccounts[0] = AgySwapAccountDisplay(name: "alpha", isActive: true, state: .cached, readAt: now.addingTimeInterval(-300), ageText: "5 分鐘前", buckets: monitor.agyBuckets)
        try assertSync("swap-cached")
        XCTAssertEqual(monitor.agyPanelPresentation().ageText, "5 分鐘前")

        // 3) swap invalid
        monitor.agyBuckets = []
        monitor.agySwapAccounts[0] = AgySwapAccountDisplay(name: "alpha", isActive: true, state: .invalid, readAt: nil, ageText: "登入失效", buckets: [])
        try assertSync("swap-invalid")
        XCTAssertEqual(monitor.agyPanelPresentation().statusText, "登入失效")
        XCTAssertTrue(monitor.agyPanelPresentation().isStatusError)

        // 4) swap never
        monitor.agySwapAccounts[0] = AgySwapAccountDisplay(name: "alpha", isActive: true, state: .never, readAt: nil, ageText: "還沒讀過", buckets: [])
        try assertSync("swap-never")
        XCTAssertEqual(monitor.agyPanelPresentation().statusText, "還沒讀過")

        // 5) legacy
        monitor.agySwapMode = false
        monitor.agySwapAccounts = []
        monitor.agyBuckets = sampleBuckets(fivePct: 88, weekPct: 77, argonPct: 66)
        try assertSync("legacy")
        XCTAssertFalse(monitor.agyPanelPresentation().showSwapHeader)
    }

    /// fix1 第 9 項：非換帳號路徑的 agy2（docker）與 agy `/usage` 維持並行；假 docker 睡 3 秒時 agy 結果不需等 docker 完成（< 1.5s）。
    func testLegacyPathRunsAgy2AndAgyInParallel() throws {
        let dir = try makeTempDir("legacy-parallel")
        defer { try? FileManager.default.removeItem(at: dir) }

        let slowDocker = try makeExecutableScript(in: dir, name: "docker", body: "#!/bin/sh\n/bin/sleep 3\nexit 1\n")
        let monitor = UsageMonitor.makeForUnitTest()

        let agyReadyExp = expectation(description: "agy finished without waiting for 3s docker")
        let bothDoneExp = expectation(description: "both agy and agy2 finished")
        let t0 = Date()
        var agyElapsed: TimeInterval = 999
        var gotAgyBuckets: [UsageBucket] = []
        var gotAgy2Status: Agy2QuotaStatus?

        UsageMonitor.runLegacyAgyAndAgy2InParallel(
            fetchAgy2: {
                monitor.fetchAgy2StatusCached(
                    dockerPath: slowDocker.path,
                    arguments: ["--state-dir", dir.path]
                )
            },
            fetchAgy: {
                (true, self.sampleBuckets(fivePct: 90, weekPct: 80, argonPct: 70))
            },
            onAgyReady: { res in
                agyElapsed = Date().timeIntervalSince(t0)
                gotAgyBuckets = res.parsed
                agyReadyExp.fulfill()
            },
            onBothDone: { combined in
                gotAgy2Status = combined.agy2
                bothDoneExp.fulfill()
            }
        )

        wait(for: [agyReadyExp], timeout: 2.0)
        XCTAssertLessThan(agyElapsed, 1.5, "假 docker 睡 3 秒時，agy 完成時間必須 < 1.5 秒，實際：\(agyElapsed)s")
        XCTAssertEqual(gotAgyBuckets.map(\.remaining), [90, 80, 70])

        wait(for: [bothDoneExp], timeout: 6.0)
        XCTAssertEqual(gotAgy2Status, .unreadable)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(t0), 2.5, "確認假 docker 確實有跑滿 3 秒")
    }

    /// fix1 第 10 項：即使呼叫執行緒把訊號遮罩設滿，posix_spawn 清空訊號遮罩與預設處理後，假子程序仍能收到 SIGTERM 並以 143 結束。
    func testSpawnFromFullyMaskedThreadDeliversSigtermAndExits143() throws {
        let dir = try makeTempDir("sigmask-term")
        defer { try? FileManager.default.removeItem(at: dir) }
        let readyFile = dir.appendingPathComponent("ready")
        let gotTermFile = dir.appendingPathComponent("got-term")

        let termScript = try makeExecutableScript(in: dir, name: "catch-term.py", body: """
        #!/usr/bin/python3
        import os, signal, time
        def on_term(sig, frm):
            with open("\(gotTermFile.path)", "w", encoding="utf-8") as f:
                f.write(str(sig) + "\\n")
            os._exit(143)
        signal.signal(signal.SIGTERM, on_term)
        with open("\(readyFile.path)", "w", encoding="utf-8") as f:
            f.write("ready\\n")
        time.sleep(30)
        """)

        let selfKillScript = try makeExecutableScript(in: dir, name: "self-term.py", body: #"""
        #!/usr/bin/python3
        import os, signal, time
        signal.signal(signal.SIGTERM, signal.SIG_DFL)
        os.kill(os.getpid(), signal.SIGTERM)
        time.sleep(5)
        os._exit(0)
        """#)

        // 在獨立執行緒中將訊號遮罩設滿（sigfillset）再呼叫 spawn，測完還原遮罩，不汙染 GCD 執行緒池。
        let spawnSem = DispatchSemaphore(value: 0)
        var handleBox: AgySwapProcessHandle?
        var selfKillBox: AgySwapProcessHandle?
        Thread.detachNewThread {
            var fullMask = sigset_t()
            var oldMask = sigset_t()
            sigfillset(&fullMask)
            pthread_sigmask(SIG_SETMASK, &fullMask, &oldMask)
            defer { pthread_sigmask(SIG_SETMASK, &oldMask, nil) }

            handleBox = AgySwapProcessHandle.spawn(
                executable: termScript.path,
                arguments: [],
                workingDirectory: dir,
                environment: AgySwapClient.minimalEnvironment(),
                timeout: 10,
                killGrace: 3.0
            )
            selfKillBox = AgySwapProcessHandle.spawn(
                executable: selfKillScript.path,
                arguments: [],
                workingDirectory: dir,
                environment: AgySwapClient.minimalEnvironment(),
                timeout: 10,
                killGrace: 1.0
            )
            spawnSem.signal()
        }
        XCTAssertEqual(spawnSem.wait(timeout: .now() + 5), .success)

        // 1) 我們送 TERM → 子程序收到 SIGTERM 以 143 離開（不等 3 秒 SIGKILL 寬限）
        let handle = try XCTUnwrap(handleBox)
        let readyDeadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: readyFile.path) && Date() < readyDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: readyFile.path))
        let tTerm = Date()
        handle.terminate()
        let result = handle.wait()
        let termElapsed = Date().timeIntervalSince(tTerm)

        XCTAssertTrue(result.weTerminated)
        XCTAssertEqual(result.exitCode, 143, "子程序必須真的收到 SIGTERM 並以 143 結束，不可落到 137 SIGKILL")
        XCTAssertEqual(AgySwapClient.classifyExit(result), .stoppedByUs)
        XCTAssertTrue(FileManager.default.fileExists(atPath: gotTermFile.path))
        XCTAssertLessThan(termElapsed, 1.5, "應在 SIGTERM 階段即時結束，不應等到 3 秒寬限期")

        // 2) 子程序自己送 SIGTERM（模擬 C495 self143）→ 必須以 143 結束且不標 weTerminated
        let selfKillHandle = try XCTUnwrap(selfKillBox)
        let selfRes = selfKillHandle.wait()
        XCTAssertFalse(selfRes.weTerminated)
        XCTAssertEqual(selfRes.exitCode, 143)
        XCTAssertEqual(AgySwapClient.classifyExit(selfRes), .failed(exitCode: 143))
    }

    /// fix1 第 11 項：開機首輪 status 逾時／accounts_error 且磁碟有 alpha 快取 → dump 顯示 alpha cached 55/54/53 及約 30 分鐘前。
    func testFirstRoundSkipRoundTimeoutAndAccountsErrorShowDiskCache() throws {
        let dir = try makeTempDir("first-round-skip-cache")
        defer { try? FileManager.default.removeItem(at: dir) }

        let oldBuckets = [
            UsageBucket(label: "Gemini Models 5h", used: 45, resets: "", resetAt: Date().addingTimeInterval(3600)),
            UsageBucket(label: "Gemini Models weekly", used: 46, resets: "", resetAt: Date().addingTimeInterval(7200)),
            UsageBucket(label: "Claude and GPT models 5h", used: 47, resets: "", resetAt: Date().addingTimeInterval(10800)),
        ]
        let thirtyMinAgo = Date().addingTimeInterval(-(30 * 60 + 15))

        // 情境 A：開機首輪 status 逾時，磁碟只有 1 份合法快取（alpha）＋ 1 份損毀快取 ＋ 1 份不合法檔名
        let stateTimeout = dir.appendingPathComponent("state-timeout", isDirectory: true)
        let cacheTimeout = stateTimeout.appendingPathComponent("agy-swap/state", isDirectory: true)
        XCTAssertTrue(AgySwapUsageCache.write(account: "alpha", readAt: thirtyMinAgo, buckets: oldBuckets, stateDir: cacheTimeout))
        try "not-json".write(to: cacheTimeout.appendingPathComponent("usage-corrupt.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: cacheTimeout.appendingPathComponent("usage-bad name.json"), atomically: true, encoding: .utf8)

        let timeoutSwap = try makeExecutableScript(in: dir, name: "timeout-swap.sh", body: "#!/bin/sh\n/bin/sleep 10\n")
        let timeoutConfig = AgySwapConfig.from(
            arguments: ["codenv", "--state-dir", stateTimeout.path, "--agy-swap-bin", timeoutSwap.path, "--agy-usage-test",
                        "--agy-swap-status-timeout", "0.4", "--agy-swap-kill-grace", "0.2"]
        )
        let monitorA = UsageMonitor.makeForUnitTest()
        let cycleA = monitorA.beginRefreshCycleOnMain()
        let expA = expectation(description: "first round timeout")
        monitorA.runAgyRefreshBranchForTest(config: timeoutConfig) { expA.fulfill() }
        monitorA.completeMainCycleOnMain(cycle: cycleA, gotClaude: false, gotOther: false)
        wait(for: [expA], timeout: 5)

        XCTAssertEqual(monitorA.lastAgyOutcome, .skipped)
        XCTAssertFalse(monitorA.agySwapMode, "開機首輪只掃到 1 份快取且未曾確認換帳號模式時，agySwapMode 維持 legacy")
        XCTAssertTrue(monitorA.agySwapAccounts.isEmpty, "fix2 第 3 項：swapMode == false 時不得把 displays 寫進 agySwapAccounts")
        XCTAssertFalse(monitorA.usesSwapAccountDisplay)
        XCTAssertFalse(monitorA.agyPanelPresentation().showSwapHeader)
        XCTAssertNil(monitorA.agyGlanceGroup().accountLabel)
        XCTAssertEqual(monitorA.error, "查不到用量")
        XCTAssertNil(monitorA.updated)

        let dumpA = monitorA.buildUsageCardDumpPayload()
        XCTAssertEqual(dumpA["mode"] as? String, "legacy")
        let accsA = try XCTUnwrap((dumpA["fullPage"] as? [String: Any])?["accounts"] as? [[String: Any]])
        XCTAssertEqual(accsA.count, 1)
        let alphaA = try XCTUnwrap(accsA.first(where: { $0["name"] as? String == "alpha" }))
        XCTAssertEqual(alphaA["state"] as? String, "cached")
        XCTAssertEqual(alphaA["ageText"] as? String, "30 分鐘前")
        let pctsA = ((alphaA["rows"] as? [[String: Any]]) ?? []).compactMap { $0["remainingPercent"] as? Int }.sorted()
        XCTAssertEqual(pctsA, [53, 54, 55])

        // 情境 B：開機首輪 accounts_error=true 且 JSON 仍帶 accounts:[alpha, bravo]（≥2 個帳號），磁碟有 alpha 快取
        let stateAccErr = dir.appendingPathComponent("state-accerr", isDirectory: true)
        let cacheAccErr = stateAccErr.appendingPathComponent("agy-swap/state", isDirectory: true)
        XCTAssertTrue(AgySwapUsageCache.write(account: "alpha", readAt: thirtyMinAgo, buckets: oldBuckets, stateDir: cacheAccErr))

        let accErrSwap = try makeExecutableScript(in: dir, name: "accerr-swap.py", body: #"""
        #!/usr/bin/python3
        import json
        print(json.dumps({
            "active": "alpha",
            "gen": 3,
            "switching": False,
            "live_matches": "alpha",
            "accounts_error": True,
            "accounts": [{"name": "alpha"}, {"name": "bravo"}]
        }))
        """#)
        let accErrConfig = AgySwapConfig.from(
            arguments: ["codenv", "--state-dir", stateAccErr.path, "--agy-swap-bin", accErrSwap.path, "--agy-usage-test"]
        )
        let monitorB = UsageMonitor.makeForUnitTest()
        let cycleB = monitorB.beginRefreshCycleOnMain()
        let expB = expectation(description: "first round accounts_error")
        monitorB.runAgyRefreshBranchForTest(config: accErrConfig) { expB.fulfill() }
        monitorB.completeMainCycleOnMain(cycle: cycleB, gotClaude: false, gotOther: false)
        wait(for: [expB], timeout: 5)

        XCTAssertEqual(monitorB.lastAgyOutcome, .skipped)
        XCTAssertTrue(monitorB.agySwapMode, "accounts_error 仍帶 ≥2 個帳號時維持 swap 模式顯示舊快取")
        XCTAssertEqual(monitorB.error, "查不到用量")
        let dumpB = monitorB.buildUsageCardDumpPayload()
        XCTAssertEqual(dumpB["mode"] as? String, "swap")
        let accsB = try XCTUnwrap((dumpB["fullPage"] as? [String: Any])?["accounts"] as? [[String: Any]])
        XCTAssertEqual(accsB.map { $0["name"] as? String }, ["alpha", "bravo"])
        let alphaB = try XCTUnwrap(accsB.first(where: { $0["name"] as? String == "alpha" }))
        XCTAssertEqual(alphaB["state"] as? String, "cached")
        XCTAssertEqual(alphaB["ageText"] as? String, "30 分鐘前")
        let pctsB = ((alphaB["rows"] as? [[String: Any]]) ?? []).compactMap { $0["remainingPercent"] as? Int }.sorted()
        XCTAssertEqual(pctsB, [53, 54, 55])

        // 情境 C：開機首輪 status 逾時且磁碟掃到 ≥2 份快取 → agySwapMode == true，全部標為快取（非使用中）
        let stateTwo = dir.appendingPathComponent("state-two", isDirectory: true)
        let cacheTwo = stateTwo.appendingPathComponent("agy-swap/state", isDirectory: true)
        XCTAssertTrue(AgySwapUsageCache.write(account: "alpha", readAt: thirtyMinAgo, buckets: oldBuckets, stateDir: cacheTwo))
        XCTAssertTrue(AgySwapUsageCache.write(account: "bravo", readAt: thirtyMinAgo, buckets: oldBuckets, stateDir: cacheTwo))
        let twoConfig = AgySwapConfig.from(
            arguments: ["codenv", "--state-dir", stateTwo.path, "--agy-swap-bin", timeoutSwap.path, "--agy-usage-test",
                        "--agy-swap-status-timeout", "0.4", "--agy-swap-kill-grace", "0.2"]
        )
        let monitorC = UsageMonitor.makeForUnitTest()
        let expC = expectation(description: "first round timeout with 2 caches")
        monitorC.runAgyRefreshBranchForTest(config: twoConfig) { expC.fulfill() }
        wait(for: [expC], timeout: 5)
        XCTAssertTrue(monitorC.agySwapMode, "掃到 ≥2 份快取時 agySwapMode 應為 true")
        XCTAssertEqual(monitorC.agySwapAccounts.map(\.name), ["alpha", "bravo"])
        XCTAssertTrue(monitorC.agySwapAccounts.allSatisfy { $0.state == .cached && !$0.isActive })
        XCTAssertTrue(monitorC.agyBuckets.isEmpty)
    }

    // MARK: - 修正單 fix2 對應單元測試（第 1～4 項）

    /// fix2 第 1 項：假 run 輸出超過 1 MiB 遭截斷，即使前面含可解析的 usage 行，仍不得寫快取且 outcome == .failed。
    func testTruncatedRunOutputDoesNotWriteCacheAndMarksFailed() throws {
        let dir = try makeTempDir("fix2-truncated-run")
        defer { try? FileManager.default.removeItem(at: dir) }

        let fakeSwap = try makeExecutableScript(in: dir, name: "truncated-run-swap.py", body: #"""
        #!/usr/bin/python3
        import json, sys
        sub = sys.argv[1] if len(sys.argv) > 1 else ""
        if sub == "status":
            print(json.dumps({
                "active": "alpha",
                "gen": 3,
                "switching": False,
                "live_matches": "alpha",
                "recovery_pending": False,
                "accounts": [{"name": "alpha"}, {"name": "bravo"}]
            }))
            sys.exit(0)
        if sub == "run":
            if "--an-file" in sys.argv:
                an = sys.argv[sys.argv.index("--an-file") + 1]
                with open(an, "w", encoding="utf-8") as f:
                    f.write("alpha 3\n")
            sys.stdout.write("Gemini Models\tFive Hour Limit\t71%\t2026-11-23T00:00:00Z\n")
            sys.stdout.write("Gemini Models\tWeekly Limit\t72%\t2026-11-29T00:00:00Z\n")
            sys.stdout.write("Claude and GPT models\tFive Hour Limit\t73%\t2026-11-23T00:00:00Z\n")
            # 補吐 >1 MiB 讓 outputTruncated == true
            chunk = "X" * 65536
            for _ in range(24):
                sys.stdout.write(chunk)
            sys.stdout.flush()
            sys.exit(0)
        """#)

        // 情境 A：磁碟已有舊快取（55/54/53）→ 不得覆蓋舊快取，outcome == .failed，且不算本輪有資料
        let stateWithOld = dir.appendingPathComponent("state-old", isDirectory: true)
        let cacheWithOld = stateWithOld.appendingPathComponent("agy-swap/state", isDirectory: true)
        let oldReadAt = Date(timeIntervalSince1970: 1_799_998_200)
        let oldBuckets = [
            UsageBucket(label: "Gemini 5 小時", used: 45, resets: "", resetAt: Date().addingTimeInterval(3600)),
            UsageBucket(label: "Gemini 每週", used: 46, resets: "", resetAt: Date().addingTimeInterval(7200)),
            UsageBucket(label: "Argon 每週", used: 47, resets: "", resetAt: Date().addingTimeInterval(10800)),
        ]
        XCTAssertTrue(AgySwapUsageCache.write(account: "alpha", readAt: oldReadAt, buckets: oldBuckets, stateDir: cacheWithOld))
        let alphaURL = try XCTUnwrap(AgySwapUsageCache.cacheFileURL(account: "alpha", stateDir: cacheWithOld))
        let rawBefore = try Data(contentsOf: alphaURL)

        let cfgWithOld = AgySwapConfig.from(
            arguments: ["codenv", "--state-dir", stateWithOld.path, "--agy-swap-bin", fakeSwap.path, "--agy-usage-test"]
        )
        let monitorA = UsageMonitor.makeForUnitTest()
        let oldUpdated = Date(timeIntervalSince1970: 1_700_000_000)
        monitorA.updated = oldUpdated
        let cycleA = monitorA.beginRefreshCycleOnMain()
        let expA = expectation(description: "truncated run with existing cache")
        monitorA.runAgyRefreshBranchForTest(config: cfgWithOld) { expA.fulfill() }
        monitorA.completeMainCycleOnMain(cycle: cycleA, gotClaude: false, gotOther: false)
        wait(for: [expA], timeout: 10)

        XCTAssertEqual(monitorA.lastAgyOutcome, .failed, "run 輸出被截斷時 outcome 必為 .failed")
        XCTAssertEqual(try Data(contentsOf: alphaURL), rawBefore, "輸出被截斷時絕不可覆蓋既有舊快取")
        let alphaDispA = try XCTUnwrap(monitorA.agySwapAccounts.first(where: { $0.name == "alpha" }))
        XCTAssertEqual(alphaDispA.state, .cached)
        XCTAssertEqual(alphaDispA.buckets.map(\.remaining).sorted(), [53, 54, 55])
        XCTAssertEqual(monitorA.error, "查不到用量")
        XCTAssertEqual(monitorA.updated, oldUpdated)

        // 情境 B：磁碟原本無快取 → 不新建快取檔，outcome == .failed，顯示為 never
        let stateEmpty = dir.appendingPathComponent("state-empty", isDirectory: true)
        let cacheEmpty = stateEmpty.appendingPathComponent("agy-swap/state", isDirectory: true)
        let cfgEmpty = AgySwapConfig.from(
            arguments: ["codenv", "--state-dir", stateEmpty.path, "--agy-swap-bin", fakeSwap.path, "--agy-usage-test"]
        )
        let monitorB = UsageMonitor.makeForUnitTest()
        let expB = expectation(description: "truncated run without existing cache")
        monitorB.runAgyRefreshBranchForTest(config: cfgEmpty) { expB.fulfill() }
        wait(for: [expB], timeout: 10)

        XCTAssertEqual(monitorB.lastAgyOutcome, .failed)
        XCTAssertNil(AgySwapUsageCache.read(account: "alpha", stateDir: cacheEmpty), "輸出被截斷時不可新建快取檔")
        let alphaDispB = try XCTUnwrap(monitorB.agySwapAccounts.first(where: { $0.name == "alpha" }))
        XCTAssertEqual(alphaDispB.state, .never)
    }

    /// fix2 第 2 項：`.swap` 分支略過／run 失敗／斷網／寫快取失敗時不把磁碟舊快取或 invalid 算成本輪有資料；run 成功寫快取時 gotData == true。
    func testSwapBranchSkipOrFailureDoesNotCountDiskCacheAsGotData() throws {
        let dir = try makeTempDir("fix2-swap-gotdata")
        let roCacheDir = dir.appendingPathComponent("state-ro/agy-swap/state", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: roCacheDir.path)
            try? FileManager.default.removeItem(at: dir)
        }

        let oldReadAt = Date().addingTimeInterval(-1800)
        let oldBuckets = [
            UsageBucket(label: "Gemini 5 小時", used: 45, resets: "", resetAt: Date().addingTimeInterval(3600)),
            UsageBucket(label: "Gemini 每週", used: 46, resets: "", resetAt: Date().addingTimeInterval(7200)),
            UsageBucket(label: "Argon 每週", used: 47, resets: "", resetAt: Date().addingTimeInterval(10800)),
        ]
        let oldUpdated = Date(timeIntervalSince1970: 1_700_000_000)

        func runCase(
            name: String,
            scriptBody: String,
            extraFlags: [String] = [],
            makeCacheReadOnly: Bool = false
        ) throws -> (monitor: UsageMonitor, stateDir: URL) {
            let stateDir = dir.appendingPathComponent("state-\(name)", isDirectory: true)
            let cacheDir = stateDir.appendingPathComponent("agy-swap/state", isDirectory: true)
            XCTAssertTrue(AgySwapUsageCache.write(account: "alpha", readAt: oldReadAt, buckets: oldBuckets, stateDir: cacheDir))
            if makeCacheReadOnly {
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: cacheDir.path)
            }
            let script = try makeExecutableScript(in: dir, name: "swap-\(name).py", body: scriptBody)
            let config = AgySwapConfig.from(
                arguments: ["codenv", "--state-dir", stateDir.path, "--agy-swap-bin", script.path, "--agy-usage-test"] + extraFlags
            )
            let monitor = UsageMonitor.makeForUnitTest()
            monitor.updated = oldUpdated
            let cycle = monitor.beginRefreshCycleOnMain()
            let exp = expectation(description: "swap gotData \(name)")
            monitor.runAgyRefreshBranchForTest(config: config) { exp.fulfill() }
            monitor.completeMainCycleOnMain(cycle: cycle, gotClaude: false, gotOther: false)
            wait(for: [exp], timeout: 5)
            return (monitor, stateDir)
        }

        // 1) status.switching == true（同時含舊快取與 invalid 帳號）→ gotData == false
        let (mSwitching, _) = try runCase(name: "switching", scriptBody: #"""
        #!/usr/bin/python3
        import json
        print(json.dumps({
            "active": "alpha", "gen": 3, "switching": True, "live_matches": "alpha",
            "accounts": [{"name": "alpha"}, {"name": "bravo", "invalid": True}]
        }))
        """#)
        XCTAssertEqual(mSwitching.lastAgyOutcome, .skipped)
        XCTAssertEqual(mSwitching.error, "查不到用量")
        XCTAssertEqual(mSwitching.updated, oldUpdated)
        XCTAssertEqual(mSwitching.agySwapAccounts.first(where: { $0.name == "alpha" })?.state, .cached)
        XCTAssertEqual(mSwitching.agySwapAccounts.first(where: { $0.name == "bravo" })?.state, .invalid)

        // 2) run 失敗（exit 1）→ gotData == false
        let (mRunFail, _) = try runCase(name: "runfail", scriptBody: #"""
        #!/usr/bin/python3
        import json, sys
        if sys.argv[1] == "status":
            print(json.dumps({
                "active": "alpha", "gen": 3, "switching": False, "live_matches": "alpha",
                "accounts": [{"name": "alpha"}, {"name": "bravo"}]
            }))
            sys.exit(0)
        sys.exit(1)
        """#)
        XCTAssertEqual(mRunFail.lastAgyOutcome, .failed)
        XCTAssertEqual(mRunFail.error, "查不到用量")
        XCTAssertEqual(mRunFail.updated, oldUpdated)

        // 3) 斷網略過（--agy-offline）→ 不呼叫 run、gotData == false
        let offlineLog = dir.appendingPathComponent("offline-calls.log")
        let (mOffline, _) = try runCase(name: "offline", scriptBody: """
        #!/usr/bin/python3
        import json, sys
        sub = sys.argv[1] if len(sys.argv) > 1 else ""
        with open("\(offlineLog.path)", "a", encoding="utf-8") as f:
            f.write(sub + "\\n")
        if sub == "status":
            print(json.dumps({
                "active": "alpha", "gen": 3, "switching": False, "live_matches": "alpha",
                "accounts": [{"name": "alpha"}, {"name": "bravo"}]
            }))
        sys.exit(0)
        """, extraFlags: ["--agy-offline"])
        XCTAssertEqual(mOffline.lastAgyOutcome, .skipped)
        XCTAssertEqual(mOffline.error, "查不到用量")
        XCTAssertEqual(mOffline.updated, oldUpdated)
        let offlineCalls = try String(contentsOf: offlineLog, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(offlineCalls, ["status"], "斷網時不得呼叫 run")

        // 4) 寫快取失敗（唯讀快取目錄）→ gotData == false
        let okScript = #"""
        #!/usr/bin/python3
        import json, sys
        sub = sys.argv[1] if len(sys.argv) > 1 else ""
        if sub == "status":
            print(json.dumps({
                "active": "alpha", "gen": 3, "switching": False, "live_matches": "alpha",
                "accounts": [{"name": "alpha"}, {"name": "bravo"}]
            }))
            sys.exit(0)
        if sub == "run":
            if "--an-file" in sys.argv:
                an = sys.argv[sys.argv.index("--an-file") + 1]
                with open(an, "w", encoding="utf-8") as f:
                    f.write("alpha 3\n")
            print("Gemini Models\tFive Hour Limit\t71%\t2026-11-23T00:00:00Z")
            print("Gemini Models\tWeekly Limit\t72%\t2026-11-29T00:00:00Z")
            sys.exit(0)
        """#
        let (mWriteFail, _) = try runCase(name: "ro", scriptBody: okScript, makeCacheReadOnly: true)
        XCTAssertEqual(mWriteFail.lastAgyOutcome, .failed)
        XCTAssertEqual(mWriteFail.error, "查不到用量")
        XCTAssertEqual(mWriteFail.updated, oldUpdated)

        // 5) run 成功並寫入快取 → gotData == true（reconcile 報「Claude 用量這次查不到」並刷新 updated）
        let (mSuccess, _) = try runCase(name: "ok", scriptBody: okScript)
        XCTAssertEqual(mSuccess.lastAgyOutcome, .ok)
        XCTAssertEqual(mSuccess.error, "Claude 用量這次查不到", "run 成功寫快取時 gotData 必為 true")
        XCTAssertNotEqual(mSuccess.updated, oldUpdated)
        XCTAssertGreaterThan(try XCTUnwrap(mSuccess.updated), oldUpdated)
        XCTAssertEqual(mSuccess.agySwapAccounts.first(where: { $0.name == "alpha" })?.state, .live)
    }

    /// fix2 第 3 項：`.skipRound` 回 `swapMode == false` 時不設 `agySwapAccounts`、維持 legacy；UI／dump 一律以 `agySwapMode && !agySwapAccounts.isEmpty` 判斷。
    func testSkipRoundSwapModeFalseKeepsLegacyAndUIUsesSwapModeGate() throws {
        let dir = try makeTempDir("fix2-skip-legacy-gate")
        defer { try? FileManager.default.removeItem(at: dir) }

        let oldBuckets = [
            UsageBucket(label: "Gemini 5 小時", used: 45, resets: "", resetAt: Date().addingTimeInterval(3600)),
            UsageBucket(label: "Gemini 每週", used: 46, resets: "", resetAt: Date().addingTimeInterval(7200)),
            UsageBucket(label: "Argon 每週", used: 47, resets: "", resetAt: Date().addingTimeInterval(10800)),
        ]
        let thirtyMinAgo = Date().addingTimeInterval(-(30 * 60 + 15))
        let failSwap = try makeExecutableScript(in: dir, name: "fail-swap.sh", body: "#!/bin/sh\nexit 1\n")

        // 1) 開機第一輪 status 失敗、磁碟只有 1 份快取 → mode == "legacy"、agySwapAccounts 為空、fullPage.accounts 為 legacy 單一帳號
        let stateOne = dir.appendingPathComponent("state-one", isDirectory: true)
        let cacheOne = stateOne.appendingPathComponent("agy-swap/state", isDirectory: true)
        XCTAssertTrue(AgySwapUsageCache.write(account: "alpha", readAt: thirtyMinAgo, buckets: oldBuckets, stateDir: cacheOne))
        let cfgOne = AgySwapConfig.from(
            arguments: ["codenv", "--state-dir", stateOne.path, "--agy-swap-bin", failSwap.path, "--agy-usage-test"]
        )
        let monitorOne = UsageMonitor.makeForUnitTest()
        let expOne = expectation(description: "skipRound one cache")
        monitorOne.runAgyRefreshBranchForTest(config: cfgOne) { expOne.fulfill() }
        wait(for: [expOne], timeout: 5)

        XCTAssertFalse(monitorOne.agySwapMode)
        XCTAssertTrue(monitorOne.agySwapAccounts.isEmpty)
        XCTAssertFalse(monitorOne.usesSwapAccountDisplay)
        XCTAssertFalse(monitorOne.agyPanelPresentation().showSwapHeader)
        XCTAssertEqual(monitorOne.agyGlanceGroup().name, "agy")
        XCTAssertNil(monitorOne.agyGlanceGroup().accountLabel)
        XCTAssertNil(monitorOne.agyGlanceGroup().othersText)
        let dumpOne = monitorOne.buildUsageCardDumpPayload()
        XCTAssertEqual(dumpOne["mode"] as? String, "legacy")
        let accsOne = try XCTUnwrap((dumpOne["fullPage"] as? [String: Any])?["accounts"] as? [[String: Any]])
        XCTAssertEqual(accsOne.count, 1)
        XCTAssertEqual(accsOne[0]["name"] as? String, "alpha")
        XCTAssertEqual(accsOne[0]["state"] as? String, "cached")
        XCTAssertEqual(accsOne[0]["ageText"] as? String, "30 分鐘前")

        // 2) 開機第一輪 accounts_error 只帶 1 個帳號 → 同樣維持 legacy、不寫 agySwapAccounts
        let stateAccErrOne = dir.appendingPathComponent("state-accerr-one", isDirectory: true)
        let cacheAccErrOne = stateAccErrOne.appendingPathComponent("agy-swap/state", isDirectory: true)
        XCTAssertTrue(AgySwapUsageCache.write(account: "alpha", readAt: thirtyMinAgo, buckets: oldBuckets, stateDir: cacheAccErrOne))
        let accErrOneSwap = try makeExecutableScript(in: dir, name: "accerr-one.py", body: #"""
        #!/usr/bin/python3
        import json
        print(json.dumps({
            "active": "alpha", "gen": 2, "switching": False, "live_matches": "alpha",
            "accounts_error": True, "accounts": [{"name": "alpha"}]
        }))
        """#)
        let cfgAccErrOne = AgySwapConfig.from(
            arguments: ["codenv", "--state-dir", stateAccErrOne.path, "--agy-swap-bin", accErrOneSwap.path, "--agy-usage-test"]
        )
        let monitorAccErrOne = UsageMonitor.makeForUnitTest()
        let expAccErrOne = expectation(description: "skipRound accounts_error one account")
        monitorAccErrOne.runAgyRefreshBranchForTest(config: cfgAccErrOne) { expAccErrOne.fulfill() }
        wait(for: [expAccErrOne], timeout: 5)

        XCTAssertFalse(monitorAccErrOne.agySwapMode)
        XCTAssertTrue(monitorAccErrOne.agySwapAccounts.isEmpty)
        XCTAssertEqual(monitorAccErrOne.buildUsageCardDumpPayload()["mode"] as? String, "legacy")

        // 3) 掃到 ≥2 份快取 → mode == "swap"、寫入 agySwapAccounts
        let stateTwo = dir.appendingPathComponent("state-two", isDirectory: true)
        let cacheTwo = stateTwo.appendingPathComponent("agy-swap/state", isDirectory: true)
        XCTAssertTrue(AgySwapUsageCache.write(account: "alpha", readAt: thirtyMinAgo, buckets: oldBuckets, stateDir: cacheTwo))
        XCTAssertTrue(AgySwapUsageCache.write(account: "bravo", readAt: thirtyMinAgo, buckets: oldBuckets, stateDir: cacheTwo))
        let cfgTwo = AgySwapConfig.from(
            arguments: ["codenv", "--state-dir", stateTwo.path, "--agy-swap-bin", failSwap.path, "--agy-usage-test"]
        )
        let monitorTwo = UsageMonitor.makeForUnitTest()
        let expTwo = expectation(description: "skipRound two caches")
        monitorTwo.runAgyRefreshBranchForTest(config: cfgTwo) { expTwo.fulfill() }
        wait(for: [expTwo], timeout: 5)

        XCTAssertTrue(monitorTwo.agySwapMode)
        XCTAssertTrue(monitorTwo.usesSwapAccountDisplay)
        XCTAssertEqual(monitorTwo.agySwapAccounts.map(\.name), ["alpha", "bravo"])
        let dumpTwo = monitorTwo.buildUsageCardDumpPayload()
        XCTAssertEqual(dumpTwo["mode"] as? String, "swap")
        let accsTwo = try XCTUnwrap((dumpTwo["fullPage"] as? [String: Any])?["accounts"] as? [[String: Any]])
        XCTAssertEqual(accsTwo.count, 2)

        // 4) 即使 agySwapAccounts 非空，只要 agySwapMode == false，所有顯示與 dump 一律走 legacy（不只看 !agySwapAccounts.isEmpty）
        let gated = UsageMonitor.makeForUnitTest()
        gated.agySwapMode = false
        gated.agyBuckets = sampleBuckets(fivePct: 88, weekPct: 77, argonPct: 66)
        gated.agySwapAccounts = [
            AgySwapAccountDisplay(name: "alpha", isActive: true, state: .cached, readAt: thirtyMinAgo, ageText: "30 分鐘前", buckets: oldBuckets),
            AgySwapAccountDisplay(name: "bravo", isActive: false, state: .cached, readAt: thirtyMinAgo, ageText: "30 分鐘前", buckets: oldBuckets),
        ]
        XCTAssertFalse(gated.usesSwapAccountDisplay)
        XCTAssertFalse(gated.agyPanelPresentation().showSwapHeader)
        XCTAssertEqual(gated.agyPanelSummaryText(), "week 77% · 5h 88% · argon 66%")
        XCTAssertEqual(gated.agyGlanceGroup().name, "agy")
        XCTAssertNil(gated.agyGlanceGroup().accountLabel)
        XCTAssertNil(gated.agyGlanceGroup().othersText)
        let gatedDump = gated.buildUsageCardDumpPayload()
        XCTAssertEqual(gatedDump["mode"] as? String, "legacy")
        let gatedAccs = try XCTUnwrap((gatedDump["fullPage"] as? [String: Any])?["accounts"] as? [[String: Any]])
        XCTAssertEqual(gatedAccs.count, 1)
        XCTAssertEqual(gatedAccs[0]["name"] as? String, "default")
        XCTAssertEqual(gatedAccs[0]["state"] as? String, "live")
    }

    /// fix2 第 4 項：`.skipRound` 掃到 ≥2 份快取且全無現用（無 active）時要清 `agyBuckets`，避免右欄在「還沒讀過」下面顯示舊百分比。
    func testSkipRoundWithTwoCachesAndNoActiveClearsAgyBuckets() throws {
        let dir = try makeTempDir("fix2-skip-clear-buckets")
        defer { try? FileManager.default.removeItem(at: dir) }

        let stateDir = dir.appendingPathComponent("state", isDirectory: true)
        let cacheDir = stateDir.appendingPathComponent("agy-swap/state", isDirectory: true)
        let thirtyMinAgo = Date().addingTimeInterval(-(30 * 60 + 15))
        XCTAssertTrue(AgySwapUsageCache.write(account: "alpha", readAt: thirtyMinAgo, buckets: sampleBuckets(fivePct: 55, weekPct: 54, argonPct: 53), stateDir: cacheDir))
        XCTAssertTrue(AgySwapUsageCache.write(account: "bravo", readAt: thirtyMinAgo, buckets: sampleBuckets(fivePct: 44, weekPct: 43, argonPct: 42), stateDir: cacheDir))

        let failSwap = try makeExecutableScript(in: dir, name: "fail-swap.sh", body: "#!/bin/sh\nexit 1\n")
        let config = AgySwapConfig.from(
            arguments: ["codenv", "--state-dir", stateDir.path, "--agy-swap-bin", failSwap.path, "--agy-usage-test"]
        )

        let monitor = UsageMonitor.makeForUnitTest()
        // 模擬上一輪殘留的舊百分比與舊 active
        monitor.agyActiveAccount = "stale-account"
        monitor.agyBuckets = sampleBuckets(fivePct: 91, weekPct: 82, argonPct: 73)

        let exp = expectation(description: "skipRound two caches no active")
        monitor.runAgyRefreshBranchForTest(config: config) { exp.fulfill() }
        wait(for: [exp], timeout: 5)

        XCTAssertTrue(monitor.agySwapMode)
        XCTAssertEqual(monitor.agySwapAccounts.map(\.name), ["alpha", "bravo"])
        XCTAssertTrue(monitor.agySwapAccounts.allSatisfy { !$0.isActive && $0.state == .cached })
        XCTAssertNil(monitor.agyActiveAccount)
        XCTAssertTrue(monitor.agyBuckets.isEmpty, "無 active 時必須清掉上一輪殘留的 agyBuckets")
        XCTAssertTrue(monitor.rows(.gemini, argon: true).isEmpty, "UsagePanel 所用的 gemini rows 必須為空")
        XCTAssertTrue(monitor.rows(.claudeAgy).isEmpty, "UsagePanel 所用的 claudeAgy rows 必須為空")

        let panel = monitor.agyPanelPresentation()
        XCTAssertTrue(panel.showSwapHeader)
        XCTAssertNil(panel.accountName)
        XCTAssertEqual(panel.statusText, "還沒讀過")
        XCTAssertEqual(panel.numbersText, "—")
        XCTAssertEqual(panel.othersText, "另有 1 個帳號")

        let summary = monitor.agyPanelSummaryText()
        XCTAssertEqual(summary, panel.summaryText)
        XCTAssertTrue(summary.contains("還沒讀過"))
        XCTAssertTrue(summary.contains("另有 1 個帳號"))
        XCTAssertFalse(summary.contains("91%"))
        XCTAssertFalse(summary.contains("82%"))
        XCTAssertFalse(summary.contains("73%"))

        let dump = monitor.buildUsageCardDumpPayload()
        XCTAssertEqual(dump["panelText"] as? String, summary)
    }
}
