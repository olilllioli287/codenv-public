#!/usr/bin/env python3
"""隔離測試 codenv-todo 在看板檔與 agy 故障下的行為。"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

SCRIPT = Path(__file__).with_name("codenv-todo").resolve()
TIMEOUT = 12


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def run(root, command, collab=None, agy=None, extra=None, timeout=TIMEOUT):
    env = os.environ.copy()
    env["CODENV_COLLAB_FILE"] = str(collab or (root / "collab.json"))
    env["CODENV_AGY_PET_SAY"] = "/usr/bin/true"
    env["CODENV_AGY_IDLE"] = "0"
    env["CODENV_AGY_RETRY"] = "1"
    env["CODENV_AGY_CHECK_HOST"] = "invalid.invalid"
    if agy is not None:
        env["CODENV_AGY"] = str(agy)
    if extra:
        env.update({k: str(v) for k, v in extra.items()})
    try:
        invocation = [sys.executable, str(SCRIPT), *command]
        return subprocess.run(invocation, cwd=root, env=env,
                              capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as e:
        raise AssertionError("子命令逾時：%s；stdout=%r stderr=%r" % (command, e.stdout, e.stderr))


def clean_result(proc, label, expected_fail=False):
    output = (proc.stdout or "") + (proc.stderr or "")
    require("Traceback (most recent call last)" not in output, label + " 印出 Python traceback")
    require(proc.returncode >= 0, label + " 被 signal 終止")
    if expected_fail:
        require(proc.returncode != 0, label + " 預期失敗但回傳成功")
        require(output.strip(), label + " 失敗時沒有可讀訊息")
    return output


def corrupt_case(root, label, payload, command):
    path = root / "collab.json"
    path.write_bytes(payload)
    before = path.read_bytes()
    p = run(root, command)
    output = clean_result(p, label, expected_fail=True)
    require(path.read_bytes() == before, label + " 改動了壞檔原始 bytes")
    require(any(word in output.lower() for word in ("collab", "看板", "json", "格式", "讀不了", "空檔")),
            label + " 沒有看得懂的看板/格式錯誤")
    print("PASS " + label)


def valid_board(path, state="todo"):
    data = {"items": [], "goals": [{"id": "goal01", "title": "fault test", "status": "active",
        "steps": [{"id": "a1b2c3", "text": "test agy", "owner": "gemini3.8flash", "state": state, "attempt": 1}]}]}
    path.write_text(json.dumps(data), encoding="utf-8")
    return data


def main():
    with tempfile.TemporaryDirectory(prefix="codenv-faults-") as td:
        root = Path(td)
        corrupt_case(root, "collab 空檔（goal ls）", b"", ["goal", "ls"])
        corrupt_case(root, "collab 截斷 JSON（step add）", b'{"goals": [{"id": "g1",',
                     ["step", "add", "goal01", "extra"])
        corrupt_case(root, "collab 非 JSON（goal ls）", b"not json\x00", ["goal", "ls"])

        path = root / "collab.json"
        path.unlink(missing_ok=True)
        p = run(root, ["goal", "ls"])
        output = clean_result(p, "collab 檔案不存在")
        require(p.returncode == 0 and "Traceback" not in output, "不存在的檔案應當作空看板")
        p = run(root, ["step", "add", "missing", "x"])
        output = clean_result(p, "不存在檔案時 step add", expected_fail=True)
        require("找不到目標" in output, "不存在看板的新增命令應明確說找不到目標")
        print("PASS collab 檔案不存在")

        # 空的殘留鎖檔應可取得；另驗證持鎖程序退出後可恢復，不等待超時。
        path.write_text('{"items": [], "goals": []}', encoding="utf-8")
        lock = Path(str(path) + ".lock")
        lock.write_bytes(b"stale lock\x00")
        p = run(root, ["add", "登記", "lock test"])
        output = clean_result(p, "殘留鎖檔")
        require(p.returncode == 0 and "Traceback" not in output, "殘留鎖檔導致寫入失敗")
        require(json.loads(path.read_text())["items"], "殘留鎖檔後沒有完成看板寫入")
        print("PASS 鎖檔殘留")


# 跑執行器用的小程式：用 SourceFileLoader 載入 codenv-todo 成模組，改模組裡的常數才真的生效
# （runpy.run_path 回傳的是副本，改了不影響函式）；online() 換成永遠連得上，不碰網路
RUNNER = """
import importlib.machinery, importlib.util, json, os, sys
loader = importlib.machinery.SourceFileLoader("todo_runner", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
def no_network(*a, **k):
    raise AssertionError("測試禁止網路")
m.urllib.request.urlopen = no_network
m.online = lambda: True
for k, v in json.loads(os.environ.get("FAULT_OVERRIDES") or "{}").items():
    setattr(m, k, v)
m.AgyRunner().main()
"""


def start_runner(root, agy, overrides=None):
    env = os.environ.copy()
    env.update({"CODENV_COLLAB_FILE": str(root / "collab.json"), "CODENV_AGY_PET_SAY": "/usr/bin/true",
                "CODENV_AGY_IDLE": "1", "CODENV_AGY_RETRY": "60", "CODENV_AGY": str(agy),
                "FAULT_OVERRIDES": json.dumps(overrides or {})})
    runner = root / "runner.py"
    runner.write_text(RUNNER, encoding="utf-8")
    return subprocess.Popen([sys.executable, str(runner), str(SCRIPT)], cwd=root, env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)


def wait_step(root, proc, ok, limit):
    """等到步驟狀態符合 ok() 或逾時；最後一定停掉執行器（整個程序群組）"""
    end = time.time() + limit
    st = None
    try:
        while time.time() < end:
            try:
                st = json.loads((root / "collab.json").read_text())["goals"][0]["steps"][0]
                if ok(st):
                    break
            except (ValueError, OSError):
                pass
            if proc.poll() is not None and not (st and ok(st)):
                time.sleep(0.2)
            time.sleep(0.2)
    finally:
        if proc.poll() is None:
            os.killpg(proc.pid, 15)
        out = proc.communicate(timeout=10)[0] or ""
    require("Traceback (most recent call last)" not in out, "執行器印出 traceback：" + out[-800:])
    return st, out


def fake_agy(root, name, body):
    f = root / name
    f.write_text("#!/bin/sh\n" + body, encoding="utf-8")
    f.chmod(0o755)
    return f


def agy_cases(root):
    def fresh(name):
        d = root / name
        d.mkdir()
        valid_board(d / "collab.json")
        return d

    # agy 路徑不存在：步驟標卡住並說開不了
    d = fresh("agy-missing")
    st, out = wait_step(d, start_runner(d, d / "does-not-exist-agy"), lambda s: s["state"] != "todo" and s["state"] != "doing", 20)
    require(st["state"] == "blocked" and "開不了 agy" in (st.get("note") or ""), "agy 不存在沒有標成卡住：%r" % st)
    print("PASS agy 路徑不存在")

    # agy 卡住不退出：把時限縮成 3 秒（PRINT_TIMEOUT + 120 = 3），執行器要強制停掉並標卡住
    d = fresh("agy-hang")
    hang = fake_agy(d, "fake-agy-hang", "sleep 300\n")
    st, out = wait_step(d, start_runner(d, hang, {"PRINT_TIMEOUT": -117}), lambda s: s["state"] == "blocked", 30)
    require(st and st["state"] == "blocked" and "強制停掉" in (st.get("note") or ""), "agy 卡住沒有被強制停掉標卡住：%r\n%s" % (st, out[-600:]))
    left = subprocess.run(["pgrep", "-f", str(hang)], capture_output=True, text=True).stdout.strip()
    require(not left, "強制停掉後假 agy 還在跑：" + left)
    print("PASS agy 卡住逾時（強制停掉、沒有殘留程序）")

    # edit 模式想跑指令被擋、沒有輸出：卡住，而且說明要寫 edit 模式（不是 read 模式的放行清單）
    d = root / "agy-edit-denied"
    d.mkdir()
    data = valid_board(d / "collab.json")
    data["goals"][0]["steps"][0]["mode"] = "edit"
    (d / "collab.json").write_text(json.dumps(data), encoding="utf-8")
    deny = fake_agy(d, "fake-agy-deny", "echo 'tool permission auto-denied: RunCommand' >&2\nexit 0\n")
    st, out = wait_step(d, start_runner(d, deny), lambda s: s["state"] == "blocked", 20)
    require(st and "edit 模式" in (st.get("note") or ""), "edit 模式被擋的說明不對：%r" % st)
    print("PASS agy edit 模式工具被擋")

    # agy 回額度用完：退回待做、記 quotaBack、建 pause.json、計數退還
    # （退回時故意不改 note，免得蓋掉 Claude 寫的退回原因；暫停原因在 pause.json／agy-status）
    d = fresh("agy-quota")
    runs = d / "agy-runs"
    runs.mkdir()
    today = time.strftime("%Y-%m-%d")
    (runs / "count.json").write_text(json.dumps({"date": today, "counts": {"gemini3.8flash": 1}, "noticed": []}), encoding="utf-8")
    quota = fake_agy(d, "fake-agy-quota", "echo 'RESOURCE_EXHAUSTED: quota exhausted' >&2\nexit 1\n")
    st, out = wait_step(d, start_runner(d, quota), lambda s: s["state"] == "todo" and s.get("quotaBack") == 1, 20)
    require(st and st["state"] == "todo" and st.get("quotaBack") == 1, "額度用完沒有退回待做並記 quotaBack：%r\n%s" % (st, out[-600:]))
    pause = json.loads((runs / "pause.json").read_text())
    require("額度" in pause.get("reason", ""), "pause.json 原因沒寫額度：%r" % pause)
    n = json.loads((runs / "count.json").read_text())["counts"].get("gemini3.8flash")
    require(n == 1, "額度用完那次的計數沒有退還（應回到 1，實際 %r）" % n)
    print("PASS agy 額度用完")

    # 執行中換負責人（轉手動／換模型）：執行器要停掉 agy、不能把步驟標完成；agy 底下忽略 SIGTERM 的子程序也要整群清掉（Codex 11/6）
    d = fresh("agy-owner-change")
    stubborn = fake_agy(d, "fake-agy-stubborn", "(trap '' TERM; exec sleep 307) &\nsleep 1\nwait\n")
    proc = start_runner(d, stubborn)
    end = time.time() + 20
    while time.time() < end:
        try:
            if json.loads((d / "collab.json").read_text())["goals"][0]["steps"][0]["state"] == "doing":
                break
        except (ValueError, OSError):
            pass
        time.sleep(0.2)
    time.sleep(1.5)
    data = json.loads((d / "collab.json").read_text())
    data["goals"][0]["steps"][0]["owner"] = "手動flash"
    (d / "collab.json").write_text(json.dumps(data), encoding="utf-8")
    time.sleep(12)      # 每 3 秒檢查一次＋SIGTERM 寬限 5 秒
    # 不用 pgrep：遇到非 ASCII 的程序參數會報錯回空字串，等於沒檢查就算通過
    ps = subprocess.run(["ps", "-ax", "-o", "pid=,command="], capture_output=True, text=True, errors="replace").stdout
    left = "\n".join(l for l in ps.splitlines() if l.strip().split(None, 1)[1:] == ["sleep 307"])   # 整個指令就是它（不要比到自己的 shell 指令）
    st, out = wait_step(d, proc, lambda s: True, 1)
    require(not left, "換負責人後忽略 SIGTERM 的子程序還在：" + left)
    require(st and st["state"] != "done" and st.get("owner") == "手動flash", "換負責人後舊的結果寫回或蓋掉負責人：%r\n%s" % (st, out[-600:]))
    require("換了負責人" in out or "停掉 agy" in out, "執行器沒有因為換負責人停掉 agy：\n" + out[-600:])
    print("PASS 執行中換負責人（停掉 agy、整群清掉、不寫回）")


if __name__ == "__main__":
    try:
        main()
        with tempfile.TemporaryDirectory(prefix="codenv-faults-agy-") as td:
            agy_cases(Path(td))
        print("全部通過")
    except Exception as exc:
        print("FAIL: " + str(exc), file=sys.stderr)
        sys.exit(1)
