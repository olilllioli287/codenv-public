#!/usr/bin/env python3
"""C185 black-box checks for graph dispatch lifetimes and long area labels."""

from __future__ import annotations

import json
import os
import pathlib
import signal
import subprocess
import sys
import time
from typing import Any
import pathlib as _pl, sys as _sys
_sys.path.insert(0, str(_pl.Path(__file__).resolve().parent))
import psread  # noqa: E402（共用 ps 讀取，見 psread.py）


FAKE_AGY = pathlib.Path(os.environ["CODENV_TEST_AGY_BIN"]) if os.environ.get("CODENV_TEST_AGY_BIN") else None


def check(label: str, passed: bool, detail: str = "") -> bool:
    status = "通過" if passed else "失敗"
    suffix = f"；{detail}" if detail else ""
    print(f"{status}：{label}{suffix}", flush=True)
    return passed


def read_processes() -> list[tuple[int, int, str]]:
    return psread.pid_ppid_command()


def app_pids(state: pathlib.Path, rows: list[tuple[int, int, str]] | None = None) -> list[int]:
    rows = rows if rows is not None else read_processes()
    needle = str(state)
    return [
        pid for pid, _ppid, command in rows
        if needle in command
        and "--state-dir" in command
        and "/Contents/MacOS/Workbench" in command
    ]


def descendants(roots: list[int], rows: list[tuple[int, int, str]]) -> list[tuple[int, str]]:
    parents = {pid: ppid for pid, ppid, _command in rows}
    commands = {pid: command for pid, _ppid, command in rows}
    found: set[int] = set()
    frontier = list(roots)
    while frontier:
        parent = frontier.pop()
        for pid, ppid in parents.items():
            if ppid == parent and pid not in found:
                found.add(pid)
                frontier.append(pid)
    return [(pid, commands[pid]) for pid in found if pid in commands]


def stop_test_app(state: pathlib.Path) -> bool:
    pids = app_pids(state)
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 6
    while time.monotonic() < deadline and app_pids(state):
        time.sleep(0.2)
    for pid in app_pids(state):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    return not app_pids(state)


def graph_snapshots(value: Any, path: str = "root") -> list[tuple[str, dict[str, Any]]]:
    if isinstance(value, dict):
        if isinstance(value.get("nodes"), list) and isinstance(value.get("edges"), list):
            return [(path, value)]
        snapshots: list[tuple[str, dict[str, Any]]] = []
        for key, nested in value.items():
            snapshots.extend(graph_snapshots(nested, f"{path}.{key}"))
        return snapshots
    if isinstance(value, list):
        snapshots = []
        for index, nested in enumerate(value):
            snapshots.extend(graph_snapshots(nested, f"{path}[{index}]"))
        return snapshots
    return []


def run_probe(
    app: pathlib.Path,
    state: pathlib.Path,
    label: str,
    graph_ops: list[str],
    commander_name: str | None = None,
) -> tuple[dict[str, Any] | None, bool]:
    state.mkdir(parents=True, exist_ok=True)
    compact = state / "compact-state"
    claude_home = state / ".claude"
    project = state / "project"
    compact.mkdir(parents=True, exist_ok=True)
    claude_home.mkdir(parents=True, exist_ok=True)
    project.mkdir(parents=True, exist_ok=True)
    output = state / f"{label}.json"

    env = os.environ.copy()
    env["CODENV_COMPACT_DIR"] = str(compact)
    env["CODENV_POOL_USAGE_FILE"] = str(state / "pool-usage.json")
    command = [
        "/usr/bin/open", "-g", "-n", str(app), "--args",
        "--state-dir", str(state),
        "--claude-home", str(claude_home),
        "--background", "--test-screen", "ipad", "--test-hidden", "--usage-fake",
        "--agy-bin", str(FAKE_AGY),
    ]
    if commander_name:
        command.extend([
            "--commander-op",
            f"0.4:new:{commander_name}:{commander_name}Group:{project}:multi",
        ])
    for operation in graph_ops:
        command.extend(["--graph-op", operation])
    command.extend(["--quit", "60", "-NSAppSleepDisabled", "YES", "-ApplePersistenceIgnoreState", "YES"])

    opened = subprocess.run(command, env=env, capture_output=True, text=True, check=False)
    if opened.returncode != 0:
        check(f"{label} open -g 啟動測試實例", False, f"exit={opened.returncode}")
        return None, False

    deadline = time.monotonic() + 45
    while time.monotonic() < deadline and not output.is_file():
        time.sleep(0.25)
    result: dict[str, Any] | None = None
    if output.is_file():
        try:
            parsed = json.loads(output.read_text(encoding="utf-8"))
            if isinstance(parsed, dict):
                result = parsed
        except (OSError, json.JSONDecodeError):
            pass
    output_ok = result is not None
    check(f"{label} probe 輸出 JSON", output_ok, "未產生有效 JSON" if not output_ok else "")

    rows = read_processes()
    roots = app_pids(state, rows)
    child_commands = [text for _pid, text in descendants(roots, rows)]
    agy_children = [text for text in child_commands if "agy -p=" in text]
    security_children = [text for text in child_commands if "security" in pathlib.Path(text.split()[0]).name.lower()]
    check(f"{label} 未啟動真 agy 子程序", not agy_children, f"數量={len(agy_children)}")
    check(f"{label} 未啟動 security 子程序", not security_children, f"數量={len(security_children)}")
    stopped = stop_test_app(state)
    check(f"{label} 測試 App 已停止", stopped, f"殘留 PID={app_pids(state)}")
    return result, output_ok and not agy_children and not security_children and stopped


def identities(records: list[dict[str, Any]]) -> dict[tuple[str, str], dict[str, Any]]:
    result: dict[tuple[str, str], dict[str, Any]] = {}
    for record in records:
        from_id, to_id = record.get("fromID"), record.get("toID")
        if from_id is not None and to_id is not None:
            result[(str(from_id), str(to_id))] = record
    return result


def active_arrows(snapshot: dict[str, Any]) -> set[tuple[str, str]]:
    return {
        (str(edge.get("fromID")), str(edge.get("toID")))
        for edge in snapshot.get("edges", [])
        if isinstance(edge, dict) and edge.get("hasArrow") is True
    }


def data_snapshots(result: dict[str, Any] | None, label: str) -> list[tuple[str, dict[str, Any]]]:
    snapshots = graph_snapshots(result) if result is not None else []
    check(f"{label} 有關聯圖 probe 資料", bool(snapshots), f"找到 {len(snapshots)} 組圖形資料")
    return snapshots


def fixture_records(
    snapshots: list[tuple[str, dict[str, Any]]], label: str
) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
    if not snapshots:
        check(f"{label} 找到兩筆有效派工", False, "沒有圖形資料")
        return None, None
    snapshot = snapshots[0][1]
    records = snapshot.get("dispatches", [])
    active = [r for r in records if isinstance(r, dict) and r.get("active") is True]
    lead_ids = {
        str(node.get("nodeID"))
        for node in snapshot.get("nodes", [])
        if isinstance(node, dict) and node.get("isAreaLead") is True and node.get("nodeID") is not None
    }
    lead_records = [r for r in active if str(r.get("fromID")) in lead_ids]
    chief_records = [r for r in active if str(r.get("fromID")) not in lead_ids]
    valid = len(active) == 2 and len(lead_records) == 1 and len(chief_records) == 1
    check(
        f"{label} 總指揮與區長各有一筆活躍派工",
        valid,
        f"活躍派工={len(active)}，區長派工={len(lead_records)}，其餘={len(chief_records)}",
    )
    if not valid:
        return None, None
    chief, lead = chief_records[0], lead_records[0]
    names_ok = all(isinstance(record.get("to"), str) and record.get("to") for record in (chief, lead))
    check(f"{label} 派工目標可用聊天室名稱操作", names_ok)
    return (chief, lead) if names_ok else (None, None)


def verify_pair_state(
    snapshots: list[tuple[str, dict[str, Any]]],
    chief_record: dict[str, Any],
    lead_record: dict[str, Any],
    chief_active: bool,
    lead_active: bool,
    label: str,
) -> bool:
    chief_key = (str(chief_record.get("fromID")), str(chief_record.get("toID")))
    lead_key = (str(lead_record.get("fromID")), str(lead_record.get("toID")))
    okay = bool(snapshots)
    for path, snapshot in snapshots:
        records = identities(snapshot.get("dispatches", []))
        arrows = active_arrows(snapshot)
        expected = {key for key, active in ((chief_key, chief_active), (lead_key, lead_active)) if active}
        chief = records.get(chief_key, {})
        lead = records.get(lead_key, {})
        records_ok = (
            chief.get("active") is chief_active
            and lead.get("active") is lead_active
            and (not chief_active or chief.get("collected") is False)
            and (not lead_active or lead.get("collected") is False)
            and (chief_active or chief.get("collected") is True)
            and (lead_active or lead.get("collected") is True)
        )
        arrows_ok = arrows.intersection({chief_key, lead_key}) == expected
        check(f"{label} {path} 派工紀錄狀態正確", records_ok)
        check(f"{label} {path} 派工箭頭狀態正確", arrows_ok, f"目前相關箭頭={len(arrows.intersection({chief_key, lead_key}))}")
        okay &= records_ok and arrows_ok
    return okay


def read_probe(state: pathlib.Path, filename: str, label: str) -> dict[str, Any] | None:
    path = state / filename
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        value = None
    valid = isinstance(value, dict)
    check(f"{label} probe 輸出 JSON", valid, f"缺少 {filename}" if not valid else "")
    return value if valid else None


def exercise_dispatch_lifecycle(app: pathlib.Path, base: pathlib.Path) -> bool:
    okay = True
    state = base / "dispatch-lifecycle" / "state"
    result, launched = run_probe(
        app,
        state,
        "dispatch-lifecycle",
        [
            "0.7:mode:graph",
            "0.9:panel:open",
            "1.4:dispatch-fixture",
            f"2.1:probe:{state / 'initial.json'}",
            "3:state:總指揮派工A:complete",
            f"3.6:probe:{state / 'chief-worker-complete.json'}",
            "4.6:state:區長派工B:complete",
            f"5.2:probe:{state / 'lead-worker-complete.json'}",
            f"5.8:probe:{state / 'dispatch-lifecycle.json'}",
        ],
        commander_name="C185Chief",
    )
    okay &= launched
    initial_result = read_probe(state, "initial.json", "初始派工")
    after_chief_result = read_probe(state, "chief-worker-complete.json", "總指揮工作完成")
    after_lead_result = read_probe(state, "lead-worker-complete.json", "區長工作完成")
    final_snapshots = data_snapshots(result, "派工流程最終狀態")
    initial = data_snapshots(initial_result, "初始派工")
    if not initial:
        return False
    chief_record, lead_record = fixture_records(initial, "初始派工")
    if chief_record is None or lead_record is None:
        return False
    names_ok = chief_record.get("to") == "總指揮派工A" and lead_record.get("to") == "區長派工B"
    check("fixture 的 A、B 分別是總指揮與區長派工聊天室", names_ok)
    okay &= names_ok

    for path, snapshot in initial:
        arrows = active_arrows(snapshot)
        initial_ok = {
            (str(chief_record.get("fromID")), str(chief_record.get("toID"))),
            (str(lead_record.get("fromID")), str(lead_record.get("toID"))),
        }.issubset(arrows)
        check(f"初始派工 {path} 總指揮與區長兩條箭頭均出現", initial_ok)
        okay &= initial_ok

    after_chief = data_snapshots(after_chief_result, "總指揮工作完成")
    okay &= verify_pair_state(after_chief, chief_record, lead_record, False, True, "總指揮工作完成後")

    after_lead = data_snapshots(after_lead_result, "區長工作完成")
    okay &= verify_pair_state(after_lead, chief_record, lead_record, False, False, "區長工作完成後")
    okay &= verify_pair_state(final_snapshots, chief_record, lead_record, False, False, "派工流程完成後")
    return okay


def exercise_error_collection(app: pathlib.Path, base: pathlib.Path) -> bool:
    state = base / "dispatch-error" / "state"
    result, okay = run_probe(
        app,
        state,
        "error-sequence",
        [
            "0.7:mode:graph",
            "0.9:panel:open",
            "1.4:dispatch-fixture",
            f"2.1:probe:{state / 'error-initial.json'}",
            "3:state:區長派工B:error",
            f"3.6:probe:{state / 'lead-error.json'}",
            "4.6:state:總指揮派工A:complete",
            f"5.2:probe:{state / 'error-final.json'}",
            f"5.8:probe:{state / 'error-sequence.json'}",
        ],
        commander_name="C185ErrorChief",
    )
    snapshots = data_snapshots(read_probe(state, "error-initial.json", "出錯情境初始派工"), "出錯情境初始派工")
    chief_record, lead_record = fixture_records(snapshots, "出錯情境")
    if chief_record is None or lead_record is None:
        return False
    names_ok = chief_record.get("to") == "總指揮派工A" and lead_record.get("to") == "區長派工B"
    check("出錯 fixture 的 A、B 派工聊天室識別正確", names_ok)
    okay &= names_ok
    after_error = data_snapshots(read_probe(state, "lead-error.json", "區長派工出錯"), "區長派工出錯")
    okay &= verify_pair_state(after_error, chief_record, lead_record, True, False, "區長派工出錯後")
    final = data_snapshots(read_probe(state, "error-final.json", "出錯後總指揮工作完成"), "出錯後總指揮工作完成")
    okay &= verify_pair_state(final, chief_record, lead_record, False, False, "出錯情境全部結束後")
    return okay


def exercise_old_dispatches(app: pathlib.Path, base: pathlib.Path) -> bool:
    state = base / "dispatch-old" / "state"
    result, okay = run_probe(
        app,
        state,
        "old-fixture",
        [
            "0.7:mode:graph",
            "0.9:panel:open",
            "1.2:dispatch-fixture:old",
            f"2:probe:{state / 'old-fixture.json'}",
        ],
        commander_name="C185OldChief",
    )
    snapshots = data_snapshots(result, "逾時派工")
    if not snapshots:
        return False
    for path, snapshot in snapshots:
        records = snapshot.get("dispatches", [])
        expired_ok = (
            len(records) == 2
            and all(record.get("active") is False and record.get("collected") is True for record in records)
            and all(bool(record.get("closedReason")) for record in records)
            and not active_arrows(snapshot)
        )
        check(f"逾 24 小時派工 {path} 已收掉", expired_ok, f"派工紀錄={len(records)}，箭頭={len(active_arrows(snapshot))}")
        okay &= expired_ok
    return okay


def exercise_long_label(app: pathlib.Path, base: pathlib.Path) -> bool:
    state = base / "long-label" / "state"
    result, okay = run_probe(
        app,
        state,
        "long-label-fixture",
        [
            "0.7:mode:graph",
            "0.9:panel:open",
            "1.2:long-label-fixture",
            f"2:probe:{state / 'long-label-fixture.json'}",
        ],
        commander_name="C185LabelChief",
    )
    snapshots = data_snapshots(result, "長區名")
    if not snapshots:
        return False
    for path, snapshot in snapshots:
        nodes = [node for node in snapshot.get("nodes", []) if isinstance(node, dict)]
        area_nodes = [node for node in nodes if node.get("isAreaLead") is True or "area" in str(node.get("kind", "")).lower()]
        candidates = area_nodes or nodes
        node = max(candidates, key=lambda item: len(str(item.get("label", ""))), default={})
        frame_ok = node.get("labelFrameInsideCanvas") is True
        check(f"長區名 {path} 標籤框完整落在畫布內", frame_ok)
        okay &= frame_ok
        if node.get("labelWasTruncated") is True:
            drawn = node.get("drawnLabel")
            ellipsis_ok = isinstance(drawn, str) and drawn.endswith("…")
            check(f"長區名 {path} 截短標籤以 … 結尾", ellipsis_ok)
            okay &= ellipsis_ok
        else:
            check(f"長區名 {path} 標籤無須截短", True)
    return okay


def main() -> int:
    if len(sys.argv) != 3:
        print("用法：graph-0700i-probe.py <codenv-test.app> <暫存根目錄>", file=sys.stderr)
        return 2
    app = pathlib.Path(sys.argv[1]).resolve()
    base = pathlib.Path(sys.argv[2]).resolve() / "c185-graph"
    base.mkdir(parents=True, exist_ok=True)
    if FAKE_AGY is None or not FAKE_AGY.is_file() or not os.access(FAKE_AGY, os.X_OK):
        print("請設定可執行的 CODENV_TEST_AGY_BIN 假 agy", file=sys.stderr)
        return 2
    if not (app / "Contents" / "MacOS" / "Workbench").is_file():
        print(f"找不到測試 App 可執行檔：{app}", file=sys.stderr)
        return 2

    results = [
        exercise_dispatch_lifecycle(app, base),
        exercise_error_collection(app, base),
        exercise_old_dispatches(app, base),
        exercise_long_label(app, base),
    ]
    passed = all(results)
    check("C185 全部驗收項目", passed)
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
