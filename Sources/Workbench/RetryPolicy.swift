import Foundation

/// Retry classification/backoff adapted from earendil-works/pi `packages/ai/src/utils/retry.ts`
/// (MIT, Mario Zechner, 2025); quota precedence and cancellation are wired for codenv sessions.
enum RetryPolicy {
    static let maxRetries = 3
    /// `completedRetries` is zero-based; returns (attempt number, delay seconds).
    static func plan(error: String, completedRetries: Int) -> (attempt: Int, delay: TimeInterval)? {
        guard completedRetries < maxRetries, isTransient(error) else { return nil }
        let attempt = completedRetries + 1
        return (attempt, delay(completedRetries: completedRetries))
    }

    static func delay(completedRetries: Int) -> TimeInterval {
        min(pow(2, Double(max(0, completedRetries))), 60)
    }

    static func isTransient(_ error: String) -> Bool {
        let s = error.lowercased()
        let quotaTerms = ["insufficient_quota", "quota", "billing", "usage limit", "usage_limit",
                          "payment required", "credit balance", "額度", "配額", "帳單", "用量上限"]
        if quotaTerms.contains(where: s.contains) { return false }

        let statusPattern = #"(?<![0-9])(429|500|502|503|504)(?![0-9])"#
        if s.range(of: statusPattern, options: .regularExpression) != nil { return true }
        let transientTerms = ["overloaded", "server busy", "too many requests", "temporarily unavailable",
                             "connection reset", "connection refused", "connection lost", "network connection was lost",
                             "socket hang up", "timed out", "timeout", "stream ended", "stream interrupted",
                             "stream cut", "rate limit", "rate_limit", "串流中途斷掉", "連線重置", "連線逾時"]
        if transientTerms.contains(where: s.contains) { return true }
        // Common transient URLError codes: timeout, cannot connect, connection lost, offline.
        return ["-1001", "-1004", "-1005", "-1009"].contains(where: s.contains)
    }

    static func event(attempt: Int, delay: TimeInterval) -> [String: Any] {
        let seconds = max(1, Int(ceil(delay)))
        return ["type": "system", "subtype": "api_retry", "attempt": attempt, "delay_seconds": seconds,
                "message": L("伺服器忙，\(seconds) 秒後重試（\(attempt)/\(maxRetries)）")]
    }

    /// A cancelled DispatchWorkItem does not invoke its operation; used by both bridges and the test probe.
    static func schedule(after delay: TimeInterval, on queue: DispatchQueue = .main, _ operation: @escaping () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem(block: operation)
        queue.asyncAfter(deadline: .now() + delay, execute: item)
        return item
    }

    static func runSelfTest(out path: String) -> Bool {
        let quota = ["insufficient_quota", "quota exceeded", "billing usage limit", "HTTP 429 quota exceeded"]
        let transient = ["HTTP 429", "伺服器回 503", "overloaded", "connection reset by peer", "串流中途斷掉", "URLError -1005", "rate limit", "rate_limit"]
        let nonTransientNumbers = ["port 5000 unavailable", "line 5024: invalid", "version 4290"]
        let checks: [(String, Bool)] = [
            ("quota_errors_never_retry", quota.allSatisfy { !isTransient($0) }),
            ("transient_errors_retry", transient.allSatisfy(isTransient)),
            ("embedded_status_digits_do_not_retry", nonTransientNumbers.allSatisfy { !isTransient($0) }),
            ("retry_limit_is_three", (0..<maxRetries).allSatisfy { plan(error: "HTTP 503", completedRetries: $0) != nil } && plan(error: "HTTP 503", completedRetries: maxRetries) == nil),
            ("backoff_doubles_and_caps", [0, 1, 2].map { delay(completedRetries: $0) } == [1, 2, 4] && delay(completedRetries: 10) == 60),
            ("retry_notice_has_attempt_and_delay", event(attempt: 1, delay: 2)["message"] as? String == "伺服器忙，2 秒後重試（1/3）")
        ]
        let canceled = DispatchSemaphore(value: 0)
        let work = schedule(after: 0.03, on: .global()) { canceled.signal() }
        work.cancel()
        let cancellationPassed = canceled.wait(timeout: .now() + 0.08) == .timedOut
        var rows = checks + [("cancelled_retry_does_not_run", cancellationPassed)]
        let ok = rows.allSatisfy(\.1)
        rows.append(("all_checks_passed", ok))
        let text = rows.map { "\($0.0)=\($0.1)" }.joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        return ok
    }
}
