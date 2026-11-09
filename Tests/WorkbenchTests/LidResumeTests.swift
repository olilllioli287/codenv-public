import XCTest
@testable import Workbench

final class LidResumeTests: XCTestCase {
    private func makeKeeper() -> (LidKeeper, SimLidEnv) {
        let env = SimLidEnv()
        let keeper = LidKeeper(env: env,
                               logURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                               markerURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        keeper.limits.statusEvery = .greatestFiniteMagnitude
        keeper.limits.preholdOffDelay = .greatestFiniteMagnitude
        keeper.resumeDelay = 0.05
        return (keeper, env)
    }

    private func prepareClosure(_ keeper: LidKeeper, env: SimLidEnv, ids: [UUID], received: Set<UUID>) {
        keeper.workingIDs = { ids }
        keeper.workingCount = { ids.count }
        keeper.sendStop = { received.contains($0) }
        keeper.sessionIsAvailable = { received.contains($0) }
        keeper.sessionIsArchived = { _ in false }
        keeper.tick() // 預擋
        env.closed = true
        keeper.tick() // stop
    }

    func testResumeMessageSentOnlyToStoppedSessions() {
        let (keeper, env) = makeKeeper()
        let stopped = UUID(), idle = UUID()
        prepareClosure(keeper, env: env, ids: [stopped], received: [stopped])
        var resumed: [UUID] = []
        keeper.sendResume = { resumed.append($0) }
        env.closed = false
        keeper.tick()
        let sent = expectation(description: "resume sent")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { sent.fulfill() }
        wait(for: [sent], timeout: 1)
        XCTAssertEqual(resumed, [stopped])
        XCTAssertFalse(resumed.contains(idle))
    }

    func testResumeMessageSentExactlyOnce() {
        let (keeper, env) = makeKeeper()
        let id = UUID()
        prepareClosure(keeper, env: env, ids: [id], received: [id])
        var count = 0
        keeper.sendResume = { _ in count += 1 }
        env.closed = false
        keeper.tick()
        let done = expectation(description: "first debounce")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { done.fulfill() }
        wait(for: [done], timeout: 1)
        env.closed = true; keeper.tick(); env.closed = false; keeper.tick()
        let doneAgain = expectation(description: "second debounce")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { doneAgain.fulfill() }
        wait(for: [doneAgain], timeout: 1)
        XCTAssertEqual(count, 1)
        XCTAssertTrue(keeper.stoppedSessionIDs.isEmpty)
    }

    func testLidDebounceCancelsOnQuickClose() {
        let (keeper, env) = makeKeeper()
        let id = UUID()
        prepareClosure(keeper, env: env, ids: [id], received: [id])
        var count = 0
        keeper.sendResume = { _ in count += 1 }
        env.closed = false; keeper.tick()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { env.closed = true; keeper.tick() }
        let done = expectation(description: "debounce expired")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { done.fulfill() }
        wait(for: [done], timeout: 1)
        XCTAssertEqual(count, 0)
    }

    func testSubToggleDisabledPreventsResumeMessage() {
        let (keeper, env) = makeKeeper()
        let id = UUID()
        prepareClosure(keeper, env: env, ids: [id], received: [id])
        keeper.resumeEnabled = { false }
        var count = 0; keeper.sendResume = { _ in count += 1 }
        env.closed = false; keeper.tick()
        let done = expectation(description: "debounce expired")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { done.fulfill() }
        wait(for: [done], timeout: 1)
        XCTAssertEqual(count, 0)
    }

    func testArchivedSessionSkippedOnResume() {
        let (keeper, env) = makeKeeper()
        let archived = UUID(), active = UUID()
        prepareClosure(keeper, env: env, ids: [archived, active], received: [archived, active])
        keeper.sessionIsArchived = { $0 == archived }
        var resumed: [UUID] = []; keeper.sendResume = { resumed.append($0) }
        env.closed = false; keeper.tick()
        let done = expectation(description: "debounce expired")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { done.fulfill() }
        wait(for: [done], timeout: 1)
        XCTAssertEqual(resumed, [active])
    }

    func testRemovedSessionSkippedOnResume() {
        let (keeper, env) = makeKeeper()
        let removed = UUID(), active = UUID()
        prepareClosure(keeper, env: env, ids: [removed, active], received: [removed, active])
        keeper.sessionIsAvailable = { $0 == active }
        var resumed: [UUID] = []; keeper.sendResume = { resumed.append($0) }
        env.closed = false; keeper.tick()
        let done = expectation(description: "debounce expired")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { done.fulfill() }
        wait(for: [done], timeout: 1)
        XCTAssertEqual(resumed, [active])
    }
}
