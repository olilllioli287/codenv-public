import Foundation

/// 總指揮派工使用的 Git worktree；建立路徑放在共用 .git 目錄下，不會弄髒主工作目錄。
enum CommanderWorktree {
    struct Assignment {
        var branch: String
        var path: String
        var reused: Bool
    }

    enum MergeCheck {
        case clean
        case uncommitted(String)
        case conflicts([String])
    }

    private struct Worktree {
        var path: String
        var branch: String?
    }

    enum Failure: LocalizedError {
        case existingClaude
        case invalidBranch(String)
        case git(String)
        case dirty(String)
        case worktreeMismatch(String)
        case noMain

        var errorDescription: String? {
            switch self {
            case .existingClaude:
                return "既有 Claude 聊天室不能帶 --worktree；請用 codenv-todo new --worktree 開新聊天室，既有對話紀錄不會搬動。"
            case .invalidBranch(let branch):
                return "無效的 Git 分支名稱：\(branch)"
            case .git(let message):
                return message
            case .dirty(let message):
                return message
            case .worktreeMismatch(let message):
                return message
            case .noMain:
                return "指定 repo 沒有本機 main 分支，無法從 main 建立 worktree。"
            }
        }
    }

    static func validate(engine: String, isNewChat: Bool) throws {
        if !isNewChat && engine.lowercased() == "claude" { throw Failure.existingClaude }
    }

    /// 建立新聊天室可用任何引擎；既有聊天室僅允許非 Claude 引擎，避免變更既有 Claude transcript 路徑。
    static func assign(repoDirectory: String, branch: String, engine: String, isNewChat: Bool) throws -> Assignment {
        try validate(engine: engine, isNewChat: isNewChat)
        return try ensure(repoDirectory: repoDirectory, branch: branch)
    }

    static func ensure(repoDirectory: String, branch: String) throws -> Assignment {
        let branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else { throw Failure.invalidBranch(branch) }
        let repoPath = canonicalPath(try gitPath(["rev-parse", "--show-toplevel"], cwd: repoDirectory))
        let valid = git(["check-ref-format", "--branch", branch], cwd: repoPath)
        guard valid.status == 0 else { throw Failure.invalidBranch(branch) }
        guard branch != "main" else { throw Failure.invalidBranch(branch) }

        let commonRaw = try gitPath(["rev-parse", "--git-common-dir"], cwd: repoPath)
        let repoURL = URL(fileURLWithPath: repoPath, isDirectory: true).standardizedFileURL
        let commonURL = commonRaw.hasPrefix("/")
            ? URL(fileURLWithPath: commonRaw, isDirectory: true)
            : URL(fileURLWithPath: commonRaw, isDirectory: true, relativeTo: repoURL)
        let manager = commonURL.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent("codenv-worktrees", isDirectory: true)
        let expectedURL = manager.appendingPathComponent(branch, isDirectory: true).standardizedFileURL
        let expectedPath = canonicalPath(expectedURL.path)
        guard expectedURL.path.hasPrefix(manager.standardizedFileURL.path + "/") else { throw Failure.invalidBranch(branch) }

        let entries = try worktrees(repoPath: repoPath)
        if let registered = entries.first(where: { $0.branch == branch }) {
            guard FileManager.default.fileExists(atPath: registered.path) else {
                throw Failure.worktreeMismatch("分支「\(branch)」的 worktree 目錄不存在：\(registered.path)")
            }
            return Assignment(branch: branch, path: canonicalPath(registered.path), reused: true)
        }

        guard !FileManager.default.fileExists(atPath: expectedPath) else {
            throw Failure.worktreeMismatch("worktree 路徑已存在但 Git 沒有登記：\(expectedPath)")
        }
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: expectedPath).deletingLastPathComponent(), withIntermediateDirectories: true)

        let branchExists = git(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], cwd: repoPath).status == 0
        if branchExists {
            _ = try gitOK(["-c", "core.hooksPath=/dev/null", "worktree", "add", expectedPath, branch], cwd: repoPath)
        } else {
            let main = git(["show-ref", "--verify", "--quiet", "refs/heads/main"], cwd: repoPath)
            guard main.status == 0 else { throw Failure.noMain }
            _ = try gitOK(["-c", "core.hooksPath=/dev/null", "worktree", "add", "-b", branch, expectedPath, "main"], cwd: repoPath)
        }

        let after = try worktrees(repoPath: repoPath)
        guard let created = after.first(where: { $0.path == expectedPath && $0.branch == branch }) else {
            throw Failure.worktreeMismatch("Git 沒有登記新建的 worktree：\(expectedPath)")
        }
        return Assignment(branch: branch, path: created.path, reused: false)
    }

    /// 先擋未提交變更，再以 merge-tree 預檢；整段不更新工作目錄或 index。
    static func check(worktreePath: String, branch: String, base: String = "main") throws -> MergeCheck {
        let path = canonicalPath(worktreePath)
        let current = canonicalPath(try gitPath(["rev-parse", "--show-toplevel"], cwd: path))
        guard current == path else { throw Failure.worktreeMismatch("指定路徑不是 worktree 根目錄：\(path)") }
        let actualBranch = try gitPath(["branch", "--show-current"], cwd: path)
        guard actualBranch == branch else {
            throw Failure.worktreeMismatch("worktree 分支是「\(actualBranch)」，不是「\(branch)」")
        }
        guard git(["check-ref-format", "--branch", base], cwd: path).status == 0,
              git(["show-ref", "--verify", "--quiet", "refs/heads/\(base)"], cwd: path).status == 0 else {
            throw Failure.git("找不到整合分支「\(base)」")
        }

        let status = git(["--no-optional-locks", "status", "--porcelain=v1", "--untracked-files=all"], cwd: path)
        guard status.status == 0 else { throw Failure.git("讀取 worktree 狀態失敗") }
        if !status.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .uncommitted(status.out.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let result = git(["merge-tree", "--write-tree", "--name-only", "-z", base, branch], cwd: path, timeout: 30, maxBytes: 1_000_000)
        if result.timedOut { throw Failure.git("merge-tree 預檢超過 30 秒") }
        if result.status == 0 { return .clean }
        if result.status == 1 {
            let files = conflictPaths(result.out)
            guard !files.isEmpty else { throw Failure.git("merge-tree 回報衝突，但無法解析檔名：\(result.out)") }
            return .conflicts(files)
        }
        throw Failure.git("merge-tree 預檢失敗（\(result.status)）：\(result.out.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    static func dispatchText(_ text: String, worktreePath: String?) -> String {
        guard let path = worktreePath, !path.isEmpty else { return text }
        return "工作資料夾：\(path)\n\(text)"
    }

    /// 測試版探針（--commander-worktree-probe-scenario file-dir|odd-names）：只驗合併預檢列出的衝突檔清單。
    /// file-dir：一邊把檔案 f 換成資料夾 f/，另一邊改 f 的內容；odd-names：兩邊改同一批含空白、中文、引號、換行的檔名。
    static func runScenarioProbe(in stateDirectory: URL, scenario: String) -> [String: Any] {
        guard scenario == "file-dir" || scenario == "odd-names" else {
            return ["ok": false, "scenario": scenario, "error": "未知情境（file-dir|odd-names）"]
        }
        let repo = stateDirectory.appendingPathComponent("commander-worktree-scenario-\(UUID().uuidString.lowercased())", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            func run(_ args: [String], cwd: String? = nil) throws -> String {
                let result = git(args, cwd: cwd ?? repo.path, timeout: 30)
                guard result.status == 0, !result.timedOut else {
                    throw Failure.git("探針 Git 指令失敗（\(result.status)）：\(args.joined(separator: " "))")
                }
                return result.out.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            func write(_ name: String, _ content: String, in directory: String) throws {
                let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(content.utf8).write(to: url, options: .atomic)
            }
            func commit(_ message: String, in directory: String) throws {
                _ = try run(["add", "-A"], cwd: directory)
                _ = try run(["commit", "-m", message], cwd: directory)
            }
            let oddNames = ["含 空白.txt", "中文檔.txt", "it's.txt", "line\nbreak.txt"]
            _ = try run(["init", "-b", "main"])
            _ = try run(["config", "user.name", "Worktree Probe"])
            _ = try run(["config", "user.email", "worktree-probe@example.test"])
            if scenario == "file-dir" {
                try write("f", "base\n", in: repo.path)
            } else {
                for name in oddNames { try write(name, "base\n", in: repo.path) }
            }
            try write("keep.txt", "keep\n", in: repo.path)
            try commit("base", in: repo.path)
            let feature = try assign(repoDirectory: repo.path, branch: "feat-scenario", engine: "codex", isNewChat: true)
            if scenario == "file-dir" {
                try FileManager.default.removeItem(atPath: feature.path + "/f")
                try write("f/g", "dir child\n", in: feature.path)
            } else {
                for name in oddNames { try write(name, "feature\n", in: feature.path) }
            }
            try commit("feature change", in: feature.path)
            _ = try run(["switch", "-c", "scenario-integration"])
            if scenario == "file-dir" {
                try write("f", "integration\n", in: repo.path)
            } else {
                for name in oddNames { try write(name, "integration\n", in: repo.path) }
            }
            try commit("integration change", in: repo.path)
            _ = try run(["switch", "main"])
            let result = try check(worktreePath: feature.path, branch: feature.branch, base: "scenario-integration")
            switch result {
            case .conflicts(let files):
                let looksLikeSentence = files.contains { $0.contains("CONFLICT") || $0.contains("): ") }
                return ["ok": !looksLikeSentence, "scenario": scenario, "state": "conflicts", "conflictFiles": files, "conflictCount": files.count,
                        "expectedOddNames": scenario == "odd-names" ? oddNames : [], "repo": repo.path]
            case .clean:
                return ["ok": false, "scenario": scenario, "state": "clean", "conflictFiles": [String](), "repo": repo.path]
            case .uncommitted(let changes):
                return ["ok": false, "scenario": scenario, "state": "uncommitted", "changes": changes, "conflictFiles": [String](), "repo": repo.path]
            }
        } catch {
            return ["ok": false, "scenario": scenario, "error": error.localizedDescription, "repo": repo.path]
        }
    }

    /// 測試版探針：在傳入的隔離資料夾建立假 repo，驗分支建立／重用／拒絕、merge-tree 結果與主目錄不變。
    static func runProbe(in stateDirectory: URL) -> [String: Any] {
        let repo = stateDirectory.appendingPathComponent("commander-worktree-probe-\(UUID().uuidString.lowercased())", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            func run(_ args: [String], cwd: String? = nil) throws -> String {
                let result = git(args, cwd: cwd ?? repo.path, timeout: 30)
                guard result.status == 0, !result.timedOut else {
                    throw Failure.git("探針 Git 指令失敗（\(result.status)）：\(args.joined(separator: " "))")
                }
                return result.out.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            func write(_ name: String, _ content: String, to directory: String) throws {
                try Data(content.utf8).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name), options: .atomic)
            }
            func commit(_ message: String, in directory: String, files: [String]) throws {
                _ = try run(["add"] + files, cwd: directory)
                _ = try run(["commit", "-m", message], cwd: directory)
            }

            _ = try run(["init", "-b", "main"])
            _ = try run(["config", "user.name", "Worktree Probe"])
            _ = try run(["config", "user.email", "worktree-probe@example.test"])
            try write("shared.txt", "base line\n", to: repo.path)
            try commit("base", in: repo.path, files: ["shared.txt"])
            let mainHeadBefore = try run(["rev-parse", "refs/heads/main"])
            let headBefore = try run(["rev-parse", "HEAD"])

            let first = try assign(repoDirectory: repo.path, branch: "feat-clean", engine: "codex", isNewChat: false)
            let reused = try assign(repoDirectory: repo.path, branch: "feat-clean", engine: "codex", isNewChat: false)
            let directoryInGitAdmin = try gitPath(["rev-parse", "--git-common-dir"], cwd: repo.path)
            let gitAdminURL = URL(fileURLWithPath: directoryInGitAdmin, isDirectory: true, relativeTo: repo).standardizedFileURL.resolvingSymlinksInPath()
            let expectedRoot = gitAdminURL.appendingPathComponent("codenv-worktrees", isDirectory: true).path + "/"

            _ = try run(["switch", "-c", "merge-clean-base"])
            try write("other.txt", "independent change\n", to: repo.path)
            try commit("clean base change", in: repo.path, files: ["other.txt"])
            _ = try run(["switch", "main"])
            let cleanResult = try check(worktreePath: first.path, branch: first.branch, base: "merge-clean-base")

            let conflict = try assign(repoDirectory: repo.path, branch: "feat-conflict", engine: "codex", isNewChat: true)
            try write("shared.txt", "feature line\n", to: conflict.path)
            try commit("feature change", in: conflict.path, files: ["shared.txt"])
            _ = try run(["switch", "-c", "merge-conflict-base"])
            try write("shared.txt", "integration line\n", to: repo.path)
            try commit("integration change", in: repo.path, files: ["shared.txt"])
            _ = try run(["switch", "main"])
            let conflictResult = try check(worktreePath: conflict.path, branch: conflict.branch, base: "merge-conflict-base")

            try write("untracked.txt", "uncommitted\n", to: first.path)
            let dirtyResult = try check(worktreePath: first.path, branch: first.branch, base: "merge-clean-base")

            let claudeHome = stateDirectory.appendingPathComponent("worktree-probe-claude-home", isDirectory: true)
            let transcript = claudeHome.appendingPathComponent("projects/example-project", isDirectory: true)
                .appendingPathComponent("existing-session.jsonl")
            try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
            let transcriptBefore = Data("既有 Claude transcript fixture\n".utf8)
            try transcriptBefore.write(to: transcript, options: .atomic)
            let worktreesBeforeClaudeReject = try run(["worktree", "list", "--porcelain"])
            let refsBeforeClaudeReject = try run(["show-ref"])
            let statusBeforeClaudeReject = try run(["status", "--porcelain=v1", "--untracked-files=all"])
            let claudeReject: String
            do {
                try validate(engine: "claude", isNewChat: false)
                claudeReject = "accepted"
            } catch { claudeReject = error.localizedDescription }
            let worktreesAfterClaudeReject = try run(["worktree", "list", "--porcelain"])
            let refsAfterClaudeReject = try run(["show-ref"])
            let statusAfterClaudeReject = try run(["status", "--porcelain=v1", "--untracked-files=all"])
            let transcriptAfter = try Data(contentsOf: transcript)
            let mainHeadAfter = try run(["rev-parse", "refs/heads/main"])
            let headAfter = try run(["rev-parse", "HEAD"])
            let mainStatus = try run(["status", "--porcelain"])
            let message = dispatchText("probe task", worktreePath: first.path)

            let clean = { if case .clean = cleanResult { return true }; return false }()
            let conflictFiles: [String] = { if case .conflicts(let files) = conflictResult { return files }; return [] }()
            let dirty = { if case .uncommitted(let changes) = dirtyResult { return changes.contains("untracked.txt") }; return false }()
            let claudeRejected = claudeReject.contains("既有 Claude 聊天室不能帶 --worktree")
            let noBranchCreated = git(["show-ref", "--verify", "--quiet", "refs/heads/claude-must-not-move"], cwd: repo.path).status != 0
            let claudeNewAllowed = (try? validate(engine: "claude", isNewChat: true)) != nil
            let codexExistingAllowed = (try? validate(engine: "codex", isNewChat: false)) != nil
            let claudeRejectUnchanged = noBranchCreated
                && worktreesBeforeClaudeReject == worktreesAfterClaudeReject
                && refsBeforeClaudeReject == refsAfterClaudeReject
                && statusBeforeClaudeReject == statusAfterClaudeReject
                && transcriptBefore == transcriptAfter
            let results: [String: Any] = [
                "ok": clean && conflictFiles.contains("shared.txt") && dirty && claudeRejected
                    && claudeRejectUnchanged && claudeNewAllowed && codexExistingAllowed
                    && mainHeadBefore == mainHeadAfter && headBefore == headAfter && mainStatus.isEmpty
                    && first.path == reused.path && reused.reused && !first.reused
                    && first.path.hasPrefix(expectedRoot)
                    && message == "工作資料夾：\(first.path)\nprobe task",
                "repo": repo.path,
                "cleanMergeCheck": clean,
                "conflictFiles": conflictFiles,
                "uncommittedDetected": dirty,
                "worktreeCreatedUnderGitAdmin": first.path.hasPrefix(expectedRoot),
                "existingWorktreeReused": first.path == reused.path && reused.reused,
                "newClaudeWorktreeAllowed": claudeNewAllowed,
                "existingNonClaudeWorktreeAllowed": codexExistingAllowed,
                "existingClaudeRejected": claudeRejected,
                "existingClaudeRejectNoRepoChange": claudeRejectUnchanged,
                "existingClaudeTranscriptUnchanged": transcriptBefore == transcriptAfter,
                "dispatchIncludesWorktreePath": message == "工作資料夾：\(first.path)\nprobe task",
                "mainRefUnchanged": mainHeadBefore == mainHeadAfter,
                "headUnchanged": headBefore == headAfter,
                "mainWorktreeClean": mainStatus.isEmpty
            ]
            return results
        } catch {
            return ["ok": false, "repo": repo.path, "error": error.localizedDescription]
        }
    }

    private static func worktrees(repoPath: String) throws -> [Worktree] {
        let result = git(["worktree", "list", "--porcelain"], cwd: repoPath)
        guard result.status == 0 else { throw Failure.git("讀取 Git worktree 清單失敗") }
        var entries: [Worktree] = []
        var path: String?
        var branch: String?
        func append() {
            if let path { entries.append(Worktree(path: URL(fileURLWithPath: path).standardizedFileURL.path, branch: branch)) }
            path = nil
            branch = nil
        }
        for line in result.out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.isEmpty { append() }
            else if line.hasPrefix("worktree ") { path = canonicalPath(String(line.dropFirst("worktree ".count))) }
            else if line.hasPrefix("branch refs/heads/") { branch = String(line.dropFirst("branch refs/heads/".count)) }
        }
        append()
        return entries
    }

    /// `merge-tree --name-only -z` 輸出：樹 OID、衝突檔名（每個以 NUL 結尾）、空欄位，之後是給人看的訊息；
    /// 只讀檔名那一段，所以 file/directory 這類沒有「Merge conflict in」字樣的衝突也不會被當成檔名亂報。
    private static func conflictPaths(_ text: String) -> [String] {
        var fields = text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        guard !fields.isEmpty else { return [] }
        fields.removeFirst()
        var paths = Set<String>()
        for field in fields {
            if field.isEmpty { break }
            paths.insert(field)
        }
        return paths.sorted()
    }

    private static func gitPath(_ args: [String], cwd: String) throws -> String {
        let result = git(args, cwd: cwd)
        guard result.status == 0 else { throw Failure.git("Git 指令失敗：\(args.joined(separator: " "))") }
        let value = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw Failure.git("Git 指令沒有回傳路徑：\(args.joined(separator: " "))") }
        return value
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func gitOK(_ args: [String], cwd: String) throws -> RPShell.Result {
        let result = git(args, cwd: cwd, timeout: 30)
        guard result.status == 0, !result.timedOut else {
            let detail = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.git("Git 建立 worktree 失敗\(detail.isEmpty ? "" : "：\(detail)")")
        }
        return result
    }

    private static func git(_ args: [String], cwd: String, timeout: TimeInterval = 8, maxBytes: Int = 600_000) -> RPShell.Result {
        RPShell.git(["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false"] + args, cwd: cwd, timeout: timeout, maxBytes: maxBytes)
    }
}
