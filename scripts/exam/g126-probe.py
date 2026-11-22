#!/usr/bin/env python3
"""G126 隔離重現：備份輪替、審查 diff fail-closed、空目標鍵。"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[2]
CLI = Path(os.environ.get("G126_CODENV_TODO") or ROOT / "scripts" / "codenv-todo")
TEMP = Path(tempfile.mkdtemp(prefix="codenv-exam-g126.", dir="/private/tmp"))
failures = 0


def check(label, passed, detail=""):
    global failures
    print(f"  {'通過' if passed else '失敗'}：{label}" + (f"（{detail}）" if detail else ""))
    failures += not passed


def goal(identifier, title=None, status="done"):
    return {"id": identifier, "title": title or identifier, "status": status, "steps": []}


def write_board(path, goals):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"items": [], "goals": goals}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def read_board(path):
    return json.loads(path.read_text(encoding="utf-8"))


def call(collab, args, extra_env=None, cwd=ROOT, timeout=20):
    env = dict(os.environ)
    env["CODENV_COLLAB_FILE"] = str(collab.resolve())
    env["CODENV_REVIEW_PROBE"] = "1"
    env["CODENV_REVIEW_ENABLED"] = "1"
    env.pop("CODENV_REVIEW_FAKE_RESULT", None)
    env.pop("CODENV_REVIEW_FAKE_DELAY", None)
    if extra_env:
        env.update(extra_env)
    return subprocess.run([str(CLI), *args], cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout)


def g1_goal_rm_backup():
    folder = TEMP / "g1"
    collab = folder / "collab.json"
    write_board(collab, [goal("g00001"), goal("g00002")])
    write_board(Path(str(collab) + ".bak"), [goal(f"full-{n:02d}") for n in range(8)])
    result = call(collab, ["goal", "rm", "g00001"])
    backup_count = len(read_board(Path(str(collab) + ".bak"))["goals"])
    check("G1 goal rm 成功刪除一筆", result.returncode == 0, f"exit={result.returncode}")
    check("G1 goal rm 保留 8 筆完整 .bak", backup_count == 8, f".bak goals={backup_count}")
    return result, backup_count


def g6_empty_keys():
    results = []
    for name, args in (("rm", ["goal", "rm", ""]), ("edit", ["goal", "edit", "", "--title", "變更後"])):
        collab = TEMP / f"g6-{name}" / "collab.json"
        write_board(collab, [goal("g-only", "唯一目標")])
        before = collab.read_bytes()
        result = call(collab, args)
        unchanged = collab.read_bytes() == before
        check(f"G6 空鍵 {name} 以 exit 2 拒絕", result.returncode == 2, f"exit={result.returncode}; stderr={result.stderr.strip()!r}")
        check(f"G6 空鍵 {name} 不修改看板", unchanged)
        results.append(result)
    whitespace = TEMP / "g6-whitespace" / "collab.json"
    write_board(whitespace, [goal("g-only", "唯一目標")])
    before = whitespace.read_bytes()
    result = call(whitespace, ["goal", "rm", " \t"])
    check("G6 純空白鍵以 exit 2 拒絕", result.returncode == 2, f"exit={result.returncode}")
    check("G6 純空白鍵不修改看板", whitespace.read_bytes() == before)
    whitespace_edit = TEMP / "g6-whitespace-edit" / "collab.json"
    write_board(whitespace_edit, [goal("g-only", "唯一目標")])
    before = whitespace_edit.read_bytes()
    result = call(whitespace_edit, ["goal", "edit", " \t", "--title", "變更後"])
    check("G6 goal edit 純空白鍵以 exit 2 拒絕", result.returncode == 2, f"exit={result.returncode}")
    check("G6 goal edit 純空白鍵不修改看板", whitespace_edit.read_bytes() == before)

    valid = TEMP / "g6-valid-keys" / "collab.json"
    write_board(valid, [goal("g-prefix-1", "前綴目標"), goal("g-delete", "完全相同標題")])
    prefix = call(valid, ["goal", "edit", "g-prefix", "--title", "改名後"])
    exact_title = call(valid, ["goal", "rm", "完全相同標題"])
    current = read_board(valid)["goals"]
    check("G6 有效 ID 前綴仍可編輯", prefix.returncode == 0 and current[0].get("title") == "改名後")
    check("G6 標題完全相同比對仍可刪除", exact_title.returncode == 0 and len(current) == 1 and current[0].get("id") == "g-prefix-1")
    return results


def init_repo(path):
    path.mkdir(parents=True)
    subprocess.run(["git", "init", "-q", str(path)], check=True, capture_output=True, text=True)
    tracked = path / "tracked.txt"
    tracked.write_text("baseline\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(path), "add", "tracked.txt"], check=True, capture_output=True, text=True)
    subprocess.run(["git", "-C", str(path), "-c", "user.name=Codenv Exam", "-c", "user.email=exam@example.test",
                    "commit", "-q", "-m", "fixture baseline"], check=True, capture_output=True, text=True)
    base = subprocess.check_output(["git", "-C", str(path), "rev-parse", "HEAD"], text=True).strip()
    return base, tracked


def fake_git_env(folder, intercept="", log_path=None):
    fakebin = folder / "fakebin"
    fakebin.mkdir(parents=True, exist_ok=True)
    real_git = shutil.which("git")
    fake_git = fakebin / "git"
    logging = (f'printf "%s\\n" "$*" >> "$G126_GIT_LOG"\n' if log_path else "")
    fake_git.write_text(
        "#!/bin/sh\n" + logging + intercept + f"exec {real_git} \"$@\"\n",
        encoding="utf-8")
    fake_git.chmod(0o755)
    env = {"PATH": str(fakebin) + os.pathsep + os.environ.get("PATH", "")}
    if log_path:
        env["G126_GIT_LOG"] = str(log_path)
    return env


def wait_review_result(collab, sid, extra_env=None, timeout=12):
    status = {}
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        probe = call(collab, ["review-probe", "status", sid], extra_env=extra_env)
        try:
            status = json.loads(probe.stdout)
        except json.JSONDecodeError:
            status = {}
        if status.get("errorCount", 0) >= 1 or status.get("rejectCount", 0) >= 1 or status.get("state") == "blocked":
            break
        time.sleep(0.2)
    return status


def g2_git_diff_failure():
    folder = TEMP / "g2-git-failure"
    repo = folder / "repo"
    base, _tracked = init_repo(repo)
    collab = folder / "collab.json"
    write_board(collab, [{"id": "g-review", "title": "審查目標", "status": "active", "steps": [
        {"id": "s-git-failure", "text": "一般施工步驟", "owner": "codenv_worker", "state": "doing",
         "reviewDir": str(repo), "reviewBase": base, "rejectCount": 0}
    ]}])
    fakebin = folder / "fakebin"
    fakebin.mkdir()
    real_git = shutil.which("git")
    fake_git = fakebin / "git"
    fake_git.write_text(
        "#!/bin/sh\n"
        "for arg in \"$@\"; do\n"
        "  if [ \"$arg\" = diff ]; then echo 'fixture git diff failure' >&2; exit 77; fi\n"
        "done\n"
        f"exec {real_git} \"$@\"\n", encoding="utf-8")
    fake_git.chmod(0o755)
    env = {"PATH": str(fakebin) + os.pathsep + os.environ.get("PATH", "")}
    result = call(collab, ["step", "s-git-failure", "完成"], extra_env=env, timeout=25)
    status = {}
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        probe = call(collab, ["review-probe", "status", "s-git-failure"], extra_env=env)
        try:
            status = json.loads(probe.stdout)
        except json.JSONDecodeError:
            status = {}
        if status.get("state") == "doing" and "Git diff 檢查失敗" in status.get("note", ""):
            break
        time.sleep(0.2)
    raw_step = read_board(collab)["goals"][0]["steps"][0]
    check("G2 git diff 非零時不標完成", status.get("state") != "done", f"state={status.get('state')!r}")
    check("G2 git diff 非零按 ERROR 計數", raw_step.get("errorCount") == 1 and status.get("rejectCount") == 0,
          f"errorCount={raw_step.get('errorCount')!r}; rejectCount={status.get('rejectCount')!r}")
    return result, status


def g2_git_root_failure_is_error():
    folder = TEMP / "g2-git-root-failure"
    repo = folder / "repo"
    init_repo(repo)
    collab = folder / "collab.json"
    write_board(collab, [{"id": "g-review", "title": "審查目標", "status": "active", "steps": [
        {"id": "s-root-failure", "text": "一般施工步驟", "owner": "codenv_worker", "state": "doing"}
    ]}])
    fake_env = fake_git_env(folder,
        'if [ "$3" = "rev-parse" ] && [ "$4" = "--show-toplevel" ]; then echo "fixture rev-parse failure" >&2; exit 42; fi\n')
    result = call(collab, ["step", "s-root-failure", "完成"], extra_env=fake_env, cwd=repo)
    status = wait_review_result(collab, "s-root-failure", extra_env=fake_env)
    raw_step = read_board(collab)["goals"][0]["steps"][0]
    check("G2 git rev-parse 非 128 錯誤不標完成", raw_step.get("state") != "done",
          f"state={raw_step.get('state')!r}; exit={result.returncode}")
    check("G2 git rev-parse 非 128 走 ERROR 計數", raw_step.get("errorCount") == 1 and raw_step.get("rejectCount", 0) == 0,
          f"errorCount={raw_step.get('errorCount')!r}; rejectCount={raw_step.get('rejectCount')!r}; status={status}")
    return result, status


def g2_missing_review_base_never_uses_later_head():
    folder = TEMP / "g2-missing-review-base"
    repo = folder / "repo"
    _base, tracked = init_repo(repo)
    collab = folder / "collab.json"
    write_board(collab, [{"id": "g-review", "title": "審查目標", "status": "active", "steps": [
        {"id": "s-missing-base", "text": "一般施工步驟", "state": "todo", "rejectCount": 0}
    ]}])
    fakebin = folder / "fakebin"
    fakebin.mkdir()
    real_git = shutil.which("git")
    fake_git = fakebin / "git"
    marker = folder / "head-failed-once"
    git_log = folder / "git.log"
    fake_git.write_text(
        "#!/bin/sh\n"
        'printf "%s\\n" "$*" >> "$G126_GIT_LOG"\n'
        'if [ "$3" = "rev-parse" ] && [ "$4" = "HEAD" ] && [ ! -e "$G126_HEAD_FAIL_MARKER" ]; then\n'
        '  : > "$G126_HEAD_FAIL_MARKER"\n'
        '  echo "fixture HEAD unavailable once" >&2\n'
        '  exit 42\n'
        'fi\n'
        f'exec {real_git} "$@"\n', encoding="utf-8")
    fake_git.chmod(0o755)
    env = {"PATH": str(fakebin) + os.pathsep + os.environ.get("PATH", ""),
           "G126_HEAD_FAIL_MARKER": str(marker), "G126_GIT_LOG": str(git_log)}

    entered = call(collab, ["step", "s-missing-base", "進行中"], extra_env=env, cwd=repo)
    after_enter = read_board(collab)["goals"][0]["steps"][0]
    check("G2 首次 HEAD 失敗不保存缺少的基準", entered.returncode == 0
          and not after_enter.get("reviewBase") and bool(after_enter.get("reviewContextError")),
          f"exit={entered.returncode}; base={after_enter.get('reviewBase')!r}; error={after_enter.get('reviewContextError')!r}")

    tracked.write_text("change committed after context capture failed\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(repo), "add", "tracked.txt"], check=True, capture_output=True, text=True)
    subprocess.run(["git", "-C", str(repo), "-c", "user.name=Codenv Exam", "-c", "user.email=exam@example.test",
                    "commit", "-q", "-m", "change after failed capture"], check=True, capture_output=True, text=True)

    error_counts = []
    for attempt in (1, 2, 3):
        result = call(collab, ["step", "s-missing-base", "完成"], extra_env=env, cwd=repo, timeout=25)
        deadline = time.monotonic() + 12
        status = {}
        while time.monotonic() < deadline:
            probe = call(collab, ["review-probe", "status", "s-missing-base"], extra_env=env)
            try:
                status = json.loads(probe.stdout)
            except json.JSONDecodeError:
                status = {}
            step = read_board(collab)["goals"][0]["steps"][0]
            if step.get("errorCount", 0) >= attempt and status.get("state") != "reviewing":
                break
            time.sleep(0.2)
        step = read_board(collab)["goals"][0]["steps"][0]
        error_counts.append(step.get("errorCount", 0))
        expected_state = "blocked" if attempt >= 3 else "doing"
        expected_needs_user = attempt >= 3
        check(f"G2 缺少原始基準第 {attempt} 次完成仍 fail-closed（含升級規則）", result.returncode == 0
              and step.get("state") == expected_state and step.get("state") != "done"
              and status.get("needsUser") is expected_needs_user
              and not step.get("reviewBase") and bool(step.get("reviewContextError"))
              and step.get("errorCount") == attempt and step.get("rejectCount", 0) == 0,
              f"exit={result.returncode}; state={step.get('state')!r}; needsUser={status.get('needsUser')!r}; "
              f"base={step.get('reviewBase')!r}; errorCount={step.get('errorCount')!r}; "
              f"rejectCount={step.get('rejectCount')!r}; contextError={step.get('reviewContextError')!r}")
    calls = git_log.read_text(encoding="utf-8").splitlines()
    head_calls = [line for line in calls if "rev-parse" in line and line.endswith(" HEAD")]
    diff_calls = [line for line in calls if " diff " in f" {line} "]
    check("G2 缺少原始基準不以後來 HEAD 或 diff 當基準放行", len(head_calls) >= 4 and not diff_calls,
          f"HEAD calls={head_calls!r}; diff calls={diff_calls!r}; errorCounts={error_counts!r}")

    # 領（claim）路徑同樣在 HEAD 失敗一次後 commit，第 1、2 次完成皆不得 done。
    claim_folder = TEMP / "g2-missing-review-base-claim"
    claim_repo = claim_folder / "repo"
    _cbase, claim_tracked = init_repo(claim_repo)
    claim_collab = claim_folder / "collab.json"
    write_board(claim_collab, [{"id": "g-review", "title": "審查目標", "status": "active", "steps": [
        {"id": "s-missing-claim", "text": "一般施工步驟", "state": "todo", "rejectCount": 0}
    ]}])
    claim_marker = claim_folder / "head-failed-once"
    claim_log = claim_folder / "git.log"
    claim_env = {"PATH": str(fakebin) + os.pathsep + os.environ.get("PATH", ""),
                 "G126_HEAD_FAIL_MARKER": str(claim_marker), "G126_GIT_LOG": str(claim_log)}
    claimed = call(claim_collab, ["step", "s-missing-claim", "領", "--by", "codenv_worker"],
                   extra_env=claim_env, cwd=claim_repo)
    after_claim = read_board(claim_collab)["goals"][0]["steps"][0]
    check("G2 領步驟 HEAD 失敗不保存缺少的基準", claimed.returncode == 0
          and not after_claim.get("reviewBase") and bool(after_claim.get("reviewContextError")),
          f"exit={claimed.returncode}; base={after_claim.get('reviewBase')!r}; error={after_claim.get('reviewContextError')!r}")
    claim_tracked.write_text("committed after claim capture failed\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(claim_repo), "add", "tracked.txt"], check=True, capture_output=True, text=True)
    subprocess.run(["git", "-C", str(claim_repo), "-c", "user.name=Codenv Exam", "-c", "user.email=exam@example.test",
                    "commit", "-q", "-m", "change after claim failure"], check=True, capture_output=True, text=True)
    for attempt in (1, 2):
        res = call(claim_collab, ["step", "s-missing-claim", "完成"], extra_env=claim_env, cwd=claim_repo, timeout=25)
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            st = read_board(claim_collab)["goals"][0]["steps"][0]
            if st.get("errorCount", 0) >= attempt and st.get("state") != "reviewing":
                break
            time.sleep(0.2)
        st = read_board(claim_collab)["goals"][0]["steps"][0]
        check(f"G2 領步驟缺少原始基準第 {attempt} 次完成仍 fail-closed",
              res.returncode == 0 and st.get("state") == "doing" and st.get("errorCount") == attempt
              and not st.get("reviewBase") and bool(st.get("reviewContextError")),
              f"exit={res.returncode}; state={st.get('state')!r}; errorCount={st.get('errorCount')!r}; base={st.get('reviewBase')!r}")
    return error_counts


def g2_failed_root_reentry_uses_toplevel():
    folder = TEMP / "g2-root-reentry-toplevel"
    repo = folder / "repo"
    init_repo(repo)
    subdir = repo / "nested" / "child"
    subdir.mkdir(parents=True)
    collab = folder / "collab.json"
    write_board(collab, [{"id": "g-review", "title": "審查目標", "status": "active", "steps": [
        {"id": "s-root-reentry", "text": "一般施工步驟", "state": "todo", "rejectCount": 0}
    ]}])
    fakebin = folder / "fakebin"
    fakebin.mkdir()
    real_git = shutil.which("git")
    fake_git = fakebin / "git"
    marker = folder / "root-failed-once"
    fake_git.write_text(
        "#!/bin/sh\n"
        'if [ "$3" = "rev-parse" ] && [ "$4" = "--show-toplevel" ] && [ ! -e "$G126_ROOT_FAIL_MARKER" ]; then\n'
        '  : > "$G126_ROOT_FAIL_MARKER"\n'
        '  echo "fixture root unavailable once" >&2\n'
        '  exit 42\n'
        'fi\n'
        f'exec {real_git} "$@"\n', encoding="utf-8")
    fake_git.chmod(0o755)
    env = {"PATH": str(fakebin) + os.pathsep + os.environ.get("PATH", ""),
           "G126_ROOT_FAIL_MARKER": str(marker)}

    first = call(collab, ["step", "s-root-reentry", "進行中"], extra_env=env, cwd=subdir)
    after_first = read_board(collab)["goals"][0]["steps"][0]
    check("G2 git root 失敗不保存未驗證的 cwd", first.returncode == 0
          and "reviewDir" not in after_first and bool(after_first.get("reviewContextError")),
          f"exit={first.returncode}; reviewDir={after_first.get('reviewDir')!r}; error={after_first.get('reviewContextError')!r}")
    reentry = call(collab, ["step", "s-root-reentry", "進行中"], extra_env=env, cwd=subdir)
    after_reentry = read_board(collab)["goals"][0]["steps"][0]
    check("G2 子目錄重入後 reviewDir 使用 Git toplevel", reentry.returncode == 0
          and after_reentry.get("reviewDir") == str(repo.resolve())
          and bool(after_reentry.get("reviewBase"))
          and not after_reentry.get("reviewContextError"),
          f"exit={reentry.returncode}; expected={str(repo.resolve())!r}; actual={after_reentry.get('reviewDir')!r}; "
          f"base={after_reentry.get('reviewBase')!r}; error={after_reentry.get('reviewContextError')!r}")

    # 先前已確認過 reviewDir（git_root 成功但 git_head 失敗）時，後續 git_root 暫時失敗不可清掉既有 reviewDir。
    preserve_folder = TEMP / "g2-preserve-review-dir"
    repo_a = preserve_folder / "repo-a"
    repo_b = preserve_folder / "repo-b"
    init_repo(repo_a)
    init_repo(repo_b)
    preserve_collab = preserve_folder / "collab.json"
    write_board(preserve_collab, [{"id": "g-review", "title": "審查目標", "status": "active", "steps": [
        {"id": "s-preserve-dir", "text": "一般施工步驟", "state": "todo", "rejectCount": 0}
    ]}])
    head_fail_env = fake_git_env(preserve_folder / "fail-head",
        'if [ "$3" = "rev-parse" ] && [ "$4" = "HEAD" ]; then echo "fixture HEAD fail" >&2; exit 42; fi\n')
    root_fail_env = fake_git_env(preserve_folder / "fail-root",
        'if [ "$3" = "rev-parse" ] && [ "$4" = "--show-toplevel" ]; then echo "fixture root fail" >&2; exit 42; fi\n')
    step1 = call(preserve_collab, ["step", "s-preserve-dir", "進行中"], extra_env=head_fail_env, cwd=repo_a)
    after_step1 = read_board(preserve_collab)["goals"][0]["steps"][0]
    step2 = call(preserve_collab, ["step", "s-preserve-dir", "進行中"], extra_env=root_fail_env, cwd=repo_b)
    after_step2 = read_board(preserve_collab)["goals"][0]["steps"][0]
    check("G2 先前已確認的 reviewDir 不因後續 git root 失敗被清掉",
          step1.returncode == 0 and step2.returncode == 0
          and after_step1.get("reviewDir") == str(repo_a.resolve())
          and after_step2.get("reviewDir") == str(repo_a.resolve())
          and bool(after_step2.get("reviewContextError")),
          f"after1={after_step1.get('reviewDir')!r}; after2={after_step2.get('reviewDir')!r}; error={after_step2.get('reviewContextError')!r}")
    return first, reentry


def g2_non_git_c218_still_finishes_with_notice():
    folder = TEMP / "g2-non-git-c218"
    folder.mkdir(parents=True)
    collab = folder / "collab.json"
    write_board(collab, [{"id": "g-review", "title": "審查目標", "status": "active", "steps": [
        {"id": "s-non-git", "text": "一般施工步驟", "state": "doing", "rejectCount": 0}
    ]}])
    result = call(collab, ["step", "s-non-git", "完成"], cwd=folder)
    step = read_board(collab)["goals"][0]["steps"][0]
    check("G2 C218 真非 Git 資料夾仍提示未送審並完成",
          result.returncode == 0 and step.get("state") == "done"
          and "未送審（目前工作資料夾不是 git 專案）" in step.get("note", "")
          and "目前工作資料夾不是 git 專案" in result.stderr,
          f"exit={result.returncode}; state={step.get('state')!r}; note={step.get('note')!r}; stderr={result.stderr.strip()!r}")
    return result, step


def g2_merge_base_failure_is_error():
    folder = TEMP / "g2-merge-base-failure"
    repo = folder / "repo"
    init_repo(repo)
    collab = folder / "collab.json"
    write_board(collab, [{"id": "g-review", "title": "審查目標", "status": "active", "steps": [
        {"id": "s-merge-base-failure", "text": "一般施工步驟", "owner": "codenv_worker", "state": "doing"}
    ]}])
    fake_env = fake_git_env(folder,
        'if [ "$3" = "merge-base" ]; then echo "fixture merge-base failure" >&2; exit 77; fi\n')
    result = call(collab, ["step", "s-merge-base-failure", "完成"], extra_env=fake_env, cwd=repo)
    status = wait_review_result(collab, "s-merge-base-failure", extra_env=fake_env)
    raw_step = read_board(collab)["goals"][0]["steps"][0]
    check("G2 git merge-base 失敗不退回 HEAD 後標完成", raw_step.get("state") != "done",
          f"state={raw_step.get('state')!r}; exit={result.returncode}")
    check("G2 git merge-base 失敗走 ERROR 計數", raw_step.get("errorCount") == 1 and raw_step.get("rejectCount", 0) == 0,
          f"errorCount={raw_step.get('errorCount')!r}; rejectCount={raw_step.get('rejectCount')!r}; status={status}")
    return result, status


def g2_doing_reentry_preserves_review_base():
    folder = TEMP / "g2-doing-reentry"
    repo = folder / "repo"
    base, tracked = init_repo(repo)
    tracked.write_text("committed after the original review base\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(repo), "add", "tracked.txt"], check=True, capture_output=True, text=True)
    subprocess.run(["git", "-C", str(repo), "-c", "user.name=Codenv Exam", "-c", "user.email=exam@example.test",
                    "commit", "-q", "-m", "later change"], check=True, capture_output=True, text=True)
    collab = folder / "collab.json"
    write_board(collab, [{"id": "g-review", "title": "審查目標", "status": "active", "steps": [
        {"id": "s-doing-reentry", "text": "一般施工步驟", "owner": "codenv_worker", "state": "doing",
         "reviewDir": str(repo), "reviewBase": base, "rejectCount": 0}
    ]}])
    git_log = folder / "git.log"
    fake_env = fake_git_env(folder, log_path=git_log)
    reentered = call(collab, ["step", "s-doing-reentry", "進行中"], extra_env=fake_env, cwd=repo)
    after_reentry = read_board(collab)["goals"][0]["steps"][0]
    log_after_reentry = git_log.read_text(encoding="utf-8") if git_log.exists() else ""
    check("G2 進行中重入保留既有 reviewBase", after_reentry.get("reviewBase") == base,
          f"expected={base}; actual={after_reentry.get('reviewBase')!r}; exit={reentered.returncode}")
    check("G2 既有 reviewBase 重入時不重新取 HEAD", not log_after_reentry.strip(),
          f"git calls={log_after_reentry.strip()!r}")
    resubmitted = call(collab, ["step", "s-doing-reentry", "完成"], extra_env={
        **fake_env, "CODENV_REVIEW_FAKE_RESULT": "REJECT"}, cwd=repo, timeout=25)
    status = wait_review_result(collab, "s-doing-reentry", extra_env=fake_env)
    check("G2 重入後原差異仍送審", "已送阿公審查" in resubmitted.stdout and status.get("state") == "doing"
          and status.get("rejectCount") == 1,
          f"stdout={resubmitted.stdout.strip()!r}; status={status}")
    return reentered, resubmitted, status


def g2_reject_preserves_review_base():
    folder = TEMP / "g2-review-base"
    repo = folder / "repo"
    base, tracked = init_repo(repo)
    tracked.write_text("changed and committed after the earlier review base\n", encoding="utf-8")
    collab = folder / "collab.json"
    write_board(collab, [{"id": "g-review", "title": "審查目標", "status": "active", "steps": [
        {"id": "s-review-base", "text": "一般施工步驟", "owner": "codenv_worker", "state": "doing",
         "reviewDir": str(repo), "reviewBase": base, "rejectCount": 0}
    ]}])
    rejected = call(collab, ["step", "s-review-base", "完成"], extra_env={
        "CODENV_REVIEW_FAKE_RESULT": "REJECT", "CODENV_REVIEW_FAKE_DELAY": "1.5"})
    check("G2 首輪 diff 進入審查", rejected.returncode == 0 and "已送阿公審查" in rejected.stdout,
          f"exit={rejected.returncode}; stdout={rejected.stdout.strip()!r}")
    subprocess.run(["git", "-C", str(repo), "add", "tracked.txt"], check=True, capture_output=True, text=True)
    subprocess.run(["git", "-C", str(repo), "-c", "user.name=Codenv Exam", "-c", "user.email=exam@example.test",
                    "commit", "-q", "-m", "reviewed change"], check=True, capture_output=True, text=True)
    head = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
    first_status = {}
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        probe = call(collab, ["review-probe", "status", "s-review-base"])
        try:
            first_status = json.loads(probe.stdout)
        except json.JSONDecodeError:
            first_status = {}
        if first_status.get("state") != "reviewing" and first_status.get("rejectCount") == 1:
            break
        time.sleep(0.2)
    after_reject = read_board(collab)["goals"][0]["steps"][0]
    check("G2 REJECT 原有退回狀態仍為 doing", after_reject.get("state") == "doing" and after_reject.get("rejectCount") == 1,
          f"state={after_reject.get('state')!r}; rejectCount={after_reject.get('rejectCount')!r}")
    check("G2 REJECT 不把基準移到已提交的 HEAD", after_reject.get("reviewBase") == base,
          f"expected={base}; actual={after_reject.get('reviewBase')!r}; HEAD={head}")
    resubmitted = call(collab, ["step", "s-review-base", "完成"], extra_env={"CODENV_REVIEW_FAKE_RESULT": "REJECT"}, timeout=25)
    status = {}
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        probe = call(collab, ["review-probe", "status", "s-review-base"])
        try:
            status = json.loads(probe.stdout)
        except json.JSONDecodeError:
            status = {}
        if status.get("state") != "reviewing":
            break
        time.sleep(0.2)
    check("G2 REJECT 後原提交 diff 仍會再送審",
          "已送阿公審查" in resubmitted.stdout and status.get("state") == "doing" and status.get("rejectCount") == 2,
          f"stdout={resubmitted.stdout.strip()!r}; state={status.get('state')!r}")
    return rejected, resubmitted, status


def g2_pass_advances_review_base_to_reviewed_head():
    folder = TEMP / "g2-pass-review-base"
    repo = folder / "repo"
    base, tracked = init_repo(repo)
    tracked.write_text("committed change included in review\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(repo), "add", "tracked.txt"], check=True, capture_output=True, text=True)
    subprocess.run(["git", "-C", str(repo), "-c", "user.name=Codenv Exam", "-c", "user.email=exam@example.test",
                    "commit", "-q", "-m", "reviewed change"], check=True, capture_output=True, text=True)
    reviewed_head = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
    collab = folder / "collab.json"
    write_board(collab, [{"id": "g-review", "title": "審查目標", "status": "active", "steps": [
        {"id": "s-pass-review-base", "text": "一般施工步驟", "owner": "codenv_worker", "state": "doing",
         "reviewDir": str(repo), "reviewBase": base, "rejectCount": 0}
    ]}])
    submitted = call(collab, ["step", "s-pass-review-base", "完成"], extra_env={
        "CODENV_REVIEW_FAKE_RESULT": "PASS", "CODENV_REVIEW_FAKE_DELAY": "1.5"}, cwd=repo)
    tracked.write_text("later change after review started\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(repo), "add", "tracked.txt"], check=True, capture_output=True, text=True)
    subprocess.run(["git", "-C", str(repo), "-c", "user.name=Codenv Exam", "-c", "user.email=exam@example.test",
                    "commit", "-q", "-m", "change after review started"], check=True, capture_output=True, text=True)
    later_head = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
    status = {}
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        probe = call(collab, ["review-probe", "status", "s-pass-review-base"])
        try:
            status = json.loads(probe.stdout)
        except json.JSONDecodeError:
            status = {}
        if status.get("state") != "reviewing":
            break
        time.sleep(0.2)
    raw_step = read_board(collab)["goals"][0]["steps"][0]
    check("G2 PASS 後以送審時 HEAD 更新 reviewBase", raw_step.get("reviewBase") == reviewed_head,
          f"expected={reviewed_head}; actual={raw_step.get('reviewBase')!r}")
    check("G2 PASS 不把審查期間的新 commit 納入基準", reviewed_head != later_head and raw_step.get("reviewBase") != later_head,
          f"reviewedHead={reviewed_head}; laterHead={later_head}; base={raw_step.get('reviewBase')!r}")
    check("G2 PASS 仍完成步驟", submitted.returncode == 0 and status.get("state") == "done",
          f"exit={submitted.returncode}; status={status}")
    return submitted, status


def main():
    print(f"G126 暫存資料夾：{TEMP}")
    g1_goal_rm_backup()
    g6_empty_keys()
    g2_git_diff_failure()
    g2_git_root_failure_is_error()
    g2_missing_review_base_never_uses_later_head()
    g2_failed_root_reentry_uses_toplevel()
    g2_non_git_c218_still_finishes_with_notice()
    g2_merge_base_failure_is_error()
    g2_doing_reentry_preserves_review_base()
    g2_reject_preserves_review_base()
    g2_pass_advances_review_base_to_reviewed_head()
    print(f"G126 失敗數：{failures}")
    if failures == 0:
        shutil.rmtree(TEMP, ignore_errors=True)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
