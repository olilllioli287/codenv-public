#!/usr/bin/env python3
"""驗證 C320 焦點同步情境，以及 C345 重載後的新文件回報。"""

from __future__ import annotations

import json
import sys
from pathlib import Path


def verify(path: Path) -> int:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"失敗：slash-focus JSON 無法讀取（{type(exc).__name__}: {exc}）")
        return 1
    if not isinstance(data, dict):
        print("失敗：slash-focus JSON 頂層不是 object")
        return 1

    failures = 0
    checks: tuple[tuple[str, str, object], ...] = (
        # 1. DOM 欄位移除。
        ("欄位移除", "result", "pass"),
        ("欄位移除", "before", True),
        ("欄位移除", "after", False),
        ("欄位移除", "removalClearedState", True),
        ("欄位移除", "activeFieldSlashJumped", False),
        ("欄位移除", "slashJumped", True),
        ("欄位移除", "responderIsInput", True),
        ("欄位移除", "firstChar", "x"),
        ("欄位移除", "firstCharPreserved", True),
        # 2. App 失焦（掛鉤直接呼叫失焦通知所用的清除函式）。
        ("App 失焦", "result", "pass"),
        ("App 失焦", "before", True),
        ("App 失焦", "after", False),
        # 3. 頁面重載。
        ("頁面重載", "result", "pass"),
        ("頁面重載", "before", True),
        ("頁面重載", "after", False),
        ("頁面重載", "reloadCompleted", True),
        ("頁面重載", "reloadClearedState", True),
        ("頁面重載", "slashJumped", True),
        ("頁面重載", "firstChar", "x"),
        ("頁面重載", "firstCharPreserved", True),
        # 4. 切換回仍有實際編輯中欄位的聊天室，JS 與 Swift 都必須為 true。
        ("切換聊天室", "result", "pass"),
        ("切換聊天室", "before", True),
        ("切換聊天室", "afterSwitchAway", False),
        ("切換聊天室", "expectedAfterReturn", True),
        ("切換聊天室", "afterReturn", True),
        ("切換聊天室", "synchronizedAfterReturn", True),
        ("切換聊天室", "secondChatCreated", True),
        ("切換聊天室", "otherChatShown", True),
        ("切換聊天室", "originalChatRestored", True),
        ("切換聊天室", "switchAwayCompleted", True),
        ("切換聊天室", "switchBackCompleted", True),
        # 5. 原生輸入框接手 responder 後仍有 DOM mutation。
        ("失焦後 DOM 變動", "result", "pass"),
        ("失焦後 DOM 變動", "before", True),
        ("失焦後 DOM 變動", "documentHasFocusAfterBlur", False),
        ("失焦後 DOM 變動", "mutationInserted", True),
        ("失焦後 DOM 變動", "webEditingAfterMutation", False),
        ("失焦後 DOM 變動", "slashJumped", True),
        ("失焦後 DOM 變動", "responderIsInput", True),
        ("失焦後 DOM 變動", "firstChar", "x"),
        ("失焦後 DOM 變動", "firstCharPreserved", True),
        # 6. readonly input 不算編輯中。
        ("readonly 欄位", "result", "pass"),
        ("readonly 欄位", "readOnlyFieldFocused", True),
        ("readonly 欄位", "jsExpectedEditing", False),
        ("readonly 欄位", "webEditingAfterReadOnlyFocus", False),
        ("整體", "result", "pass"),
    )
    section_by_label = {
        "欄位移除": "removal",
        "App 失焦": "appBlur",
        "頁面重載": "pageReload",
        "切換聊天室": "chatSwitch",
        "失焦後 DOM 變動": "blurThenMutation",
        "readonly 欄位": "readonlyInput",
        "整體": None,
    }
    for label, key, wanted in checks:
        section = section_by_label[label]
        row = data if section is None else data.get(section)
        actual = row.get(key) if isinstance(row, dict) else None
        passed = actual is wanted if isinstance(wanted, bool) else actual == wanted
        print(f"{'通過' if passed else '失敗'}：{label}.{key}={actual!r}，預期 {wanted!r}")
        failures += int(not passed)

    chat_switch = data.get("chatSwitch")
    expected_after_return = (chat_switch.get("expectedAfterReturn")
                             if isinstance(chat_switch, dict) else None)
    actual_after_return = chat_switch.get("afterReturn") if isinstance(chat_switch, dict) else None
    synchronized = (isinstance(expected_after_return, bool) and
                    isinstance(actual_after_return, bool) and
                    actual_after_return is expected_after_return)
    print(f"{'通過' if synchronized else '失敗'}：切換聊天室.afterReturn 與 JS expectedAfterReturn 相同 "
          f"（expected={expected_after_return!r}、actual={actual_after_return!r}）")
    failures += int(not synchronized)

    print("人工驗收限制：探針不合成實體 / 鍵盤事件，事件監視器消耗與輸入法組字不在本題自動驗證範圍。")
    print("掛鉤缺口：文件定義 readonlyInput，沒有獨立 disabled 欄位操作或輸出欄位；不推測 disabled 結果。")
    return 1 if failures else 0


def verify_page_reload_resync(path: Path) -> int:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"失敗：slash-focus JSON 無法讀取（{type(exc).__name__}: {exc}）")
        return 1
    if not isinstance(data, dict):
        print("失敗：slash-focus JSON 頂層不是 object")
        return 1

    # 依 C345 指定的 pageReloadResync 欄位判斷新頁編輯回報是否生效；
    # aw-rc-0709s 文件未公開新舊 docId 或舊頁 sequence 的輸出欄位，不猜名稱。
    row = data.get("pageReloadResync")
    if not isinstance(row, dict):
        print("失敗：缺少 C345 pageReloadResync 輸出")
        return 1

    checks: tuple[tuple[str, bool], ...] = (
        ("整體 result=pass", data.get("result") == "pass"),
        ("新頁有效 editing 回報已被接受", row.get("webEditingAfterNewPageFocus") is True),
        ("slashFocus 不跳回原生輸入框", row.get("slashJumped") is False),
        ("slashFocus 後 responder 保留", row.get("responderPreserved") is True),
    )
    failures = 0
    for label, passed in checks:
        print(f"{'通過' if passed else '失敗'}：{label}")
        failures += int(not passed)
    print("掛鉤缺口：docs/slash-focus-hooks.md 沒列出 pageReloadResync、新舊 docId、舊頁 sequence 或 responderPreserved 的輸出 schema；新頁接受狀態依派工明列的 webEditingAfterNewPageFocus 驗證，docId 差異及序號 >10 無法直接斷言。")
    return 1 if failures else 0


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[1] not in {"verify", "verify-page-reload"}:
        print("用法：slash-focus-probe.py verify|verify-page-reload <slash-focus.json>")
        return 2
    if argv[1] == "verify-page-reload":
        return verify_page_reload_resync(Path(argv[2]))
    return verify(Path(argv[2]))


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
