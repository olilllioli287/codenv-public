#!/usr/bin/env python3
"""檢查 C176 的 --commander-worktree-probe JSON。"""
import json
import pathlib
import sys


def verify(path_text, state_text):
    path = pathlib.Path(path_text)
    state = pathlib.Path(state_text)
    failures = 0

    def check(label, actual, expected, predicate):
        nonlocal failures
        passed = predicate(actual)
        print(f"  {'通過' if passed else '失敗'}：{label}；輸入={path}；預期={expected!r}；實際={actual!r}")
        if not passed:
            failures += 1

    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"  失敗：probe JSON 可讀；輸入={path}；預期=有效 JSON；實際={type(error).__name__}: {error}")
        return 1
    if not isinstance(data, dict):
        print(f"  失敗：probe JSON 根節點為物件；輸入={path}；預期=dict；實際={type(data).__name__}")
        return 1

    check("probe 總判定通過", data.get("ok"), True, lambda value: value is True)
    boolean_fields = (
        ("cleanMergeCheck", "乾淨分支 merge-check 回報可合併"),
        ("uncommittedDetected", "未提交修改被 merge-check 偵測並處理"),
        ("existingWorktreeReused", "既有分支 worktree 沿用"),
        ("worktreeCreatedUnderGitAdmin", "worktree 建在 Git 管理目錄下"),
        ("newClaudeWorktreeAllowed", "新 Claude 聊天室可使用 worktree"),
        ("existingNonClaudeWorktreeAllowed", "既有非 Claude 聊天室可使用 worktree"),
        ("existingClaudeRejected", "既有 Claude 聊天室帶 --worktree 被拒"),
        ("existingClaudeRejectNoRepoChange", "拒絕既有 Claude 聊天室時 repo 沒有變動"),
        ("existingClaudeTranscriptUnchanged", "拒絕既有 Claude 聊天室時 transcript 未變"),
        ("dispatchIncludesWorktreePath", "派工訊息包含 worktree 路徑"),
        ("mainRefUnchanged", "預檢沒有改動 main ref"),
        ("headUnchanged", "預檢沒有改動目前 HEAD"),
        ("mainWorktreeClean", "預檢後主 worktree 仍乾淨"),
    )
    for key, label in boolean_fields:
        check(label, data.get(key), True, lambda value: value is True)

    conflict_files = data.get("conflictFiles")
    check("衝突分支列出 shared.txt", conflict_files, "list containing shared.txt",
          lambda value: isinstance(value, list) and "shared.txt" in value)

    repo_value = data.get("repo")
    try:
        state_resolved = state.resolve(strict=True)
        repo_resolved = pathlib.Path(repo_value).resolve(strict=True) if isinstance(repo_value, str) else None
        repo_inside_state = repo_resolved is not None and repo_resolved.is_relative_to(state_resolved)
    except (OSError, RuntimeError):
        repo_resolved = None
        repo_inside_state = False
    check("probe 假 repo 存在於隔離 state-dir 內", str(repo_resolved) if repo_resolved else repo_value,
          f"位於 {state} 之下", lambda _value: repo_inside_state)
    print(f"C176 斷言失敗數：{failures}")
    return 1 if failures else 0


def main():
    if len(sys.argv) != 4 or sys.argv[1] != "verify":
        print("用法：commander-worktree-probe.py verify <probe.json> <state-dir>", file=sys.stderr)
        return 2
    return verify(sys.argv[2], sys.argv[3])


if __name__ == "__main__":
    raise SystemExit(main())
