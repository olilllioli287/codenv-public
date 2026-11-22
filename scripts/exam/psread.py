"""共用的 ps 讀取：所有考卷探針解析 `ps` 輸出都走這裡（不要再各自 split）。

為什麼：ps 輸出可能含非 UTF-8 位元組（0xff）、含換行的指令列（續行只剩一個字或空白）、空白行、只有 pid 的行。
各探針自己 `text=True` 解碼＋`a, b = line.split(None, 1)` 會在這些行崩潰（00.07.10 出版 17 題、C237 失敗）。
規則：讀 bytes → decode("utf-8", "replace") → splitlines → 欄位不足或 pid／ppid 不是整數的行一律跳過。
"""
from __future__ import annotations

import subprocess

PID_COMMAND = ("-axo", "pid=,command=")
PID_PPID_COMMAND = ("-axo", "pid=,ppid=,command=")


def read_text(ps_args=PID_COMMAND, *, timeout: float = 15) -> str:
    """跑 /bin/ps，bytes 讀回來用 replace 解碼；ps 失敗回空字串。"""
    try:
        raw = subprocess.run(["/bin/ps", *ps_args], capture_output=True, check=False, timeout=timeout).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return raw.decode("utf-8", "replace")


def parse_pid_command(text: str) -> list[tuple[int, str]]:
    rows: list[tuple[int, str]] = []
    for line in text.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[0].isdigit():
            rows.append((int(parts[0]), parts[1]))
    return rows


def parse_pid_ppid_command(text: str) -> list[tuple[int, int, str]]:
    rows: list[tuple[int, int, str]] = []
    for line in text.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
            rows.append((int(parts[0]), int(parts[1]), parts[2]))
    return rows


def pid_command(ps_args=PID_COMMAND) -> list[tuple[int, str]]:
    return parse_pid_command(read_text(ps_args))


def pid_ppid_command(ps_args=PID_PPID_COMMAND) -> list[tuple[int, int, str]]:
    return parse_pid_ppid_command(read_text(ps_args))


def process_table(ps_args=PID_PPID_COMMAND) -> dict[int, tuple[int, str]]:
    """pid -> (ppid, command)"""
    return {pid: (ppid, command) for pid, ppid, command in pid_ppid_command(ps_args)}
