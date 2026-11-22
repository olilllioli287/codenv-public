#!/usr/bin/env python3
"""Verify the C460-C464 idle/working measurement-hook contract."""
import json
import math
import re
import subprocess
import sys
import time
from pathlib import Path


TOP_LEVEL_KEYS = {
    "scenario", "canAnimate", "windowSeconds", "avgCpuPercent",
    "drawCountDelta", "drawsPerSecond", "timerRunning",
    "dirtyRectAreaRatio", "changeDrawCountDelta", "conversations", "groups",
    "appActive", "occlusionVisible", "windowVisible",
    "processTotalCpuPercent", "sessions", "jsonlFiles",
}
CASE_SCENARIO = {"C460": "idle", "C461": "waiting", "C462": "working", "C463": None, "C464": "working"}
CPU_CASES = {"C460", "C461", "C462", "C464"}


def is_number(value):
    return type(value) in (int, float) and math.isfinite(value)


def sysctl_loadavg():
    result = subprocess.run(
        ["sysctl", "-n", "vm.loadavg"], check=True,
        capture_output=True, text=True, timeout=5,
    )
    values = [float(value) for value in re.findall(r"\d+(?:\.\d+)?", result.stdout)]
    if not values:
        raise ValueError("sysctl vm.loadavg 沒有可讀數值")
    return values[0]


def loadavg_samples(meta_path):
    if meta_path.is_file():
        text = meta_path.read_text(encoding="utf-8")
        samples = []
        for line in text.splitlines():
            match = re.match(r"^(?:load|loadavg_after)=\s*([0-9]+(?:\.[0-9]+)?)", line.strip())
            if match:
                samples.append(float(match.group(1)))
        if samples:
            return samples, f"meta:{meta_path}"

    # Fallback when verifying a standalone output without the runner sidecar.
    before = sysctl_loadavg()
    time.sleep(0.1)
    after = sysctl_loadavg()
    return [before, after], "verifier fallback: sysctl vm.loadavg"


def errors_for(case_id, data, expected_scenario, meta_path):
    errors = []
    cpu_invalid_reason = None

    def check(path, condition, message):
        if not condition:
            errors.append(f"{path}: {message}")

    def object_at(name, keys):
        value = data.get(name)
        if not isinstance(value, dict):
            errors.append(f"{name}: 預期 object")
            return None
        check(f"{name}.keys", set(value) == keys, "欄位須符合契約，不接受額外欄位")
        return value

    if not isinstance(data, dict):
        return ["root: 預期 JSON object"], None
    check("root.keys", set(data) == TOP_LEVEL_KEYS, "欄位須符合契約白名單，不能多帶自由文字或私人內容")
    if expected_scenario is None:
        check("scenario", data.get("scenario") in {"idle", "working", "waiting"}, "預期 idle／working／waiting")
    else:
        check("scenario", data.get("scenario") == expected_scenario, f"預期 scenario={expected_scenario}")

    check("canAnimate", data.get("canAnimate") is True, "量測無效：canAnimate 必須為 true")
    for key in ("appActive", "occlusionVisible", "windowVisible", "timerRunning"):
        check(key, type(data.get(key)) is bool, "必須是布林值")
    check("windowSeconds", is_number(data.get("windowSeconds")) and data.get("windowSeconds") > 0, "必須是有限正數")
    check("avgCpuPercent", is_number(data.get("avgCpuPercent")) and data.get("avgCpuPercent") >= 0, "必須是有限非負數")
    check("processTotalCpuPercent", is_number(data.get("processTotalCpuPercent")) and data.get("processTotalCpuPercent") >= 0, "必須是有限非負數")
    for key in ("drawCountDelta", "changeDrawCountDelta", "conversations", "groups"):
        check(key, type(data.get(key)) is int and data.get(key) >= 0, "必須是非負整數")
    for key in ("sessions", "jsonlFiles"):
        check(key, type(data.get(key)) is int and data.get(key) >= 0, "必須是非負整數")
    for key in ("drawsPerSecond", "dirtyRectAreaRatio"):
        check(key, is_number(data.get(key)) and data.get(key) >= 0, "必須是有限非負數")

    scenario = data.get("scenario")
    if case_id in {"C460", "C461"} and scenario in {"idle", "waiting"}:
        check("drawCountDelta", data.get("drawCountDelta") == 0, "idle／waiting 量測期間不得重畫")
        check("timerRunning", data.get("timerRunning") is False, "idle／waiting 時動畫 timer 必須停止")
    elif case_id == "C462" and scenario == "working":
        check("timerRunning", data.get("timerRunning") is True, "working 光圈的 timer 必須運作")
        check("drawCountDelta", type(data.get("drawCountDelta")) is int and data.get("drawCountDelta") > 0, "working 光圈必須持續繪製")
        check("drawsPerSecond", is_number(data.get("drawsPerSecond")) and data.get("drawsPerSecond") <= 20, "working 重畫頻率不得超過 20 次／秒")
        check("dirtyRectAreaRatio", is_number(data.get("dirtyRectAreaRatio")) and data.get("dirtyRectAreaRatio") < 0.3, "working dirty rect 面積比例須小於 0.3")
    elif case_id == "C463":
        check("changeDrawCountDelta", type(data.get("changeDrawCountDelta")) is int and data.get("changeDrawCountDelta") >= 1, "資料變更後至少須重畫一次")

    if case_id in CPU_CASES and is_number(data.get("avgCpuPercent")):
        try:
            samples, source = loadavg_samples(meta_path)
            max_load = max(samples)
            if max_load >= 3.5:
                cpu_invalid_reason = f"loadavg 1 分鐘最高 {max_load:.2f}（門檻 3.5），CPU 斷言不計通過或失敗；來源 {source}"
            else:
                check("avgCpuPercent<10", data["avgCpuPercent"] < 10, "有效負載下平均 CPU 必須低於 10%")
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            cpu_invalid_reason = f"無法取得 loadavg，CPU 斷言不計通過或失敗：{error}"
    return errors, cpu_invalid_reason


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in CASE_SCENARIO:
        print("用法：idle-bench-probe.py <C460-C464> <輸出.json> <預期 scenario>", file=sys.stderr)
        return 2
    case_id, output_path, expected_scenario = sys.argv[1:]
    try:
        data = json.loads(Path(output_path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"失敗：無法讀取量測 JSON：{error}")
        return 1
    errors, cpu_invalid_reason = errors_for(case_id, data, expected_scenario, Path(output_path + ".meta"))
    if cpu_invalid_reason:
        print("量測無效：" + cpu_invalid_reason)
    for error in errors:
        print("失敗：" + error)
    if errors:
        return 1
    if cpu_invalid_reason:
        print(f"其他斷言通過：{case_id} {expected_scenario}；CPU 斷言未計")
    else:
        print(f"通過：{case_id} {expected_scenario}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
