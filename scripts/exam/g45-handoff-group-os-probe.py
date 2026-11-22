#!/usr/bin/env python3
"""OS-level reproduction and verification for G45 Handoff.runGrouped group cleanup."""

from __future__ import annotations

import argparse
import errno
import json
import os
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path


def _is_alive(pid: int) -> bool:
    if pid <= 1:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _wait_dead(pid: int, timeout: float = 0.6) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not _is_alive(pid):
            return True
        time.sleep(0.01)
    return not _is_alive(pid)


def _force_kill(pid: int) -> None:
    if pid > 1 and _is_alive(pid):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        _wait_dead(pid, timeout=0.5)


def _killpg_exists(pgid: int) -> bool:
    if pgid <= 1:
        return False
    try:
        os.killpg(pgid, 0)
        return True
    except OSError:
        return False


def _getpgid_or_minus1(pid: int) -> int:
    try:
        return os.getpgid(pid)
    except ProcessLookupError:
        return -1


def _is_owned_group_present(proc: subprocess.Popen[bytes], pid: int) -> bool:
    if pid <= 1 or not _killpg_exists(pid):
        return False
    running_before = proc.poll() is None
    current_group = _getpgid_or_minus1(pid)
    running_after = proc.poll() is None
    if running_before != running_after:
        return _killpg_exists(pid) and _getpgid_or_minus1(pid) != pid
    return (current_group == pid) if running_after else (current_group != pid)


def _run_grouped_sim(
    script: str,
    cwd: Path,
    timeout: float,
    grace: float,
    mode: str,
) -> dict:
    """Mirror Handoff.runGrouped in 'buggy' (pre-fix) or 'fixed' mode."""
    assert mode in ("buggy", "fixed")
    proc = subprocess.Popen(
        [
            "/usr/bin/perl",
            "-e",
            'use POSIX (); POSIX::setsid(); exec {$ARGV[0]} @ARGV or die "exec: $!"',
            "/bin/zsh",
            "-l",
            "-c",
            script,
        ],
        cwd=str(cwd),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    pid = proc.pid
    lock = threading.Lock()
    state = {
        "timed_out": False,
        "finished": False,
        "grace_deadline": None,
    }
    escalation_timer: list[threading.Timer] = []

    def kill_group_if_unfinished() -> None:
        with lock:
            if state["finished"] or not _is_owned_group_present(proc, pid):
                return
            try:
                os.killpg(pid, signal.SIGKILL)
            except OSError as exc:
                if exc.errno not in (errno.ESRCH, errno.EPERM):
                    raise

    def on_timeout() -> None:
        if pid <= 1:
            return
        with lock:
            if state["finished"]:
                return
            state["timed_out"] = True
            state["grace_deadline"] = time.monotonic() + max(0.0, grace)
            if _is_owned_group_present(proc, pid):
                try:
                    os.killpg(pid, signal.SIGTERM)
                except OSError as exc:
                    if exc.errno not in (errno.ESRCH, errno.EPERM):
                        raise
        t = threading.Timer(grace, kill_group_if_unfinished)
        t.daemon = True
        escalation_timer.append(t)
        t.start()

    start = time.monotonic()
    timeout_timer = threading.Timer(timeout, on_timeout)
    timeout_timer.daemon = True
    timeout_timer.start()

    stderr_chunks: list[bytes] = []

    def read_stderr() -> None:
        assert proc.stderr is not None
        stderr_chunks.append(proc.stderr.read())

    err_thread = threading.Thread(target=read_stderr, daemon=True)
    err_thread.start()
    assert proc.stdout is not None
    stdout_data = proc.stdout.read()
    err_thread.join()
    status = proc.wait()
    timeout_timer.cancel()

    if mode == "buggy":
        with lock:
            state["finished"] = True
        for t in escalation_timer:
            t.cancel()
    else:
        with lock:
            if not state["timed_out"]:
                state["finished"] = True
                if _is_owned_group_present(proc, pid):
                    try:
                        os.killpg(pid, signal.SIGKILL)
                    except OSError as exc:
                        if exc.errno not in (errno.ESRCH, errno.EPERM):
                            raise
                for t in escalation_timer:
                    t.cancel()
                deadline = None
            else:
                deadline = state["grace_deadline"]

        if deadline is not None:
            while time.monotonic() < deadline:
                with lock:
                    still = _is_owned_group_present(proc, pid)
                if not still:
                    break
                remaining = deadline - time.monotonic()
                time.sleep(min(0.02, max(0.005, remaining)))
            with lock:
                if _is_owned_group_present(proc, pid):
                    try:
                        os.killpg(pid, signal.SIGKILL)
                    except OSError as exc:
                        if exc.errno not in (errno.ESRCH, errno.EPERM):
                            raise
                state["finished"] = True
            for t in escalation_timer:
                t.cancel()

    elapsed = time.monotonic() - start
    return {
        "leaderPid": pid,
        "timedOut": state["timed_out"],
        "status": status,
        "elapsedSeconds": round(elapsed, 4),
        "stdout": stdout_data.decode("utf-8", errors="replace"),
        "stderr": b"".join(stderr_chunks).decode("utf-8", errors="replace"),
    }


def _read_pid_and_pgid(pid_file: Path) -> tuple[int, int]:
    text = pid_file.read_text(encoding="utf-8").strip()
    parts = text.split()
    return int(parts[0]), int(parts[1])


def _detached_perl_script(pid_file: Path, ignore_term: bool, sleep_seconds: int = 8, graceful_marker: Path | None = None) -> str:
    quoted_pid = shlex.quote(str(pid_file))
    if ignore_term:
        sig_setup = '$SIG{TERM}="IGNORE";'
        loop = f"my $end=time+{sleep_seconds}; while(time<$end){{ select(undef,undef,undef,0.05) }}"
    elif graceful_marker is not None:
        quoted_marker = shlex.quote(str(graceful_marker))
        sig_setup = (
            f'my $got=0; $SIG{{TERM}}=sub{{ $got=1 }};'
        )
        loop = (
            f"my $end=time+{sleep_seconds}; "
            f"while(!$got && time<$end){{ select(undef,undef,undef,0.02) }} "
            f"if($got){{ select(undef,undef,undef,0.08); "
            f'open my $mf,">",$ARGV[1] or die; print $mf "graceful\\n"; close $mf; }}'
        )
        perl_code = (
            "use POSIX (); "
            + sig_setup
            + 'open STDIN,"<","/dev/null"; open STDOUT,">","/dev/null"; open STDERR,">","/dev/null"; '
            + 'my $p=$ARGV[0]; open my $fh,">","$p.tmp" or die; '
            + 'print $fh "$$ " . POSIX::getpgrp() . "\\n"; close $fh; rename "$p.tmp",$p; '
            + loop
        )
        return (
            f"/usr/bin/perl -e {shlex.quote(perl_code)} {quoted_pid} {quoted_marker} </dev/null >/dev/null 2>&1 &\n"
            f"/usr/bin/perl -e 'my $e=time+2; until(-s $ARGV[0] || time>=$e){{ select(undef,undef,undef,0.01) }}' {quoted_pid}\n"
        )
    else:
        sig_setup = ""
        loop = f"my $end=time+{sleep_seconds}; while(time<$end){{ select(undef,undef,undef,0.05) }}"

    perl_code = (
        "use POSIX (); "
        + sig_setup
        + 'open STDIN,"<","/dev/null"; open STDOUT,">","/dev/null"; open STDERR,">","/dev/null"; '
        + 'my $p=$ARGV[0]; open my $fh,">","$p.tmp" or die; '
        + 'print $fh "$$ " . POSIX::getpgrp() . "\\n"; close $fh; rename "$p.tmp",$p; '
        + loop
    )
    return (
        f"/usr/bin/perl -e {shlex.quote(perl_code)} {quoted_pid} </dev/null >/dev/null 2>&1 &\n"
        f"/usr/bin/perl -e 'my $e=time+2; until(-s $ARGV[0] || time>=$e){{ select(undef,undef,undef,0.01) }}' {quoted_pid}\n"
    )


def run_all() -> tuple[bool, dict]:
    tmp_dir = Path(tempfile.mkdtemp(prefix="g45-handoff-os-"))
    cleanup_pids: list[int] = []
    try:
        report: dict = {}
        ok = True

        # 1. Normal exit with detached TERM-ignoring residual background child
        for mode in ("buggy", "fixed"):
            pid_file = tmp_dir / f"normal-{mode}.pid"
            script = _detached_perl_script(pid_file, ignore_term=True) + "printf 'ok'; exit 0\n"
            res = _run_grouped_sim(script, tmp_dir, timeout=2.0, grace=0.25, mode=mode)
            child_pid, child_pgid = _read_pid_and_pgid(pid_file)
            cleanup_pids.append(child_pid)
            same_group = child_pgid == res["leaderPid"]
            if mode == "buggy":
                time.sleep(0.15)
                leaked = _is_alive(child_pid)
                _force_kill(child_pid)
                passed = (not res["timedOut"]) and same_group and leaked
                report["normalExitBuggyRepro"] = {
                    **res,
                    "sameGroup": same_group,
                    "residualLeakedAsExpected": leaked,
                    "pass": passed,
                }
            else:
                killed = _wait_dead(child_pid, timeout=0.6)
                _force_kill(child_pid)
                passed = (
                    (not res["timedOut"])
                    and res["status"] == 0
                    and res["stdout"] == "ok"
                    and same_group
                    and killed
                )
                report["normalExitFixed"] = {
                    **res,
                    "sameGroup": same_group,
                    "residualKilled": killed,
                    "pass": passed,
                }
            ok &= passed

        # 2. Timeout where pipe-holding child exits on TERM while detached sibling ignores TERM
        for mode in ("buggy", "fixed"):
            pid_file = tmp_dir / f"timeout-detached-{mode}.pid"
            script = _detached_perl_script(pid_file, ignore_term=True) + "/bin/sleep 8 & exit 0\n"
            res = _run_grouped_sim(script, tmp_dir, timeout=0.25, grace=0.25, mode=mode)
            child_pid, child_pgid = _read_pid_and_pgid(pid_file)
            cleanup_pids.append(child_pid)
            same_group = child_pgid == res["leaderPid"]
            if mode == "buggy":
                # Wait past grace to confirm escalation was cancelled and child survived
                time.sleep(0.4)
                leaked = _is_alive(child_pid)
                _force_kill(child_pid)
                passed = res["timedOut"] and same_group and leaked
                report["timeoutDetachedSiblingBuggyRepro"] = {
                    **res,
                    "sameGroup": same_group,
                    "residualLeakedAsExpected": leaked,
                    "pass": passed,
                }
            else:
                killed = _wait_dead(child_pid, timeout=0.6)
                _force_kill(child_pid)
                passed = (
                    res["timedOut"]
                    and res["elapsedSeconds"] < 2.0
                    and res["elapsedSeconds"] >= 0.45
                    and same_group
                    and killed
                )
                report["timeoutDetachedSiblingFixed"] = {
                    **res,
                    "sameGroup": same_group,
                    "residualKilled": killed,
                    "pass": passed,
                }
            ok &= passed

        # 3. Timeout where detached sibling handles SIGTERM gracefully within grace window
        pid_file = tmp_dir / "timeout-graceful.pid"
        marker_file = tmp_dir / "timeout-graceful.marker"
        script = (
            _detached_perl_script(pid_file, ignore_term=False, graceful_marker=marker_file)
            + "/bin/sleep 8 & exit 0\n"
        )
        res = _run_grouped_sim(script, tmp_dir, timeout=0.25, grace=0.8, mode="fixed")
        child_pid, child_pgid = _read_pid_and_pgid(pid_file)
        cleanup_pids.append(child_pid)
        dead = _wait_dead(child_pid, timeout=0.5)
        _force_kill(child_pid)
        graceful_ok = marker_file.is_file() and marker_file.read_text(encoding="utf-8").strip() == "graceful"
        exited_before_full_grace = res["elapsedSeconds"] < 0.75
        passed = res["timedOut"] and (child_pgid == res["leaderPid"]) and dead and graceful_ok and exited_before_full_grace
        report["timeoutGracefulSiblingFixed"] = {
            **res,
            "sameGroup": child_pgid == res["leaderPid"],
            "gracefulMarkerWritten": graceful_ok,
            "exitedBeforeFullGrace": exited_before_full_grace,
            "childDead": dead,
            "pass": passed,
        }
        ok &= passed

        # 4. PID reuse guard check: live other session leader must NOT match exited leader check
        other_leader = subprocess.Popen(
            ["/usr/bin/perl", "-e", "use POSIX (); POSIX::setsid(); sleep 5"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        cleanup_pids.append(other_leader.pid)
        # Wait until setsid takes effect
        t_end = time.monotonic() + 1.0
        while time.monotonic() < t_end and _getpgid_or_minus1(other_leader.pid) != other_leader.pid:
            time.sleep(0.01)
        exited_dummy = subprocess.Popen(["/usr/bin/true"])
        exited_dummy.wait()
        # With an exited process handle (poll() is not None), a live group leader with pgid == pid must be rejected.
        rejected_reused_leader = not _is_owned_group_present(exited_dummy, other_leader.pid)
        # With the real running leader handle, it must be accepted.
        accepted_own_live_leader = _is_owned_group_present(other_leader, other_leader.pid)
        other_leader.kill()
        other_leader.wait()
        passed = rejected_reused_leader and accepted_own_live_leader
        report["pidReuseGuard"] = {
            "rejectedReusedLeader": rejected_reused_leader,
            "acceptedOwnLiveLeader": accepted_own_live_leader,
            "pass": passed,
        }
        ok &= passed

        report["allPassed"] = ok
        return ok, report
    finally:
        for pid in cleanup_pids:
            _force_kill(pid)
        shutil.rmtree(tmp_dir, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="G45 Handoff.runGrouped OS-level probe")
    parser.add_argument("--output", help="Optional JSON output file path")
    args = parser.parse_args()
    ok, report = run_all()
    rendered = json.dumps(report, indent=2, ensure_ascii=False, sort_keys=True)
    if args.output:
        out_path = Path(args.output)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(rendered + "\n", encoding="utf-8")
    print(rendered)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
