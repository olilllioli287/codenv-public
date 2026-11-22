#!/usr/bin/env python3
"""判斷指定考卷時段內，pmset -g log 是否顯示電腦睡過。"""

from __future__ import annotations

import datetime as dt
import re
import sys
from typing import Iterable


UTC = dt.timezone.utc
TIMESTAMP = re.compile(
    r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4})\s+(.*)$"
)
EVENT = re.compile(r"^(Sleep|Wake|DarkWake)\s+(.*?)\s*$")
CONTINUATION = re.compile(r"^(?:DriverReason|DriverDetails):")
HEADER = re.compile(r"^PM ASL data store:")
SUMMARY_HEADER = re.compile(r"^Time stamp\s+Domain")
SUMMARY_UUID = re.compile(r"^UUID:")
SLEEP_WAKE_SUMMARY = re.compile(r"^Sleep/Wakes since boot:")
TOTAL_SLEEP_WAKE_SUMMARY = re.compile(r"^Total Sleep/Wakes since boot:")
ASSERTION_FOOTER = re.compile(r"^Assertion status system-wide:")


def warn(message: str) -> int:
    clean = message.replace("\t", " ").replace("\r", " ").replace("\n", " ")
    print(f"WARN\t{clean}")
    return 0


def parse_arguments(argv: list[str]) -> tuple[int, int]:
    if len(argv) != 4 or argv[0] != "--start" or argv[2] != "--end":
        raise ValueError("用法：release-sleep.py --start <epoch秒> --end <epoch秒>")
    try:
        start = int(argv[1], 10)
        end = int(argv[3], 10)
    except ValueError as error:
        raise ValueError("開始與結束時間必須是 epoch 秒整數") from error
    if end < start:
        raise ValueError("結束時間早於開始時間")
    # 預先確認結束時間可格式化，避免睡眠紀錄無法解析時也輸出 traceback。
    epoch_datetime(end)
    return start, end


def epoch_datetime(value: int) -> dt.datetime:
    try:
        return dt.datetime(1970, 1, 1, tzinfo=UTC) + dt.timedelta(seconds=value)
    except OverflowError as error:
        raise ValueError("epoch 秒超出可處理範圍") from error


def format_timestamp(value: dt.datetime) -> str:
    return value.strftime("%Y-%m-%d %H:%M:%S %z")


def parse_events(lines: Iterable[str]) -> list[tuple[dt.datetime, str, dt.datetime]]:
    events: list[tuple[dt.datetime, int, str, dt.datetime]] = []
    record_count = 0
    in_summary = False
    summary_uuid_seen = False
    in_assertion_footer = False

    for line_number, raw_line in enumerate(lines, start=1):
        line = raw_line.rstrip("\r\n")
        if not line.strip():
            continue
        stripped = line.strip()
        if in_assertion_footer:
            continue
        if ASSERTION_FOOTER.match(stripped):
            in_assertion_footer = True
            continue
        if HEADER.match(stripped):
            continue
        if SLEEP_WAKE_SUMMARY.match(stripped) or TOTAL_SLEEP_WAKE_SUMMARY.match(stripped):
            continue
        if SUMMARY_HEADER.match(stripped):
            in_summary = True
            summary_uuid_seen = False
            continue
        if in_summary:
            if SUMMARY_UUID.match(stripped):
                summary_uuid_seen = True
                continue
            if summary_uuid_seen:
                if not TIMESTAMP.match(line):
                    raise ValueError(f"第 {line_number} 行摘要格式不符")
                # 摘要列也可能長得像 Sleep/Wake，但不是原始事件紀錄。
                in_summary = False
                summary_uuid_seen = False
                continue
            else:
                continue

        match = TIMESTAMP.match(line)
        if not match:
            # pmset 的 WakeDetails 後可能用無時間戳續行列出驅動原因。
            if CONTINUATION.match(line.strip()):
                continue
            raise ValueError(f"第 {line_number} 行格式不符")

        try:
            local_timestamp = dt.datetime.strptime(
                match.group(1), "%Y-%m-%d %H:%M:%S %z"
            )
        except ValueError as error:
            raise ValueError(f"第 {line_number} 行時間格式不符") from error
        timestamp = local_timestamp.astimezone(UTC)

        record_count += 1
        event_match = EVENT.match(match.group(2).strip())
        if not event_match:
            continue

        name, details = event_match.groups()
        if name == "Sleep" and details.startswith("Entering Sleep state"):
            events.append((timestamp, line_number, "sleep", local_timestamp))
        elif name == "Wake" and re.match(r"^Wake from(?:\s|$)", details):
            # Wake Requests、DarkWake 等都不代表真正醒來。
            events.append((timestamp, line_number, "wake", local_timestamp))

    if in_summary:
        raise ValueError("pmset 摘要資料不完整")
    if record_count == 0:
        raise ValueError("pmset 記錄為空或沒有有效時間戳")

    events.sort(key=lambda event: (event[0], event[1]))
    return [
        (timestamp, kind, local_timestamp)
        for timestamp, _, kind, local_timestamp in events
    ]


def find_sleep_interval(
    events: list[tuple[dt.datetime, str, dt.datetime]],
    start: dt.datetime,
    end: dt.datetime,
) -> tuple[dt.datetime, dt.datetime | None] | None:
    sleeping_since: tuple[dt.datetime, dt.datetime] | None = None
    intervals: list[
        tuple[dt.datetime, dt.datetime, dt.datetime | None, dt.datetime | None]
    ] = []

    for timestamp, kind, local_timestamp in events:
        if kind == "sleep":
            # DarkWake 後的 Back to Sleep 不會結束既有睡眠狀態。
            if sleeping_since is None:
                sleeping_since = (timestamp, local_timestamp)
        elif kind == "wake" and sleeping_since is not None:
            intervals.append((sleeping_since[0], sleeping_since[1], timestamp, local_timestamp))
            sleeping_since = None

    if sleeping_since is not None:
        intervals.append((sleeping_since[0], sleeping_since[1], None, None))

    for sleep_time, sleep_display, wake_time, wake_display in intervals:
        # 入睡事件在考卷區間內就算睡過，即使醒來發生於區間結束之後。
        if start <= sleep_time < end:
            return sleep_display, wake_display
        # 開跑前已睡著時，必須在考卷區間內有真正 Wake 才算睡過。
        if sleep_time < start and wake_time is not None and start <= wake_time < end:
            return sleep_display, wake_display
    return None


def main(argv: list[str]) -> int:
    try:
        start_epoch, end_epoch = parse_arguments(argv)
        start = epoch_datetime(start_epoch)
        end = epoch_datetime(end_epoch)
        events = parse_events(sys.stdin)
        interval = find_sleep_interval(events, start, end)
    except (OSError, ValueError) as error:
        return warn(str(error))

    if interval is None:
        print("AWAKE")
        return 0

    sleep_time, wake_time = interval
    wake_text = (
        format_timestamp(wake_time)
        if wake_time
        else format_timestamp(end.astimezone(sleep_time.tzinfo))
    )
    print(f"SLEPT\t{format_timestamp(sleep_time)}\t{wake_text}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
