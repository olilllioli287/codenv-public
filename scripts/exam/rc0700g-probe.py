#!/usr/bin/env python3
"""以公開探針輸出驗收 07-9／10／14／15／18，並比對隔離資料 metadata。"""

from __future__ import annotations

import json
import os
import signal
import stat
import subprocess
import sys
import time
import hashlib
import re
from pathlib import Path
from typing import Any
import pathlib as _pl, sys as _sys
_sys.path.insert(0, str(_pl.Path(__file__).resolve().parent))
import psread  # noqa: E402（共用 ps 讀取，見 psread.py）


def check(label: str, ok: bool, actual: Any) -> bool:
    print(f"{'通過' if ok else '失敗'}：{label}；實際={actual!r}")
    return ok


def test_pref_domain(state_dir: Path) -> str:
    """測試 suite 以 App 解開 symlink 後的 state-dir UTF-8 路徑雜湊隔離。"""
    canonical = str(state_dir.resolve())
    digest = hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:32]
    return f"com.local.aiworkbench.test.{digest}"


def read_json(path: str) -> dict[str, Any]:
    value = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("probe 頂層不是 object")
    return value


def check_readme_file(data: dict[str, Any], state_dir: Path, label: str) -> bool:
    raw_path = data.get("path")
    content = data.get("content")
    if not isinstance(raw_path, str) or not isinstance(content, str):
        return check(f"{label} README 路徑與內容有效", False,
                     {"pathType": type(raw_path).__name__, "contentType": type(content).__name__})
    path = Path(raw_path)
    if not path.is_absolute():
        path = state_dir / path
    try:
        confined = path.resolve().is_relative_to(state_dir.resolve())
        exists = path.is_file()
        same = exists and path.read_text(encoding="utf-8", errors="replace") == content
    except OSError:
        confined = exists = same = False
    return check(f"{label} README 實際寫入暫存 state-dir 且內容相符",
                 confined and exists and same,
                 {"underStateDir": confined, "exists": exists, "contentMatches": same})


def strings(value: Any):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for nested in value.values():
            yield from strings(nested)
    elif isinstance(value, list):
        for nested in value:
            yield from strings(nested)


def archive_private(path: str, state_dir: str | None = None) -> int:
    data = read_json(path)
    model_input = data.get("modelInput")
    readme = data.get("content")
    ok = True
    ok &= check("07-9 probe 提供模型輸入", isinstance(model_input, str) and bool(model_input), type(model_input).__name__)
    ok &= check("07-9 probe 提供 README 內容", isinstance(readme, str) and bool(readme), type(readme).__name__)
    marker = "〔已略過私人段落〕"
    if isinstance(model_input, str):
        ok &= check("配對／未配對私人段落都轉成略過標記", marker in model_input, f"marker_count={model_input.count(marker)}")
        ok &= check("私人標籤未送入模型", "<private>" not in model_input.lower(), "<private>" in model_input.lower())
    else:
        ok = False
    if isinstance(readme, str):
        ok &= check("README 含略過標記", marker in readme, f"marker_count={readme.count(marker)}")
        ok &= check("README 不含私人標籤", "<private>" not in readme.lower(), "<private>" in readme.lower())
    else:
        ok = False
    if state_dir is not None:
        ok &= check_readme_file(data, Path(state_dir), "07-9")
        projects = Path(state_dir) / ".claude/projects"
        transcripts = list(projects.rglob("*.jsonl")) if projects.exists() else []
        raw_counts = []
        private_payloads: list[str] = []
        for transcript in transcripts:
            for line in transcript.read_text(encoding="utf-8", errors="replace").splitlines():
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue
                for text in strings(row):
                    cursor = 0
                    while True:
                        opening = text.lower().find("<private>", cursor)
                        if opening < 0:
                            break
                        body_start = opening + len("<private>")
                        closing = text.lower().find("</private>", body_start)
                        if closing < 0:
                            private_payloads.append(text[body_start:])
                            cursor = len(text)
                        else:
                            private_payloads.append(text[body_start:closing])
                            cursor = closing + len("</private>")
            raw = transcript.read_text(encoding="utf-8", errors="replace").lower()
            if "<private>" in raw:
                raw_counts.append((raw.count("<private>"), raw.count("</private>")))
        ok &= check("原始紀錄仍保留兩段 private 與未成對開頭標籤",
                    any(opening >= 2 and closing < opening for opening, closing in raw_counts), raw_counts)
        ok &= check("兩段 private 原文都沒有送入模型輸入或 README",
                    bool(private_payloads) and all(payload not in (model_input or "") and payload not in (readme or "")
                                                  for payload in private_payloads),
                    [len(payload) for payload in private_payloads])
    return 0 if ok else 1


def _compare_transcript_snapshot(snapshot_path: str, projects_dir: str) -> bool:
    snapshot_file = Path(snapshot_path)
    if not snapshot_file.is_file():
        return check("原始紀錄有封存前快照", False, "快照不存在")
    expected = json.loads(snapshot_file.read_text(encoding="utf-8"))
    current_root = Path(projects_dir)
    current = {path.relative_to(current_root).as_posix(): path for path in current_root.rglob("*.jsonl")}
    unchanged = True
    compared = []
    for relative, old in expected.items():
        path = current_root / relative
        if relative not in current:
            unchanged = False
            compared.append((relative, "missing"))
            continue
        try:
            info = path.stat()
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            same = info.st_size == old["size"] and info.st_mtime_ns == old["mtimeNs"] and digest == old["sha256"]
        except OSError:
            same = False
        unchanged &= same
        compared.append((relative, "unchanged" if same else "changed"))
    return check("封存前已存在的原始 JSONL 前後未變", bool(expected) and unchanged, compared)


def archive_route(path: str, route: str, expected_arg: str | None = None,
                  expect_no_route: bool = False, expected_source: str | None = "agy") -> int:
    data = read_json(path)
    calls = data.get("summaryCalls")
    if not isinstance(calls, list):
        calls = []
    route_calls = [call for call in calls if isinstance(call, dict) and call.get("engine") == route]
    ok = check(f"摘要路由 {route} 呼叫次數", len(route_calls) == (0 if expect_no_route else 1), len(route_calls))
    if not expect_no_route:
        if not route_calls:
            return 1
        arguments = route_calls[0].get("arguments", [])
        call_text = " ".join(str(part) for part in arguments)
        display_args = ["-p=<prompt 已遮蔽>" if str(part).startswith("-p=") else part for part in arguments]
        ok &= check(f"{route} 摘要參數符合預期", expected_arg is None or expected_arg in call_text, display_args)
        actual_source = data.get("summarySource")
        if expected_source == "route":
            expected_source = route
        if expected_source is not None:
            ok &= check(f"{route} 路由摘要來源", actual_source == expected_source, actual_source)
    else:
        calls_all = data.get("summaryCalls", [])
        ok &= check("關閉 Hydrogen fallback 後回到 07-6 非 agy 行為", all(
            not isinstance(call, dict) or call.get("engine") != "agy" for call in calls_all
        ), {"engineCounts": {engine: sum(isinstance(call, dict) and call.get("engine") == engine
                                         for call in calls_all)
                            for engine in ("agy", "codex", "claude", "fixture")}})
        ok &= check("關閉 Hydrogen fallback 後仍有 README", bool(data.get("path")) and isinstance(data.get("content"), str),
                    {"hasPath": bool(data.get("path")), "contentType": type(data.get("content")).__name__})
    ok &= check_readme_file(data, Path(path).parent, "07-10")
    return 0 if ok else 1


def quit_summary(path: str) -> int:
    raw = Path(path).read_text(encoding="utf-8", errors="replace")
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        data = raw
    output_strings = list(strings(data))
    claude_rows = sum(value.count("Claude 回答中") for value in output_strings)
    codex_rows = sum(value.count("Codex 回答中") for value in output_strings)
    ok = True
    ok &= check("結束確認清單包含 Claude 回答中", claude_rows > 0, claude_rows)
    ok &= check("結束確認清單包含 Codex 回答中", codex_rows > 0, codex_rows)
    return 0 if ok else 1


def keychain(path: str, fake_log: str) -> int:
    data = read_json(path)
    log_path = Path(fake_log)
    log = log_path.read_text(encoding="utf-8", errors="replace") if log_path.exists() else ""
    state = Path(path).parent
    args_path = state / "usage-keychain-probe-args.txt"
    args_log = args_path.read_text(encoding="utf-8", errors="replace") if args_path.exists() else ""
    ok = True
    ok &= check("--security-bin 指定的自有假 security 腳本收到呼叫", bool(log),
                f"custom_fake_calls={sum(line.startswith('CALL ') for line in log.splitlines())}")
    ok &= check("probe 確認執行假 security 子程序", data.get("usedFakeSecurityProcess") is True,
                data.get("usedFakeSecurityProcess"))
    ok &= check("security 命令參數正確", data.get("commandArgumentsMatched") is True and
                "find-generic-password" in args_log and "-w" in args_log,
                {"commandArgumentsMatched": data.get("commandArgumentsMatched"),
                 "findGenericPassword": "find-generic-password" in args_log, "hasValueFlag": "-w" in args_log})
    ok &= check("服務名稱使用 codenv-test- 前綴", data.get("serviceUsesTestPrefix") is True and
                "codenv-test-" in args_log, data.get("serviceUsesTestPrefix"))
    ok &= check("假 security 值讀取成功", data.get("readValue") is True, data.get("readValue"))
    elapsed = data.get("timeoutElapsedMilliseconds")
    ok &= check("5 秒逾時視為未設定", data.get("timeoutReturnedMissing") is True and
                data.get("usageTimeoutSeconds") == 5 and isinstance(elapsed, (int, float)) and elapsed <= 5000,
                {"timeoutReturnedMissing": data.get("timeoutReturnedMissing"),
                 "usageTimeoutSeconds": data.get("usageTimeoutSeconds"), "elapsedMs": elapsed})
    sec_count = data.get("secItemCopyMatchingCalls")
    ok &= check("未呼叫 SecItemCopyMatching", sec_count == 0, sec_count)
    ok &= check("輸出未包含假值本身", data.get("secretWasNotWritten") is True, data.get("secretWasNotWritten"))
    emitted = "\n".join(strings(data)) + "\n" + log + "\n" + args_log
    ok &= check("probe 與假 security 呼叫紀錄不含測試值", "C177G_FAKE_VALUE_NEVER_PRINT" not in emitted,
                "測試值字面是否出現")
    return 0 if ok else 1


def _services(text: str) -> list[str]:
    found = []
    for line in text.splitlines():
        if line.startswith("SERVICE "):
            found.append(line.removeprefix("SERVICE ").strip())
        elif "codenv-test-" in line:
            found.extend(token.strip("'\" ,;[]") for token in line.split()
                         if token.startswith("codenv-test-"))
    return found


def snapshot_item(path: Path) -> dict[str, Any]:
    if not path.exists() and not path.is_symlink():
        return {"exists": False}
    info = path.lstat()
    data: dict[str, Any] = {"exists": True, "size": info.st_size, "mtimeNs": info.st_mtime_ns}
    if stat.S_ISDIR(info.st_mode):
        with os.scandir(path) as entries:
            data["children"] = {e.name: snapshot_item(Path(e.path)) for e in sorted(entries, key=lambda e: e.name)}
    return data


def snapshot(root: str, output: str) -> int:
    base = Path(root)
    rows = {name: snapshot_item(base / name) for name in (
        "collab.json", "compact-state", "pool-usage.json"
    )}
    Path(output).write_text(json.dumps(rows, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"正式資料 metadata 快照：{output}；未讀取檔案內容。")
    return 0


def compare(before: str, after: str) -> int:
    a = read_json(before)
    b = read_json(after)
    watched = ("collab.json", "compact-state", "pool-usage.json")
    changed = [name for name in watched if a.get(name) != b.get(name)]
    if changed:
        print(f"失敗：正式保護資料 metadata 改變：{changed}；未還原。")
        return 1
    print("通過：正式保護資料 metadata 一致；state.json 依隔離規則排除比對。")
    return 0


def codex_usage(output: str, fixture_paths: list[str]) -> int:
    text = Path(output).read_text(encoding="utf-8", errors="replace") if Path(output).exists() else ""
    fixture_text = "\n".join(Path(path).read_text(encoding="utf-8") for path in fixture_paths)
    addresses = ["a1@example.test", "b2@example.test", "c3@example.test", "d4@example.test",
                 "e5@example.test", "z9@example.test", "p6@example.test"]
    ok = True
    lines = [line for line in text.splitlines() if "free-row" in line]
    safe_lines = [re.sub(r"(email=)\S+", r"\1<遮罩值>", line) for line in lines]
    ok &= check("07-18 probe 有 free-row 資料", bool(lines), {"rowCount": len(lines), "rows": safe_lines})
    aliases = ("free1", "free2", "free3", "free4", "free5")
    alias_order = [alias for line in lines for alias in aliases if f"label={alias}" in line]
    unaliased_rows = [line for line in lines if not any(f"label={alias}" in line for alias in aliases)]
    ok &= check("free-row 依 free1 至 free5 順序各顯示一次", alias_order == list(aliases), alias_order)
    unaliased_masked = (len(unaliased_rows) == 1 and "@example.test" in unaliased_rows[0]
                        and not any(address in unaliased_rows[0] for address in addresses))
    ok &= check("最後一列無 alias 並顯示遮罩信箱", len(lines) == 6 and
                bool(unaliased_rows) and lines[-1] == unaliased_rows[0] and unaliased_masked,
                {"rowCount": len(lines), "unaliasedRowCount": len(unaliased_rows), "rows": safe_lines})
    ok &= check("沒有輸出任何完整 fixture 信箱", all(address not in text for address in addresses),
                {"fullAddressLeakCount": sum(address in text for address in addresses)})
    ok &= check("題目 fixtures 僅包含 example.test 信箱", all("@" not in token or "@example.test" in token
                for token in fixture_text.split()), "fixture domain")
    return 0 if ok else 1


def _write_fake(path: Path, body: str) -> None:
    path.write_text(body, encoding="utf-8")
    path.chmod(0o700)


def _fake_agy(path: Path, log: Path) -> None:
    _write_fake(path, "#!/bin/bash\nprintf 'CALL agy\\n' >> " + repr(str(log)) +
                "\ncat >/dev/null\nprintf 'SYNTHETIC_ARCHIVE_SUMMARY\\n'\n")


def _fake_codex(path: Path, log: Path) -> None:
    _write_fake(path, "#!/bin/bash\nprintf 'CALL codex\\n' >> " + repr(str(log)) +
                "\ncat >/dev/null\nprintf '{\\\"type\\\":\\\"message\\\",\\\"role\\\":\\\"assistant\\\",\\\"content\\\":\\\"SYNTHETIC_ARCHIVE_SUMMARY\\\"}\\n'\n")


def _find_app_pids(app: Path, state: Path) -> list[int]:
    binary = str(app / "Contents/MacOS/Workbench")
    return [pid for pid, command in psread.pid_command(("-ax", "-o", "pid=,command=")) if binary in command and str(state) in command]


def _process_table() -> dict[int, tuple[int, str]]:
    return psread.process_table(("-ax", "-o", "pid=,ppid=,command="))


def _is_descendant(pid: int, roots: set[int], table: dict[int, tuple[int, str]]) -> bool:
    seen: set[int] = set()
    current = pid
    while current in table and current not in seen:
        seen.add(current)
        parent = table[current][0]
        if parent in roots:
            return True
        current = parent
    return False


def _forbidden_child_kind(command: str) -> str | None:
    normalized = command.lower()
    executable = normalized.split(None, 1)[0].strip("'\"") if normalized.split() else ""
    if executable == "/usr/bin/security":
        return "security"
    if "fake-agy" not in normalized and (Path(executable).name == "agy" or "agy -p=" in normalized):
        return "agy"
    if "fake-codex" not in normalized and (Path(executable).name == "codex" or
                                            re.search(r"(?:^|/)codex(?:\s|$)", normalized)):
        return "codex"
    if "fake-magpie" not in normalized and (Path(executable).name == "magpie" or
                                              re.search(r"(?:^|/)magpie(?:\s|$)", normalized)):
        return "magpie"
    return None


def _stop_app(app: Path, state: Path) -> None:
    for pid in _find_app_pids(app, state):
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline and _find_app_pids(app, state):
        time.sleep(0.1)
    for pid in _find_app_pids(app, state):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def _run_instance(app: Path, base: Path, label: str, extra_args: list[str], output: Path,
                  timeout: float = 60.0, transcript_snapshot: Path | None = None) -> tuple[bool, list[str]]:
    state = base / label / "state"
    (state / "compact-state").mkdir(parents=True, exist_ok=True)
    (state / ".claude").mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["CODENV_COMPACT_DIR"] = str(state / "compact-state")
    env["CODENV_POOL_USAGE_FILE"] = str(state / "pool-usage.json")
    if "--agy-bin" not in extra_args:
        extra_args = ["--agy-bin", str(base / "fake-agy"), *extra_args]
    args = ["/usr/bin/open", "-g", "-n", str(app), "--args", "--state-dir", str(state),
            "--claude-home", str(state / ".claude"), "--background", "--test-screen", "ipad",
            "--test-hidden", "--usage-fake", *extra_args,
            "-NSAppSleepDisabled", "YES", "-ApplePersistenceIgnoreState", "YES"]
    print(f"啟動隔離情境 {label}：open -g -n；--state-dir={state}")
    opened = subprocess.run(args, env=env, text=True, capture_output=True)
    if opened.returncode != 0:
        print(f"失敗：open exit={opened.returncode}; stderr={opened.stderr.strip()[:240]}")
        return False, [str(state)]
    deadline = time.monotonic() + timeout
    ready = False
    transcript_base = state / ".claude/projects"
    transcript_rows: dict[str, dict[str, Any]] = {}
    seen_app_pids: set[int] = set()
    forbidden_children: dict[str, set[int]] = {"agy": set(), "codex": set(), "magpie": set(), "security": set()}
    while time.monotonic() < deadline:
        table = _process_table()
        roots = set(_find_app_pids(app, state))
        seen_app_pids.update(roots)
        for pid, (_, command) in table.items():
            kind = _forbidden_child_kind(command)
            if kind and _is_descendant(pid, roots, table):
                forbidden_children[kind].add(pid)
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        if transcript_snapshot is not None and transcript_base.exists():
            for candidate in transcript_base.rglob("*.jsonl"):
                try:
                    stat_result = candidate.stat()
                    payload = candidate.read_bytes()
                except OSError:
                    continue
                relative = candidate.relative_to(transcript_base).as_posix()
                transcript_rows[relative] = {
                    "size": stat_result.st_size,
                    "mtimeNs": stat_result.st_mtime_ns,
                    "sha256": hashlib.sha256(payload).hexdigest(),
                }
            if transcript_rows:
                transcript_snapshot.write_text(json.dumps(transcript_rows, indent=2) + "\n", encoding="utf-8")
        if output.is_file() and output.stat().st_size:
            ready = True
            break
        time.sleep(0.25)
    print(f"測試實例 PID 數：{len(seen_app_pids)}")
    _stop_app(app, state)
    remaining_app_pids = _find_app_pids(app, state)
    check(f"{state.name} 測試實例已停止", not remaining_app_pids,
          {"remainingPidCount": len(remaining_app_pids)})
    child_counts = {kind: len(pids) for kind, pids in forbidden_children.items()}
    safe = not any(forbidden_children.values())
    check(f"{state.name} 沒有啟動真 agy／Codex／magpie／security 子程序", safe, child_counts)
    remaining_children: dict[str, set[int]] = {kind: set() for kind in forbidden_children}
    table_after = _process_table()
    for kind, pids in forbidden_children.items():
        for pid in pids:
            entry = table_after.get(pid)
            if entry and _forbidden_child_kind(entry[1]) == kind:
                remaining_children[kind].add(pid)
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    remaining_children[kind].discard(pid)
    wait_until = time.monotonic() + 1.0
    while time.monotonic() < wait_until and any(remaining_children.values()):
        table_after = _process_table()
        for kind, pids in remaining_children.items():
            pids.intersection_update(pid for pid, (_, command) in table_after.items()
                                     if _forbidden_child_kind(command) == kind)
        time.sleep(0.05)
    for pids in remaining_children.values():
        for pid in list(pids):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pids.discard(pid)
    table_after = _process_table()
    for kind, pids in remaining_children.items():
        pids.intersection_update(pid for pid, (_, command) in table_after.items()
                                 if _forbidden_child_kind(command) == kind)
    residual_counts = {kind: len(pids) for kind, pids in remaining_children.items()}
    no_residual_children = not any(remaining_children.values())
    check(f"{state.name} 沒有測試子程序殘留", no_residual_children, residual_counts)
    return ready and safe and not remaining_app_pids and no_residual_children, [
        str(state), f"測試 App 曾見 PID 數={len(seen_app_pids)}",
        f"子程序={child_counts}", f"殘留子程序={residual_counts}"
    ]


def _make_security(path: Path, log: Path) -> None:
    script = f'''#!/bin/bash
log={str(log)!r}
service=""
previous=""
for argument in "$@"; do
  if [ "$previous" = "-s" ]; then service="$argument"; fi
  previous="$argument"
done
printf 'CALL %s\\n' "$*" >> "$log"
[ -z "$service" ] || printf 'SERVICE %s\\n' "$service" >> "$log"
case "$service" in *timeout*|*slow*) sleep 8; exit 0 ;; esac
printf 'C177G_FAKE_VALUE_NEVER_PRINT'
exit 0
'''
    _write_fake(path, script)


def run_case(case_id: str, app: str, temp: str) -> int:
    app_path = Path(app)
    base = Path(temp).resolve()
    formal_root = Path.home() / "Library/Application Support/codenv"
    pref_domains: set[str] = set()
    app_ok = app_path.is_dir() and (app_path / "Contents/MacOS/Workbench").is_file()
    if not check("測試 App 存在", app_ok, str(app_path)):
        return 1
    before = base / "protected-before.json"
    after = base / "protected-after.json"
    snapshot(str(formal_root), str(before))
    fake_agy = base / "fake-agy"
    agy_log = base / "agy-calls.log"
    fake_codex = base / "fake-codex"
    codex_log = base / "codex-calls.log"
    _fake_agy(fake_agy, agy_log)
    _fake_codex(fake_codex, codex_log)
    return_code = 0
    agy_before = subprocess.run(["/usr/bin/pgrep", "-fl", "agy -p="], text=True,
                                capture_output=True).stdout.splitlines()
    try:
        if case_id == "C178":
            pref_domain = test_pref_domain(base / "private" / "state")
            pref_domains.add(pref_domain)
            _write_fake(fake_agy, "#!/bin/bash\nlog=" + repr(str(agy_log)) +
                        "\nprintf 'CALL agy\\n' >> \"$log\"\npayload=\"$(cat)\"\ncombined=\"$payload $*\"\ncase \"$combined\" in *'〔已略過私人段落〕'*) printf '〔已略過私人段落〕\\n' ;; *) printf 'MISSING_PRIVATE_SKIP_MARKER\\n' ;; esac\n")
            output = base / "private/state/archive-private.json"
            transcript_snapshot = base / "private/transcripts-before.json"
            args = ["--agy-bin", str(fake_agy), "--pref", "archiveSummaryUseAgy=unset",
                    "--pref", "agyEnabled=1", "--archive-readme-probe-engine", "claude",
                    "--archive-readme-probe-agy", "--archive-readme-probe", f"8:{output}"]
            ready, info = _run_instance(app_path, base, "private", args, output,
                                        transcript_snapshot=transcript_snapshot)
            if not check("07-9 archive probe 已完成", ready, info):
                return_code = 1
            elif archive_private(str(output), str(base / "private/state")):
                return_code = 1
            if not _compare_transcript_snapshot(str(transcript_snapshot),
                                                str(base / "private/state/.claude/projects")):
                return_code = 1
            if not check("07-9 私人內容摘要只由假 agy 產生", agy_log.exists() and agy_log.read_text().count("CALL agy") == 1,
                         agy_log.read_text() if agy_log.exists() else "無呼叫記錄"):
                return_code = 1
        elif case_id == "C179":
            scenarios = [
                ("codex", "codex", "unset", "codex", "group/codex-free", False),
                ("agy", "agy", "unset", "agy", "gemini-4-hydrogen-low", False),
                ("claude", "claude", "unset", "agy", "gemini-4-hydrogen-low", False),
                ("disabled", "claude", "off", "agy", None, True),
            ]
            for label, engine, pref, expected_route, expected_arg, no_route in scenarios:
                pref_domain = test_pref_domain(base / label / "state")
                pref_domains.add(pref_domain)
                subprocess.run(["/usr/bin/defaults", "delete", pref_domain, "archiveSummaryUseAgy"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                subprocess.run(["/usr/bin/defaults", "delete", pref_domain, "agyEnabled"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                output = base / label / "state/archive.json"
                args = ["--agy-bin", str(fake_agy), "--codex-bin", str(fake_codex),
                        "--pref", f"archiveSummaryUseAgy={'0' if pref == 'off' else 'unset'}",
                        "--pref", "agyEnabled=1", "--archive-readme-probe-engine", engine,
                        "--archive-readme-probe", f"2:{output}"]
                if engine == "claude" and pref == "unset":
                    args.insert(-2, "--archive-readme-probe-agy")
                ready, info = _run_instance(app_path, base, label, args, output)
                if not check(f"07-10 {label} archive probe 已完成", ready, info):
                    return_code = 1
                elif archive_route(str(output), expected_route, expected_arg, no_route,
                                   None):
                    return_code = 1
                subprocess.run(["/usr/bin/defaults", "delete", pref_domain, "archiveSummaryUseAgy"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                subprocess.run(["/usr/bin/defaults", "delete", pref_domain, "agyEnabled"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            actual_agy = agy_log.read_text(encoding="utf-8") if agy_log.exists() else ""
            actual_codex = codex_log.read_text(encoding="utf-8") if codex_log.exists() else ""
            if not check("假 agy 實際呼叫兩次（agy 與 Claude fallback）", actual_agy.count("CALL agy") == 2,
                         actual_agy.count("CALL agy")):
                return_code = 1
            if not check("假 Codex 實際呼叫一次", actual_codex.count("CALL codex") == 1,
                         actual_codex.count("CALL codex")):
                return_code = 1
        elif case_id == "C180":
            state = base / "keychain/state"
            security_bin = state / "fake-security"
            fake_log = state / "fake-security.log"
            probe = state / "keychain.json"
            state.mkdir(parents=True, exist_ok=True)
            _make_security(security_bin, fake_log)
            security_path_ok = security_bin.is_relative_to(Path("/private/tmp")) and os.access(security_bin, os.X_OK)
            if not check("假 security 位於 /private/tmp 且可執行", security_path_ok,
                         {"underPrivateTmp": security_bin.is_relative_to(Path("/private/tmp")),
                          "executable": os.access(security_bin, os.X_OK)}):
                return_code = 1
            else:
                ready, info = _run_instance(app_path, base, "keychain", [
                    "--agy-bin", str(fake_agy),
                    "--security-bin", str(security_bin), "--usage-keychain-probe", str(probe),
                ], probe, timeout=90)
                if not check("07-14 keychain probe 已完成", ready, info):
                    return_code = 1
                elif keychain(str(probe), str(fake_log)):
                    return_code = 1
        elif case_id == "C181":
            output = base / "quit-summary/state/quit-summary.json"
            ready, info = _run_instance(app_path, base, "quit-summary", [
                "--codex-bin", str(fake_codex), "--quit-summary-probe", str(output),
            ], output)
            if not check("07-15 quit-summary probe 已完成", ready, info):
                return_code = 1
            elif quit_summary(str(output)):
                return_code = 1
        elif case_id == "C182":
            state = base / "codex-usage/state"
            state.mkdir(parents=True, exist_ok=True)
            paid, free, fallback = (state / name for name in ("paid.json", "free.json", "fallback.json"))
            paid.write_text(json.dumps({"accounts": [{
                "id": "paid-1", "user": "p6@example.test", "plan": "plus", "active": True,
                "windows": [{"name": "30 days", "remaining": 87,
                             "resetsAt": "2026-11-18T12:00:00Z"}],
            }]}), encoding="utf-8")
            free_rows = []
            for alias, email in (("free5", "e5@example.test"), ("free2", "b2@example.test"),
                                 ("free4", "d4@example.test"), ("free1", "a1@example.test"),
                                 ("free3", "c3@example.test"), (None, "z9@example.test")):
                row = {"id": f"free-{alias or 'masked'}", "user": email, "plan": "free",
                       "active": True,
                       "windows": [{"name": "30 days", "remaining": 91,
                                    "resetsAt": "2026-11-18T12:00:00Z"}]}
                if alias:
                    row["alias"] = alias
                free_rows.append(row)
            free.write_text(json.dumps({"accounts": free_rows}), encoding="utf-8")
            fallback.write_text(json.dumps({"accounts": []}), encoding="utf-8")
            output = state / "codex-usage.txt"
            ready, info = _run_instance(app_path, base, "codex-usage", [
                "--codex-usage-input", str(paid), "--codex-usage-free-input", str(free),
                "--codex-usage-fallback", str(fallback), "--codex-usage-probe", str(output),
            ], output)
            if not check("07-18 Codex usage probe 已完成", ready, info):
                return_code = 1
            elif codex_usage(str(output), [str(paid), str(free), str(fallback)]):
                return_code = 1
        else:
            return_code = 2
    finally:
        if case_id in ("C178", "C179"):
            for pref_domain in pref_domains:
                for key in ("archiveSummaryUseAgy", "agyEnabled"):
                    subprocess.run(["/usr/bin/defaults", "delete", pref_domain, key],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        snapshot(str(formal_root), str(after))
        if compare(str(before), str(after)):
            return_code = 1
        agy_after = subprocess.run(["/usr/bin/pgrep", "-fl", "agy -p="], text=True, capture_output=True).stdout
        print(f"全域 agy -p= 程序列舉行數（僅記錄，測試子孫另行監看）：測前={len(agy_before)}；測後={len(agy_after.splitlines())}")
        if case_id == "C180":
            # This exercise supplies --security-bin, and the verifier also checks the
            # fake-script log. No command in this harness invokes real security.
            pass
    print(f"{case_id} 完成，exit={return_code}；暫存資料保留於 {base}")
    return return_code


def main(argv: list[str]) -> int:
    try:
        if len(argv) >= 3 and argv[1] == "archive-private":
            return archive_private(argv[2])
        if len(argv) >= 5 and argv[1] == "archive-route":
            return archive_route(argv[2], argv[3], argv[4] if len(argv) > 4 and argv[4] != "--no-route" else None,
                                 "--no-route" in argv)
        if len(argv) == 4 and argv[1] == "keychain":
            return keychain(argv[2], argv[3])
        if len(argv) == 4 and argv[1] == "snapshot":
            return snapshot(argv[2], argv[3])
        if len(argv) == 4 and argv[1] == "compare":
            return compare(argv[2], argv[3])
        if len(argv) >= 4 and argv[1] == "codex-usage":
            return codex_usage(argv[2], argv[3:])
        if len(argv) == 5 and argv[1] == "run":
            return run_case(argv[2], argv[3], argv[4])
    except Exception as exc:
        print(f"失敗：探針驗證例外 {type(exc).__name__}: {exc}")
        return 1
    print("用法錯誤")
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
