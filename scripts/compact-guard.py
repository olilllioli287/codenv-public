#!/usr/bin/env python3
"""compact-guard：壓縮防失憶（codenv 只對自己開的 Claude Code 聊天室掛這兩個 hook，不動使用者全域設定）。

  compact-guard.py pre-compact    PreCompact hook：壓縮「之前」把最近的原話、背景任務、未完成清單等存成快照
  compact-guard.py session-start  SessionStart hook（matcher compact）：壓縮「之後」把快照整理成一段文字補回上下文

只用 Python 標準庫；不連網、不呼叫任何模型；任何錯誤都吞掉並 exit 0（絕不能卡住壓縮或啟動）。
只從 transcript 尾端往回讀一次，最多 16MB、最多 1.5 秒，讀到最近 5 則原話即停止。

快照資料夾：環境變數 CODENV_COMPACT_DIR（codenv 帶；測試實例在 --state-dir 底下）。
沒有就用 ~/Library/Application Support/codenv/compact-state。
  codenv-compact-<session_id>.json 是最新一份，舊的依序往後推（每個 session 留 3 份）；
  超過 7 天且由本工具建立的快照在每次存檔時一併清掉。

出處：做法（PreCompact 解析 transcript JSONL 存狀態、SessionStart 用 hookSpecificOutput.additionalContext 補回）
改寫自下列開源專案的設計，程式碼是照 codenv 的需求重寫的：
  - Continuous-Claude-v3（MIT，Copyright (c) 2026 Cosimo Streppone）
    .claude/hooks/src/pre-compact-continuity.ts：解析 transcript 取最近 TodoWrite、工具呼叫、改過的檔案
  - Pi coding-agent（MIT，Copyright (c) 2025 Mario Zechner）
    packages/coding-agent/src/core/compaction/compaction.ts：保留最近幾輪（keepRecent）與分段摘要的想法
  - claude-mem（Apache-2.0）：注入內容設總長上限（CONTEXT_OUTPUT_LIMIT）、超過就砍較不重要的段落
  - planning-with-files（MIT，Copyright (c) 2026 Ahmad Adi）：進度留在檔案、SessionStart 才讀回來的流程
"""
import json
import math
import os
import re
import sys
import time

USER_KEEP = 5                 # 最近幾則
ASSISTANT_TAIL = 1500         # 最後一則助理文字留幾個字（取結尾）
TOOL_KEEP = 20                # 最近幾次工具呼叫
FILE_KEEP = 15                # 最近改過的檔案
USER_TEXT_CAP = 30000         # 快照裡單則原話的保險上限（正常不會碰到；注入時另有總長上限）
USER_RENDER_CAP = 700         # 確保原話、背景任務、待辦都能同時放進注入上限
BACKGROUND_KEEP = 10
TODO_KEEP = 20
ITEM_TEXT_CAP = 200
LIMIT = 12000                 # 注入內容總長上限（字）
KEEP_SNAPSHOTS = 3
MAX_AGE_DAYS = 7
MAX_TAIL_BYTES = 16 << 20
TAIL_CHUNK_BYTES = 256 << 10
MAX_SCAN_SECONDS = 1.5
MAX_RECORD_BYTES = 2 << 20
SNAPSHOT_PREFIX = "codenv-compact-"
SNAPSHOT_MARKER = "codenv-compact-guard"

# 不是使用者真正打的話：自動包裝、系統提示、斜線指令殼、中斷標記
NOISE_PREFIXES = (
    "<system-reminder", "<task-notification", "<cross-session-message", "<command-name>", "<command-message>",
    "<local-command-", "<user-prompt-submit-hook", "[Request interrupted", "Another Claude session sent a message",
    "This session is being continued from a previous conversation", "Caveat: The messages below were generated",
)
DONE_STATUS = {"completed", "failed", "killed", "stopped", "cancelled", "canceled", "error", "timeout"}
FILE_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
STOP_TOOLS = {"TaskStop", "KillShell", "KillBash"}
INTERNAL_TAGS = (
    "system-reminder", "task-notification", "cross-session-message", "command-name", "command-message",
    "local-command-stdout", "local-command-stderr", "user-prompt-submit-hook",
)
SECRET_PREFIX_RE = re.compile(
    r"(?i)(?<![A-Za-z0-9])(?:sk-or-v1-|sk-or-|sk-ant-|nvapi-|pplx-|hf_|AKIA|sk-|gsk_|ghp_|gho_|ghu_|ghs_|ghr_|github_pat_|AIza|xox[baprs]-)[A-Za-z0-9_-]{12,}"
)
BEARER_RE = re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{8,}")
LONG_TOKEN_RE = re.compile(r"(?<![A-Za-z0-9_])[A-Za-z0-9_+/=-]{32,}(?![A-Za-z0-9_])")


def state_dir():
    d = os.environ.get("CODENV_COMPACT_DIR")
    if d:
        return d
    return os.path.expanduser("~/Library/Application Support/codenv/compact-state")


def safe_id(s):
    s = re.sub(r"[^A-Za-z0-9_-]", "", str(s or ""))[:80]
    return s


def snapshot_id(s):
    """Keep ordinary IDs stable; disambiguate IDs that required filesystem cleanup."""
    import hashlib
    original = str(s or "")
    cleaned = safe_id(original)
    if cleaned == original and cleaned:
        return cleaned
    cleaned = cleaned or "session"
    return "%s+%s" % (cleaned, hashlib.sha256(original.encode("utf-8", "replace")).hexdigest()[:12])


def _high_entropy(value):
    if len(value) < 32:
        return False
    counts = {}
    for ch in value:
        counts[ch] = counts.get(ch, 0) + 1
    entropy = 0.0
    for count in counts.values():
        p = count / len(value)
        entropy -= p * math.log2(p)
    return entropy >= 3.5


def sanitize_text(value):
    """Remove internal tagged blocks and redact common or high-entropy secrets before persistence."""
    text = str(value or "")
    for tag in INTERNAL_TAGS:
        text = re.sub(r"<" + re.escape(tag) + r"\b[^>]*/\s*>", " ", text, flags=re.I | re.S)
        text = re.sub(r"<" + re.escape(tag) + r"\b[^>]*>.*?(?:</" + re.escape(tag) + r"\s*>|$)", " ", text, flags=re.I | re.S)
    text = SECRET_PREFIX_RE.sub("[已遮蔽金鑰]", text)
    text = BEARER_RE.sub("Bearer [已遮蔽金鑰]", text)
    def redact_long_token(match):
        value = match.group(0)
        # LONG_TOKEN_RE can span slash-delimited paths; evaluate each component.
        parts = value.split("/")
        return "/".join("[已遮蔽高熵字串]" if _high_entropy(part) else part for part in parts)
    text = LONG_TOKEN_RE.sub(redact_long_token, text)
    return text


def cap_text(value, limit, from_end=False):
    text = sanitize_text(value)
    if len(text) <= limit:
        return text
    return "…" + (text[-(limit - 1):] if from_end and limit > 1 else text[:max(0, limit - 1)])


def sanitize_tree(value):
    if isinstance(value, str):
        return sanitize_text(value)
    if isinstance(value, list):
        return [sanitize_tree(item) for item in value]
    if isinstance(value, dict):
        return {sanitize_text(key) if isinstance(key, str) else key: sanitize_tree(item) for key, item in value.items()}
    return value


# ---------- 讀 transcript 尾巴 ----------

TYPE_RE = re.compile(r'"type"\s*:\s*"(user|assistant)"')


def parse_record(raw):
    if not raw or len(raw) > MAX_RECORD_BYTES:
        return None
    head = raw[:1500].decode("utf-8", "replace")
    if not TYPE_RE.search(head):
        return None                      # attachment／api-request-blob 這類不用解析（最大宗，也最肥）
    try:
        obj = json.loads(raw)
    except (ValueError, TypeError, RecursionError):
        return None
    if isinstance(obj, dict) and obj.get("type") in ("user", "assistant") and not obj.get("isSidechain"):
        return obj
    return None


def iter_records(lines):
    for raw in lines:
        obj = parse_record(raw)
        if obj is not None:
            yield obj


def read_tail_records(path):
    """Read transcript once from the end, stopping after five real user messages or the budget."""
    started = time.monotonic()
    try:
        file_size = os.path.getsize(path)
        remaining = min(file_size, MAX_TAIL_BYTES)
        with open(path, "rb") as f:
            pos = file_size
            carry = b""
            newest_first = []
            user_count = 0
            while pos > 0 and remaining > 0 and user_count < USER_KEEP:
                if time.monotonic() - started >= MAX_SCAN_SECONDS:
                    break
                amount = min(TAIL_CHUNK_BYTES, remaining, pos)
                pos -= amount
                remaining -= amount
                f.seek(pos)
                chunk = f.read(amount)
                if not chunk:
                    break
                data = chunk + carry
                parts = data.split(b"\n")
                if pos > 0:
                    carry = parts.pop(0)  # 留下跨區塊的半行，下一輪接上更早的位元組
                else:
                    carry = b""
                processed_lines = 0
                for raw in reversed(parts):
                    if not raw:
                        continue
                    # 若這次 read 已超過時限，仍使用剛讀到的最新一行，再停止解析。
                    if processed_lines and time.monotonic() - started >= MAX_SCAN_SECONDS:
                        break
                    processed_lines += 1
                    obj = parse_record(raw)
                    if obj is None:
                        continue
                    newest_first.append(obj)
                    if real_user_text(obj) is not None:
                        user_count += 1
                        if user_count >= USER_KEEP:
                            break
            return list(reversed(newest_first))
    except Exception:
        return []


def blocks(msg):
    c = (msg or {}).get("content")
    if isinstance(c, str):
        return [{"type": "text", "text": c}]
    return [b for b in c if isinstance(b, dict)] if isinstance(c, list) else []


def real_user_text(obj):
    """使用者真正打的話；不是（工具結果、系統提示、自動通知、他處轉來的訊息）就回 None。"""
    if obj.get("type") != "user" or obj.get("isMeta") or obj.get("isCompactSummary"):
        return None
    if obj.get("promptSource") == "system" or obj.get("turnOrigin") in ("task_notification", "peer", "scheduled", "system"):
        return None
    origin = obj.get("origin")
    if isinstance(origin, dict) and (origin.get("kind") == "task-notification" or "body" in origin):
        return None
    parts = []
    for b in blocks(obj.get("message")):
        t = b.get("type")
        if t == "tool_result":
            return None
        if t == "image":
            parts.append("[圖片]")
        elif t == "text":
            text = sanitize_text(b.get("text") or "")
            if text.lstrip().startswith(NOISE_PREFIXES):
                continue
            if text.strip():
                parts.append(text.strip())
    text = "\n".join(parts).strip()
    return cap_text(text, USER_TEXT_CAP, from_end=True) if text else None


def short(s, n=80):
    s = " ".join(sanitize_text(s).split())
    return s if len(s) <= n else s[:n - 1] + "…"


def safe_path(s):
    text = sanitize_text(s)
    if re.match(r"(?i)^https?://", text):
        text = re.split(r"[?#]", text, maxsplit=1)[0] + "?[URL query omitted]"
    return short(text, ITEM_TEXT_CAP)


def tool_summary(name, inp):
    name = short(name or "?", 80)
    inp = inp if isinstance(inp, dict) else {}
    # 不儲存 command、prompt、description 或 URL/query；它們可能包含金鑰或整段私密輸入。
    allowed = ("file_path", "notebook_path", "path") if name in FILE_TOOLS else ()
    for k in allowed:
        if inp.get(k):
            return "%s: %s" % (name, safe_path(inp[k]))
    return name


def analyze_records(records):
    users, tools, files = [], [], []
    todos = None
    pending = {}                           # 背景任務 id -> 描述（還沒看到完成通知）
    uses = {}                              # tool_use_id -> (name, input)
    last_text, last_mid = "", None
    for obj in records:
        if obj["type"] == "assistant":
            msg = obj.get("message") or {}
            for b in blocks(msg):
                t = b.get("type")
                if t == "text" and (b.get("text") or "").strip():
                    mid = msg.get("id")
                    text = sanitize_text(b["text"]).strip()
                    last_text = (last_text + "\n" + text) if (mid and mid == last_mid) else text
                    last_mid = mid
                elif t == "tool_use":
                    name, inp = b.get("name") or "?", b.get("input")
                    uses[b.get("id")] = (name, inp)
                    tools.append(tool_summary(name, inp))
                    if name == "TodoWrite" and isinstance(inp, dict) and isinstance(inp.get("todos"), list):
                        todos = inp["todos"]
                    if name in FILE_TOOLS and isinstance(inp, dict):
                        p = inp.get("file_path") or inp.get("notebook_path")
                        if p:
                            p = safe_path(p)
                            if p in files:
                                files.remove(p)
                            files.append(p)
                    if name in STOP_TOOLS and isinstance(inp, dict):
                        pending.pop(str(inp.get("task_id") or inp.get("shell_id") or inp.get("bash_id") or ""), None)
            continue
        # user
        text = real_user_text(obj)
        if text is not None:
            users.append({"text": text})
            continue
        for b in blocks(obj.get("message")):
            t = b.get("type")
            if t == "tool_result":
                content = b.get("content")
                s = content if isinstance(content, str) else " ".join(
                    x.get("text", "") for x in content if isinstance(x, dict)) if isinstance(content, list) else ""
                m = re.search(r"Command running in background with ID: (\w+)", s)
                tur = obj.get("toolUseResult")
                tid = m.group(1) if m else (tur.get("backgroundTaskId") if isinstance(tur, dict) else None)
                if tid:
                    name, inp = uses.get(b.get("tool_use_id"), ("Bash", {}))
                    inp = inp if isinstance(inp, dict) else {}
                    # 僅保留使用者明確填寫的短說明，不把 shell 指令或工具輸出存入快照。
                    pending[str(tid)] = short(inp.get("description") or name, ITEM_TEXT_CAP)
            elif t == "text" and "<task-notification" in (b.get("text") or ""):
                for note in re.findall(r"<task-notification\b[^>]*>(.*?)</task-notification\s*>", b["text"], re.S | re.I):
                    i, st = re.search(r"<task-id>(\w+)</task-id>", note), re.search(r"<status>(\w+)</status>", note)
                    if i and (not st or st.group(1).lower() in DONE_STATUS):
                        pending.pop(i.group(1), None)
    clean_todos = []
    for todo in todos or []:
        if not isinstance(todo, dict) or todo.get("status") == "completed":
            continue
        status = short(todo.get("status") or "pending", 24)
        content = short(todo.get("content") or todo.get("activeForm") or "", ITEM_TEXT_CAP)
        if content:
            clean_todos.append({"status": status, "content": content})
    return {
        "users": users[-USER_KEEP:], "assistant": last_text, "todos": clean_todos[:TODO_KEEP],
        "tools": tools[-TOOL_KEEP:], "files": files[-FILE_KEEP:],
        "pending": [{"id": short(k, 32), "desc": v} for k, v in list(pending.items())[-BACKGROUND_KEEP:]],
    }


def analyze(lines):
    return analyze_records(iter_records(lines))


def build_snapshot(data):
    transcript, trigger = data.get("transcript_path") or "", data.get("trigger") or ""
    res = None
    if transcript and os.path.isfile(transcript):
        res = analyze_records(read_tail_records(transcript))
    if res is None:
        return None
    return {
        "managed_by": SNAPSHOT_MARKER, "version": 2, "session_id": sanitize_text(data.get("session_id") or ""), "trigger": short(trigger, 80),
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "created_epoch": time.time(),
        "cwd": short(data.get("cwd") or "", 300),
        "user_messages": res["users"][-USER_KEEP:],
        "assistant_tail": res["assistant"][-ASSISTANT_TAIL:],
        "background_tasks": res["pending"][-BACKGROUND_KEEP:],
        "todos": res["todos"][:TODO_KEEP],
        "tool_calls": res["tools"][-TOOL_KEEP:],
        "files": res["files"][-FILE_KEEP:],
    }


# ---------- 存檔、輪替、清舊 ----------

def save_snapshot(snap):
    d = state_dir()
    snap = sanitize_tree(snap)
    sid = str(snap.get("session_id") or "")
    sid_file = snapshot_id(sid)
    if not sid or not sid_file or snap.get("managed_by") != SNAPSHOT_MARKER:
        return
    os.makedirs(d, exist_ok=True)
    stem = SNAPSHOT_PREFIX + snapshot_id(sid)
    cur = os.path.join(d, stem + ".json")
    chain = [cur] + [os.path.join(d, "%s.%d.json" % (stem, i)) for i in range(1, KEEP_SNAPSHOTS)]
    for i in range(len(chain) - 1, 0, -1):          # 往後推：.1 → .2，現在的 → .1
        if os.path.exists(chain[i - 1]):
            os.replace(chain[i - 1], chain[i])
    tmp = cur + ".tmp.%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(snap, f, ensure_ascii=False)
    os.replace(tmp, cur)
    cutoff = time.time() - MAX_AGE_DAYS * 86400
    for name in os.listdir(d):
        p = os.path.join(d, name)
        if not re.fullmatch(re.escape(SNAPSHOT_PREFIX) + r"[A-Za-z0-9_-]+(?:\+[0-9a-f]{12})?(?:\.\d)?\.json", name):
            continue
        try:
            if os.path.getmtime(p) >= cutoff:
                continue
            with open(p, encoding="utf-8") as f:
                existing = json.load(f)
            if isinstance(existing, dict) and existing.get("managed_by") == SNAPSHOT_MARKER:
                os.remove(p)
        except (OSError, ValueError, TypeError):
            continue


def load_snapshot(data):
    d = state_dir()
    sid = str(data.get("session_id") or "")
    sid_file = snapshot_id(sid)
    if not sid or not sid_file:
        return None
    paths = [os.path.join(d, SNAPSHOT_PREFIX + sid_file + ".json")]
    # 相容舊版快照，但仍必須精確比對 session_id，絕不依 cwd 或時間回退。
    legacy_id = safe_id(sid)
    paths.append(os.path.join(d, SNAPSHOT_PREFIX + legacy_id + ".json"))
    paths.append(os.path.join(d, legacy_id + ".json"))
    for p in paths:
        try:
            with open(p, encoding="utf-8") as f:
                snap = json.load(f)
        except (OSError, ValueError, TypeError):
            continue
        if not isinstance(snap, dict) or str(snap.get("session_id") or "") != sid:
            continue
        if p.endswith(SNAPSHOT_PREFIX + sid_file + ".json") and snap.get("managed_by") != SNAPSHOT_MARKER:
            continue
        return snap
    return None


# ---------- 組注入內容（原話、背景任務、待辦優先，選擇性內容先縮減） ----------

INTRO = "以下是壓縮前自動存下的上下文，以為準（若與壓縮摘要有出入，照）。"


def render(snap, users, with_tools=True, assistant=None, with_files=True):
    out = [INTRO, "（快照時間 %s，觸發 %s）" % (short(snap.get("created_at", "?"), 40), short(snap.get("trigger") or "?", 80)), ""]
    out.append("## 使用者最近原話（舊→新，共 %d 則）" % len(users))
    for i, u in enumerate(users, 1):
        out.append("[%d] %s" % (i, cap_text(u.get("text", ""), USER_RENDER_CAP, from_end=True)))
    out += ["", "## 背景任務"]
    bg = [b for b in (snap.get("background_tasks") or []) if isinstance(b, dict)][-BACKGROUND_KEEP:]
    bg_lines = ["- %s（%s）" % (short(b.get("id", "?"), 32), short(b.get("desc", ""), ITEM_TEXT_CAP)) for b in bg]
    out += [cap_text(line, ITEM_TEXT_CAP) for line in bg_lines] or ["（無）"]
    out += ["", "## 未完成清單"]
    todos = [t for t in (snap.get("todos") or []) if isinstance(t, dict)][:TODO_KEEP]
    todo_lines = ["- [%s] %s" % (short(t.get("status", "pending"), 24), short(t.get("content") or t.get("activeForm") or "", ITEM_TEXT_CAP)) for t in todos]
    out += [cap_text(line, ITEM_TEXT_CAP) for line in todo_lines] or ["（無）"]
    a = snap.get("assistant_tail", "") if assistant is None else assistant
    if a:
        out += ["", "## 最近助理文字（結尾）", cap_text(a, ASSISTANT_TAIL, from_end=True)]
    if with_tools:
        tools = [short(t, ITEM_TEXT_CAP) for t in (snap.get("tool_calls") or [])[-TOOL_KEEP:]]
        if tools:
            out += ["", "## 最近工具動作（舊→新）"] + ["- " + t for t in tools]
    if with_files and snap.get("files"):
        out += ["", "## 最近改的檔"] + ["- " + short(f, ITEM_TEXT_CAP) for f in snap["files"][-FILE_KEEP:]]
    return "\n".join(out)


def fit(snap, limit=LIMIT):
    users = [u for u in (snap.get("user_messages") or []) if isinstance(u, dict)][-USER_KEEP:]
    for kw in ({}, {"with_tools": False}, {"with_files": False},
               {"with_tools": False, "with_files": False, "assistant": cap_text(snap.get("assistant_tail", ""), 300, from_end=True)},
               {"with_tools": False, "with_files": False, "assistant": ""}):
        text = render(snap, users, **kw)
        if len(text) <= limit:
            return text
    kw = {"with_tools": False, "assistant": "", "with_files": False}
    while len(users) > 1:
        users = users[1:]
        text = render(snap, users, **kw)
        if len(text) <= limit:
            return text
    text = render(snap, users, **kw)
    if len(text) > limit and users:
        users[0] = {"text": cap_text(users[0].get("text", ""), USER_RENDER_CAP, from_end=True)}
        text = render(snap, users, **kw)
    if len(text) > limit:
        # Defensive fallback for malformed/legacy snapshots: preserve the newest original, background tasks,
        # and as many todos as fit; never chop the assembled document in the middle of a section.
        fallback = dict(snap)
        fallback["todos"] = (snap.get("todos") or [])[:TODO_KEEP]
        while fallback["todos"] and len(render(fallback, users[-1:], **kw)) > limit:
            fallback["todos"].pop()
        text = render(fallback, users[-1:], **kw)
    return text


# ---------- 進入點 ----------

def main(argv):
    try:
        cmd = argv[1] if len(argv) > 1 else ""
        data = json.loads(sys.stdin.read() or "{}")
        if not isinstance(data, dict):
            data = {}
    except Exception:
        return 0
    try:
        if cmd == "pre-compact":
            snap = build_snapshot(data)
            if snap:
                save_snapshot(snap)
        elif cmd == "session-start":
            if data.get("source") != "compact":
                return 0
            snap = load_snapshot(data)
            if snap and snap.get("user_messages") is not None:
                sys.stdout.write(json.dumps({"hookSpecificOutput": {
                    "hookEventName": "SessionStart", "additionalContext": fit(snap)}}, ensure_ascii=False))
    except Exception:                        # 防呆：hook 出任何錯都不能影響 Claude
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
