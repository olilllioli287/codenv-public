#!/usr/bin/env python3
"""Summarize KeyGuard feedback and suggest detector tuning; never edits source."""
import argparse
import json
from collections import Counter
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("file", nargs="?", default=str(Path.home() / "Library/Application Support/codenv/keyguard-false-positives.jsonl"))
    args = parser.parse_args()
    path = Path(args.file).expanduser()
    counts: Counter[str] = Counter()
    words: Counter[str] = Counter()
    examples: dict[str, list[str]] = {}
    if not path.exists():
        print(f"找不到回饋紀錄：{path}")
        return 0
    for line_no, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        try:
            item = json.loads(line)
        except json.JSONDecodeError:
            print(f"略過格式錯誤的第 {line_no} 行")
            continue
        if item.get("type") != "false-positive":
            continue
        rule = str(item.get("rule", "未知規則"))
        counts[rule] += 1
        context = str(item.get("context", "")).lower()
        for word in ("commit", "hash", "sha", "uuid", "git", "雜湊", "提交", "版本", "key", "token", "secret"):
            if word in context:
                words[(rule, word)] += 1
        examples.setdefault(rule, []).append(str(item.get("text", "")))
    if not counts:
        print("目前沒有「不是金鑰」回饋紀錄。")
        return 0
    print("誤攔規則統計：")
    for rule, count in counts.most_common():
        print(f"  {rule}: {count}")
        common = [word for (r, word), _ in words.most_common() if r == rule]
        if common:
            print("    常見上下文：" + "、".join(common[:8]))
    hex_rule = next((r for r in counts if "十六進位" in r or "hex" in r.lower()), None)
    if hex_rule:
        print(f"建議：{hex_rule} 規則遇到 commit／sha／hash／雜湊／git 語境時不攔。")
        if any(7 <= len(s) <= 40 and s and all(c in "0123456789abcdef" for c in s) for s in examples[hex_rule]):
            print("建議：7～40 位全小寫十六進位且符合 git 雜湊格式時視為提交雜湊。")
    for rule in counts:
        if rule != hex_rule:
            common = [word for (r, word), _ in words.most_common() if r == rule]
            if common:
                print(f"建議：檢視 {rule} 是否可依常見上下文（{ '、'.join(common[:5]) }）縮小誤攔。")
    print("以上僅為建議，腳本不會修改程式。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
