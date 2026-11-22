#!/usr/bin/env python3
"""Run and check the isolated C172/C173 commander-flow probe."""
import json
import os
import pathlib
import re
import signal
import subprocess
import sys
import time
import pathlib as _pl, sys as _sys
_sys.path.insert(0, str(_pl.Path(__file__).resolve().parent))
import psread  # noqa: E402（共用 ps 讀取，見 psread.py）


def run(cmd, *, timeout=10, check=False, capture=True, env=None):
    return subprocess.run(
        cmd,
        timeout=timeout,
        check=check,
        text=True,
        errors="replace",
        stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
        stderr=subprocess.PIPE if capture else subprocess.DEVNULL,
        env=env,
    )


def process_rows():
    return psread.pid_ppid_command(("-axww", "-o", "pid=,ppid=,command="))


def app_pids(binary, state):
    return [pid for pid, _ppid, command in process_rows() if command.startswith(binary) and state in command]


def is_descendant(pid, root, rows=None):
    parents = {child: parent for child, parent, _command in (rows or process_rows())}
    seen = set()
    while pid > 1 and pid not in seen:
        if pid == root:
            return True
        seen.add(pid)
        pid = parents.get(pid, 0)
    return False


def agy_pids():
    result = run(["pgrep", "-x", "agy"], timeout=5, check=False)
    return [int(value) for value in result.stdout.split() if value.isdigit()]


def process_started(pid):
    result = run(["ps", "-p", str(pid), "-o", "lstart="], timeout=5, check=False)
    return result.stdout.strip()


def stop_test_app(binary, state):
    for pid in app_pids(binary, state):
        try:
            os_kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    for _ in range(30):
        if not app_pids(binary, state):
            return True
        time.sleep(0.1)
    for pid in app_pids(binary, state):
        try:
            os_kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    return not app_pids(binary, state)


def os_kill(pid, sig):
    import os
    os.kill(pid, sig)


def check(label, actual, expected=True):
    ok = actual == expected
    print(f"  {'通過' if ok else '失敗'}：{label}（預期 {expected}，實際 {actual}）")
    return ok


def parse_events(path):
    try:
        return [json.loads(line) for line in pathlib.Path(path).read_text().splitlines() if line.strip()]
    except (OSError, json.JSONDecodeError):
        return []


class ProbeRunner:
    def __init__(self, app, root):
        self.app = pathlib.Path(app)
        self.binary = str(self.app / "Contents/MacOS/Workbench")
        self.fake_agy = os.environ.get("CODENV_TEST_AGY_BIN", "")
        if not self.fake_agy or not pathlib.Path(self.fake_agy).is_file() or not os.access(self.fake_agy, os.X_OK):
            raise RuntimeError("請設定可執行的 CODENV_TEST_AGY_BIN 假 agy")
        self.root = pathlib.Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self.ok = True
        self.seen_test_agy = {}
        self.ignored_agy = set()
        self.preexisting_agy = set(agy_pids())
        print(f"測試前 agy PID：{sorted(self.preexisting_agy)}（只記錄；非測試子孫不終止）")

    def record(self, label, actual, expected=True):
        self.ok = check(label, actual, expected) and self.ok

    def monitor_agy(self, root_pid):
        if not root_pid:
            return
        rows = process_rows()
        for pid in agy_pids():
            if is_descendant(pid, root_pid, rows):
                started = process_started(pid)
                self.seen_test_agy[pid] = started
                print(f"  失敗：測試實例子孫 agy PID {pid}，已終止")
                self.ok = False
                try:
                    os_kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            else:
                self.ignored_agy.add(pid)

    def verify_no_test_agy(self, phase):
        left = []
        for pid, started in list(self.seen_test_agy.items()):
            current = process_started(pid)
            if current and current == started:
                left.append(pid)
                print(f"  失敗：{phase} 後測試子孫 agy PID {pid} 仍存活，已終止")
                try:
                    os_kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        self.record(f"{phase} 沒有測試實例 agy 殘留", not left)
        self.seen_test_agy.clear()

    def probe(self, phase, preference):
        state = self.root / phase / "state"
        output = state / "commander-flow.jsonl"
        (state / "compact-state").mkdir(parents=True, exist_ok=True)
        claude_home = state / ".claude"
        claude_home.mkdir(parents=True, exist_ok=True)
        env = dict(__import__("os").environ)
        env["CODENV_COMPACT_DIR"] = str(state / "compact-state")
        env["CODENV_POOL_USAGE_FILE"] = str(state / "pool-usage.json")
        args = [
            "open", "-g", "-n", str(self.app), "--args",
            "--state-dir", str(state), "--background", "--test-screen", "ipad",
            "--test-hidden", "-NSAppSleepDisabled", "YES", "-ApplePersistenceIgnoreState", "YES",
            "--claude-home", str(claude_home), "--usage-fake", "--agy-bin", self.fake_agy,
            "-commanderCompletionNotices", preference,
            "--commander-flow-probe", f"2:{output}",
        ]
        ready = False
        try:
            launch = run(args, timeout=15, check=False, env=env)
            self.record(f"{phase} open -g 啟動成功", launch.returncode == 0)
            app_pid = None
            stable_size = None
            stable_rounds = 0
            for _ in range(300):
                pids = app_pids(self.binary, str(state))
                app_pid = pids[0] if pids else None
                self.monitor_agy(app_pid)
                if app_pid and output.is_file() and output.stat().st_size:
                    size = output.stat().st_size
                    if size == stable_size:
                        stable_rounds += 1
                    else:
                        stable_size, stable_rounds = size, 0
                    if stable_rounds >= 2:
                        ready = True
                        break
                time.sleep(0.2)
            self.record(f"{phase} 30 秒內測試 App 與 probe 就緒", ready)
            command_line = run(["ps", "-p", str(app_pid or ""), "-o", "command="], timeout=10, check=False).stdout
            self.record(f"{phase} 偏好只由 NSArgumentDomain 覆寫為 {preference}",
                        bool(app_pid) and f"-commanderCompletionNotices {preference}" in command_line)
            self.record(f"{phase} 測試 App 關閉", stop_test_app(self.binary, str(state)))
            self.verify_no_test_agy(phase)
        except (OSError, subprocess.TimeoutExpired) as error:
            print(f"  失敗：{phase} probe 啟動／等待錯誤：{type(error).__name__}")
            self.ok = False
            stop_test_app(self.binary, str(state))
            self.verify_no_test_agy(phase)
        return parse_events(output)

    def c172(self):
        enabled = self.probe("completion-default", "YES")
        settings = [event for event in enabled if event.get("event") == "settings"]
        nested = [event for event in enabled if event.get("event") == "nested_area_lead"]
        waiting = [event for event in enabled if event.get("event") == "permission_waiting"]
        notices = [event for event in enabled if event.get("event") == "completion_notice"]
        redactions = [event for event in enabled if event.get("event") == "completion_summary_redaction"]
        duplicates = [event for event in enabled if event.get("event") == "duplicate_result"]
        dispatches = [event for event in enabled if event.get("event") == "dispatch" and event.get("noticeRemovedAfterResult") is True]
        reports = [event for event in enabled if event.get("event") == "area_lead_report" and event.get("ok") is True]
        outside = [event for event in enabled if event.get("event") == "outside_target_rejected" and event.get("ok") is False]
        interrupt = [event for event in enabled if event.get("event") == "area_lead_interrupt_rejected" and event.get("ok") is False]
        self.record("設定頁有區長完成通知開關且預設開啟",
                    len(settings) == 1 and settings[0].get("settingsTogglePresent") is True and settings[0].get("preferenceEnabledAtStart") is True)
        self.record("子區施工聊天室繼承上層區長",
                    len(nested) == 1 and bool(nested[0].get("foundLead")) and nested[0].get("inheritedFromParent") is True)
        event_order = [event.get("event") for event in enabled]
        waiting_pos = event_order.index("permission_waiting") if event_order.count("permission_waiting") == 1 else -1
        notice_pos = event_order.index("completion_notice") if event_order.count("completion_notice") == 1 else -1
        self.record("權限等待時派工仍未完成且沒有通知，完成後才通知一次",
                    len(waiting) == 1 and waiting[0].get("status") == "waiting" and waiting[0].get("dispatchStillPending") is True and waiting[0].get("completionNoticeCount") == 0 and waiting_pos >= 0 and notice_pos > waiting_pos)
        self.record("合成金鑰摘要輸入已遮罩且沒有外流",
                    len(redactions) == 1 and redactions[0].get("inputHadSyntheticKey") is True and redactions[0].get("syntheticKeyLeaked") is False and isinstance(redactions[0].get("deliveredNotice"), str))
        self.record("重複 result 不重複送完成通知",
                    len(duplicates) == 1 and duplicates[0].get("dispatchConsumed") is True and duplicates[0].get("noticeCountAfterFirstResult") == 1 and duplicates[0].get("noticeCountAfterDuplicate") == 1)
        text = notices[0].get("text", "") if len(notices) == 1 else ""
        match = re.search(r"摘要：([^\r\n]*)", text)
        summary = match.group(1) if match else ""
        key_pattern = re.compile(r"(?i)(?:\bsk-[a-z0-9_-]{8,}\b|\bnvapi-[a-z0-9_-]{8,}\b|\bAIza[a-z0-9_-]{20,}\b|\bAKIA[A-Z0-9]{16}\b|\bgh[pousr]_[a-z0-9]{20,}\b|\bxox[baprs]-[a-z0-9-]{10,}\b)")
        self.record("預設開啟時恰有一則完成通知送達區長", len(notices) == 1 and notices[0].get("target") == "area-lead")
        self.record("通知只在派工 result 後移除一次", len(dispatches) == 1)
        self.record("完成摘要存在且不超過 200 字", bool(summary) and len(summary) <= 200)
        self.record("通知文字沒有已知格式的明文金鑰", not key_pattern.search(text))
        self.record("施工聊天室可回報區長", len(reports) == 1)
        self.record("區外目標回報被拒絕", len(outside) == 1)
        self.record("帶 --interrupt 的區長回報被拒絕", len(interrupt) == 1)

        disabled = self.probe("completion-disabled", "NO")
        disabled_settings = [event for event in disabled if event.get("event") == "settings"]
        disabled_redactions = [event for event in disabled if event.get("event") == "completion_summary_redaction"]
        disabled_duplicates = [event for event in disabled if event.get("event") == "duplicate_result"]
        self.record("關閉情境的設定頁開關狀態為關",
                    len(disabled_settings) == 1 and disabled_settings[0].get("settingsTogglePresent") is True and disabled_settings[0].get("preferenceEnabledAtStart") is False)
        self.record("關閉情境的合成金鑰摘要也沒有外流",
                    len(disabled_redactions) == 1 and disabled_redactions[0].get("inputHadSyntheticKey") is True and disabled_redactions[0].get("syntheticKeyLeaked") is False)
        self.record("關閉情境重複 result 仍不產生通知",
                    len(disabled_duplicates) == 1 and disabled_duplicates[0].get("dispatchConsumed") is True and disabled_duplicates[0].get("noticeCountAfterFirstResult") == 0 and disabled_duplicates[0].get("noticeCountAfterDuplicate") == 0)
        self.record("明確關閉後不送完成通知", not any(event.get("event") == "completion_notice" for event in disabled))
        return self.ok

    def c173(self):
        events = self.probe("steer", "YES")
        engines = ("claude", "codex", "local", "agy", "copilot", "apple")
        # 依 00.07.02 第 3 項更新：Claude --steer 不再即時插話（不送 send_now 中斷），與 agy／copilot／apple 一樣走「已排隊，這輪結束後送」；codex／local 不動
        immediate = {"codex", "local"}
        steers = [event for event in events if event.get("event") == "steer"]
        self.record("六種引擎各有一筆 steer 事件", len(steers) == 6 and all(sum(event.get("engine") == engine for event in steers) == 1 for engine in engines))
        for engine in engines:
            rows = [event for event in steers if event.get("engine") == engine]
            event = rows[0] if len(rows) == 1 else {}
            response = event.get("response", {})
            now = engine in immediate
            self.record(f"{engine} 送達模式符合規格", event.get("deliveryNow") is now)
            self.record(f"{engine} 中斷次數為零", event.get("interrupts") == 0)
            self.record(f"{engine} 回合仍維持工作中", event.get("statusRemainsWorking") is True)
            self.record(f"{engine} 插話訊息已送達或排入佇列", bool(event.get("processedMessageID")) and response.get("sent") is True and response.get("queued") is True)
            if now:
                self.record(f"{engine} 回覆不中斷插話", response.get("steered") is True and response.get("note") == "已送入不中斷插話，這輪工作會繼續")
            else:
                self.record(f"{engine} 回覆已排隊", response.get("steered") is False and response.get("note") == "已排隊，這輪結束後送")
        conflicts = [event for event in events if event.get("event") == "steer_interrupt_conflict"]
        message = conflicts[0].get("message", "") if len(conflicts) == 1 else ""
        self.record("同一命令同時指定 --steer 與 --interrupt 時遭拒且退出非零",
                    len(conflicts) == 1 and conflicts[0].get("rejected") is True and isinstance(conflicts[0].get("exitCode"), int) and conflicts[0]["exitCode"] != 0 and "--steer" in message and "--interrupt" in message)
        return self.ok


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in ("C172", "C173"):
        print("用法：commander-flow-probe.py C172|C173 <暫存目錄> <測試 App>", file=sys.stderr)
        return 2
    runner = ProbeRunner(sys.argv[3], sys.argv[2])
    result = runner.c172() if sys.argv[1] == "C172" else runner.c173()
    after = set(agy_pids())
    print(f"測後 agy PID：{sorted(after)}；測試期間未歸屬的 agy PID：{sorted(runner.ignored_agy)}")
    return 0 if result else 1


if __name__ == "__main__":
    raise SystemExit(main())
