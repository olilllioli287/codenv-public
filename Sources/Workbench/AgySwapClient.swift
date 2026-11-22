import Foundation
import Darwin

// MARK: - agy-swap 單點封裝（規格 3 A）
// 只呼叫 `status --json` 與 `run`；絕不呼叫 save／use／need／mark／mark-invalid／switch-for，也不碰鑰匙圈。
// 使用 posix_spawn + POSIX_SPAWN_SETPGROUP 讓子程序自成新行程群組：
//   收法＝只對子程序 pid 送 SIGTERM，等待 killGrace（預設 10 秒）後仍在才對 -pgid 送 SIGKILL。
//   禁止對 codenv 自己的行程群組送訊號。
// 子程序環境變數只給 HOME、PATH（含 /usr/bin:/bin）、LANG。

struct AgySwapConfig: Equatable {
    static let defaultStatusTimeout: TimeInterval = 25
    static let defaultUsageRunTimeout: TimeInterval = 75
    static let defaultNextGuessTimeout: TimeInterval = 45
    static let defaultSprintCheckTimeout: TimeInterval = 120
    static let defaultKillGrace: TimeInterval = 10
    static let defaultContainerSuccessTTL: TimeInterval = 10 * 60
    static let defaultContainerFailureTTL: TimeInterval = 5 * 60

    let isTestInstance: Bool
    let stateDir: URL?
    let agySwapBin: String?
    let agyBinOverride: String?
    let usageTestFlag: Bool
    let agyOffline: Bool
    let statusTimeout: TimeInterval
    let usageRunTimeout: TimeInterval
    let backgroundRunTimeoutOverride: TimeInterval?
    let killGrace: TimeInterval
    let usageCardDumpURL: URL?
    let testDir: URL?
    let cacheStateDir: URL
    let dockerPath: String?
    let containerMapURL: URL?
    let containerSuccessTTL: TimeInterval
    let containerFailureTTL: TimeInterval

    /// 額度查詢是否啟用 agy-swap 路徑：
    /// 正式＝agy-swap 存在；測試＝必須同時給了 `--agy-swap-bin` 與 `--agy-usage-test`。
    var usageSwapEnabled: Bool {
        guard agySwapBin != nil else { return false }
        return isTestInstance ? usageTestFlag : true
    }

    /// 背景工具（NextGuess／SprintCheck）是否啟用 agy-swap 路徑：
    /// 正式＝agy-swap 存在；測試＝只看 `--agy-swap-bin`。
    var backgroundSwapEnabled: Bool {
        agySwapBin != nil
    }

    var nextGuessTimeout: TimeInterval {
        backgroundRunTimeoutOverride ?? Self.defaultNextGuessTimeout
    }

    var sprintCheckTimeout: TimeInterval {
        backgroundRunTimeoutOverride ?? Self.defaultSprintCheckTimeout
    }

    static func current() -> AgySwapConfig {
        from(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment)
    }

    static func from(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        formalSwapPath: () -> String? = { CLITools.path("agy-swap") },
        formalDockerPath: () -> String? = { UsageMonitor.dockerPath(environment: [:], arguments: []) },
        formalSupportDir: URL = Edition.supportDir,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        homeDir: URL = Edition.home
    ) -> AgySwapConfig {
        func flagValue(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            let val = arguments[i + 1]
            return val.isEmpty ? nil : val
        }
        func positiveDouble(_ flag: String) -> TimeInterval? {
            guard let raw = flagValue(flag), let val = Double(raw), val.isFinite, val > 0 else { return nil }
            return val
        }
        func parseContainerTTL(_ raw: String?) -> (success: TimeInterval, failure: TimeInterval)? {
            guard let raw else { return nil }
            let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2,
                  let s = Double(parts[0]), s.isFinite, s >= 0,
                  let f = Double(parts[1]), f.isFinite, f >= 0 else { return nil }
            return (s, f)
        }

        let isTest = arguments.contains("--state-dir")
        if !isTest {
            let bin = formalSwapPath().flatMap { isExecutable($0) ? $0 : nil }
            let docker = formalDockerPath().flatMap { isExecutable($0) ? $0 : nil }
            return AgySwapConfig(
                isTestInstance: false,
                stateDir: nil,
                agySwapBin: bin,
                agyBinOverride: nil,
                usageTestFlag: false,
                agyOffline: false,
                statusTimeout: defaultStatusTimeout,
                usageRunTimeout: defaultUsageRunTimeout,
                backgroundRunTimeoutOverride: nil,
                killGrace: defaultKillGrace,
                usageCardDumpURL: nil,
                testDir: nil,
                cacheStateDir: homeDir.appendingPathComponent(".local/state/agy-swap", isDirectory: true),
                dockerPath: docker,
                containerMapURL: formalSupportDir.appendingPathComponent("agy-container-map.json"),
                containerSuccessTTL: defaultContainerSuccessTTL,
                containerFailureTTL: defaultContainerFailureTTL
            )
        }

        let stateDirURL = flagValue("--state-dir").map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        let testDirURL = stateDirURL?.appendingPathComponent("agy-swap", isDirectory: true)
        let cacheDirURL = testDirURL?.appendingPathComponent("state", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("codenv-agyswap-invalid-state", isDirectory: true)

        // 測試實例絕不退回 ~/.local/bin/agy-swap；只認明確提供的 --agy-swap-bin。
        let swapBin = flagValue("--agy-swap-bin").flatMap { isExecutable($0) ? $0 : nil }
        let agyBin = flagValue("--agy-bin").flatMap { isExecutable($0) ? $0 : nil }
        // 測試實例的 dockerPath 只從環境變數 CODENV_DOCKER_PATH 取得，絕不退回系統真 docker。
        let rawDockerPath = environment["CODENV_DOCKER_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let testDockerPath = rawDockerPath.flatMap { !$0.isEmpty && isExecutable($0) ? $0 : nil }
        let usageTest = arguments.contains("--agy-usage-test")
        let agyOffline = arguments.contains("--agy-offline")

        let statusTimeout = positiveDouble("--agy-swap-status-timeout") ?? defaultStatusTimeout
        let runTimeoutOverride = positiveDouble("--agy-swap-run-timeout")
        let killGrace = positiveDouble("--agy-swap-kill-grace") ?? defaultKillGrace
        let ttlOverride = parseContainerTTL(flagValue("--agy-container-ttl"))

        var dumpURL: URL?
        if let rawDump = flagValue("--usage-card-dump"), let stateRoot = stateDirURL {
            let candidate = URL(fileURLWithPath: rawDump).standardizedFileURL
            if isTestProbeOutput(candidate, inside: stateRoot) {
                dumpURL = candidate
            }
        }

        return AgySwapConfig(
            isTestInstance: true,
            stateDir: stateDirURL,
            agySwapBin: swapBin,
            agyBinOverride: agyBin,
            usageTestFlag: usageTest,
            agyOffline: agyOffline,
            statusTimeout: statusTimeout,
            usageRunTimeout: runTimeoutOverride ?? defaultUsageRunTimeout,
            backgroundRunTimeoutOverride: runTimeoutOverride,
            killGrace: killGrace,
            usageCardDumpURL: dumpURL,
            testDir: testDirURL,
            cacheStateDir: cacheDirURL,
            dockerPath: testDockerPath,
            containerMapURL: stateDirURL?.appendingPathComponent("agy-container-map.json"),
            containerSuccessTTL: ttlOverride?.success ?? defaultContainerSuccessTTL,
            containerFailureTTL: ttlOverride?.failure ?? defaultContainerFailureTTL
        )
    }
}

// MARK: - status --json 模型（總規格 4.7）

struct AgySwapStatus: Equatable {
    struct Account: Equatable {
        let name: String
        let invalid: Bool
        let exhausted: [String: String]
        let verifyFailures: Int
        let verifyFailedAt: String?
    }

    let active: String?
    let gen: Int
    let switching: Bool
    let liveMatches: String?
    let lastSwitch: String?
    let accounts: [Account]
    let recoveryPending: Bool
    let accountsError: Bool

    static func parse(_ stdout: String) -> AgySwapStatus? {
        guard let data = stdout.data(using: .utf8) else { return nil }
        return parse(data: data)
    }

    static func parse(data: Data) -> AgySwapStatus? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let accountsError = (root["accounts_error"] as? Bool) ?? false
        let recoveryPending = (root["recovery_pending"] as? Bool) ?? false
        let switching = (root["switching"] as? Bool) ?? false

        func nonEmptyString(_ key: String) -> String? {
            guard let s = root[key] as? String, !s.isEmpty else { return nil }
            return s
        }

        let genNumber = root["gen"] as? NSNumber
        let hasValidGen = genNumber != nil && CFGetTypeID(genNumber!) != CFBooleanGetTypeID()
        if !accountsError && !hasValidGen {
            return nil
        }
        let gen = hasValidGen ? genNumber!.intValue : 0

        let rawAccounts = root["accounts"] as? [[String: Any]]
        if !accountsError && rawAccounts == nil {
            return nil
        }

        var accounts: [Account] = []
        if let rawAccounts {
            for item in rawAccounts {
                guard let name = item["name"] as? String, !name.isEmpty else { continue }
                let invalid = (item["invalid"] as? Bool) ?? false
                let exhausted = (item["exhausted"] as? [String: String]) ?? [:]
                let vfNum = item["verify_failures"] as? NSNumber
                let vf = (vfNum != nil && CFGetTypeID(vfNum!) != CFBooleanGetTypeID()) ? vfNum!.intValue : 0
                let vfAt = (item["verify_failed_at"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                accounts.append(Account(
                    name: name,
                    invalid: invalid,
                    exhausted: exhausted,
                    verifyFailures: vf,
                    verifyFailedAt: vfAt
                ))
            }
        }

        return AgySwapStatus(
            active: nonEmptyString("active"),
            gen: gen,
            switching: switching,
            liveMatches: nonEmptyString("live_matches"),
            lastSwitch: nonEmptyString("last_switch"),
            accounts: accounts,
            recoveryPending: recoveryPending,
            accountsError: accountsError
        )
    }
}

// MARK: - 模式判定與連續失敗降級（規格第 2 節）

enum AgySwapModeDecision: Equatable {
    case swap(AgySwapStatus)
    case legacy(AgySwapStatus?)
    case skipRound(reason: String, consecutiveFailures: Int)
    case degradedLegacy(reason: String, consecutiveFailures: Int)
}

enum AgySwapStatusFetchResult: Equatable {
    case success(AgySwapStatus)
    case failed(reason: String)
}

final class AgySwapModeTracker {
    private let lock = NSLock()
    private(set) var consecutiveStatusFailures = 0
    static let degradeThreshold = 3

    func reset() {
        lock.lock()
        consecutiveStatusFailures = 0
        lock.unlock()
    }

    func evaluate(hasBinary: Bool, statusResult: AgySwapStatusFetchResult?) -> AgySwapModeDecision {
        lock.lock()
        defer { lock.unlock() }

        guard hasBinary else {
            consecutiveStatusFailures = 0
            return .legacy(nil)
        }

        switch statusResult {
        case .success(let status) where !status.accountsError:
            consecutiveStatusFailures = 0
            if status.accounts.count >= 2 {
                return .swap(status)
            } else {
                return .legacy(status)
            }

        case .success:
            consecutiveStatusFailures += 1
            let reason = "status 回報 accounts_error"
            if consecutiveStatusFailures >= Self.degradeThreshold {
                return .degradedLegacy(reason: reason, consecutiveFailures: consecutiveStatusFailures)
            }
            return .skipRound(reason: reason, consecutiveFailures: consecutiveStatusFailures)

        case .failed(let reason):
            consecutiveStatusFailures += 1
            if consecutiveStatusFailures >= Self.degradeThreshold {
                return .degradedLegacy(reason: reason, consecutiveFailures: consecutiveStatusFailures)
            }
            return .skipRound(reason: reason, consecutiveFailures: consecutiveStatusFailures)

        case nil:
            consecutiveStatusFailures += 1
            let reason = "status 未執行或無結果"
            if consecutiveStatusFailures >= Self.degradeThreshold {
                return .degradedLegacy(reason: reason, consecutiveFailures: consecutiveStatusFailures)
            }
            return .skipRound(reason: reason, consecutiveFailures: consecutiveStatusFailures)
        }
    }
}

// MARK: - 子程序執行結果與結束碼判讀

struct AgySwapExecResult: Equatable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let weTerminated: Bool
    let timedOut: Bool
    let launched: Bool
    let argv: [String]
    let outputTruncated: Bool

    init(
        exitCode: Int32,
        stdout: String,
        stderr: String,
        weTerminated: Bool,
        timedOut: Bool,
        launched: Bool,
        argv: [String],
        outputTruncated: Bool = false
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.weTerminated = weTerminated
        self.timedOut = timedOut
        self.launched = launched
        self.argv = argv
        self.outputTruncated = outputTruncated
    }
}

enum AgySwapProcessOutcome: Equatable {
    case ok
    case stoppedByUs
    case failed(exitCode: Int32)
}

struct AgySwapRunCallResult: Equatable {
    let exec: AgySwapExecResult
    let anInfo: AgySwapAnFileInfo?
}

/// `--agy-background-probe` 的結果快照（規格 3 F）。
struct AgyBackgroundProbeOutcome: Equatable {
    let launched: Bool
    let mode: String          // "legacy" | "swap"
    let argv: [String]
    let exitStatus: Int32?
    let stoppedByUs: Bool

    func jsonObject() -> [String: Any] {
        [
            "launched": launched,
            "mode": mode,
            "argv": argv,
            "exitStatus": exitStatus.map { Int($0) } ?? NSNull(),
            "stoppedByUs": stoppedByUs,
        ]
    }
}

// MARK: - 可取消的子程序控制柄（posix_spawn + POSIX_SPAWN_SETPGROUP）

final class AgySwapProcessHandle {
    /// stdout 與 stderr 各自累積上限（1 MiB）；超過後繼續排空管線不阻塞子程序，但不再 append 並標記 `outputTruncated`。
    static let maxStreamBytes = 1024 * 1024

    struct SignalOps {
        var kill: (pid_t, Int32) -> Int32
        var killpg: (pid_t, Int32) -> Int32

        static let live = SignalOps(
            kill: { Darwin.kill($0, $1) },
            killpg: { Darwin.killpg($0, $1) }
        )
    }

    private let pid: pid_t
    private let ownPgrp: pid_t
    private let killGrace: TimeInterval
    private let argv: [String]
    private let signalOps: SignalOps

    private let lock = NSLock()
    private var exited = false
    private var reaped = false
    private var groupConfirmedDead = false
    private var rawExitCode: Int32 = -1
    private var termSent = false
    private var weTerminated = false
    private var timedOut = false
    private var groupCleanupRequested = false
    private var termSentAt: Date?
    private var stopReadingFlag = false
    private var stdoutTruncated = false
    private var stderrTruncated = false
    private var timeoutWork: DispatchWorkItem?
    private var killWork: DispatchWorkItem?

    private var outData = Data()
    private var errData = Data()
    private let exitedSem = DispatchSemaphore(value: 0)
    private let outEOFSem = DispatchSemaphore(value: 0)
    private let errEOFSem = DispatchSemaphore(value: 0)
    private let finishedSem = DispatchSemaphore(value: 0)
    private var cachedResult: AgySwapExecResult?

    private init(
        pid: pid_t,
        ownPgrp: pid_t,
        outReadFd: Int32,
        errReadFd: Int32,
        timeout: TimeInterval,
        killGrace: TimeInterval,
        argv: [String],
        signalOps: SignalOps = .live
    ) {
        self.pid = pid
        self.ownPgrp = ownPgrp
        self.killGrace = killGrace
        self.argv = argv
        self.signalOps = signalOps

        startReader(fd: outReadFd, eof: outEOFSem) { [weak self] chunk in
            guard let self else { return }
            self.lock.lock()
            let remaining = Self.maxStreamBytes - self.outData.count
            if remaining > 0 {
                if chunk.count <= remaining {
                    self.outData.append(chunk)
                } else {
                    self.outData.append(chunk.prefix(remaining))
                    self.stdoutTruncated = true
                }
            } else {
                self.stdoutTruncated = true
            }
            self.lock.unlock()
        }
        startReader(fd: errReadFd, eof: errEOFSem) { [weak self] chunk in
            guard let self else { return }
            self.lock.lock()
            let remaining = Self.maxStreamBytes - self.errData.count
            if remaining > 0 {
                if chunk.count <= remaining {
                    self.errData.append(chunk)
                } else {
                    self.errData.append(chunk.prefix(remaining))
                    self.stderrTruncated = true
                }
            } else {
                self.stderrTruncated = true
            }
            self.lock.unlock()
        }

        let timeoutItem = DispatchWorkItem { [weak self] in
            self?.requestTerminate(fromTimeout: true)
        }
        lock.lock()
        self.timeoutWork = timeoutItem
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            // 第一階段：waitid(..., WEXITED | WNOWAIT) 等子程序結束但不收屍，此時 pid 尚未歸還系統、不會被重用。
            var siginfo = siginfo_t()
            var waitidRC: Int32 = -1
            repeat {
                siginfo = siginfo_t()
                waitidRC = Darwin.waitid(P_PID, id_t(self.pid), &siginfo, WEXITED | WNOWAIT)
            } while waitidRC == -1 && errno == EINTR

            var status: Int32 = 0
            var waited: pid_t = -1
            if waitidRC == 0 {
                // 子程序已處於 WEXITED 殭屍態：鎖內標記 exited = true，再立刻 waitpid 收屍（不阻塞），
                // 並於同一個鎖區間判斷子群組是否已無殘留，避免收屍後對可能被重用的 pid 送訊號。
                self.lock.lock()
                self.exited = true
                self.timeoutWork?.cancel()
                self.timeoutWork = nil
                repeat {
                    waited = Darwin.waitpid(self.pid, &status, 0)
                } while waited == -1 && errno == EINTR
                self.rawExitCode = waited == self.pid ? AgySwapClient.waitStatusToExitCode(status) : -1
                self.reaped = true
                let groupAlive = self.isOwnChildGroupAliveLocked()
                if !groupAlive {
                    self.groupConfirmedDead = true
                    self.killWork?.cancel()
                    self.killWork = nil
                } else if !self.weTerminated && !self.groupCleanupRequested {
                    self.killWork?.cancel()
                    self.killWork = nil
                }
                self.lock.unlock()
            } else {
                self.lock.lock()
                self.exited = true
                self.timeoutWork?.cancel()
                self.timeoutWork = nil
                self.lock.unlock()

                repeat {
                    waited = Darwin.waitpid(self.pid, &status, 0)
                } while waited == -1 && errno == EINTR

                self.lock.lock()
                self.rawExitCode = waited == self.pid ? AgySwapClient.waitStatusToExitCode(status) : -1
                self.reaped = true
                if !self.isOwnChildGroupAliveLocked() {
                    self.groupConfirmedDead = true
                    self.killWork?.cancel()
                    self.killWork = nil
                }
                self.lock.unlock()
            }

            self.exitedSem.signal()
            self.finalizeResult()
        }
    }

    static func spawn(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String],
        timeout: TimeInterval,
        killGrace: TimeInterval,
        signalOps: SignalOps = .live
    ) -> AgySwapProcessHandle? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }

        var outFds: [Int32] = [-1, -1]
        var errFds: [Int32] = [-1, -1]
        guard Darwin.pipe(&outFds) == 0 else { return nil }
        guard Darwin.pipe(&errFds) == 0 else {
            _ = Darwin.close(outFds[0]); _ = Darwin.close(outFds[1])
            return nil
        }

        // 先設 FD_CLOEXEC，避免其他並行子程序誤繼承管線。
        for fd in [outFds[0], outFds[1], errFds[0], errFds[1]] {
            _ = Darwin.fcntl(fd, F_SETFD, FD_CLOEXEC)
        }

        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            for fd in [outFds[0], outFds[1], errFds[0], errFds[1]] { _ = Darwin.close(fd) }
            return nil
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fileActions, outFds[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, errFds[1], STDERR_FILENO)
        if outFds[0] > STDERR_FILENO { posix_spawn_file_actions_addclose(&fileActions, outFds[0]) }
        if outFds[1] > STDERR_FILENO { posix_spawn_file_actions_addclose(&fileActions, outFds[1]) }
        if errFds[0] > STDERR_FILENO { posix_spawn_file_actions_addclose(&fileActions, errFds[0]) }
        if errFds[1] > STDERR_FILENO { posix_spawn_file_actions_addclose(&fileActions, errFds[1]) }

        if let workingDirectory {
            try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
            posix_spawn_file_actions_addchdir_np(&fileActions, workingDirectory.path)
        }

        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else {
            for fd in [outFds[0], outFds[1], errFds[0], errFds[1]] { _ = Darwin.close(fd) }
            return nil
        }
        defer { posix_spawnattr_destroy(&attr) }

        // POSIX_SPAWN_SETPGROUP + pgroup=0：子程序自成新行程群組（pgid == child pid），與 codenv 隔離。
        // POSIX_SPAWN_CLOEXEC_DEFAULT：未在 fileActions 明確打開/dup2 的 fd 一律不繼承。
        // POSIX_SPAWN_SETSIGDEF：恢復 SIGPIPE／SIGTERM／SIGINT／SIGHUP／SIGQUIT 預設行為（避免繼承 SIG_IGN）。
        // POSIX_SPAWN_SETSIGMASK：清空訊號遮罩，避免子程序繼承呼叫執行緒的 signal mask 而收不到 SIGTERM。
        let spawnFlags = Int16(
            POSIX_SPAWN_SETPGROUP
            | POSIX_SPAWN_CLOEXEC_DEFAULT
            | POSIX_SPAWN_SETSIGDEF
            | POSIX_SPAWN_SETSIGMASK
        )
        posix_spawnattr_setflags(&attr, spawnFlags)
        posix_spawnattr_setpgroup(&attr, 0)
        var sigDefault = sigset_t()
        sigemptyset(&sigDefault)
        sigaddset(&sigDefault, SIGPIPE)
        sigaddset(&sigDefault, SIGTERM)
        sigaddset(&sigDefault, SIGINT)
        sigaddset(&sigDefault, SIGHUP)
        sigaddset(&sigDefault, SIGQUIT)
        posix_spawnattr_setsigdefault(&attr, &sigDefault)
        var sigMask = sigset_t()
        sigemptyset(&sigMask)
        posix_spawnattr_setsigmask(&attr, &sigMask)

        let fullArgv = [executable] + arguments
        var cArgs: [UnsafeMutablePointer<CChar>?] = fullArgv.map { strdup($0) } + [nil]
        defer { for ptr in cArgs { if let ptr { free(ptr) } } }

        let envPairs = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        var cEnv: [UnsafeMutablePointer<CChar>?] = envPairs.map { strdup($0) } + [nil]
        defer { for ptr in cEnv { if let ptr { free(ptr) } } }

        var childPid: pid_t = -1
        let rc = posix_spawn(&childPid, executable, &fileActions, &attr, &cArgs, &cEnv)

        // 父程序端永遠先關閉 write 端，否則讀端永遠等不到 EOF。
        _ = Darwin.close(outFds[1])
        _ = Darwin.close(errFds[1])

        guard rc == 0, childPid > 0 else {
            _ = Darwin.close(outFds[0])
            _ = Darwin.close(errFds[0])
            return nil
        }

        return AgySwapProcessHandle(
            pid: childPid,
            ownPgrp: Darwin.getpgrp(),
            outReadFd: outFds[0],
            errReadFd: errFds[0],
            timeout: timeout,
            killGrace: killGrace,
            argv: fullArgv,
            signalOps: signalOps
        )
    }

    var processIdentifier: pid_t { pid }
    var commandArgv: [String] { argv }

    /// 供單元測試確認主子程序是否已結束並收屍。
    var hasExitedForTest: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exited && reaped
    }

    /// 供單元測試模擬逾時計時器晚到觸發。
    func triggerTimeoutForTest() {
        requestTerminate(fromTimeout: true)
    }

    /// 供單元測試模擬群組強殺工作晚到觸發。
    func triggerForceKillForTest() {
        forceKillGroupIfNeeded()
    }

    /// 主動終止（供 NextGuess stop closure 呼叫）：只對子程序 pid 送 SIGTERM，killGrace 後才對 -pgid 送 SIGKILL。
    func terminate() {
        requestTerminate(fromTimeout: false)
    }

    /// 阻塞等待子程序完全結束並回傳結果（不可在主執行緒呼叫）。
    func wait() -> AgySwapExecResult {
        finishedSem.wait()
        finishedSem.signal()
        lock.lock()
        defer { lock.unlock() }
        return cachedResult ?? AgySwapExecResult(
            exitCode: -1, stdout: "", stderr: "",
            weTerminated: weTerminated, timedOut: timedOut, launched: true, argv: argv,
            outputTruncated: stdoutTruncated || stderrTruncated
        )
    }

    /// 須在持鎖下呼叫；若群組已確認清空（`groupConfirmedDead`）則絕不再對可能被重用的 pgid 呼叫 `killpg`。
    private func isOwnChildGroupAliveLocked() -> Bool {
        guard !groupConfirmedDead else { return false }
        guard pid > 1, pid != ownPgrp else { return false }
        return signalOps.killpg(pid, 0) == 0
    }

    private func isOwnChildGroupAlive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isOwnChildGroupAliveLocked()
    }

    private func requestTerminate(fromTimeout: Bool) {
        lock.lock()
        if groupConfirmedDead || termSent {
            lock.unlock()
            return
        }
        let alreadyExited = exited
        let groupStillAlive = isOwnChildGroupAliveLocked()
        if alreadyExited {
            // 修正單第 2 項：子程序已結束則不設 weTerminated／timedOut，避免把成功的 run 判成 .stoppedByUs；
            // 也不再對 pid 送 SIGTERM，只在群組仍有殘留成員時清理群組。
            timeoutWork?.cancel()
            timeoutWork = nil
            if !groupStillAlive {
                groupConfirmedDead = true
                killWork?.cancel()
                killWork = nil
                lock.unlock()
                return
            }
            termSent = true
            groupCleanupRequested = true
            termSentAt = Date()
            forceKillGroupIfNeededLocked()
            lock.unlock()
            return
        }

        termSent = true
        weTerminated = true
        if fromTimeout { timedOut = true }
        termSentAt = Date()
        timeoutWork?.cancel()
        timeoutWork = nil

        let grace = killGrace
        let killItem = DispatchWorkItem { [weak self] in
            self?.forceKillGroupIfNeeded()
        }
        killWork = killItem

        // 規格 3 A：持鎖下只對 run（child pid）送 SIGTERM，避免解鎖後子程序收屍重用 pid；
        // 絕不對行程群組送 SIGTERM，也絕不對 codenv 群組送訊號。
        if pid > 1, pid != ownPgrp {
            _ = signalOps.kill(pid, SIGTERM)
        }
        lock.unlock()

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace, execute: killItem)
    }

    private func forceKillGroupIfNeeded() {
        lock.lock()
        forceKillGroupIfNeededLocked()
        lock.unlock()
    }

    private func forceKillGroupIfNeededLocked() {
        guard !groupConfirmedDead else { return }
        guard pid > 1, pid != ownPgrp else { return }
        let groupAlive = isOwnChildGroupAliveLocked()
        guard groupAlive else {
            if exited {
                groupConfirmedDead = true
            }
            return
        }
        // 總規格 4.2：絕不單獨對 pid 送 SIGKILL；只在群組仍存在（killpg(pid, 0) == 0）時對整個獨立子群組 -pid 送 SIGKILL。
        _ = signalOps.kill(-pid, SIGKILL)
    }

    private static func decodeUTF8Clamped(_ data: Data, truncated: Bool) -> String {
        guard truncated, !data.isEmpty else {
            return String(decoding: data, as: UTF8.self)
        }
        // 截斷點若剛好切在多位元組 UTF-8 字元中間，去掉尾端殘缺位元組，確保解碼後的 UTF-8 長度不超過 1 MiB。
        var end = data.count
        var contCount = 0
        while end > 0 && contCount < 3 && (data[end - 1] & 0xC0) == 0x80 {
            end -= 1
            contCount += 1
        }
        if end > 0 {
            let lead = data[end - 1]
            let expectedLen: Int
            if (lead & 0x80) == 0 {
                expectedLen = 1
            } else if (lead & 0xE0) == 0xC0 {
                expectedLen = 2
            } else if (lead & 0xF0) == 0xE0 {
                expectedLen = 3
            } else if (lead & 0xF8) == 0xF0 {
                expectedLen = 4
            } else {
                expectedLen = 0
            }
            let leadIndex = end - 1
            let actualLen = data.count - leadIndex
            if expectedLen == 0 || actualLen < expectedLen {
                return String(decoding: data.prefix(leadIndex), as: UTF8.self)
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func finalizeResult() {
        // 若是我們送了 TERM 或請求群組清理，且子程序先結束但同群組孫程序仍活著，等到群組清空為止。
        lock.lock()
        let terminatedByUs = weTerminated
        let cleanupRequested = groupCleanupRequested
        let sentAt = termSentAt
        let initialGroupAlive = isOwnChildGroupAliveLocked()
        lock.unlock()

        if (terminatedByUs || cleanupRequested) && initialGroupAlive {
            let deadline = (sentAt ?? Date()).addingTimeInterval(terminatedByUs ? (killGrace + 1.5) : 1.0)
            while isOwnChildGroupAlive() && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if isOwnChildGroupAlive() {
                forceKillGroupIfNeeded()
                let postKill = Date().addingTimeInterval(0.5)
                while isOwnChildGroupAlive() && Date() < postKill {
                    Thread.sleep(forTimeInterval: 0.025)
                }
            }
        }

        lock.lock()
        if !groupConfirmedDead && !isOwnChildGroupAliveLocked() {
            groupConfirmedDead = true
        }
        if groupConfirmedDead {
            killWork?.cancel()
            killWork = nil
        }
        lock.unlock()

        let drainTimeout: TimeInterval = terminatedByUs ? 0.5 : 2.0
        let deadline = DispatchTime.now() + drainTimeout
        let outDone = outEOFSem.wait(timeout: deadline) == .success
        let errDone = errEOFSem.wait(timeout: deadline) == .success
        if !outDone || !errDone {
            lock.lock()
            stopReadingFlag = true
            lock.unlock()
            _ = outEOFSem.wait(timeout: .now() + 0.3)
            _ = errEOFSem.wait(timeout: .now() + 0.3)
        }

        lock.lock()
        if !groupConfirmedDead && !isOwnChildGroupAliveLocked() {
            groupConfirmedDead = true
            killWork?.cancel()
            killWork = nil
        }
        let result = AgySwapExecResult(
            exitCode: rawExitCode,
            stdout: Self.decodeUTF8Clamped(outData, truncated: stdoutTruncated),
            stderr: Self.decodeUTF8Clamped(errData, truncated: stderrTruncated),
            weTerminated: weTerminated,
            timedOut: timedOut,
            launched: true,
            argv: argv,
            outputTruncated: stdoutTruncated || stderrTruncated
        )
        cachedResult = result
        lock.unlock()
        finishedSem.signal()
    }

    private func startReader(fd: Int32, eof: DispatchSemaphore, onChunk: @escaping (Data) -> Void) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer {
                _ = Darwin.close(fd)
                eof.signal()
            }
            var buffer = [UInt8](repeating: 0, count: 16384)
            while true {
                if let self {
                    self.lock.lock()
                    let shouldStop = self.stopReadingFlag
                    self.lock.unlock()
                    if shouldStop { break }
                } else {
                    break
                }

                var pfd = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
                let ready = Darwin.poll(&pfd, 1, 100)
                if ready == 0 { continue }
                if ready < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if (pfd.revents & Int16(POLLIN | POLLHUP)) != 0 {
                    let n = Darwin.read(fd, &buffer, buffer.count)
                    if n > 0 {
                        onChunk(Data(buffer[0..<n]))
                    } else if n == 0 {
                        break
                    } else if errno != EINTR {
                        break
                    }
                } else if (pfd.revents & Int16(POLLERR | POLLNVAL)) != 0 {
                    break
                }
            }
        }
    }
}

// MARK: - AgySwapClient 高階封裝

enum AgySwapClient {
    /// 子程序只給 HOME、PATH（必含 /usr/bin:/bin）、LANG，不洩漏其他環境變數。
    static func minimalEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment,
        homeDir: String = Edition.home.path
    ) -> [String: String] {
        let home = (base["HOME"].flatMap { $0.isEmpty ? nil : $0 }) ?? homeDir
        let lang = (base["LANG"].flatMap { $0.isEmpty ? nil : $0 }) ?? "en_US.UTF-8"
        var parts = (base["PATH"] ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        let required = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        for dir in required where !parts.contains(dir) {
            parts.append(dir)
        }
        return [
            "HOME": home,
            "PATH": parts.joined(separator: ":"),
            "LANG": lang,
        ]
    }

    static func waitStatusToExitCode(_ rawStatus: Int32) -> Int32 {
        let signalBits = rawStatus & 0x7f
        if signalBits == 0 {
            return (rawStatus >> 8) & 0xff
        }
        if signalBits != 0x7f {
            return 128 + signalBits
        }
        return -1
    }

    /// 結束碼判讀（規格 3 A）：
    /// 143／137 只有在「這一輪是我們送的 TERM」時才當作 `.stoppedByUs`；
    /// 外部殺掉或 OOM（!weTerminated）或子程序自己回非 0 → 一律視為 `.failed`。
    static func classifyExit(_ result: AgySwapExecResult) -> AgySwapProcessOutcome {
        guard result.launched else { return .failed(exitCode: -1) }
        if result.weTerminated {
            if result.exitCode == 143 || result.exitCode == 137 || result.exitCode == 0 {
                return .stoppedByUs
            }
            return .failed(exitCode: result.exitCode)
        }
        if result.exitCode == 0 {
            return .ok
        }
        return .failed(exitCode: result.exitCode)
    }

    /// 換帳號模式下網路檢查：
    /// 測試實例看 `--agy-offline`（若沒離線且有 `--agy-swap-bin`，不因缺 `--agy-bin` 而被 AgyBridge.canLaunchInCurrentInstance 擋死，也不連真網）；
    /// 正式實例直接呼叫 `AgyNet.canCall()`。
    static func canCallAgy(config: AgySwapConfig, arguments: [String] = CommandLine.arguments) -> Bool {
        if config.isTestInstance {
            if config.agyOffline || arguments.contains("--agy-offline") { return false }
            if config.agySwapBin != nil { return true }
            return AgyNet.canCall()
        }
        return AgyNet.canCall()
    }

    // MARK: - 組合 argv（純函式，方便單元測試）

    static func statusArguments(config: AgySwapConfig) -> [String] {
        var args = ["status", "--json"]
        if config.isTestInstance, let testDir = config.testDir {
            args += ["--test-dir", testDir.path]
        }
        return args
    }

    static func runArguments(
        config: AgySwapConfig,
        anFilePath: String,
        agyArguments: [String]
    ) -> [String] {
        var args = ["run", "--an-file", anFilePath]
        if config.isTestInstance {
            if let testDir = config.testDir {
                args += ["--test-dir", testDir.path]
            }
            if let agyBin = config.agyBinOverride {
                args += ["--agy-bin", agyBin]
            }
        }
        args.append("--")
        args.append(contentsOf: agyArguments)
        return args
    }

    // MARK: - 執行 status --json

    static func fetchStatus(
        config: AgySwapConfig,
        onStartHandle: ((AgySwapProcessHandle) -> Void)? = nil
    ) -> AgySwapStatusFetchResult {
        guard let bin = config.agySwapBin else {
            return .failed(reason: "找不到 agy-swap 執行檔")
        }
        let args = statusArguments(config: config)
        guard let handle = AgySwapProcessHandle.spawn(
            executable: bin,
            arguments: args,
            workingDirectory: FileManager.default.temporaryDirectory,
            environment: minimalEnvironment(),
            timeout: config.statusTimeout,
            killGrace: config.killGrace
        ) else {
            return .failed(reason: "無法啟動 agy-swap status")
        }
        onStartHandle?(handle)
        let result = handle.wait()
        if result.timedOut {
            return .failed(reason: "agy-swap status 逾時（\(Int(config.statusTimeout))s）")
        }
        if result.weTerminated {
            return .failed(reason: "agy-swap status 已取消")
        }
        if result.outputTruncated {
            return .failed(reason: "agy-swap status 輸出超過上限已截斷")
        }
        guard result.exitCode == 0 else {
            return .failed(reason: "agy-swap status 回傳結束碼 \(result.exitCode)")
        }
        guard let parsed = AgySwapStatus.parse(result.stdout) else {
            return .failed(reason: "agy-swap status JSON 解析失敗")
        }
        return .success(parsed)
    }

    // MARK: - 執行 agy-swap run（含 an-file 生命週期）

    /// 啟動 `agy-swap run`（背景工具與額度查詢共用）；回傳已啟動的 handle 與暫存 an-file 路徑。
    /// 呼叫端必須在結束後刪除 an-file（或改用下方的同步封裝 `run(...)`）。
    static func startRun(
        config: AgySwapConfig,
        agyArguments: [String],
        workingDirectory: URL,
        timeout: TimeInterval
    ) -> (handle: AgySwapProcessHandle, anFile: URL)? {
        guard let bin = config.agySwapBin,
              let anFile = AgySwapUsageCache.createAnFile() else {
            return nil
        }
        let args = runArguments(config: config, anFilePath: anFile.path, agyArguments: agyArguments)
        guard let handle = AgySwapProcessHandle.spawn(
            executable: bin,
            arguments: args,
            workingDirectory: workingDirectory,
            environment: minimalEnvironment(),
            timeout: timeout,
            killGrace: config.killGrace
        ) else {
            try? FileManager.default.removeItem(at: anFile)
            return nil
        }
        return (handle, anFile)
    }

    /// 同步執行 `agy-swap run`（含自動建立與刪除 0600 UUID an-file）。
    static func run(
        config: AgySwapConfig,
        agyArguments: [String],
        workingDirectory: URL,
        timeout: TimeInterval,
        onStartHandle: ((AgySwapProcessHandle) -> Void)? = nil
    ) -> AgySwapRunCallResult {
        guard let started = startRun(
            config: config,
            agyArguments: agyArguments,
            workingDirectory: workingDirectory,
            timeout: timeout
        ) else {
            let fallbackArgv = config.agySwapBin.map { [$0, "run"] } ?? []
            return AgySwapRunCallResult(
                exec: AgySwapExecResult(
                    exitCode: -1, stdout: "", stderr: "",
                    weTerminated: false, timedOut: false, launched: false, argv: fallbackArgv
                ),
                anInfo: nil
            )
        }
        defer { try? FileManager.default.removeItem(at: started.anFile) }
        onStartHandle?(started.handle)
        let exec = started.handle.wait()
        let anInfo = AgySwapUsageCache.parseAnFile(at: started.anFile)
        return AgySwapRunCallResult(exec: exec, anInfo: anInfo)
    }
}
