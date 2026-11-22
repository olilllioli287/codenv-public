import XCTest
@testable import Workbench

/// 07-24：闔蓋停止通知同聊天室 5 秒內只送一次（LidKeeper 自己這層；接線層另有 LidNoticeDeduplicator）
final class LidStopDedupeTests: XCTestCase {
    func testStopSentOncePerWindow() {
        let env = SimLidEnv()
        let keeper = LidKeeper(env: env,
                               logURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                               markerURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        keeper.limits.statusEvery = .greatestFiniteMagnitude
        keeper.limits.preholdOffDelay = .greatestFiniteMagnitude
        keeper.resumeDelay = 0.02
        let id = UUID()
        keeper.workingIDs = { [id] }
        keeper.workingCount = { 1 }
        var stops = 0
        keeper.sendStop = { _ in stops += 1; return true }
        keeper.sessionIsAvailable = { _ in true }
        keeper.sessionIsArchived = { _ in false }
        keeper.tick()
        env.closed = true; keeper.tick()
        env.closed = false; keeper.tick()
        env.closed = true; keeper.tick()   // 5 秒內第二次闔蓋
        XCTAssertEqual(stops, 1)
        // 視窗過後可再送
        keeper.resumeDedupeWindow = 0
        env.closed = false; keeper.tick()
        env.closed = true; keeper.tick()
        XCTAssertEqual(stops, 2)
    }
}
