#!/usr/bin/env python3
"""Verify the C450 WindowDiag probe JSON contract."""
import json
import re
import sys
from pathlib import Path


TOP_LEVEL_KEYS = {
    "normal",
    "lowAlpha",
    "readOnly",
    "observers",
    "containsWindowTitleOrChatText",
}
SNAPSHOT_KEYS = {"anomalies", "fieldsComplete", "lineLength", "lineSha12"}
READ_ONLY_KEYS = {
    "alphaBefore",
    "alphaAfter",
    "isOpaqueBefore",
    "isOpaqueAfter",
    "contentLayerOpacityBefore",
    "contentLayerOpacityAfter",
}
OBSERVER_KEYS = {
    "installedOnProbeWindow",
    "eventLogLinesAfterScreenChange",
    "eventLogLinesWithAnomalyMarker",
}
ANOMALY_LABELS = {
    "alpha-低",
    "非不透明",
    "背景透明",
    "內容層透明",
    "WS-alpha-低",
    "子層透明",
}


def errors_for(data):
    errors = []

    def check(path, condition, message):
        if not condition:
            errors.append(f"{path}: {message}")

    if not isinstance(data, dict):
        return ["root: 預期 JSON object"]

    check("root.keys", set(data) == TOP_LEVEL_KEYS, "欄位須符合契約，不能輸出視窗標題或聊天內容欄位")

    for name in ("normal", "lowAlpha"):
        snapshot = data.get(name)
        if not isinstance(snapshot, dict):
            errors.append(f"{name}: 預期 object")
            continue
        check(f"{name}.keys", set(snapshot) == SNAPSHOT_KEYS, "欄位須符合 snapshot 契約")
        anomalies = snapshot.get("anomalies")
        check(f"{name}.anomalies", isinstance(anomalies, list) and all(isinstance(x, str) for x in anomalies), "預期字串陣列")
        if isinstance(anomalies, list):
            check(f"{name}.anomalyLabels", all(x in ANOMALY_LABELS for x in anomalies), "只允許契約列出的異常類別，避免輸出自由文字")
        length = snapshot.get("lineLength")
        check(f"{name}.lineLength", type(length) is int and length > 0, "診斷行長度必須大於 0")
        digest = snapshot.get("lineSha12")
        check(f"{name}.lineSha12", isinstance(digest, str) and re.fullmatch(r"[0-9a-fA-F]{12}", digest) is not None, "只接受 12 位十六進位摘要，不接受原始診斷行")

    normal = data.get("normal")
    if isinstance(normal, dict):
        check("normal.anomalies.empty", normal.get("anomalies") == [], "alpha=1 正常視窗不得有異常")
        check("normal.fieldsComplete", normal.get("fieldsComplete") is True, "正常視窗欄位須完整")

    low_alpha = data.get("lowAlpha")
    if isinstance(low_alpha, dict):
        anomalies = low_alpha.get("anomalies")
        check("lowAlpha.alpha-low", isinstance(anomalies, list) and "alpha-低" in anomalies, "alpha=0.5 必須標記 alpha-低")

    read_only = data.get("readOnly")
    if not isinstance(read_only, dict):
        errors.append("readOnly: 預期 object")
    else:
        check("readOnly.keys", set(read_only) == READ_ONLY_KEYS, "欄位須符合唯讀檢查契約")
        for before, after in (
            ("alphaBefore", "alphaAfter"),
            ("isOpaqueBefore", "isOpaqueAfter"),
            ("contentLayerOpacityBefore", "contentLayerOpacityAfter"),
        ):
            check(f"readOnly.{before}={after}", before in read_only and after in read_only and read_only[before] == read_only[after], "診斷不得改變視窗狀態")

    observers = data.get("observers")
    if not isinstance(observers, dict):
        errors.append("observers: 預期 object")
    else:
        check("observers.keys", set(observers) == OBSERVER_KEYS, "欄位須符合 observer 契約")
        check("observers.installedOnProbeWindow", observers.get("installedOnProbeWindow") is True, "觀察器須安裝在測試視窗")
        screen_lines = observers.get("eventLogLinesAfterScreenChange")
        check("observers.eventLogLinesAfterScreenChange", type(screen_lines) is int and screen_lines >= 3, "安裝、換螢幕與 +0.3 秒記錄至少三行")
        anomaly_lines = observers.get("eventLogLinesWithAnomalyMarker")
        check("observers.eventLogLinesWithAnomalyMarker", type(anomaly_lines) is int and anomaly_lines >= 1, "alpha=0.5 後須至少有一行異常標記")

    check("containsWindowTitleOrChatText", data.get("containsWindowTitleOrChatText") is False, "不得包含視窗標題或聊天文字")
    return errors


def main():
    if len(sys.argv) != 2:
        print("用法：window-diag-probe.py <window-diag-output.json>", file=sys.stderr)
        return 2
    try:
        data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"失敗：無法讀取視窗診斷輸出：{exc}")
        return 1
    errors = errors_for(data)
    for error in errors:
        print("失敗：" + error)
    if errors:
        return 1
    print("通過：C450 視窗診斷契約")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
