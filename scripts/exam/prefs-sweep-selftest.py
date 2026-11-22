#!/usr/bin/env python3
"""Self-test prefs-sweep using only disposable fake Preferences directories."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import textwrap
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SWEEPER = ROOT / "scripts" / "exam" / "prefs-sweep"


def require(ok: bool, message: str) -> None:
    if not ok:
        raise AssertionError(message)


def start(prefs: Path, session_dir: Path) -> dict[str, str]:
    env = {**os.environ, "EXAM_PREFS_DIR": str(prefs)}
    result = subprocess.run([str(SWEEPER), "begin", str(session_dir)], env=env,
                            text=True, capture_output=True)
    require(result.returncode == 0, f"prefs-sweep begin 失敗：{result.stdout}{result.stderr}")
    return env


def end(prefs: Path, session_dir: Path, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run([str(SWEEPER), "end", str(session_dir)],
                          env={**env, "EXAM_PREFS_DIR": str(prefs)}, text=True, capture_output=True)


def run_wrapped(prefs: Path, env: dict[str, str], code: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run([str(SWEEPER), "--", sys.executable, "-c", textwrap.dedent(code)],
                          env={**env, "EXAM_PREFS_DIR": str(prefs)}, text=True, capture_output=True)


def write_file(path: Path, content: str = "fixture\n") -> None:
    path.write_text(content, encoding="utf-8")


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="codenv-pref-sweep-selftest-") as temp_dir:
        temp = Path(temp_dir)

        prefs = temp / "Preferences-safe"
        prefs.mkdir()
        old_suite = prefs / ("com.local.aiworkbench.test." + "a" * 32 + ".plist")
        old_lid = prefs / "codenv.lid-interrupt-probe.old-id.plist"
        write_file(old_suite, "old suite\n")
        write_file(old_lid, "old lid\n")
        old_ns = time.time_ns() - 5_000_000_000
        os.utime(old_suite, ns=(old_ns, old_ns))
        os.utime(old_lid, ns=(old_ns, old_ns))

        protected_names = [
            "com.local.aiworkbench.plist",
            "com.local.aiworkbench.test.plist",
            "io.github.olilllioli287.codenv.test.plist",
            "codenv-settings.plist",
            "unrelated.plist",
            "codenv.lid-interrupt-probe.plist",
            "com.local.aiworkbench.test." + "b" * 31 + ".plist",
        ]
        protected = {}
        for name in protected_names:
            path = prefs / name
            write_file(path, f"protected:{name}\n")
            protected[name] = path.read_bytes()

        rejected = subprocess.run([str(SWEEPER), "begin", str(prefs)],
                                  env={**os.environ, "EXAM_PREFS_DIR": str(prefs)},
                                  text=True, capture_output=True)
        require(rejected.returncode != 0, "Preferences 目錄不可作為 session 目錄")
        require("不可放在 Preferences 目錄內" in rejected.stderr, rejected.stderr)
        require(not (prefs / ".prefs-sweep-start").exists()
                and not (prefs / ".prefs-sweep-baseline.json").exists(),
                "拒絕 Preferences session 路徑時不得建立標記或基準")

        session = temp / "safe-run"
        env = start(prefs, session)
        baseline = json.loads((session / ".prefs-sweep-baseline.json").read_text(encoding="utf-8"))
        require(baseline["startCount"] == 2 and set(baseline["startFiles"]) == {old_suite.name, old_lid.name},
                f"基準清單／數量錯誤：{baseline}")
        time.sleep(0.03)
        new_suite = prefs / ("com.local.aiworkbench.test." + "c" * 32 + ".plist")
        new_lid = prefs / "codenv.lid-interrupt-probe.123e4567-e89b.plist"
        write_file(new_suite, "new suite\n")
        write_file(new_lid, "new lid\n")
        cleaned = end(prefs, session, env)
        require(cleaned.returncode == 0, f"兩段式清掃應成功：{cleaned.stdout}{cleaned.stderr}")
        require("測試偏好 plist：開始 2、結束 2" in cleaned.stdout, cleaned.stdout)
        require(not new_suite.exists() and not new_lid.exists(), "兩種符合名稱且較新的 plist 都應刪除")
        require(old_suite.is_file() and old_lid.is_file(), "起點前的符合名稱 plist 必須保留")
        require(all((prefs / name).read_bytes() == value for name, value in protected.items()),
                "不符合名稱的 plist 必須原樣保留")

        prefs_over = temp / "Preferences-over-limit"
        prefs_over.mkdir()
        old_baseline = prefs_over / ("com.local.aiworkbench.test." + "d" * 32 + ".plist")
        write_file(old_baseline, "baseline\n")
        os.utime(old_baseline, ns=(old_ns, old_ns))
        session_over = temp / "over-run"
        env_over = start(prefs_over, session_over)
        stale_added = prefs_over / ("com.local.aiworkbench.test." + "e" * 32 + ".plist")
        write_file(stale_added, "stale added\n")
        stale_ns = time.time_ns() - 5_000_000_000
        os.utime(stale_added, ns=(stale_ns, stale_ns))
        external = temp / "outside-target.plist"
        write_file(external, "outside target\n")
        unsafe_link = prefs_over / "codenv.lid-interrupt-probe.symlink.plist"
        unsafe_link.symlink_to(external)
        over = end(prefs_over, session_over, env_over)
        require(over.returncode != 0, "兩段式情境數量超過基準必須失敗")
        require("錯誤：考卷後測試偏好 plist 增加 2 個：" in over.stdout, over.stdout)
        require(stale_added.is_file(), "修改時間早於標記的新增檔不得刪除")
        require(unsafe_link.is_symlink() and external.is_file(), "符號連結與 Preferences 外目標都不得刪除")

        prefs_wrapped = temp / "Preferences-wrapped"
        prefs_wrapped.mkdir()
        env_wrapped = {**os.environ, "EXAM_PREFS_DIR": str(prefs_wrapped)}
        wrapped_ok = run_wrapped(prefs_wrapped, env_wrapped, """
            from pathlib import Path
            import os, time
            root = Path(os.environ["EXAM_PREFS_DIR"])
            (root / ("com.local.aiworkbench.test." + "f" * 32 + ".plist")).write_text("suite")
            (root / "codenv.lid-interrupt-probe.wrapped.plist").write_text("lid")
        """)
        require(wrapped_ok.returncode == 0, f"-- 包指令應成功：{wrapped_ok.stdout}{wrapped_ok.stderr}")
        require("測試偏好 plist：開始 0、結束 0" in wrapped_ok.stdout, wrapped_ok.stdout)
        require(not any(prefs_wrapped.iterdir()), "-- 成功指令後的新測試 plist 應清除")

        wrapped_failure = run_wrapped(prefs_wrapped, env_wrapped, """
            from pathlib import Path
            import os, sys
            root = Path(os.environ["EXAM_PREFS_DIR"])
            (root / ("com.local.aiworkbench.test." + "1" * 32 + ".plist")).write_text("failure")
            raise SystemExit(7)
        """)
        require(wrapped_failure.returncode == 7, f"-- 失敗指令要保留原結束碼：{wrapped_failure.returncode}")
        require("測試偏好 plist：開始 0、結束 0" in wrapped_failure.stdout, wrapped_failure.stdout)
        require(not any(prefs_wrapped.iterdir()), "-- 失敗指令後仍須清除新測試 plist")

        wrapped_over = run_wrapped(prefs_wrapped, env_wrapped, """
            from pathlib import Path
            import os, time
            root = Path(os.environ["EXAM_PREFS_DIR"])
            path = root / ("com.local.aiworkbench.test." + "2" * 32 + ".plist")
            path.write_text("stale")
            old = time.time() - 5
            os.utime(path, (old, old))
        """)
        require(wrapped_over.returncode != 0, "-- 結束數超過起點時必須回傳非零")
        require("錯誤：考卷後測試偏好 plist 增加 1 個：" in wrapped_over.stdout, wrapped_over.stdout)

    print("通過：prefs-sweep 兩段式與指令包裝、拒絕 Preferences session 路徑、成功／失敗清理、精確篩選、符號連結保護及超量錯誤")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"失敗：{error}", file=sys.stderr)
        raise
