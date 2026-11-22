#!/usr/bin/env python3
"""Verify the C452 WindowDiag R1 probe contract."""
import json
import sys
from pathlib import Path


TOP_LEVEL_KEYS = {
    "multiWindow",
    "colorSpace",
    "contentViewAlpha",
    "animatingAlpha",
    "stableLowAlpha",
    "noScheduleForNonRecoverable",
    "privacy",
}
COLOR_SPACES = {
    "sRGB",
    "DisplayP3",
    "GenericRGB",
    "ExtendedSRGB",
    "ExtendedLinearSRGB",
    "GenericGray",
    "其他",
    "無",
}


def errors_for(data):
    errors = []

    def check(path, condition, message):
        if not condition:
            errors.append(f"{path}: {message}")

    def object_at(name, keys):
        value = data.get(name)
        if not isinstance(value, dict):
            errors.append(f"{name}: 預期 object")
            return None
        check(f"{name}.keys", set(value) == keys, "欄位須符合契約，不接受額外自由文字欄位")
        return value

    if not isinstance(data, dict):
        return ["root: 預期 JSON object"]
    check("root.keys", set(data) == TOP_LEVEL_KEYS, "欄位須符合契約，不接受額外文字或隱私資料")

    multi = object_at(
        "multiWindow",
        {"window1EventLines", "window2EventLines", "window1ObservedAfterSecondInstall", "serialsDistinct"},
    )
    if multi is not None:
        first = multi.get("window1EventLines")
        second = multi.get("window2EventLines")
        check("multiWindow.window1EventLines", type(first) is int and first >= 3, "W1 須記錄安裝、換螢幕與後續追蹤，至少三行")
        check("multiWindow.window2EventLines", type(second) is int and second >= 1, "W2 安裝後須有至少一行視窗診斷記錄")
        check("multiWindow.window1ObservedAfterSecondInstall", multi.get("window1ObservedAfterSecondInstall") is True, "安裝 W2 後仍須觀察到 W1 新記錄")
        check("multiWindow.serialsDistinct", multi.get("serialsDistinct") is True, "兩個視窗須有不同序號")

    color = object_at("colorSpace", {"value", "inWhitelist"})
    if color is not None:
        check("colorSpace.value", color.get("value") in COLOR_SPACES, "色域值須是契約白名單之一")
        check("colorSpace.inWhitelist", color.get("inWhitelist") is True, "白名單判斷必須為 true")

    content = object_at("contentViewAlpha", {"restored", "before", "after", "anomalyListed"})
    if content is not None:
        restored = content.get("restored")
        check("contentViewAlpha.restored", isinstance(restored, list) and "內容viewalpha" in restored, "復原項目須包含內容 view alpha")
        check("contentViewAlpha.before", content.get("before") == 0.5, "內容 view alpha 輸入值須為 0.5")
        check("contentViewAlpha.after", content.get("after") == 1.0, "內容 view alpha 須復原為 1.0")
        check("contentViewAlpha.anomalyListed", content.get("anomalyListed") is True, "snapshot anomalies 須含內容view-alpha-低")

    animated = object_at("animatingAlpha", {"restoredCount", "skippedUnstableLogged"})
    if animated is not None:
        check("animatingAlpha.restoredCount", type(animated.get("restoredCount")) is int and animated.get("restoredCount") == 0, "持續變動時不得復原")
        check("animatingAlpha.skippedUnstableLogged", animated.get("skippedUnstableLogged") is True, "須記錄『復原略過』及『數值仍在變動』")

    stable = object_at("stableLowAlpha", {"restoredCount", "alphaAfter"})
    if stable is not None:
        check("stableLowAlpha.restoredCount", type(stable.get("restoredCount")) is int and stable.get("restoredCount") == 1, "穩定低 alpha 須恰復原一次")
        check("stableLowAlpha.alphaAfter", stable.get("alphaAfter") == 1.0, "穩定低 alpha 須復原為 1.0")

    nonrecoverable = object_at("noScheduleForNonRecoverable", {"restoreLines", "snapshotCountAfterTrigger"})
    if nonrecoverable is not None:
        check("noScheduleForNonRecoverable.restoreLines", type(nonrecoverable.get("restoreLines")) is int and nonrecoverable.get("restoreLines") == 0, "只有不可復原異常時不得有復原記錄")
        check("noScheduleForNonRecoverable.snapshotCountAfterTrigger", type(nonrecoverable.get("snapshotCountAfterTrigger")) is int and nonrecoverable.get("snapshotCountAfterTrigger") == 0, "觸發後不得出現『復原前』快照")

    privacy = object_at("privacy", {"containsWindowTitleOrChatText"})
    if privacy is not None:
        check("privacy.containsWindowTitleOrChatText", privacy.get("containsWindowTitleOrChatText") is False, "不得輸出視窗標題或聊天文字")

    return errors


def main():
    if len(sys.argv) != 2:
        print("用法：window-diag-r1-probe.py <window-diag-r1-output.json>", file=sys.stderr)
        return 2
    try:
        data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"失敗：無法讀取 C452 視窗診斷探針輸出：{exc}")
        return 1
    errors = errors_for(data)
    for error in errors:
        print("失敗：" + error)
    if errors:
        return 1
    print("通過：C452 視窗診斷 R1 契約")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
