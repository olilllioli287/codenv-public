import XCTest
import Darwin
@testable import Workbench

final class UsageLoginAndAgy2Tests: XCTestCase {
    private func now() -> Date {
        Date(timeIntervalSince1970: 1_800_000_000)
    }

    func testLoginExpiryTextBoundariesAndLevels() {
        let current = now()
        XCTAssertNil(UsageMonitor.loginExpiryText(expiresAt: nil, now: current))

        let expired = UsageMonitor.loginExpiryText(expiresAt: current.addingTimeInterval(-1), now: current)
        XCTAssertEqual(expired?.text, "登入已過期")
        XCTAssertEqual(expired?.level, .expired)

        let exactlyTwoDays = UsageMonitor.loginExpiryText(
            expiresAt: current.addingTimeInterval(2 * 86_400), now: current
        )
        XCTAssertEqual(exactlyTwoDays?.level, .warning)

        let overTwoDays = UsageMonitor.loginExpiryText(
            expiresAt: current.addingTimeInterval(2.01 * 86_400), now: current
        )
        XCTAssertEqual(overTwoDays?.level, .normal)

        let onePointNineDays = UsageMonitor.loginExpiryText(
            expiresAt: current.addingTimeInterval(1.9 * 86_400), now: current
        )
        XCTAssertEqual(onePointNineDays?.text, "登入 1 天後到期")
        XCTAssertEqual(onePointNineDays?.level, .warning)

        let twelveHours = UsageMonitor.loginExpiryText(
            expiresAt: current.addingTimeInterval(12 * 3_600), now: current
        )
        XCTAssertEqual(twelveHours?.text, "登入 12 小時後到期")
        XCTAssertEqual(twelveHours?.level, .warning)

        let thirtyMinutes = UsageMonitor.loginExpiryText(
            expiresAt: current.addingTimeInterval(30 * 60), now: current
        )
        XCTAssertEqual(thirtyMinutes?.text, "登入 1 小時後到期")
        XCTAssertEqual(thirtyMinutes?.level, .warning)
    }

    func testClaudeLoginExpiryJSONParsesDateWithoutEmailInResult() throws {
        let output = #"{"loggedIn":true,"authMethod":"claude.ai","loginExpiresAt":"2026-11-18T16:00:42.873Z","email":"test@example.invalid"}"#
        let parsed = try XCTUnwrap(UsageMonitor.parseClaudeLoginExpiry(output))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expected = try XCTUnwrap(formatter.date(from: "2026-11-18T16:00:42.873Z"))

        XCTAssertEqual(parsed.expiresAt, expected)
        XCTAssertFalse(String(describing: type(of: parsed)).localizedCaseInsensitiveContains("email"))
        XCTAssertFalse(String(describing: parsed).localizedCaseInsensitiveContains("email"))
    }

    func testClaudeLoginExpiryJSONWithoutDateOrWithInvalidJSONReturnsNil() {
        XCTAssertNil(UsageMonitor.parseClaudeLoginExpiry(
            #"{"loggedIn":true,"authMethod":"apiKey","email":"test@example.invalid"}"#
        ))
        XCTAssertNil(UsageMonitor.parseClaudeLoginExpiry("not-json"))
    }

    func testClaudeAndDockerOverridesAreIgnoredOutsideTestLaunch() {
        let stateArguments = ["codenv", "--state-dir", "/tmp/exam-state"]
        XCTAssertNil(UsageMonitor.claudePath(environment: [:], arguments: stateArguments))
        XCTAssertNil(UsageMonitor.dockerPath(environment: [:], arguments: stateArguments))

        XCTAssertNotEqual(
            UsageMonitor.claudePath(
                environment: ["CODENV_CLAUDE_PATH": "/tmp/fake-claude"], arguments: ["codenv"]
            ),
            "/tmp/fake-claude"
        )
        XCTAssertNotEqual(
            UsageMonitor.dockerPath(
                environment: ["CODENV_DOCKER_PATH": "/tmp/fake-docker"], arguments: ["codenv"]
            ),
            "/tmp/fake-docker"
        )
    }

    func testDockerContextSocketPathParser() {
        let output = #"[{"Endpoints":{"docker":{"Host":"unix:///tmp/fake-kiri/docker.sock"}}}]"#
        XCTAssertEqual(UsageMonitor.parseDockerSocketPath(output), "/tmp/fake-kiri/docker.sock")
        XCTAssertNil(UsageMonitor.parseDockerSocketPath("not-json"))
    }

    private struct FakeDocker {
        let root: URL
        let script: URL
        let socket: URL
        let counter: URL
    }

    private func makeFakeDocker() throws -> FakeDocker {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-agy2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("docker-fake")
        let socket = root.appendingPathComponent("missing-docker.sock")
        let counter = root.appendingPathComponent("docker-operations.log")
        let contents = #"""
        #!/bin/sh
        if [ "$1" = "context" ] && [ "$2" = "inspect" ]; then
          printf '[{"Endpoints":{"docker":{"Host":"unix://%s"}}}]\n' "$AGY2_SOCKET"
          exit 0
        fi
        if [ "$1" = "--context" ] && [ "$3" = "inspect" ]; then
          printf '%s\n' inspect >> "$AGY2_COUNTER"
          if [ "$AGY2_MODE" = "inspect-connect-fails" ]; then
            printf '%s\n' 'Cannot connect to the Docker daemon' >&2
            exit 1
          fi
          if [ "$AGY2_MODE" = "inspect-object-missing" ]; then
            printf '%s\n' 'No such object: agy2' >&2
            exit 1
          fi
          if [ "$AGY2_MODE" = "inspect-json" ]; then
            printf '%s\n' '[{"State":{"Running":false}}]'
          else
            printf '%s\n' "$AGY2_RUNNING"
          fi
          exit 0
        fi
        if [ "$1" = "--context" ] && [ "$3" = "exec" ]; then
          printf '%s\n' exec >> "$AGY2_COUNTER"
          if [ "$AGY2_MODE" = "exec-fails" ]; then
            printf '%s\n' 'synthetic failure' >&2
            exit 1
          fi
          printf '%s\n' "$AGY2_QUOTA_OUTPUT"
          exit 0
        fi
        exit 98
        """#
        try contents.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return FakeDocker(root: root, script: script, socket: socket, counter: counter)
    }

    private func fakeDockerEnvironment(
        _ fixture: FakeDocker,
        mode: String,
        running: Bool,
        quotaOutput: String = ""
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["AGY2_SOCKET"] = fixture.socket.path
        environment["AGY2_COUNTER"] = fixture.counter.path
        environment["AGY2_MODE"] = mode
        environment["AGY2_RUNNING"] = running ? "true" : "false"
        environment["AGY2_QUOTA_OUTPUT"] = quotaOutput
        return environment
    }

    private func runAgy2(
        _ fixture: FakeDocker,
        mode: String = "",
        running: Bool = false,
        socketExists: Bool,
        quotaOutput: String = ""
    ) -> Agy2QuotaStatus? {
        let environment = fakeDockerEnvironment(
            fixture, mode: mode, running: running, quotaOutput: quotaOutput
        )
        return UsageMonitor.fetchAgy2Quota(
            dockerPath: fixture.script.path,
            fileExists: { path in
                XCTAssertEqual(path, fixture.socket.path)
                return socketExists
            },
            runner: { executable, arguments, timeout in
                ExternalCommand.run(
                    executable,
                    arguments: arguments,
                    timeout: timeout,
                    environment: environment
                )
            }
        )
    }

    func testAgy2MissingSocketDoesNotRunInspectOrExec() throws {
        let fixture = try makeFakeDocker()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.socket.path))

        XCTAssertEqual(runAgy2(fixture, socketExists: false), Agy2QuotaStatus.down as Agy2QuotaStatus?)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.counter.path))
    }

    func testAgy2RunningFalseIsDown() throws {
        let fixture = try makeFakeDocker()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertEqual(
            runAgy2(fixture, running: false, socketExists: true),
            Agy2QuotaStatus.down as Agy2QuotaStatus?
        )
        XCTAssertEqual(try String(contentsOf: fixture.counter, encoding: .utf8), "inspect\n")
    }

    func testAgy2UnrecognizedInspectOutputIsUnreadable() throws {
        let fixture = try makeFakeDocker()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertEqual(
            runAgy2(fixture, mode: "inspect-json", socketExists: true),
            Agy2QuotaStatus.unreadable as Agy2QuotaStatus?
        )
        XCTAssertEqual(try String(contentsOf: fixture.counter, encoding: .utf8), "inspect\n")
    }

    func testAgy2DockerDaemonConnectionFailureIsDown() throws {
        let fixture = try makeFakeDocker()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertEqual(
            runAgy2(fixture, mode: "inspect-connect-fails", socketExists: true),
            Agy2QuotaStatus.down as Agy2QuotaStatus?
        )
        XCTAssertEqual(try String(contentsOf: fixture.counter, encoding: .utf8), "inspect\n")
    }

    func testAgy2MissingContainerObjectIsUnreadable() throws {
        let fixture = try makeFakeDocker()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertEqual(
            runAgy2(fixture, mode: "inspect-object-missing", socketExists: true),
            Agy2QuotaStatus.unreadable as Agy2QuotaStatus?
        )
        XCTAssertEqual(try String(contentsOf: fixture.counter, encoding: .utf8), "inspect\n")
    }

    func testAgy2ExecFailureIsUnreadable() throws {
        let fixture = try makeFakeDocker()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertEqual(
            runAgy2(fixture, mode: "exec-fails", running: true, socketExists: true),
            Agy2QuotaStatus.unreadable as Agy2QuotaStatus?
        )
        XCTAssertEqual(try String(contentsOf: fixture.counter, encoding: .utf8), "inspect\nexec\n")
    }

    func testExternalCommandTimeoutKillsChildProcessGroup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-command-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let script = root.appendingPathComponent("sleep-child.sh")
        let pidFile = root.appendingPathComponent("child.pid")
        defer {
            if let pidText = try? String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               let childPID = Int32(pidText), isProcessAlive(pid_t(childPID)) {
                _ = Darwin.kill(pid_t(childPID), SIGKILL)
            }
            try? FileManager.default.removeItem(at: root)
        }
        try "#!/bin/sh\n/bin/sleep 30 &\nprintf '%s\\n' \"$!\" > \"$CHILD_PID_FILE\"\nwait\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

        var environment = ProcessInfo.processInfo.environment
        environment["CHILD_PID_FILE"] = pidFile.path
        let result = ExternalCommand.run(
            "/bin/sh",
            arguments: [script.path],
            timeout: 1,
            killGrace: 1,
            environment: environment
        )
        XCTAssertEqual(result?.timedOut, true)

        let pidText = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let childPID = pid_t(try XCTUnwrap(Int32(pidText)))

        let deadline = Date().addingTimeInterval(2)
        while isProcessAlive(childPID) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertFalse(isProcessAlive(childPID), "逾時後假腳本的 sleep 子程序應已不存在")
    }

    private func isProcessAlive(_ pid: pid_t) -> Bool {
        errno = 0
        return Darwin.kill(pid, 0) == 0 || errno != ESRCH
    }
}
