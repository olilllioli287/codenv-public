import Darwin
import Foundation
import XCTest
@testable import Workbench

final class G45RecoveryAndHandoffTests: XCTestCase {
    private func makeTempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("g45-\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func waitProcessDead(_ pid: pid_t, timeout: TimeInterval = 0.6) -> Bool {
        guard pid > 1 else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return kill(pid, 0) != 0 && errno == ESRCH
    }

    private func forceKill(_ pid: pid_t) {
        guard pid > 1 else { return }
        if kill(pid, 0) == 0 {
            _ = kill(pid, SIGKILL)
            _ = waitProcessDead(pid, timeout: 0.5)
        }
    }

    private func readRecordedPid(_ file: URL) throws -> pid_t {
        let text = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = text.split(whereSeparator: \.isWhitespace).first, let pid = Int32(first) else {
            throw NSError(domain: "G45Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "無效的 pid 檔：\(text)"])
        }
        return pid
    }

    private func detachedTermIgnoringPerlLaunch(pidFile: URL) -> String {
        let q = shellQuote(pidFile.path)
        let perlCode = #"$SIG{TERM}="IGNORE"; open STDIN,"<","/dev/null"; open STDOUT,">","/dev/null"; open STDERR,">","/dev/null"; my $p=$ARGV[0]; open my $fh,">","$p.tmp" or die; print $fh "$$\n"; close $fh; rename "$p.tmp",$p; my $end=time+8; while(time<$end){ select(undef,undef,undef,0.05) }"#
        let waitCode = #"my $e=time+2; until(-s $ARGV[0] || time>=$e){ select(undef,undef,undef,0.01) }"#
        return "/usr/bin/perl -e \(shellQuote(perlCode)) \(q) </dev/null >/dev/null 2>&1 &\n"
            + "/usr/bin/perl -e \(shellQuote(waitCode)) \(q)\n"
    }

    func testNormalExitCleansResidualDetachedBackgroundChild() throws {
        let dir = try makeTempDir("normal-residual")
        let pidFile = dir.appendingPathComponent("child.pid")
        let script = detachedTermIgnoringPerlLaunch(pidFile: pidFile) + "printf 'ok'; exit 0\n"

        let start = ProcessInfo.processInfo.systemUptime
        let result = try Handoff.runGrouped(script: script, directory: dir.path, timeout: 2.0, grace: 0.25)
        let elapsed = ProcessInfo.processInfo.systemUptime - start

        let childPid = try readRecordedPid(pidFile)
        defer { forceKill(childPid) }

        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(data: result.stdout, encoding: .utf8), "ok")
        XCTAssertLessThan(elapsed, 2.0)
        XCTAssertTrue(waitProcessDead(childPid, timeout: 0.6), "正常結束後同群組殘留背景子程序應被清掉（pid=\(childPid)）")
    }

    func testTimeoutTermExitStillGraceKillsDetachedTermIgnoringSibling() throws {
        let dir = try makeTempDir("timeout-detached-sibling")
        let pidFile = dir.appendingPathComponent("sibling.pid")
        let script = detachedTermIgnoringPerlLaunch(pidFile: pidFile) + "/bin/sleep 8 & exit 0\n"

        let start = ProcessInfo.processInfo.systemUptime
        let result = try Handoff.runGrouped(script: script, directory: dir.path, timeout: 0.25, grace: 0.25)
        let elapsed = ProcessInfo.processInfo.systemUptime - start

        let childPid = try readRecordedPid(pidFile)
        defer { forceKill(childPid) }

        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(elapsed, 2.0)
        XCTAssertGreaterThanOrEqual(elapsed, 0.45, "逾時後應保留 grace 視窗再送 SIGKILL，不可因管子關閉提前取消")
        XCTAssertTrue(waitProcessDead(childPid, timeout: 0.6), "握管程序 TERM 退出後，忽略 TERM 的同群組關管子程序仍應被 grace SIGKILL 清掉（pid=\(childPid)）")
    }

    func testTimeoutTermRespondingAndTermIgnoringPipeHolders() throws {
        let dir = try makeTempDir("timeout-pipe-holders")

        let start1 = ProcessInfo.processInfo.systemUptime
        let r1 = try Handoff.runGrouped(script: "/bin/sleep 4 & exit 0", directory: dir.path, timeout: 0.2, grace: 0.25)
        let elapsed1 = ProcessInfo.processInfo.systemUptime - start1
        XCTAssertTrue(r1.timedOut)
        XCTAssertLessThan(elapsed1, 2.0)

        let start2 = ProcessInfo.processInfo.systemUptime
        let r2 = try Handoff.runGrouped(
            script: #"/usr/bin/perl -e '$SIG{TERM}="IGNORE"; my $end=time+4; while (time < $end) { select(undef, undef, undef, 0.1) }' & exit 0"#,
            directory: dir.path,
            timeout: 0.2,
            grace: 0.25
        )
        let elapsed2 = ProcessInfo.processInfo.systemUptime - start2
        XCTAssertTrue(r2.timedOut)
        XCTAssertLessThan(elapsed2, 2.0)
    }

    func testTimeoutGracefulDetachedSiblingExitsBeforeFullGrace() throws {
        let dir = try makeTempDir("timeout-graceful-sibling")
        let pidFile = dir.appendingPathComponent("graceful.pid")
        let markerFile = dir.appendingPathComponent("graceful.marker")
        let perlCode = #"my $got=0; $SIG{TERM}=sub{$got=1}; open STDIN,"<","/dev/null"; open STDOUT,">","/dev/null"; open STDERR,">","/dev/null"; my $p=$ARGV[0]; open my $fh,">","$p.tmp" or die; print $fh "$$\n"; close $fh; rename "$p.tmp",$p; my $end=time+8; while(!$got && time<$end){ select(undef,undef,undef,0.02) } if($got){ select(undef,undef,undef,0.08); open my $mf,">",$ARGV[1] or die; print $mf "graceful\n"; close $mf; }"#
        let waitCode = #"my $e=time+2; until(-s $ARGV[0] || time>=$e){ select(undef,undef,undef,0.01) }"#
        let script = "/usr/bin/perl -e \(shellQuote(perlCode)) \(shellQuote(pidFile.path)) \(shellQuote(markerFile.path)) </dev/null >/dev/null 2>&1 &\n"
            + "/usr/bin/perl -e \(shellQuote(waitCode)) \(shellQuote(pidFile.path))\n"
            + "/bin/sleep 8 & exit 0\n"

        let start = ProcessInfo.processInfo.systemUptime
        let result = try Handoff.runGrouped(script: script, directory: dir.path, timeout: 0.25, grace: 0.8)
        let elapsed = ProcessInfo.processInfo.systemUptime - start

        let childPid = try readRecordedPid(pidFile)
        defer { forceKill(childPid) }

        XCTAssertTrue(result.timedOut)
        XCTAssertTrue(waitProcessDead(childPid, timeout: 0.5))
        let marker = try? String(contentsOf: markerFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(marker, "graceful", "響應 SIGTERM 的同群組子程序應可在 grace 內優雅退出")
        XCTAssertLessThan(elapsed, 0.75, "同群組子程序在 grace 內清空後應提早返回，不必等滿整個 grace")
    }

    func testStoreEmptyOrMissingGuardDoesNotFireWhenBothPrimaryAndBackupCorrupt() {
        let broken = Data("not-json".utf8)
        // 主檔與 .bak 皆非空且損壞：不得先落入「空檔或不存在」分支（避免重複記不符事實的 EventLog）。
        XCTAssertFalse(Store.shouldProtectEmptyOrMissingPrimary(
            raw: broken, primaryMissing: false, backupHasUnrecoverableData: true
        ))
        // 主檔存在但權限／磁碟問題讀不到（raw == nil && !primaryMissing）：應交由後續「存在但讀不出來」分支處理。
        XCTAssertFalse(Store.shouldProtectEmptyOrMissingPrimary(
            raw: nil, primaryMissing: false, backupHasUnrecoverableData: true
        ))
        // 主檔 0 byte 空檔 ＋ 備份不可恢復：必須進入保護分支。
        XCTAssertTrue(Store.shouldProtectEmptyOrMissingPrimary(
            raw: Data(), primaryMissing: false, backupHasUnrecoverableData: true
        ))
        // 主檔不存在 ＋ 備份不可恢復：必須進入保護分支。
        XCTAssertTrue(Store.shouldProtectEmptyOrMissingPrimary(
            raw: nil, primaryMissing: true, backupHasUnrecoverableData: true
        ))
        // 備份無不可恢復資料時不進保護分支。
        XCTAssertFalse(Store.shouldProtectEmptyOrMissingPrimary(
            raw: Data(), primaryMissing: false, backupHasUnrecoverableData: false
        ))
        XCTAssertFalse(Store.shouldProtectEmptyOrMissingPrimary(
            raw: nil, primaryMissing: true, backupHasUnrecoverableData: false
        ))
    }
}
