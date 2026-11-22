import XCTest
@testable import Workbench

final class UsageCopilotAndHintTests: XCTestCase {
    private func json(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func copilotJSON(_ snapshots: [String: Any]) -> [String: Any] {
        ["quota_snapshots": snapshots]
    }

    func testParseCopilotFreePlanKeepsLegacyText() throws {
        let text = try json(copilotJSON([
            "chat": [
                "entitlement": 200,
                "remaining": 150,
                "percent_remaining": 75,
                "quota_reset_date_utc": "2026-12-01T00:00:00Z"
            ]
        ]))

        let parsed = UsageMonitor.parseCopilot(text)
        XCTAssertEqual(parsed?.note, "剩 150／200 次")
        XCTAssertEqual(parsed?.buckets.first?.label, "每月")
        XCTAssertEqual(parsed?.buckets.first?.used, 25)
    }

    func testParseCopilotStudentPlanUsesPremiumInteractions() throws {
        let text = try json(copilotJSON([
            "chat": ["unlimited": true],
            "completions": ["unlimited": true],
            "premium_interactions": [
                "entitlement": 200,
                "remaining": 199,
                "percent_remaining": 99.5,
                "quota_reset_date_utc": "2026-12-01T00:00:00Z"
            ]
        ]))

        let parsed = UsageMonitor.parseCopilot(text)
        XCTAssertEqual(parsed?.remaining, 199)
        XCTAssertEqual(parsed?.total, 200)
        XCTAssertEqual(parsed?.footnote, "補全不限，對話用額度")
    }

    func testStudentFootnoteRequiresUnlimitedCompletions() throws {
        let text = try json(copilotJSON([
            "chat": ["unlimited": true],
            "completions": ["unlimited": false],
            "premium_interactions": ["entitlement": 200, "remaining": 199]
        ]))

        XCTAssertNil(UsageMonitor.parseCopilot(text)?.footnote)
    }

    func testStudentWithoutPremiumInteractionsHasNoBucketOrCounts() throws {
        let text = try json(copilotJSON([
            "chat": ["unlimited": true],
            "completions": ["unlimited": true]
        ]))

        let parsed = UsageMonitor.parseCopilot(text)
        XCTAssertEqual(parsed?.buckets.count, 0)
        XCTAssertNotNil(parsed?.footnote)
        XCTAssertNil(parsed?.remaining)
        XCTAssertNil(parsed?.total)
    }

    func testMissingChatAndPremiumInteractionsReturnsNil() throws {
        let text = try json(copilotJSON([
            "completions": ["unlimited": true]
        ]))

        XCTAssertNil(UsageMonitor.parseCopilot(text))
    }

    func testMalformedPremiumInteractionsDoesNotCrash() throws {
        let malformed = [
            copilotJSON([
                "chat": ["unlimited": true],
                "completions": ["unlimited": true],
                "premium_interactions": ["entitlement": "200", "remaining": 199]
            ]),
            copilotJSON([
                "chat": ["unlimited": true],
                "completions": ["unlimited": true],
                "premium_interactions": ["remaining": 199]
            ])
        ]

        for object in malformed {
            _ = UsageMonitor.parseCopilot(try json(object))
        }
    }

    private func fixedNow() -> Date {
        Date(timeIntervalSince1970: 1_800_000_000)
    }

    private func hint(
        cycleDays: Double?,
        daysUntilReset: Double,
        remainingFraction: Double? = 0.6,
        poolName: String = "Copilot",
        remainingText: String = "剩 60%"
    ) -> String? {
        let now = fixedNow()
        let resetAt = now.addingTimeInterval(daysUntilReset * 86_400)
        return UsageMonitor.expiringSoonHint(
            poolName: poolName,
            remainingFraction: remainingFraction,
            resetAt: resetAt,
            cycleDays: cycleDays,
            now: now,
            remainingText: remainingText
        )
    }

    func testExpiringSoonHintUsesStrictRatioAndTimeBoundaries() {
        XCTAssertNil(hint(cycleDays: nil, daysUntilReset: 3))
        XCTAssertNil(hint(cycleDays: 30, daysUntilReset: 3, remainingFraction: 0.5))
        XCTAssertNotNil(hint(cycleDays: 30, daysUntilReset: 3, remainingFraction: 0.5001))
        XCTAssertNil(hint(cycleDays: 30, daysUntilReset: 7))
        XCTAssertNil(hint(cycleDays: 7, daysUntilReset: 3.5, poolName: "Kaggle"))
        XCTAssertNotNil(hint(cycleDays: 7, daysUntilReset: 3.4, poolName: "Kaggle"))
        XCTAssertNil(hint(cycleDays: 30, daysUntilReset: -0.01))
    }

    func testExpiringSoonHintRoundsDaysUpAndHandlesLessThanOneDay() {
        let rounded = hint(cycleDays: 30, daysUntilReset: 3.4, remainingFraction: 0.6)
        XCTAssertTrue(rounded?.contains("4 天後重置") == true)

        let lessThanOneDay = hint(cycleDays: 30, daysUntilReset: 0.5)
        XCTAssertTrue(lessThanOneDay?.contains("1 天內重置") == true)
    }

    func testExpiringSoonHintOmitsPrefixForEmptyPoolName() {
        let now = fixedNow()
        let result = UsageMonitor.expiringSoonHint(
            poolName: "",
            remainingFraction: 0.92,
            resetAt: now.addingTimeInterval(12 * 60 * 60),
            cycleDays: 30,
            now: now,
            remainingText: "92%"
        )

        XCTAssertEqual(result, "剩 92%，1 天內重置")
    }

    func testExpiringSoonHintTreatsZeroDenominatorAsUnavailableRatio() {
        let zeroDenominatorRatio: Double? = nil // remaining / total is undefined when total is 0.
        XCTAssertNil(hint(cycleDays: 30, daysUntilReset: 3, remainingFraction: zeroDenominatorRatio))
        XCTAssertNil(hint(cycleDays: 30, daysUntilReset: 3, remainingFraction: nil))
    }

    func testGhPathUsesOverrideOnlyForTestLaunchArguments() {
        let override = "/tmp/exam-fake-gh"
        let environment = ["CODENV_GH_PATH": override]

        XCTAssertEqual(
            UsageMonitor.ghPath(environment: environment, arguments: ["codenv", "--state-dir", "/tmp/exam-state"]),
            override
        )
        XCTAssertNotEqual(
            UsageMonitor.ghPath(environment: environment, arguments: ["codenv"]),
            override
        )
    }

    private func codexAccount(buckets: [UsageBucket]) -> CodexUsageAccountQuota {
        CodexUsageAccountQuota(
            id: "free-test-account",
            user: "free@example.test",
            plan: "free",
            active: true,
            buckets: buckets,
            resetCredits: 0,
            resetExpiries: []
        )
    }

    private func resetDate() throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-12-01T16:30:00Z"))
    }

    func testCodexFreeResetTextUsesTaipeiCalendarDate() throws {
        let account = codexAccount(buckets: [
            UsageBucket(label: "30 天", used: 10, resets: "x", resetAt: try resetDate())
        ])

        XCTAssertEqual(UsageMonitor.codexFreeResetText(account), "12/2 重置")
    }

    func testCodexFreeResetTextReturnsNilWithoutResetDate() {
        let account = codexAccount(buckets: [
            UsageBucket(label: "30 天", used: 10, resets: "x")
        ])

        XCTAssertNil(UsageMonitor.codexFreeResetText(account))
    }

    func testCodexFreeResetTextFallsBackToSingleBucket() throws {
        let account = codexAccount(buckets: [
            UsageBucket(label: "其他週期", used: 10, resets: "x", resetAt: try resetDate())
        ])

        XCTAssertEqual(UsageMonitor.codexFreeResetText(account), "12/2 重置")
    }

    func testCodexFreeResetTextDoesNotFallBackWhenMultipleBucketsDoNotMatch() throws {
        let date = try resetDate()
        let account = codexAccount(buckets: [
            UsageBucket(label: "每週", used: 10, resets: "x", resetAt: date),
            UsageBucket(label: "每年", used: 20, resets: "y", resetAt: date)
        ])

        XCTAssertNil(UsageMonitor.codexFreeResetText(account))
    }
}
