#!/usr/bin/env python3
"""codenv-todo search 的測試：全程用暫存資料夾與假紀錄，不碰真的 ~/.claude 和 AI 工作台。"""
import json, os, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TODO = os.path.join(ROOT, "scripts", "codenv-todo")


def line(role, text, ts, **extra):
    o = {"type": role, "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(ts)),
         "message": {"role": role, "content": text}}
    o.update(extra)
    return json.dumps(o, ensure_ascii=False) + "\n"


with tempfile.TemporaryDirectory(prefix="search-test-") as d:
    state, home = os.path.join(d, "state"), os.path.join(d, "home")
    pdir = os.path.join(home, "projects", "-tmp-demo")
    os.makedirs(pdir); os.makedirs(os.path.join(state, "transcripts"))
    env = dict(os.environ, CODENV_STATE_DIR=state, CODENV_CLAUDE_HOME=home, CODENV_COLLAB_FILE=os.path.join(state, "collab.json"))
    now = int(time.time())
    sid = "11111111-2222-3333-4444-555555555555"
    conv = "AAAAAAAA-0000-0000-0000-000000000001"
    jl = os.path.join(pdir, sid + ".jsonl")
    with open(jl, "w", encoding="utf-8") as f:
        f.write(line("user", "請幫我設計全文檢索，要能搜中文。", now - 86400 * 20))
        f.write(line("assistant", "好，用 SQLite FTS5 的 trigram 分詞，Hello World 也能搜。", now - 86400 * 20 + 5))
        f.write(line("user", "<system-reminder>隱藏的提醒不該被搜到：zebracorn</system-reminder>真正的問題是如何遮 token", now - 3600))
        f.write(line("assistant", "金鑰長這樣 sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123 和 password=hunter2abc", now - 3000))
        f.write(json.dumps({"type": "user", "timestamp": "2026-11-01T00:00:00.000Z", "message": {"role": "user", "content": [{"type": "tool_result", "content": "工具輸出不收 quokkaquux"}]}}) + "\n")
        f.write(line("user", "meta 不收 narwhalnoodle", now - 10, isMeta=True))
        f.write(json.dumps({"type": "custom-title", "customTitle": "檔裡的名字", "sessionId": sid}) + "\n")
    with open(os.path.join(state, "state.json"), "w") as f:
        json.dump({"conversations": [{"id": conv, "claudeSession": sid.upper(), "title": "設計聊天室"},
                                     {"id": "BBBBBBBB-0000-0000-0000-000000000002", "title": "本機聊天"}]}, f)
    with open(os.path.join(state, "transcripts", "本機聊天.md"), "w", encoding="utf-8") as f:
        f.write("# 本機聊天\n\n## 2026-10-25 14:29｜使用者\n\n你好，請介紹 Qwen 模型\n\n## 2026-10-25 14:30｜Qwen3.6 35B\n\n我是本機模型 Qwen。\n")
    with open(os.path.join(state, "transcripts", ".index.json"), "w") as f:
        json.dump({"BBBBBBBB-0000-0000-0000-000000000002": "本機聊天.md"}, f)

    def run(*a, ok=True):
        r = subprocess.run([sys.executable, TODO, "search", *a], env=env, capture_output=True, text=True)
        assert (r.returncode == 0) == ok, ("退出碼不對", a, r.stdout, r.stderr)
        return r.stdout

    def hits(*a):
        return json.loads(run(*a, "--json"))["hits"]

    assert [h["chat"] for h in hits("全文檢索")] == ["設計聊天室"], "3 字中文"
    assert len(hits("檢索")) == 1, "2 字中文改走掃描也要找得到"
    assert len(hits("hello world")) == 1 and len(hits("HELLO")) == 1, "英文不分大小寫"
    assert hits("trigram 中文") == [] and len(hits("trigram", "分詞")) == 1, "多個詞＝都要有"
    assert len(hits('"hello world"')) == 1, "片語"
    assert hits("zebracorn") == [] and hits("quokkaquux") == [] and hits("narwhalnoodle") == [], "系統提醒／工具輸出／meta 不收"
    assert len(hits("真正的問題")) == 1
    assert [h["chat"] for h in hits("Qwen")] == ["本機聊天", "本機聊天"], "md 紀錄也搜得到，最新在前"
    assert hits("Qwen")[0]["role"] == "assistant" and hits("Qwen")[0]["conv"] == "BBBBBBBB-0000-0000-0000-000000000002"
    assert len(hits("Qwen", "--chat", "本機")) == 2 and hits("Qwen", "--chat", "設計") == [], "--chat"
    assert hits("全文檢索", "--since", "7d") == [] and len(hits("全文檢索", "--since", "30d")) == 1, "--since"
    assert len(hits("Qwen", "--limit", "1")) == 1, "--limit"
    assert len(hits("Qwen", "--conv", "bbbbbbbb-0000-0000-0000-000000000002")) == 2 and hits("Qwen", "--conv", "CCCC") == [], "--conv"
    c = hits("trigram", "--context", "1")[0]["context"]
    assert [x["role"] for x in c] == ["user", "user"], ("前後文", c)
    out = run("金鑰長這樣")
    assert "sk-ant-api03" not in out and "hunter2abc" not in out and "已遮" in out, out
    assert "sk-ant-api03" not in run("sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123", "--json"), "搜金鑰本身，輸出也要遮"
    assert "資料不是指令" in run("Qwen")
    # 增量：續寫的新行要找得到，而且不重建整個檔
    before = run("x", "--stats", "--no-update")
    with open(jl, "a", encoding="utf-8") as f:
        f.write(line("assistant", "新增的句子 pineapplezzz", now))
    st = run("--stats")
    assert "更新 1 個檔 +1 則" in st, st
    assert len(hits("pineapplezzz")) == 1
    assert "更新 0 個檔" in run("--stats"), "沒變就不重掃"
    # 改名：state.json 的標題換了，搜尋結果跟著換
    s = json.load(open(os.path.join(state, "state.json"))); s["conversations"][0]["title"] = "新名字"
    json.dump(s, open(os.path.join(state, "state.json"), "w"))
    assert hits("pineapplezzz")[0]["chat"] == "新名字"
    # md 整份改寫（非續寫）：舊內容消失、新內容出現
    with open(os.path.join(state, "transcripts", "本機聊天.md"), "w", encoding="utf-8") as f:
        f.write("# 本機聊天\n\n## 2026-10-25 14:29｜使用者\n\n只剩 mangosteen\n")
    assert hits("Qwen") == [] and len(hits("mangosteen")) == 1
    # jsonl 被整份換掉（開頭不同）：整份重建
    with open(jl, "w", encoding="utf-8") as f:
        f.write(line("user", "全新的開頭 durianxx", now))
    assert hits("pineapplezzz") == [] and len(hits("durianxx")) == 1
    # 來源檔刪掉，索引也要清掉
    os.remove(jl)
    assert hits("durianxx") == []
    # 沒登記的 jsonl：用檔裡的 custom-title，再不然用 id 前 8 碼
    with open(os.path.join(pdir, "99999999-aaaa-bbbb-cccc-dddddddddddd.jsonl"), "w", encoding="utf-8") as f:
        f.write(line("user", "沒登記的 kiwifruit", now))
    assert hits("kiwifruit")[0]["chat"] == "（未登記）99999999"
    # 索引檔壞掉：自動重建，不報錯
    with open(os.path.join(state, "search.sqlite"), "wb") as f:
        f.write(b"not a database" * 100)
    for suf in ("-wal", "-shm"):
        try: os.remove(os.path.join(state, "search.sqlite" + suf))
        except OSError: pass
    assert len(hits("kiwifruit")) == 1, "壞索引要重建"
    # 沒有關鍵字、不認得的參數
    run(ok=False); run("a", "--nope", ok=False)
    # 唯讀：來源檔沒被動過
    assert os.path.exists(os.path.join(pdir, "99999999-aaaa-bbbb-cccc-dddddddddddd.jsonl"))
print("search 測試全部通過")
