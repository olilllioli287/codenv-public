#!/usr/bin/env python3
"""Build private, disposable Git fixtures and check C170's visible Git rows."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path


def run_git(repo: Path, *args: str, env: dict[str, str] | None = None) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )
    return result.stdout.strip()


def commit(repo: Path, message: str, date: str) -> None:
    env = {
        **os.environ,
        "GIT_AUTHOR_NAME": "Exam User",
        "GIT_AUTHOR_EMAIL": "exam@example.test",
        "GIT_COMMITTER_NAME": "Exam User",
        "GIT_COMMITTER_EMAIL": "exam@example.test",
        "GIT_AUTHOR_DATE": date,
        "GIT_COMMITTER_DATE": date,
    }
    run_git(repo, "add", "-A")
    run_git(repo, "commit", "--quiet", "-m", message, env=env)


def init_repo(path: Path, branch: str, file_count: int, message: str, date: str) -> None:
    path.mkdir(parents=True, exist_ok=True)
    subprocess.run(["git", "init", "-q"], cwd=path, check=True)
    run_git(path, "checkout", "-qb", branch)
    run_git(path, "config", "user.name", "Exam User")
    run_git(path, "config", "user.email", "exam@example.test")
    for index in range(1, file_count + 1):
        (path / f"tracked-{index:02}.txt").write_text("base\n", encoding="utf-8")
    commit(path, message, date)


def dirty_tracked(repo: Path, count: int) -> None:
    for index in range(1, count + 1):
        (repo / f"tracked-{index:02}.txt").write_text("changed\n", encoding="utf-8")


def status_count(repo: Path) -> int:
    return len(run_git(repo, "status", "--porcelain=v1", "--untracked-files=all").splitlines())


def assert_fixture(path: Path, branch: str, count: int, message: str) -> None:
    assert run_git(path, "branch", "--show-current") == branch, path
    assert status_count(path) == count, (path.name, status_count(path), count)
    assert run_git(path, "log", "-1", "--format=%s") == message, path


def prepare(base: Path) -> None:
    commander = base / "commander"
    nested = commander / "level-one" / "NestedRepoA"
    configured = base / "ConfiguredRepoB"
    alpha = base / "alpha-worktree"
    beta = base / "beta-worktree"
    root_repo = base / "CommanderRootRepo"

    assert not (commander / ".git").exists(), "commander fixture 必須不是 Git repo"
    init_repo(nested, "nested-a", 17, "EXAM_NESTED_LATEST", "2016-01-02T03:04:05+00:00")
    dirty_tracked(nested, 17)

    init_repo(configured, "main-b", 43, "EXAM_CONFIGURED_BASE", "2017-02-03T04:05:06+00:00")
    run_git(configured, "worktree", "add", "-q", "-b", "feature-alpha", str(alpha), "main-b")
    (alpha / "alpha-marker.txt").write_text("alpha\n", encoding="utf-8")
    commit(alpha, "EXAM_ALPHA_LATEST", "2018-03-04T05:06:07+00:00")
    dirty_tracked(alpha, 37)

    run_git(configured, "worktree", "add", "-q", "-b", "feature-beta", str(beta), "main-b")
    (beta / "beta-marker.txt").write_text("beta\n", encoding="utf-8")
    commit(beta, "EXAM_BETA_LATEST", "2019-04-05T06:07:08+00:00")
    dirty_tracked(beta, 43)

    (configured / "main-marker.txt").write_text("main\n", encoding="utf-8")
    commit(configured, "EXAM_CONFIGURED_LATEST", "2017-02-03T04:05:06+00:00")
    dirty_tracked(configured, 23)

    init_repo(root_repo, "commander-main", 13, "EXAM_ROOT_LATEST", "2020-05-06T07:08:09+00:00")
    dirty_tracked(root_repo, 13)

    assert_fixture(nested, "nested-a", 17, "EXAM_NESTED_LATEST")
    assert_fixture(configured, "main-b", 23, "EXAM_CONFIGURED_LATEST")
    assert_fixture(alpha, "feature-alpha", 37, "EXAM_ALPHA_LATEST")
    assert_fixture(beta, "feature-beta", 43, "EXAM_BETA_LATEST")
    assert_fixture(root_repo, "commander-main", 13, "EXAM_ROOT_LATEST")

    # Keep the tree layout and expected values available to the shell runner.
    manifest = {
        "commander": str(commander),
        "nested_repo": str(nested),
        "configured_repo": str(configured),
        "alpha_worktree": str(alpha),
        "beta_worktree": str(beta),
        "root_repo": str(root_repo),
    }
    (base / "fixture.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print("  斷言通過：暫存 Git fixtures 的分支、最近 commit 與未提交檔數已核對")


def scalar_text(value: object) -> list[str]:
    if isinstance(value, str):
        return [value]
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return [str(value)]
    if isinstance(value, list):
        return [part for item in value for part in scalar_text(item)]
    if isinstance(value, dict):
        return [part for item in value.values() for part in scalar_text(item)]
    return []


def visible_rows(document: object) -> list[str]:
    candidates: list[list[str]] = []

    def visit(node: object) -> None:
        if isinstance(node, dict):
            for key, child in node.items():
                if isinstance(child, list) and any(token in key.casefold() for token in ("row", "line", "entry", "item")):
                    rows = [" ".join(scalar_text(item)) for item in child]
                    if rows:
                        candidates.append(rows)
                visit(child)
        elif isinstance(node, list):
            for child in node:
                visit(child)

    visit(document)
    if candidates:
        return max(candidates, key=len)
    return scalar_text(document)


class Checks:
    def __init__(self, label: str):
        self.label = label
        self.failures = 0

    def check(self, name: str, passed: bool, actual: str = "") -> None:
        if passed:
            print(f"  斷言通過：{self.label}：{name}")
        else:
            self.failures += 1
            suffix = f"（實際：{actual[:320]}）" if actual else ""
            print(f"  斷言失敗：{self.label}：{name}{suffix}")


TIME_RE = re.compile(
    r"(?:\b(?:19|20)\d{2}\b|今天|昨天|前天|\b\d+\s*(?:秒|分鐘|小時|天|週|月|年)(?:前)?\b|\b\d+\s*(?:seconds?|minutes?|hours?|days?|weeks?|months?|years?)\s+ago\b)",
    re.IGNORECASE,
)


def read_probe(path: Path, checks: Checks) -> object:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as error:
        checks.check("probe JSON 可讀取", False, repr(error))
        return {}


def check_no_write_actions(checks: Checks, document: object) -> None:
    actions = {
        "push", "push to remote", "push changes", "commit", "commit changes",
        "推送", "推送到遠端", "提交", "提交變更",
    }
    found = [text.strip() for text in scalar_text(document) if text.strip().casefold() in actions]
    checks.check("沒有推送／commit 寫入動作文字", not found, ", ".join(found))


def verify_related(probe_path: Path) -> None:
    checks = Checks("非 repo 總指揮資料夾")
    document = read_probe(probe_path, checks)
    rows = visible_rows(document)
    flat = "\n".join(rows)
    is_probe = isinstance(document, dict)
    checks.check("Git 分頁已載入相關 repo 概覽", is_probe and document.get("loaded") is True and
                 document.get("isRepo") is False and document.get("isRelatedOverview") is True)
    repos = document.get("repos", []) if is_probe else []
    checks.check("相關 repo 概覽恰列兩個主 repo", isinstance(repos, list) and len(repos) == 2, repr(repos))
    by_name = {repo.get("name"): repo for repo in repos if isinstance(repo, dict)}
    nested = by_name.get("NestedRepoA", {})
    configured = by_name.get("ConfiguredRepoB", {})

    checks.check("列出兩層內發現的 NestedRepoA", nested.get("name") == "NestedRepoA")
    checks.check("NestedRepoA 分支正確", nested.get("branch") == "nested-a", str(nested.get("branch")))
    checks.check("NestedRepoA 未提交檔數正確", nested.get("uncommittedCount") == 17,
                 str(nested.get("uncommittedCount")))
    nested_latest = str(nested.get("latestCommit", ""))
    checks.check("NestedRepoA 顯示最近 commit 的日期時間與訊息",
                 "EXAM_NESTED_LATEST" in nested_latest and bool(TIME_RE.search(nested_latest)), nested_latest)
    checks.check("NestedRepoA 的 worktree 收在 repo 群組下",
                 nested.get("worktreeGroup") == "Worktree (1)" and len(nested.get("worktrees", [])) == 1,
                 repr(nested.get("worktreeGroup")))
    nested_worktrees = nested.get("worktrees", [])
    checks.check("NestedRepoA worktree 列出正確分支與 17 個未提交檔",
                 len(nested_worktrees) == 1 and "nested-a" in nested_worktrees[0] and
                 "NestedRepoA" in nested_worktrees[0] and "未提交 17" in nested_worktrees[0],
                 repr(nested_worktrees))

    checks.check("設定的 ConfiguredRepoB 分支正確", configured.get("branch") == "main-b",
                 str(configured.get("branch")))
    checks.check("ConfiguredRepoB 群組未提交總數正確", configured.get("uncommittedCount") == 103,
                 str(configured.get("uncommittedCount")))
    configured_latest = str(configured.get("latestCommit", ""))
    checks.check("ConfiguredRepoB 顯示 repo 群組最新 commit 的日期時間與訊息",
                 "EXAM_BETA_LATEST" in configured_latest and bool(TIME_RE.search(configured_latest)),
                 configured_latest)
    worktrees = configured.get("worktrees", [])
    checks.check("ConfiguredRepoB 下分組三個 worktree", configured.get("worktreeGroup") == "Worktree (3)" and
                 isinstance(worktrees, list) and len(worktrees) == 3,
                 f"{configured.get('worktreeGroup')}；{len(worktrees) if isinstance(worktrees, list) else '非列表'}")
    expected_worktrees = (
        ("main-b", "ConfiguredRepoB", 23),
        ("feature-alpha", "alpha-worktree", 37),
        ("feature-beta", "beta-worktree", 43),
    )
    for branch, path_marker, count in expected_worktrees:
        matches = [row for row in worktrees if branch in row]
        checks.check(f"{branch} worktree 分支、路徑與未提交數正確",
                     len(matches) == 1 and path_marker in matches[0] and f"未提交 {count}" in matches[0],
                     repr(matches))

    parent_rows = [i for i, row in enumerate(rows) if "ConfiguredRepoB" in row and "main-b" in row and "未提交 103" in row]
    group_rows = [i for i, row in enumerate(rows) if row == "Worktree (3)"]
    child_markers = (
        ("main-b", "/ConfiguredRepoB"),
        ("feature-alpha", "alpha-worktree"),
        ("feature-beta", "beta-worktree"),
    )
    child_rows = [i for i, row in enumerate(rows) if any(branch in row and path_marker in row
                  for branch, path_marker in child_markers)]
    checks.check("畫面將 worktree 列放在 ConfiguredRepoB 主 repo 群組下",
                 bool(parent_rows and group_rows and child_rows and parent_rows[0] < group_rows[0] < min(child_rows)),
                 repr(rows))
    checks.check("不顯示非 Git 專案錯誤", "這個資料夾不是 git 專案" not in flat and "not a git project" not in flat.casefold())
    check_no_write_actions(checks, document)
    if checks.failures:
        raise SystemExit(f"C170 非 repo 情境失敗 {checks.failures} 項")


def verify_single(probe_path: Path) -> None:
    checks = Checks("資料夾本身是 repo")
    document = read_probe(probe_path, checks)
    rows = visible_rows(document)
    flat = "\n".join(rows)
    is_probe = isinstance(document, dict)
    checks.check("Git 分頁判定資料夾本身是 repo", is_probe and document.get("loaded") is True and
                 document.get("isRepo") is True)
    checks.check("資料夾是 repo 時維持單 repo 檢視", is_probe and document.get("isRelatedOverview") is False)
    repos = document.get("repos", []) if is_probe else []
    checks.check("單 repo 檢視不帶相關 repo 概覽清單", repos == [], repr(repos))
    other_markers = ("NestedRepoA", "ConfiguredRepoB", "nested-a", "main-b", "feature-alpha", "feature-beta")
    checks.check("repo 根目錄不顯示相關 repo 概覽", not any(marker in flat for marker in other_markers), flat)
    check_no_write_actions(checks, document)
    if checks.failures:
        raise SystemExit(f"C170 repo 根目錄情境失敗 {checks.failures} 項")


def main() -> None:
    if len(sys.argv) < 3:
        raise SystemExit("用法：git-related-fixture.py prepare <tmp> | verify-related <probe.json> | verify-single <probe.json>")
    mode = sys.argv[1]
    if mode == "prepare":
        prepare(Path(sys.argv[2]))
    elif mode == "verify-related":
        verify_related(Path(sys.argv[2]))
    elif mode == "verify-single":
        verify_single(Path(sys.argv[2]))
    else:
        raise SystemExit(f"未知模式：{mode}")


if __name__ == "__main__":
    main()
