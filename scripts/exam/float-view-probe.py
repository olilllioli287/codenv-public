#!/usr/bin/env python3
"""驗證 C177 浮動 view probe，並快照正式 App 的保護資料 metadata。"""

from __future__ import annotations

import json
import os
import stat
import sys
from pathlib import Path


def snapshot_item(path: Path) -> dict[str, object]:
    if not path.exists() and not path.is_symlink():
        return {"exists": False}
    info = path.lstat()
    result: dict[str, object] = {
        "exists": True,
        "mode": info.st_mode,
        "device": info.st_dev,
        "inode": info.st_ino,
        "size": info.st_size,
        "mtimeNs": info.st_mtime_ns,
        "ctimeNs": info.st_ctime_ns,
    }
    if not stat.S_ISDIR(info.st_mode):
        result["atimeNs"] = info.st_atime_ns
    if stat.S_ISDIR(info.st_mode):
        children: dict[str, object] = {}
        with os.scandir(path) as entries:
            for entry in sorted(entries, key=lambda item: item.name):
                children[entry.name] = snapshot_item(Path(entry.path))
        result["children"] = children
    return result


def protected_snapshot(root: Path) -> dict[str, object]:
    return {
        "collab.json": snapshot_item(root / "collab.json"),
        "compact-state": snapshot_item(root / "compact-state"),
        "pool-usage.json": snapshot_item(root / "pool-usage.json"),
        # 記錄 state.json 供參考；正式 App 開啟時可能更新，只記錄、不作判定。
        "state.json": snapshot_item(root / "state.json"),
    }


def snapshot(root: Path, output: Path) -> int:
    data = protected_snapshot(root)
    output.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"保護資料 stat 快照：{output}")
    print("已記錄 collab.json、compact-state/、pool-usage.json 與 state.json metadata；未讀檔案內容。")
    return 0


def compare(before_path: Path, after_path: Path) -> int:
    before = json.loads(before_path.read_text(encoding="utf-8"))
    after = json.loads(after_path.read_text(encoding="utf-8"))
    watched = ("collab.json", "compact-state", "pool-usage.json")
    changed = [name for name in watched if before.get(name) != after.get(name)]
    state_changed = before.get("state.json") != after.get("state.json")
    if changed:
        print(f"失敗：正式保護資料 metadata 改變：{', '.join(changed)}；未還原任何資料。")
        return 1
    print("通過：collab.json、compact-state/、pool-usage.json metadata 前後一致。")
    print(f"state.json metadata 有變={str(state_changed).lower()}（僅記錄，不作失敗訊號）；未讀內容。")
    return 0


def verify_probe(path: Path) -> int:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        print(f"失敗：float-view probe JSON 無法讀取：{type(exc).__name__}: {exc}")
        return 1
    if not isinstance(data, dict):
        print("失敗：float-view probe 頂層不是 JSON object")
        return 1

    window_count_before = data.get("appWindowsBefore")
    window_count_after = data.get("appWindowsAfterOpen")
    window_counts_valid = (
        isinstance(window_count_before, int) and not isinstance(window_count_before, bool)
        and isinstance(window_count_after, int) and not isinstance(window_count_after, bool)
        and window_count_after <= window_count_before
    )
    print(f"{'通過' if window_counts_valid else '失敗'}：NSApp.windows 數量未增加（前={window_count_before!r}、後={window_count_after!r}）")

    checks = [
        ("浮動終端機仍在主視窗 contentView", "attachedToMainContentView"),
        ("probe 的視窗數量檢查結果", "probeDidNotChangeWindowCount"),
        ("視窗數量一致欄位", "windowCountUnchanged"),
        ("拖曳放開後位置可存讀", "positionReadBack"),
        ("最大化 frame 正確", "maximizedFrameCorrect"),
        ("還原 frame 正確", "restoredFrameCorrect"),
        ("主視窗縮小後仍在可視範圍", "visibleAfterMainWindowShrink"),
    ]
    failures = 0 if window_counts_valid else 1
    for label, key in checks:
        value = data.get(key)
        passed = value is True
        print(f"{'通過' if passed else '失敗'}：{label}（{key}={value!r}）")
        if not passed:
            failures += 1

    window_values = {key: value for key, value in data.items() if "windowCount" in key or key in {"appWindowsBefore", "appWindowsAfterOpen"}}
    print(f"NSApp.windows probe 欄位：{json.dumps(window_values, ensure_ascii=False, sort_keys=True)}")
    # 目前 probe 只回報位置讀回，未定義拖曳期間與放開後的獨立存檔欄位。
    timing_keys = ("positionSavedOnlyAfterMouseUp", "positionSaveDeferredUntilRelease", "positionWriteDeferredUntilMouseUp")
    timing_reported = next((key for key in timing_keys if key in data), None)
    if timing_reported is None:
        print("失敗：probe 未提供獨立的拖曳期間／放開後存檔時序欄位；positionReadBack 僅確認位置讀回。")
        failures += 1
    else:
        timing_ok = data[timing_reported] is True
        print(f"{'通過' if timing_ok else '失敗'}：放開後才存位置（{timing_reported}={data[timing_reported]!r}）")
        if not timing_ok:
            failures += 1
    return 1 if failures else 0


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("用法：float-view-probe.py snapshot <正式資料夾> <輸出.json> | compare <before.json> <after.json> | verify <probe.json>")
        return 2
    action = argv[1]
    if action == "snapshot" and len(argv) == 4:
        return snapshot(Path(argv[2]), Path(argv[3]))
    if action == "compare" and len(argv) == 4:
        return compare(Path(argv[2]), Path(argv[3]))
    if action == "verify" and len(argv) == 3:
        return verify_probe(Path(argv[2]))
    print("參數錯誤")
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
