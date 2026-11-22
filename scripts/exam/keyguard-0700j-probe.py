#!/usr/bin/env python3
"""C183: black-box KeyGuard probe using synthetic data and isolated state."""

from __future__ import annotations

import base64
import json
import os
import pathlib
import secrets
import signal
import string
import subprocess
import sys
import time
from typing import Any
import pathlib as _pl, sys as _sys
_sys.path.insert(0, str(_pl.Path(__file__).resolve().parent))
import psread  # noqa: E402（共用 ps 讀取，見 psread.py）


SAFE_STRING_KEYS = {"rule", "strength", "type", "reason", "status", "source", "label", "kind"}
PROTECTED_NAMES = (
    "collab.json",
    "compact-state",
    "pool-usage.json",
    "keyguard-false-positives.jsonl",
)
FAILURES: list[str] = []


def check(name: str, ok: bool, actual: Any = None) -> bool:
    state = "通過" if ok else "失敗"
    suffix = "" if actual is None else f"；實際={actual!r}"
    print(f"{state}：{name}{suffix}")
    if not ok:
        FAILURES.append(name)
    return bool(ok)


def safe_shape(value: Any, key: str = "") -> Any:
    if isinstance(value, dict):
        return {name: safe_shape(child, name) for name, child in value.items()}
    if isinstance(value, list):
        return {"count": len(value), "items": [safe_shape(child, key) for child in value[:8]]}
    if isinstance(value, str):
        if key in SAFE_STRING_KEYS and len(value) < 80:
            return value
        return {"type": "string", "length": len(value)}
    if isinstance(value, (bool, int, float)) or value is None:
        return value
    return type(value).__name__


def random_text(length: int, alphabet: str = string.ascii_letters + string.digits) -> str:
    return "".join(secrets.choice(alphabet) for _ in range(length))


def jwt_fake() -> str:
    header = base64.urlsafe_b64encode(b'{"alg":"HS256","typ":"JWT"}').decode().rstrip("=")
    payload = base64.urlsafe_b64encode(b'{"sub":"example.test","purpose":"synthetic"}').decode().rstrip("=")
    signature = random_text(32, string.ascii_letters + string.digits + "-_")
    return f"{header}.{payload}.{signature}"


def make_synthetic_inputs() -> tuple[dict[str, dict[str, Any]], list[str], list[str]]:
    weak_values = [random_text(64, string.ascii_letters + string.digits + "-_") for _ in range(12)]
    darkreader_hash = secrets.token_hex(16)
    strong = {
        "sk-prefix": "sk-" + random_text(40),
        "AIza-prefix": "AIza" + random_text(35, string.ascii_letters + string.digits + "-_"),
        "gsk-prefix": "gsk_" + random_text(48),
        "nvapi-prefix": "nvapi-" + random_text(40),
        "AKIA-prefix": "AKIA" + random_text(16, string.ascii_uppercase + string.digits),
        "JWT": jwt_fake(),
    }

    def weak(value: str) -> str:
        return f'<div data-hash="{value}"></div>'

    def darkreader(value: str) -> str:
        return f'<html><head><meta name="darkreader" content="{value}"></head></html>'

    learned_strong = [weak(value) for value in strong.values()]
    mixed_attachments = [
        f'<div data-hash="{weak_values[6 + index]}">{value}</div>'
        for index, value in enumerate(strong.values())
    ]
    learning = {
        "scans": [
            darkreader(darkreader_hash),
            *[f"synthetic strong-rule sample {value}" for value in strong.values()],
        ],
        "notAKey": [weak(weak_values[1]), weak(weak_values[2])],
        "after": [weak(weak_values[3]), *learned_strong],
        "afterDelete": [],
        "deleteLearned": False,
    }
    deletion = {
        "scans": [],
        "notAKey": [],
        "after": [],
        "afterDelete": [weak(weak_values[4])],
        "deleteLearned": True,
    }
    hard_rules = {
        "scans": [
            *[f"synthetic strong-rule sample {value}" for value in strong.values()],
            *[darkreader(value) for value in strong.values()],
        ],
        "notAKey": [],
        "after": [],
        "afterDelete": [],
        "deleteLearned": False,
        "strongNotAKey": darkreader(strong["sk-prefix"]),
        "mixedNotAKey": mixed_attachments,
        "forceAllowTokens": list(strong.values()),
        "forceAllowCheck": " ".join(strong.values()),
    }
    inputs = {"learning": learning, "deletion": deletion, "hardRules": hard_rules}
    originals = [darkreader_hash] + list(strong.values()) + weak_values
    source_texts: list[str] = []
    for section in inputs.values():
        for key in ("scans", "notAKey", "after", "afterDelete", "mixedNotAKey"):
            source_texts.extend(item for item in section.get(key, []) if isinstance(item, str))
        for key in ("strongNotAKey", "forceAllowCheck"):
            if isinstance(section.get(key), str):
                source_texts.append(section[key])
    return inputs, originals, source_texts


def stat_item(path: pathlib.Path) -> Any:
    try:
        info = path.lstat()
    except FileNotFoundError:
        return {"exists": False}
    result = {
        "exists": True,
        "mode": info.st_mode,
        "dev": info.st_dev,
        "ino": info.st_ino,
        "size": info.st_size,
        "mtimeNs": info.st_mtime_ns,
        "ctimeNs": info.st_ctime_ns,
    }
    if path.is_dir() and not path.is_symlink():
        result["children"] = {
            entry: stat_item(path / entry)
            for entry in sorted(os.listdir(path))
        }
    return result


def protected_snapshot(root: pathlib.Path) -> dict[str, Any]:
    return {name: stat_item(root / name) for name in PROTECTED_NAMES}


def process_table() -> dict[int, tuple[int, str]]:
    return psread.process_table(("-ax", "-o", "pid=,ppid=,command="))


def app_pids(app: pathlib.Path, state_dir: pathlib.Path) -> list[int]:
    binary = str(app / "Contents/MacOS/Workbench")
    state = str(state_dir)
    return [pid for pid, (_, command) in process_table().items() if binary in command and state in command]


def descendant(pid: int, ancestor: int, table: dict[int, tuple[int, str]]) -> bool:
    seen: set[int] = set()
    current = pid
    while current in table and current not in seen:
        seen.add(current)
        parent = table[current][0]
        if parent == ancestor:
            return True
        if parent <= 1:
            return False
        current = parent
    return False


def agy_pids() -> list[int]:
    result = subprocess.run(
        ["/usr/bin/pgrep", "-fl", "agy -p="],
        capture_output=True,
        text=True,
        check=False,
    )
    found: list[int] = []
    for line in result.stdout.splitlines():
        fields = line.split(None, 1)
        if fields and fields[0].isdigit():
            found.append(int(fields[0]))
    return found


def security_pids() -> list[int]:
    table = process_table()
    return [
        pid for pid, (_, command) in table.items()
        if command.startswith("/usr/bin/security ")
    ]


def stop_app(app: pathlib.Path, state_dir: pathlib.Path) -> list[int]:
    pids = app_pids(app, state_dir)
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 6
    while time.monotonic() < deadline and app_pids(app, state_dir):
        time.sleep(0.1)
    remaining = app_pids(app, state_dir)
    for pid in remaining:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    return remaining


def run_probe(
    app: pathlib.Path,
    state: pathlib.Path,
    label: str,
    probe_input: dict[str, Any],
    noop_engine: pathlib.Path,
    env: dict[str, str],
    test_agy_pids: set[int],
    unrelated_agy_pids: set[int],
    test_security_pids: set[int],
) -> tuple[dict[str, Any], str, pathlib.Path] | None:
    state.mkdir(parents=True, exist_ok=True)
    (state / "compact-state").mkdir(exist_ok=True)
    claude_home = state / ".claude"
    claude_home.mkdir(exist_ok=True)
    input_path = state / f"keyguard-{label}-input.json"
    output_path = state / f"keyguard-{label}-output.json"
    input_path.write_text(json.dumps(probe_input, ensure_ascii=False), encoding="utf-8")
    launch_env = env.copy()
    launch_env["CODENV_COMPACT_DIR"] = str(state / "compact-state")
    launch_env["CODENV_POOL_USAGE_FILE"] = str(state / "pool-usage.json")
    args = [
        "/usr/bin/open", "-g", "-n", str(app), "--args",
        "--state-dir", str(state), "--claude-home", str(claude_home),
        "--background", "--test-screen", "ipad", "--test-hidden", "--usage-fake",
        "--agy-bin", str(noop_engine),
        "--keyguard-probe-input", str(input_path),
        "--keyguard-probe-output", str(output_path),
        "-NSAppSleepDisabled", "YES", "-ApplePersistenceIgnoreState", "YES",
    ]
    opened = subprocess.run(args, env=launch_env, capture_output=True, text=True, check=False)
    if opened.returncode != 0:
        check(f"{label} probe 以 open -g 啟動", False, f"exit={opened.returncode}; stderr 字數={len(opened.stderr)}")
        return None

    deadline = time.monotonic() + 60
    ready = False
    seen_app_pids: set[int] = set()
    while time.monotonic() < deadline:
        table = process_table()
        current_apps = app_pids(app, state)
        seen_app_pids.update(current_apps)
        for pid in agy_pids():
            if any(descendant(pid, app_pid, table) for app_pid in current_apps):
                test_agy_pids.add(pid)
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            else:
                unrelated_agy_pids.add(pid)
        for pid in security_pids():
            if any(descendant(pid, app_pid, table) for app_pid in current_apps):
                test_security_pids.add(pid)
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        if output_path.is_file() and output_path.stat().st_size:
            try:
                json.loads(output_path.read_text(encoding="utf-8"))
                ready = True
                break
            except json.JSONDecodeError:
                pass
        # 測試實例可能很快就寫完輸出並結束；還沒辨識到 PID 前用較密的取樣，避免漏看（C183 偶發 PID=0）
        time.sleep(0.25 if seen_app_pids else 0.03)

    remaining = stop_app(app, state)
    check(f"{label} 測試實例已辨識 PID", bool(seen_app_pids), len(seen_app_pids))
    check(f"{label} 測試 App 已停止", not remaining, f"殘留 PID 數={len(remaining)}")
    if not ready:
        check(f"{label} KeyGuard probe 在 60 秒內輸出完整 JSON", False, "未就緒")
        return None
    output_text = output_path.read_text(encoding="utf-8", errors="replace")
    return json.loads(output_text), output_text, state / "keyguard-false-positives.jsonl"


def one_finding(row: Any) -> dict[str, Any] | None:
    if not isinstance(row, dict):
        return None
    findings = row.get("findings")
    if not isinstance(findings, list) or len(findings) != 1 or not isinstance(findings[0], dict):
        return None
    return findings[0]


def run(app_arg: str, temp_arg: str) -> int:
    FAILURES.clear()
    app = pathlib.Path(app_arg).resolve()
    temp = pathlib.Path(temp_arg).resolve()
    base = temp / "keyguard-c183"
    base.mkdir(parents=True, exist_ok=True)
    noop_engine = base / "noop-engine"
    noop_log = base / "noop-engine.log"
    noop_engine.write_text(
        "#!/bin/sh\nprintf 'called\\n' >> " + repr(str(noop_log)) + "\nexit 0\n",
        encoding="utf-8",
    )
    noop_engine.chmod(0o700)

    formal_root = pathlib.Path.home() / "Library/Application Support/codenv"
    before = protected_snapshot(formal_root)
    agy_before = agy_pids()
    print(f"正式保護檔 metadata 已拍快照；測前 agy PID={agy_before}。")
    env = os.environ.copy()
    inputs, originals, source_texts = make_synthetic_inputs()
    test_agy_pids: set[int] = set()
    unrelated_agy_pids: set[int] = set(agy_before)
    test_security_pids: set[int] = set()

    learning_state = base / "learning" / "state"
    learning_result = run_probe(
        app, learning_state, "learning", inputs["learning"], noop_engine, env,
        test_agy_pids, unrelated_agy_pids, test_security_pids,
    )
    deletion_result = None
    hard_result = None
    if learning_result is None:
        check("學習輸入 probe 有結果", False, "無輸出")
    else:
        learning_data, learning_text, learning_path = learning_result
        print("learning probe 安全結構：" + json.dumps(safe_shape(learning_data), ensure_ascii=False))
        learning_log = learning_path.read_text(encoding="utf-8", errors="replace") if learning_path.exists() else ""
        records = [line for line in learning_log.splitlines() if line]

        before_rows = learning_data.get("before") if isinstance(learning_data.get("before"), list) else []
        darkreader_finding = one_finding(before_rows[0]) if len(before_rows) > 0 else None
        check("darkreader 32 位十六進位雜湊被排除且不警告",
              bool(darkreader_finding and darkreader_finding.get("strength") == "弱"
                   and darkreader_finding.get("excluded") is True
                   and darkreader_finding.get("warning") is False),
              {"excluded": darkreader_finding.get("excluded") if darkreader_finding else None,
               "warning": darkreader_finding.get("warning") if darkreader_finding else None})
        baseline_strong = [one_finding(row) for row in before_rows[1:]]
        check("sk-、AIza、gsk_、nvapi-、AKIA、JWT 初次掃描各自警告",
              len(baseline_strong) == 6 and all(
                  item and item.get("strength") == "強" and item.get("warning") is True
                  for item in baseline_strong
              ), f"符合強規則警告數={sum(bool(item and item.get('strength') == '強' and item.get('warning') is True) for item in baseline_strong)}/6")

        feedback = learning_data.get("feedbackResults")
        check("兩次『不是金鑰』都成功呼叫 allow",
              feedback == [True, True], f"成功次數={sum(value is True for value in feedback) if isinstance(feedback, list) else 0}/2")
        check("兩次 allow 各記一筆，第三次自動抑制另記一筆",
              learning_data.get("learningRecordCountBeforeDelete") == 3
              and learning_data.get("learningRecordCount") == 3
              and len(records) == 3,
              {"probeBeforeDelete": learning_data.get("learningRecordCountBeforeDelete"),
               "probeFinal": learning_data.get("learningRecordCount"), "fileLines": len(records),
               "expected": "2 次 false-positive + 1 次弱命中自動抑制"})
        features = learning_data.get("learnedFeatures")
        feature_count = features[0].get("count") if isinstance(features, list) and len(features) == 1 and isinstance(features[0], dict) else None
        check("同前文特徵累積兩次紀錄", feature_count == 2, f"feature 次數={feature_count}")

        after_rows = learning_data.get("afterFeedback") if isinstance(learning_data.get("afterFeedback"), list) else []
        learned_weak = one_finding(after_rows[0]) if after_rows else None
        check("第三個相同特徵弱命中被抑制",
              bool(learned_weak and learned_weak.get("strength") == "弱"
                   and learned_weak.get("learnedSuppressed") is True
                   and learned_weak.get("learningCount", 0) >= 2
                   and learned_weak.get("warning") is False),
              {"suppressed": learned_weak.get("learnedSuppressed") if learned_weak else None,
               "learningCount": learned_weak.get("learningCount") if learned_weak else None,
               "warning": learned_weak.get("warning") if learned_weak else None})
        learned_strong = [one_finding(row) for row in after_rows[1:]]
        check("學習弱特徵後六類強規則仍全部警告",
              len(learned_strong) == 6 and all(
                  item and item.get("strength") == "強" and item.get("warning") is True
                  and item.get("learnedSuppressed") is False
                  for item in learned_strong
              ), f"仍警告數={sum(bool(item and item.get('strength') == '強' and item.get('warning') is True and item.get('learnedSuppressed') is False) for item in learned_strong)}/6")
        check("探針確認學習檔沒有命中原文", learning_data.get("learningLogContainsRawHit") is False,
              learning_data.get("learningLogContainsRawHit"))
        learning_all = learning_text + learning_log
        leak_count = sum(1 for value in originals if value and value in learning_all)
        full_text_leaks = sum(1 for value in source_texts if value and value in learning_log)
        check("probe 輸出與學習檔都不含合成命中原文", leak_count == 0, f"原文外洩數={leak_count}")
        check("學習檔不存附件全文", full_text_leaks == 0, f"附件全文外洩數={full_text_leaks}")
        check("學習檔只在暫存 state-dir", learning_path.is_relative_to(learning_state)
              and learning_path.is_file(), str(learning_path.relative_to(learning_state))
              if learning_path.is_relative_to(learning_state) else "路徑超出暫存")

        deletion_result = run_probe(
            app, learning_state, "deletion", inputs["deletion"], noop_engine, env,
            test_agy_pids, unrelated_agy_pids, test_security_pids,
        )
        if deletion_result is None:
            check("刪除已學特徵後恢復警告", False, "刪除 probe 無輸出")
        else:
            deletion_data, deletion_text, deletion_path = deletion_result
            print("deletion probe 安全結構：" + json.dumps(safe_shape(deletion_data), ensure_ascii=False))
            delete_rows = deletion_data.get("afterDelete") if isinstance(deletion_data.get("afterDelete"), list) else []
            deleted_finding = one_finding(delete_rows[0]) if delete_rows else None
            check("刪除學習特徵後相同弱命中重新警告",
                  bool(deleted_finding and deleted_finding.get("strength") == "弱"
                       and deleted_finding.get("warning") is True
                       and deleted_finding.get("learnedSuppressed") is False),
                  {"warning": deleted_finding.get("warning") if deleted_finding else None,
                   "learnedSuppressed": deleted_finding.get("learnedSuppressed") if deleted_finding else None})
            deleted_log = deletion_path.read_text(encoding="utf-8", errors="replace") if deletion_path.exists() else ""
            check("刪除 probe 後暫存學習紀錄清空", deletion_data.get("learningRecordCount") == 0
                  and not any(line for line in deleted_log.splitlines()),
                  {"probeCount": deletion_data.get("learningRecordCount"),
                   "fileLines": len([line for line in deleted_log.splitlines() if line])})
            deletion_leaks = sum(1 for value in originals if value and value in deletion_text + deleted_log)
            check("刪除 probe 輸出及學習檔不含合成命中原文", deletion_leaks == 0,
                  f"原文外洩數={deletion_leaks}")

    hard_state = base / "hard-rules" / "state"
    hard_result = run_probe(
        app, hard_state, "hard-rules", inputs["hardRules"], noop_engine, env,
        test_agy_pids, unrelated_agy_pids, test_security_pids,
    )
    if hard_result is None:
        check("強規則 hard-limit probe 有結果", False, "無輸出")
    else:
        hard_data, hard_text, hard_learning_path = hard_result
        print("hard-rule probe 安全結構：" + json.dumps(safe_shape(hard_data), ensure_ascii=False))
        hard_rows = hard_data.get("before") if isinstance(hard_data.get("before"), list) else []
        hard_findings = [one_finding(row) for row in hard_rows]
        check("六類強規則在一般文字與 darkreader meta 均警告",
              len(hard_findings) == 12 and all(
                  item and item.get("strength") == "強" and item.get("warning") is True
                  and item.get("excluded") is False
                  for item in hard_findings
              ), f"強規則警告數={sum(bool(item and item.get('strength') == '強' and item.get('warning') is True and item.get('excluded') is False) for item in hard_findings)}/12")
        check("既有精確 allow 不能壓掉強規則", hard_data.get("forceAllowTokensStillWarn") is True,
              hard_data.get("forceAllowTokensStillWarn"))
        check("『不是金鑰』不能消除強規則警告", hard_data.get("strongNotAKeyAccepted") is False,
              hard_data.get("strongNotAKeyAccepted"))
        check("混合附件中的強規則不能被『不是金鑰』消除",
              hard_data.get("mixedNotAKeyAccepted") is False, hard_data.get("mixedNotAKeyAccepted"))
        hard_log = hard_learning_path.read_text(encoding="utf-8", errors="replace") if hard_learning_path.exists() else ""
        hard_leaks = sum(1 for value in originals if value and value in hard_text + hard_log)
        check("強規則 probe 輸出與學習檔不含合成命中原文", hard_leaks == 0,
              f"原文外洩數={hard_leaks}")
        check("強規則學習檔只在暫存 state-dir", hard_learning_path.is_relative_to(hard_state),
              str(hard_learning_path.relative_to(hard_state))
              if hard_learning_path.is_relative_to(hard_state) else "路徑超出暫存")

    after = protected_snapshot(formal_root)
    agy_after = agy_pids()
    check("正式保護檔 metadata 前後一致", before == after)
    check("假 agy 未被呼叫", not noop_log.exists())
    check("測試實例沒有啟動 agy 子程序", not test_agy_pids, f"測試子孫 PID 數={len(test_agy_pids)}")
    check("測試實例沒有啟動真 security/keychain 程序", not test_security_pids,
          f"測試子孫 PID 數={len(test_security_pids)}")
    print(f"測後 agy PID={agy_after}；非測試子孫程序只記錄，PID={sorted(unrelated_agy_pids)}。")
    print(f"C183 probe 暫存目錄：{base}")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("用法：keyguard-0700j-probe.py <codenv-test.app> <暫存根目錄>")
        sys.exit(2)
    sys.exit(run(sys.argv[1], sys.argv[2]))
