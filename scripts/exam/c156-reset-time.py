#!/usr/bin/env python3
"""Generate and verify C156 reset-time fixtures against one captured clock."""
import json
import sys
from datetime import date, datetime, time, timedelta, timezone
from pathlib import Path

DISPLAY_NAMES = {
    "Gemini · 5 hours": "Gemini 5 小時",
    "Gemini · 7 days": "Gemini 每週",
    "Gemini 4 Argon · 7 days": "Argon 每週",
    "Claude & GPT · 5 hours": "agy Claude 5 小時",
    "Claude & GPT · 7 days": "agy Claude 每週",
}
MASKS = {
    "alpha.account@example.test": "alp***@example.test",
    "bravo.account@example.test": "bra***@example.test",
}
REMAINING = {
    "alpha.account@example.test": {
        "Gemini · 5 hours": 82,
        "Gemini · 7 days": 64,
        "Gemini 4 Argon · 7 days": 42,
        "Claude & GPT · 5 hours": 36,
        "Claude & GPT · 7 days": 72,
    },
    "bravo.account@example.test": {
        "Gemini · 5 hours": 44,
        "Gemini · 7 days": 88,
        "Gemini 4 Argon · 7 days": 26,
        "Claude & GPT · 5 hours": 58,
        "Claude & GPT · 7 days": 34,
    },
}


def parse_date(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def iso_utc(value):
    return value.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def reset_display(reset_at, now):
    """Mirror the documented same-day / tomorrow / later-date display rule."""
    local_reset = reset_at.astimezone(now.tzinfo)
    local_now = now.astimezone(now.tzinfo)
    day_delta = (local_reset.date() - local_now.date()).days
    clock = f"{local_reset.hour:02d}:{local_reset.minute:02d}"
    if day_delta == 0:
        prefix = ""
    elif day_delta == 1:
        prefix = "明天 "
    else:
        prefix = f"{local_reset.month}/{local_reset.day} "
    return f"{prefix}{clock} 回補"


def run_formatter_selftest():
    local_tz = datetime.now().astimezone().tzinfo
    fixed_day = date(2026, 11, 21)
    tested = []
    for label, hour, minute in (("00:00", 0, 0), ("04:00", 4, 0), ("18:00", 18, 0), ("23:59", 23, 59)):
        now = datetime.combine(fixed_day, time(hour, minute), tzinfo=local_tz)
        same_day = datetime.combine(fixed_day, time(23, 59, 59), tzinfo=local_tz)
        tomorrow = datetime.combine(fixed_day + timedelta(days=1), time(0, 5), tzinfo=local_tz)
        farther = datetime.combine(fixed_day + timedelta(days=2), time(0, 5), tzinfo=local_tz)
        assert reset_display(same_day, now) == "23:59 回補", (label, reset_display(same_day, now))
        assert reset_display(tomorrow, now) == "明天 00:05 回補", (label, reset_display(tomorrow, now))
        assert reset_display(farther, now) == "11/23 00:05 回補", (label, reset_display(farther, now))
        tested.append(label)
    print("純函式時段邊界通過：" + "／".join(tested) + "；同日、明天、更遠日期格式皆精確")


def make_fixture(accounts_path, expectation_path):
    local_tz = datetime.now().astimezone().tzinfo
    now = datetime.now().astimezone().replace(microsecond=0)
    today_end = datetime.combine(now.date(), time(23, 59, 59), tzinfo=local_tz)
    same_day = min(now + timedelta(minutes=15), today_end)
    tomorrow = now.date() + timedelta(days=1)
    farther_day = now.date() + timedelta(days=2)
    next_a = datetime.combine(tomorrow, time(0, 5), tzinfo=local_tz)
    next_b = datetime.combine(tomorrow, time(0, 15), tzinfo=local_tz)
    far_a = datetime.combine(farther_day, time(0, 5), tzinfo=local_tz)
    far_b = datetime.combine(farther_day, time(0, 15), tzinfo=local_tz)

    target_by_name = {
        "Gemini · 5 hours": (same_day, next_b),
        "Gemini · 7 days": (next_a, next_b),
        "Gemini 4 Argon · 7 days": (far_a, far_b),
        "Claude & GPT · 5 hours": (same_day, next_b),
        "Claude & GPT · 7 days": (far_a, far_b),
    }
    pool_by_name = {
        "Gemini · 5 hours": "Gemini",
        "Gemini · 7 days": "Gemini",
        "Gemini 4 Argon · 7 days": "Gemini 4 Argon",
        "Claude & GPT · 5 hours": "Claude & GPT",
        "Claude & GPT · 7 days": "Claude & GPT",
    }
    accounts = []
    for email in REMAINING:
        windows = []
        account_index = list(REMAINING).index(email)
        for name, remaining in REMAINING[email].items():
            windows.append({
                "name": name,
                "pool": pool_by_name[name],
                "remaining": remaining,
                "resetsAt": iso_utc(target_by_name[name][account_index]),
            })
        accounts.append({"email": email, "plan": "Google AI Pro", "windows": windows})

    Path(accounts_path).write_text(json.dumps(accounts, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    categories = set()
    for first, second in target_by_name.values():
        for target in (first, second):
            delta = (target.date() - now.date()).days
            categories.add("同日" if delta == 0 else "明天" if delta == 1 else "更遠日期")
    expected = {
        "fixtureNow": now.isoformat(timespec="seconds"),
        "timezone": str(local_tz),
        "accountMasks": MASKS,
        "displayNames": DISPLAY_NAMES,
        "remaining": REMAINING,
        "relativeDateCategories": sorted(categories),
    }
    Path(expectation_path).write_text(json.dumps(expected, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("動態 fixture 建立：" + "／".join(sorted(categories)) + "；now=" + expected["fixtureNow"] + "；timezone=" + expected["timezone"])


def verify(text_path, png_path, accounts_path, expectation_path, fake_agy_log):
    text_file, image_file = Path(text_path), Path(png_path)
    assert text_file.is_file(), f"探針未輸出 txt：{text_file}"
    assert image_file.is_file() and image_file.stat().st_size > 1000, f"探針未輸出有效 png：{image_file}"
    lines = text_file.read_text(encoding="utf-8").splitlines()
    accounts = json.loads(Path(accounts_path).read_text(encoding="utf-8"))
    expected = json.loads(Path(expectation_path).read_text(encoding="utf-8"))
    now = parse_date(expected["fixtureNow"])
    assert len(accounts) == 2 and len({a["email"] for a in accounts}) == 2, "fixture 應有兩個帳號"
    assert "card=Gemini（agy）" in lines and "accounts=2" in lines, lines

    expected_summaries = []
    expected_windows = []
    category_set = set()
    for account in accounts:
        email = account["email"]
        assert email in expected["accountMasks"], f"未知 fixture account：{email}"
        masked = expected["accountMasks"][email]
        assert f"account={masked}" in lines, (masked, lines)
        assert email not in "\n".join(lines), "輸出洩漏 fixture email"
        for window in account["windows"]:
            name = window["name"]
            display_name = expected["displayNames"][name]
            reset_at = parse_date(window["resetsAt"])
            display = reset_display(reset_at, now)
            day_delta = (reset_at.astimezone(now.tzinfo).date() - now.astimezone(now.tzinfo).date()).days
            category_set.add("同日" if day_delta == 0 else "明天" if day_delta == 1 else "更遠日期")
            expected_windows.append(
                f"window account={masked} name={display_name} remaining={window['remaining']}% reset={display}"
            )

    for name, display_name in expected["displayNames"].items():
        entries = [(a, w) for a in accounts for w in a["windows"] if w["name"] == name]
        assert len(entries) == 2, (name, entries)
        tails = [reset_display(parse_date(w["resetsAt"]), now) for _, w in entries]
        assert tails[0] != tails[1], (name, "兩帳號回補時間應不同", tails)
        avg = sum(w["remaining"] for _, w in entries) // len(entries)
        earliest = min(parse_date(w["resetsAt"]) for _, w in entries)
        expected_summaries.append(
            f"summary={display_name} remaining={avg}% reset={reset_display(earliest, now)}"
        )

    actual_summaries = [line for line in lines if line.startswith("summary=")]
    actual_windows = [line for line in lines if line.startswith("window account=")]
    assert sorted(actual_summaries) == sorted(expected_summaries), (expected_summaries, actual_summaries)
    assert sorted(actual_windows) == sorted(expected_windows), (expected_windows, actual_windows)
    joined = "\n".join(lines)
    assert "alpha.account@example.test" not in joined and "bravo.account@example.test" not in joined, lines
    assert "下一次回補" not in joined and "帳號 帳號" not in joined, lines
    assert not Path(fake_agy_log).exists(), "測試期間呼叫了假 agy，應由 usage fake 完成"
    print("斷言通過：兩帳號遮罩、五個窗口的逐帳號與平均回補字串依 fixtureNow 精確比對、帳號 reset 不合併、無 agy 呼叫")
    print("實際輸出涵蓋相對日期：" + "／".join(sorted(category_set)))


def main(argv):
    if len(argv) == 2 and argv[1] == "selftest":
        run_formatter_selftest()
        return 0
    if len(argv) == 4 and argv[1] == "generate":
        make_fixture(argv[2], argv[3])
        return 0
    if len(argv) == 7 and argv[1] == "verify":
        verify(*argv[2:])
        return 0
    print("用法：c156-reset-time.py selftest | generate <accounts.json> <expect.json> | verify <txt> <png> <accounts.json> <expect.json> <agent-stub.log>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv))
    except (AssertionError, KeyError, OSError, ValueError, json.JSONDecodeError) as error:
        print(f"失敗：{error}", file=sys.stderr)
        raise SystemExit(1)
