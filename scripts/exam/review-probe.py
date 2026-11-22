#!/usr/bin/env python3
"""C175 isolated command-line review probe checks."""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import time


def fixture(steps):
    return {
        "items": [],
        "goals": [{
            "id": "g-c175",
            "title": "C175 合成審查目標",
            "status": "active",
            "steps": steps,
        }],
    }


def make_step(step_id, text, state="doing", owner="codenv_worker", **extra):
    step = {"id": step_id, "text": text, "state": state, "owner": owner, "rejectCount": 0}
    step.update(extra)
    return step


class C175:
    def __init__(self, root):
        self.root = pathlib.Path(root)
        self.cli = self.root / "scripts/codenv-todo"
        self.temp = pathlib.Path(tempfile.mkdtemp(prefix="codenv-exam-review-c175.", dir="/private/tmp"))
        self.failures = 0
        print(f"C175 暫存資料夾：{self.temp}")

    def check(self, label, actual, expected):
        passed = actual == expected
        print(f"  {'通過' if passed else '失敗'}：{label}（預期 {expected!r}，實際 {actual!r}）")
        if not passed:
            self.failures += 1
        return passed

    def write_fixture(self, name, steps):
        path = self.temp / name / "collab.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(fixture(steps), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        return path.resolve()

    def call(self, collab, args, fake_result=None, enabled=None):
        resolved = pathlib.Path(collab).resolve()
        if not str(resolved).startswith("/private/tmp/"):
            raise RuntimeError(f"拒絕呼叫：CODENV_COLLAB_FILE 不在 /private/tmp：{resolved}")
        env = dict(os.environ)
        env["CODENV_REVIEW_PROBE"] = "1"
        env["CODENV_COLLAB_FILE"] = str(resolved)
        env.pop("CODENV_REVIEW_FAKE_RESULT", None)
        env.pop("CODENV_REVIEW_ENABLED", None)
        if fake_result is not None:
            env["CODENV_REVIEW_FAKE_RESULT"] = fake_result
        if enabled is not None:
            env["CODENV_REVIEW_ENABLED"] = enabled
        result = subprocess.run([str(self.cli), *args], cwd=self.root, env=env, capture_output=True, text=True, timeout=20)
        return result

    def probe(self, collab, step, action, note=None):
        args = ["review-probe", step, action]
        if note is not None:
            args.extend(["--note", note])
        result = self.call(collab, args)
        try:
            data = json.loads(result.stdout)
        except json.JSONDecodeError:
            data = None
        self.check(f"review-probe {action} exit code", result.returncode, 0)
        if data is None:
            self.check(f"review-probe {action} 輸出 JSON", result.stdout, "JSON")
            print(f"  stdout={result.stdout!r}; stderr={result.stderr!r}")
        return data

    def settings(self, collab):
        result = self.call(collab, ["review-probe", "settings"])
        try:
            data = json.loads(result.stdout)
        except json.JSONDecodeError:
            data = None
        self.check("review-probe settings exit code", result.returncode, 0)
        self.check("review-probe settings 輸出 JSON", data is not None, True)
        if data is None:
            print(f"  stdout={result.stdout!r}; stderr={result.stderr!r}")
            return {}
        return data

    def status(self, collab, step, report=True):
        result = self.call(collab, ["review-probe", "status", step])
        try:
            data = json.loads(result.stdout)
        except json.JSONDecodeError:
            data = None
        if report:
            self.check(f"review-probe status {step} exit code", result.returncode, 0)
            self.check(f"review-probe status {step} 輸出 JSON", data is not None, True)
        if data is None:
            print(f"  stdout={result.stdout!r}; stderr={result.stderr!r}")
            return {}
        return data

    def wait_for_review_end(self, collab, step, status):
        deadline = time.monotonic() + 5
        while status.get("state") == "reviewing" and time.monotonic() < deadline:
            time.sleep(0.2)
            status = self.status(collab, step, report=False)
        return status

    def git_collab(self, name, steps, changed=True, commit_change=False):
        repo = self.temp / name / "repo"
        repo.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "init", "-q", str(repo)], check=True, capture_output=True, text=True)
        tracked = repo / "tracked.txt"
        tracked.write_text("baseline\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(repo), "add", "tracked.txt"], check=True, capture_output=True, text=True)
        subprocess.run([
            "git", "-C", str(repo), "-c", "user.name=Codenv Exam", "-c", "user.email=exam@example.test",
            "commit", "-m", "C175 synthetic baseline",
        ], check=True, capture_output=True, text=True)
        base = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
        if changed:
            tracked.write_text("changed by C175 fixture\n", encoding="utf-8")
        if commit_change:
            subprocess.run(["git", "-C", str(repo), "add", "tracked.txt"], check=True, capture_output=True, text=True)
            subprocess.run([
                "git", "-C", str(repo), "-c", "user.name=Codenv Exam", "-c", "user.email=exam@example.test",
                "commit", "-m", "C175 synthetic step change",
            ], check=True, capture_output=True, text=True)
        for step in steps:
            step["reviewDir"] = str(repo)
            step["reviewBase"] = base
        return self.write_fixture(name, steps), repo, base

    @staticmethod
    def step_data(collab, step_id):
        data = json.loads(pathlib.Path(collab).read_text(encoding="utf-8"))
        for goal in data.get("goals", []):
            for step in goal.get("steps", []):
                if step.get("id") == step_id:
                    return goal, step
        return {}, {}

    def pass_scenario(self):
        collab = self.write_fixture("pass", [make_step("s-pass", "有變更的施工步驟"), make_step("s-next", "下一個施工步驟", "todo")])
        submitted = self.probe(collab, "s-pass", "submit") or {}
        self.check("施工步驟 submit 進 reviewing", submitted.get("state"), "reviewing")
        goal, step = self.step_data(collab, "s-pass")
        self.check("collab.json 記錄 reviewing", step.get("state"), "reviewing")
        passed = self.probe(collab, "s-pass", "PASS") or {}
        self.check("PASS 後狀態為 done", passed.get("state"), "done")
        status = self.status(collab, "s-pass")
        self.check("PASS 後 status 狀態為 done", status.get("state"), "done")
        _goal, step = self.step_data(collab, "s-pass")
        self.check("PASS 寫回 done 狀態而非 verify", step.get("state"), "done")
        return submitted, passed

    def reject_scenario(self):
        collab = self.write_fixture("reject", [make_step("s-reject", "一般施工步驟"), make_step("s-accept", "使用者驗收@你", "todo")])
        outcomes = []
        for count in range(1, 5):
            submitted = self.probe(collab, "s-reject", "submit") or {}
            expected_round_state = "reviewing"
            self.check(f"第 {count} 次送審狀態", submitted.get("state"), expected_round_state)
            note = f"合成退回原因第{count}次：缺少驗收證據"
            rejected = self.probe(collab, "s-reject", "REJECT", note=note) or {}
            state = "blocked" if count == 4 else "doing"
            self.check(f"第 {count} 次退回狀態", rejected.get("state"), state)
            self.check(f"第 {count} 次退回次數", rejected.get("rejectCount"), count)
            self.check(f"第 {count} 次 needsUser", rejected.get("needsUser"), count == 4)
            self.check(f"第 {count} 次退回原因保留", note in str(rejected.get("note", "")), True)
            status = self.status(collab, "s-reject")
            self.check(f"第 {count} 次 status 狀態", status.get("state"), state)
            self.check(f"第 {count} 次 status 退回次數", status.get("rejectCount"), count)
            self.check(f"第 {count} 次 status needsUser", status.get("needsUser"), count == 4)
            if count == 1:
                delivery = status.get("reviewDelivery") if isinstance(status.get("reviewDelivery"), dict) else {}
                content = delivery.get("content")
                self.check("第一次退回交付到施工步驟 owner", delivery.get("recipient"), "codenv_worker")
                self.check("第一次退回交付保留指定原因", isinstance(content, str) and note in content, True)
            _goal, step = self.step_data(collab, "s-reject")
            self.check(f"第 {count} 次 collab 狀態", step.get("state"), state)
            self.check(f"第 {count} 次 collab rejectCount", step.get("rejectCount"), count)
            outcomes.append(rejected)
        env = dict(os.environ, CODENV_REVIEW_PROBE="1", CODENV_COLLAB_FILE=str(collab))
        env.pop("CODENV_REVIEW_ENABLED", None)
        env.pop("CODENV_REVIEW_FAKE_RESULT", None)
        listing = subprocess.run([str(self.cli), "goal", "ls"], cwd=self.root, env=env, capture_output=True, text=True, timeout=20)
        self.check("goal ls exit code", listing.returncode, 0)
        self.check("goal ls 顯示第 4 次退回原因", "合成退回原因第4次：缺少驗收證據" in listing.stdout, True)
        queue = subprocess.run([str(self.cli), "next", "--by", "codenv_worker"], cwd=self.root, env=env, capture_output=True, text=True, timeout=20)
        self.check("next 收件清單 exit code", queue.returncode, 0)
        self.check("第 4 次 blocked 步驟出現在 CLI 收件清單", "s-reject" in queue.stdout and "卡住" in queue.stdout, True)
        return collab, outcomes, listing.stdout, queue.stdout

    def default_scenario(self):
        collab, repo, base = self.git_collab("default-off", [make_step("s-default", "預設關閉施工步驟")])
        settings = self.settings(collab)
        self.check("未設定 autoReview 時 settings 預設值關閉", settings.get("default"), False)
        self.check("未設定 autoReview 時實際 enabled 關閉", settings.get("enabled"), False)
        source = settings.get("source")
        self.check("settings 回報設定來源", isinstance(source, str) and bool(source), True)
        print(f"  settings source={source!r}")
        diff = subprocess.run(["git", "-C", str(repo), "diff", "--quiet", base, "--"], capture_output=True)
        self.check("預設關閉情境確有已追蹤 Git 變更", diff.returncode, 1)
        result = self.call(collab, ["step", "s-default", "完成"], fake_result="ERROR")
        self.check("預設關閉步驟完成 exit code", result.returncode, 0)
        self.check("預設關閉時沒有送阿公審查", "已送阿公審查" in result.stdout, False)
        status = self.status(collab, "s-default")
        self.check("預設關閉且有 Git 變更仍直接完成", status.get("state"), "done")
        self.check("預設關閉不增加退回次數", status.get("rejectCount"), 0)
        return settings, result, status

    def git_trigger_scenario(self, committed=False):
        name = "git-committed" if committed else "git-working-tree"
        step_id = "s-committed" if committed else "s-working-tree"
        collab, repo, base = self.git_collab(name, [make_step(step_id, "Git 變更施工步驟")], commit_change=committed)
        diff_args = ["git", "-C", str(repo), "diff", "--quiet", base, "--"]
        diff = subprocess.run(diff_args, capture_output=True)
        if committed:
            changed = subprocess.run(["git", "-C", str(repo), "diff", "--quiet", base, "HEAD", "--"], capture_output=True)
            self.check("已提交情境確有 reviewBase 之後的新 commit 變更", changed.returncode, 1)
        else:
            self.check("未提交情境確有相對 reviewBase 的 Git 變更", diff.returncode, 1)
        result = self.call(collab, ["step", step_id, "完成"], fake_result="PASS", enabled="1")
        self.check(f"Git 變更觸發審查（{'已提交' if committed else '未提交'}）exit code", result.returncode, 0)
        self.check(f"Git 變更觸發審查（{'已提交' if committed else '未提交'}）有送審回報",
                   "已送阿公審查" in result.stdout, True)
        status = self.status(collab, step_id)
        status = self.wait_for_review_end(collab, step_id, status)
        self.check(f"Git 變更審查 PASS 後狀態（{'已提交' if committed else '未提交'}）", status.get("state"), "done")
        self.check(f"Git 變更審查 PASS 後次數（{'已提交' if committed else '未提交'}）", status.get("rejectCount"), 0)
        return result, status

    def no_git_change_scenario(self):
        collab, repo, base = self.git_collab("no-git-change", [make_step("s-no-change", "沒有變更的施工步驟")], changed=False)
        diff = subprocess.run(["git", "-C", str(repo), "diff", "--quiet", base, "--"], capture_output=True)
        self.check("無變更情境相對 reviewBase 沒有 diff", diff.returncode, 0)
        result = self.call(collab, ["step", "s-no-change", "完成"], fake_result="ERROR", enabled="1")
        self.check("無 Git 變更不觸發阿公審查", "已送阿公審查" in result.stdout, False)
        status = self.status(collab, "s-no-change")
        self.check("無 Git 變更步驟直接完成", status.get("state"), "done")
        self.check("無 Git 變更不增加退回次數", status.get("rejectCount"), 0)
        return result, status

    def exclusion_scenario(self):
        definitions = [
            ("s-decision", "決定：採用方案", "codenv_worker", "done"),
            ("s-external", "@gemini3.8flash 查資料", "codenv_worker", "done"),
            ("s-publish", "出版@codenv_1", "codenv_worker", "done"),
            # 目標最後的使用者驗收步驟；以文字前綴驗排除送審，不混入使用者權限行為。
            ("s-accept", "使用者驗收", "codenv_worker", None),
        ]
        steps = [make_step(step_id, text, owner=owner) for step_id, text, owner, _state in definitions]
        collab, _repo, _base = self.git_collab("excluded-steps", steps)
        results = []
        for step_id, _text, _owner, expected_state in definitions:
            result = self.call(collab, ["step", step_id, "完成"], fake_result="ERROR", enabled="1")
            if step_id == "s-accept":
                self.check("最後的使用者驗收步驟完成時沒有送審",
                           "已送阿公審查" in result.stdout, False)
                status = self.status(collab, step_id, report=False)
                observed_state = status.get("state")
                self.check("使用者驗收步驟完成後沒有進 reviewing",
                           isinstance(observed_state, str) and observed_state != "reviewing", True)
            else:
                self.check(f"排除步驟 {step_id} 不送阿公審查", "已送阿公審查" in result.stdout, False)
                status = self.status(collab, step_id)
                self.check(f"排除步驟 {step_id} 不進 reviewing", status.get("state") != "reviewing", True)
                self.check(f"排除步驟 {step_id} 狀態", status.get("state"), expected_state)
                self.check(f"排除步驟 {step_id} 不增加退回次數", status.get("rejectCount"), 0)
            results.append((result, status))
        return results

    def error_scenario(self):
        collab, repo, base = self.git_collab("error", [make_step("s-error", "ERROR 路徑施工步驟")])
        diff = subprocess.run(["git", "-C", str(repo), "diff", "--quiet", base, "--"], capture_output=True)
        self.check("ERROR 路徑有 Git 變更", diff.returncode, 1)
        result = self.call(collab, ["step", "s-error", "完成"], fake_result="ERROR", enabled="1")
        status = self.status(collab, "s-error")
        status = self.wait_for_review_end(collab, "s-error", status)
        self.check("ERROR 審查失敗回到施工中", status.get("state"), "doing")
        self.check("ERROR 不算 REJECT、不增加退回次數", status.get("rejectCount"), 0)
        self.check("ERROR 不要求使用者介入", status.get("needsUser"), False)
        _goal, step = self.step_data(collab, "s-error")
        self.check("ERROR 狀態已寫回隔離 collab.json", step.get("state"), "doing")
        self.check("ERROR 次數已寫回隔離 collab.json", step.get("rejectCount"), 0)
        return result, status

    def delivery_scenario(self):
        # 題目說明：退回交付只驗 status 的 reviewDelivery 收件人與內容，不宣稱實際送達。
        collab, repo, base = self.git_collab("reject-delivery", [make_step("s-delivery", "退回送達施工步驟")])
        diff = subprocess.run(["git", "-C", str(repo), "diff", "--quiet", base, "--"], capture_output=True)
        self.check("退回送達情境有 Git 變更", diff.returncode, 1)
        result = self.call(collab, ["step", "s-delivery", "完成"], fake_result="REJECT", enabled="1")
        self.check("REJECT step 完成路徑 exit code", result.returncode, 0)
        status = self.status(collab, "s-delivery")
        status = self.wait_for_review_end(collab, "s-delivery", status)
        self.check("REJECT 後狀態回到施工中", status.get("state"), "doing")
        self.check("REJECT 後次數增加一次", status.get("rejectCount"), 1)
        delivery = status.get("reviewDelivery") if isinstance(status.get("reviewDelivery"), dict) else {}
        self.check("退回交付對象為步驟 owner", delivery.get("recipient"), "codenv_worker")
        content = delivery.get("content")
        fragments = ("s-delivery", "退回送達施工步驟", "隔離假審查結果", "codenv-todo step s-delivery 完成重新送審")
        self.check("退回交付內容包含步驟、原因與重新送審指引",
                   isinstance(content, str) and all(fragment in content for fragment in fragments), True)
        self.check("退回交付內容非空", isinstance(content, str) and bool(content.strip()), True)
        print(f"  reviewDelivery recipient={delivery.get('recipient')!r}; content={content!r}")
        print("  探針安全限制：驗證 reviewDelivery 的收件對象與內容，不實際呼叫 codenv-todo send。")
        return result, status

    def run(self):
        default_results = self.default_scenario()
        git_working_results = self.git_trigger_scenario(committed=False)
        git_committed_results = self.git_trigger_scenario(committed=True)
        no_change_results = self.no_git_change_scenario()
        exclusion_results = self.exclusion_scenario()
        error_results = self.error_scenario()
        delivery_results = self.delivery_scenario()
        pass_results = self.pass_scenario()
        reject_results = self.reject_scenario()
        print("ERROR 判定：07-3 規格／阿公審查只對 REJECT 遞增 rejectCount；probe 說明明定 ERROR 回 doing 且不加次數，現況 doing／0 符合該預期。")
        return (default_results, git_working_results, git_committed_results, no_change_results,
                exclusion_results, error_results, delivery_results, pass_results, reject_results)


def main():
    if len(sys.argv) != 3 or sys.argv[1] != "C175":
        print("用法：review-probe.py C175 <repo 根目錄>", file=sys.stderr)
        return 2
    test = C175(sys.argv[2])
    test.run()
    print(f"C175 斷言失敗數：{test.failures}")
    return 1 if test.failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
