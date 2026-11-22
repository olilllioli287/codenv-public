#!/usr/bin/env python3
"""驗證 C321：輸入框 baselineOffset 與 corrupt 自我修正。"""

from __future__ import annotations

import json
import math
import re
import sys
from pathlib import Path
from typing import Any


FIXTURE: dict[str, Any] = {
    "width": 100,
    "events": [
        {"type": "insert", "text": "底字", "label": "單行"},
        {"type": "corrupt", "range": [0, 1], "offset": 13, "label": "前置錯位修復"},
        {"type": "mark", "text": "正常", "label": "一般組字"},
        {"type": "unmark", "label": "一般組字結束"},
        {"type": "mark", "text": "組字內容非常長", "label": "組字中跨行"},
        {"type": "corrupt", "range": [4, 2], "offset": 13, "label": "組字中注入錯位"},
        {"type": "unmark", "label": "組字錯位修復"},
        {"type": "delete", "range": [2, 9], "label": "刪回單行"},
        {"type": "newline", "label": "多行換行"},
        {"type": "insert", "text": "第二行", "label": "多行"},
    ],
}

EPSILON = 1e-6
EVENT_LOG_ENTRY = re.compile(
    r"\[[^\]\r\n]+\] "
    r"輸入框 - baselineOffset 自我修正："
    r"不一致段數=(?P<segments>\d+)、各段offset=\[\s*-?\d+(?:\.\d+)?"
    r"(?:\s*,\s*-?\d+(?:\.\d+)?)*\s*\]、"
    r"視覺行數=(?P<lines>\d+)、wasComposing=(?P<was_composing>true|false)"
)


def check(label: str, passed: bool, detail: object = "") -> bool:
    suffix = f"；實際={detail!r}" if detail != "" else ""
    print(f"{'通過' if passed else '失敗'}：{label}{suffix}")
    return passed


def is_number(value: object) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(float(value))


def fixture(path: Path) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(FIXTURE, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"C321 合成輸入已寫入隔離 state-dir：{path}")
    return 0


def verify_single_line(snapshot: dict[str, Any], label: str) -> int:
    failures = 0
    runs = snapshot.get("runs")
    if not isinstance(runs, list) or not runs:
        check(f"{label} 有 runs", False, runs)
        return 1
    offsets = [run.get("baselineOffset") if isinstance(run, dict) else "<invalid-run>" for run in runs]
    no_offset = all(value is None or (is_number(value) and abs(float(value)) <= EPSILON)
                    for value in offsets)
    failures += int(not check(f"{label} 單行各 run 無 baseline offset（null／0）", no_offset, offsets))
    failures += int(not check(f"{label} baselineUniform=true", snapshot.get("baselineUniform") is True,
                              snapshot.get("baselineUniform")))
    failures += int(not check(f"{label} visualLineCount=1", snapshot.get("visualLineCount") == 1,
                              snapshot.get("visualLineCount")))
    return failures


def verify_multiline(snapshot: dict[str, Any], label: str) -> int:
    failures = 0
    runs = snapshot.get("runs")
    if not isinstance(runs, list) or not runs:
        check(f"{label} 有 runs", False, runs)
        return 1
    line_count = snapshot.get("visualLineCount")
    line_ok = isinstance(line_count, int) and not isinstance(line_count, bool) and line_count >= 2
    failures += int(not check(f"{label} 視覺行數至少 2", line_ok, line_count))
    anchor = snapshot.get("inputBaselineOffset")
    failures += int(not check(f"{label} 有非零 centered inputBaselineOffset",
                              is_number(anchor) and abs(float(anchor)) > EPSILON, anchor))
    offsets = [run.get("baselineOffset") if isinstance(run, dict) else "<invalid-run>" for run in runs]
    all_match = (is_number(anchor) and all(is_number(value) and
                                          math.isclose(float(value), float(anchor), rel_tol=0.0, abs_tol=EPSILON)
                                          for value in offsets))
    failures += int(not check(f"{label} 每個 run 都使用相同的 centered offset",
                              all_match, {"inputBaselineOffset": anchor, "runOffsets": offsets}))
    failures += int(not check(f"{label} baselineUniform=true", snapshot.get("baselineUniform") is True,
                              snapshot.get("baselineUniform")))
    return failures


def verify_composing_wrap(snapshot: dict[str, Any]) -> int:
    """組字可能跨視覺行；依文件提供的 baselineUniform 判同一行一致，不自行猜 run 所在行。"""
    failures = 0
    runs = snapshot.get("runs")
    if not isinstance(runs, list) or not runs:
        check("組字中跨視覺行有 runs", False, runs)
        return 1
    line_count = snapshot.get("visualLineCount")
    failures += int(not check("組字跨行視覺行數至少 2",
                              isinstance(line_count, int) and not isinstance(line_count, bool) and line_count >= 2,
                              line_count))
    anchor = snapshot.get("inputBaselineOffset")
    anchor_unset = (anchor is None or
                    (is_number(anchor) and abs(float(anchor)) <= EPSILON))
    failures += int(not check("組字中 inputBaselineOffset 未套用 centered offset（null／0）",
                              anchor_unset, anchor))
    offsets = [run.get("baselineOffset") if isinstance(run, dict) else "<invalid-run>" for run in runs]
    runs_unset = all(value is None or (is_number(value) and abs(float(value)) <= EPSILON)
                     for value in offsets)
    failures += int(not check("組字中各 run 未套用 centered offset（null／0）", runs_unset,
                              {"runCount": len(offsets), "allUnsetOrZero": runs_unset}))
    failures += int(not check("組字快照 baselineUniform=true（同一視覺行各段一致）",
                              snapshot.get("baselineUniform") is True,
                              snapshot.get("baselineUniform")))
    return failures


def offset_values(details: dict[str, Any], field: str) -> list[object] | None:
    rows = details.get(field)
    if not isinstance(rows, list) or not rows or any(not isinstance(item, dict) or
                                                     "baselineOffset" not in item for item in rows):
        return None
    return [item["baselineOffset"] for item in rows]


def differs_from_baseline(values: list[object] | None, baseline: object) -> bool:
    if values is None or not (baseline is None or is_number(baseline)):
        return False
    baseline_value = 0.0 if baseline is None else float(baseline)
    return all(value is None or is_number(value) for value in values) and any(
        not math.isclose(0.0 if value is None else float(value), baseline_value,
                         rel_tol=0.0, abs_tol=EPSILON)
        for value in values
    )


def matches_baseline(values: list[object] | None, baseline: object) -> bool:
    return (values is not None and is_number(baseline) and all(
        is_number(value) and math.isclose(float(value), float(baseline),
                                          rel_tol=0.0, abs_tol=EPSILON)
        for value in values
    ))


def verify_composition_repair(corrupt_snapshot: dict[str, Any], repair_snapshot: dict[str, Any],
                              snapshot_index: int, data: dict[str, Any], output_path: Path) -> int:
    """驗證組字中暫留錯位，並在 unmark 後修復與記錄。"""
    failures = 0
    corrupt_details = corrupt_snapshot.get("corrupt")
    corrupt_ok = (corrupt_snapshot.get("eventType") == "corrupt" and
                  corrupt_snapshot.get("hasMarkedText") is True and
                  isinstance(corrupt_details, dict) and
                  corrupt_details.get("baselineMismatchInjected") is True and
                  corrupt_details.get("awaitingUnmark") is True)
    failures += int(not check("組字中 corrupt 保留錯位並等待 unmark", corrupt_ok,
                              {"eventType": corrupt_snapshot.get("eventType"),
                               "hasMarkedText": corrupt_snapshot.get("hasMarkedText"),
                               "baselineMismatchInjected": isinstance(corrupt_details, dict) and
                               corrupt_details.get("baselineMismatchInjected") is True,
                               "awaitingUnmark": isinstance(corrupt_details, dict) and
                               corrupt_details.get("awaitingUnmark") is True}))
    if not isinstance(corrupt_details, dict):
        return failures + 1

    before_repair = offset_values(corrupt_details, "beforeRepairOffsets")
    mismatch_visible = differs_from_baseline(before_repair, corrupt_snapshot.get("inputBaselineOffset"))
    failures += int(not check("組字中 beforeRepairOffsets 顯示注入錯位",
                              mismatch_visible, {"offsetCount": len(before_repair or []),
                                                 "mismatchVisible": mismatch_visible}))

    intentionally_corrupt = data.get("intentionallyCorruptSnapshots")
    index_ok = intentionally_corrupt == [snapshot_index]
    failures += int(not check("intentionallyCorruptSnapshots 僅標記 corrupt 快照",
                              index_ok, {"entryCount": len(intentionally_corrupt)
                              if isinstance(intentionally_corrupt, list) else None,
                              "matchesCorruptIndex": index_ok}))
    failures += int(not check("rawAllSnapshotsUniform=false（含故意錯位快照）",
                              data.get("rawAllSnapshotsUniform") is False,
                              data.get("rawAllSnapshotsUniform") is False))
    failures += int(not check("allRunsUniform=true（排除明確標記的錯位快照）",
                              data.get("allRunsUniform") is True,
                              data.get("allRunsUniform") is True))

    repair = repair_snapshot.get("compositionRepair")
    repair_ok = (repair_snapshot.get("eventType") == "unmark" and
                 repair_snapshot.get("hasMarkedText") is False and isinstance(repair, dict))
    failures += int(not check("corrupt 後緊接 unmark compositionRepair", repair_ok,
                              {"eventType": repair_snapshot.get("eventType"),
                               "hasMarkedText": repair_snapshot.get("hasMarkedText"),
                               "repairObjectPresent": isinstance(repair, dict)}))
    if not isinstance(repair, dict):
        return failures + 1

    anchor = repair_snapshot.get("inputBaselineOffset")
    before_values = offset_values(repair, "beforeOffsets")
    failures += int(not check("unmark 前 repair 確認仍有錯位",
                              differs_from_baseline(before_values, anchor),
                              {"offsetCount": len(before_values or []),
                               "mismatchVisible": differs_from_baseline(before_values, anchor)}))
    after_values = offset_values(repair, "afterOffsets")
    failures += int(not check("unmark 後每個 offset 等於 inputBaselineOffset",
                              matches_baseline(after_values, anchor),
                              {"offsetCount": len(after_values or []),
                               "allMatch": matches_baseline(after_values, anchor)}))
    failures += int(not check("repairWasNeeded=true、wasComposing=true、afterRunsMatchInputBaseline=true",
                              repair.get("repairWasNeeded") is True and
                              repair.get("wasComposing") is True and
                              repair.get("afterRunsMatchInputBaseline") is True,
                              {"repairWasNeeded": repair.get("repairWasNeeded") is True,
                               "wasComposing": repair.get("wasComposing") is True,
                               "afterRunsMatchInputBaseline":
                               repair.get("afterRunsMatchInputBaseline") is True}))
    throttle_wait = repair.get("throttleWaitSeconds")
    throttle_wait_ok = (is_number(throttle_wait) and float(throttle_wait) >= 1.0)
    failures += int(not check("組字 repair 前已讓每秒一次限流窗過期",
                              throttle_wait_ok, throttle_wait))

    event_path_text = repair.get("eventLogPath")
    event_path = Path(event_path_text) if isinstance(event_path_text, str) else None
    state_root = output_path.resolve().parent
    event_file_exists = False
    path_in_state = False
    try:
        if event_path is not None:
            event_path.resolve().relative_to(state_root)
            path_in_state = True
            event_file_exists = event_path.exists()
    except (OSError, RuntimeError, ValueError):
        pass
    event_path_valid = path_in_state and event_file_exists
    failures += int(not check("compositionRepair EventLog 檔案存在且位於隔離 state-dir",
                              event_path_valid, {"pathInStateDir": path_in_state,
                                                 "fileExists": event_file_exists}))

    entry = repair.get("eventLogEntry")
    entry_match = EVENT_LOG_ENTRY.fullmatch(entry) if isinstance(entry, str) else None
    entry_shape = entry_match is not None and entry_match.group("was_composing") == "true"
    failures += int(not check("EventLog 有輸入框自我修正項，且只含數值診斷欄位",
                              entry_shape, {"entryPresent": isinstance(entry, str),
                                            "matchesComposingNumericFormat": entry_shape}))
    entry_metrics_match = (entry_match is not None and
                           int(entry_match.group("segments")) > 0 and
                           int(entry_match.group("lines")) == repair_snapshot.get("visualLineCount"))
    failures += int(not check("EventLog 段數為正、wasComposing=true 且行數符合 repair 快照",
                              entry_metrics_match and entry_match.group("was_composing") == "true",
                              entry_metrics_match and entry_match.group("was_composing") == "true"))
    failures += int(not check("EventLog 已寫入且不含輸入文字",
                              repair.get("eventLogWritten") is True and
                              repair.get("eventLogTextFree") is True and
                              repair.get("eventLogContainsText") is False,
                              {"eventLogWritten": repair.get("eventLogWritten") is True,
                               "eventLogTextFree": repair.get("eventLogTextFree") is True,
                               "eventLogContainsText": repair.get("eventLogContainsText")}))
    return failures


def verify(output_path: Path) -> int:
    try:
        data = json.loads(output_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"失敗：C321 輸出 JSON 無法讀取（{type(exc).__name__}: {exc}）")
        return 1
    if not isinstance(data, dict):
        print("失敗：C321 輸出 JSON 頂層不是 object")
        return 1

    failures = 0
    failures += int(not check("所有合成事件都套用", data.get("allEventsApplied") is True,
                              data.get("allEventsApplied")))
    snapshots = data.get("snapshots")
    if not isinstance(snapshots, list):
        check("snapshots 是陣列", False, snapshots)
        return failures + 1
    failures += int(not check("每個輸入事件各有一筆快照", len(snapshots) == len(FIXTURE["events"]),
                              {"actual": len(snapshots), "expected": len(FIXTURE["events"])}))

    for row in snapshots:
        valid = isinstance(row, dict) and row.get("eventStateValid") is True
        failures += int(not check("事件狀態符合 mark／unmark 預期", valid,
                                  row.get("label") if isinstance(row, dict) else row))

    by_label: dict[str, list[dict[str, Any]]] = {}
    for row in snapshots:
        if isinstance(row, dict) and isinstance(row.get("label"), str):
            by_label.setdefault(row["label"], []).append(row)

    required = ("單行", "前置錯位修復", "一般組字", "一般組字結束", "組字中跨行", "組字中注入錯位",
                "組字錯位修復", "刪回單行", "多行換行", "多行")
    for label in required:
        rows = by_label.get(label, [])
        found_once = len(rows) == 1
        failures += int(not check(f"快照標籤 {label!r} 恰一筆", found_once, len(rows)))
    if any(len(by_label.get(label, [])) != 1 for label in required):
        return failures + 1

    single = by_label["單行"][0]
    preflight = by_label["前置錯位修復"][0]
    ordinary_mark = by_label["一般組字"][0]
    ordinary_unmark = by_label["一般組字結束"][0]
    composition = by_label["組字中跨行"][0]
    corrupted = by_label["組字中注入錯位"][0]
    committed = by_label["組字錯位修復"][0]
    returned = by_label["刪回單行"][0]
    multiline = by_label["多行"][0]

    failures += verify_single_line(single, "單行控制")

    preflight_repair = preflight.get("corrupt")
    preflight_logged = (preflight.get("eventType") == "corrupt" and
                        isinstance(preflight_repair, dict) and
                        preflight_repair.get("eventLogWritten") is True and
                        preflight_repair.get("eventLogTextFree") is True and
                        preflight_repair.get("eventLogContainsText") is False)
    failures += int(not check("同一 ChatTextView 的前置錯位已記一筆無文字 EventLog",
                              preflight_logged,
                              {"eventLogWritten": preflight_repair.get("eventLogWritten")
                               if isinstance(preflight_repair, dict) else None,
                               "eventLogTextFree": preflight_repair.get("eventLogTextFree")
                               if isinstance(preflight_repair, dict) else None,
                               "eventLogContainsText": preflight_repair.get("eventLogContainsText")
                               if isinstance(preflight_repair, dict) else None}))

    ordinary_pair_ok = (ordinary_mark.get("eventType") == "mark" and
                        ordinary_mark.get("hasMarkedText") is True and
                        ordinary_unmark.get("eventType") == "unmark" and
                        ordinary_unmark.get("hasMarkedText") is False)
    failures += int(not check("一般 mark→unmark 結束組字；不要求 EventLog",
                              ordinary_pair_ok, ordinary_pair_ok))

    composition_ok = composition.get("eventType") == "mark" and composition.get("hasMarkedText") is True
    failures += int(not check("組字跨行快照處於 mark 狀態", composition_ok,
                              {"eventType": composition.get("eventType"),
                               "hasMarkedText": composition.get("hasMarkedText")}))
    failures += verify_composing_wrap(composition)

    unmark_ok = committed.get("eventType") == "unmark" and committed.get("hasMarkedText") is False
    failures += int(not check("unmark 已提交組字", unmark_ok,
                              {"eventType": committed.get("eventType"),
                               "hasMarkedText": committed.get("hasMarkedText")}))
    same_wrapped_count = (isinstance(composition.get("visualLineCount"), int) and
                          committed.get("visualLineCount") == composition.get("visualLineCount"))
    failures += int(not check("unmark 後仍保留跨行文字的視覺行數", same_wrapped_count,
                              {"mark": composition.get("visualLineCount"),
                               "unmark": committed.get("visualLineCount")}))
    failures += verify_multiline(committed, "unmark 後整份 storage")

    delete_ok = returned.get("eventType") == "delete" and returned.get("hasMarkedText") is False
    failures += int(not check("刪回單行快照已結束組字", delete_ok,
                              {"eventType": returned.get("eventType"),
                               "hasMarkedText": returned.get("hasMarkedText")}))
    failures += verify_single_line(returned, "刪回單行")

    multiline_ok = multiline.get("eventType") == "insert" and multiline.get("visualLineCount") == 2
    failures += int(not check("多行 fixture 含兩個視覺行", multiline_ok,
                              {"eventType": multiline.get("eventType"),
                               "visualLineCount": multiline.get("visualLineCount")}))
    failures += verify_multiline(multiline, "明確多行")
    corrupt_index = next((index for index, row in enumerate(snapshots) if row is corrupted), -1)
    failures += verify_composition_repair(corrupted, committed, corrupt_index, data, output_path)

    failures += int(not check("探針頂層 result=pass", data.get("result") == "pass", data.get("result")))
    return 1 if failures else 0


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[1] == "fixture":
        return fixture(Path(argv[2]))
    if len(argv) == 3 and argv[1] == "verify":
        return verify(Path(argv[2]))
    print("用法：zhuyin-baseline-probe.py fixture <input.json> | verify <output.json>")
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
