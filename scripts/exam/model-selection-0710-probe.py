#!/usr/bin/env python3
"""Verify the JSON contract requested for the 00.07.10 model-selection hook.

The app-side --model-selection-test-probe hook is not present yet. Cases C348-C350
therefore remain pending until TestHarness emits the documented fields below.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


CODEX_MODELS = [
    ("gpt-6.1-sol", "GPT-6.1 Sol"),
    ("gpt-6-sol", "GPT-6 Sol"),
    ("gpt-6.1-terra", "GPT-6.1 Terra"),
    ("gpt-6-luna", "GPT-6 Luna"),
    ("gpt-6-astra", "GPT-6 Astra"),
    ("gpt-5.6-sol", "GPT-5.6 Sol"),
    ("gpt-5.6-terra", "GPT-5.6 Terra"),
    ("gpt-5.6-luna", "GPT-5.6 Luna"),
    ("gpt-reserve", "GPT Reserve"),
    ("codex-auto-review", "Codex Auto Review"),
]
CODEX_ULTRA = {
    "gpt-6.1-sol", "gpt-6-sol", "gpt-6.1-terra", "gpt-6-astra",
    "gpt-5.6-sol", "gpt-5.6-terra",
}
CODEX_LOW_DEFAULT = {"gpt-6.1-sol", "gpt-6-astra", "gpt-6.1-terra", "gpt-5.6-sol"}
CODEX_LEVELS = ["low", "medium", "high", "xhigh", "max"]
AGY_NEW = {
    "gemini-pro-orchestrator-g1-pro": "Orchestrator (Argon)",
    "gpt-oss-120b-medium": "GPT-OSS 120B",
}


class Checks:
    def __init__(self) -> None:
        self.failed = 0

    def expect(self, label: str, condition: bool, actual: Any = None) -> None:
        if condition:
            print(f"通過：{label}")
        else:
            print(f"失敗：{label}；實際={actual!r}")
            self.failed += 1


def load_probe(case_id: str, filename: str, checks: Checks) -> dict[str, Any]:
    try:
        value = json.loads(Path(filename).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        checks.expect("探針輸出為 JSON object", False, str(exc))
        return {}
    checks.expect("探針輸出為 JSON object", isinstance(value, dict), type(value).__name__)
    if not isinstance(value, dict):
        return {}
    checks.expect("探針 schemaVersion=1", value.get("schemaVersion") == 1, value.get("schemaVersion"))
    checks.expect("探針 caseId 對應本題", value.get("caseId") == case_id, value.get("caseId"))
    return value


def rows_by_id(value: Any) -> dict[str, dict[str, Any]]:
    if not isinstance(value, list):
        return {}
    return {
        row["id"]: row for row in value
        if isinstance(row, dict) and isinstance(row.get("id"), str)
    }


def verify_c348(data: dict[str, Any], checks: Checks) -> None:
    codex = data.get("codexMenu")
    checks.expect("Codex 選單有 10 個依規格排序的項目", isinstance(codex, list) and len(codex) == 10, codex)
    if not isinstance(codex, list):
        codex = []
    for index, (model_id, display_name) in enumerate(CODEX_MODELS):
        item = codex[index] if index < len(codex) and isinstance(codex[index], dict) else {}
        checks.expect(f"Codex 第 {index + 1} 項 id／顯示名", item.get("id") == model_id and item.get("displayName") == display_name, item)
        levels = ["low", "medium", "high", "xhigh", "max", "ultra"] if model_id in CODEX_ULTRA else CODEX_LEVELS
        default = "low" if model_id in CODEX_LOW_DEFAULT else "medium"
        checks.expect(f"{model_id} 強度清單", item.get("levels") == levels, item.get("levels"))
        checks.expect(f"{model_id} 預設強度", item.get("defaultLevel") == default, item.get("defaultLevel"))

    agy = data.get("agyMenu")
    checks.expect("agy 選單共有七項且 id 不重複", isinstance(agy, list) and len(agy) == 7 and len(rows_by_id(agy)) == 7, agy)
    agy_rows = rows_by_id(agy)
    for model_id, display_name in AGY_NEW.items():
        item = agy_rows.get(model_id, {})
        checks.expect(f"agy 新模型 {model_id} 顯示名正確", item.get("displayName") == display_name, item)
        checks.expect(f"agy 新模型 {model_id} 無 levels 且隱藏拉桿", item.get("levels") == [] and item.get("sliderVisible") is False, item)
    legacy_count = sum(1 for row in agy_rows if row not in AGY_NEW)
    checks.expect("五個既有 agy 選項仍存在", legacy_count == 5, legacy_count)

    claude = data.get("claudeSliders")
    checks.expect("有輸出 Claude 模型拉桿資料", isinstance(claude, list) and len(claude) > 0, claude)
    if isinstance(claude, list):
        for item in claude:
            if not isinstance(item, dict):
                checks.expect("Claude 拉桿項目格式正確", False, item)
                continue
            declared = item.get("declaredLevels")
            visible = item.get("sliderLevels")
            checks.expect("Claude 拉桿欄位是強度陣列", isinstance(declared, list) and isinstance(visible, list), item)
            if isinstance(declared, list) and isinstance(visible, list):
                checks.expect(
                    f"Claude {item.get('id')} 的 ultra 只在模型宣告時出現",
                    "ultra" not in visible or "ultra" in declared,
                    visible,
                )


def verify_c349(data: dict[str, Any], checks: Checks) -> None:
    turns = data.get("codexTurns")
    turn_rows = [row for row in turns if isinstance(row, dict)] if isinstance(turns, list) else []
    checks.expect("turn/start 記錄僅含十個模型的 high、Sol ultra、Luna 舊 ultra 情境", len(turn_rows) == 12, len(turn_rows))
    for model_id, _ in CODEX_MODELS:
        matches = [row for row in turn_rows if row.get("selectedModelId") == model_id and row.get("selectedEffort") == "high"]
        checks.expect(f"Codex {model_id} 有一筆選 high 的 turn/start", len(matches) == 1, len(matches))
        if len(matches) != 1:
            continue
        row = matches[0]
        payload = row.get("payload") if isinstance(row.get("payload"), dict) else {}
        checks.expect(f"Codex turn/start model 保留選單 id：{model_id}", payload.get("model") == model_id, payload)
        checks.expect(f"Codex {model_id} 支援的 high 原值送出", payload.get("effort") == "high", payload)

    ultra = [row for row in turn_rows if row.get("selectedModelId") == "gpt-6.1-sol" and row.get("selectedEffort") == "ultra"]
    checks.expect("支援 ultra 的 Sol 有一筆 ultra turn/start", len(ultra) == 1, len(ultra))
    if len(ultra) == 1:
        payload = ultra[0].get("payload") if isinstance(ultra[0].get("payload"), dict) else {}
        checks.expect("支援的 ultra 原值送入 turn/start", payload.get("model") == "gpt-6.1-sol" and payload.get("effort") == "ultra", payload)

    stale = [row for row in turn_rows if row.get("selectedModelId") == "gpt-6-luna" and row.get("selectedEffort") == "ultra"]
    checks.expect("Luna 載入舊 ultra 值的測試情境存在一次", len(stale) == 1, len(stale))
    if len(stale) == 1:
        payload = stale[0].get("payload") if isinstance(stale[0].get("payload"), dict) else {}
        checks.expect("不支援的舊 effort 不放進 turn/start payload", "effort" not in payload, payload)

    agy = data.get("agyLaunches")
    agy_rows = [row for row in agy if isinstance(row, dict)] if isinstance(agy, list) else []
    checks.expect("agy 啟動記錄只含兩個新模型與 Hydrogen 相容情境", len(agy_rows) == 3, len(agy_rows))
    for model_id in AGY_NEW:
        matches = [row for row in agy_rows if row.get("selectedModelId") == model_id]
        checks.expect(f"agy 新模型 {model_id} 有一筆啟動記錄", len(matches) == 1, len(matches))
        if len(matches) == 1:
            checks.expect(f"agy --model 完全等於所選 id：{model_id}", matches[0].get("modelArg") == model_id, matches[0])
    forbidden_variants = {
        "gpt-oss-120b-high", "gpt-oss-120b-low",
        "gemini-pro-orchestrator-g1-pro-high", "gemini-pro-orchestrator-g1-pro-low",
    }
    generated = [row.get("modelArg") for row in agy_rows if row.get("modelArg") in forbidden_variants]
    checks.expect("agy 未生成新模型的 high／low 變體 id", not generated, generated)
    hydrogen = data.get("hydrogenCompatibility")
    checks.expect(
        "Hydrogen high＋effort low 仍送 gemini-4-hydrogen-low",
        isinstance(hydrogen, dict)
        and hydrogen.get("selectedModelId") == "gemini-4-hydrogen-high"
        and hydrogen.get("selectedEffort") == "low"
        and hydrogen.get("modelArg") == "gemini-4-hydrogen-low",
        hydrogen,
    )


def verify_c350(data: dict[str, Any], checks: Checks) -> None:
    attempts = data.get("cliValidation")
    rows = [row for row in attempts if isinstance(row, dict)] if isinstance(attempts, list) else []
    expected = {
        ("codex", "gpt-6-luna", "ultra"),
        ("agy", "gemini-pro-orchestrator-g1-pro", "high"),
        ("agy", "gemini-pro-orchestrator-g1-pro", "low"),
        ("agy", "gpt-oss-120b-medium", "high"),
        ("agy", "gpt-oss-120b-medium", "low"),
    }
    for engine, model_id, effort in expected:
        matches = [row for row in rows if (row.get("engine"), row.get("modelId"), row.get("effort")) == (engine, model_id, effort)]
        checks.expect(f"CLI 驗證情境存在：{engine}/{model_id}/{effort}", len(matches) == 1, len(matches))
        if len(matches) == 1:
            row = matches[0]
            checks.expect(f"CLI 已識別模型後拒絕不支援強度：{model_id}", row.get("modelRecognized") is True and row.get("rejected") is True, row)
            reason = row.get("rejectionReason")
            checks.expect(f"拒絕原因確實為強度驗證：{model_id}", isinstance(reason, str) and ("--effort 只接受" in reason or "沒有強度可調" in reason), reason)
            checks.expect(f"拒絕 {model_id} 時沒有建立聊天室或啟動引擎", row.get("conversationCreated") is False and row.get("engineStarted") is False and isinstance(row.get("exitCode"), int) and row.get("exitCode") != 0, row)


def verify_c351(data: dict[str, Any], checks: Checks) -> None:
    rows = data.get("modelNoticeScenarios", [])
    rows = rows if isinstance(rows, list) else []
    expected = {}
    for engine in ("codex", "agy", "copilot"):
        expected[f"{engine}-same"] = None
        expected[f"{engine}-restore"] = None
    expected["codex-change"] = "下一則訊息起改用 {name}"
    expected["cross-to-codex"] = "下一則訊息起改用 {name}（會重開）"
    for engine in ("agy", "copilot"):
        expected[f"{engine}-idle-change"] = "下一則訊息起改用 {name}（會重開）"
        expected[f"{engine}-busy-change"] = "下一則訊息起改用 {name}（會重開）"
    for scenario, template in expected.items():
        matches = [r for r in rows if isinstance(r, dict) and r.get("scenario") == scenario]
        checks.expect(f"提示情境恰一筆：{scenario}", len(matches) == 1, len(matches))
        if len(matches) != 1:
            continue
        row = matches[0]
        name = row.get("displayName")
        notices = row.get("notices")
        checks.expect(f"{scenario} 有模型顯示名", isinstance(name, str) and bool(name), name)
        wanted = [] if template is None else [template.format(name=name)]
        checks.expect(f"{scenario} 聊天區提示數量與文案", notices == wanted, notices)


def main() -> int:
    if len(sys.argv) != 3 or sys.argv[1] not in {"C348", "C349", "C350", "C351"}:
        print("用法：model-selection-0710-probe.py <C348|C349|C350|C351> <輸出 JSON>", file=sys.stderr)
        return 2
    case_id, filename = sys.argv[1], sys.argv[2]
    checks = Checks()
    data = load_probe(case_id, filename, checks)
    {"C348": verify_c348, "C349": verify_c349, "C350": verify_c350, "C351": verify_c351}[case_id](data, checks)
    print(f"{'通過' if checks.failed == 0 else '失敗'}：{case_id}，失敗斷言 {checks.failed} 項")
    return 0 if checks.failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
