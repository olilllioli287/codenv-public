#!/usr/bin/env python3
"""C184 black-box verification for the 07-21 local model selection probe."""

from __future__ import annotations

import json
import hashlib
import os
import pathlib
import shlex
import signal
import subprocess
import sys
import time
import pathlib as _pl, sys as _sys
_sys.path.insert(0, str(_pl.Path(__file__).resolve().parent))
import psread  # noqa: E402（共用 ps 讀取，見 psread.py）


BOLT = "mlx-community/NVIDIA-Nemotron-3.5-Bolt-E4B-OptiQ-4bit"
QWEN = "mlx-community/Qwen3.5-4B-MLX-4bit"
PREF_DOMAIN_PREFIX = "com.local.aiworkbench.test."
PREF_KEY = "archiveSummaryUseAgy"


def test_pref_domain(state_dir: pathlib.Path) -> str:
    canonical = str(state_dir.resolve())
    digest = hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:32]
    return PREF_DOMAIN_PREFIX + digest


def report(label: str, passed: bool, detail: str = "") -> None:
    status = "通過" if passed else "失敗"
    suffix = f"；{detail}" if detail else ""
    print(f"{status}：{label}{suffix}", flush=True)


def run_defaults(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["/usr/bin/defaults", *args],
        capture_output=True,
        text=True,
        check=False,
    )


def snapshot_pref(pref_domain: str) -> tuple[bool, str, str]:
    read = run_defaults("read", pref_domain, PREF_KEY)
    if read.returncode != 0:
        return False, "", ""
    value = read.stdout.strip()
    type_result = run_defaults("read-type", pref_domain, PREF_KEY)
    value_type = type_result.stdout.strip().lower()
    return True, value, value_type


def restore_pref(pref_domain: str, snapshot: tuple[bool, str, str]) -> bool:
    existed, value, value_type = snapshot
    if not existed:
        # The test guide explicitly asks to clear this test-only preference.
        run_defaults("delete", pref_domain, PREF_KEY)
        return run_defaults("read", pref_domain, PREF_KEY).returncode != 0
    if "boolean" in value_type:
        normalized = "true" if value.lower() in {"1", "true", "yes"} else "false"
        args = ("-bool", normalized)
    elif "integer" in value_type or "float" in value_type:
        args = ("-int", value)
    else:
        args = ("-string", value)
    return run_defaults("write", pref_domain, PREF_KEY, *args).returncode == 0


def write_fake_model(hub: pathlib.Path, repo_id: str) -> None:
    directory = hub / ("models--" + repo_id.replace("/", "--")) / "snapshots" / "fake"
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "config.json").write_text("{}", encoding="utf-8")
    (directory / "model.safetensors").touch()


def test_pids(state_dir: pathlib.Path) -> list[int]:
    needle = str(state_dir)
    return [pid for pid, command in psread.pid_command(("-ax", "-o", "pid=,command="))
            if needle in command and "--state-dir" in command and "/Contents/MacOS/Workbench" in command]


def stop_test_app(state_dir: pathlib.Path) -> bool:
    pids = test_pids(state_dir)
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 6
    while time.monotonic() < deadline and test_pids(state_dir):
        time.sleep(0.2)
    remaining = test_pids(state_dir)
    for pid in remaining:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    return not test_pids(state_dir)


def selected_model(value: object, repo_id: str) -> bool:
    if not isinstance(value, str):
        return False
    model_name = repo_id.split("/", 1)[1]
    return value == repo_id or value.endswith(repo_id) or model_name in value


def model_list_has(models: object, repo_id: str) -> bool:
    return isinstance(models, list) and any(selected_model(item, repo_id) for item in models)


def scenario(
    app: pathlib.Path,
    base: pathlib.Path,
    label: str,
    repo_id: str | None,
    pref_value: str,
    expected_route: str | None = None,
) -> tuple[bool, int]:
    work = base / label
    state = work / "state"
    hub = state / "hf" / "hub"
    compact = state / "compact-state"
    claude_home = state / ".claude"
    compact.mkdir(parents=True, exist_ok=True)
    claude_home.mkdir(parents=True, exist_ok=True)
    hub.mkdir(parents=True, exist_ok=True)
    if repo_id:
        write_fake_model(hub, repo_id)

    output = state / "model-selection.json"
    calls = state / "fake-agy-calls.txt"
    fake_agy = state / "fake-agy-counted"
    fake_agy.write_text(
        "#!/bin/sh\n"
        f"printf 'call\\n' >> {shlex.quote(str(calls))}\n"
        "exit 0\n",
        encoding="utf-8",
    )
    fake_agy.chmod(0o755)

    env = os.environ.copy()
    env["CODENV_COMPACT_DIR"] = str(compact)
    env["CODENV_POOL_USAGE_FILE"] = str(state / "pool-usage.json")
    command = [
        "/usr/bin/open", "-g", "-n", str(app), "--args",
        "--state-dir", str(state),
        "--claude-home", str(claude_home),
        "--background", "--test-screen", "ipad", "--test-hidden", "--usage-fake",
        "--agy-bin", str(fake_agy),
        "--hf-hub-cache-dir", str(hub),
        "--local-model-selection-probe", str(output),
        "--pref", f"archiveSummaryUseAgy={pref_value}",
        "--quit", "60",
        "-NSAppSleepDisabled", "YES", "-ApplePersistenceIgnoreState", "YES",
    ]
    opened = subprocess.run(command, env=env, capture_output=True, text=True, check=False)
    ok = True
    if opened.returncode != 0:
        report(f"{label} open -g 啟動測試實例", False, f"exit={opened.returncode}")
        return False, 0

    deadline = time.monotonic() + 50
    while time.monotonic() < deadline and not output.is_file():
        time.sleep(0.25)
    data: dict[str, object] = {}
    payload_valid = False
    if not output.is_file():
        report(f"{label} probe 輸出", False, "50 秒內未產生 JSON")
        ok = False
    else:
        try:
            parsed = json.loads(output.read_text(encoding="utf-8"))
            if isinstance(parsed, dict):
                data = parsed
                payload_valid = True
            else:
                report(f"{label} probe JSON", False, "輸出不是 JSON object")
                ok = False
        except (OSError, json.JSONDecodeError):
            report(f"{label} probe JSON", False, "輸出不存在或格式錯誤")
            ok = False

    stopped = stop_test_app(state)
    report(f"{label} 測試 App 已停止", stopped, f"殘留 PID={test_pids(state)}")
    ok &= stopped

    if payload_valid:
        no_mlx = data.get("mlxServerStarted") is False
        report(f"{label} 未啟動 MLX 伺服器", no_mlx, f"mlxServerStarted={data.get('mlxServerStarted')!r}")
        ok &= no_mlx
        if repo_id:
            default_ok = selected_model(data.get("defaultModel"), repo_id)
            summary_ok = selected_model(data.get("archiveSummaryModel"), repo_id)
            cached_models = data.get("cachedModels")
            cached_ok = model_list_has(cached_models, repo_id)
            only_expected_cached = (
                isinstance(cached_models, list)
                and len(cached_models) == 1
                and cached_ok
            )
            report(f"{label} defaultModel 選到預期模型", default_ok)
            report(f"{label} archiveSummaryModel 選到預期模型", summary_ok)
            report(f"{label} cachedModels 僅有預期模型", only_expected_cached)
            ok &= default_ok and summary_ok and only_expected_cached
        else:
            empty_ok = data.get("cachedModels") == []
            route_ok = data.get("archiveSummaryRoute") == expected_route
            report(f"{label} 快取為空", empty_ok, f"cachedModels={data.get('cachedModels')!r}")
            report(f"{label} archiveSummaryRoute={expected_route}", route_ok, f"實際={data.get('archiveSummaryRoute')!r}")
            ok &= empty_ok and route_ok

    call_count = len(calls.read_text(encoding="utf-8").splitlines()) if calls.exists() else 0
    no_agy = call_count == 0
    report(f"{label} selection probe 未呼叫假 agy", no_agy, f"呼叫次數={call_count}")
    ok &= no_agy
    return ok, call_count


def main() -> int:
    if len(sys.argv) != 3:
        print("用法：local-model-0700m-probe.py <codenv-test.app> <暫存根目錄>", file=sys.stderr)
        return 2
    app = pathlib.Path(sys.argv[1]).resolve()
    base = pathlib.Path(sys.argv[2]).resolve() / "c184-local-model"
    base.mkdir(parents=True, exist_ok=True)
    if not (app / "Contents" / "MacOS" / "Workbench").is_file():
        print(f"找不到測試 App 可執行檔：{app}", file=sys.stderr)
        return 2

    overall = True
    cases = [
        ("bolt-only", BOLT, "unset", None),
        ("qwen-only", QWEN, "unset", None),
        ("empty-default-hydrogen", None, "unset", "hydrogen"),
        ("empty-disabled-queue", None, "0", "queued"),
    ]
    for label, repo_id, pref_value, route in cases:
        state = base / label / "state"
        pref_domain = test_pref_domain(state)
        pref_snapshot = snapshot_pref(pref_domain)
        passed = False
        try:
            passed, _ = scenario(app, base, label, repo_id, pref_value, route)
        finally:
            restored = restore_pref(pref_domain, pref_snapshot)
            report(f"{label} 測試偏好 archiveSummaryUseAgy 已還原", restored)
            overall &= restored
        overall &= passed

    report("C184 全部驗收項目", overall)
    return 0 if overall else 1


if __name__ == "__main__":
    raise SystemExit(main())
