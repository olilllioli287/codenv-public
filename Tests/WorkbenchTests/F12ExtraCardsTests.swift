import XCTest
import Foundation
@testable import Workbench

private final class MockDeepSeekURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var handler: ((URLRequest) -> (response: URLResponse?, data: Data?, error: Error?, delay: TimeInterval))?
    static var recordedRequests: [URLRequest] = []
    static var cancelledCount = 0
    static var onStopLoading: (() -> Void)?

    static func reset() {
        lock.lock()
        handler = nil
        recordedRequests = []
        cancelledCount = 0
        onStopLoading = nil
        lock.unlock()
    }

    static func snapshot() -> (requests: [URLRequest], cancelled: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (recordedRequests, cancelledCount)
    }

    private let stateLock = NSLock()
    private var isCancelled = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recordedRequests.append(request)
        let currentHandler = Self.handler
        Self.lock.unlock()

        let outcome = currentHandler?(request) ?? (nil, nil, URLError(.cannotConnectToHost), 0)
        let deliver = {
            self.stateLock.lock()
            let stopped = self.isCancelled
            self.stateLock.unlock()
            guard !stopped else { return }

            if let error = outcome.error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
            if let http = outcome.response as? HTTPURLResponse,
               (300..<400).contains(http.statusCode),
               let loc = http.value(forHTTPHeaderField: "Location"),
               let redirectURL = URL(string: loc) {
                self.client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirectURL), redirectResponse: http)
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.02) {
                    self.stateLock.lock()
                    let stopped = self.isCancelled
                    self.stateLock.unlock()
                    guard !stopped else { return }
                    self.client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
                    if let data = outcome.data { self.client?.urlProtocol(self, didLoad: data) }
                    self.client?.urlProtocolDidFinishLoading(self)
                }
                return
            }
            if let response = outcome.response {
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            if let data = outcome.data {
                self.client?.urlProtocol(self, didLoad: data)
            }
            self.client?.urlProtocolDidFinishLoading(self)
        }

        if outcome.delay > 0 {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + outcome.delay, execute: deliver)
        } else {
            deliver()
        }
    }

    override func stopLoading() {
        stateLock.lock()
        isCancelled = true
        stateLock.unlock()
        Self.lock.lock()
        Self.cancelledCount += 1
        let cb = Self.onStopLoading
        Self.onStopLoading = nil
        Self.lock.unlock()
        cb?()
    }
}

final class F12ExtraCardsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MockDeepSeekURLProtocol.reset()
    }

    override func tearDown() {
        MockDeepSeekURLProtocol.reset()
        super.tearDown()
    }

    private func makeTempDir(_ prefix: String = "f12-extra-cards") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func mockSessionConfig() -> URLSessionConfiguration {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockDeepSeekURLProtocol.self]
        cfg.urlCache = nil
        cfg.httpShouldSetCookies = false
        return cfg
    }

    // MARK: - 1. DeepSeek 解析（正常／餘額 0／is_available false／JSON 壞／balance_infos 空／數字與字串金額／缺欄）

    func testParseDeepSeekStringAndNumericAmountsAndMultiCurrency() throws {
        let stringJSON = Data(#"""
        {
          "is_available": true,
          "balance_infos": [
            {
              "currency": "CNY",
              "total_balance": "12.34",
              "topped_up_balance": "10.00",
              "granted_balance": "2.34"
            },
            {
              "currency": "USD",
              "total_balance": 5.5,
              "topped_up_balance": 5,
              "granted_balance": 0.5
            }
          ]
        }
        """#.utf8)
        let parsed = ExtraKeyPools.parseDeepSeek(stringJSON)
        XCTAssertEqual(parsed, .available(notes: [
            "餘額 12.34 CNY（儲值 10.00＋贈送 2.34）",
            "餘額 5.50 USD（儲值 5.00＋贈送 0.50）",
        ]))
    }

    func testParseDeepSeekZeroBalanceWhenAvailable() {
        let zeroString = Data(#"""
        {
          "is_available": true,
          "balance_infos": [
            {
              "currency": "CNY",
              "total_balance": "0.00",
              "topped_up_balance": "0.00",
              "granted_balance": "0.00"
            }
          ]
        }
        """#.utf8)
        XCTAssertEqual(ExtraKeyPools.parseDeepSeek(zeroString), .available(notes: [
            "餘額 0.00 CNY（儲值 0.00＋贈送 0.00）",
        ]))

        let zeroNumeric = Data(#"""
        {
          "is_available": true,
          "balance_infos": [
            {
              "currency": "USD",
              "total_balance": 0,
              "topped_up_balance": 0,
              "granted_balance": 0
            }
          ]
        }
        """#.utf8)
        XCTAssertEqual(ExtraKeyPools.parseDeepSeek(zeroNumeric), .available(notes: [
            "餘額 0.00 USD（儲值 0.00＋贈送 0.00）",
        ]))
    }

    func testParseDeepSeekIsAvailableFalseShowsInsufficientMessage() {
        let unavailableJSON = Data(#"""
        {
          "is_available": false,
          "balance_infos": []
        }
        """#.utf8)
        XCTAssertEqual(ExtraKeyPools.parseDeepSeek(unavailableJSON), .unavailable)

        let src = ExtraKeySources.fake([
            "deepseek": ["key": "value", "response": ["is_available": false, "balance_infos": []]]
        ])
        let card = ExtraKeyPools.pools(src, groqCache: nil, kaggleCache: nil).first { $0.name == "DeepSeek" }
        XCTAssertNotNil(card)
        XCTAssertEqual(card?.source, "DeepSeek 官方 API")
        XCTAssertTrue(card?.buckets.isEmpty == true)
        XCTAssertTrue(card?.notes.isEmpty == true)
        XCTAssertEqual(card?.message, "帳戶餘額不足，無法呼叫")
    }

    func testParseDeepSeekFailuresReturnNilAndNeverShowZero() {
        let badPayloads: [Data] = [
            Data("{not-json".utf8),
            Data("[]".utf8),
            Data(#"{"balance_infos":[{"currency":"CNY","total_balance":"1","topped_up_balance":"1","granted_balance":"0"}]}"#.utf8),
            Data(#"{"is_available":1,"balance_infos":[{"currency":"CNY","total_balance":"1","topped_up_balance":"1","granted_balance":"0"}]}"#.utf8),
            Data(#"{"is_available":true,"balance_infos":[]}"#.utf8),
            Data(#"{"is_available":true}"#.utf8),
            Data(#"{"is_available":true,"balance_infos":[{"currency":"","total_balance":"1","topped_up_balance":"1","granted_balance":"0"}]}"#.utf8),
            Data(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"1","topped_up_balance":"1"}]}"#.utf8),
            Data(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"NaN","topped_up_balance":"1","granted_balance":"0"}]}"#.utf8),
            Data(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":true,"topped_up_balance":"1","granted_balance":"0"}]}"#.utf8),
            Data(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"abc","topped_up_balance":"1","granted_balance":"0"}]}"#.utf8),
        ]
        for payload in badPayloads {
            XCTAssertNil(ExtraKeyPools.parseDeepSeek(payload), "壞資料必須回 nil：\(String(decoding: payload, as: UTF8.self))")
        }

        // 組裝卡片：失敗一律顯示「查不到餘額」，絕不顯示 0
        let brokenSrc = ExtraKeySources.fake([
            "deepseek": ["key": "value", "response": "{invalid json"]
        ])
        let card = ExtraKeyPools.pools(brokenSrc, groqCache: nil, kaggleCache: nil).first { $0.name == "DeepSeek" }
        XCTAssertEqual(card?.name, "DeepSeek")
        XCTAssertEqual(card?.source, "DeepSeek 官方 API")
        XCTAssertEqual(card?.message, "查不到餘額")
        XCTAssertTrue(card?.buckets.isEmpty == true)
        XCTAssertTrue(card?.notes.isEmpty == true)
        XCTAssertFalse(ExtraKeyPoolCard.displayLines(for: card!).joined(separator: "\n").contains("0"))
    }

    func testDeepSeekKeyStatesAndFakeInvalidJSONObjectSafety() {
        // missing -> 不出卡
        let missingSrc = ExtraKeySources.fake(["deepseek": ["key": "missing"]])
        XCTAssertNil(ExtraKeyPools.pools(missingSrc, groqCache: nil, kaggleCache: nil).first { $0.name == "DeepSeek" })

        // denied / failed / pending 沿用既有訊息
        for (keyState, expectedMessage) in [
            ("denied", ExtraKeySources.denied),
            ("failed", "讀金鑰失敗（鑰匙圈 -25291）"),
            ("pending", "等鑰匙圈授權中"),
        ] {
            let src = ExtraKeySources.fake(["deepseek": ["key": keyState]])
            let card = ExtraKeyPools.pools(src, groqCache: nil, kaggleCache: nil).first { $0.name == "DeepSeek" }
            XCTAssertEqual(card?.source, "鑰匙圈", "keyState=\(keyState)")
            XCTAssertEqual(card?.message, expectedMessage, "keyState=\(keyState)")
        }

        // response 為非法 JSONSerialization 頂層物件（例如數字／布林／NSNull）：不得觸發 ObjC 例外，且卡片顯示「查不到餘額」
        for invalidValue in [12345 as Any, true as Any, NSNull() as Any] {
            let src = ExtraKeySources.fake(["deepseek": ["key": "value", "response": invalidValue]])
            let card = ExtraKeyPools.pools(src, groqCache: nil, kaggleCache: nil).first { $0.name == "DeepSeek" }
            XCTAssertEqual(card?.message, "查不到餘額")
        }
    }

    // MARK: - 2. DeepSeek 網路隔離、base URL 驗證、金鑰安全、逾時與不重試

    func testDeepSeekBaseURLResolutionAndLocalhostValidation() {
        // 正式版（無 --state-dir）：固定官方網址，忽略 --deepseek-base-url
        XCTAssertEqual(
            ExtraKeyPools.deepSeekBaseURL(arguments: ["codenv"])?.absoluteString,
            "https://api.deepseek.com"
        )
        XCTAssertEqual(
            ExtraKeyPools.deepSeekBaseURL(arguments: [
                "codenv", "--deepseek-base-url", "http://127.0.0.1:18080"
            ])?.absoluteString,
            "https://api.deepseek.com"
        )
        XCTAssertNil(ExtraKeyPools.deepSeekTestBaseURL(arguments: [
            "codenv", "--deepseek-base-url", "http://127.0.0.1:18080"
        ]))

        // 測試實例未帶 --deepseek-base-url -> nil（不連網）
        XCTAssertNil(ExtraKeyPools.deepSeekBaseURL(arguments: ["codenv", "--state-dir", "/tmp/exam"]))

        // 測試實例合法 localhost / 127.0.0.1 -> 接受，且端點固定 /user/balance
        let ipBase = ExtraKeyPools.deepSeekBaseURL(arguments: [
            "codenv", "--state-dir", "/tmp/exam", "--deepseek-base-url", "http://127.0.0.1:18080"
        ])
        XCTAssertEqual(ipBase?.absoluteString, "http://127.0.0.1:18080")
        XCTAssertEqual(ipBase.flatMap(ExtraKeyPools.deepSeekEndpointURL)?.absoluteString, "http://127.0.0.1:18080/user/balance")

        let localhostBase = ExtraKeyPools.deepSeekBaseURL(arguments: [
            "codenv", "--state-dir", "/tmp/exam", "--deepseek-base-url", "http://localhost:19090/"
        ])
        XCTAssertEqual(localhostBase?.absoluteString, "http://localhost:19090")
        XCTAssertEqual(localhostBase.flatMap(ExtraKeyPools.deepSeekEndpointURL)?.absoluteString, "http://localhost:19090/user/balance")

        // 非本機／不安全網址一律忽略並當沒給
        let rejected = [
            "https://api.deepseek.com",
            "http://example.com:8080",
            "http://127.0.0.1.evil.com:8080",
            "http://0.0.0.0:8080",
            "http://[::1]:8080",
            "file:///etc/passwd",
            "ftp://127.0.0.1:21",
            "http://user:pass@127.0.0.1:8080",
            "http://127.0.0.1:8080/custom/path",
            "http://127.0.0.1:8080?secret=1",
            "http://127.0.0.1:8080#frag",
            "not-a-url",
            "",
        ]
        for raw in rejected {
            let parsed = ExtraKeyPools.deepSeekBaseURL(arguments: [
                "codenv", "--state-dir", "/tmp/exam", "--deepseek-base-url", raw
            ])
            XCTAssertNil(parsed, "不合法的 --deepseek-base-url 必須忽略：\(raw)")
        }
    }

    func testDeepSeekFetchTestInstanceWithoutFlagNeverTouchesNetwork() {
        let secret = "sk-fake-deepseek-never-send-9999"
        MockDeepSeekURLProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data("{}".utf8), nil, 0)
        }
        let noFlag = ExtraKeyPools.deepSeekFetch(
            key: secret,
            arguments: ["codenv", "--state-dir", "/tmp/exam"],
            sessionConfiguration: mockSessionConfig()
        )
        XCTAssertNil(noFlag)
        XCTAssertEqual(MockDeepSeekURLProtocol.snapshot().requests.count, 0)

        let badHost = ExtraKeyPools.deepSeekFetch(
            key: secret,
            arguments: ["codenv", "--state-dir", "/tmp/exam", "--deepseek-base-url", "https://api.deepseek.com"],
            sessionConfiguration: mockSessionConfig()
        )
        XCTAssertNil(badHost)
        XCTAssertEqual(MockDeepSeekURLProtocol.snapshot().requests.count, 0)
    }

    func testDeepSeekFetchRequestHeaderPathSecurityAndNoRetry() throws {
        let secret = "sk-fake-deepseek-unit-secret-778899"
        let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:18765"))

        // 1) 成功：驗證路徑 /user/balance、GET、Authorization header，且卡片文字與 dump 不含金鑰
        MockDeepSeekURLProtocol.handler = { req in
            let body = Data(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"42.00","topped_up_balance":"40.00","granted_balance":"2.00"}]}"#.utf8)
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, body, nil, 0)
        }
        let okResult = ExtraKeyPools.fetchDeepSeekBalance(
            key: secret, baseURL: baseURL, timeout: 2, sessionConfiguration: mockSessionConfig()
        )
        XCTAssertNil(okResult.error)
        XCTAssertNotNil(okResult.data)
        let reqs = MockDeepSeekURLProtocol.snapshot().requests
        XCTAssertEqual(reqs.count, 1)
        XCTAssertEqual(reqs.first?.httpMethod, "GET")
        XCTAssertEqual(reqs.first?.url?.path, "/user/balance")
        XCTAssertEqual(reqs.first?.value(forHTTPHeaderField: "Authorization"), "Bearer \(secret)")

        // 2) HTTP 401：只發一次不重試，錯誤訊息只留類別，不含金鑰
        MockDeepSeekURLProtocol.reset()
        MockDeepSeekURLProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (resp, Data("invalid key \(secret)".utf8), nil, 0)
        }
        let unauth = ExtraKeyPools.fetchDeepSeekBalance(
            key: secret, baseURL: baseURL, timeout: 2, sessionConfiguration: mockSessionConfig()
        )
        XCTAssertNil(unauth.data)
        XCTAssertEqual(unauth.error, .httpStatus(401))
        XCTAssertEqual(unauth.errorCategory, "HTTP 401")
        XCTAssertFalse((unauth.errorCategory ?? "").contains(secret))
        XCTAssertEqual(MockDeepSeekURLProtocol.snapshot().requests.count, 1)

        // 3) 逾時：會取消 task，只發一次不重試，錯誤訊息為「逾時」且不含金鑰
        MockDeepSeekURLProtocol.reset()
        let timeoutCancelled = expectation(description: "URLProtocol stopLoading called on timeout")
        MockDeepSeekURLProtocol.onStopLoading = { timeoutCancelled.fulfill() }
        MockDeepSeekURLProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data("{}".utf8), nil, 2.0)
        }
        let timedOut = ExtraKeyPools.fetchDeepSeekBalance(
            key: secret, baseURL: baseURL, timeout: 0.15, sessionConfiguration: mockSessionConfig()
        )
        wait(for: [timeoutCancelled], timeout: 1.0)
        XCTAssertNil(timedOut.data)
        XCTAssertEqual(timedOut.error, .timeout)
        XCTAssertEqual(timedOut.errorCategory, "逾時")
        XCTAssertFalse((timedOut.errorCategory ?? "").contains(secret))
        XCTAssertEqual(MockDeepSeekURLProtocol.snapshot().requests.count, 1)
        XCTAssertGreaterThanOrEqual(MockDeepSeekURLProtocol.snapshot().cancelled, 1)

        // 4) 重導向：不跟隨跳出本機
        MockDeepSeekURLProtocol.reset()
        MockDeepSeekURLProtocol.handler = { req in
            let resp = HTTPURLResponse(
                url: req.url!, statusCode: 302, httpVersion: nil,
                headerFields: ["Location": "https://evil.example/steal"]
            )!
            return (resp, Data(), nil, 0)
        }
        let redirect = ExtraKeyPools.fetchDeepSeekBalance(
            key: secret, baseURL: baseURL, timeout: 2, sessionConfiguration: mockSessionConfig()
        )
        XCTAssertNil(redirect.data)
        XCTAssertEqual(redirect.error, .httpStatus(302))
        XCTAssertEqual(redirect.errorCategory, "HTTP 302")
        XCTAssertEqual(MockDeepSeekURLProtocol.snapshot().requests.count, 1)

        // 4b) 主動取消與連線失敗：錯誤訊息只留類別，不含金鑰
        MockDeepSeekURLProtocol.reset()
        MockDeepSeekURLProtocol.handler = { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data("{}".utf8), nil, 2.0)
        }
        let cancelled = ExtraKeyPools.fetchDeepSeekBalance(
            key: secret, baseURL: baseURL, timeout: 2, sessionConfiguration: mockSessionConfig(),
            onTask: { task in
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.03) {
                    task.cancel()
                }
            }
        )
        XCTAssertNil(cancelled.data)
        XCTAssertEqual(cancelled.error, .cancelled)
        XCTAssertEqual(cancelled.errorCategory, "已取消")
        XCTAssertFalse((cancelled.errorCategory ?? "").contains(secret))

        MockDeepSeekURLProtocol.reset()
        MockDeepSeekURLProtocol.handler = { _ in
            (nil, nil, URLError(.cannotConnectToHost), 0)
        }
        let netFail = ExtraKeyPools.fetchDeepSeekBalance(
            key: secret, baseURL: baseURL, timeout: 2, sessionConfiguration: mockSessionConfig()
        )
        XCTAssertNil(netFail.data)
        XCTAssertEqual(netFail.error, .networkError)
        XCTAssertEqual(netFail.errorCategory, "連線失敗")
        XCTAssertFalse((netFail.errorCategory ?? "").contains(secret))

        // 5) 卡片與 dump 輸出完全不含假金鑰
        var src = ExtraKeySources.isolatedEmpty()
        src.readKey = { $0 == "deepseek" ? .value(secret) : .missing }
        src.fetchDeepSeek = { _ in okResult.data }
        let card = try XCTUnwrap(ExtraKeyPools.pools(src, groqCache: nil, kaggleCache: nil).first { $0.name == "DeepSeek" })
        let cardLines = ExtraKeyPoolCard.displayLines(for: card)
        XCTAssertFalse(([card.name, card.source, card.message ?? ""] + cardLines).joined(separator: "\n").contains(secret))

        let monitor = UsageMonitor.makeForUnitTest()
        monitor.setExtraPoolsForTest(remote: [card], local: [])
        monitor.setExtraLoadedAtForTest(Date(timeIntervalSince1970: 1_800_000_000))
        let payload = monitor.buildUsagePanelDumpPayload(
            panelFrame: CGRect(x: 10, y: 20, width: 900, height: 600),
            screenVisibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 945),
            columns: 3,
            panelScale: 1.15
        )
        let dumpData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let dumpText = String(decoding: dumpData, as: UTF8.self)
        XCTAssertFalse(dumpText.contains(secret))
        XCTAssertTrue(dumpText.contains("餘額 42.00 CNY（儲值 40.00＋贈送 2.00）"))
    }

    // MARK: - 3. Qwen 帳本（正常／缺檔／unreadable／壞檔／cap≤0／NaN／spent>cap／calls 非陣列／三態讀取）

    func testQwenLedgerValidAndSpentOverCapAndOnlyThreeFieldsRead() throws {
        let fakeRoot: [String: Any] = [
            "qwen": [
                "ledger": [
                    "spent_usd": 1.35,
                    "cap_usd": 10.0,
                    "calls": [
                        ["prompt": "PRIVATE_PROMPT_MUST_NOT_APPEAR", "tokens": 500],
                        ["prompt": "SECOND_SECRET_CALL", "tokens": 200],
                    ],
                    "extra_unused_field": "SHOULD_BE_IGNORED",
                ]
            ]
        ]
        let src = ExtraKeySources.fake(fakeRoot)
        let cards = ExtraKeyPools.localPools(src)
        XCTAssertEqual(cards.count, 1)
        let card = try XCTUnwrap(cards.first)
        XCTAssertEqual(card.name, "Qwen")
        XCTAssertEqual(card.source, "本機帳本")
        XCTAssertTrue(card.buckets.isEmpty)
        XCTAssertNil(card.message)
        XCTAssertEqual(card.notes, [
            "已花 1.35／10.00 USD（本機上限，非帳戶餘額）",
            "2 次呼叫",
        ])
        let joined = ExtraKeyPoolCard.displayLines(for: card).joined(separator: "\n")
        XCTAssertFalse(joined.contains("PRIVATE_PROMPT_MUST_NOT_APPEAR"))
        XCTAssertFalse(joined.contains("SECOND_SECRET_CALL"))
        XCTAssertFalse(joined.contains("SHOULD_BE_IGNORED"))

        // spent > cap：照實顯示、不報錯
        let overSrc = ExtraKeySources.fake([
            "qwen": ["ledger": ["spent_usd": 12.5, "cap_usd": 10.0, "calls": [1, 2, 3, 4]]]
        ])
        let overCard = try XCTUnwrap(ExtraKeyPools.qwenPool(overSrc))
        XCTAssertNil(overCard.message)
        XCTAssertEqual(overCard.notes, [
            "已花 12.50／10.00 USD（本機上限，非帳戶餘額）",
            "4 次呼叫",
        ])
    }

    func testQwenLedgerMissingUnreadableMalformedAndInvalidValues() {
        // missing -> 不出卡
        XCTAssertNil(ExtraKeyPools.qwenPool(ExtraKeySources.isolatedEmpty()))
        XCTAssertNil(ExtraKeyPools.qwenPool(ExtraKeySources.fake([:])))
        XCTAssertNil(ExtraKeyPools.qwenPool(ExtraKeySources.fake(["qwen": ["ledger": "missing"]])))

        // unreadable -> 「查不到帳本」
        let unreadable = ExtraKeyPools.qwenPool(ExtraKeySources.fake(["qwen": ["ledger": "unreadable"]]))
        XCTAssertEqual(unreadable?.name, "Qwen")
        XCTAssertEqual(unreadable?.source, "本機帳本")
        XCTAssertEqual(unreadable?.message, "查不到帳本")
        XCTAssertTrue(unreadable?.buckets.isEmpty == true)

        // 各種壞檔與非法值
        let badLedgers: [Any] = [
            "{bad-json",
            "[]",
            ["spent_usd": 1.0, "cap_usd": 0.0, "calls": []],        // cap == 0
            ["spent_usd": 1.0, "cap_usd": -5.0, "calls": []],       // cap < 0
            ["spent_usd": -0.01, "cap_usd": 10.0, "calls": []],     // spent < 0
            ["spent_usd": "NaN", "cap_usd": 10.0, "calls": []],     // NaN string
            ["spent_usd": 1.0, "cap_usd": "NaN", "calls": []],      // NaN string
            ["spent_usd": true, "cap_usd": 10.0, "calls": []],      // bool
            ["spent_usd": 1.0, "cap_usd": 10.0, "calls": 3],        // calls 非陣列（數字）
            ["spent_usd": 1.0, "cap_usd": 10.0, "calls": "none"],   // calls 非陣列（字串）
            ["spent_usd": 1.0, "cap_usd": 10.0, "calls": [:]],      // calls 非陣列（物件）
            ["spent_usd": 1.0, "cap_usd": 10.0],                    // 缺 calls
            ["cap_usd": 10.0, "calls": []],                         // 缺 spent_usd
            ["spent_usd": 1.0, "calls": []],                        // 缺 cap_usd
            12345,                                                  // 非法 JSONSerialization 物件
            true,                                                   // 非法 JSONSerialization 物件
        ]
        for bad in badLedgers {
            let src = ExtraKeySources.fake(["qwen": ["ledger": bad]])
            let card = ExtraKeyPools.qwenPool(src)
            XCTAssertEqual(card?.message, "查不到帳本", "應歸為查不到帳本：\(bad)")
            XCTAssertTrue(card?.notes.isEmpty == true)
        }

        // NaN / Infinity 數值直接驗證
        XCTAssertNil(ExtraKeyPools.formatQwenNotes(spentUSD: .nan, capUSD: 10, callCount: 0))
        XCTAssertNil(ExtraKeyPools.formatQwenNotes(spentUSD: 1, capUSD: .nan, callCount: 0))
        XCTAssertNil(ExtraKeyPools.formatQwenNotes(spentUSD: .infinity, capUSD: 10, callCount: 0))
        XCTAssertNil(ExtraKeyPools.formatQwenNotes(spentUSD: 1, capUSD: .infinity, callCount: 0))
        XCTAssertNil(ExtraKeyPools.formatQwenNotes(spentUSD: 1, capUSD: 0, callCount: 0))
        XCTAssertNil(ExtraKeyPools.formatQwenNotes(spentUSD: 1, capUSD: -1, callCount: 0))
        XCTAssertNil(ExtraKeyPools.formatQwenNotes(spentUSD: -1, capUSD: 10, callCount: 0))
    }

    func testQwenLedgerReadThreeStatesAndTestInstanceIsolation() throws {
        let dir = try makeTempDir("qwen-ledger")
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1) 缺檔 -> .missing
        let missingURL = dir.appendingPathComponent("does-not-exist.json")
        XCTAssertEqual(ExtraKeyPools.readQwenLedgerFile(at: missingURL), .missing)

        // 2) 正常檔案 -> .data(Data)
        let validURL = dir.appendingPathComponent("ledger.json")
        let content = Data(#"{"spent_usd":2.5,"cap_usd":20,"calls":[{}]}"#.utf8)
        try content.write(to: validURL)
        XCTAssertEqual(ExtraKeyPools.readQwenLedgerFile(at: validURL), .data(content))

        // 3) 存在但讀不到（目錄與無讀取權限檔案）-> .unreadable
        let directoryAsFile = dir.appendingPathComponent("subdir", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryAsFile, withIntermediateDirectories: true)
        XCTAssertEqual(ExtraKeyPools.readQwenLedgerFile(at: directoryAsFile), .unreadable)

        let unreadableURL = dir.appendingPathComponent("locked.json")
        try content.write(to: unreadableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadableURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadableURL.path) }
        if geteuid() != 0 {
            XCTAssertEqual(ExtraKeyPools.readQwenLedgerFile(at: unreadableURL), .unreadable)
        }

        // 4) 測試實例一律回 .missing（即使檔案存在也不讀）
        XCTAssertEqual(
            ExtraKeyPools.fetchQwenLedger(arguments: ["codenv", "--state-dir", dir.path], url: validURL),
            .missing
        )
        XCTAssertEqual(
            ExtraKeyPools.fetchQwenLedger(arguments: ["codenv", "--usage-fake"], url: validURL),
            .missing
        )
        // 正式參數（無 --state-dir 與測試旗標）可讀指定檔案
        XCTAssertEqual(
            ExtraKeyPools.fetchQwenLedger(arguments: ["codenv"], url: validURL),
            .data(content)
        )
    }

    func testLocalExtraPoolsRunsIndependentlyOfSlowRemoteExtraPools() {
        let monitor = UsageMonitor.makeForUnitTest()
        let releaseRemote = DispatchSemaphore(value: 0)
        let localReady = expectation(description: "local Qwen card ready before slow remote finishes")
        let allDone = expectation(description: "both local and remote finished")

        let qwenCard = ExtraKeyPool(name: "Qwen", source: "本機帳本", buckets: [], notes: ["已花 1.00／10.00 USD（本機上限，非帳戶餘額）", "1 次呼叫"])
        let deepSeekCard = ExtraKeyPool(name: "DeepSeek", source: "DeepSeek 官方 API", buckets: [], notes: ["餘額 5.00 CNY（儲值 5.00＋贈送 0.00）"])
        let fixedFinishDate = Date(timeIntervalSince1970: 1_800_000_500)

        monitor.runExtraKeyRefreshForTest(
            remote: {
                _ = releaseRemote.wait(timeout: .now() + 5)
                return [deepSeekCard]
            },
            local: { [qwenCard] },
            now: { fixedFinishDate },
            onLocalUpdated: {
                XCTAssertEqual(monitor.localExtraPools.map(\.name), ["Qwen"])
                XCTAssertTrue(monitor.extraKeyPools.isEmpty, "本機卡應在遠端完成前先行顯示")
                XCTAssertEqual(monitor.allExtraKeyPools.map(\.name), ["Qwen"])
                XCTAssertNil(monitor.extraLoadedAt, "遠端未完成前 extraLoadedAt 尚不應標記為完成")
                localReady.fulfill()
                releaseRemote.signal()
            },
            onAllCompleted: {
                XCTAssertEqual(monitor.extraKeyPools.map(\.name), ["DeepSeek"])
                XCTAssertEqual(monitor.localExtraPools.map(\.name), ["Qwen"])
                XCTAssertEqual(monitor.allExtraKeyPools.map(\.name), ["DeepSeek", "Qwen"])
                XCTAssertEqual(monitor.extraLoadedAt, fixedFinishDate)
                allDone.fulfill()
            }
        )

        wait(for: [localReady, allDone], timeout: 5)
    }

    // MARK: - 4. E 補刷新條件（從未載入／超過 5 分鐘／5 分鐘內不重刷／不受 loading 影響）

    func testExtraRefreshStalePredicateAndBypassLoading() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        // 純條件函式
        XCTAssertTrue(UsageMonitor.shouldRefreshExtraPools(lastLoadedAt: nil, now: t0))
        XCTAssertFalse(UsageMonitor.shouldRefreshExtraPools(lastLoadedAt: t0, now: t0))
        XCTAssertFalse(UsageMonitor.shouldRefreshExtraPools(lastLoadedAt: t0, now: t0.addingTimeInterval(299)))
        XCTAssertFalse(UsageMonitor.shouldRefreshExtraPools(lastLoadedAt: t0, now: t0.addingTimeInterval(300)))
        XCTAssertTrue(UsageMonitor.shouldRefreshExtraPools(lastLoadedAt: t0, now: t0.addingTimeInterval(300.1)))
        XCTAssertTrue(UsageMonitor.shouldRefreshExtraPools(lastLoadedAt: t0, now: t0.addingTimeInterval(301)))

        // 主查詢 loading = true 時，從未載入與超過 5 分鐘仍觸發；5 分鐘內不重刷
        let monitor = UsageMonitor.makeForUnitTest()
        monitor.loading = true
        var triggerCount = 0

        XCTAssertTrue(monitor.refreshExtraPoolsIfStale(now: t0) { triggerCount += 1 })
        XCTAssertEqual(triggerCount, 1)

        monitor.setExtraLoadedAtForTest(t0)
        XCTAssertFalse(monitor.refreshExtraPoolsIfStale(now: t0.addingTimeInterval(120)) { triggerCount += 1 })
        XCTAssertFalse(monitor.refreshExtraPoolsIfStale(now: t0.addingTimeInterval(300)) { triggerCount += 1 })
        XCTAssertEqual(triggerCount, 1)

        XCTAssertTrue(monitor.refreshExtraPoolsIfStale(now: t0.addingTimeInterval(301)) { triggerCount += 1 })
        XCTAssertEqual(triggerCount, 2)
    }

    // MARK: - 5. 測試鉤子（--usage-panel-dump／--usage-panel-open 設定與 JSON 結構）

    func testUsagePanelDumpConfigIsolationAndPayloadShape() throws {
        let root = try makeTempDir("panel-dump-cfg")
        defer { try? FileManager.default.removeItem(at: root) }
        let stateDir = root.appendingPathComponent("state", isDirectory: true)
        let inside = stateDir.appendingPathComponent("panel.json").path
        let outside = root.appendingPathComponent("escape.json").path

        // 正式模式（無 --state-dir）：完全忽略
        let formal = UsagePanelDumpConfig.from(arguments: [
            "codenv", "--usage-panel-open", "--usage-panel-dump", inside
        ])
        XCTAssertFalse(formal.isTestInstance)
        XCTAssertFalse(formal.openOnLaunch)
        XCTAssertNil(formal.dumpURL)

        // 測試模式：state-dir 內接受
        let valid = UsagePanelDumpConfig.from(arguments: [
            "codenv", "--state-dir", stateDir.path, "--usage-panel-open", "--usage-panel-dump", inside
        ])
        XCTAssertTrue(valid.isTestInstance)
        XCTAssertTrue(valid.openOnLaunch)
        XCTAssertEqual(valid.dumpURL?.path, URL(fileURLWithPath: inside).standardizedFileURL.path)

        // 測試模式：超出 state-dir 拒絕
        let escaped = UsagePanelDumpConfig.from(arguments: [
            "codenv", "--state-dir", stateDir.path, "--usage-panel-dump", outside
        ])
        XCTAssertTrue(escaped.isTestInstance)
        XCTAssertNil(escaped.dumpURL)

        // Payload 結構與順序（含 DeepSeek 與 Qwen）
        let monitor = UsageMonitor.makeForUnitTest()
        monitor.buckets = [UsageBucket(label: "5 小時", used: 20, resets: "明天 10:00")]
        let ds = ExtraKeyPool(name: "DeepSeek", source: "DeepSeek 官方 API", buckets: [], notes: ["餘額 10.00 CNY（儲值 10.00＋贈送 0.00）"])
        let qw = ExtraKeyPool(name: "Qwen", source: "本機帳本", buckets: [], notes: ["已花 1.35／10.00 USD（本機上限，非帳戶餘額）", "3 次呼叫"])
        monitor.setExtraPoolsForTest(remote: [ds], local: [qw])
        let loadedAt = Date(timeIntervalSince1970: 1_800_000_000)
        monitor.setExtraLoadedAtForTest(loadedAt)

        let payload = monitor.buildUsagePanelDumpPayload(
            panelFrame: CGRect(x: 100, y: 200, width: 980, height: 620),
            screenVisibleFrame: CGRect(x: 0, y: 25, width: 1512, height: 945),
            columns: 3,
            panelScale: 1.15
        )
        XCTAssertEqual(payload["extraLoaded"] as? Bool, true)
        XCTAssertEqual(payload["extraLoadedAt"] as? String, AgySwapUsageCache.formatISO8601UTC(loadedAt))
        XCTAssertEqual(payload["columns"] as? Int, 3)
        XCTAssertEqual(payload["panelScale"] as? Double, 1.15)
        XCTAssertEqual(payload["order"] as? [String], ["pool:cc", "extra:DeepSeek", "extra:Qwen"])
        let frame = try XCTUnwrap(payload["panelFrame"] as? [String: Double])
        XCTAssertEqual(frame, ["x": 100, "y": 200, "w": 980, "h": 620])
        let cards = try XCTUnwrap(payload["cards"] as? [[String: Any]])
        XCTAssertEqual(cards.count, 3)
        XCTAssertEqual(cards[1]["key"] as? String, "extra:DeepSeek")
        XCTAssertEqual(cards[1]["title"] as? String, "DeepSeek")
        XCTAssertEqual(cards[1]["lines"] as? [String], ["餘額 10.00 CNY（儲值 10.00＋贈送 0.00）", "DeepSeek 官方 API"])
        XCTAssertEqual(cards[2]["key"] as? String, "extra:Qwen")
        XCTAssertEqual(cards[2]["title"] as? String, "Qwen")
        XCTAssertEqual(cards[2]["lines"] as? [String], [
            "已花 1.35／10.00 USD（本機上限，非帳戶餘額）",
            "3 次呼叫",
            "本機帳本",
        ])
    }
}
