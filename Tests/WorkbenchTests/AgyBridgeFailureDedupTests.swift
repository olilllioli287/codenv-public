import XCTest
@testable import Workbench

final class AgyBridgeFailureDedupTests: XCTestCase {
    private func makeBridge() -> AgyBridge {
        AgyBridge(session: UUID(), model: "unit-test-model")
    }

    private func enqueue(_ bridge: AgyBridge, id: String) {
        _ = bridge.outgoing([
            "type": "user",
            "uuid": id,
            "message": ["role": "user", "content": "synthetic message \(id)"]
        ])
    }

    private func nonFatalError() -> [String: Any] {
        ["event": "error", "error": ["message": "synthetic non-fatal error"]]
    }

    private func fatalErrorEvent() -> [String: Any] {
        ["event": "fatal_error", "error": ["message": "synthetic fatal error"]]
    }

    private func assertSingleErrorResult(_ results: [[String: Any]]) {
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?["is_error"] as? Bool, true)
    }

    func testNonFatalErrorThenProcessExitDoesNotDuplicateFailure() {
        let bridge = makeBridge()
        enqueue(bridge, id: "first-message")

        let results = bridge.incoming(nonFatalError())
        assertSingleErrorResult(results)

        // waiting is private; processExitFailure is the observable check that the first
        // error result already accounted for the queued message.
        XCTAssertNil(bridge.processExitFailure(code: 3, stderr: "synthetic exit"))
    }

    func testNonFatalErrorWithNewQueuedMessageStillReportsProcessExitFailure() {
        let bridge = makeBridge()
        enqueue(bridge, id: "first-message")

        let results = bridge.incoming(nonFatalError())
        assertSingleErrorResult(results)
        enqueue(bridge, id: "second-message")

        XCTAssertNotNil(bridge.processExitFailure(code: 3, stderr: "synthetic exit"))
    }

    func testProcessExitWithoutErrorStillReportsFailure() {
        let bridge = makeBridge()
        enqueue(bridge, id: "first-message")

        XCTAssertNotNil(bridge.processExitFailure(code: 3, stderr: "synthetic crash"))
    }

    func testFatalErrorThenProcessExitStaysSingleFailure() {
        let bridge = makeBridge()
        enqueue(bridge, id: "first-message")

        _ = bridge.incoming(fatalErrorEvent())

        // 維持既有行為：fatal error 已回報並清空目前回合，程序退出不再重複回報。
        XCTAssertNil(bridge.processExitFailure(code: 3, stderr: "synthetic fatal exit"))
    }
}
