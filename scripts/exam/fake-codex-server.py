#!/usr/bin/env python3
"""最小 codex app-server fixture：turn/start 持續輸出，turn/interrupt 收到後回覆並結束該 turn。"""
import json
import sys

thread_id = "exam-thread"
turn_id = None


def send(message):
    sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    try:
        request = json.loads(line)
    except (json.JSONDecodeError, TypeError):
        continue
    method = request.get("method")
    params = request.get("params") or {}
    request_id = request.get("id")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": request_id, "result": {}})
    elif method == "thread/start":
        send({"jsonrpc": "2.0", "id": request_id, "result": {"thread": {"id": thread_id}}})
    elif method == "turn/start":
        turn_id = "exam-turn"
        send({"jsonrpc": "2.0", "id": request_id, "result": {"turn": {"id": turn_id}}})
        send({"jsonrpc": "2.0", "method": "turn/started", "params": {"threadId": thread_id, "turn": {"id": turn_id}}})
        send({"jsonrpc": "2.0", "method": "item/started", "params": {"item": {"id": "exam-item", "type": "agentMessage"}}})
        send({"jsonrpc": "2.0", "method": "item/agentMessage/delta", "params": {"itemId": "exam-item", "delta": "正在生成中的假回覆"}})
    elif method == "turn/interrupt":
        valid = params.get("threadId") == thread_id and params.get("turnId") == turn_id
        if valid:
            send({"jsonrpc": "2.0", "id": request_id, "result": {}})
            send({"jsonrpc": "2.0", "method": "turn/completed", "params": {"threadId": thread_id, "turn": {"id": turn_id, "status": "interrupted"}}})
            turn_id = None
        else:
            send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32602, "message": "unknown active turn"}})
