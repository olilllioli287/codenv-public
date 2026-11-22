#!/usr/bin/env python3
"""C218–C225：rc-0700r 審查修正 A 回歸（看板審查、handoff-prep）。

只用規格、與公開介面（codenv-todo 的 review-probe 環境變數、handoff-prep 的 CLI 與
CODENV_STATE_DIR／CODENV_TEST_*_BIN）出題；不讀 Sources。全部使用 /private/tmp 底下的暫存 collab.json、
暫存 git repo 與假 agy／假 codex，不碰正式資料、不開 App。
用法：board-handoff-0700r-probe.py <C218..C225> <repo 根目錄>
"""
import datetime
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

GIT_ENV = {"GIT_AUTHOR_NAME": "Exam", "GIT_AUTHOR_EMAIL": "exam@example.test",
           "GIT_COMMITTER_NAME": "Exam", "GIT_COMMITTER_EMAIL": "exam@example.test"}


class Base:
    cid = ""

    def __init__(self, root):
        self.root = pathlib.Path(root)
        self.cli = self.root / "scripts/codenv-todo"
        self.handoff = self.root / "scripts/handoff-prep"
        self.temp = pathlib.Path(tempfile.mkdtemp(prefix=f"codenv-exam-{self.cid.lower()}.", dir="/private/tmp"))
        self.failures = 0
        print(f"{self.cid} 暫存資料夾：{self.temp}")

    def finish(self):
        print(f"{self.cid} 斷言失敗數：{self.failures}")
        shutil.rmtree(self.temp, ignore_errors=True)
        return 1 if self.failures else 0

    def check(self, label, actual, expected):
        ok = actual == expected
        print(f"  {'通過' if ok else '失敗'}：{label}（預期 {expected!r}，實際 {actual!r}）")
        if not ok:
            self.failures += 1
        return ok

    def true(self, label, value):
        return self.check(label, bool(value), True)

    def git(self, repo, *args):
        env = dict(os.environ, **GIT_ENV)
        return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True, env=env).stdout.strip()

    def make_repo(self, name):
        repo = self.temp / name / "repo"
        repo.mkdir(parents=True)
        subprocess.run(["git", "init", "-q", "-b", "main", str(repo)], check=True, capture_output=True)
        (repo / "tracked.txt").write_text("baseline\n", encoding="utf-8")
        self.git(repo, "add", "tracked.txt")
        self.git(repo, "commit", "-q", "-m", "基準")
        return repo, self.git(repo, "rev-parse", "HEAD")


class Board(Base):
    """看板審查：全部走隔離 collab.json 與 review-probe 環境變數。"""

    def write_collab(self, name, steps):
        path = self.temp / name / "collab.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        data = {"items": [], "goals": [{"id": "g-" + self.cid.lower(), "title": f"{self.cid} 合成目標", "status": "active", "steps": steps}]}
        path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        return path.resolve()

    @staticmethod
    def step(sid, text="一般施工步驟", state="doing", owner="codenv_worker", **extra):
        d = {"id": sid, "text": text, "state": state, "owner": owner, "rejectCount": 0}
        d.update(extra)
        return d

    def call(self, collab, args, fake=None, enabled=None, cwd=None):
        env = dict(os.environ, CODENV_REVIEW_PROBE="1", CODENV_COLLAB_FILE=str(collab))
        for key in ("CODENV_REVIEW_FAKE_RESULT", "CODENV_REVIEW_ENABLED", "CODENV_BROWSER_DIR", "CODENV_STATE_DIR"):
            env.pop(key, None)
        if fake:
            env["CODENV_REVIEW_FAKE_RESULT"] = fake
        if enabled is not None:
            env["CODENV_REVIEW_ENABLED"] = enabled
        return subprocess.run([str(self.cli), *args], cwd=cwd or self.root, env=env, capture_output=True, text=True, timeout=30)

    def status(self, collab, sid):
        r = self.call(collab, ["review-probe", "status", sid])
        try:
            return json.loads(r.stdout)
        except json.JSONDecodeError:
            print(f"  status 輸出不是 JSON：stdout={r.stdout!r} stderr={r.stderr!r}")
            return {}

    def raw_step(self, collab, sid):
        data = json.loads(pathlib.Path(collab).read_text(encoding="utf-8"))
        for goal in data["goals"]:
            for st in goal["steps"]:
                if st["id"] == sid:
                    return st
        return {}

    def settle(self, collab, sid, limit=10):
        st = self.status(collab, sid)
        end = time.monotonic() + limit
        while st.get("state") == "reviewing" and time.monotonic() < end:
            time.sleep(0.25)
            st = self.status(collab, sid)
        return st

    def work_cycle(self, collab, repo, sid, fake, line, in_repo=False):
        """施工流程：進行中（記基準）→ 改檔 → 完成（送審）。回傳審查結束後的 status。"""
        # in_repo：CLI 的工作目錄換成暫存 repo，不依賴考卷樹本身的 git 狀態（出版時考卷樹在乾淨的 main 上、沒有 diff）
        cwd = repo if in_repo else None
        self.call(collab, ["step", sid, "進行中"], cwd=cwd)
        with open(repo / "tracked.txt", "a", encoding="utf-8") as f:
            f.write(line + "\n")
        r = self.call(collab, ["step", sid, "完成"], fake=fake, enabled="1", cwd=cwd)
        return r, self.settle(collab, sid)


class C218(Board):
    cid = "C218"

    def run(self):
        # 規格 07-3：「專案有對應 git 變更」才進審查。施工方 11/11：沒有可審查的 diff 時不再悄悄放行，要明確提示並記備註。
        repo, base = self.make_repo("clean")
        collab = self.write_collab("clean", [self.step("s1", reviewDir=str(repo), reviewBase=base)])
        r = self.call(collab, ["step", "s1", "完成"], fake="ERROR", enabled="1")
        self.check("沒有 diff：exit code", r.returncode, 0)
        self.check("沒有 diff：沒有送阿公審查", "已送阿公審查" in r.stdout + r.stderr, False)
        self.true("沒有 diff：明確提示（stdout 或 stderr 非空）", (r.stdout + r.stderr).strip())
        st = self.status(collab, "s1")
        self.check("沒有 diff：步驟直接完成（沿用 07-3，不卡住）", st.get("state"), "done")
        self.check("沒有 diff：不增加退回次數", st.get("rejectCount"), 0)
        self.true("沒有 diff：步驟備註記下「未送審」", "未送審" in str(self.raw_step(collab, "s1").get("note", "")))

        plain = self.temp / "plain"
        plain.mkdir()
        collab = self.write_collab("plain", [self.step("s2", reviewDir=str(plain))])
        r = self.call(collab, ["step", "s2", "完成"], fake="ERROR", enabled="1")
        self.check("非 git 資料夾：沒有送阿公審查", "已送阿公審查" in r.stdout + r.stderr, False)
        self.true("非 git 資料夾：明確提示", (r.stdout + r.stderr).strip())
        self.check("非 git 資料夾：步驟完成", self.status(collab, "s2").get("state"), "done")
        self.true("非 git 資料夾：備註記下「未送審」", "未送審" in str(self.raw_step(collab, "s2").get("note", "")))

        # worktree 派工後施工方會 commit：沒存基準（沒經過「進行中」）時，仍要看得到分支上的變更。
        repo, _ = self.make_repo("branch")
        self.git(repo, "checkout", "-q", "-b", "feat-x")
        (repo / "tracked.txt").write_text("分支上已 commit 的變更\n", encoding="utf-8")
        self.git(repo, "commit", "-q", "-am", "分支變更")
        collab = self.write_collab("branch", [self.step("s3", reviewDir=str(repo))])
        r = self.call(collab, ["step", "s3", "完成"], fake="PASS", enabled="1")
        self.true("分支已 commit、沒存基準：仍送審（推論：施工方結果檔描述改用跟 main 的分岔點）", "已送阿公審查" in r.stdout)
        self.check("分支已 commit：假 PASS 後完成", self.settle(collab, "s3").get("state"), "done")

        repo, _ = self.make_repo("onmain")
        collab = self.write_collab("onmain", [self.step("s4", reviewDir=str(repo))])
        r = self.call(collab, ["step", "s4", "完成"], fake="PASS", enabled="1")
        self.check("在 main 上沒變更、沒存基準：不送審", "已送阿公審查" in r.stdout, False)
        self.check("在 main 上沒變更：步驟完成", self.status(collab, "s4").get("state"), "done")
        return self.finish()


def iso(minutes_ago):
    t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=minutes_ago)
    return t.strftime("%Y-%m-%dT%H:%M:%S.") + f"{t.microsecond // 1000:03d}Z"


class C219(Board):
    cid = "C219"

    def run(self):
        # 施工方 11/11：reviewing 超過 35 分鐘自動收回 doing（不計退回次數）。35 分鐘為其結果檔所述數值（規格 07-3 沒寫逾時，標推論）。
        repo, _ = self.make_repo("stale")
        steps = [
            self.step("s-old", state="reviewing", rejectCount=1, reviewDir=str(repo), reviewID="exam-old", reviewStartedAt=iso(40)),
            self.step("s-edge-over", state="reviewing", reviewDir=str(repo), reviewID="exam-over", reviewStartedAt=iso(37)),
            self.step("s-edge-under", state="reviewing", reviewDir=str(repo), reviewID="exam-under", reviewStartedAt=iso(33)),
            self.step("s-young", state="reviewing", reviewDir=str(repo), reviewID="exam-young", reviewStartedAt=iso(5)),
            self.step("s-other", state="todo"),
        ]
        collab = self.write_collab("stale", steps)
        r = self.call(collab, ["goal", "ls"])
        self.check("goal ls exit code", r.returncode, 0)
        old = self.status(collab, "s-old")
        self.check("40 分鐘前開始的 reviewing 被收回 doing", old.get("state"), "doing")
        self.check("收回不計退回次數（維持原 1）", old.get("rejectCount"), 1)
        self.check("收回不要求使用者介入", old.get("needsUser"), False)
        self.true("收回有備註說明", str(old.get("note", "")).strip())
        self.check("37 分鐘（超過 35）被收回", self.status(collab, "s-edge-over").get("state"), "doing")
        self.check("33 分鐘（未超過 35）維持 reviewing", self.status(collab, "s-edge-under").get("state"), "reviewing")
        self.check("5 分鐘維持 reviewing", self.status(collab, "s-young").get("state"), "reviewing")

        collab = self.write_collab("stale2", [
            self.step("t-old", state="reviewing", reviewDir=str(repo), reviewID="exam-old2", reviewStartedAt=iso(60)),
            self.step("t-other", state="todo")])
        self.call(collab, ["step", "t-other", "進行中"])
        self.check("step 指令也會回收逾時 reviewing", self.status(collab, "t-old").get("state"), "doing")

        with open(repo / "tracked.txt", "a", encoding="utf-8") as f:
            f.write("收回後的新變更\n")
        collab = self.write_collab("stale3", [
            self.step("u-old", state="reviewing", reviewDir=str(repo), reviewID="exam-old3", reviewStartedAt=iso(50),
                      reviewBase=self.git(repo, "rev-parse", "HEAD"))])
        self.call(collab, ["goal", "ls"])
        with open(repo / "tracked.txt", "a", encoding="utf-8") as f:
            f.write("收回後再改一行\n")
        r = self.call(collab, ["step", "u-old", "完成"], fake="PASS", enabled="1")
        self.true("收回後可重新送審", "已送阿公審查" in r.stdout)
        self.check("重新送審後完成", self.settle(collab, "u-old").get("state"), "done")
        return self.finish()


class C220(Board):
    cid = "C220"

    def reject_to_blocked(self, collab, sid):
        for n in range(1, 5):
            self.call(collab, ["review-probe", sid, "submit"])
            self.call(collab, ["review-probe", sid, "REJECT", "--note", f"缺少驗收證據 {n}"])

    def run(self):
        # 規格 07-3：退回超過 3 次標需要使用者（第 4 次）。施工方 11/11：使用者放行（改回進行中／待做）後 rejectCount 歸零。
        collab = self.write_collab("release", [self.step("s1"), self.step("s2")])
        self.reject_to_blocked(collab, "s1")
        st = self.status(collab, "s1")
        self.check("前置：第 4 次退回 blocked", st.get("state"), "blocked")
        self.check("前置：rejectCount=4", st.get("rejectCount"), 4)
        self.check("前置：needsUser", st.get("needsUser"), True)
        self.call(collab, ["step", "s1", "進行中"])
        st = self.status(collab, "s1")
        self.check("使用者放行（進行中）：狀態 doing", st.get("state"), "doing")
        self.check("使用者放行：rejectCount 歸零", st.get("rejectCount"), 0)
        self.check("使用者放行：needsUser 解除", st.get("needsUser"), False)
        self.call(collab, ["review-probe", "s1", "submit"])
        self.call(collab, ["review-probe", "s1", "REJECT", "--note", "放行後的退回"])
        st = self.status(collab, "s1")
        self.check("放行後再退回一次：仍是 doing（不會立刻又 blocked）", st.get("state"), "doing")
        self.check("放行後再退回一次：次數從 1 起算", st.get("rejectCount"), 1)

        self.reject_to_blocked(collab, "s2")
        self.call(collab, ["step", "s2", "待做"])
        st = self.status(collab, "s2")
        self.check("放行成「待做」：狀態 todo", st.get("state"), "todo")
        self.check("放行成「待做」：rejectCount 歸零", st.get("rejectCount"), 0)

        # 負向對照（推論）：不是「要使用者：」造成的卡住，不該被歸零。
        collab = self.write_collab("manual", [self.step("m1", rejectCount=2)])
        self.call(collab, ["step", "m1", "卡住"])
        self.call(collab, ["step", "m1", "進行中"])
        self.check("一般手動卡住再進行中：rejectCount 不被歸零（推論）", self.status(collab, "m1").get("rejectCount"), 2)
        return self.finish()


class C221(Board):
    cid = "C221"

    def run(self):
        # 施工方 11/11：審查 ERROR 不計退回次數；連續 3 次 ERROR 升級給使用者（blocked、要使用者：…）；REJECT／PASS 讓連續計數歸零。規格未寫，標推論。
        repo, _ = self.make_repo("err")
        collab = self.write_collab("err", [self.step("e1", reviewDir=str(repo)), self.step("e2", reviewDir=str(repo))])
        for n in (1, 2):
            _, st = self.work_cycle(collab, repo, "e1", "ERROR", f"E{n}", in_repo=True)
            self.check(f"ERROR 第 {n} 次：回到 doing", st.get("state"), "doing")
            self.check(f"ERROR 第 {n} 次：needsUser", st.get("needsUser"), False)
            self.check(f"ERROR 第 {n} 次：不計退回次數", st.get("rejectCount"), 0)
        _, st = self.work_cycle(collab, repo, "e1", "ERROR", "E3", in_repo=True)
        self.check("ERROR 連續第 3 次：升級 blocked", st.get("state"), "blocked")
        self.check("ERROR 連續第 3 次：needsUser", st.get("needsUser"), True)
        self.check("ERROR 連續第 3 次：仍不計退回次數", st.get("rejectCount"), 0)
        self.true("ERROR 連續第 3 次：備註以「要使用者：」開頭", str(self.raw_step(collab, "e1").get("note", "")).startswith("要使用者："))
        nxt = self.call(collab, ["next", "--by", "codenv_worker"])
        self.true("升級後出現在 next 收件清單", "e1" in nxt.stdout)

        self.call(collab, ["step", "e1", "進行中"], cwd=repo)
        _, st = self.work_cycle(collab, repo, "e1", "ERROR", "E4", in_repo=True)
        self.check("放行後再 ERROR 一次：仍 doing（連續計數已歸零）", st.get("state"), "doing")

        seq = [("ERROR", "doing"), ("ERROR", "doing"), ("REJECT", "doing"), ("ERROR", "doing"), ("ERROR", "doing"), ("ERROR", "blocked")]
        for i, (fake, want) in enumerate(seq, 1):
            _, st = self.work_cycle(collab, repo, "e2", fake, f"S{i}", in_repo=True)
            self.check(f"序列第 {i} 步 {fake}：狀態", st.get("state"), want)
        self.check("序列結束 rejectCount 只算 REJECT 的 1 次", self.status(collab, "e2").get("rejectCount"), 1)
        return self.finish()


class Handoff(Base):
    def setup_fakes(self):
        self.state = self.temp / "state"
        self.state.mkdir()
        self.log = self.temp / "calls.log"
        self.counter = self.temp / "counter"
        self.counter.write_text("0")
        body = "# 工作交接紀錄\\n\\n" + "### 1. 負責事項\\n- 測試用交接內容，長度足夠通過可用檢查。\\n" * 12
        for name in ("fake-agy", "fake-codex"):
            script = self.temp / name
            script.write_text(f"""#!/bin/bash
n=$(( $(cat '{self.counter}') + 1 )); echo $n > '{self.counter}'
{{ echo "=== CALL $n {name} cwd=$(pwd -P)"; for a in "$@"; do printf 'ARG<<%s>>\\n' "$a"; done; }} >> '{self.log}'
out=""; prev=""
for a in "$@"; do if [ "$prev" = "-o" ] || [ "$prev" = "--output-last-message" ]; then out="$a"; fi; prev="$a"; done
text="$(python3 -c "print('{body}')")
MARK-$n"
if [ -n "$out" ]; then printf '%s\\n' "$text" > "$out"; fi
printf '%s\\n' "$text"
""", encoding="utf-8")
            script.chmod(0o755)
        self.agy, self.codex = self.temp / "fake-agy", self.temp / "fake-codex"

    def transcript(self, user_text, name="t.jsonl"):
        rows = [{"type": "user", "message": {"role": "user", "content": user_text}},
                {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "好的，已收到。"}]}}]
        path = self.temp / name
        path.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n", encoding="utf-8")
        return path

    def prep(self, transcript, cid="abcd1234-0000-0000-0000-000000000000", engine="claude", summary="legacy"):
        env = dict(os.environ, CODENV_STATE_DIR=str(self.state), CODENV_TEST_AGY_BIN=str(self.agy), CODENV_TEST_CODEX_BIN=str(self.codex))
        env.pop("CODENV_HANDOFF_TITLE", None)
        return subprocess.run([str(self.handoff), "--transcript", str(transcript), "--engine", engine, "--summary-engine", summary, cid],
                              cwd=self.root, env=env, capture_output=True, text=True, timeout=40)

    def log_text(self):
        return self.log.read_text(encoding="utf-8") if self.log.exists() else ""

    def handoff_files(self):
        folder = self.state / "handoff"
        return sorted(folder.glob("*.md")) if folder.exists() else []


class C222(Handoff):
    cid = "C222"

    def run(self):
        # 施工方 11/11：同日連續交接同一聊天室，檔名遞增、保證終止；4 次得到 4 個不同檔不卡死。
        self.setup_fakes()
        tr = self.transcript("請整理這間聊天室。")
        paths = []
        for n in range(1, 7):
            try:
                r = self.prep(tr)
            except subprocess.TimeoutExpired:
                self.check(f"第 {n} 次交接在 40 秒內結束（不卡死）", "逾時", "結束")
                break
            self.check(f"第 {n} 次交接 exit code", r.returncode, 0)
            paths.append((r.stdout.strip().splitlines() or [""])[-1])
        self.check("6 次輸出 6 個不同路徑", len(set(paths)), 6)
        files = self.handoff_files()
        self.check("state 的 handoff 資料夾有 6 個檔", len(files), 6)
        wanted = [f"MARK-{i}" for i in range(1, 7)]
        found = sorted({m for f in files for m in wanted if m in f.read_text(encoding="utf-8")})
        self.check("每個檔保有各自那次的內容（沒有互相覆蓋）", found, wanted)
        return self.finish()


class C223(Handoff):
    cid = "C223"

    def run(self):
        # 施工方 11/11：codex exec 帶 --skip-git-repo-check，並在非 git 的暫存資料夾執行。規格 07-10：Codex 聊天室摘要走 codex 免費群組 group/codex-free。
        self.setup_fakes()
        tr = self.transcript("請整理 Codex 聊天室。")
        r = self.prep(tr, engine="codex", summary="engine")
        self.check("codex 引擎交接 exit code", r.returncode, 0)
        log = self.log_text()
        self.true("有呼叫假 codex", "fake-codex" in log)
        self.check("Codex 聊天室沒有改叫 agy", "fake-agy" in log, False)
        self.true("codex 參數帶 --skip-git-repo-check", "ARG<<--skip-git-repo-check>>" in log)
        self.true("codex 參數用 group/codex-free（07-10）", "group/codex-free" in log)
        cwd = ""
        for line in log.splitlines():
            if "cwd=" in line:
                cwd = line.split("cwd=", 1)[1]
        self.true("假 codex 有記到工作目錄", cwd)
        inside = subprocess.run(["git", "-C", cwd or "/nonexistent", "rev-parse", "--is-inside-work-tree"], capture_output=True, text=True)
        self.true("工作目錄不在任何 git repo 裡", inside.returncode != 0)
        self.true("工作目錄不是 codenv repo", not str(pathlib.Path(cwd).resolve()).startswith(str(self.root.resolve())))
        self.true("交接檔已產生", self.handoff_files())
        return self.finish()


SECRETS = {
    "sk 金鑰": "sk-ExamFakeKeyAAAAAAAAAAAAAAAAAAAAAAAA1234",
    "AIza 金鑰": "AIzaSyExamFakeKeyBBBBBBBBBBBBBBBBBBBBBB1",
    "gsk 金鑰": "gsk_ExamFakeKeyCCCCCCCCCCCCCCCCCCCCCCCC",
    "nvapi 金鑰": "nvapi-ExamFakeKeyDDDDDDDDDDDDDDDDDDDDDDDD",
    "AWS 金鑰": "AKIAEXAMFAKEKEY12345",
    "JWT": "eyJhbGciOiJIUzI1NiJ9.eyJleGFtIjoiZmFrZSJ9.ExamFakeSigEEEEEEEEEEEE",
    "64 碼十六進位": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
    "信箱": "alice.exam@example.test",
    "台灣手機": "0912-345-678",
    "台灣手機（無連字號）": "0987654321",
    "北美電話": "(415) 555-0132",
}
GIT_SHA = "0123456789abcdef0123456789abcdef01234567"


class C224(Handoff):
    cid = "C224"

    def run(self):
        # 施工方 11/11：handoff-prep 送摘要模型前遮罩金鑰、信箱、電話；恰 40 碼十六進位視為 git SHA 保留。
        self.setup_fakes()
        lines = [f"{name}：{value}" for name, value in SECRETS.items()]
        tr = self.transcript("請整理。以下是測試資料：\n" + "\n".join(lines) + f"\n相關 commit：{GIT_SHA}\n普通中文句子「保持原樣」。")
        r = self.prep(tr)
        self.check("交接 exit code", r.returncode, 0)
        log = self.log_text()
        self.true("摘要模型有被呼叫", "fake-agy" in log)
        for name, value in SECRETS.items():
            self.check(f"送模型的輸入不含原文：{name}", value in log, False)
        self.check("40 碼 git SHA 保留", GIT_SHA in log, True)
        self.true("普通中文保留", "普通中文句子「保持原樣」" in log)
        return self.finish()


class C225(Handoff):
    cid = "C225"

    def run(self):
        # 規格 07-9：<private>…</private> 在交接檔（handoff-prep）送模型前先刪掉，換成「〔已略過私人段落〕」；標籤沒成對時從開頭標籤到該則訊息結尾都算私人。
        self.setup_fakes()
        rows = [
            {"type": "user", "message": {"role": "user", "content": "公開前文。<private>私人段落甲：不要外流</private>公開後文。"}},
            {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "收到。"}]}},
            {"type": "user", "message": {"role": "user", "content": "第二則公開開頭。<private>沒有結尾的私人段落乙，到訊息結束都算私人"}},
            {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "第三則助理公開回答。"}]}},
        ]
        tr = self.temp / "p.jsonl"
        tr.write_text("\n".join(json.dumps(r, ensure_ascii=False) for r in rows) + "\n", encoding="utf-8")
        r = self.prep(tr)
        self.check("交接 exit code", r.returncode, 0)
        log = self.log_text()
        self.check("送模型的輸入不含成對 private 內容", "私人段落甲" in log, False)
        self.check("送模型的輸入不含不成對 private 內容", "沒有結尾的私人段落乙" in log, False)
        self.true("輸入含略過標記〔已略過私人段落〕", "〔已略過私人段落〕" in log)
        self.true("private 以外的公開文字保留", all(s in log for s in ("公開前文", "公開後文", "第二則公開開頭")))
        self.true("不成對標籤只吃到該則結尾，下一則助理回答保留", "第三則助理公開回答" in log)
        return self.finish()


CASES = {c.cid: c for c in (C218, C219, C220, C221, C222, C223, C224, C225)}


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in CASES:
        print("用法：board-handoff-0700r-probe.py <C218..C225> <repo 根目錄>", file=sys.stderr)
        return 2
    return CASES[sys.argv[1]](sys.argv[2]).run()


if __name__ == "__main__":
    raise SystemExit(main())
