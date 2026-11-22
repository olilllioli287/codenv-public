#!/usr/bin/env python3
"""Proposed hook contract; pending until app-side observations are supplied."""
import json
import sys
from pathlib import Path

def compare(expected, actual, path):
    failures = 0
    if isinstance(expected, dict):
        if not isinstance(actual, dict):
            print(f"失敗：{path} 缺少 object")
            return 1
        for key, value in expected.items():
            failures += compare(value, actual.get(key), f"{path}.{key}")
    elif type(expected) is not type(actual) or expected != actual:
        print(f"失敗：{path} 預期={expected!r} 實際={actual!r}")
        failures += 1
    else:
        print(f"通過：{path}")
    return failures

if __name__ == '__main__':
    case, filename = sys.argv[1:]
    contract = json.loads(Path(__file__).with_name('interrupted-indicator-contract.json').read_text())
    try:
        data = json.loads(Path(filename).read_text())
        expected = dict(contract[case]['expected'], caseId=case, schemaVersion=1)
        failures = compare(expected, data, case)
        if case in {"C361", "C362", "C371", "C373"}:
            persisted_expected = {"persistedReadOK": True, "conversationMissing": False}
            if case == "C373":
                persisted_expected["persistedArchivedMarkedBefore"] = True
            else:
                persisted_expected["persistedMarkedBefore"] = True
            failures += compare(persisted_expected, data, case)
    except (OSError, ValueError, KeyError) as error:
        print(f"失敗：掛鉤輸出無效：{error}")
        failures = 1
    sys.exit(bool(failures))
