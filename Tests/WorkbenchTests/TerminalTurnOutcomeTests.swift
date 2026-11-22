import XCTest
@testable import Workbench

final class TerminalTurnOutcomeTests: XCTestCase {
    func testCodexRetryEventThenSuccessDoesNotReportFailure() {
        var tracker = TerminalTurnTracker()
        let retry = tracker.observe(["type": "system", "subtype": "api_retry", "attempt": 1])
        XCTAssertNil(retry.outcome)
        let final = tracker.observe(["type": "result", "subtype": "success", "is_error": false, "result": "完成"])
        XCTAssertEqual(final.outcome, .completed)
        XCTAssertEqual(tracker.failureGeneration, 0)
        XCTAssertNil(TerminalTurnTracker.supervisionNotice(conversation: "假 Codex", event: final.event))
    }

    func testStopMarkerConvertsErrorResultToStoppedNotice() {
        var tracker = TerminalTurnTracker()
        _ = tracker.observe(["type": "user", "message": ["role": "user", "content": "[Request interrupted by user]"]])
        let result = tracker.observe(["type": "result", "subtype": "error_during_execution", "is_error": true])
        XCTAssertEqual(result.outcome, .stopped)
        XCTAssertEqual(result.event["stopped"] as? Bool, true)
        XCTAssertEqual(result.event["is_error"] as? Bool, false)
        XCTAssertEqual(tracker.failureGeneration, 0)
        XCTAssertEqual(tracker.stopGeneration, 1)
        XCTAssertTrue(TerminalTurnTracker.supervisionNotice(conversation: "假 Codex", event: result.event)?.contains("已停止") == true)
    }

    func testToolPermissionCancellationIsNotAnEngineFailure() {
        var tracker = TerminalTurnTracker()
        _ = tracker.observe(["type": "user", "message": ["role": "user", "content": "[Request interrupted by user for tool use]"]])
        let result = tracker.observe(["type": "result", "subtype": "error_during_execution", "is_error": true])
        XCTAssertEqual(result.outcome, .stopped)
        XCTAssertEqual(tracker.failureGeneration, 0)
        XCTAssertTrue(TerminalTurnTracker.supervisionNotice(conversation: "假本機", event: result.event)?.contains("已停止") == true)
    }

    func testOnlyTerminalFailureCreatesOneFailureNotice() {
        var tracker = TerminalTurnTracker()
        let result = tracker.observe(["type": "result", "subtype": "error_during_execution", "is_error": true, "result": "Codex 最終失敗"])
        let notice = TerminalTurnTracker.supervisionNotice(conversation: "假 Codex", event: result.event)
        XCTAssertEqual(result.outcome, .failed("Codex 最終失敗"))
        XCTAssertEqual(tracker.failureGeneration, 1)
        XCTAssertEqual(notice?.components(separatedBy: "引擎回報失敗").count, 2)
    }
}
