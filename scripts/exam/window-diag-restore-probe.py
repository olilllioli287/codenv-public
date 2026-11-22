#!/usr/bin/env python3
"""Verify the explicit C451 WindowDiagRestore output contract."""
import json
import sys
from pathlib import Path


SCENARIO_KEYS = {
    "normal": {
        "restored", "windowChanged", "alphaBefore", "alphaAfter",
        "contentLayerOpacityBefore", "contentLayerOpacityAfter",
        "backgroundAlphaBefore", "backgroundAlphaAfter", "eventLogRestoreLines",
        "skippedReason",
    },
    "lowAlpha": {"restored", "alphaBefore", "alphaAfter", "eventLogRestoreLines", "afterSnapshotLines", "logHasBeforeAfter"},
    "lowLayerOpacity": {"restored", "contentLayerOpacityBefore", "contentLayerOpacityAfter", "eventLogRestoreLines", "afterSnapshotLines", "logHasBeforeAfter"},
    "lowBackgroundAlpha": {"restored", "backgroundAlphaBefore", "backgroundAlphaAfter", "eventLogRestoreLines", "afterSnapshotLines", "logHasBeforeAfter"},
    "hiddenAlphaZero": {"restored", "alphaAfter"},
    "rateLimit": {"totalRestores", "fourthSkippedReason", "fourthRestored"},
    "transientNotRestored": {"restored", "eventLogRestoreLines"},
    "notVisible": {"restored", "skippedReason"},
}
RESTORE_ITEMS = {"alpha", "contentLayerOpacity", "backgroundAlpha"}
REQUIRED_SCENARIOS = set(SCENARIO_KEYS) | {"miniaturized"}


def errors_for(data, unverified):
    errors = []

    def check(path, condition, message):
        if not condition:
            errors.append(f"{path}: {message}")

    def scenario(name):
        value = data.get(name)
        if not isinstance(value, dict):
            errors.append(f"{name}: 預期 object")
            return None
        check(f"{name}.keys", set(value) == SCENARIO_KEYS[name], "欄位須符合契約；不接受自由文字欄位")
        return value

    def restored_list(name, value, expected=None, empty=False):
        items = value.get("restored")
        check(f"{name}.restored", isinstance(items, list) and all(isinstance(x, str) and x in RESTORE_ITEMS for x in items), "只接受復原項目代碼陣列")
        if isinstance(items, list):
            if empty:
                check(f"{name}.restored.empty", not items, "不得復原")
            if expected is not None:
                check(f"{name}.restored.{expected}", expected in items, f"須包含 {expected}")

    def same(before, after):
        return before in current and after in current and current[before] == current[after]

    if not isinstance(data, dict):
        return ["root: 預期 JSON object"]
    check("root.keys", set(data) == REQUIRED_SCENARIOS, "欄位須符合契約情境集合，不能多帶診斷行、私人或聊天文字")

    current = scenario("normal")
    if current is not None:
        restored_list("normal", current, empty=True)
        check("normal.windowChanged", current.get("windowChanged") is False, "正常視窗不得改變")
        check("normal.skippedReason", current.get("skippedReason") == "無可復原異常", "正常情境 skip 理由須為固定字串")
        for before, after in (
            ("alphaBefore", "alphaAfter"),
            ("contentLayerOpacityBefore", "contentLayerOpacityAfter"),
            ("backgroundAlphaBefore", "backgroundAlphaAfter"),
        ):
            check(f"normal.{before}={after}", same(before, after), "前後數值必須相同")
        check("normal.eventLogRestoreLines", current.get("eventLogRestoreLines") == 0, "正常視窗不得寫復原記錄")

    for name, item, before, after, expected_before in (
        ("lowAlpha", "alpha", "alphaBefore", "alphaAfter", 0.5),
        ("lowLayerOpacity", "contentLayerOpacity", "contentLayerOpacityBefore", "contentLayerOpacityAfter", 0.5),
        ("lowBackgroundAlpha", "backgroundAlpha", "backgroundAlphaBefore", "backgroundAlphaAfter", 0.5),
    ):
        current = scenario(name)
        if current is None:
            continue
        restored_list(name, current, expected=item)
        check(f"{name}.{before}", current.get(before) == expected_before, "異常值輸入應為 0.5")
        check(f"{name}.{after}", current.get(after) == 1.0, "值須復原至 1.0／不透明")
        count = current.get("eventLogRestoreLines")
        check(f"{name}.eventLogRestoreLines", type(count) is int and count >= 1, "至少須有一行復原記錄")
        after_count = current.get("afterSnapshotLines")
        check(f"{name}.afterSnapshotLines", type(after_count) is int and after_count >= 1, "復原後事件記錄至少須有一行快照")
        check(f"{name}.logHasBeforeAfter", current.get("logHasBeforeAfter") is True, "復原記錄須含前後數值")

    current = scenario("hiddenAlphaZero")
    if current is not None:
        restored_list("hiddenAlphaZero", current, empty=True)
        check("hiddenAlphaZero.alphaAfter", current.get("alphaAfter") == 0.0, "alpha=0 的隱藏視窗必須維持 0")

    current = scenario("rateLimit")
    if current is not None:
        total = current.get("totalRestores")
        check("rateLimit.totalRestores", type(total) is int and total == 3, "總復原次數必須恰為 3")
        check("rateLimit.fourthSkippedReason", current.get("fourthSkippedReason") == "頻率上限", "第 4 次須以頻率上限跳過")
        fourth = current.get("fourthRestored")
        check("rateLimit.fourthRestored", isinstance(fourth, list) and fourth == [], "第 4 次不得復原任何項目")

    current = scenario("transientNotRestored")
    if current is not None:
        restored_list("transientNotRestored", current, empty=True)
        check("transientNotRestored.eventLogRestoreLines", current.get("eventLogRestoreLines") == 0, "暫態自行恢復後不得寫復原行")

    current = scenario("notVisible")
    if current is not None:
        restored_list("notVisible", current, empty=True)
        check("notVisible.skippedReason", current.get("skippedReason") == "視窗不可見", "skip 理由須為固定字串")

    miniaturized = data.get("miniaturized")
    if miniaturized is None:
        unverified.append("miniaturized：掛鉤輸出 null，未驗（不計為通過）")
    elif isinstance(miniaturized, dict):
        check("miniaturized.keys", set(miniaturized) == {"restored", "skippedReason"}, "欄位須符合 skip 情境契約")
        restored_list("miniaturized", miniaturized, empty=True)
        check("miniaturized.skippedReason", miniaturized.get("skippedReason") == "視窗已最小化", "skip 理由須為固定字串")
    else:
        errors.append("miniaturized: 預期 null（未驗）或 object")
    return errors


def main():
    if len(sys.argv) != 2:
        print("用法：window-diag-restore-probe.py <window-diag-restore-output.json>", file=sys.stderr)
        return 2
    try:
        data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"失敗：無法讀取視窗復原探針輸出：{exc}")
        return 1
    unverified = []
    errors = errors_for(data, unverified)
    for item in unverified:
        print("未驗：" + item)
    for error in errors:
        print("失敗：" + error)
    if errors:
        return 1
    if unverified:
        print("部分檢查符合契約；未驗情境不計為通過")
        return 0
    print("通過：C451 視窗異常值復原契約")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
