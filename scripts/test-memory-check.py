#!/usr/bin/env python3
"""memory-check 的離線測試：用暫存假資料夾，確認超過上限會報、沒超過不報、而且絕不改任何檔。"""
import hashlib, json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "memory-check")

def snapshot(root):
    h = hashlib.sha256()
    for d, _, fs in sorted(os.walk(root)):
        for f in sorted(fs):
            p = os.path.join(d, f)
            h.update(p.encode()); h.update(open(p, "rb").read())
    return h.hexdigest()

def run(root, *extra):
    r = subprocess.run([sys.executable, "-I", TOOL, "--root", root, *extra], capture_output=True, text=True)
    return r.returncode, r.stdout

def check(name, ok):
    print(("通過：" if ok else "失敗：") + name)
    return ok

with tempfile.TemporaryDirectory() as root:
    m = os.path.join(root, "proj-a", "memory"); os.makedirs(m)
    open(os.path.join(m, "MEMORY.md"), "w").write("- [小](small.md) — 小檔\n- [大](big.md) — 大檔\n- [沒檔](gone.md) — 不存在\n")
    open(os.path.join(m, "small.md"), "w").write("---\nname: small\nreview_by: 2020-01-01\n---\n一件事\n")
    open(os.path.join(m, "big.md"), "w").write("---\nname: big\n---\n" + "".join("- 第 %d 條 流水帳資料資料資料\n" % i for i in range(600)))
    os.makedirs(os.path.join(root, "proj-empty", "memory"))   # 空的 memory 資料夾不能報錯
    before = snapshot(root)
    ok = True
    code, out = run(root)
    ok &= check("太大的檔會報（結束碼 1）", code == 1 and "big.md" in out and "archive/" in out)
    ok &= check("review_by 過期會列出、壞連結會列出", "small.md（2020-01-01）" in out and "gone.md" in out)
    code, out = run(root, "--json", "--quiet-ok")
    j = json.loads(out)
    ok &= check("JSON 有 over 與 oversized", j["over"] is True and j["results"][0]["oversized"][0]["file"] == "big.md")
    code, out = run(root, "--file-kb", "1000", "--quiet-ok")
    ok &= check("上限放寬後不印任何東西（結束碼 0）", code == 0 and out == "")
    code, out = run(root, "--index-kb", "0.01", "--file-kb", "1000")
    ok &= check("索引超過上限也會報", code == 1 and "MEMORY.md" in out)
    code, _ = run(os.path.join(root, "不存在"))
    ok &= check("資料夾不存在結束碼 2", code == 2)
    ok &= check("全程沒有改任何檔", snapshot(root) == before)
    sys.exit(0 if ok else 1)
