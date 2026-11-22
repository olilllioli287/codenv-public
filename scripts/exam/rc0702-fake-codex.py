#!/usr/bin/env python3
"""00.07.02 考題用的假 codex app-server：中斷不生效。

用法：codenv 測試版加 --codex-bin <包這個檔的 wrapper>；wrapper：
  #!/bin/sh
  exec python3 <這個檔> <記錄檔> <秒數>
行為：turn/start 後什麼都不輸出（不開工具項目，免得被當成『執行中的指令』而不中斷）；收到 turn/interrupt 只回 {}（不結束這一輪，模擬 Codex 長工具 15 秒內沒停）；
過「秒數」秒後自己結束這一輪（agentMessage 內容為 CODEX自然完成，turn/completed 狀態 completed）。
進階（C296）：第 3 個參數＝逗號分隔的秒數清單、第 4 個參數＝計數檔：每個假 Codex 程序啟動時依計數檔取下一個秒數 N，
模式改成「收到第一個 turn/interrupt 後過 N 秒才自然完成」（同樣不停、不回報中斷結果），用來在旗標期限剛過的時間點讓 result 到達；每個 turn/interrupt 另寫 #interrupt-at <epoch 秒>。
每個收到的 JSON-RPC 請求寫進記錄檔一行（方法名＋原始行），方便考題數 turn/interrupt、turn/start、turn/steer 次數。
"""
import json
import sys
import threading
import time

LOG = sys.argv[1] if len(sys.argv) > 1 else "/private/tmp/fake-codex.log"
SECS = float(sys.argv[2]) if len(sys.argv) > 2 else 45.0
AFTER = None
if len(sys.argv) > 4:
    try:
        with open(sys.argv[4], "a+", encoding="utf-8") as _f:
            _f.seek(0)
            _n = len(_f.read().split())
            _f.write("x\n")
        _lst = [float(x) for x in sys.argv[3].split(",")]
        AFTER = _lst[_n % len(_lst)]
    except (OSError, ValueError):
        AFTER = None
thread_id = "exam-thread-0702"
state = {"turn": None, "n": 0}
lock = threading.Lock()


def send(message):
    with lock:
        sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")
        sys.stdout.flush()


def log(line):
    with open(LOG, "a", encoding="utf-8") as f:
        f.write(line.rstrip("\n") + "\n")


def finish(turn_id):
    if state["turn"] != turn_id:
        return
    log("#turn-finished-natural " + turn_id)
    item = "msg-" + turn_id
    send({"jsonrpc": "2.0", "method": "item/started", "params": {"threadId": thread_id, "turnId": turn_id, "item": {"id": item, "type": "agentMessage"}}})
    send({"jsonrpc": "2.0", "method": "item/agentMessage/delta", "params": {"threadId": thread_id, "turnId": turn_id, "itemId": item, "delta": "CODEX自然完成"}})
    send({"jsonrpc": "2.0", "method": "item/completed", "params": {"threadId": thread_id, "turnId": turn_id, "item": {"id": item, "type": "agentMessage", "text": "CODEX自然完成"}}})
    send({"jsonrpc": "2.0", "method": "turn/completed", "params": {"threadId": thread_id, "turn": {"id": turn_id, "status": "completed"}}})
    state["turn"] = None


log("#pid start")
for line in sys.stdin:
    try:
        request = json.loads(line)
    except (json.JSONDecodeError, TypeError):
        continue
    method = request.get("method")
    params = request.get("params") or {}
    rid = request.get("id")
    log("%s %s" % (method, line.strip()[:300]))
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": rid, "result": {}})
    elif method in ("thread/start", "thread/resume"):
        send({"jsonrpc": "2.0", "id": rid, "result": {"thread": {"id": thread_id}}})
    elif method == "turn/start":
        state["n"] += 1
        turn_id = "exam-turn-%d" % state["n"]
        state["turn"] = turn_id
        send({"jsonrpc": "2.0", "id": rid, "result": {"turn": {"id": turn_id}}})
        send({"jsonrpc": "2.0", "method": "turn/started", "params": {"threadId": thread_id, "turn": {"id": turn_id}}})
        if AFTER is None:
            t = threading.Timer(SECS, finish, args=(turn_id,))
            t.daemon = True
            t.start()
    elif method == "turn/interrupt":
        log("#interrupt-at %.3f" % time.time())
        if AFTER is not None and state["turn"] and not state.get("after_set"):
            state["after_set"] = True
            t = threading.Timer(AFTER, finish, args=(state["turn"],))
            t.daemon = True
            t.start()
        send({"jsonrpc": "2.0", "id": rid, "result": {}})  # 回應但不停
    elif rid is not None:
        send({"jsonrpc": "2.0", "id": rid, "result": {}})
